------------------------------------------------------------------ 方案一sql同步给 PG17 安装 mysql_fdw
-- -- 1. 安装 MySQL 连接扩展（PG 专用）
-- CREATE EXTENSION IF NOT EXISTS mysql_fdw;
-- 
-- -- 2. 创建 MySQL 服务器连接
-- CREATE SERVER mysql_ktd_server
-- FOREIGN DATA WRAPPER mysql_fdw
-- OPTIONS (
--   host '192.168.110.6',
--   port '3307',
--   dbname 'ktd_lx_2026dev'
-- );
-- 
-- -- 3. 配置 MySQL 账号密码
-- CREATE USER MAPPING FOR zhuoyi
-- SERVER mysql_ktd_server
-- OPTIONS (
--   username 'root',
--   password 'Ktdmysql@2026!@#'
-- );
-- 
-- -- =============================================
-- -- 4. 开始迁移：电子围栏 + 静态标注 3张表
-- -- 自动创建表结构 + 迁移全部数据
-- -- =============================================
-- 
-- -- 迁移 电子围栏信息
-- CREATE TABLE bo_electric_fence
-- AS SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_electric_fence;
-- 
-- -- 迁移 定时录像计划表
-- CREATE TABLE bo_time_plan
-- AS SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_time_plan;
-- 
-- -- 迁移 地物标注信息
-- CREATE TABLE bo_ground_ele
-- AS SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_ground_ele;
-- 
-- 
-- -- -- 增量同步电子围栏（按ID追加）
-- -- INSERT INTO bo_electric_fence
-- -- SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_electric_fence
-- -- WHERE id > (SELECT max(id) FROM bo_electric_fence);
-- -- 
-- -- -- 增量同步地物标注
-- -- INSERT INTO bo_ground_ele
-- -- SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_ground_ele
-- -- WHERE id > (SELECT max(id) FROM bo_ground_ele);

------------------------------------------------------------------------------------------ -- 方案二 Navicat同步数据
-- 电子围栏数据迁移
-- 同步 bo_electric_fence（电子围栏信息）、 bo_time_plan （定时录像计划表）表所有数据
-- 
-- 静态标注数据迁移
-- 同步 bo_ground_ele（地物标注信息）表所有数据

-- 打开 Navicat，同时连接：
-- MySQL：192.168.110.6:3307，库 ktd_lx_2026dev
-- PG：192.168.110.6:5432，库 ktd_lx_2026gis
-- 菜单栏 → 工具 → 数据传输
-- 源：选 MySQL 的 ktd_lx_2026dev
-- 目标：选 PG 的 ktd_lx_2026gis
-- 勾选要迁移的 3 张表：
-- bo_electric_fence
-- bo_time_plan
-- bo_ground_ele
-- 选项里勾选：包含表结构、包含数据、主键索引可酌情不勾
-- 开始 → 执行完成即可。


-- 电子围栏
SELECT COUNT(*) FROM bo_electric_fence;

-- 地物标注
SELECT COUNT(*) FROM bo_ground_ele;

-- 定时计划
SELECT COUNT(*) FROM bo_time_plan;


------------------------------------------------------------------------------------------ 给电子围栏表添加 time_plan 字段
-- 1. 添加字段（varchar(4000)，默认值 default）
ALTER TABLE bo_electric_fence 
ADD COLUMN time_plan varchar(4000) DEFAULT 'default';
-- 2. 给字段加注释
COMMENT ON COLUMN bo_electric_fence.time_plan IS '时间计划';

-- 1. 给电子围栏表添加 time_plan 字段（正确PG语法）
ALTER TABLE bo_electric_fence 
ADD COLUMN time_plan varchar(4000) DEFAULT 'default';

COMMENT ON COLUMN bo_electric_fence.time_plan IS '时间计划';

-- 2. 把 bo_time_plan 数据拼成 JSON 自动更新到 time_plan 字段
UPDATE bo_electric_fence f
SET time_plan = (
  SELECT json_agg(
    json_build_object(
		 'startTime', t.start_time,
      'endTime', t.end_time,
      'left', t.time_left,
      'width', t.width
    )
  )
  FROM bo_time_plan t
  WHERE t.pid = f.id  -- 关键：通过 pid 关联围栏ID
);
-- 修改后数据查看
-- SELECT id, time_plan FROM bo_electric_fence
-- SELECT * FROM bo_time_plan WHERE pid='b554fde12f1249019dc0559528d4ad84'



