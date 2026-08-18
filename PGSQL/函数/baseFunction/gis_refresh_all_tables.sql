-- =============================================================================
-- 文件：baseFunction/gis_refresh_all_tables.sql
-- 函数：public.gis_refresh_all_tables()
-- 功能：遍历所有用户表并执行 ANALYZE，刷新 PostgreSQL 查询统计信息。
-- 依赖：public.gis_drop_function(text)，执行本文件前请先执行 baseFunction/gis_drop_function.sql。
-- 入参：无。
-- 返回：integer，表示已执行 ANALYZE 的用户表数量。
-- 示例：SELECT public.gis_refresh_all_tables();
-- 说明：本文件末尾会直接执行 SELECT gis_refresh_all_tables();。
-- =============================================================================

 -- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_refresh_all_tables');

-- =============================================================================
-- 函数名称：gis_refresh_all_tables
-- 函数功能：刷新所有用户表统计信息
-- 入参说明：无参数。
-- 返回说明：返回 integer，表示本次执行 ANALYZE 的用户表数量。
-- 处理规则：
--   1. 遍历 pg_tables 中非系统 schema 的用户表。
--   2. 跳过 pg_catalog、information_schema 和 pg_% schema。
--   3. 对每张用户表执行 ANALYZE schema.table。
-- 逻辑步骤：
--   1. 初始化刷新计数 v_count。
--   2. 从 pg_tables 查询所有非系统 schema 的用户表。
--   3. 按 schema/table 顺序逐表执行 ANALYZE。
--   4. 每成功处理一张表，输出 NOTICE 并累计 v_count。
--   5. 返回本次执行 ANALYZE 的表数量。
-- 使用示例：
--   SELECT public.gis_refresh_all_tables();
-- 注意事项：
--   本文件末尾会直接执行 SELECT gis_refresh_all_tables();。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_refresh_all_tables()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    v_count integer := 0;
BEGIN
    -- 步骤 1：从 pg_tables 获取所有需要刷新统计信息的用户表。
    FOR r IN (
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
          AND schemaname NOT LIKE 'pg_%'
        ORDER BY schemaname, tablename
    )
    LOOP
        -- 步骤 2：对当前用户表执行 ANALYZE。
        EXECUTE format('ANALYZE %I.%I', r.schemaname, r.tablename);
        -- 步骤 3：输出处理进度，并累加刷新数量。
        RAISE NOTICE '已分析: %.%', r.schemaname, r.tablename;
        v_count := v_count + 1;
    END LOOP;

    -- 步骤 4：返回本次完成 ANALYZE 的用户表数量。
    RETURN v_count;
END;
$$;
COMMENT ON FUNCTION public.gis_refresh_all_tables() IS '刷新所有用户表统计信息';

-- =============================================================================
-- 刷新所有用户表统计信息
-- =============================================================================
SELECT gis_refresh_all_tables();

-- =============================================================================
-- 调用示例
-- =============================================================================

-- 1. 手动刷新所有用户表统计信息
-- SELECT public.gis_refresh_all_tables();

-- 2. 查看执行后返回的刷新表数量
-- SELECT public.gis_refresh_all_tables() AS analyzed_table_count;
