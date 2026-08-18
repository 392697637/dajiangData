--   gis_refresh_all_tables               刷新所有用户表统计信息



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
