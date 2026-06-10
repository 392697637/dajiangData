-- 删除旧函数（如果存在），避免函数定义冲突
DROP FUNCTION IF EXISTS gis_check_electric_fence(jsonb, varchar);
DROP FUNCTION IF EXISTS gis_check_electric_fence(varchar, varchar, text);

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
CREATE OR REPLACE FUNCTION gis_check_electric_fence(
  IN p_project_id varchar,      -- 入参1：项目ID（可选），用于区分项目专属围栏表
  IN p_fence_type varchar,      -- 入参2：围栏类型，1=禁飞区，2=管控区，3=试飞区
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
    msg := '参数校验失败：围栏类型不能为空'; -- 错误提示
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
    msg := '参数校验失败：坐标信息不能为空';
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
    msg := '校验成功：禁飞区无需检测空间冲突';
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
      code := 500;                              -- 空间冲突错误码
      orig_fence_type := v_orig_fence_type;      -- 原始围栏类型

      -- 围栏类型数字映射为中文名称
      CASE conflict_fence_type
        WHEN '1' THEN v_conflict_name := '禁飞区';
        WHEN '2' THEN v_conflict_name := '管控区';
        ELSE v_conflict_name := '未知类型围栏';
      END CASE;

      -- 根据空间关系（包含/相交）返回不同提示文案
      IF v_is_contains THEN
        msg := format('试飞区与%s发生包含冲突', v_conflict_name);
      ELSE
        msg := format('试飞区与%s发生相交冲突', v_conflict_name);
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
      code := 500;
      orig_fence_type := v_orig_fence_type;

      -- 冲突类型转中文
      CASE conflict_fence_type
        WHEN '1' THEN v_conflict_name := '禁飞区';
        WHEN '2' THEN v_conflict_name := '管控区';
        ELSE v_conflict_name := '未知类型围栏';
      END CASE;

      -- 返回冲突提示信息
      IF v_is_contains THEN
        msg := format('试飞区与%s发生包含冲突', v_conflict_name);
      ELSE
        msg := format('试飞区与%s发生相交冲突', v_conflict_name);
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
      code := 500;
      orig_fence_type := v_orig_fence_type;
      v_conflict_name := '禁飞区'; -- 管控区只校验禁飞区，固定名称

      -- 根据空间关系返回提示
      IF v_is_contains THEN
        msg := format('管控区与%s发生包含冲突', v_conflict_name);
      ELSE
        msg := format('管控区与%s发生相交冲突', v_conflict_name);
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
      code := 500;
      orig_fence_type := v_orig_fence_type;
      v_conflict_name := '禁飞区';

      -- 返回冲突提示
      IF v_is_contains THEN
        msg := format('管控区与%s发生包含冲突', v_conflict_name);
      ELSE
        msg := format('管控区与%s发生相交冲突', v_conflict_name);
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
    msg := '参数校验失败：不支持的围栏类型';
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
    msg := '校验成功：未检测到相交、包含空间冲突';
    new_geom := v_new_geom_json;
    conflict_geom := null;
    RETURN NEXT;
  END IF;

-- ===================== 全局异常捕获 =====================
-- 捕获函数执行过程中所有未知异常，返回标准化错误信息
EXCEPTION WHEN OTHERS THEN
  code := 400;
  table_name := '';
  orig_fence_type := v_orig_fence_type;
  conflict_fence_type := '';
  msg := '系统异常：' || SQLERRM || ' | 错误码：' || SQLSTATE;
  new_geom := null;
  conflict_geom := null;
  RETURN NEXT;
END;
$$;


-- ========================================================================================校验电子围栏==========================================================================================
-- =============================================
-- 函数名称： gis_check_electric_fence
-- 函数功能： 电子围栏空间冲突校验（禁飞区/管控区/试飞区互斥规则校验）
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
-- 调用说明：
--   1. 第一个参数：project_id，用于校验项目专属围栏表 gis_electric_fence_{project_id} 及业务表 bo_electric_fence
--   2. 第二个参数：fenceType，1=禁飞区，2=管控区，3=试飞区
--   3. 第三个参数：lngLatAlt，支持GeoJSON Feature，也支持直接传Polygon/MultiPolygon等Geometry字符串
-- =============================================
-- 示例1：新增试飞区(3)，传Feature格式的项目范围。
SELECT * FROM gis_check_electric_fence(
  '2c95908e958f3b75019593551f520126',
  '3',
  '{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[113.289609,34.951427,0],[113.290607,34.615358,0],[113.979944,34.596458,0],[114.013926,34.930172,0]]]},"properties":{}}'
);

-- 示例2：新增试飞区(3)，直接传Geometry格式的北京全域矩形。
SELECT * FROM gis_check_electric_fence(
  '2c95908e958f3b75019593551f520126',
  '3',
  '{"type":"Polygon","coordinates":[[[115.72,39.41],[117.51,39.41],[117.51,41.05],[115.72,41.05],[115.72,39.41]]]}'
);


SELECT * FROM gis_check_electric_fence(
  '2c95908e958f3b75019593551f520126',
  '3',
  '{"type":"Polygon","coordinates":[[[115.72,39.41],[117.51,39.41],[117.51,41.05],[115.72,41.05],[115.72,39.41]]]}'
);