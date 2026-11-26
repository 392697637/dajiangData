-- =============================================================================
-- 文件：1灵犀聊城通用.sql
-- 内容：gis_write_error_log负责统一日志写入，gis_uav_flight_deviation_line负责完整三维航线构造。
-- 调用关系：空域区块实时校验及一键起飞校验均复用本文件函数；本文件不读取任务表或空域计划表。
-- 执行依赖：PostGIS、public.gis_drop_function(text)及public.gis_error_log日志表须已存在。
-- 高度约定：原规划航点Z始终表示相对机库高度；p_is_altitude只控制输出基准，不改变输入Z的含义。
-- =============================================================================

-- =============================================================================
-- 函数名称：5.gis_uav_flight_deviation_line
-- 函数功能：按航飞模式和高度基准构造起飞、规划航线、返航及降落的完整三维航线
-- 适用场景：供实时偏航校验、计划航线冲突校验及一键起飞航线冲突校验复用；本函数只生成几何，不判断空域、时间或任务状态。
-- 函数描述：
--   1. 校验机库位置、机库距地高度、安全起飞高度、返航高度、航飞模式及规划航线。
--   A. p_is_altitude=false：保留原航点相对机库高度，输出相对机库航线。
--   B. p_is_altitude=true：按相同相对机库逻辑构造航线，再给所有点统一加机库起飞点海拔（地面海拔+机库距地高度），输出海拔航线。
--   C. 模式1垂直爬升：先升至换算后首航点高度与安全起飞点高度的较大值，再平飞至首航点上方，安全点更高时垂直下降至首航点。
--   D. 模式2倾斜爬升：机库先垂直爬升到安全起飞高度，再直线飞向首航点。
--   E. 实际返航高度取末航点与配置返航高度的较大值；末航点较低时先垂直爬升，再平飞返航并垂直降落。
-- 入参说明：
--   p_uav_location   机库所在地面三维位置，XY为WGS84经纬度，Z为地面海拔，不含机库距地高度。
--   p_ground_height  机库相对地面高度；地面机库传0。
--   p_safe_height    安全起飞高度，相对起飞点（机库）。
--   p_return_height  配置返航高度，相对机库；实际返航高度不低于末航点。
--   p_route          规划航线，原航点Z为相对机库高度。
--   p_is_altitude    输出高度基准：false相对机库高度（默认），true海拔高度。
--   p_flight_mode    航飞模式：1垂直爬升（默认），2倾斜爬升。
-- 返回说明：
--   返回单个geometry值，实际为SRID=4326的LineStringZ；所有点的Z采用同一高度基准，单位：米。
-- 注意事项：
--   1. 本函数生成完整航线，供gis_uav_flight_deviation_check、gis_uav_flight_takeoff_check等校验函数使用；不单独返回偏航或空域校验结果。
--   2. 两个分支均按业务约定忽略航点与机库之间的地形高差，不查询DEM；输出仅相差统一的机库起飞点海拔偏移。
--   3. 输入参数或航线连续性无效时抛出参数校验异常，不返回code/msg结果行。
-- =============================================================================
-- =============================================================================
-- 辅助函数：gis_write_error_log
-- 作用说明：
--   1. 统一写入PG相关GIS错误日志。
--   2. 可供飞行审核及其他GIS函数内部复用。
--   3. 非业务审核接口，接口层无需直接调用。
-- 写入表：
--   public.gis_error_log(code, msg, sqlstring)
-- 参数说明：
--   p_code       日志分类：调用方常用200=业务记录、400=参数/业务错误、500=系统异常、600=函数调用或诊断信息。
--   p_msg        日志说明或错误提示；原样入库。
--   p_sqlstring  调用SQL或诊断文本，由调用方提供；本函数只保存，不执行其中的SQL。
-- 写入约定：
--   1. 不校验或重写入参，不创建日志表；仅向指定的三个字段插入一行，其余字段采用表自身默认值。
--   2. 与调用方使用同一事务，不单独提交；事务或所在异常块回滚时，相关日志写入也受回滚影响。
--   3. 不捕获日志表写入异常，由调用方决定错误处理方式；返回void表示没有业务结果行。
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
    -- 参数作为列值直接写入，p_sqlstring中的引号、JSON及SQL文本均作为普通日志内容保存。
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (p_code, p_msg, p_sqlstring);
END;
$$;

