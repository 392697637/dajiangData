-- =============================================================================
-- 函数名称：5.gis_uav_flight_deviation_line
-- 函数功能：按航飞模式和高度基准构造起飞、规划航线、返航及降落的完整三维航线
-- 函数描述：
--   1. 校验机库位置、机库距地高度、安全起飞高度、返航高度、航飞模式及规划航线。
--   A. p_is_altitude=false：将原航点距地高度减去机库距地高度，输出相对机库航线。
--   B. p_is_altitude=true：按相同相对机库逻辑构造航线，再给所有点统一加机库起飞点海拔（地面海拔+机库距地高度），输出海拔航线。
--   C. 模式1垂直爬升：先升至换算后首航点高度与安全起飞点高度的较大值，再平飞至首航点上方，安全点更高时垂直下降至首航点。
--   D. 模式2倾斜爬升：机库先垂直爬升到安全起飞高度，再直线飞向首航点。
--   E. 依次拼接起飞段、换算后的规划航线、末航点处升降至返航高度的垂直段、平飞返航段和垂直降落段。
-- 入参说明：
--   p_uav_location   机库所在地面三维位置，XY为WGS84经纬度，Z为地面海拔，不含机库距地高度。
--   p_ground_height  机库相对地面高度；地面机库传0。
--   p_safe_height    安全起飞高度，相对起飞点（机库）。
--   p_return_height  返航高度，相对机库。
--   p_route          规划航线，原航点Z为相对地面高度。
--   p_is_altitude    输出高度基准：false相对机库高度（默认），true海拔高度。
--   p_flight_mode    航飞模式：1垂直爬升（默认），2倾斜爬升。
-- 返回说明：
--   返回单个geometry值，实际为SRID=4326的LineStringZ；所有点的Z采用同一高度基准，单位：米。
-- 注意事项：
--   1. 本函数生成完整航线，供gis_uav_flight_deviation_check使用；不单独返回偏航或空域校验结果。
--   2. 两个分支均按业务约定忽略航点与机库之间的地形高差，不查询DEM；输出仅相差统一的机库起飞点海拔偏移。
--   3. 输入参数或航线连续性无效时抛出参数校验异常，不返回code/msg结果行。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
-- 统一删除public下同名旧函数及全部重载，再创建航飞模式位于最后的新签名；五参调用默认相对机库高度、垂直爬升。
SELECT public.gis_drop_function('public.gis_uav_flight_deviation_line');

