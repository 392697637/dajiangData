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
--   1. DEM 取值按 public.jc_sheng.gis_dem_table 自动选择省级 DEM 表；未配置或表不存在时返回 0。
--   2. 输入 geometry 没有 SRID 时按 EPSG:4326 处理。
--   3. 输入 geometry 已有 Z 值时，按 XY 查询 DEM，并用 DEM 高程生成新的 Z 值。
--   4. 点不在 DEM 覆盖范围内时，补高程入口使用 0 作为兜底 Z 值。
--   5. gis_dem_elevation 是基础取值函数，只负责单 Point 返回一个高程值；覆盖范围外返回 0。
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
-- 重建函数前清理
-- 说明：gis_drop_function 会删除同名函数的所有重载，避免签名变更导致旧函数残留。
-- =============================================================================
SELECT gis_drop_function('gis_dem_validate');

-- =============================================================================
-- 函数名称：gis_dem_validate
-- 函数功能：校验 jc_sheng.gis_dem_table 配置的省级 DEM 栅格表是否可用
-- 使用场景：DEM 入库后、业务调用前，检查省表配置、字段、SRID 和是否有瓦片，并补充 DEM 表注释。
-- 入参说明：无参数；固定校验 DEM SRID 为 EPSG:4326，默认轻量检查。
-- 返回说明：每个配置了 gis_dem_table 的省返回一行校验结果；配置缺失或表异常返回 code=400。
-- 状态规则：code=200 表示该省 DEM 表可用；code=400 表示配置为空、表缺失、字段缺失、无瓦片或 SRID 异常。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_validate()
RETURNS TABLE (
    -- code：状态码，200=该省 DEM 配置可用，400=配置或 DEM 表存在问题。
    code integer,
    -- msg：校验说明，返回通过原因或具体错误原因。
    msg text,
    -- shengname：省份名称，来自 public.jc_sheng.shengname。
    shengname text,
    -- shengid：省份ID，来自 public.jc_sheng.shengid。
    shengid text,
    -- gis_dem_table：省份配置的 DEM 表名，来自 public.jc_sheng.gis_dem_table。
    gis_dem_table text,
    -- dem_exists：DEM 表是否存在。
    dem_exists boolean,
    -- has_rid：DEM 表是否存在 rid 瓦片ID字段。
    has_rid boolean,
    -- has_rast：DEM 表是否存在 rast 栅格字段。
    has_rast boolean,
    -- dem_srid：DEM raster 的 SRID；正常应为 4326。
    dem_srid integer,
    -- tile_count：轻量检查下 1=至少存在一条有效 raster，0=没有有效 raster。
    tile_count bigint
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_cfg record;
    v_dem_reg regclass;
    v_checked_count integer := 0;
BEGIN
    -- 第一步：确认省份配置表是否存在。
    IF to_regclass('public.jc_sheng') IS NULL THEN
        code := 400;
        msg := '省份配置表 public.jc_sheng 不存在';
        shengname := NULL;
        shengid := NULL;
        gis_dem_table := NULL;
        dem_exists := false;
        has_rid := false;
        has_rast := false;
        dem_srid := NULL;
        tile_count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 第二步：检查 jc_sheng 必需字段是否存在。
    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'public.jc_sheng'::regclass
          AND attname IN ('geom', 'gis_dem_table')
          AND NOT attisdropped
        GROUP BY attrelid
        HAVING count(*) = 2
    ) THEN
        code := 400;
        msg := '省份配置表 public.jc_sheng 缺少 geom 或 gis_dem_table 字段';
        shengname := NULL;
        shengid := NULL;
        gis_dem_table := NULL;
        dem_exists := false;
        has_rid := false;
        has_rast := false;
        dem_srid := NULL;
        tile_count := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 第三步：逐省检查 DEM 表配置。
    FOR v_cfg IN
        SELECT
            s.shengname::text AS shengname,
            s.shengid::text AS shengid,
            NULLIF(trim(s.gis_dem_table), '') AS gis_dem_table
        FROM public.jc_sheng s
        WHERE s.gis_dem_table IS NOT NULL
        ORDER BY s.gid
    LOOP
        v_checked_count := v_checked_count + 1;

        shengname := v_cfg.shengname;
        shengid := v_cfg.shengid;
        gis_dem_table := v_cfg.gis_dem_table;
        dem_srid := NULL;
        tile_count := 0;
        has_rid := false;
        has_rast := false;

        IF gis_dem_table IS NULL THEN
            code := 400;
            msg := 'gis_dem_table 为空';
            dem_exists := false;
            RETURN NEXT;
            CONTINUE;
        END IF;

        v_dem_reg := COALESCE(
            to_regclass(gis_dem_table),
            to_regclass(format('public.%I', gis_dem_table))
        );

        IF v_dem_reg IS NULL THEN
            code := 400;
            msg := format('DEM表不存在：%s', gis_dem_table);
            dem_exists := false;
            RETURN NEXT;
            CONTINUE;
        END IF;

        dem_exists := true;

        EXECUTE format(
            'COMMENT ON TABLE %s IS %L',
            v_dem_reg,
            format('%sDEM栅格表', COALESCE(NULLIF(trim(shengname), ''), '省级'))
        );

        SELECT
            EXISTS (
                SELECT 1
                FROM pg_attribute
                WHERE attrelid = v_dem_reg
                  AND attname = 'rid'
                  AND NOT attisdropped
            ),
            EXISTS (
                SELECT 1
                FROM pg_attribute
                WHERE attrelid = v_dem_reg
                  AND attname = 'rast'
                  AND NOT attisdropped
            )
        INTO has_rid, has_rast;

        IF has_rid THEN
            EXECUTE format('COMMENT ON COLUMN %s.rid IS %L', v_dem_reg, '栅格瓦片主键');
        END IF;

        IF has_rast THEN
            EXECUTE format('COMMENT ON COLUMN %s.rast IS %L', v_dem_reg, 'DEM栅格瓦片');
        END IF;

        IF EXISTS (
            SELECT 1
            FROM pg_attribute
            WHERE attrelid = v_dem_reg
              AND attname = 'filename'
              AND NOT attisdropped
        ) THEN
            EXECUTE format('COMMENT ON COLUMN %s.filename IS %L', v_dem_reg, '源栅格文件名');
        END IF;

        IF NOT has_rid OR NOT has_rast THEN
            code := 400;
            msg := 'DEM表缺少 rid 或 rast 字段';
            RETURN NEXT;
            CONTINUE;
        END IF;

        EXECUTE format(
            $sql$
            SELECT ST_SRID(rast), 1::bigint
            FROM %s
            WHERE rast IS NOT NULL
            LIMIT 1
            $sql$,
            v_dem_reg
        )
        INTO dem_srid, tile_count;

        IF tile_count IS NULL OR tile_count = 0 THEN
            code := 400;
            msg := 'DEM表没有有效栅格瓦片';
            tile_count := 0;
            RETURN NEXT;
            CONTINUE;
        END IF;

        IF dem_srid <> 4326 THEN
            code := 400;
            msg := format('DEM SRID不是4326，当前为%s', dem_srid);
        ELSE
            code := 200;
            msg := 'DEM校验通过';
        END IF;

        RETURN NEXT;
    END LOOP;

    IF v_checked_count = 0 THEN
        code := 400;
        msg := 'public.jc_sheng 未配置任何 gis_dem_table';
        shengname := NULL;
        shengid := NULL;
        gis_dem_table := NULL;
        dem_exists := false;
        has_rid := false;
        has_rast := false;
        dem_srid := NULL;
        tile_count := 0;
        RETURN NEXT;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_validate() IS '校验jc_sheng配置的省级DEM表、字段、SRID和瓦片，并补充DEM表注释';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_elevation');

