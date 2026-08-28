-- =============================================================================
-- 6.2 DEM 分析函数
-- =============================================================================
-- 用途:
--   基于 PostGIS Raster DEM 提供地形分析能力，主要用于地图点击查询、
--   作业区/行政区统计、航线剖面、飞行净空校验和地形产品生成。
--
--   1. 高程查询
--      查询点位地面高程，或给点、线、面 geometry 自动补 DEM 高程 Z 值。
--
--   2. 区域分析
--      对面范围统计最低/最高/平均高程、相对高差、高程分级、
--      区域起伏风险，并可提取 DEM 像元点或规则采样点。
--
--   3. 线路分析
--      沿航线、道路、管线按距离采样，生成高程剖面，
--      统计累计爬升、累计下降、最大坡度等指标。
--
--   4. 坡度与航线安全
--      对点位近似计算坡度、坡向和坡度风险；
--      对带 Z 航线计算离地净空，并识别低净空采样点。
--
--   5. 数据生产 / 预处理
--      生成等高线表，输出 DEM 范围、分辨率、SRID 等水文分析预处理参数。
--
-- 执行顺序:
--   1. baseFunction/gis_drop_function.sql
--   2. PGSQL/函数/6.1DEM.sql
--   3. PGSQL/函数/6.2DEM分析函数.sql
--
-- 默认按输入 geometry 从 public.jc_sheng.gis_dem_table 获取对应 DEM 表；
-- 也可通过 p_dem_table 显式指定 DEM 表，未命中配置时回退 public.gis_dem_henan。
--
-- 扩展分析函数:
--   A. 区域分析
--      最高/最低点、相对高差、网格起伏度、高程风险、DEM 像元点提取和规则采样。
--      对应函数:
--        gis_dem_minmax_points_by_polygon
--        gis_dem_relative_height_by_polygon
--        gis_dem_terrain_relief_by_grid
--        gis_dem_elevation_risk_by_polygon
--        gis_dem_extract_points_by_polygon
--        gis_dem_sample_grid_by_polygon
--
--   B. 线路分析
--      剖面统计、路线爬升下降、剖面 JSON 输出。
--      对应函数:
--        gis_dem_profile_stats_by_line
--        gis_dem_route_climb_by_line
--        gis_dem_cross_section_geojson
--
--   C. 航线安全
--      通视参数准备、坡度风险、航线离地净空、低净空采样点识别。
--      对应函数:
--        gis_dem_slope_risk_at_point
--        gis_dem_viewshed_prepare_point
--        gis_dem_obstacle_clearance_by_line
--        gis_dem_low_clearance_segments
--
--   D. 数据生产
--      等高线表生成、水文分析参数准备。
--      对应函数:
--        gis_dem_generate_contour_table
--        gis_dem_water_flow_prepare
--
-- 函数分类:
--   1. 基础查询
--      1.1 gis_dem_resolve_table              按输入 geometry 或显式表名解析 DEM 栅格表
--      1.2 gis_dem_value_at_point             查询单点 DEM 高程值
--      1.3 gis_dem_extent                     查询 DEM 覆盖范围、SRID 和瓦片数量
--
--   2. 区域分析
--      2.1 gis_dem_stats_by_polygon           统计面范围内像元数量、最低/最高/平均高程和标准差
--      2.2 gis_dem_hypsometric_by_polygon     按高程间隔统计面范围内像元数量
--      2.3 gis_dem_minmax_points_by_polygon   查询面范围内最低点和最高点位置
--      2.4 gis_dem_relative_height_by_polygon 统计区域相对高差
--      2.5 gis_dem_terrain_relief_by_grid     按规则网格统计地形起伏度
--      2.6 gis_dem_elevation_risk_by_polygon  根据区域相对高差输出起伏风险等级
--      2.7 gis_dem_extract_points_by_polygon  提取面范围内 DEM 像元中心点和高程
--      2.8 gis_dem_sample_grid_by_polygon     在面范围内生成规则采样点并查询高程
--
--   3. 线路分析
--      3.1 gis_dem_profile_by_line            沿 LineString 按米采样生成高程剖面
--      3.2 gis_dem_profile_stats_by_line      统计剖面的最低/最高/平均高程、累计爬升和累计下降
--      3.3 gis_dem_route_climb_by_line        输出路线距离、起终点高程、最大坡度、累计爬升和累计下降
--      3.4 gis_dem_cross_section_geojson      将高程剖面输出为 JSON 数组，便于前端绘图
--
--   4. 坡度 / 航线安全
--      4.1 gis_dem_slope_aspect_at_point      近似计算点位坡度、坡度百分比、坡向角和坡向名称
--      4.2 gis_dem_slope_risk_at_point        根据点位坡度输出风险等级
--      4.3 gis_dem_viewshed_prepare_point     输出通视分析所需观察点地面高程和观察高度
--      4.4 gis_dem_obstacle_clearance_by_line 计算带 Z 航线相对 DEM 地面的离地净空
--      4.5 gis_dem_low_clearance_segments     识别低于安全离地高度的航线采样点
--
--   5. 数据生产 / 预处理
--      5.1 gis_dem_generate_contour_table     通过 ST_Contour 生成等高线矢量表
--      5.2 gis_dem_water_flow_prepare         输出 DEM 范围、分辨率、SRID 等水文分析预处理参数
--
--   6. geometry 补高程
--      6.1 gis_dem_point_with_elevation       点/多点补 DEM 高程 Z 值
--      6.2 gis_dem_line_with_elevation        线/多线补 DEM 高程 Z 值
--      6.3 gis_dem_polygon_with_elevation     面/多面补 DEM 高程 Z 值
--      6.4 gis_dem_geom_with_elevation        根据 geometry 类型通用补 DEM 高程 Z 值
--
-- 性能提示:
--   点查询、剖面分析适合在线调用；大范围区域统计、等高线生成建议离线执行。
--
-- 返回策略:
--   1. 所有函数统一返回 TABLE 结构，前两列固定为 code、msg。
--   2. code=200 表示执行成功，后续列返回函数业务数据。
--   3. code=400 表示输入参数错误、DEM 表不存在、空间范围无数据或业务条件不满足。
--   4. code=500 表示函数执行过程中出现数据库异常，msg 返回异常信息。
--   5. 接口层可直接读取 code/msg 判断状态，再读取后续业务字段。
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;


-- =============================================================================
-- 1.1 gis_dem_resolve_table
-- 函数名称：gis_dem_resolve_table
-- 函数功能：统一解析本次 DEM 分析应该读取哪一张 PostGIS Raster 表。
-- 使用场景：点高程查询、区域统计、剖面分析、坡度坡向、航线净空等函数的 DEM 表选择。
-- 实时调用：适合实时调用，函数只做 DEM 表解析，开销很小。
-- 解析规则：优先使用 p_dem_table；未传表名时按 p_geom 与 public.jc_sheng.geom 相交关系读取 gis_dem_table；仍未命中时回退 public.gis_dem_henan。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_resolve_table');
-- =============================================================================
-- 函数名称：gis_dem_resolve_table
-- 函数功能：统一解析本次 DEM 分析应该读取哪一张 PostGIS Raster 表。
-- 入参说明：
--   1. p_geom      输入点、线、面或其他 geometry；会转为 EPSG:4326 后匹配 public.jc_sheng.geom。
--   2. p_dem_table 可选 DEM 表名；支持 public.gis_dem_henan 或 gis_dem_henan 两种写法。
-- 返回值：
--   TABLE(code, msg, dem_table)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_resolve_table(
    p_geom geometry DEFAULT NULL,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE (code integer, msg varchar, dem_table regclass)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_table text;
    v_geom_4326 geometry;
    v_dem_reg regclass;
BEGIN
    v_dem_table := NULLIF(trim(COALESCE(p_dem_table, '')), '');

    IF v_dem_table IS NULL AND p_geom IS NOT NULL AND to_regclass('public.jc_sheng') IS NOT NULL THEN
        v_geom_4326 := CASE
            WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_Force2D(p_geom), 4326)
            WHEN ST_SRID(p_geom) = 4326 THEN ST_Force2D(p_geom)
            ELSE ST_Transform(ST_Force2D(p_geom), 4326)
        END;

        SELECT NULLIF(trim(s.gis_dem_table), '')
        INTO v_dem_table
        FROM public.jc_sheng s
        WHERE s.geom IS NOT NULL
          AND s.gis_dem_table IS NOT NULL
          AND s.geom && v_geom_4326
          AND ST_Intersects(s.geom, v_geom_4326)
        ORDER BY s.gid
        LIMIT 1;
    END IF;

    IF v_dem_table IS NULL THEN
        v_dem_table := 'public.gis_dem_henan';
    END IF;

    v_dem_reg := COALESCE(to_regclass(v_dem_table), to_regclass(format('public.%I', v_dem_table)));
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, format('DEM表不存在: %s', v_dem_table)::varchar, NULL::regclass;
        RETURN;
    END IF;

    RETURN QUERY SELECT 200, '执行成功'::varchar, v_dem_reg;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 500, SQLERRM::varchar, NULL::regclass;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_resolve_table(geometry, text) IS '按输入geometry或显式表名解析DEM栅格表';


-- =============================================================================

