-- ==============================================
-- PostgreSQL + PostGIS 无人机GIS系统 完整表结构初始化脚本
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
-- 由于函数可能存在多个重载，这里通过系统表动态删除所有名为 gis_generate_3d_grid 的函数
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc
              WHERE proname = 'gis_generate_3d_grid')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.oid::regproc || '(' || r.args || ') CASCADE';
    END LOOP;
END;
$$;

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
BEGIN
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
        msg := '参数错误：GeoJSON格式非法，无法解析空间范围';
        RETURN NEXT;
        RETURN;
    END;

    -- ===================== 基础参数合法性校验 =====================
    -- 检查范围参数：最小值不能大于等于最大值
    IF v_min_lon >= v_max_lon OR v_min_lat >= v_max_lat OR p_min_alt >= p_max_alt THEN
        code := 400;
        msg := '参数错误：最小坐标不能大于等于最大坐标';
        RETURN NEXT;
        RETURN;
    END IF;

    -- 检查分辨率：必须大于0
    IF p_resolution <= 0 THEN
        code := 400;
        msg := '参数错误：分辨率必须大于0';
        RETURN NEXT;
        RETURN;
    END IF;

    IF GeometryType(v_geom) NOT IN ('POLYGON', 'MULTIPOLYGON') THEN
        code := 400;
        msg := '参数错误：GeoJSON必须是Polygon或MultiPolygon面数据';
        RETURN NEXT;
        RETURN;
    END IF;

    -- ===================== 计算网格步长 =====================
    -- 纬度方向约1度=111320米；经度方向按区域中心纬度修正
    v_mid_lat := (v_min_lat + v_max_lat) / 2.0;
    v_lon_meter := 111320.0 * cos(radians(v_mid_lat));

    IF abs(v_lon_meter) < 1 THEN
        code := 400;
        msg := '参数错误：区域纬度过高，无法按经纬度生成稳定网格';
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
        msg := format('参数错误：预计最多生成 %s 个网格点，超过单次上限 %s，请提高分辨率或缩小范围', v_estimated_count, v_max_grid_count);
        count := v_estimated_count;
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
        WITH xy_grid AS (
            SELECT
                s_lon AS x,
                s_lat AS y,
                ($1 + s_lon * $4)::DOUBLE PRECISION AS lon,
                ($2 + s_lat * $5)::DOUBLE PRECISION AS lat,
                ST_SetSRID(
                    ST_MakePoint($1 + s_lon * $4, $2 + s_lat * $5),
                    4326
                )::geometry(Point,4326) AS geom2d
            FROM
                generate_series(0, $10) s_lon,
                generate_series(0, $11) s_lat
            WHERE ($1 + s_lon * $4) <= $7
              AND ($2 + s_lat * $5) <= $8
              AND ST_Covers($13::geometry, ST_SetSRID(ST_MakePoint($1 + s_lon * $4, $2 + s_lat * $5), 4326))
        ),
        z_grid AS (
            SELECT
                s_alt AS z,
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
            0::DOUBLE PRECISION AS ground_alt,
            z.alt::DOUBLE PRECISION AS relative_alt,
            true::BOOLEAN AS is_flyable,
            0::SMALLINT AS risk_level,
            NULL::VARCHAR(20) AS zone_type,
            0::INT AS block_mask,
            NULL::VARCHAR(30) AS obstacle_type,
            NULL::VARCHAR(64) AS obstacle_id,
            ''{}''::JSONB AS source_flags,
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
    EXECUTE format('COMMENT ON COLUMN %I.ground_alt IS ''地面高程，来自DEM/地形数据，单位：米'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.relative_alt IS ''相对地面高度：alt - ground_alt，单位：米'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.is_flyable IS ''是否可飞：true=可参与路径规划，false=不可通行'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.risk_level IS ''综合风险等级：0安全，1低，2中，3高，9不可飞'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.zone_type IS ''电子围栏区域类型：禁飞区/管控区/适飞区'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.block_mask IS ''阻塞位标记：1电子围栏，2建筑，4地形，8倾斜摄影，16 DEM'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.obstacle_type IS ''障碍类型：建筑/地形/倾斜模型/DEM等'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.obstacle_id IS ''命中的障碍对象ID'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.source_flags IS ''多源数据命中详情，用于调试和溯源'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.geom2d IS ''二维空间点，WGS84经纬度坐标系'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.geom IS ''三维空间点，WGS84经纬度坐标系 + 高度'';', v_table);

    EXECUTE format('SELECT count(*)::BIGINT FROM %I;', v_table) INTO v_cnt;
    count := v_cnt;

    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I (x, y, z);', v_idx_prefix || '_xyz', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (x, y, z) WHERE is_flyable = true;', v_idx_prefix || '_fly_xyz', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (x, y) WHERE is_flyable = true;', v_idx_prefix || '_fly_xy', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (zone_type);', v_idx_prefix || '_zone', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (block_mask);', v_idx_prefix || '_mask', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST(geom2d);', v_idx_prefix || '_geom2d', v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST(geom);', v_idx_prefix || '_geom', v_table);

    -- ===================== 恢复autovacuum并更新表统计信息 =====================
    EXECUTE format('ALTER TABLE %I SET (autovacuum_enabled = on); ANALYZE %I;', v_table, v_table);

    -- ===================== 执行成功，返回结果 =====================
    msg := format('三维网格生成成功，共生成 %s 个点', v_cnt);
    RETURN NEXT;

-- ===================== 全局异常捕获 =====================
EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := '生成失败：' || SQLERRM;
    count := 0;
    RETURN NEXT;
END;
$$;
-- ===================== 函数调用示例 =====================
 
SELECT * FROM gis_generate_3d_grid(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Polygon","coordinates":[[[112.70,34.20],[114.20,34.20],[114.20,35.00],[112.70,35.00],[112.70,34.20]]]}',
    50,
    300,
    100
);
 
-- ========================================== gis_mark_electric_fence  更新三维网格表============================================================
-- ===================== 删除可能存在的同名函数（保证幂等性） =====================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc
              WHERE proname = 'gis_mark_electric_fence')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.oid::regproc || '(' || r.args || ') CASCADE';
    END LOOP;
