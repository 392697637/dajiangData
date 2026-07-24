-- =============================================================================
-- 6.1 DEM 高程工具函数
--
-- 函数清单：
--   gis_dem_validate                  校验 DEM 栅格表是否可用
--   gis_dem_elevation                 按单个 Point 查询 DEM 高程值
--   gis_dem_elevation_geometry        基础 DEM 高程提取和补高程统一入口
--   gis_dem_elevation_point           点/多点补 DEM 高程入口，支持 geometry
--   gis_dem_elevation_line            线/多线补 DEM 高程入口，支持 geometry
--   gis_dem_elevation_polygon         面/多面补 DEM 高程入口，支持 geometry
--   gis_dem_elevation_text_point      点/多点文本补 DEM 高程入口，支持 WKT/EWKT/GeoJSON
--   gis_dem_elevation_text_line       线/多线文本补 DEM 高程入口，支持 WKT/EWKT/GeoJSON
--   gis_dem_elevation_text_polygon    面/多面文本补 DEM 高程入口，支持 WKT/EWKT/GeoJSON
--   gis_dem_elevation_text            解析 WKT/EWKT/GeoJSON 并返回 DEM 高程结果
--
-- 统一约定：
--   1. DEM 栅格表固定读取 public.gis_dem_henan。
--   2. 输入 geometry 没有 SRID 时按 EPSG:4326 处理。
--   3. 输入 geometry 已有 Z 值时，按 XY 查询 DEM，并用 DEM 高程生成新的 Z 值。
--   4. 点不在 DEM 覆盖范围内时，补高程入口使用 0 作为兜底 Z 值。
--   5. gis_dem_elevation 是基础取值函数，只负责单 Point 返回一个高程值；覆盖范围外返回 NULL。
--   6. gis_dem_elevation_geometry 是 geometry 统一入口；点/线/面语义明确时可调用对应语义化入口。
--   7. 点/线/面 geometry 入口使用 gis_dem_elevation_point/line/polygon。
--   8. 点/线/面 text 入口使用 gis_dem_elevation_text_point/line/polygon，支持 WKT、EWKT、GeoJSON。
-- =============================================================================



-- =============================================================================
-- 扩展依赖
-- 说明：启用 PostGIS 几何和 PostGIS Raster 能力。
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

-- =============================================================================
-- 表注释
-- 说明：如果 DEM 表已经存在，则补充表和核心字段的数据库注释。
-- =============================================================================
DO $$
BEGIN
    IF to_regclass('public.gis_dem_henan') IS NULL THEN
        RETURN;
    END IF;

COMMENT ON TABLE public.gis_dem_henan IS '河南DEM栅格表';
COMMENT ON COLUMN public.gis_dem_henan.rid IS '栅格瓦片主键';
COMMENT ON COLUMN public.gis_dem_henan.rast IS 'DEM栅格瓦片';

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'gis_dem_henan'
          AND column_name = 'filename'
    ) THEN
COMMENT ON COLUMN public.gis_dem_henan.filename IS '源栅格文件名';
    END IF;
END;
$$;


-- =============================================================================
-- 重建函数前清理
-- 说明：gis_drop_function 会删除同名函数的所有重载，避免签名变更导致旧函数残留。
-- =============================================================================
SELECT gis_drop_function('gis_dem_validate');

