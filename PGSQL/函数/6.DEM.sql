-- =============================================================================
-- 6.DEM.sql
--   gis_dem_validate                 校验河南 DEM 表入库状态
--   gis_dem_elevation                按经纬度查询 DEM 高程
--   gis_dem_elevation_by_point       按 Point 几何查询 DEM 高程
--   gis_dem_stats_by_polygon         按面统计 DEM 高程
--   gis_dem_profile_by_line          按线生成 DEM 高程剖面
--   gis_dem_point_with_elevation     点补充 DEM 高程，返回 PointZ
--   gis_dem_line_with_elevation      线补充 DEM 高程，返回 LineStringZ
--   gis_dem_polygon_with_elevation   面补充 DEM 高程，返回 PolygonZ
--   gis_dem_geom_with_elevation      点线面通用补充 DEM 高程
--
-- 统一约定：
--   1. DEM 正式表为 public.gis_dem_henan。
--   2. DEM 正式坐标系为 EPSG:4326。
--   3. DEM 表由 raster2pgsql 导入生成，本文件不负责导入 tif。
--   4. 电子围栏、航点、航线、业务面默认使用 EPSG:4326。
-- =============================================================================


-- =============================================================================
-- 1. 扩展依赖与 DEM 表注释
-- =============================================================================
-- 作用说明：启用 PostGIS Raster 能力，并给 DEM 表和核心字段补充数据库注释。
-- 表说明：public.gis_dem_henan 为河南 DEM 栅格主表，每条记录通常是一块栅格瓦片。
-- 字段说明：
--   rid       瓦片主键，raster2pgsql 自动生成。
--   rast      DEM 栅格数据，PostGIS raster 类型。
--   filename  可选字段，导入时使用 raster2pgsql -F 才会生成。
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

DO $$
BEGIN
    IF to_regclass('public.gis_dem_henan') IS NULL THEN
        RETURN;
    END IF;

    COMMENT ON TABLE public.gis_dem_henan IS 'DEM栅格表';
    COMMENT ON COLUMN public.gis_dem_henan.rid IS '瓦片主键';
    COMMENT ON COLUMN public.gis_dem_henan.rast IS '栅格数据';

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gis_dem_henan'
          AND column_name = 'filename'
    ) THEN
        COMMENT ON COLUMN public.gis_dem_henan.filename IS '文件名';
    END IF;
END;
$$;


-- =============================================================================
-- 2. 删除函数
-- =============================================================================
-- 作用说明：按项目统一工具删除同名重载函数，避免 CREATE OR REPLACE 时参数变化导致冲突。
-- 注意事项：gis_drop_function 由建库脚本提供，内部使用 CASCADE 删除依赖函数。
-- =============================================================================
SELECT gis_drop_function('gis_dem_geom_with_elevation');
SELECT gis_drop_function('gis_dem_polygon_with_elevation');
SELECT gis_drop_function('gis_dem_line_with_elevation');
SELECT gis_drop_function('gis_dem_point_with_elevation');
SELECT gis_drop_function('gis_dem_profile_by_line');
SELECT gis_drop_function('gis_dem_stats_by_polygon');
SELECT gis_drop_function('gis_dem_elevation_by_point');
SELECT gis_drop_function('gis_dem_elevation');
SELECT gis_drop_function('gis_dem_henan_validate');
SELECT gis_drop_function('gis_dem_validate');


