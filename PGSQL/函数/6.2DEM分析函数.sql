-- =============================================================================
-- 6.2 DEM 分析函数
--
-- 函数清单：
--   gis_dem_stats_by_polygon          统计面范围内 DEM 高程分布
--   gis_dem_profile_by_line           沿线采样并返回 DEM 高程剖面
--   gis_dem_point_with_elevation      返回带 DEM Z 值的点或多点
--   gis_dem_line_with_elevation       返回带 DEM Z 值的线
--   gis_dem_polygon_with_elevation    返回带 DEM Z 值的面
--   gis_dem_geom_with_elevation       按几何类型统一补充 DEM 高程
--
-- 统一约定：
--   1. 本文件依赖 6.1DEM.sql 中的 gis_dem_value_at_point。
--   2. 输入 geometry 没有 SRID 时按 EPSG:4326 处理。
--   3. 输入 geometry 已有 Z 值时，按 XY 查询 DEM，并用 DEM 高程生成新的 Z 值。
--   4. 统计和剖面函数直接读取 public.gis_dem_henan。
-- =============================================================================



-- =============================================================================
-- 扩展依赖
-- 说明：启用 PostGIS 几何和 PostGIS Raster 能力。
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;


-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_dem_stats_by_polygon');

-- =============================================================================
-- 函数名称：gis_dem_stats_by_polygon
-- 函数功能：统计面范围内 DEM 高程分布
-- 入参说明：p_geom 支持 Polygon 或 MultiPolygon。
-- 返回说明：返回有效像元数量、最小值、最大值、平均值和标准差。
-- 注意事项：输入面会自动转换到 DEM SRID 后参与裁剪统计。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_stats_by_polygon(
    p_geom geometry
)
RETURNS TABLE (
    count bigint,
    min double precision,
    max double precision,
    mean double precision,
    stddev double precision
)
LANGUAGE sql
STABLE
AS $$
    WITH dem_srid AS (
        SELECT ST_SRID(rast) AS srid
        FROM public.gis_dem_henan
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    input_area AS (
        SELECT
            CASE
                WHEN p_geom IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_MakeValid(ST_Force2D(p_geom)), 4326)
                ELSE ST_MakeValid(ST_Force2D(p_geom))
            END AS geom
    ),
    area_dem AS (
        SELECT ST_Transform(a.geom, d.srid) AS geom
        FROM input_area a
        CROSS JOIN dem_srid d
        WHERE a.geom IS NOT NULL
          AND ST_GeometryType(a.geom) IN ('ST_Polygon', 'ST_MultiPolygon')
    ),
    clipped AS (
        SELECT ST_Clip(r.rast, 1, a.geom, true) AS rast
        FROM public.gis_dem_henan r
        CROSS JOIN area_dem a
        WHERE ST_Intersects(r.rast, a.geom)
    )
    SELECT
        (s).count::bigint,
        (s).min,
        (s).max,
        (s).mean,
        (s).stddev
    FROM (
        SELECT ST_SummaryStatsAgg(rast, 1, true) AS s
        FROM clipped
    ) q;
$$;

COMMENT ON FUNCTION public.gis_dem_stats_by_polygon(geometry) IS '统计面范围内DEM高程分布';


-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_dem_profile_by_line');

-- =============================================================================
-- 函数名称：gis_dem_profile_by_line
-- 函数功能：沿 LineString 按步长采样并查询 DEM 高程剖面
-- 入参说明：p_line 为 LineString；p_step 为采样步长，单位与输入线坐标单位一致。
-- 返回说明：返回采样序号、线内距离、采样点和高程值。
-- 注意事项：EPSG:4326 的单位是度；如需按米采样，应先转为米制投影坐标系。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_profile_by_line(
    p_line geometry,
    p_step double precision DEFAULT 0.001
)
RETURNS TABLE (
    seq integer,
    distance double precision,
    geom geometry(Point),
    elevation double precision
)
LANGUAGE sql
STABLE
AS $$
    WITH input_line AS (
        SELECT
            CASE
                WHEN p_line IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_line) = 0 THEN ST_SetSRID(ST_Force2D(p_line), 4326)
                ELSE ST_Force2D(p_line)
            END AS geom,
            GREATEST(p_step, 0.000001) AS step_len
    ),
    params AS (
        SELECT
            geom,
            step_len,
            ST_Length(geom) AS line_len
        FROM input_line
        WHERE geom IS NOT NULL
          AND ST_GeometryType(geom) = 'ST_LineString'
    ),
    samples AS (
        SELECT
            row_number() OVER (ORDER BY g.dist)::integer AS seq,
            LEAST(g.dist, p.line_len) AS distance,
            ST_LineInterpolatePoint(p.geom, LEAST(g.dist, p.line_len) / NULLIF(p.line_len, 0)) AS geom
        FROM params p
        CROSS JOIN LATERAL generate_series(0, p.line_len, p.step_len) AS g(dist)
        WHERE p.line_len > 0
    )
    SELECT
        s.seq,
        s.distance,
        s.geom,
        public.gis_dem_value_at_point(s.geom) AS elevation
    FROM samples s
    ORDER BY s.seq;
