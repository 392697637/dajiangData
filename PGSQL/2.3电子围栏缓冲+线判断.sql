-- ==================================================================================== gis_electric_fence_buffer  根据电子围栏ID和缓冲半径，计算缓冲面==========================================================
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

-- 删除已存在的同名函数（避免函数重载冲突）
DROP FUNCTION IF EXISTS public.gis_electric_fence_buffer(varchar(32), double precision);

-- 创建/替换函数
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
BEGIN
    -- ==============================================
    -- 1. 入参合法性校验：围栏ID 不能为空/空字符串
    -- ==============================================
    IF p_fence_id IS NULL OR p_fence_id = '' THEN
        -- 返回400：参数错误，所有几何字段置空
        RETURN QUERY SELECT
            400, '围栏ID不能为空'::varchar,
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
            400, '未查询到有效围栏数据'::varchar,
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
        '成功'::varchar,            -- 提示信息
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
            ('服务异常：' || SQLERRM)::varchar,  -- 异常信息（SQLERRM=系统错误描述）
            NULL::varchar, NULL::json, NULL::json, NULL::json;
END;
$$;


-- 函数调用示例-------------------------------------------------------------------------------
-- SELECT * FROM gis_electric_fence_buffer('2052290479526682626', 30);

 
-- ==================================================================================== gis_electric_fence_check_line_buffer  线穿电子围栏检测+缓冲==========================================================
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

-- 删除函数
DROP FUNCTION IF EXISTS public.gis_electric_fence_check_line_buffer(text, double precision);

-- 创建函数
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
BEGIN
    -- ==============================================
    -- 1. GeoJSON线路解析：转换为PostGIS几何对象，强制设置4326坐标系
    -- ==============================================
    v_line := ST_SetSRID(ST_GeomFromGeoJSON(p_line_geojson), 4326);

    -- ==============================================
    -- 2. 核心逻辑：查询所有与线路3D相交的有效围栏
    -- ==============================================
    RETURN QUERY
    SELECT
        res.code,
        res.msg,
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

EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500, ('服务异常：' || SQLERRM)::varchar,
            NULL::varchar, NULL::json, NULL::json, NULL::json;
END;
$$;

 
-- 函数调用示例：线穿围栏检测-------------------------------------------------------------------------------
SELECT * FROM public.gis_electric_fence_check_line_buffer('{
  "type":"LineString",
  "coordinates":[
    [113.405861,34.769437,120],
    [113.405861,34.769437,120]
  ]
}',10);

 
 
-- ==================================================================================== gis_bo_electric_fence_check_line  线穿电子围栏检测==========================================================
-- ====================================================================================
-- 函数名称： gis_electric_fence_check_line
-- 函数功能： 无人机航线/轨迹 3D 电子围栏碰撞检测（无缓冲，纯原始围栏判断）
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

-- 删除函数
DROP FUNCTION IF EXISTS public.gis_electric_fence_check_line(text);

-- 创建函数
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
BEGIN
    -- 1. 参数校验
    IF p_line_geojson IS NULL OR p_line_geojson = '' THEN
        RETURN QUERY SELECT
            400, '航线GeoJSON不能为空'::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- 2. 解析GeoJSON为几何体，并设置坐标系WGS84(4326)
    BEGIN
        v_line := ST_SetSRID(ST_GeomFromGeoJSON(p_line_geojson), 4326);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT
                400, 'GeoJSON格式解析失败：' || SQLERRM::varchar,
                NULL::varchar, NULL::json;
            RETURN;
    END;

    -- 3. 校验输入必须是线要素(LineString/MultiLineString)
    IF ST_GeometryType(v_line) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY SELECT
            400, '输入几何体必须是线类型(LineString)'::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- 4. 核心查询：3D电子围栏碰撞检测
    RETURN QUERY
    SELECT
        200 AS code,
        '检测到航线闯入电子围栏'::varchar AS msg,
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
            200, '航线未闯入任何电子围栏'::varchar,
            NULL::varchar, NULL::json;
    END IF;

-- 异常捕获
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500, ('服务异常：' || SQLERRM)::varchar,
            NULL::varchar, NULL::json;
END;
$$;