-- =============================================================================
-- 函数名称：gis_dem_validate
-- 函数功能：校验河南 DEM 表是否可用
-- 函数描述：
--   1. 检查 public.gis_dem_henan 是否存在。
--   2. 读取 DEM 实际 SRID、瓦片数量和栅格范围。
--   3. 判断 DEM 是否为 EPSG:4326。
--   4. 判断 DEM 范围是否落在河南经纬度附近。
--   5. 如果存在 public.bo_electric_fence.geom，统计电子围栏与 DEM 范围相交数量。
-- 参数说明：
--   p_old_srid  integer  兼容旧调用，正式固定使用 4326
--   p_new_srid  integer  兼容旧调用，正式固定使用 4326
-- 返回值：
--   code              integer  200=通过，400=失败
--   msg               text     校验说明
--   dem_exists        boolean  DEM 表是否存在
--   dem_srid          integer  DEM 栅格实际 SRID
--   tile_count        bigint   DEM 瓦片数量
--   extent_4326       text     DEM 范围，EPSG:4326 WKT
--   in_henan_range    boolean  是否在河南附近
--   fence_total       bigint   电子围栏总数
--   fence_intersects  bigint   与 DEM 范围相交的电子围栏数量
-- 适用场景：DEM 导入完成后，先执行该函数确认 SRID 和范围是否正确。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_validate(
    p_old_srid integer DEFAULT 4326,
    p_new_srid integer DEFAULT 4326
)
RETURNS TABLE (
    code integer,
    msg text,
    dem_exists boolean,
    dem_srid integer,
    tile_count bigint,
    extent_4326 text,
    in_henan_range boolean,
    fence_total bigint,
    fence_intersects bigint
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_srid integer;
    v_tile_count bigint;
    v_extent geometry;
    v_extent_4326 geometry;
    v_has_fence_geom boolean;
BEGIN
    IF to_regclass('public.gis_dem_henan') IS NULL THEN
        RETURN QUERY SELECT
            400,
            'DEM表不存在'::text,
            false,
            NULL::integer,
            0::bigint,
            NULL::text,
            false,
            NULL::bigint,
            NULL::bigint;
        RETURN;
    END IF;

    SELECT
        ST_SRID(rast),
        count(*),
        ST_SetSRID(ST_Envelope(ST_Collect(ST_ConvexHull(rast))), ST_SRID(rast))
    INTO v_dem_srid, v_tile_count, v_extent
    FROM public.gis_dem_henan
    WHERE rast IS NOT NULL
    GROUP BY ST_SRID(rast)
    ORDER BY count(*) DESC
    LIMIT 1;

    IF v_tile_count IS NULL OR v_tile_count = 0 THEN
        RETURN QUERY SELECT
            400,
            'DEM表无有效栅格'::text,
            true,
            v_dem_srid,
            0::bigint,
            NULL::text,
            false,
            NULL::bigint,
            NULL::bigint;
        RETURN;
    END IF;

    v_extent_4326 := ST_Transform(v_extent, 4326);
    in_henan_range :=
        ST_XMin(v_extent_4326) >= 108
        AND ST_XMax(v_extent_4326) <= 118
        AND ST_YMin(v_extent_4326) >= 30
        AND ST_YMax(v_extent_4326) <= 38;

    fence_total := NULL;
    fence_intersects := NULL;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'bo_electric_fence'
          AND column_name = 'geom'
    )
    INTO v_has_fence_geom;

    IF v_has_fence_geom THEN
        SELECT count(*)
        INTO fence_total
        FROM public.bo_electric_fence
        WHERE geom IS NOT NULL;

        SELECT count(*)
        INTO fence_intersects
        FROM public.bo_electric_fence
        WHERE geom IS NOT NULL
          AND ST_Intersects(
              ST_Transform(
                  CASE
                      WHEN ST_SRID(geom) = 0 THEN ST_SetSRID(geom, 4326)
                      ELSE geom
                  END,
                  4326
              ),
              v_extent_4326
          );
    END IF;

    RETURN QUERY SELECT
        CASE
            WHEN v_dem_srid <> 4326 THEN 400
            WHEN NOT in_henan_range THEN 400
            ELSE 200
        END,
        CASE
            WHEN v_dem_srid <> 4326 THEN format('DEM SRID不是4326，当前为%s', v_dem_srid)
            WHEN NOT in_henan_range THEN 'DEM范围不在河南附近'
            ELSE 'DEM校验通过'
        END,
        true,
        v_dem_srid,
        v_tile_count,
        ST_AsText(v_extent_4326),
        in_henan_range,
        fence_total,
        fence_intersects;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_validate(integer, integer)
IS '河南DEM校验';


-- =============================================================================
-- 函数名称：gis_dem_elevation
-- 函数功能：按经纬度查询 DEM 高程
-- 函数描述：
--   1. 接收 lon、lat 两个经纬度参数。
--   2. 默认输入坐标系为 EPSG:4326。
--   3. 自动查询 public.gis_dem_henan.rast 第一波段高程值。
-- 参数说明：
--   p_lon   double precision  经度
--   p_lat   double precision  纬度
--   p_srid  integer           输入点 SRID，正式默认 4326
-- 返回值：double precision，高程值；点不在 DEM 范围内时返回 NULL。
-- 适用场景：按航点、设备点、地图点击点查询地面高程。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_elevation(
    p_lon double precision,
    p_lat double precision,
    p_srid integer DEFAULT 4326
)
RETURNS double precision
LANGUAGE sql
STABLE
AS $$
    SELECT public.gis_dem_elevation_by_point(
        ST_SetSRID(ST_MakePoint(p_lon, p_lat), p_srid)
    );
