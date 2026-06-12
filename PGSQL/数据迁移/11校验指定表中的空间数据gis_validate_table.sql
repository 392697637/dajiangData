-- ====================================================================================
-- 函数名称：gis_validate_table
-- 功能说明：
--   1. 校验指定表中的空间数据是否合法。
--   2. 支持原始 GeoJSON 文本字段：lng_lat_alt、geojson、geometry_json、geo_data。
--   3. 支持迁移后的 PostGIS 空间字段：geom。
--   4. 自动识别主键字段：id、uid、pk、gid。
--   5. 校验失败的数据追加写入 gis_error_<表名>，不清空历史错误。
--   6. 保存错误行完整 JSON，并记录本次校验批次号，方便回溯问题数据。
--   7. 对可以自动修复的无效空间数据，保存修复后的正确 GeoJSON、正确整行 JSON 和参考修复 SQL。
--   8. 错误表字段按“批次信息 -> 行定位 -> 错误说明 -> 原始数据 -> 修复数据 -> SQL”顺序输出。
--   9. Polygon / MultiPolygon 面环未闭合时，自动生成闭合后的正确数据。
--
-- 入参说明：
--   p_table_name：需要校验的表名，例如 bo_electric_fence。
--   p_geo_type  ：允许的几何类型，支持 Geometry、Point、Line、LineString、Polygon。
--
-- 返回说明：
--   error_count   ：错误数据数量。
--   sql_statement ：查看错误明细的 SQL。
-- ====================================================================================

-- GeoJSON 解析函数：
-- 1. 支持 Feature 和直接 Geometry 两种格式。
-- 2. Polygon / MultiPolygon 外环或内环未闭合时，自动追加第一个点完成闭合。
-- 3. 返回 PostGIS geometry，供校验函数生成修复后的正确数据。
DROP FUNCTION IF EXISTS gis_geojson_to_closed_geom(text);
CREATE OR REPLACE FUNCTION gis_geojson_to_closed_geom(p_geojson text)
RETURNS geometry
LANGUAGE plpgsql
AS $$
DECLARE
    v_json jsonb;
    v_geom_json jsonb;
    v_geom_type text;
BEGIN
    IF p_geojson IS NULL OR trim(p_geojson) = '' THEN
        RETURN NULL;
    END IF;

    v_json := p_geojson::jsonb;

    IF v_json ->> 'type' = 'Feature' THEN
        v_geom_json := v_json -> 'geometry';
    ELSE
        v_geom_json := v_json;
    END IF;

    IF v_geom_json IS NULL THEN
        RETURN NULL;
    END IF;

    v_geom_type := v_geom_json ->> 'type';

    IF v_geom_type = 'Polygon' THEN
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

    RETURN ST_GeomFromGeoJSON(v_geom_json::text);
END;
$$;

-- GeoJSON 面闭合校验函数：
-- 1. 直接检查原始 GeoJSON 坐标数组，不依赖 ST_GeomFromGeoJSON。
-- 2. Polygon / MultiPolygon 所有环首尾点一致时返回 true。
-- 3. 非面数据返回 true，避免影响点/线校验。
DROP FUNCTION IF EXISTS gis_geojson_rings_closed(text);
CREATE OR REPLACE FUNCTION gis_geojson_rings_closed(p_geojson text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_json jsonb;
    v_geom_json jsonb;
    v_geom_type text;
    v_not_closed_count int := 0;
BEGIN
    IF p_geojson IS NULL OR trim(p_geojson) = '' THEN
        RETURN NULL;
    END IF;

    v_json := p_geojson::jsonb;

    IF v_json ->> 'type' = 'Feature' THEN
        v_geom_json := v_json -> 'geometry';
    ELSE
        v_geom_json := v_json;
    END IF;

    IF v_geom_json IS NULL THEN
        RETURN NULL;
    END IF;

    v_geom_type := v_geom_json ->> 'type';

    IF v_geom_type = 'Polygon' THEN
        SELECT count(*) INTO v_not_closed_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS r(ring)
        WHERE jsonb_array_length(ring) > 0
          AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1);

        RETURN v_not_closed_count = 0;

    ELSIF v_geom_type = 'MultiPolygon' THEN
        SELECT count(*) INTO v_not_closed_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS p(poly)
        CROSS JOIN LATERAL jsonb_array_elements(p.poly) AS r(ring)
        WHERE jsonb_array_length(ring) > 0
          AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1);

        RETURN v_not_closed_count = 0;
    END IF;

    RETURN true;
