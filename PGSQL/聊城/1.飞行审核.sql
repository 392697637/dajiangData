-- =============================================================================
-- 1.飞行审核.sql
-- 飞行审核规则说明：
--   （1）空域校验
--   A、飞越禁飞区：检查是否经过禁飞区，穿越禁飞区，阻断提交。
--   B、飞越管控区：检查是否经过管控区。
--      1. 有飞行计划，校验通过，继续后续校验。
--      2. 无飞行计划，校验不通过，提醒用户，不阻断提交，继续后续校验。
-- 函数见以下：
--1.gis_flight_route_nofly            禁飞区航线检查，命中时阻断提交
--2.gis_flight_route_control          管控区航线检查，命中时结合飞行计划提示
-- 返回说明：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息
--   ischeck    是否在空域内
--   check_type 校验结果类型
-- check_type：
--   ln_within  线与面：包含于
--   ln_outside 线与面：相离
--   ln_crosses 线与面：交叉
--   ln_enters  线与面：穿入/穿出
--   ln_overlaps 线与面：重叠
--   zone_type  区域类型：管控区
--   hit_count  命中的管控区数量
--   C、飞行航线空域校验：校验航线是否在计划空域范围内。
--      1. 未超出空域范围，校验通过，继续后续校验。
--      2. 超出空域范围，校验不通过，提醒用户，不阻断提交，继续后续校验。
-- 函数见以下：
--3.gis_flight_route_circle      飞行审核圆空域航线校验
--4.gis_flight_route_polygon     飞行审核面空域航线校验
-- 返回说明：
--   code      状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg       返回信息
--   ischeck   是否在计划空域内
--   check_type 校验结果类型
-- check_type：
--   ln_within    线与面：包含于
--   ln_outside   线与面：相离
--   ln_crosses   线与面：交叉
--   ln_enters    线与面：穿入/穿出
--   ln_overlaps  线与面：重叠

 
--   （2）航线校验
--   A、飞行高度检查：检查飞行高度是否≤120米。
--      1. 飞行高度（真高）≤120米，校验通过。
--      2. 飞行高度＞120米，且未关联飞行计划，校验不通过，提醒用户，不阻断提交。
--      3. 飞行高度＞120米，且关联飞行计划，校验通过。
--   B、飞行高度校验：任务飞行高度与计划航线的一致性校验。
--      1. 关联飞行计划，飞行高度（真高）在计划飞行高度区间内，校验通过。
--      2. 关联飞行计划，飞行高度在计划飞行高度区间外，校验不通过，提醒用户，不阻断提交。
--   C、飞行偏离校验：任务飞行航线与计划航线水平偏移校验。
--      1. 水平偏移距离＞20米，校验不通过，提醒用户，不阻断提交。
--      2. 水平偏移距离≤20米，校验通过。
-- 函数见以下：
--5.gis_flight_height_check       飞行审核高度检查
--6.gis_flight_height_plan        飞行审核计划高度校验
--7.gis_flight_route_deviation    飞行审核航线偏离校验
 
-- 5高度检查返回说明：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息
--   ischeck    是否通过高度校验
--   minheight  最小飞行高度，单位米
--   maxheight  最大飞行高度，单位米
--
-- 6计划高度校验返回说明：
--   code        状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg         返回信息
--   ischeck     是否通过计划高度校验，true=高度偏差≤阈值，false=高度偏差＞阈值
--   height      高度偏差米数，当前取最大高度偏差
--   max_height  最大高度偏差米数
--   min_height  最小高度偏差米数
--
-- 7飞行偏离校验返回说明：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息
--   ischeck       是否通过偏离校验，true=水平偏移距离≤阈值，false=水平偏移距离＞阈值
--   distance      偏移米数，当前取最大偏移米数
--   max_distance  最大偏移米数
--   min_distance  最小偏移米数


-- 依赖说明：
--   1. PostGIS 空间扩展。
--   2. public.gis_geojson_to_geom(text) GeoJSON解析函数。
 
-- =============================================================================
-- 辅助函数：gis_write_error_log
-- 作用说明：
--   1. 统一写入PG相关GIS错误日志。
--   2. 可供飞行审核及其他GIS函数内部复用。
--   3. 非业务审核接口，接口层无需直接调用。
-- 写入表：
--   public.gis_error_log(code, msg, sqlstring)
-- 参数说明：
--   p_code       错误状态码：400=参数/业务错误，500=系统异常
--   p_msg        错误提示信息
--   p_sqlstring  触发错误时的SQL语句
-- =============================================================================
SELECT gis_drop_function('gis_write_error_log');

