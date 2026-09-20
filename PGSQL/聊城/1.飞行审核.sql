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
--3.gis_flight_height_check       飞行审核高度检查
--4.gis_flight_height_plan        飞行审核计划高度校验
--5.gis_flight_route_deviation    飞行审核航线偏离校验
 
-- 3高度检查返回说明：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息
--   ischeck    是否通过高度校验
--   minheight  最小飞行高度，单位米
--   maxheight  最大飞行高度，单位米
--
-- 4计划高度校验返回说明：
--   code        状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg         返回信息
--   ischeck     是否通过计划高度校验，true=高度偏差≤阈值，false=高度偏差＞阈值
--   height      高度偏差米数，当前取最大高度偏差
--   max_height  最大高度偏差米数
--   min_height  最小高度偏差米数
--
-- 5飞行偏离校验返回说明：
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
-- 函数名称：gis_flight_height_check
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
-- 函数介绍：gis_flight_height_check
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
STABLE
AS $$
DECLARE
    v_route geometry;
    v_minheight numeric;
    v_maxheight numeric;
    v_ischeck boolean;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        RETURN QUERY SELECT 400, format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_limit_height IS NULL OR p_limit_height < 0 THEN
        RETURN QUERY SELECT 400, format('参数错误：限高阈值不能小于0米，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_is_elevation IS NULL THEN
        RETURN QUERY SELECT 400, format('参数错误：是否海拔高度不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    BEGIN
        v_route := ST_SetSRID(public.gis_geojson_to_geom(p_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 400, format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
        RETURN;
    END;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        RETURN QUERY SELECT 400, format('参数错误：航线GeoJSON无有效空间数据，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT 400, format('参数错误：航线必须是LineString或MultiLineString，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
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
        RETURN QUERY SELECT
            400,
            format('无数据：未获取到有效%s，执行时间 %s 秒',
                CASE WHEN p_is_elevation THEN '真高' ELSE '飞行高度' END,
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric;
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
    RETURN QUERY SELECT 500, format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_height_check(text, numeric, boolean)
IS '飞行审核高度检查';

-- =============================================================================
-- 函数名称：gis_flight_height_plan
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
-- 函数介绍：gis_flight_height_plan
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
STABLE
AS $$
DECLARE
    v_plan_route geometry;
    v_task_route geometry;
    v_height numeric;
    v_max_height numeric;
    v_min_height numeric;
    v_ischeck boolean;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    IF p_plan_route_geojson IS NULL OR btrim(p_plan_route_geojson) = '' THEN
        RETURN QUERY SELECT 400, format('参数错误：计划航线GeoJSON不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_task_route_geojson IS NULL OR btrim(p_task_route_geojson) = '' THEN
        RETURN QUERY SELECT 400, format('参数错误：任务航线GeoJSON不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF p_height_m IS NULL OR p_height_m < 0 THEN
        RETURN QUERY SELECT 400, format('参数错误：允许高度偏差不能小于0米，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    BEGIN
        v_plan_route := ST_SetSRID(public.gis_geojson_to_geom(p_plan_route_geojson), 4326);
        v_task_route := ST_SetSRID(public.gis_geojson_to_geom(p_task_route_geojson), 4326);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 400, format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END;

    IF v_plan_route IS NULL OR ST_IsEmpty(v_plan_route) THEN
        RETURN QUERY SELECT 400, format('参数错误：计划航线GeoJSON无有效空间数据，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF v_task_route IS NULL OR ST_IsEmpty(v_task_route) THEN
        RETURN QUERY SELECT 400, format('参数错误：任务航线GeoJSON无有效空间数据，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_plan_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT 400, format('参数错误：计划航线必须是LineString或MultiLineString，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_task_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT 400, format('参数错误：任务航线必须是LineString或MultiLineString，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
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
        RETURN QUERY SELECT 400, format('无数据：航线采样点未获取到有效飞行高度，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
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
    RETURN QUERY SELECT 500, format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)), false, NULL::numeric, NULL::numeric, NULL::numeric;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_height_plan(text, text, numeric)
IS '飞行审核计划高度校验';

-- =============================================================================
-- 函数名称：gis_flight_route_deviation
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
-- 函数介绍：gis_flight_route_deviation
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
STABLE
AS $$
DECLARE
    v_plan_route geometry;
    v_task_route geometry;
    v_distance numeric;
    v_max_distance numeric;
    v_min_distance numeric;
    v_ischeck boolean;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    IF p_plan_route_geojson IS NULL OR btrim(p_plan_route_geojson) = '' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：计划航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
        RETURN;
    END IF;

    IF p_task_route_geojson IS NULL OR btrim(p_task_route_geojson) = '' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：任务航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
        RETURN;
    END IF;

    IF p_offset_m IS NULL OR p_offset_m < 0 THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：允许偏移距离不能小于0米，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
        RETURN;
    END IF;

    BEGIN
        v_plan_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_plan_route_geojson)), 4326);
        v_task_route := ST_SetSRID(ST_Force2D(public.gis_geojson_to_geom(p_task_route_geojson)), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                format('参数错误：GeoJSON解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
                false,
                NULL::numeric,
                NULL::numeric,
                NULL::numeric;
            RETURN;
    END;

    IF v_plan_route IS NULL OR ST_IsEmpty(v_plan_route) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：计划航线GeoJSON无有效空间数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
        RETURN;
    END IF;

    IF v_task_route IS NULL OR ST_IsEmpty(v_task_route) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：任务航线GeoJSON无有效空间数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_plan_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：计划航线必须是LineString或MultiLineString，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
        RETURN;
    END IF;

    IF ST_GeometryType(v_task_route) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：任务航线必须是LineString或MultiLineString，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
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
        RETURN QUERY SELECT
            500,
            format('执行异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)),
            false,
            NULL::numeric,
            NULL::numeric,
            NULL::numeric;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_route_deviation(text, text, numeric)
IS '飞行审核航线偏离校验';

-- =============================================================================
-- 调用示例
-- =============================================================================

-- 点+半径计划空域
-- 入参：
--   1. p_center_geojson 中心点GeoJSON，格式为Point，坐标为[经度,纬度]
--   2. p_radius_m      计划空域半径，单位米
--   3. p_route_geojson  航线GeoJSON，格式为LineString/MultiLineString，坐标可带高度[经度,纬度,高度]
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否在点+半径计划空域内，true=在范围内，false=超出范围
--   check_type 空间关系类型：ln_within=包含于 ln_outside=相离 ln_crosses=交叉 ln_enters=穿入/穿出 ln_overlaps=重叠
-- SELECT code, msg, ischeck, check_type
-- FROM public.gis_flight_route_circle(
--     '{"type":"Point","coordinates":[115.985,36.455]}',
--     1000,
--     '{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}'
-- );

-- 面计划空域
-- 入参：
--   1. p_polygon_geojson 计划面空域GeoJSON，格式为Polygon/MultiPolygon
--   2. p_route_geojson   航线GeoJSON，格式为LineString/MultiLineString，坐标可带高度[经度,纬度,高度]
-- 返回：
--   code       状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg        返回信息，包含校验结果和执行耗时
--   ischeck    是否在面计划空域内，true=在范围内，false=超出范围
--   check_type 空间关系类型：ln_within=包含于 ln_outside=相离 ln_crosses=交叉 ln_enters=穿入/穿出 ln_overlaps=重叠
-- SELECT code, msg, ischeck, check_type
-- FROM public.gis_flight_route_polygon(
--     '{"type":"Polygon","coordinates":[[[115.970,36.440],[116.000,36.440],[116.000,36.470],[115.970,36.470],[115.970,36.440]]]}',
--     '{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}'
-- );

-- 飞行高度检查
-- 入参：
--   1. p_route_geojson 航线GeoJSON，格式为LineString/MultiLineString，坐标高度为海拔高度或飞行高度
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
--     '{"type":"LineString","coordinates":[[115.984,36.454,180],[115.990,36.458,180]]}',
--     120,
--     true
-- );

-- 直接使用航线点高度
-- 入参：
--   1. p_route_geojson 航线GeoJSON，坐标第三位直接作为飞行高度
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
--     '{"type":"LineString","coordinates":[[115.984,36.454,110],[115.990,36.458,180]]}',
--     120,
--     false
-- );

-- 飞行审核计划高度校验
-- 入参：
--   1. p_plan_route_geojson 计划航线GeoJSON，坐标第三位为计划高度
--   2. p_task_route_geojson 任务航线GeoJSON，坐标第三位为任务高度
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
--     '{"type":"LineString","coordinates":[[115.984,36.454,150],[115.990,36.458,180]]}',
--     '{"type":"LineString","coordinates":[[115.984,36.454,160],[115.990,36.458,170]]}',
--     20
-- );

-- 飞行偏离校验
-- 入参：
--   1. p_plan_route_geojson 计划航线GeoJSON，格式为LineString/MultiLineString
--   2. p_task_route_geojson 任务航线GeoJSON，格式为LineString/MultiLineString
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
--     '{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}',
--     '{"type":"LineString","coordinates":[[115.9841,36.4541,120],[115.9901,36.4581,120]]}',
--     20
-- );
