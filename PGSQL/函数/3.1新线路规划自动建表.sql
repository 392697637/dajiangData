-- =============================================================================
-- 3.1新线路规划自动建表.sql
--   gis_generate_3d_grid                    生成项目三维飞行网格
--   gis_mark_electric_fence                 标记网格电子围栏障碍
--   gis_refresh_electric_fence              刷新网格电子围栏标记
--   gis_mark_buildings                      标记网格建筑物障碍
--
-- =============================================================================

-- ==============================================
-- PostgreSQL + PostGIS 无人机GIS系统 完整表结构初始化脚本
--
-- 本文件定位：
--   负责把业务区域转换成项目级三维网格，并把电子围栏、项目专属围栏、建筑等障碍数据
--   写入网格的 block_mask/is_flyable 字段。3.2/3.3 的路径规划函数主要读取这里生成的
--   gis_grid_nodes_<project_id> 表。
--
-- 数据流：
--   GeoJSON面 + 高度范围 + 分辨率
--     -> gis_generate_3d_grid 生成 gis_grid_nodes_<project_id>
--     -> gis_mark_electric_fence / gis_refresh_electric_fence 写入电子围栏阻塞位 block_mask & 1
--     -> gis_mark_buildings 写入建筑阻塞位 block_mask & 2
--     -> 3.2/3.3 基于 is_flyable=true 的节点做路径规划
--
-- 使用提醒：
--   1. 文件底部包含 SELECT 调用示例，生产环境批量执行前建议确认是否需要注释示例调用。
--   2. gis_generate_3d_grid 会先删除同名项目网格表再重建，适合初始化/重建，不适合在线增量更新。
--   3. 网格表使用 UNLOGGED 提高写入速度，数据库异常重启后可能丢失，需要永久保存时可改为 LOGGED。
--   4. 分辨率越小数据量按三维近似立方增长，100m适合全局粗网格，20/30m建议只在3.3走廊内生成。
--
-- 返回策略：
--   code=200 表示函数正常完成。
--   code=400 表示输入参数非法。
--   code=500 表示执行过程中出现异常。
--   msg 中包含执行时间，以及具体执行说明。
--
-- 功能说明：
-- 1. 依赖PostGIS扩展实现空间数据存储、空间索引、地理计算
-- 2. 包含电子围栏管理、3D网格路径规划、飞行轨迹记录三大核心模块
-- 3. 所有表/索引统一采用【先删除、后创建】策略，保证脚本幂等性
-- 4. 提供三维网格生成与电子围栏区域标注函数，支持项目级数据隔离
-- ==============================================

-- ====================================================================================  启用PostGIS空间扩展 ==================================================================================== 
-- 为PostgreSQL提供空间几何对象、空间函数、空间索引、地理计算能力
CREATE EXTENSION IF NOT EXISTS postgis;
-- 提供拓扑结构分析、空间数据校验能力（可选增强扩展）
CREATE EXTENSION IF NOT EXISTS postgis_topology;

-- ==================================================================================== 会话级性能加速设置 ====================================================================================
-- 以下设置仅对当前会话生效，可在生成大规模网格数据时提升性能
SET work_mem = '256MB';                        -- 提高排序和哈希操作的内存
SET maintenance_work_mem = '1GB';             -- 提高维护操作（如CREATE INDEX）的内存
SET max_parallel_maintenance_workers = 8;     -- 允许并行创建索引
SET synchronous_commit = OFF;                  -- 关闭同步提交，减少磁盘IO（风险：系统崩溃可能丢失最近事务）


-- ================================================================= gis_generate_3d_grid 生成三维网格节点表====================================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_generate_3d_grid');

