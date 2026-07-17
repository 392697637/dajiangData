-- =============================================================================
-- 6.DEM.sql
--   GeoTIFF DEM 数据在 PostgreSQL/PostGIS 中的入库、查询和常用函数
--
-- 说明：
--   1. DEM tif 推荐使用 raster2pgsql 入库为 PostGIS raster。
--   2. 默认表名：public.gis_dem，栅格字段：rast。
--   3. 坐标系示例使用 EPSG:4326；实际项目请替换为 tif 的真实 SRID。
--   4. 高程单位通常由 DEM 数据源决定，常见为米。
--
-- 文件内容：
--   1. 扩展与表结构：postgis、postgis_raster、gis_dem 主表、空间索引、栅格约束。
--   2. GeoTIFF DEM 入库命令：Windows/Linux raster2pgsql 导入示例和参数说明。
--   3. DEM 基础检查：表范围、SRID、像元大小、波段、NoData 信息。
--   4. 点位高程函数：gis_dem_elevation、gis_dem_elevation_by_point。
--   5. 面范围统计函数：gis_dem_stats_by_polygon。
--   6. 线路剖面函数：gis_dem_profile_by_line。
--   7. 派生地形表：gis_dem_slope、gis_dem_aspect、gis_dem_hillshade。
--   8. 调用示例：统一放在文件最后。
-- =============================================================================


-- =============================================================================
-- 1. 扩展与表结构
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

-- DEM 主表。一般由 raster2pgsql 自动创建，这里保留结构模板便于手工建表或核对。
CREATE TABLE IF NOT EXISTS public.gis_dem (
    rid serial PRIMARY KEY,
    rast raster,
    filename text,
    created_at timestamp without time zone DEFAULT now()
);

-- 栅格空间索引。使用 ST_ConvexHull(rast) 建立 GIST 索引，用于按范围快速过滤瓦片。
CREATE INDEX IF NOT EXISTS idx_gis_dem_rast_gist
ON public.gis_dem
USING gist (ST_ConvexHull(rast));

-- 栅格元数据约束。入库后执行，便于 PostGIS 识别 SRID、像元大小、波段等信息。
SELECT AddRasterConstraints('public'::name, 'gis_dem'::name, 'rast'::name);


-- =============================================================================
-- 2. GeoTIFF DEM 入库命令
-- =============================================================================

-- Windows 示例：
-- raster2pgsql -s 4326 -I -C -M -t 256x256 "E:\data\dem.tif" public.gis_dem | psql -h 127.0.0.1 -p 5432 -U postgres -d your_db

-- Linux 示例：
-- raster2pgsql -s 4326 -I -C -M -t 256x256 /data/dem.tif public.gis_dem | psql -h 127.0.0.1 -p 5432 -U postgres -d your_db

-- 参数说明：
--   -s 4326     设置 DEM 坐标系 SRID，按实际 tif 修改。
--   -I          创建栅格空间索引。
--   -C          添加栅格约束。
--   -M          入库后执行 VACUUM ANALYZE。
--   -t 256x256  将大 tif 切片入库，提高查询效率。
--   -a          追加到已有表；首次建表不加 -a。


-- =============================================================================
-- 3. DEM 基础检查
-- =============================================================================

-- 查看 DEM 表范围。
SELECT ST_AsText(ST_Extent(ST_ConvexHull(rast))) AS dem_extent
FROM public.gis_dem;

-- 查看栅格元信息。
SELECT
    rid,
    ST_SRID(rast) AS srid,
    ST_Width(rast) AS width,
    ST_Height(rast) AS height,
    ST_NumBands(rast) AS bands,
    ST_PixelWidth(rast) AS pixel_width,
    ST_PixelHeight(rast) AS pixel_height,
    ST_BandNoDataValue(rast, 1) AS nodata
FROM public.gis_dem
ORDER BY rid
LIMIT 20;


-- =============================================================================
-- 4. 点位高程查询函数
-- =============================================================================