-- 1.2 gis_dem_value_at_point
-- 函数名称：gis_dem_value_at_point
-- 函数功能：查询单点位置的 DEM 地面高程值。
-- 使用场景：地图点击取高程、航线采样点取地面高程、坡度坡向和净空分析的基础取值。
-- 实时调用：适合实时调用，推荐用于地图点击、单点查询和少量采样点查询。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_value_at_point');
-- =============================================================================
-- 函数名称：gis_dem_value_at_point
-- 函数功能：查询单点位置的 DEM 地面高程值。
-- 入参说明：
--   1. p_point     Point geometry；无 SRID 时按 EPSG:4326 处理。
--   2. p_dem_table 可选 DEM 表名；为空时按 p_point 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, elevation)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_value_at_point(
    p_point geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    msg varchar,
    elevation double precision
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
    v_dem_srid integer;
    v_point geometry;
    v_value double precision;
BEGIN
    IF p_point IS NULL OR ST_IsEmpty(p_point) THEN
        RETURN QUERY SELECT 400, '输入点为空'::varchar, NULL::double precision;
        RETURN;
    END IF;

    IF ST_GeometryType(p_point) <> 'ST_Point' THEN
        RETURN QUERY SELECT 400, format('只支持 Point，当前类型: %s', ST_GeometryType(p_point))::varchar, NULL::double precision;
        RETURN;
    END IF;

    SELECT r.dem_table
    INTO v_dem_reg
    FROM public.gis_dem_resolve_table(p_point, p_dem_table) r
    WHERE r.code = 200
    LIMIT 1;

    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, 'DEM表不存在或未匹配到DEM表'::varchar, NULL::double precision;
        RETURN;
    END IF;

    EXECUTE format('SELECT ST_SRID(rast) FROM %s WHERE rast IS NOT NULL LIMIT 1', v_dem_reg)
    INTO v_dem_srid;

    IF v_dem_srid IS NULL THEN
        RETURN QUERY SELECT 400, 'DEM表无有效栅格数据'::varchar, NULL::double precision;
        RETURN;
    END IF;

    v_point :=
        CASE
            WHEN ST_SRID(p_point) = 0 THEN ST_SetSRID(ST_Force2D(p_point), 4326)
            WHEN ST_SRID(p_point) = v_dem_srid THEN ST_Force2D(p_point)
            ELSE ST_Transform(ST_Force2D(p_point), v_dem_srid)
        END;

    EXECUTE format($sql$
        SELECT ST_Value(r.rast, 1, $1)
        FROM %s r
        WHERE r.rast IS NOT NULL
          AND r.rast && $1
          AND ST_Intersects(r.rast, $1)
        ORDER BY r.rid
        LIMIT 1
    $sql$, v_dem_reg)
    USING v_point
    INTO v_value;

    IF v_value IS NULL THEN
        RETURN QUERY SELECT 400, '点不在DEM覆盖范围内或无有效像元'::varchar, NULL::double precision;
        RETURN;
    END IF;

    RETURN QUERY SELECT 200, '执行成功'::varchar, v_value;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 500, SQLERRM::varchar, NULL::double precision;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_value_at_point(geometry, text) IS '查询单点DEM高程值，默认按点位解析DEM表';


-- =============================================================================

-- 1.3 gis_dem_extent
-- 函数名称：gis_dem_extent
-- 函数功能：查询指定 DEM 栅格表的覆盖范围、SRID 和瓦片数量。
-- 使用场景：GeoServer 发布前检查、前端图层定位、DEM 数据入库后范围校验。
-- 实时调用：适合实时调用，也可在系统启动或图层加载时缓存结果。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_extent');
-- =============================================================================
-- 函数名称：gis_dem_extent
-- 函数功能：查询指定 DEM 栅格表的覆盖范围、SRID 和瓦片数量。
-- 入参说明：
--   1. p_dem_table DEM 栅格表名；默认 public.gis_dem_henan。
--   2. p_out_srid  输出范围 geometry 的 SRID；默认 EPSG:4326。
-- 返回值：
--   TABLE(code, msg, dem_table, dem_srid, tile_count, geom)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_extent(
    p_dem_table text DEFAULT 'public.gis_dem_henan',
    p_out_srid integer DEFAULT 4326
)
RETURNS TABLE (
    code integer,
    msg varchar,
    dem_table text,
    dem_srid integer,
    tile_count bigint,
    geom geometry
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
BEGIN
    v_dem_reg := COALESCE(to_regclass(p_dem_table), to_regclass(format('public.%I', p_dem_table)));
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, format('DEM表不存在: %s', p_dem_table)::varchar, NULL::text, NULL::integer, NULL::bigint, NULL::geometry;
        RETURN;
    END IF;

    RETURN QUERY EXECUTE format($sql$
        WITH e AS (
            SELECT
                ST_SRID(rast) AS srid,
                COUNT(*)::bigint AS tile_count,
                ST_Envelope(ST_Collect(ST_ConvexHull(rast))) AS geom
            FROM %s
            WHERE rast IS NOT NULL
            GROUP BY ST_SRID(rast)
        )
        SELECT
            200 AS code,
            '执行成功'::varchar AS msg,
            %L::text AS dem_table,
            e.srid AS dem_srid,
            e.tile_count,
            CASE
                WHEN e.srid = $1 THEN ST_SetSRID(e.geom, e.srid)
                ELSE ST_Transform(ST_SetSRID(e.geom, e.srid), $1)
            END AS geom
        FROM e
    $sql$, v_dem_reg, v_dem_reg::text)
    USING p_out_srid;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_extent(text, integer) IS '返回DEM覆盖范围、SRID和瓦片数量';


-- =============================================================================

-- 2.1 gis_dem_stats_by_polygon
-- 函数名称：gis_dem_stats_by_polygon
-- 函数功能：统计面范围内 DEM 高程分布。
-- 使用场景：行政区、电子围栏、作业区、任务区的最低/最高/平均高程分析。
-- 实时调用：小范围面适合实时调用；大范围行政区建议后台执行或缓存结果。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_stats_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_stats_by_polygon
-- 函数功能：统计面范围内 DEM 高程分布。
-- 入参说明：
--   1. p_geom      Polygon 或 MultiPolygon；无 SRID 时按 EPSG:4326 处理。
--   2. p_dem_table 可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, pixel_count, min_elevation, max_elevation, mean_elevation, stddev_elevation)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_stats_by_polygon(
    p_geom geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    msg varchar,
    pixel_count bigint,
    min_elevation double precision,
    max_elevation double precision,
    mean_elevation double precision,
    stddev_elevation double precision
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
    v_dem_srid integer;
    v_geom geometry;
BEGIN
    IF p_geom IS NULL OR ST_IsEmpty(p_geom) THEN
        RETURN QUERY SELECT 400, '输入面为空'::varchar, NULL::bigint, NULL::double precision, NULL::double precision, NULL::double precision, NULL::double precision;
        RETURN;
    END IF;

    SELECT r.dem_table INTO v_dem_reg FROM public.gis_dem_resolve_table(p_geom, p_dem_table) r WHERE r.code = 200 LIMIT 1;
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, 'DEM表不存在或未匹配到DEM表'::varchar, NULL::bigint, NULL::double precision, NULL::double precision, NULL::double precision, NULL::double precision;
        RETURN;
    END IF;

    EXECUTE format('SELECT ST_SRID(rast) FROM %s WHERE rast IS NOT NULL LIMIT 1', v_dem_reg)
    INTO v_dem_srid;

    v_geom :=
        CASE
            WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_MakeValid(ST_Force2D(p_geom)), 4326)
            WHEN ST_SRID(p_geom) = v_dem_srid THEN ST_MakeValid(ST_Force2D(p_geom))
            ELSE ST_Transform(ST_MakeValid(ST_Force2D(p_geom)), v_dem_srid)
        END;

    IF ST_GeometryType(v_geom) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        RETURN QUERY SELECT 400, format('只支持 Polygon/MultiPolygon，当前类型: %s', ST_GeometryType(v_geom))::varchar, NULL::bigint, NULL::double precision, NULL::double precision, NULL::double precision, NULL::double precision;
        RETURN;
    END IF;

    RETURN QUERY EXECUTE format($sql$
        WITH clipped AS (
            SELECT ST_Clip(r.rast, 1, $1, true) AS rast
            FROM %s r
            WHERE r.rast IS NOT NULL
              AND r.rast && $1
              AND ST_Intersects(r.rast, $1)
        ),
        stats AS (
            SELECT ST_SummaryStatsAgg(rast, 1, true) AS s
            FROM clipped
        )
        SELECT
            200 AS code,
            '执行成功'::varchar AS msg,
            (s).count::bigint AS pixel_count,
            (s).min AS min_elevation,
            (s).max AS max_elevation,
            (s).mean AS mean_elevation,
            (s).stddev AS stddev_elevation
        FROM stats
    $sql$, v_dem_reg)
    USING v_geom;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_stats_by_polygon(geometry, text) IS '统计面范围内DEM高程分布';


-- =============================================================================

-- 2.2 gis_dem_hypsometric_by_polygon
-- 函数名称：gis_dem_hypsometric_by_polygon
-- 函数功能：按高程间隔统计面范围内的 DEM 像元数量。
-- 使用场景：生成区域高程分布柱状图、分析作业区不同海拔段占比。
-- 实时调用：小范围面可实时调用；大范围或较小分级间隔会扫描大量像元，建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_hypsometric_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_hypsometric_by_polygon
-- 函数功能：按高程间隔统计面范围内 DEM 像元数量。
-- 入参说明：
--   1. p_geom      Polygon 或 MultiPolygon；无 SRID 时按 EPSG:4326 处理。
--   2. p_interval  高程分级间隔；默认 100。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, class_min, class_max, pixel_count)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_hypsometric_by_polygon(
    p_geom geometry,
    p_interval double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    msg varchar,
    class_min double precision,
    class_max double precision,
    pixel_count bigint
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
    v_dem_srid integer;
    v_geom geometry;
    v_interval double precision;
BEGIN
    IF p_geom IS NULL OR ST_IsEmpty(p_geom) THEN
        RETURN QUERY SELECT 400, '输入面为空'::varchar, NULL::double precision, NULL::double precision, NULL::bigint;
        RETURN;
    END IF;

    v_interval := GREATEST(COALESCE(p_interval, 100.0), 0.000001);
    SELECT r.dem_table INTO v_dem_reg FROM public.gis_dem_resolve_table(p_geom, p_dem_table) r WHERE r.code = 200 LIMIT 1;
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, 'DEM表不存在或未匹配到DEM表'::varchar, NULL::double precision, NULL::double precision, NULL::bigint;
        RETURN;
    END IF;

    EXECUTE format('SELECT ST_SRID(rast) FROM %s WHERE rast IS NOT NULL LIMIT 1', v_dem_reg)
    INTO v_dem_srid;

    v_geom :=
        CASE
            WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_MakeValid(ST_Force2D(p_geom)), 4326)
            WHEN ST_SRID(p_geom) = v_dem_srid THEN ST_MakeValid(ST_Force2D(p_geom))
            ELSE ST_Transform(ST_MakeValid(ST_Force2D(p_geom)), v_dem_srid)
        END;

    RETURN QUERY EXECUTE format($sql$
        WITH clipped AS (
            SELECT ST_Clip(r.rast, 1, $1, true) AS rast
            FROM %s r
            WHERE r.rast IS NOT NULL
              AND r.rast && $1
              AND ST_Intersects(r.rast, $1)
        ),
        pixels AS (
            SELECT (p).val::double precision AS elev
            FROM clipped c
            CROSS JOIN LATERAL ST_PixelAsCentroids(c.rast, 1, true) AS p
            WHERE (p).val IS NOT NULL
        ),
        classified AS (
            SELECT floor(elev / $2) * $2 AS class_min
            FROM pixels
        )
        SELECT
            200 AS code,
            '执行成功'::varchar AS msg,
            class_min,
            class_min + $2 AS class_max,
            COUNT(*)::bigint AS pixel_count
        FROM classified
        GROUP BY class_min
        ORDER BY class_min
    $sql$, v_dem_reg)
    USING v_geom, v_interval;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_hypsometric_by_polygon(geometry, double precision, text) IS '按高程间隔统计面范围内DEM像元数量';


