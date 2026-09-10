-- =============================================================================
-- 0日常.sql
-- =============================================================================
-- 文件定位：
--   日常数据库维护脚本，存放临时、低频、需要人工确认后执行的维护 SQL。
--
-- 本次内容：
--   1. 备份 bo_ground_ele 表。
--   2. 将 bo_ground_ele.geom 字段统一转换为三维 GeometryZ。
--   3. 刷新 PostGIS geometry_columns 元数据，确保外部工具能识别最新几何类型。
--
-- 使用提醒：
--   1. CREATE TABLE ... AS 会复制当前表数据，但不会复制原表索引、约束、触发器和字段注释。
--   2. ALTER COLUMN geom TYPE 会重写表数据，生产环境建议在低峰期执行。
--   3. 执行前请确认 bo_ground_ele_bak 是否已存在，避免备份表名冲突。
-- =============================================================================

-- 备份地面高程表当前数据，用于后续类型转换前留存快照。
CREATE TABLE bo_ground_ele_bak AS SELECT * FROM bo_ground_ele;


-- 将 geom 字段转换为三维几何类型；已有二维几何通过 ST_Force3D 补齐 Z 值。
ALTER TABLE public.bo_ground_ele
ALTER COLUMN geom TYPE geometry(GeometryZ)
USING ST_Force3D(geom);

-- 更新 PostGIS 元数据表（geometry_columns），让几何字段类型信息保持同步。
SELECT Populate_Geometry_Columns('public.bo_ground_ele'::regclass);
