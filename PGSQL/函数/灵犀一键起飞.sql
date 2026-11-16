-- =============================================================================
-- 灵犀一键起飞.sql
-- 灵犀一键起飞航线冲突校验规则说明
--
-- 脚本用途：提供计划航线与计划航线、计划航线与在飞航线的三维空间冲突校验，
--           返回校验状态、冲突数量、机库ID及双方原始航线和冲突代表点。
-- 通用约定：
--   1. 输入航线使用WGS84经纬度（SRID=4326），高度和安全间距单位为米。
--   2. 计划航线的原始航点Z为相对地面高度；计算航线统一转换为海拔高度。
--   3. 安全间距R为两条航线中心线允许的最大三维距离，距离<=R（含边界）判为冲突。
--   4. code表示执行状态：200=校验完成，400=参数或航线数据错误，500=执行异常。
--   5. ischeck=true表示未发现冲突；发现冲突、参数错误或执行异常时为false。
--   6. 本函数只判断空间冲突，不判断飞行时间是否重叠；在飞/剩余航线由调用方传入。
--
--   （1）计划航线与计划航线冲突
--   函数：public.gis_uav_flight_takeoff_check
--   规则：按输入顺序只比较i<j，不比较自身，不返回反向重复对。
--   返回：plan_conflicts数组。
--
--   （2）计划航线与在飞航线冲突
--   函数：public.gis_uav_flight_takeoff_check
--   规则：每条计划航线逐一比较每条在飞航线，同机库ID也参与检查。
--   返回：realtime_conflicts数组。
--
-- 依赖说明：
--   1. PostGIS >= 3.2，使用ST_DumpSegments、ST_3DDWithin、ST_3DShortestLine和PROJ投影。
--   2. 函数/baseFunction/gis_drop_function.sql：删除同名函数及全部重载。
--   3. 函数/baseFunction/gis_geojson_to_geom.sql：解析GeoJSON为geometry。
--   4. 项目产品共用函数/1灵犀聊城通用.sql：
--      public.gis_uav_flight_deviation_line，构造完整三维起降航线。
--   5. 本函数不读取或修改任务表，所有计划和在飞航线通过JSON数组传入。
-- =============================================================================

-- =============================================================================
-- 函数说明
-- =============================================================================
-- 函数名称：gis_uav_flight_takeoff_check
-- 函数功能：批量检测计划航线之间、计划航线与在飞航线之间的三维空间冲突。
-- 函数描述：
--   1. 校验两个航线集合和安全间距R。
--   2. 将计划航线及带机库参数的在飞航线补齐为完整起飞、规划、返航和降落航线。
--   3. 将所有计算航线转换到同一局部米制坐标系，保留Z为海拔米。
--   4. 先按整条航线筛选三维距离<=R的航线对，再逐航段提取冲突代表点。
--   5. 返回计划与计划、计划与在飞两个冲突集合。
-- 入参说明：
--   p_plan_routes      jsonb；必填；计划航线数组，空集合传[]，不能为NULL。
--   p_realtime_routes  jsonb；选填；在飞航线数组，默认[]，不能为NULL。
--   p_buffer_radius    double precision；选填；三维安全间距R，单位米，默认0。
-- 计划航线项字段：
--   hangar_id          必填；非空字符串或数字；机库ID。
--   uav_location       必填；GeoJSON PointZ或Feature，Z为机库所在地面海拔。
--   ground_height     必填；机库相对地面高度，单位米，地面机库传0。
--   safe_height       必填；相对机库的安全起飞高度，单位米。
--   return_height     选填；相对机库的返航高度，省略时采用safe_height。
--   flight_mode       选填；1=垂直爬升，2=倾斜爬升，省略时为1。
--   route              必填；GeoJSON LineStringZ或首尾三维衔接的MultiLineStringZ，原Z为距地高度。
-- 在飞航线项字段：
--   A、带uav_location等参数：按计划航线方式调用gis_uav_flight_deviation_line生成完整海拔航线。
--   B、仅有hangar_id和route：route必须已经是海拔航线，直接作为在飞或剩余航线使用。
-- 返回说明：
--   code               integer；200=校验完成，400=参数或航线数据错误，500=执行异常。
--   msg                text；校验结果或错误原因；发现冲突时包含冲突数量和参与冲突的机库ID。
--   ischeck            boolean；true=未发现冲突，false=发现冲突或校验失败。
--   plan_conflicts     jsonb数组；计划与计划冲突，每条只返回一次。
--   realtime_conflicts jsonb数组；计划与在飞冲突。
-- 每条冲突记录：
--   plan_hangar_id、conflict_hangar_id     双方机库ID。
--   plan_route、conflict_route             双方原始GeoJSON航线，不返回补齐后的计算航线。
--   intersection_points                    冲突航段对的代表点数组。
--   plan_point、conflict_point             双方航段最近点，GeoJSON PointZ，Z为海拔米。
--   distance_m                             双方最近点的三维距离，单位米。
-- 异常说明：
--   1. 参数或航线数据错误直接返回code=400，不向调用方抛出内部校验异常。
--   2. 未预期的数据库或空间计算错误返回code=500。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
-- 删除旧入口和同名重载，避免数据库中残留旧定义。
SELECT public.gis_drop_function('public.gis_uav_one_key_takeoff_check');
SELECT public.gis_drop_function('public.gis_uav_flight_takeoff_check');

