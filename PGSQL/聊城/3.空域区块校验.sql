-- =============================================================================
-- 3.空域区块校验.sql
-- 空域区块校验规则说明
--
--   （1）航线空域区块命中校验
--   函数：public.gis_flight_route_airspace
--   作用：根据任务航线判断是否经过指定项目下启用、未删除且final_geom不为空的空域区块。
--   规则：
--   A、项目ID不能为空，只校验该项目下的空域区块。
--   B、航线GeoJSON不能为空，geometry必须为LineString或MultiLineString。
--   C、空间命中只使用二维几何判断；航线和空域区块的Z值不参与命中判断。
--   D、命中任意空域区块时ischeck=true；未命中时ischeck=false。
--   返回：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息，包含命中结果或错误原因
--   ischeck       是否命中空域区块，true=命中，false=未命中
--   hit_count     命中的空域区块数量
--   hit_blockids  命中的空域区块ID数组
--
--   （2）任务航线用空计划校验
--   函数：public.gis_flight_task_airspace
--   作用：校验任务航线是否满足空域区块、用空计划、用空时间和高度限制，返回任务是否可执行。
--   规则：
--   A、先调用gis_flight_route_airspace判断任务航线经过哪些空域区块。
--   B、未经过空域区块时任务不可执行。
--   C、经过空域区块时，进入下一步，判断plan_status是否为true。
--   D、plan_status=false表示空域不可用，任务不可执行。
--   E、plan_status=true表示空域可用，进入下一步，判断任务用空时间段是否完整落在空域计划时间段内。
--   F、任务用空时间段未完整落在空域计划时间段内时任务不可执行。
--   G、任务用空时间段完整在计划时间段内，进入下一步，判断传入的航线高度参数。
--   H、传入的航线高度不在空域最低/最高高度范围内时任务不可执行。
--   I、传入的航线高度在空域最低/最高高度范围内时，进入下一步，判断航点高度是否在空域最低/最高高度范围内。
--   J、航点高度不在空域最低/最高高度范围内时任务不可执行。
--   K、航点高度在空域最低/最高高度范围内时，任务可以执行。
--   返回：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息，包含可执行结果或不可执行原因
--   ischeck       任务是否可执行，true=可执行，false=不可执行
--   hit_count     命中的空域区块数量
--   hit_blockids  命中的空域区块ID数组
--
--   （3）任务航线空域范围和高度校验
--   函数：public.gis_flight_airspace_check
--   作用：校验任务航线所有航点是否全部在空域区块范围内，并检查航线高度和航点高度是否超过空域高度。
--   规则：
--   A、项目ID不能为空，只校验该项目下未删除且final_geom不为空的空域区块。
--   B、航线GeoJSON不能为空，geometry必须为LineString或MultiLineString，航点坐标必须包含Z值。
--   C、p_only_enabled=false时不判断发布/启用状态；p_only_enabled=true时只校验已启用/已发布空域。
--   D、所有航点必须落在空域区块final_geom范围内；任一航点不在范围内时ischeck=false。
--   E、航线高度p_route_height和航点Z高度均不能超过覆盖航点的空域区块airspace_height。
--   F、范围和高度全部通过时ischeck=true；否则ischeck=false，调用方应阻断提交。
--   返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果或错误原因
--   ischeck    是否通过空域范围和高度校验，true=通过，false=不通过
--   check_type 校验结果类型：ln_within=范围内 height_over=高度超限 ln_outside=范围外
--   zone_type  区域类型：可飞空域
--   hit_count  命中的空域区块数量
--
-- 依赖说明：
--   1. PostGIS 空间扩展。
--   2. public.gis_geojson_to_geom(text) GeoJSON解析函数。
--   3. public.gis_write_error_log(integer, text, text) 错误日志函数。
--   4. public.bo_airspace_block 空域区块表。
--   5. public.bo_airspace_plan 用空计划表。
-- =============================================================================