-- =============================================================================
-- 函数名称：gis_dem_validate
-- 函数功能：校验 DEM 栅格表是否可用
-- 使用场景：DEM 入库后、业务调用前，快速检查表是否存在、SRID 是否正确、范围是否落在河南区域。
-- 入参说明：p_old_srid、p_new_srid 为兼容旧调用保留，当前校验目标固定为 EPSG:4326。
-- 返回说明：返回状态码、说明、DEM SRID、瓦片数量、范围和电子围栏覆盖情况。
-- 状态规则：code=200 表示可用；code=400 表示表缺失、无有效瓦片、SRID 错误或范围异常。
-- 注意事项：正式 DEM 表固定为 public.gis_dem_henan；电子围栏统计仅在 bo_electric_fence.geom 存在时返回。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_validate(
    p_old_srid integer DEFAULT 4326,
    p_new_srid integer DEFAULT 4326
)
RETURNS TABLE (
    code integer,
    msg text,
    dem_exists boolean,
    dem_srid integer,
    tile_count bigint,
    extent_4326 text,
    in_henan_range boolean,
    fence_total bigint,
    fence_intersects bigint
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_srid integer;
    v_tile_count bigint;
    v_extent geometry;
    v_extent_4326 geometry;
    v_has_fence_geom boolean;
BEGIN
    -- 第一步：确认 DEM 主表是否存在；不存在时直接返回失败。
    IF to_regclass('public.gis_dem_henan') IS NULL THEN
        RETURN QUERY SELECT
            400,
            'DEM表不存在'::text,
            false,
            NULL::integer,
            0::bigint,
            NULL::text,
            false,
            NULL::bigint,
            NULL::bigint;
        RETURN;
    END IF;

    -- 第二步：读取 DEM 主表中占比最高的 SRID、瓦片数量和整体范围。
    SELECT
        ST_SRID(rast),
        count(*),
        ST_SetSRID(ST_Envelope(ST_Collect(ST_ConvexHull(rast))), ST_SRID(rast))
    INTO v_dem_srid, v_tile_count, v_extent
    FROM public.gis_dem_henan
    WHERE rast IS NOT NULL
    GROUP BY ST_SRID(rast)
    ORDER BY count(*) DESC
    LIMIT 1;

    -- 第三步：DEM 表存在但没有有效 raster 时，返回不可用状态。
    IF v_tile_count IS NULL OR v_tile_count = 0 THEN
        RETURN QUERY SELECT
            400,
            'DEM表没有有效栅格瓦片'::text,
            true,
            v_dem_srid,
            0::bigint,
            NULL::text,
            false,
            NULL::bigint,
            NULL::bigint;
        RETURN;
    END IF;

    -- 第四步：把 DEM 范围转换到 4326，并判断是否落在河南经纬度预期范围内。
    v_extent_4326 := ST_Transform(v_extent, 4326);
    in_henan_range :=
        ST_XMin(v_extent_4326) >= 108
        AND ST_XMax(v_extent_4326) <= 118
        AND ST_YMin(v_extent_4326) >= 30
        AND ST_YMax(v_extent_4326) <= 38;

    fence_total := NULL;
    fence_intersects := NULL;

    -- 第五步：如果电子围栏表存在 geom 字段，则统计围栏总数和与 DEM 相交数量。
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'bo_electric_fence'
          AND column_name = 'geom'
    )
    INTO v_has_fence_geom;

    IF v_has_fence_geom THEN
        -- 统计有效电子围栏总数。
        SELECT count(*)
        INTO fence_total
        FROM public.bo_electric_fence
        WHERE geom IS NOT NULL;

        -- 统一把电子围栏转换到 4326，再与 DEM 4326 范围做相交判断。
        SELECT count(*)
        INTO fence_intersects
        FROM public.bo_electric_fence
        WHERE geom IS NOT NULL
          AND ST_Intersects(
              ST_Transform(
                  CASE
                      WHEN ST_SRID(geom) = 0 THEN ST_SetSRID(geom, 4326)
                      ELSE geom
                  END,
                  4326
              ),
              v_extent_4326
          );
    END IF;

    -- 第六步：根据 SRID 和范围校验结果统一组装返回值。
    RETURN QUERY SELECT
        CASE
            WHEN v_dem_srid <> 4326 THEN 400
            WHEN NOT in_henan_range THEN 400
            ELSE 200
        END,
        CASE
            WHEN v_dem_srid <> 4326 THEN format('DEM SRID不是4326，当前为%s', v_dem_srid)
            WHEN NOT in_henan_range THEN 'DEM范围不在河南预期范围内'
            ELSE 'DEM校验通过'
        END,
        true,
        v_dem_srid,
        v_tile_count,
        ST_AsText(v_extent_4326),
        in_henan_range,
        fence_total,
        fence_intersects;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_validate(integer, integer) IS '校验DEM表、SRID、范围和电子围栏覆盖情况';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation');