-- =============================================================================
-- 函数名称：gis_dem_elevation
-- 函数功能：根据单个 Point 查询 DEM 第一波段高程值
-- 入参说明：p_geom 为 Point geometry，SRID 为空时按 4326 处理。
-- 返回说明：返回 double precision 高程值；未配置 DEM 表、表不存在、点不在 DEM 覆盖范围内时返回 0。
-- 注意事项：这是底层取值函数，只取一个像元值；业务统一补高程优先调用 gis_dem_elevation_geometry。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation(
    p_geom geometry
)
RETURNS double precision
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_point_4326 geometry;
    v_dem_table text;
    v_dem_reg regclass;
    v_has_rid boolean;
    v_has_rast boolean;
    v_elevation double precision;
BEGIN
    IF p_geom IS NULL THEN
        RETURN 0;
    END IF;

    IF ST_GeometryType(p_geom) <> 'ST_Point' THEN
        RETURN 0;
    END IF;

    v_point_4326 :=
        CASE
            WHEN ST_SRID(p_geom) = 0 THEN ST_SetSRID(ST_Force2D(p_geom), 4326)
            ELSE ST_Transform(ST_Force2D(p_geom), 4326)
        END;

    IF to_regclass('public.jc_sheng') IS NULL THEN
        RETURN 0;
    END IF;

    SELECT NULLIF(trim(s.gis_dem_table), '')
    INTO v_dem_table
    FROM public.jc_sheng s
    WHERE s.geom IS NOT NULL
      AND s.gis_dem_table IS NOT NULL
      AND ST_Covers(s.geom, v_point_4326)
    ORDER BY s.gid
    LIMIT 1;

    IF v_dem_table IS NULL THEN
        RETURN 0;
    END IF;

    v_dem_reg := COALESCE(
        to_regclass(v_dem_table),
        to_regclass(format('public.%I', v_dem_table))
    );
    IF v_dem_reg IS NULL THEN
        RETURN 0;
    END IF;

    SELECT
        EXISTS (
            SELECT 1
            FROM pg_attribute
            WHERE attrelid = v_dem_reg
              AND attname = 'rid'
              AND NOT attisdropped
        ),
        EXISTS (
            SELECT 1
            FROM pg_attribute
            WHERE attrelid = v_dem_reg
              AND attname = 'rast'
              AND NOT attisdropped
        )
    INTO v_has_rid, v_has_rast;

    IF NOT v_has_rid OR NOT v_has_rast THEN
        RETURN 0;
    END IF;

    EXECUTE format(
        $sql$
        SELECT ST_Value(r.rast, 1, $1)
        FROM %s r
        WHERE r.rast IS NOT NULL
          AND ST_Intersects(r.rast, $1)
        ORDER BY r.rid
        LIMIT 1
        $sql$,
        v_dem_reg
    )
    USING v_point_4326
    INTO v_elevation;

    RETURN COALESCE(v_elevation, 0);