-- =============================================================================
-- 函数名称：1.gis_flight_route_airspace
-- 函数功能：校验航线是否命中空域区块
-- 函数描述：
--   1. 校验项目ID和航线GeoJSON是否为空。
--   2. 解析航线GeoJSON，并校验geometry必须为LineString或MultiLineString。
--   3. 将航线和空域区块final_geom转为二维WGS84几何。
--   4. 查询指定项目下启用、未删除且final_geom不为空的空域区块。
--   5. 使用ST_Intersects判断航线是否命中空域区块。
--   6. 返回命中状态、命中数量和命中的空域区块ID数组。
-- 入参说明：
--   p_project_id      项目ID。
--   p_route_geojson   航线GeoJSON，geometry必须为LineString或MultiLineString。
-- 返回说明：
--   返回code、msg、ischeck、hit_count、hit_blockids。
-- 注意事项：
--   1. 本函数只判断空间命中，不判断用空计划、时间段或高度。
--   2. Z值会被ST_Force2D去掉，命中判断只按平面范围执行。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_airspace');

-- =============================================================================
-- 函数介绍：1.gis_flight_route_airspace
-- 主要作用：返回任务航线在指定项目下命中的空域区块ID列表。
-- 入参说明：
--   p_project_id      项目ID；varchar；必填；只检查该项目下启用且未删除的空域区块。
--   p_route_geojson   航线GeoJSON字符串；text；必填；支持Feature/geometry格式，geometry必须为LineString或MultiLineString。
-- 入参校验：
--   1. p_project_id不能为空。
--   2. p_route_geojson不能为空，且必须能通过public.gis_geojson_to_geom解析为有效几何。
--   3. 解析后的geometry必须为LineString或MultiLineString。
-- 返回说明：
--   code             integer；200=执行成功，400=参数错误或无可校验空域区块数据，500=执行异常。
--   msg              text；返回命中结果、参数错误、无数据或异常信息；该函数msg包含执行耗时。
--   ischeck          boolean；true=航线命中至少一个空域区块，false=未命中、参数错误或执行异常。
--   hit_count        integer；命中的空域区块数量；未命中、参数错误或异常时为0。
--   hit_blockids     text[]；命中的空域区块ID数组；未命中、参数错误或异常时为空数组。
-- 注意事项：
--   1. 本函数只做空间命中校验，不校验用空计划、任务时间段或高度。
--   2. 空间命中使用二维几何判断，航线和空域区块的Z值不参与ST_Intersects。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_route_airspace(
    p_project_id varchar,
    p_route_geojson text
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    hit_count integer,
    hit_blockids text[]
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_route_geom geometry;
    v_route_type text;
    v_scope_count integer;
    v_elapsed numeric;
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_route_airspace(%L, %L);',
        p_project_id, p_route_geojson);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    BEGIN
        v_route_geom := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END;

    IF v_route_geom IS NULL OR ST_IsEmpty(v_route_geom) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    v_route_geom := ST_SetSRID(ST_MakeValid(ST_Force2D(v_route_geom)), 4326);
    v_route_type := GeometryType(v_route_geom);

    IF v_route_type NOT IN ('LINESTRING', 'MULTILINESTRING') THEN
        v_msg := format('参数错误：航线geometry必须为LineString或MultiLineString，当前为%s，执行时间 %s 秒',
            COALESCE(v_route_type, 'NULL'),
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    SELECT count(*)::integer
    INTO v_scope_count
    FROM public.bo_airspace_block b
    WHERE b.del_flag = false
      AND b.use_enabled = true
      AND b.final_geom IS NOT NULL
      AND b.project_id = btrim(p_project_id);

    IF v_scope_count = 0 THEN
        v_msg := format('无可校验空域区块数据，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    SELECT
        count(*)::integer,
        COALESCE(array_agg(hit.id::text ORDER BY hit.id), ARRAY[]::text[])
    INTO hit_count, hit_blockids
    FROM (
        SELECT DISTINCT b.id
        FROM public.bo_airspace_block b
        WHERE b.del_flag = false
          AND b.use_enabled = true
          AND b.final_geom IS NOT NULL
          AND b.project_id = btrim(p_project_id)
          AND ST_Intersects(
              v_route_geom,
              ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326)
          )
    ) hit;

    ischeck := hit_count > 0;
    code := 200;
    v_elapsed := round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);

    IF ischeck THEN
        msg := format('航线命中空域区块%s个，执行时间 %s 秒', hit_count, v_elapsed);
    ELSE
        msg := format('航线未命中空域区块，执行时间 %s 秒', v_elapsed);
    END IF;

    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('航线空域区块校验执行异常：%s，执行时间 %s 秒',
        SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[];
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_airspace(varchar, text)
IS '校验航线是否命中空域区块';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 使用给定空域区块边界附近的三维航线，验证航线是否命中空域区块。
-- SELECT * FROM public.gis_flight_route_airspace(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{"name":"聊城测试航线-01"},"geometry":{"type":"LineString","coordinates":[[116.094985998182,36.4932144812562,20],[116.090938528597,36.4759344898339,23],[116.079014084674,36.4612198448471,20],[116.061030283079,36.4513087910904,24],[116.0397231281,36.4477081819969,24]]}}'
-- );