-- =============================================================================
-- 函数名称：gis_dem_elevation
-- 函数功能：根据单个 Point 查询 DEM 第一波段高程值
-- 入参说明：p_geom 为 Point geometry，SRID 为空时按 4326 处理。
-- 返回说明：返回 double precision 高程值；点不在 DEM 覆盖范围内返回 NULL。
-- 注意事项：这是底层取值函数，只取一个像元值，不负责补 0；业务统一补高程优先调用 gis_dem_elevation_geometry。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation(
    p_geom geometry
)
RETURNS double precision
LANGUAGE sql
STABLE
AS $$
    -- dem_srid：读取 DEM raster 的真实 SRID，用于把输入点转换到同一坐标系。
    WITH dem_srid AS (
        SELECT ST_SRID(rast) AS srid
        FROM public.gis_dem_henan
        WHERE rast IS NOT NULL
        LIMIT 1
    ),
    -- input_point：标准化输入点；SRID 为空时按 4326，已有 Z 时去掉 Z。
    input_point AS (
        SELECT
            CASE
                WHEN p_geom IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_Force2D(p_geom), 4326)
                ELSE ST_Force2D(p_geom)
            END AS geom
    ),
    -- point_dem：仅接受 Point，并转换到 DEM 坐标系。
    point_dem AS (
        SELECT ST_Transform(i.geom, d.srid) AS geom
        FROM input_point i
        CROSS JOIN dem_srid d
        WHERE i.geom IS NOT NULL
          AND ST_GeometryType(i.geom) = 'ST_Point'
    )
    -- 在覆盖该点的第一个栅格瓦片中读取第一波段像元值。
    SELECT ST_Value(r.rast, 1, p.geom)
    FROM public.gis_dem_henan r
    CROSS JOIN point_dem p
    WHERE ST_Intersects(r.rast, p.geom)
    ORDER BY r.rid
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation(geometry) IS '按单个Point查询DEM高程值';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_geometry');