END;
$$;
 
-- ==============================================
-- 函数名：gis_mark_electric_fence
-- 功能描述：根据电子围栏表 bo_electric_fence 中的数据，更新三维网格表中每个点的 zone_type。
--          根据围栏的 fence_type 字段进行映射：
--            '1' → '禁飞区'
--            '2' → '管控区'
--            '3' → '适飞区'
--          当一个网格点同时落在多个围栏内时，按照优先级选取：禁飞区 > 管控区 > 适飞区。
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
-- ==============================================
CREATE OR REPLACE FUNCTION gis_mark_electric_fence(p_project_id VARCHAR DEFAULT '')
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_table TEXT;
    v_cnt BIGINT;
    v_start timestamptz;
    v_step_start timestamptz;
    v_filter_geom geometry;
    v_extent box3d;
    v_col_exists boolean;
BEGIN
    v_start := clock_timestamp();
    RAISE NOTICE '[开始] %', v_start;

    -- 步骤1：表名
    v_step_start := clock_timestamp();
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;
    RAISE NOTICE '[步骤1] 表名: %，耗时: %', v_table, clock_timestamp() - v_step_start;

    -- 步骤2：检查 zone_type 列是否存在，使用别名避免歧义
    v_step_start := clock_timestamp();
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = current_schema() AND c.table_name = v_table AND c.column_name = 'zone_type'
    ) INTO v_col_exists;
    IF NOT v_col_exists THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN zone_type VARCHAR(20);', v_table);
        RAISE NOTICE '[步骤2] 已添加 zone_type 列，耗时: %', clock_timestamp() - v_step_start;
    ELSE
        RAISE NOTICE '[步骤2] zone_type 列已存在，跳过，耗时: %', clock_timestamp() - v_step_start;
    END IF;

    -- 步骤3：外包矩形（极速）
    v_step_start := clock_timestamp();
    RAISE NOTICE '[步骤3] 计算围栏外包矩形...';
    EXECUTE format('
        SELECT ST_Extent(ST_SetSRID(geom, 4326))
        FROM bo_electric_fence
        WHERE del_flag = false
          AND fence_type IN (''1'',''2'',''3'')
          AND (%L = '''' OR project_id = %L)
    ', p_project_id, p_project_id) INTO v_extent;

    IF v_extent IS NULL THEN
        RAISE NOTICE '[步骤3] 无围栏，清空标记';
        EXECUTE format('UPDATE %I SET zone_type = NULL WHERE zone_type IS NOT NULL', v_table);
        GET DIAGNOSTICS v_cnt = ROW_COUNT;
        count := v_cnt;
        code := 200;
        msg := '无围栏';
        RETURN NEXT;
        RETURN;
    END IF;

    v_filter_geom := ST_SetSRID(
        ST_MakeEnvelope(
            ST_XMin(v_extent), ST_YMin(v_extent),
            ST_XMax(v_extent), ST_YMax(v_extent),
            4326
        ), 4326
    );
    RAISE NOTICE '[步骤3] 外包矩形完成，耗时: %', clock_timestamp() - v_step_start;

    -- 步骤4：核心更新（修复 SRID 问题）
    v_step_start := clock_timestamp();
    RAISE NOTICE '[步骤4] 开始批量更新...';
    EXECUTE format('
        WITH candidates AS (
            SELECT id, geom
            FROM %I
            WHERE geom && %L   -- 外包矩形过滤
        ),
        best_zone AS (
            SELECT 
                c.id,
                (
                    SELECT CASE f.fence_type
                        WHEN ''1'' THEN ''禁飞区''
                        WHEN ''2'' THEN ''管控区''
                        WHEN ''3'' THEN ''适飞区''
                    END
                    FROM bo_electric_fence f
                    WHERE f.del_flag = false
                      AND f.fence_type IN (''1'',''2'',''3'')
                      AND (%L = '''' OR f.project_id = %L)
                      AND ST_Intersects(c.geom, ST_SetSRID(f.geom, 4326))  -- 强制统一 SRID
                    ORDER BY CASE f.fence_type WHEN ''1'' THEN 1 WHEN ''2'' THEN 2 WHEN ''3'' THEN 3 END
                    LIMIT 1
                ) AS zone_type
            FROM candidates c
        )
        UPDATE %I n
        SET zone_type = b.zone_type
        FROM best_zone b
        WHERE n.id = b.id
          AND (n.zone_type IS DISTINCT FROM b.zone_type)
    ', v_table, v_filter_geom, p_project_id, p_project_id, v_table);

    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    count := v_cnt;
    RAISE NOTICE '[步骤4] 更新完成，耗时: %，影响行数: %', clock_timestamp() - v_step_start, v_cnt;

    code := 200;
    msg := format('完成，耗时 %s 秒，更新 %s 行', EXTRACT(epoch FROM clock_timestamp() - v_start)::int, v_cnt);
    RETURN NEXT;
EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := SQLERRM;
    count := 0;
    table_name := v_table;   -- 确保异常时也有表名
    RAISE NOTICE '[异常] %', SQLERRM;
    RETURN NEXT;
END;
$$;
 
-- ===================== 标记网格区域类型示例 =====================
 SELECT * FROM gis_mark_electric_fence('2c95908e958f3b75019593551f520126');

 
-- ============================================================ gis_refresh_electric_fence  重置所有网格====================================================================================
-- ===================== 删除可能存在的同名函数（保证幂等性） =====================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc
              WHERE proname = 'gis_refresh_electric_fence')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.oid::regproc || '(' || r.args || ') CASCADE';
    END LOOP;
END;
$$;

-- ==============================================
-- 函数名：gis_refresh_electric_fence
-- 功能描述：刷新三维网格的电子围栏标记。先清空已标记的zone_type，再重新标记。
-- 参数：p_project_id - 项目ID（可选，空表示公共表）
-- 返回值：标准TABLE结构
--   code        integer     返回码：200成功，500执行异常
--   table_name  text        操作的网格表名
--   msg         text        结果描述
--   count       bigint      更新记录数
-- 适用场景：电子围栏数据修改后，快速刷新网格区域标记
-- ==============================================
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence(p_project_id VARCHAR DEFAULT '')
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
    v_updated_match_rows INT := 0;
    v_cleared_rows INT := 0;
BEGIN
    -- 确定网格表名
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;

    -- 兼容旧表结构：确保目标表存在 zone_type 列
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20);', v_table);

    -- 计算应该写入的目标 zone_type，按围栏优先级取最高优先级值
    EXECUTE format(' 
        CREATE TEMP TABLE tmp_desired_zone ON COMMIT DROP AS
        WITH filtered_fences AS (
            SELECT
                id,
                fence_type,
                ST_SetSRID(geom, 4326) AS geom4326,
                CASE fence_type
                    WHEN ''1'' THEN 1
                    WHEN ''2'' THEN 2
                    WHEN ''3'' THEN 3
                    ELSE 4
                END AS priority
            FROM bo_electric_fence
            WHERE del_flag = false
              AND fence_type IN (''1'', ''2'', ''3'')
              AND ($1 = '''' OR project_id::TEXT = $1::TEXT)
        ),
        ranked_matches AS (
            SELECT
                n.id,
                CASE f.fence_type
                    WHEN ''1'' THEN ''禁飞区''
                    WHEN ''2'' THEN ''管控区''
                    WHEN ''3'' THEN ''适飞区''
                END AS zone_type,
                ROW_NUMBER() OVER (PARTITION BY n.id ORDER BY f.priority) AS rn
            FROM %I n
            JOIN filtered_fences f
              ON n.geom && f.geom4326
             AND ST_Intersects(n.geom, f.geom4326)
        )
        SELECT id, zone_type
        FROM ranked_matches
        WHERE rn = 1
    ', v_table) USING p_project_id;

    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tmp_desired_zone_id ON tmp_desired_zone(id);';
    EXECUTE 'ANALYZE tmp_desired_zone;';

    -- 更新当前应保留或修改的 zone_type
    EXECUTE format(' 
        UPDATE %I n
        SET zone_type = t.zone_type
        FROM tmp_desired_zone t
        WHERE n.id = t.id
          AND (n.zone_type IS DISTINCT FROM t.zone_type)
    ', v_table);
    GET DIAGNOSTICS v_updated_match_rows = ROW_COUNT;

    -- 清除不再落在有效围栏内的旧 zone_type
    EXECUTE format('
        UPDATE %I n
        SET zone_type = NULL
        WHERE n.zone_type IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM tmp_desired_zone t WHERE t.id = n.id)
    ', v_table);
    GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

    count := v_updated_match_rows + v_cleared_rows;
    code := 200;
    msg := format('刷新电子围栏标记完成，更新 %s 条记录', count);
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_table;
    msg := '刷新失败：' || SQLERRM;
    count := 0;
    RETURN NEXT;
END;
$$;
 
-- ===================== 刷新电子围栏标记示例 =====================
-- 当围栏数据发生变更（如新增、修改、删除），调用此函数刷新全部区域标记
 -- 示例 刷新指定项目网格表
SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126');