-- =============================================================================
-- 函数名称：2.gis_flight_task_airspace
-- 函数功能：校验任务航线用空是否可执行
-- 函数描述：
--   1. 基础参数校验：项目、任务、航线GeoJSON、航点Z值、航线高度、日期、时间段。
--   2. 解析用空日期和任务时间段。
--   A. 先调用gis_flight_route_airspace判断任务航线经过哪些空域区块。
--   B. 未经过空域区块时任务不可执行。
--   C. 经过空域区块时，判断plan_status是否为true。
--   D. plan_status=false表示空域不可用，任务不可执行。
--   E. plan_status=true表示空域可用，再判断任务用空时间段是否完整落在空域计划时间段内。
--   F. 任务用空时间段未完整落在空域计划时间段内时任务不可执行。
--   G. 空域范围和高度由gis_flight_airspace_check统一校验。
--   H. 空域范围、高度、计划状态和时间段均通过时，任务可以执行。
-- 入参说明：
--   p_project_id       项目ID。
--   p_task_id          任务ID。
--   p_route_geojson    航线GeoJSON，geometry必须为LineString或MultiLineString，航点坐标必须包含Z值。
--   p_route_height     航线高度参数，单位：米。
--   p_use_date         用空日期，格式yyyy-MM-dd。
--   p_task_time_plan   任务用空时间段JSON数组。
-- 返回说明：
--   返回code、msg、ischeck、hit_count、hit_blockids。
-- 注意事项：
--   1. plan_status=true表示空域可用，plan_status=false表示空域不可用。
--   2. 本函数先调用gis_flight_airspace_check做空域范围和高度阻断校验，再校验空域状态和时间段。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_task_airspace');

