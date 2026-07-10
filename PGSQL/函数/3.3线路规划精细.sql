-- =============================================================================
-- 3.3线路规划精细.sql
--   gis_generate_corridor_fine_grid         生成航廊精细飞行网格
--   gis_mark_electric_fence_on_grid         标记精细网格电子围栏
--   gis_mark_buildings_on_grid              标记精细网格建筑障碍
--   gis_astar_3d_flight_plan_on_grid        指定网格精细避障寻路
--   gis_astar_3d_flight_plan_build          建筑避障精细航线规划
--
-- =============================================================================

-- ==============================================
-- 100m 全局粗规划 + 20m 航线矩形精规划
-- 依赖：
--   1. 3.1 中的 gis_generate_3d_grid / gis_mark_electric_fence / gis_mark_buildings
--   2. 3.2 中的 gis_astar_3d_flight_plan / gis_linestring_length_m
-- 说明：
--   - 全局粗规划继续使用 gis_grid_nodes_<project_id>
--   - 精细规划只在粗航线所有线路点外包矩形内生成精细网格，避免全域 20m 数据量爆炸
--   - 精细网格是 UNLOGGED 实表，不是内存表；p_drop_fine_grid=true 时总控函数结束后删除
--   - 精细网格表名：gis_grid_nodes_fine_<16位hash>，避免项目ID过长导致 PostgreSQL 标识符截断冲突
--   - 本文件依赖 3.2 的 gis_astar_3d_flight_plan 新返回结构：code/msg + gis_flight_paths 字段
--
-- 总体流程：
--   1. 先用 3.2 的 100m 全局网格跑一次粗 A*，拿到一条大概可行的粗航线。
--   2. 取粗航线所有线路点构成外包矩形，不再做 buffer 外扩。
--   3. 只在矩形范围内部生成 20m 精细三维网格，控制数据量。
--   4. 对这张临时/中间精细网格重新打电子围栏和建筑物阻塞标记。
--   5. 在精细网格上再跑一次 A*，得到更贴近障碍物边界的精细航线。
--
-- 重要字段约定：
--   is_flyable  = true 表示 A* 可以走这个网格点。
--   block_mask  使用二进制位记录阻塞来源：
--                 第 1 位，值 1：电子围栏造成阻塞；
--                 第 2 位，值 2：建筑物造成阻塞；
--                 后续如果增加障碍类型，可以继续用 4/8/16。
--   zone_type   记录围栏类型中文名，例如 禁飞区 / 管控区 / 适飞区。
--   geom2d      二维点，只用于平面相交、围栏、建筑判断，速度更快。
--   geom        三维点，用于 A* 距离计算和最终航线高度。
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
--    根据粗航线所有线路点外包矩形生成精细网格。
--    输入粗航线 LineStringZ、垂直高度范围和精细分辨率。
--    返回精细网格表名，后续由围栏/建筑打标函数和精细 A* 使用。
--
-- 参数说明：
--   p_project_id       项目ID。用于生成稳定表名；不能为空。
--   p_path_line        粗规划得到的航线，通常是 LineStringZ。函数会取整条线路的外包矩形。
--   p_min_alt          精细网格最低高度，单位米。通常取起终点高度和 0 的最小值。
--   p_max_alt          精细网格最高高度，单位米。通常取安全高度、起点高度、终点高度的最大值。
--   p_resolution       精细网格平面分辨率，单位米；默认 20。数值越小，网格越密，计算越慢。
--   p_task_id          任务ID。用于参与精细表名 hash；为空时自动生成随机 key。
--   p_drop_old         如果同名精细网格表已存在，true=先删除重建，false=直接复用旧表。
--
-- 返回字段：
--   code        200/400/500 状态码。
--   table_name  生成或复用的精细网格表名。
--   msg         执行说明和耗时。
--   count       生成的网格点数量；估算超限时返回预计数量。
-- ============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_generate_corridor_fine_grid');

