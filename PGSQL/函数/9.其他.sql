-- =============================================================================
-- 9.其他.sql
--   DROP TABLE                           快速删除测试/临时表
--   ANALYZE                              刷新指定表统计信息
--   pg_stat_activity                     查看数据库连接与SQL状态
--   pg_terminate_backend                 清理空闲或超时连接
--
-- 说明：用于日常数据库维护、问题排查和临时清理操作。
-- =============================================================================


-- =============================================================================
-- 1. 三维网格表清理
-- =============================================================================

-- 方式1：固定表名快速删除。
-- 表存在则删除，表不存在不报错；如果存在依赖对象，可能删除失败。
DROP TABLE IF EXISTS gis_grid_nodes_2c95908e958f3b75019593551f520126;


-- 方式2：固定表名级联删除。
-- 删除表，并同时删除依赖该表的对象；测试环境或确认依赖可删除时使用。
DROP TABLE IF EXISTS gis_grid_nodes_2c95908e958f3b75019593551f520126 CASCADE;


-- 方式3：动态项目表名安全删除。
-- 适用于项目ID动态拼接表名的场景，先判断表是否存在再删除。
DO $$
DECLARE
    v_project_id text := '2c95908e958f3b75019593551f520126';
    v_table text;
    v_reg regclass;
BEGIN
    IF v_project_id IS NULL OR v_project_id = '' THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(v_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;

    SELECT to_regclass(format('%I.%I', current_schema(), v_table)) INTO v_reg;

    IF v_reg IS NOT NULL THEN
        EXECUTE format('DROP TABLE %s CASCADE;', v_reg);
    END IF;
END;
$$;


-- =============================================================================
-- 2. 统计信息刷新
-- =============================================================================

-- 刷新所有 gis_electric_fence_ 前缀表的统计信息。
-- 用于让 PostgreSQL 优化器拿到最新数据分布，提升查询计划准确性。
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN (
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE tablename LIKE 'gis_electric_fence_%'
          AND schemaname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY schemaname, tablename
    )
    LOOP
        EXECUTE format('ANALYZE %I.%I', r.schemaname, r.tablename);
        RAISE NOTICE '已分析: %.%', r.schemaname, r.tablename;
    END LOOP;
END;
$$;


-- =============================================================================
-- 3. 数据库连接监控
-- =============================================================================

-- 查看当前数据库连接明细，按 SQL 执行时长倒序排列。
-- 用于排查慢 SQL、长连接、等待事件和客户端来源。
SELECT
    pid,
    usename AS 数据库用户名,
    datname AS 数据库名,
    client_addr AS 客户端IP,
    client_port AS 客户端端口,
    state AS 连接状态,
    now() - query_start AS sql执行时长,
    now() - state_change AS 空闲时长,
    wait_event_type,
    wait_event,
    query AS 当前执行SQL
FROM pg_stat_activity
ORDER BY sql执行时长 DESC;


-- 查看当前连接总数、最大连接数和连接占用百分比。
-- 用于判断连接池或应用连接是否接近数据库上限。
SELECT
    COUNT(*) AS 当前总连接数,
    current_setting('max_connections')::int AS 最大允许连接,
    ROUND(COUNT(*)::numeric / current_setting('max_connections')::int * 100, 2) AS 连接占用百分比
FROM pg_stat_activity;


-- 查看正在执行的 SQL，按运行时间倒序排列。
-- 用于快速定位当前仍在运行的长耗时 SQL。
SELECT
    pid,
    usename,
    datname,
    client_addr,
    now() - query_start AS run_time,
    query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY run_time DESC;


-- 按客户端 IP 统计连接数量。
-- 用于发现某个应用节点或客户端连接数异常偏高。
SELECT
    client_addr,
    COUNT(*) AS 连接数量
FROM pg_stat_activity
GROUP BY client_addr
ORDER BY 连接数量 DESC;


-- 查询空闲超过 30 分钟的连接。
-- 只查看不终止，适合先确认是否可以清理。
SELECT
    pid,
    usename,
    datname,
    client_addr,
    now() - state_change AS idle_duration,
    now() - query_start AS run_duration,
    state,
    query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND state = 'idle'
  AND now() - state_change > INTERVAL '30 minutes';


-- =============================================================================
-- 4. 数据库连接清理
-- =============================================================================

-- 终止空闲超过 30 分钟的连接。
-- 注意：会断开对应客户端连接，执行前建议先用上面的查询确认。
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND state = 'idle'
  AND now() - state_change > INTERVAL '30 minutes';


-- 终止执行超过 30 分钟的活跃 SQL。
-- 注意：会中断正在执行的业务 SQL，建议仅在确认异常时执行。
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND state = 'active'
  AND now() - query_start > INTERVAL '30 minutes';