-- =============================================================================
-- 函数介绍：2.gis_flight_task_airspace
-- 主要作用：按空域命中、空域可用状态、用空时间段、航线高度和航点高度判断任务是否可执行。
-- 入参说明：
--   p_project_id       项目ID；varchar；必填；只检查该项目下启用且未删除的空域区块。
--   p_task_id          任务ID；varchar；必填；用于返回msg中标识当前任务。
--   p_route_geojson    航线GeoJSON字符串；text；必填；geometry必须为LineString或MultiLineString，航点坐标必须包含Z值。
--   p_route_height     航线高度参数；double precision；必填且不能小于0；单位：米；用于和空域区块最低/最高高度比较。
--   p_use_date         用空日期字符串；varchar；必填；格式yyyy-MM-dd；用于匹配bo_airspace_plan.use_date。
--   p_task_time_plan   任务用空时间段JSON数组字符串；text；必填；格式如[{"startTime":"15:00:00","endTime":"16:00:00"}]。
-- 入参校验：
--   1. 项目ID、任务ID、航线GeoJSON、航线高度、用空日期和任务用空时间段均不能为空。
--   2. 航线高度p_route_height不能小于0。
--   3. p_use_date必须能转换为date，格式建议为yyyy-MM-dd。
--   4. p_task_time_plan必须为非空JSON数组，每个元素必须包含startTime和endTime，且能转换为time。
--   5. p_route_geojson必须能解析为有效几何，并且航点坐标必须包含Z值；geometry类型由gis_flight_route_airspace校验。
-- 返回说明：
--   code               integer；200=执行成功，400=参数错误/无可校验数据，500=执行异常。
--   msg                text；返回参数错误、不可执行原因或可执行结果；任务函数msg不返回执行耗时。
--   ischeck            boolean；true=任务可执行，false=任务不可执行、参数错误或执行异常。
--   hit_count          integer；命中的空域区块数量；未经过空域区块时为0。
--   hit_blockids       text[]；命中的空域区块ID数组；未经过空域区块或参数错误时为空数组。
-- msg业务结果说明：
--   1. 未经过空域区块：任务{task_id}未经过空域区块，不可执行。
--   2. 无用空计划：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}无用空计划。
--   3. 空域不可用：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}空域不可用。
--   4. 时间段超出计划：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}任务时间段{startTime}-{endTime}超出用空计划时间段。
--   5. 空域/高度不通过：直接返回gis_flight_airspace_check的阻断原因。
--   6. 全部通过：任务{task_id}经过空域区块{hit_count}个，空域范围、高度、用空计划和时间段校验通过，可执行。
-- 注意事项：
--   1. plan_status=true表示空域可用；plan_status=false表示空域不可用。
--   2. 只有plan_status=true时才继续校验任务时间段。
--   3. 航点高度取p_route_geojson中所有航点Z值；没有Z值按参数错误处理。
--   4. 可飞空域范围和高度上限由gis_flight_airspace_check统一处理。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_task_airspace(
    p_project_id varchar,
    p_task_id varchar,
    p_route_geojson text,
    p_route_height double precision,
    p_use_date varchar,
    p_task_time_plan text
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    hit_count integer,
    hit_blockids text[]
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_log_sql text;
    v_airspace_check record;
    v_route_check record;
    v_route_geom geometry;
    v_route_point_max_height double precision;
    v_use_date date;
    v_task_time_plan jsonb;
    v_error_msgs text[];
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_task_airspace(%L, %L, %L, %L, %L, %L);',
        p_project_id, p_task_id, p_route_geojson, p_route_height, p_use_date, p_task_time_plan);

    -- 一、基础参数校验。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := '参数错误：项目ID不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_task_id IS NULL OR btrim(p_task_id) = '' THEN
        v_msg := '参数错误：任务ID不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_route_height IS NULL OR p_route_height < 0 THEN
        v_msg := '参数错误：航线高度不能为空且不能小于0';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_use_date IS NULL OR btrim(p_use_date) = '' THEN
        v_msg := '参数错误：用空日期不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_task_time_plan IS NULL OR btrim(p_task_time_plan) = '' THEN
        v_msg := '参数错误：任务用空时间段不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    -- 二、日期、任务时间段和航点Z值解析。
    BEGIN
        v_use_date := btrim(p_use_date)::date;
    EXCEPTION WHEN OTHERS THEN
        v_msg := '参数错误：用空日期格式错误，应为yyyy-MM-dd';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END;

    BEGIN
        v_task_time_plan := p_task_time_plan::jsonb;

        IF jsonb_typeof(v_task_time_plan) IS DISTINCT FROM 'array'
           OR jsonb_array_length(v_task_time_plan) = 0 THEN
            RAISE EXCEPTION '任务用空时间段必须为非空JSON数组';
        END IF;

        PERFORM 1
        FROM jsonb_array_elements(v_task_time_plan) AS task_item(item)
        WHERE NULLIF(item ->> 'startTime', '') IS NULL
           OR NULLIF(item ->> 'endTime', '') IS NULL;

        IF FOUND THEN
            RAISE EXCEPTION '任务用空时间段缺少startTime或endTime';
        END IF;

        PERFORM
            NULLIF(item ->> 'startTime', '')::time,
            NULLIF(item ->> 'endTime', '')::time
        FROM jsonb_array_elements(v_task_time_plan) AS task_item(item);
    EXCEPTION WHEN OTHERS THEN
        v_msg := '参数错误：任务用空时间段格式错误，应为[{startTime,endTime}]数组';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END;

    BEGIN
        v_route_geom := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：任务航线GeoJSON解析失败：%s', SQLERRM);
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END;

    SELECT max(ST_Z((dp).geom))
    INTO v_route_point_max_height
    FROM ST_DumpPoints(v_route_geom) AS dp
    WHERE ST_Z((dp).geom) IS NOT NULL;

    IF v_route_point_max_height IS NULL THEN
        v_msg := '参数错误：任务航线GeoJSON必须包含航点高度Z值';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    -- 三、空域范围和高度阻断校验。该步骤统一复用第3个空域区块提交前校验函数。
    SELECT *
    INTO v_airspace_check
    FROM public.gis_flight_airspace_check(p_project_id, p_route_geojson, p_route_height::numeric, true)
    LIMIT 1;

    IF COALESCE(v_airspace_check.code, 500) <> 200
       OR COALESCE(v_airspace_check.ischeck, false) = false THEN
        RETURN QUERY SELECT
            COALESCE(v_airspace_check.code, 500),
            COALESCE(v_airspace_check.msg, '空域区块提交前校验未通过'),
            false,
            COALESCE(v_airspace_check.hit_count, 0)::integer,
            ARRAY[]::text[];
        RETURN;
    END IF;

    -- 四、空间命中区块查询。这里保留区块ID数组，供后续用空计划和时间段校验使用。
    SELECT *
    INTO v_route_check
    FROM public.gis_flight_route_airspace(p_project_id, p_route_geojson)
    LIMIT 1;

    IF COALESCE(v_route_check.code, 500) <> 200 THEN
        RETURN QUERY SELECT
            v_route_check.code,
            v_route_check.msg,
            false,
            COALESCE(v_route_check.hit_count, 0),
            COALESCE(v_route_check.hit_blockids, ARRAY[]::text[]);
        RETURN;
    END IF;

    hit_count := COALESCE(v_route_check.hit_count, 0);
    hit_blockids := COALESCE(v_route_check.hit_blockids, ARRAY[]::text[]);

    IF hit_count = 0 THEN
        v_msg := format('任务%s未经过空域区块，不可执行', p_task_id);
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids;
        RETURN;
    END IF;

    -- 五、对命中的空域区块做用空计划和时间段业务校验：
    -- 1. 用空日期必须存在计划；
    -- 2. plan_status必须为true，false表示空域不可用；
    -- 3. plan_status=true后，每个任务时间段必须完整落在某个计划时间段内，否则不可执行；
    WITH hit_blocks AS (
        SELECT
            b.id,
            b.airspace_name,
            b.min_height,
            b.airspace_height
        FROM public.bo_airspace_block b
        WHERE b.id = ANY(hit_blockids)
    ),
    task_segments AS (
        SELECT
            row_number() OVER () AS segment_no,
            NULLIF(item ->> 'startTime', '')::time AS start_time,
            NULLIF(item ->> 'endTime', '')::time AS end_time,
            (v_use_date + NULLIF(item ->> 'startTime', '')::time) AS start_ts,
            CASE
                WHEN NULLIF(item ->> 'endTime', '')::time <= NULLIF(item ->> 'startTime', '')::time
                THEN (v_use_date + NULLIF(item ->> 'endTime', '')::time + interval '1 day')
                ELSE (v_use_date + NULLIF(item ->> 'endTime', '')::time)
            END AS end_ts
        FROM jsonb_array_elements(v_task_time_plan) AS task_item(item)
    ),
    block_day_plan AS (
        SELECT
            hb.id AS block_id,
            COALESCE(NULLIF(btrim(hb.airspace_name), ''), hb.id) AS block_name,
            COALESCE(hb.min_height, 0) AS min_height,
            hb.airspace_height,
            v_use_date AS use_date,
            p.plan_status,
            p.time_plan
        FROM hit_blocks hb
        LEFT JOIN public.bo_airspace_plan p
            ON p.block_id = hb.id
           AND p.use_date = v_use_date
           AND p.del_flag = false
    ),
    plan_segments AS (
        SELECT
            bdp.block_id,
            bdp.block_name,
            bdp.min_height,
            bdp.airspace_height,
            bdp.use_date,
            bdp.plan_status,
            bdp.time_plan,
            seg.start_time AS plan_start_time,
            seg.end_time AS plan_end_time,
            (bdp.use_date + seg.start_time) AS plan_start_ts,
            CASE
                WHEN seg.end_time <= seg.start_time
                THEN (bdp.use_date + seg.end_time + interval '1 day')
                ELSE (bdp.use_date + seg.end_time)
            END AS plan_end_ts
        FROM block_day_plan bdp
        LEFT JOIN LATERAL (
            SELECT
                NULLIF(item ->> 'startTime', '')::time AS start_time,
                NULLIF(item ->> 'endTime', '')::time AS end_time
            FROM jsonb_array_elements(
                CASE
                    WHEN btrim(COALESCE(bdp.time_plan, '')) ~ '^\s*\['
                    THEN bdp.time_plan::jsonb
                    ELSE '[]'::jsonb
                END
            ) AS plan_item(item)
        ) seg ON true
    ),
    block_time_check AS (
        SELECT
            bdp.block_id,
            NOT EXISTS (
                SELECT 1
                FROM task_segments ts
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM plan_segments ps
                    WHERE ps.block_id = bdp.block_id
                      AND ps.use_date = bdp.use_date
                      AND ps.plan_start_ts IS NOT NULL
                      AND ps.plan_end_ts IS NOT NULL
                      AND ts.start_ts >= ps.plan_start_ts
                      AND ts.end_ts <= ps.plan_end_ts
                )
            ) AS is_time_valid
        FROM block_day_plan bdp
        WHERE bdp.plan_status = true
    ),
    invalid_reasons AS (
        SELECT DISTINCT
            block_id,
            block_name,
            format('%s无用空计划', to_char(use_date, 'YYYY-MM-DD')) AS reason
        FROM block_day_plan
        WHERE plan_status IS NULL

        UNION ALL

        SELECT DISTINCT
            block_id,
            block_name,
            format('%s空域不可用', to_char(use_date, 'YYYY-MM-DD')) AS reason
        FROM block_day_plan
        WHERE plan_status = false

        UNION ALL

        SELECT DISTINCT
            bdp.block_id,
            bdp.block_name,
            format('%s任务时间段%s-%s超出用空计划时间段',
                to_char(bdp.use_date, 'YYYY-MM-DD'),
                to_char(ts.start_time, 'HH24:MI:SS'),
                to_char(ts.end_time, 'HH24:MI:SS')) AS reason
        FROM block_day_plan bdp
        CROSS JOIN task_segments ts
        JOIN block_time_check btc
            ON btc.block_id = bdp.block_id
        WHERE bdp.plan_status = true
          AND btc.is_time_valid = false
          AND NOT EXISTS (
              SELECT 1
              FROM plan_segments ps
              WHERE ps.block_id = bdp.block_id
                AND ps.use_date = bdp.use_date
                AND ps.plan_start_ts IS NOT NULL
                AND ps.plan_end_ts IS NOT NULL
                AND ts.start_ts >= ps.plan_start_ts
                AND ts.end_ts <= ps.plan_end_ts
          )

    ),
    invalid_blocks AS (
        SELECT
            block_id,
            block_name,
            string_agg(reason, '；' ORDER BY reason) AS reason
        FROM invalid_reasons
        GROUP BY block_id, block_name
    )
    SELECT COALESCE(array_agg(format('%s(%s)：%s', block_name, block_id, reason) ORDER BY block_id), ARRAY[]::text[])
    INTO v_error_msgs
    FROM invalid_blocks;

    IF COALESCE(array_length(v_error_msgs, 1), 0) > 0 THEN
        v_msg := format('任务%s不可执行：%s',
            p_task_id, array_to_string(v_error_msgs, '；'));
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids;
    ELSE
        v_msg := format('任务%s经过空域区块%s个，空域范围、高度、用空计划和时间段校验通过，可执行',
            p_task_id, hit_count);
        RETURN QUERY SELECT 200, v_msg, true, hit_count, hit_blockids;
    END IF;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('任务航线用空校验执行异常：%s', SQLERRM);
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[];
END;
$$;

