-- ============================================================================
-- 2.在对接接口.sql
-- 日期：2026-08-03
-- 范围：DEM 高程处理接口。
-- 说明：本文档整理 DEM 相关函数和调用示例，方便后续对接查看。
-- ============================================================================

-- ============================================================================
-- DEM 函数目录
-- ============================================================================
-- 1. gis_dem_validate
--    校验 DEM 表、SRID、范围和电子围栏覆盖情况。
--
-- 2. gis_dem_elevation
--    按单个 Point 查询 DEM 第一波段高程值。
--
-- 3. gis_dem_elevation_geometry
--    基础 DEM 高程提取和补高程统一入口，返回带 DEM Z 值的新 geometry。
--
-- 4. gis_dem_elevation_point
--    点/多点 geometry 专用 DEM 补高入口。
--
-- 5. gis_dem_elevation_line
--    线/多线 geometry 专用 DEM 补高入口。
--
-- 6. gis_dem_elevation_polygon
--    面/多面 geometry 专用 DEM 补高入口。
--
-- 7. gis_dem_elevation_text_point
--    点/多点文本专用 DEM 补高入口，支持 WKT、EWKT、GeoJSON。
--
-- 8. gis_dem_elevation_text_line
--    线/多线文本专用 DEM 补高入口，支持 WKT、EWKT、GeoJSON。
--
-- 9. gis_dem_elevation_text_polygon
--    面/多面文本专用 DEM 补高入口，支持 WKT、EWKT、GeoJSON。
--
-- 10. gis_dem_elevation_text
--     解析 WKT、EWKT 或 GeoJSON，并返回 DEM 高程结果表。
--
-- 11. gis_dem_update_table_z0
--     按表名和几何列名批量补 DEM 高程；二维面或 Z 全为 0 的面会更新。
--
-- 12. gis_dem_reset_table_z0
--     按表名和几何列名批量清空 DEM 高程，把面/多面的 Z 值统一重置为 0。
-- ============================================================================

-- ============================================================================
-- gis_dem_validate
-- 功能：校验 DEM 表、SRID、范围和电子围栏覆盖情况。
-- ============================================================================
SELECT * FROM public.gis_dem_validate();

-- ============================================================================
-- gis_dem_elevation
-- 功能：按单个 Point 查询 DEM 高程值；点不在 DEM 覆盖范围内返回 NULL。
-- ============================================================================
SELECT public.gis_dem_elevation(
    ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
) AS elevation;

-- ============================================================================
-- gis_dem_elevation_geometry
-- 功能：基础 DEM 高程提取和补高程统一入口，返回带 DEM Z 值的新 geometry。
-- ============================================================================
SELECT ST_AsText(
    public.gis_dem_elevation_geometry(
        ST_SetSRID(ST_GeomFromText('LINESTRING(113.60 34.70,113.70 34.80)'), 4326)
    )
) AS result_wkt;

-- ============================================================================
-- gis_dem_elevation_point / gis_dem_elevation_line / gis_dem_elevation_polygon
-- 功能：点、线、面 geometry 专用 DEM 补高入口。
-- ============================================================================
SELECT ST_AsText(public.gis_dem_elevation_point(
    ST_SetSRID(ST_GeomFromText('POINT(113.65 34.76)'), 4326)
)) AS point_z;

SELECT ST_AsText(public.gis_dem_elevation_line(
    ST_SetSRID(ST_GeomFromText('LINESTRING(113.60 34.70,113.70 34.80)'), 4326)
)) AS line_z;

SELECT ST_AsText(public.gis_dem_elevation_polygon(
    ST_SetSRID(ST_GeomFromText('POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))'), 4326)
)) AS polygon_z;

-- ============================================================================
-- gis_dem_elevation_text_point / gis_dem_elevation_text_line / gis_dem_elevation_text_polygon
-- 功能：点、线、面文本专用 DEM 补高入口，支持 WKT、EWKT、GeoJSON。
-- ============================================================================
SELECT ST_AsText(public.gis_dem_elevation_text_point('POINT(113.65 34.76)')) AS point_text_z;

SELECT ST_AsText(public.gis_dem_elevation_text_line(
    'SRID=4326;LINESTRING(113.60 34.70,113.70 34.80)'
)) AS line_text_z;

SELECT ST_AsText(public.gis_dem_elevation_text_polygon(
    '{"type":"Polygon","coordinates":[[[113.60,34.70],[113.70,34.70],[113.70,34.80],[113.60,34.80],[113.60,34.70]]]}'
)) AS polygon_text_z;

-- ============================================================================
-- gis_dem_elevation_text
-- 功能：解析 WKT、EWKT 或 GeoJSON，并返回 DEM 高程结果表。
-- 返回：geom_type, seq, point_geom, elevation, result_geom, result_wkt。
-- ============================================================================
SELECT *
FROM public.gis_dem_elevation_text('POINT(113.65 34.76)');

SELECT *
FROM public.gis_dem_elevation_text(
    '{"type":"LineString","coordinates":[[113.60,34.70],[113.70,34.80]]}'
);

-- ============================================================================
-- 保留：电子围栏 DEM 高程处理
-- 说明：以下两个 SQL 放在文档最后，方便后续直接执行。
-- ============================================================================

-- ============================================================================
-- gis_dem_update_table_z0
-- 功能：批量给电子围栏 geom 补 DEM 高程。
-- 规则：二维面或 Z 全为 0 的 Polygon/MultiPolygon 会更新为 DEM 高程；
--      已有非 0 Z 的数据保持不变。
-- 参数：
--   p_table_name   text   表名，支持 schema.table
--   p_geom_column  text   几何字段名
-- ============================================================================
SELECT * FROM public.gis_dem_update_table_z0('public.bo_electric_fence', 'geom');

-- ============================================================================
-- gis_dem_reset_table_z0
-- 功能：批量清空电子围栏 geom 高程，把面/多面的 Z 值统一重置为 0。
-- 参数：
--   p_table_name   text   表名，支持 schema.table
--   p_geom_column  text   几何字段名
-- ============================================================================
SELECT * FROM public.gis_dem_reset_table_z0('public.bo_electric_fence', 'geom');
