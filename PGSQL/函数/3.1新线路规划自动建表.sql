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


-- -- ==================================================================================== 电子围栏信息表 bo_electric_fence ====================================================================================
-- -- 业务用途：存储无人机禁飞区、限飞区、电子围栏区域的空间与属性信息
-- -- 数据结构：支持2D面/多边形几何，WGS84经纬度坐标系
-- DROP TABLE IF EXISTS "public"."bo_electric_fence";
-- 
-- CREATE TABLE "public"."bo_electric_fence" (
--   "id" varchar(32) COLLATE "pg_catalog"."default" NOT NULL,  -- 主键ID，业务唯一标识，通常使用UUID
--   "create_time" timestamp(6) NOT NULL DEFAULT now(),         -- 记录创建时间，精确到毫秒，默认当前系统时间
--   "create_user" varchar(32) COLLATE "pg_catalog"."default",  -- 创建人ID，关联系统用户表
--   "del_flag" bool NOT NULL DEFAULT false,                    -- 逻辑删除标识：false=数据有效，true=已删除（软删除）
--   "remark" varchar(1000) COLLATE "pg_catalog"."default",    -- 备注说明，用于记录围栏额外描述信息
--   "update_time" timestamp(6) NOT NULL DEFAULT now(),         -- 记录最后更新时间，精确到毫秒，默认当前系统时间
--   "update_user" varchar(32) COLLATE "pg_catalog"."default",  -- 最后更新人ID，关联系统用户表
--   "project_id" varchar(32) COLLATE "pg_catalog"."default",   -- 所属项目ID，用于多项目隔离
--   "code" varchar(255) COLLATE "pg_catalog"."default",        -- 围栏编号，自定义编码规则，便于管理
--   "status" varchar(32) COLLATE "pg_catalog"."default",       -- 围栏状态：如启用/禁用/过期/维护中
--   "name" varchar(200) COLLATE "pg_catalog"."default",        -- 围栏名称，用于界面展示与快速检索
--   "type" varchar(32) COLLATE "pg_catalog"."default",         -- 围栏类型：如禁飞区、限高区、限飞区、警示区
--   "frequency" varchar(32) COLLATE "pg_catalog"."default",    -- 执行频率：用于定时生效类围栏（单次/每日/每周）
--   "area" varchar(255) COLLATE "pg_catalog"."default",        -- 围栏面积，单位：平方米，存储计算结果
--   "week" varchar(255) COLLATE "pg_catalog"."default",        -- 周设置：存储周几生效，格式如 1,3,5（周一三五）
--   "day" varchar(255) COLLATE "pg_catalog"."default",         -- 日设置：存储日期范围，用于按自然日控制生效
--   "start_time" varchar(32) COLLATE "pg_catalog"."default",   -- 生效开始时间，字符串格式，灵活适配业务时间规则
--   "end_time" varchar(32) COLLATE "pg_catalog"."default",     -- 生效结束时间，字符串格式
--   "draw_method" varchar(32) COLLATE "pg_catalog"."default", -- 绘制方式：如手动绘制、导入坐标、圆形绘制、矩形绘制
--   "height" float8,                                            -- 围栏限制高度，单位：米，无人机垂直方向限制
--   "fence_type" varchar(20) COLLATE "pg_catalog"."default",    -- 围栏分类：用于业务维度区分（如机场围栏、楼宇围栏）
--   "geom" geometry(GEOMETRY,4326),                             -- 空间几何字段，WGS84坐标系，支持点/线/面等任意几何类型
--   "time_plan" varchar(4000) COLLATE "pg_catalog"."default",   -- 时间计划配置，存储复杂时间策略JSON字符串
--   CONSTRAINT "bo_electric_fence_pkey" PRIMARY KEY ("id")      -- 主键约束，保证ID唯一性
-- );
-- 
-- -- ===================== 电子围栏表索引 =====================
-- -- 先删除旧索引，避免重复创建报错
-- DROP INDEX IF EXISTS "idx_bef_del_name";
-- DROP INDEX IF EXISTS "idx_bo_electric_fence_geom";
-- 
-- -- 普通B树索引：针对【删除标识+围栏名称】组合查询优化，提升列表查询速度
-- CREATE INDEX "idx_bef_del_name" ON "public"."bo_electric_fence" USING btree ("del_flag","name");
-- -- 空间GIST索引：针对空间几何字段geom优化，加速空间包含、相交、距离计算等查询
-- CREATE INDEX "idx_bo_electric_fence_geom" ON "public"."bo_electric_fence" USING gist ("geom");
-- 
-- -- ===================== 电子围栏表 注释 =====================
-- COMMENT ON TABLE "public"."bo_electric_fence" IS '电子围栏信息表：存储无人机禁飞/限飞区域的空间与业务属性信息';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."id" IS '主键ID，业务唯一标识';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."create_time" IS '记录创建时间';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."create_user" IS '创建人ID';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."del_flag" IS '逻辑删除标识：false=正常，true=已删除';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."remark" IS '备注说明信息';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."update_time" IS '记录最后更新时间';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."update_user" IS '最后更新人ID';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."project_id" IS '所属项目ID，项目级数据隔离';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."code" IS '围栏自定义编号';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."status" IS '围栏状态：启用/禁用/过期';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."name" IS '围栏名称，界面展示用';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."type" IS '围栏类型：禁飞区/限高区/警示区';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."frequency" IS '生效执行频率：单次/每日/每周';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."area" IS '围栏面积，单位：平方米';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."week" IS '周生效规则：1-7代表周一到周日，逗号分隔';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."day" IS '日生效规则：存储日期范围';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."start_time" IS '生效开始时间';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."end_time" IS '生效结束时间';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."draw_method" IS '围栏绘制方式：手动/导入/圆形/矩形';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."height" IS '围栏限制高度，单位：米';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."fence_type" IS '围栏业务分类';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."geom" IS '空间几何对象，WGS84经纬度坐标系';
-- COMMENT ON COLUMN "public"."bo_electric_fence"."time_plan" IS '复杂时间计划配置字符串';


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
DROP FUNCTION IF EXISTS gis_generate_3d_grid(VARCHAR, TEXT, NUMERIC, NUMERIC, INT);

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
    v_cnt  INT := 0;                       -- 插入网格点的总行数
    step_lon NUMERIC;                      -- 经度方向步长（度）
    step_lat NUMERIC;                      -- 纬度方向步长（度）
    step_alt INT;                          -- 高度方向步长（米）
    v_min_lon NUMERIC;                     -- 从GeoJSON解析出的最小经度
    v_max_lon NUMERIC;                     -- 从GeoJSON解析出的最大经度
    v_min_lat NUMERIC;                     -- 从GeoJSON解析出的最小纬度
    v_max_lat NUMERIC;                     -- 从GeoJSON解析出的最大纬度