COMMENT ON FUNCTION public.gis_flight_task_airspace(varchar, varchar, text, double precision, varchar, text)
IS '校验任务航线用空是否可执行';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 使用给定空域区块范围内的航线，校验指定高度、日期和用空时间段是否可执行。
-- 航线高度参数为120米，任务时间段为当天15:00至17:00。
-- SELECT * FROM public.gis_flight_task_airspace(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     'TASK-002',
--     '{"type":"Feature","properties":{"name":"聊城测试任务-02"},"geometry":{"type":"LineString","coordinates":[[116.050595925683,36.4486612526228,24],[116.028829029087,36.4484861336817,23],[116.007677862129,36.529997795765,23],[115.984306922738,36.5011170452416,19]]}}',
--     120,
--     '2026-10-12',
--     '[{"startTime":"15:00:00","endTime":"16:00:00"},{"startTime":"16:00:00","endTime":"17:00:00"}]'
-- );

-- =============================================================================
-- 函数名称：3.gis_flight_airspace_check
-- 函数功能：空域区块提交前校验
-- 函数描述：
--   1. 接收项目ID、任务航线GeoJSON和航线高度。
--   2. 按bo_airspace_block.final_geom判断所有航点是否在可飞空域内。
--   3. 按bo_airspace_block.airspace_height检查航线高度和航点Z高度是否超高。
--   4. 任一航点不在空域内，或任一高度超过空域高度，均校验不通过，调用方应阻断提交。
-- 参数说明：
--   p_project_id       项目ID；只检查该项目下未删除的空域区块。
--   p_route_geojson    航线GeoJSON，支持LineString/MultiLineString/Feature。
--   p_route_height     航线高度，单位米。
--   p_only_enabled     是否只检查已启用/已发布空域；默认false。
-- 返回说明：返回code、msg、ischeck、check_type、zone_type、hit_count。
-- 注意事项：ischeck=true表示通过校验；ischeck=false表示调用方应阻断提交。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_airspace_check');