-- =============================================================================
-- 函数介绍：gis_uav_flight_takeoff_check
-- 主要作用：统一计划、在飞航线的高度基准并检测三维空间冲突。
-- 处理步骤：
--   1. 校验输入集合为JSON数组，校验R为非负有限值。
--   2. 解析每条航线，保留原始JSON；计划项和带机库参数的在飞项调用完整航线函数。
--   3. 以第一条计划机库为中心建立局部AEQD投影，XY转换为米，Z保持海拔米。
--   4. 计划集合为空时直接返回code=200、ischeck=true和两个空数组。
--   5. 计划与计划只比较i<j；计划与在飞逐一比较。
--   6. 用ST_3DDWithin按R筛选航线对，再用ST_DumpSegments拆分命中的航线。
--   7. 用ST_3DShortestLine取得双方最近点，点坐标转回WGS84后按点对去重。
--   8. 根据冲突数组统计数量，组装msg中的冲突类型数量和机库ID。
-- 高度约定：
--   1. gis_uav_flight_deviation_line(..., true, flight_mode)返回海拔基准的完整航线。
--   2. 机库起飞、规划、返航和降落段均参与冲突判断。
--   3. 不查询DEM，沿用完整航线函数忽略航点与机库间地形高差的约定。
--   4. 为消除投影浮点残差，小于0.0000001米的距离按0处理；R小于该值时按该容差筛选。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_uav_flight_takeoff_check(
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
    v_plan_conflict_count integer := 0;
    v_realtime_conflict_count integer := 0;
    v_conflict_hangar_ids text;
    v_msg text;
BEGIN
    IF jsonb_typeof(p_plan_routes) IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_realtime_routes) IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object(
            'code', 400,
            'msg', '计划航线和在飞航线集合必须为JSON数组，空集合请传[]',
            'ischeck', false,
            'plan_conflicts', '[]'::jsonb,
            'realtime_conflicts', '[]'::jsonb
        );
    END IF;
    -- 避免NaN、Infinity；NULL不能悄悄导致所有冲突漏报。
    IF p_buffer_radius IS NULL OR p_buffer_radius < 0
       OR p_buffer_radius::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RETURN jsonb_build_object(
            'code', 400,
            'msg', '缓冲半径必须为非负有限值（米）',
            'ischeck', false,
            'plan_conflicts', '[]'::jsonb,
            'realtime_conflicts', '[]'::jsonb
        );
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
            RETURN jsonb_build_object(
                'code', 400,
                'msg', format('%s航线集合第%s项：%s', v_item.kind, v_item.ord, SQLERRM),
                'ischeck', false,
                'plan_conflicts', '[]'::jsonb,
                'realtime_conflicts', '[]'::jsonb
            );
        END;
    END LOOP;

    IF v_plan_count = 0 THEN
        RETURN jsonb_build_object(
            'code', 200,
            'msg', '校验完成：未发现冲突',
            'ischeck', true,
            'plan_conflicts', '[]'::jsonb,
            'realtime_conflicts', '[]'::jsonb
        );
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
               CASE WHEN b.ord <= v_plan_count THEN 'plan_conflicts'
                    ELSE 'realtime_conflicts' END AS kind,
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
        'plan_conflicts', COALESCE(
            jsonb_agg(c.item ORDER BY c.plan_ord, c.conflict_ord) FILTER (WHERE c.kind = 'plan_conflicts'), '[]'::jsonb),
        'realtime_conflicts', COALESCE(
            jsonb_agg(c.item ORDER BY c.plan_ord, c.conflict_ord) FILTER (WHERE c.kind = 'realtime_conflicts'), '[]'::jsonb)
    ) INTO v_result FROM conflicts c;
    v_plan_conflict_count := jsonb_array_length(v_result->'plan_conflicts');
    v_realtime_conflict_count := jsonb_array_length(v_result->'realtime_conflicts');

    IF v_plan_conflict_count + v_realtime_conflict_count = 0 THEN
        v_msg := '校验完成：未发现冲突';
        RETURN jsonb_build_object('code', 200, 'msg', v_msg, 'ischeck', true) || v_result;
    END IF;

    SELECT string_agg(hangar_id, ', ' ORDER BY hangar_id)
    INTO v_conflict_hangar_ids
    FROM (
        SELECT DISTINCT item->>'plan_hangar_id' AS hangar_id
        FROM jsonb_array_elements((v_result->'plan_conflicts') || (v_result->'realtime_conflicts')) AS e(item)
        UNION
        SELECT DISTINCT item->>'conflict_hangar_id' AS hangar_id
        FROM jsonb_array_elements((v_result->'plan_conflicts') || (v_result->'realtime_conflicts')) AS e(item)
    ) ids
    WHERE hangar_id IS NOT NULL AND hangar_id <> '';

    v_msg := format(
        '校验完成：发现%s条冲突（计划与计划%s条，计划与在飞%s条），机库ID：%s',
        v_plan_conflict_count + v_realtime_conflict_count,
        v_plan_conflict_count,
        v_realtime_conflict_count,
        COALESCE(v_conflict_hangar_ids, '未提供')
    );
    RETURN jsonb_build_object('code', 200, 'msg', v_msg, 'ischeck', false) || v_result;
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'code', 500,
            'msg', format('执行异常：%s', SQLERRM),
            'ischeck', false,
            'plan_conflicts', '[]'::jsonb,
            'realtime_conflicts', '[]'::jsonb
        );