END;
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
-- 注意事项：业务侧已有 geometry 时优先调用该函数；每个顶点会通过 jc_sheng.gis_dem_table 自动选择 DEM 表，接口层只有文本时使用 gis_dem_elevation_text。
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
            (d).geom AS geom,
            ST_GeometryType((d).geom) AS geom_type
        FROM input_geom i
        CROSS JOIN LATERAL ST_Dump(i.geom) AS d
        WHERE i.geom IS NOT NULL
    ),
    -- vertices：一次性拆出所有支持类型的顶点。
    vertices AS (
        SELECT
            p.path,
            p.geom_type,
            (dp).path AS point_path,
            (dp).geom AS point_geom
        FROM parts p
        CROSS JOIN LATERAL ST_DumpPoints(p.geom) AS dp
        WHERE p.geom_type IN ('ST_Point', 'ST_LineString', 'ST_Polygon')
    ),
    -- z_vertices：所有顶点通过底层函数自动选择省级 DEM 表取 Z；覆盖范围外统一使用 Z=0。
    z_vertices AS (
        SELECT
            v.path,
            v.geom_type,
            v.point_path,
            ST_MakePoint(
                ST_X(v.point_geom),
                ST_Y(v.point_geom),
                COALESCE(public.gis_dem_elevation(v.point_geom), 0)
            ) AS point_geom
        FROM vertices v
    ),
    -- z_lines：按顶点顺序重建 LineStringZ。
    z_lines AS (
        SELECT
            path,
            ST_MakeLine(point_geom ORDER BY point_path[1]) AS geom
        FROM z_vertices
        WHERE geom_type = 'ST_LineString'
        GROUP BY path
    ),
    -- z_rings：按环号和顶点顺序重建 PolygonZ 的外环/内环。
    z_rings AS (
        SELECT
            path,
            point_path[1] AS ring_no,
            ST_MakeLine(point_geom ORDER BY point_path[2]) AS ring_geom
        FROM z_vertices
        WHERE geom_type = 'ST_Polygon'
        GROUP BY path, point_path[1]
    ),
    -- z_polygons：用补高后的外环和内环重建 PolygonZ。
    z_polygons AS (
        SELECT
            zr.path,
            ST_MakePolygon(
                (SELECT ring_geom FROM z_rings outer_ring WHERE outer_ring.path = zr.path AND outer_ring.ring_no = 1),
                COALESCE(
                    ARRAY(
                        SELECT ring_geom
                        FROM z_rings inner_ring
                        WHERE inner_ring.path = zr.path
                          AND inner_ring.ring_no > 1
                        ORDER BY ring_no
                    ),
                    ARRAY[]::geometry[]
                )
            ) AS geom
        FROM z_rings zr
        GROUP BY zr.path
    ),
    -- z_parts：按子几何类型生成带 DEM Z 值的新子几何。
    z_parts AS (
        SELECT
            p.path,
            CASE p.geom_type
                WHEN 'ST_Point' THEN (SELECT point_geom FROM z_vertices zv WHERE zv.path = p.path LIMIT 1)
                WHEN 'ST_LineString' THEN (SELECT geom FROM z_lines zl WHERE zl.path = p.path)
                WHEN 'ST_Polygon' THEN (SELECT geom FROM z_polygons zp WHERE zp.path = p.path)
                ELSE NULL::geometry
            END AS geom
        FROM parts p
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
                    (
                        SELECT ST_CollectionExtract(
                            ST_Collect(geom ORDER BY path),
                            CASE
                                WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_MultiPoint' THEN 1
                                WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_MultiLineString' THEN 2
                                WHEN ST_GeometryType((SELECT geom FROM input_geom)) = 'ST_MultiPolygon' THEN 3
                                ELSE 0
                            END
                        )
                        FROM z_parts
                        WHERE geom IS NOT NULL
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
    v_result_geom geometry;
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

    IF v_type NOT IN (
        'ST_Point', 'ST_MultiPoint',
        'ST_LineString', 'ST_MultiLineString',
        'ST_Polygon', 'ST_MultiPolygon',
        'ST_GeometryCollection'
    ) THEN
        RAISE EXCEPTION 'Unsupported DEM geometry type: %', v_type;
    END IF;

    v_result_geom := public.gis_dem_elevation_geometry(v_geom);

    -- 第三步：点/多点返回补高程后的结果几何；单点额外返回 elevation 字段。
    IF v_type IN ('ST_Point', 'ST_MultiPoint') THEN
        RETURN QUERY
        SELECT
            v_type,
            1,
            CASE WHEN v_type = 'ST_Point' THEN ST_Force2D(v_geom)::geometry(Point) ELSE NULL::geometry(Point) END,
            CASE WHEN v_type = 'ST_Point' AND v_result_geom IS NOT NULL THEN ST_Z(v_result_geom) ELSE NULL::double precision END,
            v_result_geom,
            ST_AsText(v_result_geom);
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
            v_result_geom,
            ST_AsText(v_result_geom);
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
            v_result_geom,
            ST_AsText(v_result_geom);
        RETURN;
    END IF;

    RETURN;
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


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_update_table_z0');

-- =============================================================================
-- 函数名称：gis_dem_update_table_z0
-- 函数功能：按表名和几何列名批量补 DEM 高程；函数内部按点、线、面分组分批执行。
-- 入参说明：
--   1. p_table_name  表名，支持 'bo_electric_fence' 或 'public.bo_electric_fence'。
--   2. p_geom_column 几何列名，例如 'geom'。
--   3. p_batch_size  每批处理数量，默认 100。
-- 返回说明：
--   code=200 执行成功；updated_count 为实际更新行数；skipped_count 为未更新的非空几何行数。
-- 使用示例：
--   SELECT * FROM public.gis_dem_update_table_z0('public.bo_electric_fence', 'geom');
-- 注意事项：
--   1. 处理 Point/MultiPoint、LineString/MultiLineString、Polygon/MultiPolygon。
--   2. 二维 geometry 也会视为需要补高程。
--   3. 三维 geometry 只有 ST_ZMin=0 且 ST_ZMax=0 时才会补 DEM，已有真实高程不会覆盖。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_update_table_z0(
    -- p_table_name：目标表名；可以传不带 schema 的表名，也可以传 schema.table。
    p_table_name text,
    -- p_geom_column：目标几何列名；默认处理 geom 字段。
    p_geom_column text DEFAULT 'geom',
    -- p_batch_size：函数内部每批处理数量；点/线/面会分组分批执行。
    p_batch_size integer DEFAULT 100
)
RETURNS TABLE (
    -- code：执行状态码，200=成功，400=参数错误，500=执行异常。
    code integer,
    -- msg：中文执行说明，包含更新数量和耗时。
    msg text,
    -- table_name：实际解析后的目标表名。
    table_name text,
    -- geom_column：实际处理的几何列名。
    geom_column text,
    -- candidate_count：满足“需要补高程”条件的候选行数。
    candidate_count bigint,
    -- updated_count：本次 UPDATE 实际更新行数。
    updated_count bigint,
    -- skipped_count：非空几何中未更新的行数。
    skipped_count bigint,
    -- elapsed_seconds：函数执行耗时，单位秒。
    elapsed_seconds numeric
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- v_start_time：记录函数开始时间，用于最终返回耗时。
    v_start_time timestamp := clock_timestamp();
    -- v_table_reg：把文本表名解析成 regclass，后续动态 SQL 使用该对象名。
    v_table_reg regclass;
    -- v_column_exists：标记目标几何列是否存在。
    v_column_exists boolean;
    -- v_candidate_count：记录需要补 DEM 的候选行数。
    v_candidate_count bigint := 0;
    -- v_updated_count：记录 UPDATE 实际影响行数。
    v_updated_count bigint := 0;
    -- v_total_nonnull_count：记录目标几何列非空总数，用于计算跳过数量。
    v_total_nonnull_count bigint := 0;
    -- v_batch_count：记录单批更新行数。
    v_batch_count bigint := 0;
    -- v_geom_types：按点、线、面分组处理。
    v_geom_types text[];
BEGIN
    -- 1. 基础参数校验：表名和列名都不能为空。
    --    trim 后为空字符串时直接返回 400，不继续执行动态 SQL。
    IF NULLIF(trim(p_table_name), '') IS NULL THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            '参数错误：表名不能为空'::text,                                         -- msg：错误原因。
            p_table_name,                                                          -- table_name：回显入参表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    IF p_batch_size IS NULL OR p_batch_size <= 0 THEN
        RETURN QUERY SELECT
            400,
            '参数错误：批量大小必须大于0'::text,
            p_table_name,
            p_geom_column,
            0::bigint,
            0::bigint,
            0::bigint,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
        RETURN;
    END IF;

    --    几何列名为空时也直接返回 400。
    IF NULLIF(trim(p_geom_column), '') IS NULL THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            '参数错误：几何列名不能为空'::text,                                     -- msg：错误原因。
            p_table_name,                                                          -- table_name：回显入参表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    -- 2. 将传入表名解析为 regclass，避免动态 SQL 直接拼接不存在的表。
    --    p_table_name 支持 'bo_electric_fence' 和 'public.bo_electric_fence' 两种写法。
    --    如果不带 schema，会按当前 search_path 解析。
    v_table_reg := to_regclass(p_table_name);
    IF v_table_reg IS NULL THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            format('参数错误：表不存在：%s', p_table_name),                         -- msg：提示表不存在。
            p_table_name,                                                          -- table_name：回显入参表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    -- 3. 校验几何列是否真实存在，避免列名写错时进入 UPDATE。
    --    pg_attribute.attrelid 使用 regclass 精确定位目标表。
    --    NOT attisdropped 排除已经删除但仍残留在系统目录中的列。
    SELECT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = v_table_reg
          AND attname = p_geom_column
          AND NOT attisdropped
    )
    INTO v_column_exists;

    IF NOT v_column_exists THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            format('参数错误：几何列不存在：%s.%s', v_table_reg::text, p_geom_column), -- msg：提示列不存在。
            v_table_reg::text,                                                     -- table_name：解析后的真实表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    -- 4. 统计非空几何总数，用于返回 skipped_count。
    --    %s 接收 regclass，输出已安全解析的表名；%I 接收列名，按标识符安全转义。
    EXECUTE format(
        'SELECT count(*) FROM %s WHERE %I IS NOT NULL',
        v_table_reg,     -- %s：目标表。
        p_geom_column    -- %I：目标几何列。
    )
    INTO v_total_nonnull_count;

    -- 5. 统计候选数据：
    --    - 只处理 Point/MultiPoint、LineString/MultiLineString、Polygon/MultiPolygon；
    --    - 二维几何 ST_NDims < 3，需要补高程；
    --    - 三维几何只有 Z 最小值和最大值都为 0 时才补高程；
    --    - 已有非 0 Z 值的数据不会进入候选集。
    --    注意：ST_ZMin/ST_ZMax 对二维几何可能返回 NULL，所以二维几何单独用 ST_NDims < 3 判断。
    EXECUTE format(
        $sql$
        SELECT count(*)
        FROM %s
        WHERE %I IS NOT NULL                                             -- 几何为空无法补高程，跳过。
          AND ST_GeometryType(%I) IN (                                   -- 只处理点/线/面及对应 Multi 类型。
              'ST_Point', 'ST_MultiPoint',
              'ST_LineString', 'ST_MultiLineString',
              'ST_Polygon', 'ST_MultiPolygon'
          )
          AND (
              ST_NDims(%I) < 3                                           -- 二维几何需要补 DEM Z。
              OR (
                  COALESCE(ST_ZMin(%I), 0) = 0                           -- 三维几何最小 Z 为 0。
                  AND COALESCE(ST_ZMax(%I), 0) = 0                       -- 三维几何最大 Z 为 0，说明整条几何 Z 全为 0。
              )
          )
        $sql$,
        v_table_reg,     -- %s：目标表。
        p_geom_column,   -- 第 1 个 %I：IS NOT NULL 的几何列。
        p_geom_column,   -- 第 2 个 %I：ST_GeometryType 的几何列。
        p_geom_column,   -- 第 3 个 %I：ST_NDims 的几何列。
        p_geom_column,   -- 第 4 个 %I：ST_ZMin 的几何列。
        p_geom_column    -- 第 5 个 %I：ST_ZMax 的几何列。
    )
    INTO v_candidate_count;

    -- 6. 对候选数据按点、线、面分组分批执行 DEM 补高，并写回原几何列。
    --    public.gis_dem_elevation_geometry 会按几何类型返回 PointZ/MultiPointZ、LineStringZ/MultiLineStringZ、PolygonZ/MultiPolygonZ。
    FOREACH v_geom_types SLICE 1 IN ARRAY ARRAY[
        ARRAY['ST_Point', 'ST_MultiPoint'],
        ARRAY['ST_LineString', 'ST_MultiLineString'],
        ARRAY['ST_Polygon', 'ST_MultiPolygon']
    ] LOOP
        LOOP
            EXECUTE format(
                $sql$
                WITH todo AS (
                    SELECT ctid
                    FROM %s
                    WHERE %I IS NOT NULL
                      AND ST_GeometryType(%I) = ANY (%L::text[])
                      AND (
                          ST_NDims(%I) < 3
                          OR (
                              COALESCE(ST_ZMin(%I), 0) = 0
                              AND COALESCE(ST_ZMax(%I), 0) = 0
                          )
                      )
                    ORDER BY ST_NPoints(%I), ctid
                    LIMIT %s
                )
                UPDATE %s t
                SET %I = public.gis_dem_elevation_geometry(t.%I)
                FROM todo
                WHERE t.ctid = todo.ctid
                $sql$,
                v_table_reg,
                p_geom_column,
                p_geom_column,
                v_geom_types,
                p_geom_column,
                p_geom_column,
                p_geom_column,
                p_geom_column,
                p_batch_size,
                v_table_reg,
                p_geom_column,
                p_geom_column
            );

            GET DIAGNOSTICS v_batch_count = ROW_COUNT;
            v_updated_count := v_updated_count + v_batch_count;
            EXIT WHEN v_batch_count = 0;
        END LOOP;
    END LOOP;

    -- 8. 返回执行结果，方便接口或 SQL 控制台直接查看更新数量和耗时。
    RETURN QUERY SELECT
        200,                                                                       -- code：成功。
        format('DEM补高完成，候选 %s 条，更新 %s 条，跳过 %s 条，执行时间 %s 秒',
            v_candidate_count,                                                     -- 候选行数。
            v_updated_count,                                                       -- 更新行数。
            GREATEST(v_total_nonnull_count - v_updated_count, 0),                  -- 跳过行数，避免出现负数。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3) -- 执行耗时。
        )::text,                                                                   -- msg：执行摘要。
        v_table_reg::text,                                                         -- table_name：解析后的真实表名。
        p_geom_column,                                                             -- geom_column：处理的几何列名。
        v_candidate_count,                                                         -- candidate_count：候选行数。
        v_updated_count,                                                           -- updated_count：更新行数。
        GREATEST(v_total_nonnull_count - v_updated_count, 0),                      -- skipped_count：跳过行数。
        ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);    -- elapsed_seconds：总耗时。

