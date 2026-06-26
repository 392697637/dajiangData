-- ==============================================
-- 其他常用SQL
-- 功能：快速删除三维网格表
-- 说明：
--   1. 固定表名手动删除，优先使用 DROP TABLE IF EXISTS。
--   2. 如果存在依赖对象需要一起删除，使用 CASCADE。
--   3. 如果表名由项目ID动态拼接，使用 DO + to_regclass + EXECUTE。
-- ==============================================


-- ===================== 方式1：固定表名快速删除 =====================
-- 表存在则删除，表不存在不报错；如果存在依赖对象，可能删除失败。
DROP TABLE IF EXISTS gis_grid_nodes_2c95908e958f3b75019593551f520126;


-- ===================== 方式2：固定表名级联删除 =====================
-- 删除表，并同时删除依赖该表的对象；测试环境或确认依赖可删除时使用。
DROP TABLE IF EXISTS gis_grid_nodes_2c95908e958f3b75019593551f520126 CASCADE;


-- ===================== 方式3：动态表名安全删除 =====================
-- 适用于函数、批处理、项目ID动态拼接表名的场景。
DO $$
DECLARE
    v_project_id TEXT := '2c95908e958f3b75019593551f520126';
    v_table TEXT;
    v_reg REGCLASS;
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


--使用 DO 块自动执行（立即生效）
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT schemaname, tablename
              FROM pg_tables
              WHERE tablename LIKE 'gis_electric_fence_%'
                AND schemaname NOT IN ('pg_catalog', 'information_schema'))
    LOOP
        EXECUTE format('ANALYZE %I.%I', r.schemaname, r.tablename);
        RAISE NOTICE '已分析: %.%', r.schemaname, r.tablename;
    END LOOP;
END;
$$;