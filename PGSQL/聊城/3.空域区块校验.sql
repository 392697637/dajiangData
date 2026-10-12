-- =============================================================================
-- 3.空域区块校验.sql
-- 空域区块校验规则说明：
--   （1）航线空域区块命中校验
--   A、根据任务航线判断是否经过启用且未删除的空域区块。
--   B、项目ID不能为空，只检查对应项目的空域区块。
-- 函数见以下：
-- 1.gis_flight_route_airspace        校验航线是否命中空域区块
-- 返回说明：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息
--   ischeck       是否命中空域区块，true=命中，false=未命中
--   hit_count     命中的空域区块数量
--   hit_blockids  命中的空域区块ID数组
--
--   （2）任务航线用空计划校验
--   A、先调用 gis_flight_route_airspace 判断任务航线经过哪些空域区块。
--   B、未经过空域区块时任务可执行。
--   C、经过空域区块时，校验对应日期的用空计划是否存在且可用。
--   D、校验任务用空时间段是否完整落在空域计划时间段内。
--   E、校验任务航线最大高度是否超过空域区块高度。
-- 函数见以下：
-- 2.gis_flight_task_airspace         校验任务航线用空是否可执行
-- 返回说明：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息，包含不可执行原因和执行耗时
--   ischeck       任务是否可执行，true=可执行，false=不可执行
--   hit_count     命中的空域区块数量
--   hit_blockids  命中的空域区块ID数组
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
--   1. 接收项目ID和任务航线GeoJSON。
--   2. 航线必须为LineString或MultiLineString，可带高度坐标。
--   3. 空间校验使用二维航线和空域区块final_geom相交判断。
--   4. 只校验启用、未删除且final_geom不为空的空域区块。
-- 参数说明：
--   p_project_id      项目ID；不能为空，只检查对应项目的空域区块
--   p_route_geojson   航线Feature GeoJSON，geometry为LineString/MultiLineString
-- 返回说明：返回code、msg、ischeck、hit_count、hit_blockids。
-- 注意事项：ischeck=true 表示航线命中空域区块。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_airspace');

-- =============================================================================
-- 函数介绍：1.gis_flight_route_airspace
-- 主要作用：校验航线是否命中空域区块。
-- 入参说明：项目ID、航线GeoJSON。
-- 返回说明：返回执行状态、是否命中、命中数量和命中空域区块ID数组。
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
-- SELECT * FROM public.gis_flight_route_airspace(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.90,36.43,0],[116.02,36.49,0]]}}'
-- );

-- =============================================================================
-- 函数名称：2.gis_flight_task_airspace
-- 函数功能：校验任务航线用空是否可执行
-- 函数描述：
--   1. 接收项目ID、任务ID、任务航线、用空日期和任务用空时间段。
--   2. 先调用gis_flight_route_airspace判断经过哪些空域区块。
--   3. 根据命中的空域区块和用空日期查询bo_airspace_plan。
--   4. 校验计划是否存在、是否可用、任务时间段是否超出计划时间段。
--   5. 提取任务航线最大高度，与空域区块高度比较。
-- 参数说明：
--   p_project_id       项目ID；不能为空，只检查对应项目的空域区块
--   p_task_id          任务ID
--   p_route_geojson    航线Feature GeoJSON，geometry为LineString/MultiLineString
--   p_use_date         用空日期字符串，格式yyyy-MM-dd
--   p_task_time_plan   任务用空时间段JSON数组字符串，如[{"startTime":"15:00:00","endTime":"16:00:00"}]
-- 返回说明：返回code、msg、ischeck、hit_count、hit_blockids。
-- 注意事项：ischeck=true 表示任务可执行；false 表示任务不可执行或参数错误。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_task_airspace');