EXCEPTION WHEN OTHERS THEN
    -- 9. 捕获异常并以结果集返回，避免批处理调用时只有报错没有上下文。
    --    这里不重新抛异常，便于接口统一按 code/msg 处理。
    RETURN QUERY SELECT
        500,                                                                       -- code：执行异常。
        format('DEM补高失败：%s，执行时间 %s 秒',
            SQLERRM,                                                               -- PostgreSQL 返回的异常信息。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3) -- 失败前耗时。
        )::text,                                                                   -- msg：失败摘要。
        COALESCE(v_table_reg::text, p_table_name),                                 -- table_name：优先返回已解析表名，否则回显入参。
        p_geom_column,                                                             -- geom_column：回显处理列名。
        v_candidate_count,                                                         -- candidate_count：异常前已统计到的候选行数。
        v_updated_count,                                                           -- updated_count：异常前已更新行数，通常为 0。
        0::bigint,                                                                 -- skipped_count：异常时不再计算跳过行数。
        ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);    -- elapsed_seconds：失败前耗时。
END;
$$;

COMMENT ON FUNCTION public.gis_dem_update_table_z0(text, text, integer) IS '按表名和几何列名分类型分批补DEM高程：二维点线面或Z全为0的点线面会更新，已有非0 Z保持不变';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT gis_drop_function('gis_dem_reset_table_z0');