-- =============================================================================

-- 2.3 gis_dem_minmax_points_by_polygon
-- 函数名称：gis_dem_minmax_points_by_polygon
-- 函数功能：查询面范围内 DEM 最低点和最高点的位置与高程值。
-- 使用场景：区域地形极值定位、作业区最高障碍点辅助判断、最低洼位置识别。
-- 实时调用：小范围面可实时调用；大范围会遍历像元查极值，建议后台执行或缓存。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_minmax_points_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_minmax_points_by_polygon
-- 函数功能：查询面范围内 DEM 最低点和最高点。
-- 入参说明：
--   1. p_geom      Polygon 或 MultiPolygon；无 SRID 时按 EPSG:4326 处理。
--   2. p_dem_table 可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, point_type, elevation, geom)，point_type 为 min 或 max。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_minmax_points_by_polygon(
    p_geom geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, point_type text, elevation double precision, geom geometry(Point, 4326))
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
    v_dem_srid integer;
    v_geom geometry;
BEGIN
    IF p_geom IS NULL OR ST_IsEmpty(p_geom) THEN
        RETURN QUERY SELECT 400, '输入面为空'::varchar, NULL::text, NULL::double precision, NULL::geometry(Point, 4326);
        RETURN;
    END IF;
    SELECT r.dem_table INTO v_dem_reg FROM public.gis_dem_resolve_table(p_geom, p_dem_table) r WHERE r.code = 200 LIMIT 1;
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, 'DEM表不存在或未匹配到DEM表'::varchar, NULL::text, NULL::double precision, NULL::geometry(Point, 4326);
        RETURN;
    END IF;
    EXECUTE format('SELECT ST_SRID(rast) FROM %s WHERE rast IS NOT NULL LIMIT 1', v_dem_reg) INTO v_dem_srid;
    v_geom := CASE
        WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_MakeValid(ST_Force2D(p_geom)), 4326)
        WHEN ST_SRID(p_geom) = v_dem_srid THEN ST_MakeValid(ST_Force2D(p_geom))
        ELSE ST_Transform(ST_MakeValid(ST_Force2D(p_geom)), v_dem_srid)
    END;

    RETURN QUERY EXECUTE format($sql$
        WITH clipped AS (
            SELECT ST_Clip(r.rast, 1, $1, true) AS rast
            FROM %s r
            WHERE r.rast IS NOT NULL AND r.rast && $1 AND ST_Intersects(r.rast, $1)
        ),
        px AS (
            SELECT (p).val::double precision AS elevation, ST_SetSRID(ST_MakePoint((p).x, (p).y), $2) AS geom
            FROM clipped c CROSS JOIN LATERAL ST_PixelAsCentroids(c.rast, 1, true) p
            WHERE (p).val IS NOT NULL
        ),
        ranked AS (
            SELECT * FROM (
                SELECT 'min'::text AS point_type, elevation, geom FROM px ORDER BY elevation ASC LIMIT 1
            ) min_px
            UNION ALL
            SELECT * FROM (
                SELECT 'max'::text AS point_type, elevation, geom FROM px ORDER BY elevation DESC LIMIT 1
            ) max_px
        )
        SELECT 200 AS code, '执行成功'::varchar AS msg, point_type, elevation,
            CASE WHEN $2 = 4326 THEN geom::geometry(Point, 4326)
                 ELSE ST_Transform(geom, 4326)::geometry(Point, 4326) END
        FROM ranked
    $sql$, v_dem_reg) USING v_geom, v_dem_srid;
END;
$$;
COMMENT ON FUNCTION public.gis_dem_minmax_points_by_polygon(geometry, text) IS '查询面范围内DEM最低点和最高点';

-- =============================================================================

-- 2.4 gis_dem_relative_height_by_polygon
-- 函数名称：gis_dem_relative_height_by_polygon
-- 函数功能：统计区域相对高差，即最高高程减最低高程。
-- 使用场景：判断区域地形起伏程度、作业区地形复杂度评估、风险分级前置计算。
-- 实时调用：小范围面可实时调用；本函数依赖区域统计，大范围建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_relative_height_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_relative_height_by_polygon
-- 函数功能：统计区域相对高差，即最高高程减最低高程。
-- 入参说明：
--   1. p_geom      Polygon 或 MultiPolygon。
--   2. p_dem_table 可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, min_elevation, max_elevation, relative_height)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_relative_height_by_polygon(
    p_geom geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, min_elevation double precision, max_elevation double precision, relative_height double precision)
LANGUAGE sql
STABLE
AS $$
    SELECT s.code, s.msg, s.min_elevation, s.max_elevation, s.max_elevation - s.min_elevation
    FROM public.gis_dem_stats_by_polygon(p_geom, p_dem_table) s
    WHERE s.code = 200;
$$;
COMMENT ON FUNCTION public.gis_dem_relative_height_by_polygon(geometry, text) IS '统计区域相对高差';

-- =============================================================================

-- 2.5 gis_dem_terrain_relief_by_grid
-- 函数名称：gis_dem_terrain_relief_by_grid
-- 函数功能：将输入面切成规则网格，并统计每个网格内地形起伏度。
-- 使用场景：区域起伏度分区展示、地形复杂区域定位、前端网格专题图渲染。
-- 实时调用：不建议实时调用，网格切分后会对多个子区域统计，建议离线或后台生成。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_terrain_relief_by_grid');
-- =============================================================================
-- 函数名称：gis_dem_terrain_relief_by_grid
-- 函数功能：将输入面切成规则网格，并统计每个网格内地形起伏度。
-- 入参说明：
--   1. p_geom             Polygon 或 MultiPolygon。
--   2. p_grid_size_degree 经纬度网格边长，单位度；默认 0.05。
--   3. p_dem_table        可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, grid_id, geom, min_elevation, max_elevation, relative_height)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_terrain_relief_by_grid(
    p_geom geometry,
    p_grid_size_degree double precision DEFAULT 0.05,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, grid_id bigint, geom geometry(Polygon, 4326), min_elevation double precision, max_elevation double precision, relative_height double precision)
LANGUAGE sql
STABLE
AS $$
    WITH input AS (
        SELECT CASE WHEN ST_SRID(p_geom)=0 THEN ST_SetSRID(ST_Force2D(p_geom),4326)
                    WHEN ST_SRID(p_geom)=4326 THEN ST_Force2D(p_geom)
                    ELSE ST_Transform(ST_Force2D(p_geom),4326) END AS geom
    ),
    grid AS (
        SELECT row_number() OVER ()::bigint AS grid_id, (ST_SquareGrid(GREATEST(p_grid_size_degree, 0.0001), geom)).geom::geometry(Polygon, 4326) AS geom
        FROM input
    ),
    clipped_grid AS (
        SELECT grid_id, ST_Intersection(g.geom, i.geom)::geometry(Polygon, 4326) AS geom
        FROM grid g CROSS JOIN input i
        WHERE ST_Intersects(g.geom, i.geom)
    )
    SELECT 200, '执行成功'::varchar, g.grid_id, g.geom, r.min_elevation, r.max_elevation, r.relative_height
    FROM clipped_grid g
    CROSS JOIN LATERAL public.gis_dem_relative_height_by_polygon(g.geom, p_dem_table) r
    WHERE NOT ST_IsEmpty(g.geom)
      AND r.code = 200;
$$;
COMMENT ON FUNCTION public.gis_dem_terrain_relief_by_grid(geometry, double precision, text) IS '按规则网格统计地形起伏度';

-- =============================================================================

