-- =============================================================================
-- 3.1粗三维网格生成.sql
--   gis_generate_3d_grid                    生成项目三维飞行网格
--
-- =============================================================================

-- ==============================================
-- PostgreSQL + PostGIS 无人机GIS系统 完整表结构初始化脚本
--
-- 本文件定位：
--   负责把业务区域转换成项目级粗三维网格，生成 gis_grid_nodes_<project_id> 表。
--   电子围栏、建筑等障碍打标由后续脚本按需写入 block_mask/is_flyable 字段。
--
-- 数据流：
--   GeoJSON面 + 高度范围 + 分辨率
--     -> gis_generate_3d_grid 生成 gis_grid_nodes_<project_id>
--     -> 3.2电子围栏打标记.sql 写入电子围栏阻塞位 block_mask & 1
--     -> 建筑阻塞位 block_mask & 2 由 4.2建筑标记.sql 中的 gis_mark_buildings 写入
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
-- 2. 本文件只包含项目粗三维网格生成函数
-- 3. 所有表/索引统一采用【先删除、后创建】策略，保证脚本幂等性
-- 4. 生成项目级网格表，支持项目级数据隔离
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
 