-- =============================================================================
-- 函数名称：gis_dem_reset_table_z0
-- 函数功能：按表名和几何列名批量清空高程；函数内部按点、线、面分组分批执行。
-- 入参说明：
--   1. p_table_name  表名，支持 'bo_electric_fence' 或 'public.bo_electric_fence'。
--   2. p_geom_column 几何列名，例如 'geom'。
--   3. p_batch_size  每批处理数量，默认 100。
-- 返回说明：
--   code=200 执行成功；updated_count 为实际更新行数；skipped_count 为未更新的非空几何行数。
-- 使用示例：
--   SELECT * FROM public.gis_dem_reset_table_z0('public.bo_electric_fence', 'geom');
-- 注意事项：
--   1. 处理 Point/MultiPoint、LineString/MultiLineString、Polygon/MultiPolygon。
--   2. 二维点/线/面会被转换为 Z=0 的三维几何。
--   3. 三维点/线/面只要存在非 0 Z 值，就会被重置为 Z=0。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_reset_table_z0(
    -- p_table_name：目标表名；可以传不带 schema 的表名，也可以传 schema.table。
    p_table_name text,
    -- p_geom_column：目标几何列名；默认处理 geom 字段。
    p_geom_column text DEFAULT 'geom',
    -- p_batch_size：函数内部每批处理数量；点/线/面会分组分批执行。
    p_batch_size integer DEFAULT 100
)
RETURNS TABLE (
    -- code：执行状态码，200=成功，400=参数错误，500=执行异常。
    code integer,
    -- msg：中文执行说明，包含更新数量和耗时。
    msg text,
    -- table_name：实际解析后的目标表名。
    table_name text,
    -- geom_column：实际处理的几何列名。
    geom_column text,
    -- candidate_count：满足“需要重置 Z 为 0”条件的候选行数。
    candidate_count bigint,
    -- updated_count：本次 UPDATE 实际更新行数。
    updated_count bigint,
    -- skipped_count：非空几何中未更新的行数。
    skipped_count bigint,
    -- elapsed_seconds：函数执行耗时，单位秒。
    elapsed_seconds numeric
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- v_start_time：记录函数开始时间，用于最终返回耗时。
    v_start_time timestamp := clock_timestamp();
    -- v_table_reg：把文本表名解析成 regclass，后续动态 SQL 使用该对象名。
    v_table_reg regclass;
    -- v_column_exists：标记目标几何列是否存在。
    v_column_exists boolean;
    -- v_candidate_count：记录需要重置 Z 的候选行数。
    v_candidate_count bigint := 0;
    -- v_updated_count：记录 UPDATE 实际影响行数。
    v_updated_count bigint := 0;
    -- v_total_nonnull_count：记录目标几何列非空总数，用于计算跳过数量。
    v_total_nonnull_count bigint := 0;
    -- v_batch_count：记录单批更新行数。
    v_batch_count bigint := 0;
    -- v_geom_types：按点、线、面分组处理。
    v_geom_types text[];
BEGIN
    -- 1. 基础参数校验：表名和列名都不能为空。
    --    trim 后为空字符串时直接返回 400，不继续执行动态 SQL。
    IF NULLIF(trim(p_table_name), '') IS NULL THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            '参数错误：表名不能为空'::text,                                         -- msg：错误原因。
            p_table_name,                                                          -- table_name：回显入参表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    IF p_batch_size IS NULL OR p_batch_size <= 0 THEN
        RETURN QUERY SELECT
            400,
            '参数错误：批量大小必须大于0'::text,
            p_table_name,
            p_geom_column,
            0::bigint,
            0::bigint,
            0::bigint,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
        RETURN;
    END IF;

    --    几何列名为空时也直接返回 400。
    IF NULLIF(trim(p_geom_column), '') IS NULL THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            '参数错误：几何列名不能为空'::text,                                     -- msg：错误原因。
            p_table_name,                                                          -- table_name：回显入参表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    -- 2. 将传入表名解析为 regclass，避免动态 SQL 直接拼接不存在的表。
    --    p_table_name 支持 'bo_electric_fence' 和 'public.bo_electric_fence' 两种写法。
    --    如果不带 schema，会按当前 search_path 解析。
    v_table_reg := to_regclass(p_table_name);
    IF v_table_reg IS NULL THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            format('参数错误：表不存在：%s', p_table_name),                         -- msg：提示表不存在。
            p_table_name,                                                          -- table_name：回显入参表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    -- 3. 校验几何列是否真实存在，避免列名写错时进入 UPDATE。
    --    pg_attribute.attrelid 使用 regclass 精确定位目标表。
    --    NOT attisdropped 排除已经删除但仍残留在系统目录中的列。
    SELECT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = v_table_reg
          AND attname = p_geom_column
          AND NOT attisdropped
    )
    INTO v_column_exists;

    IF NOT v_column_exists THEN
        RETURN QUERY SELECT
            400,                                                                   -- code：参数错误。
            format('参数错误：几何列不存在：%s.%s', v_table_reg::text, p_geom_column), -- msg：提示列不存在。
            v_table_reg::text,                                                     -- table_name：解析后的真实表名。
            p_geom_column,                                                         -- geom_column：回显入参列名。
            0::bigint,                                                             -- candidate_count：未执行统计，返回 0。
            0::bigint,                                                             -- updated_count：未执行更新，返回 0。
            0::bigint,                                                             -- skipped_count：未执行统计，返回 0。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3); -- elapsed_seconds：当前耗时。
        RETURN;
    END IF;

    -- 4. 统计非空几何总数，用于返回 skipped_count。
    --    %s 接收 regclass，输出已安全解析的表名；%I 接收列名，按标识符安全转义。
    EXECUTE format(
        'SELECT count(*) FROM %s WHERE %I IS NOT NULL',
        v_table_reg,     -- %s：目标表。
        p_geom_column    -- %I：目标几何列。
    )
    INTO v_total_nonnull_count;

    -- 5. 统计候选数据：
    --    - 只处理 Point/MultiPoint、LineString/MultiLineString、Polygon/MultiPolygon；
    --    - 二维点/线/面需要转换为 Z=0 的三维几何；
    --    - 三维点/线/面只要 Z 最小值或最大值不是 0，就需要重置；
    --    - 已经是 Z 全为 0 的三维点/线/面不会进入候选集。
    EXECUTE format(
        $sql$
        SELECT count(*)
        FROM %s
        WHERE %I IS NOT NULL                                             -- 几何为空无需处理，跳过。
          AND ST_GeometryType(%I) IN (                                   -- 只处理点/线/面及对应 Multi 类型。
              'ST_Point', 'ST_MultiPoint',
              'ST_LineString', 'ST_MultiLineString',
              'ST_Polygon', 'ST_MultiPolygon'
          )
          AND (
              ST_NDims(%I) < 3                                           -- 二维几何需要转换为 Z=0。
              OR COALESCE(ST_ZMin(%I), 0) <> 0                           -- 三维几何最小 Z 不是 0，需要重置。
              OR COALESCE(ST_ZMax(%I), 0) <> 0                           -- 三维几何最大 Z 不是 0，需要重置。
          )
        $sql$,
        v_table_reg,     -- %s：目标表。
        p_geom_column,   -- 第 1 个 %I：IS NOT NULL 的几何列。
        p_geom_column,   -- 第 2 个 %I：ST_GeometryType 的几何列。
        p_geom_column,   -- 第 3 个 %I：ST_NDims 的几何列。
        p_geom_column,   -- 第 4 个 %I：ST_ZMin 的几何列。
        p_geom_column    -- 第 5 个 %I：ST_ZMax 的几何列。
    )
    INTO v_candidate_count;

    -- 6. 对候选数据按点、线、面分组分批执行 Z 重置，并写回原几何列。
    --    ST_Force2D 先去掉原始 Z，ST_Force3DZ(..., 0) 再统一补回 Z=0。
    FOREACH v_geom_types SLICE 1 IN ARRAY ARRAY[
        ARRAY['ST_Point', 'ST_MultiPoint'],
        ARRAY['ST_LineString', 'ST_MultiLineString'],
        ARRAY['ST_Polygon', 'ST_MultiPolygon']
    ] LOOP
        LOOP
            EXECUTE format(
                $sql$
                WITH todo AS (
                    SELECT ctid
                    FROM %s
                    WHERE %I IS NOT NULL
                      AND ST_GeometryType(%I) = ANY (%L::text[])
                      AND (
                          ST_NDims(%I) < 3
                          OR COALESCE(ST_ZMin(%I), 0) <> 0
                          OR COALESCE(ST_ZMax(%I), 0) <> 0
                      )
                    ORDER BY ST_NPoints(%I), ctid
                    LIMIT %s
                )
                UPDATE %s t
                SET %I = ST_Force3DZ(ST_Force2D(t.%I), 0)
                FROM todo
                WHERE t.ctid = todo.ctid
                $sql$,
                v_table_reg,
                p_geom_column,
                p_geom_column,
                v_geom_types,
                p_geom_column,
                p_geom_column,
                p_geom_column,
                p_geom_column,
                p_batch_size,
                v_table_reg,
                p_geom_column,
                p_geom_column
            );

            GET DIAGNOSTICS v_batch_count = ROW_COUNT;
            v_updated_count := v_updated_count + v_batch_count;
            EXIT WHEN v_batch_count = 0;
        END LOOP;
    END LOOP;

    -- 8. 返回执行结果，方便接口或 SQL 控制台直接查看更新数量和耗时。
    RETURN QUERY SELECT
        200,                                                                       -- code：成功。
        format('DEM高程清零完成，候选 %s 条，更新 %s 条，跳过 %s 条，执行时间 %s 秒',
            v_candidate_count,                                                     -- 候选行数。
            v_updated_count,                                                       -- 更新行数。
            GREATEST(v_total_nonnull_count - v_updated_count, 0),                  -- 跳过行数，避免出现负数。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3) -- 执行耗时。
        )::text,                                                                   -- msg：执行摘要。
        v_table_reg::text,                                                         -- table_name：解析后的真实表名。
        p_geom_column,                                                             -- geom_column：处理的几何列名。
        v_candidate_count,                                                         -- candidate_count：候选行数。
        v_updated_count,                                                           -- updated_count：更新行数。
        GREATEST(v_total_nonnull_count - v_updated_count, 0),                      -- skipped_count：跳过行数。
        ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);    -- elapsed_seconds：总耗时。