-- 2.6 gis_dem_elevation_risk_by_polygon
-- 函数名称：gis_dem_elevation_risk_by_polygon
-- 函数功能：根据区域相对高差输出高程起伏风险等级。
-- 使用场景：区域地形风险初判、任务区起伏程度分级、地图专题渲染分级依据。
-- 实时调用：小范围面可实时调用；依赖区域统计，大范围建议后台执行或缓存。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_elevation_risk_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_elevation_risk_by_polygon
-- 函数功能：根据区域相对高差输出高程起伏风险等级。
-- 入参说明：
--   1. p_geom      Polygon 或 MultiPolygon。
--   2. p_dem_table 可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, min_elevation, max_elevation, mean_elevation, relative_height, risk_level)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_elevation_risk_by_polygon(
    p_geom geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, min_elevation double precision, max_elevation double precision, mean_elevation double precision, relative_height double precision, risk_level text)
LANGUAGE sql
STABLE
AS $$
    SELECT s.code, s.msg, s.min_elevation, s.max_elevation, s.mean_elevation, s.max_elevation - s.min_elevation,
        CASE
            WHEN s.max_elevation IS NULL THEN '未知'
            WHEN s.max_elevation - s.min_elevation >= 500 THEN '高起伏'
            WHEN s.max_elevation - s.min_elevation >= 200 THEN '中起伏'
            WHEN s.max_elevation - s.min_elevation >= 50 THEN '低起伏'
            ELSE '平缓'
        END
    FROM public.gis_dem_stats_by_polygon(p_geom, p_dem_table) s
    WHERE s.code = 200;
$$;
COMMENT ON FUNCTION public.gis_dem_elevation_risk_by_polygon(geometry, text) IS '区域高程起伏风险等级';

-- =============================================================================

-- 2.7 gis_dem_extract_points_by_polygon
-- 函数名称：gis_dem_extract_points_by_polygon
-- 函数功能：提取面范围内 DEM 像元中心点及高程值。
-- 使用场景：DEM 点云化抽样、前端散点展示、区域内原始高程样本导出。
-- 实时调用：不建议大范围实时调用；仅适合限制 p_limit 的小范围预览，批量导出建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_extract_points_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_extract_points_by_polygon
-- 函数功能：提取面范围内 DEM 像元中心点及高程值。
-- 入参说明：
--   1. p_geom      Polygon 或 MultiPolygon。
--   2. p_limit     最大返回点数；默认 10000。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, seq, geom, elevation)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_extract_points_by_polygon(
    p_geom geometry,
    p_limit integer DEFAULT 10000,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, seq bigint, geom geometry(Point, 4326), elevation double precision)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
    v_dem_srid integer;
    v_geom geometry;
BEGIN
    SELECT r.dem_table INTO v_dem_reg FROM public.gis_dem_resolve_table(p_geom, p_dem_table) r WHERE r.code = 200 LIMIT 1;
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, 'DEM表不存在或未匹配到DEM表'::varchar, NULL::bigint, NULL::geometry(Point, 4326), NULL::double precision;
        RETURN;
    END IF;
    EXECUTE format('SELECT ST_SRID(rast) FROM %s WHERE rast IS NOT NULL LIMIT 1', v_dem_reg) INTO v_dem_srid;
    v_geom := CASE WHEN ST_SRID(p_geom)=0 THEN ST_SetSRID(ST_Force2D(p_geom),4326)
                   WHEN ST_SRID(p_geom)=v_dem_srid THEN ST_Force2D(p_geom)
                   ELSE ST_Transform(ST_Force2D(p_geom),v_dem_srid) END;
    RETURN QUERY EXECUTE format($sql$
        SELECT 200 AS code, '执行成功'::varchar AS msg, row_number() OVER ()::bigint,
            CASE WHEN $2=4326 THEN ST_SetSRID(ST_MakePoint((p).x,(p).y),$2)::geometry(Point,4326)
                 ELSE ST_Transform(ST_SetSRID(ST_MakePoint((p).x,(p).y),$2),4326)::geometry(Point,4326) END,
            (p).val::double precision
        FROM %s r CROSS JOIN LATERAL ST_PixelAsCentroids(ST_Clip(r.rast,1,$1,true),1,true) p
        WHERE r.rast IS NOT NULL AND r.rast && $1 AND ST_Intersects(r.rast,$1) AND (p).val IS NOT NULL
        LIMIT $3
    $sql$, v_dem_reg) USING v_geom, v_dem_srid, GREATEST(COALESCE(p_limit,10000),1);
END;
$$;
COMMENT ON FUNCTION public.gis_dem_extract_points_by_polygon(geometry, integer, text) IS '提取面范围内DEM采样点';

-- =============================================================================

-- 2.8 gis_dem_sample_grid_by_polygon
-- 函数名称：gis_dem_sample_grid_by_polygon
-- 函数功能：在面范围内生成规则采样点，并查询每个点 DEM 高程。
-- 使用场景：轻量化区域采样、前端网格点展示、避免直接读取大量 DEM 像元。
-- 实时调用：可实时调用，但必须限制面范围和网格间距，避免生成过多采样点。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_sample_grid_by_polygon');
-- =============================================================================
-- 函数名称：gis_dem_sample_grid_by_polygon
-- 函数功能：在面范围内生成规则采样点，并查询每个点 DEM 高程。
-- 入参说明：
--   1. p_geom             Polygon 或 MultiPolygon。
--   2. p_grid_size_degree 经纬度采样网格边长，单位度；默认 0.01。
--   3. p_dem_table        可选 DEM 表名；为空时按 p_geom 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, seq, geom, elevation)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_sample_grid_by_polygon(
    p_geom geometry,
    p_grid_size_degree double precision DEFAULT 0.01,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, seq bigint, geom geometry(Point, 4326), elevation double precision)
LANGUAGE sql
STABLE
AS $$
    WITH input AS (
        SELECT CASE WHEN ST_SRID(p_geom)=0 THEN ST_SetSRID(ST_Force2D(p_geom),4326)
                    WHEN ST_SRID(p_geom)=4326 THEN ST_Force2D(p_geom)
                    ELSE ST_Transform(ST_Force2D(p_geom),4326) END AS geom
    ),
    pts AS (
        SELECT row_number() OVER ()::bigint AS seq, ST_PointOnSurface((ST_SquareGrid(GREATEST(p_grid_size_degree,0.0001), geom)).geom)::geometry(Point,4326) AS geom
        FROM input
    )
    SELECT 200, '执行成功'::varchar, p.seq, p.geom, (SELECT v.elevation FROM public.gis_dem_value_at_point(p.geom, p_dem_table) v WHERE v.code = 200 LIMIT 1)
    FROM pts p, input i
    WHERE ST_Intersects(i.geom, p.geom);
$$;
COMMENT ON FUNCTION public.gis_dem_sample_grid_by_polygon(geometry, double precision, text) IS '在面范围内生成规则采样点并查询高程';

-- =============================================================================

-- 3.1 gis_dem_profile_by_line
-- 函数名称：gis_dem_profile_by_line
-- 函数功能：沿 LineString 按米采样并查询 DEM 高程，生成高程剖面。
-- 使用场景：航线、道路、管线、巡检线路的距离-高程曲线。
-- 实时调用：适合短线实时调用；长线路应增大 p_step_m 或后台计算。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_profile_by_line');
-- =============================================================================
-- 函数名称：gis_dem_profile_by_line
-- 函数功能：沿 LineString 按米采样并查询 DEM 高程，生成高程剖面。
-- 入参说明：
--   1. p_line      LineString；无 SRID 时按 EPSG:4326 处理。
--   2. p_step_m    采样间隔，单位米；默认 100。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_line 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, seq, distance_m, geom, elevation)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_profile_by_line(
    p_line geometry,
    p_step_m double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    msg varchar,
    seq integer,
    distance_m double precision,
    geom geometry(Point, 4326),
    elevation double precision
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_line_4326 geometry;
    v_len_m double precision;
    v_step_m double precision;
BEGIN
    IF p_line IS NULL OR ST_IsEmpty(p_line) THEN
        RETURN QUERY SELECT 400, '输入线为空'::varchar, NULL::integer, NULL::double precision, NULL::geometry(Point, 4326), NULL::double precision;
        RETURN;
    END IF;

    v_line_4326 :=
        CASE
            WHEN ST_SRID(p_line) = 0 THEN ST_SetSRID(ST_Force2D(p_line), 4326)
            WHEN ST_SRID(p_line) = 4326 THEN ST_Force2D(p_line)
            ELSE ST_Transform(ST_Force2D(p_line), 4326)
        END;

    IF ST_GeometryType(v_line_4326) <> 'ST_LineString' THEN
        RETURN QUERY SELECT 400, format('只支持 LineString，当前类型: %s', ST_GeometryType(v_line_4326))::varchar, NULL::integer, NULL::double precision, NULL::geometry(Point, 4326), NULL::double precision;
        RETURN;
    END IF;

    v_len_m := ST_Length(v_line_4326::geography);
    v_step_m := GREATEST(COALESCE(p_step_m, 100.0), 0.1);

    RETURN QUERY
    WITH samples AS (
        SELECT
            LEAST(d::double precision, v_len_m) AS distance_m,
            ST_SetSRID(
                ST_LineInterpolatePoint(v_line_4326, LEAST(d::double precision, v_len_m) / NULLIF(v_len_m, 0)),
                4326
            )::geometry(Point, 4326) AS geom
        FROM generate_series(0::numeric, v_len_m::numeric, v_step_m::numeric) AS g(d)
        WHERE v_len_m > 0
        UNION ALL
        SELECT
            v_len_m AS distance_m,
            ST_SetSRID(ST_EndPoint(v_line_4326), 4326)::geometry(Point, 4326) AS geom
        WHERE v_len_m > 0
    ),
    dedup AS (
        SELECT DISTINCT ON (round(distance_m::numeric, 3))
            distance_m,
            geom
        FROM samples
        ORDER BY round(distance_m::numeric, 3), distance_m
    )
    SELECT
        200 AS code,
        '执行成功'::varchar AS msg,
        row_number() OVER (ORDER BY d.distance_m)::integer AS seq,
        d.distance_m,
        d.geom,
        (SELECT v.elevation FROM public.gis_dem_value_at_point(d.geom, p_dem_table) v WHERE v.code = 200 LIMIT 1) AS elevation
    FROM dedup d
    ORDER BY d.distance_m;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_profile_by_line(geometry, double precision, text) IS '沿线按米采样并返回DEM高程剖面';


-- =============================================================================

-- 3.2 gis_dem_profile_stats_by_line
-- 函数名称：gis_dem_profile_stats_by_line
-- 函数功能：对沿线高程剖面做统计汇总。
-- 使用场景：航线或道路纵断面汇总、累计爬升下降统计、线路地形复杂度判断。
-- 实时调用：适合短线实时调用；依赖剖面采样，长线路建议后台执行或缓存。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_profile_stats_by_line');
-- =============================================================================
-- 函数名称：gis_dem_profile_stats_by_line
-- 函数功能：对沿线高程剖面做统计汇总。
-- 入参说明：
--   1. p_line      LineString。
--   2. p_step_m    采样间隔，单位米；默认 100。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_line 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, sample_count, min_elevation, max_elevation, mean_elevation, total_ascent, total_descent)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_profile_stats_by_line(
    p_line geometry,
    p_step_m double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, sample_count bigint, min_elevation double precision, max_elevation double precision, mean_elevation double precision, total_ascent double precision, total_descent double precision)
