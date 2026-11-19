-- =============================================================================
-- 灵犀一键起飞.sql
-- 灵犀一键起飞航线冲突校验规则说明
--
-- 脚本用途：提供计划航线与计划航线、计划航线与在飞航线的三维空间冲突校验，
--           返回校验状态、冲突数量、机库ID及双方原始航线和冲突代表点。
-- 通用约定：
--   1. 输入航线使用WGS84经纬度（SRID=4326），高度和安全间距单位为米。
--   2. 原始航点Z按相对地面高度约定；机库位置有效时换算为海拔，缺失或无效时按调用约定直接保留原始Z。
--   3. 安全间距R为两条航线中心线允许的最大三维距离，距离<=R（含边界）判为冲突。
--   4. code表示执行状态：200=校验完成，400=参数或航线数据错误，500=执行异常。
--   5. ischeck=true表示未发现冲突；发现冲突、参数错误或执行异常时为false。
--   6. 本函数只判断空间冲突，不判断飞行时间是否重叠；在飞/剩余航线由调用方传入。
--   7. 计划和在飞两个集合按处理顺序合并校验uav_id全局唯一；重复时保留先出现项，忽略后出现项并写入数据库日志。
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
--      public.gis_write_error_log，统一写入gis_error_log。
--   5. 本函数不读取或修改任务表，所有计划和在飞航线通过JSON数组传入。
-- =============================================================================

-- =============================================================================
-- 函数说明
-- =============================================================================
-- 函数名称：gis_uav_flight_takeoff_check
-- 函数功能：批量检测计划航线之间、计划航线与在飞航线之间的三维空间冲突。
-- 返回形式：固定返回一行表记录，冲突明细分别放在plan_conflicts和realtime_conflicts两个jsonb字段中。
-- 函数描述：
--   1. 校验两个航线集合和安全间距R。
--   2. 对机库位置有效的航线补齐为完整起飞、规划、返航和降落航线；位置缺失或无效时沿用原始航线。
--   3. 将所有计算航线转换到同一局部米制坐标系；位置有效时Z为海拔米，位置缺失或无效时沿用原航线Z。
--   4. 先按整条航线筛选三维距离<=R的航线对，再逐航段提取冲突代表点。
--   5. 返回计划与计划、计划与在飞两个冲突集合。
-- 入参说明：
--   p_plan_routes      jsonb；必填；计划航线数组，空集合传[]，不能为NULL。
--   p_realtime_routes  jsonb；选填；在飞航线数组，默认[]，不能为NULL。
--   p_buffer_radius    double precision；选填；三维安全间距R，单位米，默认0。
-- 计划航线项字段：
--   uav_id             必填；非空字符串或数字；值为机库ID；两个集合合计不能重复，重复时保留先出现项。
--   uav_location       选填；GeoJSON PointZ或Feature，Z为机库所在地面海拔；缺失或无效时跳过起降航线补齐。
--   ground_height     位置有效时必填；机库相对地面高度，单位米，地面机库传0；位置缺失或无效时忽略。
--   safe_height       位置有效时必填；相对机库的安全起飞高度，单位米；位置缺失或无效时忽略。
--   return_height     位置有效时选填；相对机库的返航高度，省略时采用safe_height。
--   flight_mode       位置有效时选填；1=垂直爬升，2=倾斜爬升，省略时为1。
--   route              必填；GeoJSON LineStringZ或首尾三维衔接的MultiLineStringZ，原Z为距地高度。
-- 在飞航线项字段：
--   与计划航线使用完全相同的字段；机库位置有效时调用gis_uav_flight_deviation_line，缺失或无效时使用原始航线。
-- 返回表字段：
--   code               integer；200=校验完成，400=参数或航线数据错误，500=执行异常。
--   msg                text；校验结果或错误原因；发现冲突时包含冲突数量和参与冲突的机库ID；忽略重复航线时包含忽略记录。
--   ischeck            boolean；true=未发现冲突，false=发现冲突或校验失败。
--   plan_conflicts     jsonb数组；计划与计划冲突，每条只返回一次。
--   realtime_conflicts jsonb数组；计划与在飞冲突。
-- 每条冲突记录：
--   route_type                              计划航线冲突或在飞航线冲突。
--   plan_uav_id、conflict_uav_id     双方机库ID。
--   plan_route、conflict_route             双方原始GeoJSON航线，不返回补齐后的计算航线。
--   points                                  冲突航段对的代表点数组。
--   plan_point、conflict_point             双方航段最近点，GeoJSON PointZ；位置有效时Z为海拔米，否则沿用原航线Z。
--   distance_m                             双方最近点的三维距离，单位米。
-- 异常说明：
--   1. 参数或航线数据错误直接返回code=400，不向调用方抛出内部校验异常。
--   2. 未预期的数据库或空间计算错误返回code=500。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
-- 删除旧入口和同名重载，避免数据库中残留旧定义。
SELECT public.gis_drop_function('public.gis_uav_flight_takeoff_check');

