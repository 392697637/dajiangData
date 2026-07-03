-- =============================================================================
-- 2.2电子围栏校验-函数..sql
--   gis_check_electric_fence                校验电子围栏冲突
--   gis_electric_fence_check_point          检测航点落入围栏
--   gis_electric_fence_check_line           检测航线穿越围栏
--   gis_electric_fence_buffer               生成电子围栏缓冲区
--   gis_electric_fence_check_line_buffer    检测航线缓冲区冲突
--
-- =============================================================================

-- =============================================
-- 函数名称： gis_check_electric_fence
-- 函数功能： 电子围栏空间冲突校验（禁飞区/管控区/试飞区互斥规则校验）
-- 函数描述： 1. 接收项目ID、围栏类型、坐标GeoJSON三个独立参数
--            2. 自动标准化几何数据（2D、修复、设置坐标系）
--            3. 按类型执行空间冲突校验：
--               - 禁飞区(1)：无需校验，直接通过
--               - 管控区(2)：禁止与禁飞区(1)相交/包含
--               - 试飞区(3)：禁止与禁飞区(1)、管控区(2)相交/包含
--            4. 支持项目专属围栏表 + 公共围栏表双重校验
--            5. 返回冲突详情：类型、表名、几何、提示文案
-- 函数说明： 依赖PostGIS空间扩展，坐标系使用WGS84(4326)
-- 参数说明：
--   p_project_id    varchar     项目ID（可选），用于区分项目专属围栏表
--   p_fence_type    text        围栏类型：1=禁飞区，2=管控区，3=试飞区
--   p_lng_lat_alt   text        坐标GeoJSON字符串，支持Feature或直接Geometry
-- 返回值： 标准TABLE结构
--   code               integer     返回码：200成功，400参数错误，500空间冲突
--   table_name         text        冲突对应的表名
--   orig_fence_type    text        传入的原始围栏类型
--   conflict_fence_type text       冲突的围栏类型(数字)
--   msg                text        详细提示信息（区分相交/包含 + 中文名称）
--   new_geom           text        标准化后的新围栏几何JSON
--   conflict_geom      text        冲突围栏的几何JSON
-- 适用场景： 新增/编辑电子围栏前的空间合规性校验，防止区域重叠冲突
-- =============================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_check_electric_fence');

