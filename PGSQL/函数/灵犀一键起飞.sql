-- =============================================================================
-- 函数：public.gis_uav_one_key_takeoff_check
-- 功能：批量检测计划航线之间、计划航线与在飞航线之间的三维空间冲突。
-- 依赖及加载顺序：
--   1. PostGIS >= 3.2（使用ST_DumpSegments；需要PROJ支持）。
--   2. 函数/baseFunction/gis_geojson_to_geom.sql。
--   3. 项目产品共用函数/1灵犀聊城通用.sql中的gis_uav_flight_deviation_line。
--   公共函数的安装依赖见各自文件；本文件只创建业务函数，不读取或修改任务表。
--
-- 入参：
--   p_plan_routes      jsonb；必填；计划起飞航线数组，空集合传[]，不能为NULL。
--   p_realtime_routes  jsonb；选填；在飞航线数组，默认[]，不能为NULL。
--   p_buffer_radius    double precision；选填；三维安全间距R（米），默认0。
--                      两条航线的中心线最短距离<=R（含边界）判为冲突。
-- 每条计划航线为以下JSON对象：
--   hangar_id       必填；非空字符串或数字；机库ID，结果保留输入的JSON类型。
--   uav_location    必填；GeoJSON PointZ（或Feature），XY为WGS84经纬度，Z为机库所在地面海拔。
--   ground_height   必填；机库相对地面高度（米），地面机库传0。
--   safe_height     必填；相对机库的安全起飞高度（米）。
--   return_height   选填；相对机库的返航高度（米）；省略时采用safe_height。
--   flight_mode     选填；1垂直爬升，2倾斜爬升；省略时为1。
--   route           必填；GeoJSON LineStringZ或按顺序首尾衔接的MultiLineStringZ（也支持Feature）；
--                   原规划航点Z为距地高度（米），与gis_uav_flight_deviation_line入参约定一致。
-- 每条在飞航线支持两种格式：
--   A. 与计划航线同格式：带uav_location等起降参数，调用公共函数生成完整海拔航线。
--   B. 仅有hangar_id和route：route已是海拔高度的在飞/剩余航线，不再补起降段或换算高度；
--      可为不连续的MultiLineStringZ，严格保留各段，不在断开的航段间补线。
--      两种格式以是否提供非null的uav_location区分，不能把距地航线当作格式B传入。
--
-- 返回：jsonb，始终含两个数组（无冲突为[]）：
--   plan_plan_conflicts      计划与计划；按输入顺序只比较i<j，不返回自身及反向重复对。
--   plan_realtime_conflicts  计划与在飞；逐一比较，同机库ID也参与检查。
-- 每条冲突：
--   plan_hangar_id、plan_route         计划机库ID及原来计划航线（保留原始GeoJSON）。
--   conflict_hangar_id、conflict_route 相交机库ID及原来相交航线（保留原始GeoJSON）。
--   intersection_points               冲突航段对的代表点数组，按点对去重；每项包括：
--     plan_point、conflict_point        双方航段的最近点，GeoJSON PointZ，Z统一为海拔米。
--     distance_m                        两点的三维距离（米）。
--   真正相交时两点重合；仅缓冲区相交时保留双方最近点，不虚构中心线交点。
--   连续重叠航段有无限交点，每个命中的航段对返回一组代表点，不枚举重叠区全部点。
--
-- 计算约定：
--   1. 两类带起降参数的航线均调用gis_uav_flight_deviation_line(..., true, flight_mode)，
--      起飞、规划、返航及降落段均参与检查；沿用公共函数忽略航点间地形高差的约定。
--   2. 所有航线投影到以第一条计划的机库为中心的局部AEQD米制坐标系，Z保持海拔米；
--      适用于同一作业区域的局部航线，属于投影下直线航段的距离计算。
--   3. 只判断空间冲突，不判断飞行时间是否重叠；调用方负责筛选在飞/剩余航线。
--   4. 参数或任一航线无效时抛出22023异常，消息包含集合类型及从1开始的下标。
--   5. 为消除投影和三维运算的浮点残差，小于0.0000001米的距离视为0；
--      R小于该值时按此数值容差筛选，防止R=0漏报实际交点。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_uav_one_key_takeoff_check(
    p_plan_routes jsonb,
    p_realtime_routes jsonb DEFAULT '[]'::jsonb,
    p_buffer_radius double precision DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_item record;
    v_data jsonb;
    v_inputs jsonb[] := ARRAY[]::jsonb[];
    v_routes geometry[] := ARRAY[]::geometry[];
    v_route geometry;
    v_location geometry;
    v_center geometry;
    v_projection text;
    v_plan_count integer;
    v_limit double precision;
    v_result jsonb;
BEGIN
    IF jsonb_typeof(p_plan_routes) IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_realtime_routes) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '计划航线和在飞航线集合必须为JSON数组，空集合请传[]';
    END IF;
    -- 避免NaN、Infinity；NULL不能悄悄导致所有冲突漏报。
    IF p_buffer_radius IS NULL OR p_buffer_radius < 0
       OR p_buffer_radius::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '缓冲半径必须为非负有限值（米）';
    END IF;
    v_limit := greatest(p_buffer_radius, 0.0000001::double precision);
    v_plan_count := jsonb_array_length(p_plan_routes);

    -- 一、按计划、在飞的顺序解析一次，原始对象和计算几何分别保存。
    FOR v_item IN
        SELECT '计划' AS kind, p.ord, p.data, 1 AS group_order
        FROM jsonb_array_elements(p_plan_routes) WITH ORDINALITY AS p(data, ord)
        UNION ALL
        SELECT '在飞', r.ord, r.data, 2
        FROM jsonb_array_elements(p_realtime_routes) WITH ORDINALITY AS r(data, ord)
        ORDER BY group_order, ord
    LOOP
        BEGIN
            v_data := v_item.data;
            IF jsonb_typeof(v_data) IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION '航线项必须为JSON对象';
            END IF;
            IF COALESCE(jsonb_typeof(v_data->'hangar_id'), 'null') NOT IN ('string', 'number')
               OR btrim(v_data->>'hangar_id') = '' THEN
                RAISE EXCEPTION 'hangar_id必须为非空字符串或数字';
            END IF;
            IF jsonb_typeof(v_data->'route') IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION 'route必须为GeoJSON三维航线对象';
            END IF;
            v_route := public.gis_geojson_to_geom((v_data->'route')::text);

            IF v_item.kind = '计划' OR ((v_data->'uav_location') IS NOT NULL
               AND v_data->'uav_location' <> 'null'::jsonb) THEN
                -- 显式null不采用默认值，交由公共函数报错；仅字段省略时使用默认配置。
                v_location := public.gis_geojson_to_geom((v_data->'uav_location')::text);
                v_route := public.gis_uav_flight_deviation_line(
                    v_location,
                    (v_data->>'ground_height')::double precision,
                    (v_data->>'safe_height')::double precision,
                    CASE WHEN v_data ? 'return_height' THEN (v_data->>'return_height')::double precision
                         ELSE (v_data->>'safe_height')::double precision END,
                    v_route,
                    true,
                    CASE WHEN v_data ? 'flight_mode' THEN (v_data->>'flight_mode')::integer ELSE 1 END
                );
                IF v_item.kind = '计划' AND v_center IS NULL THEN
                    v_center := v_location;
                END IF;
            ELSE
                -- 在飞格式B已有统一的海拔基准；禁止用Force3DZ把缺失Z静默补成0。
                IF v_route IS NULL OR ST_IsEmpty(v_route)
                   OR GeometryType(v_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
                   OR NOT ST_IsValid(v_route) OR ST_SRID(v_route) NOT IN (0, 4326) THEN
                    RAISE EXCEPTION '在飞route必须为WGS84有效非空三维LineString或MultiLineString';
                END IF;
                IF EXISTS (
                    SELECT 1 FROM ST_DumpPoints(v_route) d
                    WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
                       OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)
                       OR ST_Z(d.geom) IS NULL
                       OR ST_Z(d.geom)::text IN ('NaN', 'Infinity', '-Infinity')
                ) OR EXISTS (SELECT 1 FROM ST_Dump(v_route) d WHERE ST_IsEmpty(d.geom)) THEN
                    RAISE EXCEPTION '在飞航点须有有效经纬度和有限海拔Z，且不能包含空航段';
                END IF;
                v_route := ST_SetSRID(v_route, 4326);
            END IF;
            v_inputs := array_append(v_inputs, v_data);
            v_routes := array_append(v_routes, v_route);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION USING ERRCODE = '22023',
                MESSAGE = format('%s航线集合第%s项：%s', v_item.kind, v_item.ord, SQLERRM);
        END;
    END LOOP;

    IF v_plan_count = 0 THEN
        RETURN jsonb_build_object('plan_plan_conflicts', '[]'::jsonb, 'plan_realtime_conflicts', '[]'::jsonb);
    END IF;
    v_projection := format(
        '+proj=aeqd +lat_0=%s +lon_0=%s +datum=WGS84 +units=m +no_defs',
        ST_Y(v_center), ST_X(v_center)
    );

    -- 二、每条完整航线只投影一次；先筛选冲突航线对，再逐航段提取全部命中对的代表点。
    WITH routes AS MATERIALIZED (
        SELECT r.ord, v_inputs[r.ord::integer] AS original,
               ST_Transform(r.geom, v_projection) AS geom
        FROM unnest(v_routes) WITH ORDINALITY AS r(geom, ord)
    ), pairs AS MATERIALIZED (
        SELECT a.ord AS plan_ord, b.ord AS conflict_ord,
               CASE WHEN b.ord <= v_plan_count THEN 'plan_plan_conflicts'
                    ELSE 'plan_realtime_conflicts' END AS kind,
               a.original AS plan_input, b.original AS conflict_input
        FROM routes a JOIN routes b ON a.ord < b.ord
        WHERE a.ord <= v_plan_count AND ST_3DDWithin(a.geom, b.geom, v_limit)
    ), segments AS MATERIALIZED (
        SELECT r.ord, d.geom
        FROM routes r CROSS JOIN LATERAL ST_DumpSegments(r.geom) d
        WHERE EXISTS (SELECT 1 FROM pairs p WHERE r.ord IN (p.plan_ord, p.conflict_ord))
    ), conflicts AS (
        SELECT p.plan_ord, p.conflict_ord, p.kind,
               jsonb_build_object(
                   'plan_hangar_id', p.plan_input->'hangar_id',
                   'plan_route', p.plan_input->'route',
                   'conflict_hangar_id', p.conflict_input->'hangar_id',
                   'conflict_route', p.conflict_input->'route',
                   'intersection_points', points.items
               ) AS item
        FROM pairs p CROSS JOIN LATERAL (
            SELECT jsonb_agg(q.point_pair ORDER BY q.point_pair) AS items
            FROM (
                SELECT DISTINCT jsonb_build_object(
                    'plan_point', ST_AsGeoJSON(ST_Transform(ST_StartPoint(s.line), v_projection, 4326), 9, 0)::jsonb,
                    'conflict_point', ST_AsGeoJSON(ST_Transform(ST_EndPoint(s.line), v_projection, 4326), 9, 0)::jsonb,
                    'distance_m', CASE WHEN ST_3DLength(s.line) <= 0.0000001 THEN 0::double precision
                                       ELSE ST_3DLength(s.line) END
                ) AS point_pair
                FROM segments a JOIN segments b
                    ON a.ord = p.plan_ord AND b.ord = p.conflict_ord
                   AND ST_3DDWithin(a.geom, b.geom, v_limit)
                CROSS JOIN LATERAL (SELECT ST_3DShortestLine(a.geom, b.geom) AS line) s
            ) q
        ) points
    )
    SELECT jsonb_build_object(
        'plan_plan_conflicts', COALESCE(
            jsonb_agg(c.item ORDER BY c.plan_ord, c.conflict_ord) FILTER (WHERE c.kind = 'plan_plan_conflicts'), '[]'::jsonb),
        'plan_realtime_conflicts', COALESCE(
            jsonb_agg(c.item ORDER BY c.plan_ord, c.conflict_ord) FILTER (WHERE c.kind = 'plan_realtime_conflicts'), '[]'::jsonb)
    ) INTO v_result FROM conflicts c;
    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.gis_uav_one_key_takeoff_check(jsonb, jsonb, double precision)