LANGUAGE sql
STABLE
AS $$
    WITH p AS (
        SELECT *, lag(elevation) OVER (ORDER BY seq) AS prev_elevation
        FROM public.gis_dem_profile_by_line(p_line, p_step_m, p_dem_table)
        WHERE code = 200 AND elevation IS NOT NULL
    )
    SELECT
        200,
        '执行成功'::varchar,
        COUNT(*)::bigint,
        MIN(elevation),
        MAX(elevation),
        AVG(elevation),
        COALESCE(SUM(GREATEST(elevation - prev_elevation, 0)), 0),
        COALESCE(SUM(GREATEST(prev_elevation - elevation, 0)), 0)
    FROM p;
$$;
COMMENT ON FUNCTION public.gis_dem_profile_stats_by_line(geometry, double precision, text) IS '沿线剖面统计最低最高平均高程和累计爬升下降';

-- =============================================================================

-- 3.3 gis_dem_route_climb_by_line
-- 函数名称：gis_dem_route_climb_by_line
-- 函数功能：统计路线距离、起终点高程、最大坡度、累计爬升和累计下降。
-- 使用场景：路线爬升下降分析、航线高度规划辅助、线路坡度风险评估。
-- 实时调用：适合短线实时调用；采样点过多时建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_route_climb_by_line');
-- =============================================================================
-- 函数名称：gis_dem_route_climb_by_line
-- 函数功能：统计路线距离、起终点高程、最大坡度、累计爬升和累计下降。
-- 入参说明：
--   1. p_line      LineString。
--   2. p_step_m    采样间隔，单位米；默认 100。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_line 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, distance_m, start_elevation, end_elevation, max_slope_percent, total_ascent, total_descent)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_route_climb_by_line(
    p_line geometry,
    p_step_m double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, distance_m double precision, start_elevation double precision, end_elevation double precision, max_slope_percent double precision, total_ascent double precision, total_descent double precision)
LANGUAGE sql
STABLE
AS $$
    WITH p AS (
        SELECT *, lag(elevation) OVER (ORDER BY seq) AS prev_elevation, lag(distance_m) OVER (ORDER BY seq) AS prev_distance_m
        FROM public.gis_dem_profile_by_line(p_line, p_step_m, p_dem_table)
        WHERE code = 200 AND elevation IS NOT NULL
    )
    SELECT
        200,
        '执行成功'::varchar,
        MAX(distance_m),
        (array_agg(elevation ORDER BY seq))[1],
        (array_agg(elevation ORDER BY seq DESC))[1],
        MAX(ABS(elevation - prev_elevation) / NULLIF(distance_m - prev_distance_m, 0) * 100.0),
        COALESCE(SUM(GREATEST(elevation - prev_elevation, 0)), 0),
        COALESCE(SUM(GREATEST(prev_elevation - elevation, 0)), 0)
    FROM p;
$$;
COMMENT ON FUNCTION public.gis_dem_route_climb_by_line(geometry, double precision, text) IS '路线距离、起终点高程、最大坡度和累计爬升下降分析';

-- =============================================================================

-- 3.4 gis_dem_cross_section_geojson
-- 函数名称：gis_dem_cross_section_geojson
-- 函数功能：将沿线高程剖面输出为 JSON 数组。
-- 使用场景：接口直接返回前端绘图数据、剖面图组件渲染、线路高程曲线展示。
-- 实时调用：适合短线实时调用；返回 JSON 数据量随采样点增加，长线路建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_cross_section_geojson');
-- =============================================================================
-- 函数名称：gis_dem_cross_section_geojson
-- 函数功能：将沿线高程剖面输出为 JSON 数组。
-- 入参说明：
--   1. p_line      LineString。
--   2. p_step_m    采样间隔，单位米；默认 100。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_line 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, profile_json)，profile_json 为剖面 JSON 数组。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_cross_section_geojson(
    p_line geometry,
    p_step_m double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, profile_json jsonb)
LANGUAGE sql
STABLE
AS $$
    SELECT 200, '执行成功'::varchar, jsonb_agg(jsonb_build_object(
        'seq', p.seq,
        'distance_m', p.distance_m,
        'elevation', p.elevation,
        'geometry', ST_AsGeoJSON(p.geom)::jsonb
    ) ORDER BY p.seq)
    FROM public.gis_dem_profile_by_line(p_line, p_step_m, p_dem_table) p
    WHERE p.code = 200;
$$;
COMMENT ON FUNCTION public.gis_dem_cross_section_geojson(geometry, double precision, text) IS '高程剖面输出JSON数组';

-- =============================================================================

-- 4.1 gis_dem_slope_aspect_at_point
-- 函数名称：gis_dem_slope_aspect_at_point
-- 函数功能：近似计算点位坡度、坡度百分比、坡向角和坡向名称。
-- 使用场景：点位地形风险判断、起降点周边坡度评估、地面起伏辅助分析。
-- 实时调用：适合实时调用，单点周边少量采样开销较小。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_slope_aspect_at_point');
-- =============================================================================
-- 函数名称：gis_dem_slope_aspect_at_point
-- 函数功能：近似计算点位坡度、坡度百分比、坡向角和坡向名称。
-- 入参说明：
--   1. p_point     Point geometry；无 SRID 时按 EPSG:4326 处理。
--   2. p_sample_m  周边采样距离，单位米；默认 30。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_point 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, elevation, slope_degree, slope_percent, aspect_degree, aspect_name)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_slope_aspect_at_point(
    p_point geometry,
    p_sample_m double precision DEFAULT 30.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    msg varchar,
    elevation double precision,
    slope_degree double precision,
    slope_percent double precision,
    aspect_degree double precision,
    aspect_name text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_point geometry(Point, 4326);
    v_d double precision;
    zc double precision;
    zn double precision;
    zs double precision;
    ze double precision;
    zw double precision;
    dzdx double precision;
    dzdy double precision;
    aspect double precision;
BEGIN
    IF p_point IS NULL OR ST_IsEmpty(p_point) THEN
        RETURN QUERY SELECT 400, '输入点为空'::varchar, NULL::double precision, NULL::double precision, NULL::double precision, NULL::double precision, NULL::text;
        RETURN;
    END IF;

    IF ST_GeometryType(p_point) <> 'ST_Point' THEN
        RETURN QUERY SELECT 400, format('只支持 Point，当前类型: %s', ST_GeometryType(p_point))::varchar, NULL::double precision, NULL::double precision, NULL::double precision, NULL::double precision, NULL::text;
        RETURN;
    END IF;

    v_point :=
        CASE
            WHEN ST_SRID(p_point) = 0 THEN ST_SetSRID(ST_Force2D(p_point), 4326)
            WHEN ST_SRID(p_point) = 4326 THEN ST_Force2D(p_point)
            ELSE ST_Transform(ST_Force2D(p_point), 4326)
        END::geometry(Point, 4326);

    v_d := GREATEST(COALESCE(p_sample_m, 30.0), 0.1);

    zc := (SELECT v.elevation FROM public.gis_dem_value_at_point(v_point, p_dem_table) v WHERE v.code = 200 LIMIT 1);
    zn := (SELECT v.elevation FROM public.gis_dem_value_at_point(ST_Project(v_point::geography, v_d, radians(0))::geometry, p_dem_table) v WHERE v.code = 200 LIMIT 1);
    ze := (SELECT v.elevation FROM public.gis_dem_value_at_point(ST_Project(v_point::geography, v_d, radians(90))::geometry, p_dem_table) v WHERE v.code = 200 LIMIT 1);
    zs := (SELECT v.elevation FROM public.gis_dem_value_at_point(ST_Project(v_point::geography, v_d, radians(180))::geometry, p_dem_table) v WHERE v.code = 200 LIMIT 1);
    zw := (SELECT v.elevation FROM public.gis_dem_value_at_point(ST_Project(v_point::geography, v_d, radians(270))::geometry, p_dem_table) v WHERE v.code = 200 LIMIT 1);

    IF zn IS NULL OR zs IS NULL OR ze IS NULL OR zw IS NULL THEN
        RETURN QUERY SELECT 400, '周边采样点无有效DEM高程'::varchar, zc, NULL::double precision, NULL::double precision, NULL::double precision, NULL::text;
        RETURN;
    END IF;

    dzdx := (ze - zw) / (2.0 * v_d);
    dzdy := (zn - zs) / (2.0 * v_d);
    aspect := mod(degrees(atan2(dzdx, dzdy)) + 360.0, 360.0);

    RETURN QUERY SELECT
        200 AS code,
        '执行成功'::varchar AS msg,
        zc AS elevation,
        degrees(atan(sqrt(dzdx * dzdx + dzdy * dzdy))) AS slope_degree,
        sqrt(dzdx * dzdx + dzdy * dzdy) * 100.0 AS slope_percent,
        aspect AS aspect_degree,
        CASE
            WHEN aspect >= 337.5 OR aspect < 22.5 THEN '北'
            WHEN aspect < 67.5 THEN '东北'
            WHEN aspect < 112.5 THEN '东'
            WHEN aspect < 157.5 THEN '东南'
            WHEN aspect < 202.5 THEN '南'
            WHEN aspect < 247.5 THEN '西南'
            WHEN aspect < 292.5 THEN '西'
            ELSE '西北'
        END AS aspect_name;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_slope_aspect_at_point(geometry, double precision, text) IS '点位坡度和坡向近似分析';


-- =============================================================================

-- 4.2 gis_dem_slope_risk_at_point
-- 函数名称：gis_dem_slope_risk_at_point
-- 函数功能：根据点位坡度输出坡度风险等级。
-- 使用场景：起降点坡度风险提示、作业点地形安全判断、地图点位风险标注。
-- 实时调用：适合实时调用，依赖单点坡度坡向计算。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_slope_risk_at_point');
-- =============================================================================
-- 函数名称：gis_dem_slope_risk_at_point
-- 函数功能：根据点位坡度输出坡度风险等级。
-- 入参说明：
--   1. p_point     Point geometry。
--   2. p_sample_m  周边采样距离，单位米；默认 30。
--   3. p_dem_table 可选 DEM 表名；为空时按 p_point 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, elevation, slope_degree, slope_percent, risk_level)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_slope_risk_at_point(
    p_point geometry,
    p_sample_m double precision DEFAULT 30.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, elevation double precision, slope_degree double precision, slope_percent double precision, risk_level text)
