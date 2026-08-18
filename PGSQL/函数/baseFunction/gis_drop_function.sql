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