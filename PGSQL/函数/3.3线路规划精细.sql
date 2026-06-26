-- ==============================================
-- 100m 全局粗规划 + 20/30m 航线走廊精规划
-- 依赖：
--   1. 3.1 中的 gis_generate_3d_grid / gis_mark_electric_fence / gis_mark_buildings
--   2. 3.2 中的 gis_astar_3d_flight_plan / gis_linestring_length_m
-- 说明：
--   - 全局粗规划继续使用 gis_grid_nodes_<project_id>
--   - 精细规划只在粗航线 buffer 走廊内生成临时精细网格
--   - 精细网格表名：gis_grid_nodes_<project_id>_fine_<task_id>
-- ==============================================

CREATE EXTENSION IF NOT EXISTS postgis;


-- ============================================================
-- 1. 根据粗航线生成走廊精细网格
-- ============================================================
DROP FUNCTION IF EXISTS gis_generate_corridor_fine_grid(
    VARCHAR, GEOMETRY, NUMERIC, NUMERIC, INT, DOUBLE PRECISION, VARCHAR, BOOLEAN
);

CREATE OR REPLACE FUNCTION gis_generate_corridor_fine_grid(
    p_project_id VARCHAR,
    p_path_line GEOMETRY,
    p_min_alt NUMERIC,
    p_max_alt NUMERIC,
    p_resolution INT DEFAULT 30,
    p_corridor_width DOUBLE PRECISION DEFAULT 500,
    p_task_id VARCHAR DEFAULT NULL,
    p_drop_old BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_project_key TEXT;
    v_task_key TEXT;
    v_table TEXT;
    v_idx_prefix TEXT;
    v_table_regclass REGCLASS;
    v_corridor geometry(MultiPolygon,4326);
    v_min_lon DOUBLE PRECISION;
    v_max_lon DOUBLE PRECISION;
    v_min_lat DOUBLE PRECISION;
    v_max_lat DOUBLE PRECISION;
    v_mid_lat DOUBLE PRECISION;
    v_lon_meter DOUBLE PRECISION;
    step_lon DOUBLE PRECISION;
    step_lat DOUBLE PRECISION;
    step_alt DOUBLE PRECISION;
    v_lon_max_idx INT;
    v_lat_max_idx INT;
    v_alt_max_idx INT;
    v_estimated_count BIGINT;
    v_cnt BIGINT;
BEGIN
    code := 200;
    table_name := NULL;
    msg := '';
    count := 0;

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        msg := '项目ID不能为空';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_path_line IS NULL OR ST_IsEmpty(p_path_line) THEN
        code := 400;
        msg := '粗航线不能为空';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_resolution <= 0 OR p_corridor_width <= 0 THEN
        code := 400;
        msg := '分辨率和走廊宽度必须大于0';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_min_alt >= p_max_alt THEN
        code := 400;
        msg := '最小高度不能大于等于最大高度';
        RETURN NEXT;
        RETURN;
    END IF;

    v_project_key := regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_task_key := COALESCE(NULLIF(regexp_replace(COALESCE(p_task_id, ''), '[^0-9a-zA-Z_]', '', 'g'), ''), substr(md5(clock_timestamp()::text), 1, 12));
    -- PostgreSQL标识符最长63字节，精细表名用hash压缩，避免项目ID+任务ID过长被截断。
    v_table := 'gis_grid_nodes_fine_' || substr(md5(v_project_key || '_' || v_task_key), 1, 16);
    v_idx_prefix := 'idx_' || substr(md5(v_table), 1, 12);
    table_name := v_table;

    v_corridor := ST_Multi(ST_Buffer(ST_Force2D(ST_SetSRID(p_path_line, 4326))::geography, p_corridor_width)::geometry)::geometry(MultiPolygon,4326);

    SELECT
        ST_XMin(v_corridor),
        ST_XMax(v_corridor),
        ST_YMin(v_corridor),
        ST_YMax(v_corridor)
    INTO v_min_lon, v_max_lon, v_min_lat, v_max_lat;

    v_mid_lat := (v_min_lat + v_max_lat) / 2.0;
    v_lon_meter := 111320.0 * cos(radians(v_mid_lat));
    IF abs(v_lon_meter) < 1 THEN
        code := 400;
        msg := '区域纬度过高，无法生成精细网格';
        RETURN NEXT;
        RETURN;
    END IF;

    step_lat := p_resolution / 111320.0;
    step_lon := p_resolution / v_lon_meter;
    step_alt := p_resolution;

    v_lon_max_idx := floor((v_max_lon - v_min_lon) / step_lon)::INT;
    v_lat_max_idx := floor((v_max_lat - v_min_lat) / step_lat)::INT;
    v_alt_max_idx := floor((p_max_alt::DOUBLE PRECISION - p_min_alt::DOUBLE PRECISION) / step_alt)::INT;
    v_estimated_count := (v_lon_max_idx::BIGINT + 1) * (v_lat_max_idx::BIGINT + 1) * (v_alt_max_idx::BIGINT + 1);

    IF v_estimated_count > 30000000 THEN
        code := 400;
        msg := format('走廊精细网格预计 %s 条，超过3000万，请增大分辨率或缩小走廊宽度', v_estimated_count);
        count := v_estimated_count;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT to_regclass(format('%I.%I', current_schema(), v_table)) INTO v_table_regclass;
    IF v_table_regclass IS NOT NULL AND p_drop_old THEN
        EXECUTE format('DROP TABLE %s CASCADE;', v_table_regclass);
    ELSIF v_table_regclass IS NOT NULL THEN
        code := 200;
        msg := format('精细网格表已存在：%s', v_table);
        EXECUTE format('SELECT count(*) FROM %I', v_table) INTO count;
        RETURN NEXT;
        RETURN;
    END IF;

    EXECUTE format('
        CREATE UNLOGGED TABLE %I
        WITH (autovacuum_enabled = off) AS
        WITH lon_series AS (
            SELECT s_lon::INT AS x, ($1 + s_lon * $4)::DOUBLE PRECISION AS lon
            FROM generate_series(0, $10) s_lon
            WHERE ($1 + s_lon * $4) <= $7
        ),
        lat_series AS (
            SELECT s_lat::INT AS y, ($2 + s_lat * $5)::DOUBLE PRECISION AS lat
            FROM generate_series(0, $11) s_lat
            WHERE ($2 + s_lat * $5) <= $8
        ),
        xy_grid AS MATERIALIZED (
            SELECT
                x.x,
                y.y,
                x.lon,
                y.lat,
                ST_SetSRID(ST_MakePoint(x.lon, y.lat), 4326)::geometry(Point,4326) AS geom2d
            FROM lon_series x
            CROSS JOIN lat_series y
            WHERE ST_Covers($13::geometry, ST_SetSRID(ST_MakePoint(x.lon, y.lat), 4326))
        ),
        z_grid AS MATERIALIZED (
            SELECT s_alt::INT AS z, ($3 + s_alt * $6)::DOUBLE PRECISION AS alt
            FROM generate_series(0, $12) s_alt
            WHERE ($3 + s_alt * $6) <= $9
        )
        SELECT
            ((z.z::BIGINT * ($11::BIGINT + 1) + xy.y::BIGINT) * ($10::BIGINT + 1) + xy.x::BIGINT + 1) AS id,
            xy.x::INT,
            xy.y::INT,
            z.z::INT,
            xy.lon,
            xy.lat,
            z.alt,
            true::BOOLEAN AS is_flyable,
            NULL::VARCHAR(20) AS zone_type,
            0::INT AS block_mask,
            xy.geom2d,
            ST_SetSRID(ST_MakePoint(xy.lon, xy.lat, z.alt), 4326)::geometry(PointZ,4326) AS geom
        FROM xy_grid xy
        CROSS JOIN z_grid z
    ', v_table)
    USING v_min_lon, v_min_lat, p_min_alt,
          step_lon, step_lat, step_alt,
          v_max_lon, v_max_lat, p_max_alt,
          v_lon_max_idx, v_lat_max_idx, v_alt_max_idx,
          v_corridor;

    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    count := v_cnt;

    EXECUTE format('ALTER TABLE %I ALTER COLUMN id SET NOT NULL', v_table);
    EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I PRIMARY KEY (id)', v_table, v_table || '_pkey');
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I (x, y, z)', v_idx_prefix || '_xyz', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (x, y, z) WHERE is_flyable = true', v_idx_prefix || '_fly_xyz', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST(geom2d) WHERE z = 0', v_idx_prefix || '_geom2d_z0', v_table);
    EXECUTE format('ANALYZE %I', v_table);

    msg := format('走廊精细网格生成成功：%s，共 %s 条', v_table, v_cnt);
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_table;
    msg := '生成走廊精细网格失败：' || SQLERRM;
    count := 0;
    RETURN NEXT;
END;
$$;


-- ============================================================
-- 2. 对指定网格表做电子围栏打标
-- ============================================================
DROP FUNCTION IF EXISTS gis_mark_electric_fence_on_grid(VARCHAR, VARCHAR);

CREATE OR REPLACE FUNCTION gis_mark_electric_fence_on_grid(
    p_project_id VARCHAR,
    p_grid_table VARCHAR
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_grid_reg REGCLASS;
    v_project_key TEXT;
    v_project_fence_table TEXT;
    v_project_fence_reg REGCLASS;
    v_geom_col TEXT;
    v_extent box3d;
    v_updated BIGINT := 0;
    v_cleared BIGINT := 0;
BEGIN
    table_name := p_grid_table;
    SELECT to_regclass(format('%I.%I', current_schema(), p_grid_table)) INTO v_grid_reg;
    IF v_grid_reg IS NULL THEN
        code := 404;
        msg := format('网格表不存在：%s', p_grid_table);
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20)', p_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0', p_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true', p_grid_table);

    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = p_grid_table
          AND column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;

    DROP TABLE IF EXISTS tmp_fine_fence;
    CREATE TEMP TABLE tmp_fine_fence (
        id text,
        priority int,
        zone_type varchar(20),
        max_height double precision,
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    INSERT INTO tmp_fine_fence
    SELECT
        id::text,
        CASE fence_type WHEN '1' THEN 10 WHEN '2' THEN 20 WHEN '3' THEN 30 END,
        CASE fence_type WHEN '1' THEN '禁飞区' WHEN '2' THEN '管控区' WHEN '3' THEN '适飞区' END::varchar(20),
        NULLIF(COALESCE(height, 0), 0)::double precision,
        ST_SetSRID(ST_Force2D(geom), 4326)
    FROM bo_electric_fence
    WHERE del_flag = false
      AND status = '1'
      AND geom IS NOT NULL
      AND fence_type IN ('1','2','3')
      AND (COALESCE(p_project_id, '') = '' OR project_id::text = p_project_id::text);

    v_project_key := regexp_replace(COALESCE(p_project_id, ''), '[^0-9a-zA-Z_]', '', 'g');
    v_project_fence_table := 'gis_electric_fence_' || v_project_key;
    SELECT to_regclass(format('%I.%I', current_schema(), v_project_fence_table)) INTO v_project_fence_reg;
    IF v_project_fence_reg IS NOT NULL THEN
        EXECUTE format('
            INSERT INTO tmp_fine_fence
            SELECT
                id::text,
                CASE fence_type WHEN ''1'' THEN 10 WHEN ''2'' THEN 20 END,
                CASE fence_type WHEN ''1'' THEN ''禁飞区'' WHEN ''2'' THEN ''管控区'' END::varchar(20),
                NULL::double precision,
                ST_SetSRID(ST_Force2D(geom), 4326)
            FROM %s
            WHERE geom IS NOT NULL
              AND fence_type IN (''1'',''2'')
        ', v_project_fence_reg);
    END IF;

    CREATE INDEX IF NOT EXISTS idx_tmp_fine_fence_geom ON tmp_fine_fence USING GIST (geom4326);
    ANALYZE tmp_fine_fence;

    SELECT ST_Extent(geom4326) INTO v_extent FROM tmp_fine_fence;
    IF v_extent IS NULL THEN
        code := 200;
        msg := '无有效电子围栏';
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS tmp_fine_desired_zone;
    EXECUTE format('
        CREATE TEMP TABLE tmp_fine_desired_zone ON COMMIT DROP AS
        WITH xy_match AS MATERIALIZED (
            SELECT
                n.x,
                n.y,
                f.zone_type,
                f.max_height,
                f.priority,
                f.id AS fence_id
            FROM (
                SELECT DISTINCT x, y, %I AS geom2d
                FROM %I
                WHERE z = 0
                  AND %I && ST_MakeEnvelope($1, $2, $3, $4, 4326)
            ) n
            JOIN tmp_fine_fence f
              ON n.geom2d && f.geom4326
             AND ST_Intersects(n.geom2d, f.geom4326)
        )
        SELECT DISTINCT ON (n.id)
            n.id,
            xy.zone_type
        FROM %I n
        JOIN xy_match xy
          ON n.x = xy.x
         AND n.y = xy.y
        WHERE xy.max_height IS NULL
           OR n.alt <= xy.max_height
        ORDER BY n.id, xy.priority, xy.fence_id
    ', v_geom_col, p_grid_table, v_geom_col, p_grid_table)
    USING ST_XMin(v_extent), ST_YMin(v_extent), ST_XMax(v_extent), ST_YMax(v_extent);

    CREATE INDEX IF NOT EXISTS idx_tmp_fine_desired_zone_id ON tmp_fine_desired_zone(id);
    ANALYZE tmp_fine_desired_zone;

    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = t.zone_type,
            block_mask = CASE
                WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN COALESCE(n.block_mask, 0) | 1
                ELSE COALESCE(n.block_mask, 0) & ~1
            END,
            is_flyable = CASE
                WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN false
                ELSE ((COALESCE(n.block_mask, 0) & ~1) = 0)
            END
        FROM tmp_fine_desired_zone t
        WHERE n.id = t.id
    ', p_grid_table);
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = NULL,
            block_mask = COALESCE(n.block_mask, 0) & ~1,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~1) = 0)
        WHERE (n.zone_type IS NOT NULL OR (COALESCE(n.block_mask, 0) & 1) <> 0)
          AND NOT EXISTS (SELECT 1 FROM tmp_fine_desired_zone t WHERE t.id = n.id)
    ', p_grid_table);
    GET DIAGNOSTICS v_cleared = ROW_COUNT;

    code := 200;
    count := v_updated + v_cleared;
    msg := format('精细网格电子围栏打标完成，更新 %s 条，清空 %s 条', v_updated, v_cleared);
    RETURN NEXT;
END;
$$;


-- ============================================================
-- 3. 对指定网格表做建筑打标，支持 buffer 防漏标
-- ============================================================
DROP FUNCTION IF EXISTS gis_mark_buildings_on_grid(VARCHAR, VARCHAR, DOUBLE PRECISION);

CREATE OR REPLACE FUNCTION gis_mark_buildings_on_grid(
    p_project_id VARCHAR,
    p_grid_table VARCHAR,
    p_building_buffer DOUBLE PRECISION DEFAULT 0
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_project_key TEXT;
    v_building_table TEXT;
    v_grid_reg REGCLASS;
    v_building_reg REGCLASS;
    v_geom_col TEXT;
    v_updated BIGINT := 0;
    v_cleared BIGINT := 0;
BEGIN
    table_name := p_grid_table;
    v_project_key := regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_building_table := 'gis_buildings_' || v_project_key;

    SELECT to_regclass(format('%I.%I', current_schema(), p_grid_table)) INTO v_grid_reg;
    SELECT to_regclass(format('%I.%I', current_schema(), v_building_table)) INTO v_building_reg;
    IF v_grid_reg IS NULL THEN
        code := 404;
        msg := format('网格表不存在：%s', p_grid_table);
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;
    IF v_building_reg IS NULL THEN
        code := 404;
        msg := format('建筑表不存在：%s', v_building_table);
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0', p_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true', p_grid_table);

    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = p_grid_table
          AND column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;

    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (geom gist_geometry_ops_2d)',
                   'idx_' || substr(md5(v_building_table), 1, 12) || '_geom',
                   v_building_table);

    DROP TABLE IF EXISTS tmp_fine_building_hit;
    EXECUTE format('
        CREATE TEMP TABLE tmp_fine_building_hit ON COMMIT DROP AS
        WITH buildings AS MATERIALIZED (
            SELECT
                COALESCE(id::text, gid::text) AS building_id,
                CASE WHEN COALESCE(height, 0) > 0 THEN height::double precision ELSE 5::double precision END AS max_height,
                CASE
                    WHEN $1 > 0 THEN ST_Buffer(ST_SetSRID(ST_Force2D(geom), 4326)::geography, $1)::geometry
                    ELSE ST_SetSRID(ST_Force2D(geom), 4326)
                END AS geom2d
            FROM %I
            WHERE geom IS NOT NULL
        ),
        xy_match AS MATERIALIZED (
            SELECT DISTINCT ON (n.x, n.y)
                n.x,
                n.y,
                b.building_id,
                b.max_height
            FROM (
                SELECT DISTINCT x, y, %I AS geom2d
                FROM %I
                WHERE z = 0
            ) n
            JOIN buildings b
              ON n.geom2d && b.geom2d
             AND ST_Intersects(n.geom2d, b.geom2d)
            ORDER BY n.x, n.y, b.max_height DESC, b.building_id
        )
        SELECT n.id
        FROM %I n
        JOIN xy_match xy
          ON n.x = xy.x
         AND n.y = xy.y
        WHERE n.alt <= xy.max_height
    ', v_building_table, v_geom_col, p_grid_table, p_grid_table)
    USING p_building_buffer;

    CREATE INDEX IF NOT EXISTS idx_tmp_fine_building_hit_id ON tmp_fine_building_hit(id);
    ANALYZE tmp_fine_building_hit;

    EXECUTE format('
        UPDATE %I n
        SET
            block_mask = COALESCE(n.block_mask, 0) | 2,
            is_flyable = false
        FROM tmp_fine_building_hit h
        WHERE n.id = h.id
    ', p_grid_table);
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    EXECUTE format('
        UPDATE %I n
        SET
            block_mask = COALESCE(n.block_mask, 0) & ~2,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~2) = 0)
        WHERE (COALESCE(n.block_mask, 0) & 2) <> 0
          AND NOT EXISTS (SELECT 1 FROM tmp_fine_building_hit h WHERE h.id = n.id)
    ', p_grid_table);
    GET DIAGNOSTICS v_cleared = ROW_COUNT;

    code := 200;
    count := v_updated + v_cleared;
    msg := format('精细网格建筑打标完成，更新 %s 条，清空 %s 条', v_updated, v_cleared);
    RETURN NEXT;
END;
$$;


-- ============================================================
-- 4. 在指定网格表上做简化 A* 规划
-- ============================================================
DROP FUNCTION IF EXISTS gis_astar_3d_flight_plan_on_grid(
    VARCHAR, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR
);

CREATE OR REPLACE FUNCTION gis_astar_3d_flight_plan_on_grid(
    p_grid_table VARCHAR,
    p_start_lon DOUBLE PRECISION,
    p_start_lat DOUBLE PRECISION,
    p_start_alt DOUBLE PRECISION,
    p_end_lon DOUBLE PRECISION,
    p_end_lat DOUBLE PRECISION,
    p_end_alt DOUBLE PRECISION,
    p_safe_altitude DOUBLE PRECISION DEFAULT 120,
    p_height_mode DOUBLE PRECISION DEFAULT 0,
    p_force_gen BOOLEAN DEFAULT TRUE,
    p_project_id VARCHAR DEFAULT NULL,
    p_create_user VARCHAR DEFAULT NULL
) RETURNS SETOF gis_flight_paths
LANGUAGE plpgsql
AS $$
DECLARE
    v_grid_reg REGCLASS;
    v_start_pt geometry(PointZ,4326);
    v_end_pt geometry(PointZ,4326);
    v_start_id BIGINT;
    v_goal_id BIGINT;
    v_min_x INT;
    v_max_x INT;
    v_min_y INT;
    v_max_y INT;
    v_margin INT := 30;
    v_curr BIGINT;
    v_curr_x INT;
    v_curr_y INT;
    v_curr_z INT;
    v_curr_geom geometry(PointZ,4326);
    v_curr_g DOUBLE PRECISION;
    v_nid BIGINT;
    v_n_geom geometry(PointZ,4326);
    v_new_g DOUBLE PRECISION;
    v_loop INT := 0;
    v_found BOOLEAN := false;
    v_path_ids BIGINT[] := ARRAY[]::BIGINT[];
    v_current BIGINT;
    v_path_line geometry(LineStringZ,4326);
    v_final_line geometry(LineStringZ,4326);
    v_waypoints JSONB;
    v_smooth_waypoints JSONB;
    v_path_id INT;
BEGIN
    SELECT to_regclass(format('%I.%I', current_schema(), p_grid_table)) INTO v_grid_reg;
    IF v_grid_reg IS NULL THEN
        RAISE EXCEPTION '网格表不存在：%', p_grid_table;
    END IF;

    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);

    EXECUTE format('SELECT id FROM %I WHERE is_flyable = true ORDER BY geom <-> $1 LIMIT 1', p_grid_table)
    INTO v_start_id USING v_start_pt;
    EXECUTE format('SELECT id FROM %I WHERE is_flyable = true ORDER BY geom <-> $1 LIMIT 1', p_grid_table)
    INTO v_goal_id USING v_end_pt;

    IF v_start_id IS NULL OR v_goal_id IS NULL THEN
        RAISE EXCEPTION '精细网格中找不到可飞起点或终点';
    END IF;

    EXECUTE format('SELECT x FROM %I WHERE id = $1', p_grid_table) INTO v_min_x USING v_start_id;
    EXECUTE format('SELECT x FROM %I WHERE id = $1', p_grid_table) INTO v_max_x USING v_goal_id;
    EXECUTE format('SELECT y FROM %I WHERE id = $1', p_grid_table) INTO v_min_y USING v_start_id;
    EXECUTE format('SELECT y FROM %I WHERE id = $1', p_grid_table) INTO v_max_y USING v_goal_id;

    IF v_min_x > v_max_x THEN v_min_x := v_min_x + v_max_x; v_max_x := v_min_x - v_max_x; v_min_x := v_min_x - v_max_x; END IF;
    IF v_min_y > v_max_y THEN v_min_y := v_min_y + v_max_y; v_max_y := v_min_y - v_max_y; v_min_y := v_min_y - v_max_y; END IF;

    DROP TABLE IF EXISTS tmp_fine_astar_grid;
    EXECUTE format('
        CREATE TEMP TABLE tmp_fine_astar_grid ON COMMIT DROP AS
        SELECT
            id::BIGINT,
            x,
            y,
            z,
            geom,
            true AS is_walkable,
            1e100::DOUBLE PRECISION AS g_cost,
            1e100::DOUBLE PRECISION AS f_cost,
            NULL::BIGINT AS parent_id,
            false AS closed
        FROM %I
        WHERE is_flyable = true
          AND x BETWEEN $1 AND $2
          AND y BETWEEN $3 AND $4
    ', p_grid_table)
    USING v_min_x - v_margin, v_max_x + v_margin, v_min_y - v_margin, v_max_y + v_margin;

    CREATE UNIQUE INDEX IF NOT EXISTS idx_tmp_fine_astar_grid_id ON tmp_fine_astar_grid(id);
    CREATE INDEX IF NOT EXISTS idx_tmp_fine_astar_grid_xyz ON tmp_fine_astar_grid(x, y, z);
    CREATE INDEX IF NOT EXISTS idx_tmp_fine_astar_grid_open ON tmp_fine_astar_grid(f_cost) WHERE closed = false;
    ANALYZE tmp_fine_astar_grid;

    UPDATE tmp_fine_astar_grid
    SET g_cost = 0,
        f_cost = ST_3DDistance(geom, v_end_pt)
    WHERE id = v_start_id;

    WHILE v_loop < 80000 LOOP
        v_loop := v_loop + 1;

        SELECT id, x, y, z, geom, g_cost
        INTO v_curr, v_curr_x, v_curr_y, v_curr_z, v_curr_geom, v_curr_g
        FROM tmp_fine_astar_grid
        WHERE closed = false
        ORDER BY f_cost
        LIMIT 1;

        IF v_curr IS NULL THEN
            EXIT;
        END IF;

        IF v_curr = v_goal_id THEN
            v_found := true;
            EXIT;
        END IF;

        UPDATE tmp_fine_astar_grid SET closed = true WHERE id = v_curr;

        FOR v_nid, v_n_geom IN
            SELECT n.id, n.geom
            FROM tmp_fine_astar_grid n
            WHERE n.closed = false
              AND n.x BETWEEN v_curr_x - 1 AND v_curr_x + 1
              AND n.y BETWEEN v_curr_y - 1 AND v_curr_y + 1
              AND n.z BETWEEN v_curr_z - 1 AND v_curr_z + 1
              AND n.id <> v_curr
        LOOP
            v_new_g := v_curr_g + ST_3DDistance(v_curr_geom, v_n_geom);
            UPDATE tmp_fine_astar_grid
            SET
                g_cost = v_new_g,
                f_cost = v_new_g + ST_3DDistance(v_n_geom, v_end_pt),
                parent_id = v_curr
            WHERE id = v_nid
              AND v_new_g < g_cost;
        END LOOP;
    END LOOP;

    IF NOT v_found THEN
        v_path_line := ST_MakeLine(v_start_pt, v_end_pt);
        v_final_line := v_path_line;
    ELSE
        v_current := v_goal_id;
        WHILE v_current IS NOT NULL LOOP
            v_path_ids := array_prepend(v_current, v_path_ids);
            SELECT parent_id INTO v_current FROM tmp_fine_astar_grid WHERE id = v_current;
        END LOOP;

        v_path_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
        v_path_line := ST_AddPoint(v_path_line, v_start_pt);
        v_path_line := ST_AddPoint(v_path_line, ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326));

        FOR v_loop IN 1..COALESCE(array_length(v_path_ids, 1), 0) LOOP
            SELECT ST_AddPoint(
                v_path_line,
                ST_SetSRID(ST_MakePoint(ST_X(geom), ST_Y(geom), p_safe_altitude), 4326)
            )
            INTO v_path_line
            FROM tmp_fine_astar_grid
            WHERE id = v_path_ids[v_loop];
        END LOOP;

        v_path_line := ST_AddPoint(v_path_line, ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326));
        v_path_line := ST_AddPoint(v_path_line, v_end_pt);
        v_final_line := v_path_line;
    END IF;

    SELECT jsonb_agg(jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom)) ORDER BY (dp).path[1])
    INTO v_waypoints
    FROM ST_DumpPoints(v_path_line) AS dp;

    SELECT jsonb_agg(jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom)) ORDER BY (dp).path[1])
    INTO v_smooth_waypoints
    FROM ST_DumpPoints(v_final_line) AS dp;

    INSERT INTO gis_flight_paths (
        project_id, create_user, update_user,
        start_point, end_point, safe_altitude,
        path_line, smooth_path_line,
        waypoints, smooth_waypoints, total_distance, smooth_ratio
    ) VALUES (
        p_project_id, p_create_user, p_create_user,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_path_line, v_final_line,
        v_waypoints, v_smooth_waypoints,
        gis_linestring_length_m(v_final_line), p_height_mode
    ) RETURNING id INTO v_path_id;

    RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_path_id;
