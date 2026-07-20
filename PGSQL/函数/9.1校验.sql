-- =============================================================================
-- 9.1校验.sql
--   gis_check_point_in_polygon              判断点是否在面内/立体围栏内
--
-- =============================================================================

-- =============================================
-- 函数名称gis_check_point_in_polygon
-- 函数功能点是否位于面内/立体围栏内校验
-- 函数描述1. 接收面文本和点数组两个参数
--            2. 面支持 WKT、POLYGON Z、MULTIPOLYGON、GeoJSON Geometry、GeoJSON Feature
--            3. 点支持单点数组 [lng,lat,alt] 和多点数组 [[lng,lat,alt],...]
--            4. 使用 ST_Covers 做平面判断，点落在面边界上按命中处理
--            5. 面参数携带 height、min_alt/max_alt 或坐标 Z 时，自动追加高度范围判断
--            6. 面参数没有有效高度时，自动退回平面点面判断
-- 函数说明依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)
-- 参数说明
--   p_polygon_text  text        面文本，支持 WKT/GeoJSON Geometry/GeoJSON Feature
--   p_point_array   text        点数组JSON字符串，支持 [lng,lat,alt] 或 [[lng,lat,alt],...]
-- 返回值：标准TABLE结构
--   code            integer     返回码：200成功，400参数错误，500服务异常
--   msg             varchar     返回提示信息，包含执行时间和命中说明
--   ischeck         boolean     是否命中管控区/立体围栏
--   check_type      varchar     p_inner/p_inner_3d/p_outer/p_outer_height/invalid_param/error
--   point_geom      geometry    解析后的点几何，SRID=4326
--   polygon_geom    geometry    解析后的面几何，SRID=4326
--   point_geom_json json        点GeoJSON
--   polygon_geom_json json      面GeoJSON
-- 适用场景单点或批量点位是否进入管控区、电子围栏平面范围或高度范围校验
-- 注意事项
--   1. 坐标顺序必须为 [经度,纬度,高度]，不能写成 [纬度,经度,高度]
--   2. height 表示高度范围 0 到 height；min_alt/max_alt 表示自定义高度范围
--   3. 多点输入时，单个点参数非法只影响该点返回结果，不中断其他点校验
-- =============================================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_check_point_in_polygon');