EXCEPTION WHEN OTHERS THEN
    -- 9. 捕获异常并以结果集返回，避免批处理调用时只有报错没有上下文。
    --    这里不重新抛异常，便于接口统一按 code/msg 处理。
    RETURN QUERY SELECT
        500,                                                                       -- code：执行异常。
        format('DEM高程清零失败：%s，执行时间 %s 秒',
            SQLERRM,                                                               -- PostgreSQL 返回的异常信息。
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3) -- 失败前耗时。
        )::text,                                                                   -- msg：失败摘要。
        COALESCE(v_table_reg::text, p_table_name),                                 -- table_name：优先返回已解析表名，否则回显入参。
        p_geom_column,                                                             -- geom_column：回显处理列名。
        v_candidate_count,                                                         -- candidate_count：异常前已统计到的候选行数。
        v_updated_count,                                                           -- updated_count：异常前已更新行数，通常为 0。
        0::bigint,                                                                 -- skipped_count：异常时不再计算跳过行数。
        ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);    -- elapsed_seconds：失败前耗时。
END;
$$;

COMMENT ON FUNCTION public.gis_dem_reset_table_z0(text, text, integer) IS '按表名和几何列名分类型分批清空DEM高程：点线面的Z值统一重置为0';


-- =============================================================================
-- 调用示例：批量更新表中 Z 为 0 的点/线/面 DEM 高程
-- 说明：
--   1. 以下示例会直接 UPDATE 目标表，请先在测试库或事务中确认候选数量。
--   2. 二维点/线/面或 Z 全为 0 的三维点/线/面会被更新为 DEM 高程。
--   3. 已有非 0 Z 值的数据不会被覆盖。
-- =============================================================================

