-- =============================================================================
-- 文件：baseFunction/gis_drop_function.sql
-- 函数：public.gis_drop_function(p_function_name text)
-- 功能：按函数名删除同名函数及其所有重载，支持传入 schema.function_name。
-- 依赖：无；这是其他函数脚本常用的基础清理函数，应优先执行。
-- 入参：p_function_name，函数名，例如 'gis_refresh_all_tables' 或 'public.gis_refresh_all_tables'。
-- 返回：void。
-- 示例：SELECT public.gis_drop_function('gis_geojson_to_geom');
-- =============================================================================
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
-- 函数名称：gis_drop_function
-- 函数功能：按函数名删除同名函数及其所有重载
-- 入参说明：
--   1. p_function_name 支持不带 schema 的函数名，例如 'gis_geojson_to_geom'。
--   2. p_function_name 也支持 schema.function_name，例如 'public.gis_geojson_to_geom'。
-- 返回说明：无返回值；匹配到的函数会通过 DROP FUNCTION IF EXISTS ... CASCADE 删除。
-- 处理规则：
--   1. 入参为空时抛出异常。
--   2. 不带 schema 时删除所有 schema 下同名函数。
--   3. 带 schema 时只删除指定 schema 下的同名函数。
-- 逻辑步骤：
--   1. 校验 p_function_name 是否为空。
--   2. 判断入参是否包含 schema，并拆分 schema_name/function_name。
--   3. 查询 pg_proc 和 pg_namespace，找出匹配的函数及参数签名。
--   4. 循环执行 DROP FUNCTION IF EXISTS schema.function(args) CASCADE。
-- 使用示例：
--   SELECT public.gis_drop_function('gis_geojson_to_geom');
--   SELECT public.gis_drop_function('public.gis_geojson_to_geom');
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
    -- 步骤 1：校验入参，函数名不能为空。
    IF p_function_name IS NULL OR trim(p_function_name) = '' THEN
        RAISE EXCEPTION 'Function name cannot be empty';
    END IF;

    -- 步骤 2：判断是否传入 schema，并拆分 schema 与函数名。
    IF position('.' IN p_function_name) > 0 THEN
        v_schema_name := split_part(p_function_name, '.', 1);
        v_function_name := split_part(p_function_name, '.', 2);
    ELSE
        v_function_name := p_function_name;
    END IF;

    -- 步骤 3：从系统目录查询所有匹配的函数重载。
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
        -- 步骤 4：逐个重载函数执行 DROP FUNCTION。
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
-- 调用示例
-- =============================================================================

-- 1. 删除所有 schema 下同名函数
-- SELECT public.gis_drop_function('gis_geojson_to_geom');

-- 2. 只删除 public schema 下同名函数
-- SELECT public.gis_drop_function('public.gis_geojson_to_geom');

-- 3. 删除刷新统计信息函数
-- SELECT public.gis_drop_function('gis_refresh_all_tables');