IS '一键起飞三维航线冲突检查：调用公共函数补齐起降航线，以中心线三维距离<=R比较计划与计划、计划与在飞，返回原航线及冲突代表点对';

-- =============================================================================
-- 调用示例：计划机库A/B的规划段交叉，并与在飞机库C的海拔航线交叉。
-- 计划原航点为距地100米，机库所在地面海拔50米，换算后规划段海拔150米。
-- 缓冲半径R=5米，中心线距离<=5米属于冲突；R=0只检查中心线相交。
-- 示例不自动执行；复制取消注释后调用。
-- =============================================================================
-- SELECT jsonb_pretty(public.gis_uav_one_key_takeoff_check(
--     '[
--       {
--         "hangar_id": "A",
--         "uav_location": {"type":"Point","coordinates":[116.00,36.00,50]},
--         "ground_height": 0,
--         "safe_height": 60,
--         "return_height": 80,
--         "flight_mode": 1,
--         "route": {"type":"LineString","coordinates":[[116.00,36.00,100],[116.02,36.00,100]]}
--       },
--       {
--         "hangar_id": "B",
--         "uav_location": {"type":"Point","coordinates":[116.01,35.99,50]},
--         "ground_height": 0,
--         "safe_height": 60,
--         "return_height": 80,
--         "flight_mode": 2,
--         "route": {"type":"LineString","coordinates":[[116.01,35.99,100],[116.01,36.01,100]]}
--       }
--     ]'::jsonb,
--     '[
--       {
--         "hangar_id": "C",
--         "route": {"type":"LineString","coordinates":[[116.015,35.99,150],[116.015,36.01,150]]}
--       }
--     ]'::jsonb,
--     5
-- ));
--
-- 空集合：返回{"plan_plan_conflicts":[],"plan_realtime_conflicts":[]}。
-- SELECT public.gis_uav_one_key_takeoff_check('[]'::jsonb);
-- 只有计划：在飞集合省略；返航高度、航飞模式也可在各计划对象中省略。
-- SELECT public.gis_uav_one_key_takeoff_check(:plan_routes::jsonb);
-- 单独读取两个结果集合：
-- SELECT result->'plan_plan_conflicts' AS plan_plan_conflicts,
--        result->'plan_realtime_conflicts' AS plan_realtime_conflicts
-- FROM (SELECT public.gis_uav_one_key_takeoff_check(:plan_routes::jsonb, :realtime_routes::jsonb, :radius) AS result) t;