END;
$$;


-- ============================================================
-- 5. 两阶段规划总控函数
-- ============================================================
DROP FUNCTION IF EXISTS gis_astar_3d_flight_plan_fine(
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    INT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, BOOLEAN
);

CREATE OR REPLACE FUNCTION gis_astar_3d_flight_plan_fine(
    p_start_lon DOUBLE PRECISION,
    p_start_lat DOUBLE PRECISION,
    p_start_alt DOUBLE PRECISION,
    p_end_lon DOUBLE PRECISION,
    p_end_lat DOUBLE PRECISION,
    p_end_alt DOUBLE PRECISION,
    p_safe_altitude DOUBLE PRECISION DEFAULT 120,
    p_height_mode DOUBLE PRECISION DEFAULT 0,
    p_coarse_resolution DOUBLE PRECISION DEFAULT 100,
    p_fine_resolution INT DEFAULT 30,
    p_corridor_width DOUBLE PRECISION DEFAULT 500,
    p_building_buffer DOUBLE PRECISION DEFAULT 30,
    p_force_gen BOOLEAN DEFAULT TRUE,
    p_project_id VARCHAR DEFAULT NULL,
    p_create_user VARCHAR DEFAULT NULL,
    p_task_id VARCHAR DEFAULT NULL,
    p_drop_fine_grid BOOLEAN DEFAULT TRUE
) RETURNS SETOF gis_flight_paths
LANGUAGE plpgsql
AS $$
DECLARE
    v_coarse gis_flight_paths%ROWTYPE;
    v_fine gis_flight_paths%ROWTYPE;
    v_grid_result RECORD;
    v_mark_result RECORD;
    v_task_key TEXT;
    v_fine_table TEXT;
    v_path_line geometry(LineStringZ,4326);