COMMENT ON FUNCTION public.gis_write_error_log(integer, text, text)
IS 'PG相关GIS错误日志写入函数';
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
--   p_return_height  配置返航高度；double precision；必填；相对机库的非负有限高度（米）；实际返航高度取其与末航点高度的较大值。
--   p_route          原规划航线；geometry；必填；有效且非空的LineStringZ或MultiLineStringZ，原航点Z为相对机库高度（米）。
--   p_is_altitude    输出高度基准；boolean；选填，默认false；false=相对机库高度，true=海拔高度，不能为NULL。
--   p_flight_mode    航飞模式；integer；选填，默认1；1=垂直爬升，2=倾斜爬升，不能为NULL。
-- 入参校验：
--   1. 机库和规划航线的SRID须为4326或0；SRID=0按WGS84解释，不执行坐标变换。
--   2. 所有经度须位于[-180,180]、纬度须位于[-90,90]，机库须包含有限Z，原航点须包含非负有限Z。
--   3. 机库距地高度、安全起飞高度、返航高度均不能为空、不能小于0，不能为NaN或正负Infinity。
--   4. 多段航线须按存储顺序在XYZ三维空间首尾衔接，不允许空航段、断开或自动反转航段。
--   5. 航飞模式仅允许1或2，不能为NULL；输出高度类型不能为NULL。
--   6. 两种输出类型的原航线Z均须为相对机库高度，不能直接传入海拔或距地高度。
-- 返回说明：
--   geometry          完整三维航线，实际为SRID=4326的LineStringZ；起点和终点均为机库点。
--   相对高度分支：机库点Z=0，规划航点Z=原航点Z，安全点Z=p_safe_height，返航点Z=max(末航点Z,p_return_height)。
--   海拔高度分支：机库起飞点海拔=ST_Z(p_uav_location)+p_ground_height；机库点Z=机库起飞点海拔。
--   规划航点Z=原航点Z+机库起飞点海拔，安全点Z=机库起飞点海拔+p_safe_height，返航点Z=max(换算后末航点Z,机库起飞点海拔+p_return_height)。
-- 航飞模式说明：
--   1. 垂直爬升：机库 → 机库上方爬升点（首航点与安全点高度的较大值） → 必要时增加首航点上方同高度点 → 换算后的规划航线 → 末航点处返航高度点 → 机库上方返航点 → 机库。
--   2. 倾斜爬升：机库 → 机库上方安全起飞点 → 换算后的规划航线 → 末航点处返航高度点 → 机库上方返航点 → 机库。
-- 异常结果说明：
--   1. 参数或航线连续性无效时抛出参数校验异常，并说明具体错误。
--   2. 由gis_uav_flight_deviation_check调用时，上述异常转换为code=400、ischeck=false的校验结果。
-- 注意事项：
--   1. 相对高度输出非负，海拔输出允许负Z；所有Z统一表示所选高度基准，XY仍为WGS84经纬度，高度单位均为米。
--   2. 两个分支均不查询DEM，按业务约定忽略不同航点与机库之间的地形高差。
--   3. 海拔分支采用与相对分支相同的路径逻辑，各点Z统一加机库起飞点海拔（所在地面海拔+机库距地高度）；地面与遥测海拔须采用相同高程基准。
--   4. 保留原航点和航段的顺序与方向；末航点低于配置返航高度时先垂直爬升，否则直接按末航点高度平飞返航；回到机库上方后垂直降落。
--   5. 只组合三维航点，不做投影、空间冲突、飞行时间或障碍物校验；后续距离计算由调用方选择米制坐标系。
--   6. 起飞、规划、返航位置重合时可出现连续相同点；本函数保留构造顺序，不额外删除重复点。
-- 日志与异常：入口先写一条600调用日志，sqlstring保存格式化后的调用SQL以便复现输入；日志与调用方共用事务，不单独提交。
--             参数、几何或航线连续性无效时直接抛出异常，由调用方转换为对应的参数错误结果。
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
VOLATILE
AS $$
DECLARE
    -- v_route是统一SRID后的原规划线；遍历部件时以v_previous_end校验下一部件的三维衔接。
    v_route geometry;
    v_part record;
    v_previous_end geometry;
    -- 按原几何路径展开并保存规划航点，随后在数组前后补充安全点或返航爬升点。
    v_points geometry[];
    v_point_index integer;
    v_point_height double precision;
    -- 相对分支为0，海拔分支为地面海拔+机库距地高度；作为全部航点共用的Z偏移。
    v_home_height double precision;
    -- 机库点、机库正上方起飞点、机库正上方返航点，三者XY相同，Z按阶段分别确定。
    v_home geometry;
    v_takeoff geometry;
    v_return geometry;
    v_last_point geometry;
    v_takeoff_height double precision;
    -- 入口日志文本；%L将几何EWKT、数值和布尔按SQL字面量格式化，NULL保留为NULL。
    v_log_sql text;