$$;

COMMENT ON FUNCTION public.gis_dem_profile_by_line(geometry, double precision) IS '沿线采样并返回DEM高程剖面';


-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_dem_point_with_elevation');

-- =============================================================================
-- 函数名称：gis_dem_point_with_elevation
-- 函数功能：给 Point 或 MultiPoint 补充 DEM 高程
-- 入参说明：p_point 支持 Point 或 MultiPoint，SRID 为空时按 4326 处理。
-- 返回说明：返回带 DEM Z 值的 PointZ 或 MultiPointZ。
-- 注意事项：点不在 DEM 覆盖范围内时 Z 值补 0。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_point_with_elevation(
    p_point geometry
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    WITH input_point AS (
        SELECT
            CASE
                WHEN p_point IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_point) = 0 THEN ST_SetSRID(ST_Force2D(p_point), 4326)
                ELSE ST_Force2D(p_point)
            END AS geom,
            COALESCE(NULLIF(ST_SRID(p_point), 0), 4326) AS srid
    ),
    points AS (
        SELECT
            row_number() OVER (ORDER BY (dp).path)::integer AS seq,
            (dp).geom AS geom
        FROM input_point i
        CROSS JOIN LATERAL ST_Dump(i.geom) AS dp
        WHERE i.geom IS NOT NULL
          AND ST_GeometryType(i.geom) IN ('ST_Point', 'ST_MultiPoint')
    ),
    z_points AS (
        SELECT
            seq,
            ST_MakePoint(
                ST_X(geom),
                ST_Y(geom),
                COALESCE(public.gis_dem_value_at_point(geom), 0)
            ) AS geom
        FROM points
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM z_points) THEN NULL::geometry
            WHEN ST_GeometryType((SELECT geom FROM input_point)) = 'ST_Point' THEN
                ST_SetSRID((SELECT geom FROM z_points ORDER BY seq LIMIT 1), (SELECT srid FROM input_point))
            ELSE
                ST_SetSRID(
                    (
                        SELECT ST_Multi(ST_Collect(geom ORDER BY seq))
                        FROM z_points
                    ),
                    (SELECT srid FROM input_point)
                )
        END
    FROM input_point;
$$;

COMMENT ON FUNCTION public.gis_dem_point_with_elevation(geometry) IS '返回带DEM高程Z值的点或多点';


-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_dem_line_with_elevation');

-- =============================================================================
-- 函数名称：gis_dem_line_with_elevation
-- 函数功能：给 LineString 每个顶点补充 DEM 高程
-- 入参说明：p_line 为 LineString，SRID 为空时按 4326 处理。
-- 返回说明：返回带 DEM Z 值的 LineStringZ。
-- 注意事项：MultiLineString 请通过 gis_dem_elevation 统一入口处理。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_line_with_elevation(
    p_line geometry
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    WITH input_line AS (
        SELECT
            CASE
                WHEN p_line IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_line) = 0 THEN ST_SetSRID(ST_Force2D(p_line), 4326)
                ELSE ST_Force2D(p_line)
            END AS geom,
            COALESCE(NULLIF(ST_SRID(p_line), 0), 4326) AS srid
    ),
    points AS (
        SELECT
            (dp).path[1] AS seq,
            (dp).geom AS geom
        FROM input_line i
        CROSS JOIN LATERAL ST_DumpPoints(i.geom) AS dp
        WHERE i.geom IS NOT NULL
          AND ST_GeometryType(i.geom) = 'ST_LineString'
    )
    SELECT
        CASE
            WHEN count(*) = 0 THEN NULL::geometry
            ELSE ST_SetSRID(
                ST_MakeLine(
                    ST_MakePoint(
                        ST_X(geom),
                        ST_Y(geom),
                        COALESCE(public.gis_dem_value_at_point(geom), 0)
                    )
                    ORDER BY seq
                ),
                (SELECT srid FROM input_line)
            )
        END
    FROM points;
$$;

COMMENT ON FUNCTION public.gis_dem_line_with_elevation(geometry) IS '返回带DEM高程Z值的线';


-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_dem_polygon_with_elevation');

