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
--   route_length_km 航线二维长度，单位：千米
--
--   （2）点位空域区块命中校验
--   函数：public.gis_flight_point_airspace
--   作用：根据项目ID和点位GeoJSON判断点位位于哪些启用、未删除的空域区块。
--   规则：
--   A、项目ID不能为空；点位必须为GeoJSON Feature且geometry必须为Point。
--   B、只判断二维范围，落在空域区块边界上的点视为命中。
--   C、命中任意空域区块时ischeck=true；未命中时ischeck=false。
--   返回：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息，包含命中结果或错误原因
--   ischeck       是否命中空域区块
--   hit_count     命中的空域区块数量
--   hit_blockids  命中的空域区块ID数组
--
--   （3）任务航线用空计划校验
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
--   （4）任务航线空域范围和高度校验
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
--   返回code、msg、ischeck、hit_count、hit_blockids、route_length_km。
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
--   route_length_km  double precision；航线二维长度，单位：千米；无效航线或异常时为NULL。
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
    hit_blockids text[],
    route_length_km double precision
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

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_flight_route_airspace', v_log_sql);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::double precision;
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::double precision;
        RETURN;
    END IF;

    BEGIN
        v_route_geom := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::double precision;
        RETURN;
    END;

    IF v_route_geom IS NULL OR ST_IsEmpty(v_route_geom) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::double precision;
        RETURN;
    END IF;

    v_route_geom := ST_SetSRID(ST_MakeValid(ST_Force2D(v_route_geom)), 4326);
    v_route_type := GeometryType(v_route_geom);

    IF v_route_type NOT IN ('LINESTRING', 'MULTILINESTRING') THEN
        v_msg := format('参数错误：航线geometry必须为LineString或MultiLineString，当前为%s，执行时间 %s 秒',
            COALESCE(v_route_type, 'NULL'),
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::double precision;
        RETURN;
    END IF;

    route_length_km := round((ST_Length(v_route_geom::geography) / 1000.0)::numeric, 6)::double precision;

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
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], route_length_km;
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
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[], NULL::double precision;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_airspace(varchar, text)
IS '校验航线是否命中项目内启用的空域区块并返回结果';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 使用给定空域区块边界附近的三维航线，验证航线是否命中空域区块。
-- SELECT * FROM public.gis_flight_route_airspace(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{"name":"聊城测试航线-01"},"geometry":{"type":"LineString","coordinates":[[116.094985998182,36.4932144812562,20],[116.090938528597,36.4759344898339,23],[116.079014084674,36.4612198448471,20],[116.061030283079,36.4513087910904,24],[116.0397231281,36.4477081819969,24]]}}'
-- );

-- =============================================================================
-- 函数名称：2.gis_flight_point_airspace
-- 函数功能：判断指定项目的点位位于哪些空域区块
-- 函数描述：
--   1. 校验项目ID和点位GeoJSON是否为空。
--   2. 解析点位GeoJSON Feature，并校验geometry必须为非空Point。
--   3. 将点位和空域区块final_geom转为二维WGS84几何。
--   4. 查询指定项目下启用、未删除且final_geom不为空的空域区块。
--   5. 使用ST_Covers判断点位是否落在区块范围内，边界点视为命中。
--   6. 返回命中状态、命中数量和命中的空域区块ID数组。
-- 入参说明：
--   p_project_id     项目ID。
--   p_point_geojson  点位GeoJSON Feature，geometry必须为Point。
-- 返回说明：
--   返回code、msg、ischeck、hit_count、hit_blockids。
-- 注意事项：
--   Z值不参与空间命中判断。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_point_airspace');