-- 按经纬度查询 DEM 高程。
-- 入参坐标默认 EPSG:4326，如 DEM 表不是 4326，会自动转换到 DEM SRID。
CREATE OR REPLACE FUNCTION public.gis_dem_elevation(
    p_lon double precision,
    p_lat double precision,
    p_srid integer DEFAULT 4326
)
RETURNS double precision
LANGUAGE sql
STABLE
AS $$
    WITH dem_srid AS (
        SELECT ST_SRID(rast) AS srid
        FROM public.gis_dem
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    pt AS (
        SELECT ST_Transform(
            ST_SetSRID(ST_MakePoint(p_lon, p_lat), p_srid),
            (SELECT srid FROM dem_srid)
        ) AS geom
    )
    SELECT ST_Value(d.rast, 1, p.geom)
    FROM public.gis_dem d
    CROSS JOIN pt p
    WHERE ST_Intersects(d.rast, p.geom)
    ORDER BY d.rid
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation(double precision, double precision, integer)
IS '按点坐标查询 DEM 第一波段高程值。';


-- 按 geometry 点查询 DEM 高程。
CREATE OR REPLACE FUNCTION public.gis_dem_elevation_by_point(
    p_geom geometry
)
RETURNS double precision
LANGUAGE sql
STABLE
AS $$
    WITH dem_srid AS (
        SELECT ST_SRID(rast) AS srid
        FROM public.gis_dem
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    pt AS (
        SELECT ST_Transform(p_geom, (SELECT srid FROM dem_srid)) AS geom
    )
    SELECT ST_Value(d.rast, 1, p.geom)
    FROM public.gis_dem d
    CROSS JOIN pt p
    WHERE ST_Intersects(d.rast, p.geom)
    ORDER BY d.rid
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_by_point(geometry)
IS '按 geometry 点查询 DEM 第一波段高程值。';


-- =============================================================================
-- 5. 范围 DEM 统计函数
-- =============================================================================

-- 统计指定面范围内 DEM 的最小值、最大值、平均值、像元数。
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
        FROM public.gis_dem
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    area_geom AS (
        SELECT ST_Transform(p_geom, (SELECT srid FROM dem_srid)) AS geom
    ),
    clipped AS (
        SELECT ST_Clip(d.rast, 1, a.geom, true) AS rast
        FROM public.gis_dem d
        CROSS JOIN area_geom a
        WHERE ST_Intersects(d.rast, a.geom)
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
IS '统计指定 geometry 范围内 DEM 高程的 count/min/max/mean/stddev。';


-- =============================================================================
-- 6. 线路高程剖面函数
-- =============================================================================

-- 沿线按固定距离采样，返回每个采样点的距离、坐标和高程。
-- p_step 使用线 geometry 的坐标单位；若线为 EPSG:4326，建议先转为米制投影再传入。
CREATE OR REPLACE FUNCTION public.gis_dem_profile_by_line(
    p_line geometry,
    p_step double precision DEFAULT 10
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
    WITH params AS (
        SELECT
            p_line AS line_geom,
            GREATEST(p_step, 0.000001) AS step_len,
            ST_Length(p_line) AS line_len
    ),
    samples AS (
        SELECT
            row_number() OVER ()::integer AS seq,
            LEAST(g.dist, p.line_len) AS distance,
            ST_LineInterpolatePoint(p.line_geom, LEAST(g.dist, p.line_len) / NULLIF(p.line_len, 0)) AS geom
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
IS '沿线按固定间距采样 DEM 高程，生成线路高程剖面。';


-- =============================================================================
-- 7. 坡度、坡向和阴影地形派生示例
-- =============================================================================

-- 坡度栅格。单位为度，适合 DEM 为米制投影坐标时使用。
CREATE TABLE IF NOT EXISTS public.gis_dem_slope AS
SELECT
    rid,
    ST_Slope(rast, 1, '32BF', 'DEGREES') AS rast
FROM public.gis_dem
WHERE rast IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_gis_dem_slope_rast_gist
ON public.gis_dem_slope
USING gist (ST_ConvexHull(rast));

-- 坡向栅格。单位为度，0/360 通常代表北向。
CREATE TABLE IF NOT EXISTS public.gis_dem_aspect AS
SELECT
    rid,
    ST_Aspect(rast, 1, '32BF', 'DEGREES') AS rast
FROM public.gis_dem
WHERE rast IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_gis_dem_aspect_rast_gist
ON public.gis_dem_aspect
USING gist (ST_ConvexHull(rast));

-- 阴影地形。azimuth 为光源方位角，altitude 为光源高度角。
CREATE TABLE IF NOT EXISTS public.gis_dem_hillshade AS
SELECT
    rid,
    ST_HillShade(rast, 1, '8BUI', 315, 45) AS rast
FROM public.gis_dem
WHERE rast IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_gis_dem_hillshade_rast_gist
ON public.gis_dem_hillshade
USING gist (ST_ConvexHull(rast));


-- =============================================================================
-- 8. 常用查询示例
-- =============================================================================

-- 查询单点高程。
SELECT public.gis_dem_elevation(116.3913, 39.9075, 4326) AS elevation;

-- 查询 WKT 面范围内高程统计。
SELECT *
FROM public.gis_dem_stats_by_polygon(
    ST_GeomFromText(
        'POLYGON((116.38 39.90,116.40 39.90,116.40 39.92,116.38 39.92,116.38 39.90))',
        4326
    )
);

-- 查询 WKT 线路高程剖面。
SELECT *
FROM public.gis_dem_profile_by_line(
    ST_GeomFromText('LINESTRING(116.38 39.90,116.40 39.92)', 4326),
    0.001
);