BEGIN
    -- 入口600日志先于参数校验；几何参数用EWKT文本记录，便于直接复现本次调用。
    v_log_sql := format(
        'SELECT public.gis_uav_flight_deviation_line(%L, %L, %L, %L, %L, %L, %L);',
        ST_AsEWKT(p_uav_location),
        p_ground_height::text,
        p_safe_height::text,
        p_return_height::text,
        ST_AsEWKT(p_route),
        p_is_altitude::text,
        p_flight_mode::text
    );
    PERFORM public.gis_write_error_log(600, 'gis_uav_flight_deviation_line', v_log_sql);

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
    -- 这三个输入高度均要求非负有限；海拔换算后的航点Z则可以为负，两者校验范围不同。
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
    -- 二、原航线须为有效三维线，原Z表示相对机库高度，不能用海拔或距地高度直接传入。
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
        RAISE EXCEPTION USING MESSAGE = '规划航点须使用WGS84经纬度并包含非负有限的相对机库高度';
    END IF;
    -- 前面已限制SRID为0或4326；此处统一标记并保留XYZ，不执行经纬度坐标变换。
    v_route := ST_SetSRID(ST_Force3DZ(p_route), 4326);
    -- 多段航线不能凭空补线，且不能用ST_LineMerge改变原有航段的方向和顺序。
    -- d.path确定部件原始顺序，衔接要求XYZ完全相等，不使用距离容差或端点吸附。
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
    -- 即使相对分支不使用地面海拔和距地高度换算，这些输入仍已通过前面的统一参数校验。
    v_home_height := CASE WHEN p_is_altitude THEN ST_Z(p_uav_location) + p_ground_height ELSE 0 END;
    -- 按原几何路径顺序保存航点，避免排序、合线或去重改变飞行路线。
    SELECT array_agg(d.geom ORDER BY d.path) INTO v_points FROM ST_DumpPoints(v_route) d;
    FOR v_point_index IN 1..array_length(v_points, 1) LOOP
        -- 原航点已相对机库；相对输出保留原Z，海拔输出加机库起飞点海拔，不再减机库距地高度。
        v_point_height := ST_Z(v_points[v_point_index]) + v_home_height;
        -- 经纬度保持原值，只替换高度；最终所有规划航点采用同一高度基准。
        v_points[v_point_index] := ST_SetSRID(ST_MakePoint(
            ST_X(v_points[v_point_index]), ST_Y(v_points[v_point_index]), v_point_height
        ), 4326);
    END LOOP;
    -- 四、建立同基准机库起飞点：相对模式以机库为0，海拔模式为所在地面海拔加机库距地高度。
    v_home := ST_SetSRID(ST_MakePoint(ST_X(p_uav_location), ST_Y(p_uav_location), v_home_height), 4326);
    -- 五、先计算安全起飞点高度；模式1爬升至安全点与首航点高度的较大值，模式2直接采用安全点。
    -- 两种模式均先从v_home垂直飞至v_takeoff；区别在于之后是平飞至首航点上方，还是直线斜飞至首航点。
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
    -- 模式2跳过上述模式1的首航点高度调整，起飞点保留配置的安全起飞高度。
    v_takeoff := ST_SetSRID(ST_MakePoint(ST_X(p_uav_location), ST_Y(p_uav_location), v_takeoff_height), 4326);
    -- 两种航飞模式均在同一高度基准下取末航点与配置返航高度的较大值，作为实际返航高度。
    v_last_point := v_points[array_length(v_points, 1)];
    -- v_return在机库上方；greatest保证返航不会先从末航点下降到较低的配置高度。
    v_return := ST_SetSRID(ST_MakePoint(
        ST_X(p_uav_location), ST_Y(p_uav_location),
        greatest(ST_Z(v_last_point), v_home_height + p_return_height)
    ), 4326);
    IF ST_Z(v_last_point) < ST_Z(v_return) THEN
        -- 末航点较低时在原经纬度处垂直爬升；较高或等高时直接平飞，不增加同位置点。
        v_points := v_points || ARRAY[ST_SetSRID(ST_MakePoint(
            ST_X(v_last_point), ST_Y(v_last_point), ST_Z(v_return)
        ), 4326)];
    END IF;
    -- 六、连接起飞、全部规划航点、必要的末航点爬升点、机库上方返航点和降落点。
    -- 最后一段由v_return垂直降至v_home；输出保留规划方向，首尾均为同一个机库起飞点。
    RETURN ST_MakeLine(ARRAY[v_home, v_takeoff] || v_points || ARRAY[v_return, v_home]);
