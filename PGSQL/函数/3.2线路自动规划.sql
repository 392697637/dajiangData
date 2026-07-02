-- ==============================================
-- 3.2 线路自动规划：全局网格 A* 粗规划函数
--
-- 本文件定位：
--   基于 3.1 生成的项目级网格表 gis_grid_nodes_<project_id> 做三维 A* 路径规划，
--   并把结果写入 gis_flight_paths。它适合使用 100m 左右的全局粗网格进行快速规划。
--
-- 与 3.1 / 3.3 的关系：
--   1. 3.1 负责生成网格和障碍打标，输出 is_flyable=true/false。
--   2. 3.2 读取可飞网格做全局路径搜索，返回 code/msg + 航线字段。
--   3. 3.3 会先调用本文件的 gis_astar_3d_flight_plan 得到粗航线，
--      再沿粗航线走廊生成 20/30m 精细网格做二次规划。
--
-- 返回策略：
--   code=200 表示函数正常完成。
--   code=400 表示输入参数非法。
--   code=500 表示执行过程中出现异常。
--   msg 中包含执行时间，以及具体执行说明，便于接口侧记录耗时和定位慢点。
--
-- 维护提醒：
--   本文件的核心函数使用 RETURNS TABLE，返回列 id/project_id/del_flag 等会成为 PL/pgSQL 变量。
--   函数体内静态 SQL 必须使用表别名访问同名字段，避免 "column reference is ambiguous"。
-- ==============================================

-- =============================================================================
-- 计算 LineStringZ 的近似米制三维长度：经纬度近似换算为米，高度差按 Z 值米计算
-- =============================================================================
DROP FUNCTION IF EXISTS gis_linestring_length_m(geometry);

CREATE OR REPLACE FUNCTION gis_linestring_length_m(p_line geometry)
RETURNS DOUBLE PRECISION AS $$
    WITH pts AS (
        SELECT (dp).path[1] AS idx, (dp).geom AS geom
        FROM ST_DumpPoints(p_line) AS dp
    ),
    segs AS (
        SELECT
            a.geom AS geom_a,
            b.geom AS geom_b,
            RADIANS((ST_Y(a.geom) + ST_Y(b.geom)) / 2.0) AS avg_lat_rad
        FROM pts a
        JOIN pts b ON b.idx = a.idx + 1
    )
    SELECT COALESCE(SUM(
        SQRT(
            POWER((ST_X(geom_b) - ST_X(geom_a)) * 111000.0 * COS(avg_lat_rad), 2)
            + POWER((ST_Y(geom_b) - ST_Y(geom_a)) * 111000.0, 2)
            + POWER(COALESCE(ST_Z(geom_b), 0) - COALESCE(ST_Z(geom_a), 0), 2)
        )
    ), 0)::DOUBLE PRECISION
    FROM segs;
$$ LANGUAGE SQL IMMUTABLE STRICT;
COMMENT ON FUNCTION gis_linestring_length_m(geometry) IS '计算线长';

-- ==================================================================================== gis_astar_3d_flight  单段三维路径规划====================================================================================
-- ===================== 删除可能存在的同名函数（保证幂等性） =====================

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc
              WHERE proname IN ('gis_astar_3d_flight_plan', 'gis_astar_3d_flight')
              ORDER BY CASE proname WHEN 'gis_astar_3d_flight_plan' THEN 1 ELSE 2 END)
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.oid::regproc || '(' || r.args || ') CASCADE';
    END LOOP;
END;
$$;


/**
 * 函数名称：gis_astar_3d_flight
 * 所属模块：GIS 空间三维路径规划 / 无人机自动驾驶航线生成
 * 依赖环境：PostgreSQL + PostGIS（支持PointZ/LineStringZ/3D距离计算）
 * 依赖表：
 *   1. gis_grid_nodes / gis_grid_nodes_{项目ID}
 *      三维空间网格节点表（包含 zone_type 字段，'禁飞区' 表示不可通行）
 *   2. gis_flight_paths 飞行航线结果表（存储规划好的航线数据）
 *   3. bo_electric_fence 禁飞区表（用于边相交性动态检查）
 *
 * 【核心功能】
 * 基于三维A*寻路算法，为单段起终点自动生成带避障、高度平滑、可直接执行的低空飞行航线。
 * 支持历史航线复用、强制重算、多级容错兜底、多项目多用户数据隔离。
 *
 * 【重要修改说明】
 * - 原网格表无 is_walkable 列，现根据 zone_type 动态计算：
 *   zone_type = '禁飞区' → 不可通行 (is_walkable = false)
 *   其他情况（包括 NULL、'管控区'、'适飞区'）→ 可通行 (is_walkable = true)
 * - A* 扩展邻居时，实时检查当前节点到邻居节点的线段是否与启用的禁飞区相交，
 *   若相交则跳过该邻居（边阻塞），确保路径不穿越禁飞区。
 *
 * 【算法流程】
 * 1. 构建起点/终点 3D 坐标
 * 2. 非强制重算 → 优先复用历史航线
 * 3. 检查网格是否可用 → 决定是否启用 A*
 * 4. A* 启用 → 三维网格寻路（含边相交性动态检查）
 * 5. 路径平滑（爬升 → 平飞 → 下降）
 * 6. 异常/寻路失败 → 自动降级为直线航线
 * 7. 保存并返回最终航线
 *
 * 【高度模式】
 * p_height_mode = 0         → 直升直降（原地起飞爬升 → 平飞 → 终点上空垂直降落）
 * p_height_mode 0~1         → 平滑三段式飞行（爬升 → 平飞 → 下降）
 * 例：0.3 → 前30%爬升，中间40%平飞，后30%下降
 *
 * ======================================================================================
 * 参数说明（按调用顺序）
 * ======================================================================================
 * @param p_start_lon        起点经度（必填）  ：飞行器起飞位置经度（WGS84）
 * @param p_start_lat        起点纬度（必填）  ：飞行器起飞位置纬度（WGS84）
 * @param p_start_alt        起点高度（必填）  ：飞行器起飞高度（单位：米）
 * @param p_end_lon          终点经度（必填）  ：飞行器目标降落经度
 * @param p_end_lat          终点纬度（必填）  ：飞行器目标降落纬度
 * @param p_end_alt          终点高度（必填）  ：飞行器目标降落高度
 * @param p_safe_altitude    安全飞行高度（默认120米）：巡航阶段必须保持的高度
 * @param p_height_mode      高度平滑模式（默认0）：
 *                           0        = 直升直降（起飞原地爬高、终点原地降落）
 *                           0~1 之间 = 平滑飞行（按比例爬升、平飞、下降）
 * @param p_force_gen        是否强制重新生成（默认false）：true=强制重算，false=优先复用历史航线
 * @param p_project_id       项目ID（可选）    ：业务系统项目唯一标识，用于数据隔离
 * @param p_create_user      创建用户（可选）  ：航线创建人用户ID
 * ======================================================================================
 *
 * 【返回值】
 * code        integer     返回码：200成功，400参数错误，500执行异常
 * msg         text        执行结果描述，包含执行时间
 * 其余字段为 gis_flight_paths 表字段，实际调用时通常只有一行。
 *
 * 维护注意：
 * 本函数使用 RETURNS TABLE，id/project_id/del_flag 等返回列会成为 PL/pgSQL 输出变量。
 * 函数体内静态 SQL 访问同名表字段时必须使用表别名，例如 p.id、g.id。
 */