LANGUAGE sql
STABLE
AS $$
    SELECT s.code, s.msg, s.elevation, s.slope_degree, s.slope_percent,
        CASE
            WHEN s.slope_degree IS NULL THEN '未知'
            WHEN s.slope_degree < 5 THEN '平缓'
            WHEN s.slope_degree < 15 THEN '缓坡'
            WHEN s.slope_degree < 30 THEN '陡坡'
            ELSE '极陡坡'
        END
    FROM public.gis_dem_slope_aspect_at_point(p_point, p_sample_m, p_dem_table) s;
$$;
COMMENT ON FUNCTION public.gis_dem_slope_risk_at_point(geometry, double precision, text) IS '点位坡度风险等级';

-- =============================================================================

-- 4.3 gis_dem_viewshed_prepare_point
-- 函数名称：gis_dem_viewshed_prepare_point
-- 函数功能：准备通视分析观察点参数。
-- 使用场景：通视分析前置参数整理、观察点高度计算、外部视域分析工具入参准备。
-- 实时调用：适合实时调用，本函数只准备观察点高程和参数，不执行完整通视计算。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_viewshed_prepare_point');
-- =============================================================================
-- 函数名称：gis_dem_viewshed_prepare_point
-- 函数功能：准备通视分析观察点参数。
-- 入参说明：
--   1. p_point             观察点 Point。
--   2. p_observer_height_m 观察者离地高度，单位米；默认 1.7。
--   3. p_target_height_m   目标离地高度，单位米；默认 0。
--   4. p_dem_table         可选 DEM 表名；为空时按 p_point 自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, ground_elevation, observer_elevation, target_height_m, geom)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_viewshed_prepare_point(
    p_point geometry,
    p_observer_height_m double precision DEFAULT 1.7,
    p_target_height_m double precision DEFAULT 0.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, ground_elevation double precision, observer_elevation double precision, target_height_m double precision, geom geometry(Point, 4326))
LANGUAGE sql
STABLE
AS $$
    SELECT
        200,
        '执行成功'::varchar,
        (SELECT v.elevation FROM public.gis_dem_value_at_point(p_point, p_dem_table) v WHERE v.code = 200 LIMIT 1),
        (SELECT v.elevation FROM public.gis_dem_value_at_point(p_point, p_dem_table) v WHERE v.code = 200 LIMIT 1) + COALESCE(p_observer_height_m, 0),
        COALESCE(p_target_height_m, 0),
        CASE WHEN ST_SRID(p_point) = 4326 THEN ST_Force2D(p_point)::geometry(Point, 4326)
             WHEN ST_SRID(p_point) = 0 THEN ST_SetSRID(ST_Force2D(p_point), 4326)::geometry(Point, 4326)
             ELSE ST_Transform(ST_Force2D(p_point), 4326)::geometry(Point, 4326) END;
$$;
COMMENT ON FUNCTION public.gis_dem_viewshed_prepare_point(geometry, double precision, double precision, text) IS '通视分析观察点参数准备';

-- =============================================================================

-- 4.4 gis_dem_obstacle_clearance_by_line
-- 函数名称：gis_dem_obstacle_clearance_by_line
-- 函数功能：沿带 Z 航线采样，计算每个采样点相对 DEM 地面的离地净空。
-- 使用场景：无人机航线净空校验、飞行高度复核、低空通道安全分析。
-- 实时调用：短航线适合实时调用；长航线或小采样间隔会产生大量点，建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_obstacle_clearance_by_line');
-- =============================================================================
-- 函数名称：gis_dem_obstacle_clearance_by_line
-- 函数功能：沿带 Z 航线采样，计算每个采样点相对 DEM 地面的离地净空。
-- 入参说明：
--   1. p_line_z    LineStringZ；Z 值表示飞行高度或绝对高度。
--   2. p_step_m    采样间隔，单位米；默认 100。
--   3. p_dem_table 可选 DEM 表名；为空时按航线范围自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, seq, distance_m, geom, flight_altitude, ground_elevation, clearance_m)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_obstacle_clearance_by_line(
    p_line_z geometry,
    p_step_m double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, seq integer, distance_m double precision, geom geometry(Point, 4326), flight_altitude double precision, ground_elevation double precision, clearance_m double precision)
LANGUAGE sql
STABLE
AS $$
    WITH line2d AS (
        SELECT CASE WHEN ST_SRID(p_line_z)=0 THEN ST_SetSRID(ST_Force2D(p_line_z),4326)
                    WHEN ST_SRID(p_line_z)=4326 THEN ST_Force2D(p_line_z)
                    ELSE ST_Transform(ST_Force2D(p_line_z),4326) END AS geom2d,
               p_line_z AS geomz
    ),
    p AS (
        SELECT pr.*, ST_LineLocatePoint(l.geom2d, pr.geom) AS frac, l.geomz
        FROM line2d l CROSS JOIN LATERAL public.gis_dem_profile_by_line(l.geom2d, p_step_m, p_dem_table) pr
        WHERE pr.code = 200
    )
    SELECT 200, '执行成功'::varchar, p.seq, p.distance_m, p.geom,
        COALESCE(ST_Z(ST_LineInterpolatePoint(geomz, frac)), 0) AS flight_altitude,
        elevation AS ground_elevation,
        COALESCE(ST_Z(ST_LineInterpolatePoint(geomz, frac)), 0) - elevation AS clearance_m
    FROM p;
$$;
COMMENT ON FUNCTION public.gis_dem_obstacle_clearance_by_line(geometry, double precision, text) IS '航线离地净空分析';

-- =============================================================================

-- 4.5 gis_dem_low_clearance_segments
-- 函数名称：gis_dem_low_clearance_segments
-- 函数功能：识别带 Z 航线中低于安全离地高度的采样点。
-- 使用场景：航线低净空告警、飞行安全审查、输出需要调整高度的风险采样点。
-- 实时调用：短航线适合实时调用；依赖航线净空采样，长航线建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_low_clearance_segments');
-- =============================================================================
-- 函数名称：gis_dem_low_clearance_segments
-- 函数功能：识别带 Z 航线中低于安全离地高度的采样点。
-- 入参说明：
--   1. p_line_z           LineStringZ；Z 值表示飞行高度或绝对高度。
--   2. p_safe_clearance_m 安全离地高度阈值，单位米；默认 120。
--   3. p_step_m           采样间隔，单位米；默认 100。
--   4. p_dem_table        可选 DEM 表名；为空时按航线范围自动解析 DEM 表。
-- 返回值：
--   TABLE(code, msg, seq, distance_m, geom, clearance_m, risk_level)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_low_clearance_segments(
    p_line_z geometry,
    p_safe_clearance_m double precision DEFAULT 120.0,
    p_step_m double precision DEFAULT 100.0,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, seq integer, distance_m double precision, geom geometry(Point, 4326), clearance_m double precision, risk_level text)
LANGUAGE sql
STABLE
AS $$
    SELECT c.code, c.msg, c.seq, c.distance_m, c.geom, c.clearance_m,
        CASE
            WHEN c.clearance_m IS NULL THEN '未知'
            WHEN c.clearance_m < 0 THEN '撞地风险'
            WHEN c.clearance_m < p_safe_clearance_m THEN '低净空'
            ELSE '安全'
        END
    FROM public.gis_dem_obstacle_clearance_by_line(p_line_z, p_step_m, p_dem_table) c
    WHERE c.code = 200 AND (c.clearance_m IS NULL OR c.clearance_m < p_safe_clearance_m);
