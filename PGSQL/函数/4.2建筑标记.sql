-- =============================================================================
-- 4.2建筑标记.sql
--   gis_mark_buildings  标记网格建筑物障碍
--
-- 说明：
--   本文件从 3.1新线路规划自动建表.sql 中拆分建筑相关逻辑。
--   依赖项目网格表 gis_grid_nodes_<project_id> 和建筑表 gis_buildings_<project_id>。
-- =============================================================================

SELECT gis_drop_function('gis_mark_buildings');

-- =============================================================================
-- 函数介绍：gis_mark_buildings
-- 主要作用：根据项目建筑表，把建筑占用范围标记到三维网格中，形成建筑障碍。
-- 入参说明：p_project_id 为项目ID；p_building_buffer 为建筑平面缓冲距离，单位米。
-- 返回说明：返回网格表名、更新数量和执行消息，供路径规划前确认建筑障碍数据。
-- 注意事项：依赖 gis_buildings_<project_id> 和 gis_grid_nodes_<project_id>；缓冲值可降低小建筑漏标风险。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_mark_buildings(
    p_project_id VARCHAR,
    p_building_buffer DOUBLE PRECISION DEFAULT 0
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_grid_table TEXT;
    v_building_table TEXT;
    v_grid_reg REGCLASS;
    v_building_reg REGCLASS;
    v_geom_col TEXT;
    v_updated_rows BIGINT := 0;
    v_cleared_rows BIGINT := 0;
    v_idx_prefix TEXT;
    v_building_idx_prefix TEXT;
    v_extent box3d;
    v_log_sql text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_mark_buildings(%L, %s);',
        p_project_id, COALESCE(p_building_buffer::text, 'NULL'));

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        table_name := NULL;
        msg := format('参数错误：项目ID不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    v_grid_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_building_table := 'gis_buildings_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    table_name := v_grid_table;
    v_idx_prefix := 'idx_' || substr(md5(v_grid_table), 1, 12);
    v_building_idx_prefix := 'idx_' || substr(md5(v_building_table), 1, 12);

    SELECT to_regclass(format('%I.%I', current_schema(), v_grid_table)) INTO v_grid_reg;
    SELECT to_regclass(format('%I.%I', current_schema(), v_building_table)) INTO v_building_reg;

    IF v_grid_reg IS NULL THEN
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', v_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_building_reg IS NULL THEN
        code := 400;
        msg := format('参数错误：建筑表不存在：%s，执行时间 %s 秒', v_building_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_grid_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;

    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0;', v_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true;', v_grid_table);
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (%I) WHERE z = 0;',
        v_idx_prefix || '_' || v_geom_col || '_z0',
        v_grid_table,
        v_geom_col
    );

    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (geom gist_geometry_ops_2d);',
                   v_building_idx_prefix || '_geom',
                   v_building_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (id);',
                   v_building_idx_prefix || '_id',
                   v_building_table);

    DROP TABLE IF EXISTS tmp_mark_building;
    EXECUTE format('
        CREATE TEMP TABLE tmp_mark_building ON COMMIT DROP AS
        SELECT
            COALESCE(id::text, gid::text) AS building_id,
            CASE WHEN COALESCE(height, 0) > 0 THEN height::double precision ELSE 5::double precision END AS max_height,
            CASE
                WHEN $1 > 0 THEN ST_Buffer(ST_SetSRID(ST_Force2D(geom), 4326)::geography, $1)::geometry(Geometry,4326)
                ELSE ST_SetSRID(ST_Force2D(geom), 4326)::geometry(Geometry,4326)
            END AS geom2d
        FROM %I
        WHERE geom IS NOT NULL
    ', v_building_table)
    USING GREATEST(COALESCE(p_building_buffer, 0), 0);

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_building_geom ON tmp_mark_building USING GIST (geom2d);
    CREATE INDEX IF NOT EXISTS idx_tmp_mark_building_height ON tmp_mark_building (max_height);
    ANALYZE tmp_mark_building;

    SELECT ST_Extent(geom2d) INTO v_extent FROM tmp_mark_building;

    IF v_extent IS NULL THEN
        EXECUTE format('
            UPDATE %I n
            SET
                block_mask = COALESCE(n.block_mask, 0) & ~2,
                is_flyable = ((COALESCE(n.block_mask, 0) & ~2) = 0)
            WHERE (COALESCE(n.block_mask, 0) & 2) <> 0
        ', v_grid_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

        count := v_cleared_rows;
        code := 200;
        msg := format('无有效建筑数据，已清空 %s 条建筑标记，执行时间 %s 秒',
            v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS tmp_mark_building_scope_xy;
    EXECUTE format('
        CREATE TEMP TABLE tmp_mark_building_scope_xy ON COMMIT DROP AS
        SELECT DISTINCT x, y, %I AS geom2d
        FROM %I
        WHERE z = 0
          AND %I && ST_MakeEnvelope($1, $2, $3, $4, 4326)
    ', v_geom_col, v_grid_table, v_geom_col)
    USING ST_XMin(v_extent), ST_YMin(v_extent), ST_XMax(v_extent), ST_YMax(v_extent);

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_building_scope_xy ON tmp_mark_building_scope_xy (x, y);
    CREATE INDEX IF NOT EXISTS idx_tmp_mark_building_scope_geom ON tmp_mark_building_scope_xy USING GIST (geom2d);
    ANALYZE tmp_mark_building_scope_xy;

    DROP TABLE IF EXISTS tmp_mark_building_xy;
    CREATE TEMP TABLE tmp_mark_building_xy ON COMMIT DROP AS
    SELECT DISTINCT ON (n.x, n.y)
        n.x,
        n.y,
        b.building_id,
        b.max_height
    FROM tmp_mark_building_scope_xy n
    JOIN tmp_mark_building b
      ON n.geom2d && b.geom2d
     AND ST_Intersects(n.geom2d, b.geom2d)
    ORDER BY n.x, n.y, b.max_height DESC, b.building_id;

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_building_xy ON tmp_mark_building_xy (x, y);
    ANALYZE tmp_mark_building_xy;

    DROP TABLE IF EXISTS tmp_mark_building_hit;
    EXECUTE format('
        CREATE TEMP TABLE tmp_mark_building_hit ON COMMIT DROP AS
        SELECT
            n.id,
            xy.building_id
        FROM %I n
        JOIN tmp_mark_building_xy xy
          ON n.x = xy.x
         AND n.y = xy.y
        WHERE n.alt <= xy.max_height
    ', v_grid_table);

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_building_hit_id ON tmp_mark_building_hit(id);
    ANALYZE tmp_mark_building_hit;

    EXECUTE format('
        UPDATE %I n
        SET
            block_mask = COALESCE(n.block_mask, 0) | 2,
            is_flyable = false
        FROM tmp_mark_building_hit h
        WHERE n.id = h.id
          AND (
              (COALESCE(n.block_mask, 0) & 2) = 0
              OR n.is_flyable IS DISTINCT FROM false
          )
    ', v_grid_table);
    GET DIAGNOSTICS v_updated_rows = ROW_COUNT;

    EXECUTE format('
        UPDATE %I n
        SET
            block_mask = COALESCE(n.block_mask, 0) & ~2,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~2) = 0)
        WHERE (COALESCE(n.block_mask, 0) & 2) <> 0
          AND NOT EXISTS (SELECT 1 FROM tmp_mark_building_hit h WHERE h.id = n.id)
    ', v_grid_table);
    GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

    count := v_updated_rows + v_cleared_rows;
    code := 200;
    msg := format('建筑打标完成，更新 %s 条，清空 %s 条，执行时间 %s 秒',
        v_updated_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_grid_table;
    msg := format('建筑打标失败：%s，执行时间 %s 秒',
        SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_mark_buildings(VARCHAR, DOUBLE PRECISION) IS '标记网格建筑物障碍';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- SELECT * FROM gis_mark_buildings('2c95908e958f3b75019593551f520126');
-- SELECT * FROM gis_mark_buildings('2c95908e958f3b75019593551f520126', 30);