-- 12.1 先统计 bo_electric_fence.geom 中需要补 DEM 的候选数据
-- SELECT count(*) AS need_update_count
-- FROM public.bo_electric_fence
-- WHERE geom IS NOT NULL
--   AND ST_GeometryType(geom) IN (
--       'ST_Point', 'ST_MultiPoint',
--       'ST_LineString', 'ST_MultiLineString',
--       'ST_Polygon', 'ST_MultiPolygon'
--   )
--   AND (
--       ST_NDims(geom) < 3
--       OR (
--           COALESCE(ST_ZMin(geom), 0) = 0
--           AND COALESCE(ST_ZMax(geom), 0) = 0
--       )
--   );

-- 12.2 批量补 DEM 高程：表名支持 schema.table，列名按实际几何列传入
-- SELECT *
-- FROM public.gis_dem_update_table_z0('public.bo_electric_fence', 'geom');

-- 12.3 在事务中试跑，确认返回结果后再 COMMIT
-- BEGIN;
-- SELECT *
-- FROM public.gis_dem_update_table_z0('public.bo_electric_fence', 'geom');
-- -- 检查更新后的 Z 值范围
-- SELECT
--     id,
--     ST_NDims(geom) AS dims,
--     ST_ZMin(geom) AS z_min,
--     ST_ZMax(geom) AS z_max
-- FROM public.bo_electric_fence
-- WHERE geom IS NOT NULL
-- ORDER BY create_time DESC
-- LIMIT 20;
-- COMMIT;
-- -- 如检查结果不符合预期，可在 COMMIT 前执行：ROLLBACK;


