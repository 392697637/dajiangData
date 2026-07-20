-- =============================================================================
-- 2.2电子围栏校验-函数..sql
--   gis_check_electric_fence                校验电子围栏冲突
--   gis_electric_fence_check_point          检测航点落入围栏
--   gis_electric_fence_check_line           检测航线穿越围栏
--   gis_electric_fence_buffer               生成电子围栏缓冲区
--   gis_electric_fence_check_point_buffer   检测航点缓冲区冲突
--   gis_electric_fence_check_line_buffer    检测航线缓冲区冲突
--
-- =============================================================================

-- =============================================
-- 函数名称gis_check_electric_fence
-- 函数功能电子围栏空间冲突校验（禁飞区/管控区试飞区互斥规则校验）
-- 函数描述1. 接收项目ID、围栏类型、坐标GeoJSON三个独立参数
--            2. 自动标准化几何数据（2D、修复、设置坐标系
--            3. 按类型执行空间冲突校验：
--               - 禁飞区1)：无需校验，直接通过
--               - 管控区2)：禁止与禁飞区1)相交/包含
--               - 试飞区3)：禁止与禁飞区1)、管控区(2)相交/包含
--            4. 支持项目专属围栏+ 公共围栏表双重校
--            5. 返回冲突详情：类型、表名、几何、提示文案
-- 函数说明依赖PostGIS空间扩展，坐标系使用WGS84(4326)
-- 参数说明
--   p_project_id    varchar     项目ID（可选），用于区分项目专属围栏表
--   p_fence_type    text        围栏类型=禁飞区，2=管控区，3=试飞区
--   p_lng_lat_alt   text        坐标GeoJSON字符串，支持Feature或直接Geometry
-- 返回值： 标准TABLE结构
--   code               integer     返回码：200成功00参数错误00空间冲突
--   table_name         text        冲突对应的表名
--   orig_fence_type    text        传入的原始围栏类型
--   conflict_fence_type text       冲突的围栏类型数字)
--   msg                text        详细提示信息（区分相包含 + 中文名称
--   new_geom           text        标准化后的新围栏几何JSON
--   conflict_geom      text        冲突围栏的几何JSON
-- 适用场景新增/编辑电子围栏前的空间合规性校验，防止区域重叠冲突
-- =============================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_check_electric_fence');

