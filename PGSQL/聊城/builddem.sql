/*
===============================================================================
聊城建筑 ground_dem 写入和异常建筑删除脚本

流程:
1 新增并计算建筑面积字段 area_m2
2 清空 ground_dem
3 根据建筑面范围内 DEM 最高高程写入 ground_dem
  如果建筑面取不到 DEM, 兜底取建筑第一个点 DEM 高程
4 删除疑似单面、碎小面积、高度异常、ground_dem 为空的建筑
5 查询剩余建筑验证结果

删除规则:
1 height 为空或 height <= 0
2 ground_dem 为空
3 面积小于 5 平方米
4 等效宽度 2 * area / perimeter 小于 0.8 米
===============================================================================
*/

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

/* 1 新增并计算建筑面积字段 area_m2, 单位平方米 */
ALTER TABLE public.gis_build_liaocheng
ADD COLUMN IF NOT EXISTS area_m2 numeric;

WITH area_result AS (
    SELECT
        b.gid,
        ST_Area(
            ST_CollectionExtract(ST_MakeValid(ST_Force2D(b.geom)), 3)::geography
        ) AS area_m2
    FROM public.gis_build_liaocheng b
    WHERE b.geom IS NOT NULL
      AND NOT ST_IsEmpty(b.geom)
),
updated_area AS (
    UPDATE public.gis_build_liaocheng b
    SET area_m2 = round(ar.area_m2::numeric, 2)
    FROM area_result ar
    WHERE b.gid = ar.gid
    RETURNING b.gid, b.area_m2
)
SELECT
    COUNT(*) AS area_updated_count,
    MIN(area_m2) AS min_area_m2,
    MAX(area_m2) AS max_area_m2,
    round(AVG(area_m2), 2) AS avg_area_m2
FROM updated_area;

/* 2 清空 ground_dem */
UPDATE public.gis_build_liaocheng
SET ground_dem = NULL
WHERE ground_dem IS NOT NULL;

/* 3 根据建筑面范围内 DEM 最高高程写入 ground_dem */
WITH build_geom AS (
    SELECT
        b.gid,
        ST_CollectionExtract(ST_MakeValid(ST_Force2D(b.geom)), 3) AS calc_geom,
        ST_PointN(
            ST_ExteriorRing(
                ST_GeometryN(
                    ST_CollectionExtract(ST_MakeValid(ST_Force2D(b.geom)), 3),
                    1
                )
            ),
            1
        ) AS first_point
    FROM public.gis_build_liaocheng b
    WHERE b.geom IS NOT NULL
      AND NOT ST_IsEmpty(b.geom)
),
dem_max AS (
    SELECT
        bg.gid,
        (ST_SummaryStatsAgg(
            ST_Clip(d.rast, 1, bg.calc_geom, true),
            1,
            true
        )).max AS max_dem
    FROM build_geom bg
    JOIN public.gis_dem_shandong d
      ON d.rast IS NOT NULL
     AND d.rast && bg.calc_geom
     AND ST_Intersects(d.rast, bg.calc_geom)
    WHERE bg.calc_geom IS NOT NULL
      AND NOT ST_IsEmpty(bg.calc_geom)
    GROUP BY bg.gid
    HAVING (ST_SummaryStatsAgg(
        ST_Clip(d.rast, 1, bg.calc_geom, true),
        1,
        true
    )).max IS NOT NULL
),
dem_first_point AS (
    SELECT DISTINCT ON (bg.gid)
        bg.gid,
        ST_Value(d.rast, 1, bg.first_point) AS first_point_dem
    FROM build_geom bg
    JOIN public.gis_dem_shandong d
      ON d.rast IS NOT NULL
     AND bg.first_point IS NOT NULL
     AND d.rast && bg.first_point
     AND ST_Intersects(d.rast, bg.first_point)
    WHERE bg.calc_geom IS NOT NULL
      AND NOT ST_IsEmpty(bg.calc_geom)
    ORDER BY bg.gid, d.rid
),
dem_result AS (
    SELECT
        bg.gid,
        COALESCE(dm.max_dem, dfp.first_point_dem) AS ground_dem
    FROM build_geom bg
    LEFT JOIN dem_max dm ON dm.gid = bg.gid
    LEFT JOIN dem_first_point dfp ON dfp.gid = bg.gid
    WHERE COALESCE(dm.max_dem, dfp.first_point_dem) IS NOT NULL
),
updated AS (
    UPDATE public.gis_build_liaocheng b
    SET ground_dem = round(dr.ground_dem::numeric, 2)
    FROM dem_result dr
    WHERE b.gid = dr.gid
    RETURNING b.gid, b.ground_dem
)
SELECT
    COUNT(*) AS updated_count,
    MIN(ground_dem) AS min_ground_dem,
    MAX(ground_dem) AS max_ground_dem,
    round(AVG(ground_dem), 2) AS avg_ground_dem