CREATE OR REPLACE FUNCTION public.gis_write_error_log(
    p_code integer,
    p_msg text,
    p_sqlstring text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (p_code, p_msg, p_sqlstring);
END;
$$;

COMMENT ON FUNCTION public.gis_write_error_log(integer, text, text)
IS 'PG相关GIS错误日志写入函数';

-- =============================================================================
-- 函数名称：1.gis_flight_route_nofly
-- 函数功能：判断航线是否经过禁飞区
-- 函数描述：
--   1. 接收项目ID和任务航线GeoJSON。
--   2. 检查航线是否经过禁飞区。
--   3. 按航线二维投影相交 + 航线最低高度与围栏高度做高度过滤。
--   4. Feature、FeatureCollection、Point/MultiPoint 等输入统一通过 gis_geojson_to_geom 解析。
-- 参数说明：
--   p_project_id      项目ID；为空时只检查公共电子围栏
--   p_route_geojson   航线GeoJSON，支持Point/MultiPoint/LineString/MultiLineString/Feature/FeatureCollection
-- 返回说明：返回code、msg、ischeck、check_type、zone_type、hit_count。
-- 注意事项：ischeck=true 表示航线命中禁飞区，调用方应阻断提交。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_nofly');

-- =============================================================================
-- 函数介绍：1.gis_flight_route_nofly
-- 主要作用：判断航线是否经过禁飞区。
-- 入参说明：项目ID、航线GeoJSON。
-- 返回说明：返回执行状态、是否命中禁飞区、校验结果类型、区域类型和命中数量。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_route_nofly(
    p_project_id text,
    p_route_geojson text
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
    v_hit_count bigint := 0;
    v_check_type text := 'ln_outside';
    v_table_name text;
    v_table_exists boolean := false;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_route_nofly(%L, %L);',
        p_project_id, p_route_geojson);

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, v_check_type, '禁飞区'::text, 0::bigint;
        RETURN;
    END IF;

    BEGIN
        v_route := ST_SetSRID(public.gis_geojson_to_geom(p_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, v_check_type, '禁飞区'::text, 0::bigint;
        RETURN;
    END;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, v_check_type, '禁飞区'::text, 0::bigint;
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_Point', 'ST_MultiPoint', 'ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持点或线，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, v_check_type, '禁飞区'::text, 0::bigint;
        RETURN;
    END IF;

    IF p_project_id IS NOT NULL AND btrim(p_project_id) <> '' THEN
        v_table_name := 'gis_electric_fence_' || btrim(p_project_id);
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = v_table_name
        ) INTO v_table_exists;
    END IF;

    IF v_table_exists THEN
        EXECUTE format(
            'SELECT count(*) FROM %I f
             WHERE f.fence_type = ''1''
               AND f.geom IS NOT NULL
               AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D($1))
               AND (NOT $2 OR COALESCE(f.height, 0) = 0 OR
                    COALESCE((SELECT min(ST_Z((p).geom))
                              FROM ST_DumpPoints($1) d
                              CROSS JOIN LATERAL ST_DumpPoints(d.geom) p
                              WHERE ST_Z((p).geom) IS NOT NULL), 0) = 0 OR
                    COALESCE((SELECT min(ST_Z((p).geom))
                              FROM ST_DumpPoints($1) d
                              CROSS JOIN LATERAL ST_DumpPoints(d.geom) p
                              WHERE ST_Z((p).geom) IS NOT NULL), 0) <= f.height)',
            v_table_name
        ) INTO v_hit_count USING v_route, true;
    END IF;

    SELECT v_hit_count + count(*)
    INTO v_hit_count
    FROM public.bo_electric_fence f
    WHERE f.fence_type = '1'
      AND f.del_flag = false
      AND f.status = '1'
      AND f.use_enabled = true
      AND f.geom IS NOT NULL
      AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D(v_route))
      AND (
          COALESCE(f.height, 0) = 0
          OR COALESCE((
              SELECT min(ST_Z((p).geom))
              FROM ST_DumpPoints(v_route) d
              CROSS JOIN LATERAL ST_DumpPoints(d.geom) p
              WHERE ST_Z((p).geom) IS NOT NULL
          ), 0) = 0
          OR COALESCE((
              SELECT min(ST_Z((p).geom))
              FROM ST_DumpPoints(v_route) d
              CROSS JOIN LATERAL ST_DumpPoints(d.geom) p
              WHERE ST_Z((p).geom) IS NOT NULL
          ), 0) <= f.height
      );

    v_check_type := CASE WHEN v_hit_count = 0 THEN 'ln_outside' ELSE 'ln_crosses' END;

    RETURN QUERY SELECT
        200,
        format('%s，命中禁飞区 %s 个，执行时间 %s 秒',
            CASE WHEN v_hit_count > 0 THEN '检测到航线经过禁飞区' ELSE '航线未经过禁飞区' END,
            v_hit_count,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::text,
        v_hit_count > 0,
        v_check_type,
        '禁飞区'::text,
        v_hit_count;
EXCEPTION WHEN OTHERS THEN
    v_msg := format('执行异常：%s，执行时间 %s 秒',
        SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg,
        false, 'ln_outside'::text, '禁飞区'::text, 0::bigint;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_nofly(text, text)
IS '飞行审核禁飞区航线检查；命中时阻断提交';

-- =============================================================================
-- 辅助函数：gis_flight_route_zone_check
-- 作用说明：
--   1. 按围栏类型统计航线命中区域。
--   2. 当前供 gis_flight_route_control 等审核函数内部复用。
--   3. 非业务审核接口，接口层无需直接调用。
-- 参数说明：
--   p_project_id     项目ID；为空时只检查公共电子围栏
--   p_route_geojson  航线GeoJSON，统一通过 gis_geojson_to_geom 解析
--   p_fence_type     围栏类型：1=禁飞区，2=管控区
-- 返回说明：返回code、msg、ischeck、check_type、zone_type、hit_count。
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_zone_check');

CREATE OR REPLACE FUNCTION public.gis_flight_route_zone_check(
    p_project_id text,
    p_route_geojson text,
    p_fence_type text
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
    v_min_z double precision := 0;
    v_hit_count bigint := 0;
    v_table_name text;
    v_table_exists boolean := false;
    v_zone_name text := CASE p_fence_type WHEN '1' THEN '禁飞区' WHEN '2' THEN '管控区' ELSE '电子围栏' END;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_route_zone_check(%L, %L, %L);',
        p_project_id, p_route_geojson, p_fence_type);

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, 'ln_outside'::text, v_zone_name, 0::bigint;
        RETURN;
    END IF;

    BEGIN
        v_route := ST_SetSRID(public.gis_geojson_to_geom(p_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, 'ln_outside'::text, v_zone_name, 0::bigint;
        RETURN;
    END;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, 'ln_outside'::text, v_zone_name, 0::bigint;
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_Point', 'ST_MultiPoint', 'ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持点或线，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg,
            false, 'ln_outside'::text, v_zone_name, 0::bigint;
        RETURN;
    END IF;

    SELECT COALESCE(min(ST_Z((p).geom)), 0)
    INTO v_min_z
    FROM ST_DumpPoints(v_route) d
    CROSS JOIN LATERAL ST_DumpPoints(d.geom) p
    WHERE ST_Z((p).geom) IS NOT NULL;

    IF p_project_id IS NOT NULL AND btrim(p_project_id) <> '' THEN
        v_table_name := 'gis_electric_fence_' || btrim(p_project_id);
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = v_table_name
        ) INTO v_table_exists;
    END IF;

    IF v_table_exists THEN
        EXECUTE format(
            'SELECT count(*) FROM %I f
             WHERE f.fence_type = $2
               AND f.geom IS NOT NULL
               AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D($1))
               AND (COALESCE(f.height, 0) = 0 OR $3 = 0 OR $3 <= f.height)',
            v_table_name
        ) INTO v_hit_count USING v_route, p_fence_type, v_min_z;
    END IF;

    SELECT v_hit_count + count(*)
    INTO v_hit_count
    FROM public.bo_electric_fence f
    WHERE f.fence_type = p_fence_type
      AND f.del_flag = false
      AND f.status = '1'
      AND f.use_enabled = true
      AND f.geom IS NOT NULL
      AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D(v_route))
      AND (COALESCE(f.height, 0) = 0 OR v_min_z = 0 OR v_min_z <= f.height);

    RETURN QUERY SELECT
        200,
        format('%s，命中%s %s 个', CASE WHEN v_hit_count > 0
            THEN '检测到航线经过区域' ELSE '航线未经过区域' END, v_zone_name, v_hit_count)::text,
        v_hit_count > 0,
        CASE WHEN v_hit_count > 0 THEN 'ln_crosses' ELSE 'ln_outside' END,
        v_zone_name,
        v_hit_count;
EXCEPTION WHEN OTHERS THEN
    v_msg := format('执行异常：%s，执行时间 %s 秒',
        SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg,
        false, 'ln_outside'::text, v_zone_name, 0::bigint;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_zone_check(text, text, text)
IS '飞行审核内部通用区域命中统计函数';

-- =============================================================================
-- 函数名称：2.gis_flight_route_control
-- 函数功能：判断航线是否经过管控区
-- 函数描述：
--   1. 接收项目ID和任务航线GeoJSON。
--   2. 检查航线是否经过管控区。
--   3. 按航线二维投影相交 + 航线最低高度与围栏高度做高度过滤。
--   4. Feature、FeatureCollection、Point/MultiPoint 等输入统一通过 gis_geojson_to_geom 解析。
-- 参数说明：
--   p_project_id      项目ID；为空时只检查公共电子围栏
--   p_route_geojson   航线GeoJSON，支持Point/MultiPoint/LineString/MultiLineString/Feature/FeatureCollection
-- 返回说明：返回code、msg、ischeck、check_type、zone_type、hit_count。
-- 注意事项：ischeck=true 表示航线命中管控区；是否阻断由调用方结合飞行计划决定。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_control');

-- =============================================================================
-- 函数介绍：2.gis_flight_route_control
-- 主要作用：判断航线是否经过管控区。
-- 入参说明：项目ID、航线GeoJSON。
-- 返回说明：返回执行状态、是否命中管控区、校验结果类型、区域类型和命中数量。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_route_control(
    p_project_id text,
    p_route_geojson text
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
BEGIN
    RETURN QUERY
    SELECT r.code,
           replace(replace(r.msg, '禁飞区', '管控区'), 'no_fly', 'control'),
           r.ischeck,
           r.check_type,
           '管控区'::text,
           r.hit_count
    FROM public.gis_flight_route_zone_check(p_project_id, p_route_geojson, '2') r;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_control(text, text)
IS '飞行审核管控区航线检查；命中后由调用方结合飞行计划决定是否仅提示';

-- =============================================================================
-- 函数名称：3.gis_flight_route_circle
-- 函数功能：圆空域航线校验
-- 函数描述：
--   1. 接收中心点GeoJSON、半径米和航线GeoJSON。
--   2. 根据中心点和半径生成圆形计划空域。
--   3. 判断航线是否完全在圆形空域内。
-- 参数说明：
--   p_center_geojson  中心点GeoJSON，必须为Point
--   p_radius_m        半径，单位米
--   p_route_geojson   航线GeoJSON，支持LineString/MultiLineString
-- 返回说明：返回code、msg、ischeck、check_type。
-- 注意事项：边界按在范围内处理。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_circle');

-- =============================================================================
-- 函数介绍：3.gis_flight_route_circle
-- 主要作用：校验航线是否在点+半径计划空域内。
-- 入参说明：中心点GeoJSON、半径米、航线GeoJSON。
-- 返回说明：返回执行状态、是否在范围内和校验结果类型。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_route_circle(
    p_center_geojson text,
    p_radius_m numeric,
    p_route_geojson text
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    check_type text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_center geometry;
    v_airspace geometry;
    v_route geometry;
    v_ischeck boolean;
    v_check_type text;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_route_circle(%L, %s, %L);',
        p_center_geojson, COALESCE(p_radius_m::text, 'NULL'), p_route_geojson);

    IF p_center_geojson IS NULL OR btrim(p_center_geojson) = '' THEN
        v_msg := format('参数错误：中心点GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF p_radius_m IS NULL OR p_radius_m <= 0 THEN
        v_msg := format('参数错误：半径必须大于0米，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    BEGIN
        v_center := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_center_geojson)), 4326);
        v_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_route_geojson)), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            v_msg := format('参数错误：GeoJSON解析失败：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
            RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
            RETURN;
    END;

    IF v_center IS NULL OR ST_IsEmpty(v_center) THEN
        v_msg := format('参数错误：中心点GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF ST_GeometryType(v_center) <> 'ST_Point' THEN
        v_msg := format('参数错误：中心点GeoJSON仅支持点，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持线，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    v_airspace := ST_SetSRID(ST_Buffer(v_center::geography, p_radius_m::double precision)::geometry, 4326);
    v_check_type := CASE
        WHEN ST_CoveredBy(ST_Force2D(v_route), ST_Boundary(v_airspace)) THEN 'ln_overlaps'
        WHEN ST_CoveredBy(ST_Force2D(v_route), v_airspace) THEN 'ln_within'
        WHEN NOT ST_Intersects(v_airspace, ST_Force2D(v_route)) THEN 'ln_outside'
        WHEN ST_Covers(v_airspace, ST_StartPoint(ST_Force2D(v_route)))
          <> ST_Covers(v_airspace, ST_EndPoint(ST_Force2D(v_route))) THEN 'ln_enters'
        ELSE 'ln_crosses'
    END;
    v_ischeck := v_check_type IN ('ln_within', 'ln_overlaps');

    RETURN QUERY SELECT
        200,
        format('%s，执行时间 %s 秒',
            CASE WHEN v_ischeck THEN '执行成功：航线在计划圆形空域范围内' ELSE '执行成功：航线超出计划圆形空域范围' END,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
        v_ischeck,
        v_check_type;

EXCEPTION
    WHEN OTHERS THEN
        v_msg := format('执行异常：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
        RETURN QUERY SELECT 500, v_msg, false, 'ln_outside'::text;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_circle(text, numeric, text)
IS '飞行审核圆空域航线校验';

-- =============================================================================
-- 函数名称：4.gis_flight_route_polygon
-- 函数功能：面空域航线校验
-- 函数描述：
--   1. 接收计划面空域GeoJSON和航线GeoJSON。
--   2. 支持Polygon/MultiPolygon空域。
--   3. 判断航线是否完全在空域内。
-- 参数说明：
--   p_airspace_geojson  空域面GeoJSON，支持Polygon/MultiPolygon
--   p_route_geojson     航线GeoJSON，支持LineString/MultiLineString
-- 返回说明：返回code、msg、ischeck、check_type。
-- 注意事项：边界按在范围内处理。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_polygon');

-- =============================================================================
-- 函数介绍：4.gis_flight_route_polygon
-- 主要作用：校验航线是否在计划面空域内。
-- 入参说明：空域面GeoJSON、航线GeoJSON。
-- 返回说明：返回执行状态、是否在范围内和校验结果类型。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_route_polygon(
    p_airspace_geojson text,
    p_route_geojson text
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    check_type text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_airspace geometry;
    v_route geometry;
    v_ischeck boolean;
    v_check_type text;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_route_polygon(%L, %L);',
        p_airspace_geojson, p_route_geojson);

    IF p_airspace_geojson IS NULL OR btrim(p_airspace_geojson) = '' THEN
        v_msg := format('参数错误：空域面GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    BEGIN
        v_airspace := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_airspace_geojson)), 4326);
        v_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_route_geojson)), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            v_msg := format('参数错误：GeoJSON解析失败：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
            RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
            RETURN;
    END;

    IF v_airspace IS NULL OR ST_IsEmpty(v_airspace) THEN
        v_msg := format('参数错误：空域面GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF ST_GeometryType(v_airspace) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        v_msg := format('参数错误：空域面GeoJSON仅支持面，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF NOT ST_IsValid(v_airspace) THEN
        v_airspace := ST_MakeValid(v_airspace);
    END IF;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持线，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 'ln_outside'::text;
        RETURN;
    END IF;

    v_check_type := CASE
        WHEN ST_CoveredBy(ST_Force2D(v_route), ST_Boundary(v_airspace)) THEN 'ln_overlaps'
        WHEN ST_CoveredBy(ST_Force2D(v_route), v_airspace) THEN 'ln_within'
        WHEN NOT ST_Intersects(v_airspace, ST_Force2D(v_route)) THEN 'ln_outside'
        WHEN ST_Covers(v_airspace, ST_StartPoint(ST_Force2D(v_route)))
          <> ST_Covers(v_airspace, ST_EndPoint(ST_Force2D(v_route))) THEN 'ln_enters'
        ELSE 'ln_crosses'
    END;
    v_ischeck := v_check_type IN ('ln_within', 'ln_overlaps');

    RETURN QUERY SELECT
        200,
        format('%s，执行时间 %s 秒',
            CASE WHEN v_ischeck THEN '执行成功：航线在计划面空域范围内' ELSE '执行成功：航线超出计划面空域范围' END,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
        v_ischeck,
        v_check_type;

EXCEPTION
    WHEN OTHERS THEN
        v_msg := format('执行异常：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
        RETURN QUERY SELECT 500, v_msg, false, 'ln_outside'::text;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_polygon(text, text)
IS '飞行审核面空域航线校验';

-- =============================================================================
-- 函数名称：5.gis_flight_height_check
-- 函数功能：飞行高度检查
-- 函数描述：
--   1. 接收任务航线GeoJSON。
--   2. 从航线点Z值获取飞行高度。
--   3. 飞行高度≤120米通过，飞行高度＞120米不通过。
-- 参数说明：
--   p_route_geojson  任务航线GeoJSON，支持LineString/MultiLineString
--   p_limit_height   限高阈值，单位米，默认120
--   p_is_elevation   是否按海拔高度计算，true=航线点海拔高度减地面高程计算真高，false=直接使用航线点高度，默认true
-- 返回说明：返回code、msg、ischeck、minheight、maxheight。
-- 注意事项：ischeck=true表示校验通过。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_height_check');

-- =============================================================================
-- 函数介绍：5.gis_flight_height_check
-- 主要作用：检查航线点飞行高度是否超过120米。
-- 入参说明：任务航线GeoJSON、限高阈值、是否海拔高度。
-- 返回说明：返回执行状态、是否通过、最小/最大飞行高度。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_height_check(
    p_route_geojson text,
    p_limit_height numeric DEFAULT 120,
    p_is_elevation boolean DEFAULT true
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    minheight numeric,
    maxheight numeric
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_route geometry;
    v_minheight numeric;
    v_maxheight numeric;
    v_ischeck boolean;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_height_check(%L, %s, %L);',
        p_route_geojson, COALESCE(p_limit_height::text, 'NULL'), p_is_elevation);

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_limit_height IS NULL OR p_limit_height < 0 THEN
        v_msg := format('参数错误：限高阈值不能小于0米，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_is_elevation IS NULL THEN
        v_msg := format('参数错误：是否海拔高度不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    BEGIN
        v_route := ST_SetSRID(public.gis_geojson_to_geom(p_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持线，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF NOT p_is_elevation THEN
        WITH height_points AS (
            SELECT ST_Z((dp).geom) AS height
            FROM ST_DumpPoints(v_route) AS dp
            WHERE ST_Z((dp).geom) IS NOT NULL
        )
        SELECT ROUND(MIN(height)::numeric, 3), ROUND(MAX(height)::numeric, 3)
        INTO v_minheight, v_maxheight
        FROM height_points;
    ELSE
        WITH height_points AS (
            SELECT ST_Z((dp).geom) - ST_Z(dem.geom) AS height
            FROM ST_DumpPoints(v_route) AS dp
            CROSS JOIN LATERAL (
                SELECT public.gis_dem_elevation_base(
                    ST_Force2D((dp).geom)
                ) AS geom
            ) AS dem
            WHERE ST_Z((dp).geom) IS NOT NULL
              AND dem.geom IS NOT NULL
              AND ST_Z(dem.geom) IS NOT NULL
        )
        SELECT ROUND(MIN(height)::numeric, 3), ROUND(MAX(height)::numeric, 3)
        INTO v_minheight, v_maxheight
        FROM height_points;
    END IF;

    IF v_minheight IS NULL OR v_maxheight IS NULL THEN
        v_msg := format('无数据：未获取到有效%s，执行时间 %s 秒',
            CASE WHEN p_is_elevation THEN '真高' ELSE '飞行高度' END,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    v_ischeck := v_maxheight <= p_limit_height;

    RETURN QUERY SELECT
        200,
        format('%s，最大%s %s 米，阈值 %s 米，执行时间 %s 秒',
            CASE WHEN v_ischeck THEN '执行成功：飞行高度小于等于阈值' ELSE '执行成功：飞行高度大于阈值' END,
            CASE WHEN p_is_elevation THEN '真高' ELSE '飞行高度' END,
            v_maxheight,
            p_limit_height,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
        v_ischeck,
        v_minheight,
        v_maxheight;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, NULL::numeric, NULL::numeric;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_height_check(text, numeric, boolean)
IS '飞行审核高度检查';

-- =============================================================================
-- 函数名称：6.gis_flight_height_plan
-- 函数功能：计划高度校验
-- 函数描述：
--   1. 接收计划航线GeoJSON和任务航线GeoJSON。
--   2. 计算任务航线与计划航线的高度偏差。
--   3. 默认高度偏差阈值为0米。
-- 参数说明：
--   p_plan_route_geojson  计划航线GeoJSON，支持LineString/MultiLineString
--   p_task_route_geojson  任务航线GeoJSON，支持LineString/MultiLineString
--   p_height_m            允许高度偏差，单位米，默认0
-- 返回说明：返回code、msg、ischeck、height、max_height、min_height。
-- 注意事项：ischeck=true表示高度偏差≤阈值。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_height_plan');

-- =============================================================================
-- 函数介绍：6.gis_flight_height_plan
-- 主要作用：校验任务航线与计划航线的高度偏差。
-- 入参说明：计划航线GeoJSON、任务航线GeoJSON、允许高度偏差米数。
-- 返回说明：返回执行状态、是否通过、高度偏差、最大/最小高度偏差。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_height_plan(
    p_plan_route_geojson text,
    p_task_route_geojson text,
    p_height_m numeric DEFAULT 0
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    height numeric,
    max_height numeric,
    min_height numeric
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_plan_route geometry;
    v_task_route geometry;
    v_height numeric;
    v_max_height numeric;
    v_min_height numeric;
    v_ischeck boolean;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_height_plan(%L, %L, %s);',
        p_plan_route_geojson, p_task_route_geojson, COALESCE(p_height_m::text, 'NULL'));

    IF p_plan_route_geojson IS NULL OR btrim(p_plan_route_geojson) = '' THEN
        v_msg := format('参数错误：计划航线GeoJSON不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_task_route_geojson IS NULL OR btrim(p_task_route_geojson) = '' THEN
        v_msg := format('参数错误：任务航线GeoJSON不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_height_m IS NULL OR p_height_m < 0 THEN
        v_msg := format('参数错误：允许高度偏差不能小于0米，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    BEGIN
        v_plan_route := ST_SetSRID(public.gis_geojson_to_geom(p_plan_route_geojson), 4326);
        v_task_route := ST_SetSRID(public.gis_geojson_to_geom(p_task_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END;

    IF v_plan_route IS NULL OR ST_IsEmpty(v_plan_route) THEN
        v_msg := format('参数错误：计划航线GeoJSON无有效几何，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF v_task_route IS NULL OR ST_IsEmpty(v_task_route) THEN
        v_msg := format('参数错误：任务航线GeoJSON无有效几何，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_plan_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：计划航线GeoJSON仅支持线，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_task_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：任务航线GeoJSON仅支持线，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    WITH plan_parts AS (
        SELECT
            (d).geom AS geom,
            GREATEST(CEIL(ST_Length(ST_Force2D((d).geom)::geography) / 20)::integer, 1) AS step_count
        FROM ST_Dump(v_plan_route) AS d
    ),
    plan_points AS (
        SELECT
            ST_LineInterpolatePoint(pp.geom, gs.i::double precision / pp.step_count) AS geom
        FROM plan_parts pp
        CROSS JOIN LATERAL generate_series(0, pp.step_count) AS gs(i)
        WHERE ST_Z(ST_LineInterpolatePoint(pp.geom, gs.i::double precision / pp.step_count)) IS NOT NULL
    ),
    task_parts AS (
        SELECT
            (d).geom AS geom,
            GREATEST(CEIL(ST_Length(ST_Force2D((d).geom)::geography) / 20)::integer, 1) AS step_count
        FROM ST_Dump(v_task_route) AS d
    ),
    task_points AS (
        SELECT
            ST_LineInterpolatePoint(tp.geom, gs.i::double precision / tp.step_count) AS geom
        FROM task_parts tp
        CROSS JOIN LATERAL generate_series(0, tp.step_count) AS gs(i)
        WHERE ST_Z(ST_LineInterpolatePoint(tp.geom, gs.i::double precision / tp.step_count)) IS NOT NULL
    ),
    height_points AS (
        SELECT ABS(ST_Z(t.geom) - ST_Z(p.geom)) AS height_diff
        FROM task_points t
        CROSS JOIN LATERAL (
            SELECT p.geom
            FROM plan_points p
            ORDER BY ST_Force2D(t.geom) <-> ST_Force2D(p.geom)
            LIMIT 1
        ) p
    )
    SELECT ROUND(MAX(height_diff)::numeric, 3), ROUND(MIN(height_diff)::numeric, 3)
    INTO v_max_height, v_min_height
    FROM height_points;

    IF v_max_height IS NULL OR v_min_height IS NULL THEN
        v_msg := format('无数据：航线采样点未获取到有效飞行高度，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    v_height := v_max_height;
    v_ischeck := v_height <= p_height_m;

    RETURN QUERY SELECT
        200,
        format('%s，高度偏差 %s 米，阈值 %s 米，执行时间 %s 秒',
            CASE WHEN v_ischeck THEN '执行成功：高度偏差小于等于阈值' ELSE '执行成功：高度偏差大于阈值' END,
            v_height,
            p_height_m,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
        v_ischeck,
        v_height,
        v_max_height,
        v_min_height;

EXCEPTION WHEN OTHERS THEN
    v_msg := format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_height_plan(text, text, numeric)
IS '飞行审核计划高度校验';

-- =============================================================================
-- 函数名称：7.gis_flight_route_deviation
-- 函数功能：航线偏离校验
-- 函数描述：
--   1. 接收计划航线GeoJSON和任务航线GeoJSON。
--   2. 计算两条航线的水平最大偏移距离。
--   3. 默认偏移阈值为20米。
-- 参数说明：
--   p_plan_route_geojson  计划航线GeoJSON，支持LineString/MultiLineString
--   p_task_route_geojson  任务航线GeoJSON，支持LineString/MultiLineString
--   p_offset_m            允许水平偏移距离，单位米，默认20
-- 返回说明：返回code、msg、ischeck、distance、max_distance、min_distance。
-- 注意事项：ischeck=true表示偏移距离≤阈值。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_route_deviation');

-- =============================================================================
-- 函数介绍：7.gis_flight_route_deviation
-- 主要作用：校验任务航线与计划航线的水平偏移距离。
-- 入参说明：计划航线GeoJSON、任务航线GeoJSON、允许偏移米数。
-- 返回说明：返回执行状态、是否通过、偏移米数、最大/最小偏移米数。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_route_deviation(
    p_plan_route_geojson text,
    p_task_route_geojson text,
    p_offset_m numeric DEFAULT 20
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    distance numeric,
    max_distance numeric,
    min_distance numeric
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_plan_route geometry;
    v_task_route geometry;
    v_distance numeric;
    v_max_distance numeric;
    v_min_distance numeric;
    v_ischeck boolean;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_route_deviation(%L, %L, %s);',
        p_plan_route_geojson, p_task_route_geojson, COALESCE(p_offset_m::text, 'NULL'));

    IF p_plan_route_geojson IS NULL OR btrim(p_plan_route_geojson) = '' THEN
        v_msg := format('参数错误：计划航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_task_route_geojson IS NULL OR btrim(p_task_route_geojson) = '' THEN
        v_msg := format('参数错误：任务航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_offset_m IS NULL OR p_offset_m < 0 THEN
        v_msg := format('参数错误：允许偏移距离不能小于0米，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    BEGIN
        v_plan_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_plan_route_geojson)), 4326);
        v_task_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_task_route_geojson)), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            v_msg := format('参数错误：GeoJSON解析失败：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
            RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
            RETURN;
    END;

    IF v_plan_route IS NULL OR ST_IsEmpty(v_plan_route) THEN
        v_msg := format('参数错误：计划航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF v_task_route IS NULL OR ST_IsEmpty(v_task_route) THEN
        v_msg := format('参数错误：任务航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_plan_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：计划航线GeoJSON仅支持线，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_task_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：任务航线GeoJSON仅支持线，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    WITH
    plan_points AS (
        SELECT (dp).geom AS geom
        FROM ST_DumpPoints(ST_Segmentize(v_plan_route::geography, 20)::geometry) AS dp
    ),
    task_points AS (
        SELECT (dp).geom AS geom
        FROM ST_DumpPoints(ST_Segmentize(v_task_route::geography, 20)::geometry) AS dp
    ),
    plan_to_task AS (
        SELECT
            COALESCE(MAX(ST_Distance(p.geom::geography, v_task_route::geography)), 0) AS max_dist_m,
            COALESCE(MIN(ST_Distance(p.geom::geography, v_task_route::geography)), 0) AS min_dist_m
        FROM plan_points p
    ),
    task_to_plan AS (
        SELECT
            COALESCE(MAX(ST_Distance(t.geom::geography, v_plan_route::geography)), 0) AS max_dist_m,
            COALESCE(MIN(ST_Distance(t.geom::geography, v_plan_route::geography)), 0) AS min_dist_m
        FROM task_points t
    )
    SELECT
        ROUND(GREATEST(plan_to_task.max_dist_m, task_to_plan.max_dist_m)::numeric, 3),
        ROUND(LEAST(plan_to_task.min_dist_m, task_to_plan.min_dist_m)::numeric, 3)
    INTO v_max_distance, v_min_distance
    FROM plan_to_task, task_to_plan;

    v_distance := v_max_distance;
    v_ischeck := v_distance <= p_offset_m;

    RETURN QUERY SELECT
        200,
        format('%s，水平偏移距离 %s 米，阈值 %s 米，执行时间 %s 秒',
            CASE WHEN v_ischeck THEN '执行成功：水平偏移距离未超出阈值' ELSE '执行成功：水平偏移距离超出阈值' END,
            v_distance,
            p_offset_m,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
        v_ischeck,
        v_distance,
        v_max_distance,
        v_min_distance;

EXCEPTION
    WHEN OTHERS THEN
        v_msg := format('执行异常：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
        RETURN QUERY SELECT 500, v_msg, false, NULL::numeric, NULL::numeric, NULL::numeric;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_deviation(text, text, numeric)
IS '飞行审核航线偏离校验';

-- =============================================================================
-- 调用示例
-- =============================================================================

-- 1.禁飞区航线检查
-- 入参：
--   1. p_project_id    项目ID；为空时只检查公共电子围栏
--   2. p_route_geojson 航线Feature GeoJSON，geometry格式为LineString/MultiLineString，坐标可带高度[经度,纬度,高度]
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否在禁飞区空域内，true=命中禁飞区，false=未命中禁飞区
--   check_type 空间关系类型：ln_within=包含于 ln_outside=相离 ln_crosses=交叉 ln_enters=穿入/穿出 ln_overlaps=重叠
--   zone_type  区域类型：禁飞区
--   hit_count  命中的禁飞区数量
-- SELECT code, msg, ischeck, check_type, zone_type, hit_count
-- FROM public.gis_flight_route_nofly(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}'
-- );

-- 2.管控区航线检查
-- 入参：
--   1. p_project_id    项目ID；为空时只检查公共电子围栏
--   2. p_route_geojson 航线Feature GeoJSON，geometry格式为LineString/MultiLineString，坐标可带高度[经度,纬度,高度]
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否在管控区空域内，true=命中管控区，false=未命中管控区
--   check_type 空间关系类型：ln_within=包含于 ln_outside=相离 ln_crosses=交叉 ln_enters=穿入/穿出 ln_overlaps=重叠
--   zone_type  区域类型：管控区
--   hit_count  命中的管控区数量
-- SELECT code, msg, ischeck, check_type, zone_type, hit_count
-- FROM public.gis_flight_route_control(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}'
-- );

-- 3.点+半径计划空域
-- 入参：
--   1. p_center_geojson 中心点Feature GeoJSON，geometry格式为Point，坐标为[经度,纬度]
--   2. p_radius_m      计划空域半径，单位米
--   3. p_route_geojson  航线Feature GeoJSON，geometry格式为LineString/MultiLineString，坐标可带高度[经度,纬度,高度]
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否在点+半径计划空域内，true=在范围内，false=超出范围
--   check_type 空间关系类型：ln_within=包含于 ln_outside=相离 ln_crosses=交叉 ln_enters=穿入/穿出 ln_overlaps=重叠
-- SELECT code, msg, ischeck, check_type
-- FROM public.gis_flight_route_circle(
--     '{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[115.985,36.455]}}',
--     1000,
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}'
-- );

-- 4.面计划空域
-- 入参：
--   1. p_polygon_geojson 计划面空域Feature GeoJSON，geometry格式为Polygon/MultiPolygon
--   2. p_route_geojson   航线Feature GeoJSON，geometry格式为LineString/MultiLineString，坐标可带高度[经度,纬度,高度]
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否在面计划空域内，true=在范围内，false=超出范围
--   check_type 空间关系类型：ln_within=包含于 ln_outside=相离 ln_crosses=交叉 ln_enters=穿入/穿出 ln_overlaps=重叠
-- SELECT code, msg, ischeck, check_type
-- FROM public.gis_flight_route_polygon(
--     '{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[115.970,36.440],[116.000,36.440],[116.000,36.470],[115.970,36.470],[115.970,36.440]]]}}',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}'
-- );

-- 5.飞行高度检查
-- 入参：
--   1. p_route_geojson 航线Feature GeoJSON，geometry格式为LineString/MultiLineString，坐标高度为海拔高度或飞行高度
--   2. p_limit_height  限高阈值，单位米，例如120
--   3. p_is_altitude   是否按海拔高度计算：true=坐标高度为海拔高度，需结合DEM计算真高；false=直接使用航线点高度
-- 返回：
--   code      状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg       返回信息，包含校验结果和执行耗时
--   ischeck   是否通过高度校验，true=最大飞行高度小于等于阈值，false=最大飞行高度大于阈值
--   minheight 最小飞行高度，单位米
--   maxheight 最大飞行高度，单位米
-- SELECT code, msg, ischeck, minheight, maxheight
-- FROM public.gis_flight_height_check(
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,180],[115.990,36.458,180]]}}',
--     120,
--     true
-- );

-- 5.1直接使用航线点高度
-- 入参：
--   1. p_route_geojson 航线Feature GeoJSON，geometry为LineString/MultiLineString，坐标第三位直接作为飞行高度
--   2. p_limit_height  限高阈值，单位米，例如120
--   3. p_is_altitude   false=不结合DEM，直接使用航线点高度
-- 返回：
--   code      状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg       返回信息，包含校验结果和执行耗时
--   ischeck   是否通过高度校验，true=最大飞行高度小于等于阈值，false=最大飞行高度大于阈值
--   minheight 最小飞行高度，单位米
--   maxheight 最大飞行高度，单位米
-- SELECT code, msg, ischeck, minheight, maxheight
-- FROM public.gis_flight_height_check(
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,110],[115.990,36.458,180]]}}',
--     120,
--     false
-- );

-- 6.飞行审核计划高度校验
-- 入参：
--   1. p_plan_route_geojson 计划航线Feature GeoJSON，geometry为LineString/MultiLineString，坐标第三位为计划高度
--   2. p_task_route_geojson 任务航线Feature GeoJSON，geometry为LineString/MultiLineString，坐标第三位为任务高度
--   3. p_height_m           允许高度偏差阈值，单位米
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否通过计划高度校验，true=高度偏差小于等于阈值，false=高度偏差大于阈值
--   height     高度偏差米数，当前取最大高度偏差
--   max_height 最大高度偏差米数
--   min_height 最小高度偏差米数
-- SELECT code, msg, ischeck, height, max_height, min_height
-- FROM public.gis_flight_height_plan(
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,150],[115.990,36.458,180]]}}',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,160],[115.990,36.458,170]]}}',
--     20
-- );

-- 7.飞行偏离校验
-- 入参：
--   1. p_plan_route_geojson 计划航线Feature GeoJSON，geometry为LineString/MultiLineString
--   2. p_task_route_geojson 任务航线Feature GeoJSON，geometry为LineString/MultiLineString
--   3. p_offset_m           允许水平偏移阈值，单位米
-- 返回：
--   code         状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg          返回信息，包含校验结果和执行耗时
--   ischeck      是否通过偏离校验，true=水平偏移距离小于等于阈值，false=水平偏移距离大于阈值
--   distance     偏移米数，当前取最大偏移米数
--   max_distance 最大偏移米数
--   min_distance 最小偏移米数
-- SELECT code, msg, ischeck, distance, max_distance, min_distance
-- FROM public.gis_flight_route_deviation(
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}',
--     '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.9841,36.4541,120],[115.9901,36.4581,120]]}}',
--     20
-- );