$$;

COMMENT ON FUNCTION public.gis_dem_elevation(double precision, double precision, integer)
IS '经纬度查高程';


-- =============================================================================
-- 函数名称：gis_dem_elevation_by_point
-- 函数功能：按 Point 几何查询 DEM 高程
-- 函数描述：
--   1. 接收 geometry(Point)。
--   2. 输入无 SRID 时按 EPSG:4326 处理。
--   3. 输入 SRID 与 DEM 不一致时自动转换到 DEM SRID。
-- 参数说明：
--   p_geom  geometry  点几何
-- 返回值：double precision，高程值；点不在 DEM 范围内时返回 NULL。
-- 适用场景：业务表中已有 geom 字段时直接查询高程。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_elevation_by_point(
    p_geom geometry
)
RETURNS double precision
LANGUAGE sql
STABLE
AS $$
    WITH dem_srid AS (
        SELECT ST_SRID(rast) AS srid
        FROM public.gis_dem_henan
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    input_point AS (
        SELECT
            CASE
                WHEN p_geom IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_Force2D(p_geom), 4326)
                ELSE ST_Force2D(p_geom)
            END AS geom
    ),
    point_dem AS (
        SELECT ST_Transform(i.geom, d.srid) AS geom
        FROM input_point i
        CROSS JOIN dem_srid d
        WHERE i.geom IS NOT NULL
          AND ST_GeometryType(i.geom) = 'ST_Point'
    )
    SELECT ST_Value(r.rast, 1, p.geom)
    FROM public.gis_dem_henan r
    CROSS JOIN point_dem p
    WHERE ST_Intersects(r.rast, p.geom)
    ORDER BY r.rid
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_by_point(geometry)
IS '点几何查高程';


-- =============================================================================
-- 函数名称：gis_dem_stats_by_polygon
-- 函数功能：按面范围统计 DEM 高程
-- 函数描述：
--   1. 接收 Polygon 或 MultiPolygon。
--   2. 自动转换到 DEM SRID。
--   3. 裁剪 DEM 后统计第一波段 count、min、max、mean、stddev。
-- 参数说明：
--   p_geom  geometry  面几何
-- 返回值：TABLE，高程统计结果。
-- 适用场景：统计电子围栏、任务区、测区范围内的高程分布。
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

COMMENT ON FUNCTION public.gis_dem_stats_by_polygon(geometry)
IS '面统计高程';


-- =============================================================================
-- 函数名称：gis_dem_profile_by_line
-- 函数功能：按线生成 DEM 高程剖面
-- 函数描述：
--   1. 接收 LineString。
--   2. 按 p_step 间距在线上采样。
--   3. 返回采样序号、线内距离、采样点和高程。
-- 参数说明：
--   p_line  geometry          线几何
--   p_step  double precision  采样间距，单位与输入线坐标单位一致
-- 返回值：TABLE，高程剖面点。
-- 注意事项：EPSG:4326 的单位是度；如需按米采样，应先将线转换到米制坐标后生成采样点。
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
        public.gis_dem_elevation_by_point(s.geom) AS elevation
    FROM samples s
    ORDER BY s.seq;
$$;

COMMENT ON FUNCTION public.gis_dem_profile_by_line(geometry, double precision)
IS '线路高程剖面';


-- =============================================================================
-- 函数名称：gis_dem_point_with_elevation
-- 函数功能：给点补充 DEM 高程
-- 函数描述：接收 Point，查询 DEM 高程后返回 PointZ。
-- 参数说明：p_point geometry，点几何。
-- 返回值：geometry(PointZ)。
-- 适用场景：给航点、兴趣点补充地面高程。
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
    )
    SELECT
        CASE
            WHEN geom IS NULL OR ST_GeometryType(geom) <> 'ST_Point' THEN NULL::geometry
            ELSE ST_SetSRID(
                ST_MakePoint(
                    ST_X(geom),
                    ST_Y(geom),
                    COALESCE(public.gis_dem_elevation_by_point(geom), 0)
                ),
                srid
            )
        END
    FROM input_point;
$$;

COMMENT ON FUNCTION public.gis_dem_point_with_elevation(geometry)
IS '点补DEM高程';