-- =============================================================================
-- 函数名称：gis_dem_elevation_geometry
-- 函数功能：基础 DEM 高程提取/补高程统一入口
-- 入参说明：p_geom 支持点、多点、线、多线、面、多面和集合，支持二维和三维输入。
-- 返回说明：返回带 DEM Z 值的新 geometry；已有 Z 会被 DEM 高程替换。
-- 类型规则：单几何保持原单类型；Multi* 拆分补高程后再合成对应 Multi*；GeometryCollection 会忽略不支持的子类型。
-- 注意事项：业务侧已有 geometry 时优先调用该函数；接口层只有文本时使用 gis_dem_elevation_text。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_geometry(
    p_geom geometry
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    -- input_geom：统一输入几何的 SRID 和维度；后续全部按 2D XY 查询 DEM。
    WITH input_geom AS (
        SELECT
            CASE
                WHEN p_geom IS NULL THEN NULL::geometry
                WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_Force2D(p_geom), 4326)
                ELSE ST_Force2D(p_geom)
            END AS geom,
            COALESCE(NULLIF(ST_SRID(p_geom), 0), 4326) AS srid
    ),
    -- parts：把 Multi* 和 GeometryCollection 拆成单个 Point/LineString/Polygon 处理。
    parts AS (
        SELECT
            (d).path AS path,
            (d).geom AS geom
        FROM input_geom i
        CROSS JOIN LATERAL ST_Dump(i.geom) AS d
        WHERE i.geom IS NOT NULL
    ),
    -- z_parts：按子几何类型生成带 DEM Z 值的新子几何。
    z_parts AS (
        SELECT
            path,
            CASE ST_GeometryType(geom)
                WHEN 'ST_Point' THEN
                    -- Point：直接按点取高程，重建 PointZ。
                    ST_MakePoint(
                        ST_X(geom),
                        ST_Y(geom),
                        COALESCE(public.gis_dem_elevation(geom), 0)
                    )
                WHEN 'ST_LineString' THEN
                    -- LineString：拆顶点逐点取高程，再按原顶点顺序重建 LineStringZ。
                    (
                        SELECT ST_MakeLine(
                            ST_MakePoint(
                                ST_X((dp).geom),
                                ST_Y((dp).geom),
                                COALESCE(public.gis_dem_elevation((dp).geom), 0)
                            )
                            ORDER BY (dp).path[1]
                        )
                        FROM ST_DumpPoints(geom) AS dp
                    )
                WHEN 'ST_Polygon' THEN
                    -- Polygon：拆外环/内环顶点补高程，再重建 PolygonZ。
                    (
                        WITH rings AS (
                            -- rings：拆出外环和所有内环，ring_no=0 为外环。
                            SELECT
                                (dr).path[1] AS ring_no,
                                (dr).geom AS ring_geom
                            FROM ST_DumpRings(geom) AS dr
                        ),
                        z_rings AS (
                            -- z_rings：对每个环逐顶点补 DEM Z，并保持环内点顺序。
                            SELECT
                                ring_no,
                                ST_MakeLine(
                                    ST_MakePoint(
                                        ST_X((dp).geom),
                                        ST_Y((dp).geom),
                                        COALESCE(public.gis_dem_elevation((dp).geom), 0)
                                    )
                                    ORDER BY (dp).path[1]
                                ) AS ring_geom
                            FROM rings r
                            CROSS JOIN LATERAL ST_DumpPoints(r.ring_geom) AS dp
                            GROUP BY ring_no
                        )
                        -- 使用补高程后的外环和内环重新构造 PolygonZ。
                        SELECT ST_MakePolygon(
                            (SELECT ring_geom FROM z_rings WHERE ring_no = 0),
                            COALESCE(
                                ARRAY(SELECT ring_geom FROM z_rings WHERE ring_no > 0 ORDER BY ring_no),
                                ARRAY[]::geometry[]
                            )
                        )
                    )
                ELSE NULL::geometry
            END AS geom
        FROM parts
    )
    SELECT
        CASE
            -- 输入为空或所有子几何都不支持时返回 NULL。
            WHEN (SELECT geom FROM input_geom) IS NULL THEN NULL::geometry
            WHEN NOT EXISTS (SELECT 1 FROM z_parts WHERE geom IS NOT NULL) THEN NULL::geometry
            -- 单 Point/LineString/Polygon 保持单几何类型返回。
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_Point' THEN
                ST_SetSRID((SELECT geom FROM z_parts ORDER BY path LIMIT 1), (SELECT srid FROM input_geom))
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_LineString' THEN
                ST_SetSRID((SELECT geom FROM z_parts ORDER BY path LIMIT 1), (SELECT srid FROM input_geom))
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_Polygon' THEN
                ST_SetSRID((SELECT geom FROM z_parts ORDER BY path LIMIT 1), (SELECT srid FROM input_geom))
            -- GeometryCollection 保留集合结构，忽略不支持的子类型。
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_GeometryCollection' THEN
                ST_SetSRID((SELECT ST_Collect(geom ORDER BY path) FROM z_parts WHERE geom IS NOT NULL), (SELECT srid FROM input_geom))
            ELSE
                -- MultiPoint/MultiLineString/MultiPolygon 按原输入类型提取对应维度后返回。
                ST_SetSRID(
                    ST_CollectionExtract(
                        ST_Collect(geom ORDER BY path),
                        CASE
                            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_MultiPoint' THEN 1
                            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_MultiLineString' THEN 2
                            WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_MultiPolygon' THEN 3
                            ELSE 0
                        END
                    ),
                    (SELECT srid FROM input_geom)
                )
        END
    FROM input_geom;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_geometry(geometry) IS '基础DEM高程提取和补高程统一入口';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_parse_geometry_text');

