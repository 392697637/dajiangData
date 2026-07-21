-- =============================================================================
-- 6.DEM.sql
--   GeoTIFF DEM 数据在 PostgreSQL/PostGIS 中的入库、查询和常用函数
--
-- 说明：
--   1. DEM tif 推荐使用 raster2pgsql 入库为 PostGIS raster。
--   2. 默认表名：public.gis_dem_henan，栅格字段：rast。
--   3. 坐标系示例使用 EPSG:4326；实际项目请替换为 tif 的真实 SRID。
--   4. 高程单位通常由 DEM 数据源决定，常见为米。
--
-- 文件内容：
--   1. 扩展：postgis、postgis_raster。
--   2. GeoTIFF DEM 入库命令：Windows/Linux raster2pgsql 导入示例和参数说明。
--   3. DEM 基础检查：表范围、SRID、像元大小、波段、NoData 信息。
--   4. 点位高程函数：gis_dem_elevation、gis_dem_elevation_by_point。
--   5. 面范围统计函数：gis_dem_stats_by_polygon。
--   6. 线路剖面函数：gis_dem_profile_by_line。
--   7. 派生地形表：gis_dem_slope、gis_dem_aspect、gis_dem_hillshade。
--   8. 调用示例：统一放在文件最后。
-- =============================================================================


-- =============================================================================
-- 1. 扩展
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

-- 注意：
--   public.gis_dem_henan 不在本脚本中手工创建。
--   正式 DEM 表应由 raster2pgsql 根据 tif 自动创建并导入数据。
--   这样可以同时生成切片数据、空间索引、栅格约束和统计信息。
--
-- 推荐统一表名：
--   public.gis_dem_henan
--
-- 表名说明：
--   public
--     PostgreSQL schema 名称，表示该表位于 public 命名空间。
--
--   gis_dem_henan
--     河南 DEM 栅格主表名称，用于保存 raster2pgsql 导入后的 DEM 瓦片数据。
--     后续高程查询、范围统计、线路剖面、坡度坡向分析函数均默认读取该表。
--
--   public.gis_dem_henan
--     完整表名。推荐项目中统一使用该表名，避免函数和导入表不一致。
--
-- raster2pgsql 生成的表通常包含：
--   rid  integer 主键
--   rast raster  DEM 栅格瓦片
--
-- public.gis_dem_henan 字段说明：
--   rid
--     栅格瓦片主键。raster2pgsql 会为每个切片生成一条记录。
--     例如使用 -t 256x256 后，一张 tif 会被拆成多条 256x256 瓦片记录。
--
--   rast
--     PostGIS raster 类型字段，保存 DEM 栅格瓦片数据。
--     后续 ST_Value、ST_Intersects、ST_Clip、ST_SummaryStatsAgg 等函数都读取该字段。
--
--   filename
--     原始 tif 文件名字段。只有 raster2pgsql 使用 -F 参数时才会自动生成。
--     当前推荐导入命令未使用 -F，因此默认表通常没有 filename 字段。
--
--   created_at
--     入库时间字段。raster2pgsql 默认不会自动生成该字段。
--     如果业务需要记录入库时间，可以导入后手工 ALTER TABLE 添加。
--
-- 当前推荐的正式表结构以 raster2pgsql 实际生成结果为准，核心必需字段是：
--   rid
--   rast
--
-- 如果需要在导入后补充入库时间字段，可以执行：
-- ALTER TABLE public.gis_dem_henan
-- ADD COLUMN IF NOT EXISTS created_at timestamp without time zone DEFAULT now();
--
-- 如果需要记录文件名，推荐导入时使用 -F：
-- raster2pgsql -s 4326 -I -C -M -F -t 256x256 "E:\DEM\HENAN.tif" public.gis_dem_henan > E:\DEM\gis_dem_henan.sql
--
-- 本脚本后续函数默认读取：
--   public.gis_dem_henan.rast

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

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gis_dem_henan'
          AND column_name = 'created_at'
    ) THEN
        COMMENT ON COLUMN public.gis_dem_henan.created_at IS '入库时间';
    END IF;
END;
$$;

-- =============================================================================
-- 2. GeoTIFF DEM 入库命令
-- =============================================================================

-- Windows CMD 推荐流程：
-- 1. 删除旧 SQL 文件：
-- del /f /q E:\DEM\gis_dem_henan.sql
--
-- 2. 由 raster2pgsql 生成 SQL 文件。正式表名使用 public.gis_dem_henan：
-- raster2pgsql -s 4326 -I -C -M -t 256x256 "E:\DEM\HENAN.tif" public.gis_dem_henan > E:\DEM\gis_dem_henan.sql
--
-- 3. 设置数据库密码：
-- set PGPASSWORD=Ktd@postSQL@2026!@#
--
-- 4. 导入数据库：
-- psql -h 192.168.110.6 -p 5432 -U zhuoyi -d ktd_lx_2026gis -f E:\DEM\gis_dem_henan.sql
--
-- 5. 验证切片数量：
-- psql -h 192.168.110.6 -p 5432 -U zhuoyi -d ktd_lx_2026gis -c "SELECT COUNT(*) FROM public.gis_dem_henan;"

-- Linux 示例：
-- PGPASSWORD='Ktd@postSQL@2026!@#' raster2pgsql -s 4326 -I -C -M -t 256x256 "/data/dem/HENAN.tif" public.gis_dem_henan | psql -h 192.168.110.6 -p 5432 -U zhuoyi -d ktd_lx_2026gis

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
FROM public.gis_dem_henan;

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
FROM public.gis_dem_henan
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
        FROM public.gis_dem_henan
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
    FROM public.gis_dem_henan d
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
        FROM public.gis_dem_henan
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    pt AS (
        SELECT ST_Transform(p_geom, (SELECT srid FROM dem_srid)) AS geom
    )
    SELECT ST_Value(d.rast, 1, p.geom)
    FROM public.gis_dem_henan d
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
        FROM public.gis_dem_henan
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    area_geom AS (
        SELECT ST_Transform(p_geom, (SELECT srid FROM dem_srid)) AS geom
    ),
    clipped AS (
        SELECT ST_Clip(d.rast, 1, a.geom, true) AS rast
        FROM public.gis_dem_henan d
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
CREATE TABLE IF NOT EXISTS public.gis_dem_henan_slope AS
SELECT
    rid,
    ST_Slope(rast, 1, '32BF', 'DEGREES') AS rast
FROM public.gis_dem_henan
WHERE rast IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_gis_dem_slope_rast_gist
ON public.gis_dem_henan_slope
USING gist (ST_ConvexHull(rast));

-- 坡向栅格。单位为度，0/360 通常代表北向。
CREATE TABLE IF NOT EXISTS public.gis_dem_henan_aspect AS
SELECT
    rid,
    ST_Aspect(rast, 1, '32BF', 'DEGREES') AS rast
FROM public.gis_dem_henan
WHERE rast IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_gis_dem_aspect_rast_gist
ON public.gis_dem_henan_aspect
USING gist (ST_ConvexHull(rast));

-- 阴影地形。azimuth 为光源方位角，altitude 为光源高度角。
CREATE TABLE IF NOT EXISTS public.gis_dem_henan_hillshade AS
SELECT
    rid,
    ST_HillShade(rast, 1, '8BUI', 315, 45) AS rast
FROM public.gis_dem_henan
WHERE rast IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_gis_dem_hillshade_rast_gist
ON public.gis_dem_henan_hillshade
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





