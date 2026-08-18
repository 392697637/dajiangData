-- =============================================================================
-- 0 基础公共函数
--
-- 函数清单：
--   gis_geojson_to_geom    解析 GeoJSON 为空间 geometry，支持面环自动闭合
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
    IF p_geojson IS NULL OR btrim(p_geojson) = '' THEN
        RETURN NULL;
    END IF;

    v_json := p_geojson::jsonb;

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

    IF v_geom_json IS NULL THEN
        RETURN NULL;
    END IF;

    v_geom_type := v_geom_json ->> 'type';

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

    RETURN ST_GeomFromGeoJSON(v_geom_json::text);
END;
$$;

COMMENT ON FUNCTION public.gis_geojson_to_geom(text) IS '解析 GeoJSON 为空间 geometry，支持 Feature/FeatureCollection，并自动闭合 Polygon/MultiPolygon 面环';