BEGIN
    v_task_key := COALESCE(NULLIF(regexp_replace(COALESCE(p_task_id, ''), '[^0-9a-zA-Z_]', '', 'g'), ''), substr(md5(clock_timestamp()::text), 1, 12));

    -- 第一步：全局 100m 粗规划，使用 3.2 原函数和全局网格表
    SELECT *
    INTO v_coarse
    FROM gis_astar_3d_flight_plan(
        p_start_lon, p_start_lat, p_start_alt,
        p_end_lon, p_end_lat, p_end_alt,
        p_safe_altitude, p_height_mode,
        TRUE, p_project_id, p_create_user
    )
    LIMIT 1;

    IF v_coarse.id IS NULL THEN
        RAISE EXCEPTION '粗规划失败，无法生成精细走廊';
    END IF;

    v_path_line := COALESCE(v_coarse.smooth_path_line, v_coarse.path_line);
    IF v_path_line IS NULL OR ST_IsEmpty(v_path_line) THEN
        RAISE EXCEPTION '粗规划结果无有效航线';
    END IF;

    -- 第二步：根据粗航线 buffer 生成 20/30m 走廊精细网格
    SELECT *
    INTO v_grid_result
    FROM gis_generate_corridor_fine_grid(
        p_project_id,
        v_path_line,
        LEAST(p_start_alt, p_end_alt, 0),
        GREATEST(p_safe_altitude, p_start_alt, p_end_alt),
        p_fine_resolution,
        p_corridor_width,
        v_task_key,
        TRUE
    )
    LIMIT 1;

    IF v_grid_result.code <> 200 THEN
        RAISE EXCEPTION '精细网格生成失败：%', v_grid_result.msg;
    END IF;
    v_fine_table := v_grid_result.table_name;

    -- 第三步：精细网格打标
    SELECT * INTO v_mark_result FROM gis_mark_electric_fence_on_grid(p_project_id, v_fine_table) LIMIT 1;
    SELECT * INTO v_mark_result FROM gis_mark_buildings_on_grid(p_project_id, v_fine_table, p_building_buffer) LIMIT 1;

    -- 第四步：在精细网格上重新规划
    SELECT *
    INTO v_fine
    FROM gis_astar_3d_flight_plan_on_grid(
        v_fine_table,
        p_start_lon, p_start_lat, p_start_alt,
        p_end_lon, p_end_lat, p_end_alt,
        p_safe_altitude, p_height_mode,
        TRUE, p_project_id, p_create_user
    )
    LIMIT 1;

    IF p_drop_fine_grid AND v_fine_table IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', v_fine_table);
    END IF;

    RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_fine.id;

EXCEPTION WHEN OTHERS THEN
    IF p_drop_fine_grid AND v_fine_table IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', v_fine_table);
    END IF;

    RAISE NOTICE '精细规划失败，返回粗规划或直线兜底：%', SQLERRM;

    IF v_coarse.id IS NOT NULL THEN
        RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_coarse.id;
    ELSE
        RETURN QUERY
        SELECT *
        FROM gis_astar_3d_flight_plan(
            p_start_lon, p_start_lat, p_start_alt,
            p_end_lon, p_end_lat, p_end_alt,
            p_safe_altitude, p_height_mode,
            TRUE, p_project_id, p_create_user
        )
        LIMIT 1;
    END IF;
END;
$$;


-- 调用示例：
-- SELECT * FROM gis_astar_3d_flight_plan_fine(
--     112.80, 34.30, 0,
--     114.00, 34.80, 0,
--     120,
--     0,
--     100,
--     30,
--     500,
--     30,
--     true,
--     '2c95908e958f3b75019593551f520126',
--     'system',
--     'task001',
--     true
-- );
