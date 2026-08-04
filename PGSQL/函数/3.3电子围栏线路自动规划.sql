-- =============================================================================
-- 3.2线路自动规划.sql
--   gis_linestring_length_m                 计算三维航线实际长度
--   gis_flight_point_in_fence               判断航点是否在围栏
--   gis_flight_line_intersects_fence        判断航线是否穿越围栏
--   gis_astar_3d_flight                     规划单段三维避障航线
--   gis_astar_3d_flight_plan                单段航线自动规划接口
--   gis_flight_paths_plan                   多点航线自动分段规划
--
-- =============================================================================

-- =============================================================================
-- 2026-07-13 维护备注：航线平滑与直升直降规则
-- 1. p_height_mode = 0 且起点高度 != 安全高度时，必须保留：
--      起点真实高度 -> 起点安全高度
-- 2. p_height_mode = 0 且终点高度 != 安全高度时，必须保留：
--      终点安全高度 -> 终点真实高度
-- 3. 起点/终点高度都等于安全高度时，若直线不穿越围栏，允许最终简化为：
--      起点 -> 终点
-- 4. 直线兜底、A*失败兜底、异常兜底、长距离快速直线返回，都必须按同一套直升直降规则构造航线。
-- 5. 原始航线 path_line 和平滑航线 smooth_path_line 在返回/入库前会删除连续重复点；
--    仅删除 XYZ 都相同的重复点，同经纬度但高度不同的直升直降点必须保留。
-- =============================================================================

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
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_linestring_length_m');
-- =============================================================================
-- 函数介绍：gis_linestring_length_m
-- 主要作用：计算LineString或LineStringZ航线的近似三维实际长度，单位米。
-- 入参说明：p_line 为PostGIS线几何，支持带Z高度的三维航线。
-- 返回说明：返回整条线各相邻点段长度累加值，二维距离按经纬度近似换算，高度差按米计算。
-- 注意事项：该函数用于航线距离统计，适合小范围无人机航线；超大范围需改用更精确测地线算法。
-- =============================================================================
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
COMMENT ON FUNCTION gis_linestring_length_m(geometry) IS '计算三维航线实际长度';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_linestring_remove_duplicate_points');
-- =============================================================================
-- 函数介绍：gis_linestring_remove_duplicate_points
-- 主要作用：删除LineString航线中的连续重复点。
-- 返回说明：仅当连续点XYZ都相同才删除；同经纬度但高度不同的直升直降点会保留。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_linestring_remove_duplicate_points(p_line geometry)
RETURNS geometry
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_clean geometry;
    v_count integer;
BEGIN
    IF p_line IS NULL OR ST_IsEmpty(p_line) OR GeometryType(p_line) NOT IN ('LINESTRING', 'LINESTRINGZ') THEN
        RETURN p_line;
    END IF;

    WITH pts AS (
        SELECT
            (dp).path[1] AS idx,
            (dp).geom AS geom,
            lag((dp).geom) OVER (ORDER BY (dp).path[1]) AS prev_geom
        FROM ST_DumpPoints(p_line) AS dp
    ),
    kept AS (
        SELECT idx, geom
        FROM pts
        WHERE prev_geom IS NULL
           OR abs(ST_X(geom) - ST_X(prev_geom)) > 0.000000001
           OR abs(ST_Y(geom) - ST_Y(prev_geom)) > 0.000000001
           OR abs(COALESCE(ST_Z(geom), 0) - COALESCE(ST_Z(prev_geom), 0)) > 0.000000001
    )
    SELECT ST_SetSRID(ST_MakeLine(geom ORDER BY idx), ST_SRID(p_line)), count(*)
    INTO v_clean, v_count
    FROM kept;

    IF COALESCE(v_count, 0) < 2 THEN
        RETURN p_line;
    END IF;

    RETURN v_clean;
END;
$$;
COMMENT ON FUNCTION gis_linestring_remove_duplicate_points(geometry) IS '删除LineString连续重复点，保留同经纬度不同高度的直升直降点';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_point_in_fence');
-- =============================================================================
-- 函数介绍：gis_flight_point_in_fence
-- 主要作用：判断单个航点是否落入禁飞区或管控区。
-- 入参说明：p_point 为航点几何；p_project_id 用于匹配全局电子围栏和项目国家规定表。
-- 返回说明：返回boolean，true表示航点命中不可通行围栏，false表示未命中。
-- 注意事项：同时检查 bo_electric_fence 和 gis_electric_fence_<project_id>。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_flight_point_in_fence(
    p_point geometry,
    p_project_id varchar DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_hit boolean := false;
    v_project_fence_table text;
    v_project_fence_has_height boolean := false;
BEGIN
    IF p_point IS NULL THEN
        RETURN false;
    END IF;

    IF to_regclass('public.bo_electric_fence') IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1
            FROM public.bo_electric_fence f
            WHERE f.geom IS NOT NULL
              AND f.fence_type IN ('1', '2')
              AND f.status = '1'
              AND f.del_flag = false
              AND f.use_enabled = true
              AND (COALESCE(p_project_id, '') = '' OR f.project_id::text = p_project_id::text)
              AND (
                  COALESCE(f.height, 0) = 0
                  OR COALESCE(ST_Z(p_point), 0) <= f.height
              )
              AND ST_Covers(
                  ST_SetSRID(ST_MakeValid(ST_Force2D(f.geom)), 4326),
                  ST_Force2D(p_point)
              )
        ) INTO v_hit;

        IF v_hit THEN
            RETURN true;
        END IF;
    END IF;

    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
        v_project_fence_table := 'gis_electric_fence_' || regexp_replace(trim(p_project_id), '[^0-9a-zA-Z_]', '', 'g');
        IF to_regclass(format('%I.%I', 'public', v_project_fence_table)) IS NOT NULL THEN
            SELECT EXISTS(
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = v_project_fence_table
                  AND column_name = 'height'
            ) INTO v_project_fence_has_height;

            EXECUTE format('
                SELECT EXISTS(
                    SELECT 1
                    FROM %I.%I f
                    WHERE f.geom IS NOT NULL
                      AND f.fence_type IN (''1'', ''2'')
                      %s
                      AND ST_Covers(
                          ST_SetSRID(ST_MakeValid(ST_Force2D(f.geom)), 4326),
                          ST_Force2D($1)
                      )
                )',
                'public',
                v_project_fence_table,
                CASE WHEN v_project_fence_has_height THEN
                    'AND (COALESCE(f.height, 0) = 0 OR COALESCE(ST_Z($1), 0) <= f.height)'
                ELSE
                    ''
                END
            )
            INTO v_hit
            USING p_point;

            IF v_hit THEN
                RETURN true;
            END IF;
        END IF;
    END IF;

    RETURN false;
END;
$$;
COMMENT ON FUNCTION gis_flight_point_in_fence(geometry, varchar) IS '判断航点是否在围栏';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_line_intersects_fence');
-- =============================================================================
-- 函数介绍：gis_flight_line_intersects_fence
-- 主要作用：判断航线线段是否穿越禁飞区或管控区。
-- 入参说明：p_line 为待检测航线几何；p_project_id 用于匹配全局电子围栏和项目国家规定表。
-- 返回说明：返回boolean，true表示线段与不可通行围栏相交，false表示未相交。
-- 注意事项：同时检查 bo_electric_fence 和 gis_electric_fence_<project_id>。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_flight_line_intersects_fence(
    p_line geometry,
    p_project_id varchar DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_hit boolean := false;
    v_project_fence_table text;
    v_project_fence_has_height boolean := false;
BEGIN
    IF p_line IS NULL THEN
        RETURN false;
    END IF;

    IF to_regclass('public.bo_electric_fence') IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1
            FROM public.bo_electric_fence f
            WHERE f.geom IS NOT NULL
              AND f.fence_type IN ('1', '2')
              AND f.status = '1'
              AND f.del_flag = false
              AND f.use_enabled = true
              AND (COALESCE(p_project_id, '') = '' OR f.project_id::text = p_project_id::text)
              AND (
                  COALESCE(f.height, 0) = 0
                  OR (
                      SELECT MIN(ST_Z((dp).geom))
                      FROM ST_DumpPoints(p_line) AS dp
                  ) <= f.height
              )
              AND ST_Intersects(
                  ST_SetSRID(ST_MakeValid(ST_Force2D(f.geom)), 4326),
                  ST_Force2D(p_line)
              )
        ) INTO v_hit;

        IF v_hit THEN
            RETURN true;
        END IF;
    END IF;

    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
        v_project_fence_table := 'gis_electric_fence_' || regexp_replace(trim(p_project_id), '[^0-9a-zA-Z_]', '', 'g');
        IF to_regclass(format('%I.%I', 'public', v_project_fence_table)) IS NOT NULL THEN
            SELECT EXISTS(
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = v_project_fence_table
                  AND column_name = 'height'
            ) INTO v_project_fence_has_height;

            EXECUTE format('
                SELECT EXISTS(
                    SELECT 1
                    FROM %I.%I f
                    WHERE f.geom IS NOT NULL
                      AND f.fence_type IN (''1'', ''2'')
                      %s
                      AND ST_Intersects(
                          ST_SetSRID(ST_MakeValid(ST_Force2D(f.geom)), 4326),
                          ST_Force2D($1)
                      )
                )',
                'public',
                v_project_fence_table,
                CASE WHEN v_project_fence_has_height THEN
                    'AND (COALESCE(f.height, 0) = 0 OR (SELECT MIN(ST_Z((dp).geom)) FROM ST_DumpPoints($1) AS dp) <= f.height)'
                ELSE
                    ''
                END
            )
            INTO v_hit
            USING p_line;

            IF v_hit THEN
                RETURN true;
            END IF;
        END IF;
    END IF;

    RETURN false;