$$;
COMMENT ON FUNCTION public.gis_dem_low_clearance_segments(geometry, double precision, double precision, text) IS '识别低于安全离地高度的航线采样点';


-- =============================================================================

-- 5.1 gis_dem_generate_contour_table
-- 函数名称：gis_dem_generate_contour_table
-- 函数功能：通过 PostGIS Raster 的 ST_Contour 生成等高线矢量表。
-- 使用场景：离线生产 10m、50m、100m 等高线图层，供 GeoServer 发布和前端叠加展示。
-- 实时调用：不建议实时调用，应作为离线数据生产或后台任务执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_generate_contour_table');
-- =============================================================================
-- 函数名称：gis_dem_generate_contour_table
-- 函数功能：通过 PostGIS Raster 的 ST_Contour 生成等高线矢量表。
-- 入参说明：
--   1. p_interval     等高距；默认 50。
--   2. p_target_table 目标等高线表名；默认 public.gis_dem_henan_contour。
--   3. p_dem_table    DEM 栅格表名；默认 public.gis_dem_henan。
-- 返回值：
--   TABLE(code, msg, result)，result 为生成完成提示。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_generate_contour_table(
    p_interval double precision DEFAULT 50.0,
    p_target_table text DEFAULT 'public.gis_dem_henan_contour',
    p_dem_table text DEFAULT 'public.gis_dem_henan'
)
RETURNS TABLE(code integer, msg varchar, result text)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_dem_reg regclass;
    v_target text;
BEGIN
    v_dem_reg := COALESCE(to_regclass(p_dem_table), to_regclass(format('public.%I', p_dem_table)));
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, format('DEM表不存在: %s', p_dem_table)::varchar, NULL::text;
        RETURN;
    END IF;
    v_target := p_target_table;
    EXECUTE format('DROP TABLE IF EXISTS %s', v_target);
    EXECUTE format($sql$
        CREATE TABLE %s AS
        SELECT row_number() OVER ()::bigint AS id,
               c.value::double precision AS elevation,
               ST_Multi(c.geom)::geometry(MultiLineString, 4326) AS geom
        FROM %s r
        CROSS JOIN LATERAL ST_Contour(r.rast, 1, %L::double precision, 0.0) c
        WHERE c.geom IS NOT NULL AND NOT ST_IsEmpty(c.geom)
    $sql$, v_target, v_dem_reg, GREATEST(COALESCE(p_interval,50.0),0.000001));
    EXECUTE format('ALTER TABLE %s ADD PRIMARY KEY (id)', v_target);
    EXECUTE format('CREATE INDEX ON %s USING gist (geom)', v_target);
    EXECUTE format('CREATE INDEX ON %s (elevation)', v_target);
    EXECUTE format('ANALYZE %s', v_target);
    RETURN QUERY SELECT 200, '执行成功'::varchar, format('等高线表生成完成: %s, interval=%s', v_target, p_interval);
END;
$$;
COMMENT ON FUNCTION public.gis_dem_generate_contour_table(double precision, text, text) IS '通过ST_Contour生成等高线表';

-- =============================================================================

-- 5.2 gis_dem_water_flow_prepare
-- 函数名称：gis_dem_water_flow_prepare
-- 函数功能：输出水文分析前需要了解的 DEM 基础参数。
-- 使用场景：水文处理前检查 DEM 范围、分辨率、坐标系和瓦片数量，辅助后续外部工具处理。
-- 实时调用：可以实时调用，但通常作为水文分析预处理或系统检查步骤。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_water_flow_prepare');
-- =============================================================================
-- 函数名称：gis_dem_water_flow_prepare
-- 函数功能：输出水文分析前需要了解的 DEM 基础参数。
-- 入参说明：
--   1. p_dem_table DEM 栅格表名；默认 public.gis_dem_henan。
-- 返回值：
--   TABLE(code, msg, dem_table, dem_srid, tile_count, pixel_size_x, pixel_size_y, extent)。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_water_flow_prepare(
    p_dem_table text DEFAULT 'public.gis_dem_henan'
)
RETURNS TABLE(code integer, msg varchar, dem_table text, dem_srid integer, tile_count bigint, pixel_size_x double precision, pixel_size_y double precision, extent geometry)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg regclass;
BEGIN
    v_dem_reg := COALESCE(to_regclass(p_dem_table), to_regclass(format('public.%I', p_dem_table)));
    IF v_dem_reg IS NULL THEN
        RETURN QUERY SELECT 400, format('DEM表不存在: %s', p_dem_table)::varchar, NULL::text, NULL::integer, NULL::bigint, NULL::double precision, NULL::double precision, NULL::geometry;
        RETURN;
    END IF;
    RETURN QUERY EXECUTE format($sql$
        SELECT 200 AS code, '执行成功'::varchar AS msg, %L::text, ST_SRID(rast), COUNT(*)::bigint, AVG(abs(ST_ScaleX(rast))), AVG(abs(ST_ScaleY(rast))),
               ST_Envelope(ST_Collect(ST_ConvexHull(rast))) AS extent
        FROM %s
        WHERE rast IS NOT NULL
        GROUP BY ST_SRID(rast)
    $sql$, v_dem_reg::text, v_dem_reg);
END;
$$;
COMMENT ON FUNCTION public.gis_dem_water_flow_prepare(text) IS '返回水文分析预处理所需DEM范围、分辨率、SRID等参数';

-- =============================================================================

-- 6.1 gis_dem_point_with_elevation
-- 函数名称：gis_dem_point_with_elevation
-- 函数功能：为 Point 或 MultiPoint 补充 DEM 高程 Z 值。
-- 使用场景：点位数据补地面高程、兴趣点三维化、地图点击结果补 Z 值。
-- 实时调用：适合实时调用，尤其适合点和少量多点补高程。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_point_with_elevation');
-- =============================================================================
-- 函数名称：gis_dem_point_with_elevation
-- 函数功能：为 Point 或 MultiPoint 补充 DEM 高程 Z 值。
-- 入参说明：
--   1. p_point     Point 或 MultiPoint geometry。
--   2. p_dem_table 可选 DEM 表名；为空时由 6.1 核心函数自动解析。
-- 返回值：
--   TABLE(code, msg, geom)，geom 返回 PointZ 或 MultiPointZ。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_point_with_elevation(
    p_point geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, geom geometry)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_point IS NULL THEN
        RETURN QUERY SELECT 400, '输入geometry为空'::varchar, NULL::geometry;
        RETURN;
    END IF;
    IF ST_GeometryType(ST_Force2D(p_point)) NOT IN ('ST_Point', 'ST_MultiPoint') THEN
        RETURN QUERY SELECT 400, format('只支持 Point/MultiPoint，当前类型: %s', ST_GeometryType(p_point))::varchar, NULL::geometry;
        RETURN;
    END IF;
    RETURN QUERY SELECT 200, '执行成功'::varchar, public.gis_dem_elevation_base(p_point, p_dem_table);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_point_with_elevation(geometry, text) IS '点/多点补DEM高程';

-- =============================================================================

-- 6.2 gis_dem_line_with_elevation
-- 函数名称：gis_dem_line_with_elevation
-- 函数功能：为 LineString 或 MultiLineString 顶点补充 DEM 高程 Z 值。
-- 使用场景：道路、航线、管线等线要素按顶点补地面高程，生成三维线路。
-- 实时调用：短线或顶点较少时适合实时调用；复杂长线建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_line_with_elevation');
-- =============================================================================
-- 函数名称：gis_dem_line_with_elevation
-- 函数功能：为 LineString 或 MultiLineString 顶点补充 DEM 高程 Z 值。
-- 入参说明：
--   1. p_line      LineString 或 MultiLineString geometry。
--   2. p_dem_table 可选 DEM 表名；为空时由 6.1 核心函数自动解析。
-- 返回值：
--   TABLE(code, msg, geom)，geom 返回 LineStringZ 或 MultiLineStringZ。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_line_with_elevation(
    p_line geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, geom geometry)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_line IS NULL THEN
        RETURN QUERY SELECT 400, '输入geometry为空'::varchar, NULL::geometry;
        RETURN;
    END IF;
    IF ST_GeometryType(ST_Force2D(p_line)) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT 400, format('只支持 LineString/MultiLineString，当前类型: %s', ST_GeometryType(p_line))::varchar, NULL::geometry;
        RETURN;
    END IF;
    RETURN QUERY SELECT 200, '执行成功'::varchar, public.gis_dem_elevation_base(p_line, p_dem_table);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_line_with_elevation(geometry, text) IS '线/多线补DEM高程';

-- =============================================================================

-- 6.3 gis_dem_polygon_with_elevation
-- 函数名称：gis_dem_polygon_with_elevation
-- 函数功能：为 Polygon 或 MultiPolygon 边界顶点补充 DEM 高程 Z 值。
-- 使用场景：作业区、行政区、电子围栏边界补高程，生成带 Z 面要素。
-- 实时调用：小面或顶点较少时可实时调用；复杂面建议后台执行。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_polygon_with_elevation');
-- =============================================================================
-- 函数名称：gis_dem_polygon_with_elevation
-- 函数功能：为 Polygon 或 MultiPolygon 边界顶点补充 DEM 高程 Z 值。
-- 入参说明：
--   1. p_polygon   Polygon 或 MultiPolygon geometry。
--   2. p_dem_table 可选 DEM 表名；为空时由 6.1 核心函数自动解析。
-- 返回值：
--   TABLE(code, msg, geom)，geom 返回 PolygonZ 或 MultiPolygonZ。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_polygon_with_elevation(
    p_polygon geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, geom geometry)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_polygon IS NULL THEN
        RETURN QUERY SELECT 400, '输入geometry为空'::varchar, NULL::geometry;
        RETURN;
    END IF;
    IF ST_GeometryType(ST_Force2D(p_polygon)) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        RETURN QUERY SELECT 400, format('只支持 Polygon/MultiPolygon，当前类型: %s', ST_GeometryType(p_polygon))::varchar, NULL::geometry;
        RETURN;
    END IF;
    RETURN QUERY SELECT 200, '执行成功'::varchar, public.gis_dem_elevation_base(p_polygon, p_dem_table);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_polygon_with_elevation(geometry, text) IS '面/多面补DEM高程';