BEGIN
    -- 初始化返回参数，默认成功状态
    code := 200;
    table_name := '';
    msg := '';
    count := 0;

    -- ===================== 从GeoJSON字符串自动解析空间范围 =====================
    -- 解析GeoJSON，自动获取最小/最大经纬度，格式错误则直接返回400
    BEGIN
        SELECT 
            ST_XMin(ST_GeomFromGeoJSON(p_geojson))::NUMERIC,
            ST_XMax(ST_GeomFromGeoJSON(p_geojson))::NUMERIC,
            ST_YMin(ST_GeomFromGeoJSON(p_geojson))::NUMERIC,
            ST_YMax(ST_GeomFromGeoJSON(p_geojson))::NUMERIC
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

    -- ===================== 计算网格步长 =====================
    -- 水平分辨率（米）转经纬度度数：1度 ≈ 111000米
    step_lon := p_resolution / 111000.0;
    step_lat := p_resolution / 111000.0;
    -- 高度步长直接使用分辨率（米）
    step_alt := p_resolution;

    -- ===================== 根据项目ID生成表名 =====================
    -- 项目ID为空使用默认表名，不为空则拼接项目ID，并过滤非法字符防止SQL注入
    IF p_project_id IS NULL OR p_project_id = '' THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;

    -- ===================== 删除已存在的旧表 =====================
    EXECUTE format('DROP TABLE IF EXISTS %I;', v_table);
		
    -- ===================== 创建三维网格表（UNLOGGED 提升写入速度） =====================
    -- 关闭autovacuum，避免批量插入时自动清理影响性能
    EXECUTE format('
        CREATE UNLOGGED TABLE IF NOT EXISTS %I (
            id SERIAL PRIMARY KEY,
            x INT NOT NULL,               -- 网格X轴索引
            y INT NOT NULL,               -- 网格Y轴索引
            z INT NOT NULL,               -- 网格Z轴索引
            lon DOUBLE PRECISION,         -- 经度
            lat DOUBLE PRECISION,         -- 纬度
            alt DOUBLE PRECISION,         -- 高度（米）
            zone_type VARCHAR(20) DEFAULT NULL,  -- 区域类型：禁飞区/管控区/适飞区
            geom geometry(PointZ,4326)    -- 三维空间点，WGS84坐标系
        ) WITH (autovacuum_enabled = off);
    ', v_table);

    -- ===================== 给表和字段添加注释 =====================
    EXECUTE format('COMMENT ON TABLE %I IS ''三维网格节点表'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.id IS ''自增主键'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.x IS ''网格X索引'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.y IS ''网格Y索引'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.z IS ''网格Z索引'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.lon IS ''经度'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.lat IS ''纬度'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.alt IS ''高度'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.zone_type IS ''区域类型（禁飞区/管控区/适飞区）'';', v_table);
    EXECUTE format('COMMENT ON COLUMN %I.geom IS ''空间几何（三维点，WGS84坐标系）'';', v_table);

    -- ===================== 清空表数据（防止残留） =====================
    EXECUTE format('TRUNCATE TABLE %I;', v_table);

    -- ===================== 批量生成三维网格点并插入表中 =====================
    -- 使用generate_series生成x/y/z三个维度的序列，计算坐标与三维几何点
    EXECUTE format('
        INSERT INTO %I (x, y, z, lon, lat, alt, geom)
        SELECT
            s_lon, s_lat, s_alt,
            $1 + s_lon * $4,
            $2 + s_lat * $5,
            $3 + s_alt * $6,
            ST_SetSRID(ST_MakePoint($1 + s_lon * $4, $2 + s_lat * $5, $3 + s_alt * $6), 4326)
        FROM
            generate_series(0, CEIL(($7 - $1) / $4)::INT) s_lon,
            generate_series(0, CEIL(($8 - $2) / $5)::INT) s_lat,
            generate_series(0, CEIL(($9 - $3) / $6)::INT) s_alt
        WHERE
            $1 + s_lon * $4 <= $7
            AND $2 + s_lat * $5 <= $8
            AND $3 + s_alt * $6 <= $9;
    ', v_table)
    USING v_min_lon, v_min_lat, p_min_alt,
          step_lon, step_lat, step_alt,
          v_max_lon, v_max_lat, p_max_alt;

    -- ===================== 获取插入的网格点总数 =====================
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    count := v_cnt;

    -- ===================== 创建索引，加速查询 =====================
    -- 创建x,y,z复合索引
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (x, y, z);', 'idx_xyz_'||v_table, v_table);
    -- 创建空间索引，支持GIS空间查询
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING GIST(geom);', 'idx_geom_'||v_table, v_table);

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
SELECT * FROM gis_generate_3d_grid(
    '2c95908e958f3b75019593551f520126',
    ' ',
    50,
    300,
    100
);
-- ========================================================== gis_mark_electric_fence  更新三维网格表====================================================================================
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
DROP FUNCTION IF EXISTS gis_mark_electric_fence(VARCHAR);

CREATE OR REPLACE FUNCTION gis_mark_electric_fence(p_project_id VARCHAR DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;                       -- 目标网格表名
    v_cnt INT := 0;                     -- 更新的记录数
BEGIN
    -- 确定网格表名
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;

    -- 确保目标表有 zone_type 列（兼容旧表结构）
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20);', v_table);

    -- 创建临时表，存储每个网格点应设置的最终区域类型（基于最高优先级围栏）
    EXECUTE format('
        CREATE TEMP TABLE tmp_zone_grid AS
        SELECT DISTINCT ON (n.id) n.id,
        CASE f.fence_type
            WHEN ''1'' THEN ''禁飞区''
            WHEN ''2'' THEN ''管控区''
            WHEN ''3'' THEN ''适飞区''
        END AS zone_type
        FROM %I n
				-- JOIN bo_electric_fence f ON ST_DWithin(n.geom::geography, f.geom::geography, 100)
				-- JOIN bo_electric_fence f ON ST_Intersects(n.geom, f.geom)
					JOIN bo_electric_fence f 
						ON ST_Intersects(n.geom, ST_SetSRID(f.geom, 4326))
        WHERE f.del_flag = false
           --  AND n.alt <= f.height                      -- 只考虑高度在围栏限制内的网格点
          AND f.fence_type IN (''1'',''2'',''3'')
          AND ( $1 = '''' OR f.project_id::TEXT = $1::TEXT )   -- 项目过滤
        ORDER BY n.id,
        CASE f.fence_type
            WHEN ''1'' THEN 1
            WHEN ''2'' THEN 2
            WHEN ''3'' THEN 3
            ELSE 4
        END
    ', v_table) USING p_project_id;

    -- 批量更新网格表，只更新那些类型确实发生变化的行
    EXECUTE format('
        UPDATE %I n
        SET zone_type = t.zone_type
        FROM tmp_zone_grid t
        WHERE n.id = t.id
        AND (n.zone_type IS DISTINCT FROM t.zone_type)
    ', v_table);

    -- 获取实际被更新的行数
    GET DIAGNOSTICS v_cnt = ROW_COUNT;

    -- 清理临时表
    DROP TABLE IF EXISTS tmp_zone_grid;

    RETURN jsonb_build_object('success', true, 'table', v_table, 'updated_count', v_cnt);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'msg', SQLERRM);
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
DROP FUNCTION IF EXISTS gis_mark_electric_fence(VARCHAR);

CREATE OR REPLACE FUNCTION gis_mark_electric_fence(p_project_id VARCHAR DEFAULT '')
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;                       -- 目标网格表名
    v_cnt INT := 0;                     -- 更新的记录数
BEGIN
    -- 初始化返回值
    code := 200;
    table_name := '';
    msg := '';
    count := 0;

    -- ===================== 确定网格表名 =====================
    -- 项目ID为空使用公共表，不为空使用项目专属表
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;

    -- ===================== 兼容旧表结构：确保目标表存在 zone_type 列 =====================
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20);', v_table);

    -- ===================== 创建临时表：计算每个网格点最高优先级的区域类型 =====================
    -- 使用 DISTINCT ON + 排序保证每个网格点只取优先级最高的围栏（禁飞>管控>适飞）
    -- 空间判断：网格点与围栏几何相交 ST_Intersects
    EXECUTE format('
        CREATE TEMP TABLE tmp_zone_grid AS
        SELECT DISTINCT ON (n.id) n.id,
        CASE f.fence_type
            WHEN ''1'' THEN ''禁飞区''
            WHEN ''2'' THEN ''管控区''
            WHEN ''3'' THEN ''适飞区''
        END AS zone_type
        FROM %I n
					-- JOIN bo_electric_fence f ON ST_DWithin(n.geom::geography, f.geom::geography, 100)
				-- JOIN bo_electric_fence f ON ST_Intersects(n.geom, f.geom)
        JOIN bo_electric_fence f  ON ST_Intersects(n.geom, ST_SetSRID(f.geom, 4326))
        WHERE f.del_flag = false
				--  AND n.alt <= f.height                      -- 只考虑高度在围栏限制内的网格点
          AND f.fence_type IN (''1'',''2'',''3'')
          AND ( $1 = '''' OR f.project_id::TEXT = $1::TEXT )   -- 项目隔离过滤
        ORDER BY n.id,
        CASE f.fence_type                                    -- 优先级排序：1<2<3
            WHEN ''1'' THEN 1
            WHEN ''2'' THEN 2
            WHEN ''3'' THEN 3
            ELSE 4
        END
    ', v_table) USING p_project_id;

    -- ===================== 批量更新网格表区域类型 =====================
    -- 仅更新值发生变化的行，减少不必要IO
    EXECUTE format('
        UPDATE %I n
        SET zone_type = t.zone_type
        FROM tmp_zone_grid t
        WHERE n.id = t.id
        AND (n.zone_type IS DISTINCT FROM t.zone_type)
    ', v_table);

    -- ===================== 获取实际更新行数 =====================
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    count := v_cnt;

    -- ===================== 清理临时表 =====================
    DROP TABLE IF EXISTS tmp_zone_grid;

    -- ===================== 返回执行成功结果 =====================
    msg := format('网格区域类型标记完成，成功更新 %s 条记录', v_cnt);
    RETURN NEXT;

-- ===================== 全局异常捕获 =====================
EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := '标记失败：' || SQLERRM;
    count := 0;
    RETURN NEXT;
END;
$$;
 
 UPDATE gis_grid_nodes SET zone_type = NULL WHERE zone_type IS NOT NULL;

-- ===================== 标记网格区域类型示例 =====================
 SELECT * FROM gis_mark_electric_fence('2c95908e958f3b75019593551f520126');

-- 查询被标记的网格（显示前10条）
SELECT id, lon, lat, alt, zone_type
FROM gis_grid_nodes
WHERE zone_type IS NOT NULL
LIMIT 10;

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
DROP FUNCTION IF EXISTS gis_refresh_electric_fence(VARCHAR);

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
BEGIN
    -- 确定网格表名
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;

    -- 仅重置非空的 zone_type 为 NULL（避免全表更新）
    EXECUTE format('
        UPDATE %I SET zone_type = NULL WHERE zone_type IS NOT NULL;
    ', v_table);

    -- 重新调用标记函数完成区域标注
    RETURN QUERY SELECT * FROM gis_mark_electric_fence(p_project_id);

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



