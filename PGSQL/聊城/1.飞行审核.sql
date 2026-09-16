-- =============================================================================
-- 1.飞行审核.sql
-- 飞行审核规则说明：
--   （1）空域校验
--   A、飞越禁飞区：检查是否经过禁飞区，穿越禁飞区，阻断提交。
--   B、飞越管控区：检查是否经过管控区。
--      1. 有飞行计划，校验通过，继续后续校验。
--      2. 无飞行计划，校验不通过，提醒用户，不阻断提交，继续后续校验。
-- 函数见gis_electric_fence_check_line
--   C、飞行航线空域校验：校验航线是否在计划空域范围内。
--      1. 未超出空域范围，校验通过，继续后续校验。
--      2. 超出空域范围，校验不通过，提醒用户，不阻断提交，继续后续校验。
-- 函数见以下：
--1.gis_flight_route_circle      飞行审核圆空域航线校验
--2.gis_flight_route_polygon     飞行审核面空域航线校验
 
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
--
 
--
-- 依赖说明：
--   1. PostGIS 空间扩展。
--   2. public.gis_geojson_to_geom(text) GeoJSON解析函数。
--
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
-- =============================================================================

-- =============================================================================
-- 函数名称：gis_flight_route_circle
-- 函数功能：圆空域航线校验
-- 函数描述：
--   1. 接收中心点GeoJSON、半径和航线GeoJSON。
--   2. 自动生成圆形计划空域。
--   3. 判断航线是否完全在空域内。
-- 参数说明：
--   p_center_geojson  中心点GeoJSON，支持Point或Feature<Point>
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
-- 函数介绍：gis_flight_route_circle
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
STABLE
AS $$
DECLARE
    v_center geometry;
    v_airspace geometry;
    v_route geometry;
    v_ischeck boolean;
    v_check_type text;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    IF p_center_geojson IS NULL OR btrim(p_center_geojson) = '' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：中心点GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF p_radius_m IS NULL OR p_radius_m <= 0 THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：半径必须大于0米，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    BEGIN
        v_center := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_center_geojson)), 4326);
        v_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_route_geojson)), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                format('参数错误：GeoJSON解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
                false,
                'ln_outside';
            RETURN;
    END;

    IF v_center IS NULL OR ST_IsEmpty(v_center) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：中心点GeoJSON无有效空间数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF ST_GeometryType(v_center) <> 'ST_Point' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：中心点必须是Point，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：航线GeoJSON无有效空间数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：航线必须是LineString或MultiLineString，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
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
        RETURN QUERY SELECT
            500,
            format('执行异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_circle(text, numeric, text)
IS '飞行审核圆空域航线校验';

-- =============================================================================
-- 函数名称：gis_flight_route_polygon
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
-- 函数介绍：gis_flight_route_polygon
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
STABLE
AS $$
DECLARE
    v_airspace geometry;
    v_route geometry;
    v_ischeck boolean;
    v_check_type text;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    IF p_airspace_geojson IS NULL OR btrim(p_airspace_geojson) = '' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：空域面GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    BEGIN
        v_airspace := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_airspace_geojson)), 4326);
        v_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_route_geojson)), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                format('参数错误：GeoJSON解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
                false,
                'ln_outside';
            RETURN;
    END;

    IF v_airspace IS NULL OR ST_IsEmpty(v_airspace) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：空域面GeoJSON无有效空间数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF ST_GeometryType(v_airspace) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：空域必须是Polygon或MultiPolygon，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF NOT ST_IsValid(v_airspace) THEN
        v_airspace := ST_MakeValid(v_airspace);
    END IF;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：航线GeoJSON无有效空间数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：航线必须是LineString或MultiLineString，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
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
        RETURN QUERY SELECT
            500,
            format('执行异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            'ln_outside';
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_polygon(text, text)
IS '飞行审核面空域航线校验';

-- =============================================================================
-- 调用示例
-- =============================================================================

-- 点+半径计划空域
-- SELECT code, msg, ischeck, check_type
-- FROM public.gis_flight_route_circle(
--     '{"type":"Point","coordinates":[115.985,36.455]}',
--     1000,
--     '{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}'
-- );

-- 面计划空域
-- SELECT code, msg, ischeck, check_type
-- FROM public.gis_flight_route_polygon(
--     '{"type":"Polygon","coordinates":[[[115.970,36.440],[116.000,36.440],[116.000,36.470],[115.970,36.470],[115.970,36.440]]]}',
--     '{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}'
-- );