-- =============================================================================
-- 函数名称：gis_dem_parse_geometry_text
-- 函数功能：解析 WKT、EWKT 或 GeoJSON 文本为空间 geometry
-- 入参说明：
--   1. WKT：未声明 SRID 时默认按 EPSG:4326。
--   2. EWKT：形如 SRID=4326;POINT(...)，保留文本内 SRID。
--   3. GeoJSON：支持 Geometry 和 Feature；Feature 自动读取 geometry 节点。
-- 返回说明：返回解析后的 geometry；空字符串返回 NULL。
-- 注意事项：这是 6.1 内部 helper，业务侧优先调用点/线/面 text 专用入口或 gis_dem_elevation_text。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_parse_geometry_text(
    p_geom_text text
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_text text;
    v_json jsonb;
    v_geom geometry;
BEGIN
    v_text := btrim(p_geom_text);

    IF v_text IS NULL OR v_text = '' THEN
        RETURN NULL;
    END IF;

    IF left(v_text, 1) = '{' THEN
        v_json := v_text::jsonb;

        IF v_json ->> 'type' = 'Feature' THEN
            v_geom := ST_GeomFromGeoJSON((v_json -> 'geometry')::text);
        ELSE
            v_geom := ST_GeomFromGeoJSON(v_text);
        END IF;

        IF ST_SRID(v_geom) = 0 THEN
            v_geom := ST_SetSRID(v_geom, 4326);
        END IF;
    ELSIF upper(v_text) LIKE 'SRID=%;%' THEN
        v_geom := ST_GeomFromEWKT(v_text);
    ELSE
        v_geom := ST_GeomFromText(v_text, 4326);
    END IF;

    RETURN v_geom;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_parse_geometry_text(text) IS '解析WKT、EWKT或GeoJSON文本为空间geometry';





-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_point');

-- =============================================================================
-- 函数名称：gis_dem_elevation_point
-- 函数功能：点/多点补高程入口，返回带 DEM Z 值的新点或多点
-- 入参说明：p_point 支持 Point 和 MultiPoint。
-- 返回说明：Point 返回 PointZ；MultiPoint 返回 MultiPointZ。
-- 适用场景：业务语义明确为点位、航点或点集时使用；可避免误把线面传入点接口。
-- 注意事项：该函数是语义化包装，内部调用 gis_dem_elevation_geometry；非点类型会直接抛错。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_point(
    p_point geometry
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_point IS NULL THEN
        RETURN NULL;
    END IF;

    IF ST_GeometryType(p_point) NOT IN ('ST_Point', 'ST_MultiPoint') THEN
        RAISE EXCEPTION 'Only Point or MultiPoint geometry is supported: %', ST_GeometryType(p_point);
    END IF;

    RETURN public.gis_dem_elevation_geometry(p_point);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_point(geometry) IS '点/多点补DEM高程入口';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_text_point');

-- =============================================================================
-- 函数名称：gis_dem_elevation_text_point
-- 函数功能：点/多点文本补高程入口
-- 入参说明：p_point_text 支持 Point/MultiPoint 的 WKT、EWKT、GeoJSON Geometry 或 GeoJSON Feature。
-- 返回说明：Point 文本返回 PointZ；MultiPoint 文本返回 MultiPointZ。
-- 注意事项：文本解析后仍会做点/多点类型校验；非点类型会直接抛错。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_text_point(
    p_point_text text
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    SELECT public.gis_dem_elevation_point(public.gis_dem_parse_geometry_text(p_point_text));
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_text_point(text) IS '解析点/多点WKT、EWKT或GeoJSON并补DEM高程';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_line');

-- =============================================================================
-- 函数名称：gis_dem_elevation_line
-- 函数功能：线/多线补高程入口，返回带 DEM Z 值的新线或多线
-- 入参说明：p_line 支持 LineString 和 MultiLineString。
-- 返回说明：LineString 返回 LineStringZ；MultiLineString 返回 MultiLineStringZ。
-- 适用场景：业务语义明确为航线、轨迹或线路时使用；可避免误把面或点传入线接口。
-- 注意事项：该函数是语义化包装，内部调用 gis_dem_elevation_geometry；非线类型会直接抛错。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_line(
    p_line geometry
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_line IS NULL THEN
        RETURN NULL;
    END IF;

    IF ST_GeometryType(p_line) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
        RAISE EXCEPTION 'Only LineString or MultiLineString geometry is supported: %', ST_GeometryType(p_line);
    END IF;

    RETURN public.gis_dem_elevation_geometry(p_line);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_line(geometry) IS '线/多线补DEM高程入口';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_text_line');

-- =============================================================================
-- 函数名称：gis_dem_elevation_text_line
-- 函数功能：线/多线文本补高程入口
-- 入参说明：p_line_text 支持 LineString/MultiLineString 的 WKT、EWKT、GeoJSON Geometry 或 GeoJSON Feature。
-- 返回说明：LineString 文本返回 LineStringZ；MultiLineString 文本返回 MultiLineStringZ。
-- 注意事项：文本解析后仍会做线/多线类型校验；非线类型会直接抛错。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_text_line(
    p_line_text text
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    SELECT public.gis_dem_elevation_line(public.gis_dem_parse_geometry_text(p_line_text));
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_text_line(text) IS '解析线/多线WKT、EWKT或GeoJSON并补DEM高程';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_polygon');

-- =============================================================================
-- 函数名称：gis_dem_elevation_polygon
-- 函数功能：面/多面补高程入口，返回带 DEM Z 值的新面或多面
-- 入参说明：p_polygon 支持 Polygon 和 MultiPolygon。
-- 返回说明：Polygon 返回 PolygonZ；MultiPolygon 返回 MultiPolygonZ。
-- 适用场景：业务语义明确为面范围、作业区域或禁飞区范围时使用；可避免误把点线传入面接口。
-- 注意事项：该函数是语义化包装，内部调用 gis_dem_elevation_geometry；非面类型会直接抛错。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_polygon(
    p_polygon geometry
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_polygon IS NULL THEN
        RETURN NULL;
    END IF;

    IF ST_GeometryType(p_polygon) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        RAISE EXCEPTION 'Only Polygon or MultiPolygon geometry is supported: %', ST_GeometryType(p_polygon);
    END IF;

    RETURN public.gis_dem_elevation_geometry(p_polygon);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_polygon(geometry) IS '面/多面补DEM高程入口';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_text_polygon');

-- =============================================================================
-- 函数名称：gis_dem_elevation_text_polygon
-- 函数功能：面/多面文本补高程入口
-- 入参说明：p_polygon_text 支持 Polygon/MultiPolygon 的 WKT、EWKT、GeoJSON Geometry 或 GeoJSON Feature。
-- 返回说明：Polygon 文本返回 PolygonZ；MultiPolygon 文本返回 MultiPolygonZ。
-- 注意事项：文本解析后仍会做面/多面类型校验；非面类型会直接抛错。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_text_polygon(
    p_polygon_text text
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    SELECT public.gis_dem_elevation_polygon(public.gis_dem_parse_geometry_text(p_polygon_text));
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_text_polygon(text) IS '解析面/多面WKT、EWKT或GeoJSON并补DEM高程';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation_text');

-- =============================================================================
-- 函数名称：gis_dem_elevation_text
-- 函数功能：根据 WKT、EWKT 或 GeoJSON 文本统一查询/补充 DEM 高程
-- 入参说明：
--   1. WKT：POINT、MULTIPOINT、LINESTRING、MULTILINESTRING、POLYGON、MULTIPOLYGON、GEOMETRYCOLLECTION。
--   2. EWKT：形如 SRID=4326;POINT(...)，按文本内 SRID 解析。
--   3. GeoJSON：支持 Geometry 和 Feature；Feature 会自动读取 geometry 节点，properties 不参与计算。
-- 返回说明：
--   geom_type   解析后的 PostGIS 几何类型。
--   seq         当前文本统一入口每次返回 1 行，固定为 1。
--   point_geom  单 Point 输入时返回二维点；其他类型为 NULL。
--   elevation   单 Point 输入时返回 DEM 高程；其他类型为 NULL。
--   result_geom 补 DEM 高程后的 Z 几何。
--   result_wkt  result_geom 的 WKT 表达。
-- 注意事项：WKT 默认按 EPSG:4326 解析；GeoJSON 未带 SRID 时按 EPSG:4326。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_text(
    p_geom_text text
)
RETURNS TABLE (
    geom_type text,
    seq integer,
    point_geom geometry(Point),
    elevation double precision,
    result_geom geometry,
    result_wkt text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_text text;
    v_geom geometry;
    v_type text;
BEGIN
    -- 第一步：清理输入文本；空字符串返回空结果。
    v_text := btrim(p_geom_text);

    IF v_text IS NULL OR v_text = '' THEN
        RETURN;
    END IF;

    -- 第二步：复用统一文本解析 helper，并读取 PostGIS 几何类型。
    v_geom := public.gis_dem_parse_geometry_text(v_text);
    v_type := ST_GeometryType(v_geom);

    -- 第三步：点/多点返回补高程后的结果几何；单点额外返回 elevation 字段。
    IF v_type IN ('ST_Point', 'ST_MultiPoint') THEN
        RETURN QUERY
        SELECT
            v_type,
            1,
            CASE WHEN v_type = 'ST_Point' THEN ST_Force2D(v_geom)::geometry(Point) ELSE NULL::geometry(Point) END,
            CASE WHEN v_type = 'ST_Point' THEN public.gis_dem_elevation(v_geom) ELSE NULL::double precision END,
            public.gis_dem_elevation_geometry(v_geom),
            ST_AsText(public.gis_dem_elevation_geometry(v_geom));
        RETURN;
    END IF;

    -- 第四步：线/多线通过基础入口补 DEM Z，返回 result_geom/result_wkt。
    IF v_type IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN QUERY
        SELECT
            v_type,
            1,
            NULL::geometry(Point),
            NULL::double precision,
            public.gis_dem_elevation_geometry(v_geom),
            ST_AsText(public.gis_dem_elevation_geometry(v_geom));
        RETURN;
    END IF;

    -- 第五步：面/多面/集合通过基础入口补 DEM Z，返回 result_geom/result_wkt。
    IF v_type IN ('ST_Polygon', 'ST_MultiPolygon', 'ST_GeometryCollection') THEN
        RETURN QUERY
        SELECT
            v_type,
            1,
            NULL::geometry(Point),
            NULL::double precision,
            public.gis_dem_elevation_geometry(v_geom),
            ST_AsText(public.gis_dem_elevation_geometry(v_geom));
        RETURN;
    END IF;

    -- 第六步：其他几何类型当前不作为 DEM 基础入口支持。
    RAISE EXCEPTION 'Unsupported DEM geometry type: %', v_type;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_text(text) IS '解析WKT、EWKT或GeoJSON并返回DEM高程结果';

-- =============================================================================
-- 调用示例
-- 说明：
--   1. 以下示例默认输入坐标为 EPSG:4326，经纬度顺序为 lon lat。
--   2. 已经持有 geometry 时使用 gis_dem_elevation_geometry 或点/线/面 geometry 语义入口。
--   3. 接口层收到 WKT、EWKT 或 GeoJSON 文本时，可使用点/线/面 text 专用入口。
--   4. 需要统一表结构返回时使用 gis_dem_elevation_text。
-- =============================================================================

-- 1. 校验 DEM 入库状态
-- SELECT * FROM public.gis_dem_validate();

-- 2. 查询单个 Point 的 DEM 高程值
-- SELECT public.gis_dem_elevation(
--     ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
-- ) AS elevation;

-- 3. 使用基础统一入口给 Point 补 DEM 高程，返回 PointZ
-- SELECT ST_AsText(
--     public.gis_dem_elevation_geometry(
--         ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
--     )
-- ) AS point_z;

-- 4. 使用基础统一入口给 MultiPoint 补 DEM 高程，返回 MultiPointZ
-- SELECT ST_AsText(
--     public.gis_dem_elevation_geometry(
--         ST_GeomFromText('MULTIPOINT((113.65 34.76),(113.66 34.77))', 4326)
--     )
-- ) AS multipoint_z;

-- 5. 使用基础统一入口给 LineString 补 DEM 高程，返回 LineStringZ
-- SELECT ST_AsText(
--     public.gis_dem_elevation_geometry(
--         ST_GeomFromText('LINESTRING(113.60 34.70,113.65 34.76,113.70 34.80)', 4326)
--     )
-- ) AS line_z;

-- 6. 使用基础统一入口给 Polygon 补 DEM 高程，返回 PolygonZ
-- SELECT ST_AsText(
--     public.gis_dem_elevation_geometry(
--         ST_GeomFromText(
--             'POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))',
--             4326
--         )
--     )
-- ) AS polygon_z;

-- 7. 点/多点补高程 geometry 专用入口
-- SELECT ST_AsText(
--     public.gis_dem_elevation_point(
--         ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)
--     )
-- ) AS point_z;
--
-- SELECT ST_AsText(
--     public.gis_dem_elevation_point(
--         ST_GeomFromText('MULTIPOINT((113.65 34.76),(113.66 34.77))', 4326)
--     )
-- ) AS multipoint_z;

-- 8. 线/多线补高程 geometry 专用入口
-- SELECT ST_AsText(
--     public.gis_dem_elevation_line(
--         ST_GeomFromText('LINESTRING(113.60 34.70,113.70 34.80)', 4326)
--     )
-- ) AS line_z;
--
-- SELECT ST_AsText(
--     public.gis_dem_elevation_line(
--         ST_GeomFromText('MULTILINESTRING((113.60 34.70,113.70 34.80),(113.62 34.72,113.68 34.78))', 4326)
--     )
-- ) AS multiline_z;

-- 9. 面/多面补高程 geometry 专用入口
-- SELECT ST_AsText(
--     public.gis_dem_elevation_polygon(
--         ST_GeomFromText(
--             'POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))',
--             4326
--         )
--     )
-- ) AS polygon_z;
--
-- SELECT ST_AsText(
--     public.gis_dem_elevation_polygon(
--         ST_GeomFromText(
--             'MULTIPOLYGON(((113.60 34.70,113.66 34.70,113.66 34.76,113.60 34.76,113.60 34.70)),((113.68 34.72,113.72 34.72,113.72 34.78,113.68 34.78,113.68 34.72)))',
--             4326
--         )
--     )
-- ) AS multipolygon_z;

-- 10. 点/线/面 text 专用入口：WKT、EWKT、GeoJSON Geometry、GeoJSON Feature 都支持，返回补高程后的 Z 几何。
-- SELECT ST_AsText(public.gis_dem_elevation_text_point('POINT(113.65 34.76)')) AS point_text_z;
--
-- SELECT ST_AsText(public.gis_dem_elevation_text_line('SRID=4326;LINESTRING(113.60 34.70,113.70 34.80)')) AS line_text_z;
--
-- SELECT ST_AsText(
--     public.gis_dem_elevation_text_polygon(
--         '{"type":"Feature","properties":{"name":"demo"},"geometry":{"type":"Polygon","coordinates":[[[113.60,34.70],[113.70,34.70],[113.70,34.80],[113.60,34.80],[113.60,34.70]]]}}'
--     )
-- ) AS polygon_text_z;

-- 11. 文本统一入口：WKT、EWKT、GeoJSON Geometry、GeoJSON Feature 都支持。
--    返回字段包含 geom_type、seq、point_geom、elevation、result_geom、result_wkt。
--    点会额外返回 elevation；线、面、集合主要看 result_geom/result_wkt。
--
-- 11.1 WKT：未声明 SRID 时默认按 EPSG:4326 解析。
-- SELECT *
-- FROM public.gis_dem_elevation_text('POINT(113.65 34.76)');
--
-- 11.2 EWKT：使用文本内声明的 SRID。
-- SELECT result_wkt
-- FROM public.gis_dem_elevation_text('SRID=4326;LINESTRING(113.60 34.70,113.70 34.80)');
--
-- 11.3 GeoJSON Geometry：适合前端直接传 geometry 对象字符串。
-- SELECT result_wkt
-- FROM public.gis_dem_elevation_text('{"type":"LineString","coordinates":[[113.60,34.70],[113.70,34.80]]}');
--
-- 11.4 GeoJSON Feature：函数自动读取 geometry 节点，properties 不参与计算。
-- SELECT result_wkt
-- FROM public.gis_dem_elevation_text('{"type":"Feature","properties":{"name":"demo"},"geometry":{"type":"Polygon","coordinates":[[[113.60,34.70],[113.70,34.70],[113.70,34.80],[113.60,34.80],[113.60,34.70]]]}}');
