-- ====================================================================================
-- GIS 空间数据校验
-- ====================================================================================
-- 主入口：
--   SELECT * FROM gis_validate_table('表名', 'Geometry');
--
-- 作用：
--   校验指定表中的空间数据，支持 GeoJSON 文本字段和 PostGIS geom 字段。
--   错误统一写入 gis_error_table，通过 table_name 区分来源表。
--
-- 支持字段：
--   主键字段：id、uid、pk、gid，按顺序自动识别。
--   空间字段：lng_lat_alt、geojson、geometry_json、geo_data、geom，按顺序自动识别。
--
-- 支持类型：
--   Geometry：点、线、面都允许。
--   Point   ：只允许 ST_Point / ST_MultiPoint。
--   Line    ：只允许 ST_LineString / ST_MultiLineString。
--   Polygon ：只允许 ST_Polygon / ST_MultiPolygon，并检查面环闭合。
--
-- 返回：
--   error_count   ：本次错误数量。
--   sql_statement ：查看本次错误明细的 SQL。
-- ====================================================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_geojson_to_geom');
-- ====================================================================================
-- 1. GeoJSON 转 geometry
-- ====================================================================================
-- 一个函数处理点、线、面：
--   1. 支持 FeatureCollection、Feature 和直接 Geometry 三种格式。
--   2. 点、线直接转 geometry。
--   3. Polygon / MultiPolygon 未闭合时，自动追加首点再转换。
CREATE OR REPLACE FUNCTION gis_geojson_to_geom(
    p_geojson text,
    p_geo_type text DEFAULT 'Geometry'
)
RETURNS geometry
LANGUAGE plpgsql
AS $$
DECLARE
    v_json jsonb;       -- 输入字符串转成的完整 JSON
    v_geom_json jsonb;  -- 真正的 geometry JSON；Feature 格式时取 geometry 节点
    v_geom_type text;   -- GeoJSON 类型：Point/LineString/Polygon/MultiPolygon 等
    v_features jsonb;   -- FeatureCollection 中的 features 数组
    v_feature_count integer; -- FeatureCollection 中有效 geometry 数量
    v_bad_ring_count integer; -- 面数据中无法组成面的坏环数量