-- =============================================================================
-- 函数介绍：3.gis_flight_airspace_check
-- 主要作用：校验任务航线所有航点是否均在可飞空域内，且飞行高度不超过空域高度。
-- 返回说明：
--   check_type = ln_within       航点全部在可飞空域内且高度通过。
--   check_type = ln_outside      存在航点不在可飞空域范围内。
--   check_type = height_over     航线高度或航点高度超过可飞空域高度。
--   zone_type  = 可飞空域
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_airspace_check(
    p_project_id text,
    p_route_geojson text,
    p_route_height numeric,
    p_only_enabled boolean DEFAULT false
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    check_type text,
    zone_type text,
    hit_count bigint
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_route geometry;
    v_route_type text;
    v_scope_count bigint := 0;
    v_outside_count bigint := 0;
    v_route_height_over_count bigint := 0;
    v_point_height_over_count bigint := 0;
    v_hit_count bigint := 0;
    v_max_airspace_height numeric;
    v_max_point_height numeric;
    v_check_type text := 'ln_outside';
    v_zone_type text := '可飞空域';
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_airspace_check(%L, %L, %s, %L);',
        p_project_id, p_route_geojson, COALESCE(p_route_height::text, 'NULL'), p_only_enabled);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    IF p_route_height IS NULL OR p_route_height < 0 THEN
        v_msg := format('参数错误：航线高度不能为空且不能小于0，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    IF p_only_enabled IS NULL THEN
        v_msg := format('参数错误：是否只检查启用空域不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    BEGIN
        v_route := ST_SetSRID(public.gis_geojson_to_geom(p_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    v_route_type := ST_GeometryType(v_route);

    IF v_route_type NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持LineString或MultiLineString，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    SELECT count(*)
    INTO v_scope_count
    FROM public.bo_airspace_block b
    WHERE b.del_flag = false
      AND b.final_geom IS NOT NULL
      AND b.project_id = btrim(p_project_id)
      AND (p_only_enabled = false OR b.use_enabled = true);

    IF v_scope_count = 0 THEN
        v_msg := format('无数据：项目下无可校验空域区块，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, v_zone_type, 0::bigint;
        RETURN;
    END IF;

    WITH route_points AS (
        SELECT
            row_number() OVER () AS point_no,
            (dp).geom AS geom,
            ST_Z((dp).geom) AS point_height
        FROM ST_DumpPoints(v_route) AS dp
    ),
    point_airspace AS (
        SELECT
            rp.point_no,
            rp.point_height,
            max(b.airspace_height)::numeric AS max_airspace_height,
            count(DISTINCT b.id)::bigint AS block_count
        FROM route_points rp
        LEFT JOIN public.bo_airspace_block b
            ON b.del_flag = false
           AND b.final_geom IS NOT NULL
           AND b.project_id = btrim(p_project_id)
           AND (p_only_enabled = false OR b.use_enabled = true)
           AND ST_Covers(
               ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326),
               ST_SetSRID(ST_Force2D(rp.geom), 4326)
           )
        GROUP BY rp.point_no, rp.point_height
    ),
    hit_blocks AS (
        SELECT DISTINCT b.id
        FROM route_points rp
        JOIN public.bo_airspace_block b
            ON b.del_flag = false
           AND b.final_geom IS NOT NULL
           AND b.project_id = btrim(p_project_id)
           AND (p_only_enabled = false OR b.use_enabled = true)
           AND ST_Covers(
               ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326),
               ST_SetSRID(ST_Force2D(rp.geom), 4326)
           )
    )
    SELECT
        count(*) FILTER (WHERE block_count = 0)::bigint,
        count(*) FILTER (WHERE block_count > 0 AND p_route_height > COALESCE(max_airspace_height, 0))::bigint,
        count(*) FILTER (
            WHERE block_count > 0
              AND point_height IS NOT NULL
              AND point_height > COALESCE(max_airspace_height, 0)
        )::bigint,
        (SELECT count(*)::bigint FROM hit_blocks),
        max(max_airspace_height),
        max(point_height)::numeric
    INTO
        v_outside_count,
        v_route_height_over_count,
        v_point_height_over_count,
        v_hit_count,
        v_max_airspace_height,
        v_max_point_height
    FROM point_airspace;

    IF v_outside_count > 0 THEN
        v_check_type := 'ln_outside';
        v_msg := format('校验不通过：%s个航点不在可飞空域范围内，阻断提交，执行时间 %s 秒',
            v_outside_count, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, false, v_check_type, v_zone_type, v_hit_count;
        RETURN;
    END IF;

    IF v_route_height_over_count > 0 THEN
        v_check_type := 'height_over';
        v_msg := format('校验不通过：航线高度%s米超过可飞空域高度%s米，阻断提交，执行时间 %s 秒',
            p_route_height,
            COALESCE(v_max_airspace_height, 0),
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, false, v_check_type, v_zone_type, v_hit_count;
        RETURN;
    END IF;

    IF v_point_height_over_count > 0 THEN
        v_check_type := 'height_over';
        v_msg := format('校验不通过：航点最大高度%s米超过可飞空域高度%s米，阻断提交，执行时间 %s 秒',
            COALESCE(v_max_point_height, 0),
            COALESCE(v_max_airspace_height, 0),
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, false, v_check_type, v_zone_type, v_hit_count;
        RETURN;
    END IF;

    v_check_type := 'ln_within';
    RETURN QUERY SELECT
        200,
        format('校验通过：航点全部在可飞空域范围内，航线高度和航点高度未超过可飞空域高度，命中空域区块%s个，执行时间 %s 秒',
            v_hit_count, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::text,
        true,
        v_check_type,
        v_zone_type,
        v_hit_count;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('执行异常：%s，执行时间 %s 秒',
        SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 'ln_outside'::text, v_zone_type, 0::bigint;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_airspace_check(text, text, numeric, boolean)
IS '空域区块提交前校验；航点必须全部在可飞空域内，航线高度和航点高度均不能超过可飞空域高度';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- SELECT code, msg, ischeck, check_type, zone_type, hit_count
-- FROM public.gis_flight_airspace_check(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{"name":"聊城测试任务"},"geometry":{"type":"LineString","coordinates":[[116.050595925683,36.4486612526228,24],[116.028829029087,36.4484861336817,23]]}}',
--     120,
--     false
-- );