-- =============================================
------------------------------------------------------------------------------------------ 函数：统一公共字段（create_time/update_time/del_flag等）
-- =============================================
DROP FUNCTION IF EXISTS lx_gis_base_common_columns(text);
CREATE OR REPLACE FUNCTION lx_gis_base_common_columns(tbl_name text)
RETURNS void AS $$
BEGIN
    -- 1. create_time
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'create_time' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN create_time timestamp NOT NULL DEFAULT now()', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.create_time IS ''创建时间''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_time TYPE timestamp USING create_time::timestamp', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_time SET NOT NULL', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_time SET DEFAULT now()', tbl_name);
    END IF;

    -- 2. create_user
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'create_user' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN create_user varchar(32)', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.create_user IS ''创建者''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_user TYPE varchar(32) USING create_user::varchar(32)', tbl_name);
    END IF;

    -- 3. update_time
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'update_time' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN update_time timestamp NOT NULL DEFAULT now()', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.update_time IS ''更新时间''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_time TYPE timestamp USING update_time::timestamp', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_time SET NOT NULL', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_time SET DEFAULT now()', tbl_name);
    END IF;

    -- 4. update_user
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'update_user' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN update_user varchar(32)', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.update_user IS ''更新者''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_user TYPE varchar(32) USING update_user::varchar(32)', tbl_name);
    END IF;

    -- 5. del_flag → boolean
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'del_flag' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN del_flag boolean NOT NULL DEFAULT false', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.del_flag IS ''是否删除：false未删除；true删除''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag DROP DEFAULT;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag TYPE varchar(5);', tbl_name);
        EXECUTE format('UPDATE %I SET del_flag = CASE WHEN del_flag IN (''1'',''true'',''t'') THEN ''true'' ELSE ''false'' END WHERE del_flag IS NOT NULL;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag TYPE boolean USING del_flag::boolean;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag SET NOT NULL;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag SET DEFAULT false;', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.del_flag IS ''是否删除：false未删除；true删除''', tbl_name);
    END IF;
    RAISE NOTICE '✅ 表 % 公共字段处理完成', tbl_name;
END;
$$ LANGUAGE plpgsql;

-- =============================================
------------------------------------------------------------------------------------------ 函数：char 直接改为 varchar(32) + 清除字符串前后空格
-- =============================================
DROP FUNCTION IF EXISTS lx_gis_string_columns_varchar(text);

CREATE OR REPLACE FUNCTION lx_gis_string_columns_varchar(p_table_name text)
RETURNS void AS $$
DECLARE
    rec record;
BEGIN
    -- 1. 直接把所有 char 类型 → varchar(32)
    FOR rec IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = p_table_name
          AND data_type = 'character'  -- 只处理char
    LOOP
        EXECUTE format(
            'ALTER TABLE %I ALTER COLUMN %I TYPE varchar(32)',
            p_table_name, rec.column_name
        );
        RAISE NOTICE '✅ 字段 % 已从 char 直接改为 varchar(32)', rec.column_name;
    END LOOP;

    -- 2. 清除所有字符串字段前后空格
    FOR rec IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = p_table_name
          AND data_type IN ('character varying', 'text')
    LOOP
        EXECUTE format(
            'UPDATE %I SET %I = trim(%I) WHERE %I IS NOT NULL',
            p_table_name, rec.column_name, rec.column_name, rec.column_name
        );
    END LOOP;

    RAISE NOTICE '==================================================';
    RAISE NOTICE '✅ 表 % 处理完成：char→varchar(32)，空格已清除', p_table_name;
    RAISE NOTICE '==================================================';
END;
$$ LANGUAGE plpgsql;
 

-- =============================================
-- 批量执行所有表
-- =============================================
 
SELECT lx_gis_base_common_columns('bo_electric_fence');
SELECT lx_gis_base_common_columns('bo_time_plan');
SELECT lx_gis_base_common_columns('bo_ground_ele');

 

 
SELECT lx_gis_string_columns_varchar('bo_electric_fence');
SELECT lx_gis_string_columns_varchar('bo_time_plan');
SELECT lx_gis_string_columns_varchar('bo_ground_ele');












------------------------------------------------------------------------------------------空间数据创建


 -- 安装 PostGIS 空间扩展
CREATE EXTENSION IF NOT EXISTS postgis;

-- =============================================
-- 清理旧字段 
-- =============================================
DROP INDEX IF EXISTS idx_bo_electric_fence_geom_3d;
ALTER TABLE bo_electric_fence DROP COLUMN IF EXISTS geom_3d;
DROP INDEX IF EXISTS idx_bo_electric_fence_geom;
ALTER TABLE bo_electric_fence DROP COLUMN IF EXISTS geom;


-- 创建 3D 几何字段（字段名固定为 geom）
ALTER TABLE bo_electric_fence ADD COLUMN IF NOT EXISTS geom geometry(POLYGONZ, 4326);
-- =============================================
-- 创建空间索引（名称固定为 idx_bo_electric_fence_geom）
-- =============================================
CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_geom ON bo_electric_fence USING GIST (geom);

-- =============================================
-- 直接生成 3D 空间数据（自动补 Z=0，一步到位，不报错）
-- =============================================
UPDATE bo_electric_fence
SET geom = ST_SetSRID(
    ST_Force3D(
        ST_GeomFromGeoJSON( (lng_lat_alt::json ->> 'geometry')::text )
    ),
    4326
)
WHERE
    lng_lat_alt IS NOT NULL
    AND ST_GeometryType( ST_GeomFromGeoJSON( (lng_lat_alt::json ->> 'geometry')::text ) )
        IN ('ST_Polygon', 'ST_MultiPolygon');
				 
-- 给 geom 字段添加注释 
COMMENT ON COLUMN bo_electric_fence.geom IS '空间数据';

-- 查询
-- SELECT * FROM bo_electric_fence
  
-- 删除无效空数据 
DELETE FROM bo_electric_fence WHERE lng_lat_alt IS NULL;
DELETE FROM bo_electric_fence WHERE geom IS NULL;


-- -- 查询电子围栏，并把 3D geom 转成 2D 显示
-- SELECT 
--     id,
--     name,
--     -- 核心：3D 转 2D 函数
--     ST_AsText( ST_Force2D(geom) ) AS geom_2d,
--     -- 保留原始 3D 方便对比
--     ST_AsText(geom) AS geom_3d
-- FROM bo_electric_fence;



-- 安装 PostGIS
CREATE EXTENSION IF NOT EXISTS postgis;

-- 删除旧字段
ALTER TABLE bo_ground_ele DROP COLUMN IF EXISTS geom;
ALTER TABLE bo_ground_ele DROP COLUMN IF EXISTS geom_3d;

-- 创建通用空间字段（兼容 点 Point、线 Line、面 Polygon）
ALTER TABLE bo_ground_ele ADD COLUMN IF NOT EXISTS geom geometry(GeometryZ, 4326);

-- 空间索引
CREATE INDEX IF NOT EXISTS idx_bo_ground_ele_geom
ON bo_ground_ele USING GIST (geom);

-- 生成 3D 空间数据（兼容点、线、面，不报错）
UPDATE bo_ground_ele
SET geom = ST_SetSRID(
    ST_Force3D(
        ST_GeomFromGeoJSON(
            regexp_replace(
                lng_lat_alt::text,
                '(\d)\s+(-?\d)',
                '\1,\2',
                'g'
            )::json ->> 'geometry'
        )
    ),
    4326
)
WHERE
    lng_lat_alt IS NOT NULL
    AND lng_lat_alt <> ''
    AND lng_lat_alt ~ '^\{.*\}$';

-- 给 geom 加注释：空间数据
COMMENT ON COLUMN bo_ground_ele.geom IS '空间数据';

-- 清理无效数据
DELETE FROM bo_ground_ele WHERE lng_lat_alt IS NULL;
DELETE FROM bo_ground_ele WHERE geom IS NULL;
-- =============================================
--  清理lng_lat_alt 
ALTER TABLE bo_ground_ele DROP COLUMN IF EXISTS lng_lat_alt;

-- =============================================
--  查看最终结果（2D 空间数据） 
SELECT 
    id,
    ST_AsText(geom) AS 二维空间数据,
    ST_GeometryType(geom) AS 几何类型
FROM bo_ground_ele;


------------------------------------------------------------------------------------------ --   Navicat同步数据
-- 电子围栏数据迁移
-- 同步 bo_electric_fence（电子围栏信息）、 bo_time_plan （定时录像计划表）表所有数据
-- 
-- 静态标注数据迁移
-- 同步 bo_ground_ele（地物标注信息）表所有数据

-- 打开 Navicat，同时连接：
-- MySQL：192.168.110.6:3307，库 ktd_lx_2026dev
-- PG：192.168.110.6:5432，库 ktd_lx_2026gis
-- 菜单栏 → 工具 → 数据传输
-- 源：选 MySQL 的 ktd_lx_2026dev
-- 目标：选 PG 的 ktd_lx_2026gis
-- 勾选要迁移的 3 张表：
-- bo_electric_fence
-- bo_time_plan
-- bo_ground_ele
-- 选项里勾选：包含表结构、包含数据、主键索引可酌情不勾
-- 开始 → 执行完成即可。