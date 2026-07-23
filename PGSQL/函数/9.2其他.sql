-- =============================================================================
-- 9.其他.sql
-- =============================================================================
-- 文件定位：
--   日常数据库维护、问题排查和临时清理脚本集合。
--
-- 主要内容：
--   1. 三维网格表清理
--   2. 统计信息刷新
--   3. 数据库连接监控
--   4. 数据库连接清理
--   5. UNLOGGED 表转换为 LOGGED 表
--
-- 使用提醒：
--   1. 本文件包含 DROP TABLE、pg_terminate_backend、ALTER TABLE SET LOGGED 等高影响操作。
--   2. 清理和终止连接类 SQL 默认放在尾部调用示例中，执行前请确认目标对象和业务影响。
--   3. ALTER TABLE ... SET LOGGED 会重写整张表，大表会比较慢，并会占用表锁，建议低峰期执行。
-- =============================================================================


-- =============================================================================
-- 1. 三维网格表清理
-- =============================================================================
-- 功能说明：
--   项目三维网格表按项目 ID 动态生成，表名规则通常为：
--     gis_grid_nodes_<project_id>
--   本节提供固定表名删除和动态项目 ID 删除两类写法。
--
-- 注意事项：
--   1. DROP TABLE 会永久删除目标表。
--   2. CASCADE 会同时删除依赖对象，仅在确认依赖可删除时使用。
--   3. 生产环境建议先执行 to_regclass 查询确认表名。

-- 查看项目网格表是否存在。
SELECT to_regclass('public.gis_grid_nodes_2c95908e958f3b75019593551f520126') AS grid_table_regclass;


-- =============================================================================
-- 2. 统计信息刷新
-- =============================================================================
-- 功能说明：
--   对动态生成的 GIS 表执行 ANALYZE，让 PostgreSQL 优化器拿到最新数据分布。
--   适合在大批量导入、网格生成、围栏打标后执行。
--
-- 注意事项：
--   1. ANALYZE 不修改业务数据。
--   2. 数据量较大时会消耗一定 IO，但通常风险较低。

-- 刷新所有 gis_electric_fence_ 前缀表的统计信息。
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

