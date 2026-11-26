-- =============================================================================
-- 灵犀一键起飞.sql
-- 灵犀一键起飞航线冲突校验规则说明
--
-- 脚本用途：提供计划航线与计划航线、计划航线与在飞航线的三维空间冲突校验，
--           返回校验状态、冲突数量、机库ID、双方原始航线及命中航段对的进入/离开点。
-- 通用约定：
--   1. 输入航线使用WGS84经纬度（SRID=4326），高度和安全间距单位为米。
--   2. 原始航点Z按相对机库高度约定；机库位置有效时加机库起飞点海拔，缺失或无效时直接保留原始Z，调用方须保证各条计算航线高度基准一致。
--   3. 安全间距R为两条航线中心线的三维冲突阈值，距离<R（不含边界）判为冲突；R=0时不判冲突。
--      R直接用于中心线距离比较，不生成缓冲几何，也不将双方半径相加；例如R=5时，距离等于5米不提醒。
--   4. code表示执行状态：200=校验完成，400=参数或航线数据错误，500=执行异常。
--   5. ischeck=true表示未发现冲突；发现冲突、参数错误或执行异常时为false。
--   6. 本函数只判断空间冲突，不判断飞行时间是否重叠；在飞/剩余航线由调用方传入。
--   7. 计划和在飞两个集合按处理顺序合并校验uav_id全局唯一；重复时保留先出现项，忽略后出现项并写入数据库日志。
--   8. 冲突数量按航线对统计，同一航线对命中多个航段时仍只算一条冲突；points取首个命中航段对的进入/离开点。
--
--   （1）计划航线与计划航线冲突
--   函数：public.gis_uav_flight_takeoff_check
--   规则：按输入顺序只比较i<j，不比较自身，不返回反向重复对。
--   返回：plan_conflicts数组。
--
--   （2）计划航线与在飞航线冲突
--   函数：public.gis_uav_flight_takeoff_check
--   规则：对去重后的集合，每条计划航线逐一比较每条在飞航线；同机库ID的后出现项已被忽略。
--         不检查在飞航线与在飞航线之间的冲突。
--   返回：realtime_conflicts数组。
--
-- 依赖说明：
--   1. PostGIS >= 3.2，使用ST_DumpSegments、ST_3DDWithin、ST_3DDistance和PROJ投影。
--   2. 函数/baseFunction/gis_drop_function.sql：删除同名函数及全部重载。
--   3. 函数/baseFunction/gis_geojson_to_geom.sql：解析GeoJSON为geometry。
--   4. 项目产品共用函数/1灵犀聊城通用.sql：
--      public.gis_uav_flight_deviation_line，构造完整三维起降航线。
--      public.gis_write_error_log，统一写入gis_error_log。
--   5. 本函数不读取或修改任务表，所有计划和在飞航线通过JSON数组传入。
--   6. gis_write_error_log与航线构造函数均由公共脚本提供；日志表public.gis_error_log须预先存在。
-- 与其他校验的关系：
--   本函数按航段中心线三维距离<R判冲突；3.空域区块校验.sql的任务航线冲突函数使用二维缓冲相交及整体Z区间重叠。
--   两者的距离、半径为0及边界规则分别以各自实现为准，不能直接互换结果。
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
--   4. 先按整条航线粗筛候选航线对，再逐航段按三维距离<R判定，并计算进入/离开R范围的位置。
--   5. 返回计划与计划、计划与在飞两个冲突集合。
-- 入参说明：
--   p_plan_routes      jsonb；必填；计划航线数组，空集合传[]，不能为NULL。
--   p_realtime_routes  jsonb；选填；在飞航线数组，默认[]，不能为NULL。
--   p_buffer_radius    double precision；选填；三维安全间距R，单位米，须为非负有限值，默认0；0不判冲突。
-- 计划航线项字段：
--   uav_id             必填；非空字符串或数字；值为机库ID；两个集合合计不能重复，重复时保留先出现项。
--                      按去除首尾空白后的文本判断重复，例如数字1与字符串"1"视为同一机库。
--   uav_location       选填；GeoJSON PointZ或Feature，Z为机库所在地面海拔；缺失或无效时跳过起降航线补齐。
--   ground_height     位置有效时必填；机库相对地面高度，单位米，地面机库传0；位置缺失或无效时忽略。
--   safe_height       位置有效时必填；相对机库的安全起飞高度，单位米；位置缺失或无效时忽略。
--   return_height     位置有效时选填；相对机库的配置返航高度，省略时采用safe_height；实际返航高度取其与末航点高度的较大值。
--   flight_mode       位置有效时选填；1=垂直爬升，2=倾斜爬升，省略时为1。
--   route              必填；GeoJSON LineStringZ或首尾三维衔接的MultiLineStringZ，原Z为相对机库的非负有限高度。
--                      MultiLineString按输入部件顺序检查XYZ首尾完全相等，不自动排序、补线或吸附端点。
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
--   points                                  一维jsonb对象数组；命中航段对时包含开始、结束两组点对，未命中时为空数组。
-- points明细格式：
--   plan_point、conflict_point             计划航段进入/离开R范围的位置及对方航段上的最近对应点，GeoJSON PointZ；位置有效时Z为海拔米，否则沿用原航线Z。
--   distance_m                             当前起止位置到对方航段最近点的三维距离，单位米，不是整条航线的最短距离。
--   顺序约定                               所有点对平铺在同一数组；首个命中航段对依次追加开始、结束点对；退化航段两条相同；仅接触R边界不返回。
--   范围约定                               整段都在R内时返回计划航段首尾点；仅部分在R内时二分逼近进入/离开位置，取边界内侧点。
--   精度约定                               GeoJSON坐标最多保留9位小数；distance_m按米制计算几何求得，未用序列化后的坐标重新计算。
--                                          接近边界的内侧点在坐标序列化或展示四舍五入后可能看起来位于边界，不代表仅接触边界也会报冲突。
-- 日志说明：
--   1. 入口在参数校验前写一条600调用日志，sqlstring保存格式化后的调用SQL，便于复现输入。
--   2. 每忽略一条重复uav_id航线，再写一条600日志，并把忽略记录追加到返回msg。
--   3. 600是gis_error_log的日志分类，与返回code字段的200/400/500含义不同。
--   4. 日志写入使用调用方事务；异常块或事务回滚会影响对应日志的持久化，不单独提交日志。
-- 异常说明：
--   1. 集合、半径不合法，或航线逐项解析/补齐块内发生异常，返回code=400；航线项异常的msg包含集合类型和原始序号。
--   2. 上述逐项处理块之外的异常由外层捕获，返回code=500；两类错误均返回ischeck=false及两个空冲突数组。
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
--   5. 两个集合均完成逐项解析后，若计划集合为空，返回code=200、ischeck=true和两个空数组。
--   6. 计划与计划只比较i<j；计划与在飞逐一比较。
--   7. 用ST_3DDWithin按R粗筛航线对，再用ST_DumpSegments拆分航线，最终仅保留三维距离<R的航段对。
--   8. 命中一对航段即可确认航线对冲突，并计算该航段对进入/离开R范围的位置写入points。
--   9. 根据冲突数组统计数量，组装msg中的冲突类型数量和机库ID。
-- 高度约定：
--   1. gis_uav_flight_deviation_line(..., true, flight_mode)返回海拔基准的完整航线；机库位置缺失或无效时沿用原始航线。
--   2. 位置有效时机库起飞、规划、返航和降落段均参与判断；位置缺失或无效时只检查传入的原始route。
--   3. 不查询DEM；使用完整航线函数时加机库起飞点海拔统一基准，位置缺失或无效时直接使用原始航线高度，由调用方保证与其他计算航线同基准。
--      机库起飞点海拔=ST_Z(uav_location)+ground_height；原规划航点海拔=原Z+机库起飞点海拔。
--   4. 冲突严格按原始三维距离<R判定，不扩大R。
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
    -- 遍历输入项时保留集合类型、原始序号和JSON内容，便于错误定位及返回原航线。
    v_item record;
    v_data jsonb;
    -- 两个数组下标一一对应，按去重后的“计划在前、在飞在后”顺序保存原始对象与计算几何。
    v_inputs jsonb[] := ARRAY[]::jsonb[];
    v_routes geometry[] := ARRAY[]::geometry[];
    v_route geometry;
    v_location geometry;
    v_location_valid boolean := false;
    -- v_center只由第一条保留的计划航线确定，全部航线共用v_projection，避免坐标系不同导致距离不可比。
    v_center geometry;
    v_projection text;
    -- v_plan_count是去重后计划航线数量，也是在合并数组中区分计划和在飞的下标分界。
    v_plan_count integer;
    -- v_limit始终等于已校验的输入R；用于粗筛及严格判定，不是双方缓冲半径之和。
    v_limit double precision;
    v_result jsonb;
    -- 当前候选航线对及其两个航段；航线对循环内再逐一检查双方航段组合。
    v_pair record;
    v_plan_segment geometry;
    v_conflict_segment geometry;
    -- v_boundaries保存当前冲突航段对进入、离开R范围的最近短线，供points组装使用。
    v_boundaries geometry[];
    v_points jsonb := '[]'::jsonb;
    v_has_conflict boolean := false;
    v_conflict_item jsonb;
    -- 按航线对积累两类冲突，最终分别转换成返回的JSON数组。
    v_plan_items jsonb[] := ARRAY[]::jsonb[];
    v_realtime_items jsonb[] := ARRAY[]::jsonb[];
    -- ID集合用于跨集合去重，计划航线数量只统计未重复项，不按原始JSON项数确定分界。
    v_plan_uav_ids text[] := ARRAY[]::text[];
    v_realtime_uav_ids text[] := ARRAY[]::text[];
    v_uav_id text;
    -- 重复项的忽略说明既写600日志，也在成功返回的msg中汇总展示。
    v_duplicate_logs text[] := ARRAY[]::text[];
    v_duplicate_log text;
    v_duplicate_msg text := '';
    v_plan_conflict_count integer := 0;
    v_realtime_conflict_count integer := 0;
    v_conflict_uav_ids text;
    v_msg text;
    v_log_sql text;