BEGIN
    IF p_geojson IS NULL OR trim(p_geojson) = '' THEN
        RETURN NULL;
    END IF;

    -- GeoJSON 文本必须先能转成 jsonb；非法 JSON 会抛异常，由主校验函数记录。
    v_json := p_geojson::jsonb;

    -- 兼容三种常见格式：
    --   FeatureCollection：{"type":"FeatureCollection","features":[...]}
    --   Feature ：{"type":"Feature","geometry":{...}}
    --   Geometry：{"type":"Polygon","coordinates":[...]}
    IF v_json ->> 'type' = 'FeatureCollection' THEN
        v_features := CASE
            WHEN jsonb_typeof(v_json -> 'features') = 'array' THEN v_json -> 'features'
            ELSE '[]'::jsonb
        END;

        SELECT count(*)
        INTO v_feature_count
        FROM jsonb_array_elements(v_features) AS f(feature)
        WHERE jsonb_typeof(f.feature -> 'geometry') = 'object';

        IF v_feature_count = 0 THEN
            RETURN NULL;
        END IF;

        IF v_feature_count = 1 THEN
            SELECT f.feature -> 'geometry'
            INTO v_geom_json
            FROM jsonb_array_elements(v_features) AS f(feature)
            WHERE jsonb_typeof(f.feature -> 'geometry') = 'object'
            LIMIT 1;
        ELSE
            SELECT
                CASE
                    WHEN bool_and(f.feature -> 'geometry' ->> 'type' = 'Polygon')
                        THEN jsonb_build_object(
                            'type', 'MultiPolygon',
                            'coordinates', jsonb_agg(f.feature -> 'geometry' -> 'coordinates' ORDER BY feature_ord)
                        )
                    ELSE jsonb_build_object(
                        'type', 'GeometryCollection',
                        'geometries', jsonb_agg(f.feature -> 'geometry' ORDER BY feature_ord)
                    )
                END
            INTO v_geom_json
            FROM jsonb_array_elements(v_features) WITH ORDINALITY AS f(feature, feature_ord)
            WHERE jsonb_typeof(f.feature -> 'geometry') = 'object';
        END IF;
    ELSIF v_json ->> 'type' = 'Feature' THEN
        v_geom_json := v_json -> 'geometry';
    ELSE
        v_geom_json := v_json;
    END IF;

    IF v_geom_json IS NULL THEN
        RETURN NULL;
    END IF;

    v_geom_type := v_geom_json ->> 'type';

    -- 只有面需要补闭合点；点线不做额外处理。
    IF v_geom_type = 'Polygon' THEN
        IF jsonb_typeof(v_geom_json -> 'coordinates') IS DISTINCT FROM 'array' THEN
            RETURN NULL;
        END IF;

        IF jsonb_array_length(v_geom_json -> 'coordinates') = 0 THEN
            RETURN NULL;
        END IF;

        -- Polygon 的每个 ring 至少要有 3 个点，才能补首点形成合法闭合环。
        -- 例如 {"coordinates":[[]]} 是坏数据，不能转换成面。
        SELECT count(*)
        INTO v_bad_ring_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS r(ring)
        WHERE CASE
            WHEN jsonb_typeof(ring) = 'array' THEN jsonb_array_length(ring) < 3
            ELSE true
        END;

        IF v_bad_ring_count > 0 THEN
            RETURN NULL;
        END IF;

        -- Polygon 坐标结构：coordinates = [ring1, ring2, ...]
        -- 对每一个 ring 检查首尾点；未闭合就追加首点。
        SELECT jsonb_set(
            v_geom_json,
            '{coordinates}',
            COALESCE(
                jsonb_agg(
                    CASE
                        WHEN jsonb_array_length(ring) > 0
                             AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1)
                            THEN ring || jsonb_build_array(ring -> 0)
                        ELSE ring
                    END
                    ORDER BY ring_ord
                ),
                '[]'::jsonb
            ),
            false
        )
        INTO v_geom_json
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') WITH ORDINALITY AS r(ring, ring_ord);

    ELSIF v_geom_type = 'MultiPolygon' THEN
        IF jsonb_typeof(v_geom_json -> 'coordinates') IS DISTINCT FROM 'array' THEN
            RETURN NULL;
        END IF;

        IF jsonb_array_length(v_geom_json -> 'coordinates') = 0 THEN
            RETURN NULL;
        END IF;

        SELECT count(*)
        INTO v_bad_ring_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS p(poly)
        WHERE jsonb_typeof(poly) IS DISTINCT FROM 'array'
           OR jsonb_array_length(poly) = 0;

        IF v_bad_ring_count > 0 THEN
            RETURN NULL;
        END IF;

        -- MultiPolygon 的每个 ring 也至少要有 3 个点。
        SELECT count(*)
        INTO v_bad_ring_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS p(poly)
        CROSS JOIN LATERAL jsonb_array_elements(p.poly) AS r(ring)
        WHERE CASE
            WHEN jsonb_typeof(ring) = 'array' THEN jsonb_array_length(ring) < 3
            ELSE true
        END;

        IF v_bad_ring_count > 0 THEN
            RETURN NULL;
        END IF;

        -- MultiPolygon 坐标结构：coordinates = [polygon1, polygon2, ...]
        -- 每个 polygon 内还有多个 ring，所以需要先拆 polygon，再拆 ring。
        SELECT jsonb_set(
            v_geom_json,
            '{coordinates}',
            COALESCE(jsonb_agg(poly_closed ORDER BY poly_ord), '[]'::jsonb),
            false
        )
        INTO v_geom_json
        FROM (
            SELECT
                poly_ord,
                jsonb_agg(
                    CASE
                        WHEN jsonb_array_length(ring) > 0
                             AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1)
                            THEN ring || jsonb_build_array(ring -> 0)
                        ELSE ring
                    END
                    ORDER BY ring_ord
                ) AS poly_closed
            FROM jsonb_array_elements(v_geom_json -> 'coordinates') WITH ORDINALITY AS p(poly, poly_ord)
            CROSS JOIN LATERAL jsonb_array_elements(p.poly) WITH ORDINALITY AS r(ring, ring_ord)
            GROUP BY poly_ord
        ) s;
    END IF;

    -- 最终交给 PostGIS 解析成 geometry。
    RETURN ST_GeomFromGeoJSON(v_geom_json::text);