-- =============================================================================
-- 函数介绍：2.gis_flight_point_airspace
-- 主要作用：返回指定项目下点位命中的空域区块ID列表。
-- 入参说明：
--   p_project_id     项目ID；varchar；必填；只检查该项目下启用且未删除的空域区块。
--   p_point_geojson  点位GeoJSON Feature字符串；text；必填，geometry必须为Point。
-- 入参校验：
--   1. p_project_id不能为空。
--   2. p_point_geojson不能为空，必须为GeoJSON Feature，且能通过public.gis_geojson_to_geom解析为有效Point。
-- 返回说明：
--   code          integer；200=执行成功，400=参数错误或无可校验空域区块数据，500=执行异常。
--   msg           text；返回命中结果、参数错误、无数据或异常信息，包含执行耗时。
--   ischeck       boolean；true=点位命中至少一个空域区块，false=未命中或执行失败。
--   hit_count     integer；命中的空域区块数量，未命中或执行失败时为0。
--   hit_blockids  text[]；命中的空域区块ID数组，未命中或执行失败时为空数组。
-- 注意事项：
--   1. 空间判断使用二维几何，点位Z值不参与命中判断。
--   2. 边界点按命中处理；重叠区块返回所有命中的区块ID。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_point_airspace(
    p_project_id varchar,
    p_point_geojson text
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    hit_count integer,
    hit_blockids text[],
    task_id varchar
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_point_geom geometry;
    v_scope_count integer;
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_point_airspace(%L, %L);',
        p_project_id, p_point_geojson);

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_flight_point_airspace', v_log_sql);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_point_geojson IS NULL OR btrim(p_point_geojson) = '' THEN
        v_msg := format('参数错误：点位GeoJSON不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    BEGIN
        IF p_point_geojson::jsonb->>'type' IS DISTINCT FROM 'Feature'
           OR p_point_geojson::jsonb->'geometry'->>'type' IS DISTINCT FROM 'Point' THEN
            v_msg := format('参数错误：点位GeoJSON必须为Point类型的Feature，执行时间 %s 秒',
                round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
            RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
            RETURN;
        END IF;
        v_point_geom := public.gis_geojson_to_geom(p_point_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：点位GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END;

    IF v_point_geom IS NULL OR ST_IsEmpty(v_point_geom) OR GeometryType(v_point_geom) <> 'POINT' THEN
        v_msg := format('参数错误：点位geometry必须为非空Point，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    v_point_geom := ST_SetSRID(ST_Force2D(v_point_geom), 4326);

    SELECT count(*)::integer INTO v_scope_count
    FROM public.bo_airspace_block b
    WHERE b.del_flag = false
      AND b.use_enabled = true
      AND b.final_geom IS NOT NULL
      AND b.project_id = btrim(p_project_id);

    IF v_scope_count = 0 THEN
        v_msg := format('无可校验空域区块数据，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    SELECT count(*)::integer,
           COALESCE(array_agg(hit.id::text ORDER BY hit.id), ARRAY[]::text[])
    INTO hit_count, hit_blockids
    FROM (
        SELECT DISTINCT b.id
        FROM public.bo_airspace_block b
        WHERE b.del_flag = false
          AND b.use_enabled = true
          AND b.final_geom IS NOT NULL
          AND b.project_id = btrim(p_project_id)
          AND ST_Covers(
              ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326),
              v_point_geom
          )
    ) hit;

    ischeck := hit_count > 0;
    code := 200;
    IF ischeck THEN
        msg := format('点位命中空域区块%s个，执行时间 %s 秒', hit_count,
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    ELSE
        msg := format('点位未命中空域区块，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    END IF;
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('点位空域区块校验执行异常：%s，执行时间 %s 秒',
        SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[];
END;
$$;

COMMENT ON FUNCTION public.gis_flight_point_airspace(varchar, text)
IS '判断项目点位命中的空域区块并返回命中明细结果';

-- SELECT * FROM public.gis_flight_point_airspace(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[116.094985998182,36.4932144812562]}}'
-- );

-- =============================================================================
-- 函数名称：3.gis_flight_task_airspace
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
-- 函数介绍：3.gis_flight_task_airspace
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
    hit_blockids text[],
    task_id varchar
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

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_flight_task_airspace', v_log_sql);

    -- 一、基础参数校验。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := '参数错误：项目ID不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END IF;

    IF p_task_id IS NULL OR btrim(p_task_id) = '' THEN
        v_msg := '参数错误：任务ID不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END IF;

    IF p_route_height IS NULL OR p_route_height < 0 THEN
        v_msg := '参数错误：航线高度不能为空且不能小于0';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END IF;

    IF p_use_date IS NULL OR btrim(p_use_date) = '' THEN
        v_msg := '参数错误：用空日期不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END IF;

    IF p_task_time_plan IS NULL OR btrim(p_task_time_plan) = '' THEN
        v_msg := '参数错误：任务用空时间段不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END IF;

    -- 二、日期、任务时间段和航点Z值解析。
    BEGIN
        v_use_date := btrim(p_use_date)::date;
    EXCEPTION WHEN OTHERS THEN
        v_msg := '参数错误：用空日期格式错误，应为yyyy-MM-dd';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
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
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END;

    BEGIN
        v_route_geom := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：任务航线GeoJSON解析失败：%s', SQLERRM);
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END;

    SELECT max(ST_Z((dp).geom))
    INTO v_route_point_max_height
    FROM ST_DumpPoints(v_route_geom) AS dp
    WHERE ST_Z((dp).geom) IS NOT NULL;

    IF v_route_point_max_height IS NULL THEN
        v_msg := '参数错误：任务航线GeoJSON必须包含航点高度Z值';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
        RETURN;
    END IF;

    -- 三、空域范围和高度阻断校验。该步骤统一复用第4个空域区块提交前校验函数。
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
            ARRAY[]::text[], p_task_id;
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
            COALESCE(v_route_check.hit_blockids, ARRAY[]::text[]),
            p_task_id;
        RETURN;
    END IF;

    hit_count := COALESCE(v_route_check.hit_count, 0);
    hit_blockids := COALESCE(v_route_check.hit_blockids, ARRAY[]::text[]);

    IF hit_count = 0 THEN
        v_msg := format('任务%s未经过空域区块，不可执行', p_task_id);
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids, p_task_id;
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
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids, p_task_id;
    ELSE
        v_msg := format('任务%s经过空域区块%s个，空域范围、高度、用空计划和时间段校验通过，可执行',
            p_task_id, hit_count);
        RETURN QUERY SELECT 200, v_msg, true, hit_count, hit_blockids, p_task_id;
    END IF;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('任务航线用空校验执行异常：%s', SQLERRM);
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_task_airspace(varchar, varchar, text, double precision, varchar, text)
IS '校验任务航线用空计划时间高度及空域可执行状态';

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
-- 函数名称：4.gis_flight_airspace_check
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
-- 函数介绍：4.gis_flight_airspace_check
-- 主要作用：校验任务航线所有航点是否均在可飞空域内，且飞行高度不超过空域高度。
-- 入参说明：
--   p_project_id       项目ID；text；必填；只检查该项目下未删除且final_geom不为空的空域区块。
--   p_route_geojson    航线GeoJSON字符串；text；必填；支持Feature/geometry格式，geometry必须为LineString或MultiLineString，航点坐标必须包含Z值。
--   p_route_height     航线高度；numeric；必填；单位米，不能超过覆盖航点的可飞空域高度。
--   p_only_enabled     是否只校验启用空域；boolean；选填，默认false；true=只检查启用空域，false=检查未删除空域。
-- 入参校验：
--   1. p_project_id不能为空。
--   2. p_route_geojson不能为空，且必须能通过public.gis_geojson_to_geom解析为有效几何。
--   3. 解析后的geometry必须为LineString或MultiLineString。
--   4. 航线坐标必须包含Z值，Z值作为航点高度参与可飞空域高度校验。
--   5. p_route_height不能为空，且必须大于等于0。
-- 返回说明：
--   code             integer；200=执行成功，400=参数错误或无可校验空域区块数据，500=执行异常。
--   msg              text；返回范围/高度校验结果、参数错误、无数据或异常信息；该函数msg包含执行耗时。
--   ischeck          boolean；true=航点全部在可飞空域内且高度通过，false=范围不通过、高度超限、参数错误或执行异常。
--   check_type       text；ln_within=范围和高度通过，ln_outside=存在航点不在可飞空域范围内，height_over=航线高度或航点高度超过可飞空域高度。
--   zone_type        text；固定返回“可飞空域”；本函数仅校验可飞空域范围和高度，不同于函数1、2中的命中区域类型。
--   hit_count        bigint；航点命中的可飞空域区块数量；未命中、参数错误或异常时为0。
-- 注意事项：
--   1. 本函数只校验可飞空域范围和高度，不校验用空计划、任务时间段或空域计划状态。
--   2. 范围判断使用二维几何，航点Z值不参与ST_Covers空间判断，只作为航点高度参与高度校验。
--   3. 任一航点未落入可飞空域，或任一高度超过覆盖该航点的可飞空域高度，ischeck=false，调用方应阻断提交。
--   4. p_only_enabled=true时只校验启用空域；p_only_enabled=false时校验项目下未删除空域。
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

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_flight_airspace_check', v_log_sql);

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
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
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
IS '校验航线范围及航线航点高度是否符合空域限制';

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

-- =============================================================================
-- 函数名称：5.gis_uav_flight_deviation_check
-- 函数功能：飞行任务偏差校验
-- 函数描述：
--   1. 接收项目ID、任务ID、无人机实时遥测信息和校验规则数组。
--   2. 根据项目ID和任务ID读取bo_flight_job中未删除的规划航线。
--   3. 规则1（无人机偏航）：比较当前位置与规划航线的二维最短距离，超过50米判为违规。
--   4. 规则2（无人机超高）：检查遥测距地高度，超过120米判为违规。
--   5. 规则3（闯入管制空域）：检查当前位置是否命中管控围栏，或所在空域是否已进入管制时段。
--      无人机飞入管制范围，以及原可飞时段结束后仍停留在空域内，均判为违规。
--   6. 汇总本次所选规则的违规类型；全部正常时通过校验，任一规则违规时不通过。
-- 参数说明：
--   p_task_id    任务ID，用于定位任务、规划航线、项目空域及项目围栏范围。
--   p_telemetry   无人机实时遥测，包括经纬度、海拔高度、距地高度和遥测时间。
--   p_rules       三位整数校验开关数组，按偏航、超高、闯入管制空域排列；1执行，0跳过，默认ARRAY[1,1,1]。
-- 返回说明：
--   返回code、msg、ischeck、active_rule、datajson。
--   ischeck表示本次校验是否通过，active_rule按偏航、超高、闯入管制空域的位置返回违规标记。
-- 注意事项：
--   持续异常去重、恢复正常后再次告警由调用方结合前后遥测结果处理。
-- =============================================================================

-- =============================================================================
-- 航线规划来源：使用现有public.bo_flight_job表
-- =============================================================================
-- 任务ID使用bo_flight_job.out_id，规划航线使用plan_route_gemo，规划空域使用plan_airspace_block_id。

-- =============================================================================
-- =============================================================================
-- 依赖表脚本（仅注释，不在本文件重复创建）
-- =============================================================================
-- CREATE TABLE public.bo_flight_job (
--     id varchar(32) NOT NULL,
--     out_id varchar(32),
--     name varchar(200),
--     uav_id varchar(32),
--     plan_start_time date,
--     plan_end_time date,
--     plan_route_gemo geometry(GEOMETRY),
--     plan_airspace_block_id varchar(1000),
--     actual_start_time date,
--     actual_end_time date,
--     actual_route_gemo geometry(GEOMETRY),
--     excecute_status int2,
--     feature varchar(4000),
--     create_time timestamp(6) NOT NULL DEFAULT now(),
--     create_user varchar(32),
--     update_time timestamp(6) NOT NULL DEFAULT now(),
--     update_user varchar(32),
--     project_id varchar(64),
--     del_flag boolean NOT NULL DEFAULT false,
--     CONSTRAINT bo_flight_job_pkey PRIMARY KEY (id)
-- );
-- ALTER TABLE public.bo_flight_job OWNER TO zhuoyi;
-- CREATE INDEX idx_out_id ON public.bo_flight_job USING btree (out_id);
-- COMMENT ON COLUMN public.bo_flight_job.id IS '主键';
-- COMMENT ON COLUMN public.bo_flight_job.out_id IS '灵犀平台任务id';
-- COMMENT ON COLUMN public.bo_flight_job.name IS '任务名称';
-- COMMENT ON COLUMN public.bo_flight_job.uav_id IS '飞行器id';
-- COMMENT ON COLUMN public.bo_flight_job.plan_start_time IS '计划开始时间';
-- COMMENT ON COLUMN public.bo_flight_job.plan_end_time IS '计划结束时间';
-- COMMENT ON COLUMN public.bo_flight_job.plan_route_gemo IS '规划航线';
-- COMMENT ON COLUMN public.bo_flight_job.plan_airspace_block_id IS '计划空域id: id1, id2, id3 ......';
-- COMMENT ON COLUMN public.bo_flight_job.actual_start_time IS '实际开始时间';
-- COMMENT ON COLUMN public.bo_flight_job.actual_end_time IS '实际结束时间';
-- COMMENT ON COLUMN public.bo_flight_job.actual_route_gemo IS '实际航线';
-- COMMENT ON COLUMN public.bo_flight_job.excecute_status IS '任务执行状态';
-- COMMENT ON COLUMN public.bo_flight_job.feature IS '扩展字段';
-- COMMENT ON COLUMN public.bo_flight_job.project_id IS '项目id';
-- COMMENT ON COLUMN public.bo_flight_job.del_flag IS '是否删除：t删除；f未删除';
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_uav_flight_deviation_check');

-- =============================================================================
-- 函数介绍：5.gis_uav_flight_deviation_check
-- 主要作用：读取指定项目任务的规划航线，执行偏航、超高和闯入管制空域校验，返回校验结果及遥测信息。
-- 入参说明：
--   p_task_id    任务ID；varchar；必填；与bo_flight_job.out_id匹配，且del_flag=false；项目ID由任务记录取得。
--   p_telemetry   遥测信息；jsonb；必填；必须为JSON对象，包含下列全部遥测字段。
--   p_rules       校验开关；integer[]；选填，默认ARRAY[1,1,1]；固定三位0/1，位置依次对应规则1、2、3。
-- 遥测字段说明：
--   longitude/latitude  WGS84经纬度；数值；必填；范围分别为[-180,180]、[-90,90]。
--   altitude            海拔高度；数值；必填；单位米，必须为有限值，用于围栏高度判断。
--   height              距地高度；数值；必填；单位米，必须为非负有限值，用于超高校验。
--   timeStamp           遥测时间；字符串；必填；格式yyyy-MM-dd HH:mm:ss，按北京时间用于可飞时段判断。
-- 入参校验：
--   1. 项目ID、任务ID不能为空，遥测必须为JSON对象。
--   2. 规则参数必须为长度3的一维整数数组，各元素只能为0或1，不能为NULL。
--   3. 经纬度、海拔高度、距地高度及时间戳必须有效。
--   4. 指定项目下必须存在未删除的规划航线，否则返回400。
--   5. 执行规则1时，航线geom必须为有效、非空且坐标合法的LineString或MultiLineString。
-- 返回说明：
--   code         integer；200=校验完成，400=参数或数据错误，500=执行异常。
--   msg          text；校验结果或错误原因；成功时包含当前违规项数。
--   ischeck      boolean；true=本次所选规则全部正常，false=有违规或执行失败。
--   active_rule  jsonb数组；固定三位0/1，与入参规则位置一一对应；1=该规则正常，0=该规则违规或未执行，返回格式为[1,0,1]。
--                全部正常返回[1,1,1]；执行失败也返回[1,1,1]，必须先检查code。
--   datajson     jsonb；包含project_id、task_id、telemetry的JSON对象。
--                project_id、task_id为去除首尾空白后的项目ID、任务ID；telemetry为原始遥测JSON。
-- 注意事项：
--   1. 偏航距离等于50米、距地高度等于120米时均正常。
--   2. 用空计划按遥测时间转换为北京时间，采用[开始,结束)，支持跨午夜计划。
--   3. 持续异常去重、恢复及乱序过滤由调用方维护；只有code=200才表示校验完成。
--   4. 规划航线按任务ID从bo_flight_job.plan_route_gemo读取，项目ID由bo_flight_job.project_id取得。
--   5. 经过空域数组用于记录规划航线关联关系；实时管制校验仍检查当前位置所在的全部项目空域，避免偏航进入其他空域时漏检。
--   6. 未选择的规则不参与结果汇总，不能将未返回的规则认定为已恢复。
--   7. code=400或500时ischeck=false、active_rule=[1,1,1]，不能据此判断正常或恢复。
--   8. 规则3由每次遥测调用触发，不包含空域时段结束后的后台定时检查。
--   9. ARRAY[1,0,1]仅执行规则1和3；ARRAY[0,1,0]仅执行规则2；ARRAY[0,0,0]不执行安全规则，基础参数及任务航线仍须有效。
-- 依赖说明：PostGIS、bo_flight_job、bo_airspace_block、bo_airspace_plan、gis_flight_route_zone_check及其围栏表。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_uav_flight_deviation_check(
    p_task_id varchar,
    p_telemetry jsonb,
    p_rules integer[] DEFAULT ARRAY[1,1,1]
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    active_rule jsonb,
    datajson jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_task_id varchar := btrim(p_task_id);
    v_project varchar;
    v_lon double precision;
    v_lat double precision;
    v_alt double precision;
    v_height double precision;
    v_point geometry;
    v_route geometry;
    v_distance double precision;
    v_time timestamptz;
    v_local timestamp;

    v_rule integer;
    v_violation_count integer := 0;
    v_rules integer[];
    v_active_rule integer[] := ARRAY[1,1,1];
    v_bad boolean;
    v_intrusion boolean := false;
    v_control record;
    v_control_hit boolean := false;
    v_log_sql text;

BEGIN
    v_log_sql := format('SELECT * FROM public.gis_uav_flight_deviation_check(%L, %L, %L);',
        p_task_id, p_telemetry::text, p_rules::text);

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_uav_flight_deviation_check', v_log_sql);
    -- 完成所有入参校验和规则计算后，统一返回本次结果。
    IF COALESCE(v_task_id, '') = ''
       OR jsonb_typeof(p_telemetry) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '任务ID和遥测对象不能为空';
    END IF;
    IF p_rules IS NULL OR cardinality(p_rules) <> 3
       OR array_ndims(p_rules) IS DISTINCT FROM 1 OR EXISTS (
        SELECT 1 FROM unnest(p_rules) e(item)
        WHERE e.item IS NULL OR e.item NOT IN (0, 1)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规则开关必须为三个整数0或1，如[1,0,1]';
    END IF;
    SELECT COALESCE(array_agg(e.pos::integer ORDER BY e.pos), ARRAY[]::integer[])
    INTO v_rules FROM unnest(p_rules) WITH ORDINALITY e(item, pos)
    WHERE e.item = 1;
    v_lon := (p_telemetry->>'longitude')::double precision;
    v_lat := (p_telemetry->>'latitude')::double precision;
    v_alt := (p_telemetry->>'altitude')::double precision;
    IF v_lon IS NULL OR NOT (v_lon BETWEEN -180 AND 180)
       OR v_lat IS NULL OR NOT (v_lat BETWEEN -90 AND 90)
       OR v_alt IS NULL OR v_alt::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '经纬度或海拔无效，单位必须为度/米';
    END IF;
    v_height := (p_telemetry->>'height')::double precision;
    IF v_height IS NULL OR v_height < 0 OR v_height::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '遥测height距地高度不能为空且必须为非负有限值（米）';
    END IF;
    IF p_telemetry->>'timeStamp' IS NULL OR btrim(p_telemetry->>'timeStamp') = '' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '遥测时间timeStamp不能为空（格式yyyy-MM-dd HH:mm:ss）';
    END IF;
    BEGIN
        v_time := (btrim(p_telemetry->>'timeStamp')::timestamp without time zone)
            AT TIME ZONE 'Asia/Shanghai';
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'timeStamp格式错误，应为yyyy-MM-dd HH:mm:ss';
    END;
    IF NOT isfinite(v_time) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'timeStamp必须为有效时间';
    END IF;
    v_local := v_time AT TIME ZONE 'Asia/Shanghai';
    v_point := ST_SetSRID(ST_MakePoint(v_lon, v_lat, v_alt), 4326);
    SELECT r.project_id, r.plan_route_gemo INTO v_project, v_route
    FROM public.bo_flight_job r
    WHERE r.out_id = v_task_id AND r.del_flag = false;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '指定任务out_id不存在或任务已删除';
    END IF;
    IF 1 = ANY(v_rules) THEN
        IF v_route IS NULL OR ST_IsEmpty(v_route)
           OR GeometryType(v_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
           OR NOT ST_IsValid(v_route) THEN
            RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'bo_flight_job.plan_route_gemo必须为有效且非空的规划航线';
        END IF;
        v_route := ST_SetSRID(ST_Force2D(v_route), 4326);
        IF EXISTS (SELECT 1 FROM ST_DumpPoints(v_route) d
                   WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
                      OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)) THEN
            RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规划航线必须使用WGS84经纬度';
        END IF;
        v_distance := ST_Distance(ST_Force2D(v_point)::geography, v_route::geography);
    END IF;
    IF 3 = ANY(v_rules) THEN
        -- 复用飞行审核脚本中的管控围栏规则，包含项目围栏与全局围栏。
        SELECT * INTO v_control FROM public.gis_flight_route_zone_check(
            v_project, ST_AsGeoJSON(v_point), '2');
        IF v_control.code IS DISTINCT FROM 200 THEN
            RAISE EXCEPTION '管控围栏校验失败：%', v_control.msg;
        END IF;
        v_control_hit := COALESCE(v_control.ischeck, false);
        SELECT v_control_hit OR EXISTS (
            SELECT 1 FROM public.bo_airspace_block b
            WHERE b.project_id = v_project AND b.del_flag = false
              AND b.use_enabled = true AND b.final_geom IS NOT NULL
              AND ST_Covers(ST_SetSRID(ST_Force2D(b.final_geom), 4326), ST_Force2D(v_point))
              AND NOT EXISTS (
                  SELECT 1 FROM public.bo_airspace_plan p
                  CROSS JOIN LATERAL jsonb_array_elements(
                      COALESCE(NULLIF(btrim(p.time_plan), ''), '[]')::jsonb
                  ) s(item)
                  WHERE p.block_id = b.id AND p.del_flag = false AND p.plan_status = true
                    AND p.use_date BETWEEN v_local::date - 1 AND v_local::date
                    AND v_local >= p.use_date + (s.item->>'startTime')::time
                    AND v_local < p.use_date + (s.item->>'endTime')::time
                        + CASE WHEN (s.item->>'endTime')::time <= (s.item->>'startTime')::time
                               THEN interval '1 day' ELSE interval '0 day' END
              )
        ) INTO v_intrusion;
    END IF;

    FOREACH v_rule IN ARRAY v_rules LOOP
        v_bad := CASE v_rule WHEN 1 THEN v_distance > 50 WHEN 2 THEN v_height > 120 ELSE v_intrusion END;
        IF v_bad THEN
            v_active_rule[v_rule] := 0;
            v_violation_count := v_violation_count + 1;
        END IF;
    END LOOP;
    RETURN QUERY SELECT 200, format('校验完成，当前异常%s项', v_violation_count),
        v_violation_count = 0, to_jsonb(v_active_rule),
        jsonb_build_object('project_id', v_project, 'task_id', v_task_id, 'telemetry', p_telemetry);
EXCEPTION
    WHEN data_exception THEN
        PERFORM public.gis_write_error_log(400, 'gis_uav_flight_deviation_check', SQLERRM::text);
        RETURN QUERY SELECT 400, SQLERRM::text, false, '[1,1,1]'::jsonb,
            jsonb_build_object('project_id', v_project, 'task_id', v_task_id, 'telemetry', p_telemetry);
    WHEN OTHERS THEN
        PERFORM public.gis_write_error_log(500, 'gis_uav_flight_deviation_check', SQLERRM::text);
        -- 执行失败时不返回部分校验结果。
        RETURN QUERY SELECT 500, ('实时安全告警校验异常：' || SQLERRM)::text,
            false, '[1,1,1]'::jsonb,
            jsonb_build_object('project_id', v_project, 'task_id', v_task_id, 'telemetry', p_telemetry);
END;
$$;
COMMENT ON FUNCTION public.gis_uav_flight_deviation_check(varchar, jsonb, integer[])
IS '实时校验飞行任务偏航超高和管制空域入侵情况';

-- =============================================================================
-- 入参与返回结果说明
-- =============================================================================
-- 遥测信息字段：
--   longitude   WGS84经度；数值，必填，范围[-180,180]。
--   latitude    WGS84纬度；数值，必填，范围[-90,90]。
--   altitude    海拔高度；数值，必填，单位米。
--   height      距地高度；数值，必填，单位米，非负有限值。
--   timeStamp   遥测时间；必填，字符串格式yyyy-MM-dd HH:mm:ss，按北京时间解析。
-- 返回字段：
--   code         integer；200=校验完成，400=参数或数据错误，500=执行异常。
--   msg          text；校验结果或错误原因。
--   ischeck      boolean；true=本次所选规则全部正常，false=有违规或执行失败。
--   active_rule  jsonb数组；固定三位0/1，位置依次对应偏航、超高、闯入管制空域，返回格式为[1,0,1]。
--                1=该规则正常，0=该规则违规或未执行；例如[1,0,1]表示仅检测到超高违规。
--   datajson     jsonb；项目ID、任务ID及原始遥测信息组成的JSON对象。
-- datajson字段：
--   project_id   项目ID，去除首尾空白。
--   task_id     任务ID，去除首尾空白。
--   telemetry    原样返回传入的遥测JSON。
-- 注意：code=400/500时active_rule=[1,1,1]，不表示正常，调用方须先检查code。
-- 返回示例（返回行表示为JSON）：
-- {"code":200,"msg":"校验完成，当前异常1项","ischeck":false,"active_rule":[0,1,1],
--  "datajson":{"project_id":"项目ID","task_id":"任务ID",
--  "telemetry":{"longitude":116.09,"latitude":36.48,
--               "altitude":160,"height":125,"timeStamp":"2026-10-22 15:30:00"}}}

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 1. 保存规划航线，经过空域ID数组可按航线与项目空域的二维相交关系生成。
-- 规划任务数据由业务写入public.bo_flight_job，此处不重复创建航线表。
-- SELECT 'record-001', 'route-001', 'project-001', 'task-001', '测试规划航线', route.geom,
--        ARRAY(SELECT b.id::text FROM public.bo_airspace_block b
--              WHERE b.project_id = 'project-001' AND b.del_flag = false
--                AND b.use_enabled = true AND b.final_geom IS NOT NULL
--                AND ST_Intersects(ST_Force2D(route.geom), ST_Force2D(b.final_geom))
--              ORDER BY b.id)
-- FROM (SELECT ST_GeomFromText('LINESTRING Z(116.08 36.47 100,116.10 36.49 100)', 4326) AS geom) route;
--
-- 2. 按任务ID、遥测信息和规则开关进行实时校验；项目ID由任务记录自动取得。
-- SELECT * FROM public.gis_uav_flight_deviation_check(
--     'task-001',
--     '{"longitude":116.09,"latitude":36.48,
--       "altitude":160,"height":125,"timeStamp":"2026-10-22 15:30:00"}'::jsonb,
--     ARRAY[1,0,1]
-- );
-- 仅校验超高时最后一个参数传ARRAY[0,1,0]；正常时active_rule返回[1,1,1]。
-- 入参ARRAY[1,0,1]：仅执行偏航、管制校验；若仅偏航违规则active_rule=[0,1,1]。

 

-- =============================================================================
-- 函数名称：6.gis_flight_task_route_check
-- 函数功能：校验输入航线与指定项目下指定任务的规划航线是否存在空间冲突。
-- 函数描述：
--   1. 校验项目 ID、航线 GeoJSON、任务 ID 数组和缓冲半径。
--   2. 通过 public.gis_geojson_to_geom 解析航线，统一转为二维 WGS84（SRID=4326）。
--   3. 仅接受有效的 LineString 或 MultiLineString；Z/M 高程和测量维度不参与判断。
--   4. 按缓冲半径（米）生成输入航线缓冲区；半径为 0 时直接使用原始航线。
--   5. 从 public.bo_flight_job 查询未删除、项目匹配、任务 ID 匹配且规划航线有效的任务。
--   6. 使用 ST_Intersects 判断输入航线缓冲区与任务规划航线是否相交。
-- 入参说明：
--   p_project_id：项目 ID，varchar，必填； 
--   p_route_geojson：待校验航线 GeoJSON，text，必填； 
--   p_task_ids：待校验任务 ID 数组； 
--   p_buffer_radius：缓冲半径 ；
-- 返回说明：
--   返回code、msg、ischeck、task_ids
-- =============================================================================

-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_flight_task_route_check');
-- =============================================================================
-- 函数介绍：6.gis_flight_task_route_check
-- 主要作用：根据项目、待校验航线和任务 ID 集合，判断任务规划航线是否与待校验
--           航线发生空间冲突，并返回冲突任务清单。
--
-- 入参说明：
--   p_project_id：项目 ID，varchar，必填。函数会去除首尾空白，并仅查询该项目
--                 下的任务；NULL 或空字符串直接返回 400。
--   p_route_geojson：待校验航线 GeoJSON，text，必填。由
--                     public.gis_geojson_to_geom 统一解析，可传 Geometry、Feature
--                     或 FeatureCollection；NULL、空字符串或解析失败返回 400。
--   p_task_ids：任务 ID 数组，varchar[]，必填。函数会去除每个元素首尾空白并去重；
--               NULL、空数组、空字符串或包含 NULL 元素时返回 400。
--   p_buffer_radius：航线缓冲半径，double precision，单位为米，默认 50。取值必须
--                    为大于等于 0 的有限数；NaN、Infinity 和 -Infinity 返回 400。
--
-- 入参及空间校验：
--   1. 解析后的航线统一转换为二维 WGS84 几何（SRID=4326），Z/M 维度不参与判断。
--   2. 航线必须为有效且非空的 LineString 或 MultiLineString。
--   3. 缓冲半径为 0 时使用原始航线；大于 0 时使用 geography 生成米制缓冲区。
--   4. 缓冲区生成失败、几何修复失败或其他空间计算异常返回 500/400 结果。
--
-- 数据筛选规则：
--   仅检查 public.bo_flight_job 中 del_flag=false（NULL 按未删除处理）、project_id
--   匹配 p_project_id、out_id 位于 p_task_ids 且 plan_route_gemo 不为空、非空并有效
--   的任务。任务规划航线统一按二维 SRID=4326 几何参与相交判断。
--
-- 冲突判定：
--   使用 ST_Intersects 判断待校验航线缓冲区与任务规划航线是否相交；边界接触也视为
--   相交。命中的任务 ID 会去重并按字典序排序。
--
-- 返回说明（固定返回一行）：
--   code：200 表示校验完成；400 表示参数、GeoJSON 或航线几何不合法；500 表示执行
--         过程发生未预期异常。
--   msg：校验结果或错误详情；发现冲突时包含冲突数量及任务 ID。
--   ischeck：true 表示未发现冲突；false 表示发现至少一条冲突或校验失败。
--   task_ids：冲突任务 ID，以英文逗号分隔；无冲突、参数错误或系统异常时返回空字符串。
--
-- 注意事项：
--   本函数只做二维平面空间相交判断，不比较飞行高度、时间、速度或其他任务属性；
--   p_buffer_radius 的单位为米，输入 GeoJSON 坐标必须使用 WGS84 经纬度坐标。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_task_route_check(
    p_project_id varchar,
    p_route_geojson text,
    p_task_ids varchar[],
    p_buffer_radius double precision DEFAULT 50
)
RETURNS TABLE (code integer, msg text, ischeck boolean, task_ids text)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_route geometry; v_buffer geometry; v_hit_ids text[];
BEGIN
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '项目ID不能为空');
        RETURN QUERY SELECT 400, '参数错误：项目ID不能为空', false, '';
        RETURN;
    END IF;
    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线GeoJSON不能为空');
        RETURN QUERY SELECT 400, '参数错误：航线GeoJSON不能为空', false, '';
        RETURN;
    END IF;
    IF p_task_ids IS NULL OR cardinality(p_task_ids) = 0 THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '任务ID数组不能为空');
        RETURN QUERY SELECT 400, '参数错误：任务ID数组不能为空'::text, false, ''::text;
        RETURN;
    END IF;
    -- 清洗任务 ID，避免空字符串参与 ANY 比较，并去重。
    SELECT array_agg(DISTINCT NULLIF(btrim(v), '') ORDER BY NULLIF(btrim(v), ''))
      INTO p_task_ids
      FROM unnest(p_task_ids) AS x(v);
    IF p_task_ids IS NULL OR cardinality(p_task_ids) = 0
       OR EXISTS (SELECT 1 FROM unnest(p_task_ids) AS x(v) WHERE v IS NULL) THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '任务ID数组不能包含空值');
        RETURN QUERY SELECT 400,'参数错误：任务ID数组不能包含空值'::text,false,''::text; RETURN;
    END IF;
    IF p_buffer_radius IS NULL OR p_buffer_radius < 0
       OR p_buffer_radius IN ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision) THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '缓冲半径必须为非负有限值（米）');
        RETURN QUERY SELECT 400,'参数错误：缓冲半径必须为非负有限值（米）'::text,false,''::text; RETURN;
    END IF;
    BEGIN
        v_route := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线GeoJSON解析失败：' || SQLERRM);
        RETURN QUERY SELECT 400, ('参数错误：航线GeoJSON解析失败：' || SQLERRM), false, '';
        RETURN;
    END;
    v_route:=ST_SetSRID(ST_Force2D(ST_MakeValid(v_route)),4326);
    IF v_route IS NULL OR ST_IsEmpty(v_route)
       OR ST_GeometryType(v_route) NOT IN ('ST_LineString','ST_MultiLineString')
       OR NOT ST_IsValid(v_route) THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线geometry必须为有效的LineString或MultiLineString');
        RETURN QUERY SELECT 400,'参数错误：航线geometry必须为有效的LineString或MultiLineString'::text,false,''::text; RETURN;
    END IF;
    BEGIN
        v_buffer:=CASE WHEN p_buffer_radius=0 THEN v_route ELSE ST_Buffer(v_route::geography,p_buffer_radius)::geometry END;
    EXCEPTION WHEN OTHERS THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线缓冲区生成失败：' || SQLERRM);
        RETURN QUERY SELECT 400,('参数错误：航线缓冲区生成失败：'||SQLERRM)::text,false,''::text; RETURN;
    END;
    SELECT array_agg(DISTINCT g.out_id::text ORDER BY g.out_id::text) INTO v_hit_ids FROM public.bo_flight_job g WHERE COALESCE(g.del_flag,false)=false AND g.project_id=btrim(p_project_id) AND g.out_id::text=ANY(p_task_ids::text[]) AND g.plan_route_gemo IS NOT NULL AND NOT ST_IsEmpty(g.plan_route_gemo) AND ST_IsValid(g.plan_route_gemo) AND ST_Intersects(v_buffer,ST_SetSRID(ST_Force2D(g.plan_route_gemo),4326));
    v_hit_ids:=COALESCE(v_hit_ids,ARRAY[]::text[]);
    IF cardinality(v_hit_ids)=0 THEN RETURN QUERY SELECT 200,'校验完成，未发现相交航线'::text,true,''::text; ELSE RETURN QUERY SELECT 200,format('校验完成，发现%s条相交航线：%s',cardinality(v_hit_ids),array_to_string(v_hit_ids,',')),false,array_to_string(v_hit_ids,','); END IF;
EXCEPTION WHEN OTHERS THEN
    PERFORM public.gis_write_error_log(500, 'gis_flight_task_route_check', '任务航线冲突校验异常：' || SQLERRM);
    RETURN QUERY SELECT 500,('任务航线冲突校验异常：'||SQLERRM)::text,false,''::text;
END; $$;


COMMENT ON FUNCTION public.gis_flight_task_route_check(varchar, text, varchar[], double precision)
IS '按项目、航线GeoJSON和任务ID数组校验任务航线冲突，缓冲半径默认50米';

 
-- =============================================================================
-- 调用示例
-- =============================================================================
-- SELECT code, msg, ischeck, task_ids
-- FROM public.gis_flight_task_route_check(
-- 'project-001', 
-- '{""type"":""LineString"",""coordinates"": [[116.1,36.4],[116.2,36.5]]}', 
-- ARRAY['task-001','task-002']::varchar[],
--  50
--  );