-- =============================================================================
-- 函数介绍：gis_uav_flight_takeoff_check
-- 主要作用：统一计划、在飞航线的高度基准并检测三维空间冲突。
-- 处理步骤：
--   1. 校验输入集合为JSON数组，校验R为非负有限值。
--   2. 解析每条航线，保留原始JSON；机库位置有效时调用完整航线函数，否则直接使用原始航线。
--   3. 按计划集合后在飞集合的顺序全局校验uav_id唯一性，一个机库只保留一条输入航线；重复项忽略并写数据库日志。
--   4. 以第一条计划航线的有效机库位置或原始航线首点为中心建立局部AEQD投影，XY转换为米，Z按上述规则保留。
--   5. 计划集合为空时直接返回code=200、ischeck=true和两个空数组。
--   6. 计划与计划只比较i<j；计划与在飞逐一比较。
--   7. 用ST_3DDWithin按R筛选航线对，再用ST_DumpSegments拆分命中的航线。
--   8. 用ST_3DShortestLine取得双方最近点，点坐标转回WGS84后按点对去重。
--   9. 根据冲突数组统计数量，组装msg中的冲突类型数量和机库ID。
-- 高度约定：
--   1. gis_uav_flight_deviation_line(..., true, flight_mode)返回海拔基准的完整航线；机库位置缺失或无效时沿用原始航线。
--   2. 位置有效时机库起飞、规划、返航和降落段均参与判断；位置缺失或无效时只检查传入的原始route。
--   3. 不查询DEM；使用完整航线函数时沿用其忽略航点与机库间地形高差的约定，位置缺失或无效时直接使用原始航线高度。
--   4. 为消除投影浮点残差，小于0.0000001米的距离按0处理；R小于该值时按该容差筛选。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_uav_flight_takeoff_check(
    p_plan_routes jsonb,
    p_realtime_routes jsonb DEFAULT '[]'::jsonb,
    p_buffer_radius double precision DEFAULT 0
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    plan_conflicts jsonb,
    realtime_conflicts jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_item record;
    v_data jsonb;
    v_inputs jsonb[] := ARRAY[]::jsonb[];
    v_routes geometry[] := ARRAY[]::geometry[];
    v_route geometry;
    v_location geometry;
    v_location_valid boolean := false;
    v_center geometry;
    v_projection text;
    v_plan_count integer;
    v_limit double precision;
    v_result jsonb;
    v_plan_uav_ids text[] := ARRAY[]::text[];
    v_realtime_uav_ids text[] := ARRAY[]::text[];
    v_uav_id text;
    v_duplicate_logs text[] := ARRAY[]::text[];
    v_duplicate_log text;
    v_duplicate_msg text := '';
    v_plan_conflict_count integer := 0;
    v_realtime_conflict_count integer := 0;
    v_conflict_uav_ids text;
    v_msg text;
    v_log_sql text;
BEGIN
    v_log_sql := format(
        'SELECT * FROM public.gis_uav_flight_takeoff_check(%L, %L, %L);',
        p_plan_routes::text, p_realtime_routes::text, p_buffer_radius::text
    );
    -- PERFORM public.gis_write_error_log(600, 'gis_uav_flight_takeoff_check', v_log_sql);

    IF jsonb_typeof(p_plan_routes) IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_realtime_routes) IS DISTINCT FROM 'array' THEN
        code := 400;
        msg := '计划航线和在飞航线集合必须为JSON数组，空集合请传[]';
        ischeck := false;
        plan_conflicts := '[]'::jsonb;
        realtime_conflicts := '[]'::jsonb;
        RETURN NEXT;
        RETURN;
    END IF;
    -- 避免NaN、Infinity；NULL不能悄悄导致所有冲突漏报。
    IF p_buffer_radius IS NULL OR p_buffer_radius < 0
       OR p_buffer_radius::text IN ('NaN', 'Infinity', '-Infinity') THEN
        code := 400;
        msg := '缓冲半径必须为非负有限值（米）';
        ischeck := false;
        plan_conflicts := '[]'::jsonb;
        realtime_conflicts := '[]'::jsonb;
        RETURN NEXT;
        RETURN;
    END IF;
    v_limit := greatest(p_buffer_radius, 0.0000001::double precision);
    v_plan_count := 0;

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
            IF COALESCE(jsonb_typeof(v_data->'uav_id'), 'null') NOT IN ('string', 'number')
               OR btrim(v_data->>'uav_id') = '' THEN
                RAISE EXCEPTION 'uav_id必须为非空字符串或数字';
            END IF;
            v_uav_id := btrim(v_data->>'uav_id');
            IF v_uav_id = ANY(v_plan_uav_ids) OR v_uav_id = ANY(v_realtime_uav_ids) THEN
                v_duplicate_log := format(
                    '%s航线集合第%s项uav_id=%s重复，已忽略后出现的航线，保留先出现的航线',
                    v_item.kind, v_item.ord, v_uav_id
                );
                -- PERFORM public.gis_write_error_log(
                --     600, 'gis_uav_flight_takeoff_check: ' || v_duplicate_log, v_log_sql
                -- );
                v_duplicate_logs := array_append(v_duplicate_logs, v_duplicate_log);
                CONTINUE;
            END IF;
            IF v_item.kind = '计划' THEN
                v_plan_uav_ids := array_append(v_plan_uav_ids, v_uav_id);
                v_plan_count := v_plan_count + 1;
            ELSE
                v_realtime_uav_ids := array_append(v_realtime_uav_ids, v_uav_id);
            END IF;
            IF jsonb_typeof(v_data->'route') IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION 'route必须为GeoJSON三维航线对象';
            END IF;
            v_route := public.gis_geojson_to_geom((v_data->'route')::text);
            IF v_route IS NULL OR ST_IsEmpty(v_route)
               OR GeometryType(v_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
               OR NOT ST_IsValid(v_route) THEN
                RAISE EXCEPTION 'route必须为有效且非空的三维LineString或MultiLineString';
            END IF;
            IF ST_SRID(v_route) NOT IN (0, 4326) OR EXISTS (
                SELECT 1 FROM ST_DumpPoints(v_route) d
                WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
                   OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)
                   OR ST_Z(d.geom) IS NULL OR ST_Z(d.geom) < 0
                   OR ST_Z(d.geom)::text IN ('NaN', 'Infinity', '-Infinity')
            ) THEN
                RAISE EXCEPTION 'route必须使用WGS84经纬度并包含非负有限的三维高度';
            END IF;
            IF EXISTS (
                SELECT 1
                FROM ST_Dump(v_route) d
                WHERE ST_IsEmpty(d.geom)
            ) THEN
                RAISE EXCEPTION 'MultiLineString航线不能包含空航段';
            END IF;
            IF EXISTS (
                SELECT 1
                FROM (
                    SELECT d.geom,
                           lag(d.geom) OVER (ORDER BY d.path) AS previous_geom
                    FROM ST_Dump(v_route) d
                ) parts
                WHERE previous_geom IS NOT NULL
                  AND (
                      ST_X(ST_EndPoint(previous_geom)) <> ST_X(ST_StartPoint(geom))
                      OR ST_Y(ST_EndPoint(previous_geom)) <> ST_Y(ST_StartPoint(geom))
                      OR ST_Z(ST_EndPoint(previous_geom)) <> ST_Z(ST_StartPoint(geom))
                  )
            ) THEN
                RAISE EXCEPTION 'MultiLineString航线各段必须按飞行顺序在三维空间首尾衔接';
            END IF;

            -- 计划和在飞航线使用同一套机库、起飞高度及飞行模式字段。
            -- 机库位置缺失、格式错误或不满足PointZ要求时，跳过完整起降航线构造，直接使用原始航线。
            v_location := NULL;
            BEGIN
                v_location := public.gis_geojson_to_geom((v_data->'uav_location')::text);
            EXCEPTION WHEN OTHERS THEN
                v_location := NULL;
            END;
            v_location_valid := false;
            IF v_location IS NOT NULL
               AND NOT ST_IsEmpty(v_location)
               AND GeometryType(v_location) = 'POINT' THEN
                IF ST_SRID(v_location) IN (0, 4326)
                   AND ST_X(v_location) BETWEEN -180 AND 180
                   AND ST_Y(v_location) BETWEEN -90 AND 90
                   AND ST_Z(v_location) IS NOT NULL
                   AND ST_Z(v_location)::text NOT IN ('NaN', 'Infinity', '-Infinity') THEN
                    v_location_valid := true;
                END IF;
            END IF;
            IF v_location_valid THEN
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
            END IF;
            IF v_item.kind = '计划' AND v_center IS NULL THEN
                IF v_location_valid THEN
                    v_center := v_location;
                ELSE
                    SELECT d.geom
                    INTO v_center
                    FROM ST_DumpPoints(v_route) d
                    ORDER BY d.path
                    LIMIT 1;
                END IF;
            END IF;
            v_inputs := array_append(v_inputs, v_data);
            v_routes := array_append(v_routes, v_route);
        EXCEPTION WHEN OTHERS THEN
            code := 400;
            msg := format('%s航线集合第%s项：%s', v_item.kind, v_item.ord, SQLERRM);
            ischeck := false;
            plan_conflicts := '[]'::jsonb;
            realtime_conflicts := '[]'::jsonb;
            RETURN NEXT;
            RETURN;
        END;
    END LOOP;

    IF cardinality(v_duplicate_logs) > 0 THEN
        v_duplicate_msg := '；已忽略重复航线：' || array_to_string(v_duplicate_logs, '；');
    END IF;

    IF v_plan_count = 0 THEN
        code := 200;
        msg := '校验完成：未发现冲突' || v_duplicate_msg;
        ischeck := true;
        plan_conflicts := '[]'::jsonb;
        realtime_conflicts := '[]'::jsonb;
        RETURN NEXT;
        RETURN;
    END IF;
    v_projection := format(
        '+proj=aeqd +lat_0=%s +lon_0=%s +datum=WGS84 +units=m +no_defs',
        ST_Y(v_center), ST_X(v_center)
    );

    -- 二、每条计算航线只投影一次；先筛选冲突航线对，再逐航段提取全部命中对的代表点。
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
                   'route_type', CASE WHEN p.kind = 'plan_conflicts' THEN '计划航线冲突' ELSE '在飞航线冲突' END,
                   'plan_uav_id', p.plan_input->'uav_id',
                   'plan_route', p.plan_input->'route',
                   'conflict_uav_id', p.conflict_input->'uav_id',
                   'conflict_route', p.conflict_input->'route',
                   'points', points.items
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
        v_msg := '校验完成：未发现冲突' || v_duplicate_msg;
        code := 200;
        msg := v_msg;
        ischeck := true;
        plan_conflicts := v_result->'plan_conflicts';
        realtime_conflicts := v_result->'realtime_conflicts';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT string_agg(uav_id, ', ' ORDER BY uav_id)
    INTO v_conflict_uav_ids
    FROM (
        SELECT DISTINCT item->>'plan_uav_id' AS uav_id
        FROM jsonb_array_elements((v_result->'plan_conflicts') || (v_result->'realtime_conflicts')) AS e(item)
        UNION
        SELECT DISTINCT item->>'conflict_uav_id' AS uav_id
        FROM jsonb_array_elements((v_result->'plan_conflicts') || (v_result->'realtime_conflicts')) AS e(item)
    ) ids
    WHERE uav_id IS NOT NULL AND uav_id <> '';

    v_msg := format(
        '校验完成：发现%s条冲突（计划与计划%s条，计划与在飞%s条），机库ID：%s',
        v_plan_conflict_count + v_realtime_conflict_count,
        v_plan_conflict_count,
        v_realtime_conflict_count,
        COALESCE(v_conflict_uav_ids, '未提供')
    ) || v_duplicate_msg;
    code := 200;
    msg := v_msg;
    ischeck := false;
    plan_conflicts := v_result->'plan_conflicts';
    realtime_conflicts := v_result->'realtime_conflicts';
    RETURN NEXT;
    RETURN;
EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('执行异常：%s', SQLERRM);
        ischeck := false;
        plan_conflicts := '[]'::jsonb;
        realtime_conflicts := '[]'::jsonb;
        RETURN NEXT;
        RETURN;
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
-- SELECT *
-- FROM public.gis_uav_flight_takeoff_check(
--     '[                                      -- p_plan_routes：计划航线数组
--       {
--         "uav_id": "A",                                      -- 机库ID；重复时忽略后一个
--         "uav_location": {"type":"Point","coordinates":[116.00,36.00,50]}, -- 机库位置；经度、纬度、地面海拔
--         "ground_height": 0,                                  -- 机库相对地面高度，单位米
--         "safe_height": 60,                                    -- 安全起飞高度，单位米
--         "return_height": 80,                                 -- 返航高度，单位米
--         "flight_mode": 1,                                    -- 1=垂直爬升，2=倾斜爬升
--         "route": {"type":"LineString","coordinates":[[116.00,36.00,100],[116.02,36.00,100]]} -- 原始航线；Z为距地高度
--       },
--       {
--         "uav_id": "B",                                      -- 机库ID
--         "uav_location": {"type":"Point","coordinates":[116.01,35.99,50]}, -- 机库位置；经度、纬度、地面海拔
--         "ground_height": 0,                                  -- 机库相对地面高度，单位米
--         "safe_height": 60,                                    -- 安全起飞高度，单位米
--         "return_height": 80,                                 -- 返航高度，单位米
--         "flight_mode": 2,                                    -- 1=垂直爬升，2=倾斜爬升
--         "route": {"type":"LineString","coordinates":[[116.01,35.99,100],[116.01,36.01,100]]} -- 原始航线；Z为距地高度
--       }
--     ]'::jsonb,                                                -- p_plan_routes结束
--     '[                                                      -- p_realtime_routes：在飞航线数组
--       {
--         "uav_id": "C",                                      -- 机库ID
--         "uav_location": {"type":"Point","coordinates":[116.015,35.99,50]}, -- 机库位置；经度、纬度、地面海拔
--         "ground_height": 0,                                  -- 机库相对地面高度，单位米
--         "safe_height": 60,                                    -- 安全起飞高度，单位米
--         "return_height": 80,                                 -- 返航高度，单位米
--         "flight_mode": 1,                                    -- 1=垂直爬升，2=倾斜爬升
--         "route": {"type":"LineString","coordinates":[[116.015,35.99,100],[116.015,36.01,100]]} -- 原始航线；Z为距地高度
--       }
--     ]'::jsonb,                                                -- p_realtime_routes结束
--     5                                                         -- p_buffer_radius：三维安全间距，单位米
-- );
--
-- SELECT jsonb_pretty(to_jsonb(t))
-- FROM (
--     SELECT *
--     FROM public.gis_uav_flight_takeoff_check(
--         p_plan_routes,
--         p_realtime_routes,
--         5
--     )
-- ) AS t;
--
-- 返回结果为固定一行的表：
-- code | msg | ischeck | plan_conflicts(jsonb) | realtime_conflicts(jsonb)
-- 下面展开该行中的两个jsonb冲突字段：
-- {
--   "code": 200,                                               -- 校验状态：200=完成，400=参数错误，500=执行异常
--   "msg": "校验完成：发现2条冲突（计划与计划1条，计划与在飞1条），机库ID：A, B, C", -- 校验信息
--   "ischeck": false,                                          -- false=发现冲突或校验失败，true=无冲突
--   "plan_conflicts": [                                        -- 计划与计划冲突集合
--     {
--       "route_type": "计划航线冲突",                         -- 冲突类型
--       "plan_uav_id": "A",                                   -- 计划航线机库ID
--       "conflict_uav_id": "B",                               -- 相交计划航线机库ID
--       "plan_route": "原始计划GeoJSON",                      -- 计划航线原始GeoJSON
--       "conflict_route": "原始计划GeoJSON",                  -- 相交航线原始GeoJSON
--       "points": [                                             -- 冲突航段最近点数组
--         {
--           "plan_point": {"type":"Point","coordinates":[116.010000,36.000000417,130]}, -- 计划航线最近点：[经度,纬度,海拔]
--           "conflict_point": {"type":"Point","coordinates":[116.010000,36.000000417,130]}, -- 相交航线最近点：[经度,纬度,海拔]
--           "distance_m": 0                                  -- 两点三维距离，单位米
--         },
--         {
--           "plan_point": {"type":"Point","coordinates":[116.010000,36.000000417,150]}, -- 计划航线最近点：[经度,纬度,海拔]
--           "conflict_point": {"type":"Point","coordinates":[116.010000,36.000000417,150]}, -- 相交航线最近点：[经度,纬度,海拔]
--           "distance_m": 0                                  -- 两点三维距离，单位米
--         }
--       ]
--     }
--   ],
--   "realtime_conflicts": [                                   -- 计划与在飞冲突集合
--     {
--       "route_type": "在飞航线冲突",                         -- 冲突类型
--       "plan_uav_id": "A",                                   -- 计划航线机库ID
--       "conflict_uav_id": "C",                               -- 相交在飞航线机库ID
--       "plan_route": "原始计划GeoJSON",                      -- 计划航线原始GeoJSON
--       "conflict_route": "原始在飞GeoJSON",                  -- 相交在飞航线原始GeoJSON
--       "points": [                                             -- 冲突航段最近点数组
--         {
--           "plan_point": {"type":"Point","coordinates":[116.015000,36.000000313,130]}, -- 计划航线最近点：[经度,纬度,海拔]
--           "conflict_point": {"type":"Point","coordinates":[116.015000,36.000000313,130]}, -- 在飞航线最近点：[经度,纬度,海拔]
--           "distance_m": 0                                  -- 两点三维距离，单位米
--         },
--         {
--           "plan_point": {"type":"Point","coordinates":[116.015000,36.000000313,150]}, -- 计划航线最近点：[经度,纬度,海拔]
--           "conflict_point": {"type":"Point","coordinates":[116.015000,36.000000313,150]}, -- 在飞航线最近点：[经度,纬度,海拔]
--           "distance_m": 0                                  -- 两点三维距离，单位米
--         }
--       ]
--     }
--   ]
-- }