-- =============================================================================
-- 函数介绍：2.gis_flight_task_airspace
-- 主要作用：校验任务航线用空是否可执行。
-- 入参说明：项目ID、任务ID、航线GeoJSON、用空日期、任务用空时间段数组。
-- 返回说明：返回执行状态、任务是否可执行、命中数量和命中空域区块ID数组。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_task_airspace(
    p_project_id varchar,
    p_task_id varchar,
    p_route_geojson text,
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
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_route_check record;
    v_route_geom geometry;
    v_route_max_height double precision;
    v_use_date date;
    v_task_time_plan jsonb;
    v_error_msgs text[];
    v_elapsed numeric;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_task_airspace(%L, %L, %L, %L, %L);',
        p_project_id, p_task_id, p_route_geojson, p_use_date, p_task_time_plan);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_task_id IS NULL OR btrim(p_task_id) = '' THEN
        v_msg := format('参数错误：任务ID不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_use_date IS NULL OR btrim(p_use_date) = '' THEN
        v_msg := format('参数错误：用空日期不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    IF p_task_time_plan IS NULL OR btrim(p_task_time_plan) = '' THEN
        v_msg := format('参数错误：任务用空时间段不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END IF;

    BEGIN
        v_use_date := btrim(p_use_date)::date;
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：用空日期格式错误，应为yyyy-MM-dd，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
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
        v_msg := format('参数错误：任务用空时间段格式错误，应为[{startTime,endTime}]数组，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[];
        RETURN;
    END;

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
        v_msg := format('任务%s未经过空域区块，可执行，执行时间 %s 秒',
            p_task_id, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, true, hit_count, hit_blockids;
        RETURN;
    END IF;

    BEGIN
        v_route_geom := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：任务航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, hit_count, hit_blockids;
        RETURN;
    END;

    SELECT COALESCE(max(ST_Z((dp).geom)), 0)
    INTO v_route_max_height
    FROM ST_DumpPoints(v_route_geom) AS dp
    WHERE ST_Z((dp).geom) IS NOT NULL;

    WITH hit_blocks AS (
        SELECT
            b.id,
            b.airspace_name,
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
    block_plan AS (
        SELECT
            hb.id AS block_id,
            COALESCE(NULLIF(btrim(hb.airspace_name), ''), hb.id) AS block_name,
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
    parsed_plan AS (
        SELECT
            bp.block_id,
            bp.block_name,
            bp.airspace_height,
            bp.use_date,
            bp.plan_status,
            bp.time_plan,
            seg.start_time AS plan_start_time,
            seg.end_time AS plan_end_time,
            (bp.use_date + seg.start_time) AS plan_start_ts,
            CASE
                WHEN seg.end_time <= seg.start_time
                THEN (bp.use_date + seg.end_time + interval '1 day')
                ELSE (bp.use_date + seg.end_time)
            END AS plan_end_ts
        FROM block_plan bp
        LEFT JOIN LATERAL (
            SELECT
                NULLIF(item ->> 'startTime', '')::time AS start_time,
                NULLIF(item ->> 'endTime', '')::time AS end_time
            FROM jsonb_array_elements(
                CASE
                    WHEN btrim(COALESCE(bp.time_plan, '')) ~ '^\s*\['
                    THEN bp.time_plan::jsonb
                    ELSE '[]'::jsonb
                END
            ) AS plan_item(item)
        ) seg ON true
    ),
    invalid_blocks AS (
        SELECT
            block_id,
            block_name,
            string_agg(reason, '；' ORDER BY reason) AS reason
        FROM (
            SELECT DISTINCT
                block_id,
                block_name,
                format('航线高度%s米超过空域高度%s米',
                    v_route_max_height, COALESCE(airspace_height, 0)) AS reason
            FROM block_plan
            WHERE v_route_max_height > COALESCE(airspace_height, 0)

            UNION ALL

            SELECT DISTINCT
                block_id,
                block_name,
                format('%s无用空计划', to_char(use_date, 'YYYY-MM-DD')) AS reason
            FROM block_plan
            WHERE plan_status IS NULL

            UNION ALL

            SELECT DISTINCT
                block_id,
                block_name,
                format('%s用空计划不可用', to_char(use_date, 'YYYY-MM-DD')) AS reason
            FROM block_plan
            WHERE plan_status = false

            UNION ALL

            SELECT DISTINCT
                bp.block_id,
                bp.block_name,
                format('%s任务时间段%s-%s超出用空计划时间段',
                    to_char(bp.use_date, 'YYYY-MM-DD'),
                    to_char(ts.start_time, 'HH24:MI:SS'),
                    to_char(ts.end_time, 'HH24:MI:SS')) AS reason
            FROM block_plan bp
            CROSS JOIN task_segments ts
            WHERE bp.plan_status = true
              AND NOT EXISTS (
                  SELECT 1
                  FROM parsed_plan pp
                  WHERE pp.block_id = bp.block_id
                    AND pp.use_date = bp.use_date
                    AND pp.plan_start_ts IS NOT NULL
                    AND pp.plan_end_ts IS NOT NULL
                    AND ts.start_ts >= pp.plan_start_ts
                    AND ts.end_ts <= pp.plan_end_ts
              )
        ) invalid_reason
        GROUP BY block_id, block_name
    )
    SELECT COALESCE(array_agg(format('%s(%s)：%s', block_name, block_id, reason) ORDER BY block_id), ARRAY[]::text[])
    INTO v_error_msgs
    FROM invalid_blocks;

    v_elapsed := round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);

    IF COALESCE(array_length(v_error_msgs, 1), 0) > 0 THEN
        v_msg := format('任务%s不可执行：%s，执行时间 %s 秒',
            p_task_id, array_to_string(v_error_msgs, '；'), v_elapsed);
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids;
    ELSE
        v_msg := format('任务%s经过空域区块%s个，用空计划和高度校验通过，可执行，执行时间 %s 秒',
            p_task_id, hit_count, v_elapsed);
        RETURN QUERY SELECT 200, v_msg, true, hit_count, hit_blockids;
    END IF;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('任务航线用空校验执行异常：%s，执行时间 %s 秒',
        SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[];
END;
$$;

COMMENT ON FUNCTION public.gis_flight_task_airspace(varchar, varchar, text, varchar, text)
IS '校验任务航线用空是否可执行';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- SELECT * FROM public.gis_flight_task_airspace(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     'TASK-001',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.90,36.43,100],[116.02,36.49,100]]}}',
--     '2026-10-09',
--     '[{"startTime":"15:00:00","endTime":"16:00:00"},{"startTime":"16:00:00","endTime":"17:00:00"}]'
-- );