-- =============================================================================
-- 函数介绍：gis_check_electric_fence
-- 主要作用：校验新建或编辑电子围栏时，是否与已有围栏存在空间冲突或规则冲突。
-- 入参说明：p_project_id 为项目ID；p_geom_json 为待校验围栏GeoJSON；p_fence_type 为围栏类型。
-- 返回说明：返回状态码、提示信息以及冲突明细，供保存围栏前进行业务拦截。
-- 注意事项：依赖PostGIS空间判断；校验逻辑会结合全局围栏和项目专属围栏数据。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_check_electric_fence(
  IN p_project_id varchar,      -- 入参1：项目ID（可选），用于区分项目专属围栏表
  IN p_fence_type text,         -- 入参2：围栏类型，1=禁飞区，2=管控区，3=试飞区
  IN p_lng_lat_alt text         -- 入参3：坐标GeoJSON字符串，支持Feature或直接Geometry
)
RETURNS TABLE (
  code integer,           -- 返回码：200成功，400参数错误，500空间冲突
  table_name text,        -- 冲突对应的表名
  orig_fence_type text,   -- 传入的原始围栏类型
  conflict_fence_type text,-- 冲突的围栏类型(数字)
  msg text,               -- 详细提示信息（区分相交/包含 + 中文名称）
  new_geom text,          -- 标准化后的新围栏几何JSON
  conflict_geom text      -- 冲突围栏的几何JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_fence_type text;          -- 处理后的围栏类型(数字)
  v_orig_fence_type text;     -- 原始传入的围栏类型(数字)
  v_geojson_str text;         -- 传入的坐标GeoJSON字符串
  v_new_geom geometry;        -- 标准化处理后的几何对象
  v_geojson_json jsonb;        -- lngLatAlt解析后的JSON对象，兼容Feature和直接Geometry
  v_new_geom_json text;       -- 新几何的GeoJSON格式字符串
  v_sql text;                 -- 动态执行SQL语句
  v_has_conflict boolean;     -- 是否存在冲突标记
  v_is_contains boolean;     -- 是否为包含关系标记
  v_conflict_name text;       -- 冲突围栏中文名称
  v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
BEGIN
  -- 初始化冲突标记：默认无冲突
  v_has_conflict := false;

  -- ===================== 1. 解析入参 =====================
  -- 围栏类型从第二个参数直接传入，去除前后空格后参与规则判断。
  v_orig_fence_type := trim(p_fence_type);
  v_fence_type := v_orig_fence_type;
  -- 坐标GeoJSON从第三个参数直接传入，兼容Feature和直接Geometry。
  v_geojson_str := trim(p_lng_lat_alt);

  -- ===================== 2. 基础参数非空校验 =====================
  -- 校验围栏类型是否为空
  IF v_fence_type IS NULL OR v_fence_type = '' THEN
    code := 400;                     -- 参数错误码
    table_name := '';                -- 无表名
    orig_fence_type := v_orig_fence_type; -- 原始围栏类型
    conflict_fence_type := '';       -- 无冲突类型
    msg := format('参数校验失败：围栏类型不能为空，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3)); -- 错误提示
    new_geom := null;                -- 无几何数据
    conflict_geom := null;           -- 无冲突几何
    RETURN NEXT;  -- 返回结果行
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
    new_geom := null;
    conflict_geom := null;
    RETURN NEXT;
    RETURN;
  END IF;

  -- ===================== 3. 几何标准化处理 =====================
  -- 将GeoJSON字符串转为JSON对象。
  -- lngLatAlt可能传Feature，也可能直接传Polygon/MultiPolygon等Geometry；这里统一兼容两种格式。
  v_geojson_json := v_geojson_str::jsonb;
  IF v_geojson_json ->> 'type' = 'Feature' THEN
    -- Feature格式：几何数据位于geometry节点。
    v_new_geom := ST_GeomFromGeoJSON(v_geojson_json ->> 'geometry');
  ELSE
    -- Geometry格式：整个JSON就是几何对象。
    v_new_geom := ST_GeomFromGeoJSON(v_geojson_json::text);
  END IF;
  -- 强制转为2D几何（剔除高度值） + 自动修复非法几何（自相交、不闭合等）
  v_new_geom := ST_MakeValid(ST_Force2D(v_new_geom));
  -- 设置坐标系为EPSG:4326（WGS84经纬度坐标系）
  v_new_geom := ST_SetSRID(v_new_geom, 4326);
  -- 将标准化处理后的几何对象转回GeoJSON字符串，用于返回
  v_new_geom_json := ST_AsGeoJSON(v_new_geom);

  -- ===================== 4. 禁飞区(1) 直接校验通过 =====================
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

  -- ===================== 5. 试飞区(3) 冲突校验 =====================
  -- 业务规则：试飞区禁止与禁飞区(1)、管控区(2)发生相交/包含关系
  IF v_fence_type = '3' THEN
    -- 拼接动态SQL：优先查询项目专属围栏表
    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
      -- 使用format的%L返回表名文本，%I安全引用动态项目表名。
      -- 项目专属表字段名为 fence_type，用于判断冲突围栏类型。
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
      -- 无项目ID时，查询公共电子围栏表
      -- 公共项目围栏表同样使用 fence_type 字段。
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

      -- 围栏类型数字映射为中文名称
      CASE conflict_fence_type
        WHEN '1' THEN v_conflict_name := '禁飞区';
        WHEN '2' THEN v_conflict_name := '管控区';
        ELSE v_conflict_name := '未知类型围栏';
      END CASE;

      -- 根据空间关系（包含/相交）返回不同提示文案
      IF v_is_contains THEN
        msg := format('试飞区与%s发生包含冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      ELSE
        msg := format('试飞区与%s发生相交冲突，执行时间 %s 秒',
          v_conflict_name, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
      END IF;
      new_geom := v_new_geom_json;  -- 返回标准化后的新几何
      RETURN NEXT;                  -- 返回当前冲突行
    END LOOP;

    -- 遍历公共围栏表 bo_electric_fence，继续校验冲突
    v_sql := 'SELECT ''bo_electric_fence'', fence_type, ST_AsGeoJSON(geom),
              ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
              FROM bo_electric_fence
              WHERE fence_type IN (''1'',''2'') AND project_id = $2
              AND ST_Intersects($1, ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326))';
    FOR table_name, conflict_fence_type, conflict_geom, v_is_contains IN EXECUTE v_sql USING v_new_geom, p_project_id
    LOOP
      v_has_conflict := true;
      code := 200;
      orig_fence_type := v_orig_fence_type;

      -- 冲突类型转中文
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

  -- ===================== 6. 管控区(2) 冲突校验 =====================
  -- 业务规则：管控区禁止与禁飞区(1)发生相交/包含关系
  ELSIF v_fence_type = '2' THEN
    -- 拼接动态SQL：优先查询项目专属围栏表
    IF p_project_id IS NOT NULL AND trim(p_project_id) <> '' THEN
      -- 项目专属表名动态生成，必须使用%I作为标识符引用；表内围栏类型字段为 fence_type。
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

    -- 校验公共表 bo_electric_fence 中的禁飞区冲突
    v_sql := 'SELECT ''bo_electric_fence'', fence_type, ST_AsGeoJSON(geom),
              ST_Contains(ST_SetSRID(ST_MakeValid(ST_Force2D(geom)), 4326), $1) as is_contains
              FROM bo_electric_fence
              WHERE fence_type = ''1'' AND project_id = $2
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
  -- 传入的围栏类型不是1/2/3，返回参数错误
  ELSE
    code := 400;
    table_name := '';
    orig_fence_type := v_orig_fence_type;
    conflict_fence_type := '';
    msg := format('参数校验失败：不支持的围栏类型，执行时间 %s 秒',
      ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    new_geom := null;
    conflict_geom := null;
    RETURN NEXT;
    RETURN;
  END IF;

  -- ===================== 8. 无冲突返回成功 =====================
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
  new_geom := null;
  conflict_geom := null;
  RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_check_electric_fence(varchar, text, text) IS '校验电子围栏冲突';


-- =============================================================================
-- 电子围栏线判断、点判断、缓冲、点缓冲判断、线缓冲判断、 
-- =============================================================================

-- ====================================================================
-- 函数名称： gis_electric_fence_check_point
-- 函数功能： 无人机定位点 3D 电子围栏碰撞检测（无缓冲，纯原始围栏判断）
-- 函数描述： 1. 传入 项目ID + 点的GeoJSON（支持Feature和Point格式）
--            2. 高度=0（默认）：仅执行2D平面包含判断
--            3. 高度>0：执行3D立体包含判断（Z从0到围栏height）
--            4. 项目ID不为空时查询 gis_electric_fence_{project_id} 表（注意表不存在的情况）
--            5. 项目ID为空时查询 bo_electric_fence 表
--            6. 只查询禁飞区、启用状态、未删除的有效围栏
--            7. 返回标准格式结果集，与航线检测函数完全通用，前端可直接渲染
-- 函数说明： 依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)
-- 参数说明：
--   p_project_id    text            输入参数：项目ID（可选），为空则查询公共表
--   p_point_geojson text            输入参数：点的GeoJSON字符串（必填，支持Feature和Point格式）
-- 返回值： 标准TABLE结构，与航线检测函数完全一致
--   code      integer    状态码：200=执行成功 400=参数错误 500=执行异常
--   msg       varchar    状态描述信息
--   id        varchar(32) 围栏ID
--   geom_geojson json    原始围栏几何的GeoJSON
-- 函数注意：
--   1. 表 bo_electric_fence 必须存在，且包含字段：id, geom, height, del_flag, fence_type, status
--   2. 2D判断使用 ST_Contains，3D判断结合平面+高度区间校验
--   3. 高度默认0时，不参与高度计算，仅判断平面是否在围栏内
-- 适用场景： 无人机实时定位是否闯入禁飞区/管控区
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_check_point');

-- 创建函数
-- =============================================================================
-- 函数介绍：gis_electric_fence_check_point
-- 主要作用：判断单个航点是否落入启用中的禁飞区、管控区等电子围栏范围。
-- 入参说明：p_point_json 为航点Point/PointZ GeoJSON；p_project_id 用于限定项目围栏范围。
-- 返回说明：返回命中状态、围栏类型、围栏名称和提示信息，供航点合法性校验使用。
-- 注意事项：点位坐标默认WGS84；高度规则需结合围栏数据中的高度字段判断。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_point(
    p_project_id text,
    p_point_geojson text
)
RETURNS TABLE (
    code integer,
    msg varchar,
    id varchar(32),
    geom_geojson json
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_point geometry;          -- 存储生成的空间点几何对象
    v_geojson_json jsonb;      -- 解析后的GeoJSON对象
    v_z double precision;      -- 高度值
    v_table_name text;         -- 动态表名
    v_sql text;                -- 动态SQL语句
    v_table_exists boolean;    -- 表是否存在
    v_found boolean;           -- 是否找到匹配的围栏
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
BEGIN
    -- =============================================
    -- 【400 参数错误】第一步：校验点GeoJSON是否为空
    -- =============================================
    IF p_point_geojson IS NULL OR p_point_geojson = '' THEN
        RETURN QUERY SELECT
            400, format('点的GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- =============================================
    -- 解析GeoJSON字符串
    -- =============================================
    BEGIN
        v_geojson_json := p_point_geojson::jsonb;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400, format('点的GeoJSON格式错误，执行时间 %s 秒',
                    ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
                NULL::varchar, NULL::json;
            RETURN;
    END;

    -- =============================================
    -- 从GeoJSON中提取点几何和高度
    -- =============================================
    BEGIN
        IF v_geojson_json ->> 'type' = 'Feature' THEN
            -- Feature格式
            v_point := ST_GeomFromGeoJSON(v_geojson_json ->> 'geometry');
            -- 尝试从Feature的properties或几何的Z坐标获取高度
            v_z := COALESCE(
                (v_geojson_json -> 'properties' ->> 'z')::double precision,
                (v_geojson_json -> 'properties' ->> 'height')::double precision,
                ST_Z(v_point),
                0
            );
        ELSE
            -- 直接Geometry格式
            v_point := ST_GeomFromGeoJSON(v_geojson_json::text);
            v_z := COALESCE(ST_Z(v_point), 0);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400, format('点的GeoJSON解析失败，执行时间 %s 秒',
                    ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
                NULL::varchar, NULL::json;
            RETURN;
    END;

    -- =============================================
    -- 校验点类型
    -- =============================================
    IF ST_GeometryType(v_point) NOT IN ('ST_Point') THEN
        RETURN QUERY SELECT
            400, format('GeoJSON必须是Point类型，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- =============================================
    -- 标准化几何（设置坐标系）
    -- =============================================
    v_point := ST_SetSRID(ST_Force2D(v_point), 4326);

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
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public'
            AND table_name = v_table_name
        ) INTO v_table_exists;

        IF v_table_exists THEN
            -- 项目表存在，使用UNION ALL连接项目表和公共表
            v_sql := format('
                SELECT
                    200 AS code,
                    format(''当前位置在禁飞区内，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))::varchar AS msg,
                    f.id::varchar(32),
                    ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
                FROM %I f
                WHERE
                    f.fence_type = ''1''
                    AND f.height >= 0
                    AND ST_Contains(ST_SetSRID(f.geom, 4326), $1)
                    AND (
                        $2 = 0
                        OR
                        ($2 > 0 AND $2 <= COALESCE(f.height, 0))
                    )
                UNION ALL
                SELECT
                    200 AS code,
                    format(''当前位置在禁飞区内，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))::varchar AS msg,
                    f.id::varchar(32),
                    ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
                FROM bo_electric_fence f
                WHERE
                    f.fence_type = ''1''
                    AND f.status = ''1''
                    AND f.del_flag = false
                    AND f.height >= 0
                    AND ST_Contains(ST_SetSRID(f.geom, 4326), $1)
                    AND (
                        $2 = 0
                        OR
                        ($2 > 0 AND $2 <= COALESCE(f.height, 0))
                    )',
                v_table_name
            );
        ELSE
            -- 项目表不存在，只查询公共表
            v_sql := '
                SELECT
                    200 AS code,
                    format(''当前位置在禁飞区内，执行时间 %s 秒'', ROUND(EXTRACT(epoch FROM clock_timestamp() - $3)::numeric, 3))::varchar AS msg,
                    f.id::varchar(32),
                    ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
                FROM bo_electric_fence f
                WHERE
                    f.fence_type = ''1''
                    AND f.status = ''1''
                    AND f.del_flag = false
                    AND f.height >= 0
                    AND ST_Contains(ST_SetSRID(f.geom, 4326), $1)
                    AND (
                        $2 = 0
                        OR
                        ($2 > 0 AND $2 <= COALESCE(f.height, 0))
                    )';
        END IF;

        -- 执行统一的查询
        RETURN QUERY EXECUTE v_sql USING v_point, v_z, v_start_time;

        -- 检查是否找到结果
        IF FOUND THEN
            v_found := true;
        END IF;
    ELSE
        -- 没有项目ID，只查询公共表
        RETURN QUERY
        SELECT
            200 AS code,
            format('当前位置在禁飞区内，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar AS msg,
            f.id::varchar(32),
            ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
        FROM bo_electric_fence f
        WHERE
            f.fence_type = '1'        -- 围栏类型：禁飞区
            AND f.status = '1'        -- 状态：启用
            AND f.del_flag = false    -- 未删除
            AND f.height >= 0         -- 围栏高度合法
            AND ST_Contains(ST_SetSRID(f.geom, 4326), v_point) -- 平面包含判断
            AND (
                v_z = 0
                OR
                (v_z > 0 AND v_z <= COALESCE(f.height, 0))
            );

        -- 检查是否找到结果
        IF FOUND THEN
            v_found := true;
        END IF;
    END IF;

    -- =============================================
    -- 【200 成功】未检测到闯入任何禁飞区
    -- =============================================
    IF NOT v_found THEN
        RETURN QUERY SELECT
            200, format('当前位置不在禁飞区内，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

-- =============================================
-- 【500 服务异常】系统/数据库/空间函数异常
-- =============================================
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500, format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_point(text, text) IS '检测航点落入围栏';
 
-- ====================================================================================
-- 函数名称： gis_electric_fence_check_line
-- 函数功能： 无人机航线/轨迹 3D 电子围栏碰撞检测 
-- 函数描述： 1. 传入 3D 航线 GeoJSON（LineString）
--            2. 自动将 2D 围栏拉伸为 3D 立体棱柱（Z 从 0 到 围栏 height）
--            3. 执行 3D 空间相交判断：航线穿过围栏 → 返回该围栏信息
--            4. 只查询未删除、有效状态的围栏
--            5. 返回标准格式结果集，前端可直接渲染
-- 函数说明： 依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)
-- 参数说明：
--   p_line_geojson     text           输入参数：线路/轨迹/线段的GeoJSON字符串（必填）
-- 返回值： 标准TABLE结构，包含状态码、提示信息、围栏ID、各类几何GeoJSON
--   code      integer    状态码：200=执行成功 400=参数错误/未查询到数据 500=执行异常
--   msg       varchar    状态描述信息
--   id        varchar(32) 围栏ID
--   geom_geojson json    原始围栏几何的GeoJSON
-- 适用场景： 无人机航线闯入禁飞区/管控区实时检测
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_check_line');

-- 创建函数
-- =============================================================================
-- 函数介绍：gis_electric_fence_check_line
-- 主要作用：检测输入航线是否直接穿越或接触启用中的电子围栏区域。
-- 入参说明：p_line_json 为航线LineString/LineStringZ GeoJSON。
-- 返回说明：返回是否冲突、命中围栏属性和相交结果，供航线提交前快速校验。
-- 注意事项：本函数不额外扩航线缓冲，如需安全距离判断请使用带buffer的函数。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_line(
    p_line_geojson text
)
RETURNS TABLE (
    code integer,
    msg varchar,
    id varchar(32),
    geom_geojson json
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_line geometry;       -- 解析后的航线几何体
    v_fence_3d geometry;  -- 3D围栏几何体
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
BEGIN
    -- 1. 参数校验
    IF p_line_geojson IS NULL OR p_line_geojson = '' THEN
        RETURN QUERY SELECT
            400, format('航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- 2. 解析GeoJSON为几何体，并设置坐标系WGS84(4326)
    BEGIN
        v_line := ST_SetSRID(ST_GeomFromGeoJSON(p_line_geojson), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400, format('GeoJSON格式解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
                NULL::varchar, NULL::json;
            RETURN;
    END;

    -- 3. 校验输入必须是线要素(LineString/MultiLineString)
    IF ST_GeometryType(v_line) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT
            400, format('输入几何体必须是线类型(LineString)，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- 4. 核心查询：3D电子围栏碰撞检测
    RETURN QUERY
    SELECT
        200 AS code,
        format('检测到航线闯入电子围栏，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar AS msg,
        f.id,
        ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
    FROM bo_electric_fence f
    WHERE
        -- 未删除的围栏
        f.del_flag = false
        -- 围栏高度不能为空/负数
        AND f.height > 0
        -- 3D空间相交判断（核心）
        AND ST_3DIntersects(
            -- 航线几何体
            v_line,
            -- 【正确】将2D面拉伸为3D棱柱（立体围栏）
            ST_Extrude(
                ST_Force3DZ(ST_SetSRID(f.geom, 4326), 0),
                0, 0, COALESCE(f.height, 0)
            )
        );

    -- 5. 无碰撞时返回空结果+状态200
    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200, format('航线未闯入任何电子围栏，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
    END IF;

-- 异常捕获
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500, format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_line(text) IS '检测航线穿越围栏';


-- ====================================================================================
-- 函数名称： gis_electric_fence_buffer
-- 函数功能： 根据电子围栏ID和缓冲半径，计算围栏2D缓冲面、构建3D立体几何体，并返回GeoJSON格式数据
-- 函数描述： 1. 校验入参围栏ID是否为空
--            2. 从电子围栏表查询有效围栏数据（未删除）
--            3. 基于WGS84(4326)坐标系计算指定半径的2D平面缓冲区
--            4. 基于2D缓冲面生成底部Z=0、顶部Z=围栏高度的3D立体几何体
--            5. 统一返回标准状态码+几何数据的GeoJSON
-- 函数说明： 依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)，平面缓冲使用墨卡托(3857)计算
-- 参数说明：
--   p_fence_id     varchar(32)   输入参数：电子围栏唯一ID（必填）
--   p_buffer_radius double precision 输入参数：缓冲半径（单位：米），传0则不做缓冲，直接使用原始围栏
-- 返回值： 标准TABLE结构，包含状态码、提示信息、围栏ID、各类几何GeoJSON
--   code      integer    状态码：200=执行成功 400=参数错误/未查询到数据 500=执行异常
-- 200：执行成功，返回完整几何数据
-- 400：参数为空 / 无有效围栏数据（业务异常）
-- 500：SQL 执行异常、表不存在、字段错误等（系统异常）
--   msg       varchar    状态描述信息
-- 返回策略：
--   code=200 表示函数正常完成。
--   code=400 表示输入参数非法。
--   code=500 表示执行过程中出现异常。
--   msg 中包含执行时间，以及具体执行说明。
--   id        varchar(32) 围栏ID
--   geom_geojson json    原始围栏几何的GeoJSON
--   buffer_2d_geojson json 2D缓冲面几何的GeoJSON
--   solid_3d_geojson json 3D立体几何体的GeoJSON
-- 函数注意：
--   1. 表 bo_electric_fence 必须存在，且包含字段：id, geom, height, del_flag
--   2. geom 字段为PostGIS几何类型，height 为围栏高度（数字类型）
--   3. 缓冲半径单位为**米**，坐标系转换保证距离计算准确
--   4. 3D几何体为：底部(Z=0) + 顶部(Z=围栏高度) 的集合几何体
-- 适用场景： 电子围栏可视化、GIS空间分析、前端地图渲染（2D/3D围栏展示）
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_buffer');

-- =============================================================================
-- 函数介绍：gis_electric_fence_buffer
-- 主要作用：根据电子围栏ID和缓冲距离，计算围栏外扩后的缓冲面几何。
-- 入参说明：p_fence_id 为围栏ID；p_buffer_m 为缓冲距离，单位米。
-- 返回说明：返回缓冲区GeoJSON、原始围栏信息和执行状态，便于前端展示或后续碰撞判断。
-- 注意事项：缓冲按米计算，内部会转换到适合平面距离计算的坐标系后再转回WGS84。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_buffer(
    p_fence_id varchar(32),        -- 入参1：围栏ID
    p_buffer_radius double precision -- 入参2：缓冲半径（米）
)
-- 定义函数返回的表结构（字段顺序、类型必须严格匹配）
RETURNS TABLE (
    code integer,
    msg varchar,
    id varchar(32),
    geom_geojson json,
    buffer_2d_geojson json,
    solid_3d_geojson json
)
-- 函数语言：PL/pgSQL（PostgreSQL过程语言）
LANGUAGE plpgsql
-- 稳定性声明：STABLE 表示函数在同一事务中，相同入参返回相同结果（无写入操作）
STABLE
AS $$
DECLARE
    -- 定义变量：存储2D缓冲后的几何对象
    v_buffer_geom geometry;
    -- 定义变量：存储单条围栏记录（类型与表 bo_electric_fence 完全一致）
    v_fence_record bo_electric_fence%ROWTYPE;
    -- 定义变量：存储3D立体几何对象
    v_3d_geom geometry;
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
BEGIN
    -- ==============================================
    -- 1. 入参合法性校验：围栏ID 不能为空/空字符串
    -- ==============================================
    IF p_fence_id IS NULL OR p_fence_id = '' THEN
        -- 返回400：参数错误，所有几何字段置空
        RETURN QUERY SELECT
            400, format('围栏ID不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json, NULL::json, NULL::json;
        -- 终止函数执行
        RETURN;
    END IF;

    -- ==============================================
    -- 2. 查询有效围栏数据（未逻辑删除）
    -- ==============================================
    SELECT * 
    INTO v_fence_record  -- 查询结果存入围栏记录变量
    FROM bo_electric_fence f
    WHERE f.id = p_fence_id  -- 按围栏ID匹配
      AND f.del_flag = false; -- 只查询未删除的数据

    -- ==============================================
    -- 3. 校验：未查询到有效围栏数据
    -- ==============================================
    IF v_fence_record.id IS NULL THEN
        -- 返回400：无数据，所有几何字段置空
        RETURN QUERY SELECT
            400, format('未查询到有效围栏数据，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json, NULL::json, NULL::json;
        RETURN;
    END IF;

    -- ==============================================
    -- 4. 计算2D缓冲几何（核心GIS逻辑）
    -- ==============================================
    SELECT
        CASE 
            -- 情况1：缓冲半径=0 → 直接使用原始围栏几何，设置坐标系4326(WGS84)
            WHEN p_buffer_radius = 0 THEN 
                ST_SetSRID(v_fence_record.geom, 4326)
            -- 情况2：半径>0 → 计算缓冲区
            ELSE 
                -- 步骤：4326转3857（墨卡托，米单位）→ 做缓冲 → 转回4326
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
    -- 5. 构建3D立体几何体（底部+顶部）
    -- ==============================================
    SELECT
        -- 转换为多几何对象（兼容前端渲染）
        ST_Multi(
            -- 合并两个3D面：底部(Z=0) + 顶部(Z=围栏高度)
            ST_Collect(
                -- 底部面：Z坐标=0
                ST_Force3DZ(v_buffer_geom, 0),
                -- 顶部面：Z坐标=围栏高度（空值则用0）
                ST_Force3DZ(v_buffer_geom, COALESCE(v_fence_record.height, 0))
            )
        )
    INTO v_3d_geom; -- 结果存入3D几何变量

    -- ==============================================
    -- 6. 执行成功：返回200 + 所有几何数据
    -- ==============================================
    RETURN QUERY SELECT
        200,                        -- 状态码：成功
        format('成功，执行时间 %s 秒',
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,            -- 提示信息
        v_fence_record.id::varchar, -- 围栏ID
        -- 原始围栏几何 → GeoJSON
        ST_AsGeoJSON(ST_SetSRID(v_fence_record.geom, 4326))::json,
        -- 2D缓冲几何 → GeoJSON
        ST_AsGeoJSON(v_buffer_geom)::json,
        -- 3D立体几何 → GeoJSON
        ST_AsGeoJSON(v_3d_geom)::json;

-- ==============================================
-- 异常捕获：执行过程中出现任何错误，返回500
-- ==============================================
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500,                                -- 状态码：服务异常
            format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,  -- 异常信息（SQLERRM=系统错误描述）
            NULL::varchar, NULL::json, NULL::json, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_buffer(varchar, double precision) IS '生成电子围栏缓冲区';


 
-- ====================================================================================
-- 函数名称： gis_electric_fence_check_line_buffer
-- 函数功能： 航线/轨迹/线段 穿入电子围栏检测（支持2D缓冲 + 3D立体相交判断）
-- 函数描述： 1. 接收线路/轨迹GeoJSON字符串与缓冲半径
--            2. 半径=0 → 使用原始围栏几何判断相交
--            3. 半径>0 → 先对围栏做外扩缓冲，再判断
--            4. 自动将围栏拉伸为3D立体（高度=围栏height字段）
--            5. 执行3D空间相交判断：线路穿过围栏 → 返回该围栏完整信息
--            6. 无任何相交 → 返回空结果集
-- 函数说明： 依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)，平面缓冲使用墨卡托(3857)计算
--            内部复用 gis_electric_fence_buffer 函数获取完整围栏+缓冲+3D数据
-- 参数说明：
--   p_line_geojson     text           输入参数：线路/轨迹/线段的GeoJSON字符串（必填）
--   p_buffer_radius    double precision 输入参数：缓冲半径（单位：米），默认0不缓冲
-- 返回值： 标准TABLE结构，包含状态码、提示信息、围栏ID、各类几何GeoJSON
--   code      integer    状态码：200=执行成功 400=参数错误/未查询到数据 500=执行异常
--   msg       varchar    状态描述信息
--   id        varchar(32) 围栏ID
--   geom_geojson json    原始围栏几何的GeoJSON
--   buffer_2d_geojson json 2D缓冲面几何的GeoJSON
--   solid_3d_geojson json 3D立体几何体的GeoJSON
-- 函数注意：
--   1. 依赖函数：gis_electric_fence_buffer 必须提前创建
--   2. 表 bo_electric_fence 必须存在，且包含字段：id, geom, height, del_flag
--   3. 3D判断使用 ST_3DIntersects，支持带高度的航线/轨迹检测
--   4. 缓冲半径单位为**米**，坐标系转换保证距离计算准确
-- 适用场景： 无人机航线规划、飞行轨迹闯入禁飞/管控/试飞区自动检测
-- ====================================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_electric_fence_check_line_buffer');

-- 创建函数
-- =============================================================================
-- 函数介绍：gis_electric_fence_check_line_buffer
-- 主要作用：对输入航线先做缓冲，再检测缓冲区是否与电子围栏发生冲突。
-- 入参说明：p_line_json 为航线LineString/LineStringZ GeoJSON；p_buffer_m 为航线安全缓冲半径。
-- 返回说明：返回冲突状态、命中的围栏信息和相交几何，用于航线安全距离校验。
-- 注意事项：适合带安全裕度的航线校验；缓冲距离越大，命中范围越宽。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_line_buffer(
    p_line_geojson text,
    p_buffer_radius double precision DEFAULT 0
)
RETURNS TABLE (
    code integer,
    msg varchar,
    id varchar(32),
    geom_geojson json,
    buffer_2d_geojson json,
    solid_3d_geojson json
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_line geometry; -- 存储转换后的线路几何对象
    v_start_time timestamptz := clock_timestamp(); -- 函数开始时间，用于统一返回耗时
BEGIN
    -- ==============================================
    -- 1. GeoJSON线路解析：转换为PostGIS几何对象，强制设置4326坐标系
    -- ==============================================
    IF p_line_geojson IS NULL OR p_line_geojson = '' THEN
        RETURN QUERY SELECT
            400, format('航线GeoJSON不能为空，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json, NULL::json, NULL::json;
        RETURN;
    END IF;

    BEGIN
        v_line := ST_SetSRID(ST_GeomFromGeoJSON(p_line_geojson), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400, format('GeoJSON格式解析失败：%s，执行时间 %s 秒',
                    SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
                NULL::varchar, NULL::json, NULL::json, NULL::json;
            RETURN;
    END;

    -- ==============================================
    -- 2. 核心逻辑：查询所有与线路3D相交的有效围栏
    -- ==============================================
    RETURN QUERY
    SELECT
        res.code,
        format('%s，线检测执行时间 %s 秒',
            res.msg,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar AS msg,
        res.id,
        res.geom_geojson,
        res.buffer_2d_geojson,
        res.solid_3d_geojson
    FROM bo_electric_fence f,
         -- 计算围栏2D缓冲面
         LATERAL (
             SELECT
                 CASE WHEN p_buffer_radius = 0 THEN ST_SetSRID(f.geom, 4326)
                      ELSE ST_Transform(ST_Buffer(ST_Transform(ST_SetSRID(f.geom,4326),3857), p_buffer_radius), 4326)
                 END AS buf
         ) AS buf_data,
         -- 构建3D立体几何体（拉伸高度）
         LATERAL ST_Extrude(ST_Force3D(buf_data.buf), 0, 0, COALESCE(f.height, 0)) AS solid_geom,
         -- 调用已有缓冲函数，获取标准返回结构
         LATERAL gis_electric_fence_buffer(f.id, p_buffer_radius) AS res
    WHERE
        f.del_flag = false  -- 仅有效围栏
        AND ST_3DIntersects(v_line, solid_geom); -- 3D空间相交判断

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200, format('航线未闯入任何电子围栏，执行时间 %s 秒',
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json, NULL::json, NULL::json;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500, format('服务异常：%s，执行时间 %s 秒',
                SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            NULL::varchar, NULL::json, NULL::json, NULL::json;
END;
$$;
COMMENT ON FUNCTION public.gis_electric_fence_check_line_buffer(text, double precision) IS '检测航线缓冲区冲突';

 
 
 
-- 函数调用示例=============================================
-- 示例1：有项目ID，查询项目表，使用Point格式
-- SELECT * FROM gis_electric_fence_check_point(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Point","coordinates":[113.405861,34.769437,10000]}'
-- );

-- 示例2：有项目ID，查询项目表，使用Feature格式
-- SELECT * FROM gis_electric_fence_check_point(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Feature","geometry":{"type":"Point","coordinates":[113.405861,34.769437]},"properties":{"z":10000}}'
-- );

-- 示例3：无项目ID，查询公共表
-- SELECT * FROM gis_electric_fence_check_point(
--     '',
--     '{"type":"Point","coordinates":[113.405861,34.769437,10000]}'
-- );

-- 示例4：无项目ID（NULL），查询公共表
-- SELECT * FROM gis_electric_fence_check_point(
--     NULL,
--     '{"type":"Point","coordinates":[113.405861,34.769437]}'
-- );

-- =============================================================================
-- 调用示例
-- =============================================================================

-- SELECT * FROM gis_electric_fence_buffer('2052290479526682626', 30);

-- SELECT * FROM public.gis_electric_fence_check_line_buffer('{
--   "type":"LineString",
--   "coordinates":[
--     [113.405861,34.769437,120],
--     [113.405861,34.769437,120]
--   ]
-- }',10);

-- SELECT * FROM public.gis_electric_fence_check_line('{
--   "type":"LineString",
--   "coordinates":[
--     [113.405861,34.769437,120],
--     [113.405861,34.769437,120]
--   ]
-- }');

-- =============================================================================
-- gis_check_electric_fence 调用示例
-- =============================================================================

-- 示例1：新增试飞区(3)，传Feature格式的项目范围。
-- SELECT * FROM gis_check_electric_fence(
--   '2c95908e958f3b75019593551f520126',
--   '3',
--   '{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[113.289609,34.951427,0],[113.290607,34.615358,0],[113.979944,34.596458,0],[114.013926,34.930172,0]]]},"properties":{}}'
-- );

-- 示例2：新增试飞区(3)，直接传Geometry格式的北京全域矩形。
-- SELECT * FROM gis_check_electric_fence(
--   '2c95908e958f3b75019593551f520126',
--   '3',
--   '{"type":"Polygon","coordinates":[[[115.72,39.41],[117.51,39.41],[117.51,41.05],[115.72,41.05],[115.72,39.41]]]}'
-- );
 
