-- =============================================================================
-- 文件：baseFunction/gis_geojson_to_geom.sql
-- 函数：public.gis_geojson_to_geom(p_geojson text)
-- 功能：解析 GeoJSON 为 PostGIS geometry，支持 Geometry、Feature、FeatureCollection。
-- 依赖：public.gis_drop_function(text)，执行本文件前请先执行 baseFunction/gis_drop_function.sql。
-- 入参：p_geojson，GeoJSON 文本；空文本、无有效 geometry 或坏面环返回 NULL。
-- 返回：geometry。
-- 规则：Feature 自动读取 geometry；多个 Polygon FeatureCollection 合并为 MultiPolygon；混合类型返回 GeometryCollection；面环未闭合时自动补首点。
-- 示例：SELECT public.gis_geojson_to_geom('{"type":"Point","coordinates":[113.65,34.76]}');
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_geojson_to_geom');

-- =============================================================================
-- 函数名称：gis_geojson_to_geom
-- 函数功能：解析 GeoJSON 为空间 geometry
-- 入参说明：
--   1. p_geojson 支持 GeoJSON Geometry、Feature、FeatureCollection。
-- 返回说明：返回 PostGIS geometry；空文本、无有效 geometry 或坏面环返回 NULL。
-- 处理规则：
--   1. Feature 自动读取 geometry 节点。
--   2. FeatureCollection 只有 1 个有效 geometry 时返回该 geometry。
--   3. FeatureCollection 有多个 Polygon 时合并为 MultiPolygon。
--   4. FeatureCollection 有多个混合 geometry 时返回 GeometryCollection。
--   5. Polygon/MultiPolygon 未闭合 ring 自动追加首点；少于 3 个点的坏 ring 返回 NULL。
-- 逻辑步骤：
--   1. 清理并校验输入文本，空文本直接返回 NULL。
--   2. 将文本转换为 jsonb，并识别 Geometry、Feature 或 FeatureCollection。
--   3. 提取真正的 geometry JSON；多个 Polygon Feature 合并为 MultiPolygon。
--   4. 对 Polygon/MultiPolygon 检查坐标层级和 ring 点数。
--   5. 对未闭合 ring 追加首点，生成闭合后的 GeoJSON。
--   6. 调用 ST_GeomFromGeoJSON 转换为 PostGIS geometry。
-- =============================================================================
-- 使用示例：
--   SELECT ST_AsEWKT(public.gis_geojson_to_geom('{"type":"Point","coordinates":[113.65,34.76]}'));
--   SELECT ST_AsEWKT(public.gis_geojson_to_geom('{"type":"Polygon","coordinates":[[[113.60,34.70],[113.70,34.70],[113.70,34.80],[113.60,34.80]]]}'));
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_geojson_to_geom(
    p_geojson text
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_json jsonb;
    v_geom_json jsonb;
    v_geom_type text;
    v_features jsonb;
    v_feature_count integer;
    v_bad_ring_count integer;
BEGIN
    -- 步骤 1：清理并校验输入文本，空文本直接返回 NULL。
    IF p_geojson IS NULL OR btrim(p_geojson) = '' THEN
        RETURN NULL;
    END IF;

    -- 步骤 2：将 GeoJSON 文本转换为 jsonb，非法 JSON 会由 PostgreSQL 抛出异常。
    v_json := p_geojson::jsonb;

    -- 步骤 3：按 Geometry / Feature / FeatureCollection 三种输入形式提取 geometry JSON。
    IF v_json ->> 'type' = 'FeatureCollection' THEN
        v_features := CASE
            WHEN jsonb_typeof(v_json -> 'features') = 'array' THEN v_json -> 'features'
            ELSE '[]'::jsonb
        END;

        -- 步骤 3.1：统计 FeatureCollection 中有效 geometry 数量。
        SELECT count(*)
        INTO v_feature_count
        FROM jsonb_array_elements(v_features) AS f(feature)
        WHERE jsonb_typeof(f.feature -> 'geometry') = 'object';

        IF v_feature_count = 0 THEN
            RETURN NULL;
        END IF;

        -- 步骤 3.2：单个有效 geometry 直接取出，多个 geometry 按类型合并或收集。
        IF v_feature_count = 1 THEN
            SELECT f.feature -> 'geometry'
            INTO v_geom_json
            FROM jsonb_array_elements(v_features) AS f(feature)
            WHERE jsonb_typeof(f.feature -> 'geometry') = 'object'
            LIMIT 1;
        ELSE
            SELECT CASE
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

    -- 步骤 4：没有提取到 geometry 时返回 NULL。
    IF v_geom_json IS NULL THEN
        RETURN NULL;
    END IF;

    -- 步骤 5：读取 geometry 类型，只有面类型需要额外闭合处理。
    v_geom_type := v_geom_json ->> 'type';

    -- 步骤 6：Polygon 校验坐标结构、坏 ring，并自动补闭合点。
    IF v_geom_type = 'Polygon' THEN
        IF jsonb_typeof(v_geom_json -> 'coordinates') IS DISTINCT FROM 'array' THEN
            RETURN NULL;
        END IF;

        IF jsonb_array_length(v_geom_json -> 'coordinates') = 0 THEN
            RETURN NULL;
        END IF;

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

    -- 步骤 7：MultiPolygon 逐 polygon、逐 ring 校验并自动补闭合点。
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

    -- 步骤 8：将最终 GeoJSON 交给 PostGIS 转为 geometry。
    RETURN ST_GeomFromGeoJSON(v_geom_json::text);
END;
$$;

COMMENT ON FUNCTION public.gis_geojson_to_geom(text) IS '解析 GeoJSON 为空间 geometry，支持 Feature/FeatureCollection，修补Polygon数据。';
-- =============================================================================
-- 调用示例
-- =============================================================================

-- 1. Point Geometry
-- SELECT ST_AsEWKT(public.gis_geojson_to_geom(
--     '{"type":"Point","coordinates":[113.65,34.76]}'
-- ));

-- 2. LineString Geometry
-- SELECT ST_AsEWKT(public.gis_geojson_to_geom(
--     '{"type":"LineString","coordinates":[[113.60,34.70],[113.70,34.80]]}'
-- ));

-- 3. Polygon Geometry，未闭合 ring 会自动追加首点
-- SELECT ST_AsEWKT(public.gis_geojson_to_geom(
--     '{"type":"Polygon","coordinates":[[[113.60,34.70],[113.70,34.70],[113.70,34.80],[113.60,34.80]]]}'
-- ));

-- 4. Feature，自动读取 geometry 节点
-- SELECT ST_AsEWKT(public.gis_geojson_to_geom(
--     '{"type":"Feature","properties":{"name":"test"},"geometry":{"type":"Point","coordinates":[113.65,34.76]}}'
-- ));

-- 5. FeatureCollection，多个 Polygon 会合并为 MultiPolygon
-- SELECT ST_AsEWKT(public.gis_geojson_to_geom(
--     '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[113.60,34.70],[113.61,34.70],[113.61,34.71],[113.60,34.70]]]}},{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[113.70,34.80],[113.71,34.80],[113.71,34.81],[113.70,34.80]]]}}]}'
-- ));

-- 6. 空文本返回 NULL
-- SELECT public.gis_geojson_to_geom('');