-- =============================================================================
-- 函数介绍：5.gis_uav_flight_deviation_line
-- 主要作用：统一规划航点的高度基准，再按航飞模式生成从机库起飞到返回机库降落的完整三维航线。
-- 入参说明：
--   p_uav_location   机库所在地面位置；geometry；必填；非空PointZ，XY为经纬度，Z为有限的地面海拔高度（米），不含机库距地高度。
--   p_ground_height  机库相对地面高度；double precision；必填；非负有限值（米），地面机库传0。
--   p_safe_height    安全起飞高度；double precision；必填；相对机库的非负有限高度（米）。
--   p_return_height  返航高度；double precision；必填；相对机库的非负有限高度（米）。
--   p_route          原规划航线；geometry；必填；有效且非空的LineStringZ或MultiLineStringZ，原航点Z为距地高度（米）。
--   p_is_altitude    输出高度基准；boolean；选填，默认false；false=相对机库高度，true=海拔高度，不能为NULL。
--   p_flight_mode    航飞模式；integer；选填，默认1；1=垂直爬升，2=倾斜爬升，不能为NULL。
-- 入参校验：
--   1. 机库和规划航线的SRID须为4326或0；SRID=0按WGS84解释，不执行坐标变换。
--   2. 所有经度须位于[-180,180]、纬度须位于[-90,90]，机库须包含有限Z，原航点须包含非负有限Z。
--   3. 机库距地高度、安全起飞高度、返航高度均不能为空、不能小于0，不能为NaN或正负Infinity。
--   4. 多段航线须按存储顺序在XYZ三维空间首尾衔接，不允许空航段、断开或自动反转航段。
--   5. 航飞模式仅允许1或2，不能为NULL；输出高度类型不能为NULL。
--   6. 两种输出类型的原航线Z均须为距地高度，不能直接传入海拔或相对机库高度。
-- 返回说明：
--   geometry          完整三维航线，实际为SRID=4326的LineStringZ；起点和终点均为机库点。
--   相对高度分支：机库点Z=0，规划航点Z=原航点Z-p_ground_height，安全点Z=p_safe_height，返航点Z=p_return_height。
--   海拔高度分支：机库起飞点海拔=ST_Z(p_uav_location)+p_ground_height；机库点Z=机库起飞点海拔。
--   规划航点Z=原航点Z-p_ground_height+机库起飞点海拔，安全点Z=机库起飞点海拔+p_safe_height，返航点Z=机库起飞点海拔+p_return_height。
-- 航飞模式说明：
--   1. 垂直爬升：机库 → 机库上方爬升点（首航点与安全点高度的较大值） → 必要时增加首航点上方同高度点 → 换算后的规划航线 → 末航点处返航高度点 → 机库上方返航点 → 机库。
--   2. 倾斜爬升：机库 → 机库上方安全起飞点 → 换算后的规划航线 → 末航点处返航高度点 → 机库上方返航点 → 机库。
-- 异常结果说明：
--   1. 参数或航线连续性无效时抛出参数校验异常，并说明具体错误。
--   2. 由gis_uav_flight_deviation_check调用时，上述异常转换为code=400、ischeck=false的校验结果。
-- 注意事项：
--   1. 输出允许负Z；所有Z统一表示所选高度基准，XY仍为WGS84经纬度，高度单位均为米。
--   2. 两个分支均不查询DEM，按业务约定忽略不同航点与机库之间的地形高差。
--   3. 海拔分支采用与相对分支相同的路径逻辑，各点Z统一加机库起飞点海拔（所在地面海拔+机库距地高度）；地面与遥测海拔须采用相同高程基准。
--   4. 保留原航点和航段的顺序与方向；返航先在末航点处垂直升降，再平飞回机库上方并垂直降落；末航点已在返航高度时不重复增加同位置点。
-- 依赖说明：PostGIS；两种高度输出均不依赖DEM查询函数或地形数据。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_uav_flight_deviation_line(
    p_uav_location geometry,
    p_ground_height double precision,
    p_safe_height double precision,
    p_return_height double precision,
    p_route geometry,
    p_is_altitude boolean DEFAULT false,
    p_flight_mode integer DEFAULT 1
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_route geometry;
    v_part record;
    v_previous_end geometry;
    v_points geometry[];
    v_point_index integer;
    v_point_height double precision;
    v_home_height double precision;
    v_home geometry;
    v_takeoff geometry;
    v_return geometry;
    v_last_point geometry;
    v_takeoff_height double precision;
BEGIN
    -- 一、机库所在地面位置须有有效经纬度和地面海拔Z；即使输出相对高度，也先校验完整的地面三维位置。
    IF p_uav_location IS NULL OR ST_IsEmpty(p_uav_location)
       OR GeometryType(p_uav_location) <> 'POINT' THEN
        RAISE EXCEPTION USING MESSAGE = '机库位置必须为非空的WGS84三维点';
    END IF;
    IF ST_SRID(p_uav_location) NOT IN (0, 4326)
       OR NOT (ST_X(p_uav_location) BETWEEN -180 AND 180)
       OR NOT (ST_Y(p_uav_location) BETWEEN -90 AND 90)
       OR ST_Z(p_uav_location) IS NULL
       OR ST_Z(p_uav_location)::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION USING MESSAGE = '机库位置须使用WGS84经纬度并包含有限的地面海拔高度';
    END IF;
    -- 这三个输入高度均要求非负有限；换算后的航点Z则可以为负，两者校验范围不同。
    IF EXISTS (
        SELECT 1 FROM (VALUES (p_ground_height), (p_safe_height), (p_return_height)) h(value)
        WHERE h.value IS NULL OR h.value < 0 OR h.value::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION USING MESSAGE = '机库距地高度、安全起飞高度及返航高度必须为非负有限值（米）';
    END IF;
    IF p_flight_mode IS NULL OR p_flight_mode NOT IN (1, 2) THEN
        RAISE EXCEPTION USING MESSAGE = '航飞模式必须为1（垂直爬升）或2（倾斜爬升）';
    END IF;
    IF p_is_altitude IS NULL THEN
        RAISE EXCEPTION USING MESSAGE = '航线高度类型不能为空：false为相对机库高度，true为海拔高度';
    END IF;
    -- 二、原航线须为有效三维线，原Z表示距地高度，不能用海拔或相对机库高度直接传入。
    IF p_route IS NULL OR ST_IsEmpty(p_route)
       OR GeometryType(p_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
       OR NOT ST_IsValid(p_route) THEN
        RAISE EXCEPTION USING MESSAGE = '规划航线必须为有效且非空的三维LineString或MultiLineString';
    END IF;
    IF ST_SRID(p_route) NOT IN (0, 4326) OR EXISTS (
        SELECT 1 FROM ST_DumpPoints(p_route) d
        WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
           OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)
           OR ST_Z(d.geom) IS NULL OR ST_Z(d.geom) < 0
           OR ST_Z(d.geom)::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION USING MESSAGE = '规划航点须使用WGS84经纬度并包含非负有限的相对地面高度';
    END IF;
    -- 前面已限制SRID为0或4326；此处统一标记并保留XYZ，不执行经纬度坐标变换。
    v_route := ST_SetSRID(ST_Force3DZ(p_route), 4326);
    -- 多段航线不能凭空补线，且不能用ST_LineMerge改变原有航段的方向和顺序。
    FOR v_part IN SELECT d.geom FROM ST_Dump(v_route) d ORDER BY d.path LOOP
        IF ST_IsEmpty(v_part.geom) THEN
            RAISE EXCEPTION USING MESSAGE = '多段规划航线不能包含空航段';
        END IF;
        IF v_previous_end IS NOT NULL AND (
            ST_X(v_previous_end) <> ST_X(ST_StartPoint(v_part.geom))
            OR ST_Y(v_previous_end) <> ST_Y(ST_StartPoint(v_part.geom))
            OR ST_Z(v_previous_end) <> ST_Z(ST_StartPoint(v_part.geom))
        ) THEN
            RAISE EXCEPTION USING MESSAGE = '多段规划航线必须按飞行顺序在三维空间首尾衔接';
        END IF;
        v_previous_end := ST_EndPoint(v_part.geom);
    END LOOP;
    -- 三、两种输出均按相对机库逻辑换算；海拔输出以地面海拔加机库距地高度作为起飞点海拔。
    v_home_height := CASE WHEN p_is_altitude THEN ST_Z(p_uav_location) + p_ground_height ELSE 0 END;
    -- 按原几何路径顺序保存航点，避免排序、合线或去重改变飞行路线。
    SELECT array_agg(d.geom ORDER BY d.path) INTO v_points FROM ST_DumpPoints(v_route) d;
    FOR v_point_index IN 1..array_length(v_points, 1) LOOP
        -- 先减机库距地高度取得相对机库高度，再加所选基准；两种输出均忽略地形高差，不查询DEM。
        v_point_height := ST_Z(v_points[v_point_index]) - p_ground_height + v_home_height;
        -- 经纬度保持原值，只替换高度；最终所有规划航点采用同一高度基准。
        v_points[v_point_index] := ST_SetSRID(ST_MakePoint(
            ST_X(v_points[v_point_index]), ST_Y(v_points[v_point_index]), v_point_height
        ), 4326);
    END LOOP;
    -- 四、建立同基准机库起飞点：相对模式以机库为0，海拔模式为所在地面海拔加机库距地高度。
    v_home := ST_SetSRID(ST_MakePoint(ST_X(p_uav_location), ST_Y(p_uav_location), v_home_height), 4326);
    -- 五、先计算安全起飞点高度；模式1爬升至安全点与首航点高度的较大值，模式2直接采用安全点。
    v_takeoff_height := v_home_height + p_safe_height;
    IF p_flight_mode = 1 THEN
        IF ST_Z(v_points[1]) < v_takeoff_height THEN
            -- 安全点更高时，增加首航点正上方的同高度点，先平飞到该点，再垂直下降至原首航点。
            v_points := ARRAY[ST_SetSRID(ST_MakePoint(
                ST_X(v_points[1]), ST_Y(v_points[1]), v_takeoff_height
            ), 4326)] || v_points;
        ELSE
            -- 首航点不低于安全点时，保持升至首航点高度后直接平飞的路径。
            v_takeoff_height := ST_Z(v_points[1]);
        END IF;
    END IF;
    v_takeoff := ST_SetSRID(ST_MakePoint(ST_X(p_uav_location), ST_Y(p_uav_location), v_takeoff_height), 4326);
    -- 返航高度始终相对机库，两种航飞模式均先在末航点处垂直升降至返航高度，再平飞回机库上方。
    v_return := ST_SetSRID(ST_MakePoint(ST_X(p_uav_location), ST_Y(p_uav_location), v_home_height + p_return_height), 4326);
    v_last_point := v_points[array_length(v_points, 1)];
    IF ST_Z(v_last_point) <> ST_Z(v_return) THEN
        -- 在末航点经纬度处补充返航高度点；已处于返航高度时，原末航点直接作为平飞起点。
        v_points := v_points || ARRAY[ST_SetSRID(ST_MakePoint(
            ST_X(v_last_point), ST_Y(v_last_point), ST_Z(v_return)
        ), 4326)];
    END IF;
    -- 六、连接起飞、全部规划航点、末航点处返航高度点、机库上方返航点和降落点。
    RETURN ST_MakeLine(ARRAY[v_home, v_takeoff] || v_points || ARRAY[v_return, v_home]);
END;
$$;
COMMENT ON FUNCTION public.gis_uav_flight_deviation_line(geometry, double precision, double precision, double precision, geometry, boolean, integer)
IS '按航飞模式构造机库起飞、规划航线、返航及降落的完整三维航线，默认垂直爬升，支持相对机库或海拔高度输出';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 1. 省略高度类型和航飞模式，默认垂直爬升、输出相对机库航线；所在地面海拔100米、距地20米，机库起飞点海拔120米，安全起飞60米、返航90米。
-- 原航点距地高度分别为120米、150米，换算后相对机库高度为100米、130米，垂直爬升至首航点高度100米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     60,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,100,100,130,90,90,0]，末航点先从130米垂直降到90米，再以90米高度平飞返航并降落。
--
-- 2. 倾斜爬升，输出海拔航线；按与相对高度相同的路径逻辑构造，再统一加机库起飞点海拔100+20=120米。
-- 安全起飞点海拔为120+60=180米，返航点海拔为120+90=210米；原航点海拔分别为120-20+120=220米、150-20+120=250米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     60,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326),
--     true,
--     2
-- ));
-- 返回Z序列为[120,180,220,250,210,210,120]，末航点先降到海拔210米，再平飞返航并降落，不需要DEM地形数据。
--
-- 3. 从已有任务读取起降参数和规划航线；第六参false输出相对机库航线，最后一参采用任务航飞模式。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     j.uav_location,
--     j.ground_height,
--     j.safe_height,
--     j.return_height,
--     j.plan_route_gemo,
--     false,
--     j.flight_mode
-- )) AS full_route
-- FROM public.bo_flight_job j
-- WHERE j.out_id = 'f6a024e15c604ce4a7dfd2f895c266fe' AND j.del_flag = false;

-- 4. 默认垂直爬升，安全起飞120米高于换算后的首航点100米；先升至120米，平飞到首航点上方，再垂直降到100米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     120,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,120,120,100,130,90,90,0]；第2至3点平飞，第3至4点在首航点经纬度处垂直下降，末航点再垂直降至90米后平飞返航。