-- =============================================================================

-- 6.4 gis_dem_geom_with_elevation
-- 函数名称：gis_dem_geom_with_elevation
-- 函数功能：根据输入 geometry 类型统一补充 DEM 高程 Z 值。
-- 使用场景：接口层不区分点线面时统一补高程，由 6.1 核心函数按 geometry 类型处理。
-- 实时调用：是否适合实时调用取决于输入 geometry 复杂度；点、短线、小面适合实时调用。
-- =============================================================================
-- 删除函数
SELECT public.gis_drop_function('gis_dem_geom_with_elevation');
-- =============================================================================
-- 函数名称：gis_dem_geom_with_elevation
-- 函数功能：根据输入 geometry 类型统一补充 DEM 高程 Z 值。
-- 入参说明：
--   1. p_geom      支持 6.1 核心函数可处理的 geometry。
--   2. p_dem_table 可选 DEM 表名；为空时由 6.1 核心函数自动解析。
-- 返回值：
--   TABLE(code, msg, geom)，geom 返回与输入类型对应的带 Z geometry。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_dem_geom_with_elevation(
    p_geom geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS TABLE(code integer, msg varchar, geom geometry)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_geom IS NULL THEN
        RETURN QUERY SELECT 400, '输入geometry为空'::varchar, NULL::geometry;
        RETURN;
    END IF;
    RETURN QUERY SELECT 200, '执行成功'::varchar, public.gis_dem_elevation_base(p_geom, p_dem_table);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_geom_with_elevation(geometry, text) IS '任意支持geometry补DEM高程';


-- ======================================调用示例=======================================
-- 说明：调用示例顺序与头部函数分类、正文函数创建顺序一一对应。

-- 基础查询
-- 1.1 gis_dem_resolve_table：按点位自动解析 DEM 表。
-- SELECT * FROM public.gis_dem_resolve_table(
--   ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326),
--   NULL
-- );
--
-- 1.2 gis_dem_value_at_point：查询单点 DEM 高程。
-- SELECT * FROM public.gis_dem_value_at_point(
--   ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
-- );
--
-- 1.3 gis_dem_extent：查询 DEM 覆盖范围、SRID 和瓦片数量。
-- SELECT code, msg, dem_table, dem_srid, tile_count, ST_AsGeoJSON(geom) AS geom_geojson
-- FROM public.gis_dem_extent('public.gis_dem_henan', 4326);

-- 区域分析
-- 2.1 gis_dem_stats_by_polygon：统计面范围内 DEM 高程分布。
-- SELECT * FROM public.gis_dem_stats_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326)
-- );
--
-- 2.2 gis_dem_hypsometric_by_polygon：按高程间隔统计面范围内像元数量。
-- SELECT * FROM public.gis_dem_hypsometric_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326),
--   100
-- );
--
-- 2.3 gis_dem_minmax_points_by_polygon：查询面范围内最低点和最高点。
-- SELECT code, msg, point_type, elevation, ST_AsGeoJSON(geom) AS geom_geojson
-- FROM public.gis_dem_minmax_points_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326)
-- );
--
-- 2.4 gis_dem_relative_height_by_polygon：统计区域相对高差。
-- SELECT * FROM public.gis_dem_relative_height_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326)
-- );
--
-- 2.5 gis_dem_terrain_relief_by_grid：按规则网格统计地形起伏度。
-- SELECT code, msg, grid_id, min_elevation, max_elevation, relative_height, ST_AsGeoJSON(geom) AS geom_geojson
-- FROM public.gis_dem_terrain_relief_by_grid(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326),
--   0.05
-- );
--
-- 2.6 gis_dem_elevation_risk_by_polygon：输出区域高程起伏风险等级。
-- SELECT * FROM public.gis_dem_elevation_risk_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326)
-- );
--
-- 2.7 gis_dem_extract_points_by_polygon：提取面范围内 DEM 像元中心点。
-- SELECT code, msg, seq, elevation, ST_AsGeoJSON(geom) AS geom_geojson
-- FROM public.gis_dem_extract_points_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326),
--   1000
-- );
--
-- 2.8 gis_dem_sample_grid_by_polygon：生成规则采样点并查询高程。
-- SELECT code, msg, seq, elevation, ST_AsGeoJSON(geom) AS geom_geojson
-- FROM public.gis_dem_sample_grid_by_polygon(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326),
--   0.01
-- );

-- 线路分析
-- 3.1 gis_dem_profile_by_line：沿线生成高程剖面。
-- SELECT * FROM public.gis_dem_profile_by_line(
--   ST_GeomFromText('LINESTRING(113.6 34.7,113.8 34.9)', 4326),
--   100
-- );
--
-- 3.2 gis_dem_profile_stats_by_line：统计沿线剖面指标。
-- SELECT * FROM public.gis_dem_profile_stats_by_line(
--   ST_GeomFromText('LINESTRING(113.6 34.7,113.8 34.9)', 4326),
--   100
-- );
--
-- 3.3 gis_dem_route_climb_by_line：统计路线爬升下降。
-- SELECT * FROM public.gis_dem_route_climb_by_line(
--   ST_GeomFromText('LINESTRING(113.6 34.7,113.8 34.9)', 4326),
--   100
-- );
--
-- 3.4 gis_dem_cross_section_geojson：高程剖面输出 JSON。
-- SELECT * FROM public.gis_dem_cross_section_geojson(
--   ST_GeomFromText('LINESTRING(113.6 34.7,113.8 34.9)', 4326),
--   100
-- );

-- 坡度 / 航线安全
-- 4.1 gis_dem_slope_aspect_at_point：点位坡度坡向分析。
-- SELECT * FROM public.gis_dem_slope_aspect_at_point(
--   ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326),
--   30
-- );
--
-- 4.2 gis_dem_slope_risk_at_point：点位坡度风险等级。
-- SELECT * FROM public.gis_dem_slope_risk_at_point(
--   ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326),
--   30
-- );
--
-- 4.3 gis_dem_viewshed_prepare_point：通视分析观察点参数准备。
-- SELECT * FROM public.gis_dem_viewshed_prepare_point(
--   ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326),
--   1.7,
--   0
-- );
--
-- 4.4 gis_dem_obstacle_clearance_by_line：航线离地净空分析。
-- SELECT * FROM public.gis_dem_obstacle_clearance_by_line(
--   ST_GeomFromEWKT('SRID=4326;LINESTRING Z(113.6 34.7 300,113.8 34.9 350)'),
--   100
-- );
--
-- 4.5 gis_dem_low_clearance_segments：识别低净空航线采样点。
-- SELECT * FROM public.gis_dem_low_clearance_segments(
--   ST_GeomFromEWKT('SRID=4326;LINESTRING Z(113.6 34.7 300,113.8 34.9 350)'),
--   120,
--   100
-- );

-- 数据生产 / 预处理
-- 5.1 gis_dem_generate_contour_table：生成 50m 等高线表。
-- SELECT * FROM public.gis_dem_generate_contour_table(
--   50,
--   'public.gis_dem_henan_contour_50m',
--   'public.gis_dem_henan'
-- );
--
-- 5.2 gis_dem_water_flow_prepare：水文分析预处理参数。
-- SELECT * FROM public.gis_dem_water_flow_prepare('public.gis_dem_henan');

-- geometry 补高程
-- 6.1 gis_dem_point_with_elevation：点/多点补 DEM 高程。
-- SELECT ST_AsText(public.gis_dem_point_with_elevation(
--   ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
-- ));
--
-- 6.2 gis_dem_line_with_elevation：线/多线补 DEM 高程。
-- SELECT ST_AsText(public.gis_dem_line_with_elevation(
--   ST_GeomFromText('LINESTRING(113.6 34.7,113.8 34.9)', 4326)
-- ));
--
-- 6.3 gis_dem_polygon_with_elevation：面/多面补 DEM 高程。
-- SELECT ST_AsText(public.gis_dem_polygon_with_elevation(
--   ST_GeomFromText('POLYGON((113 34,114 34,114 35,113 35,113 34))', 4326)
-- ));
--
-- 6.4 gis_dem_geom_with_elevation：通用 geometry 补 DEM 高程。
-- SELECT ST_AsText(public.gis_dem_geom_with_elevation(
--   ST_GeomFromText('LINESTRING(113.6 34.7,113.8 34.9)', 4326)
-- ));

-- 连库执行本文件
-- DEV:
-- set PGPASSWORD=KtdpostSQL@2026!@#
-- psql -h 192.168.110.6 -p 5432 -U zhuoyi -d ktd_lx_2026gis -f "E:\CHAJIAN\dajiangData\PGSQL\函数\6.2DEM分析函数.sql"
--
-- TEST:
-- set PGPASSWORD=KtdpostSQL@2026!@#
-- psql -h 192.168.110.15 -p 5432 -U zhuoyi -d ktd_lx_2026gis -f "E:\CHAJIAN\dajiangData\PGSQL\函数\6.2DEM分析函数.sql"
--
-- 正式:
-- set PGPASSWORD=Ktd@postSQL@2026!@#
-- psql -h 101.201.32.79 -p 15432 -U zhuoyi -d ktd_lx_2026gis -f "E:\CHAJIAN\dajiangData\PGSQL\函数\6.2DEM分析函数.sql"









