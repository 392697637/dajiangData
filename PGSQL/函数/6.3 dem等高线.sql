-- 6.3 DEM 等高线生成脚本
-- 源表: public.gis_dem_henan
-- 源字段: rast raster
-- 目标表:
--   public.gis_dem_henan_contour_100m
--   public.gis_dem_henan_contour_50m
--   public.gis_dem_henan_contour_10m
-- 坐标系: EPSG:4326

-- 1. 检查 PostGIS / Raster 能力
SELECT postgis_full_version();

-- 2. 检查源 DEM 栅格表
SELECT
  COUNT(*) AS tile_count,
  MIN(ST_SRID(rast)) AS min_srid,
  MAX(ST_SRID(rast)) AS max_srid,
  MIN(ST_NumBands(rast)) AS min_bands,
  MAX(ST_NumBands(rast)) AS max_bands
FROM public.gis_dem_henan;

-- 3. 生成 100m 等高线
-- 建议先执行 100m，确认速度和效果后再执行 50m、10m。
DROP TABLE IF EXISTS public.gis_dem_henan_contour_100m;

CREATE TABLE public.gis_dem_henan_contour_100m AS
WITH raw AS (
  SELECT
    c.value::double precision AS elevation,
    ST_Multi(c.geom)::geometry(MultiLineString, 4326) AS geom
  FROM public.gis_dem_henan r
  CROSS JOIN LATERAL ST_Contour(
    r.rast,
    1,
    100.0,
    0.0
  ) AS c
)
SELECT
  row_number() OVER ()::bigint AS id,
  elevation,
  geom
FROM raw
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

ALTER TABLE public.gis_dem_henan_contour_100m
ADD CONSTRAINT gis_dem_henan_contour_100m_pkey PRIMARY KEY (id);

CREATE INDEX idx_gis_dem_henan_contour_100m_geom
ON public.gis_dem_henan_contour_100m
USING gist (geom);

CREATE INDEX idx_gis_dem_henan_contour_100m_elevation
ON public.gis_dem_henan_contour_100m (elevation);

ANALYZE public.gis_dem_henan_contour_100m;

-- 4. 生成 50m 等高线
DROP TABLE IF EXISTS public.gis_dem_henan_contour_50m;

CREATE TABLE public.gis_dem_henan_contour_50m AS
WITH raw AS (
  SELECT
    c.value::double precision AS elevation,
    ST_Multi(c.geom)::geometry(MultiLineString, 4326) AS geom
  FROM public.gis_dem_henan r
  CROSS JOIN LATERAL ST_Contour(
    r.rast,
    1,
    50.0,
    0.0
  ) AS c
)
SELECT
  row_number() OVER ()::bigint AS id,
  elevation,
  geom
FROM raw
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

ALTER TABLE public.gis_dem_henan_contour_50m
ADD CONSTRAINT gis_dem_henan_contour_50m_pkey PRIMARY KEY (id);

CREATE INDEX idx_gis_dem_henan_contour_50m_geom
ON public.gis_dem_henan_contour_50m
USING gist (geom);

CREATE INDEX idx_gis_dem_henan_contour_50m_elevation
ON public.gis_dem_henan_contour_50m (elevation);

ANALYZE public.gis_dem_henan_contour_50m;

-- 5. 生成 10m 等高线
-- 10m 数据量通常较大，耗时会明显高于 50m 和 100m。
DROP TABLE IF EXISTS public.gis_dem_henan_contour_10m;

CREATE TABLE public.gis_dem_henan_contour_10m AS
WITH raw AS (
  SELECT
    c.value::double precision AS elevation,
    ST_Multi(c.geom)::geometry(MultiLineString, 4326) AS geom
  FROM public.gis_dem_henan r
  CROSS JOIN LATERAL ST_Contour(
    r.rast,
    1,
    10.0,
    0.0
  ) AS c
)
SELECT
  row_number() OVER ()::bigint AS id,
  elevation,
  geom
FROM raw
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

ALTER TABLE public.gis_dem_henan_contour_10m
ADD CONSTRAINT gis_dem_henan_contour_10m_pkey PRIMARY KEY (id);

CREATE INDEX idx_gis_dem_henan_contour_10m_geom
ON public.gis_dem_henan_contour_10m
USING gist (geom);

CREATE INDEX idx_gis_dem_henan_contour_10m_elevation
ON public.gis_dem_henan_contour_10m (elevation);

ANALYZE public.gis_dem_henan_contour_10m;

-- 6. 结果检查
SELECT '100m' AS contour_interval, COUNT(*) AS line_count
FROM public.gis_dem_henan_contour_100m
UNION ALL
SELECT '50m' AS contour_interval, COUNT(*) AS line_count
FROM public.gis_dem_henan_contour_50m
UNION ALL
SELECT '10m' AS contour_interval, COUNT(*) AS line_count
FROM public.gis_dem_henan_contour_10m;

SELECT
  '100m' AS contour_interval,
  MIN(elevation) AS min_elevation,
  MAX(elevation) AS max_elevation
FROM public.gis_dem_henan_contour_100m
UNION ALL
SELECT
  '50m' AS contour_interval,
  MIN(elevation) AS min_elevation,
  MAX(elevation) AS max_elevation
FROM public.gis_dem_henan_contour_50m
UNION ALL
SELECT
  '10m' AS contour_interval,
  MIN(elevation) AS min_elevation,
  MAX(elevation) AS max_elevation
FROM public.gis_dem_henan_contour_10m;

SELECT
  '100m' AS contour_interval,
  GeometryType(geom) AS geom_type,
  ST_SRID(geom) AS srid,
  COUNT(*) AS count
FROM public.gis_dem_henan_contour_100m
GROUP BY GeometryType(geom), ST_SRID(geom)
UNION ALL
SELECT
  '50m' AS contour_interval,
  GeometryType(geom) AS geom_type,
  ST_SRID(geom) AS srid,
  COUNT(*) AS count
FROM public.gis_dem_henan_contour_50m
GROUP BY GeometryType(geom), ST_SRID(geom)
UNION ALL
SELECT
  '10m' AS contour_interval,
  GeometryType(geom) AS geom_type,
  ST_SRID(geom) AS srid,
  COUNT(*) AS count
FROM public.gis_dem_henan_contour_10m
GROUP BY GeometryType(geom), ST_SRID(geom);