-- 刷新所有 gis_grid_nodes_ 前缀表的统计信息。
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN (
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE tablename LIKE 'gis_grid_nodes_%'
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
-- 功能说明：
--   查看当前连接、活跃 SQL、连接来源和空闲连接，用于排查慢 SQL、长连接和连接池异常。
--
-- 注意事项：
--   1. 本节只查询，不终止连接。
--   2. query 字段可能包含业务 SQL，导出或分享时注意敏感信息。

-- 查看当前数据库连接明细，按 SQL 执行时长倒序排列。
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
SELECT
    COUNT(*) AS 当前总连接数,
    current_setting('max_connections')::int AS 最大允许连接,
    ROUND(COUNT(*)::numeric / current_setting('max_connections')::int * 100, 2) AS 连接占用百分比
FROM pg_stat_activity;

-- 查看正在执行的 SQL，按运行时间倒序排列。
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
SELECT
    client_addr,
    COUNT(*) AS 连接数量
FROM pg_stat_activity
GROUP BY client_addr
ORDER BY 连接数量 DESC;

-- 查询空闲超过 30 分钟的连接，只查看不终止。
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
-- 功能说明：
--   终止空闲过久或执行过久的连接，用于处理异常连接、卡死 SQL 或连接池泄漏。
--
-- 注意事项：
--   1. pg_terminate_backend 会断开客户端连接或中断正在执行的 SQL。
--   2. 执行前建议先运行第 3 节对应查询确认 pid、客户端和 SQL 内容。
--   3. 默认排除当前会话：pid <> pg_backend_pid()。

-- 终止空闲超过 30 分钟的连接。
-- SELECT pg_terminate_backend(pid)
-- FROM pg_stat_activity
-- WHERE pid <> pg_backend_pid()
--   AND state = 'idle'
--   AND now() - state_change > INTERVAL '30 minutes';

-- 终止执行超过 30 分钟的活跃 SQL。
-- SELECT pg_terminate_backend(pid)
-- FROM pg_stat_activity
-- WHERE pid <> pg_backend_pid()
--   AND state = 'active'
--   AND now() - query_start > INTERVAL '30 minutes';


-- =============================================================================
-- 5. UNLOGGED 表转换为 LOGGED 表
-- =============================================================================
-- 功能说明：
--   查询并转换 public schema 下的 UNLOGGED 普通表。
--   UNLOGGED 表写入快，但 PostgreSQL 异常重启后数据可能被清空；LOGGED 表会写 WAL，数据更安全。
--
-- relpersistence 含义：
--   p = LOGGED 普通持久表
--   u = UNLOGGED 表
--   t = TEMP 临时表
--
-- 注意事项：
--   1. ALTER TABLE ... SET LOGGED 会重写整张表。
--   2. 转换大表期间会持有表锁，建议低峰期执行。
--   3. 如果只想转换网格表，把 WHERE 中增加：AND c.relname LIKE 'gis_grid_nodes_%'。

-- 查询 public 下所有 UNLOGGED 表。
SELECT
    c.relname AS table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relpersistence = 'u'
ORDER BY c.relname;

-- 将 public 下所有 UNLOGGED 表转换为 LOGGED 表。
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT
            n.nspname AS schema_name,
            c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind = 'r'
          AND c.relpersistence = 'u'
        ORDER BY c.relname
    LOOP
        RAISE NOTICE '正在转换 %.% 为 LOGGED', r.schema_name, r.table_name;

        EXECUTE format(
            'ALTER TABLE %I.%I SET LOGGED',
            r.schema_name,
            r.table_name
        );
    END LOOP;
END $$;

-- 转换后验证是否仍有 UNLOGGED 表。
SELECT
    c.relname AS table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relpersistence = 'u'
ORDER BY c.relname;


-- =============================================================================
-- 6. 项目电子围栏 MultiSurface 几何修复
-- =============================================================================
-- 功能说明：
--   部分导入或编辑后的电子围栏 geom 可能是 ST_MultiSurface。
--   某些 PostGIS 函数、GeoServer 渲染、空间分析或前端 GeoJSON 输出更适合使用 Polygon/MultiPolygon。
--   本节用于先检查 MultiSurface 数据，再把曲面几何转为线性 MultiPolygon 风格几何。
--
-- 处理逻辑：
--   1. ST_GeometryType(geom) = 'ST_MultiSurface' 用于筛选异常或不兼容的曲面几何。
--   2. ST_CurveToLine(geom) 把曲线/曲面边界线性化。
--   3. ST_Multi(...) 保持结果为 MULTI 几何，便于与项目电子围栏表的多面结构兼容。
--
-- 注意事项：
--   1. UPDATE 会修改 geom 字段，执行前建议先 SELECT 核对数据。
--   2. 示例中表名包含项目 ID，使用前请替换为目标项目表。
--   3. 如果表内有几何索引，更新后建议执行 ANALYZE，必要时重建空间索引。

-- 查询指定项目电子围栏表中 MultiSurface 类型的围栏，查看 ID、类型和 WKT。
SELECT id, ST_GeometryType(geom), ST_AsText(geom)
FROM public.gis_electric_fence_2c95908e958f3b75019593551f520126
WHERE ST_GeometryType(geom) = 'ST_MultiSurface';

-- 将指定项目电子围栏表中的 MultiSurface 转为线性 MULTI 几何，避免后续空间计算或渲染兼容问题。
UPDATE public.gis_electric_fence_2c95908e958f3b75019593551f520126
SET geom = ST_Multi(ST_CurveToLine(geom))
WHERE ST_GeometryType(geom) = 'ST_MultiSurface';


-- =============================================================================
-- 调用示例
-- =============================================================================

-- 示例1：固定表名快速删除三维网格表。
-- DROP TABLE IF EXISTS gis_grid_nodes_2c95908e958f3b75019593551f520126;

-- 示例2：固定表名级联删除三维网格表。
-- DROP TABLE IF EXISTS gis_grid_nodes_2c95908e958f3b75019593551f520126 CASCADE;

-- 示例3：动态项目表名安全删除三维网格表。
-- DO $$
-- DECLARE
--     v_project_id text := '2c95908e958f3b75019593551f520126';
--     v_table text;
--     v_reg regclass;
-- BEGIN
--     IF v_project_id IS NULL OR v_project_id = '' THEN
--         v_table := 'gis_grid_nodes';
--     ELSE
--         v_table := 'gis_grid_nodes_' || regexp_replace(v_project_id, '[^0-9a-zA-Z_]', '', 'g');
--     END IF;
--
--     SELECT to_regclass(format('%I.%I', current_schema(), v_table)) INTO v_reg;
--
--     IF v_reg IS NOT NULL THEN
--         RAISE NOTICE '准备删除表：%', v_reg;
--         EXECUTE format('DROP TABLE %s CASCADE;', v_reg);
--     ELSE
--         RAISE NOTICE '表不存在：%', v_table;
--     END IF;
-- END;
-- $$;

-- 示例4：只查询 GIS 网格相关 UNLOGGED 表。
-- SELECT
--     c.relname AS table_name
-- FROM pg_class c
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public'
--   AND c.relkind = 'r'
--   AND c.relpersistence = 'u'
--   AND c.relname LIKE 'gis_grid_nodes_%'
-- ORDER BY c.relname;

-- 示例5：只把 GIS 网格相关 UNLOGGED 表转换为 LOGGED 表。
-- DO $$
-- DECLARE
--     r record;
-- BEGIN
--     FOR r IN
--         SELECT
--             n.nspname AS schema_name,
--             c.relname AS table_name
--         FROM pg_class c
--         JOIN pg_namespace n ON n.oid = c.relnamespace
--         WHERE n.nspname = 'public'
--           AND c.relkind = 'r'
--           AND c.relpersistence = 'u'
--           AND c.relname LIKE 'gis_grid_nodes_%'
--         ORDER BY c.relname
--     LOOP
--         RAISE NOTICE '正在转换 %.% 为 LOGGED', r.schema_name, r.table_name;
--         EXECUTE format('ALTER TABLE %I.%I SET LOGGED', r.schema_name, r.table_name);
--     END LOOP;
-- END $$;

-- 示例6：刷新指定项目网格表统计信息。
-- ANALYZE public.gis_grid_nodes_2c95908e958f3b75019593551f520126;
