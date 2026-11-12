-- =============================================================================
-- 3.空域区块校验.sql
-- 空域区块校验规则说明
--
-- 脚本用途：提供航线/点位空域命中、任务用空计划、空域范围与高度、完整起降航线构造、实时遥测及任务航线冲突校验。
-- 通用约定：
--   1. 输入坐标使用WGS84经纬度（SRID=4326），高度和缓冲半径单位为米；航线长度单位为千米。
--   2. code表示执行状态，200仅表示校验完成；业务结果还须结合ischeck及各函数的结果字段判断。
--   3. 第1、2个函数的ischeck=true表示命中；第3、4、6、7个函数的ischeck=true表示校验通过。
--   4. check_type为text类型的数字字符串，仅第3、4个函数返回；第3个函数另有204（用空计划或时间不满足）。
--   5. 空域空间范围使用bo_airspace_block.final_geom；平面范围与高度分别校验，具体高度规则见各函数说明。
--   6. 第5个函数gis_uav_flight_deviation_line直接返回geometry；参数或航线连续性无效时抛出异常，不返回code/ischeck。
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
--   task_id       varchar；预留返回字段，正常、参数错误和执行异常时均返回NULL
--
--   （3）任务航线用空计划校验
--   函数：public.gis_flight_task_airspace
--   作用：校验任务航线是否满足空域区块、用空计划、用空时间和高度限制，返回任务是否可执行。
--   规则：
--   A、先调用gis_flight_airspace_check，以p_only_enabled=true校验空域范围和航点高度。
--   B、底层code=200且check_type为200或202时继续执行；202由计划高度终裁，201、203、400、500直接返回。
--   C、再调用gis_flight_route_airspace取得航线命中的空域区块ID；未命中任何区块时任务不可执行。
--   D、每个命中区块在p_use_date当天都必须有未删除且plan_status=true的用空计划；无计划或计划不可用时任务不可执行。
--   E、p_task_time_plan为非空JSON数组，元素包含startTime和endTime；每个任务时间段必须被每个命中区块的某一个计划时间段完整包含，不拼接多个计划段。
--   F、任务段和计划段的结束时间小于或等于开始时间时，结束日期均顺延一天；起止边界相等可满足包含关系。
--   G、任一航点Z值缺失或无效时，整条航线统一使用p_route_height作为校验高度；否则取航点Z最大值。
--   H、对完整包含任务时间段的计划段，至少有一个段的height不低于航线校验高度；height缺失或无效时按区块airspace_height兜底。
--   I、任一区块存在计划高度超限时归类202；其他计划或时间问题归类204；所有区块、所有任务时间段均满足时任务可执行。
--   返回：
--   code          状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg           返回信息，包含可执行结果或不可执行原因
--   ischeck       任务是否可执行，true=可执行，false=不可执行
--   hit_count     命中的空域区块数量
--   hit_blockids  命中的空域区块ID数组
--   task_id       当前任务ID，原样返回p_task_id
--   check_type    text；200=通过，201=范围超限/无可校验空域，202=高度超限，203=范围和高度均超限，204=用空计划或时间不满足，400=参数错误，500=执行异常
--   check_msg     校验结果的详细原因和处理建议
--
--   （4）任务航线空域范围和高度校验
--   函数：public.gis_flight_airspace_check
--   作用：校验任务航线的航点及整条航线是否全部在空域区块范围内，并检查航点高度是否超过空域高度。
--   规则：
--   A、项目ID不能为空，只校验该项目下未删除且final_geom不为空的空域区块。
--   B、航线GeoJSON不能为空，geometry必须为LineString或MultiLineString；任一航点Z值缺失或无效时，整条航线统一使用p_route_height。
--   C、p_only_enabled默认true，只校验use_enabled=true的空域；false时不限制启用状态。
--   D、所有航点必须落在空域区块final_geom范围内，且整条航线的线段必须落在空域区块并集范围内；任一航点或任一线段超出时ischeck=false，归类为201（或203）。
--   E、航点高度不能超过覆盖该航点的区块airspace_height最小值；覆盖区块的高度均为NULL时按0米上限处理，等于上限可通过。
--   F、范围和高度全部通过时ischeck=true；否则ischeck=false，调用方应阻断提交。
--   返回：
--   code       状态码：200=执行成功（含无可校验空域的业务不通过） 400=参数错误 500=执行异常
--   msg        返回信息，包含校验结果或错误原因
--   ischeck    是否通过空域范围和高度校验，true=通过，false=不通过
--   check_type text；200=范围和高度通过，201=范围超限/无可校验空域，202=高度超限，203=范围和高度均超限，400=参数错误，500=执行异常
--   check_msg  校验结果的中文说明，包含具体失败原因或通过说明
--   hit_count  bigint；覆盖航点的去重空域区块数量，与第1、3个函数按整条航线相交统计的数量口径不同
--
--   （5）无人机完整起降航线构造
--   函数：public.gis_uav_flight_deviation_line
--   作用：按航飞模式和高度基准，将机库起飞段、规划航线、返航段和降落段拼接为完整三维航线，供第6个函数使用。
--   入参：
--   p_uav_location   geometry；机库PointZ，XY为WGS84经纬度，Z为机库海拔（米）。
--   p_ground_height  double precision；机库相对地面高度（米），地面机库传0；非负有限值。
--   p_safe_height    double precision；相对机库的安全起飞高度（米）；非负有限值。
--   p_return_height  double precision；相对机库的返航高度（米）；非负有限值。
--   p_route          geometry；原规划航线LineStringZ或按飞行顺序首尾衔接的MultiLineStringZ，Z为非负有限的距地高度（米）。
--   p_is_altitude    boolean；输出高度基准，默认false；false=相对机库高度，true=海拔高度，不能为NULL。
--   p_flight_mode    integer；航飞模式，默认1；1=垂直爬升，2=倾斜爬升，不能为NULL。
--   规则：
--   A、相对分支：机库点Z=0，原航点Z减p_ground_height；安全点Z=p_safe_height，返航点Z=p_return_height，忽略地形高差。
--   B、海拔分支：采用相同的相对机库航线逻辑，再给所有点统一加机库海拔；原航点Z为原Z-p_ground_height+机库海拔。
--   C、垂直爬升：先在机库处升至换算后首航点高度与安全起飞点高度的较大值，再平飞至首航点上方；安全点更高时垂直下降至首航点。
--   D、倾斜爬升：先在机库处升至安全起飞高度，再直线飞向首航点；两种模式均按原顺序经过规划航点。
--   E、返航先在末航点经纬度处垂直升降到返航高度，再平飞到机库上方同一高度，最后垂直降落；末航点已在返航高度时直接平飞。
--   F、机库和原航线SRID须为4326或0，SRID=0按WGS84解释；多段航线须在XYZ三维空间首尾衔接，不自动反转或连接断开的航段。
--   G、两个分支均忽略航点与机库之间的地形高差，不查询DEM；海拔航线与相对航线仅相差机库海拔这一统一Z偏移。
--   返回：
--   geometry      SRID=4326的LineStringZ，起终点均为机库，所有Z统一为所选高度基准（米），允许负Z
--   异常          参数或航线连续性无效时抛出SQLSTATE 22023；由第6个函数调用时转换为code=400
--
--   （6）无人机实时偏航、超高和用空计划时段校验
--   函数：public.gis_uav_flight_deviation_check
--   作用：根据任务ID和实时遥测执行所选规则，返回本次违规标记及原始遥测信息。
--   入参：
--   p_task_id               varchar；任务ID，匹配bo_flight_job.out_id；项目ID、规划航线和起降参数从未删除任务记录取得。
--   p_telemetry             jsonb对象；必含longitude、latitude、timeStamp；altitude为海拔米，height为相对机库高度米；规则1的三维校验和规则2使用选定高度。
--   p_rules                 integer[]；默认ARRAY[1,1,1]；固定三位0/1，依次控制偏航、超高、用空计划时段；1执行，0跳过。
--   p_deviation_threshold   double precision；偏航距离阈值，单位米，默认50；须为非负有限值，不能为NULL。
--   规则：
--   A、高度基准：altitude缺失、格式错误、非有限、为0或与height精确相等时使用相对机库高度，否则使用有效海拔；规则1的三维校验和规则2采用同一分支。
--   B、偏航：机库位置非空时，用gis_uav_flight_deviation_line构造同高度基准的完整航线并计算三维最短距离；机库位置为NULL或空几何时，沿用原规划航线计算二维水平最短距离。
--      距离严格大于p_deviation_threshold时违规，等于阈值正常；仅三维分支要求有效遥测高度、三维规划航线及完整起降参数，原航线Z为相对地面高度。
--   C、超高：按当前位置覆盖的启用项目区块及遥测时间匹配可用计划段；各区块取命中段有效height最大值，无有效值时依次回退区块airspace_height、0米。
--      相对限高=距地限高-ground_height，海拔限高=距地限高+遥测点DEM；相对分支忽略地形高差，必需DEM无效时返回400。
--      多区块覆盖时取各区块限高的最小值；同基准遥测高度严格大于该限高时违规，等于限高正常；未命中任何启用区块时本规则不报超高。
--   D、用空计划时段：任一覆盖当前位置的启用项目区块没有覆盖遥测时间的可用计划段时违规；不检查管控围栏，不依赖任务plan_airspace_block_id。
--      未命中任何启用区块时沿用原逻辑，不报本项异常；区块边界视为命中。
--   E、timeStamp按北京时间解释，建议yyyy-MM-dd HH:mm:ss；规则2和3查询当天和前一天计划，采用[开始,结束)，结束时间小于或等于开始时间时顺延一天。
--      计划段startTime/endTime仅接受HH:mm或HH:mm:ss，小时00至23；违规判断由每次遥测调用触发。
--   F、只汇总已启用规则；仅启用规则3时不要求遥测高度及起降参数有效，持续异常去重、恢复和乱序处理由调用方维护。
--   返回：
--   code          integer；200=校验完成（可能有违规），400=参数或数据错误，500=执行异常
--   msg           校验结果或错误原因，正常执行时包含违规项数
--   ischeck       本次所选规则是否全部通过
--   active_rule   jsonb数组，固定三位，依次对应偏航、超高、用空计划时段；0=违规，1=未发现违规或未启用
--                 code=400或500时也返回[1,1,1]，须先检查code，不能据此判断正常或恢复
--   datajson      jsonb对象，包含project_id、task_id、telemetry
--
--   （7）任务航线冲突校验
--   函数：public.gis_flight_task_route_check
--   作用：在指定项目和任务ID集合内，检查待校验航线与任务规划航线是否存在空间冲突。
--   入参：
--   p_project_id     项目ID，必填
--   p_route_geojson  待校验航线GeoJSON，解析后须为有效、非空的LineString/MultiLineString，并能取得Z高度范围
--   p_task_ids       varchar[]，必填且非空；元素去除首尾空白并去重，不允许NULL或空字符串
--   p_buffer_radius double precision，单位米，默认50；须为非负有限值，0表示使用原始航线
--   规则：
--   A、仅检查bo_flight_job中项目匹配、out_id在指定任务集合内、未删除（del_flag为NULL也按未删除处理）且规划航线非空有效的记录。
--   B、待校验航线的二维缓冲区与任务规划航线相交，且两条航线的Z高度范围重叠时判定冲突；边界接触、高度区间端点相等均计入。
--   C、冲突任务ID去重后按字典序排序；本函数不比较任务时间、速度或其他属性。
--   返回：
--   code       integer；200=校验完成，400=参数或航线数据错误，500=执行异常
--   msg        校验结果或错误原因，发现冲突时包含冲突数量和任务ID
--   ischeck    true=未发现冲突，false=发现冲突或校验失败
--   task_ids   text；冲突任务ID以英文逗号分隔，无冲突或执行失败时为空字符串
--
-- 依赖说明：
--   1. PostGIS 空间扩展。
--   2. PGSQL/函数/baseFunction/gis_drop_function.sql：public.gis_drop_function(text)，按名称删除旧函数。
--   3. PGSQL/函数/baseFunction/gis_geojson_to_geom.sql：public.gis_geojson_to_geom(text)，解析GeoJSON。
--   4. PGSQL/聊城/1.飞行审核.sql：public.gis_write_error_log(integer, text, text)，写入public.gis_error_log。
--   5. PGSQL/聊城/2.空域区块.sql：public.bo_airspace_block空域区块表、public.bo_airspace_plan用空计划表。
--   6. public.bo_flight_job任务表，第6、7个函数读取out_id、project_id、del_flag、plan_route_gemo。
--      第6个函数还读取uav_location、ground_height、safe_height、return_height、flight_mode；机库位置非空时调用第5个函数gis_uav_flight_deviation_line构造完整航线，为空时沿用原航线水平偏航校验。
--   7. 第3个函数运行时复用本文件的第4个和第1个函数；调用前需完成本文件全部函数的创建。
--   8. PGSQL/函数/6.2DEM分析函数.sql：public.gis_dem_value_at_point(geometry, text)及其DEM表解析函数；第6个函数的海拔超高校验用于空域限高换算，必需DEM不可用时返回400。
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

    -- 一、校验项目和航线文本；参数不完整时直接返回400，不执行后续空间查询。
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
        -- 二、通过统一GeoJSON解析函数取得几何；解析错误在当前分支转换为参数错误。
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

    -- 命中校验仅使用二维位置；修复几何后再次限制类型，避免集合或其他几何参与航线判断。
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

    -- geography长度单位为米，除以1000后返回千米；该长度不计入航点高度差。
    route_length_km := round((ST_Length(v_route_geom::geography) / 1000.0)::numeric, 6)::double precision;

    -- 三、先确认项目下存在可校验区块，区分“无空域数据”和“有数据但航线未命中”。
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

    -- 四、对启用且未删除的项目区块逐个判断二维相交；边界接触也计入，区块ID去重并排序。
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

    -- 五、命中任一区块即为true；code=200只表示查询完成，未命中时仍返回200。
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
    -- 未被参数分支处理的空间或数据库异常统一记录日志，并返回空命中结果。
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
--   返回code、msg、ischeck、hit_count、hit_blockids、task_id。
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
--   task_id       varchar；预留返回字段，本函数不接收任务ID，所有返回分支均为NULL。
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

    -- 一、项目和点位文本均为必填；此处只校验输入，尚未查询空域区块。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
        RETURN;
    END IF;

    IF p_point_geojson IS NULL OR btrim(p_point_geojson) = '' THEN
        v_msg := format('参数错误：点位GeoJSON不能为空，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
        RETURN;
    END IF;

    BEGIN
        -- 二、限定为Point类型的Feature，再交给统一解析函数；裸Point和其他类型均不接受。
        IF p_point_geojson::jsonb->>'type' IS DISTINCT FROM 'Feature'
           OR p_point_geojson::jsonb->'geometry'->>'type' IS DISTINCT FROM 'Point' THEN
            v_msg := format('参数错误：点位GeoJSON必须为Point类型的Feature，执行时间 %s 秒',
                round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
            RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
            RETURN;
        END IF;
        v_point_geom := public.gis_geojson_to_geom(p_point_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：点位GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
        RETURN;
    END;

    IF v_point_geom IS NULL OR ST_IsEmpty(v_point_geom) OR GeometryType(v_point_geom) <> 'POINT' THEN
        v_msg := format('参数错误：点位geometry必须为非空Point，执行时间 %s 秒',
            round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
        RETURN;
    END IF;

    -- 后续只按二维经纬度判断覆盖关系，输入点的Z高度不参与命中校验。
    v_point_geom := ST_SetSRID(ST_Force2D(v_point_geom), 4326);

    -- 三、没有启用且未删除的项目区块时返回400，与点位未命中区块的200结果区分。
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
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
        RETURN;
    END IF;

    -- 四、ST_Covers包含区块边界；重叠位置保留所有命中区块，去重后生成稳定排序的ID数组。
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

    -- 五、按命中数量生成业务结果；命中0个时ischeck=false，仍表示本次查询正常完成，预留task_id保持NULL。
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
    -- 捕获空间计算及查询异常，日志保留原始调用，返回500和空命中集合。
    v_msg := format('点位空域区块校验执行异常：%s，执行时间 %s 秒',
        SQLERRM, round(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[], NULL::varchar;
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
--   A. 先调用gis_flight_airspace_check做空域范围和高度阻断校验。
--   B. 底层code=200且check_type为200或202时继续执行，202由计划高度终裁；其余状态或分类直接返回。
--   C. 调用gis_flight_route_airspace判断任务航线经过哪些空域区块；未经过时任务不可执行。
--   D. 经过空域区块时，判断plan_status是否为true；false表示空域不可用，任务不可执行。
--   E. plan_status=true后，判断任务用空时间段是否完整落在空域计划时间段内，未完整落入时任务不可执行。
--   F. 任务时间段已落入计划时间段时，按该计划时间段time_plan的height校验航线校验高度，超出时任务不可执行（check_type=202）。
--   G. 航线校验高度沿用底层规则：任一航点Z缺失或无效时整条航线统一使用p_route_height，否则取航点Z最大值；计划段height缺失或无效时按区块airspace_height兜底。
--   H. 空域范围、计划高度、计划状态和时间段均通过时，任务可以执行。
-- 入参说明：
--   p_project_id       项目ID。
--   p_task_id          任务ID。
--   p_route_geojson    航线GeoJSON，geometry必须为LineString或MultiLineString，任一航点Z值缺失或无效时整条航线统一使用航线高度参数。
--   p_route_height     航线高度参数，单位：米。
--   p_use_date         用空日期，格式yyyy-MM-dd。
--   p_task_time_plan   任务用空时间段JSON数组。
-- 返回说明：
--   返回code、msg、ischeck、hit_count、hit_blockids、task_id、check_type、check_msg。
-- 注意事项：
--   1. plan_status=true表示空域可用，plan_status=false表示空域不可用。
--   2. 本函数先调用gis_flight_airspace_check；仅底层code=200且check_type为200或202时，继续按用空计划time_plan的height校验高度。
--   3. time_plan元素格式如{"startTime":"10:12:00","endTime":"15:12:00","height":120}；height缺失、为空或非数值时按区块airspace_height兜底。
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
--   p_route_geojson    航线GeoJSON字符串；text；必填；geometry必须为LineString或MultiLineString，任一航点Z值缺失或无效时整条航线统一使用航线高度参数。
--   p_route_height     航线高度参数；double precision；必填且不能小于0；单位：米；任一航点缺少Z高度时整条航线统一使用该值。
--   p_use_date         用空日期字符串；varchar；必填；格式yyyy-MM-dd；用于匹配bo_airspace_plan.use_date。
--   p_task_time_plan   任务用空时间段JSON数组字符串；text；必填；格式如[{"startTime":"15:00:00","endTime":"16:00:00"}]。
-- 入参校验：
--   1. 项目ID、任务ID、航线GeoJSON、航线高度、用空日期和任务用空时间段均不能为空。
--   2. 航线高度p_route_height不能小于0。
--   3. p_use_date必须能转换为date，格式建议为yyyy-MM-dd。
--   4. p_task_time_plan必须为非空JSON数组，每个元素必须包含startTime和endTime，且能转换为time。
--   5. p_route_geojson必须能解析为有效几何，任一航点Z值缺失或无效时整条航线统一使用航线高度参数；geometry类型由gis_flight_airspace_check校验。
-- 返回说明：
--   code               integer；200=执行成功，400=参数错误/无可校验数据，500=执行异常。
--   msg                text；返回参数错误、不可执行原因或可执行结果；复用底层结果时可能包含执行耗时。
--   ischeck            boolean；true=任务可执行，false=任务不可执行、参数错误或执行异常。
--   hit_count          integer；命中的空域区块数量；未经过空域区块时为0。
--   hit_blockids       text[]；命中的空域区块ID数组；未经过空域区块或参数错误时为空数组。
--   task_id            varchar；原样返回p_task_id，供调用方关联当前任务。
-- msg业务结果说明：
--   1. 未经过空域区块：任务{task_id}未经过空域区块，不可执行。
--   2. 无用空计划：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}无用空计划。
--   3. 空域不可用：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}空域不可用。
--   4. 时间段超出计划：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}任务时间段{startTime}-{endTime}超出用空计划时间段。
--   5. 空域范围不通过：直接返回gis_flight_airspace_check的阻断原因。
--   6. 高度超出计划高度：任务{task_id}不可执行：{空域名称}({空域ID})：{yyyy-MM-dd}任务时间段{startTime}-{endTime}已落入计划时间段，但包含它的计划时间段高度上限最高{height}米，低于航线校验高度{H}米。
--   7. 全部通过：任务{task_id}经过空域区块{hit_count}个，空域范围、高度、用空计划和时间段校验通过，可执行。
--   check_type       text；校验结果分类ID（数字字符串）：
--     200：校验通过，ischeck=true，可以执行任务。
--     201：航线超出空域范围，或当前项目下没有符合校验条件的空域区块。
--     202：任务高度超出包含任务时间段的计划高度上限；底层仅高度超限时继续校验，不直接复用底层202。
--     203：范围超限且航点高度超限（复用底层203）。
--     204：用空计划或时间不满足。
--     400：参数错误。
--     500：校验执行异常。
--     除200外，其余分类均为ischeck=false，不可执行任务。
--   check_msg        text；对应分类的详细原因、判断规则和处理建议：
--     200：空域范围、高度、用空计划和任务时间段均满足要求，可以执行任务。
--     201：航线范围校验不通过时，直接复用gis_flight_airspace_check的check_msg。
--     202：说明任务时间段已落入计划时间段，但航线校验高度超过包含它的计划高度上限；结果以计划高度校验为准。
--     203：直接复用gis_flight_airspace_check的check_msg，说明范围和高度同时不通过的原因。
--     204：用空计划或时间不满足，包含以下情况：
--       1. 用空计划或时间不满足；无用空计划；该空域在指定日期未配置用空计划。
--       2. 用空计划或时间不满足；空域不可用；该空域当天的用空计划已设为不可用（plan_status=false）。
--       3. 用空计划或时间不满足；任务时间段超出计划；任务时间段未完整落在任一计划时间段内。
--       4. 用空计划或时间不满足；任务时间段超出计划；当天计划可用，但未配置有效的用空时间段。
--       5. 用空计划或时间不满足；同时存在多个问题时，逐项列出各空域的无用空计划、空域不可用或任务时间段超出计划的具体原因。
--     400：必填参数缺失、参数格式错误等；说明具体错误参数。
--     500：校验过程中发生数据库或函数执行异常；说明异常原因及处理建议。
-- 注意事项：
--   1. plan_status=true表示空域可用；plan_status=false表示空域不可用。
--   2. 只有plan_status=true时才继续校验任务时间段。
--   3. 任一航点Z高度缺失或无效时，整条航线统一按航线高度参数作为校验高度；否则取航点Z最大值。
--   4. 可飞空域范围由gis_flight_airspace_check统一处理；底层code=200且check_type=202时不直接阻断，以用空计划height终裁高度。
--   5. 原航点Z、p_route_height、区块airspace_height和计划段height须采用同一高度基准；函数直接比较数值，不自动进行海拔与相对高度换算。
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
    task_id varchar,
    check_type text,
    check_msg text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_log_sql text;
    -- 底层范围校验和命中查询分别保留结果，后续计划校验复用其分类及命中区块。
    v_airspace_check record;
    v_route_check record;
    v_route_geom geometry;
    v_use_date date;
    v_task_time_plan jsonb;
    v_error_msgs text[];
    v_plan_issue_types text[];
    v_check_height numeric;
    v_check_type text;
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
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END IF;

    IF p_task_id IS NULL OR btrim(p_task_id) = '' THEN
        v_msg := '参数错误：任务ID不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END IF;

    IF p_route_height IS NULL OR p_route_height < 0 THEN
        v_msg := '参数错误：航线高度不能为空且不能小于0';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END IF;

    IF p_use_date IS NULL OR btrim(p_use_date) = '' THEN
        v_msg := '参数错误：用空日期不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END IF;

    IF p_task_time_plan IS NULL OR btrim(p_task_time_plan) = '' THEN
        v_msg := '参数错误：任务用空时间段不能为空';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END IF;

    -- 二、日期、任务时间段和航点Z值解析。
    BEGIN
        v_use_date := btrim(p_use_date)::date;
    EXCEPTION WHEN OTHERS THEN
        v_msg := '参数错误：用空日期格式错误，应为yyyy-MM-dd';
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END;

    BEGIN
        -- 任务可包含多个时间段；先校验数组及每段时间，再在计划匹配时补齐日期和跨午夜结束时间。
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
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END;

    BEGIN
        v_route_geom := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：任务航线GeoJSON解析失败：%s', SQLERRM);
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '400'::text, v_msg || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。';
        RETURN;
    END;

    -- 三、空域范围和高度阻断校验。该步骤统一复用第4个空域区块提交前校验函数。
    SELECT *
    INTO v_airspace_check
    FROM public.gis_flight_airspace_check(p_project_id, p_route_geojson, p_route_height::numeric, true)
    LIMIT 1;

    -- 底层code=200且check_type为200（通过）或202（仅航点高度超限）时继续；202由用空计划height终裁。
    -- check_type为201或203包含范围超限，code为400或500表示参数或执行异常，均直接返回底层结果。
    IF COALESCE(v_airspace_check.code, 500) <> 200
       OR COALESCE(v_airspace_check.check_type, '500') NOT IN ('200', '202') THEN
        RETURN QUERY SELECT
            COALESCE(v_airspace_check.code, 500),
            COALESCE(v_airspace_check.msg, '空域区块提交前校验未通过'),
            false,
            COALESCE(v_airspace_check.hit_count, 0)::integer,
            ARRAY[]::text[], p_task_id,
            CASE
                WHEN COALESCE(v_airspace_check.code, 500) = 500 THEN '500'
                WHEN v_airspace_check.code = 400 THEN '400'
                ELSE v_airspace_check.check_type
            END::text,
            CASE
                WHEN v_airspace_check.code = 400
                    THEN COALESCE(v_airspace_check.msg, '参数错误') || '。任务不可执行：请按上述提示补全或修正输入参数后重新校验。'
                ELSE COALESCE(v_airspace_check.check_msg, v_airspace_check.msg, '空域范围和高度校验未通过')
            END::text;
        RETURN;
    END IF;

    -- 三.二、计算航线校验高度，用于按用空计划time_plan的height校验：
    -- 与底层规则一致，任一航点Z缺失、非数值或为NaN/Infinity/-Infinity时整条航线统一使用p_route_height，否则取航点Z最大值。
    -- 执行到此处时底层已解析成功，几何必为LineString/MultiLineString；异常时兜底按p_route_height处理。
    BEGIN
        WITH route_geometries AS (
            SELECT feature -> 'geometry' AS geom
            FROM jsonb_array_elements(
                CASE WHEN p_route_geojson::jsonb ->> 'type' = 'FeatureCollection'
                          AND jsonb_typeof(p_route_geojson::jsonb -> 'features') = 'array'
                    THEN p_route_geojson::jsonb -> 'features'
                    ELSE '[]'::jsonb END
            ) AS f(feature)
            WHERE p_route_geojson::jsonb ->> 'type' = 'FeatureCollection'
              AND jsonb_typeof(feature -> 'geometry') = 'object'
            UNION ALL
            SELECT CASE WHEN p_route_geojson::jsonb ->> 'type' = 'Feature'
                THEN p_route_geojson::jsonb -> 'geometry' ELSE p_route_geojson::jsonb END
            WHERE p_route_geojson::jsonb ->> 'type' IS DISTINCT FROM 'FeatureCollection'
        ),
        route_points AS (
            SELECT pt.point
            FROM route_geometries rg
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE WHEN rg.geom ->> 'type' = 'LineString'
                        THEN jsonb_build_array(rg.geom -> 'coordinates')
                     WHEN rg.geom ->> 'type' = 'MultiLineString'
                        THEN rg.geom -> 'coordinates'
                     ELSE '[]'::jsonb END
            ) AS l(line)
            CROSS JOIN LATERAL jsonb_array_elements(l.line) AS pt(point)
        )
        SELECT CASE WHEN bool_or(jsonb_typeof(rp.point -> 2) IS DISTINCT FROM 'number'
                                 OR rp.point ->> 2 IN ('NaN', 'Infinity', '-Infinity'))
                        THEN p_route_height::numeric
                    ELSE max((rp.point ->> 2)::numeric)
               END
        INTO v_check_height
        FROM route_points rp;

        v_check_height := COALESCE(v_check_height, p_route_height::numeric);
    EXCEPTION WHEN OTHERS THEN
        v_check_height := p_route_height::numeric;
    END;

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
            p_task_id, CASE WHEN COALESCE(v_route_check.code, 500) = 500 THEN '500' ELSE '400' END::text, COALESCE(v_route_check.msg, '航线空域命中查询未成功') || '。任务不可执行：无法完成航线与空域区块的命中查询，请根据错误原因检查航线数据及空域配置后重新校验。';
        RETURN;
    END IF;

    hit_count := COALESCE(v_route_check.hit_count, 0);
    hit_blockids := COALESCE(v_route_check.hit_blockids, ARRAY[]::text[]);

    IF hit_count = 0 THEN
        v_msg := format('任务%s未经过空域区块，不可执行', p_task_id);
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids, p_task_id, '201'::text, '航线超出空域范围；航线未经过任何空域区块；'::text || v_msg || '。航线与当前项目下已启用且未删除的空域区块没有空间命中，无法匹配可用的用空计划；请检查航线位置和空域配置。';
        RETURN;
    END IF;

    -- 五、对命中的空域区块做用空计划和时间段业务校验：
    -- 1. 用空日期必须存在计划；
    -- 2. plan_status必须为true，false表示空域不可用；
    -- 3. plan_status=true后，每个任务时间段必须完整落在某个计划时间段内，否则不可执行；
    -- 4. 任务时间段已落入计划时间段时，包含它的计划时间段height上限必须不低于航线校验高度v_check_height，否则不可执行（check_type=202）；
    --    计划时间段height缺失、为空或非数值时，按该区块airspace_height兜底。
    WITH hit_blocks AS (
        -- 只展开航线已命中的区块，后续每个区块都必须满足任务用空条件。
        SELECT
            b.id,
            b.airspace_name,
            b.min_height,
            b.airspace_height
        FROM public.bo_airspace_block b
        WHERE b.id = ANY(hit_blockids)
    ),
    task_segments AS (
        -- 把时分秒转换为完整时间戳；结束不晚于开始时，按次日结束处理。
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
        -- LEFT JOIN保留当天没有计划的区块，便于生成“无用空计划”的明确原因。
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
        -- 展开区块计划段并补齐起止日期；缺少有效计划高度时沿用该区块的最高高度。
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
            COALESCE(seg.raw_height, bdp.airspace_height)::numeric AS plan_height,
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
                NULLIF(item ->> 'endTime', '')::time AS end_time,
                -- height缺失、为空或非数值时按非数值处理，外层COALESCE回退为区块airspace_height。
                CASE WHEN (item ->> 'height') ~ '^[0-9]+(\.[0-9]+)?$'
                    THEN (item ->> 'height')::numeric END AS raw_height
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
        -- 双层NOT EXISTS表示：不存在任何一个未被单个计划段完整包含的任务段。
        -- 相邻计划段不拼接使用，只有计划可用的区块才进入时间包含关系校验。
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
        -- 分别收集缺计划、计划禁用、时间不包含和计划高度不足，不因首个失败而丢失其他区块原因。
        SELECT DISTINCT
            block_id,
            block_name,
            format('%s没有可用的用空计划记录，或计划状态为空；请为该区块配置当天的用空计划并明确设置为可用', to_char(use_date, 'YYYY-MM-DD')) AS reason, '无用空计划'::text AS issue_type
        FROM block_day_plan
        WHERE plan_status IS NULL

        UNION ALL

        SELECT DISTINCT
            block_id,
            block_name,
            format('%s用空计划已设置为空域不可用（plan_status=false）；请调整任务日期，或确认该区块计划可用后重新校验', to_char(use_date, 'YYYY-MM-DD')) AS reason, '空域不可用'::text AS issue_type
        FROM block_day_plan
        WHERE plan_status = false

        UNION ALL

        SELECT DISTINCT
            bdp.block_id,
            bdp.block_name,
            format('%s任务时间段%s-%s未被任何一个有效计划时间段完整包含（计划时间段为空也不通过）；每个任务时间段必须从开始到结束都落在同一个计划时间段内，不会拼接多个计划时间段，请调整任务时间或用空计划',
                to_char(bdp.use_date, 'YYYY-MM-DD'),
                to_char(ts.start_time, 'HH24:MI:SS'),
                to_char(ts.end_time, 'HH24:MI:SS')) AS reason, '任务时间段超出计划'::text AS issue_type
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

        UNION ALL

        -- 任务时间段已落入计划时间段，但所有包含它的计划时间段height上限均低于航线校验高度。
        SELECT DISTINCT
            bdp.block_id,
            bdp.block_name,
            format('%s任务时间段%s-%s已落入计划时间段，但包含它的计划时间段高度上限最高%s米，低于航线校验高度%s米；请降低航线高度，或调整该区块用空计划时间段的高度上限',
                to_char(bdp.use_date, 'YYYY-MM-DD'),
                to_char(ts.start_time, 'HH24:MI:SS'),
                to_char(ts.end_time, 'HH24:MI:SS'),
                (SELECT max(ps.plan_height)
                 FROM plan_segments ps
                 WHERE ps.block_id = bdp.block_id
                   AND ps.use_date = bdp.use_date
                   AND ps.plan_start_ts IS NOT NULL
                   AND ps.plan_end_ts IS NOT NULL
                   AND ts.start_ts >= ps.plan_start_ts
                   AND ts.end_ts <= ps.plan_end_ts),
                v_check_height) AS reason, '任务高度超出计划高度'::text AS issue_type
        FROM block_day_plan bdp
        CROSS JOIN task_segments ts
        WHERE bdp.plan_status = true
          AND EXISTS (
              SELECT 1
              FROM plan_segments ps
              WHERE ps.block_id = bdp.block_id
                AND ps.use_date = bdp.use_date
                AND ps.plan_start_ts IS NOT NULL
                AND ps.plan_end_ts IS NOT NULL
                AND ts.start_ts >= ps.plan_start_ts
                AND ts.end_ts <= ps.plan_end_ts
          )
          AND NOT EXISTS (
              SELECT 1
              FROM plan_segments ps
              WHERE ps.block_id = bdp.block_id
                AND ps.use_date = bdp.use_date
                AND ps.plan_start_ts IS NOT NULL
                AND ps.plan_end_ts IS NOT NULL
                AND ts.start_ts >= ps.plan_start_ts
                AND ts.end_ts <= ps.plan_end_ts
                AND ps.plan_height >= v_check_height
          )

    ),
    invalid_blocks AS (
        -- 同一区块的多项问题合并展示，再按区块ID排序汇总到任务结果。
        SELECT
            block_id,
            block_name,
            string_agg(reason, '；' ORDER BY reason) AS reason
        FROM invalid_reasons
        GROUP BY block_id, block_name
    )
    SELECT COALESCE(array_agg(format('%s(%s)：%s', block_name, block_id, reason) ORDER BY block_id), ARRAY[]::text[])
    , (SELECT array_agg(DISTINCT ir.issue_type ORDER BY ir.issue_type) FROM invalid_reasons ir)
    INTO v_error_msgs, v_plan_issue_types
    FROM invalid_blocks;

    -- 六、按是否存在失败原因返回任务结果；有高度问题时优先分类202，其余计划问题归类204。
    IF COALESCE(array_length(v_error_msgs, 1), 0) > 0 THEN
        v_msg := format('任务%s不可执行：%s',
            p_task_id, array_to_string(v_error_msgs, '；'));
        -- 任一命中区块存在高度超出计划高度问题时归类202，其余用空计划或时间问题归类204。
        v_check_type := CASE
            WHEN '任务高度超出计划高度' = ANY(COALESCE(v_plan_issue_types, ARRAY[]::text[])) THEN '202'
            ELSE '204' END;
        RETURN QUERY SELECT 200, v_msg, false, hit_count, hit_blockids, p_task_id, v_check_type,
            CASE WHEN v_check_type = '202'
                THEN '高度超出计划限制；'::text || v_msg || '。任务时间段已落入计划时间段，但航线校验高度超出包含它的计划时间段高度上限；请降低航线高度，或调整用空计划时间段的高度上限后重新校验。'
                ELSE '用空计划或时间不满足；'::text || (CASE WHEN cardinality(v_plan_issue_types) > 1 THEN '多种计划或时间问题（' || array_to_string(v_plan_issue_types, '、') || '）' ELSE v_plan_issue_types[1] END)::text || '；' || v_msg || '。任务经过的每一个空域区块都必须在用空日期有可用计划，且每个任务时间段都必须完整包含在该区块的某一个计划时间段内；以上任一问题未解决，任务均不可执行。'
            END::text;
    ELSE
        v_msg := format('任务%s经过空域区块%s个，空域范围、高度、用空计划和时间段校验通过，可执行',
            p_task_id, hit_count);
        RETURN QUERY SELECT 200, v_msg, true, hit_count, hit_blockids, p_task_id, '200'::text, v_msg || '。所有航点及整条航线均在可飞空域内，航线校验高度未超过用空计划时间段高度上限，所有命中区块在用空日期均有可用计划，且每个任务时间段均被各区块的某一个计划时间段完整包含。';
    END IF;

EXCEPTION WHEN OTHERS THEN
    -- 未预期异常统一阻断任务，保留原始调用日志并返回500分类。
    v_msg := format('任务航线用空校验执行异常：%s', SQLERRM);
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, 0::integer, ARRAY[]::text[], p_task_id, '500'::text, v_msg || '。本次校验未能完成，任务不可执行；请联系管理员检查错误日志，处理后重新校验。';
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
--   2. 按bo_airspace_block.final_geom判断所有航点是否在可飞空域内，并判断整条航线的线段是否完全落在可飞空域并集内。
--   3. 任一航点Z高度缺失或无效时，整条航线统一使用p_route_height，再按bo_airspace_block.airspace_height检查航点高度是否超高。
--   4. 任一航点不在空域内、任一线段超出空域并集，或任一航点高度超过空域高度，均校验不通过，调用方应阻断提交。
-- 参数说明：
--   p_project_id       项目ID；只检查该项目下未删除的空域区块。
--   p_route_geojson    航线GeoJSON，支持LineString/MultiLineString/Feature。
--   p_route_height     备用航线高度，单位米；必填且不能小于0；任一航点Z缺失或无效时用于整条航线赋值并参与超限判断。
--   p_only_enabled     是否只检查已启用/已发布空域；默认true。
-- 返回说明：返回code、msg、ischeck、check_type、check_msg、hit_count。
-- 注意事项：ischeck=true表示通过校验；ischeck=false表示调用方应阻断提交。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_flight_airspace_check');

-- =============================================================================
-- 函数介绍：4.gis_flight_airspace_check
-- 主要作用：校验任务航线的航点及整条航线是否均在可飞空域内，且航点高度不超过空域高度。
-- 入参说明：
--   p_project_id       项目ID；text；必填；只检查该项目下未删除且final_geom不为空的空域区块。
--   p_route_geojson    航线GeoJSON字符串；text；必填；支持Feature/geometry格式，geometry必须为LineString或MultiLineString；任一航点Z值缺失或无效时整条航线统一使用p_route_height。
--   p_route_height     备用航线高度；numeric；必填且不能小于0；单位米；任一航点Z缺失或无效时整条航线采用该值参与超限判断，Z完整有效时不参与计算。
--   p_only_enabled     是否只校验启用空域；boolean；选填，默认true；true=只检查启用空域，false=检查未删除空域。
-- 入参校验：
--   1. p_project_id不能为空。
--   2. p_route_geojson不能为空，且必须能通过public.gis_geojson_to_geom解析为有效几何。
--   3. 解析后的geometry必须为LineString或MultiLineString。
--   4. 任一航点Z高度缺失或无效（缺失、非数值、NaN、Infinity、-Infinity）时，整条航线统一使用p_route_height赋值，再按对应空域上限判断是否超限。
--   5. p_route_height不能为空，且必须大于等于0；航线Z值完整有效时该值不参与计算。
--   6. 航线中任一线段坐标为空（coordinates=[]）时返回400，避免被静默忽略。
-- 返回说明：
--   code             integer；200=执行成功（包括无可校验空域时的范围校验不通过），400=参数错误，500=执行异常。
--   msg              text；返回范围/高度校验结果、参数错误、无数据或异常信息；该函数msg包含执行耗时。
--   ischeck          boolean；true=航点全部在可飞空域内且高度通过，false=范围不通过、高度超限、参数错误或执行异常。
--   check_type       text；校验结果分类ID：
--     200：航线范围和高度均通过，ischeck=true。
--     201：航线超出空域范围，ischeck=false。
--     202：航点高度超出限制，ischeck=false。
--     203：航线超出空域范围并且航点高度超出，ischeck=false，优先于201、202返回。
--     400：参数错误，code=400，ischeck=false。
--     500：校验执行异常，code=500，ischeck=false。
--   check_msg        text；对应check_type分类ID的说明，
--     200：航线范围和高度均通过；航点及整条航线均在空域内，航点高度均未超限。
--     201：航线超出空域范围：
--       1. 航线超出空域范围；航点有不在可飞空域内；（说明：航线经过空域，但有航点在空域外；含航点全在空域外但航段穿越空域的情况）
--       2. 航线超出空域范围；航点都在空域内，航线不在可飞空域范围；（说明：航点都在空域内，但航点之间的线段越出空域）
--       3. 航线超出空域范围；航点都不在可飞空域区块，航线超出可飞空域范围；（说明：航线未命中空域区块，航点都不在空域内）
--       4. 航线超出空域范围；当前项目下无可校验空域；（说明：项目下无可校验空域区块）
--     202：航点高度超出限制：
--       1. 航点高度超出限制；航点高度250米超过对应空域高度200米上限。（说明：航点Z高度超限）
--       2. 任一航点Z值缺失或无效时整条航线已统一使用p_route_height赋值，赋值后的航点高度同样参与超限判断。
--     203：航线超出空域范围并且航点高度超出限制：
--       1. 航线超出空域范围并且高度超出限制；航点有不在可飞空域内；航点高度250米超过对应空域高度200米上限。（说明：范围超限且航点高度超限）
--       2. 航点都在空域内但航线不在可飞空域范围时，check_msg以“航点都在空域内，航线不在可飞空域范围”代替“航点有不在可飞空域内”。
--       3. 航点都不在可飞空域区块时，check_msg以“航点都不在可飞空域区块，航线超出可飞空域范围”代替“航点有不在可飞空域内”。
--       以上数值仅为示例，实际返回对应空域高度上限及超限高度，只列出超限项。
--     400：参数错误；请查看参数。
--     500：校验执行异常；数据库或函数执行异常。
--   hit_count        bigint；航点命中的可飞空域区块数量；未命中、参数错误或异常时为0。
-- 注意事项：
--   1. 本函数只校验可飞空域范围和高度，不校验用空计划、任务时间段或空域计划状态。
--   2. 范围判断使用二维几何：航点按ST_Covers逐点判断，整条航线按ST_Covers判断是否完全落在空域并集内；Z值不参与空间判断。
--   3. 任一航点Z高度缺失或无效时整条航线统一使用p_route_height参与超限判断；航线Z值完整有效时该值不参与计算。
--   4. 任一航点未落入可飞空域、任一线段越出空域并集，或任一航点高度超过覆盖该航点的可飞空域高度，ischeck=false，调用方应阻断提交。
--   5. 高度仅对有空域覆盖的航点判断；全部航点在空域外时，只判范围失败，不推断高度超限；重叠区块取airspace_height最小值，覆盖区块的高度均为NULL时按0米上限处理。
--   6. 航线整体校验使用项目下可校验空域区块的并集，因此航线跨越多块空域时按并集判断，不要求必须落在同一区块内。
--   7. p_only_enabled=true时只校验启用空域；p_only_enabled=false时校验项目下未删除空域。
--   8. 原航点Z、p_route_height与区块airspace_height须采用同一高度基准；函数直接比较数值，不自动进行海拔与相对高度换算。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_flight_airspace_check(
    p_project_id text,
    p_route_geojson text,
    p_route_height numeric,
    p_only_enabled boolean DEFAULT true
)
RETURNS TABLE (
    code integer,
    msg text,
    ischeck boolean,
    check_type text,
    check_msg text,
    hit_count bigint
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_route geometry;
    v_route_type text;
    v_route_json jsonb;
    v_scope_count bigint := 0;
    v_outside_count bigint := 0;
    v_point_height_over_count bigint := 0;
    v_total_point_count bigint := 0;
    v_point_height_details text;
    v_height_msg text;
    v_hit_count bigint := 0;
    v_route_outside boolean := false;
    v_route_hits_airspace boolean := false;
    v_route_empty boolean := false;
    v_route_2d geometry;
    v_check_type text := '400';
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;
    v_msg text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_flight_airspace_check(%L, %L, %s, %L);',
        p_project_id, p_route_geojson, COALESCE(p_route_height::text, 'NULL'), p_only_enabled);

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_flight_airspace_check', v_log_sql);

    -- 一、检查项目、航线文本、备用高度和启用状态开关，参数错误统一返回400分类。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        v_msg := format('参数错误：项目ID不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END IF;

    IF p_route_geojson IS NULL OR btrim(p_route_geojson) = '' THEN
        v_msg := format('参数错误：航线GeoJSON不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END IF;

    IF p_route_height IS NULL OR p_route_height < 0 THEN
        v_msg := format('参数错误：航线高度不能为空且不能小于0，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END IF;

    IF p_only_enabled IS NULL THEN
        v_msg := format('参数错误：是否只检查启用空域不能为空，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END IF;

    BEGIN
        -- 二、提取实际航线坐标并统一高度；任一航点Z不可用时，整条航线采用p_route_height。
        v_route_json := p_route_geojson::jsonb;

        -- 单次jsonb遍历完成geometry提取、空坐标线段检测和Z填充重建；提取方式与gis_geojson_to_geom一致，只处理实际geometry，不遍历properties。
        -- 任一航点Z缺失、非数值或为NaN/Infinity/-Infinity时整条航线统一使用p_route_height；空坐标线段会被gis_geojson_to_geom静默忽略，检测后单独判为参数错误。
        WITH route_geometries AS (
                SELECT
                    feature -> 'geometry' AS geom,
                    feature_ord
                FROM jsonb_array_elements(
                    CASE WHEN v_route_json ->> 'type' = 'FeatureCollection'
                              AND jsonb_typeof(v_route_json -> 'features') = 'array'
                        THEN v_route_json -> 'features'
                        ELSE '[]'::jsonb END
                ) WITH ORDINALITY AS f(feature, feature_ord)
                WHERE v_route_json ->> 'type' = 'FeatureCollection'
                  AND jsonb_typeof(feature -> 'geometry') = 'object'
                UNION ALL
                SELECT CASE WHEN v_route_json ->> 'type' = 'Feature'
                    THEN v_route_json -> 'geometry' ELSE v_route_json END,
                    1
                WHERE v_route_json ->> 'type' IS DISTINCT FROM 'FeatureCollection'
            ),
            normalized_geometries AS (
                SELECT
                    rg.geom,
                    rg.feature_ord,
                    CASE WHEN rg.geom ->> 'type' = 'LineString'
                              THEN jsonb_build_array(rg.geom -> 'coordinates')
                         WHEN rg.geom ->> 'type' = 'MultiLineString'
                              THEN rg.geom -> 'coordinates'
                    END AS lines
                FROM route_geometries rg
            ),
            empty_check AS (
                -- LineString的lines为单元素数组[coordinates]，MultiLineString的lines即coordinates；空数组或含空线段均判为空坐标。
                SELECT EXISTS (
                    SELECT 1
                    FROM normalized_geometries ng
                    WHERE ng.geom ->> 'type' IN ('LineString', 'MultiLineString')
                      AND CASE
                            WHEN jsonb_typeof(ng.geom -> 'coordinates') IS DISTINCT FROM 'array' THEN false
                            ELSE jsonb_array_length(ng.lines) = 0
                                 OR EXISTS (
                                     SELECT 1
                                     FROM jsonb_array_elements(ng.lines) AS l(line)
                                     WHERE jsonb_typeof(l.line) = 'array'
                                       AND jsonb_array_length(l.line) = 0
                                 )
                          END
                ) AS flag
            ),
            all_route_points AS (
                SELECT pt.point
                FROM normalized_geometries ng
                CROSS JOIN LATERAL jsonb_array_elements(ng.lines) AS l(line)
                CROSS JOIN LATERAL jsonb_array_elements(l.line) AS pt(point)
            ),
            need_fill AS (
                -- Z缺失、非数值或为NaN/Infinity/-Infinity时触发整条航线填充；jsonb中NaN等仍属number类型，需按取出文本再判一次。
                SELECT EXISTS (
                    SELECT 1
                    FROM all_route_points rp
                    WHERE jsonb_typeof(rp.point -> 2) IS DISTINCT FROM 'number'
                       OR rp.point ->> 2 IN ('NaN', 'Infinity', '-Infinity')
                ) AS flag
            ),
            filled_lines AS (
                -- 按原要素、线段和航点顺序重建XYZ坐标，避免补高度时改变飞行顺序。
                SELECT
                    ng.feature_ord,
                    jsonb_agg(s.line_coords ORDER BY s.line_ord) AS filled_coordinates
                FROM normalized_geometries ng
                CROSS JOIN need_fill nf
                JOIN LATERAL (
                    SELECT
                        l.line_ord,
                        jsonb_agg(
                            jsonb_build_array(
                                p.point -> 0,
                                p.point -> 1,
                                CASE WHEN nf.flag
                                    THEN to_jsonb(p_route_height) ELSE p.point -> 2 END
                            ) ORDER BY p.point_ord
                        ) AS line_coords
                    FROM jsonb_array_elements(ng.lines) WITH ORDINALITY AS l(line, line_ord)
                    CROSS JOIN LATERAL jsonb_array_elements(l.line) WITH ORDINALITY AS p(point, point_ord)
                    GROUP BY l.line_ord
                ) s ON ng.lines IS NOT NULL
                GROUP BY ng.feature_ord
            ),
            filled_geometries AS (
                -- 将重建的坐标写回原几何，之后统一包装为FeatureCollection交给公共函数解析。
                SELECT
                    ng.feature_ord,
                    CASE WHEN ng.lines IS NULL THEN ng.geom
                         WHEN ng.geom ->> 'type' = 'LineString'
                              THEN jsonb_set(ng.geom, '{coordinates}', fl.filled_coordinates -> 0, false)
                         ELSE jsonb_set(ng.geom, '{coordinates}', fl.filled_coordinates, false)
                    END AS geom
                FROM normalized_geometries ng
                LEFT JOIN filled_lines fl ON fl.feature_ord = ng.feature_ord
            )
            SELECT jsonb_build_object(
                'type', 'FeatureCollection',
                'features', COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'type', 'Feature',
                            'properties', '{}'::jsonb,
                            'geometry', fg.geom
                        ) ORDER BY fg.feature_ord
                    ),
                    '[]'::jsonb
                )
            ),
            (SELECT flag FROM empty_check)
        INTO v_route_json, v_route_empty
        FROM filled_geometries fg;

        IF v_route_empty THEN
            v_msg := format('参数错误：航线存在空坐标线段，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
            RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
            RETURN;
        END IF;

        -- 保留带Z航线供高度统计，同时准备二维副本用于范围覆盖与相交判断。
        v_route := ST_SetSRID(public.gis_geojson_to_geom(v_route_json::text), 4326);
        v_route_2d := ST_Force2D(v_route);
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('参数错误：航线GeoJSON解析失败：%s，执行时间 %s 秒',
            SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END;

    IF v_route IS NULL OR ST_IsEmpty(v_route) THEN
        v_msg := format('参数错误：航线GeoJSON无有效几何，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END IF;

    -- 统一解析可能得到其他几何类型，进入航线范围校验前再限制为线或多段线。
    v_route_type := ST_GeometryType(v_route);

    IF v_route_type NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        v_msg := format('参数错误：航线GeoJSON仅支持LineString或MultiLineString，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(400, v_msg, v_log_sql);
        RETURN QUERY SELECT 400, v_msg, false, v_check_type, '参数错误；请查看参数。'::text, 0::bigint;
        RETURN;
    END IF;

    -- 三、按项目、删除标记及p_only_enabled筛选区块；没有区块时按范围不通过返回201。
    SELECT count(*)
    INTO v_scope_count
    FROM public.bo_airspace_block b
    WHERE b.del_flag = false
      AND b.final_geom IS NOT NULL
      AND b.project_id = btrim(p_project_id)
      AND (p_only_enabled = false OR b.use_enabled = true);

    IF v_scope_count = 0 THEN
        v_check_type := '201';
        v_msg := format('无数据：项目下无可校验空域区块，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        PERFORM public.gis_write_error_log(200, v_msg, v_log_sql);
        RETURN QUERY SELECT 200, v_msg, false, v_check_type, '航线超出空域范围；当前项目下无可校验空域；'::text, 0::bigint;
        RETURN;
    END IF;

    WITH route_points AS MATERIALIZED (
        -- 四、逐航点保留二维位置及原Z；物化结果供空间命中和高度统计重复使用。
        SELECT
            row_number() OVER () AS point_no,
            ST_SetSRID(ST_Force2D((dp).geom), 4326) AS geom_2d,
            ST_Z((dp).geom) AS point_height
        FROM ST_DumpPoints(v_route) AS dp
    ),
    point_block_hits AS MATERIALIZED (
        -- LEFT JOIN保留未覆盖航点；先用包围盒缩小范围，再用ST_Covers精确判断且包含边界。
        SELECT
            rp.point_no,
            rp.point_height,
            b.id AS block_id,
            b.airspace_height
        FROM route_points rp
        LEFT JOIN public.bo_airspace_block b
            ON b.del_flag = false
           AND b.final_geom IS NOT NULL
           AND b.project_id = btrim(p_project_id)
           AND (p_only_enabled = false OR b.use_enabled = true)
           AND b.final_geom && rp.geom_2d
           AND ST_Covers(
               ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326),
               rp.geom_2d
           )
    ),
    point_stats AS (
        -- 每个航点单独统计覆盖数和最低限高，避免用其他位置的区块高度代替当前航点上限。
        SELECT
            point_no,
            point_height,
            -- 同一航点被多个区块覆盖时，按其中最低的高度上限校验。
            min(airspace_height)::numeric AS min_airspace_height,
            count(DISTINCT block_id)::bigint AS block_count
        FROM point_block_hits
        GROUP BY point_no, point_height
    )
    SELECT
        count(*) FILTER (WHERE block_count = 0)::bigint,
        count(*) FILTER (
            WHERE block_count > 0 AND point_height > COALESCE(min_airspace_height, 0)
        )::bigint,
        count(*)::bigint,
        (SELECT count(DISTINCT block_id)::bigint FROM point_block_hits),
        string_agg(DISTINCT format('航点高度%s米超过对应空域高度%s米上限',
            point_height, COALESCE(min_airspace_height, 0)), '；') FILTER (
            WHERE block_count > 0 AND point_height > COALESCE(min_airspace_height, 0))
    INTO
        v_outside_count,
        v_point_height_over_count,
        v_total_point_count,
        v_hit_count,
        v_point_height_details
    FROM point_stats;

    v_height_msg := '航点高度超出限制；' || v_point_height_details || '。';

    -- 航点全部在空域外时，航线仍可能穿过空域；判断航线是否命中区块，用于区分201/203文案（部分航点在空域内时必然命中，无需再查）。
    IF v_outside_count >= v_total_point_count THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.bo_airspace_block b
            WHERE b.del_flag = false
              AND b.final_geom IS NOT NULL
              AND b.project_id = btrim(p_project_id)
              AND (p_only_enabled = false OR b.use_enabled = true)
              AND b.final_geom && v_route_2d
              AND ST_Intersects(
                  ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326),
                  v_route_2d)
        ) INTO v_route_hits_airspace;
    END IF;

    -- 航线整体校验：整条航线的线段必须落在可飞空域并集内；航点已越界时直接按201返回，跳过并集校验。
    IF v_outside_count = 0 THEN
        SELECT NOT COALESCE(
                   ST_Covers(ST_Union(s.geom), v_route_2d),
                   false)
        INTO v_route_outside
        FROM (
            SELECT ST_SetSRID(ST_MakeValid(ST_Force2D(b.final_geom)), 4326) AS geom
            FROM public.bo_airspace_block b
            WHERE b.del_flag = false
              AND b.final_geom IS NOT NULL
              AND b.project_id = btrim(p_project_id)
              AND (p_only_enabled = false OR b.use_enabled = true)
              AND b.final_geom && ST_Envelope(v_route_2d)
        ) s;
    END IF;

    -- 范围和高度统计均已完成，优先识别同时失败；范围包含航点越界和航线段越界，仅对有空域覆盖的航点判断高度。
    IF (v_outside_count > 0 OR v_route_outside) AND v_point_height_over_count > 0 THEN
        v_check_type := '203';
        v_msg := format('校验不通过：%s；空域内有%s个航点的Z高度超限；范围和高度均不通过，阻断提交，执行时间 %s 秒',
            CASE WHEN v_outside_count > 0
                    THEN format('%s个航点不在可飞空域范围内', v_outside_count)
                 ELSE '航点都在空域内，航线超出可飞空域范围'
            END,
            v_point_height_over_count,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, false, v_check_type,
            ('航线超出空域范围并且高度超出限制；'
             || CASE
                    WHEN v_outside_count > 0 AND v_outside_count >= v_total_point_count
                         AND NOT v_route_hits_airspace
                        THEN '航点都不在可飞空域区块，航线超出可飞空域范围；'
                    WHEN v_outside_count > 0
                        THEN '航点有不在可飞空域内；'
                    ELSE '航点都在空域内，航线不在可飞空域范围；'
                END
             || v_point_height_details || '。')::text, v_hit_count;
        RETURN;
    END IF;

    -- 已排除范围和高度同时失败，剩余范围问题单独归类201。
    IF v_outside_count > 0 OR v_route_outside THEN
        v_check_type := '201';
        v_msg := format('校验不通过：%s，阻断提交，执行时间 %s 秒',
            CASE WHEN v_outside_count > 0
                    THEN format('%s个航点不在可飞空域范围内', v_outside_count)
                 ELSE '航点都在空域内，航线超出可飞空域范围'
            END,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, false, v_check_type,
            CASE
                WHEN v_outside_count > 0 AND v_outside_count >= v_total_point_count
                     AND NOT v_route_hits_airspace
                    THEN '航线超出空域范围；航点都不在可飞空域区块，航线超出可飞空域范围；'
                WHEN v_outside_count > 0
                    THEN '航线超出空域范围；航点有不在可飞空域内；'
                ELSE '航线超出空域范围；航点都在空域内，航线不在可飞空域范围；'
            END::text, v_hit_count;
        RETURN;
    END IF;

    -- 范围全部满足但存在超高航点时归类202；高度等于限高不会计入超限数量。
    IF v_point_height_over_count > 0 THEN
        v_check_type := '202';
        -- 与check_msg共用按各航点对应空域上限生成的超限说明，避免使用跨空域最大高度。
        v_msg := format('校验不通过：%s阻断提交，执行时间 %s 秒',
            v_height_msg,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN QUERY SELECT 200, v_msg, false, v_check_type, v_height_msg, v_hit_count;
        RETURN;
    END IF;

    -- 航点范围、整条线段范围及各航点高度均满足后，才返回业务通过。
    v_check_type := '200';
    RETURN QUERY SELECT
        200,
        format('校验通过：航点及整条航线均在可飞空域范围内，航点高度未超过可飞空域高度，命中空域区块%s个，执行时间 %s 秒',
            v_hit_count, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::text,
        true,
        v_check_type,
        '航线范围和高度均通过；航点及整条航线均在空域内，航点高度均未超限。'::text,
        v_hit_count;

EXCEPTION WHEN OTHERS THEN
    -- 未预期的几何处理或查询异常返回500，不复用此前算出的部分统计结果。
    v_msg := format('执行异常：%s，执行时间 %s 秒',
        SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    PERFORM public.gis_write_error_log(500, v_msg, v_log_sql);
    RETURN QUERY SELECT 500, v_msg, false, '500'::text, '校验执行异常；数据库或函数执行异常。'::text, 0::bigint;
END;
$$;

COMMENT ON FUNCTION public.gis_flight_airspace_check(text, text, numeric, boolean)
IS '校验航点及整条航线是否符合空域范围和高度限制，任一航点缺少Z高度时整条航线按航线高度赋值';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- SELECT code, msg, ischeck, check_type, check_msg, hit_count
-- FROM public.gis_flight_airspace_check(
--     'd10326d5a9894cd6b8b5bd365a103394',
--     '{"type":"Feature","properties":{"name":"聊城测试任务"},"geometry":{"type":"LineString","coordinates":[[116.050595925683,36.4486612526228],[116.028829029087,36.4484861336817]]}}',
--     120,
--     true
-- );


-- =============================================================================
-- 航线规划来源：使用现有public.bo_flight_job表
-- =============================================================================
-- 按bo_flight_job.out_id定位任务，从project_id和plan_route_gemo取得项目及规划航线。
-- plan_airspace_block_id记录规划空域关联；实时规则2和3均以当前位置覆盖的项目区块为准。

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

COMMENT ON TABLE public.bo_flight_job IS '无人机飞行任务表';

-- 为已有任务表补充机库位置、相对地面高度、安全起飞高度、返航高度和航飞模式；允许重复执行。
ALTER TABLE public.bo_flight_job
    ADD COLUMN IF NOT EXISTS uav_location geometry(PointZ, 4326),
    ADD COLUMN IF NOT EXISTS ground_height double precision DEFAULT 0,
    ADD COLUMN IF NOT EXISTS safe_height double precision,
    ADD COLUMN IF NOT EXISTS return_height double precision,
    ADD COLUMN IF NOT EXISTS flight_mode smallint;

COMMENT ON COLUMN public.bo_flight_job.uav_location IS '机库位置，WGS84三维点（经度、纬度、海拔高度），SRID=4326，高度单位：米';
COMMENT ON COLUMN public.bo_flight_job.ground_height IS '机库相对地面高度，单位：米，默认0';
COMMENT ON COLUMN public.bo_flight_job.safe_height IS '安全起飞高度，相对起飞点（机库）的高度，单位：米；垂直爬升时起飞高度取安全点与首航点高度的较大值，安全点更高时平飞至首航点上方再垂直下降；倾斜爬升时先上升至该高度再飞向首航点';
COMMENT ON COLUMN public.bo_flight_job.return_height IS '无人机返航高度，相对机库高度，单位：米；在末航点处垂直升降至该高度后平飞到机库上方，再垂直降落至机库';
COMMENT ON COLUMN public.bo_flight_job.flight_mode IS '航飞模式：1垂直爬升（先垂直爬升后平飞，安全起飞高度高于首航点时增加垂直下降段）；2倾斜爬升（爬升至安全起飞高度后，再直线飞向航线起始点）';

-- =============================================================================
-- 函数名称：5.gis_uav_flight_deviation_line
-- 函数功能：按航飞模式和高度基准构造起飞、规划航线、返航及降落的完整三维航线
-- 函数描述：
--   1. 校验机库位置、机库距地高度、安全起飞高度、返航高度、航飞模式及规划航线。
--   A. p_is_altitude=false：将原航点距地高度减去机库距地高度，输出相对机库航线。
--   B. p_is_altitude=true：按相同相对机库逻辑构造航线，再给所有点统一加机库海拔，输出海拔航线。
--   C. 模式1垂直爬升：先升至换算后首航点高度与安全起飞点高度的较大值，再平飞至首航点上方，安全点更高时垂直下降至首航点。
--   D. 模式2倾斜爬升：机库先垂直爬升到安全起飞高度，再直线飞向首航点。
--   E. 依次拼接起飞段、换算后的规划航线、末航点处升降至返航高度的垂直段、平飞返航段和垂直降落段。
-- 入参说明：
--   p_uav_location   机库三维位置，XY为WGS84经纬度，Z为机库海拔。
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
--   2. 两个分支均按业务约定忽略航点与机库之间的地形高差，不查询DEM；输出仅相差统一的机库海拔偏移。
--   3. 输入参数或航线连续性无效时抛出SQLSTATE 22023异常，不返回code/msg结果行。
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
--   p_uav_location   机库位置；geometry；必填；非空PointZ，XY为经纬度，Z为有限的海拔高度（米）。
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
--   海拔高度分支：机库点Z=机库海拔，规划航点Z=原航点Z-p_ground_height+机库海拔，安全点Z=机库海拔+p_safe_height，返航点Z=机库海拔+p_return_height。
-- 航飞模式说明：
--   1. 垂直爬升：机库 → 机库上方爬升点（首航点与安全点高度的较大值） → 必要时增加首航点上方同高度点 → 换算后的规划航线 → 末航点处返航高度点 → 机库上方返航点 → 机库。
--   2. 倾斜爬升：机库 → 机库上方安全起飞点 → 换算后的规划航线 → 末航点处返航高度点 → 机库上方返航点 → 机库。
-- 异常结果说明：
--   1. 参数或航线连续性无效时抛出SQLSTATE 22023，并说明具体错误。
--   2. 由gis_uav_flight_deviation_check调用时，上述异常转换为code=400、ischeck=false的校验结果。
-- 注意事项：
--   1. 输出允许负Z；所有Z统一表示所选高度基准，XY仍为WGS84经纬度，高度单位均为米。
--   2. 两个分支均不查询DEM，按业务约定忽略不同航点与机库之间的地形高差。
--   3. 海拔分支采用与相对分支相同的路径逻辑，各点Z统一加p_uav_location的机库海拔；机库和遥测海拔须采用相同高程基准。
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
    -- 一、机库须有有效经纬度和海拔Z；即使输出相对高度，也先校验完整的机库三维位置。
    IF p_uav_location IS NULL OR ST_IsEmpty(p_uav_location)
       OR GeometryType(p_uav_location) <> 'POINT' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '机库位置必须为非空的WGS84三维点';
    END IF;
    IF ST_SRID(p_uav_location) NOT IN (0, 4326)
       OR NOT (ST_X(p_uav_location) BETWEEN -180 AND 180)
       OR NOT (ST_Y(p_uav_location) BETWEEN -90 AND 90)
       OR ST_Z(p_uav_location) IS NULL
       OR ST_Z(p_uav_location)::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '机库位置须使用WGS84经纬度并包含有限的海拔高度';
    END IF;
    -- 这三个输入高度均要求非负有限；换算后的航点Z则可以为负，两者校验范围不同。
    IF EXISTS (
        SELECT 1 FROM (VALUES (p_ground_height), (p_safe_height), (p_return_height)) h(value)
        WHERE h.value IS NULL OR h.value < 0 OR h.value::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '机库距地高度、安全起飞高度及返航高度必须为非负有限值（米）';
    END IF;
    IF p_flight_mode IS NULL OR p_flight_mode NOT IN (1, 2) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '航飞模式必须为1（垂直爬升）或2（倾斜爬升）';
    END IF;
    IF p_is_altitude IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '航线高度类型不能为空：false为相对机库高度，true为海拔高度';
    END IF;
    -- 二、原航线须为有效三维线，原Z表示距地高度，不能用海拔或相对机库高度直接传入。
    IF p_route IS NULL OR ST_IsEmpty(p_route)
       OR GeometryType(p_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
       OR NOT ST_IsValid(p_route) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规划航线必须为有效且非空的三维LineString或MultiLineString';
    END IF;
    IF ST_SRID(p_route) NOT IN (0, 4326) OR EXISTS (
        SELECT 1 FROM ST_DumpPoints(p_route) d
        WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
           OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)
           OR ST_Z(d.geom) IS NULL OR ST_Z(d.geom) < 0
           OR ST_Z(d.geom)::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规划航点须使用WGS84经纬度并包含非负有限的相对地面高度';
    END IF;
    -- 前面已限制SRID为0或4326；此处统一标记并保留XYZ，不执行经纬度坐标变换。
    v_route := ST_SetSRID(ST_Force3DZ(p_route), 4326);
    -- 多段航线不能凭空补线，且不能用ST_LineMerge改变原有航段的方向和顺序。
    FOR v_part IN SELECT d.geom FROM ST_Dump(v_route) d ORDER BY d.path LOOP
        IF ST_IsEmpty(v_part.geom) THEN
            RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '多段规划航线不能包含空航段';
        END IF;
        IF v_previous_end IS NOT NULL AND (
            ST_X(v_previous_end) <> ST_X(ST_StartPoint(v_part.geom))
            OR ST_Y(v_previous_end) <> ST_Y(ST_StartPoint(v_part.geom))
            OR ST_Z(v_previous_end) <> ST_Z(ST_StartPoint(v_part.geom))
        ) THEN
            RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '多段规划航线必须按飞行顺序在三维空间首尾衔接';
        END IF;
        v_previous_end := ST_EndPoint(v_part.geom);
    END LOOP;
    -- 三、两种输出均按相对机库逻辑换算；相对输出的基准为0，海拔输出统一加机库海拔。
    v_home_height := CASE WHEN p_is_altitude THEN ST_Z(p_uav_location) ELSE 0 END;
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
    -- 四、建立同基准机库点：相对模式以机库为0，海拔模式直接使用机库原始海拔。
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
-- 1. 省略高度类型和航飞模式，默认垂直爬升、输出相对机库航线；机库海拔120米、距地20米，安全起飞60米、返航90米。
-- 原航点距地高度分别为120米、150米，换算后相对机库高度为100米、130米，垂直爬升至首航点高度100米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 120)', 4326),
--     20,
--     60,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,100,100,130,90,90,0]，末航点先从130米垂直降到90米，再以90米高度平飞返航并降落。
--
-- 2. 倾斜爬升，输出海拔航线；按与相对高度相同的路径逻辑构造，再统一加机库海拔120米。
-- 安全起飞点海拔为120+60=180米，返航点海拔为120+90=210米；原航点海拔分别为120-20+120=220米、150-20+120=250米。
-- SELECT ST_AsEWKT(public.gis_uav_flight_deviation_line(
--     ST_GeomFromText('POINT Z(113.46 34.81 120)', 4326),
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
--     ST_GeomFromText('POINT Z(113.46 34.81 120)', 4326),
--     20,
--     120,
--     90,
--     ST_GeomFromText('LINESTRING Z(113.48 34.81 120,113.48 34.83 150)', 4326)
-- ));
-- 返回Z序列为[0,120,120,100,130,90,90,0]；第2至3点平飞，第3至4点在首航点经纬度处垂直下降，末航点再垂直降至90米后平飞返航。

-- =============================================================================
-- 函数名称：6.gis_uav_flight_deviation_check
-- 函数功能：实时校验无人机偏航、超高和用空计划时段
-- 函数描述：
--   1. 校验任务ID、遥测坐标、遥测时间、规则开关和偏航距离阈值。
--   2. 按bo_flight_job.out_id读取未删除任务，取得所属项目、规划航线和起降参数。
--   A. 选择高度基准：altitude不可用、为0或等于height时使用相对机库高度，否则使用海拔高度。
--   B. 规则1：机库位置非空时生成完整起降航线并计算三维距离；机库位置为空时用原规划航线计算二维水平距离，严格超过偏航阈值时违规。
--   C. 规则2：按遥测位置和时间取得空域计划限高，转换到同一高度基准后比较，遥测高度严格超过限高时违规。
--   D. 规则3：任一覆盖当前位置的启用项目区块没有覆盖遥测时间的有效计划段时违规。
--   E. 汇总启用规则的违规项数和标记；只有本次启用规则全部正常时，ischeck才为true。
-- 入参说明：
--   p_task_id               任务ID，匹配bo_flight_job.out_id；项目ID从任务记录取得。
--   p_telemetry             遥测JSON对象，包含经纬度、海拔高度、相对机库高度和遥测时间。
--   p_rules                 三位整数规则开关，依次控制偏航、超高、用空计划时段；1执行，0跳过，默认ARRAY[1,1,1]。
--   p_deviation_threshold   偏航距离阈值，单位：米，默认50；须为非负有限值。
-- 返回说明：
--   返回code、msg、ischeck、active_rule、datajson。
--   code表示是否完成校验，ischeck表示是否通过；active_rule按偏航、超高、用空计划时段的顺序返回标记。
-- 注意事项：
--   1. 入参p_rules中1表示启用；返回active_rule中0表示违规，1表示未发现违规或未启用，两者含义不同。
--   2. code=200仍可能存在违规；code=400或500时，active_rule=[1,1,1]只是占位，不能据此认定正常。
--   3. 规则2和3使用遥测时间匹配计划；未覆盖任何启用项目区块时，这两项均不报异常。
--   4. 持续异常去重、恢复和乱序处理由调用方结合前后遥测结果维护。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_uav_flight_deviation_check');

-- =============================================================================
-- 函数介绍：6.gis_uav_flight_deviation_check
-- 主要作用：按任务ID读取规划航线及起降参数，对单次遥测执行偏航、超高和用空计划时段校验。
-- 入参说明：
--   p_task_id               任务ID；varchar；必填；匹配bo_flight_job.out_id，只读取del_flag=false的任务，项目ID由任务记录取得。
--   p_telemetry             遥测信息；jsonb；必填；必须为JSON对象，包含经纬度和时间戳，高度按下述规则取值。
--   p_rules                 规则开关；integer[]；选填，默认ARRAY[1,1,1]；依次控制偏航、超高、用空计划时段，1执行、0跳过。
--   p_deviation_threshold   偏航距离阈值；double precision；选填，默认50；单位：米；非负有限值，不能为NULL。
-- 遥测字段说明：
--   longitude              WGS84经度；数值；必填；范围[-180,180]，单位：度。
--   latitude               WGS84纬度；数值；必填；范围[-90,90]，单位：度。
--   altitude               海拔高度；有限数值，单位：米，允许负值；不可用、为0或等于height时选择相对分支，否则选择海拔分支。
--   height                 相对起飞点（机库）高度；有限数值，单位：米，允许负值；相对分支启用规则2，或机库位置非空并启用规则1时必填。
--   timeStamp              遥测时间；字符串；必填；建议yyyy-MM-dd HH:mm:ss，按timestamp without time zone解析后按北京时间解释。
-- 入参校验：
--   1. 任务ID不能为空，遥测必须为JSON对象。
--   2. 规则参数必须为长度3的一维整数数组，各元素只能为0或1，不能为NULL。
--   3. 经纬度须在上述范围内，timeStamp须可解析且为有限时间；启用规则2，或机库位置非空并启用规则1时，选定分支的遥测高度须有效。
--   4. 必须存在对应的未删除任务；规则1在机库位置非空时由gis_uav_flight_deviation_line校验规划航线及完整起降参数；机库位置为NULL或空几何时，只校验原规划航线的二维几何、SRID和经纬度。
--   5. 规则2存在空域限高时，相对分支须有非负有限的ground_height，海拔分支须有遥测点对应的有效DEM。
--   6. p_deviation_threshold须为非负有限值，即使关闭规则1也须有效；参数或必需数据无效时返回400。
-- 返回说明：
--   code                   integer；200=校验完成（可能有违规），400=参数或数据错误，500=执行异常。
--   msg                    text；正常执行时返回当前违规项数，失败时返回具体错误原因。
--   ischeck                boolean；true=本次启用规则全部正常，false=有违规、参数错误或执行异常。
--   active_rule            jsonb数组；固定三位，依次对应偏航、超高、用空计划时段；0=违规，1=未发现违规或未启用。
--   datajson               jsonb对象；包含project_id、task_id、telemetry。
--     project_id           任务记录中的项目ID，原样返回。
--     task_id              去除首尾空白后的任务ID。
--     telemetry            原样返回的遥测JSON对象。
-- msg业务结果说明：
--   1. 全部正常：code=200，msg=校验完成，当前异常0项，ischeck=true。
--   2. 存在违规：code=200，msg=校验完成，当前异常{N}项，ischeck=false；具体违规类型通过active_rule判断。
--   3. 参数或数据错误：code=400，msg说明任务、遥测、阈值、起降参数或必需DEM等错误原因，ischeck=false。
--   4. 执行异常：code=500，msg以“实时安全告警校验异常：”开头并附异常原因，ischeck=false。
-- active_rule业务结果说明（仅code=200时有效）：
--   [1,1,1]：本次启用规则未发现违规；关闭的规则也返回1，不表示这些规则已完成校验。
--   [0,1,1]：仅偏航违规；[1,0,1]：仅超高违规；[1,1,0]：仅用空计划时段违规。
--   多项违规时对应位置同时为0，例如[0,0,1]表示偏航和超高违规，[0,0,0]表示三项均违规。
-- 高度基准说明：
--   1. altitude缺失、格式错误、非有限、为0或与height精确相等时选择相对分支，否则使用有效海拔；规则1的三维校验和规则2采用同一分支，机库位置为空时规则1不使用高度。
--   2. 相对分支：遥测使用height，机库点Z=0，原航点Z和空域距地限高均减ground_height；忽略航点与机库的地形高差。
--   3. 海拔分支：遥测使用altitude，机库点Z为机库海拔，原航点Z-ground_height后统一加机库海拔；空域距地限高仍加遥测点DEM。
--   4. altitude和height分别解析，格式错误或非有限值视为不可用；海拔分支不要求height有效。
-- 规则说明：
--   A. 规则1：机库位置非空时，按航飞模式生成完整航线，将XY转换到以遥测位置为中心的米制投影，计算包含Z高度差的三维最短距离。
--      机库位置为NULL或空几何时，不构造起降段，直接将原规划航线转为二维geography计算水平距离，不要求遥测高度或起降参数。
--      距离严格大于p_deviation_threshold时违规，等于阈值正常；比较所选整条航线，不区分当前飞行阶段。
--   B. 规则2：查找覆盖遥测位置的启用、未删除且final_geom不为空的项目区块，区块边界也视为命中。
--      每个区块对覆盖遥测时间的有效计划段height取最大值；height只接受非负整数或小数，无有效值时回退区块airspace_height，再为空取0。
--      计划高度优先覆盖区块高度，不额外与区块最高高度取较小值；多个覆盖区块之间取限高最小值，再统一高度基准比较。
--      遥测高度严格大于最终限高时违规，等于限高正常；本规则只检查超高，不检查min_height。
--   C. 规则3：任一覆盖区块没有当前有效计划段时违规；计划须未删除、plan_status=true且日期及时间命中。
--      计划段是否有效只按时间判断，height是否有效不影响计划命中；不检查管控围栏或任务plan_airspace_block_id。
--   D. 规则2和3同时启用时复用区块及计划查询；仅启用规则3时单独查询，不解析计划高度。
-- 注意事项：
--   1. 规则2和3按遥测对应的北京时间查询当天及前一天计划，采用[开始,结束)；结束时间小于或等于开始时间时顺延一天。
--   2. 计划段startTime/endTime仅接受HH:mm或HH:mm:ss，小时范围00至23；time_plan示例为[{"startTime":"10:00:00","endTime":"12:00:00","height":150}]。
--   3. time_plan只按首尾正则初筛，通过初筛的非法JSON仍可能使本次校验返回400。
--   4. 未覆盖任何启用项目区块时，规则2限高为NULL、规则3无缺失计划区块，这两项均不报异常；不据此判断已处于可飞空域内。
--   5. 航线构造的两个高度分支均不查询DEM；海拔分支仅规则2的限高换算查询DEM，须返回code=200和有限海拔，0米、负值均有效，且须与遥测海拔采用同一高程基准。
--      必需DEM缺失、无覆盖、非有限或查询失败时返回400，不在同次校验中切换高度基准。
--   6. 规则2关闭，且规则1关闭或机库位置为空时，不要求遥测高度及起降参数有效；规则3始终不依赖高度，全部规则关闭仍须通过基础参数和任务校验。
--   7. code=400或500时ischeck=false、active_rule=[1,1,1]，不能把占位标记解释为正常或恢复。
--   8. 调用方须保证任务out_id唯一、项目ID和空域限高数据有效；本函数当前未单独校验重复out_id、空项目或区块限高的有限性。
--   9. 仅检查本次遥测，持续异常去重、恢复、乱序及遥测时效处理由调用方维护。
-- 依赖说明：PostGIS、gis_write_error_log、gis_uav_flight_deviation_line、bo_flight_job、bo_airspace_block、bo_airspace_plan；海拔分支的规则2还需要DEM查询函数和对应数据。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_uav_flight_deviation_check(
    p_task_id varchar,
    p_telemetry jsonb,
    p_rules integer[] DEFAULT ARRAY[1,1,1],
    p_deviation_threshold double precision DEFAULT 50
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
    -- altitude为海拔，height为相对机库高度；按上游约定选择本次统一使用的高度基准。
    v_task_id varchar := btrim(p_task_id);
    v_project varchar;
    v_lon double precision;
    v_lat double precision;
    v_alt double precision;
    v_height double precision;
    v_use_altitude boolean;
    v_telemetry_height double precision;
    v_ground_elevation double precision;
    v_dem_code integer;
    v_check_height numeric;
    v_height_limit numeric;
    v_point_2d geometry;
    v_point_3d geometry;
    v_route geometry;
    v_uav_location geometry;
    v_has_uav_location boolean;
    v_dock_ground_height double precision;
    v_safe_height double precision;
    v_return_height double precision;
    v_flight_mode integer;
    v_distance double precision;
    v_local_projection text;
    -- v_time保存遥测对应的绝对时间，v_local保存北京时间，用于匹配计划日期和时段。
    v_time timestamptz;
    v_local timestamp;

    -- v_rules保存实际启用的规则编号；v_active_rule固定按偏航、超高、用空计划时段排列。
    -- 入参开关中1表示启用；返回标记中0表示违规、1表示未发现违规或未启用。
    v_rule integer;
    v_violation_count integer := 0;
    v_rules integer[];
    v_active_rule integer[] := ARRAY[1,1,1];
    v_bad boolean;
    v_no_plan boolean := false;
    v_log_sql text;

BEGIN
    -- 一、记录本次调用，随后完成基础参数校验；所有规则均关闭时仍须校验参数和任务。
    v_log_sql := format('SELECT * FROM public.gis_uav_flight_deviation_check(%L, %L, %L, %L);',
        p_task_id, p_telemetry::text, p_rules::text, p_deviation_threshold::text);

    -- 记录函数调用日志：入参和函数名称写入gis_error_log
    PERFORM public.gis_write_error_log(600, 'gis_uav_flight_deviation_check', v_log_sql);
    -- 任务ID须非空，遥测须为JSON对象；参数错误统一交由下方异常分支返回400。
    IF COALESCE(v_task_id, '') = ''
       OR jsonb_typeof(p_telemetry) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '任务ID和遥测对象不能为空';
    END IF;
    -- 三位开关只能取0或1，不接受NULL、多维数组或其他长度。
    IF p_rules IS NULL OR cardinality(p_rules) <> 3
       OR array_ndims(p_rules) IS DISTINCT FROM 1 OR EXISTS (
        SELECT 1 FROM unnest(p_rules) e(item)
        WHERE e.item IS NULL OR e.item NOT IN (0, 1)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规则开关必须为三个整数0或1，如[1,0,1]';
    END IF;
    -- 阈值0允许零距离容差，不能用来关闭偏航规则；关闭规则须通过p_rules控制。
    IF p_deviation_threshold IS NULL OR p_deviation_threshold < 0
       OR p_deviation_threshold::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '偏航距离阈值必须为非负有限值（米）';
    END IF;
    -- 用元素的位置生成规则编号，例如[1,0,1]转换为规则编号数组[1,3]。
    -- 全部关闭时生成空数组，后续规则计算及违规汇总循环均跳过。
    SELECT COALESCE(array_agg(e.pos::integer ORDER BY e.pos), ARRAY[]::integer[])
    INTO v_rules FROM unnest(p_rules) WITH ORDINALITY e(item, pos)
    WHERE e.item = 1;
    -- 二、解析遥测坐标：经纬度按WGS84范围校验。
    v_lon := (p_telemetry->>'longitude')::double precision;
    v_lat := (p_telemetry->>'latitude')::double precision;
    IF v_lon IS NULL OR NOT (v_lon BETWEEN -180 AND 180)
       OR v_lat IS NULL OR NOT (v_lat BETWEEN -90 AND 90) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '经纬度无效，单位必须为度';
    END IF;

    -- 分别解析海拔和相对机库高度；格式错误或非有限值视为缺失，后续按启用规则要求选定高度有效。
    BEGIN
        v_alt := NULLIF(btrim(p_telemetry->>'altitude'), '')::double precision;
    EXCEPTION WHEN data_exception THEN
        v_alt := NULL;
    END;
    IF v_alt::text IN ('NaN', 'Infinity', '-Infinity') THEN
        v_alt := NULL;
    END IF;
    BEGIN
        v_height := NULLIF(btrim(p_telemetry->>'height'), '')::double precision;
    EXCEPTION WHEN data_exception THEN
        v_height := NULL;
    END;
    IF v_height::text IN ('NaN', 'Infinity', '-Infinity') THEN
        v_height := NULL;
    END IF;
    -- 按上游约定，海拔为0或等于相对高度时使用相对高度；海拔或可单参调用的DEM函数缺失时也进入相对分支。
    v_use_altitude := v_alt IS NOT NULL AND v_alt <> 0
                      AND (v_height IS NULL OR v_alt <> v_height)
                      AND (
                          to_regprocedure('public.gis_dem_value_at_point(geometry)') IS NOT NULL
                          OR EXISTS (
                              SELECT 1 FROM pg_proc p
                              WHERE p.oid = to_regprocedure('public.gis_dem_value_at_point(geometry,text)')
                                AND p.pronargdefaults >= 1
                          )
                      );
    IF v_alt IS NOT NULL AND v_alt <> 0
       AND (v_height IS NULL OR v_alt <> v_height) AND NOT v_use_altitude THEN
        PERFORM public.gis_write_error_log(600,
            'gis_uav_flight_deviation_check：DEM函数缺失或不支持单参数调用，改用相对高度height', v_log_sql);
    END IF;
    v_telemetry_height := CASE WHEN v_use_altitude THEN v_alt ELSE v_height END;
    -- 三、遥测时间去除首尾空白后按timestamp without time zone解析，再按北京时间解释；须为有限时间。
    -- yyyy-MM-dd HH:mm:ss为建议输入格式；此处通过类型转换解析，计划匹配使用遥测时间。
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
    -- 空域覆盖和DEM查询使用二维位置；有机库位置的偏航校验稍后结合选定高度构造三维点。
    v_point_2d := ST_SetSRID(ST_MakePoint(v_lon, v_lat), 4326);
    -- 四、按平台任务out_id读取未删除任务，取得项目、原航线及起降参数。
    SELECT r.project_id, r.plan_route_gemo, r.uav_location, r.ground_height,
           r.safe_height, r.return_height, r.flight_mode
    INTO v_project, v_route, v_uav_location, v_dock_ground_height,
         v_safe_height, v_return_height, v_flight_mode
    FROM public.bo_flight_job r
    WHERE r.out_id = v_task_id AND r.del_flag = false;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '指定任务out_id不存在或任务已删除';
    END IF;
    v_has_uav_location := v_uav_location IS NOT NULL AND NOT ST_IsEmpty(v_uav_location);
    -- 超高和有机库位置的三维偏航需要高度；无机库位置时，偏航沿用原航线的二维水平距离。
    IF 2 = ANY(v_rules) OR (1 = ANY(v_rules) AND v_has_uav_location) THEN
        IF v_telemetry_height IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '偏航或超高校验需要有效海拔或相对机库高度';
        END IF;
        v_check_height := v_telemetry_height::numeric;
    END IF;
    -- 五、规则1：有机库位置时校验完整三维航线；机库位置为空时继续校验原规划航线的水平偏航。
    IF 1 = ANY(v_rules) THEN
        IF v_has_uav_location THEN
            v_route := public.gis_uav_flight_deviation_line(
                v_uav_location, v_dock_ground_height, v_safe_height,
                v_return_height, v_route, v_use_altitude, v_flight_mode
            );
            v_point_3d := ST_SetSRID(ST_MakePoint(v_lon, v_lat, v_telemetry_height), 4326);
            -- 局部等距投影以本次遥测位置为中心，XY转为米，Z保留米，避免经纬度与高度混用单位。
            v_local_projection := format('+proj=aeqd +lat_0=%s +lon_0=%s +datum=WGS84 +units=m +no_defs', v_lat, v_lon);
            v_distance := ST_3DDistance(
                ST_Transform(v_point_3d, v_local_projection),
                ST_Transform(v_route, v_local_projection)
            );
        ELSE
            -- 缺少机库位置无法补齐起降段或统一机库高度基准，沿用旧逻辑检查原航线的二维水平偏航。
            IF v_route IS NULL OR ST_IsEmpty(v_route)
               OR GeometryType(v_route) NOT IN ('LINESTRING', 'MULTILINESTRING')
               OR NOT ST_IsValid(v_route) THEN
                RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规划航线必须为有效且非空的LineString或MultiLineString';
            END IF;
            IF ST_SRID(v_route) NOT IN (0, 4326) OR EXISTS (
                SELECT 1 FROM ST_DumpPoints(v_route) d
                WHERE NOT (ST_X(d.geom) BETWEEN -180 AND 180)
                   OR NOT (ST_Y(d.geom) BETWEEN -90 AND 90)
            ) THEN
                RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '规划航点须使用有效的WGS84经纬度';
            END IF;
            v_route := ST_SetSRID(ST_Force2D(v_route), 4326);
            v_distance := ST_Distance(v_point_2d::geography, v_route::geography);
        END IF;
    END IF;
    -- 六、规则2：按当前点位与遥测时间，计算本次超高校验使用的高度上限。
    IF 2 = ANY(v_rules) THEN
        -- v_local来自遥测timeStamp，按计划日期和[开始,结束)筛选对应计划段；前一天计划用于匹配跨午夜时段。
        -- 先查所有位置覆盖的启用区块，对每个区块独立查命中时间的计划段height。
        -- 每个区块同时统计命中计划段数量与有效height最大值，供规则2和3复用；无效height不参与max，但不影响计划命中。
        -- 仅当所有命中段的height均无效，或没有命中任何计划段时，才回退区块airspace_height；后者为空则取0。
        -- 多个区块覆盖同一点时，再取各区块限高的最小值。
        -- 未命中任何启用区块时，min返回NULL、v_no_plan为false。
        SELECT min(COALESCE(plan_match.height_limit, b.airspace_height::numeric, 0)),
               COALESCE(bool_or(plan_match.segment_count = 0), false)
        INTO v_height_limit, v_no_plan
        FROM public.bo_airspace_block b
        CROSS JOIN LATERAL (
            SELECT max(CASE WHEN (item ->> 'height') ~ '^[0-9]+(\.[0-9]+)?$'
                            THEN (item ->> 'height')::numeric END) AS height_limit,
                   count(*) AS segment_count
            FROM public.bo_airspace_plan p
            -- 首尾正则只做外形筛选；通过初筛的非法JSON仍交由400异常分支处理。
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE
                    WHEN btrim(COALESCE(p.time_plan, '')) ~ '^\s*\['
                     AND btrim(COALESCE(p.time_plan, '')) ~ '(\{[^\{\}]*\}|\])\s*$'
                    THEN p.time_plan::jsonb
                    ELSE '[]'::jsonb
                END
            ) AS plan_item(item)
            WHERE p.block_id = b.id
              AND p.del_flag = false AND p.plan_status = true
              AND p.use_date BETWEEN v_local::date - 1 AND v_local::date
              -- 与规则3保持相同的时间格式及[开始,结束)判断；跨午夜时结束日期顺延一天。
              AND NULLIF(item ->> 'startTime', '') ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$'
              AND NULLIF(item ->> 'endTime', '')   ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$'
              AND v_local >= p.use_date + NULLIF(item ->> 'startTime', '')::time
              AND v_local <  p.use_date + NULLIF(item ->> 'endTime', '')::time
                  + CASE WHEN NULLIF(item ->> 'endTime', '')::time <= NULLIF(item ->> 'startTime', '')::time
                         THEN interval '1 day' ELSE interval '0 day' END
        ) plan_match
        WHERE b.project_id = v_project AND b.del_flag = false
          AND b.use_enabled = true AND b.final_geom IS NOT NULL
          -- 先用原列包围盒利用现有GiST索引，再精确判断二维覆盖（包含区块边界）。
          AND b.final_geom && v_point_2d
          AND ST_Covers(ST_SetSRID(ST_Force2D(b.final_geom), 4326), v_point_2d);
        -- 空域计划/区块限高均为距地高度，转换到与本次遥测相同的高度基准后再比较。
        IF v_height_limit IS NOT NULL THEN
            IF v_use_altitude THEN
                -- 此处仅为超高校验按遥测位置查询DEM换算限高；航线构造按机库海拔统一平移，不查询DEM。
                -- 必需DEM不可用时返回400，同一次调用不会临时回退height而混用高度基准。
                BEGIN
                    SELECT dem.code, dem.elevation INTO v_dem_code, v_ground_elevation
                    FROM public.gis_dem_value_at_point(v_point_2d) dem LIMIT 1;
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '无法取得遥测点DEM地形海拔：' || SQLERRM;
                END;
                IF v_dem_code IS DISTINCT FROM 200 OR v_ground_elevation IS NULL
                   OR v_ground_elevation::text IN ('NaN', 'Infinity', '-Infinity') THEN
                    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '遥测点缺少有效DEM地形海拔，无法进行海拔超高校验';
                END IF;
                v_height_limit := v_height_limit + v_ground_elevation::numeric;
            ELSE
                IF v_dock_ground_height IS NULL OR v_dock_ground_height < 0
                   OR v_dock_ground_height::text IN ('NaN', 'Infinity', '-Infinity') THEN
                    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = '相对高度超高校验需要非负有限的机库距地高度';
                END IF;
                -- 按业务约定忽略航点与机库的地形高差：相对限高=距地限高-机库距地高度。
                v_height_limit := v_height_limit - v_dock_ground_height::numeric;
            END IF;
        END IF;
    END IF;
    -- 七、规则3：仅检查所在区块是否有覆盖遥测时间的有效计划段。
    -- 规则2已完成相同的区块与时段查询时直接复用；未命中任何启用区块时不报本项异常。
    IF 3 = ANY(v_rules) AND NOT (2 = ANY(v_rules)) THEN
        -- 找到任意一个“位置覆盖但没有当前有效计划段”的区块即可违规，并非任一区块有计划就通过。
        SELECT EXISTS (
            SELECT 1 FROM public.bo_airspace_block b
            WHERE b.project_id = v_project AND b.del_flag = false
              AND b.use_enabled = true AND b.final_geom IS NOT NULL
              AND b.final_geom && v_point_2d
              AND ST_Covers(ST_SetSRID(ST_Force2D(b.final_geom), 4326), v_point_2d)
              AND NOT EXISTS (
                  SELECT 1 FROM public.bo_airspace_plan p
                  CROSS JOIN LATERAL jsonb_array_elements(
                      CASE
                          WHEN btrim(COALESCE(p.time_plan, '')) ~ '^\s*\['
                           AND btrim(COALESCE(p.time_plan, '')) ~ '(\{[^\{\}]*\}|\])\s*$'
                          THEN p.time_plan::jsonb
                          ELSE '[]'::jsonb
                      END
                  ) s(item)
                  WHERE p.block_id = b.id AND p.del_flag = false AND p.plan_status = true
                    -- 与规则2一致，读取当天及前一天计划，采用[开始,结束)，支持跨午夜。
                    AND p.use_date BETWEEN v_local::date - 1 AND v_local::date
                    AND NULLIF(s.item->>'startTime', '') ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$'
                    AND NULLIF(s.item->>'endTime', '')   ~ '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$'
                    AND v_local >= p.use_date + NULLIF(s.item->>'startTime', '')::time
                    AND v_local <  p.use_date + NULLIF(s.item->>'endTime', '')::time
                        + CASE WHEN NULLIF(s.item->>'endTime', '')::time <= NULLIF(s.item->>'startTime', '')::time
                               THEN interval '1 day' ELSE interval '0 day' END
              )
        ) INTO v_no_plan;
    END IF;

    -- 八、仅汇总已启用规则；所选偏航距离严格大于传入阈值、同基准遥测高度严格大于非NULL限高时才违规。
    -- 未启用规则的返回标记保持为1。
    FOREACH v_rule IN ARRAY v_rules LOOP
        v_bad := CASE v_rule
            WHEN 1 THEN v_distance > p_deviation_threshold
            WHEN 2 THEN v_height_limit IS NOT NULL AND v_check_height > v_height_limit
            ELSE v_no_plan END;
        IF v_bad THEN
            -- 返回标记初始化为1，仅把已启用且实际违规的位置改为0，同时累计异常项数。
            v_active_rule[v_rule] := 0;
            v_violation_count := v_violation_count + 1;
        END IF;
    END LOOP;
    -- code=200表示校验完成，ischeck由违规项数决定；同时返回任务所属项目与原始遥测信息。
    RETURN QUERY SELECT 200, format('校验完成，当前异常%s项', v_violation_count),
        v_violation_count = 0, to_jsonb(v_active_rule),
        jsonb_build_object('project_id', v_project, 'task_id', v_task_id, 'telemetry', p_telemetry);
EXCEPTION
    -- 参数显式校验错误，以及数值、时间、JSON等数据转换异常，统一返回400。
    -- 失败时[1,1,1]仅为占位，调用方须先检查code，不能把失败结果视为正常或恢复。
    WHEN data_exception THEN
        PERFORM public.gis_write_error_log(400, 'gis_uav_flight_deviation_check', SQLERRM::text);
        RETURN QUERY SELECT 400, SQLERRM::text, false, '[1,1,1]'::jsonb,
            jsonb_build_object('project_id', v_project, 'task_id', v_task_id, 'telemetry', p_telemetry);
    -- 其余执行异常返回500并记录错误日志，不输出此前已经计算出的部分规则结果。
    WHEN OTHERS THEN
        PERFORM public.gis_write_error_log(500, 'gis_uav_flight_deviation_check', SQLERRM::text);
        RETURN QUERY SELECT 500, ('实时安全告警校验异常：' || SQLERRM)::text,
            false, '[1,1,1]'::jsonb,
            jsonb_build_object('project_id', v_project, 'task_id', v_task_id, 'telemetry', p_telemetry);
END;
$$;
COMMENT ON FUNCTION public.gis_uav_flight_deviation_check(varchar, jsonb, integer[], double precision)
IS '按任务和遥测实时校验偏航、超高及用空计划时段；有机库位置时校验完整三维航线，无机库位置时校验原航线水平偏航，偏航阈值默认50米';

-- =============================================================================
-- 调用示例
-- =============================================================================
-- 前提：任务已存在且del_flag=false；执行规则1时须具备有效规划航线；机库位置非空时还须具备三维航点及完整起降参数，为空时沿用原航线水平偏航校验。
-- 启用海拔超高校验时还须具备有效DEM；以下示例展示调用方式，实际是否通过取决于任务航线、空域和计划数据。
-- 1. 默认执行全部规则，偏航阈值为50米；213.49既不为0也不等于101.9，使用海拔分支。
-- SELECT * FROM public.gis_uav_flight_deviation_check(
--     'f6a024e15c604ce4a7dfd2f895c266fe',
--     '{"height":101.9,"altitude":213.49,"latitude":34.816419,"longitude":113.472792,"timeStamp":"2026-11-11 10:49:32"}'::jsonb
-- );
--
-- 2. 显式传入全部规则，省略第四参仍使用默认50米；altitude=0，使用height=101.9的相对机库高度。
-- altitude与height精确相等时也进入相对分支；航线及空域距地高度均减任务ground_height后比较。
-- SELECT * FROM public.gis_uav_flight_deviation_check(
--     'f6a024e15c604ce4a7dfd2f895c266fe',
--     '{"height":101.9,"altitude":0,"latitude":34.816419,"longitude":113.472792,"timeStamp":"2026-11-11 10:49:32"}'::jsonb,
--     ARRAY[1,1,1]
-- );
--
-- 3. 只校验偏航和用空计划时段，自定义偏航阈值为30米；三维距离等于30米正常，严格超过30米才判偏航。
-- SELECT * FROM public.gis_uav_flight_deviation_check(
--     'f6a024e15c604ce4a7dfd2f895c266fe',
--     '{"height":101.9,"altitude":0,"latitude":34.816419,"longitude":113.472792,"timeStamp":"2026-11-11 10:49:32"}'::jsonb,
--     ARRAY[1,0,1],
--     30
-- );
--
-- 4. 仅校验用空计划时段，无须提供altitude或height；偏航阈值省略时取默认50米。
-- SELECT * FROM public.gis_uav_flight_deviation_check(
--     'f6a024e15c604ce4a7dfd2f895c266fe',
--     '{"latitude":34.816419,"longitude":113.472792,"timeStamp":"2026-11-11 10:49:32"}'::jsonb,
--     ARRAY[0,0,1]
-- );
-- 仅校验超高时第三参传ARRAY[0,1,0]；关闭全部规则时传ARRAY[0,0,0]，仍会校验基础参数和任务是否存在。
-- 先判断code，再读取ischeck和active_rule；例如code=200且active_rule=[1,0,1]表示仅发现超高违规。
--
-- 5. 任务机库位置为NULL或空几何时，直接用原规划航线校验水平偏航；仅启用规则1时无须提供高度和起降参数。
-- SELECT * FROM public.gis_uav_flight_deviation_check(
--     'f6a024e15c604ce4a7dfd2f895c266fe',
--     '{"latitude":34.816419,"longitude":113.472792,"timeStamp":"2026-11-11 10:49:32"}'::jsonb,
--     ARRAY[1,0,0]
-- );

 

-- =============================================================================
-- 函数名称：7.gis_flight_task_route_check
-- 函数功能：校验输入航线与指定项目下指定任务的规划航线是否存在空间冲突。
-- 函数描述：
--   1. 校验项目 ID、航线 GeoJSON、任务 ID 数组和缓冲半径。
--   2. 通过 public.gis_geojson_to_geom 解析航线，统一转为二维 WGS84（SRID=4326）。
--   3. 仅接受有效的 LineString 或 MultiLineString；Z高度范围参与冲突判断，M维度不参与判断。
--   4. 按缓冲半径（米）生成输入航线缓冲区；半径为 0 时直接使用原始航线。
--   5. 从 public.bo_flight_job 查询未删除、项目匹配、任务 ID 匹配且规划航线有效的任务。
--   6. 输入航线缓冲区与任务规划航线二维相交，且Z高度范围重叠时判定为冲突。
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
-- 函数介绍：7.gis_flight_task_route_check
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
--   1. 解析后的航线使用 WGS84 坐标（SRID=4326），Z高度范围参与冲突判断。
--   2. 航线必须为有效且非空的 LineString 或 MultiLineString，且能够取得Z高度范围。
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
--   相交；还须满足两条航线的Z高度范围重叠。命中的任务 ID 去重并按字典序排序。
--
-- 返回说明（固定返回一行）：
--   code：200 表示校验完成；400 表示参数、GeoJSON 或航线几何不合法；500 表示执行
--         过程发生未预期异常。
--   msg：校验结果或错误详情；发现冲突时包含冲突数量及任务 ID。
--   ischeck：true 表示未发现冲突；false 表示发现至少一条冲突或校验失败。
--   task_ids：冲突任务 ID，以英文逗号分隔；无冲突、参数错误或系统异常时返回空字符串。
--
-- 注意事项：
--   本函数按二维空间相交及航线Z高度范围重叠判断冲突，不比较时间、速度或其他任务属性；
--   p_buffer_radius 的单位为米，输入 GeoJSON 坐标必须使用 WGS84 经纬度坐标。
--   待校验航线与候选任务航线的Z须采用同一高度基准；函数直接比较高度区间，不自动进行海拔与相对高度换算。
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
    v_route_min_z double precision; v_route_max_z double precision;
BEGIN
    -- 一、限定项目、待校验航线和候选任务集合，避免对项目全部任务进行无条件冲突查询。
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
    -- 缓冲半径单位为米；0表示直接使用原航线，负值、NULL和非有限值均作为参数错误。
    IF p_buffer_radius IS NULL OR p_buffer_radius < 0
       OR p_buffer_radius IN ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision) THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '缓冲半径必须为非负有限值（米）');
        RETURN QUERY SELECT 400,'参数错误：缓冲半径必须为非负有限值（米）'::text,false,''::text; RETURN;
    END IF;
    BEGIN
        -- 二、调用统一解析函数提取航线几何，输入格式错误在当前分支转换为400。
        v_route := public.gis_geojson_to_geom(p_route_geojson);
    EXCEPTION WHEN OTHERS THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线GeoJSON解析失败：' || SQLERRM);
        RETURN QUERY SELECT 400, ('参数错误：航线GeoJSON解析失败：' || SQLERRM), false, '';
        RETURN;
    END;
    -- 保留原Z并修复几何，先提取待校验航线的整体高度区间，供后续与候选任务比较。
    v_route:=ST_SetSRID(ST_MakeValid(v_route),4326);
    SELECT min(ST_Z((d).geom)), max(ST_Z((d).geom)) INTO v_route_min_z, v_route_max_z FROM ST_DumpPoints(v_route) AS d;
    IF v_route_min_z IS NULL OR v_route_max_z IS NULL THEN
        RETURN QUERY SELECT 400, 'route Z height is required'::text, false, ''::text;
        RETURN;
    END IF;
    -- 高度范围和线类型都满足后才进入缓冲区与相交判断；点、面、空几何均不接受。
    IF v_route IS NULL OR ST_IsEmpty(v_route)
       OR ST_GeometryType(v_route) NOT IN ('ST_LineString','ST_MultiLineString')
       OR NOT ST_IsValid(v_route) THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线geometry必须为有效的LineString或MultiLineString');
        RETURN QUERY SELECT 400,'参数错误：航线geometry必须为有效的LineString或MultiLineString'::text,false,''::text; RETURN;
    END IF;
    BEGIN
        -- 三、geography按米生成水平缓冲区；半径为0时保留原线，Z高度另按区间判断。
        v_buffer:=CASE WHEN p_buffer_radius=0 THEN v_route ELSE ST_Buffer(v_route::geography,p_buffer_radius)::geometry END;
    EXCEPTION WHEN OTHERS THEN
        PERFORM public.gis_write_error_log(400, 'gis_flight_task_route_check', '航线缓冲区生成失败：' || SQLERRM);
        RETURN QUERY SELECT 400,('参数错误：航线缓冲区生成失败：'||SQLERRM)::text,false,''::text; RETURN;
    END;
    -- 四、候选任务须项目匹配、ID位于指定集合、未删除且航线有效；二维相交和高度区间重叠须同时满足。
    -- 不比较任务时间，也不按相交位置插值高度；命中任务ID去重后按字典序返回。
    SELECT array_agg(DISTINCT g.out_id::text ORDER BY g.out_id::text) INTO v_hit_ids FROM public.bo_flight_job g WHERE COALESCE(g.del_flag,false)=false AND g.project_id=btrim(p_project_id) AND g.out_id::text=ANY(p_task_ids::text[]) AND g.plan_route_gemo IS NOT NULL AND NOT ST_IsEmpty(g.plan_route_gemo) AND ST_IsValid(g.plan_route_gemo) AND ST_Intersects(v_buffer,ST_SetSRID(ST_Force2D(g.plan_route_gemo),4326))
    AND ST_ZMin(Box3D(g.plan_route_gemo)) IS NOT NULL
    AND ST_ZMax(Box3D(g.plan_route_gemo)) IS NOT NULL
    -- 两个闭区间相交即满足高度条件，区间端点相等也视为重叠。
    AND v_route_min_z <= ST_ZMax(Box3D(g.plan_route_gemo))
    AND v_route_max_z >= ST_ZMin(Box3D(g.plan_route_gemo));
    -- 五、无冲突时返回true；有冲突时返回false及逗号分隔的任务ID，code均为200。
    v_hit_ids:=COALESCE(v_hit_ids,ARRAY[]::text[]);
    IF cardinality(v_hit_ids)=0 THEN RETURN QUERY SELECT 200,'校验完成，未发现相交航线'::text,true,''::text; ELSE RETURN QUERY SELECT 200,format('校验完成，发现%s条相交航线：%s',cardinality(v_hit_ids),array_to_string(v_hit_ids,',')),false,array_to_string(v_hit_ids,','); END IF;
EXCEPTION WHEN OTHERS THEN
    -- 未被前面参数分支处理的空间或查询异常返回500，不返回部分命中任务。
    PERFORM public.gis_write_error_log(500, 'gis_flight_task_route_check', '任务航线冲突校验异常：' || SQLERRM);
    RETURN QUERY SELECT 500,('任务航线冲突校验异常：'||SQLERRM)::text,false,''::text;
END; $$;


COMMENT ON FUNCTION public.gis_flight_task_route_check(varchar, text, varchar[], double precision)
IS '按项目、航线GeoJSON和任务ID数组校验任务航线冲突，缓冲半径默认50米';

 
-- =============================================================================
-- 调用示例
-- =============================================================================
-- 待校验航线为三维LineString，高度100米；候选任务航线须使用同一高度基准，水平缓冲半径为50米。
-- SELECT code, msg, ischeck, task_ids
-- FROM public.gis_flight_task_route_check(
--     'project-001',
--     '{"type":"LineString","coordinates":[[116.1,36.4,100],[116.2,36.5,100]]}',
--     ARRAY['task-001','task-002']::varchar[],
--     50
-- );