-- =============================================================================
-- 函数名称：gis_dem_polygon_with_elevation
-- 函数功能：给 Polygon 外环和内环顶点补充 DEM 高程
-- 入参说明：p_polygon 为 Polygon，SRID 为空时按 4326 处理。
-- 返回说明：返回带 DEM Z 值的 PolygonZ。
-- 注意事项：MultiPolygon 请通过 gis_dem_elevation 统一入口处理。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_polygon_with_elevation(
    p_polygon geometry
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    WITH input_polygon AS (
        SELECT
            CASE
                WHEN p_polygon IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_polygon) = 0 THEN ST_SetSRID(ST_Force2D(p_polygon), 4326)
                ELSE ST_Force2D(p_polygon)
            END AS geom,
            COALESCE(NULLIF(ST_SRID(p_polygon), 0), 4326) AS srid
    ),
    rings AS (
        SELECT
            (dr).path[1] AS ring_no,
            (dr).geom AS geom
        FROM input_polygon i
        CROSS JOIN LATERAL ST_DumpRings(i.geom) AS dr
        WHERE i.geom IS NOT NULL
          AND ST_GeometryType(i.geom) = 'ST_Polygon'
    ),
    ring_points AS (
        SELECT
            r.ring_no,
            (dp).path[1] AS point_no,
            (dp).geom AS geom
        FROM rings r
        CROSS JOIN LATERAL ST_DumpPoints(r.geom) AS dp
    ),
    z_rings AS (
        SELECT
            ring_no,
            ST_MakeLine(
                ST_MakePoint(
                    ST_X(geom),
                    ST_Y(geom),
                    COALESCE(public.gis_dem_value_at_point(geom), 0)
                )
                ORDER BY point_no
            ) AS geom
        FROM ring_points
        GROUP BY ring_no
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM z_rings WHERE ring_no = 0) THEN NULL::geometry
            ELSE ST_SetSRID(
                ST_MakePolygon(
                    (SELECT geom FROM z_rings WHERE ring_no = 0),
                    COALESCE(
                        ARRAY(SELECT geom FROM z_rings WHERE ring_no > 0 ORDER BY ring_no),
                        ARRAY[]::geometry[]
                    )
                ),
                (SELECT srid FROM input_polygon)
            )
        END;
$$;

COMMENT ON FUNCTION public.gis_dem_polygon_with_elevation(geometry) IS '返回带DEM高程Z值的面';


-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_dem_geom_with_elevation');

-- =============================================================================
-- 函数名称：gis_dem_geom_with_elevation
-- 函数功能：按几何类型统一补充 DEM 高程
-- 入参说明：p_geom 支持 Point、MultiPoint、LineString、MultiLineString、Polygon、MultiPolygon、GeometryCollection。
-- 返回说明：返回与输入类型对应的带 Z 几何；不支持的子类型会被忽略。
-- 注意事项：这是 gis_dem_elevation 的实际分发实现。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_geom_with_elevation(
    p_geom geometry
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    WITH input_geom AS (
        SELECT
            CASE
                WHEN p_geom IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_Force2D(p_geom), 4326)
                ELSE ST_Force2D(p_geom)
            END AS geom,
            COALESCE(NULLIF(ST_SRID(p_geom), 0), 4326) AS srid
    ),
    parts AS (
        SELECT
            (d).path AS path,
            (d).geom AS geom
        FROM input_geom i
        CROSS JOIN LATERAL ST_Dump(i.geom) AS d
        WHERE i.geom IS NOT NULL
    ),
    z_parts AS (
        SELECT
            path,
            CASE ST_GeometryType(geom)
                WHEN 'ST_Point' THEN public.gis_dem_point_with_elevation(geom)
                WHEN 'ST_LineString' THEN public.gis_dem_line_with_elevation(geom)
                WHEN 'ST_Polygon' THEN public.gis_dem_polygon_with_elevation(geom)
                ELSE NULL::geometry
            END AS geom
        FROM parts
    )
    SELECT
        CASE
            WHEN (SELECT geom FROM input_geom) IS NULL THEN NULL::geometry
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) IN ('ST_Point', 'ST_MultiPoint') THEN
                public.gis_dem_point_with_elevation((SELECT geom FROM input_geom))
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_LineString' THEN
                public.gis_dem_line_with_elevation((SELECT geom FROM input_geom))
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_Polygon' THEN
                public.gis_dem_polygon_with_elevation((SELECT geom FROM input_geom))
            WHEN NOT EXISTS (SELECT 1 FROM z_parts WHERE geom IS NOT NULL) THEN NULL::geometry
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_GeometryCollection' THEN
                ST_SetSRID(
                    (
                        SELECT ST_Collect(geom ORDER BY path)
                        FROM z_parts
                        WHERE geom IS NOT NULL
                    ),
                    (SELECT srid FROM input_geom)
                )
            ELSE
                ST_SetSRID(
                    ST_CollectionExtract(
                        ST_Collect(geom ORDER BY path),
                        CASE
                            WHEN ST_GeometryType((SELECT geom FROM input_geom)) IN ('ST_LineString', 'ST_MultiLineString') THEN 2
                            WHEN ST_GeometryType((SELECT geom FROM input_geom)) IN ('ST_Polygon', 'ST_MultiPolygon') THEN 3
                            ELSE 0
                        END
                    ),
                    (SELECT srid FROM input_geom)
                )
        END
    FROM input_geom;
$$;

COMMENT ON FUNCTION public.gis_dem_geom_with_elevation(geometry) IS '按几何类型统一补充DEM高程';