END;
$$;
COMMENT ON FUNCTION public.gis_uav_flight_deviation_line(geometry, double precision, double precision, double precision, geometry, boolean, integer)
IS '构造无人机完整起飞、规划、返航和降落三维航线：输入航点Z相对机库，支持相对机库或海拔高度输出';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 1. 省略高度类型和航飞模式，默认垂直爬升、输出相对机库航线；所在地面海拔100米、距地20米，机库起飞点海拔120米，安全起飞60米、返航90米。
-- 原航点相对机库高度分别为120米、150米，相对输出保留原Z，垂直爬升至首航点高度120米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     60,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,120,120,150,150,0]，末航点150米高于配置返航90米，直接以150米高度平飞返航并降落。
--
-- 2. 倾斜爬升，输出海拔航线；按与相对高度相同的路径逻辑构造，再统一加机库起飞点海拔100+20=120米。
-- 安全起飞点海拔为120+60=180米，配置返航海拔为120+90=210米；原航点海拔分别为240米、270米，实际返航海拔取末航点270米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     60,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326),
--     true,
--     2
-- ));
-- 返回Z序列为[120,180,240,270,270,120]，末航点直接以海拔270米平飞返航并降落，不需要DEM地形数据。
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

-- 4. 默认垂直爬升，安全起飞140米高于首航点相对机库高度120米；先升至140米，平飞到首航点上方，再垂直降到120米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     140,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,140,140,120,150,150,0]；第2至3点平飞，第3至4点在首航点经纬度处垂直下降，末航点直接以150米高度平飞返航。
--
-- 5. 末航点相对机库150米低于配置返航200米；先在末航点处垂直爬升至200米，再平飞返航并降落。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 100)', 4326),
--     20,
--     60,
--     200,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,120,120,150,200,200,0]，末航点处先垂直爬升，再以200米高度平飞回机库上方。