-- =============================================================================
-- 函数介绍：gis_check_point_in_polygon
-- 主要作用：判断一个或多个点是否落入给定面或立体高度范围。
-- 入参说明：p_polygon_text 为面WKT/GeoJSON文本；p_point_array 为单点或多点坐标数组JSON。
-- 返回说明：返回每个点的命中状态、判断类型、点几何和面几何，供临时校验或接口联调用。
-- 注意事项：有有效高度时做平面+高度判断；无有效高度时只做平面判断。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_check_point_in_polygon(
    p_polygon_text text,
    p_point_array text
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    point_geom geometry,
    polygon_geom geometry,
    point_geom_json json,
    polygon_geom_json json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_polygon geometry;
    v_polygon_json jsonb;
    v_point_json jsonb;
    v_min_z double precision;
    v_max_z double precision;
    v_geom_min_z double precision;
    v_geom_max_z double precision;
    v_has_height boolean := false;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    -- 先校验面参数，支持 WKT 或 GeoJSON。
    IF p_polygon_text IS NULL OR btrim(p_polygon_text) = '' THEN
        RETURN QUERY SELECT
            400,
            format('面参数不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false,
            'invalid_param'::varchar,
            NULL::geometry,
            NULL::geometry,
            NULL::json,
            NULL::json;
        RETURN;
    END IF;

    -- 校验点参数，必须是 JSON 文本。
    IF p_point_array IS NULL OR btrim(p_point_array) = '' THEN
        RETURN QUERY SELECT
            400,
            format('点数组不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false,
            'invalid_param'::varchar,
            NULL::geometry,
            NULL::geometry,
            NULL::json,
            NULL::json;
        RETURN;
    END IF;

    -- 解析面参数：以 "{" 开头按 GeoJSON 处理，否则按 WKT 处理。
    BEGIN
        IF left(btrim(p_polygon_text), 1) = '{' THEN
            v_polygon_json := p_polygon_text::jsonb;

            IF v_polygon_json ->> 'type' = 'Feature' THEN
                v_polygon := ST_SetSRID(ST_GeomFromGeoJSON((v_polygon_json -> 'geometry')::text), 4326);
                v_min_z := COALESCE(
                    (v_polygon_json -> 'properties' ->> 'min_alt')::double precision,
                    (v_polygon_json -> 'properties' ->> 'min_height')::double precision,
                    0
                );
                v_max_z := COALESCE(
                    (v_polygon_json -> 'properties' ->> 'max_alt')::double precision,
                    (v_polygon_json -> 'properties' ->> 'max_height')::double precision,
                    (v_polygon_json -> 'properties' ->> 'height')::double precision
                );
            ELSE
                v_polygon := ST_SetSRID(ST_GeomFromGeoJSON(p_polygon_text), 4326);
                v_min_z := COALESCE(
                    (v_polygon_json ->> 'min_alt')::double precision,
                    (v_polygon_json ->> 'min_height')::double precision,
                    0
                );
                v_max_z := COALESCE(
                    (v_polygon_json ->> 'max_alt')::double precision,
                    (v_polygon_json ->> 'max_height')::double precision,
                    (v_polygon_json ->> 'height')::double precision
                );
            END IF;
        ELSE
            v_polygon := ST_SetSRID(ST_GeomFromText(p_polygon_text), 4326);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                format('面参数解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
                false,
                'invalid_param'::varchar,
                NULL::geometry,
                NULL::geometry,
                NULL::json,
                NULL::json;
            RETURN;
    END;

    -- 点面校验只允许 Polygon/MultiPolygon 面几何。
    IF ST_GeometryType(v_polygon) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        RETURN QUERY SELECT
            400,
            format('面参数必须是Polygon或MultiPolygon，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false,
            'invalid_param'::varchar,
            NULL::geometry,
            v_polygon,
            NULL::json,
            ST_AsGeoJSON(v_polygon)::json;
        RETURN;
    END IF;

    -- 从面坐标 Z 值中读取高度范围；如果 properties 已提供高度，则优先使用 properties。
    SELECT
        MIN(ST_Z((dp).geom)),
        MAX(ST_Z((dp).geom))
    INTO v_geom_min_z, v_geom_max_z
    FROM ST_DumpPoints(v_polygon) AS dp
    WHERE ST_Z((dp).geom) IS NOT NULL;

    v_min_z := COALESCE(v_min_z, v_geom_min_z, 0);
    v_max_z := COALESCE(v_max_z, v_geom_max_z, 0);
    v_has_height := COALESCE(v_max_z, 0) > 0;

    -- 面参数合法后再解析点数组 JSON。
    BEGIN
        v_point_json := p_point_array::jsonb;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                format('点数组解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
                false,
                'invalid_param'::varchar,
                NULL::geometry,
                v_polygon,
                NULL::json,
                ST_AsGeoJSON(v_polygon)::json;
            RETURN;
    END;

    -- 顶层必须是单点坐标数组，或多点坐标数组。
    IF jsonb_typeof(v_point_json) <> 'array' OR jsonb_array_length(v_point_json) = 0 THEN
        RETURN QUERY SELECT
            400,
            format('点数组必须是 [lng,lat,alt] 或 [[lng,lat,alt],...]，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false,
            'invalid_param'::varchar,
            NULL::geometry,
            v_polygon,
            NULL::json,
            ST_AsGeoJSON(v_polygon)::json;
        RETURN;
    END IF;

    RETURN QUERY
    WITH point_items AS (
        -- 单点输入：[lng, lat, alt]。
        SELECT
            1 AS item_index,
            v_point_json AS point_item
        WHERE jsonb_typeof(v_point_json -> 0) <> 'array'

        UNION ALL

        -- 多点输入：[[lng, lat, alt], ...]。
        SELECT
            p.ord::integer AS item_index,
            p.value AS point_item
        FROM jsonb_array_elements(v_point_json) WITH ORDINALITY AS p(value, ord)
        WHERE jsonb_typeof(v_point_json -> 0) = 'array'
    ),
    parsed_points AS (
        -- 将每个合法坐标数组转换为 SRID=4326 的 Point 几何。
        SELECT
            item_index,
            CASE
                WHEN jsonb_typeof(point_item) = 'array'
                 AND jsonb_array_length(point_item) >= 2
                THEN ST_SetSRID(ST_MakePoint(
                    (point_item ->> 0)::double precision,
                    (point_item ->> 1)::double precision,
                    COALESCE((point_item ->> 2)::double precision, 0)
                ), 4326)
                ELSE NULL::geometry
            END AS item_geom
        FROM point_items
    ),
    checked_points AS (
        -- 面有高度时，同时判断平面命中和高度范围；面无高度时，只判断平面命中。
        SELECT
            item_index,
            item_geom,
            CASE
                WHEN item_geom IS NULL THEN false
                WHEN NOT ST_Covers(ST_Force2D(v_polygon), ST_Force2D(item_geom)) THEN false
                WHEN NOT v_has_height THEN true
                WHEN v_max_z > v_min_z THEN COALESCE(ST_Z(item_geom), 0) BETWEEN v_min_z AND v_max_z
                ELSE COALESCE(ST_Z(item_geom), 0) BETWEEN 0 AND v_max_z
            END AS is_inside,
            CASE
                WHEN item_geom IS NULL THEN false
                ELSE ST_Covers(ST_Force2D(v_polygon), ST_Force2D(item_geom))
            END AS is_horizontal_inside,
            CASE
                WHEN item_geom IS NULL THEN false
                WHEN NOT v_has_height THEN true
                WHEN v_max_z > v_min_z THEN COALESCE(ST_Z(item_geom), 0) BETWEEN v_min_z AND v_max_z
                ELSE COALESCE(ST_Z(item_geom), 0) BETWEEN 0 AND v_max_z
            END AS is_height_inside
        FROM parsed_points
    )
    SELECT
        CASE WHEN item_geom IS NULL THEN 400 ELSE 200 END AS code,
        CASE
            WHEN item_geom IS NULL THEN format('点坐标项非法，check_type=invalid_param，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
            WHEN is_inside AND v_has_height THEN format('点在面内或边界上，且高度在范围内，check_type=p_inner_3d，高度范围[%s,%s]，执行时间 %s 秒',
                v_min_z, v_max_z, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
            WHEN is_inside THEN format('点在面内或边界上，check_type=p_inner，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
            WHEN v_has_height AND is_horizontal_inside AND NOT is_height_inside THEN format('点平面位置在面内或边界上，但高度超出范围，check_type=p_outer_height，高度范围[%s,%s]，执行时间 %s 秒',
                v_min_z, v_max_z, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
            ELSE format('点在面外，check_type=p_outer，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
        END::varchar AS msg,
        is_inside AS ischeck,
        CASE
            WHEN item_geom IS NULL THEN 'invalid_param'
            WHEN is_inside AND v_has_height THEN 'p_inner_3d'
            WHEN is_inside THEN 'p_inner'
            WHEN v_has_height AND is_horizontal_inside AND NOT is_height_inside THEN 'p_outer_height'
            ELSE 'p_outer'
        END::varchar AS check_type,
        item_geom AS point_geom,
        v_polygon AS polygon_geom,
        CASE WHEN item_geom IS NULL THEN NULL::json ELSE ST_AsGeoJSON(item_geom)::json END AS point_geom_json,
        ST_AsGeoJSON(v_polygon)::json AS polygon_geom_json
    FROM checked_points
    ORDER BY item_index;

EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500,
            format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false,
            'error'::varchar,
            NULL::geometry,
            NULL::geometry,
            NULL::json,
            NULL::json;
END;
$$;

COMMENT ON FUNCTION public.gis_check_point_in_polygon(text, text)
IS '判断一个或多个 [经度,纬度,高度] 点是否位于 Polygon/MultiPolygon 面内、边界上或立体高度范围内。';

-- =============================================================================
-- 调用示例
-- =============================================================================

-- 示例1：WKT/POLYGON Z + 单点数组 [lng,lat,alt]
-- 说明：面坐标 Z 全为 0，无有效高度，按平面规则判断。
SELECT *
FROM public.gis_check_point_in_polygon(
    'POLYGON Z((113.468131 34.825104 0, 113.468176 34.819035 0, 113.472381 34.819072 0, 113.476475 34.819975 0, 113.476476 34.825196 0, 113.468131 34.825104 0))',
    '[113.479352, 34.825104, 10]'
);

-- 示例2：GeoJSON Feature height + 多点数组 [[lng,lat,alt],...]
-- 说明：
--   1. properties.height=120，高度范围为 0 <= alt <= 120。
--   2. 第1个点高度10，若平面在面内则返回 p_inner_3d。
--   3. 第2个点高度130，若平面在面内则返回 p_outer_height。
--   4. 第3个点平面位置在面外则返回 p_outer。
SELECT *
FROM public.gis_check_point_in_polygon(
    '{
        "type": "Feature",
        "properties": {
            "height": 120
        },
        "geometry": {
            "type": "Polygon",
            "coordinates": [[
                [113.4791, 34.814719, 0.0],
                [113.480661, 34.814727, 0.0],
                [113.480603, 34.813656, 0.0],
                [113.479188, 34.813671, 0.0],
                [113.4791, 34.814719, 0.0]
            ]]
        }
    }',
    '[
        [113.479352, 34.814000, 10],
        [113.479352, 34.814000, 130],
        [113.479352, 34.825104, 10]
    ]'
);