-- =============================================================================
-- 函数名称：gis_dem_line_with_elevation
-- 函数功能：给线补充 DEM 高程
-- 函数描述：拆分 LineString 顶点，逐点查询 DEM 高程后重新组成 LineStringZ。
-- 参数说明：p_line geometry，线几何。
-- 返回值：geometry(LineStringZ)。
-- 适用场景：给航线顶点补充地面高程。
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
                        COALESCE(public.gis_dem_elevation_by_point(geom), 0)
                    )
                    ORDER BY seq
                ),
                (SELECT srid FROM input_line)
            )
        END
    FROM points;
$$;

COMMENT ON FUNCTION public.gis_dem_line_with_elevation(geometry)
IS '线补DEM高程';


-- =============================================================================
-- 函数名称：gis_dem_polygon_with_elevation
-- 函数功能：给面补充 DEM 高程
-- 函数描述：拆分 Polygon 外环和内环顶点，逐点查询 DEM 高程后重新组成 PolygonZ。
-- 参数说明：p_polygon geometry，面几何。
-- 返回值：geometry(PolygonZ)。
-- 适用场景：给电子围栏、作业区边界补充地面高程。
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
                    COALESCE(public.gis_dem_elevation_by_point(geom), 0)
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

COMMENT ON FUNCTION public.gis_dem_polygon_with_elevation(geometry)
IS '面补DEM高程';


-- =============================================================================
-- 函数名称：gis_dem_geom_with_elevation
-- 函数功能：点线面通用补充 DEM 高程
-- 函数描述：根据输入几何类型自动调用点、线、面补高程函数。
-- 参数说明：p_geom geometry，支持 Point、LineString、Polygon。
-- 返回值：geometry，返回带 Z 值的几何；不支持的类型返回 NULL。
-- 适用场景：接口层不确定输入类型时统一调用。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_geom_with_elevation(
    p_geom geometry
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    SELECT
        CASE ST_GeometryType(p_geom)
            WHEN 'ST_Point' THEN public.gis_dem_point_with_elevation(p_geom)
            WHEN 'ST_LineString' THEN public.gis_dem_line_with_elevation(p_geom)
            WHEN 'ST_Polygon' THEN public.gis_dem_polygon_with_elevation(p_geom)
            ELSE NULL::geometry
        END;
$$;

COMMENT ON FUNCTION public.gis_dem_geom_with_elevation(geometry)
IS '几何补DEM高程';


-- =============================================================================
-- 调用示例
-- =============================================================================
-- 说明：以下示例默认输入 EPSG:4326，经纬度顺序为 lon lat。
-- =============================================================================

-- 1. 校验 DEM 入库状态
-- SELECT * FROM public.gis_dem_validate();
-- SELECT * FROM public.gis_dem_validate(4326, 4326);

-- 2. 查看 DEM 表范围
-- SELECT ST_AsText(ST_Envelope(ST_Collect(ST_ConvexHull(rast)))) AS dem_extent
-- FROM public.gis_dem_henan;

-- 3. 查询单点高程
-- SELECT public.gis_dem_elevation(113.65, 34.76, 4326) AS elevation;

-- 4. 查询 geometry 点高程
-- SELECT public.gis_dem_elevation_by_point(
--     ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
-- ) AS elevation;

-- 5. 查询面范围高程统计
-- SELECT *
-- FROM public.gis_dem_stats_by_polygon(
--     ST_GeomFromText(
--         'POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))',
--         4326
--     )
-- );

-- 6. 查询线路高程剖面
-- SELECT *
-- FROM public.gis_dem_profile_by_line(
--     ST_GeomFromText('LINESTRING(113.60 34.70,113.65 34.76,113.70 34.80)', 4326),
--     0.001
-- );

-- 7. 点补 DEM 高程，返回 PointZ
-- SELECT ST_AsText(
--     public.gis_dem_point_with_elevation(
--         ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
--     )
-- ) AS point_z;

-- 8. 线补 DEM 高程，返回 LineStringZ
-- SELECT ST_AsText(
--     public.gis_dem_line_with_elevation(
--         ST_GeomFromText('LINESTRING(113.60 34.70,113.65 34.76,113.70 34.80)', 4326)
--     )
-- ) AS line_z;

-- 9. 面补 DEM 高程，返回 PolygonZ
-- SELECT ST_AsText(
--     public.gis_dem_polygon_with_elevation(
--         ST_GeomFromText(
--             'POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))',
--             4326
--         )
--     )
-- ) AS polygon_z;

-- 10. 通用点线面补高程
-- SELECT ST_AsText(
--     public.gis_dem_geom_with_elevation(
--         ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
--     )
-- ) AS geom_z;