-- =============================================================================
-- 函数介绍：gis_check_electric_fence
-- 主要作用：校验新建或编辑电子围栏时，是否与已有围栏存在空间冲突或规则冲突
-- 入参说明：p_project_id 为项目ID；p_geom_json 为待校验围栏GeoJSON；p_fence_type 为围栏类型
-- 返回说明：返回状态码、提示信息以及冲突明细，供保存围栏前进行业务拦截
-- 注意事项：依赖PostGIS空间判断；校验逻辑会结合全局围栏和项目专属围栏数据
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_check_electric_fence(
  IN p_project_id varchar,      -- 入参1：项目ID（可选），用于区分项目专属围栏表
  IN p_fence_type text,         -- 入参2：围栏类型，1=禁飞区，2=管控区，3=试飞区
  IN p_lng_lat_alt text         -- 入参3：坐标GeoJSON字符串，支持Feature或直接Geometry
)
RETURNS TABLE (
  code integer,           -- 返回码：200成功00参数错误00空间冲突
  table_name text,        -- 冲突对应的表名
  orig_fence_type text,   -- 传入的原始围栏类型
  conflict_fence_type text,-- 冲突的围栏类型数字)
  msg text,               -- 详细提示信息（区分相包含 + 中文名称
  new_geom text,          -- 标准化后的新围栏几何JSON
  conflict_geom text      -- 冲突围栏的几何JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_fence_type text;          -- 处理后的围栏类型(数字)
  v_orig_fence_type text;     -- 原始传入的围栏类型数字)
  v_geojson_str text;         -- 传入的坐标GeoJSON字符串
  v_new_geom geometry;        -- 标准化处理后的几何对
  v_geojson_json jsonb;        -- lngLatAlt解析后的JSON对象，兼容Feature和直接Geometry
  v_new_geom_json text;       -- 新几何的GeoJSON格式字符串
  v_sql text;                 -- 动态执行SQL语句
  v_has_conflict boolean;     -- 是否存在冲突标记
  v_is_contains boolean;     -- 是否为包含关系标记
  v_conflict_name text;       -- 冲突围栏中文名称
  v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
  v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_check_electric_fence(%L, %L, %L);',
        p_project_id, p_fence_type, p_lng_lat_alt);

  -- 初始化冲突标记：默认无冲突
  v_has_conflict := false;

  -- ===================== 1. 解析入参 =====================
  -- 围栏类型从第二个参数直接传入，去除前后空格后参与规则判断
  v_orig_fence_type := trim(p_fence_type);
  v_fence_type := v_orig_fence_type;
  -- 坐标GeoJSON从第三个参数直接传入，兼容Feature和直接Geometry
  v_geojson_str := trim(p_lng_lat_alt);

  -- ===================== 2. 基础参数非空校验 =====================
  -- 校验围栏类型是否为空
  IF v_fence_type IS NULL OR v_fence_type = '' THEN
    code := 400;                     -- 参数错误
    table_name := '';                -- 无表名
    orig_fence_type := v_orig_fence_type; -- 原始围栏类型
    conflict_fence_type := '';       -- 无冲突类型
    msg := format('参数校验失败：围栏类型不能为空，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)); -- 错误提示
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code,msg,v_log_sql);
    new_geom := null;                -- 无几何数据
    conflict_geom := null;           -- 无冲突几何
    RETURN NEXT;  -- 返回结果
    RETURN;       -- 终止函数执行
  END IF;

  -- 校验坐标信息是否为空
  IF v_geojson_str IS NULL OR v_geojson_str = '' THEN
    code := 400;
    table_name := '';
    orig_fence_type := v_orig_fence_type;
    conflict_fence_type := '';
    msg := format('参数校验失败：坐标信息不能为空，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code,        msg,        v_log_sql
    );
    new_geom := null;
    conflict_geom := null;
    RETURN NEXT;
    RETURN;
  END IF;

  -- ===================== 3. 几何标准化处=====================
  -- 将GeoJSON字符串转为JSON对象
  -- lngLatAlt可能传Feature，也可能直接传Polygon/MultiPolygon等Geometry；这里统一兼容两种格式
  v_geojson_json := v_geojson_str::jsonb;
  IF v_geojson_json ->> 'type' = 'Feature' THEN
    -- Feature格式：几何数据位于geometry节点
    v_new_geom := ST_GeomFromGeoJSON(v_geojson_json ->> 'geometry');
  ELSE
    -- Geometry格式：整个JSON就是几何对象
    v_new_geom := ST_GeomFromGeoJSON(v_geojson_json::text);
  END IF;
  -- 强制转为2D几何（剔除高度值） + 自动修复非法几何（自相交、不闭合等）
  v_new_geom := ST_MakeValid(ST_Force2D(v_new_geom));
  -- 设置坐标系为EPSG:4326（WGS84经纬度坐标系
  v_new_geom := ST_SetSRID(v_new_geom, 4326);
  -- 将标准化处理后的几何对象转回GeoJSON字符串，用于返回
  v_new_geom_json := ST_AsGeoJSON(v_new_geom);

  -- ===================== 4. 禁飞区1) 直接校验通过 =====================
  -- 业务规则：禁飞区为最高优先级，无需检测任何空间冲突
  IF v_fence_type = '1' THEN
    code := 200;
    table_name := '';
    orig_fence_type := v_orig_fence_type;
    conflict_fence_type := '';
    msg := format('校验成功：禁飞区无需检测空间冲突，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    new_geom := v_new_geom_json;
    conflict_geom := null;
    RETURN NEXT;
    RETURN;
  END IF;

  -- ===================== 5. 试飞区3) 冲突校验 =====================
  -- 业务规则：试飞区禁止与禁飞区(1)、管控区(2)发生相交/包含关系
  IF v_fence_type = '3' THEN
    -- 拼接动态SQL：优先查询项目专属围栏表
    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
      -- 使用formatL返回表名文本I安全引用动态项目表名
      -- 项目专属表字段名fence_type，用于判断冲突围栏类型
      v_sql := format(
        'SELECT %L, fence_type, ST_AsGeoJSON(geom),
         ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
         FROM %I
         WHERE fence_type IN (''1'',''2'')
         AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))',
        'gis_electric_fence_' || trim(p_project_id),
        'gis_electric_fence_' || trim(p_project_id)
      );
    ELSE
      -- 无项目ID时，查询公共电子围栏
      -- 公共项目围栏表同样使fence_type 字段
      v_sql := 'SELECT ''gis_electric_fence'', fence_type, ST_AsGeoJSON(geom),
                ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
                FROM gis_electric_fence
                WHERE fence_type IN (''1'',''2'')
                AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))';
    END IF;

    -- 遍历冲突查询结果，逐条返回冲突信息
    FOR table_name, conflict_fence_type, conflict_geom, v_is_contains IN EXECUTE v_sql USING v_new_geom
    LOOP
      -- 标记存在空间冲突
      v_has_conflict := true;
      code := 200;                              -- 空间冲突属于正常校验结果
      orig_fence_type := v_orig_fence_type;      -- 原始围栏类型

      -- 围栏类型数字映射为中文名
      CASE conflict_fence_type
        WHEN '1' THEN v_conflict_name := '禁飞区';
        WHEN '2' THEN v_conflict_name := '管控区';
        ELSE v_conflict_name := '未知类型围栏';
      END CASE;

      -- 根据空间关系（包相交）返回不同提示文案
      IF v_is_contains THEN
        msg := format('试飞区与%s发生包含冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      ELSE
        msg := format('试飞区与%s发生相交冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      END IF;
      new_geom := v_new_geom_json;  -- 返回标准化后的新几何
      RETURN NEXT;                  -- 返回当前冲突
    END LOOP;

    -- 遍历公共围栏bo_electric_fence，继续校验冲突
    v_sql := 'SELECT ''bo_electric_fence'', fence_type, ST_AsGeoJSON(geom),
              ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
              FROM bo_electric_fence
              WHERE fence_type IN (''1'',''2'') AND project_id = $2
              AND del_flag = false AND status = ''1''
              AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))';
    FOR table_name, conflict_fence_type, conflict_geom, v_is_contains IN EXECUTE v_sql USING v_new_geom, p_project_id
    LOOP
      v_has_conflict := true;
      code := 200;
      orig_fence_type := v_orig_fence_type;

      -- 冲突类型转中
      CASE conflict_fence_type
        WHEN '1' THEN v_conflict_name := '禁飞区';
        WHEN '2' THEN v_conflict_name := '管控区';
        ELSE v_conflict_name := '未知类型围栏';
      END CASE;

      -- 返回冲突提示信息
      IF v_is_contains THEN
        msg := format('试飞区与%s发生包含冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      ELSE
        msg := format('试飞区与%s发生相交冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      END IF;
      new_geom := v_new_geom_json;
      RETURN NEXT;
    END LOOP;

  -- ===================== 6. 管控区2) 冲突校验 =====================
  -- 业务规则：管控区禁止与禁飞区(1)发生相交/包含关系
  ELSIF v_fence_type = '2' THEN
    -- 拼接动态SQL：优先查询项目专属围栏表
    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
      -- 项目专属表名动态生成，必须使用%I作为标识符引用；表内围栏类型字段fence_type
      v_sql := format(
        'SELECT %L, fence_type, ST_AsGeoJSON(geom),
         ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
         FROM %I
         WHERE fence_type = ''1''
         AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))',
        'gis_electric_fence_' || trim(p_project_id),
        'gis_electric_fence_' || trim(p_project_id)
      );
    ELSE
      -- 无项目ID时查询公共围栏表
      v_sql := 'SELECT ''gis_electric_fence'', fence_type, ST_AsGeoJSON(geom),
                ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
                FROM gis_electric_fence
                WHERE fence_type = ''1''
                AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))';
    END IF;

    -- 遍历项目围栏表冲突数据
    FOR table_name, conflict_fence_type, conflict_geom, v_is_contains IN EXECUTE v_sql USING v_new_geom
    LOOP
      v_has_conflict := true;
      code := 200;
      orig_fence_type := v_orig_fence_type;
      v_conflict_name := '禁飞区'; -- 管控区只校验禁飞区，固定名称

      -- 根据空间关系返回提示
      IF v_is_contains THEN
        msg := format('管控区与%s发生包含冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      ELSE
        msg := format('管控区与%s发生相交冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      END IF;
      new_geom := v_new_geom_json;
      RETURN NEXT;
    END LOOP;

    -- 校验公共bo_electric_fence 中的禁飞区冲突
    v_sql := 'SELECT ''bo_electric_fence'', fence_type, ST_AsGeoJSON(geom),
              ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
              FROM bo_electric_fence
              WHERE fence_type = ''1'' AND project_id = $2
              AND del_flag = false AND status = ''1''
              AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))';
    FOR table_name, conflict_fence_type, conflict_geom, v_is_contains IN EXECUTE v_sql USING v_new_geom, p_project_id
    LOOP
      v_has_conflict := true;
      code := 200;
      orig_fence_type := v_orig_fence_type;
      v_conflict_name := '禁飞区';

      -- 返回冲突提示
      IF v_is_contains THEN
        msg := format('管控区与%s发生包含冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      ELSE
        msg := format('管控区与%s发生相交冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      END IF;
      new_geom := v_new_geom_json;
      RETURN NEXT;
    END LOOP;

  -- ===================== 7. 未知围栏类型 =====================
  -- 传入的围栏类型不/2/3，返回参数错
  ELSE
    code := 400;
    table_name := '';
    orig_fence_type := v_orig_fence_type;
    conflict_fence_type := '';
    msg := format('参数校验失败：不支持的围栏类型，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (
        code,
        msg,
        v_log_sql
    );
    new_geom := null;
    conflict_geom := null;
    RETURN NEXT;
    RETURN;
  END IF;

  -- ===================== 8. 无冲突返回成功=====================
  -- 所有校验规则执行完成，未发现任何空间冲突
  IF NOT v_has_conflict THEN
    code := 200;
    table_name := '';
    orig_fence_type := v_orig_fence_type;
    conflict_fence_type := '';
    msg := format('校验成功：未检测到相交、包含空间冲突，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    new_geom := v_new_geom_json;
    conflict_geom := null;
    RETURN NEXT;
  END IF;

-- ===================== 全局异常捕获 =====================
-- 捕获函数执行过程中所有未知异常，返回标准化错误信息
EXCEPTION WHEN OTHERS THEN
  code := 500;
  table_name := '';
  orig_fence_type := v_orig_fence_type;
  conflict_fence_type := '';
  msg := format('系统异常：%s | 错误码：%s，执行时间 %s 秒',
    SQLERRM, SQLSTATE, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
  INSERT INTO public.gis_error_log(code, msg, sqlstring)
  VALUES (
      code,
      msg,
      v_log_sql
  );
  new_geom := null;
  conflict_geom := null;
  RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_check_electric_fence(varchar, text, text) IS '校验电子围栏冲突';


-- =============================================================================
-- 电子围栏线判断、点判断、缓冲、点缓冲判断、线缓冲判断
-- =============================================================================

-- ====================================================================
-- 函数名称gis_electric_fence_check_point
-- 函数功能无人机定位点 3D 电子围栏碰撞检测（无缓冲，纯原始围栏判断）
-- 函数描述1. 传入 项目ID + 点的GeoJSON（支持Feature和Point格式
--            2. 高度=0（默认）：仅执行2D平面包含判断
--            3. 禁飞区和管控区统一按同一套平面+高度逻辑校验
--            4. 项目ID不为空时查询 gis_electric_fence_{project_id} 表（注意表不存在的情况）
--            5. 项目ID为空时查bo_electric_fence
--            6. 只查询禁飞区、启用状态、未删除的有效围栏
--            7. 返回标准格式结果集，与航线检测函数完全通用，前端可直接渲染
-- 函数说明依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)
-- 参数说明
--   p_project_id    text            输入参数：项目ID（可选），为空则查询公共
--   p_point_geojson text            输入参数：点的GeoJSON字符串（必填，支持Feature和Point格式
-- 返回值： 标准TABLE结构，与航线检测函数完全一
--   code      integer    状态码00=执行成功 400=参数错误 500=执行异常
--   msg       varchar    状态描述信息
--   geom      geometry   本次校验的输入点几何
--   electric_id varchar(32) 命中的围栏ID
--   electric_geom geometry  命中的围栏数据库原始几何
--   electric_geojson json   命中的围栏GeoJSON
-- 函数注意
--   1. bo_electric_fence 必须存在，且包含字段：id, geom, height, del_flag, fence_type, status
--   2. 2D判断使用 ST_Covers，3D判断结合平面+高度区间校验，边界点算命中
--   3. 围栏高度为空或0时按无限高度处理，仅判断平面是否在围栏内
-- 适用场景无人机实时定位是否闯入禁飞区/管控区
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_check_point');

-- 创建函数
-- =============================================================================
-- 函数介绍：gis_electric_fence_check_point
-- 主要作用：判断单个航点是否落入启用中的禁飞区、管控区等电子围栏范围栏
-- 入参说明：p_point_json 为航点Point/PointZ GeoJSON；p_project_id 用于限定项目围栏范围栏
-- 返回说明：返回命中状态、围栏类型、围栏名称和提示信息，供航点合法性校验使用
-- 注意事项：点位坐标默认WGS84；高度规则需结合围栏数据中的高度字段判断
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_point(
    p_project_id text,
    p_point_geojson text
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    table_name varchar,
    geom geometry,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_point geometry;          -- 存储生成的空间点几何对象
    v_geojson_json jsonb;      -- 解析后的GeoJSON对象
    v_z double precision;      -- 高度
    v_table_name text;         -- 动态表名
    v_sql text;                -- 动态SQL语句
    v_table_exists boolean;    -- 表是否存
    v_found boolean;           -- 是否找到匹配的围栏
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_check_point(%L, %L);',
        p_project_id, p_point_geojson);

    -- =============================================
    -- 00 参数错误】第一步：校验点GeoJSON是否为空
    -- =============================================
    IF p_point_geojson IS NULL OR p_point_geojson = '' THEN
        code := 400;
        msg := format('点参数为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'p_outer'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    -- =============================================
    -- 解析GeoJSON字符串
    -- =============================================
    BEGIN
        v_geojson_json := p_point_geojson::jsonb;
    EXCEPTION
        WHEN OTHERS THEN
            code := 400;
            msg := format('点的GeoJSON格式错误，执行时间 %s 秒',
                    ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                code,
                msg,
                v_log_sql
            );

            RETURN QUERY SELECT
                code, msg::varchar,
                false, 'p_outer'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
            RETURN;
    END;

    -- =============================================
    -- 从GeoJSON中提取点几何和高
    -- =============================================
    BEGIN
        IF jsonb_typeof(v_geojson_json) = 'array' THEN
            -- Support coordinate array input: [lng, lat, alt] or [[lng, lat, alt], ...].
            IF jsonb_array_length(v_geojson_json) = 0 THEN
                RAISE EXCEPTION 'Point coordinate array cannot be empty';
            END IF;

            IF jsonb_typeof(v_geojson_json -> 0) = 'array' THEN
                IF EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(v_geojson_json) AS p(pt)
                    WHERE jsonb_typeof(p.pt) <> 'array'
                       OR jsonb_array_length(p.pt) < 2
                ) THEN
                    RAISE EXCEPTION 'Each point coordinate requires at least lng and lat';
                END IF;

                SELECT ST_Multi(ST_Collect(
                    ST_MakePoint(
                        (p.pt ->> 0)::double precision,
                        (p.pt ->> 1)::double precision,
                        COALESCE((p.pt ->> 2)::double precision, 0)
                    )
                    ORDER BY p.ord
                ))
                INTO v_point
                FROM jsonb_array_elements(v_geojson_json) WITH ORDINALITY AS p(pt, ord);
                v_z := 0;
            ELSE
                IF jsonb_array_length(v_geojson_json) < 2 THEN
                    RAISE EXCEPTION 'Point coordinate array requires at least lng and lat';
                END IF;

                v_point := ST_MakePoint(
                    (v_geojson_json ->> 0)::double precision,
                    (v_geojson_json ->> 1)::double precision,
                    COALESCE((v_geojson_json ->> 2)::double precision, 0)
                );
                v_z := COALESCE((v_geojson_json ->> 2)::double precision, 0);
            END IF;
        ELSIF v_geojson_json ->> 'type' = 'FeatureCollection' THEN
            IF jsonb_typeof(v_geojson_json -> 'features') <> 'array'
               OR jsonb_array_length(v_geojson_json -> 'features') = 0 THEN
                RAISE EXCEPTION 'FeatureCollection requires non-empty features';
            END IF;

            SELECT ST_Multi(ST_Collect(
                ST_GeomFromGeoJSON(f.feature ->> 'geometry')
                ORDER BY f.ord
            ))
            INTO v_point
            FROM jsonb_array_elements(v_geojson_json -> 'features') WITH ORDINALITY AS f(feature, ord)
            WHERE f.feature -> 'geometry' IS NOT NULL;
            v_z := 0;
        ELSIF v_geojson_json ->> 'type' = 'Feature' THEN
            -- Feature格式
            v_point := ST_GeomFromGeoJSON(v_geojson_json ->> 'geometry');
            -- 尝试从Feature的properties或几何的Z坐标获取高度
            v_z := COALESCE(
                (v_geojson_json -> 'properties' ->> 'z')::double precision,
                (v_geojson_json -> 'properties' ->> 'height')::double precision,
                CASE WHEN ST_GeometryType(v_point) = 'ST_Point' THEN ST_Z(v_point) END,
                0
            );
        ELSE
            -- 直接Geometry格式
            v_point := ST_GeomFromGeoJSON(v_geojson_json::text);
            v_z := COALESCE(
                CASE WHEN ST_GeometryType(v_point) = 'ST_Point' THEN ST_Z(v_point) END,
                0
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            code := 400;
            msg := format('点的GeoJSON解析失败，执行时间 %s 秒',
                    ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                code,
                msg,
                v_log_sql
            );

            RETURN QUERY SELECT
                code, msg::varchar,
                false, 'p_outer'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
            RETURN;
    END;

    -- =============================================
    -- 校验点类型
    -- =============================================
    IF ST_GeometryType(v_point) NOT IN ('ST_Point', 'ST_MultiPoint') THEN
        code := 400;
        msg := format('GeoJSON必须是Point类型，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'p_outer'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    -- =============================================
    -- 标准化几何（设置坐标系），保留输入高度Z
    -- =============================================
    IF ST_CoordDim(v_point) < 3 AND v_z > 0 THEN
        v_point := ST_Force3DZ(v_point, v_z);
    END IF;
    v_point := ST_SetSRID(v_point, 4326);

    -- =============================================
    -- 构建动态表名和SQL
    -- =============================================
    v_found := false;

    -- 构建最终的查询SQL
    v_sql := '';

    IF p_project_id IS NOT NULL AND p_project_id <> '' THEN
        -- 有项目ID，先检查项目表是否存在
        v_table_name := 'gis_electric_fence_' || p_project_id;

        -- 检查表是否存在
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
            AND t.table_name = v_table_name
        ) INTO v_table_exists;

        IF v_table_exists THEN
            -- 项目表存在，使用UNION ALL连接项目表和公共
            v_sql := format('
                WITH input_points AS (
                    SELECT d.path, d.geom AS geom
                    FROM ST_Dump($1) AS d
                )
                SELECT
                    200 AS code,
                    CASE
                        WHEN hit.id IS NULL THEN format(''当前位置不在禁飞区/管控区内，check_type=p_outer(点在外部)，执行时间 %%s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))
                        ELSE format(''当前位置在%%s内，check_type=p_inner(点在内部)，执行时间 %%s 秒'', CASE hit.fence_type WHEN ''1'' THEN ''禁飞区'' WHEN ''2'' THEN ''管控区'' ELSE ''电子围栏'' END, ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))
                    END::varchar AS msg,
                    (hit.id IS NOT NULL) AS ischeck,
                    CASE WHEN hit.id IS NULL THEN ''p_outer'' ELSE ''p_inner'' END::varchar AS check_type,
                    COALESCE(hit.table_name, '''')::varchar AS table_name,
                    ip.geom,
                    hit.id::varchar(32) AS electric_id,
                    hit.fence_type::varchar AS fence_type,
                    hit.geom AS electric_geom,
                    hit.geom_geojson AS electric_geojson
                FROM input_points ip
                LEFT JOIN LATERAL (
                    SELECT h.table_name, h.id, h.fence_type, h.geom, h.geom_geojson
                    FROM (
                        SELECT
                            %L::varchar AS table_name,
                            f.id::varchar(32) AS id,
                            f.fence_type::varchar AS fence_type,
                            f.geom AS geom,
                            ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson,
                            1 AS priority
                        FROM %I f
                        WHERE f.fence_type IN (''1'',''2'')
                          AND ST_Intersects(ST_SetSRID(f.geom, 4326), ip.geom)
                          AND (
                              COALESCE(ST_Z(ip.geom), 0) = 0
                              OR COALESCE(f.height, 0) = 0
                              OR
                              (COALESCE(ST_Z(ip.geom), 0) > 0 AND COALESCE(ST_Z(ip.geom), 0) <= f.height)
                          )
                        UNION ALL
                        SELECT
                            ''bo_electric_fence''::varchar AS table_name,
                            f.id::varchar(32) AS id,
                            f.fence_type::varchar AS fence_type,
                            f.geom AS geom,
                            ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson,
                            2 AS priority
                        FROM bo_electric_fence f
                        WHERE f.fence_type IN (''1'',''2'')
                          AND f.status = ''1''
                          AND f.del_flag = false
                          AND f.project_id::text = btrim($2)
                          AND ST_Intersects(ST_SetSRID(f.geom, 4326), ip.geom)
                          AND (
                              COALESCE(ST_Z(ip.geom), 0) = 0
                              OR COALESCE(f.height, 0) = 0
                              OR
                              (COALESCE(ST_Z(ip.geom), 0) > 0 AND COALESCE(ST_Z(ip.geom), 0) <= f.height)
                          )
                    ) h
                    ORDER BY CASE h.fence_type WHEN ''1'' THEN 1 WHEN ''2'' THEN 2 ELSE 9 END,
                             h.priority,
                             h.id
                    LIMIT 1
                ) hit ON true
                ORDER BY ip.path',
                v_table_name,
                v_table_name
            );
        ELSE
            -- 项目表不存在，只查询公共
            v_sql := '
                WITH input_points AS (
                    SELECT d.path, d.geom AS geom
                    FROM ST_Dump($1) AS d
                )
                SELECT
                    200 AS code,
                    CASE
                        WHEN hit.id IS NULL THEN format(''当前位置不在禁飞区/管控区内，check_type=p_outer(点在外部)，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))
                        ELSE format(''当前位置在%s内，check_type=p_inner(点在内部)，执行时间 %s 秒'', CASE hit.fence_type WHEN ''1'' THEN ''禁飞区'' WHEN ''2'' THEN ''管控区'' ELSE ''电子围栏'' END, ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))
                    END::varchar AS msg,
                    (hit.id IS NOT NULL) AS ischeck,
                    CASE WHEN hit.id IS NULL THEN ''p_outer'' ELSE ''p_inner'' END::varchar AS check_type,
                    COALESCE(hit.table_name, '''')::varchar AS table_name,
                    ip.geom,
                    hit.id::varchar(32) AS electric_id,
                    hit.fence_type::varchar AS fence_type,
                    hit.geom AS electric_geom,
                    hit.geom_geojson AS electric_geojson
                FROM input_points ip
                LEFT JOIN LATERAL (
                    SELECT
                        ''bo_electric_fence''::varchar AS table_name,
                        f.id::varchar(32) AS id,
                        f.fence_type::varchar AS fence_type,
                        f.geom AS geom,
                        ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
                    FROM bo_electric_fence f
                    WHERE f.fence_type IN (''1'',''2'')
                      AND f.status = ''1''
                      AND f.del_flag = false
                      AND f.project_id::text = btrim($2)
                      AND ST_Intersects(ST_SetSRID(f.geom, 4326), ip.geom)
                      AND (
                          COALESCE(ST_Z(ip.geom), 0) = 0
                          OR COALESCE(f.height, 0) = 0
                          OR
                          (COALESCE(ST_Z(ip.geom), 0) > 0 AND COALESCE(ST_Z(ip.geom), 0) <= f.height)
                      )
                    ORDER BY CASE f.fence_type WHEN ''1'' THEN 1 WHEN ''2'' THEN 2 ELSE 9 END,
                             f.id
                    LIMIT 1
                ) hit ON true
                ORDER BY ip.path';
        END IF;

        -- 执行统一的查
        RETURN QUERY EXECUTE v_sql USING v_point, p_project_id, v_start_time;

        -- 检查是否找到结果
        IF FOUND THEN
            v_found := true;
        END IF;
    ELSE
        -- 没有项目ID，只查询公共
        RETURN QUERY
        SELECT
            200 AS code,
            CASE
                WHEN hit.id IS NULL THEN format('当前位置不在禁飞区/管控区内，check_type=p_outer(点在外部)，执行时间 %s 秒',
                    ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
                ELSE format('当前位置在%s内，check_type=p_inner(点在内部)，执行时间 %s 秒',
                    CASE hit.fence_type WHEN '1' THEN '禁飞区' WHEN '2' THEN '管控区' ELSE '电子围栏' END,
                    ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
            END::varchar AS msg,
            (hit.id IS NOT NULL) AS ischeck,
            CASE WHEN hit.id IS NULL THEN 'p_outer' ELSE 'p_inner' END::varchar AS check_type,
            COALESCE(hit.table_name, '')::varchar AS table_name,
            ip.geom,
            hit.id::varchar(32) AS electric_id,
            hit.fence_type::varchar AS fence_type,
            hit.geom AS electric_geom,
            hit.geom_geojson AS electric_geojson
        FROM (
            SELECT d.path, d.geom AS geom
            FROM ST_Dump(v_point) AS d
        ) ip
        LEFT JOIN LATERAL (
            SELECT
                'bo_electric_fence'::varchar AS table_name,
                f.id::varchar(32) AS id,
                f.fence_type::varchar AS fence_type,
                f.geom AS geom,
                ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
            FROM bo_electric_fence f
            WHERE f.fence_type IN ('1','2') -- 围栏类型：禁飞区/管控区
              AND f.status = '1'            -- 状态：启用
              AND f.del_flag = false        -- 未删
              AND ST_Intersects(ST_SetSRID(f.geom, 4326), ip.geom)
              AND (
                  COALESCE(ST_Z(ip.geom), 0) = 0
                  OR COALESCE(f.height, 0) = 0
                  OR
                  (COALESCE(ST_Z(ip.geom), 0) > 0 AND COALESCE(ST_Z(ip.geom), 0) <= f.height)
              )
            LIMIT 1
        ) hit ON true
        ORDER BY ip.path;

        -- 检查是否找到结果
        IF FOUND THEN
            v_found := true;
        END IF;
    END IF;

    -- =============================================
    -- 00 成功】未检测到闯入任何禁飞区/管控区
    -- =============================================
    IF NOT v_found THEN
        RETURN QUERY SELECT
            200, format('当前位置不在禁飞区/管控区内，check_type=p_outer(点在外部)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false, 'p_outer'::varchar, ''::varchar, v_point, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
        RETURN;
    END IF;

-- =============================================
-- 00 服务异常】系数据空间函数异常
-- =============================================
EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'p_outer'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_point(text, text) IS '检测航点落入围栏';

-- ====================================================================================
-- 函数名称gis_electric_fence_check_line
-- 函数功能无人机航线/轨迹电子围栏平面穿越检测
-- 函数描述1. 传入航线 GeoJSON（LineString/LineStringZ/MultiLineString）
--            2. 禁飞区和管控区统一按二维平面相交规则判断
--            3. 不再根据 height 字段切换三维相交逻辑，避免两类围栏判断不一致
--            4. 只查询未删除、有效状态的围栏
--            5. 返回标准格式结果集，前端可直接渲
-- 函数说明依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)
-- 参数说明
--   p_line_geojson     text           输入参数：线轨迹/线段的GeoJSON字符串（必填
-- 返回值： 标准TABLE结构，包含状态码、提示信息、输入线几何、命中围栏信息
--   code      integer    状态码00=执行成功 400=参数错误/未查询到数据 500=执行异常
--   msg       varchar    状态描述信息
--   geom      geometry   本次校验的输入线几何
--   electric_id varchar(32) 命中的围栏ID
--   electric_geom geometry  命中的围栏数据库原始几何
--   electric_geojson json   命中的围栏GeoJSON
-- 适用场景无人机航线闯入禁飞区/管控区实时检测
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_check_line');

-- 创建函数
-- =============================================================================
-- 函数介绍：gis_electric_fence_check_line
-- 主要作用：检测输入航线在二维平面上是否直接穿越或接触启用中的电子围栏区域
-- 入参说明：p_line_json 为航线LineString/LineStringZ GeoJSON、Feature或坐标数组
-- 返回说明：返回是否冲突、命中围栏属性和相交结果，供航线提交前快速校验
-- 注意事项：本函数不额外扩航线缓冲，也不按height做三维判断；如需安全距离判断请使用带buffer的函数
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_line(
    p_project_id text,
    p_line_geojson text
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    table_name varchar,
    geom geometry,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_line geometry;
    v_line_json jsonb;
    v_fence_3d geometry;
    v_table_name text;
    v_sql text;
    v_table_exists boolean;
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_check_line(%L, %L);',
        p_project_id, p_line_geojson);

    -- 1. 参数校验
    IF p_line_geojson IS NULL OR p_line_geojson = '' THEN
        code := 400;
        msg := format('航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'ln_outside'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    -- 2. 解析航线输入，并设置坐标系WGS84(4326)
    BEGIN
        v_line_json := p_line_geojson::jsonb;

        IF jsonb_typeof(v_line_json) = 'array' THEN
            -- 支持单线 [[lng,lat,alt], ...] 和多线 [[[lng,lat,alt], ...], ...].
            IF jsonb_array_length(v_line_json) < 2 THEN
                RAISE EXCEPTION 'Line coordinate array requires at least two points';
            END IF;

            IF jsonb_typeof(v_line_json -> 0) = 'array'
               AND jsonb_array_length(v_line_json -> 0) > 0
               AND jsonb_typeof((v_line_json -> 0) -> 0) = 'array' THEN
                v_line := ST_GeomFromGeoJSON(
                    jsonb_build_object(
                        'type', 'MultiLineString',
                        'coordinates', v_line_json
                    )::text
                );
            ELSE
                v_line := ST_GeomFromGeoJSON(
                    jsonb_build_object(
                        'type', 'LineString',
                        'coordinates', v_line_json
                    )::text
                );
            END IF;
        ELSIF v_line_json ->> 'type' = 'FeatureCollection' THEN
            IF jsonb_typeof(v_line_json -> 'features') <> 'array'
               OR jsonb_array_length(v_line_json -> 'features') = 0 THEN
                RAISE EXCEPTION 'FeatureCollection requires non-empty features';
            END IF;

            SELECT ST_Multi(ST_Collect(
                ST_GeomFromGeoJSON(f.feature ->> 'geometry')
                ORDER BY f.ord
            ))
            INTO v_line
            FROM jsonb_array_elements(v_line_json -> 'features') WITH ORDINALITY AS f(feature, ord)
            WHERE f.feature -> 'geometry' IS NOT NULL;
        ELSIF v_line_json ->> 'type' = 'Feature' THEN
            -- Feature格式：几何数据位于geometry节点。
            v_line := ST_GeomFromGeoJSON(v_line_json ->> 'geometry');
        ELSE
            -- Geometry格式：LineString/MultiLineString。
            v_line := ST_GeomFromGeoJSON(v_line_json::text);
        END IF;

        v_line := ST_SetSRID(v_line, 4326);
    EXCEPTION
        WHEN OTHERS THEN
            code := 400;
            msg := format('航线GeoJSON/坐标数组解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                code,
                msg,
                v_log_sql
            );

            RETURN QUERY SELECT
                code, msg::varchar,
                false, 'ln_outside'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
            RETURN;
    END;

    -- 3. 校验输入必须是线要素(LineString/MultiLineString)
    IF ST_GeometryType(v_line) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        code := 400;
        msg := format('输入几何体必须是线类型(LineString)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'ln_outside'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    -- 4. 航线二维平面相交校验：禁飞区和管控区统一使用同一套逻辑。
    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
        v_table_name := 'gis_electric_fence_' || trim(p_project_id);

        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_table_name
        ) INTO v_table_exists;

        IF v_table_exists THEN
            v_sql := format('
                WITH input_lines AS (
                    SELECT d.path, d.geom AS geom
                    FROM ST_Dump($1) AS d
                )
                SELECT
                    200 AS code,
                    CASE
                        WHEN hit.id IS NULL THEN format(''航线未闯入任何电子围栏，check_type=%%s，执行时间 %%s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $2)::numeric, 3))
                        ELSE format(''检测到航线闯入电子围栏，check_type=%%s，执行时间 %%s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $2)::numeric, 3))
                    END::varchar AS msg,
                    (hit.id IS NOT NULL) AS ischeck,
                ct.check_type,
                COALESCE(hit.table_name, '''')::varchar AS table_name,
                il.geom,
                    hit.id::varchar(32) AS electric_id,
                    hit.fence_type::varchar AS fence_type,
                    hit.geom AS electric_geom,
                    hit.geom_geojson AS electric_geojson
                FROM input_lines il
                LEFT JOIN LATERAL (
                    SELECT h.table_name, h.id, h.fence_type, h.geom, h.geom_geojson
                    FROM (
                        SELECT
                            %L::varchar AS table_name,
                            f.id::varchar(32) AS id,
                            f.fence_type::varchar AS fence_type,
                            f.geom AS geom,
                            ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson,
                            1 AS priority
                        FROM %I f
                        WHERE f.fence_type IN (''1'',''2'')
                          AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D(il.geom))
                        UNION ALL
                        SELECT
                            ''bo_electric_fence''::varchar AS table_name,
                            f.id::varchar(32) AS id,
                            f.fence_type::varchar AS fence_type,
                            f.geom AS geom,
                            ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson,
                            2 AS priority
                        FROM bo_electric_fence f
                        WHERE f.fence_type IN (''1'',''2'')
                          AND f.del_flag = false
                          AND f.status = ''1''
                          AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D(il.geom))
                    ) h
                    ORDER BY h.priority, h.id
                    LIMIT 1
                ) hit ON true
                CROSS JOIN LATERAL (
                    SELECT
                        x.check_type,
                        CASE x.check_type
                            WHEN ''ln_outside'' THEN ''ln_outside(线与面：相离)''
                            WHEN ''ln_within'' THEN ''ln_within(线与面：包含于)''
                            WHEN ''ln_enters'' THEN ''ln_enters(线与面：穿入/穿出)''
                            WHEN ''ln_overlaps'' THEN ''ln_overlaps(线与面：重叠)''
                            ELSE ''ln_crosses(线与面：交叉)''
                        END::varchar AS check_type_msg
                    FROM (
                        SELECT CASE
                            WHEN hit.id IS NULL THEN ''ln_outside''
                            WHEN ST_CoveredBy(ST_Force2D(il.geom), ST_Boundary(ST_SetSRID(hit.geom, 4326))) THEN ''ln_overlaps''
                            WHEN ST_CoveredBy(ST_Force2D(il.geom), ST_SetSRID(hit.geom, 4326)) THEN ''ln_within''
                            WHEN ST_Covers(ST_SetSRID(hit.geom, 4326), ST_StartPoint(ST_Force2D(il.geom))) <> ST_Covers(ST_SetSRID(hit.geom, 4326), ST_EndPoint(ST_Force2D(il.geom))) THEN ''ln_enters''
                            ELSE ''ln_crosses''
                        END::varchar AS check_type
                    ) x
                ) ct
                ORDER BY il.path',
                v_table_name,
                v_table_name
            );
        ELSE
            v_sql := '
                WITH input_lines AS (
                    SELECT d.path, d.geom AS geom
                    FROM ST_Dump($1) AS d
                )
                SELECT
                    200 AS code,
                    CASE
                        WHEN hit.id IS NULL THEN format(''航线未闯入任何电子围栏，check_type=%s，执行时间 %s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $2)::numeric, 3))
                        ELSE format(''检测到航线闯入电子围栏，check_type=%s，执行时间 %s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $2)::numeric, 3))
                    END::varchar AS msg,
                    (hit.id IS NOT NULL) AS ischeck,
                ct.check_type,
                COALESCE(hit.table_name, '''')::varchar AS table_name,
                il.geom,
                    hit.id::varchar(32) AS electric_id,
                    hit.fence_type::varchar AS fence_type,
                    hit.geom AS electric_geom,
                    hit.geom_geojson AS electric_geojson
                FROM input_lines il
                LEFT JOIN LATERAL (
                    SELECT
                        ''bo_electric_fence''::varchar AS table_name,
                        f.id::varchar(32) AS id,
                        f.fence_type::varchar AS fence_type,
                        f.geom AS geom,
                        ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
                    FROM bo_electric_fence f
                    WHERE f.fence_type IN (''1'',''2'')
                      AND f.del_flag = false
                      AND f.status = ''1''
                      AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D(il.geom))
                    ORDER BY f.id
                    LIMIT 1
                ) hit ON true
                CROSS JOIN LATERAL (
                    SELECT
                        x.check_type,
                        CASE x.check_type
                            WHEN ''ln_outside'' THEN ''ln_outside(线与面：相离)''
                            WHEN ''ln_within'' THEN ''ln_within(线与面：包含于)''
                            WHEN ''ln_enters'' THEN ''ln_enters(线与面：穿入/穿出)''
                            WHEN ''ln_overlaps'' THEN ''ln_overlaps(线与面：重叠)''
                            ELSE ''ln_crosses(线与面：交叉)''
                        END::varchar AS check_type_msg
                    FROM (
                        SELECT CASE
                            WHEN hit.id IS NULL THEN ''ln_outside''
                            WHEN ST_CoveredBy(ST_Force2D(il.geom), ST_Boundary(ST_SetSRID(hit.geom, 4326))) THEN ''ln_overlaps''
                            WHEN ST_CoveredBy(ST_Force2D(il.geom), ST_SetSRID(hit.geom, 4326)) THEN ''ln_within''
                            WHEN ST_Covers(ST_SetSRID(hit.geom, 4326), ST_StartPoint(ST_Force2D(il.geom))) <> ST_Covers(ST_SetSRID(hit.geom, 4326), ST_EndPoint(ST_Force2D(il.geom))) THEN ''ln_enters''
                            ELSE ''ln_crosses''
                        END::varchar AS check_type
                    ) x
                ) ct
                ORDER BY il.path';
        END IF;
    ELSE
        v_sql := '
            WITH input_lines AS (
                SELECT d.path, d.geom AS geom
                FROM ST_Dump($1) AS d
            )
            SELECT
                200 AS code,
                CASE
                    WHEN hit.id IS NULL THEN format(''航线未闯入任何电子围栏，check_type=%s，执行时间 %s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $2)::numeric, 3))
                    ELSE format(''检测到航线闯入电子围栏，check_type=%s，执行时间 %s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $2)::numeric, 3))
                END::varchar AS msg,
                (hit.id IS NOT NULL) AS ischeck,
                ct.check_type,
                COALESCE(hit.table_name, '''')::varchar AS table_name,
                il.geom,
                hit.id::varchar(32) AS electric_id,
                hit.fence_type::varchar AS fence_type,
                hit.geom AS electric_geom,
                hit.geom_geojson AS electric_geojson
            FROM input_lines il
            LEFT JOIN LATERAL (
                SELECT
                    ''bo_electric_fence''::varchar AS table_name,
                    f.id::varchar(32) AS id,
                    f.fence_type::varchar AS fence_type,
                    f.geom AS geom,
                    ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
                FROM bo_electric_fence f
                WHERE f.fence_type IN (''1'',''2'')
                  AND f.del_flag = false
                  AND f.status = ''1''
                  AND ST_Intersects(ST_SetSRID(f.geom, 4326), ST_Force2D(il.geom))
                ORDER BY f.id
                LIMIT 1
            ) hit ON true
            CROSS JOIN LATERAL (
                SELECT
                    x.check_type,
                    CASE x.check_type
                        WHEN ''ln_outside'' THEN ''ln_outside(线与面：相离)''
                        WHEN ''ln_within'' THEN ''ln_within(线与面：包含于)''
                        WHEN ''ln_enters'' THEN ''ln_enters(线与面：穿入/穿出)''
                        WHEN ''ln_overlaps'' THEN ''ln_overlaps(线与面：重叠)''
                        ELSE ''ln_crosses(线与面：交叉)''
                    END::varchar AS check_type_msg
                FROM (
                    SELECT CASE
                        WHEN hit.id IS NULL THEN ''ln_outside''
                        WHEN ST_CoveredBy(ST_Force2D(il.geom), ST_Boundary(ST_SetSRID(hit.geom, 4326))) THEN ''ln_overlaps''
                        WHEN ST_CoveredBy(ST_Force2D(il.geom), ST_SetSRID(hit.geom, 4326)) THEN ''ln_within''
                        WHEN ST_Covers(ST_SetSRID(hit.geom, 4326), ST_StartPoint(ST_Force2D(il.geom))) <> ST_Covers(ST_SetSRID(hit.geom, 4326), ST_EndPoint(ST_Force2D(il.geom))) THEN ''ln_enters''
                        ELSE ''ln_crosses''
                    END::varchar AS check_type
                ) x
            ) ct
            ORDER BY il.path';
    END IF;

    RETURN QUERY EXECUTE v_sql USING v_line, v_start_time;

    -- 5. 无碰撞时返回空结果状00
    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200, format('航线未闯入任何电子围栏，check_type=ln_outside(线与面：相离)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false, 'ln_outside'::varchar, ''::varchar, v_line, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
    END IF;

-- 异常捕获
EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'ln_outside'::varchar, ''::varchar, NULL::geometry, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_line(text, text) IS '检测航线穿越围栏';


-- ====================================================================================
-- 函数名称gis_electric_fence_buffer
-- 函数功能根据电子围栏ID和缓冲半径，计算围栏2D缓冲面、构D立体几何体，并返回GeoJSON格式数据
-- 函数描述1. 校验入参围栏ID是否为空
--            2. 从电子围栏表查询有效围栏数据（未删除
--            3. 基于WGS84(4326)坐标系计算指定半径的2D平面缓冲突
--            4. 基于2D缓冲面生成底部Z=0、顶部Z=围栏高度D立体几何
--            5. 统一返回标准状态码+几何数据的GeoJSON
-- 函数说明依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)，平面缓冲使用墨卡托(3857)计算
-- 参数说明
--   p_project_id   text          输入参数：项目ID（可选）
--   p_fence_id     varchar(32)   输入参数：电子围栏唯一ID（可选，为空返回全部）
--   p_buffer_radius double precision 输入参数：缓冲半径（单位：米），0则不做缓冲，直接使用原始围栏
-- 返回值： 标准TABLE结构，包含状态码、提示信息、围栏ID、各类几何GeoJSON
--   code      integer    状态码00=执行成功 400=参数错误/未查询到数据 500=执行异常
-- 200：执行成功，返回完整几何数据
-- 400：参数为/ 无有效围栏数据（业务异常
-- 500：SQL 执行异常、表不存在、字段错误等（系统异常）
--   msg       varchar    状态描述信息
-- 返回策略
--   code=200 表示函数正常完成功
--   code=400 表示输入参数非法
--   code=500 表示执行过程中出现异常
--   msg 中包含执行时间，以及具体执行说明
--   id        varchar(32) 围栏ID
--   geom_geojson json    原始围栏几何的GeoJSON
--   electric_buffer_geom geometry 缓冲面几何
--   electric_buffer_geojson json 缓冲面几何的GeoJSON
--   electric_solid_geom geometry 立体几何体
--   electric_solid_geojson json 立体几何体的GeoJSON
-- 函数注意
--   1. bo_electric_fence 必须存在，且包含字段：id, geom, height, del_flag
--   2. geom 字段为PostGIS几何类型，height 为围栏高度（数字类型
--   3. 缓冲半径单位**，坐标系转换保证距离计算准确
--   4. 3D几何体为：底Z=0) + 顶部(Z=围栏高度) 的集合几何体
-- 适用场景电子围栏可视化、GIS空间分析、前端地图渲染（2D/3D围栏展示
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_buffer');

-- =============================================================================
-- 函数介绍：gis_electric_fence_buffer
-- 主要作用：根据电子围栏ID和缓冲距离，计算围栏外扩后的缓冲面几何
-- 入参说明：p_project_id 为项目ID；p_fence_id 为围栏ID（为空返回全部）；p_buffer_m 为缓冲距离，单位米。
-- 返回说明：返回缓冲区GeoJSON、原始围栏信息和执行状态，便于前端展示或后续碰撞判断。
-- 注意事项：缓冲按米计算，内部会转换到适合平面距离计算的坐标系后再转回WGS84
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_buffer(
    p_fence_id varchar(32),        -- 入参1：围栏ID
    p_buffer_radius double precision, -- 入参2：缓冲半径（米）
    p_return_geojson boolean DEFAULT false -- 是否返回GeoJSON
)
-- 定义函数返回的表结构（字段顺序、类型必须严格匹配）
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json,
    electric_buffer_geom geometry,
    electric_buffer_geojson json,
    electric_solid_geom geometry,
    electric_solid_geojson json
)
-- 函数语言：PL/pgSQL（PostgreSQL过程语言
LANGUAGE plpgsql
-- 易变性声明：VOLATILE 表示函数可能写入错误日志表
VOLATILE
AS $$
DECLARE
    -- 定义变量：存D缓冲后的几何对象
    v_buffer_geom geometry;
    -- 定义变量：存储单条围栏记录（类型与表 bo_electric_fence 完全一致）
    v_fence_record bo_electric_fence%ROWTYPE;
    -- 定义变量：存D立体几何对象
    v_3d_geom geometry;
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_buffer(%L, %s, %L);',
        p_fence_id, COALESCE(p_buffer_radius::text, 'NULL'), p_return_geojson);

    -- ==============================================
    -- 1. 入参合法性校验：围栏ID 不能为空/空字符串
    -- ==============================================
    IF p_fence_id IS NULL OR p_fence_id = '' THEN
        -- 返回400：参数错误，所有几何字段置
        code := 400;
        msg := format('围栏ID不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
        -- 终止函数执行
        RETURN;
    END IF;

    -- ==============================================
    -- 2. 查询有效围栏数据（未逻辑删除
    -- ==============================================
    SELECT *
    INTO v_fence_record  -- 查询结果存入围栏记录变量
    FROM bo_electric_fence f
    WHERE f.id = p_fence_id  -- 按围栏ID匹配
      AND f.del_flag = false  -- 只查询未删除的数据
      AND f.status = '1';     -- 只查询启用状态的数据

    -- ==============================================
    -- 3. 校验：未查询到有效围栏数据
    -- ==============================================
    IF v_fence_record.id IS NULL THEN
        -- 返回400：无数据，所有几何字段置
        code := 400;
        msg := format('未查询到有效围栏数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    -- ==============================================
    -- 4. 计算2D缓冲几何（核心GIS逻辑
    -- ==============================================
    SELECT
            CASE
                -- 情况1：缓冲半0 直接使用原始围栏几何，设置坐标系4326(WGS84)
                WHEN p_buffer_radius = 0 THEN
                    ST_SetSRID(v_fence_record.geom, 4326)
                -- 情况2：半0 计算缓冲突
                ELSE
                    -- 步骤326857（墨卡托，米单位）→ 做缓转回4326
                    ST_Transform(
                        ST_Buffer(
                            ST_Transform(ST_SetSRID(v_fence_record.geom,4326),3857),
                            p_buffer_radius
                        ),
                        4326
                    )
            END
    INTO v_buffer_geom; -- 结果存入缓冲几何变量

    -- ==============================================
    -- 5. 构建3D立体几何体（底部+顶部
    -- ==============================================
    SELECT
            -- 转换为多几何对象（兼容前端渲染）
            ST_Multi(
                -- 合并两个3D面：底部(Z=0) + 顶部(Z=围栏高度)
                ST_Collect(
                    -- 底部面：Z坐标=0
                    ST_Force3DZ(v_buffer_geom, 0),
                    -- 顶部面：Z坐标=围栏高度（空值则
                    ST_Force3DZ(v_buffer_geom, COALESCE(v_fence_record.height, 0))
                )
            )
    INTO v_3d_geom; -- 结果存入3D几何变量

    -- ==============================================
    -- 6. 执行成功：返00 + 所有几何数据
    -- ==============================================
    RETURN QUERY SELECT
        200,                        -- 状态码：成功
        format('成功，check_type=b_generated(缓冲区已生成)，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,            -- 提示信息
        true,
        'b_generated'::varchar,
        v_fence_record.id::varchar, -- 围栏ID
        v_fence_record.fence_type::varchar,
        v_fence_record.geom,
        -- 原始围栏几何 GeoJSON
        CASE WHEN p_return_geojson THEN ST_AsGeoJSON(ST_SetSRID(v_fence_record.geom, 4326))::json ELSE NULL::json END,
        v_buffer_geom,
        -- 2D缓冲几何 GeoJSON
        CASE WHEN p_return_geojson THEN ST_AsGeoJSON(v_buffer_geom)::json ELSE NULL::json END,
        v_3d_geom,
        -- 3D立体几何 GeoJSON
        CASE WHEN p_return_geojson THEN ST_AsGeoJSON(v_3d_geom)::json ELSE NULL::json END;

-- ==============================================
-- 异常捕获：执行过程中出现任何错误，返00
-- ==============================================
EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_buffer(varchar, double precision, boolean) IS '生成电子围栏缓冲区';

-- 支持项目ID；p_fence_id为空时返回项目/公共范围内全部围栏缓冲数据
CREATE OR REPLACE FUNCTION public.gis_electric_fence_buffer(
    p_project_id text,
    p_fence_id varchar(32) DEFAULT NULL,
    p_buffer_radius double precision DEFAULT 0,
    p_return_geojson boolean DEFAULT false
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json,
    electric_buffer_geom geometry,
    electric_buffer_geojson json,
    electric_solid_geom geometry,
    electric_solid_geojson json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_table_name text;
    v_table_exists boolean;
    v_sql text;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_buffer(%L, %L, %s, %L);',
        p_project_id, p_fence_id, COALESCE(p_buffer_radius::text, 'NULL'), p_return_geojson);

    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
        v_table_name := 'gis_electric_fence_' || trim(p_project_id);

        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_table_name
        ) INTO v_table_exists;

        IF v_table_exists THEN
            v_sql := format('
                WITH src AS (
                    SELECT f.id::varchar AS id,
                           f.geom AS geom,
                           ST_SetSRID(f.geom, 4326) AS calc_geom,
                           COALESCE(f.height, 0)::double precision AS height,
                           ''1''::varchar AS fence_type
                    FROM %I f
                    WHERE f.geom IS NOT NULL
                      AND ($1 IS NULL OR btrim($1) = '''' OR f.id::varchar = btrim($1))
                    UNION ALL
                    SELECT f.id::varchar AS id,
                           f.geom AS geom,
                           ST_SetSRID(f.geom, 4326) AS calc_geom,
                           COALESCE(f.height, 0)::double precision AS height,
                           f.fence_type::varchar AS fence_type
                    FROM bo_electric_fence f
                    WHERE f.del_flag = false
                      AND f.status = ''1''
                      AND f.geom IS NOT NULL
                      AND ($1 IS NULL OR btrim($1) = '''' OR f.id::varchar = btrim($1))
                      AND ($2 IS NULL OR btrim($2) = '''' OR f.project_id::text = btrim($2))
                )
                SELECT
                    200 AS code,
                    format(''成功，check_type=b_generated(缓冲区已生成)，执行时间 %%s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $4)::numeric, 3))::varchar AS msg,
                    true AS ischeck,
                    ''b_generated''::varchar AS check_type,
                    src.id::varchar(32) AS electric_id,
                    src.fence_type::varchar AS fence_type,
                    src.geom AS electric_geom,
                    CASE WHEN $5 THEN ST_AsGeoJSON(src.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                    buf.buffer_geom AS electric_buffer_geom,
                    CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                    solid.solid_geom AS electric_solid_geom,
                    CASE WHEN $5 THEN ST_AsGeoJSON(solid.solid_geom)::json ELSE NULL::json END AS electric_solid_geojson
                FROM src
                CROSS JOIN LATERAL (
                    SELECT CASE
                        WHEN COALESCE($3, 0) = 0 THEN ST_Force2D(src.calc_geom)
                        ELSE ST_Transform(
                            ST_Buffer(ST_Transform(ST_Force2D(src.calc_geom), 3857), COALESCE($3, 0)),
                            4326
                        )
                    END AS buffer_geom
                ) buf
                CROSS JOIN LATERAL (
                    SELECT ST_Multi(ST_Collect(
                            ST_Force3DZ(buf.buffer_geom, 0),
                            ST_Force3DZ(buf.buffer_geom, src.height)
                        )) AS solid_geom
                ) solid',
                v_table_name
            );
        ELSE
            v_sql := '
                WITH src AS (
                    SELECT f.id::varchar AS id,
                           f.geom AS geom,
                           ST_SetSRID(f.geom, 4326) AS calc_geom,
                           COALESCE(f.height, 0)::double precision AS height,
                           f.fence_type::varchar AS fence_type
                    FROM bo_electric_fence f
                    WHERE f.del_flag = false
                      AND f.status = ''1''
                      AND f.geom IS NOT NULL
                      AND ($1 IS NULL OR btrim($1) = '''' OR f.id::varchar = btrim($1))
                      AND ($2 IS NULL OR btrim($2) = '''' OR f.project_id::text = btrim($2))
                )
                SELECT
                    200 AS code,
                    format(''成功，check_type=b_generated(缓冲区已生成)，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $4)::numeric, 3))::varchar AS msg,
                    true AS ischeck,
                    ''b_generated''::varchar AS check_type,
                    src.id::varchar(32) AS electric_id,
                    src.fence_type::varchar AS fence_type,
                    src.geom AS electric_geom,
                    CASE WHEN $5 THEN ST_AsGeoJSON(src.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                    buf.buffer_geom AS electric_buffer_geom,
                    CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                    solid.solid_geom AS electric_solid_geom,
                    CASE WHEN $5 THEN ST_AsGeoJSON(solid.solid_geom)::json ELSE NULL::json END AS electric_solid_geojson
                FROM src
                CROSS JOIN LATERAL (
                    SELECT CASE
                        WHEN COALESCE($3, 0) = 0 THEN ST_Force2D(src.calc_geom)
                        ELSE ST_Transform(
                            ST_Buffer(ST_Transform(ST_Force2D(src.calc_geom), 3857), COALESCE($3, 0)),
                            4326
                        )
                    END AS buffer_geom
                ) buf
                CROSS JOIN LATERAL (
                    SELECT ST_Multi(ST_Collect(
                            ST_Force3DZ(buf.buffer_geom, 0),
                            ST_Force3DZ(buf.buffer_geom, src.height)
                        )) AS solid_geom
                ) solid';
        END IF;
    ELSE
        v_sql := '
            WITH src AS (
                SELECT f.id::varchar AS id,
                       f.geom AS geom,
                       ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height,
                       f.fence_type::varchar AS fence_type
                    FROM bo_electric_fence f
                    WHERE f.del_flag = false
                      AND f.status = ''1''
                      AND f.geom IS NOT NULL
                  AND ($1 IS NULL OR btrim($1) = '''' OR f.id::varchar = btrim($1))
            )
            SELECT
                200 AS code,
                format(''成功，check_type=b_generated(缓冲区已生成)，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $4)::numeric, 3))::varchar AS msg,
                true AS ischeck,
                ''b_generated''::varchar AS check_type,
                src.id::varchar(32) AS electric_id,
                src.fence_type::varchar AS fence_type,
                src.geom AS electric_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(src.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                buf.buffer_geom AS electric_buffer_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                solid.solid_geom AS electric_solid_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(solid.solid_geom)::json ELSE NULL::json END AS electric_solid_geojson
            FROM src
            CROSS JOIN LATERAL (
                SELECT CASE
                    WHEN COALESCE($3, 0) = 0 THEN ST_Force2D(src.calc_geom)
                    ELSE ST_Transform(
                        ST_Buffer(ST_Transform(ST_Force2D(src.calc_geom), 3857), COALESCE($3, 0)),
                        4326
                    )
                END AS buffer_geom
            ) buf
            CROSS JOIN LATERAL (
                SELECT ST_Multi(ST_Collect(
                        ST_Force3DZ(buf.buffer_geom, 0),
                        ST_Force3DZ(buf.buffer_geom, src.height)
                    )) AS solid_geom
            ) solid';
    END IF;

    RETURN QUERY EXECUTE v_sql USING p_fence_id, p_project_id, p_buffer_radius, v_start_time, p_return_geojson;

    IF NOT FOUND THEN
        code := 400;
        msg := format('未查询到有效围栏数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_buffer(text, varchar, double precision, boolean) IS '生成电子围栏缓冲区';



-- 航点缓冲区检测，支持项目ID

SELECT gis_drop_function('gis_electric_fence_check_point_buffer');

CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_point_buffer(
    p_project_id text,
    p_point_geojson text,
    p_buffer_radius double precision DEFAULT 0,
    p_return_geojson boolean DEFAULT false
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json,
    electric_buffer_geom geometry,
    electric_buffer_geojson json,
    electric_solid_geom geometry,
    electric_solid_geojson json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_point geometry;
    v_point_json jsonb;
    v_z double precision;
    v_table_name text;
    v_table_exists boolean;
    v_sql text;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_check_point_buffer(%L, %L, %s, %L);',
        p_project_id, p_point_geojson, COALESCE(p_buffer_radius::text, 'NULL'), p_return_geojson);

    IF p_point_geojson IS NULL OR p_point_geojson = '' THEN
        code := 400;
        msg := format('点的GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    BEGIN
        v_point_json := p_point_geojson::jsonb;
        IF jsonb_typeof(v_point_json) = 'array' THEN
            IF jsonb_array_length(v_point_json) < 2 THEN
                RAISE EXCEPTION 'Point coordinate array requires at least lng and lat';
            ELSIF jsonb_array_length(v_point_json) >= 3 THEN
                v_point := ST_MakePoint(
                    (v_point_json ->> 0)::double precision,
                    (v_point_json ->> 1)::double precision,
                    (v_point_json ->> 2)::double precision
                );
                v_z := COALESCE((v_point_json ->> 2)::double precision, 0);
            ELSE
                v_point := ST_MakePoint(
                    (v_point_json ->> 0)::double precision,
                    (v_point_json ->> 1)::double precision
                );
                v_z := 0;
            END IF;
        ELSIF v_point_json ->> 'type' = 'Feature' THEN
            v_point := ST_GeomFromGeoJSON(v_point_json ->> 'geometry');
            v_z := COALESCE(
                (v_point_json -> 'properties' ->> 'z')::double precision,
                (v_point_json -> 'properties' ->> 'height')::double precision,
                ST_Z(v_point),
                0
            );
        ELSE
            v_point := ST_GeomFromGeoJSON(v_point_json::text);
            v_z := COALESCE(ST_Z(v_point), 0);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            code := 400;
            msg := format('点GeoJSON解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                code,
                msg,
                v_log_sql
            );

            RETURN QUERY SELECT
                code, msg::varchar,
                false, 'invalid_param'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
            RETURN;
    END;

    IF ST_GeometryType(v_point) NOT IN ('ST_Point') THEN
        code := 400;
        msg := format('GeoJSON必须是Point类型，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    IF ST_CoordDim(v_point) < 3 AND v_z > 0 THEN
        v_point := ST_Force3DZ(v_point, v_z);
    END IF;
    v_point := ST_SetSRID(v_point, 4326);

    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
        v_table_name := 'gis_electric_fence_' || trim(p_project_id);
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_table_name
        ) INTO v_table_exists;
    ELSE
        v_table_exists := false;
    END IF;

    IF v_table_exists THEN
        v_sql := format('
            WITH fences AS (
                SELECT f.id::varchar AS id, f.geom AS geom, ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height, ''1''::varchar AS fence_type, 1 AS priority
                FROM %I f
                WHERE f.geom IS NOT NULL
                UNION ALL
                SELECT f.id::varchar AS id, f.geom AS geom, ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height, f.fence_type::varchar AS fence_type, 2 AS priority
                FROM bo_electric_fence f
                WHERE f.del_flag = false
                  AND f.status = ''1''
                  AND f.geom IS NOT NULL
                  AND ($3 IS NULL OR btrim($3) = '''' OR f.project_id::text = btrim($3))
            )
            SELECT
                200 AS code,
                format(''检测到航点闯入电子围栏缓冲区，check_type=p_inner(点在内部)，执行时间 %%s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $4)::numeric, 3))::varchar AS msg,
                true AS ischeck,
                ''p_inner''::varchar AS check_type,
                f.id::varchar(32) AS electric_id,
                f.fence_type::varchar AS fence_type,
                f.geom AS electric_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(f.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                buf.buffer_geom AS electric_buffer_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )) AS electric_solid_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )))::json ELSE NULL::json END AS electric_solid_geojson
            FROM fences f
            CROSS JOIN LATERAL (
                SELECT CASE
                    WHEN COALESCE($2, 0) = 0 THEN ST_Force2D(f.calc_geom)
                    ELSE ST_Transform(ST_Buffer(ST_Transform(ST_Force2D(f.calc_geom), 3857), COALESCE($2, 0)), 4326)
                END AS buffer_geom
            ) buf
            WHERE ST_Covers(buf.buffer_geom, $1)
              AND (
                  COALESCE(ST_Z($1), 0) = 0
                  OR COALESCE(f.height, 0) = 0
                  OR (COALESCE(ST_Z($1), 0) > 0 AND COALESCE(ST_Z($1), 0) <= f.height)
              )
            ORDER BY f.priority, f.id
            LIMIT 1',
            v_table_name
        );
    ELSE
        v_sql := '
            WITH fences AS (
                SELECT f.id::varchar AS id, f.geom AS geom, ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height, f.fence_type::varchar AS fence_type
                FROM bo_electric_fence f
                WHERE f.del_flag = false
                  AND f.status = ''1''
                  AND f.geom IS NOT NULL
                  AND ($3 IS NULL OR btrim($3) = '''' OR f.project_id::text = btrim($3))
            )
            SELECT
                200 AS code,
                format(''检测到航点闯入电子围栏缓冲区，check_type=p_inner(点在内部)，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $4)::numeric, 3))::varchar AS msg,
                true AS ischeck,
                ''p_inner''::varchar AS check_type,
                f.id::varchar(32) AS electric_id,
                f.fence_type::varchar AS fence_type,
                f.geom AS electric_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(f.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                buf.buffer_geom AS electric_buffer_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )) AS electric_solid_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )))::json ELSE NULL::json END AS electric_solid_geojson
            FROM fences f
            CROSS JOIN LATERAL (
                SELECT CASE
                    WHEN COALESCE($2, 0) = 0 THEN ST_Force2D(f.calc_geom)
                    ELSE ST_Transform(ST_Buffer(ST_Transform(ST_Force2D(f.calc_geom), 3857), COALESCE($2, 0)), 4326)
                END AS buffer_geom
            ) buf
            WHERE ST_Covers(buf.buffer_geom, $1)
              AND (
                  COALESCE(ST_Z($1), 0) = 0
                  OR COALESCE(f.height, 0) = 0
                  OR (COALESCE(ST_Z($1), 0) > 0 AND COALESCE(ST_Z($1), 0) <= f.height)
              )
            ORDER BY f.id
            LIMIT 1';
    END IF;

    RETURN QUERY EXECUTE v_sql USING v_point, p_buffer_radius, p_project_id, v_start_time, p_return_geojson;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200, format('航点未闯入任何电子围栏缓冲区，check_type=p_outer(点在外部)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false, 'p_outer'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_point_buffer(text, text, double precision, boolean) IS '检测航点缓冲区冲突';


-- ====================================================================================
-- 函数名称gis_electric_fence_check_line_buffer
-- 函数功能航线/轨迹/线段 穿入电子围栏检测（支持2D缓冲 + 3D立体相交判断
-- 函数描述1. 接收线路/轨迹GeoJSON字符串与缓冲半径
--            2. 半径=0 使用原始围栏几何判断相交
--            3. 半径>0 先对围栏做外扩缓冲，再判
--            4. 自动将围栏拉伸为3D立体（高围栏height字段
--            5. 执行3D空间相交判断：线路穿过围栏返回该围栏完整信息
--            6. 无任何相返回空结果集
-- 函数说明依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)，平面缓冲使用墨卡托(3857)计算
--            内部复用 gis_electric_fence_buffer 函数获取完整围栏+缓冲+3D数据
-- 参数说明
--   p_line_geojson     text           输入参数：线轨迹/线段的GeoJSON字符串（必填
--   p_buffer_radius    double precision 输入参数：缓冲半径（单位：米），默认0不缓
-- 返回值： 标准TABLE结构，包含状态码、提示信息、围栏ID、各类几何GeoJSON
--   code      integer    状态码00=执行成功 400=参数错误/未查询到数据 500=执行异常
--   msg       varchar    状态描述信息
--   id        varchar(32) 围栏ID
--   electric_geojson json    原始围栏几何的GeoJSON
--   electric_buffer_geojson json 2D缓冲面几何的GeoJSON
--   electric_solid_geojson json 3D立体几何体的GeoJSON
-- 函数注意
--   1. 依赖函数：gis_electric_fence_buffer 必须提前创建
--   2. bo_electric_fence 必须存在，且包含字段：id, geom, height, del_flag
--   3. 禁飞区和管控区统一按同一套缓冲区/高度逻辑校验
--   4. 缓冲半径单位**，坐标系转换保证距离计算准确
-- 适用场景无人机航线规划、飞行轨迹闯入禁管控/试飞区自动检
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_check_line_buffer');

-- 创建函数
-- =============================================================================
-- 函数介绍：gis_electric_fence_check_line_buffer
-- 主要作用：对输入航线先做缓冲，再检测缓冲区是否与电子围栏发生冲突
-- 入参说明：p_line_json 为航线LineString/LineStringZ GeoJSON；p_buffer_m 为航线安全缓冲半径
-- 返回说明：返回冲突状态、命中的围栏信息和相交几何，用于航线安全距离校验
-- 注意事项：适合带安全裕度的航线校验；缓冲距离越大，命中范围越宽
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_line_buffer(
    p_line_geojson text,
    p_buffer_radius double precision DEFAULT 0,
    p_return_geojson boolean DEFAULT false
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json,
    electric_buffer_geom geometry,
    electric_buffer_geojson json,
    electric_solid_geom geometry,
    electric_solid_geojson json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_line geometry; -- 存储转换后的线路几何对象
    v_line_json jsonb;
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_check_line_buffer(%L, %s, %L);',
        p_line_geojson, COALESCE(p_buffer_radius::text, 'NULL'), p_return_geojson);

    -- ==============================================
    -- 1. GeoJSON线路解析：转换为PostGIS几何对象，强制设326坐标记
    -- ==============================================
    IF p_line_geojson IS NULL OR p_line_geojson = '' THEN
        code := 400;
        msg := format('航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    BEGIN
        v_line_json := p_line_geojson::jsonb;

        IF jsonb_typeof(v_line_json) = 'array' THEN
            IF jsonb_array_length(v_line_json) < 2 THEN
                RAISE EXCEPTION 'Line coordinate array requires at least two points';
            END IF;
            v_line := ST_GeomFromGeoJSON(
                jsonb_build_object(
                    'type', 'LineString',
                    'coordinates', v_line_json
                )::text
            );
        ELSIF v_line_json ->> 'type' = 'Feature' THEN
            v_line := ST_GeomFromGeoJSON(v_line_json ->> 'geometry');
        ELSE
            v_line := ST_GeomFromGeoJSON(v_line_json::text);
        END IF;

        v_line := ST_SetSRID(v_line, 4326);
    EXCEPTION
        WHEN OTHERS THEN
            code := 400;
            msg := format('航线GeoJSON/坐标数组解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                code,
                msg,
                v_log_sql
            );

            RETURN QUERY SELECT
                code, msg::varchar,
                false, 'invalid_param'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
            RETURN;
    END;

    -- ==============================================
    -- 2. 核心逻辑：禁飞区和管控区统一按缓冲区/高度逻辑判断
    -- ==============================================
    RETURN QUERY
    SELECT
        res.code,
        format('检测到航线缓冲区闯入电子围栏，check_type=%s，执行时间 %s 秒',
            ct.check_type_msg,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar AS msg,
        true AS ischeck,
        ct.check_type,
        res.electric_id,
        res.fence_type,
        res.electric_geom,
        res.electric_geojson,
        res.electric_buffer_geom,
        res.electric_buffer_geojson,
        res.electric_solid_geom,
        res.electric_solid_geojson
    FROM bo_electric_fence f,
         -- 计算围栏2D缓冲突
         LATERAL (
             SELECT
                 CASE WHEN p_buffer_radius = 0 THEN ST_SetSRID(f.geom, 4326)
                      ELSE ST_Transform(ST_Buffer(ST_Transform(ST_SetSRID(f.geom,4326),3857), p_buffer_radius), 4326)
                 END AS buf
         ) AS buf_data,
         -- 构建3D立体几何体（拉伸高度
         LATERAL ST_Extrude(ST_Force3D(buf_data.buf), 0, 0, COALESCE(f.height, 0)) AS solid_geom,
         -- 调用已有缓冲函数，获取标准返回结果
         LATERAL gis_electric_fence_buffer(NULL, f.id, p_buffer_radius, p_return_geojson) AS res,
         LATERAL (
             SELECT
                 x.check_type,
                 CASE x.check_type
                     WHEN 'ln_outside' THEN 'ln_outside(线与面：相离)'
                     WHEN 'ln_within' THEN 'ln_within(线与面：包含于)'
                     WHEN 'ln_enters' THEN 'ln_enters(线与面：穿入/穿出)'
                     WHEN 'ln_overlaps' THEN 'ln_overlaps(线与面：重叠)'
                     ELSE 'ln_crosses(线与面：交叉)'
                 END::varchar AS check_type_msg
             FROM (
                 SELECT CASE
                     WHEN ST_CoveredBy(ST_Force2D(v_line), ST_Boundary(buf_data.buf)) THEN 'ln_overlaps'
                     WHEN ST_CoveredBy(ST_Force2D(v_line), buf_data.buf) THEN 'ln_within'
                     WHEN ST_Covers(buf_data.buf, ST_StartPoint(ST_Force2D(v_line))) <> ST_Covers(buf_data.buf, ST_EndPoint(ST_Force2D(v_line))) THEN 'ln_enters'
                     ELSE 'ln_crosses'
                 END::varchar AS check_type
             ) x
         ) AS ct
    WHERE
        f.del_flag = false  -- 仅有效围栏
        AND f.status = '1'  -- 仅启用围栏
        AND (
            (COALESCE(f.height, 0) = 0 AND ST_Intersects(ST_Force2D(v_line), buf_data.buf))
            OR
            (COALESCE(f.height, 0) > 0 AND ST_3DIntersects(v_line, solid_geom))
        )
    ORDER BY f.id
    LIMIT 1; -- 禁飞区和管控区统一：有高度按3D判断，无高度/0高度按2D判断

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200, format('航线未闯入任何电子围栏，check_type=ln_outside(线与面：相离)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false, 'ln_outside'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_line_buffer(text, double precision, boolean) IS '检测航线缓冲区冲突';

-- 支持项目ID的航线缓冲区检测
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_line_buffer(
    p_project_id text,
    p_line_geojson text,
    p_buffer_radius double precision DEFAULT 0,
    p_return_geojson boolean DEFAULT false
)
RETURNS TABLE (
    code integer,
    msg varchar,
    ischeck boolean,
    check_type varchar,
    electric_id varchar(32),
    fence_type varchar,
    electric_geom geometry,
    electric_geojson json,
    electric_buffer_geom geometry,
    electric_buffer_geojson json,
    electric_solid_geom geometry,
    electric_solid_geojson json
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_line geometry;
    v_line_json jsonb;
    v_table_name text;
    v_table_exists boolean;
    v_sql text;
    v_start_time timestamptz := clock_timestamp();
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_electric_fence_check_line_buffer(%L, %L, %s, %L);',
        p_project_id, p_line_geojson, COALESCE(p_buffer_radius::text, 'NULL'), p_return_geojson);

    IF p_line_geojson IS NULL OR p_line_geojson = '' THEN
        code := 400;
        msg := format('航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
        RETURN;
    END IF;

    BEGIN
        v_line_json := p_line_geojson::jsonb;

        IF jsonb_typeof(v_line_json) = 'array' THEN
            IF jsonb_array_length(v_line_json) < 2 THEN
                RAISE EXCEPTION 'Line coordinate array requires at least two points';
            END IF;
            v_line := ST_GeomFromGeoJSON(
                jsonb_build_object(
                    'type', 'LineString',
                    'coordinates', v_line_json
                )::text
            );
        ELSIF v_line_json ->> 'type' = 'Feature' THEN
            v_line := ST_GeomFromGeoJSON(v_line_json ->> 'geometry');
        ELSE
            v_line := ST_GeomFromGeoJSON(v_line_json::text);
        END IF;

        v_line := ST_SetSRID(v_line, 4326);
    EXCEPTION
        WHEN OTHERS THEN
            code := 400;
            msg := format('航线GeoJSON/坐标数组解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                code,
                msg,
                v_log_sql
            );

            RETURN QUERY SELECT
                code, msg::varchar,
                false, 'invalid_param'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
            RETURN;
    END;

    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
        v_table_name := 'gis_electric_fence_' || trim(p_project_id);
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_table_name
        ) INTO v_table_exists;
    ELSE
        v_table_exists := false;
    END IF;

    IF v_table_exists THEN
        v_sql := format('
            WITH fences AS (
                SELECT f.id::varchar AS id, f.geom AS geom, ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height, ''1''::varchar AS fence_type, 1 AS priority
                FROM %I f
                WHERE f.geom IS NOT NULL
                UNION ALL
                SELECT f.id::varchar AS id, f.geom AS geom, ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height, f.fence_type::varchar AS fence_type, 2 AS priority
                FROM bo_electric_fence f
                WHERE f.del_flag = false
                  AND f.status = ''1''
                  AND f.geom IS NOT NULL
                  AND ($2 IS NULL OR btrim($2) = '''' OR f.project_id::text = btrim($2))
            )
            SELECT
                200 AS code,
                format(''检测到航线缓冲区闯入电子围栏，check_type=%%s，执行时间 %%s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))::varchar AS msg,
                true AS ischeck,
                ct.check_type,
                f.id::varchar(32) AS electric_id,
                f.fence_type::varchar AS fence_type,
                f.geom AS electric_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(f.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                buf.buffer_geom AS electric_buffer_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )) AS electric_solid_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )))::json ELSE NULL::json END AS electric_solid_geojson
            FROM fences f
            CROSS JOIN LATERAL (
                SELECT CASE
                    WHEN COALESCE($1, 0) = 0 THEN ST_Force2D(f.calc_geom)
                    ELSE ST_Transform(ST_Buffer(ST_Transform(ST_Force2D(f.calc_geom), 3857), COALESCE($1, 0)), 4326)
                END AS buffer_geom
            ) buf
            CROSS JOIN LATERAL (
                SELECT ST_Extrude(ST_Force3D(buf.buffer_geom), 0, 0, f.height) AS solid_geom
            ) solid
            CROSS JOIN LATERAL (
                SELECT
                    x.check_type,
                    CASE x.check_type
                        WHEN ''ln_outside'' THEN ''ln_outside(线与面：相离)''
                        WHEN ''ln_within'' THEN ''ln_within(线与面：包含于)''
                        WHEN ''ln_enters'' THEN ''ln_enters(线与面：穿入/穿出)''
                        WHEN ''ln_overlaps'' THEN ''ln_overlaps(线与面：重叠)''
                        ELSE ''ln_crosses(线与面：交叉)''
                    END::varchar AS check_type_msg
                FROM (
                    SELECT CASE
                        WHEN ST_CoveredBy(ST_Force2D($4), ST_Boundary(buf.buffer_geom)) THEN ''ln_overlaps''
                        WHEN ST_CoveredBy(ST_Force2D($4), buf.buffer_geom) THEN ''ln_within''
                        WHEN ST_Covers(buf.buffer_geom, ST_StartPoint(ST_Force2D($4))) <> ST_Covers(buf.buffer_geom, ST_EndPoint(ST_Force2D($4))) THEN ''ln_enters''
                        ELSE ''ln_crosses''
                    END::varchar AS check_type
                ) x
            ) ct
            WHERE (
                (COALESCE(f.height, 0) = 0 AND ST_Intersects(ST_Force2D($4), buf.buffer_geom))
                OR
                (COALESCE(f.height, 0) > 0 AND ST_3DIntersects($4, solid.solid_geom))
            )
            ORDER BY f.priority, f.id
            LIMIT 1',
            v_table_name
        );
    ELSE
        v_sql := '
            WITH fences AS (
                SELECT f.id::varchar AS id, f.geom AS geom, ST_SetSRID(f.geom, 4326) AS calc_geom,
                       COALESCE(f.height, 0)::double precision AS height, f.fence_type::varchar AS fence_type
                FROM bo_electric_fence f
                WHERE f.del_flag = false
                  AND f.status = ''1''
                  AND f.geom IS NOT NULL
                  AND ($2 IS NULL OR btrim($2) = '''' OR f.project_id::text = btrim($2))
            )
            SELECT
                200 AS code,
                format(''检测到航线缓冲区闯入电子围栏，check_type=%s，执行时间 %s 秒'', ct.check_type_msg, ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))::varchar AS msg,
                true AS ischeck,
                ct.check_type,
                f.id::varchar(32) AS electric_id,
                f.fence_type::varchar AS fence_type,
                f.geom AS electric_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(f.calc_geom)::json ELSE NULL::json END AS electric_geojson,
                buf.buffer_geom AS electric_buffer_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(buf.buffer_geom)::json ELSE NULL::json END AS electric_buffer_geojson,
                ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )) AS electric_solid_geom,
                CASE WHEN $5 THEN ST_AsGeoJSON(ST_Multi(ST_Collect(
                    ST_Force3DZ(buf.buffer_geom, 0),
                    ST_Force3DZ(buf.buffer_geom, f.height)
                )))::json ELSE NULL::json END AS electric_solid_geojson
            FROM fences f
            CROSS JOIN LATERAL (
                SELECT CASE
                    WHEN COALESCE($1, 0) = 0 THEN ST_Force2D(f.calc_geom)
                    ELSE ST_Transform(ST_Buffer(ST_Transform(ST_Force2D(f.calc_geom), 3857), COALESCE($1, 0)), 4326)
                END AS buffer_geom
            ) buf
            CROSS JOIN LATERAL (
                SELECT ST_Extrude(ST_Force3D(buf.buffer_geom), 0, 0, f.height) AS solid_geom
            ) solid
            CROSS JOIN LATERAL (
                SELECT
                    x.check_type,
                    CASE x.check_type
                        WHEN ''ln_outside'' THEN ''ln_outside(线与面：相离)''
                        WHEN ''ln_within'' THEN ''ln_within(线与面：包含于)''
                        WHEN ''ln_enters'' THEN ''ln_enters(线与面：穿入/穿出)''
                        WHEN ''ln_overlaps'' THEN ''ln_overlaps(线与面：重叠)''
                        ELSE ''ln_crosses(线与面：交叉)''
                    END::varchar AS check_type_msg
                FROM (
                    SELECT CASE
                        WHEN ST_CoveredBy(ST_Force2D($4), ST_Boundary(buf.buffer_geom)) THEN ''ln_overlaps''
                        WHEN ST_CoveredBy(ST_Force2D($4), buf.buffer_geom) THEN ''ln_within''
                        WHEN ST_Covers(buf.buffer_geom, ST_StartPoint(ST_Force2D($4))) <> ST_Covers(buf.buffer_geom, ST_EndPoint(ST_Force2D($4))) THEN ''ln_enters''
                        ELSE ''ln_crosses''
                    END::varchar AS check_type
                ) x
            ) ct
            WHERE (
                (COALESCE(f.height, 0) = 0 AND ST_Intersects(ST_Force2D($4), buf.buffer_geom))
                OR
                (COALESCE(f.height, 0) > 0 AND ST_3DIntersects($4, solid.solid_geom))
            )
            ORDER BY f.id
            LIMIT 1';
    END IF;

    RETURN QUERY EXECUTE v_sql USING p_buffer_radius, p_project_id, v_start_time, v_line, p_return_geojson;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200, format('航线未闯入任何电子围栏缓冲区，check_type=ln_outside(线与面：相离)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            false, 'ln_outside'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        code := 500;
        msg := format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (
            code,
            msg,
            v_log_sql
        );

        RETURN QUERY SELECT
            code, msg::varchar,
            false, 'error'::varchar, NULL::varchar, NULL::varchar, NULL::geometry, NULL::json, NULL::geometry, NULL::json, NULL::geometry, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_line_buffer(text, text, double precision, boolean) IS '检测航线缓冲区冲突';



-- =============================================================================
-- 文件内全部函数调用示例
-- 说明：以下示例均为注释形式；需要执行时取消对应 SELECT 块的注释。
-- =============================================================================

-- =============================================================================
-- 1. gis_check_electric_fence
-- 功能：新增/编辑电子围栏前，校验围栏空间冲突。
-- 入参：p_project_id, p_fence_type, p_lng_lat_alt
-- =============================================================================

-- 示例1：新增试飞区(3)，传 Feature 格式项目范围
-- SELECT * FROM gis_check_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '3',
--     '{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[113.289609,34.951427,0],[113.290607,34.615358,0],[113.979944,34.596458,0],[114.013926,34.930172,0]]]},"properties":{}}'
-- );

-- 示例2：新增试飞区(3)，直接传 Geometry 格式
-- SELECT * FROM gis_check_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '3',
--     '{"type":"Polygon","coordinates":[[[115.72,39.41],[117.51,39.41],[117.51,41.05],[115.72,41.05],[115.72,39.41]]]}'
-- );

-- 示例3：新增管控区(2)
-- SELECT * FROM gis_check_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '2',
--     '{"type":"Polygon","coordinates":[[[113.462897,34.815104,0],[113.462853,34.808521,0],[113.467863,34.808484,0],[113.467952,34.815031,0],[113.462897,34.815104,0]]]}'
-- );

-- =============================================================================
-- 2. gis_electric_fence_check_point
-- 功能：检测航点是否落入电子围栏。
-- 入参：p_project_id, p_point_geojson
-- 返回：code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
-- =============================================================================

-- 示例1：有项目ID，Point/PointZ GeoJSON
-- SELECT * FROM public.gis_electric_fence_check_point(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Point","coordinates":[113.405861,34.769437,10000]}'
-- );

-- 示例2：有项目ID，Feature 格式
-- SELECT * FROM public.gis_electric_fence_check_point(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Feature","geometry":{"type":"Point","coordinates":[113.405861,34.769437]},"properties":{"z":10000}}'
-- );

-- 示例3：有项目ID，坐标数组格式 [lng,lat,alt]
-- SELECT * FROM public.gis_electric_fence_check_point(
--     '2c95908e958f3b75019593551f520126',
--     '[113.405861,34.769437,10]'
-- );

-- 示例4：无项目ID，查公共表
-- SELECT * FROM public.gis_electric_fence_check_point(
--     '',
--     '{"type":"Point","coordinates":[113.405861,34.769437,10000]}'
-- );

-- 示例5：无项目ID（NULL），查公共表
-- SELECT * FROM public.gis_electric_fence_check_point(
--     NULL,
--     '{"type":"Point","coordinates":[113.405861,34.769437]}'
-- );

-- =============================================================================
-- 3. gis_electric_fence_check_line
-- 功能：检测航线是否直接穿越电子围栏。
-- 入参：p_project_id, p_line_geojson
-- 返回：code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
-- =============================================================================

-- SELECT * FROM public.gis_electric_fence_check_line(
--     '2c95908e958f3b75019593551f520126',
--     '{
--         "type":"LineString",
--         "coordinates":[
--             [113.405861,34.769437,120],
--             [113.4654075,34.8085025,120]
--         ]
--     }'
-- );

-- 示例2：坐标数组格式 [[lng,lat,alt], [lng,lat,alt]]
-- SELECT * FROM public.gis_electric_fence_check_line(
--     '2c95908e958f3b75019593551f520126',
--     '[
--         [113.405861,34.769437,120],
--         [113.4654075,34.8085025,120]
--     ]'
-- );

-- 示例3：Feature格式
-- SELECT * FROM public.gis_electric_fence_check_line(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Feature","geometry":{"type":"LineString","coordinates":[[113.405861,34.769437,120],[113.4654075,34.8085025,120]]},"properties":{}}'
-- );

-- =============================================================================
-- 4. gis_electric_fence_buffer
-- 功能：生成围栏缓冲区/3D立体几何。
-- 重载1：gis_electric_fence_buffer(p_fence_id, p_buffer_radius, p_return_geojson)
-- 重载2：gis_electric_fence_buffer(p_project_id, p_fence_id, p_buffer_radius, p_return_geojson)
-- p_return_geojson 默认 false；需要返回GeoJSON时传 true
-- 返回：code, msg, ischeck, check_type, electric_id, fence_type, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
-- =============================================================================

-- 示例1：旧版调用，按围栏ID生成缓冲
-- SELECT * FROM public.gis_electric_fence_buffer(
--     '2052290479526682626',
--     30,
--     true
-- );

-- 示例2：新版调用，项目ID + 指定围栏ID
-- SELECT * FROM public.gis_electric_fence_buffer(
--     '2c95908e958f3b75019593551f520126',
--     '2052290479526682626',
--     30,
--     true
-- );

-- 示例3：新版调用，p_fence_id 为空，返回项目/公共范围内全部围栏
-- SELECT * FROM public.gis_electric_fence_buffer(
--     '2c95908e958f3b75019593551f520126',
--     NULL,
--     30,
--     false
-- );

-- 示例4：新版调用，无项目ID且 p_fence_id 为空，返回公共表全部围栏
-- SELECT * FROM public.gis_electric_fence_buffer(
--     NULL,
--     NULL,
--     0,
--     false
-- );

-- =============================================================================
-- 5. gis_electric_fence_check_point_buffer
-- 功能：检测航点是否闯入电子围栏缓冲区。
-- 入参：p_project_id, p_point_geojson, p_buffer_radius, p_return_geojson
-- 返回：code, msg, ischeck, check_type, electric_id, fence_type, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
-- =============================================================================

-- 示例1：Point/PointZ GeoJSON
-- SELECT * FROM public.gis_electric_fence_check_point_buffer(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Point","coordinates":[113.405861,34.769437,120]}',
--     10,
--     true
-- );

-- 示例2：坐标数组格式 [lng,lat,alt]
-- SELECT * FROM public.gis_electric_fence_check_point_buffer(
--     '2c95908e958f3b75019593551f520126',
--     '[113.405861,34.769437,120]',
--     10,
--     false
-- );

-- 示例3：无项目ID，查公共表
-- SELECT * FROM public.gis_electric_fence_check_point_buffer(
--     NULL,
--     '{"type":"Point","coordinates":[113.405861,34.769437,120]}',
--     10,
--     false
-- );

-- =============================================================================
-- 6. gis_electric_fence_check_line_buffer
-- 功能：检测航线是否闯入电子围栏缓冲区。
-- 重载1：gis_electric_fence_check_line_buffer(p_line_geojson, p_buffer_radius, p_return_geojson)
-- 重载2：gis_electric_fence_check_line_buffer(p_project_id, p_line_geojson, p_buffer_radius, p_return_geojson)
-- p_return_geojson 默认 false；需要返回GeoJSON时传 true
-- 返回：code, msg, ischeck, check_type, electric_id, fence_type, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
-- =============================================================================

-- 示例1：旧版调用，无项目ID
-- SELECT * FROM public.gis_electric_fence_check_line_buffer(
--     '{
--         "type":"LineString",
--         "coordinates":[
--             [113.405861,34.769437,120],
--             [113.4654075,34.8085025,120]
--         ]
--     }',
--     10,
--     true
-- );

-- 示例2：新版调用，带项目ID
-- SELECT * FROM public.gis_electric_fence_check_line_buffer(
--     '2c95908e958f3b75019593551f520126',
--     '{
--         "type":"LineString",
--         "coordinates":[
--             [113.405861,34.769437,120],
--             [113.4654075,34.8085025,120]
--         ]
--     }',
--     10,
--     true
-- );

-- 示例3：新版调用，坐标数组格式 [[lng,lat,alt], [lng,lat,alt]]
-- SELECT * FROM public.gis_electric_fence_check_line_buffer(
--     '2c95908e958f3b75019593551f520126',
--     '[
--         [113.405861,34.769437,120],
--         [113.4654075,34.8085025,120]
--     ]',
--     10,
--     false
-- );