END;
$$;
COMMENT ON FUNCTION gis_flight_line_intersects_fence(geometry, varchar) IS '判断航线是否穿越围栏';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_astar_3d_flight');

-- =============================================================================
-- 函数介绍：gis_astar_3d_flight
-- 主要作用：对单段起终点执行三维A*航线规划，自动避开网格中不可飞节点和围栏穿越边。
-- 入参说明：包含起点/终点经纬高、安全高度、高度模式、是否强制重算、项目ID和创建人。
-- 返回说明：返回规划状态、航线记录字段、原始路径、平滑路径、航点JSON和距离统计。
-- 注意事项：优先复用历史航线；强制重算或无历史时读取项目网格表，失败时会降级返回直线航线。
-- =============================================================================
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
    v_start_safe_pt geometry(PointZ,4326);
    v_end_safe_pt   geometry(PointZ,4326);
    
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
    -- A*算法生成的初始三维线路（未做可视连线简化）
    v_raw_path_line geometry(LineStringZ,4326);
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
    -- 本次A*两点距离（米），用于动态调整搜索范围
    v_astar_segment_m DOUBLE PRECISION;
    -- 搜索范围外扩网格数：短线小、长线大，避免固定外扩导致短线变慢或长线绕不开
    v_expand_grid INT;
    
    -- ====================== 算法控制标志 ======================
    -- 是否启用A*算法进行路径规划（true=启用，false=直接直线）
    v_use_astar     BOOLEAN := false;
    -- 实际参与本次规划的网格表名；优先使用项目网格表 gis_grid_nodes_{项目ID}
    v_grid_table     TEXT;
    v_debug_tmp_grid_count BIGINT;
    v_debug_start_node TEXT;
    v_debug_goal_node TEXT;
    v_debug_path_ids_before_trim INT[];
    
    -- ====================== 边检查辅助变量 ======================
    v_edge_line     geometry(LineStringZ,4326);   -- 节点间的线段几何
    v_log_sql      text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_astar_3d_flight(%s, %s, %s, %s, %s, %s, %s, %s, %L, %L, %L);',
        COALESCE(p_start_lon::text, 'NULL'), COALESCE(p_start_lat::text, 'NULL'), COALESCE(p_start_alt::text, 'NULL'),
        COALESCE(p_end_lon::text, 'NULL'), COALESCE(p_end_lat::text, 'NULL'), COALESCE(p_end_alt::text, 'NULL'),
        COALESCE(p_safe_altitude::text, 'NULL'), COALESCE(p_height_mode::text, 'NULL'),
        p_force_gen, p_project_id, p_create_user);

    -- ====================== 0. 基础参数校验 ======================
    IF p_start_lon IS NULL OR p_start_lat IS NULL OR p_start_alt IS NULL
       OR p_end_lon IS NULL OR p_end_lat IS NULL OR p_end_alt IS NULL THEN
        code := 400;
        msg := format('参数错误：起点/终点经纬度和高度不能为空，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_safe_altitude IS NULL OR p_safe_altitude <= 0 THEN
        code := 400;
        msg := format('参数错误：安全高度必须大于0，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_height_mode IS NULL OR p_height_mode < 0 OR p_height_mode >= 1 THEN
        code := 400;
        msg := format('参数错误：高度平滑模式必须满足 0 <= p_height_mode < 1，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    -- ====================== 1. 构建3D起点和终点几何对象 ======================
    -- 将输入的经纬度+高度构造成PostGIS 3D点，并指定WGS84坐标系（SRID 4326）
    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt   := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);
    v_start_safe_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326);
    v_end_safe_pt   := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326);
    RAISE NOTICE '【A*调试】规划安全高度点：start_safe=(%,%,%), end_safe=(%,%,%)',
        ST_X(v_start_safe_pt), ST_Y(v_start_safe_pt), ST_Z(v_start_safe_pt),
        ST_X(v_end_safe_pt), ST_Y(v_end_safe_pt), ST_Z(v_end_safe_pt);

    IF gis_flight_point_in_fence(v_start_pt, p_project_id) THEN
        code := 400;
        msg := format('参数错误：起点在禁飞区或管控区内，start=(%s,%s,%s)，执行时间 %s 秒',
                      p_start_lon, p_start_lat, p_start_alt,
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF gis_flight_point_in_fence(v_end_pt, p_project_id) THEN
        code := 400;
        msg := format('参数错误：终点在禁飞区或管控区内，end=(%s,%s,%s)，执行时间 %s 秒',
                      p_end_lon, p_end_lat, p_end_alt,
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

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
              AND ST_Z(geom) <= $2
            ORDER BY geom <-> $1
            LIMIT 1', v_grid_table)
        INTO v_start_id
        USING v_start_safe_pt, p_safe_altitude;

        -- 查找终点最近的可通行网格，优先使用综合 is_flyable 标记。
        EXECUTE format('
            SELECT id
            FROM %I
            WHERE is_flyable = true
              AND ST_Z(geom) <= $2
            ORDER BY geom <-> $1
            LIMIT 1', v_grid_table)
        INTO v_goal_id
        USING v_end_safe_pt, p_safe_altitude;
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
                EXISTS(SELECT 1 FROM %I WHERE id = $1 AND is_flyable = true AND ST_Z(geom) <= $3)
                AND EXISTS(SELECT 1 FROM %I WHERE id = $2 AND is_flyable = true AND ST_Z(geom) <= $3)
                AND EXISTS(SELECT 1 FROM %I WHERE is_flyable = true AND ST_Z(geom) <= $3)',
            v_grid_table, v_grid_table, v_grid_table)
        INTO v_use_astar
        USING v_start_id, v_goal_id, p_safe_altitude;
    ELSE
        v_use_astar := false;
    END IF;

    -- ====================== 分支1：不满足A* → 直接生成两点直线航线（兜底方案） ======================
    -- 此分支处理以下情况：网格表为空、起点或终点在禁飞区、无法匹配网格等
    IF NOT v_use_astar THEN
        IF v_grid_table IS NULL THEN
            code := 500;
            msg := format('规划失败：未找到可用网格表，无法启用A*，执行时间 %s 秒',
                          ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        ELSIF v_start_id IS NULL AND v_goal_id IS NULL THEN
            code := 400;
            msg := format('规划失败：起点和终点附近均未找到可飞网格节点，grid_table=%s，执行时间 %s 秒',
                          v_grid_table,
                          ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        ELSIF v_start_id IS NULL THEN
            code := 400;
            msg := format('规划失败：起点附近未找到可飞网格节点，grid_table=%s，执行时间 %s 秒',
                          v_grid_table,
                          ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        ELSIF v_goal_id IS NULL THEN
            code := 400;
            msg := format('规划失败：终点附近未找到可飞网格节点，grid_table=%s，执行时间 %s 秒',
                          v_grid_table,
                          ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        ELSE
            code := 500;
            msg := format('规划失败：网格数据状态不一致，A*启用校验未通过，grid_table=%s，start_id=%s，goal_id=%s，执行时间 %s 秒',
                          v_grid_table,
                          COALESCE(v_start_id::text, 'NULL'),
                          COALESCE(v_goal_id::text, 'NULL'),
                          ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        END IF;

        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
        -- 构建符合直升直降规则的3D直线航线。
        v_path_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
        v_path_line := ST_AddPoint(v_path_line, v_start_pt);
        IF p_height_mode = 0 AND abs(p_start_alt - p_safe_altitude) > 0.001 THEN
            v_path_line := ST_AddPoint(v_path_line,
                ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326)
            );
        END IF;
        IF p_height_mode = 0 AND abs(p_end_alt - p_safe_altitude) > 0.001 THEN
            v_path_line := ST_AddPoint(v_path_line,
                ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
            );
        END IF;
        v_path_line := ST_AddPoint(v_path_line, v_end_pt);
        v_path_line := gis_linestring_remove_duplicate_points(v_path_line);
        -- 最终路径 = 原始直线路径（未经平滑）
        v_final_path := v_path_line;
        SELECT jsonb_agg(
            jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom))
            ORDER BY (dp).path[1]
        )
        INTO v_waypoints
        FROM ST_DumpPoints(v_path_line) AS dp;
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

    v_astar_segment_m := SQRT(
        POWER((p_end_lon - p_start_lon) * 111000.0 * COS(RADIANS((p_start_lat + p_end_lat) / 2.0)), 2)
        + POWER((p_end_lat - p_start_lat) * 111000.0, 2)
    );

    v_expand_grid := CASE
        WHEN v_astar_segment_m <= 1000 THEN 3
        WHEN v_astar_segment_m <= 2000 THEN 5
        WHEN v_astar_segment_m <= 5000 THEN 10
        WHEN v_astar_segment_m <= 10000 THEN 20
        WHEN v_astar_segment_m <= 20000 THEN 40
        ELSE 60
    END;

    -- 按本次A*两点距离动态扩大搜索范围，避免短线过慢、长线绕不开。
    -- 先确定原始范围（确保min <= max），再向外扩展
    SELECT least(v_min_x, v_max_x), greatest(v_min_x, v_max_x)
    INTO v_min_x, v_max_x;
    v_min_x := v_min_x - v_expand_grid;
    v_max_x := v_max_x + v_expand_grid;
    
    SELECT least(v_min_y, v_max_y), greatest(v_min_y, v_max_y)
    INTO v_min_y, v_max_y;
    v_min_y := v_min_y - v_expand_grid;
    v_max_y := v_max_y + v_expand_grid;

  -- 将搜索范围内的可飞网格数据导入临时表；is_walkable 始终为 true（WHERE 已过滤不可通行区域）
    EXECUTE format('
         INSERT INTO tmp_grid
        SELECT id, x, y, z, geom,
               true,
               0,0,0,NULL
        FROM %I
        WHERE x BETWEEN %s AND %s AND y BETWEEN %s AND %s
          AND is_flyable = true
          AND ST_Z(geom) <= %s
    ', v_grid_table, v_min_x, v_max_x, v_min_y, v_max_y, p_safe_altitude);

    CREATE INDEX idx_tmp_grid_xyz ON tmp_grid (x, y, z);
    CREATE INDEX idx_tmp_grid_geom ON tmp_grid USING GIST (geom);
    ANALYZE tmp_grid;

    SELECT COUNT(*) INTO v_debug_tmp_grid_count FROM tmp_grid;
    RAISE NOTICE '【A*调试】tmp_grid_count=%, safe_altitude=%, segment_m=%, expand_grid=%, x_range=[%,%], y_range=[%,%]',
        v_debug_tmp_grid_count,
        p_safe_altitude,
        ROUND(v_astar_segment_m::numeric, 2),
        v_expand_grid,
        v_min_x, v_max_x, v_min_y, v_max_y;
    FOR v_debug_start_node IN
        SELECT format('z=%s, alt=%s, count=%s', z, ST_Z(geom), count(*))
        FROM tmp_grid
        GROUP BY z, ST_Z(geom)
        ORDER BY z
    LOOP
        RAISE NOTICE '【A*调试】tmp_grid高度层：%', v_debug_start_node;
    END LOOP;

    -- 在临时表中重新匹配最近的起点/终点网格（确保在搜索范围内）
    SELECT g.id INTO v_start_id FROM tmp_grid g ORDER BY g.geom <-> v_start_safe_pt LIMIT 1;
    SELECT g.id INTO v_goal_id  FROM tmp_grid g ORDER BY g.geom <-> v_end_safe_pt LIMIT 1;

    SELECT format('id=%s,x=%s,y=%s,z=%s,lon=%s,lat=%s,alt=%s,dist_m=%s',
                  g.id, g.x, g.y, g.z, ST_X(g.geom), ST_Y(g.geom), ST_Z(g.geom),
                  ROUND(ST_Distance(g.geom::geography, v_start_safe_pt::geography)::numeric, 3))
    INTO v_debug_start_node
    FROM tmp_grid g
    WHERE g.id = v_start_id;
    SELECT format('id=%s,x=%s,y=%s,z=%s,lon=%s,lat=%s,alt=%s,dist_m=%s',
                  g.id, g.x, g.y, g.z, ST_X(g.geom), ST_Y(g.geom), ST_Z(g.geom),
                  ROUND(ST_Distance(g.geom::geography, v_end_safe_pt::geography)::numeric, 3))
    INTO v_debug_goal_node
    FROM tmp_grid g
    WHERE g.id = v_goal_id;
    RAISE NOTICE '【A*调试】tmp重选start：%', COALESCE(v_debug_start_node, 'NULL');
    RAISE NOTICE '【A*调试】tmp重选goal ：%', COALESCE(v_debug_goal_node, 'NULL');

    -- 初始化起点代价：g_cost = 0（起点到自身代价为0）
    -- h_cost = 起点到终点的3D直线距离（启发函数）
    -- f_cost = g_cost + h_cost
    UPDATE tmp_grid g
    SET g_cost = 0,
        h_cost = ST_3DDistance(g.geom, v_end_safe_pt),
        f_cost = 0 + ST_3DDistance(g.geom, v_end_safe_pt)
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
                    WHERE g.x BETWEEN v_curr_x - 1 AND v_curr_x + 1      -- X方向相邻（经度）
                  AND g.y BETWEEN v_curr_y - 1 AND v_curr_y + 1      -- Y方向相邻（纬度）
                  AND g.z BETWEEN v_curr_z - 1 AND v_curr_z + 1      -- Z方向相邻（高度层）
                  AND g.id <> v_curr                -- 排除当前节点自身
                  AND g.is_walkable = TRUE          -- 只考虑可通行的网格
                  AND g.id <> ALL(v_closed)         -- 排除已经处理过的节点
            LOOP
                -- 计算通过当前节点到达邻居节点的新g代价 = 当前g代价 + 当前节点到邻居的3D距离
                new_g := v_curr_g + ST_3DDistance(v_n_geom, v_curr_geom);
                
                -- ======================  边相交性检查 ======================
                -- 构建当前节点到邻居节点的线段
                v_edge_line := ST_MakeLine(v_curr_geom, v_n_geom);
                -- 统一使用封装函数判断禁飞区/管控区，包含 bo_electric_fence 和项目专属国家规定围栏。
                IF gis_flight_line_intersects_fence(v_edge_line, p_project_id) THEN
                    CONTINUE;   -- 该边穿越禁飞区，不可通行，跳过此邻居
                END IF;
                -- ===============================================================

                -- 如果邻居节点不在开放列表中，或者新路径的g代价更小，则更新邻居的代价和父节点
                IF v_nid <> ALL(v_open) OR new_g < v_n_g THEN
                    UPDATE tmp_grid g
                    SET g_cost = new_g,
                        h_cost = ST_3DDistance(v_n_geom, v_end_safe_pt),
                        f_cost = new_g + ST_3DDistance(v_n_geom, v_end_safe_pt),
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
        -- 仅当路径中确实包含虚拟节点（起点ID=-1，终点ID=-2）时才移除首尾。
        -- 当前A*回溯使用真实网格节点ID，不能无条件裁掉首尾，否则两节点路径会被裁空。
        v_debug_path_ids_before_trim := v_path_ids;
        RAISE NOTICE '【A*调试】回溯裁剪前 path_ids=%', v_debug_path_ids_before_trim;
        IF array_length(v_path_ids, 1) >= 2
           AND v_path_ids[1] = -1
           AND v_path_ids[array_length(v_path_ids, 1)] = -2 THEN
            v_path_ids := v_path_ids[2:array_length(v_path_ids, 1)-1];
        END IF;
        RAISE NOTICE '【A*调试】回溯裁剪后 path_ids=%', v_path_ids;
        
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
        DROP TABLE IF EXISTS tmp_grid;
        code := 400;
        msg := format('规划失败：A*未找到有效路径，无法生成避障航线，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
        DROP TABLE IF EXISTS tmp_grid;-- 清理临时表
        -- 生成符合直升直降规则的直线航线（与分支1逻辑相同）
        v_path_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
        v_path_line := ST_AddPoint(v_path_line, v_start_pt);
        IF p_height_mode = 0 AND abs(p_start_alt - p_safe_altitude) > 0.001 THEN
            v_path_line := ST_AddPoint(v_path_line,
                ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326)
            );
        END IF;
        IF p_height_mode = 0 AND abs(p_end_alt - p_safe_altitude) > 0.001 THEN
            v_path_line := ST_AddPoint(v_path_line,
                ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
            );
        END IF;
        v_path_line := ST_AddPoint(v_path_line, v_end_pt);
        v_path_line := gis_linestring_remove_duplicate_points(v_path_line);
        v_final_path := v_path_line;
        SELECT jsonb_agg(
            jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom))
            ORDER BY (dp).path[1]
        )
        INTO v_waypoints
        FROM ST_DumpPoints(v_path_line) AS dp;
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
    IF p_height_mode = 0
       AND abs(p_start_alt - p_safe_altitude) > 0.001 THEN
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
    IF p_height_mode = 0
       AND abs(p_end_alt - p_safe_altitude) > 0.001 THEN
        v_path_line := ST_AddPoint(v_path_line,
            ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
        );
    END IF;

    -- 5. 添加真实终点
    v_path_line := ST_AddPoint(v_path_line, v_end_pt);
    v_raw_path_line := v_path_line;
    v_raw_path_line := gis_linestring_remove_duplicate_points(v_raw_path_line);

    -- ====================== 原始路径可视连线简化 ======================
    -- 规则：
    -- 1. 起点高度与安全高度不一致时保留起点原地升降段；一致时起点参与简化。
    -- 2. 终点高度与安全高度不一致时保留终点原地升降段；一致时终点参与简化。
    -- 3. 判断“当前点 -> 下下个点”的直连线是否穿越禁飞区/管控区，不穿越则删除中间点。
    -- 4. 删除后继续用当前点向新的下下个点校验；若穿越则保留中间点并移动到下一个点。
    DECLARE
        v_simplify_idx INT := 2;                 -- 默认跳过起点原地升降段，从第二个点开始校验
        v_simplify_end_offset INT := 3;          -- 默认保留终点原地升降段
        v_min_simplify_points INT := 3;          -- 无起降垂直段时，允许3点压缩为2点
        v_has_start_vertical BOOLEAN := (p_height_mode = 0 AND abs(p_start_alt - p_safe_altitude) > 0.001);
        v_has_end_vertical BOOLEAN := (p_height_mode = 0 AND abs(p_end_alt - p_safe_altitude) > 0.001);
        v_direct_line geometry(LineStringZ,4326);-- 当前点到下下个点的直连线
        v_blocked BOOLEAN;                       -- 直连线是否穿越禁飞区/管控区
    BEGIN
        IF NOT v_has_start_vertical THEN
            v_simplify_idx := 1;
        ELSE
            v_min_simplify_points := 4;
        END IF;

        IF NOT v_has_end_vertical THEN
            v_simplify_end_offset := 2;
        ELSE
            v_min_simplify_points := 4;
        END IF;

        WHILE ST_NumPoints(v_path_line) >= v_min_simplify_points
              AND v_simplify_idx <= ST_NumPoints(v_path_line) - v_simplify_end_offset LOOP

            v_direct_line := ST_MakeLine(
                ST_PointN(v_path_line, v_simplify_idx),
                ST_PointN(v_path_line, v_simplify_idx + 2)
            );

            -- 仅当直连线不穿越禁飞区/管控区时才允许删除中间点。
            v_blocked := gis_flight_line_intersects_fence(v_direct_line, p_project_id);

            IF NOT v_blocked THEN
                -- PostGIS点序号是1-based，ST_RemovePoint索引是0-based；删除中间点 idx+1。
                v_path_line := ST_RemovePoint(v_path_line, v_simplify_idx);
            ELSE
                v_simplify_idx := v_simplify_idx + 1;
            END IF;
        END LOOP;
    END;

    v_path_line := gis_linestring_remove_duplicate_points(v_path_line);
    -- 平滑路径当前直接使用简化后的 v_path_line。
    v_final_path := v_path_line;

    -- ====================== 生成原始航点JSON数组 ======================
    -- 将A*初始路径（v_raw_path_line）中的每个点转换为JSON对象，包含经度、纬度、高度
    SELECT jsonb_agg(
        jsonb_build_object('lon', ST_X(pt), 'lat', ST_Y(pt), 'alt', ST_Z(pt))
        ORDER BY idx
    ) INTO v_waypoints
    FROM (
        SELECT (ST_DumpPoints(v_raw_path_line)).geom AS pt,
               generate_series(1, ST_NumPoints(v_raw_path_line)) AS idx
    ) t;

    -- ====================== 生成平滑航点JSON数组 ======================
    -- 将简化路径（v_path_line）中的每个点转换为JSON对象
    SELECT jsonb_agg(jsonb_build_object('lon', ST_X(p), 'lat', ST_Y(p), 'alt', ST_Z(p)))
    INTO v_smooth_waypoints
    FROM (SELECT (ST_DumpPoints(v_path_line)).geom AS p) AS t;

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
    RAISE NOTICE '【调试】规划异常，拒绝直线兜底，触发原因：%（SQLSTATE=%）', SQLERRM, SQLSTATE;
    DROP TABLE IF EXISTS tmp_grid;
    code := 500;
    msg := format('执行异常：%s，已拒绝生成直线兜底航线，执行时间 %s 秒',
                  SQLERRM,
                  ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
    RETURN;
      -- 确保临时表被删除（如果存在）
    RAISE NOTICE '【调试】自动返回直线兜底航线，触发原因：%（SQLSTATE=%）', SQLERRM, SQLSTATE;
    DROP TABLE IF EXISTS tmp_grid;

    -- 异常兜底：生成符合直升直降规则的直线航线（与分支1完全相同）
    v_path_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    v_path_line := ST_AddPoint(v_path_line, v_start_pt);
    IF p_height_mode = 0 AND abs(p_start_alt - p_safe_altitude) > 0.001 THEN
        v_path_line := ST_AddPoint(v_path_line,
            ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326)
        );
    END IF;
    IF p_height_mode = 0 AND abs(p_end_alt - p_safe_altitude) > 0.001 THEN
        v_path_line := ST_AddPoint(v_path_line,
            ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
        );
    END IF;
    v_path_line := ST_AddPoint(v_path_line, v_end_pt);
    v_path_line := gis_linestring_remove_duplicate_points(v_path_line);
    v_final_path := v_path_line;

    SELECT jsonb_agg(
        jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom))
        ORDER BY (dp).path[1]
    )
    INTO v_waypoints
    FROM ST_DumpPoints(v_path_line) AS dp;
    v_smooth_waypoints := v_waypoints;

    -- 异常时也只返回兜底航线，不写入 gis_flight_paths。
    v_return_msg := format('执行异常：%s，已返回直线兜底航线，执行时间 %s 秒',
                           SQLERRM,
                           ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (500, v_return_msg, v_log_sql);
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
) IS '规划单段三维避障航线';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_astar_3d_flight_plan');
-- =============================================================================
-- 函数介绍：gis_astar_3d_flight_plan
-- 主要作用：对外提供单段航线规划接口，封装A*规划、结果组装和必要的业务参数转换。
-- 入参说明：传入起终点经纬高、安全高度、重算标记、项目ID、创建人和高度模式。
-- 返回说明：返回统一code/msg和航线结果，供业务系统直接发起单段自动规划。
-- 注意事项：5km内直接调用gis_astar_3d_flight，超过5km交给gis_flight_paths_plan分段处理。
-- =============================================================================
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
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_segment_m DOUBLE PRECISION;
    v_start_pt geometry(PointZ,4326);
    v_end_pt geometry(PointZ,4326);
    v_direct_line geometry(LineStringZ,4326);
    v_waypoints jsonb;
    v_path_id integer;
    v_return_msg text;
    v_calc record;
    v_log_sql      text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_astar_3d_flight_plan(%s, %s, %s, %s, %s, %s, %s, %s, %L, %L, %L);',
        COALESCE(p_start_lon::text, 'NULL'), COALESCE(p_start_lat::text, 'NULL'), COALESCE(p_start_alt::text, 'NULL'),
        COALESCE(p_end_lon::text, 'NULL'), COALESCE(p_end_lat::text, 'NULL'), COALESCE(p_end_alt::text, 'NULL'),
        COALESCE(p_safe_altitude::text, 'NULL'), COALESCE(p_height_mode::text, 'NULL'),
        p_force_gen, p_project_id, p_create_user);

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

    v_segment_m := SQRT(
        POWER((p_end_lon - p_start_lon) * 111000.0 * COS(RADIANS((p_start_lat + p_end_lat) / 2.0)), 2)
        + POWER((p_end_lat - p_start_lat) * 111000.0, 2)
    );

    IF v_segment_m <= 5000.0 THEN
        SELECT *
        INTO v_calc
        FROM gis_astar_3d_flight(
            p_start_lon, p_start_lat, p_start_alt,
            p_end_lon, p_end_lat, p_end_alt,
            p_safe_altitude, p_height_mode, p_force_gen,
            p_project_id, p_create_user
        )
        LIMIT 1;

        IF NOT FOUND THEN
            RETURN QUERY SELECT
                500,
                '规划失败：gis_astar_3d_flight 未返回任何结果',
                (NULL::gis_flight_paths).*;
            RETURN;
        END IF;

        IF v_calc.code IS DISTINCT FROM 200
           OR v_calc.id IS NOT NULL
           OR v_calc.path_line IS NULL
           OR v_calc.smooth_path_line IS NULL THEN
            RETURN QUERY SELECT
                v_calc.code, v_calc.msg,
                v_calc.id, v_calc.project_id, v_calc.create_user, v_calc.create_time,
                v_calc.update_user, v_calc.update_time, v_calc.del_flag,
                v_calc.start_point, v_calc.end_point, v_calc.safe_altitude,
                v_calc.path_line, v_calc.smooth_path_line,
                v_calc.waypoints, v_calc.smooth_waypoints,
                v_calc.total_distance, v_calc.smooth_ratio;
            RETURN;
        END IF;

        INSERT INTO gis_flight_paths (
            project_id, create_user, update_user,
            start_point, end_point, safe_altitude,
            path_line, smooth_path_line,
            waypoints, smooth_waypoints, total_distance, smooth_ratio
        ) VALUES (
            p_project_id, p_create_user, p_create_user,
            v_calc.start_point, v_calc.end_point, v_calc.safe_altitude,
            v_calc.path_line, v_calc.smooth_path_line,
            v_calc.waypoints, v_calc.smooth_waypoints,
            v_calc.total_distance, v_calc.smooth_ratio
        ) RETURNING gis_flight_paths.id INTO v_path_id;

        v_return_msg := format('规划成功：5km内单段航线已生成并保存，距离 %s 米', ROUND(v_segment_m::numeric, 2));
        RETURN QUERY
        SELECT 200, v_return_msg, p.*
        FROM gis_flight_paths p
        WHERE p.id = v_path_id;
        RETURN;
    END IF;

    v_start_pt := ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_start_alt), 4326);
    v_end_pt := ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_end_alt), 4326);

    IF gis_flight_point_in_fence(v_start_pt, p_project_id) THEN
        code := 400;
        msg := format('参数错误：起点在禁飞区或管控区内，start=(%s,%s,%s)，执行时间 %s 秒',
                      p_start_lon, p_start_lat, p_start_alt,
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF gis_flight_point_in_fence(v_end_pt, p_project_id) THEN
        code := 400;
        msg := format('参数错误：终点在禁飞区或管控区内，end=(%s,%s,%s)，执行时间 %s 秒',
                      p_end_lon, p_end_lat, p_end_alt,
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    v_direct_line := ST_MakeLine(v_start_pt, v_end_pt);

    -- 长距离但整条直线不经过禁飞区/管控区时，直接返回一条总航线，避免进入 5km 循环。
    IF NOT gis_flight_line_intersects_fence(v_direct_line, p_project_id) THEN
        v_direct_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
        v_direct_line := ST_AddPoint(v_direct_line, v_start_pt);
        IF p_height_mode = 0 AND abs(p_start_alt - p_safe_altitude) > 0.001 THEN
            v_direct_line := ST_AddPoint(v_direct_line,
                ST_SetSRID(ST_MakePoint(p_start_lon, p_start_lat, p_safe_altitude), 4326)
            );
        END IF;
        IF p_height_mode = 0 AND abs(p_end_alt - p_safe_altitude) > 0.001 THEN
            v_direct_line := ST_AddPoint(v_direct_line,
                ST_SetSRID(ST_MakePoint(p_end_lon, p_end_lat, p_safe_altitude), 4326)
            );
        END IF;
        v_direct_line := ST_AddPoint(v_direct_line, v_end_pt);
        v_direct_line := gis_linestring_remove_duplicate_points(v_direct_line);

        SELECT jsonb_agg(
            jsonb_build_object('lon', ST_X((dp).geom), 'lat', ST_Y((dp).geom), 'alt', ST_Z((dp).geom))
            ORDER BY (dp).path[1]
        )
        INTO v_waypoints
        FROM ST_DumpPoints(v_direct_line) AS dp;

        INSERT INTO gis_flight_paths (
            project_id, create_user, update_user,
            start_point, end_point, safe_altitude,
            path_line, smooth_path_line,
            waypoints, smooth_waypoints, total_distance, smooth_ratio
        ) VALUES (
            p_project_id, p_create_user, p_create_user,
            v_start_pt, v_end_pt, p_safe_altitude,
            v_direct_line, v_direct_line,
            v_waypoints, v_waypoints,
            gis_linestring_length_m(v_direct_line),
            p_height_mode
        ) RETURNING gis_flight_paths.id INTO v_path_id;

        v_return_msg := format('规划成功：长距离直线无围栏冲突，已快速生成直线航线，距离 %s 米', ROUND(v_segment_m::numeric, 2));
        RETURN QUERY SELECT 200, v_return_msg, p.* FROM gis_flight_paths p WHERE p.id = v_path_id;
        RETURN;
    END IF;

    -- 超过 5km 再走汇总函数：
    -- 沿直线按 5km 探测，安全段直接合并，遇禁飞区/管控区才调用 A*；最终只插入并返回一条总航线。
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
) IS '两点自动航线规划入口';

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_paths_plan');
-- =============================================================================
-- 函数介绍：gis_flight_paths_plan
-- 主要作用：对多个航点按顺序拆分成多段，逐段调用航线规划并汇总成完整航线。
-- 入参说明：p_points 支持对象数组或坐标数组；p_safe_altitude 为安全高度；p_force_gen 控制是否强制重算。
-- 返回说明：返回多段规划后的整体结果、分段结果、合并航点和总距离等信息。
-- 注意事项：适合多航点任务；任一分段失败时需结合返回code/msg判断是否继续使用结果。
-- =============================================================================
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
    v_input_idx INT;
    v_ratio1 DOUBLE PRECISION;
    v_ratio2 DOUBLE PRECISION;
    v_anchor_m DOUBLE PRECISION;
    v_probe_m DOUBLE PRECISION;
    v_last_safe_m DOUBLE PRECISION;
    v_exit_m DOUBLE PRECISION;
    v_anchor_point geometry(PointZ,4326);
    v_probe_point geometry(PointZ,4326);
    v_probe_line geometry(LineStringZ,4326);
    v_probe_point_blocked boolean;
    v_probe_line_blocked boolean;
    v_scan_m DOUBLE PRECISION;
    v_scan_limit_m DOUBLE PRECISION;
    v_seen_blocked boolean;

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
    v_direct_line geometry(LineStringZ,4326);

    v_start_pt geometry(PointZ,4326);
    v_end_pt geometry(PointZ,4326);
    v_merged_path_line geometry(LineStringZ,4326) := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    v_merged_smooth_line geometry(LineStringZ,4326) := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
    v_waypoints JSONB;
    v_smooth_waypoints JSONB;

    v_point_idx INT;
    v_point_count INT;
    v_append_start INT;
    v_bad_point_seq INT;
    v_bad_point_lon DOUBLE PRECISION;
    v_bad_point_lat DOUBLE PRECISION;
    v_bad_point_alt DOUBLE PRECISION;
    v_log_sql      text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_paths_plan(%L, %s, %L, %L, %L, %s);',
        p_points::text, COALESCE(p_safe_altitude::text, 'NULL'), p_force_gen, p_project_id, p_create_user, COALESCE(p_height_mode::text, 'NULL'));

    IF p_points IS NULL OR jsonb_typeof(p_points) <> 'array' THEN
        code := 400;
        msg := format('参数错误：p_points 必须是 JSONB 数组，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    IF p_safe_altitude IS NULL OR p_safe_altitude <= 0 THEN
        code := 400;
        msg := format('参数错误：安全高度必须大于0，执行时间 %s 秒',
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
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
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
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
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
        RETURN;
    END IF;

    SELECT seq, lon, lat, alt
    INTO v_bad_point_seq, v_bad_point_lon, v_bad_point_lat, v_bad_point_alt
    FROM tmp_flight_plan_input_points
    WHERE gis_flight_point_in_fence(
        ST_SetSRID(ST_MakePoint(lon, lat, alt), 4326),
        p_project_id
    )
    ORDER BY seq
    LIMIT 1;

    IF v_bad_point_seq IS NOT NULL THEN
        code := 400;
        msg := format('参数错误：规划点 seq=%s 在禁飞区或管控区内，point=(%s,%s,%s)，执行时间 %s 秒',
                      v_bad_point_seq, v_bad_point_lon, v_bad_point_lat, v_bad_point_alt,
                      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
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

    -- 相邻输入点逐段处理：沿直线按 5km 探测，安全段合并，遇障碍段才调用 A*。
    -- gis_astar_3d_flight 只负责计算障碍段并返回数据，不写入 gis_flight_paths。
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

        IF v_segment_m <= 0.001 THEN
            v_direct_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
            v_direct_line := ST_AddPoint(v_direct_line, ST_SetSRID(ST_MakePoint(v_lon1, v_lat1, v_alt1), 4326));
            IF p_height_mode = 0 AND abs(v_alt1 - p_safe_altitude) > 0.001 THEN
                v_direct_line := ST_AddPoint(v_direct_line,
                    ST_SetSRID(ST_MakePoint(v_lon1, v_lat1, p_safe_altitude), 4326)
                );
            END IF;
            IF p_height_mode = 0 AND abs(v_alt2 - p_safe_altitude) > 0.001 THEN
                v_direct_line := ST_AddPoint(v_direct_line,
                    ST_SetSRID(ST_MakePoint(v_lon2, v_lat2, p_safe_altitude), 4326)
                );
            END IF;
            v_direct_line := ST_AddPoint(v_direct_line, ST_SetSRID(ST_MakePoint(v_lon2, v_lat2, v_alt2), 4326));
            v_direct_line := gis_linestring_remove_duplicate_points(v_direct_line);

            v_point_count := ST_NumPoints(v_direct_line);
            v_append_start := CASE WHEN ST_NumPoints(v_merged_path_line) = 0 THEN 1 ELSE 2 END;
            FOR v_point_idx IN v_append_start..v_point_count LOOP
                v_merged_path_line := ST_AddPoint(v_merged_path_line, ST_PointN(v_direct_line, v_point_idx));
            END LOOP;

            v_point_count := ST_NumPoints(v_direct_line);
            v_append_start := CASE WHEN ST_NumPoints(v_merged_smooth_line) = 0 THEN 1 ELSE 2 END;
            FOR v_point_idx IN v_append_start..v_point_count LOOP
                v_merged_smooth_line := ST_AddPoint(v_merged_smooth_line, ST_PointN(v_direct_line, v_point_idx));
            END LOOP;

            v_part_count := v_part_count + 1;
            CONTINUE;
        END IF;

        v_anchor_m := 0;

        WHILE v_anchor_m < v_segment_m LOOP
            v_last_safe_m := v_anchor_m;

            LOOP
                v_probe_m := LEAST(v_last_safe_m + 5000.0, v_segment_m);
                v_ratio1 := CASE WHEN v_segment_m = 0 THEN 0 ELSE v_anchor_m / v_segment_m END;
                v_ratio2 := CASE WHEN v_segment_m = 0 THEN 1 ELSE v_probe_m / v_segment_m END;

                v_seg_start_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio1;
                v_seg_start_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio1;
                v_seg_start_alt := CASE WHEN v_anchor_m = 0 THEN v_alt1 ELSE p_safe_altitude END;

                v_seg_end_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio2;
                v_seg_end_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio2;
                v_seg_end_alt := CASE WHEN v_probe_m >= v_segment_m THEN v_alt2 ELSE p_safe_altitude END;

                v_anchor_point := ST_SetSRID(ST_MakePoint(v_seg_start_lon, v_seg_start_lat, v_seg_start_alt), 4326);
                v_probe_point := ST_SetSRID(ST_MakePoint(v_seg_end_lon, v_seg_end_lat, v_seg_end_alt), 4326);
                v_probe_line := ST_MakeLine(v_anchor_point, v_probe_point);

                v_probe_point_blocked := gis_flight_point_in_fence(v_probe_point, p_project_id);
                v_probe_line_blocked := gis_flight_line_intersects_fence(v_probe_line, p_project_id);

                IF NOT v_probe_point_blocked AND NOT v_probe_line_blocked THEN
                    v_last_safe_m := v_probe_m;

                    IF v_last_safe_m >= v_segment_m THEN
                        v_direct_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
                        v_direct_line := ST_AddPoint(v_direct_line, v_anchor_point);
                        IF p_height_mode = 0
                           AND v_anchor_m = 0
                           AND abs(v_seg_start_alt - p_safe_altitude) > 0.001 THEN
                            v_direct_line := ST_AddPoint(v_direct_line,
                                ST_SetSRID(ST_MakePoint(v_seg_start_lon, v_seg_start_lat, p_safe_altitude), 4326)
                            );
                        END IF;
                        IF p_height_mode = 0
                           AND v_probe_m >= v_segment_m
                           AND abs(v_seg_end_alt - p_safe_altitude) > 0.001 THEN
                            v_direct_line := ST_AddPoint(v_direct_line,
                                ST_SetSRID(ST_MakePoint(v_seg_end_lon, v_seg_end_lat, p_safe_altitude), 4326)
                            );
                        END IF;
                        v_direct_line := ST_AddPoint(v_direct_line, v_probe_point);
                        v_direct_line := gis_linestring_remove_duplicate_points(v_direct_line);

                        v_point_count := ST_NumPoints(v_direct_line);
                        v_append_start := CASE WHEN ST_NumPoints(v_merged_path_line) = 0 THEN 1 ELSE 2 END;
                        FOR v_point_idx IN v_append_start..v_point_count LOOP
                            v_merged_path_line := ST_AddPoint(v_merged_path_line, ST_PointN(v_direct_line, v_point_idx));
                        END LOOP;

                        v_point_count := ST_NumPoints(v_direct_line);
                        v_append_start := CASE WHEN ST_NumPoints(v_merged_smooth_line) = 0 THEN 1 ELSE 2 END;
                        FOR v_point_idx IN v_append_start..v_point_count LOOP
                            v_merged_smooth_line := ST_AddPoint(v_merged_smooth_line, ST_PointN(v_direct_line, v_point_idx));
                        END LOOP;

                        v_part_count := v_part_count + 1;
                        v_anchor_m := v_segment_m;
                        EXIT;
                    END IF;

                    CONTINUE;
                END IF;

                IF v_last_safe_m > v_anchor_m THEN
                    v_ratio2 := v_last_safe_m / v_segment_m;
                    v_seg_end_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio2;
                    v_seg_end_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio2;
                    v_seg_end_alt := p_safe_altitude;
                    v_probe_point := ST_SetSRID(ST_MakePoint(v_seg_end_lon, v_seg_end_lat, v_seg_end_alt), 4326);
                    v_direct_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
                    v_direct_line := ST_AddPoint(v_direct_line, v_anchor_point);
                    IF p_height_mode = 0
                       AND v_anchor_m = 0
                       AND abs(v_seg_start_alt - p_safe_altitude) > 0.001 THEN
                        v_direct_line := ST_AddPoint(v_direct_line,
                            ST_SetSRID(ST_MakePoint(v_seg_start_lon, v_seg_start_lat, p_safe_altitude), 4326)
                        );
                    END IF;
                    v_direct_line := ST_AddPoint(v_direct_line, v_probe_point);
                    v_direct_line := gis_linestring_remove_duplicate_points(v_direct_line);

                    v_point_count := ST_NumPoints(v_direct_line);
                    v_append_start := CASE WHEN ST_NumPoints(v_merged_path_line) = 0 THEN 1 ELSE 2 END;
                    FOR v_point_idx IN v_append_start..v_point_count LOOP
                        v_merged_path_line := ST_AddPoint(v_merged_path_line, ST_PointN(v_direct_line, v_point_idx));
                    END LOOP;

                    v_point_count := ST_NumPoints(v_direct_line);
                    v_append_start := CASE WHEN ST_NumPoints(v_merged_smooth_line) = 0 THEN 1 ELSE 2 END;
                    FOR v_point_idx IN v_append_start..v_point_count LOOP
                        v_merged_smooth_line := ST_AddPoint(v_merged_smooth_line, ST_PointN(v_direct_line, v_point_idx));
                    END LOOP;

                    v_part_count := v_part_count + 1;
                    v_anchor_m := v_last_safe_m;
                    EXIT;
                END IF;

                IF v_probe_point_blocked OR v_probe_line_blocked THEN
                    RAISE NOTICE '【分段探测】input_seq=%, 5km探测命中禁飞/管控，开始从1km递增探测，anchor_m=%, first_probe_m=%, point_blocked=%, line_blocked=%',
                        v_input_idx,
                        ROUND(v_anchor_m::numeric, 2),
                        ROUND(v_probe_m::numeric, 2),
                        v_probe_point_blocked,
                        v_probe_line_blocked;

                    v_seen_blocked := false;
                    v_exit_m := NULL;
                    v_scan_limit_m := LEAST(v_anchor_m + 30000.0, v_segment_m);
                    v_scan_m := LEAST(v_anchor_m + 1000.0, v_segment_m);

                    WHILE v_scan_m <= v_scan_limit_m LOOP
                        v_ratio2 := v_scan_m / v_segment_m;
                        v_seg_end_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio2;
                        v_seg_end_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio2;
                        v_seg_end_alt := CASE WHEN v_scan_m >= v_segment_m THEN v_alt2 ELSE p_safe_altitude END;
                        v_probe_point := ST_SetSRID(ST_MakePoint(v_seg_end_lon, v_seg_end_lat, v_seg_end_alt), 4326);
                        v_probe_line := ST_MakeLine(v_anchor_point, v_probe_point);

                        v_probe_point_blocked := gis_flight_point_in_fence(v_probe_point, p_project_id);
                        v_probe_line_blocked := gis_flight_line_intersects_fence(v_probe_line, p_project_id);

                        RAISE NOTICE '【分段探测】input_seq=%, anchor_m=%, scan_m=%, lon=%, lat=%, alt=%, point_blocked=%, line_blocked=%',
                            v_input_idx,
                            ROUND(v_anchor_m::numeric, 2),
                            ROUND(v_scan_m::numeric, 2),
                            v_seg_end_lon,
                            v_seg_end_lat,
                            v_seg_end_alt,
                            v_probe_point_blocked,
                            v_probe_line_blocked;

                        IF NOT v_seen_blocked AND NOT v_probe_point_blocked AND NOT v_probe_line_blocked THEN
                            v_last_safe_m := v_scan_m;
                        ELSE
                            v_seen_blocked := true;
                        END IF;

                        IF v_seen_blocked AND NOT v_probe_point_blocked THEN
                            v_exit_m := v_scan_m;
                            RAISE NOTICE '【分段探测】input_seq=%, 找到出口点 exit_m=%, last_safe_m=%',
                                v_input_idx,
                                ROUND(v_exit_m::numeric, 2),
                                ROUND(v_last_safe_m::numeric, 2);
                            EXIT;
                        END IF;

                        IF v_scan_m >= v_scan_limit_m THEN
                            EXIT;
                        END IF;
                        v_scan_m := LEAST(v_scan_m + 1000.0, v_segment_m);
                    END LOOP;

                    IF v_last_safe_m > v_anchor_m THEN
                        v_ratio2 := v_last_safe_m / v_segment_m;
                        v_seg_end_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio2;
                        v_seg_end_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio2;
                        v_seg_end_alt := p_safe_altitude;
                        v_probe_point := ST_SetSRID(ST_MakePoint(v_seg_end_lon, v_seg_end_lat, v_seg_end_alt), 4326);
                        v_direct_line := ST_SetSRID('LINESTRING Z EMPTY'::geometry, 4326);
                        v_direct_line := ST_AddPoint(v_direct_line, v_anchor_point);
                        v_direct_line := ST_AddPoint(v_direct_line, v_probe_point);
                        v_direct_line := gis_linestring_remove_duplicate_points(v_direct_line);

                        v_point_count := ST_NumPoints(v_direct_line);
                        v_append_start := CASE WHEN ST_NumPoints(v_merged_path_line) = 0 THEN 1 ELSE 2 END;
                        FOR v_point_idx IN v_append_start..v_point_count LOOP
                            v_merged_path_line := ST_AddPoint(v_merged_path_line, ST_PointN(v_direct_line, v_point_idx));
                        END LOOP;

                        v_point_count := ST_NumPoints(v_direct_line);
                        v_append_start := CASE WHEN ST_NumPoints(v_merged_smooth_line) = 0 THEN 1 ELSE 2 END;
                        FOR v_point_idx IN v_append_start..v_point_count LOOP
                            v_merged_smooth_line := ST_AddPoint(v_merged_smooth_line, ST_PointN(v_direct_line, v_point_idx));
                        END LOOP;

                        v_part_count := v_part_count + 1;
                        v_anchor_m := v_last_safe_m;
                        EXIT;
                    END IF;

                    IF v_exit_m IS NULL THEN
                        RAISE NOTICE '【分段探测】input_seq=%, 未找到出口点，anchor_m=%, scan_limit_m=%',
                            v_input_idx,
                            ROUND(v_anchor_m::numeric, 2),
                            ROUND(v_scan_limit_m::numeric, 2);
                        RAISE EXCEPTION '分段路径规划失败：input_seq=%, anchor_m=%, scan_limit_m=%，按1km探测至30km未找到禁飞/管控出口点',
                            v_input_idx,
                            ROUND(v_anchor_m::numeric, 2),
                            ROUND(v_scan_limit_m::numeric, 2);
                    END IF;

                    v_probe_m := v_exit_m;
                END IF;

                v_ratio1 := v_anchor_m / v_segment_m;
                v_ratio2 := v_probe_m / v_segment_m;

                v_seg_start_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio1;
                v_seg_start_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio1;
                v_seg_start_alt := CASE WHEN v_anchor_m = 0 THEN v_alt1 ELSE p_safe_altitude END;
                v_seg_end_lon := v_lon1 + (v_lon2 - v_lon1) * v_ratio2;
                v_seg_end_lat := v_lat1 + (v_lat2 - v_lat1) * v_ratio2;
                v_seg_end_alt := CASE WHEN v_probe_m >= v_segment_m THEN v_alt2 ELSE p_safe_altitude END;

                IF (v_probe_m - v_anchor_m) <= 5000.0 THEN
                    SELECT
                        r.id, r.project_id, r.create_user, r.create_time,
                        r.update_user, r.update_time, r.del_flag,
                        r.start_point, r.end_point, r.safe_altitude,
                        r.path_line, r.smooth_path_line,
                        r.waypoints, r.smooth_waypoints,
                        r.total_distance, r.smooth_ratio
                    INTO v_part
                    FROM gis_astar_3d_flight_plan(
                        v_seg_start_lon, v_seg_start_lat, v_seg_start_alt,
                        v_seg_end_lon, v_seg_end_lat, v_seg_end_alt,
                        p_safe_altitude,
                        p_height_mode,
                        TRUE,
                        p_project_id,
                        p_create_user
                    ) r
                    LIMIT 1;
                ELSE
                    -- 点落入较长围栏时，离开点可能超过 5km；这里直接调用核心函数，避免两点入口再次回到本函数形成递归。
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
                END IF;

                IF v_part.path_line IS NULL OR v_part.smooth_path_line IS NULL THEN
                    RAISE EXCEPTION '分段路径规划失败：input_seq=%, anchor_m=%, probe_m=%, segment_m=%',
                        v_input_idx,
                        ROUND(v_anchor_m::numeric, 2),
                        ROUND(v_probe_m::numeric, 2),
                        ROUND((v_probe_m - v_anchor_m)::numeric, 2);
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

                v_anchor_m := v_probe_m;
                EXIT;
            END LOOP;
        END LOOP;
    END LOOP;

    v_merged_path_line := gis_linestring_remove_duplicate_points(v_merged_path_line);
    v_merged_smooth_line := gis_linestring_remove_duplicate_points(v_merged_smooth_line);

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
    v_return_msg := format('规划成功：多点/长距离探测规划完成，共处理 %s 个航段，执行时间 %s 秒',
                           v_part_count,
                           ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RETURN QUERY SELECT 200, v_return_msg, p.* FROM gis_flight_paths p WHERE p.id = v_path_id;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := format('执行异常：%s，执行时间 %s 秒',
                  SQLERRM,
                  ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN QUERY SELECT code, msg, (NULL::gis_flight_paths).*;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION gis_flight_paths_plan(JSONB, DOUBLE PRECISION, BOOLEAN, VARCHAR, VARCHAR, DOUBLE PRECISION) IS '多点航线自动分段规划';


-- =============================================================================
-- 调用示例
-- =============================================================================
-- 统一说明：
--   1. 本区块只提供调用示例，默认全部注释，避免执行建函数脚本时写入测试航线。
--   2. p_height_mode = 0：直升直降。
--   3. 0 < p_height_mode < 1：按比例平滑爬升/下降。
--   4. p_force_gen = TRUE：强制重新规划，不复用 gis_flight_paths 历史航线。
--   5. p_project_id：项目ID，用于匹配项目网格表、项目围栏和历史航线。
--   6. path_line / waypoints：原始航线。
--   7. smooth_path_line / smooth_waypoints：平滑/简化后航线。
--   8. 连续重复点会被删除；同经纬度但高度不同的直升直降点会保留。
-- =============================================================================

-- =============================================================================
-- A. 辅助函数示例
-- =============================================================================

-- A1. 计算三维航线长度
-- SELECT gis_linestring_length_m(
--     ST_GeomFromText('LINESTRING Z (113.640409 34.744365 50, 113.657920 34.748111 120)', 4326)
-- );

-- A2. 判断航点是否落入禁飞/管控围栏
-- SELECT gis_flight_point_in_fence(
--     ST_SetSRID(ST_MakePoint(113.640409, 34.744365, 120), 4326),
--     'TEST001'
-- );

-- A3. 判断航线是否穿越禁飞/管控围栏
-- SELECT gis_flight_line_intersects_fence(
--     ST_GeomFromText('LINESTRING Z (113.640409 34.744365 50, 113.657920 34.748111 120)', 4326),
--     'TEST001'
-- );

-- A4. 删除连续重复点，保留同经纬度不同高度的垂直点
-- SELECT ST_AsText(gis_linestring_remove_duplicate_points(
--     ST_GeomFromText(
--         'LINESTRING Z (113.1 34.1 100, 113.1 34.1 100, 113.1 34.1 120, 113.2 34.2 120)',
--         4326
--     )
-- ));

-- =============================================================================
-- B. 单段核心函数 gis_astar_3d_flight
-- 说明：只计算并返回单段结果，不写入 gis_flight_paths；通常由入口函数调用。
-- =============================================================================

-- SELECT code, msg, waypoints, smooth_waypoints
-- FROM gis_astar_3d_flight(
--     113.48457, 34.814507, 100.0,
--     113.48575564234284, 34.81534315486885, 120.0,
--     120.0, 0, TRUE,
--     '2c95908e958f3b75019593551f520126', 'user_123'
-- );

-- =============================================================================
-- C. 单段入口函数 gis_astar_3d_flight_plan
-- 说明：5km内调用核心函数并入库；超过5km会转入 gis_flight_paths_plan。
-- =============================================================================

-- C1. 起点高度 != 安全高度，终点高度 = 安全高度
-- 预期点形态：起点真实高度 -> 起点安全高度 -> 终点
-- SELECT code, msg, id, waypoints, smooth_waypoints
-- FROM gis_astar_3d_flight_plan(
--     113.48457::double precision, 34.814507::double precision, 100.0::double precision,
--     113.48575564234284::double precision, 34.81534315486885::double precision, 120.0::double precision,
--     120.0::double precision, 0::double precision, TRUE::boolean,
--     '2c95908e958f3b75019593551f520126'::varchar, 'user_123'::varchar
-- );

-- C2. 起点高度 = 安全高度，终点高度 != 安全高度
-- 预期点形态：起点 -> 终点安全高度 -> 终点真实高度
-- SELECT code, msg, id, waypoints, smooth_waypoints
-- FROM gis_astar_3d_flight_plan(
--     113.48457, 34.814507, 120.0,
--     113.48575564234284, 34.81534315486885, 80.0,
--     120.0, 0, TRUE,
--     '2c95908e958f3b75019593551f520126', 'user_123'
-- );

-- C3. 起点高度 != 安全高度，终点高度 != 安全高度
-- 预期点形态：起点真实高度 -> 起点安全高度 -> 终点安全高度 -> 终点真实高度
-- SELECT code, msg, id, waypoints, smooth_waypoints
-- FROM gis_astar_3d_flight_plan(
--     113.48457, 34.814507, 100.0,
--     113.48575564234284, 34.81534315486885, 80.0,
--     120.0, 0, TRUE,
--     '2c95908e958f3b75019593551f520126', 'user_123'
-- );

-- C4. 起点高度 = 安全高度，终点高度 = 安全高度
-- 若直线无围栏冲突，预期可简化为：起点 -> 终点
-- SELECT code, msg, id, waypoints, smooth_waypoints
-- FROM gis_astar_3d_flight_plan(
--     113.48457, 34.814507, 120.0,
--     113.48575564234284, 34.81534315486885, 120.0,
--     120.0, 0, TRUE,
--     '2c95908e958f3b75019593551f520126', 'user_123'
-- );

-- C5. 平滑爬升/下降模式示例
-- SELECT code, msg, id, waypoints, smooth_waypoints
-- FROM gis_astar_3d_flight_plan(
--     113.48457, 34.814507, 80.0,
--     113.48575564234284, 34.81534315486885, 130.0,
--     120.0, 0.3, TRUE,
--     '2c95908e958f3b75019593551f520126', 'user_123'
-- );

-- =============================================================================
-- D. 多点入口函数 gis_flight_paths_plan
-- 说明：按输入点顺序逐段规划，最终只插入并返回一条总航线。
-- =============================================================================

-- D1. 常规多点航线
-- SELECT code, msg, id, total_distance, waypoints, smooth_waypoints
-- FROM gis_flight_paths_plan(
--     jsonb_build_array(
--         jsonb_build_object('lon', 113.48457, 'lat', 34.814507, 'alt', 100.0),
--         jsonb_build_object('lon', 113.48575564234284, 'lat', 34.81534315486885, 'alt', 120.0),
--         jsonb_build_object('lon', 113.4901, 'lat', 34.8172, 'alt', 80.0)
--     ),
--     120.0, TRUE, '2c95908e958f3b75019593551f520126', 'user_123', 0
-- );

-- D2. 多点零距离垂直段
-- 相邻输入点经纬度相同但高度不同，用于验证垂直段不会丢失。
-- SELECT code, msg, id, waypoints, smooth_waypoints
-- FROM gis_flight_paths_plan(
--     jsonb_build_array(
--         jsonb_build_object('lon', 113.48457, 'lat', 34.814507, 'alt', 80.0),
--         jsonb_build_object('lon', 113.48457, 'lat', 34.814507, 'alt', 120.0),
--         jsonb_build_object('lon', 113.48575564234284, 'lat', 34.81534315486885, 'alt', 120.0)
--     ),
--     120.0, TRUE, '2c95908e958f3b75019593551f520126', 'user_123', 0
-- );

-- D3. 数组坐标格式输入
-- p_points 也支持 [[lon, lat, alt], ...] 格式。
-- SELECT code, msg, id, total_distance, waypoints, smooth_waypoints
-- FROM gis_flight_paths_plan(
--     jsonb_build_array(
--         jsonb_build_array(113.48457, 34.814507, 100.0),
--         jsonb_build_array(113.48575564234284, 34.81534315486885, 120.0),
--         jsonb_build_array(113.4901, 34.8172, 80.0)
--     ),
--     120.0, TRUE, '2c95908e958f3b75019593551f520126', 'user_123', 0
-- );

-- D4. 长距离多点航线
-- 相邻点超过5km时会按5km探测；安全段直接合并，遇围栏/障碍段调用A*。
-- SELECT code, msg, id, total_distance, waypoints, smooth_waypoints
-- FROM gis_flight_paths_plan(
--     jsonb_build_array(
--         jsonb_build_object('lon', 113.48457, 'lat', 34.814507, 'alt', 100.0),
--         jsonb_build_object('lon', 113.56000, 'lat', 34.850000, 'alt', 120.0),
--         jsonb_build_object('lon', 113.62000, 'lat', 34.900000, 'alt', 100.0)
--     ),
--     120.0, TRUE, '2c95908e958f3b75019593551f520126', 'user_123', 0
-- );

-- =============================================================================
-- E. 结果检查示例
-- =============================================================================

-- E1. 查看返回/入库航线的 path_line 与 smooth_path_line 点序
-- 将 WHERE p.id = 1 替换为实际返回的航线ID。
-- SELECT
--     p.id,
--     'path_line' AS line_type,
--     (dp).path[1] AS seq,
--     ST_X((dp).geom) AS lon,
--     ST_Y((dp).geom) AS lat,
--     ST_Z((dp).geom) AS alt
-- FROM gis_flight_paths p
-- CROSS JOIN LATERAL ST_DumpPoints(p.path_line) AS dp
-- WHERE p.id = 1
-- UNION ALL
-- SELECT
--     p.id,
--     'smooth_path_line' AS line_type,
--     (dp).path[1] AS seq,
--     ST_X((dp).geom) AS lon,
--     ST_Y((dp).geom) AS lat,
--     ST_Z((dp).geom) AS alt
-- FROM gis_flight_paths p
-- CROSS JOIN LATERAL ST_DumpPoints(p.smooth_path_line) AS dp
-- WHERE p.id = 1
-- ORDER BY line_type, seq;

-- E2. 查看JSON航点
-- SELECT id, waypoints, smooth_waypoints
-- FROM gis_flight_paths
-- WHERE id = 1;