---------------------------------------------------------------- 函数调用测试 ---------------------------------------------------------------- 
SELECT * FROM public.gis_electric_fence_check_line('{
  "type":"LineString",
  "coordinates":[
    [113.405861,34.769437,120],
    [113.405861,34.769437,120]
  ]
}');
-- ================================================ gis_check_point_in_forbidden_zone  检查点是否在启用的禁飞区内==========================================================
-- ====================================================================
-- 函数名称： gis_electric_fence_check_point
-- 函数功能： 无人机定位点 3D 电子围栏碰撞检测（无缓冲，纯原始围栏判断）
-- 函数描述： 1. 传入 经纬度+高度（支持2D/3D点）
--            2. 高度=0（默认）：仅执行2D平面包含判断
--            3. 高度>0：执行3D立体包含判断（Z从0到围栏height）
--            4. 只查询禁飞区、启用状态、未删除的有效围栏
--            5. 返回标准格式结果集，与航线检测函数完全通用，前端可直接渲染
-- 函数说明： 依赖PostGIS空间扩展，坐标系默认使用WGS84(4326)
-- 参数说明：
--   p_lon       double precision  输入参数：经度（WGS84，必填）
--   p_lat       double precision  输入参数：纬度（WGS84，必填）
--   p_z         double precision  输入参数：高度/海拔（选填，默认0）
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

-- 删除函数
DROP FUNCTION IF EXISTS public.gis_electric_fence_check_point(double precision, double precision, double precision);

-- 创建函数
CREATE OR REPLACE FUNCTION public.gis_electric_fence_check_point(
    p_lon double precision,
    p_lat double precision,
    p_z double precision DEFAULT 0
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
    v_point geometry; -- 存储生成的空间点几何对象
BEGIN
    -- =============================================
    -- 【400 参数错误】第一步：校验经纬度是否为空
    -- =============================================
    IF p_lon IS NULL OR p_lat IS NULL THEN
        RETURN QUERY SELECT
            400, '经纬度不能为空'::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- =============================================
    -- 【400 参数错误】第二步：校验经纬度是否在合法范围内
    -- =============================================
    IF p_lon < -180 OR p_lon > 180 OR p_lat < -90 OR p_lat > 90 THEN
        RETURN QUERY SELECT
            400, '经纬度超出合法范围'::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

    -- =============================================
    -- 构建2D空间点（带WGS84坐标系）
    -- =============================================
    v_point := ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326);

    -- =============================================
    -- 核心查询：检测点是否在有效禁飞区内
    -- 规则：
    -- 1. 必须在围栏平面内
    -- 2. 高度=0：不校验高度
    -- 3. 高度>0：必须 ≤ 围栏高度
    -- =============================================
    RETURN QUERY
    SELECT
        200 AS code,
        '当前位置在禁飞区内'::varchar AS msg,
        f.id,
        ST_AsGeoJSON(ST_SetSRID(f.geom, 4326))::json AS geom_geojson
    FROM bo_electric_fence f
    WHERE
        f.fence_type = '1'        -- 围栏类型：禁飞区
        AND f.status = '1'        -- 状态：启用
        AND f.del_flag = false    -- 未删除
        AND f.height >= 0         -- 围栏高度合法
        AND ST_Contains(ST_SetSRID(f.geom, 4326), v_point) -- 平面包含判断
        AND (
            p_z = 0
            OR
            (p_z > 0 AND p_z <= COALESCE(f.height, 0))
        );

    -- =============================================
    -- 【201 成功】未检测到闯入任何禁飞区
    -- =============================================
    IF NOT FOUND THEN
        RETURN QUERY SELECT
            201, '当前位置不在禁飞区内'::varchar,
            NULL::varchar, NULL::json;
        RETURN;
    END IF;

-- =============================================
-- 【500 服务异常】系统/数据库/空间函数异常
-- =============================================
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT
            500, ('服务异常：' || SQLERRM)::varchar,
            NULL::varchar, NULL::json;
END;
$$;

 
-- 函数调用示例=============================================
SELECT * FROM gis_electric_fence_check_point(113.405861, 34.769437,10000);

SELECT * FROM gis_electric_fence_check_point(113.405861, 34.769437);
 
 