FROM updated;

/* 4 直接删除疑似单面、碎小面积、高度异常、ground_dem 为空的建筑 */
WITH params AS (
    SELECT
        5.0::double precision AS min_area_m2,
        0.8::double precision AS min_width_m
),
fixed AS (
    SELECT
        b.gid,
        b.height,
        b.ground_dem,
        b.area_m2,
        ST_Multi(
            ST_CollectionExtract(
                ST_MakeValid(ST_Force2D(b.geom)),
                3
            )
        )::geometry(MultiPolygon, 4326) AS geom
    FROM public.gis_build_liaocheng b
    WHERE b.geom IS NOT NULL
      AND NOT ST_IsEmpty(b.geom)
),
metric AS (
    SELECT
        f.gid,
        f.height,
        f.ground_dem,
        f.area_m2,
        ST_Perimeter(f.geom::geography) AS perimeter_m
    FROM fixed f
    WHERE f.geom IS NOT NULL
      AND NOT ST_IsEmpty(f.geom)
),
delete_target AS (
    SELECT
        m.gid,
        CASE
            WHEN m.height IS NULL OR m.height <= 0 THEN 'height_invalid'
            WHEN m.ground_dem IS NULL THEN 'ground_dem_null'
            WHEN m.area_m2 < p.min_area_m2 THEN 'small_area'
            WHEN CASE
                    WHEN m.perimeter_m > 0 THEN 2.0 * m.area_m2 / m.perimeter_m
                    ELSE 0
                 END < p.min_width_m THEN 'thin_or_single_face'
            ELSE 'other'
        END AS delete_reason
    FROM metric m
    CROSS JOIN params p
    WHERE m.height IS NULL
       OR m.height <= 0
       OR m.ground_dem IS NULL
       OR m.area_m2 < p.min_area_m2
       OR CASE
            WHEN m.perimeter_m > 0 THEN 2.0 * m.area_m2 / m.perimeter_m
            ELSE 0
          END < p.min_width_m
),
deleted AS (
    DELETE FROM public.gis_build_liaocheng b
    USING delete_target dt
    WHERE b.gid = dt.gid
    RETURNING b.gid, dt.delete_reason
)
SELECT
    delete_reason,
    COUNT(*) AS deleted_count
FROM deleted
GROUP BY delete_reason
ORDER BY delete_reason;

/* 5 查询剩余建筑验证结果 */
SELECT
    COUNT(*) AS build_count,
    COUNT(ground_dem) AS ground_dem_count,
    COUNT(*) - COUNT(ground_dem) AS missing_ground_dem_count,
    round(COUNT(ground_dem)::numeric * 100 / NULLIF(COUNT(*), 0), 2) AS ground_dem_percent,
    MIN(area_m2) AS min_area_m2,
    MAX(area_m2) AS max_area_m2,
    round(AVG(area_m2), 2) AS avg_area_m2,
    MIN(ground_dem) AS min_ground_dem,
    MAX(ground_dem) AS max_ground_dem,
    round(AVG(ground_dem), 2) AS avg_ground_dem
FROM public.gis_build_liaocheng;
