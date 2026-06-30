-- ==============================================
-- 100m 全局粗规划 + 20/30m 航线走廊精规划
-- 依赖：
--   1. 3.1 中的 gis_generate_3d_grid / gis_mark_electric_fence / gis_mark_buildings
--   2. 3.2 中的 gis_astar_3d_flight_plan / gis_linestring_length_m
-- 说明：
--   - 全局粗规划继续使用 gis_grid_nodes_<project_id>
--   - 精细规划只在粗航线 buffer 走廊内生成精细网格，避免全域 20/30m 数据量爆炸
--   - 精细网格是 UNLOGGED 实表，不是内存表；p_drop_fine_grid=true 时总控函数结束后删除
--   - 精细网格表名：gis_grid_nodes_fine_<16位hash>，避免项目ID过长导致 PostgreSQL 标识符截断冲突
--   - 本文件依赖 3.2 的 gis_astar_3d_flight_plan 新返回结构：code/msg + gis_flight_paths 字段
--
-- 返回策略：
--   code=200 表示函数正常完成。
--   code=400 表示输入参数非法。
--   code=500 表示执行过程中出现异常。
--   msg 中包含执行时间，以及具体执行说明。
-- ==============================================

CREATE EXTENSION IF NOT EXISTS postgis;


-- ============================================================
-- 1. gis_generate_corridor_fine_grid
--    根据粗航线生成走廊精细网格。
--    输入粗航线 LineStringZ、走廊宽度、垂直高度范围和精细分辨率。
--    返回精细网格表名，后续由围栏/建筑打标函数和精细 A* 使用。
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
    v_start_time timestamptz := clock_timestamp();
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
        msg := format('参数错误：项目ID不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_path_line IS NULL OR ST_IsEmpty(p_path_line) THEN
        code := 400;
        msg := format('参数错误：粗航线不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_resolution <= 0 OR p_corridor_width <= 0 THEN
        code := 400;
        msg := format('参数错误：分辨率和走廊宽度必须大于0，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_min_alt >= p_max_alt THEN
        code := 400;
        msg := format('参数错误：最小高度不能大于等于最大高度，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
        msg := format('参数错误：区域纬度过高，无法生成精细网格，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
        msg := format('参数错误：走廊精细网格预计 %s 条，超过3000万，请增大分辨率或缩小走廊宽度，执行时间 %s 秒', v_estimated_count, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := v_estimated_count;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT to_regclass(format('%I.%I', current_schema(), v_table)) INTO v_table_regclass;
    IF v_table_regclass IS NOT NULL AND p_drop_old THEN
        EXECUTE format('DROP TABLE %s CASCADE;', v_table_regclass);
    ELSIF v_table_regclass IS NOT NULL THEN
        code := 200;
        msg := format('精细网格表已存在：%s，执行时间 %s 秒', v_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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

    msg := format('走廊精细网格生成成功：%s，共 %s 条，执行时间 %s 秒', v_table, v_cnt, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_table;
    msg := format('生成走廊精细网格失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    RETURN NEXT;
END;
$$;


-- ============================================================
-- 2. gis_mark_electric_fence_on_grid
--    对指定网格表做电子围栏打标。
--
-- 适用场景：
--   精细网格表不是固定项目全局表，表名由 gis_generate_corridor_fine_grid 动态生成，
--   因此不能直接复用 3.1 中按 project_id 推导表名的 gis_mark_electric_fence。
--
-- 打标规则：
--   - bo_electric_fence 中 fence_type=1/2/3 分别映射为禁飞区/管控区/适飞区；
--   - 项目专属表 gis_electric_fence_<project_id> 中 fence_type=1/2 作为禁飞/管控；
--   - 禁飞区、管控区设置 block_mask 第1位，并让 is_flyable=false；
--   - 适飞区只写 zone_type，不清除其他来源造成的阻塞。
--
-- 性能策略：
--   先把有效围栏物化到临时表并建 GiST 索引，再按围栏范围裁剪 z=0 网格点。
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
    v_start_time timestamptz := clock_timestamp();
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
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', p_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
        msg := format('无有效电子围栏，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
    msg := format('精细网格电子围栏打标完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated, v_cleared, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;
END;
$$;


-- ============================================================
-- 3. gis_mark_buildings_on_grid
--    对指定精细网格表做建筑打标，支持 buffer 防漏标。
--
-- 参数说明：
--   p_project_id        项目ID，用于定位 gis_buildings_<project_id>。
--   p_grid_table        要打标的网格表名，通常是走廊精细网格。
--   p_building_buffer   建筑外扩距离，单位米；30m精细网格可取10~30，100m粗网格可取30~50。
--
-- 打标规则：
--   - 网格二维点落入建筑面，且网格 alt <= 建筑 height，则 block_mask | 2；
--   - height 为空或小于等于0时按 5m 默认高度处理；
--   - 清除不再命中的旧建筑阻塞位，并按剩余 block_mask 重算 is_flyable。
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
    v_start_time timestamptz := clock_timestamp();
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
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', p_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;
    IF v_building_reg IS NULL THEN
        code := 400;
        msg := format('参数错误：建筑表不存在：%s，执行时间 %s 秒', v_building_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
    msg := format('精细网格建筑打标完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated, v_cleared, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;
END;
$$;


-- ============================================================
-- 4. gis_astar_3d_flight_plan_on_grid
--    在指定网格表上做简化 A* 规划。
--
-- 与 3.2 的区别：
--   - 3.2 自动选择 gis_grid_nodes_<project_id> 或公共 gis_grid_nodes；
--   - 本函数显式接收 p_grid_table，因此可直接在走廊精细网格上规划；
--   - 本函数假设围栏/建筑等障碍已经被打标到 is_flyable/block_mask，
--     搜索阶段主要使用 is_flyable=true，不再重复扫描原始障碍表。
--
-- 结果：
--   规划结果写入 gis_flight_paths，并返回该航线记录。
--   如果没有找到精细路径，会退化为起点到终点的直线路径，保证总控函数有结果可返回。
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
) RETURNS TABLE (
    code integer,
    msg text,
    id integer,
    project_id char(32),
    create_user varchar(32),
    create_time timestamp,
    update_user varchar(32),
    update_time timestamp,
    del_flag boolean,
    start_point geometry(PointZ,4326),
    end_point geometry(PointZ,4326),
    safe_altitude double precision,
    path_line geometry(LineStringZ,4326),
    smooth_path_line geometry(LineStringZ,4326),
    waypoints jsonb,
    smooth_waypoints jsonb,
    total_distance double precision,
    smooth_ratio double precision
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_return_msg TEXT;
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
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', p_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_start_lon IS NULL OR p_start_lat IS NULL OR p_start_alt IS NULL
       OR p_end_lon IS NULL OR p_end_lat IS NULL OR p_end_alt IS NULL THEN
        code := 400;
        msg := format('参数错误：起点/终点经纬度和高度不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_safe_altitude IS NULL OR p_safe_altitude <= 0 THEN
        code := 400;
        msg := format('参数错误：安全高度必须大于0，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);

    EXECUTE format('SELECT id FROM %I WHERE is_flyable = true ORDER BY geom <-> $1 LIMIT 1', p_grid_table)
    INTO v_start_id USING v_start_pt;
    EXECUTE format('SELECT id FROM %I WHERE is_flyable = true ORDER BY geom <-> $1 LIMIT 1', p_grid_table)
    INTO v_goal_id USING v_end_pt;

    IF v_start_id IS NULL OR v_goal_id IS NULL THEN
        code := 400;
        msg := format('参数错误：精细网格中找不到可飞起点或终点，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
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

    UPDATE tmp_fine_astar_grid g
    SET g_cost = 0,
        f_cost = ST_3DDistance(g.geom, v_end_pt)
    WHERE g.id = v_start_id;

    WHILE v_loop < 80000 LOOP
        v_loop := v_loop + 1;

        SELECT g.id, g.x, g.y, g.z, g.geom, g.g_cost
        INTO v_curr, v_curr_x, v_curr_y, v_curr_z, v_curr_geom, v_curr_g
        FROM tmp_fine_astar_grid g
        WHERE g.closed = false
        ORDER BY g.f_cost
        LIMIT 1;

        IF v_curr IS NULL THEN
            EXIT;
        END IF;

        IF v_curr = v_goal_id THEN
            v_found := true;
            EXIT;
        END IF;

        UPDATE tmp_fine_astar_grid g SET closed = true WHERE g.id = v_curr;

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
            UPDATE tmp_fine_astar_grid g
            SET
                g_cost = v_new_g,
                f_cost = v_new_g + ST_3DDistance(v_n_geom, v_end_pt),
                parent_id = v_curr
            WHERE g.id = v_nid
              AND v_new_g < g.g_cost;
        END LOOP;
    END LOOP;

    IF NOT v_found THEN
        v_path_line := ST_MakeLine(v_start_pt, v_end_pt);
        v_final_line := v_path_line;
    ELSE
        v_current := v_goal_id;
        WHILE v_current IS NOT NULL LOOP
            v_path_ids := array_prepend(v_current, v_path_ids);
            SELECT g.parent_id INTO v_current FROM tmp_fine_astar_grid g WHERE g.id = v_current;
        END LOOP;

        v_path_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
        v_path_line := ST_AddPoint(v_path_line, v_start_pt);
        v_path_line := ST_AddPoint(v_path_line, ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326));

        IF COALESCE(array_length(v_path_ids, 1), 0) > 0 THEN
            FOR v_loop IN 1..array_length(v_path_ids, 1) LOOP
                SELECT ST_AddPoint(
                    v_path_line,
                    ST_SetSRID(ST_MakePoint(ST_X(g.geom), ST_Y(g.geom), p_safe_altitude), 4326)
                )
                INTO v_path_line
                FROM tmp_fine_astar_grid g
                WHERE g.id = v_path_ids[v_loop];
            END LOOP;
        END IF;

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
    ) RETURNING gis_flight_paths.id INTO v_path_id;

    v_return_msg := CASE
        WHEN v_found THEN format('精细网格A*规划完成，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
        ELSE format('精细网格未找到有效路径，已返回直线兜底航线，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
    END;
    RETURN QUERY SELECT 200, v_return_msg, p.* FROM gis_flight_paths p WHERE p.id = v_path_id;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
END;
$$;


-- ============================================================
-- 5. gis_astar_3d_flight_plan_fine
--    两阶段规划总控函数：100m全局粗规划 + 20/30m走廊精规划。
--
-- 执行流程：
--   1. 调用 3.2 的 gis_astar_3d_flight_plan 生成粗航线；
--   2. 对粗航线做 geography buffer，得到走廊面；
--   3. 在走廊内生成精细网格表；
--   4. 对精细网格做电子围栏和建筑打标；
--   5. 在精细网格上重新规划；
--   6. 按 p_drop_fine_grid 决定是否删除精细网格表。
--
-- 参数建议：
--   p_coarse_resolution  仅作为调用语义说明，实际粗网格分辨率由 3.1 已生成表决定。
--   p_fine_resolution    推荐 20 或 30；越小数据量越大。
--   p_corridor_width     推荐 300~800m；太窄可能粗航线附近无可行绕行空间。
--   p_drop_fine_grid     true=用完删除，适合一次性规划；false=保留表，方便排查或复用。
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
) RETURNS TABLE (
    code integer,
    msg text,
    id integer,
    project_id char(32),
    create_user varchar(32),
    create_time timestamp,
    update_user varchar(32),
    update_time timestamp,
    del_flag boolean,
    start_point geometry(PointZ,4326),
    end_point geometry(PointZ,4326),
    safe_altitude double precision,
    path_line geometry(LineStringZ,4326),
    smooth_path_line geometry(LineStringZ,4326),
    waypoints jsonb,
    smooth_waypoints jsonb,
    total_distance double precision,
    smooth_ratio double precision
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_coarse gis_flight_paths%ROWTYPE;
    v_fine gis_flight_paths%ROWTYPE;
    v_coarse_code INT;
    v_coarse_msg TEXT;
    v_fine_code INT;
    v_fine_msg TEXT;
    v_grid_result RECORD;
    v_mark_result RECORD;
    v_task_key TEXT;
    v_fine_table TEXT;
    v_path_line geometry(LineStringZ,4326);
BEGIN
    v_task_key := COALESCE(NULLIF(regexp_replace(COALESCE(p_task_id, ''), '[^0-9a-zA-Z_]', '', 'g'), ''), substr(md5(clock_timestamp()::text), 1, 12));

    -- 第一步：全局粗规划，使用 3.2 原函数和全局网格表。
    -- 3.2 返回 code/msg + gis_flight_paths 字段，这里显式接收，避免字段错位。
    SELECT
        r.code,
        r.msg,
        r.id, r.project_id, r.create_user, r.create_time,
        r.update_user, r.update_time, r.del_flag,
        r.start_point, r.end_point, r.safe_altitude,
        r.path_line, r.smooth_path_line,
        r.waypoints, r.smooth_waypoints,
        r.total_distance, r.smooth_ratio
    INTO
        v_coarse_code,
        v_coarse_msg,
        v_coarse.id, v_coarse.project_id, v_coarse.create_user, v_coarse.create_time,
        v_coarse.update_user, v_coarse.update_time, v_coarse.del_flag,
        v_coarse.start_point, v_coarse.end_point, v_coarse.safe_altitude,
        v_coarse.path_line, v_coarse.smooth_path_line,
        v_coarse.waypoints, v_coarse.smooth_waypoints,
        v_coarse.total_distance, v_coarse.smooth_ratio
    FROM gis_astar_3d_flight_plan(
        p_start_lon, p_start_lat, p_start_alt,
        p_end_lon, p_end_lat, p_end_alt,
        p_safe_altitude, p_height_mode,
        TRUE, p_project_id, p_create_user
    ) r
    LIMIT 1;

    IF v_coarse_code IS DISTINCT FROM 200 OR v_coarse.id IS NULL THEN
        RAISE EXCEPTION '粗规划失败，无法生成精细走廊：%', COALESCE(v_coarse_msg, '无返回结果');
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
    SELECT
        r.code,
        r.msg,
        r.id, r.project_id, r.create_user, r.create_time,
        r.update_user, r.update_time, r.del_flag,
        r.start_point, r.end_point, r.safe_altitude,
        r.path_line, r.smooth_path_line,
        r.waypoints, r.smooth_waypoints,
        r.total_distance, r.smooth_ratio
    INTO
        v_fine_code,
        v_fine_msg,
        v_fine.id, v_fine.project_id, v_fine.create_user, v_fine.create_time,
        v_fine.update_user, v_fine.update_time, v_fine.del_flag,
        v_fine.start_point, v_fine.end_point, v_fine.safe_altitude,
        v_fine.path_line, v_fine.smooth_path_line,
        v_fine.waypoints, v_fine.smooth_waypoints,
        v_fine.total_distance, v_fine.smooth_ratio
    FROM gis_astar_3d_flight_plan_on_grid(
        v_fine_table,
        p_start_lon, p_start_lat, p_start_alt,
        p_end_lon, p_end_lat, p_end_alt,
        p_safe_altitude, p_height_mode,
        TRUE, p_project_id, p_create_user
    ) r
    LIMIT 1;

    IF v_fine_code IS DISTINCT FROM 200 OR v_fine.id IS NULL THEN
        RAISE EXCEPTION '精细规划失败：%', COALESCE(v_fine_msg, '无返回结果');
    END IF;

    IF p_drop_fine_grid AND v_fine_table IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', v_fine_table);
    END IF;

    RETURN QUERY
    SELECT 200,
           format('两阶段精细规划完成：%s，执行时间 %s 秒', COALESCE(v_fine_msg, '精细规划成功'), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
           p.*
    FROM gis_flight_paths p
    WHERE p.id = v_fine.id;

EXCEPTION WHEN OTHERS THEN
    IF p_drop_fine_grid AND v_fine_table IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', v_fine_table);
    END IF;

    RAISE NOTICE '精细规划失败，返回粗规划或直线兜底：%', SQLERRM;

    IF v_coarse.id IS NOT NULL THEN
        RETURN QUERY
        SELECT 500,
               format('执行异常：%s，已返回粗规划兜底航线，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
               p.*
        FROM gis_flight_paths p
        WHERE p.id = v_coarse.id;
    ELSE
        RETURN QUERY
        SELECT
            500,
            format('执行异常：%s，已返回直线/粗规划兜底航线，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            r.id, r.project_id, r.create_user, r.create_time,
            r.update_user, r.update_time, r.del_flag,
            r.start_point, r.end_point, r.safe_altitude,
            r.path_line, r.smooth_path_line,
            r.waypoints, r.smooth_waypoints,
            r.total_distance, r.smooth_ratio
        FROM gis_astar_3d_flight_plan(
            p_start_lon, p_start_lat, p_start_alt,
            p_end_lon, p_end_lat, p_end_alt,
            p_safe_altitude, p_height_mode,
            TRUE, p_project_id, p_create_user
        ) r
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