-- =============================================================================
-- 函数介绍：gis_generate_corridor_fine_grid
-- 主要作用：沿粗规划航线生成走廊范围内的精细三维网格，用于二次精细避障。
-- 入参说明：包含项目ID、中心航线、高度范围、分辨率、任务标识和是否重建。
-- 返回说明：返回精细网格表名、生成数量和执行状态，供后续围栏和建筑标记使用。
-- 注意事项：只在粗航线所有线路点外包矩形内建网格，适合20米精细分辨率，避免全域高密度建表。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_generate_corridor_fine_grid(
    p_project_id VARCHAR,
    p_path_line GEOMETRY,
    p_min_alt NUMERIC,
    p_max_alt NUMERIC,
    p_resolution INT DEFAULT 20,
    p_task_id VARCHAR DEFAULT NULL,
    p_drop_old BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp(); -- 记录函数开始时间，用于返回 msg 中的耗时。
    v_project_key TEXT;                            -- 清洗后的项目ID，只保留字母、数字、下划线，避免动态表名非法。
    v_task_key TEXT;                               -- 清洗后的任务ID；为空则用当前时间 md5 生成一个短 key。
    v_table TEXT;                                  -- 最终生成的精细网格表名。
    v_idx_prefix TEXT;                             -- 精细网格索引名前缀，避免索引名过长。
    v_table_regclass REGCLASS;                     -- 用 to_regclass 检查表是否存在时的结果。
    v_min_lon DOUBLE PRECISION;                    -- 走廊外包框最小经度。
    v_max_lon DOUBLE PRECISION;                    -- 走廊外包框最大经度。
    v_min_lat DOUBLE PRECISION;                    -- 走廊外包框最小纬度。
    v_max_lat DOUBLE PRECISION;                    -- 走廊外包框最大纬度。
    v_mid_lat DOUBLE PRECISION;                    -- 走廊中间纬度，用来估算经度方向每度对应多少米。
    v_lon_meter DOUBLE PRECISION;                  -- 当前纬度附近 1 度经度约等于多少米。
    step_lon DOUBLE PRECISION;                     -- 经度方向网格步长，单位是“度”，由米换算而来。
    step_lat DOUBLE PRECISION;                     -- 纬度方向网格步长，单位是“度”，由米换算而来。
    step_alt DOUBLE PRECISION;                     -- 高度方向网格步长，单位米。
    v_lon_max_idx INT;                             -- 经度方向 generate_series 的最大下标。
    v_lat_max_idx INT;                             -- 纬度方向 generate_series 的最大下标。
    v_alt_max_idx INT;                             -- 高度方向 generate_series 的最大下标。
    v_estimated_count BIGINT;                      -- 按外包框预估的最大三维网格数量，用于提前拦截超大任务。
    v_cnt BIGINT;                                  -- 实际写入精细网格表的行数。
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_generate_corridor_fine_grid(%L, %L, %s, %s, %s, %L, %L);',
        p_project_id, ST_AsText(p_path_line), COALESCE(p_min_alt::text, 'NULL'), COALESCE(p_max_alt::text, 'NULL'), COALESCE(p_resolution::text, 'NULL'), p_task_id, p_drop_old);

    code := 200;
    table_name := NULL;
    msg := '';
    count := 0;

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        msg := format('参数错误：项目ID不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_path_line IS NULL OR ST_IsEmpty(p_path_line) THEN
        code := 400;
        msg := format('参数错误：粗航线不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_resolution <= 0 THEN
        code := 400;
        msg := format('参数错误：分辨率必须大于0，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_min_alt >= p_max_alt THEN
        code := 400;
        msg := format('参数错误：最小高度不能大于等于最大高度，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 动态表名不能直接拼接原始 project_id/task_id，因为可能包含横线、中文或其他非法字符。
    v_project_key := regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_task_key := COALESCE(NULLIF(regexp_replace(COALESCE(p_task_id, ''), '[^0-9a-zA-Z_]', '', 'g'), ''), substr(md5(clock_timestamp()::text), 1, 12));
    -- PostgreSQL标识符最长63字节，精细表名用hash压缩，避免项目ID+任务ID过长被截断。
    v_table := 'gis_grid_nodes_fine_' || substr(md5(v_project_key || '_' || v_task_key), 1, 16);
    v_idx_prefix := 'idx_' || substr(md5(v_table), 1, 12);
    table_name := v_table;

    -- 取粗航线所有线路点构成的外包矩形，不再做 buffer 外扩。
    SELECT
        ST_XMin(ST_Envelope(ST_Force2D(ST_SetSRID(p_path_line, 4326)))),
        ST_XMax(ST_Envelope(ST_Force2D(ST_SetSRID(p_path_line, 4326)))),
        ST_YMin(ST_Envelope(ST_Force2D(ST_SetSRID(p_path_line, 4326)))),
        ST_YMax(ST_Envelope(ST_Force2D(ST_SetSRID(p_path_line, 4326))))
    INTO v_min_lon, v_max_lon, v_min_lat, v_max_lat;

    -- 线路经度或纬度完全相同时，矩形面积为0，无法生成二维网格；只做最小兜底展开。
    IF v_min_lon = v_max_lon THEN
        v_min_lon := v_min_lon - 0.000001;
        v_max_lon := v_max_lon + 0.000001;
    END IF;
    IF v_min_lat = v_max_lat THEN
        v_min_lat := v_min_lat - 0.000001;
        v_max_lat := v_max_lat + 0.000001;
    END IF;
    v_mid_lat := (v_min_lat + v_max_lat) / 2.0;
    v_lon_meter := 111320.0 * cos(radians(v_mid_lat));
    IF abs(v_lon_meter) < 1 THEN
        code := 400;
        msg := format('参数错误：区域纬度过高，无法生成精细网格，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 30m/20m 分辨率需要换算成经纬度步长。
    -- 纬度 1 度约 111320 米；经度 1 度随纬度变化，所以用 v_lon_meter 单独计算。
    step_lat := p_resolution / 111320.0;
    step_lon := p_resolution / v_lon_meter;
    step_alt := 1.0;

    v_lon_max_idx := floor((v_max_lon - v_min_lon) / step_lon)::INT;
    v_lat_max_idx := floor((v_max_lat - v_min_lat) / step_lat)::INT;
    v_alt_max_idx := floor((p_max_alt::DOUBLE PRECISION - p_min_alt::DOUBLE PRECISION) / step_alt)::INT;
    v_estimated_count := (v_lon_max_idx::BIGINT + 1) * (v_lat_max_idx::BIGINT + 1) * (v_alt_max_idx::BIGINT + 1);

    IF v_estimated_count > 30000000 THEN
        code := 400;
        msg := format('参数错误：精细网格预计 %s 条，超过3000万，请增大分辨率或缩小线路点外包矩形范围，执行时间 %s 秒', v_estimated_count, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := v_estimated_count;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 如果同名表已经存在：p_drop_old=true 时删掉重建；否则直接返回旧表和旧行数。
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

    -- 创建 UNLOGGED 精细网格表：
    --   lon_series  生成经度方向离散点。
    --   lat_series  生成纬度方向离散点。
    --   xy_grid     先生成二维点，并只保留落在走廊面内的点。
    --   z_grid      生成高度方向离散点。
    --   最终 xy_grid × z_grid 得到三维点。
    --
    -- 这里使用 EXECUTE format 是因为表名 v_table 是动态的；实际数值参数通过 USING 传入，
    -- 可以避免把坐标、距离直接拼到 SQL 字符串里。
    EXECUTE format('
        CREATE UNLOGGED TABLE %I
        WITH (autovacuum_enabled = off) AS
        WITH lon_series AS (
            -- x 是经度方向网格下标，lon 是真实经度。
            SELECT s_lon::INT AS x, ($1 + s_lon * $4)::DOUBLE PRECISION AS lon
            FROM generate_series(0, $10) s_lon
            WHERE ($1 + s_lon * $4) <= $7
        ),
        lat_series AS (
            -- y 是纬度方向网格下标，lat 是真实纬度。
            SELECT s_lat::INT AS y, ($2 + s_lat * $5)::DOUBLE PRECISION AS lat
            FROM generate_series(0, $11) s_lat
            WHERE ($2 + s_lat * $5) <= $8
        ),
        xy_grid AS MATERIALIZED (
            -- MATERIALIZED 强制物化二维网格，后面和 z_grid 做笛卡尔积时避免重复计算。
            SELECT
                x.x,
                y.y,
                x.lon,
                y.lat,
                ST_SetSRID(ST_MakePoint(x.lon, y.lat), 4326)::geometry(Point,4326) AS geom2d
            FROM lon_series x
            CROSS JOIN lat_series y
        ),
        z_grid AS MATERIALIZED (
            -- z 是高度方向网格下标，alt 是真实高度，单位米。
            SELECT s_alt::INT AS z, ($3 + s_alt * $6)::DOUBLE PRECISION AS alt
            FROM generate_series(0, $12) s_alt
            WHERE ($3 + s_alt * $6) <= $9
        )
        SELECT
            -- id 用 x/y/z 下标计算得到，保证同一个网格内唯一且稳定。
            ((z.z::BIGINT * ($11::BIGINT + 1) + xy.y::BIGINT) * ($10::BIGINT + 1) + xy.x::BIGINT + 1) AS id,
            xy.x::INT,
            xy.y::INT,
            z.z::INT,
            xy.lon,
            xy.lat,
            z.alt,
            true::BOOLEAN AS is_flyable, -- 初始都认为可飞，后续围栏/建筑打标会改成 false。
            NULL::VARCHAR(20) AS zone_type, -- 围栏类型，建筑阻塞不写这个字段。
            0::INT AS block_mask, -- 阻塞来源位图：1=围栏，2=建筑。
            xy.geom2d, -- 二维点，用于平面空间判断。
            ST_SetSRID(ST_MakePoint(xy.lon, xy.lat, z.alt), 4326)::geometry(PointZ,4326) AS geom -- 三维点，用于 A*。
        FROM xy_grid xy
        CROSS JOIN z_grid z
    ', v_table)
    USING v_min_lon, v_min_lat, p_min_alt,
          step_lon, step_lat, step_alt,
          v_max_lon, v_max_lat, p_max_alt,
          v_lon_max_idx, v_lat_max_idx, v_alt_max_idx;

    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    count := v_cnt;

    -- 建索引：
    --   主键 id        用于路径回溯、临时表关联。
    --   (x,y,z)        用于 A* 查邻居。
    --   fly_xyz        只索引可飞点，减少搜索扫描量。
    --   geom2d_z0      只在 z=0 的二维平面点建 GiST，用于围栏/建筑平面匹配。
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
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_generate_corridor_fine_grid(VARCHAR, GEOMETRY, NUMERIC, NUMERIC, INT, VARCHAR, BOOLEAN) IS '生成航廊精细飞行网格';


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
--
-- 参数说明：
--   p_project_id  项目ID。用于筛选 bo_electric_fence，也用于查找 gis_electric_fence_<project_id>。
--   p_grid_table  需要打标的网格表名，一般是 gis_generate_corridor_fine_grid 返回的精细网格表。
--
-- 返回字段：
--   code        200/400 状态码；本函数未单独写异常块，异常会抛给上层总控函数处理。
--   table_name  被打标的网格表名。
--   msg         执行说明和耗时。
--   count       更新行数 + 清空旧标记行数。
-- ============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_mark_electric_fence_on_grid');

-- =============================================================================
-- 函数介绍：gis_mark_electric_fence_on_grid
-- 主要作用：把电子围栏障碍标记到指定精细网格表中，更新可飞状态。
-- 入参说明：p_grid_table 为精细网格表名；p_project_id 为项目ID，用于读取项目围栏数据。
-- 返回说明：返回更新行数和状态信息，用于确认精细网格围栏障碍标记完成。
-- 注意事项：函数针对指定网格表操作，调用前需确保精细网格已生成且表名正确。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_mark_electric_fence_on_grid(
    p_project_id VARCHAR,
    p_grid_table VARCHAR
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于耗时统计。
    v_grid_reg REGCLASS;                           -- 精细网格表是否存在。
    v_project_key TEXT;                            -- 清洗后的项目ID，用于拼项目专属围栏表名。
    v_project_fence_table TEXT;                    -- 项目专属围栏表名：gis_electric_fence_<project_id>。
    v_project_fence_reg REGCLASS;                  -- 项目专属围栏表是否存在。
    v_geom_col TEXT;                               -- 网格平面判断使用的几何列；优先 geom2d，没有则用 geom。
    v_grid_extent box3d;                           -- 当前精细网格二维范围，用于只筛选走廊缓冲范围内的围栏。
    v_extent box3d;                                -- 所有有效围栏的总外包框，用于先裁剪网格范围。
    v_updated BIGINT := 0;                         -- 本次命中围栏并更新的网格点数量。
    v_cleared BIGINT := 0;                         -- 本次清除旧围栏标记的网格点数量。
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_mark_electric_fence_on_grid(%L, %L);',
        p_project_id, p_grid_table);

    table_name := p_grid_table;
    SELECT to_regclass(format('%I.%I', current_schema(), p_grid_table)) INTO v_grid_reg;
    IF v_grid_reg IS NULL THEN
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', p_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 保证目标网格表具备打标需要的字段；重复执行也安全。
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20)', p_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0', p_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true', p_grid_table);

    -- 精细网格有 geom2d；如果传入的是旧结构网格表，则退化使用 geom。
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = p_grid_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;

    EXECUTE format('SELECT ST_Extent(%I) FROM %I WHERE z = 0', v_geom_col, p_grid_table)
    INTO v_grid_extent;

    IF v_grid_extent IS NULL THEN
        code := 200;
        msg := format('精细网格无二维走廊点，跳过电子围栏打标，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    -- tmp_fine_fence 统一承载“全局围栏表 + 项目专属围栏表”的有效围栏。
    -- priority 数值越小优先级越高，后面 DISTINCT ON 会按这个优先级决定最终 zone_type。
    DROP TABLE IF EXISTS tmp_fine_fence;
    CREATE TEMP TABLE tmp_fine_fence (
        id text,
        priority int,
        zone_type varchar(20),
        max_height double precision,
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    -- 读取全局电子围栏：
    --   fence_type=1 禁飞区，阻塞飞行；
    --   fence_type=2 管控区，当前也按阻塞处理；
    --   fence_type=3 适飞区，只做区域标识，不主动阻塞。
    -- height 为 0 或 NULL 表示不限制高度，整列高度都受影响。
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
      AND (COALESCE(p_project_id, '') = '' OR project_id::text = p_project_id::text)
      AND ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope(ST_XMin(v_grid_extent), ST_YMin(v_grid_extent), ST_XMax(v_grid_extent), ST_YMax(v_grid_extent), 4326)
      AND ST_Intersects(ST_SetSRID(ST_Force2D(geom), 4326), ST_MakeEnvelope(ST_XMin(v_grid_extent), ST_YMin(v_grid_extent), ST_XMax(v_grid_extent), ST_YMax(v_grid_extent), 4326));

    -- 项目专属围栏表如果存在，也合并进临时围栏表。
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
              AND ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope($1, $2, $3, $4, 4326)
              AND ST_Intersects(ST_SetSRID(ST_Force2D(geom), 4326), ST_MakeEnvelope($1, $2, $3, $4, 4326))
        ', v_project_fence_reg)
        USING ST_XMin(v_grid_extent), ST_YMin(v_grid_extent), ST_XMax(v_grid_extent), ST_YMax(v_grid_extent);
    END IF;

    -- 临时表也建 GiST 索引，因为后续要做大量点面相交。
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

    -- tmp_fine_desired_zone 计算每个网格点“本次应该是什么围栏状态”。
    -- 先在 z=0 的二维点上做点面相交，得到命中的 x/y；
    -- 再扩展到所有高度 z，并用 max_height 判断这个高度是否受围栏影响。
    DROP TABLE IF EXISTS tmp_fine_desired_zone;
    EXECUTE format('
        CREATE TEMP TABLE tmp_fine_desired_zone ON COMMIT DROP AS
        WITH xy_match AS MATERIALIZED (
            -- 二维命中结果：某个 x/y 落在哪些围栏面内。
            SELECT
                n.x,
                n.y,
                f.zone_type,
                f.max_height,
                f.priority,
                f.id AS fence_id
            FROM (
                -- 只取 z=0 是因为同一个 x/y 的二维位置相同，不需要每个高度重复做点面相交。
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
            -- 如果一个网格点同时落入多个围栏，按 priority 和 fence_id 选一个最终 zone_type。
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

    -- 把本次命中的围栏状态写回网格：
    --   禁飞区/管控区：设置 block_mask 第 1 位，并置 is_flyable=false。
    --   适飞区：清除 block_mask 第 1 位；但如果还有建筑等其他阻塞位，仍不可飞。
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

    -- 走廊精细网格由总控函数新建，默认不存在旧围栏标记，跳过全表清理以降低耗时。
    v_cleared := 0;

    code := 200;
    count := v_updated + v_cleared;
    msg := format('精细网格电子围栏打标完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated, v_cleared, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_mark_electric_fence_on_grid(VARCHAR, VARCHAR) IS '标记精细网格电子围栏';


-- ============================================================
-- 3. gis_mark_buildings_on_grid
--    对指定精细网格表做建筑打标，支持 buffer 防漏标。
--
-- 参数说明：
--   p_project_id        项目ID，用于定位 gis_buildings_<project_id>。
--   p_grid_table        要打标的网格表名，通常是走廊精细网格。
--   p_building_buffer   建筑外扩距离，单位米；20m精细网格默认取20。
--                       作用是给建筑面稍微外扩，防止网格点刚好从建筑边缘“漏过去”。
--
-- 返回字段：
--   code        200/400 状态码；异常会抛给上层总控函数处理。
--   table_name  被打标的网格表名。
--   msg         执行说明和耗时。
--   count       更新行数 + 清空旧建筑阻塞行数。
--
-- 打标规则：
--   - 网格二维点落入建筑面，且网格 alt <= 建筑 height，则 block_mask | 2；
--   - height 为空或小于等于0时按 5m 默认高度处理；
--   - 清除不再命中的旧建筑阻塞位，并按剩余 block_mask 重算 is_flyable。
-- ============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_mark_buildings_on_grid');

-- =============================================================================
-- 函数介绍：gis_mark_buildings_on_grid
-- 主要作用：把项目建筑物范围标记到指定精细网格表中，作为精细规划障碍。
-- 入参说明：p_grid_table 为精细网格表名；p_project_id 为项目ID；p_building_buffer 为建筑缓冲距离。
-- 返回说明：返回建筑障碍更新行数和执行消息，供精细路径规划前检查。
-- 注意事项：依赖项目建筑表；缓冲距离按米处理，可根据建筑数据精度适当调整。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_mark_buildings_on_grid(
    p_project_id VARCHAR,
    p_grid_table VARCHAR,
    p_building_buffer DOUBLE PRECISION DEFAULT 0
)
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于耗时统计。
    v_project_key TEXT;                            -- 清洗后的项目ID，用于拼建筑表名。
    v_building_table TEXT;                         -- 建筑表名：gis_buildings_<project_id>。
    v_grid_reg REGCLASS;                           -- 网格表是否存在。
    v_building_reg REGCLASS;                       -- 建筑表是否存在。
    v_geom_col TEXT;                               -- 网格平面判断使用的几何列；优先 geom2d。
    v_grid_extent box3d;                           -- 当前精细网格二维范围，用于只筛选走廊缓冲范围内的建筑。
    v_min_alt DOUBLE PRECISION;                    -- 当前精细网格最低高度，用于跳过不会影响巡航高度的低矮建筑。
    v_updated BIGINT := 0;                         -- 本次命中建筑并设置阻塞的网格点数。
    v_cleared BIGINT := 0;                         -- 本次清理旧建筑阻塞的网格点数。
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_mark_buildings_on_grid(%L, %L, %s);',
        p_project_id, p_grid_table, COALESCE(p_building_buffer::text, 'NULL'));

    table_name := p_grid_table;
    v_project_key := regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_building_table := 'gis_buildings_' || v_project_key;

    SELECT to_regclass(format('%I.%I', current_schema(), p_grid_table)) INTO v_grid_reg;
    SELECT to_regclass(format('%I.%I', current_schema(), v_building_table)) INTO v_building_reg;
    IF v_grid_reg IS NULL THEN
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', p_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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

    -- 保证目标网格表有阻塞字段；zone_type 是围栏字段，建筑不需要写。
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0', p_grid_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true', p_grid_table);

    -- 建筑判断只需要二维位置，优先使用 geom2d。
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = p_grid_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;

    EXECUTE format('SELECT ST_Extent(%I), MIN(alt) FROM %I WHERE z = 0', v_geom_col, p_grid_table)
    INTO v_grid_extent, v_min_alt;

    IF v_grid_extent IS NULL THEN
        code := 200;
        msg := format('精细网格无二维走廊点，跳过建筑打标，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 建筑表 geom 建二维 GiST 索引，加速点面相交。
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (geom gist_geometry_ops_2d)',
                   'idx_' || substr(md5(v_building_table), 1, 12) || '_geom',
                   v_building_table);

    -- tmp_fine_building_hit 保存本次被建筑挡住的网格点 id。
    -- 判断方式：
    --   1. 建筑面按 p_building_buffer 外扩；
    --   2. z=0 平面点落入建筑面，说明这个 x/y 在建筑占地范围内；
    --   3. 再判断三维网格点 alt <= 建筑高度，低于楼高才算被挡。
    DROP TABLE IF EXISTS tmp_fine_building_hit;
    EXECUTE format('
        CREATE TEMP TABLE tmp_fine_building_hit ON COMMIT DROP AS
        WITH buildings AS MATERIALIZED (
            -- 统一建筑数据：没有高度时按 5m 处理；需要 buffer 时按米外扩。
            SELECT
                COALESCE(id::text, gid::text) AS building_id,
                CASE WHEN COALESCE(height, 0) > 0 THEN height::double precision ELSE 5::double precision END AS max_height,
                CASE
                    WHEN $1 > 0 THEN ST_Buffer(ST_SetSRID(ST_Force2D(geom), 4326)::geography, $1)::geometry
                    ELSE ST_SetSRID(ST_Force2D(geom), 4326)
                END AS geom2d
            FROM %I
            WHERE geom IS NOT NULL
              AND (CASE WHEN COALESCE(height, 0) > 0 THEN height::double precision ELSE 5::double precision END) >= $6
              AND ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope($2, $3, $4, $5, 4326)
              AND ST_Intersects(ST_SetSRID(ST_Force2D(geom), 4326), ST_MakeEnvelope($2, $3, $4, $5, 4326))
        ),
        xy_match AS MATERIALIZED (
            -- 每个 x/y 如果命中多个建筑，取最高建筑，避免低楼覆盖高楼判断。
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
    USING p_building_buffer, ST_XMin(v_grid_extent), ST_YMin(v_grid_extent), ST_XMax(v_grid_extent), ST_YMax(v_grid_extent), COALESCE(v_min_alt, 0);

    CREATE INDEX IF NOT EXISTS idx_tmp_fine_building_hit_id ON tmp_fine_building_hit(id);
    ANALYZE tmp_fine_building_hit;

    -- 命中建筑的网格点设置 block_mask 第 2 位，并直接设为不可飞。
    EXECUTE format('
        UPDATE %I n
        SET
            block_mask = COALESCE(n.block_mask, 0) | 2,
            is_flyable = false
        FROM tmp_fine_building_hit h
        WHERE n.id = h.id
    ', p_grid_table);
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- 走廊精细网格由总控函数新建，默认不存在旧建筑标记，跳过全表清理以降低耗时。
    v_cleared := 0;

    code := 200;
    count := v_updated + v_cleared;
    msg := format('精细网格建筑打标完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated, v_cleared, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_mark_buildings_on_grid(VARCHAR, VARCHAR, DOUBLE PRECISION) IS '标记精细网格建筑障碍';


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
--
-- 参数说明：
--   p_grid_table      已经生成并完成障碍打标的网格表名。
--   p_start_lon       起点经度，WGS84，经度单位度。
--   p_start_lat       起点纬度，WGS84，纬度单位度。
--   p_start_alt       起点高度，单位米。
--   p_end_lon         终点经度，WGS84，经度单位度。
--   p_end_lat         终点纬度，WGS84，纬度单位度。
--   p_end_alt         终点高度，单位米。
--   p_safe_altitude   巡航/安全高度，单位米；路径中间点会统一抬到这个高度。
--   p_height_mode     高度模式，目前仅原样写入 smooth_ratio 字段，保持和 3.2 返回结构兼容。
--   p_project_id      写入 gis_flight_paths.project_id。
--   p_create_user     写入 gis_flight_paths.create_user/update_user。
--
-- A* 临时表字段：
--   g_cost     从起点走到当前点的累计代价。
--   f_cost     g_cost + 当前点到终点的启发式距离，值越小越优先搜索。
--   parent_id  当前点是从哪个上一个点走过来的，用于最后回溯路径。
--   closed     true 表示这个点已经完成扩展，不再重复处理。
-- ============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_astar_3d_flight_plan_on_grid');

-- =============================================================================
-- 函数介绍：gis_astar_3d_flight_plan_on_grid
-- 主要作用：在指定精细网格表上执行三维A*规划，生成更贴合走廊和障碍的航线。
-- 入参说明：包含精细网格表名、起终点经纬高、安全高度、项目ID、创建人和高度模式。
-- 返回说明：返回规划状态、路径线、平滑路径、航点JSON和距离等规划结果。
-- 注意事项：函数只使用传入网格表寻路，调用前应先完成围栏和建筑障碍标记。
-- =============================================================================
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
    v_start_time timestamptz := clock_timestamp();       -- 函数开始时间，用于耗时统计。
    v_return_msg TEXT;                                   -- 最终返回给调用方的说明。
    v_grid_reg REGCLASS;                                 -- 精细网格表是否存在。
    v_start_pt geometry(PointZ,4326);                    -- 起点三维几何。
    v_end_pt geometry(PointZ,4326);                      -- 终点三维几何。
    v_start_id BIGINT;                                   -- 距离真实起点最近的可飞网格点 id。
    v_goal_id BIGINT;                                    -- 距离真实终点最近的可飞网格点 id。
    v_min_x INT;                                         -- 搜索窗口最小 x，下方会由起终点 x 计算。
    v_max_x INT;                                         -- 搜索窗口最大 x。
    v_min_y INT;                                         -- 搜索窗口最小 y。
    v_max_y INT;                                         -- 搜索窗口最大 y。
    v_margin INT := 30;                                  -- 搜索窗口额外扩展的网格数量，避免窗口过窄。
    v_curr BIGINT;                                       -- 当前从 open 集合中取出的网格点 id。
    v_curr_x INT;                                        -- 当前点 x 下标。
    v_curr_y INT;                                        -- 当前点 y 下标。
    v_curr_z INT;                                        -- 当前点 z 下标。
    v_curr_geom geometry(PointZ,4326);                   -- 当前点三维几何。
    v_curr_g DOUBLE PRECISION;                           -- 当前点 g_cost。
    v_nid BIGINT;                                        -- 邻居点 id。
    v_n_geom geometry(PointZ,4326);                      -- 邻居点三维几何。
    v_new_g DOUBLE PRECISION;                            -- 从当前点走到邻居点后的新累计代价。
    v_loop INT := 0;                                     -- A* 主循环次数，用于防止极端情况下无限跑。
    v_found BOOLEAN := false;                            -- 是否成功搜索到终点网格。
    v_path_ids BIGINT[] := ARRAY[]::BIGINT[];             -- 回溯得到的网格点 id 列表，顺序为起点到终点。
    v_current BIGINT;                                    -- 回溯 parent_id 时当前处理的点。
    v_path_line geometry(LineStringZ,4326);              -- 原始规划线。
    v_raw_path_line geometry(LineStringZ,4326);          -- 精细A*网格回溯得到的原始线路。
    v_final_line geometry(LineStringZ,4326);             -- 平滑线；当前实现暂未额外平滑，等于 v_path_line。
    v_waypoints JSONB;                                   -- path_line 拆出来的航点 JSON。
    v_smooth_waypoints JSONB;                            -- smooth_path_line 拆出来的航点 JSON。
    v_path_id INT;                                       -- 写入 gis_flight_paths 后生成的记录 id。
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_astar_3d_flight_plan_on_grid(%L, %s, %s, %s, %s, %s, %s, %s, %s, %L, %L);',
        p_grid_table, COALESCE(p_start_lon::text, 'NULL'), COALESCE(p_start_lat::text, 'NULL'), COALESCE(p_start_alt::text, 'NULL'), COALESCE(p_end_lon::text, 'NULL'), COALESCE(p_end_lat::text, 'NULL'), COALESCE(p_end_alt::text, 'NULL'), COALESCE(p_safe_altitude::text, 'NULL'), COALESCE(p_height_mode::text, 'NULL'), p_project_id, p_create_user);

    SELECT to_regclass(format('%I.%I', current_schema(), p_grid_table)) INTO v_grid_reg;
    IF v_grid_reg IS NULL THEN
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', p_grid_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_start_lon IS NULL OR p_start_lat IS NULL OR p_start_alt IS NULL
       OR p_end_lon IS NULL OR p_end_lat IS NULL OR p_end_alt IS NULL THEN
        code := 400;
        msg := format('参数错误：起点/终点经纬度和高度不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_safe_altitude IS NULL OR p_safe_altitude <= 0 THEN
        code := 400;
        msg := format('参数错误：安全高度必须大于0，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- 构造真实起终点。A* 实际从“最近的可飞网格点”开始/结束，但最终航线会保留真实起终点。
    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);

    -- 找到离真实起点/终点最近的可飞网格点，作为 A* 的 start/goal。
    EXECUTE format('SELECT id FROM %I WHERE is_flyable = true ORDER BY geom <-> $1 LIMIT 1', p_grid_table)
    INTO v_start_id USING v_start_pt;
    EXECUTE format('SELECT id FROM %I WHERE is_flyable = true ORDER BY geom <-> $1 LIMIT 1', p_grid_table)
    INTO v_goal_id USING v_end_pt;

    IF v_start_id IS NULL OR v_goal_id IS NULL THEN
        code := 400;
        msg := format('参数错误：精细网格中找不到可飞起点或终点，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- 根据起终点网格的 x/y 得到一个搜索窗口，再向外扩 v_margin 个网格。
    -- 这样不需要把整张精细网格都放进 A* 临时表，能明显减少搜索量。
    EXECUTE format('SELECT x FROM %I WHERE id = $1', p_grid_table) INTO v_min_x USING v_start_id;
    EXECUTE format('SELECT x FROM %I WHERE id = $1', p_grid_table) INTO v_max_x USING v_goal_id;
    EXECUTE format('SELECT y FROM %I WHERE id = $1', p_grid_table) INTO v_min_y USING v_start_id;
    EXECUTE format('SELECT y FROM %I WHERE id = $1', p_grid_table) INTO v_max_y USING v_goal_id;

    -- 保证 min/max 顺序正确。这里用算术交换写法，避免额外声明临时变量。
    IF v_min_x > v_max_x THEN v_min_x := v_min_x + v_max_x; v_max_x := v_min_x - v_max_x; v_min_x := v_min_x - v_max_x; END IF;
    IF v_min_y > v_max_y THEN v_min_y := v_min_y + v_max_y; v_max_y := v_min_y - v_max_y; v_min_y := v_min_y - v_max_y; END IF;

    -- tmp_fine_astar_grid 是本次 A* 的工作表，只放可飞点和搜索窗口内的点。
    -- 注意：这里没有把不可飞点放进去，所以邻居查询天然绕开围栏/建筑。
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

    -- A* 会频繁按 id 回溯、按 x/y/z 找邻居、按 f_cost 取最优开放点，因此建三个索引。
    CREATE UNIQUE INDEX IF NOT EXISTS idx_tmp_fine_astar_grid_id ON tmp_fine_astar_grid(id);
    CREATE INDEX IF NOT EXISTS idx_tmp_fine_astar_grid_xyz ON tmp_fine_astar_grid(x, y, z);
    CREATE INDEX IF NOT EXISTS idx_tmp_fine_astar_grid_open ON tmp_fine_astar_grid(f_cost) WHERE closed = false;
    ANALYZE tmp_fine_astar_grid;

    -- 初始化起点：起点 g_cost=0，f_cost=到终点的直线距离。
    UPDATE tmp_fine_astar_grid g
    SET g_cost = 0,
        f_cost = ST_3DDistance(g.geom, v_end_pt)
    WHERE g.id = v_start_id;

    -- A* 主循环：
    --   1. 每次取 f_cost 最小且未 closed 的点；
    --   2. 如果是终点，搜索成功；
    --   3. 否则关闭当前点，枚举周围 26 个三维邻居；
    --   4. 如果通过当前点到邻居更便宜，就更新邻居的 g/f/parent。
    -- 80000 是保护上限，防止异常数据导致函数长时间不返回。
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

        -- 三维 3×3×3 邻域，排除当前点本身，最多 26 个方向。
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

    -- 如果 A* 没找到路，返回起点到终点直线兜底，避免上层完全没有航线。
    IF NOT v_found THEN
        v_path_line := ST_MakeLine(v_start_pt, v_end_pt);
        v_raw_path_line := v_path_line;
        v_final_line := v_path_line;
    ELSE
        -- 从 goal 沿 parent_id 一路回溯到 start，得到网格路径 id。
        v_current := v_goal_id;
        WHILE v_current IS NOT NULL LOOP
            v_path_ids := array_prepend(v_current, v_path_ids);
            SELECT g.parent_id INTO v_current FROM tmp_fine_astar_grid g WHERE g.id = v_current;
        END LOOP;

        -- 组装原始航线：只保留精细A*在网格上回溯得到的原始点。
        IF COALESCE(array_length(v_path_ids, 1), 0) >= 2 THEN
            SELECT ST_MakeLine(g.geom ORDER BY u.ord)::geometry(LineStringZ,4326)
            INTO v_raw_path_line
            FROM unnest(v_path_ids) WITH ORDINALITY AS u(id, ord)
            JOIN tmp_fine_astar_grid g ON g.id = u.id;
        END IF;
        IF v_raw_path_line IS NULL OR ST_NumPoints(v_raw_path_line) < 2 THEN
            v_raw_path_line := ST_MakeLine(v_start_pt, v_end_pt);
        END IF;

        -- 组装处理后航线：
        --   真实起点 -> 起点上升到安全高度 -> 精细网格水平路径 -> 终点安全高度 -> 真实终点。
        -- 当前代码把中间网格点高度统一改成 p_safe_altitude。
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

    -- path_line/waypoints 存原始网格线路；smooth_path_line/smooth_waypoints 存处理后线路。
    SELECT jsonb_agg(jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom)) ORDER BY (dp).path[1])
    INTO v_waypoints
    FROM ST_DumpPoints(v_raw_path_line) AS dp;

    SELECT jsonb_agg(jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom)) ORDER BY (dp).path[1])
    INTO v_smooth_waypoints
    FROM ST_DumpPoints(v_final_line) AS dp;

    -- 写入统一航线结果表，保持和 3.2 粗规划结果同一套返回结构。
    INSERT INTO gis_flight_paths (
        project_id, create_user, update_user,
        start_point, end_point, safe_altitude,
        path_line, smooth_path_line,
        waypoints, smooth_waypoints, total_distance, smooth_ratio
    ) VALUES (
        p_project_id, p_create_user, p_create_user,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_raw_path_line, v_final_line,
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
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
END;
$$;
COMMENT ON FUNCTION gis_astar_3d_flight_plan_on_grid(
    VARCHAR, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, VARCHAR, VARCHAR
) IS '指定网格精细避障寻路';


-- ============================================================
-- 5. gis_astar_3d_flight_plan_build
--    两阶段规划总控函数：100m全局粗规划 + 20m矩形精规划。
--
-- 执行流程：
--   1. 调用 3.2 的 gis_astar_3d_flight_plan 生成粗航线；
--   2. 取粗航线所有线路点外包矩形；
--   3. 在矩形范围内生成精细网格表；
--   4. 对精细网格做电子围栏和建筑打标；
--   5. 在精细网格上重新规划；
--   6. 按 p_drop_fine_grid 决定是否删除精细网格表。
--
-- 参数策略：
--   粗网格由 3.1 已生成表决定；精细网格固定 20m，建筑外扩固定 20m。
--
-- 完整参数说明：
--   p_start_lon          起点经度，WGS84，单位度。
--   p_start_lat          起点纬度，WGS84，单位度。
--   p_start_alt          起点高度，单位米。
--   p_end_lon            终点经度，WGS84，单位度。
--   p_end_lat            终点纬度，WGS84，单位度。
--   p_end_alt            终点高度，单位米。
--   p_safe_altitude      安全/巡航高度，单位米；粗规划和精细规划都会使用。
--   p_height_mode        高度模式，传给底层规划函数；当前也会写入结果 smooth_ratio 字段。
--   p_project_id         项目ID，用于选择项目网格、围栏、建筑表，并写入航线结果。
--   p_create_user        创建人账号/ID，写入 gis_flight_paths。
--   p_drop_fine_grid     是否在函数结束后删除精细网格表；排查问题时传 false。
--
-- 返回字段：
--   code/msg             先返回本总控函数状态，再拼接 gis_flight_paths 的完整字段。
--   其他字段             与 gis_flight_paths 表结构一致，例如 path_line、waypoints、total_distance。
-- ============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_astar_3d_flight_plan_build');

-- =============================================================================
-- 函数介绍：gis_astar_3d_flight_plan_build
-- 主要作用：组合粗规划、走廊精细建网格、障碍标记和精细A*，生成建筑避障优化航线。
-- 入参说明：参考粗规划入口，包含起终点经纬高、安全高度、高度模式、项目ID和创建人。
-- 返回说明：返回最终精细规划结果，并保留过程状态信息，便于判断失败环节。
-- 注意事项：该函数是精细线路规划入口，依赖3.2粗规划、项目网格、围栏和建筑数据完整可用。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_astar_3d_flight_plan_build(
    p_start_lon DOUBLE PRECISION,
    p_start_lat DOUBLE PRECISION,
    p_start_alt DOUBLE PRECISION,
    p_end_lon DOUBLE PRECISION,
    p_end_lat DOUBLE PRECISION,
    p_end_alt DOUBLE PRECISION,
    p_safe_altitude DOUBLE PRECISION DEFAULT 120,
    p_height_mode DOUBLE PRECISION DEFAULT 0,
    p_project_id VARCHAR DEFAULT NULL,
    p_create_user VARCHAR DEFAULT NULL,
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
    v_start_time timestamptz := clock_timestamp(); -- 总控函数开始时间，用于整体耗时统计。
    v_coarse gis_flight_paths%ROWTYPE;             -- 粗规划写入 gis_flight_paths 后对应的记录。
    v_fine gis_flight_paths%ROWTYPE;               -- 精细规划写入 gis_flight_paths 后对应的记录。
    v_coarse_code INT;                             -- 粗规划返回状态码。
    v_coarse_msg TEXT;                             -- 粗规划返回说明。
    v_fine_code INT;                               -- 精细规划返回状态码。
    v_fine_msg TEXT;                               -- 精细规划返回说明。
    v_grid_result RECORD;                          -- 生成精细网格函数的返回结果。
    v_mark_result RECORD;                          -- 围栏/建筑打标函数的返回结果；主要用于接收，当前不强制校验。
    v_task_key TEXT;                               -- 清洗后的任务 key，用于生成精细网格表名。
    v_fine_table TEXT;                             -- 本次生成的精细网格表名。
    v_path_line geometry(LineStringZ,4326);        -- 粗规划航线，用它来生成精细走廊。
    v_fail_code INT := 500;                        -- 失败返回码：400参数/业务校验，500空间计算/执行异常。
    v_fail_msg TEXT;                               -- 失败返回说明。
    v_step_start timestamptz;                      -- 分阶段计时起点。
    v_coarse_seconds NUMERIC := 0;                 -- 粗规划耗时。
    v_grid_seconds NUMERIC := 0;                   -- 精细网格生成耗时。
    v_fence_seconds NUMERIC := 0;                  -- 电子围栏打标耗时。
    v_building_seconds NUMERIC := 0;               -- 建筑打标耗时。
    v_astar_seconds NUMERIC := 0;                  -- 精细A*耗时。
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_astar_3d_flight_plan_build(%s, %s, %s, %s, %s, %s, %s, %s, %L, %L, %L);',
        COALESCE(p_start_lon::text, 'NULL'), COALESCE(p_start_lat::text, 'NULL'), COALESCE(p_start_alt::text, 'NULL'),
        COALESCE(p_end_lon::text, 'NULL'), COALESCE(p_end_lat::text, 'NULL'), COALESCE(p_end_alt::text, 'NULL'),
        COALESCE(p_safe_altitude::text, 'NULL'), COALESCE(p_height_mode::text, 'NULL'), p_project_id, p_create_user, p_drop_fine_grid);

    -- 自动生成短任务 key，避免不同任务的精细临时表互相覆盖。
    v_task_key := substr(md5(clock_timestamp()::text), 1, 12);

    -- 第一步：全局粗规划，使用 3.2 原函数和全局网格表。
    -- 3.2 返回 code/msg + gis_flight_paths 字段，这里显式接收，避免字段错位。
    v_step_start := clock_timestamp();
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
    v_coarse_seconds := ROUND(EXTRACT(epoch FROM clock_timestamp() - v_step_start)::numeric, 3);

    IF v_coarse_code IS DISTINCT FROM 200 OR v_coarse.id IS NULL THEN
        v_fail_code := COALESCE(NULLIF(v_coarse_code, 200), 400);
        v_fail_msg := format('粗规划失败，无法生成精细走廊：%s', COALESCE(v_coarse_msg, '无返回结果'));
        RETURN QUERY SELECT
            v_fail_code,
            format('%s，执行时间 %s 秒', v_fail_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- 优先使用粗规划的 smooth_path_line 作为走廊中心线；没有平滑线时使用原始 path_line。
    v_path_line := COALESCE(v_coarse.smooth_path_line, v_coarse.path_line);
    IF v_path_line IS NULL OR ST_IsEmpty(v_path_line) THEN
        v_fail_code := 400;
        v_fail_msg := '粗规划结果无有效航线';
        RETURN QUERY SELECT
            v_fail_code,
            format('%s，执行时间 %s 秒', v_fail_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- 第二步：根据粗航线所有线路点外包矩形生成 20m 精细网格
    -- 高度范围只覆盖安全高度上下1米；起降段由最终航线直接连接真实起终点和安全高度点。
    -- 这样避免从地面到安全高度生成多层精细网格，降低建网格和打标成本。
    v_step_start := clock_timestamp();
    SELECT *
    INTO v_grid_result
    FROM gis_generate_corridor_fine_grid(
        p_project_id,
        v_path_line,
        GREATEST(COALESCE(p_safe_altitude, 0) - 1, 0)::numeric,
        (COALESCE(p_safe_altitude, 0) + 1)::numeric,
        20,
        v_task_key::varchar,
        TRUE
    )
    LIMIT 1;
    v_grid_seconds := ROUND(EXTRACT(epoch FROM clock_timestamp() - v_step_start)::numeric, 3);

    IF v_grid_result.code <> 200 THEN
        v_fail_code := COALESCE(NULLIF(v_grid_result.code, 200), 400);
        v_fail_msg := format('精细网格生成失败：%s', COALESCE(v_grid_result.msg, '无返回结果'));
        RETURN QUERY SELECT
            v_fail_code,
            format('%s，执行时间 %s 秒', v_fail_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            (NULL::gis_flight_paths).*;
        RETURN;
    END IF;
    v_fine_table := v_grid_result.table_name;

    -- 第三步：精细网格打标。
    -- 当前只接收打标返回结果，不中断 code!=200 的情况；
    -- 如果你希望建筑表缺失时直接失败，可以在这里增加 v_mark_result.code 校验。
    v_step_start := clock_timestamp();
    SELECT * INTO v_mark_result FROM gis_mark_electric_fence_on_grid(p_project_id, v_fine_table) LIMIT 1;
    v_fence_seconds := ROUND(EXTRACT(epoch FROM clock_timestamp() - v_step_start)::numeric, 3);

    v_step_start := clock_timestamp();
    SELECT * INTO v_mark_result FROM gis_mark_buildings_on_grid(p_project_id, v_fine_table, 20) LIMIT 1;
    v_building_seconds := ROUND(EXTRACT(epoch FROM clock_timestamp() - v_step_start)::numeric, 3);

    -- 第四步：在精细网格上重新规划
    v_step_start := clock_timestamp();
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
        p_project_id, p_create_user
    ) r
    LIMIT 1;
    v_astar_seconds := ROUND(EXTRACT(epoch FROM clock_timestamp() - v_step_start)::numeric, 3);

    IF v_fine_code IS DISTINCT FROM 200 OR v_fine.id IS NULL THEN
        v_fail_code := COALESCE(NULLIF(v_fine_code, 200), 400);
        v_fail_msg := format('精细规划失败：%s', COALESCE(v_fine_msg, '无返回结果'));
        RETURN QUERY SELECT
            v_fail_code,
            format('%s，执行时间 %s 秒', v_fail_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- 成功后按参数决定是否删除精细网格表。删除后只保留 gis_flight_paths 中的航线结果。
    IF p_drop_fine_grid AND v_fine_table IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', v_fine_table);
    END IF;

    RETURN QUERY
    SELECT 200,
           format('两阶段精细规划完成：%s；粗规划 %s 秒，建网格 %s 秒，围栏打标 %s 秒，建筑打标 %s 秒，A* %s 秒，总耗时 %s 秒',
                  COALESCE(v_fine_msg, '精细规划成功'),
                  v_coarse_seconds, v_grid_seconds, v_fence_seconds, v_building_seconds, v_astar_seconds,
                  ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
           p.*
    FROM gis_flight_paths p
    WHERE p.id = v_fine.id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            500,
            format('空间计算错误：精细规划已生成但结果记录不存在，id=%s，执行时间 %s 秒', COALESCE(v_fine.id::text, 'NULL'), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            (NULL::gis_flight_paths).*;
    END IF;

EXCEPTION WHEN OTHERS THEN
    -- 任意步骤异常时，也尽量清理精细网格表，避免失败任务留下大量中间表。
    IF p_drop_fine_grid AND v_fine_table IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', v_fine_table);
    END IF;

    RAISE NOTICE '精细规划失败，返回粗规划或直线兜底：%', SQLERRM;

    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (500, format('空间计算错误：%s', SQLERRM), v_log_sql);

    -- 如果粗规划已经成功，则返回粗规划航线作为兜底；否则再调用一次 3.2，让 3.2 自己兜底。
    IF v_coarse.id IS NOT NULL THEN
        RETURN QUERY
        SELECT 500,
               format('空间计算错误：%s，已返回粗规划兜底航线，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
               p.*
        FROM gis_flight_paths p
        WHERE p.id = v_coarse.id;

        IF NOT FOUND THEN
            RETURN QUERY SELECT
                500,
                format('空间计算错误：%s，粗规划兜底记录不存在，id=%s，执行时间 %s 秒', SQLERRM, COALESCE(v_coarse.id::text, 'NULL'), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
                (NULL::gis_flight_paths).*;
        END IF;
    ELSE
        RETURN QUERY
        SELECT
            500,
            format('空间计算错误：%s，已返回直线/粗规划兜底航线，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
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

        IF NOT FOUND THEN
            RETURN QUERY SELECT
                500,
                format('空间计算错误：%s，直线/粗规划兜底无返回结果，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
                (NULL::gis_flight_paths).*;
        END IF;
    END IF;
END;
$$;
COMMENT ON FUNCTION gis_astar_3d_flight_plan_build(
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, VARCHAR, VARCHAR, BOOLEAN
) IS '建筑避障精细航线规划';


-- 调用示例：
-- SELECT * FROM gis_astar_3d_flight_plan_build(
--     112.80, 34.30, 0,
--     114.00, 34.80, 0,
--     120,
--     0,
--     '2c95908e958f3b75019593551f520126',
--     'system',
--     TRUE
-- );

-- SELECT * FROM gis_generate_corridor_fine_grid(
--     '2c95908e958f3b75019593551f520126',
--     ST_GeomFromText('LINESTRING Z (112.80 34.30 0, 114.00 34.80 0)', 4326),
--     0, 300, 20, 'task001', TRUE
-- );

-- SELECT * FROM gis_mark_electric_fence_on_grid(
--     '2c95908e958f3b75019593551f520126',
--     'gis_grid_nodes_fine_task001'
-- );

-- SELECT * FROM gis_mark_buildings_on_grid(
--     '2c95908e958f3b75019593551f520126',
--     'gis_grid_nodes_fine_task001',
--     20
-- );

-- SELECT * FROM gis_astar_3d_flight_plan_on_grid(
--     'gis_grid_nodes_fine_task001',
--     112.80, 34.30, 0,
--     114.00, 34.80, 0,
--     120, 0,
--     '2c95908e958f3b75019593551f520126',
--     'system'
-- );