END;
$$;
COMMENT ON FUNCTION gis_geojson_to_geom(text, text) IS 'GeoJSON转几何';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_validate_write_error');
-- ====================================================================================
-- 2. 错误写入
-- ====================================================================================
-- 统一把校验错误写入 gis_error_table。
CREATE OR REPLACE FUNCTION gis_validate_write_error(
    p_error_table text,        -- 错误表名，目前固定为 gis_error_table
    p_table_name text,         -- 被校验的源表名
    p_row_id text,             -- 源表错误行主键值
    p_column_name text,        -- 被校验的空间字段名
    p_geometry_type text,      -- 实际几何类型或期望几何类型
    p_error_code text,         -- 错误分类
    p_error_message text,      -- 错误说明
    p_bad_json_value text,     -- 原始空间字段值，或 geom 转出的 GeoJSON
    p_error_data_json jsonb,   -- 源表错误行完整 JSON
    p_correct_geojson text,    -- 能自动修复时生成的正确 GeoJSON
    p_correct_data_json jsonb, -- 能自动修复时生成的修复后整行 JSON
    p_correct_sql_value text,  -- 参考修复 SQL
    p_is_ring_closed boolean,  -- 面环是否闭合
    p_bad_sql_value text,      -- 定位源表错误行的查询 SQL
    p_check_batch text         -- 本次校验批次号
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- 表名需要动态拼接，所以用 EXECUTE format('%I')；字段值通过 USING 绑定，避免引号转义问题。
    EXECUTE format('
        INSERT INTO %I(
            table_name, row_id, column_name, geometry_type,
            error_code, error_message, bad_json_value, error_data_json,
            correct_geojson, correct_data_json, correct_sql_value, is_ring_closed,
            bad_sql_value, check_batch
        ) VALUES (
            $1, $2, $3, $4,
            $5, $6, $7, $8,
            $9, $10, $11, $12,
            $13, $14
        )',
        p_error_table
    )
    USING
        p_table_name,
        p_row_id,
        p_column_name,
        p_geometry_type,
        p_error_code,
        p_error_message,
        p_bad_json_value,
        p_error_data_json,
        p_correct_geojson,
        p_correct_data_json,
        p_correct_sql_value,
        p_is_ring_closed,
        p_bad_sql_value,
        p_check_batch;
END;
$$;
COMMENT ON FUNCTION gis_validate_write_error(
    text, text, text, text, text, text, text, text, jsonb, text, jsonb, text, boolean, text, text
) IS '写校验错误';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_validate_table');
-- ====================================================================================
-- 主校验函数
-- ====================================================================================
CREATE OR REPLACE FUNCTION gis_validate_table(
    p_table_name text,
    p_geo_type text DEFAULT 'Geometry'
)
RETURNS TABLE(error_count int, sql_statement text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_column text;       -- 自动识别到的主键字段
    v_geo_column text;      -- 自动识别到的空间字段
    v_table_reg regclass;   -- 真实表对象，兼容 schema.table
    v_table_sql text;       -- 动态 SQL 中使用的安全表名
    v_error_table text := 'gis_error_table'; -- 统一错误表
    v_allowed_types text[]; -- 本次允许的 PostGIS 几何类型列表
    v_sql text;             -- 遍历源表数据的动态 SQL

    rec record;             -- 当前正在校验的源表行
    v_geo_text text;        -- 当前空间数据的 GeoJSON 文本
    v_geom geometry;        -- 当前空间数据转成的 PostGIS geometry
    v_row_json jsonb;       -- 当前源表行完整 JSON
    v_row_sql text;         -- 定位当前源表行的查询 SQL

    v_error_code text;      -- 错误分类
    v_error_message text;   -- 错误说明
    v_check_batch text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'); -- 本次校验批次
    v_error_count int := 0; -- 本次累计错误数量

    v_correct_geom geometry;     -- 自动修复后的 geometry
    v_correct_geojson text;      -- 自动修复后的 GeoJSON
    v_correct_data_json jsonb;   -- 自动修复后的整行 JSON
    v_correct_sql_value text;    -- 参考修复 SQL

    v_json jsonb;                -- 面闭合检查时使用的完整 JSON
    v_geom_json jsonb;           -- 面闭合检查时使用的 geometry JSON
    v_geom_type text;            -- 面闭合检查时使用的 GeoJSON 类型
    v_features jsonb;            -- FeatureCollection 中的 features 数组
    v_feature_count integer;     -- FeatureCollection 中有效 geometry 数量
    v_is_ring_closed boolean;    -- 面环是否闭合
    v_not_closed_count int;      -- 未闭合环数量
BEGIN
    -- 0. 先确认表是否存在。
    -- to_regclass 支持 search_path，也支持传入 public.bo_electric_fence 这类 schema.table。
    v_table_reg := to_regclass(p_table_name);
    IF v_table_reg IS NULL THEN
        RAISE EXCEPTION 'Cannot find table %', p_table_name;
    END IF;
    v_table_sql := v_table_reg::text;

    -- 1. 根据入参确定允许的几何类型。
    CASE lower(coalesce(p_geo_type, 'geometry'))
        WHEN 'point' THEN
            v_allowed_types := ARRAY['ST_Point', 'ST_MultiPoint'];
        WHEN 'line' THEN
            v_allowed_types := ARRAY['ST_LineString', 'ST_MultiLineString'];
        WHEN 'linestring' THEN
            v_allowed_types := ARRAY['ST_LineString', 'ST_MultiLineString'];
        WHEN 'polygon' THEN
            v_allowed_types := ARRAY['ST_Polygon', 'ST_MultiPolygon'];
        ELSE
            v_allowed_types := ARRAY[
                'ST_Point',
                'ST_MultiPoint',
                'ST_LineString',
                'ST_MultiLineString',
                'ST_Polygon',
                'ST_MultiPolygon'
            ];
    END CASE;

    -- 2. 自动识别主键字段。
    SELECT attname INTO v_id_column
    FROM pg_attribute
    WHERE attrelid = v_table_reg
      AND attnum > 0
      AND NOT attisdropped
      AND attname IN ('id', 'uid', 'pk', 'gid')
    ORDER BY CASE attname
        WHEN 'id' THEN 1
        WHEN 'uid' THEN 2
        WHEN 'pk' THEN 3
        WHEN 'gid' THEN 4
        ELSE 99
    END
    LIMIT 1;

    IF v_id_column IS NULL THEN
        v_id_column := 'id';
    END IF;

    -- 3. 自动识别空间字段。
    SELECT attname INTO v_geo_column
    FROM pg_attribute
    WHERE attrelid = v_table_reg
      AND attnum > 0
      AND NOT attisdropped
      AND attname IN ('lng_lat_alt', 'geojson', 'geometry_json', 'geo_data', 'geom')
    ORDER BY CASE attname
        WHEN 'lng_lat_alt' THEN 1
        WHEN 'geojson' THEN 2
        WHEN 'geometry_json' THEN 3
        WHEN 'geo_data' THEN 4
        WHEN 'geom' THEN 5
        ELSE 99
    END
    LIMIT 1;

    IF v_geo_column IS NULL THEN
        RAISE EXCEPTION 'Cannot find GeoJSON or geom column in table %', p_table_name;
    END IF;

    -- 4. 创建统一错误表。
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            error_id bigserial PRIMARY KEY,
            check_batch text,          -- 本次校验批次号
            checked_at timestamptz DEFAULT now(), -- 错误写入时间
            table_name text,           -- 被校验的源表名
            row_id text,               -- 源表错误行主键值
            column_name text,          -- 被校验的空间字段名
            geometry_type text,        -- 实际几何类型或期望几何类型
            error_code text,           -- 错误分类
            error_message text,        -- 错误说明
            bad_json_value text,       -- 原始空间字段值，或 geom 转出的 GeoJSON
            error_data_json jsonb,     -- 源表错误行完整 JSON
            correct_geojson text,      -- 自动修复后的 GeoJSON
            correct_data_json jsonb,   -- 自动修复后的整行 JSON
            correct_sql_value text,    -- 参考修复 SQL
            is_ring_closed boolean,    -- 面环是否闭合
            bad_sql_value text         -- 定位源表错误行的查询 SQL
        )',
        v_error_table
    );

    EXECUTE format('COMMENT ON TABLE %I IS %L', v_error_table, 'GIS空间数据校验错误明细表，按批次追加记录');
    EXECUTE format('COMMENT ON COLUMN %I.check_batch IS %L', v_error_table, '本次校验批次号');
    EXECUTE format('COMMENT ON COLUMN %I.table_name IS %L', v_error_table, '被校验的源表名');
    EXECUTE format('COMMENT ON COLUMN %I.row_id IS %L', v_error_table, '源表错误数据主键值');
    EXECUTE format('COMMENT ON COLUMN %I.error_code IS %L', v_error_table, '错误分类');
    EXECUTE format('COMMENT ON COLUMN %I.error_message IS %L', v_error_table, '错误说明');
    EXECUTE format('COMMENT ON COLUMN %I.correct_sql_value IS %L', v_error_table, '参考修复 SQL');

    -- 5. 遍历待校验数据。
    -- 这里不写死字段名，而是使用前面识别出的主键字段和空间字段。
    IF v_geo_column = 'geom' THEN
        v_sql := format(
            'SELECT %I::text AS id, ST_AsGeoJSON(%I)::text AS geo_text, %I::geometry AS geom_value, to_jsonb(t) AS row_json FROM %s t WHERE %I IS NOT NULL',
            v_id_column, v_geo_column, v_geo_column, v_table_sql, v_geo_column
        );
    ELSE
        v_sql := format(
            'SELECT %I::text AS id, %I::text AS geo_text, NULL::geometry AS geom_value, to_jsonb(t) AS row_json FROM %s t WHERE %I IS NOT NULL',
            v_id_column, v_geo_column, v_table_sql, v_geo_column
        );
    END IF;

    FOR rec IN EXECUTE v_sql LOOP
        -- 每行开始前清空中间变量，避免上一行的修复结果影响下一行。
        v_geo_text := NULL;
        v_geom := NULL;
        v_row_json := rec.row_json;
        v_row_sql := format('SELECT * FROM %s WHERE %I = %L', v_table_sql, v_id_column, rec.id);

        v_correct_geom := NULL;
        v_correct_geojson := NULL;
        v_correct_data_json := NULL;
        v_correct_sql_value := NULL;
        v_is_ring_closed := NULL;

        BEGIN
            -- 5.1 解析空间数据。
            IF v_geo_column = 'geom' THEN
                -- 已迁移后的 PostGIS 字段直接校验，同时转成 GeoJSON 方便错误表展示。
                v_geom := rec.geom_value;
                v_geo_text := rec.geo_text;
            ELSE
                -- 迁移前的文本字段按 GeoJSON 解析；面数据会在 gis_geojson_to_geom 内自动补闭合点。
                v_geo_text := rec.geo_text;
                v_geom := gis_geojson_to_geom(v_geo_text, p_geo_type);
            END IF;

            -- 5.2 空间数据为空或无法转 geometry。
            IF v_geom IS NULL THEN
                v_error_code := '缺少空间数据';
                v_error_message := 'GeoJSON 中缺少 geometry 节点，或 geom 字段为空/无效';

                PERFORM gis_validate_write_error(
                    v_error_table, p_table_name, rec.id::text, v_geo_column, p_geo_type,
                    v_error_code, v_error_message, v_geo_text, v_row_json,
                    v_correct_geojson, v_correct_data_json, v_correct_sql_value,
                    v_is_ring_closed, v_row_sql, v_check_batch
                );

                v_error_count := v_error_count + 1;
                CONTINUE;
            END IF;

            -- 5.3 类型不匹配。
            IF NOT ST_GeometryType(v_geom) = ANY(v_allowed_types) THEN
                v_error_code := '几何类型不匹配';
                v_error_message := format(
                    '当前几何类型为 %s，不在允许类型 [%s] 中',
                    ST_GeometryType(v_geom),
                    array_to_string(v_allowed_types, ',')
                );

                PERFORM gis_validate_write_error(
                    v_error_table, p_table_name, rec.id::text, v_geo_column, ST_GeometryType(v_geom),
                    v_error_code, v_error_message, v_geo_text, v_row_json,
                    v_correct_geojson, v_correct_data_json, v_correct_sql_value,
                    v_is_ring_closed, v_row_sql, v_check_batch
                );

                v_error_count := v_error_count + 1;
                CONTINUE;
            END IF;

            -- 5.4 面数据闭合检查。
            IF ST_GeometryType(v_geom) IN ('ST_Polygon', 'ST_MultiPolygon') THEN
                IF v_geo_column = 'geom' THEN
                    -- geom 字段已经是 PostGIS geometry，直接用边界是否闭合判断。
                    v_is_ring_closed := ST_IsClosed(ST_Boundary(v_geom));
                ELSE
                    -- GeoJSON 文本需要检查原始坐标是否本来闭合。
                    -- 注意：v_geom 已经是补点后的 geometry，所以不能用它判断原始数据是否闭合。
                    v_json := v_geo_text::jsonb;

                    IF v_json ->> 'type' = 'FeatureCollection' THEN
                        v_features := CASE
                            WHEN jsonb_typeof(v_json -> 'features') = 'array' THEN v_json -> 'features'
                            ELSE '[]'::jsonb
                        END;

                        SELECT count(*)
                        INTO v_feature_count
                        FROM jsonb_array_elements(v_features) AS f(feature)
                        WHERE jsonb_typeof(f.feature -> 'geometry') = 'object';

                        IF v_feature_count = 1 THEN
                            SELECT f.feature -> 'geometry'
                            INTO v_geom_json
                            FROM jsonb_array_elements(v_features) AS f(feature)
                            WHERE jsonb_typeof(f.feature -> 'geometry') = 'object'
                            LIMIT 1;
                        ELSIF v_feature_count > 1 THEN
                            SELECT
                                CASE
                                    WHEN bool_and(f.feature -> 'geometry' ->> 'type' = 'Polygon')
                                        THEN jsonb_build_object(
                                            'type', 'MultiPolygon',
                                            'coordinates', jsonb_agg(f.feature -> 'geometry' -> 'coordinates' ORDER BY feature_ord)
                                        )
                                    ELSE jsonb_build_object(
                                        'type', 'GeometryCollection',
                                        'geometries', jsonb_agg(f.feature -> 'geometry' ORDER BY feature_ord)
                                    )
                                END
                            INTO v_geom_json
                            FROM jsonb_array_elements(v_features) WITH ORDINALITY AS f(feature, feature_ord)
                            WHERE jsonb_typeof(f.feature -> 'geometry') = 'object';
                        ELSE
                            v_geom_json := NULL;
                        END IF;
                    ELSIF v_json ->> 'type' = 'Feature' THEN
                        v_geom_json := v_json -> 'geometry';
                    ELSE
                        v_geom_json := v_json;
                    END IF;

                    v_geom_type := v_geom_json ->> 'type';

                    IF v_geom_type = 'Polygon' THEN
                        -- Polygon：逐个 ring 检查首尾坐标是否一致。
                        SELECT count(*) INTO v_not_closed_count
                        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS r(ring)
                        WHERE jsonb_array_length(ring) > 0
                          AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1);

                    ELSIF v_geom_type = 'MultiPolygon' THEN
                        -- MultiPolygon：先拆 polygon，再逐个 ring 检查首尾坐标。
                        SELECT count(*) INTO v_not_closed_count
                        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS p(poly)
                        CROSS JOIN LATERAL jsonb_array_elements(p.poly) AS r(ring)
                        WHERE jsonb_array_length(ring) > 0
                          AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1);
                    ELSE
                        v_not_closed_count := 0;
                    END IF;

                    v_is_ring_closed := v_not_closed_count = 0;
                END IF;

                IF NOT v_is_ring_closed THEN
                    v_error_code := '面未闭合';
                    v_error_message := 'Polygon/MultiPolygon 存在未闭合环，已生成闭合后的正确数据';

                    -- 生成修复建议：闭合后的 GeoJSON、闭合后的整行 JSON、可参考执行的 UPDATE。
                    v_correct_geom := gis_geojson_to_geom(v_geo_text, 'Polygon');
                    v_correct_geojson := ST_AsGeoJSON(v_correct_geom);
                    v_correct_data_json := jsonb_set(v_row_json, ARRAY[v_geo_column], to_jsonb(v_correct_geojson), true);

                    IF v_geo_column = 'geom' THEN
                        v_correct_sql_value := format(
                            'UPDATE %s SET %I = ST_SetSRID(ST_GeomFromGeoJSON(%L), 4326) WHERE %I = %L;',
                            v_table_sql, v_geo_column, v_correct_geojson, v_id_column, rec.id
                        );
                    ELSE
                        v_correct_sql_value := format(
                            'UPDATE %s SET %I = %L WHERE %I = %L;',
                            v_table_sql, v_geo_column, v_correct_geojson, v_id_column, rec.id
                        );
                    END IF;

                    PERFORM gis_validate_write_error(
                        v_error_table, p_table_name, rec.id::text, v_geo_column, ST_GeometryType(v_geom),
                        v_error_code, v_error_message, v_geo_text, v_row_json,
                        v_correct_geojson, v_correct_data_json, v_correct_sql_value,
                        v_is_ring_closed, v_row_sql, v_check_batch
                    );

                    v_error_count := v_error_count + 1;
                    CONTINUE;
                END IF;
            END IF;

            -- 5.5 PostGIS 有效性检查。
            IF NOT ST_IsValid(v_geom) THEN
                v_error_code := '空间数据无效';
                v_error_message := '空间数据无效：' || ST_IsValidReason(v_geom);

                -- ST_MakeValid 能修复自相交等无效几何，修复结果写入错误表供人工确认。
                v_correct_geom := ST_MakeValid(v_geom);
                v_correct_geojson := ST_AsGeoJSON(v_correct_geom);
                v_correct_data_json := jsonb_set(v_row_json, ARRAY[v_geo_column], to_jsonb(v_correct_geojson), true);

                IF v_geo_column = 'geom' THEN
                    v_correct_sql_value := format(
                        'UPDATE %s SET %I = ST_SetSRID(ST_GeomFromGeoJSON(%L), 4326) WHERE %I = %L;',
                        v_table_sql, v_geo_column, v_correct_geojson, v_id_column, rec.id
                    );
                ELSE
                    v_correct_sql_value := format(
                        'UPDATE %s SET %I = %L WHERE %I = %L;',
                        v_table_sql, v_geo_column, v_correct_geojson, v_id_column, rec.id
                    );
                END IF;

                PERFORM gis_validate_write_error(
                    v_error_table, p_table_name, rec.id::text, v_geo_column, ST_GeometryType(v_geom),
                    v_error_code, v_error_message, v_geo_text, v_row_json,
                    v_correct_geojson, v_correct_data_json, v_correct_sql_value,
                    v_is_ring_closed, v_row_sql, v_check_batch
                );

                v_error_count := v_error_count + 1;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- 单行数据解析失败不影响整表校验，记录错误后继续下一行。
            v_error_code := '空间数据解析失败';
            v_error_message := '空间数据解析失败：' || SQLERRM;

            PERFORM gis_validate_write_error(
                v_error_table, p_table_name, rec.id::text, v_geo_column, p_geo_type,
                v_error_code, v_error_message, v_geo_text, v_row_json,
                v_correct_geojson, v_correct_data_json, v_correct_sql_value,
                v_is_ring_closed, v_row_sql, v_check_batch
            );

            v_error_count := v_error_count + 1;
        END;
    END LOOP;

    -- 返回本次错误数量，以及一条可以直接复制执行的查看明细 SQL。
    RETURN QUERY
    SELECT
        v_error_count,
        format(
            'SELECT * FROM %I WHERE check_batch = %L ORDER BY checked_at DESC',
            v_error_table,
            v_check_batch
        )::text;
END;
$$;
COMMENT ON FUNCTION gis_validate_table(text, text) IS '校验空间数据';

-- ====================================================================================
-- 使用示例
-- ====================================================================================

-- 校验点线面全部类型。
SELECT * FROM gis_validate_table('bo_electric_fence', 'Geometry');

SELECT * FROM gis_validate_table('bo_ground_ele', 'Geometry');
-- 只允许点。
-- SELECT * FROM gis_validate_table('your_point_table', 'Point');

-- 只允许线。
-- SELECT * FROM gis_validate_table('your_line_table', 'Line');

-- 只允许面。
-- SELECT * FROM gis_validate_table('your_polygon_table', 'Polygon');

-- 查看某张表的历史错误。
-- SELECT * FROM gis_error_table WHERE table_name = 'bo_electric_fence' ORDER BY checked_at DESC;