-- ==============================================
-- 函数名：gis_generate_3d_grid
-- 功能描述：生成三维网格节点表。根据传入的GeoJSON面范围、高程范围和分辨率，
--          自动计算经纬度边界并生成均匀分布的3D网格点，每个点包含空间坐标（经纬度+高度）及其索引。
-- 参数说明：
--   p_project_id           : 项目ID（必传）。表名变为 gis_grid_nodes_<project_id>，实现项目级数据隔离。
--   p_geojson              : GeoJSON面（Polygon），函数自动解析并计算最小/最大经纬度范围。
--   p_min_alt, p_max_alt   : 高程范围（米），例如 50, 280
--   p_resolution           : 网格分辨率（米），表示相邻网格点之间的水平/垂直间距
-- 返回值：标准TABLE结构
--   code        integer     返回码：200成功，400参数错误，500执行异常
--   table_name  text        生成的网格表名
--   msg         text        返回信息/错误提示
--   count       bigint      生成网格点总数量
-- 注意事项：
--   - 函数使用 UNLOGGED 表且关闭自动清理（autovacuum_enabled=off），以最大化写入速度，
--     适用于一次性构建网格场景。生成完成后建议手动执行 ALTER TABLE ... SET LOGGED 永久化。
--   - 经纬度步长通过分辨率除以111000米（赤道附近1度≈111km）近似换算，高纬度地区可能存在轻微形变，
--     如需精确可实际使用中根据平均纬度调整。
--   - 建表后会自动创建 (x,y,z) 复合索引和 geom 空间索引。
--   - 支持直接传入GeoJSON面，自动计算外接矩形范围，无需手动指定经纬度。
-- ==============================================
-- =============================================================================
-- 函数介绍：gis_generate_3d_grid
-- 主要作用：根据项目范围GeoJSON、高度范围和分辨率，生成项目级三维飞行网格节点表。
-- 入参说明：p_project_id 为项目ID；p_geojson 为面范围；p_min_alt/p_max_alt 为高度范围；p_resolution 为网格间距。
-- 返回说明：返回生成表名、状态信息和网格点数量，供后续围栏、建筑标记和路径规划使用。
-- 注意事项：会删除并重建同名网格表；分辨率越小数据量按三维近似立方增长。
-- =============================================================================
 CREATE OR REPLACE FUNCTION gis_generate_3d_grid(
    p_project_id VARCHAR,
    p_geojson TEXT,
    p_min_alt NUMERIC,
    p_max_alt NUMERIC,
    p_resolution INT
) 
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp(); -- 统计函数总耗时，写入返回msg
    v_table TEXT;                          -- 最终生成的网格表名
    v_idx_prefix TEXT;                     -- 动态索引名前缀，避免项目ID过长导致索引名截断冲突
    v_cnt BIGINT := 0;                     -- 插入网格点的总行数
    v_estimated_count BIGINT := 0;         -- 按外接矩形预估的最大网格点数量
    v_max_grid_count BIGINT := 30000000;   -- 单次生成上限，防止误操作生成超大表
    v_table_regclass REGCLASS;             -- 已存在的目标表对象，存在才删除
    v_lon_max_idx INT;                     -- 经度方向最大网格索引
    v_lat_max_idx INT;                     -- 纬度方向最大网格索引
    v_alt_max_idx INT;                     -- 高度方向最大网格索引
    step_lon DOUBLE PRECISION;             -- 经度方向步长（度）
    step_lat DOUBLE PRECISION;             -- 纬度方向步长（度）
    step_alt DOUBLE PRECISION;             -- 高度方向步长（米）
    v_mid_lat DOUBLE PRECISION;            -- 区域中心纬度，用于修正经度方向步长
    v_lon_meter DOUBLE PRECISION;          -- 当前纬度下1度经度对应米数
    v_geom geometry;                       -- 解析后的GeoJSON几何，仅解析一次
    v_min_lon DOUBLE PRECISION;            -- 从GeoJSON解析出的最小经度
    v_max_lon DOUBLE PRECISION;            -- 从GeoJSON解析出的最大经度
    v_min_lat DOUBLE PRECISION;            -- 从GeoJSON解析出的最小纬度
    v_max_lat DOUBLE PRECISION;            -- 从GeoJSON解析出的最大纬度
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_generate_3d_grid(%L, %L, %s, %s, %s);',
        p_project_id, p_geojson, COALESCE(p_min_alt::text, 'NULL'), COALESCE(p_max_alt::text, 'NULL'), COALESCE(p_resolution::text, 'NULL'));

    -- 初始化返回参数，默认成功状态
    code := 200;
    table_name := '';
    msg := '';
    count := 0;

    -- 提高当前事务内CTAS和索引创建的并行倾向，最终是否并行由PostgreSQL优化器决定
    BEGIN
        PERFORM set_config('max_parallel_workers_per_gather', '8', true);
        PERFORM set_config('max_parallel_workers', '16', true);
        PERFORM set_config('parallel_setup_cost', '0', true);
        PERFORM set_config('parallel_tuple_cost', '0', true);
        PERFORM set_config('min_parallel_table_scan_size', '0', true);
        PERFORM set_config('min_parallel_index_scan_size', '0', true);
        PERFORM set_config('jit', 'off', true);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- ===================== 从GeoJSON字符串自动解析空间范围 =====================
    -- GeoJSON只解析一次，后续复用几何对象和外接矩形范围
    BEGIN
        v_geom := ST_SetSRID(ST_GeomFromGeoJSON(p_geojson), 4326);
        v_geom := ST_MakeValid(v_geom);

        SELECT
            ST_XMin(v_geom),
            ST_XMax(v_geom),
            ST_YMin(v_geom),
            ST_YMax(v_geom)
        INTO v_min_lon, v_max_lon, v_min_lat, v_max_lat;
    EXCEPTION WHEN OTHERS THEN
        code := 400;
        msg := format('参数错误：GeoJSON格式非法，无法解析空间范围，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END;

    -- ===================== 基础参数合法性校验 =====================
    -- 检查范围参数：最小值不能大于等于最大值
    IF v_min_lon >= v_max_lon OR v_min_lat >= v_max_lat OR p_min_alt >= p_max_alt THEN
        code := 400;
        msg := format('参数错误：最小坐标不能大于等于最大坐标，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 检查分辨率：必须大于0
    IF p_resolution <= 0 THEN
        code := 400;
        msg := format('参数错误：分辨率必须大于0，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF GeometryType(v_geom) NOT IN ('POLYGON', 'MULTIPOLYGON') THEN
        code := 400;
        msg := format('参数错误：GeoJSON必须是Polygon或MultiPolygon面数据，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- ===================== 计算网格步长 =====================
    -- 纬度方向约1度=111320米；经度方向按区域中心纬度修正
    v_mid_lat := (v_min_lat + v_max_lat) / 2.0;
    v_lon_meter := 111320.0 * cos(radians(v_mid_lat));

    IF abs(v_lon_meter) < 1 THEN
        code := 400;
        msg := format('参数错误：区域纬度过高，无法按经纬度生成稳定网格，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    step_lat := p_resolution / 111320.0;
    step_lon := p_resolution / v_lon_meter;
    -- 高度步长直接使用分辨率（米）
    step_alt := p_resolution;

    -- ===================== 预估生成数量，避免低分辨率误生成超大表 =====================
    v_lon_max_idx := floor((v_max_lon - v_min_lon) / step_lon)::INT;
    v_lat_max_idx := floor((v_max_lat - v_min_lat) / step_lat)::INT;
    v_alt_max_idx := floor((p_max_alt::DOUBLE PRECISION - p_min_alt::DOUBLE PRECISION) / step_alt)::INT;
    v_estimated_count := (v_lon_max_idx::BIGINT + 1) * (v_lat_max_idx::BIGINT + 1) * (v_alt_max_idx::BIGINT + 1);

    IF v_estimated_count > v_max_grid_count THEN
        code := 400;
        msg := format('参数错误：预计最多生成 %s 个网格点，超过单次上限 %s，请提高分辨率或缩小范围，执行时间 %s 秒', v_estimated_count, v_max_grid_count, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := v_estimated_count;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- ===================== 根据项目ID生成表名 =====================
    -- 项目ID为空使用默认项目表名，不为空则拼接项目ID，并过滤非法字符防止SQL注入
    IF p_project_id IS NULL OR p_project_id = '' THEN
        v_table := 'gis_grid_nodes_default';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;
    v_idx_prefix := 'idx_' || substr(md5(v_table), 1, 12);

    -- ===================== 存在旧表才删除，避免无表场景走DROP异常/通知路径 =====================
    SELECT to_regclass(format('%I.%I', current_schema(), v_table)) INTO v_table_regclass;
    IF v_table_regclass IS NOT NULL THEN
        EXECUTE format('DROP TABLE %s CASCADE;', v_table_regclass);
    END IF;
		
    -- ===================== 批量生成三维网格点并建表 =====================
    -- CTAS避免逐行维护SERIAL/主键；先过滤二维面内点，再展开高度层，减少重复空间判断
    EXECUTE format('
        CREATE UNLOGGED TABLE %I
        WITH (autovacuum_enabled = off) AS
        WITH lon_series AS (
            SELECT
                s_lon::INT AS x,
                ($1 + s_lon * $4)::DOUBLE PRECISION AS lon
            FROM generate_series(0, $10) s_lon
            WHERE ($1 + s_lon * $4) <= $7
        ),
        lat_series AS (
            SELECT
                s_lat::INT AS y,
                ($2 + s_lat * $5)::DOUBLE PRECISION AS lat
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
            SELECT
                s_alt::INT AS z,
                ($3 + s_alt * $6)::DOUBLE PRECISION AS alt
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
        CROSS JOIN z_grid z;
    ', v_table)
    USING v_min_lon, v_min_lat, p_min_alt,
          step_lon, step_lat, step_alt,
          v_max_lon, v_max_lat, p_max_alt,
          v_lon_max_idx, v_lat_max_idx, v_alt_max_idx,
          v_geom;
    GET DIAGNOSTICS v_cnt = ROW_COUNT;

    -- ===================== 补充主键、注释和索引 =====================
    EXECUTE format('ALTER TABLE %I ALTER COLUMN id SET NOT NULL;', v_table);
    EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I PRIMARY KEY (id);', v_table, v_table || '_pkey');

    EXECUTE format('COMMENT ON TABLE %I IS ''项目三维网格节点表：用于电子围栏、建筑、地形、倾斜摄影、DEM等多源打标'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.id IS ''网格节点主键ID，按x/y/z计算生成'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.x IS ''网格X索引，经度方向'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.y IS ''网格Y索引，纬度方向'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.z IS ''网格Z索引，高度方向'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.lon IS ''经度'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.lat IS ''纬度'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.alt IS ''绝对高度或当前系统统一高度基准，单位：米'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.is_flyable IS ''是否可飞：true=可参与路径规划，false=不可通行'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.zone_type IS ''电子围栏区域类型：禁飞区/管控区/适飞区'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.block_mask IS ''阻塞位标记：1电子围栏，2建筑，4地形，8倾斜摄影，16 DEM，32国家空域规则'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.geom2d IS ''二维空间点，WGS84经纬度坐标系'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.geom IS ''三维空间点，WGS84经纬度坐标系 + 高度'';', v_table);

    count := v_cnt;

    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I (x, y, z);', v_idx_prefix || '_xyz', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (x, y, z) WHERE is_flyable = true;', v_idx_prefix || '_fly_xyz', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (x, y) WHERE is_flyable = true;', v_idx_prefix || '_fly_xy', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (block_mask) WHERE block_mask <> 0;', v_idx_prefix || '_mask', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST(geom2d) WHERE z = 0;', v_idx_prefix || '_geom2d_z0', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST(geom);', v_idx_prefix || '_geom', v_table);

    -- ===================== 恢复autovacuum并更新表统计信息 =====================
    EXECUTE format('ALTER TABLE %I SET (autovacuum_enabled = on); ANALYZE %I;', v_table, v_table);

    -- ===================== 执行成功，返回结果 =====================
    msg := format('三维网格生成成功，共生成 %s 个点，执行时间 %s 秒', v_cnt, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;

-- ===================== 全局异常捕获 =====================
EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := format('生成失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_generate_3d_grid(VARCHAR, TEXT, NUMERIC, NUMERIC, INT) IS '生成项目三维飞行网格';
 
-- ========================================== gis_mark_electric_fence  更新三维网格表============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_mark_electric_fence');
 
-- ==============================================
-- 函数名：gis_mark_electric_fence
-- 功能描述：根据电子围栏表 bo_electric_fence 中的数据，更新三维网格表中每个点的 zone_type。
--          根据围栏的 fence_type 字段进行映射：
--            '1' → '禁飞区'
--            '2' → '管控区'
--            '3' → '适飞区'
--          当一个网格点同时落在多个围栏内时，按照优先级选取：禁飞区 > 管控区 > 适飞区。
--          同时维护 block_mask 第1位和 is_flyable：
--            禁飞区/管控区：block_mask | 1，is_flyable=false
--            适飞区：仅记录 zone_type，不清除建筑/地形等其他阻塞位
-- 参数：p_project_id - 项目ID（可选，空字符串或NULL表示操作默认表 gis_grid_nodes）
-- 返回值：标准TABLE结构
--   code        integer     返回码：200成功，400参数错误，500执行异常
--   table_name  text        操作的网格表名
--   msg         text        执行结果描述
--   count       bigint      更新的记录行数
-- 优化点：
--   - 使用临时表存储受影响的网格ID及其应设置的最高优先级区域类型。
--   - 利用 ST_Intersects 空间连接和 DISTINCT ON + 排序实现每个网格仅选优先级最高的区域。
--   - 批量更新仅修改 zone_type 实际发生变化的行，减少写IO。
--   - 通过 project_id 过滤围栏数据，支持多项目隔离。
-- 注意事项：
--   - 调用前需确保三维网格表已通过 gis_generate_3d_grid 生成。
--   - 围栏数据必须包含有效的 geometry 和 height（限制高度），且 fence_type 在 ('1','2','3') 范围内。
--   - height 为空或0时表示不限高；否则仅标记 alt <= height 的网格层。
--   - 如果存在 gis_electric_fence_<project_id> 项目专属围栏表，会与 bo_electric_fence 合并打标。
-- ==============================================
-- =============================================================================
-- 函数介绍：gis_mark_electric_fence
-- 主要作用：把当前有效电子围栏写入项目三维网格，标记禁飞区、管控区等不可飞节点。
-- 入参说明：p_project_id 为项目ID；为空时使用默认网格表和全局围栏范围。
-- 返回说明：返回网格表名、更新数量和执行消息，用于确认围栏障碍标记结果。
-- 注意事项：函数会维护block_mask、zone_type和is_flyable字段，执行前需先生成网格表。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_mark_electric_fence(p_project_id VARCHAR DEFAULT '')
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_table TEXT;
    v_updated_rows BIGINT := 0;
    v_cleared_rows BIGINT := 0;
    v_start timestamptz := clock_timestamp();
    v_step_start timestamptz;
    v_extent box3d;
    v_col_exists boolean;
    v_geom_col TEXT;
    v_project_fence_table TEXT;
    v_project_fence_regclass REGCLASS;
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_mark_electric_fence(%L);',
        p_project_id);

    v_step_start := clock_timestamp();
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
        v_project_fence_table := NULL;
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
        v_project_fence_table := 'gis_electric_fence_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;
    RAISE NOTICE '[gis_mark_electric_fence] table: %, elapsed: %', v_table, clock_timestamp() - v_step_start;

    IF to_regclass(format('%I.%I', current_schema(), v_table)) IS NULL THEN
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', v_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    v_step_start := clock_timestamp();
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_table
          AND c.column_name = 'zone_type'
    ) INTO v_col_exists;

    IF NOT v_col_exists THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN zone_type VARCHAR(20);', v_table);
    END IF;
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0;', v_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true;', v_table);

    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (%I) WHERE z = 0;',
        'idx_' || substr(md5(v_table), 1, 12) || '_' || v_geom_col || '_z0',
        v_table,
        v_geom_col
    );
    RAISE NOTICE '[gis_mark_electric_fence] prepare columns elapsed: %', clock_timestamp() - v_step_start;

    v_step_start := clock_timestamp();
    DROP TABLE IF EXISTS tmp_mark_electric_fence;
    CREATE TEMP TABLE tmp_mark_electric_fence (
        id text,
        source_table text,
        priority int,
        zone_type varchar(20),
        max_height double precision,
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    INSERT INTO tmp_mark_electric_fence (
        id, source_table, priority, zone_type, max_height, geom4326
    )
    SELECT
        id::text,
        'bo_electric_fence',
        CASE fence_type WHEN '1' THEN 10 WHEN '2' THEN 20 WHEN '3' THEN 30 END AS priority,
        CASE fence_type
            WHEN '1' THEN '禁飞区'
            WHEN '2' THEN '管控区'
            WHEN '3' THEN '适飞区'
        END::varchar(20) AS zone_type,
        NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
        ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
    FROM bo_electric_fence
    WHERE del_flag = false
      AND status = '1'
      AND geom IS NOT NULL
      AND fence_type IN ('1','2','3')
      AND (COALESCE(p_project_id, '') = '' OR project_id::text = p_project_id::text);

    IF v_project_fence_table IS NOT NULL THEN
        SELECT to_regclass(format('%I.%I', current_schema(), v_project_fence_table)) INTO v_project_fence_regclass;
        IF v_project_fence_regclass IS NOT NULL THEN
            EXECUTE format('
                INSERT INTO tmp_mark_electric_fence (
                    id, source_table, priority, zone_type, max_height, geom4326
                )
                SELECT
                    id::text,
                    %L,
                    CASE fence_type WHEN ''1'' THEN 10 WHEN ''2'' THEN 20 END AS priority,
                    CASE fence_type
                        WHEN ''1'' THEN ''禁飞区''
                        WHEN ''2'' THEN ''管控区''
                    END::varchar(20) AS zone_type,
                    NULL::double precision AS max_height,
                    ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
                FROM %s
                WHERE geom IS NOT NULL
                  AND fence_type IN (''1'',''2'')
            ', v_project_fence_table, v_project_fence_regclass);
        END IF;
    END IF;

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_electric_fence_geom ON tmp_mark_electric_fence USING GIST (geom4326);
    ANALYZE tmp_mark_electric_fence;

    SELECT ST_Extent(geom4326) INTO v_extent FROM tmp_mark_electric_fence;

    IF v_extent IS NULL THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~1,
                is_flyable = ((COALESCE(block_mask, 0) & ~1) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 1) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;
        count := v_cleared_rows;
        code := 200;
        msg := format('无有效电子围栏，已清空 %s 条标记，执行时间 %s 秒', v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;
    RAISE NOTICE '[gis_mark_electric_fence] materialize fences elapsed: %', clock_timestamp() - v_step_start;

    v_step_start := clock_timestamp();
    DROP TABLE IF EXISTS tmp_mark_desired_zone;
    EXECUTE format('
        CREATE TEMP TABLE tmp_mark_desired_zone ON COMMIT DROP AS
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
            JOIN tmp_mark_electric_fence f
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
    ', v_geom_col, v_table, v_geom_col, v_table)
    USING ST_XMin(v_extent), ST_YMin(v_extent), ST_XMax(v_extent), ST_YMax(v_extent);

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_desired_zone_id ON tmp_mark_desired_zone(id);
    ANALYZE tmp_mark_desired_zone;

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
        FROM tmp_mark_desired_zone t
        WHERE n.id = t.id
          AND (
              n.zone_type IS DISTINCT FROM t.zone_type
              OR n.block_mask IS DISTINCT FROM CASE
                    WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN COALESCE(n.block_mask, 0) | 1
                    ELSE COALESCE(n.block_mask, 0) & ~1
                 END
              OR n.is_flyable IS DISTINCT FROM CASE
                    WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN false
                    ELSE ((COALESCE(n.block_mask, 0) & ~1) = 0)
                 END
          )
    ', v_table);
    GET DIAGNOSTICS v_updated_rows = ROW_COUNT;

    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = NULL,
            block_mask = COALESCE(n.block_mask, 0) & ~1,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~1) = 0)
        WHERE (n.zone_type IS NOT NULL OR (COALESCE(n.block_mask, 0) & 1) <> 0)
          AND NOT EXISTS (SELECT 1 FROM tmp_mark_desired_zone t WHERE t.id = n.id)
    ', v_table);
    GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

    count := v_updated_rows + v_cleared_rows;
    code := 200;
    msg := format('电子围栏标记完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start)::numeric, 3));
    RAISE NOTICE '[gis_mark_electric_fence] update elapsed: %, affected: %', clock_timestamp() - v_step_start, count;
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start)::numeric, 3));
    count := 0;
    table_name := v_table;
    RAISE NOTICE '[gis_mark_electric_fence] error: %', SQLERRM;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_mark_electric_fence(VARCHAR) IS '标记网格电子围栏障碍';
 

 
-- ============================================================ gis_refresh_electric_fence  重置所有网格====================================================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_refresh_electric_fence');

-- ==============================================
-- 函数名：gis_refresh_electric_fence
-- 功能描述：刷新三维网格的电子围栏标记。先清空已标记的zone_type，再重新标记。
-- 参数：p_project_id - 项目ID（可选，空表示公共表）
--       p_refresh_json - 可选刷新JSON；包含fence_id时只刷新该围栏影响范围。
-- 返回值：标准TABLE结构
--   code        integer     返回码：200成功，500执行异常
--   table_name  text        操作的网格表名
--   msg         text        结果描述
--   count       bigint      更新记录数
-- 适用场景：电子围栏数据修改后，快速刷新网格区域标记
-- 说明：
--   - 局部刷新会先找到指定围栏范围，再把该范围内所有可能重叠的有效围栏重新计算一遍；
--   - 如果围栏已经被物理删除且无法找到原 geom，无法确定影响范围，只能做全量刷新；
--   - 推荐业务删除围栏时使用软删除，然后调用本函数局部刷新。
-- ==============================================
-- =============================================================================
-- 函数介绍：gis_refresh_electric_fence
-- 主要作用：刷新网格中的电子围栏标记，可全量刷新，也可按单个围栏局部刷新。
-- 入参说明：p_project_id 为项目ID；p_refresh_json 为空或不含fence_id时全量刷新，包含fence_id时按围栏范围局部刷新。
-- 返回说明：返回清除和更新后的总影响行数，以及本次刷新状态信息。
-- 注意事项：局部刷新依赖围栏原始geom确定影响范围；删除围栏后建议保留软删除记录再刷新。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence(
    p_project_id VARCHAR DEFAULT '',
    p_refresh_json jsonb DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_updated_match_rows BIGINT := 0;
    v_cleared_rows BIGINT := 0;
    v_geom_col TEXT;
    v_project_fence_table TEXT;
    v_project_fence_regclass REGCLASS;
    v_scope_extent box3d;
    v_fence_id varchar;
    v_is_partial boolean;
    v_start_time timestamptz := clock_timestamp();
    v_action text;
    v_fence_type text;
    v_new_geojson jsonb;
    v_old_geojson jsonb;
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_fence_id := COALESCE(
        p_refresh_json ->> 'fence_id',
        p_refresh_json ->> 'fenceId',
        p_refresh_json ->> 'id'
    );
    v_is_partial := COALESCE(NULLIF(btrim(v_fence_id), ''), '') <> '';

    v_log_sql := format('SELECT * FROM public.gis_refresh_electric_fence(%L, %L);',
        p_project_id, p_refresh_json);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        table_name := '';
        msg := format('参数错误：项目ID不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_project_fence_table := 'gis_electric_fence_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    table_name := v_table;
    SELECT to_regclass(format('%I.%I', current_schema(), v_project_fence_table)) INTO v_project_fence_regclass;

    IF v_project_fence_regclass IS NULL THEN
        code := 500;
        msg := format('执行异常：电子围栏表不存在：%s，执行时间 %s 秒', v_project_fence_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF to_regclass(format('%I.%I', current_schema(), v_table)) IS NULL THEN
        code := 500;
        msg := format('执行异常：网格表不存在：%s，执行时间 %s 秒', v_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20);', v_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0;', v_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true;', v_table);

    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (%I) WHERE z = 0;',
        'idx_' || substr(md5(v_table), 1, 12) || '_' || v_geom_col || '_z0',
        v_table,
        v_geom_col
    );

    IF NOT v_is_partial THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~1,
                is_flyable = ((COALESCE(block_mask, 0) & ~1) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 1) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

        RETURN QUERY
        SELECT
            m.code,
            m.table_name,
            format('已清空 %s 条电子围栏标记；%s', v_cleared_rows, m.msg)::text AS msg,
            (v_cleared_rows + COALESCE(m.count, 0))::bigint AS count
        FROM gis_mark_electric_fence(p_project_id) AS m;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS tmp_refresh_electric_fence;
    CREATE TEMP TABLE tmp_refresh_electric_fence (
        id text,
        source_table text,
        priority int,
        zone_type varchar(20),
        max_height double precision,
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    DROP TABLE IF EXISTS tmp_refresh_scope_fence;
    CREATE TEMP TABLE tmp_refresh_scope_fence (
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    IF v_is_partial THEN
        IF p_refresh_json IS NOT NULL THEN
            v_action := lower(COALESCE(
                p_refresh_json ->> 'action',
                p_refresh_json ->> 'operate',
                p_refresh_json ->> 'operation',
                p_refresh_json ->> 'type',
                ''
            ));
            v_fence_type := COALESCE(p_refresh_json ->> 'fence_type', p_refresh_json ->> 'fenceType');
            v_new_geojson := COALESCE(
                p_refresh_json -> 'geojson',
                p_refresh_json -> 'geom',
                p_refresh_json -> 'geometry',
                p_refresh_json -> 'new_geojson',
                p_refresh_json -> 'newGeom',
                p_refresh_json -> 'new_geometry'
            );
            v_old_geojson := COALESCE(
                p_refresh_json -> 'old_geojson',
                p_refresh_json -> 'oldGeom',
                p_refresh_json -> 'old_geometry'
            );

            IF v_action IN ('add', 'insert', 'create', '新增') THEN
                IF v_new_geojson IS NULL THEN
                    code := 400;
                    msg := format('参数错误：新增刷新必须提供geojson，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                INSERT INTO tmp_refresh_scope_fence (geom4326)
                SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);

            ELSIF v_action IN ('edit', 'update', 'modify', '编辑') THEN
                IF v_new_geojson IS NULL THEN
                    code := 400;
                    msg := format('参数错误：编辑刷新必须提供geojson，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                IF v_new_geojson IS NOT NULL THEN
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
                END IF;

                IF v_old_geojson IS NOT NULL THEN
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_old_geojson ->> 'type' = 'Feature' THEN v_old_geojson ->> 'geometry' ELSE v_old_geojson::text END)), 4326);
                END IF;

            ELSIF v_action IN ('delete', 'remove', 'del', '删除') THEN
                IF v_new_geojson IS NOT NULL THEN
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
                END IF;
            ELSE
                code := 400;
                msg := format('参数错误：refresh_json.action必须是新增/编辑/删除，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                count := 0;
                INSERT INTO public.gis_error_log(code, msg, sqlstring)
                VALUES (code, msg, v_log_sql);
                RETURN NEXT;
                RETURN;
            END IF;

            IF v_fence_type IS NULL OR v_fence_type NOT IN ('1', '2', '3') THEN
                code := 400;
                msg := format('参数错误：fence_type必须是1/2/3，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                count := 0;
                INSERT INTO public.gis_error_log(code, msg, sqlstring)
                VALUES (code, msg, v_log_sql);
                RETURN NEXT;
                RETURN;
            END IF;
        END IF;

        INSERT INTO tmp_refresh_scope_fence (geom4326)
        SELECT ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
        FROM bo_electric_fence
        WHERE id::text = v_fence_id::text
          AND geom IS NOT NULL
          AND (COALESCE(p_project_id, '') = '' OR project_id::TEXT = p_project_id::TEXT);

        IF v_project_fence_table IS NOT NULL AND v_project_fence_regclass IS NOT NULL THEN
            EXECUTE format('
                INSERT INTO tmp_refresh_scope_fence (geom4326)
                SELECT ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
                FROM %s
                WHERE id::text = $1
                  AND geom IS NOT NULL
            ', v_project_fence_regclass)
            USING v_fence_id;
        END IF;

        SELECT ST_Extent(geom4326) INTO v_scope_extent FROM tmp_refresh_scope_fence;

        IF v_scope_extent IS NULL THEN
            code := 400;
            msg := format('参数错误：未找到可刷新的电子围栏或围栏无geom：%s，执行时间 %s 秒', v_fence_id, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            count := 0;
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (code, msg, v_log_sql);
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    INSERT INTO tmp_refresh_electric_fence (
        id, source_table, priority, zone_type, max_height, geom4326
    )
    SELECT
        id::text,
        'bo_electric_fence',
        CASE fence_type WHEN '1' THEN 10 WHEN '2' THEN 20 WHEN '3' THEN 30 END AS priority,
        CASE fence_type
            WHEN '1' THEN '禁飞区'
            WHEN '2' THEN '管控区'
            WHEN '3' THEN '适飞区'
        END::varchar(20) AS zone_type,
        NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
        ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
    FROM bo_electric_fence
    WHERE del_flag = false
      AND status = '1'
      AND geom IS NOT NULL
      AND fence_type IN ('1', '2', '3')
      AND (COALESCE(p_project_id, '') = '' OR project_id::TEXT = p_project_id::TEXT)
      AND (
          NOT v_is_partial
          OR ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope(
              ST_XMin(v_scope_extent), ST_YMin(v_scope_extent),
              ST_XMax(v_scope_extent), ST_YMax(v_scope_extent), 4326
          )
      );

    IF v_project_fence_table IS NOT NULL THEN
        IF v_project_fence_regclass IS NOT NULL THEN
            EXECUTE format('
                INSERT INTO tmp_refresh_electric_fence (
                    id, source_table, priority, zone_type, max_height, geom4326
                )
                SELECT
                    id::text,
                    %L,
                    CASE fence_type WHEN ''1'' THEN 10 WHEN ''2'' THEN 20 END AS priority,
                    CASE fence_type
                        WHEN ''1'' THEN ''禁飞区''
                        WHEN ''2'' THEN ''管控区''
                    END::varchar(20) AS zone_type,
                    NULL::double precision AS max_height,
                    ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
                FROM %s
                WHERE geom IS NOT NULL
                  AND fence_type IN (''1'',''2'')
                  AND (
                      NOT $1
                      OR ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope($2, $3, $4, $5, 4326)
                  )
            ', v_project_fence_table, v_project_fence_regclass)
            USING v_is_partial,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_XMin(v_scope_extent) END,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_YMin(v_scope_extent) END,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_XMax(v_scope_extent) END,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_YMax(v_scope_extent) END;
        END IF;
    END IF;

    CREATE INDEX IF NOT EXISTS idx_tmp_refresh_electric_fence_geom ON tmp_refresh_electric_fence USING GIST (geom4326);
    ANALYZE tmp_refresh_electric_fence;

    IF NOT v_is_partial THEN
        SELECT ST_Extent(geom4326) INTO v_scope_extent FROM tmp_refresh_electric_fence;
    END IF;

    IF v_scope_extent IS NULL THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~1,
                is_flyable = ((COALESCE(block_mask, 0) & ~1) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 1) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;
        count := v_cleared_rows;
        code := 200;
        msg := format('无有效电子围栏，已清空 %s 条标记，执行时间 %s 秒', v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS tmp_refresh_scope_xy;
    EXECUTE format('
        CREATE TEMP TABLE tmp_refresh_scope_xy ON COMMIT DROP AS
        SELECT DISTINCT x, y, %I AS geom2d
        FROM %I
        WHERE z = 0
          AND %I && ST_MakeEnvelope($1, $2, $3, $4, 4326)
    ', v_geom_col, v_table, v_geom_col)
    USING ST_XMin(v_scope_extent), ST_YMin(v_scope_extent), ST_XMax(v_scope_extent), ST_YMax(v_scope_extent);

    CREATE INDEX IF NOT EXISTS idx_tmp_refresh_scope_xy ON tmp_refresh_scope_xy (x, y);
    ANALYZE tmp_refresh_scope_xy;

    DROP TABLE IF EXISTS tmp_desired_zone;
    EXECUTE format(' 
        CREATE TEMP TABLE tmp_desired_zone ON COMMIT DROP AS
        WITH xy_match AS MATERIALIZED (
            SELECT
                n.x,
                n.y,
                f.zone_type,
                f.max_height,
                f.priority,
                f.id AS fence_id
            FROM (
                SELECT x, y, geom2d
                FROM tmp_refresh_scope_xy
            ) n
            JOIN tmp_refresh_electric_fence f
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
    ', v_table);

    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tmp_desired_zone_id ON tmp_desired_zone(id);';
    EXECUTE 'ANALYZE tmp_desired_zone;';

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
        FROM tmp_desired_zone t
        WHERE n.id = t.id
          AND (
              n.zone_type IS DISTINCT FROM t.zone_type
              OR n.block_mask IS DISTINCT FROM CASE
                    WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN COALESCE(n.block_mask, 0) | 1
                    ELSE COALESCE(n.block_mask, 0) & ~1
                 END
              OR n.is_flyable IS DISTINCT FROM CASE
                    WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN false
                    ELSE ((COALESCE(n.block_mask, 0) & ~1) = 0)
                 END
          )
    ', v_table);
    GET DIAGNOSTICS v_updated_match_rows = ROW_COUNT;

    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = NULL,
            block_mask = COALESCE(n.block_mask, 0) & ~1,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~1) = 0)
        WHERE (n.zone_type IS NOT NULL OR (COALESCE(n.block_mask, 0) & 1) <> 0)
          AND EXISTS (SELECT 1 FROM tmp_refresh_scope_xy s WHERE s.x = n.x AND s.y = n.y)
          AND NOT EXISTS (SELECT 1 FROM tmp_desired_zone t WHERE t.id = n.id)
    ', v_table);
    GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

    count := v_updated_match_rows + v_cleared_rows;
    code := 200;
    msg := CASE
        WHEN v_is_partial THEN format('按围栏 %s 局部刷新完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_fence_id, v_updated_match_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
        ELSE format('按 bo_electric_fence 当前有效数据和项目专属围栏刷新完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated_match_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
    END;
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_table;
    msg := format('刷新失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_refresh_electric_fence(VARCHAR, jsonb) IS '刷新网格电子围栏标记';
 


-- ========================================== gis_mark_buildings  根据建筑表标记三维网格障碍============================================================
-- 功能说明：
--   1. 根据项目建筑表 gis_buildings_<project_id> 标记三维网格中的建筑障碍。
--   2. 命中的网格设置 block_mask 第2位：block_mask | 2，并将 is_flyable=false。
--   3. 未命中的旧建筑标记会清除：block_mask & ~2，并按剩余阻塞位重算 is_flyable。
-- 性能优化：
--   - 先把建筑几何物化到临时表并创建 GiST 索引；
--   - 再按建筑总体空间范围裁剪 z=0 平面网格；
--   - 先做二维 x/y 命中，再展开高度层，避免全量三维网格和所有建筑直接空间连接。
-- 参数：
--   p_project_id       项目ID，不能为空。
--   p_building_buffer  建筑缓冲距离，单位米；100m 粗网格建议 30~50，避免小建筑漏标。
-- 返回：
--   code/table_name/msg/count，其中 count=更新建筑阻塞位 + 清除旧建筑阻塞位的行数。
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_mark_buildings');

-- =============================================================================
-- 函数介绍：gis_mark_buildings
-- 主要作用：根据项目建筑表，把建筑占用范围标记到三维网格中，形成建筑障碍。
-- 入参说明：p_project_id 为项目ID；p_building_buffer 为建筑平面缓冲距离，单位米。
-- 返回说明：返回网格表名、更新数量和执行消息，供路径规划前确认建筑障碍数据。
-- 注意事项：依赖gis_buildings_<project_id>和gis_grid_nodes_<project_id>；缓冲值可降低小建筑漏标风险。
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
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
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
        msg := format('无有效建筑数据，已清空 %s 条建筑标记，执行时间 %s 秒', v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
    msg := format('建筑打标完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_grid_table;
    msg := format('建筑打标失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_mark_buildings(VARCHAR, DOUBLE PRECISION) IS '标记网格建筑物障碍';

-- =============================================================================
-- 函数调用示例
-- =============================================================================
-- SELECT * FROM gis_generate_3d_grid(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Polygon","coordinates":[[[112.70,34.20],[114.20,34.20],[114.20,35.00],[112.70,35.00],[112.70,34.20]]]}',
--     0,
--     300,
--     100
-- );

-- SELECT * FROM gis_mark_electric_fence('2c95908e958f3b75019593551f520126');

-- 当围栏数据发生变更（如新增、修改、删除），调用此函数刷新全部区域标记。
-- SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126', NULL::jsonb);

-- 只刷新指定围栏影响范围。
-- SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126', '{"fence_id":"围栏ID"}'::jsonb);

-- 新增围栏后：用新geojson确定刷新范围
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '围栏ID',
--     '{"action":"add","fence_type":"1","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'::jsonb
-- );

-- 编辑围栏后：用新geojson + old_geojson共同确定刷新范围；old_geojson不传时按围栏ID查询
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '围栏ID',
--     '{"action":"edit","fence_type":"2","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.3,34.1],[113.3,34.3],[113.1,34.3],[113.1,34.1]]]},"old_geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'::jsonb
-- );

-- 删除围栏后：优先用geojson确定旧范围；geojson不传时按围栏ID查询
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '围栏ID',
--     '{"action":"delete","fence_type":"3","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'::jsonb
-- );

-- SELECT * FROM gis_mark_buildings('2c95908e958f3b75019593551f520126');