-- =============================================================================
-- 调用示例：批量清空表中点/线/面的 DEM 高程
-- 说明：
--   1. 以下示例会直接 UPDATE 目标表，请先在测试库或事务中确认候选数量。
--   2. 二维点/线/面会被转换为 Z=0 的三维几何。
--   3. 已有非 0 Z 值的点/线/面会被重置为 Z=0。
-- =============================================================================

-- 13.1 先统计 bo_electric_fence.geom 中需要清空高程的候选数据
-- SELECT count(*) AS need_reset_count
-- FROM public.bo_electric_fence
-- WHERE geom IS NOT NULL
--   AND ST_GeometryType(geom) IN (
--       'ST_Point', 'ST_MultiPoint',
--       'ST_LineString', 'ST_MultiLineString',
--       'ST_Polygon', 'ST_MultiPolygon'
--   )
--   AND (
--       ST_NDims(geom) < 3
--       OR COALESCE(ST_ZMin(geom), 0) <> 0
--       OR COALESCE(ST_ZMax(geom), 0) <> 0
--   );

-- 13.2 批量清空 DEM 高程：表名支持 schema.table，列名按实际几何列传入
-- SELECT *
-- FROM public.gis_dem_reset_table_z0('public.bo_electric_fence', 'geom');

-- 13.3 在事务中试跑，确认返回结果后再 COMMIT
-- BEGIN;
-- SELECT *
-- FROM public.gis_dem_reset_table_z0('public.bo_electric_fence', 'geom');
-- -- 检查清空后的 Z 值范围
-- SELECT
--     id,
--     ST_NDims(geom) AS dims,
--     ST_ZMin(geom) AS z_min,
--     ST_ZMax(geom) AS z_max
-- FROM public.bo_electric_fence
-- WHERE geom IS NOT NULL
-- ORDER BY create_time DESC
-- LIMIT 20;
-- COMMIT;
-- -- 如检查结果不符合预期，可在 COMMIT 前执行：ROLLBACK;
