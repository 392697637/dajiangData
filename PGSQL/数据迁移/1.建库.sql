-- =============================================================================
-- 1.建库.sql
--   ktd_lx_2026gis                       创建GIS业务数据库
--   plpgsql/postgis/postgis_sfcgal       安装空间与过程语言扩展
--   timescaledb                          安装时序数据库扩展
--   gis_error_log                        创建PG相关GIS错误日志
--   gis_drop_function                    删除同名重载函数
--   gis_refresh_all_tables               刷新所有用户表统计信息
--
-- 说明：用于数据库初始化、基础扩展安装、错误日志表和通用工具函数创建。
-- =============================================================================

-- -- 强制断开所有连接 + 删除数据库
-- 
DROP DATABASE IF EXISTS ktd_lx_2026gis WITH (FORCE);

-- 创建空间时序数据库：ktd_lx_2026gis（适用于GIS+PostGIS+TimescaleDB场景）
CREATE DATABASE ktd_lx_2026gis
WITH 
ENCODING = 'UTF8'          -- 字符集编码为UTF8，支持中文、特殊字符，避免乱码
TEMPLATE = template0       -- 使用纯净系统模板template0，防止继承旧库配置，PostGIS建库必用
LC_COLLATE = ''            -- 排序规则使用模板默认（不指定则自动适配）
LC_CTYPE = ''             -- 字符分类规则使用模板默认
CONNECTION LIMIT = -1;     -- 数据库最大连接数不限制（-1代表无上限）

-- 切换到新数据库 ktd_lx_2026gis;

-- 开启必须扩展
 -- 加载PL/pgSQL过程语言（PostgreSQL默认内置函数语言，必装）
CREATE EXTENSION IF NOT EXISTS plpgsql;
-- PostGIS 空间地理扩展（Cesium三维GIS、地图、几何计算核心依赖）
CREATE EXTENSION IF NOT EXISTS postgis;          -- 基础PostGIS（点线面、坐标、空间索引）
CREATE EXTENSION IF NOT EXISTS postgis_topology; -- 拓扑结构支持（地理数据校验、空间关系）
CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;    -- 高级3D几何运算（Cesium 3D模型、体积计算）
-- TimescaleDB 时序数据库扩展（无人机、物联网高频采集数据存储、查询优化）
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- 验证扩展安装成功
SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name IN ('postgis','timescaledb');
-- 只查询 plpgsql、postgis、timescaledb 等核心扩展
SELECT 
  extname AS 扩展名称,
  extversion AS 版本号,
  CASE WHEN extname IS NOT NULL THEN '已安装' ELSE '未安装' END AS 状态
FROM pg_extension
WHERE extname IN (
  'plpgsql',
  'postgis',
  'postgis_topology',
  'postgis_sfcgal',
  'timescaledb'
)
ORDER BY extname;

-- public.spatial_ref_sys = PostGIS 的坐标系统字典表 **
-- 它存储了全世界所有的地图投影、坐标参考系（如 WGS84、GCJ-02、Web 墨卡托等），GIS 功能必须依赖它才
-- 查看全世界所有坐标系统（几千条）
SELECT * FROM spatial_ref_sys;
-- 查看我们最常用的 WGS84 经纬度坐标
SELECT * FROM spatial_ref_sys WHERE srid = 4326;
-- 查看 Cesium/地图常用的 Web墨卡托坐标
SELECT * FROM spatial_ref_sys WHERE srid = 3857;

-- 验证 PostGIS 空间插件是否正常安装并返回版本号
SELECT PostGIS_Version();

-- 启用 PostGIS 扩展（首次执行）
CREATE EXTENSION IF NOT EXISTS postgis;


-- =============================================================================
-- PG相关GIS错误日志
-- =============================================================================
DROP TABLE IF EXISTS public.gis_error_log;

CREATE TABLE IF NOT EXISTS public.gis_error_log (
    id bigserial PRIMARY KEY,
    code integer,
    msg text,
    sqlstring text,
    create_time timestamp without time zone DEFAULT now()
);
COMMENT ON TABLE public.gis_error_log IS 'PG相关GIS错误日志';
COMMENT ON COLUMN public.gis_error_log.id IS '日志主键ID';
COMMENT ON COLUMN public.gis_error_log.code IS '错误状态码：400=参数/业务错误，500=系统异常';
COMMENT ON COLUMN public.gis_error_log.msg IS '错误提示信息';
COMMENT ON COLUMN public.gis_error_log.sqlstring IS '触发错误时的SQL语句';
COMMENT ON COLUMN public.gis_error_log.create_time IS '日志创建时间';

CREATE INDEX IF NOT EXISTS idx_gis_error_log_create_time
ON public.gis_error_log(create_time DESC);
COMMENT ON INDEX public.idx_gis_error_log_create_time IS 'PG相关GIS错误日志创建时间倒序查询索引';




-- =============================================================================
-- 删除函数
-- =============================================================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc
              WHERE proname = 'gis_drop_function')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.oid::regproc || '(' || r.args || ') CASCADE';
    END LOOP;
END;
$$;
-- =============================================================================
-- 删除函数工具：传入函数名称，删除所有同名重载函数
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_drop_function(p_function_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    v_schema_name text;
    v_function_name text;
BEGIN
    IF p_function_name IS NULL OR trim(p_function_name) = '' THEN
        RAISE EXCEPTION 'Function name cannot be empty';
    END IF;

    IF position('.' IN p_function_name) > 0 THEN
        v_schema_name := split_part(p_function_name, '.', 1);
        v_function_name := split_part(p_function_name, '.', 2);
    ELSE
        v_function_name := p_function_name;
    END IF;

    FOR r IN (
        SELECT
            n.nspname AS schema_name,
            p.proname AS function_name,
            pg_get_function_identity_arguments(p.oid) AS function_args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname = v_function_name
          AND (v_schema_name IS NULL OR n.nspname = v_schema_name)
    )
    LOOP
        EXECUTE format(
            'DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE',
            r.schema_name,
            r.function_name,
            r.function_args
        );
    END LOOP;
END;
$$;
COMMENT ON FUNCTION gis_drop_function(text) IS '按名称删除同名重载函数';

 

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_refresh_all_tables');

-- =============================================================================
-- 刷新所有用户表统计信息
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_refresh_all_tables()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    v_count integer := 0;
BEGIN
    FOR r IN (
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
          AND schemaname NOT LIKE 'pg_%'
        ORDER BY schemaname, tablename
    )
    LOOP
        EXECUTE format('ANALYZE %I.%I', r.schemaname, r.tablename);
        RAISE NOTICE '已分析: %.%', r.schemaname, r.tablename;
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;
COMMENT ON FUNCTION public.gis_refresh_all_tables() IS '刷新所有用户表统计信息';

-- =============================================================================
-- 刷新所有用户表统计信息
-- =============================================================================
SELECT gis_refresh_all_tables();
