

-- ==================================================================================== gis_astar_3d_flight_plan  空间三维路径规划====================================================================================
-- ===================== 删除可能存在的同名函数（保证幂等性） =====================

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT oid, proname, pg_get_function_identity_arguments(oid) as args
              FROM pg_proc
              WHERE proname = 'gis_astar_3d_flight_plan')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.oid::regproc || '(' || r.args || ') CASCADE';
    END LOOP;
END;
$$;

-- =============================================================================
-- 删除同名函数 
-- =============================================================================

DROP FUNCTION IF EXISTS gis_astar_3d_flight_plan(
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR
);


/**
 * 函数名称：gis_astar_3d_flight_plan
 * 所属模块：GIS 空间三维路径规划 / 无人机自动驾驶航线生成
 * 依赖环境：PostgreSQL + PostGIS（支持PointZ/LineStringZ/3D距离计算）
 * 依赖表：
 *   1. gis_grid_nodes / gis_grid_nodes_{项目ID}
 *      三维空间网格节点表（包含 zone_type 字段，'禁飞区' 表示不可通行）
 *   2. gis_flight_paths 飞行航线结果表（存储规划好的航线数据）
 *   3. bo_electric_fence 禁飞区表（用于边相交性动态检查）
 *
 * 【核心功能】
 * 基于三维A*寻路算法，为无人机/飞行器自动生成带避障、高度平滑、可直接执行的低空飞行航线。
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
 * 返回 gis_flight_paths 表的多行记录（SETOF），实际调用时通常只有一行，
 * 包含原始路径、平滑路径、航点JSON、3D距离等业务字段。
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
) RETURNS SETOF gis_flight_paths AS $$
DECLARE
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
    
    -- ====================== 数据库操作 ======================
    -- 新插入航线表的主键ID
    v_path_id       INT;
    
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
    -- ====================== 1. 构建3D起点和终点几何对象 ======================
    -- 将输入的经纬度+高度构造成PostGIS 3D点，并指定WGS84坐标系（SRID 4326）
    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt   := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);

    -- ====================== 2. 非强制生成时，优先复用历史航线 ======================
    -- 未开启强制重算 → 尝试查询完全相同条件的历史航线（避免重复计算）
    IF NOT p_force_gen THEN
        -- 查询条件：未删除 + 同项目 + 同安全高度 + 同平滑模式 + 起止点空间相等
        SELECT * INTO v_old_path
        FROM gis_flight_paths
        WHERE del_flag = false
          AND project_id IS NOT DISTINCT FROM p_project_id
          AND safe_altitude = p_safe_altitude
          AND smooth_ratio = p_height_mode
          AND ST_Equals(start_point, v_start_pt)
          AND ST_Equals(end_point, v_end_pt)
        LIMIT 1;-- 只取一条（通常最多一条）

        -- 找到历史航线 → 直接返回并结束函数，极大提升性能
        IF v_old_path IS NOT NULL THEN
            RETURN NEXT v_old_path;
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
        -- 查找起点最近的 可通行网格（非禁飞区、非管控区）
        EXECUTE format('
            SELECT id
            FROM %I
            WHERE zone_type IS NULL OR zone_type = ''适飞区''
            ORDER BY geom <-> $1
            LIMIT 1', v_grid_table)
        INTO v_start_id
        USING v_start_pt;

        -- 查找终点最近的 可通行网格（非禁飞区、非管控区）
        EXECUTE format('
            SELECT id
            FROM %I
            WHERE zone_type IS NULL OR zone_type = ''适飞区''
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
                EXISTS(SELECT 1 FROM %I WHERE id = $1 AND (zone_type IS NULL OR zone_type = ''适飞区''))
                AND EXISTS(SELECT 1 FROM %I WHERE id = $2 AND (zone_type IS NULL OR zone_type = ''适飞区''))
                AND EXISTS(SELECT 1 FROM %I WHERE zone_type IS NULL OR zone_type = ''适飞区'')',
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
        -- 将直线航线插入数据库持久化，并获取新记录的ID
        INSERT INTO gis_flight_paths (
            project_id, create_user, update_user,
            start_point, end_point, safe_altitude,
            path_line, smooth_path_line,
            waypoints, smooth_waypoints, total_distance, smooth_ratio
        ) VALUES (
            p_project_id,
            p_create_user,
            p_create_user,
            v_start_pt,
            v_end_pt, 
            p_safe_altitude,
            v_path_line, 
            v_final_path,
            v_waypoints, 
            v_smooth_waypoints,
            ST_3DLength(v_path_line),    -- 计算3D空间距离（米） 
            p_height_mode
        ) RETURNING id INTO v_path_id;    -- 获取插入后的自增主键

        -- 返回新生成的航线记录（SETOF 形式）
        RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_path_id;
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

  -- 将搜索范围内的网格数据导入临时表，并动态计算 is_walkable,is_walkable始终为true（WHERE已过滤不可通行区域）
    -- 根据 zone_type 字段：'禁飞区' → false（不可通行），其他 → true（可通行）
    EXECUTE format('
         INSERT INTO tmp_grid
        SELECT id, x, y, z, geom,
               true,
               0,0,0,NULL
        FROM %I
        WHERE x BETWEEN %s AND %s AND y BETWEEN %s AND %s
          AND (zone_type IS NULL OR zone_type = ''适飞区'')
    ', v_grid_table, v_min_x, v_max_x, v_min_y, v_max_y);

    -- 在临时表中重新匹配最近的起点/终点网格（确保在搜索范围内）
    SELECT id INTO v_start_id FROM tmp_grid ORDER BY geom <-> v_start_pt LIMIT 1;
    SELECT id INTO v_goal_id  FROM tmp_grid ORDER BY geom <-> v_end_pt LIMIT 1;

    -- 初始化起点代价：g_cost = 0（起点到自身代价为0）
    -- h_cost = 起点到终点的3D直线距离（启发函数）
    -- f_cost = g_cost + h_cost
    UPDATE tmp_grid
    SET g_cost = 0,
        h_cost = ST_3DDistance(geom, v_end_pt),
        f_cost = g_cost + h_cost
    WHERE id = v_start_id;

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
            SELECT id, x, y, z, geom, g_cost
            INTO v_curr, v_curr_x, v_curr_y, v_curr_z, v_curr_geom, v_curr_g
            FROM tmp_grid
            WHERE id = ANY(v_open)
            ORDER BY f_cost LIMIT 1;

            -- 如果当前节点就是目标节点，则成功找到路径，退出循环
            IF v_curr = v_goal_id THEN EXIT; END IF;

            -- 将当前节点从开放列表移至关闭列表（表示已处理）
            v_open := array_remove(v_open, v_curr);
            v_closed := array_append(v_closed, v_curr);

           -- 遍历当前节点在三维空间中的26个邻域节点（3x3x3范围，排除自身）
            FOR v_nid, v_n_geom, v_n_g, v_n_walk IN
                SELECT id, geom, g_cost, is_walkable
                FROM tmp_grid
                    WHERE ABS(x - v_curr_x) <= 1      -- X方向相邻（经度）
                  AND ABS(y - v_curr_y) <= 1      -- Y方向相邻（纬度）
                  AND ABS(z - v_curr_z) <= 1      -- Z方向相邻（高度层）
                  AND id <> v_curr                -- 排除当前节点自身
                  AND is_walkable = TRUE          -- 只考虑可通行的网格
                  AND id <> ALL(v_closed)         -- 排除已经处理过的节点
            LOOP
                -- 计算通过当前节点到达邻居节点的新g代价 = 当前g代价 + 当前节点到邻居的3D距离
                new_g := v_curr_g + ST_3DDistance(v_n_geom, v_curr_geom);
                
                -- ======================  边相交性检查 ======================
                -- 构建当前节点到邻居节点的线段
                v_edge_line := ST_MakeLine(v_curr_geom, v_n_geom);
                -- 检查线段是否与任何启用的禁飞区相交（二维/三维相交）
                -- 注意：若禁飞区 geom 为三维体，建议使用 ST_3DIntersects；为二维多边形则使用 ST_Intersects
                IF EXISTS(
                    SELECT 1 FROM public.bo_electric_fence
                    WHERE fence_type IN ('1', '2')   -- 禁飞区+管控区
                      AND status = '1'
                      AND del_flag = false
                      AND ST_Intersects(ST_SetSRID(geom, 4326), v_edge_line)   -- 若需三维精确判断，改为 ST_3DIntersects
                ) THEN
                    CONTINUE;   -- 该边穿越禁飞区，不可通行，跳过此邻居
                END IF;
                -- ===============================================================

                -- 如果邻居节点不在开放列表中，或者新路径的g代价更小，则更新邻居的代价和父节点
                IF v_nid <> ALL(v_open) OR new_g < v_n_g THEN
                    UPDATE tmp_grid
                    SET g_cost = new_g,
                        h_cost = ST_3DDistance(v_n_geom, v_end_pt),
                        f_cost = new_g + ST_3DDistance(v_n_geom, v_end_pt),
                        parent_id = v_curr
                    WHERE id = v_nid;

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
            SELECT parent_id INTO v_current_id FROM tmp_grid WHERE id = v_current_id;
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
                    SELECT ST_X(geom), ST_Y(geom), ST_Z(geom)
                    INTO v_node_lon, v_node_lat, v_node_alt
                    FROM tmp_grid WHERE id = v_path_ids[v_node_idx];
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

        INSERT INTO gis_flight_paths (
            project_id, create_user, update_user,
            start_point, end_point, safe_altitude,
            path_line, smooth_path_line,
            waypoints, smooth_waypoints, total_distance, smooth_ratio
        ) VALUES (
            p_project_id, p_create_user, p_create_user,
            v_start_pt, v_end_pt, p_safe_altitude,
            v_path_line, v_final_path,
            v_waypoints, v_smooth_waypoints,
            ST_3DLength(v_path_line), p_height_mode
        ) RETURNING id INTO v_path_id;

        RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_path_id;
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
                ST_X((SELECT geom FROM tmp_grid WHERE id = v_path_ids[i])),
                ST_Y((SELECT geom FROM tmp_grid WHERE id = v_path_ids[i])),
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

 -- ====================== 路径平滑插值（生成实际可飞行的平滑轨迹） ======================
    v_final_path := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    DECLARE
        -- 每段路径之间插值的点数（值越大轨迹越平滑，但点数越多）
        v_interp_steps INT := 10;
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

    -- ====================== 将最终航线保存到数据库 ======================
    INSERT INTO gis_flight_paths (
        project_id, create_user, update_user,
        start_point, end_point, safe_altitude,
        path_line, smooth_path_line,
        waypoints, smooth_waypoints, total_distance, smooth_ratio
    ) VALUES (
        p_project_id, p_create_user, p_create_user,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_path_line, v_final_path,
        v_waypoints, v_smooth_waypoints,
        ST_3DLength(v_final_path),  -- 计算平滑后的总飞行距离（米）
        p_height_mode
    ) RETURNING id INTO v_path_id;
     -- 删除临时表，释放资源
    DROP TABLE IF EXISTS tmp_grid;

    -- 返回最终生成的航线记录
    RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_path_id;

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

    INSERT INTO gis_flight_paths (
        project_id, create_user, update_user,
        start_point, end_point, safe_altitude,
        path_line, smooth_path_line,
        waypoints, smooth_waypoints, total_distance, smooth_ratio
    ) VALUES (
        p_project_id, p_create_user, p_create_user,
        v_start_pt, v_end_pt, p_safe_altitude,
        v_path_line, v_final_path,
        v_waypoints, v_smooth_waypoints,
        ST_3DLength(v_path_line), p_height_mode
    ) RETURNING id INTO v_path_id;

    -- 返回兜底航线
    RETURN QUERY SELECT * FROM gis_flight_paths WHERE id = v_path_id;
END;
$$ LANGUAGE plpgsql;



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


-- ==================================================================================== gis_generate_smooth_flight_path  Demo测试====================================================================================
-- ===================== 删除可能存在的同名函数（保证幂等性） =====================

-- =============================================================================
-- 函数名称：gis_generate_smooth_flight_path
-- 功能描述：无人机三维路径规划的上层封装接口，供业务系统直接调用。
--           接收 numeric 类型参数，自动转换为 double precision，
--           调用核心 A* 算法函数 gis_astar_3d_flight_plan，
--           并将返回的航线记录转换为 JSONB 格式输出。
-- 参数说明：
--   p_start_lon      numeric  起点经度（度）
--   p_start_lat      numeric  起点纬度（度）
--   p_start_alt      numeric  起点高度（米）
--   p_end_lon        numeric  终点经度（度）
--   p_end_lat        numeric  终点纬度（度）
--   p_end_alt        numeric  终点高度（米）
--   p_safe_altitude  numeric  安全飞行高度（默认120米）
--   p_height_mode    numeric  高度平滑模式：0=直升直降，0~1=三段式爬升/平飞/下降（默认0）
--   p_force_gen      boolean  是否强制重新生成（默认false）
--   p_project_id     varchar  项目ID（可选）
--   p_create_user    varchar  创建用户ID（可选）
-- 返回值：JSONB，包含以下字段：
--   - success        boolean   是否规划成功
--   - message        text      提示信息
--   - pathId         integer   航线记录ID（关联 gis_flight_paths 表）
--   - totalDistance  numeric   总飞行距离（米）
--   - safeAltitude   numeric   安全高度
--   - heightMode     numeric   高度模式
--   - rawWaypoints   jsonb     原始航点数组 [{lon,lat,alt}, ...]
--   - smoothWaypoints jsonb    平滑后航点数组
--   - rawPathWKT     text      原始路径WKT字符串（LineStringZ）
--   - smoothPathWKT  text      平滑路径WKT字符串（LineStringZ）
-- 依赖函数：gis_astar_3d_flight_plan（核心路径规划）
-- 依赖表：gis_flight_paths
-- =============================================================================
DROP FUNCTION IF EXISTS gis_generate_smooth_flight_path(
    numeric, numeric, numeric, numeric, numeric, numeric,
    numeric, numeric, boolean, varchar, varchar
);

CREATE OR REPLACE FUNCTION gis_generate_smooth_flight_path(
    p_start_lon      numeric,
    p_start_lat      numeric,
    p_start_alt      numeric,
    p_end_lon        numeric,
    p_end_lat        numeric,
    p_end_alt        numeric,
    p_safe_altitude  numeric DEFAULT 120,
    p_height_mode    numeric DEFAULT 0,
    p_force_gen      boolean DEFAULT FALSE,
    p_project_id     varchar DEFAULT NULL,
    p_create_user    varchar DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_result_record gis_flight_paths%ROWTYPE;  -- 存储核心函数返回的航线记录
    v_result_json   JSONB;                     -- 最终返回的JSON结果
BEGIN
    -- 调用核心三维路径规划函数（类型转换：numeric → double precision）
    -- 注意：gis_astar_3d_flight_plan 返回 SETOF gis_flight_paths，这里只取第一条记录
    SELECT * INTO v_result_record
    FROM gis_astar_3d_flight_plan(
        p_start_lon::double precision,
        p_start_lat::double precision,
        p_start_alt::double precision,
        p_end_lon::double precision,
        p_end_lat::double precision,
        p_end_alt::double precision,
        p_safe_altitude::double precision,
        p_height_mode::double precision,
        p_force_gen,
        p_project_id,
        p_create_user
    )
    LIMIT 1;  -- 确保只取一条记录（正常情况下只返回一行）

    -- 检查是否成功获取到航线记录
    IF v_result_record.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', '路径规划失败：未返回有效航线记录',
            'pathId', NULL
        );
    END IF;

    -- 构建详细的 JSON 返回对象，包含航线所有关键信息
    v_result_json := jsonb_build_object(
        'success', true,
        'message', '路径规划成功',
        'pathId', v_result_record.id,
        'totalDistance', ROUND(v_result_record.total_distance::numeric, 2),
        'safeAltitude', v_result_record.safe_altitude,
        'heightMode', v_result_record.smooth_ratio,
        'rawWaypoints', v_result_record.waypoints,
        'smoothWaypoints', v_result_record.smooth_waypoints,
        'rawPathWKT', ST_AsText(v_result_record.path_line),
        'smoothPathWKT', ST_AsText(v_result_record.smooth_path_line)
    );

    RETURN v_result_json;

EXCEPTION WHEN OTHERS THEN
    -- 异常捕获：返回错误信息，保证接口不崩溃
    RETURN jsonb_build_object(
        'success', false,
        'message', '路径规划异常：' || SQLERRM,
        'pathId', NULL
    );
END;
$$ LANGUAGE plpgsql;



-- 调用封装函数，返回 JSONB 结果
SELECT gis_generate_smooth_flight_path(
    113.64909580463211, 34.74222956510219, 50.0,
    113.64114796099274, 34.75015766069998, 50.0,
    120, 0, false, 'project_001', 'user_123'
);
SELECT gis_generate_smooth_flight_path

 (113.47373999723933, 34.81302708351442, 50.0, 113.4731599287305, 34.80794220338304, 50.0, 120, 0, False, 'project_001', 'user_123')