CREATE OR REPLACE FUNCTION gis_astar_3d_flight(
    p_start_lon        DOUBLE PRECISION,
    p_start_lat        DOUBLE PRECISION,
    p_start_alt        DOUBLE PRECISION,
    p_end_lon          DOUBLE PRECISION,
    p_end_lat          DOUBLE PRECISION,
    p_end_alt          DOUBLE PRECISION,
    p_safe_altitude    DOUBLE PRECISION DEFAULT 120,
    p_height_mode      DOUBLE PRECISION DEFAULT 0,
    p_force_gen        BOOLEAN DEFAULT FALSE,
    p_project_id       VARCHAR DEFAULT NULL,
    p_create_user      VARCHAR DEFAULT NULL
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
) AS $$
DECLARE
    v_start_time    timestamptz := clock_timestamp();
    v_return_msg    TEXT;

    -- ====================== 几何相关变量 ======================
    -- 3D起点几何对象（PointZ，WGS84坐标系SRID=4326）
    v_start_pt      geometry(PointZ,4326);
    -- 3D终点几何对象
    v_end_pt        geometry(PointZ,4326);
    
    -- ====================== 历史航线复用 ======================
    -- 存储查询到的匹配历史航线记录
    v_old_path      gis_flight_paths;
    
    -- ====================== 网格节点ID ======================
    -- 距离起点最近的网格节点ID
    v_start_id      INT;
    -- 距离终点最近的网格节点ID
    v_goal_id       INT;
    
    -- ====================== A* 路径结果 ======================
    -- A*算法找到的路径节点ID数组（用于回溯生成线路）
    v_path_ids      INT[];
    -- 路径回溯时当前遍历节点ID
    v_current_id    INT;
    
    -- ====================== 线路几何 ======================
    -- A*算法生成的原始三维线路（未做高度平滑）
    v_path_line     geometry(LineStringZ,4326);
    -- 高度平滑后的最终可执行飞行线路
    v_final_path    geometry(LineStringZ,4326);
    
    -- ====================== 航点JSON ======================
    -- 原始路径对应的航点JSON数组（lon/lat/alt）
    v_waypoints     JSONB;
    -- 平滑后路径对应的航点JSON数组
    v_smooth_waypoints JSONB;
    
    -- ====================== 高度平滑辅助变量 ======================
    -- 高度计算中间比例值（用于三段式平滑）
    ratio           DOUBLE PRECISION;
    -- 插值计算后的新高度值（米）
    new_z           DOUBLE PRECISION;
    
    -- ====================== 搜索范围裁剪 ======================
    -- 网格搜索范围X轴最小值（经度方向索引）
    v_min_x INT;
    -- 网格搜索范围X轴最大值
    v_max_x INT;
    -- 网格搜索范围Y轴最小值（纬度方向索引）
    v_min_y INT;
    -- 网格搜索范围Y轴最大值
    v_max_y INT;
    
    -- ====================== 算法控制标志 ======================
    -- 是否启用A*算法进行路径规划（true=启用，false=直接直线）
    v_use_astar     BOOLEAN := false;
    -- 实际参与本次规划的网格表名；优先使用项目网格表 gis_grid_nodes_{项目ID}
    v_grid_table     TEXT;
    
    -- ====================== 边检查辅助变量 ======================
    v_edge_line     geometry(LineStringZ,4326);   -- 节点间的线段几何