BEGIN
    -- %L按SQL字面量格式处理JSON、半径和NULL，日志中的调用SQL可用于复现本次输入。
    v_log_sql := format(
        'SELECT * FROM public.gis_uav_flight_takeoff_check(%L, %L, %L);',
        p_plan_routes::text, p_realtime_routes::text, p_buffer_radius::text
    );
    -- 入口600日志先于参数校验，因此不合法的输入调用也会尝试记录。
    PERFORM public.gis_write_error_log(600, 'gis_uav_flight_takeoff_check', v_log_sql);

    -- 显式区分JSON数组、JSON null及SQL NULL，防止把错误集合当成空数组继续处理。
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
    -- 直接使用调用方半径，不增加距离容差；R=0时任何非负距离都不满足distance<R。
    v_limit := p_buffer_radius;
    v_plan_count := 0;

    -- 一、按计划、在飞的顺序解析一次，原始对象和计算几何分别保存。
    -- group_order确保计划集合优先，同一集合内按ord保留输入顺序，因此跨集合重复时计划项优先。
    FOR v_item IN
        SELECT '计划' AS kind, p.ord, p.data, 1 AS group_order
        FROM jsonb_array_elements(p_plan_routes) WITH ORDINALITY AS p(data, ord)
        UNION ALL
        SELECT '在飞', r.ord, r.data, 2
        FROM jsonb_array_elements(p_realtime_routes) WITH ORDINALITY AS r(data, ord)
        ORDER BY group_order, ord
    LOOP
        BEGIN
            -- 每项先校验对象和机库ID，再判断重复；重复项直接忽略，不继续解析它的route或机库参数。
            v_data := v_item.data;
            IF jsonb_typeof(v_data) IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION '航线项必须为JSON对象';
            END IF;
            IF COALESCE(jsonb_typeof(v_data->'uav_id'), 'null') NOT IN ('string', 'number')
               OR btrim(v_data->>'uav_id') = '' THEN
                RAISE EXCEPTION 'uav_id必须为非空字符串或数字';
            END IF;
            -- 数字ID与字符串ID统一按文本比较；首尾空白不参与唯一性判断，返回原始JSON时仍保留原值。
            v_uav_id := btrim(v_data->>'uav_id');
            IF v_uav_id = ANY(v_plan_uav_ids) OR v_uav_id = ANY(v_realtime_uav_ids) THEN
                v_duplicate_log := format(
                    '%s航线集合第%s项uav_id=%s重复，已忽略后出现的航线，保留先出现的航线',
                    v_item.kind, v_item.ord, v_uav_id
                );
                -- 重复项单独写600日志；CONTINUE保留先出现项，不覆盖已保存的航线。
                PERFORM public.gis_write_error_log(
                    600, 'gis_uav_flight_takeoff_check: ' || v_duplicate_log, v_log_sql
                );
                v_duplicate_logs := array_append(v_duplicate_logs, v_duplicate_log);
                CONTINUE;
            END IF;
            -- 仅非重复项进入ID集合与数量统计，保证后续v_inputs/v_routes中的计划分界一致。
            IF v_item.kind = '计划' THEN
                v_plan_uav_ids := array_append(v_plan_uav_ids, v_uav_id);
                v_plan_count := v_plan_count + 1;
            ELSE
                v_realtime_uav_ids := array_append(v_realtime_uav_ids, v_uav_id);
            END IF;
            -- route为必填项；解析后须是有效且非空的线几何，不能用点、面或缺失航线参与检查。
            IF jsonb_typeof(v_data->'route') IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION 'route必须为GeoJSON三维航线对象';
            END IF;
            v_route := public.gis_geojson_to_geom((v_data->'route')::text);
            IF v_route IS NULL OR ST_IsEmpty(v_route)
               OR GeometryType(v_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
               OR NOT ST_IsValid(v_route) THEN
                RAISE EXCEPTION 'route必须为有效且非空的三维LineString或MultiLineString';
            END IF;
            -- 逐点校验经纬度与Z；此处要求原航点高度非负，补齐后转换成的海拔高度不在这里重新限制。
            IF ST_SRID(v_route) NOT IN (0, 4326) OR EXISTS (
                SELECT 1 FROM ST_DumpPoints(v_route) d
                WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
                   OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)
                   OR ST_Z(d.geom) IS NULL OR ST_Z(d.geom) < 0
                   OR ST_Z(d.geom)::text IN ('NaN', 'Infinity', '-Infinity')
            ) THEN
                RAISE EXCEPTION 'route必须使用WGS84经纬度并包含非负有限的三维高度';
            END IF;
            -- 整条非空仍可能含空部件，须检查MultiLineString的每个部件。
            IF EXISTS (
                SELECT 1
                FROM ST_Dump(v_route) d
                WHERE ST_IsEmpty(d.geom)
            ) THEN
                RAISE EXCEPTION 'MultiLineString航线不能包含空航段';
            END IF;
            -- 按部件路径顺序比较上一部件末点与当前部件首点，XYZ必须完全衔接，不采用距离容差。
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
                -- 机库位置是可选信息，解析失败只触发沿用原航线，不把该航线整体判为参数错误。
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
                -- true要求公共函数输出海拔航线；返航高度及飞行模式仅在字段缺省时取默认值。
                -- 机库距地高度、安全高度等参数由公共函数校验，异常由本项外层捕获并返回400。
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
            -- 第一条保留的计划航线确定共用投影中心；没有有效机库时，选该航线按路径顺序的首点。
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
            -- 原始JSON用于输出，补齐后的geometry仅用于计算；二者保持相同数组下标。
            v_inputs := array_append(v_inputs, v_data);
            v_routes := array_append(v_routes, v_route);
        EXCEPTION WHEN OTHERS THEN
            -- 任一非重复航线解析或补齐失败即结束整次校验，返回集合类型、原始序号及数据库错误原因。
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

    -- 没有计划航线便没有需要比较的航线对；在飞集合已在上方完成解析，不再两两互查。
    IF v_plan_count = 0 THEN
        code := 200;
        msg := '校验完成：未发现冲突' || v_duplicate_msg;
        ischeck := true;
        plan_conflicts := '[]'::jsonb;
        realtime_conflicts := '[]'::jsonb;
        RETURN NEXT;
        RETURN;
    END IF;
    -- AEQD以当前中心建立局部米制XY坐标，已有的Z高度按米保留，用于后续三维距离计算。
    v_projection := format(
        '+proj=aeqd +lat_0=%s +lon_0=%s +datum=WGS84 +units=m +no_defs',
        ST_Y(v_center), ST_X(v_center)
    );

    -- 二、每条计算航线只投影一次；逐航段判断冲突，暂不计算交点。
    FOR v_pair IN
    -- MATERIALIZED复用投影结果，避免在航线配对、航段拆分时重复转换同一条航线。
    WITH routes AS MATERIALIZED (
        SELECT r.ord, v_inputs[r.ord::integer] AS original,
               ST_Transform(r.geom, v_projection) AS geom
        FROM unnest(v_routes) WITH ORDINALITY AS r(geom, ord)
    ), pairs AS MATERIALIZED (
        -- a始终是计划航线；a.ord<b.ord排除自身及反向重复对，也自然排除了在飞与在飞的配对。
        -- ST_3DDWithin按distance<=R粗筛，最终是否冲突由下方航段三维距离<R决定。
        SELECT a.ord AS plan_ord, b.ord AS conflict_ord,
               CASE WHEN b.ord <= v_plan_count THEN 'plan_conflicts'
                    ELSE 'realtime_conflicts' END AS kind,
               a.original AS plan_input, b.original AS conflict_input
        FROM routes a JOIN routes b ON a.ord < b.ord
        WHERE a.ord <= v_plan_count AND ST_3DDWithin(a.geom, b.geom, v_limit)
    ), segments AS MATERIALIZED (
        -- 只拆分候选航线；d.path保留部件及航段顺序，起飞、返航、降落段若已补齐也一并参与。
        SELECT r.ord, d.path AS segment_path, d.geom
        FROM routes r CROSS JOIN LATERAL ST_DumpSegments(r.geom) d
        WHERE EXISTS (SELECT 1 FROM pairs p WHERE r.ord IN (p.plan_ord, p.conflict_ord))
    ), segment_arrays AS (
        -- 每条航线的航段按原路径顺序组成数组，后续FOREACH据此遍历航段对。
        SELECT ord, array_agg(geom ORDER BY segment_path) AS geoms
        FROM segments
        GROUP BY ord
    )
    SELECT p.*, a.geoms AS plan_segments, b.geoms AS conflict_segments
    FROM pairs p
    JOIN segment_arrays a ON a.ord = p.plan_ord
    JOIN segment_arrays b ON b.ord = p.conflict_ord
    ORDER BY p.plan_ord, p.conflict_ord
    LOOP
        -- 每条航线对单独记录是否命中，并重置交点明细容器。
        v_has_conflict := false;
        v_boundaries := ARRAY[]::geometry[];
        v_points := '[]'::jsonb;
        FOREACH v_plan_segment IN ARRAY v_pair.plan_segments LOOP
            FOREACH v_conflict_segment IN ARRAY v_pair.conflict_segments LOOP
                -- 直接比较三维最短距离，严格排除仅接触R边界的航段对。
                IF ST_3DDistance(v_plan_segment, v_conflict_segment) >= v_limit THEN
                    CONTINUE;
                END IF;

                -- 交点及进入/离开边界计算：沿计划航段求进入、离开R范围的位置。
                -- 沿计划航段到对方线段的距离为凸函数，因此<R的部分形成一个连续区间。
                -- 以最近点为已知内点，向计划航段首、尾分别查找区间两端，不按返回点坐标重新排序。
                -- 每侧最多二分64次，沿计划航段的搜索区间不大于0.00000001米时提前结束。
                DECLARE
                    v_first geometry := ST_StartPoint(v_plan_segment);
                    v_last geometry := ST_EndPoint(v_plan_segment);
                    -- 最近短线的方向与传参顺序一致：起点在计划航段，终点在冲突航段。
                    v_nearest_line geometry := ST_3DShortestLine(v_plan_segment, v_conflict_segment);
                    v_nearest_point geometry;
                    v_inside_point geometry;
                    v_probe geometry;
                    v_length double precision := ST_3DLength(v_plan_segment);
                    v_dx double precision := ST_X(v_last) - ST_X(v_first);
                    v_dy double precision := ST_Y(v_last) - ST_Y(v_first);
                    v_dz double precision := ST_Z(v_last) - ST_Z(v_first);
                    -- t=0为计划航段首点，t=1为末点；inside/outside分别维护范围内、范围外的搜索端点。
                    v_nearest_t double precision := 0;
                    v_inside_t double precision;
                    v_outside_t double precision;
                    v_middle_t double precision;
                    v_side integer;
                    v_iteration integer;
                BEGIN
                    -- 粗筛包含边界，此处排除最短距离>=R的航段对；仅相切或整段贴着R边界都不产生冲突。
                    IF v_nearest_line IS NULL OR ST_3DLength(v_nearest_line) >= v_limit THEN
                        CONTINUE;
                    END IF;
                    -- 通过严格距离检查后再确认该航线对冲突，并记录本航段对的进入/离开点对。
                    v_has_conflict := true;
                    -- 最短线起点位于计划航段，终点位于对方航段；起点是距离严格<R的已知内点。
                    v_nearest_point := ST_StartPoint(v_nearest_line);
                    IF v_length > 0 THEN
                        -- 用三维长度比例得到最近点在线段上的参数t，限定到[0,1]以消除微小计算越界。
                        v_nearest_t := greatest(0::double precision, least(1::double precision,
                            ST_3DDistance(v_first, v_nearest_point) / v_length));
                    END IF;
                    -- 零长度航段保留t=0，避免除零；两侧都返回同一个位置。
                    FOR v_side IN 1..2 LOOP
                        -- 第一侧求进入位置，第二侧求离开位置；端点本身在R内时直接保留该端点。
                        v_probe := CASE WHEN v_side = 1 THEN v_first ELSE v_last END;
                        IF ST_3DDistance(v_probe, v_conflict_segment) >= v_limit THEN
                            -- 当前端点位于范围外或边界上，以它为外点、最近点为内点建立搜索区间。
                            v_inside_t := v_nearest_t;
                            v_outside_t := CASE WHEN v_side = 1 THEN 0 ELSE 1 END;
                            v_inside_point := v_nearest_point;
                            FOR v_iteration IN 1..64 LOOP
                                EXIT WHEN abs(v_inside_t - v_outside_t) * v_length <= 0.00000001;
                                v_middle_t := (v_inside_t + v_outside_t) / 2;
                                -- 沿计划航段的XYZ方向向量插值，保证倾斜和垂直航段也按三维位置求解。
                                v_probe := ST_Translate(v_first, v_dx * v_middle_t, v_dy * v_middle_t, v_dz * v_middle_t);
                                -- 只有严格<R的探测点才更新内点，距离等于R时更新外点。
                                IF ST_3DDistance(v_probe, v_conflict_segment) < v_limit THEN
                                    v_inside_t := v_middle_t;
                                    v_inside_point := v_probe;
                                ELSE
                                    v_outside_t := v_middle_t;
                                END IF;
                            END LOOP;
                            -- 返回仍满足<R的内侧近似点，而不是最后一次可能位于外侧的探测点。
                            v_probe := v_inside_point;
                        END IF;
                        -- 为当前进入/离开位置重新求对方最近点；同一航段对按开始、结束顺序连续追加两条短线。
                        v_boundaries := array_append(v_boundaries,
                            ST_3DShortestLine(v_probe, v_conflict_segment));
                    END LOOP;
                END;
                EXIT;
            END LOOP;
            EXIT WHEN v_has_conflict;
        END LOOP;
        -- 候选航线对若只有边界接触，所有航段都会被严格判定排除，此时整对不计入冲突。
        IF NOT v_has_conflict THEN
            CONTINUE;
        END IF;

        -- 每两条短线为同一航段对的开始、结束；保持航段与端点的原有顺序。
        -- 所有点对直接聚合为一个数组，不再按航段对嵌套分组；无明细时返回[]。
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   -- 两端点各自转回WGS84 PointZ；坐标最多9位小数，距离仍来自转换前的米制短线。
                   'plan_point', ST_AsGeoJSON(ST_Transform(ST_StartPoint(s.line), v_projection, 4326), 9, 0)::jsonb,
                   'conflict_point', ST_AsGeoJSON(ST_Transform(ST_EndPoint(s.line), v_projection, 4326), 9, 0)::jsonb,
                   -- 近零距离显示为0只影响返回值，航段是否冲突已在前面的严格<R判断中确定。
                   'distance_m', CASE WHEN ST_3DLength(s.line) <= 0.0000001 THEN 0::double precision
                                      ELSE ST_3DLength(s.line) END
               ) ORDER BY s.ord), '[]'::jsonb)
        INTO v_points
        FROM unnest(v_boundaries) WITH ORDINALITY s(line, ord);

        -- 每条航线对只生成一条冲突记录，附双方原始route及本航段对的进入/离开点。
        v_conflict_item := jsonb_build_object(
            'route_type', CASE WHEN v_pair.kind = 'plan_conflicts' THEN '计划航线冲突' ELSE '在飞航线冲突' END,
            'plan_uav_id', v_pair.plan_input->'uav_id',
            'plan_route', v_pair.plan_input->'route',
            'conflict_uav_id', v_pair.conflict_input->'uav_id',
            'conflict_route', v_pair.conflict_input->'route',
            'points', v_points
        );
        IF v_pair.kind = 'plan_conflicts' THEN
            v_plan_items := array_append(v_plan_items, v_conflict_item);
        ELSE
            v_realtime_items := array_append(v_realtime_items, v_conflict_item);
        END IF;
    END LOOP;
    -- 三、按航线对汇总两类结果；空的PL/pgSQL数组转换为[]，冲突数量不按points的个数统计。
    v_result := jsonb_build_object('plan_conflicts', to_jsonb(v_plan_items),
                                  'realtime_conflicts', to_jsonb(v_realtime_items));
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

    -- 汇总两类冲突中的双方机库ID，去重并按文本排序，避免同一机库参与多对冲突时在msg中反复出现。
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

    -- 发现冲突仍表示校验执行完成，所以code=200、ischeck=false，详细数量与机库写入msg。
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
        -- 兜底处理入口日志、投影、距离计算及结果组装等外层异常，不把执行失败当作无冲突。
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
IS '一键起飞三维航线冲突检查：以中心线三维距离<R判断冲突，不含边界，R=0时不判冲突，points返回命中航段对的进入/离开点';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 计划机库A/B的规划段交叉，并与在飞机库C的海拔航线交叉。
-- 计划原航点相对机库100米，机库所在地面海拔50米、距地高度0米，换算后规划段海拔150米。
-- 末航点相对机库100米高于配置返航80米，因此实际返航海拔同为150米。
-- 缓冲半径R=5米，中心线距离<5米属于冲突，等于5米不冲突；R=0时不判冲突。
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
--         "route": {"type":"LineString","coordinates":[[116.00,36.00,100],[116.02,36.00,100]]} -- 原始航线；Z为相对机库高度
--       },
--       {
--         "uav_id": "B",                                      -- 机库ID
--         "uav_location": {"type":"Point","coordinates":[116.01,35.99,50]}, -- 机库位置；经度、纬度、地面海拔
--         "ground_height": 0,                                  -- 机库相对地面高度，单位米
--         "safe_height": 60,                                    -- 安全起飞高度，单位米
--         "return_height": 80,                                 -- 返航高度，单位米
--         "flight_mode": 2,                                    -- 1=垂直爬升，2=倾斜爬升
--         "route": {"type":"LineString","coordinates":[[116.01,35.99,100],[116.01,36.01,100]]} -- 原始航线；Z为相对机库高度
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
--         "route": {"type":"LineString","coordinates":[[116.015,35.99,100],[116.015,36.01,100]]} -- 原始航线；Z为相对机库高度
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
-- 下面展开两个jsonb冲突字段，每条冲突的points包含该航段对进入/离开R范围的点对。
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
--       "points": [{"plan_point": {...}, "conflict_point": {...}, "distance_m": 0.0}]  -- 进入/离开R范围的最近点对
--     }
--   ],
--   "realtime_conflicts": [                                   -- 计划与在飞冲突集合
--     {
--       "route_type": "在飞航线冲突",                         -- 冲突类型
--       "plan_uav_id": "A",                                   -- 计划航线机库ID
--       "conflict_uav_id": "C",                               -- 相交在飞航线机库ID
--       "plan_route": "原始计划GeoJSON",                      -- 计划航线原始GeoJSON
--       "conflict_route": "原始在飞GeoJSON",                  -- 相交在飞航线原始GeoJSON
--       "points": [{"plan_point": {...}, "conflict_point": {...}, "distance_m": 0.0}]  -- 进入/离开R范围的最近点对
--     }
--   ]
-- }