END;
$$;

COMMENT ON FUNCTION public.gis_uav_flight_takeoff_check(jsonb, jsonb, double precision)
IS '一键起飞三维航线冲突检查：返回code/msg/ischeck及计划与计划、计划与在飞冲突集合，以中心线三维距离<=R判断冲突';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 计划机库A/B的规划段交叉，并与在飞机库C的海拔航线交叉。
-- 计划原航点为距地100米，机库所在地面海拔50米，换算后规划段海拔150米。
-- 缓冲半径R=5米，中心线距离<=5米属于冲突；R=0只检查中心线相交。
-- SELECT jsonb_pretty(public.gis_uav_flight_takeoff_check(
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
--
-- 返回结果（完整航线和冲突点字段按实际数据展开）：
-- {
--   "code": 200,
--   "msg": "校验完成：发现2条冲突（计划与计划1条，计划与在飞1条），机库ID：A, B, C",
--   "ischeck": false,
--   "plan_conflicts": [
--     {
--       "plan_hangar_id": "A",
--       "conflict_hangar_id": "B",
--       "plan_route": "原始计划GeoJSON",
--       "conflict_route": "原始计划GeoJSON",
--       "intersection_points": [{"plan_point": "PointZ", "conflict_point": "PointZ", "distance_m": 0}]
--     }
--   ],
--   "realtime_conflicts": [
--     {
--       "plan_hangar_id": "A",
--       "conflict_hangar_id": "C",
--       "plan_route": "原始计划GeoJSON",
--       "conflict_route": "原始在飞GeoJSON",
--       "intersection_points": [{"plan_point": "PointZ", "conflict_point": "PointZ", "distance_m": 0}]
--     }
--   ]
-- }