BEGIN
    -- ====================== 0. 基础参数校验 ======================
    IF p_start_lon IS NULL OR p_start_lat IS NULL OR p_start_alt IS NULL
       OR p_end_lon IS NULL OR p_end_lat IS NULL OR p_end_alt IS NULL THEN
        code := 400;
        msg := format('参数错误：起点/终点经纬度和高度不能为空，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_safe_altitude IS NULL OR p_safe_altitude <= 0 THEN
        code := 400;
        msg := format('参数错误：安全高度必须大于0，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_height_mode IS NULL OR p_height_mode < 0 OR p_height_mode >= 1 THEN
        code := 400;
        msg := format('参数错误：高度平滑模式必须满足 0 <= p_height_mode < 1，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- ====================== 1. 构建3D起点和终点几何对象 ======================
    -- 将输入的经纬度+高度构造成PostGIS 3D点，并指定WGS84坐标系（SRID 4326）
    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt   := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);

    -- ====================== 2. 非强制生成时，优先复用历史航线 ======================
    -- 未开启强制重算 → 尝试查询完全相同条件的历史航线（避免重复计算）
    IF NOT p_force_gen THEN
        -- 查询条件：未删除 + 同项目 + 同安全高度 + 同平滑模式 + 起止点空间相等
        SELECT fp.* INTO v_old_path
        FROM gis_flight_paths fp
        WHERE fp.del_flag = false
          AND fp.project_id IS NOT DISTINCT FROM p_project_id
          AND fp.safe_altitude = p_safe_altitude
          AND fp.smooth_ratio = p_height_mode
          AND ST_Equals(fp.start_point, v_start_pt)
          AND ST_Equals(fp.end_point, v_end_pt)
        LIMIT 1;-- 只取一条（通常最多一条）

        -- 找到历史航线 → 直接返回并结束函数，极大提升性能
        IF v_old_path IS NOT NULL THEN
            v_return_msg := format('规划成功：复用历史航线，执行时间 %s 秒',
                                   ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            RETURN QUERY SELECT 200, v_return_msg, (v_old_path).*;
            RETURN;
        END IF;
    END IF;

    -- ====================== 3. 判断是否满足A*算法执行条件 ======================
    -- 网格表选择规则：
    -- 1. project_id不为空且项目网格表 gis_grid_nodes_{项目ID} 存在 → 使用项目网格表
    -- 2. 项目网格表不存在但公共表 gis_grid_nodes 存在 → 使用公共表
    -- 3. 两者都不存在 → 不启用A*，直接走直线兜底
    IF p_project_id IS NOT NULL
       AND trim(p_project_id) <> ''
       AND to_regclass(format('%I.%I', 'public', 'gis_grid_nodes_' || trim(p_project_id))) IS NOT NULL THEN
        v_grid_table := 'gis_grid_nodes_' || trim(p_project_id);
    ELSIF to_regclass('public.gis_grid_nodes') IS NOT NULL THEN
        v_grid_table := 'gis_grid_nodes';
    ELSE
        v_grid_table := NULL;
        RAISE NOTICE '【调试】未找到可用网格表，直接返回直线兜底航线';
    END IF;

    IF v_grid_table IS NOT NULL THEN
        -- 查找起点最近的可通行网格，优先使用综合 is_flyable 标记。
        EXECUTE format('
            SELECT id
            FROM %I
            WHERE is_flyable = true
            ORDER BY geom <-> $1
            LIMIT 1', v_grid_table)
        INTO v_start_id
        USING v_start_pt;

        -- 查找终点最近的可通行网格，优先使用综合 is_flyable 标记。
        EXECUTE format('
            SELECT id
            FROM %I
            WHERE is_flyable = true
            ORDER BY geom <-> $1
            LIMIT 1', v_grid_table)
        INTO v_goal_id
        USING v_end_pt;
    END IF;

    -- A*启用条件：
    --   (1) 起止点都找到有效网格节点
    --   (2) 起止点所在网格为适飞区或未标记（非禁飞区、非管控区）
    --   (3) 网格表有可通行网格（确保存在数据）
    IF v_start_id IS NOT NULL
       AND v_goal_id IS NOT NULL
       AND v_grid_table IS NOT NULL THEN
        -- 所有条件满足，启用A*寻路
        EXECUTE format('
            SELECT
                EXISTS(SELECT 1 FROM %I WHERE id = $1 AND is_flyable = true)
                AND EXISTS(SELECT 1 FROM %I WHERE id = $2 AND is_flyable = true)
                AND EXISTS(SELECT 1 FROM %I WHERE is_flyable = true)',
            v_grid_table, v_grid_table, v_grid_table)
        INTO v_use_astar
        USING v_start_id, v_goal_id;
    ELSE
        v_use_astar := false;
    END IF;

    -- ====================== 分支1：不满足A* → 直接生成两点直线航线（兜底方案） ======================
    -- 此分支处理以下情况：网格表为空、起点或终点在禁飞区、无法匹配网格等
    IF NOT v_use_astar THEN
      -- 构建起点到终点的3D直线（LineStringZ）
        v_path_line := ST_MakeLine(v_start_pt, v_end_pt);
        -- 最终路径 = 原始直线路径（未经平滑）
        v_final_path := v_path_line;
        -- 构建两点航点JSON数组
        v_waypoints := jsonb_build_array(
            jsonb_build_object('lon', p_start_lon, 'lat', p_start_lat, 'alt', p_start_alt),
            jsonb_build_object('lon', p_end_lon, 'lat', p_end_lat, 'alt', p_end_alt)
        );
        -- 平滑航点与原始航点一致（直线无需平滑）
        v_smooth_waypoints := v_waypoints;
        -- 只返回计算结果，不写入 gis_flight_paths。
        v_return_msg := format('规划成功：未满足A*条件，已生成直线兜底航线，执行时间 %s 秒',
                               ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY
        SELECT
            200, v_return_msg,
            NULL::integer, p_project_id::char(32), p_create_user::varchar(32), NOW()::timestamp,
            p_create_user::varchar(32), NOW()::timestamp, false,
            v_start_pt, v_end_pt, p_safe_altitude,
            v_path_line, v_final_path,
            v_waypoints, v_smooth_waypoints,
            gis_linestring_length_m(v_final_path), p_height_mode;
        RETURN; -- 提前结束函数
    END IF;
 -- ====================== 分支2：满足A*条件 → 执行三维路径规划 ======================
    -- 创建A*算法临时表（事务结束自动删除，不占用持久存储）
    -- 包含网格坐标、几何对象、可通行标志、代价和父节点信息
    CREATE TEMP TABLE tmp_grid (
        id INT PRIMARY KEY,               -- 网格节点ID
        x INT, y INT, z INT,              -- 网格三维坐标索引
        geom geometry(PointZ,4326),       -- 网格几何点（三维）
        is_walkable BOOLEAN,              -- 是否可通行（动态计算）
        g_cost FLOAT,                     -- 起点到当前节点的实际代价（距离）
        h_cost FLOAT,                     -- 当前节点到终点的启发式预估代价（3D距离）
        f_cost FLOAT,                     -- 总代价 f = g + h
        parent_id INT                     -- 父节点ID，用于路径回溯
    ) ON COMMIT DELETE ROWS;

    -- 获取起止点所在网格的X/Y索引坐标，用于限定搜索范围（缩小计算量）
    EXECUTE format('SELECT x FROM %I WHERE id = $1', v_grid_table) INTO v_min_x USING v_start_id;
    EXECUTE format('SELECT x FROM %I WHERE id = $1', v_grid_table) INTO v_max_x USING v_goal_id;
    EXECUTE format('SELECT y FROM %I WHERE id = $1', v_grid_table) INTO v_min_y USING v_start_id;
    EXECUTE format('SELECT y FROM %I WHERE id = $1', v_grid_table) INTO v_max_y USING v_goal_id;

    -- 扩大搜索范围（向外扩展10个网格），避免路径贴边导致无法通行
    -- 先确定原始范围（确保min <= max），再向外扩展
    SELECT least(v_min_x, v_max_x), greatest(v_min_x, v_max_x)
    INTO v_min_x, v_max_x;
    v_min_x := v_min_x - 10;
    v_max_x := v_max_x + 10;
    
    SELECT least(v_min_y, v_max_y), greatest(v_min_y, v_max_y)
    INTO v_min_y, v_max_y;
    v_min_y := v_min_y - 10;
    v_max_y := v_max_y + 10;

  -- 将搜索范围内的可飞网格数据导入临时表；is_walkable 始终为 true（WHERE 已过滤不可通行区域）
    EXECUTE format('
         INSERT INTO tmp_grid
        SELECT id, x, y, z, geom,
               true,
               0,0,0,NULL
        FROM %I
        WHERE x BETWEEN %s AND %s AND y BETWEEN %s AND %s
          AND is_flyable = true
    ', v_grid_table, v_min_x, v_max_x, v_min_y, v_max_y);

    -- 在临时表中重新匹配最近的起点/终点网格（确保在搜索范围内）
    SELECT g.id INTO v_start_id FROM tmp_grid g ORDER BY g.geom <-> v_start_pt LIMIT 1;
    SELECT g.id INTO v_goal_id  FROM tmp_grid g ORDER BY g.geom <-> v_end_pt LIMIT 1;

    -- 初始化起点代价：g_cost = 0（起点到自身代价为0）
    -- h_cost = 起点到终点的3D直线距离（启发函数）
    -- f_cost = g_cost + h_cost
    UPDATE tmp_grid g
    SET g_cost = 0,
        h_cost = ST_3DDistance(g.geom, v_end_pt),
        f_cost = 0 + ST_3DDistance(g.geom, v_end_pt)
    WHERE g.id = v_start_id;

    -- ====================== A* 算法核心循环 ======================
    DECLARE
        -- 开放列表：待检查的节点ID数组
        v_open INT[] := ARRAY[v_start_id];
        -- 关闭列表：已检查的节点ID数组
        v_closed INT[] := '{}'::INT[];
        -- 当前正在处理的节点ID
        v_curr INT;
        -- 当前节点的网格坐标
        v_curr_x INT; v_curr_y INT; v_curr_z INT;
        -- 当前节点的几何对象
        v_curr_geom geometry;
        -- 当前节点的g代价
        v_curr_g FLOAT;
        -- 邻居节点ID
        v_nid INT;
        -- 邻居节点几何对象
        v_n_geom geometry;
        -- 邻居节点当前的g代价
        v_n_g FLOAT;
        -- 邻居节点是否可通行
        v_n_walk BOOLEAN;
        -- 通过当前节点到达邻居的新g代价
        new_g FLOAT;
    BEGIN
        -- 只要开放列表不为空，就继续搜索
        WHILE array_length(v_open, 1) > 0 LOOP
            -- 从开放列表中取出 f_cost 最小的节点作为当前节点
            SELECT g.id, g.x, g.y, g.z, g.geom, g.g_cost
            INTO v_curr, v_curr_x, v_curr_y, v_curr_z, v_curr_geom, v_curr_g
            FROM tmp_grid g
            WHERE g.id = ANY(v_open)
            ORDER BY g.f_cost LIMIT 1;

            -- 如果当前节点就是目标节点，则成功找到路径，退出循环
            IF v_curr = v_goal_id THEN EXIT; END IF;

            -- 将当前节点从开放列表移至关闭列表（表示已处理）
            v_open := array_remove(v_open, v_curr);
            v_closed := array_append(v_closed, v_curr);

           -- 遍历当前节点在三维空间中的26个邻域节点（3x3x3范围，排除自身）
            FOR v_nid, v_n_geom, v_n_g, v_n_walk IN
                SELECT g.id, g.geom, g.g_cost, g.is_walkable
                FROM tmp_grid g
                    WHERE ABS(g.x - v_curr_x) <= 1      -- X方向相邻（经度）
                  AND ABS(g.y - v_curr_y) <= 1      -- Y方向相邻（纬度）
                  AND ABS(g.z - v_curr_z) <= 1      -- Z方向相邻（高度层）
                  AND g.id <> v_curr                -- 排除当前节点自身
                  AND g.is_walkable = TRUE          -- 只考虑可通行的网格
                  AND g.id <> ALL(v_closed)         -- 排除已经处理过的节点
            LOOP
                -- 计算通过当前节点到达邻居节点的新g代价 = 当前g代价 + 当前节点到邻居的3D距离
                new_g := v_curr_g + ST_3DDistance(v_n_geom, v_curr_geom);
                
                -- ======================  边相交性检查 ======================
                -- 构建当前节点到邻居节点的线段
                v_edge_line := ST_MakeLine(v_curr_geom, v_n_geom);
                -- 检查线段是否与任何启用的禁飞区相交（二维/三维相交）
                -- 注意：若禁飞区 geom 为三维体，建议使用 ST_3DIntersects；为二维多边形则使用 ST_Intersects
                IF EXISTS(
                    SELECT 1 FROM public.bo_electric_fence f
                    WHERE f.fence_type IN ('1', '2')   -- 禁飞区+管控区
                      AND f.status = '1'
                      AND f.del_flag = false
                      AND ST_Intersects(ST_SetSRID(f.geom, 4326), v_edge_line)   -- 若需三维精确判断，改为 ST_3DIntersects
                ) THEN
                    CONTINUE;   -- 该边穿越禁飞区，不可通行，跳过此邻居
                END IF;
                -- ===============================================================

                -- 如果邻居节点不在开放列表中，或者新路径的g代价更小，则更新邻居的代价和父节点
                IF v_nid <> ALL(v_open) OR new_g < v_n_g THEN
                    UPDATE tmp_grid g
                    SET g_cost = new_g,
                        h_cost = ST_3DDistance(v_n_geom, v_end_pt),
                        f_cost = new_g + ST_3DDistance(v_n_geom, v_end_pt),
                        parent_id = v_curr
                    WHERE g.id = v_nid;

                    -- 如果邻居节点不在开放列表中，则将其加入开放列表
                    IF v_nid <> ALL(v_open) THEN
                        v_open := array_append(v_open, v_nid);
                    END IF;
                END IF;
            END LOOP;
        END LOOP;

        -- ====================== 从终点回溯父节点，生成路径ID数组 ======================
        -- 从目标节点开始，沿着 parent_id 链向上回溯，直到父节点为 NULL
        v_current_id := v_goal_id;
        WHILE v_current_id IS NOT NULL LOOP
            -- 将节点ID插入数组头部（保证路径从起点到终点的顺序）
            v_path_ids := array_prepend(v_current_id, v_path_ids);
            -- 获取当前节点的父节点ID
            SELECT g.parent_id INTO v_current_id FROM tmp_grid g WHERE g.id = v_current_id;
        END LOOP;
        -- 移除首尾虚拟节点（起点ID=-1，终点ID=-2），只保留中间的网格路径节点
        IF array_length(v_path_ids, 1) >= 2 THEN
            v_path_ids := v_path_ids[2:array_length(v_path_ids, 1)-1];
        END IF;
        
        -- 输出A*路径所有节点的坐标信息
        DECLARE
            v_node_idx INT;
            v_node_lon DOUBLE PRECISION;
            v_node_lat DOUBLE PRECISION;
            v_node_alt DOUBLE PRECISION;
        BEGIN
            RAISE NOTICE '【A*路径坐标】';
            IF COALESCE(array_length(v_path_ids, 1), 0) > 0 THEN
                FOR v_node_idx IN 1..array_length(v_path_ids, 1) LOOP
                    SELECT ST_X(g.geom), ST_Y(g.geom), ST_Z(g.geom)
                    INTO v_node_lon, v_node_lat, v_node_alt
                    FROM tmp_grid g WHERE g.id = v_path_ids[v_node_idx];
                    RAISE NOTICE '节点%: (经度=%, 纬度=%, 高度=%)',
                        v_node_idx, v_node_lon, v_node_lat, v_node_alt;
                END LOOP;
            ELSE
                RAISE NOTICE '【A*路径坐标】未生成有效路径节点';
            END IF;
        END;
    END;

    -- ====================== A* 寻路失败（路径点数量 < 2）→ 降级为直线航线 ======================
    -- 路径点少于2说明没有有效路径（可能起点终点不连通，或搜索失败），此时使用直线航线
    IF COALESCE(array_length(v_path_ids, 1), 0) < 1 THEN
        DROP TABLE IF EXISTS tmp_grid;-- 清理临时表
        -- 生成两点直线航线（与分支1逻辑相同）
        v_path_line := ST_MakeLine(v_start_pt, v_end_pt);
        v_final_path := v_path_line;
        v_waypoints := jsonb_build_array(
            jsonb_build_object('lon', p_start_lon, 'lat', p_start_lat, 'alt', p_start_alt),
            jsonb_build_object('lon', p_end_lon, 'lat', p_end_lat, 'alt', p_end_alt)
        );
        v_smooth_waypoints := v_waypoints;

        v_return_msg := format('规划成功：A*未找到有效路径，已生成直线兜底航线，执行时间 %s 秒',
                               ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY
        SELECT
            200, v_return_msg,
            NULL::integer, p_project_id::char(32), p_create_user::varchar(32), NOW()::timestamp,
            p_create_user::varchar(32), NOW()::timestamp, false,
            v_start_pt, v_end_pt, p_safe_altitude,
            v_path_line, v_final_path,
            v_waypoints, v_smooth_waypoints,
            gis_linestring_length_m(v_final_path), p_height_mode;
        RETURN;
    END IF;

  -- ====================== 生成标准原始路径（未平滑，但包含起飞/降落过渡） ======================
    -- 初始化空的3D线几何（SRID=4326）
    v_path_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    -- 1. 添加真实起点
    v_path_line := ST_AddPoint(v_path_line, v_start_pt);

    -- 2. 如果高度模式为直升直降（p_height_mode = 0），则在起点位置添加一个安全高度点（原地爬升）
    IF p_height_mode = 0 THEN
        v_path_line := ST_AddPoint(v_path_line,
            ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326)
        );
    END IF;

    -- 3. 循环添加A*路径所有网格点（高度统一为安全高度）
    FOR i IN 1..array_length(v_path_ids, 1) LOOP
        v_path_line := ST_AddPoint(v_path_line,
            ST_SetSRID(ST_MakePoint(
                ST_X((SELECT g.geom FROM tmp_grid g WHERE g.id = v_path_ids[i])),
                ST_Y((SELECT g.geom FROM tmp_grid g WHERE g.id = v_path_ids[i])),
                p_safe_altitude), 4326)
        );
    END LOOP;

    -- 4. 如果高度模式为直升直降，则在终点位置添加一个安全高度点（终点上空悬停）
    IF p_height_mode = 0 THEN
        v_path_line := ST_AddPoint(v_path_line,
            ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
        );
    END IF;

    -- 5. 添加真实终点
    v_path_line := ST_AddPoint(v_path_line, v_end_pt);

    -- ====================== 原始路径可视连线简化 ======================
    -- 规则：
    -- 1. 从第二个点开始，判断“当前点 -> 下下个点”的直连线是否穿越禁飞区/管控区。
    -- 2. 若不穿越，则删除中间点，相当于把“第二点-第三点-第四点”简化为“第二点-第四点”。
    -- 3. 删除后继续用当前点向新的下下个点校验，直到倒数第二个点为止。
    -- 4. 若直连线穿越禁飞区/管控区，则保留中间点，并移动到下一个点继续判断。
    DECLARE
        v_simplify_idx INT := 2;                 -- 从第二个点开始校验
        v_direct_line geometry(LineStringZ,4326);-- 当前点到下下个点的直连线
        v_blocked BOOLEAN;                       -- 直连线是否穿越禁飞区/管控区
    BEGIN
        WHILE ST_NumPoints(v_path_line) >= 4
              AND v_simplify_idx <= ST_NumPoints(v_path_line) -
                  CASE
                      WHEN NOT (p_height_mode > 0 AND p_height_mode < 1) THEN 3
                      ELSE 2
                  END LOOP

            v_direct_line := ST_MakeLine(
                ST_PointN(v_path_line, v_simplify_idx),
                ST_PointN(v_path_line, v_simplify_idx + 2)
            );

            -- 仅判断禁飞区/管控区；不穿越则允许删除中间点。
            SELECT EXISTS(
                SELECT 1
                FROM public.bo_electric_fence f
                WHERE f.fence_type IN ('1', '2')
                  AND f.status = '1'
                  AND f.del_flag = false
                  AND ST_Intersects(
                      ST_SetSRID(ST_MakeValid(ST_Force2D(f.geom)), 4326),
                      ST_Force2D(v_direct_line)
                  )
            ) INTO v_blocked;

            IF NOT v_blocked THEN
                -- PostGIS点序号是1-based，ST_RemovePoint索引是0-based；删除中间点 idx+1。
                v_path_line := ST_RemovePoint(v_path_line, v_simplify_idx);
            ELSE
                v_simplify_idx := v_simplify_idx + 1;
            END IF;
        END LOOP;
    END;

 -- ====================== 路径平滑插值（生成实际可飞行的平滑轨迹） ======================
    v_final_path := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    DECLARE
        -- 每段路径之间插值的点数（值越大轨迹越平滑，但点数越多）
        v_interp_steps INT := 1;
        -- 原始路径的总段数（点数-1）
        v_seg_cnt INT;
        -- 当前线段的起点和终点几何对象
        v_p1 geometry; v_p2 geometry;
        -- 线段起点的经纬度
        v_lon1 DOUBLE PRECISION; v_lat1 DOUBLE PRECISION;
        -- 线段终点的经纬度
        v_lon2 DOUBLE PRECISION; v_lat2 DOUBLE PRECISION;
        -- 线性插值比例（0~1之间）
        v_t DOUBLE PRECISION;
        -- 循环变量：v_ix 为插值步数，s 为线段索引
        v_ix INT; s INT;
        -- 当前插值点的经纬度
        v_curr_lon DOUBLE PRECISION; v_curr_lat DOUBLE PRECISION;
    BEGIN
        -- 先添加真实起点
        v_final_path := ST_AddPoint(v_final_path, v_start_pt);
        v_seg_cnt := ST_NumPoints(v_path_line) - 1;  -- 原始路径的总段数

        -- 对于直升直降模式，在起点后直接添加一个安全高度点（原地垂直爬升）
        IF NOT (p_height_mode > 0 AND p_height_mode < 1) THEN
            v_final_path := ST_AddPoint(v_final_path,
                ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326)
            );
        END IF;

        -- 遍历原始路径的所有线段，对每段进行线性插值
        FOR s IN 1..v_seg_cnt LOOP
            v_p1 := ST_PointN(v_path_line, s);
            v_p2 := ST_PointN(v_path_line, s+1);
            v_lon1 := ST_X(v_p1); v_lat1 := ST_Y(v_p1);
            v_lon2 := ST_X(v_p2); v_lat2 := ST_Y(v_p2);

            -- 在当前线段内生成 v_interp_steps-1 个插值点（两端点已存在，所以减1）
            FOR v_ix IN 1..v_interp_steps - 1 LOOP
                v_t := v_ix::DOUBLE PRECISION / v_interp_steps;
                -- 经纬度线性插值
                v_curr_lon := v_lon1 + (v_lon2 - v_lon1) * v_t;
                v_curr_lat := v_lat1 + (v_lat2 - v_lat1) * v_t;

                -- 高度插值逻辑：根据高度模式决定当前点的高度
                IF p_height_mode > 0 AND p_height_mode < 1 THEN
                    -- 三段式平滑模式：计算当前点在整条路径中的比例位置
                    ratio := ((s-1) * v_interp_steps + v_ix)::DOUBLE PRECISION / (v_seg_cnt * v_interp_steps);
                    IF ratio <= p_height_mode THEN
                        -- 前 p_height_mode 比例：从起点高度平滑爬升到安全高度
                        new_z := p_start_alt + (p_safe_altitude - p_start_alt) * (ratio / p_height_mode);
                    ELSIF ratio >= 1 - p_height_mode THEN
                        -- 后 p_height_mode 比例：从安全高度平滑下降到终点高度
                        new_z := p_safe_altitude - (p_safe_altitude - p_end_alt) * ((ratio - (1 - p_height_mode)) / p_height_mode);
                    ELSE
                        -- 中间段：保持安全高度平飞
                        new_z := p_safe_altitude;
                    END IF;
                ELSE
                    -- 直升直降模式：全程使用安全高度（起点/终点高度已在起点/终点点中处理）
                    new_z := p_safe_altitude;
                END IF;

                -- 将插值点加入最终路径
                v_final_path := ST_AddPoint(v_final_path,
                    ST_SetSRID(ST_MakePoint(v_curr_lon, v_curr_lat, new_z), 4326)
                );
            END LOOP;
        END LOOP;

        -- 对于直升直降模式，在终点前添加一个安全高度点（终点上空悬停）
        IF NOT (p_height_mode > 0 AND p_height_mode < 1) THEN
            v_final_path := ST_AddPoint(v_final_path,
                ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
            );
        END IF;

        -- 最后加入真实终点
        v_final_path := ST_AddPoint(v_final_path, v_end_pt);
    END;

    -- ====================== 生成原始航点JSON数组 ======================
    -- 将原始路径（v_path_line）中的每个点转换为JSON对象，包含经度、纬度、高度
    SELECT jsonb_agg(
        jsonb_build_object('lon', ST_X(pt), 'lat', ST_Y(pt), 'alt', ST_Z(pt))
        ORDER BY idx
    ) INTO v_waypoints
    FROM (
        SELECT (ST_DumpPoints(v_path_line)).geom AS pt,
               generate_series(1, ST_NumPoints(v_path_line)) AS idx
    ) t;

    -- ====================== 生成平滑航点JSON数组 ======================
    -- 将平滑路径（v_final_path）中的每个点转换为JSON对象
    SELECT jsonb_agg(jsonb_build_object('lon', ST_X(p), 'lat', ST_Y(p), 'alt', ST_Z(p)))
    INTO v_smooth_waypoints
    FROM (SELECT (ST_DumpPoints(v_final_path)).geom AS p) AS t;

    -- 单段核心函数只返回计算结果，最终入库由 gis_flight_paths_plan 汇总后处理。
    DROP TABLE IF EXISTS tmp_grid;

    -- 返回最终生成的航线数据
    v_return_msg := format('规划成功：A*路径规划完成，执行时间 %s 秒',
                           ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN QUERY
    SELECT
        200, v_return_msg,
        NULL::integer, p_project_id::char(32), p_create_user::varchar(32), NOW()::timestamp,
        p_create_user::varchar(32), NOW()::timestamp, false,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_path_line, v_final_path,
        v_waypoints, v_smooth_waypoints,
        gis_linestring_length_m(v_final_path), p_height_mode;

-- ====================== 全局异常捕获：任何错误都返回直线航线（保证服务不崩溃） ======================
EXCEPTION WHEN OTHERS THEN
      -- 确保临时表被删除（如果存在）
    RAISE NOTICE '【调试】自动返回直线兜底航线，触发原因：%（SQLSTATE=%）', SQLERRM, SQLSTATE;
    DROP TABLE IF EXISTS tmp_grid;

    -- 异常兜底：生成两点直线航线（与分支1完全相同）
    v_path_line := ST_MakeLine(v_start_pt, v_end_pt);
    v_final_path := v_path_line;
    v_waypoints := jsonb_build_array(
        jsonb_build_object('lon', p_start_lon, 'lat', p_start_lat, 'alt', p_start_alt),
        jsonb_build_object('lon', p_end_lon, 'lat', p_end_lat, 'alt', p_end_alt)
    );
    v_smooth_waypoints := v_waypoints;

    -- 异常时也只返回兜底航线，不写入 gis_flight_paths。
    v_return_msg := format('执行异常：%s，已返回直线兜底航线，执行时间 %s 秒',
                           SQLERRM,
                           ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN QUERY
    SELECT
        500, v_return_msg,
        NULL::integer, p_project_id::char(32), p_create_user::varchar(32), NOW()::timestamp,
        p_create_user::varchar(32), NOW()::timestamp, false,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_path_line, v_final_path,
        v_waypoints, v_smooth_waypoints,
        gis_linestring_length_m(v_final_path), p_height_mode;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION gis_astar_3d_flight(
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR
) IS '单段航线';

-- ====================================================================================
-- gis_astar_3d_flight_plan
-- 对外入口函数：统一调用 gis_flight_paths_plan，最终只写入一条总航线。
-- ====================================================================================
/**
 * 函数名称：gis_astar_3d_flight_plan
 * 核心功能：对外航线规划入口。
 * 处理规则：
 *   1. 起终点距离不超过 5km：按 1 段计算。
 *   2. 起终点距离超过 5km：按每段不超过 5km 拆分。
 *   3. 所有分段统一合并，只写入一条总航线。
 */
CREATE OR REPLACE FUNCTION gis_astar_3d_flight_plan(
    p_start_lon        DOUBLE PRECISION,
    p_start_lat        DOUBLE PRECISION,
    p_start_alt        DOUBLE PRECISION,
    p_end_lon          DOUBLE PRECISION,
    p_end_lat          DOUBLE PRECISION,
    p_end_alt          DOUBLE PRECISION,
    p_safe_altitude    DOUBLE PRECISION DEFAULT 120,
    p_height_mode      DOUBLE PRECISION DEFAULT 0,
    p_force_gen        BOOLEAN DEFAULT FALSE,
    p_project_id       VARCHAR DEFAULT NULL,
    p_create_user      VARCHAR DEFAULT NULL
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
) AS $$
BEGIN
    IF p_start_lon IS NULL OR p_start_lat IS NULL OR p_start_alt IS NULL
       OR p_end_lon IS NULL OR p_end_lat IS NULL OR p_end_alt IS NULL THEN
        RETURN QUERY
        SELECT *
        FROM gis_astar_3d_flight(
            p_start_lon, p_start_lat, p_start_alt,
            p_end_lon, p_end_lat, p_end_alt,
            p_safe_altitude, p_height_mode, p_force_gen,
            p_project_id, p_create_user
        );
        RETURN;
    END IF;

    -- 正常入口统一走汇总函数：
    -- 5km 内按 1 段计算，超过 5km 自动拆段；最终只插入并返回一条总航线。
    RETURN QUERY
    SELECT *
    FROM gis_flight_paths_plan(
        jsonb_build_array(
            jsonb_build_object('lon', p_start_lon, 'lat', p_start_lat, 'alt', p_start_alt),
            jsonb_build_object('lon', p_end_lon, 'lat', p_end_lat, 'alt', p_end_alt)
        ),
        p_safe_altitude,
        p_force_gen,
        p_project_id,
        p_create_user,
        p_height_mode
    );
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION gis_astar_3d_flight_plan(
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR
) IS '分段入口';


-- =============================================================================
-- gis_flight_paths_plan
-- 支持起终点或多点规划。输入点超过 5km 的相邻段会按 5km 自动拆分后逐段规划，
-- 最后拼接为一条总航线写入 gis_flight_paths。
--
-- p_points 支持两种格式：
--   [{"lon":113.1,"lat":34.1,"alt":50},{"lon":113.2,"lat":34.2,"alt":50}]
--   [[113.1,34.1,50],[113.2,34.2,50]]
-- =============================================================================
DROP FUNCTION IF EXISTS gis_flight_paths_plan(JSONB, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS gis_flight_paths_plan(JSONB, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR, DOUBLE PRECISION);

CREATE OR REPLACE FUNCTION gis_flight_paths_plan(
    p_points         JSONB,
    p_safe_altitude  DOUBLE PRECISION DEFAULT 120,
    p_force_gen      BOOLEAN DEFAULT FALSE,
    p_project_id     VARCHAR DEFAULT NULL,
    p_create_user    VARCHAR DEFAULT NULL,
    p_height_mode    DOUBLE PRECISION DEFAULT 0
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
) AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_return_msg TEXT;

    v_input_count INT;
    v_segment_m DOUBLE PRECISION;
    v_segment_count INT;
    v_input_idx INT;
    v_segment_idx INT;
    v_ratio1 DOUBLE PRECISION;
    v_ratio2 DOUBLE PRECISION;

    v_lon1 DOUBLE PRECISION;
    v_lat1 DOUBLE PRECISION;
    v_alt1 DOUBLE PRECISION;
    v_lon2 DOUBLE PRECISION;
    v_lat2 DOUBLE PRECISION;
    v_alt2 DOUBLE PRECISION;

    v_seg_start_lon DOUBLE PRECISION;
    v_seg_start_lat DOUBLE PRECISION;
    v_seg_start_alt DOUBLE PRECISION;
    v_seg_end_lon DOUBLE PRECISION;
    v_seg_end_lat DOUBLE PRECISION;
    v_seg_end_alt DOUBLE PRECISION;

    v_part gis_flight_paths%ROWTYPE;
    v_part_count INT := 0;
    v_path_id INT;

    v_start_pt geometry(PointZ,4326);
    v_end_pt geometry(PointZ,4326);
    v_merged_path_line geometry(LineStringZ,4326) := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    v_merged_smooth_line geometry(LineStringZ,4326) := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    v_waypoints JSONB;
    v_smooth_waypoints JSONB;

    v_point_idx INT;
    v_point_count INT;
    v_append_start INT;
BEGIN
    IF p_points IS NULL OR jsonb_typeof(p_points) <> 'array' THEN
        code := 400;
        msg := format('参数错误：p_points 必须是 JSONB 数组，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_safe_altitude IS NULL OR p_safe_altitude <= 0 THEN
        code := 400;
        msg := format('参数错误：安全高度必须大于0，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS tmp_flight_plan_input_points;
    CREATE TEMP TABLE tmp_flight_plan_input_points ON COMMIT DROP AS
    SELECT
        ord::INT AS seq,
        (
            CASE
                WHEN jsonb_typeof(elem) = 'array' THEN elem->>0
                ELSE elem->>'lon'
            END
        )::DOUBLE PRECISION AS lon,
        (
            CASE
                WHEN jsonb_typeof(elem) = 'array' THEN elem->>1
                ELSE elem->>'lat'
            END
        )::DOUBLE PRECISION AS lat,
        COALESCE(
            NULLIF(
                CASE
                    WHEN jsonb_typeof(elem) = 'array' THEN elem->>2
                    ELSE elem->>'alt'
                END,
                ''
            )::DOUBLE PRECISION,
            p_safe_altitude
        ) AS alt
    FROM jsonb_array_elements(p_points) WITH ORDINALITY AS t(elem, ord);

    SELECT COUNT(*) INTO v_input_count FROM tmp_flight_plan_input_points;
    IF v_input_count < 2 THEN
        code := 400;
        msg := format('参数错误：p_points 至少需要包含 2 个坐标点，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM tmp_flight_plan_input_points
        WHERE lon IS NULL OR lat IS NULL OR alt IS NULL
    ) THEN
        code := 400;
        msg := format('参数错误：p_points 中存在无效坐标点，必须包含 lon/lat/alt 或 [lon,lat,alt]，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    SELECT ST_SetSRID(ST_MakePoint(lon, lat, alt), 4326)
    INTO v_start_pt
    FROM tmp_flight_plan_input_points
    WHERE seq = 1;

    SELECT ST_SetSRID(ST_MakePoint(lon, lat, alt), 4326)
    INTO v_end_pt
    FROM tmp_flight_plan_input_points
    WHERE seq = v_input_count;

    -- 相邻输入点逐段处理，单段超过 5km 则继续拆成若干小段。
    -- gis_astar_3d_flight 只负责计算并返回数据，不写入 gis_flight_paths。
    -- 本函数统一把所有分段结果合并后，只插入一条总航线。
    FOR v_input_idx IN 1..v_input_count - 1 LOOP
        SELECT lon, lat, alt INTO v_lon1, v_lat1, v_alt1
        FROM tmp_flight_plan_input_points WHERE seq = v_input_idx;

        SELECT lon, lat, alt INTO v_lon2, v_lat2, v_alt2
        FROM tmp_flight_plan_input_points WHERE seq = v_input_idx + 1;

        v_segment_m := SQRT(
            POWER((v_lon2 - v_lon1) * 111000.0 * COS(RADIANS((v_lat1 + v_lat2) / 2.0)), 2)
            + POWER((v_lat2 - v_lat1) * 111000.0, 2)
        );
        v_segment_count := GREATEST(1, CEIL(v_segment_m / 5000.0)::INT);

        FOR v_segment_idx IN 1..v_segment_count LOOP
            v_ratio1 := (v_segment_idx - 1)::DOUBLE PRECISION / v_segment_count;
            v_ratio2 := v_segment_idx::DOUBLE PRECISION / v_segment_count;

            v_seg_start_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio1;
            v_seg_start_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio1;
            v_seg_end_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio2;
            v_seg_end_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio2;

            v_seg_start_alt := CASE WHEN v_segment_idx = 1 THEN v_alt1 ELSE p_safe_altitude END;
            v_seg_end_alt := CASE WHEN v_segment_idx = v_segment_count THEN v_alt2 ELSE p_safe_altitude END;

            SELECT
                r.id, r.project_id, r.create_user, r.create_time,
                r.update_user, r.update_time, r.del_flag,
                r.start_point, r.end_point, r.safe_altitude,
                r.path_line, r.smooth_path_line,
                r.waypoints, r.smooth_waypoints,
                r.total_distance, r.smooth_ratio
            INTO v_part
            FROM gis_astar_3d_flight(
                v_seg_start_lon, v_seg_start_lat, v_seg_start_alt,
                v_seg_end_lon, v_seg_end_lat, v_seg_end_alt,
                p_safe_altitude,
                p_height_mode,
                TRUE,
                p_project_id,
                p_create_user
            ) r
            LIMIT 1;

            IF v_part.path_line IS NULL OR v_part.smooth_path_line IS NULL THEN
                RAISE EXCEPTION '分段路径规划失败：input_seq=%, segment=%', v_input_idx, v_segment_idx;
            END IF;

            v_part_count := v_part_count + 1;

            v_point_count := ST_NumPoints(v_part.path_line);
            v_append_start := CASE WHEN ST_NumPoints(v_merged_path_line) = 0 THEN 1 ELSE 2 END;
            FOR v_point_idx IN v_append_start..v_point_count LOOP
                v_merged_path_line := ST_AddPoint(v_merged_path_line, ST_PointN(v_part.path_line, v_point_idx));
            END LOOP;

            v_point_count := ST_NumPoints(v_part.smooth_path_line);
            v_append_start := CASE WHEN ST_NumPoints(v_merged_smooth_line) = 0 THEN 1 ELSE 2 END;
            FOR v_point_idx IN v_append_start..v_point_count LOOP
                v_merged_smooth_line := ST_AddPoint(v_merged_smooth_line, ST_PointN(v_part.smooth_path_line, v_point_idx));
            END LOOP;
        END LOOP;
    END LOOP;

    SELECT jsonb_agg(
        jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom))
        ORDER BY (dp).path[1]
    )
    INTO v_waypoints
    FROM ST_DumpPoints(v_merged_path_line) AS dp;

    SELECT jsonb_agg(
        jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom))
        ORDER BY (dp).path[1]
    )
    INTO v_smooth_waypoints
    FROM ST_DumpPoints(v_merged_smooth_line) AS dp;

    -- 所有分段点已经合并到 v_merged_path_line / v_merged_smooth_line。
    -- 这里只插入一条总航线记录，最终返回的也是这一条记录。
    INSERT INTO gis_flight_paths (
        project_id, create_user, update_user,
        start_point, end_point, safe_altitude,
        path_line, smooth_path_line,
        waypoints, smooth_waypoints, total_distance, smooth_ratio
    ) VALUES (
        p_project_id, p_create_user, p_create_user,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_merged_path_line, v_merged_smooth_line,
        v_waypoints, v_smooth_waypoints,
        gis_linestring_length_m(v_merged_smooth_line),
        p_height_mode
    ) RETURNING gis_flight_paths.id INTO v_path_id;

    -- 子分段只在内存中参与合并，不产生分段航线记录。
    v_return_msg := format('规划成功：多点/长距离分段规划完成，共计算 %s 个分段，执行时间 %s 秒',
                           v_part_count,
                           ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN QUERY SELECT 200, v_return_msg, p.* FROM gis_flight_paths p WHERE p.id = v_path_id;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := format('执行异常：%s，执行时间 %s 秒',
                  SQLERRM,
                  ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION gis_flight_paths_plan(JSONB, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR, DOUBLE PRECISION) IS '多点规划';



SELECT * FROM gis_astar_3d_flight_plan(
    113.64040905110176, 34.744365280882896, 50,
    113.65792057874526, 34.748111106532264, 50,
    140, 0, TRUE, 'TEST001', 'admin'
);

SELECT * FROM gis_astar_3d_flight_plan(
    113.64222358404974, 34.74451810188475, 50,
    113.64726547682564, 34.74503129632292, 50,
    140, 0, TRUE, 'TEST001', 'admin'
);
SELECT gis_astar_3d_flight_plan (
    113.6414337492313, 34.74416672368355, 50.0, 
    113.64713158192619, 34.745232119865804, 50.0, 
    120, 0, False, 'project_001', 'user_123'
    );