END;
$$;

DROP FUNCTION IF EXISTS gis_validate_table(text, text);

CREATE OR REPLACE FUNCTION gis_validate_table(
    p_table_name text,
    p_geo_type text DEFAULT 'Geometry'
)
RETURNS TABLE(error_count int, sql_statement text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_column text;         -- 自动识别到的主键字段
    v_geo_column text;        -- 自动识别到的空间字段，可能是 GeoJSON 文本字段或 geom 字段
    v_backup_table text;      -- 错误数据输出表：gis_error_<表名>
    v_allowed_types text[];   -- 本次允许的 PostGIS 几何类型
    v_sql text;               -- 动态遍历源表的 SQL
    rec record;               -- 源表当前行
    v_geo_text text;          -- 当前行空间字段的 GeoJSON 文本
    v_geom geometry;          -- 当前行解析后的 PostGIS geometry
    v_correct_geom geometry;  -- ST_MakeValid 修复后的 geometry
    v_correct_geojson text;   -- 修复后的 GeoJSON
    v_correct_data_json jsonb;-- 修复后的整行 JSON
    v_correct_sql_value text; -- 参考修复 SQL
    v_is_ring_closed boolean; -- Polygon/MultiPolygon 面环是否全部闭合
    v_row_json jsonb;         -- 当前错误行完整 JSON
    v_error text;             -- 中文错误说明
    v_error_code text;        -- 中文错误分类
    v_row_sql text;           -- 定位当前错误行的查询 SQL
    v_check_batch text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
    v_error_count int := 0;
BEGIN
    -- 根据入参 p_geo_type 映射允许的 PostGIS 几何类型。
    CASE lower(coalesce(p_geo_type, 'geometry'))
        WHEN 'point' THEN
            v_allowed_types := ARRAY['ST_Point'];
        WHEN 'line' THEN
            v_allowed_types := ARRAY['ST_LineString', 'ST_MultiLineString'];
        WHEN 'linestring' THEN
            v_allowed_types := ARRAY['ST_LineString', 'ST_MultiLineString'];
        WHEN 'polygon' THEN
            v_allowed_types := ARRAY['ST_Polygon', 'ST_MultiPolygon'];
        ELSE
            v_allowed_types := ARRAY[
                'ST_Point',
                'ST_LineString',
                'ST_MultiLineString',
                'ST_Polygon',
                'ST_MultiPolygon'
            ];
    END CASE;

    -- 自动识别源表主键字段，用于记录 row_id 和生成定位 SQL。
    SELECT column_name INTO v_id_column
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = p_table_name
      AND column_name IN ('id', 'uid', 'pk', 'gid')
    ORDER BY CASE column_name
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

    -- 自动识别空间字段。迁移前通常是 GeoJSON 文本字段，迁移后通常是 geom 字段。
    SELECT column_name INTO v_geo_column
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = p_table_name
      AND column_name IN ('lng_lat_alt', 'geojson', 'geometry_json', 'geo_data', 'geom')
    ORDER BY CASE column_name
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

    v_backup_table := 'gis_error_' || p_table_name;

    -- 创建错误输出表。新表按展示/排查最常用的字段顺序创建。
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            error_id bigserial PRIMARY KEY,
            check_batch text,
            checked_at timestamptz DEFAULT now(),
            table_name text,
            row_id text,
            column_name text,
            geometry_type text,
            error_code text,
            error_message text,
            bad_json_value text,
            error_data_json jsonb,
            correct_geojson text,
            correct_data_json jsonb,
            correct_sql_value text,
            is_ring_closed boolean,
            bad_sql_value text
        )', v_backup_table
    );

    -- 兼容已经存在的旧错误表：只补字段，不清空历史数据。
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS error_data_json jsonb', v_backup_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS correct_geojson text', v_backup_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS correct_data_json jsonb', v_backup_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS correct_sql_value text', v_backup_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_ring_closed boolean', v_backup_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS check_batch text', v_backup_table);

    -- 给错误输出表和字段添加注释，便于在 Navicat/pgAdmin 中直接理解字段含义。
    EXECUTE format('COMMENT ON TABLE %I IS %L', v_backup_table, 'GIS空间数据校验错误明细表，按批次追加记录，不清空历史数据');
    EXECUTE format('COMMENT ON COLUMN %I.error_id IS %L', v_backup_table, '错误记录自增主键');
    EXECUTE format('COMMENT ON COLUMN %I.check_batch IS %L', v_backup_table, '本次校验批次号，同一次函数执行产生相同批次号');
    EXECUTE format('COMMENT ON COLUMN %I.checked_at IS %L', v_backup_table, '错误记录写入时间');
    EXECUTE format('COMMENT ON COLUMN %I.table_name IS %L', v_backup_table, '被校验的源表名');
    EXECUTE format('COMMENT ON COLUMN %I.row_id IS %L', v_backup_table, '源表错误数据的主键值');
    EXECUTE format('COMMENT ON COLUMN %I.column_name IS %L', v_backup_table, '被校验的空间字段名');
    EXECUTE format('COMMENT ON COLUMN %I.geometry_type IS %L', v_backup_table, '当前数据解析出的几何类型，或本次期望的几何类型');
    EXECUTE format('COMMENT ON COLUMN %I.error_code IS %L', v_backup_table, '中文错误分类');
    EXECUTE format('COMMENT ON COLUMN %I.error_message IS %L', v_backup_table, '中文错误说明和具体异常原因');
    EXECUTE format('COMMENT ON COLUMN %I.bad_json_value IS %L', v_backup_table, '错误空间字段原始值或转换后的 GeoJSON');
    EXECUTE format('COMMENT ON COLUMN %I.error_data_json IS %L', v_backup_table, '源表错误行完整 JSON');
    EXECUTE format('COMMENT ON COLUMN %I.correct_geojson IS %L', v_backup_table, '可自动修复时生成的正确 GeoJSON');
    EXECUTE format('COMMENT ON COLUMN %I.correct_data_json IS %L', v_backup_table, '可自动修复时生成的修复后整行 JSON');
    EXECUTE format('COMMENT ON COLUMN %I.correct_sql_value IS %L', v_backup_table, '可自动修复时生成的参考 UPDATE SQL');
    EXECUTE format('COMMENT ON COLUMN %I.is_ring_closed IS %L', v_backup_table, '面数据所有环是否已经闭合，true=已闭合，false=存在未闭合环');
    EXECUTE format('COMMENT ON COLUMN %I.bad_sql_value IS %L', v_backup_table, '定位源表错误行的查询 SQL');

    -- 读取待校验数据，同时把整行转成 JSON，方便写入错误表。
    v_sql := format(
        'SELECT %I AS id, %I AS geo_value, to_jsonb(t) AS row_json FROM %I t WHERE %I IS NOT NULL',
        v_id_column, v_geo_column, p_table_name, v_geo_column
    );

    FOR rec IN EXECUTE v_sql LOOP
        -- 每行重新初始化，避免上一行的修复结果污染下一行。
        v_geom := NULL;
        v_correct_geom := NULL;
        v_correct_geojson := NULL;
        v_correct_data_json := NULL;
        v_correct_sql_value := NULL;
        v_is_ring_closed := NULL;
        v_geo_text := NULL;
        v_row_json := rec.row_json;
        v_row_sql := format('SELECT * FROM %I WHERE %I = %L', p_table_name, v_id_column, rec.id);

        BEGIN
            -- geom 字段直接作为 PostGIS geometry 使用；文本字段按 GeoJSON 解析。
            IF v_geo_column = 'geom' THEN
                v_geom := rec.geo_value;
                v_geo_text := ST_AsGeoJSON(v_geom);
            ELSE
                v_geo_text := rec.geo_value::text;

                PERFORM v_geo_text::jsonb;
                v_geom := gis_geojson_to_closed_geom(v_geo_text);
            END IF;

            -- 无法得到 geometry，记录为“缺少空间数据”。
            IF v_geom IS NULL THEN
                v_error_code := '缺少空间数据';
                v_error := 'GeoJSON 中缺少 geometry 节点，或 geom 字段为空/无效';
                EXECUTE format('
                    INSERT INTO %I(
                        table_name, row_id, column_name, geometry_type,
                        error_code, error_message, bad_json_value, error_data_json,
                        correct_geojson, correct_data_json, correct_sql_value, is_ring_closed,
                        bad_sql_value, check_batch
                    ) VALUES (%L, %L, %L, %L, %L, %L, %L, %L::jsonb, %L, %L::jsonb, %L, %L, %L, %L)',
                    v_backup_table,
                    p_table_name, rec.id::text, v_geo_column, p_geo_type,
                    v_error_code, v_error, v_geo_text, v_row_json::text,
                    v_correct_geojson, v_correct_data_json::text, v_correct_sql_value, v_is_ring_closed, v_row_sql,
                    v_check_batch
                );
                v_error_count := v_error_count + 1;
                CONTINUE;
            END IF;

            -- 几何类型不符合 p_geo_type 要求，记录类型错误。
            IF NOT ST_GeometryType(v_geom) = ANY(v_allowed_types) THEN
                v_error_code := '几何类型不匹配';
                v_error := format(
                    '当前几何类型为 %s，不在允许类型 [%s] 中',
                    ST_GeometryType(v_geom),
                    array_to_string(v_allowed_types, ',')
                );
                EXECUTE format('
                    INSERT INTO %I(
                        table_name, row_id, column_name, geometry_type,
                        error_code, error_message, bad_json_value, error_data_json,
                        correct_geojson, correct_data_json, correct_sql_value, is_ring_closed,
                        bad_sql_value, check_batch
                    ) VALUES (%L, %L, %L, %L, %L, %L, %L, %L::jsonb, %L, %L::jsonb, %L, %L, %L, %L)',
                    v_backup_table,
                    p_table_name, rec.id::text, v_geo_column, ST_GeometryType(v_geom),
                    v_error_code, v_error, v_geo_text, v_row_json::text,
                    v_correct_geojson, v_correct_data_json::text, v_correct_sql_value, v_is_ring_closed, v_row_sql,
                    v_check_batch
                );
                v_error_count := v_error_count + 1;
                CONTINUE;
            END IF;

            -- Polygon / MultiPolygon 面闭合校验：存在未闭合环时，生成闭合后的正确数据。
            IF ST_GeometryType(v_geom) IN ('ST_Polygon', 'ST_MultiPolygon') THEN
                IF v_geo_column = 'geom' THEN
                    v_is_ring_closed := ST_IsClosed(ST_Boundary(v_geom));
                ELSE
                    v_is_ring_closed := gis_geojson_rings_closed(v_geo_text);
                END IF;

                IF NOT v_is_ring_closed THEN
                    v_error_code := '面未闭合';
                    v_error := 'Polygon/MultiPolygon 存在未闭合环，已自动追加首点生成闭合后的正确数据';
                    v_correct_geom := gis_geojson_to_closed_geom(v_geo_text);
                    v_correct_geojson := ST_AsGeoJSON(v_correct_geom);
                    v_correct_data_json := jsonb_set(v_row_json, ARRAY[v_geo_column], to_jsonb(v_correct_geojson), true);

                    IF v_geo_column = 'geom' THEN
                        v_correct_sql_value := format(
                            'UPDATE %I SET %I = ST_SetSRID(ST_GeomFromGeoJSON(%L), 4326) WHERE %I = %L;',
                            p_table_name, v_geo_column, v_correct_geojson, v_id_column, rec.id
                        );
                    ELSE
                        v_correct_sql_value := format(
                            'UPDATE %I SET %I = jsonb_set(%I::jsonb, ''{geometry}'', %L::jsonb, true)::text WHERE %I = %L;',
                            p_table_name, v_geo_column, v_geo_column, v_correct_geojson, v_id_column, rec.id
                        );
                    END IF;

                    EXECUTE format('
                        INSERT INTO %I(
                            table_name, row_id, column_name, geometry_type,
                            error_code, error_message, bad_json_value, error_data_json,
                            correct_geojson, correct_data_json, correct_sql_value, is_ring_closed,
                            bad_sql_value, check_batch
                        ) VALUES (%L, %L, %L, %L, %L, %L, %L, %L::jsonb, %L, %L::jsonb, %L, %L, %L, %L)',
                        v_backup_table,
                        p_table_name, rec.id::text, v_geo_column, ST_GeometryType(v_geom),
                        v_error_code, v_error, v_geo_text, v_row_json::text,
                        v_correct_geojson, v_correct_data_json::text, v_correct_sql_value, v_is_ring_closed, v_row_sql,
                        v_check_batch
                    );
                    v_error_count := v_error_count + 1;
                    CONTINUE;
                END IF;
            END IF;

            -- 几何对象无效时，用 ST_MakeValid 生成可参考的修复数据。
            IF NOT ST_IsValid(v_geom) THEN
                v_error_code := '空间数据无效';
                v_error := '空间数据无效：' || ST_IsValidReason(v_geom);
                v_correct_geom := ST_MakeValid(v_geom);
                v_correct_geojson := ST_AsGeoJSON(v_correct_geom);
                v_correct_data_json := jsonb_set(v_row_json, ARRAY[v_geo_column], to_jsonb(v_correct_geojson), true);

                IF v_geo_column = 'geom' THEN
                    v_correct_sql_value := format(
                        'UPDATE %I SET %I = ST_SetSRID(ST_GeomFromGeoJSON(%L), 4326) WHERE %I = %L;',
                        p_table_name, v_geo_column, v_correct_geojson, v_id_column, rec.id
                    );
                ELSE
                    v_correct_sql_value := format(
                        'UPDATE %I SET %I = jsonb_set(%I::jsonb, ''{geometry}'', %L::jsonb, true)::text WHERE %I = %L;',
                        p_table_name, v_geo_column, v_geo_column, v_correct_geojson, v_id_column, rec.id
                    );
                END IF;

                EXECUTE format('
                    INSERT INTO %I(
                        table_name, row_id, column_name, geometry_type,
                        error_code, error_message, bad_json_value, error_data_json,
                        correct_geojson, correct_data_json, correct_sql_value, is_ring_closed,
                        bad_sql_value, check_batch
                    ) VALUES (%L, %L, %L, %L, %L, %L, %L, %L::jsonb, %L, %L::jsonb, %L, %L, %L, %L)',
                    v_backup_table,
                    p_table_name, rec.id::text, v_geo_column, ST_GeometryType(v_geom),
                    v_error_code, v_error, v_geo_text, v_row_json::text,
                    v_correct_geojson, v_correct_data_json::text, v_correct_sql_value, v_is_ring_closed, v_row_sql,
                    v_check_batch
                );
                v_error_count := v_error_count + 1;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- JSON 解析、GeoJSON 转 geometry、空间函数执行异常统一记录为解析失败。
            v_error_code := '空间数据解析失败';
            v_error := '空间数据解析失败：' || SQLERRM;
            EXECUTE format('
                INSERT INTO %I(
                    table_name, row_id, column_name, geometry_type,
                    error_code, error_message, bad_json_value, error_data_json,
                    correct_geojson, correct_data_json, correct_sql_value, is_ring_closed,
                    bad_sql_value, check_batch
                ) VALUES (%L, %L, %L, %L, %L, %L, %L, %L::jsonb, %L, %L::jsonb, %L, %L, %L, %L)',
                v_backup_table,
                p_table_name, rec.id::text, v_geo_column, p_geo_type,
                v_error_code, v_error, v_geo_text, v_row_json::text,
                v_correct_geojson, v_correct_data_json::text, v_correct_sql_value, v_is_ring_closed, v_row_sql,
                v_check_batch
            );
            v_error_count := v_error_count + 1;
        END;
    END LOOP;

    RETURN QUERY
    SELECT
        v_error_count,
        format(
            'SELECT * FROM %I WHERE check_batch = %L ORDER BY checked_at DESC',
            v_backup_table,
            v_check_batch
        )::text;
END;
$$;

SELECT * FROM gis_validate_table('bo_electric_fence', 'Geometry');
