-- =============================================================================
-- 6.1 DEM 高程工具函数
--
-- 函数清单：
--   公共函数
--   gis_dem_validate                  校验 DEM 栅格表是否可用
--   gis_dem_elevation_base            DEM 高程提取和补高程统一入口（唯一核心入口，p_dem_table 可选）
--   gis_dem_parse_geometry_text       解析 WKT/EWKT/GeoJSON 文本为空间 geometry（内部 helper）
--
--   输出函数
--   gis_dem_elevation_point            点/多点补 DEM 高程入口，支持 geometry（自动获取 DEM 表）
--   gis_dem_elevation_line             线/多线补 DEM 高程入口，支持 geometry（自动获取 DEM 表）
--   gis_dem_elevation_polygon          面/多面补 DEM 高程入口，支持 geometry（自动获取 DEM 表）
--   gis_dem_elevation_geometry         按 geometry 自动分发到点/线/面专用入口
--   gis_dem_elevation_text_point       点/多点文本补 DEM 高程入口，支持 WKT/EWKT/GeoJSON
--   gis_dem_elevation_text_line        线/多线文本补 DEM 高程入口，支持 WKT/EWKT/GeoJSON
--   gis_dem_elevation_text_polygon     面/多面文本补 DEM 高程入口，支持 WKT/EWKT/GeoJSON
--   gis_dem_elevation_text             解析 WKT/EWKT/GeoJSON 并返回 DEM 高程结果
--   gis_dem_update_table_z0            按表名和几何列名批量补 DEM 高程
--   gis_dem_reset_table_z0             按表名和几何列名批量清空 DEM 高程
--
-- 统一约定：
--   1. gis_dem_elevation_base 的 p_dem_table 可选：传了用传的，为空时按几何从 public.jc_sheng 自动获取；其余 wrapper 只传 geom，统一走核心入口。
--   2. 输入 geometry 没有 SRID 时按 EPSG:4326 处理。
--   3. 输入 geometry 已有 Z 值时，按 XY 查询 DEM，并用 DEM 高程生成新的 Z 值。
--   4. 表不存在、未命中像元或 jc_sheng 未配置时，Z 值统一为 0。
--   5. gis_dem_elevation_base 是唯一核心入口，内部批量取瓦片、逐点内存取值；其余函数统一走该入口。
--   6. geometry 通用入口使用 gis_dem_elevation_geometry；点/线/面专用入口使用 gis_dem_elevation_point/line/polygon。
--   7. 点/线/面 text 入口使用 gis_dem_elevation_text_point/line/polygon，支持 WKT、EWKT、GeoJSON。
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
SELECT public.gis_drop_function('gis_dem_validate');

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
SELECT public.gis_drop_function('gis_dem_elevation_base');

-- =============================================================================
-- 函数名称：gis_dem_elevation_base
-- 函数功能：DEM 高程提取/补高程统一入口（唯一核心入口）
-- 入参说明：
--   1. p_geom      支持点、多点、线、多线、面、多面和集合，支持二维和三维输入。
--   2. p_dem_table DEM 栅格表名，可选；为空时根据 p_geom 从 public.jc_sheng 自动获取对应省份的 DEM 表。
-- 返回说明：返回带 DEM Z 值的新 geometry；已有 Z 会被 DEM 高程替换。
-- 类型规则：单几何保持原单类型；Multi* 拆分补高程后再合成对应 Multi*；GeometryCollection 会忽略不支持的子类型。
-- 处理逻辑：
--   1. p_dem_table 为空时，按 p_geom（转 4326）与 jc_sheng.geom 做 ST_Intersects，取配置的 gis_dem_table。
--   2. 批量查出与所有顶点相交的 DEM 瓦片（一次 GiST 扫描）。
--   3. 每个顶点在命中的少量瓦片（通常 1~4 片）内取像元值，纯内存计算。
--   4. 表不存在、jc_sheng 未配置或点未命中像元时，Z 值统一为 0。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_base(
    p_geom      geometry,
    p_dem_table text DEFAULT NULL
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dem_reg    regclass;
    v_dem_table  text;
    v_geom_4326  geometry;
    v_result     geometry;
BEGIN
    IF p_geom IS NULL THEN
        RETURN NULL;
    END IF;

    -- 优先使用显式传入的 p_dem_table；为空时从 jc_sheng 按 p_geom 自动获取。
    v_dem_table := NULLIF(trim(COALESCE(p_dem_table, '')), '');

    IF v_dem_table IS NULL AND to_regclass('public.jc_sheng') IS NOT NULL THEN
        v_geom_4326 :=
            CASE
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

    -- 解析 v_dem_table 为 regclass；为空或表不存在时走 Z=0 兜底路径
    v_dem_reg := NULL;
    IF v_dem_table IS NOT NULL THEN
        v_dem_reg := COALESCE(
            to_regclass(v_dem_table),
            to_regclass(format('public.%I', v_dem_table))
        );
    END IF;

    -- 表不存在或未命中：走 Z=0 兜底路径
    IF v_dem_reg IS NULL THEN
        EXECUTE format($sql$
            WITH input_geom AS MATERIALIZED (
                SELECT
                    CASE
                        WHEN ST_SRID($1) = 0 THEN ST_SetSRID(ST_Force2D($1), 4326)
                        ELSE ST_Force2D($1)
                    END AS geom,
                    COALESCE(NULLIF(ST_SRID($1), 0), 4326) AS srid
            ),
            parts AS (
                SELECT (d).path, (d).geom, ST_GeometryType((d).geom) AS geom_type
                FROM input_geom i, LATERAL ST_Dump(i.geom) d
                WHERE i.geom IS NOT NULL
            ),
            vertices AS (
                SELECT p.path, p.geom_type, (dp).path AS point_path, (dp).geom AS point_geom
                FROM parts p, LATERAL ST_DumpPoints(p.geom) dp
                WHERE p.geom_type IN ('ST_Point','ST_LineString','ST_Polygon')
            ),
            z_vertices AS (
                SELECT path, geom_type, point_path,
                       ST_MakePoint(ST_X(point_geom), ST_Y(point_geom), 0) AS point_geom
                FROM vertices
            ),
            z_lines AS (
                SELECT path, ST_MakeLine(point_geom ORDER BY point_path[1]) AS geom
                FROM z_vertices WHERE geom_type='ST_LineString' GROUP BY path
            ),
            z_rings AS (
                SELECT path, point_path[1] AS ring_no,
                       ST_MakeLine(point_geom ORDER BY point_path[2]) AS ring_geom
                FROM z_vertices WHERE geom_type='ST_Polygon'
                GROUP BY path, point_path[1]
            ),
            z_polygons AS (
                SELECT path, ST_MakePolygon(
                    (SELECT ring_geom FROM z_rings WHERE path=zr.path AND ring_no=1),
                    COALESCE(ARRAY(SELECT ring_geom FROM z_rings WHERE path=zr.path AND ring_no>1 ORDER BY ring_no), ARRAY[]::geometry[])
                ) AS geom
                FROM z_rings zr GROUP BY path
            ),
            z_parts AS (
                SELECT p.path,
                    CASE p.geom_type
                        WHEN 'ST_Point' THEN (SELECT point_geom FROM z_vertices WHERE path=p.path LIMIT 1)
                        WHEN 'ST_LineString' THEN (SELECT geom FROM z_lines WHERE path=p.path)
                        WHEN 'ST_Polygon' THEN (SELECT geom FROM z_polygons WHERE path=p.path)
                        ELSE NULL::geometry
                    END AS geom
                FROM parts p
            )
            SELECT CASE
                WHEN (SELECT geom FROM input_geom) IS NULL THEN NULL::geometry
                WHEN NOT EXISTS (SELECT 1 FROM z_parts WHERE geom IS NOT NULL) THEN NULL::geometry
                WHEN ST_GeometryType((SELECT geom FROM input_geom)) IN ('ST_Point','ST_LineString','ST_Polygon')
                    THEN ST_SetSRID((SELECT geom FROM z_parts ORDER BY path LIMIT 1), (SELECT srid FROM input_geom))
                WHEN ST_GeometryType((SELECT geom FROM input_geom))='ST_GeometryCollection'
                    THEN ST_SetSRID(ST_Collect(zp.geom ORDER BY zp.path), (SELECT srid FROM input_geom))
                ELSE ST_SetSRID(
                    ST_CollectionExtract(ST_Collect(zp.geom ORDER BY zp.path),
                        CASE ST_GeometryType((SELECT geom FROM input_geom))
                            WHEN 'ST_MultiPoint' THEN 1
                            WHEN 'ST_MultiLineString' THEN 2
                            WHEN 'ST_MultiPolygon' THEN 3
                            ELSE 0 END),
                    (SELECT srid FROM input_geom))
            END
            FROM input_geom, z_parts AS zp WHERE zp.geom IS NOT NULL;
        $sql$) USING p_geom INTO v_result;
        RETURN v_result;
    END IF;

    -- 表存在：批量取瓦片 + 逐点内存取值
    EXECUTE format($sql$
        WITH input_geom AS MATERIALIZED (
            SELECT
                CASE
                    WHEN ST_SRID($1) = 0 THEN ST_SetSRID(ST_Force2D($1), 4326)
                    WHEN ST_SRID($1) = 4326 THEN ST_Force2D($1)
                    ELSE ST_Transform(ST_Force2D($1), 4326)
                END AS geom,
                COALESCE(NULLIF(ST_SRID($1), 0), 4326) AS srid
        ),
        parts AS (
            SELECT (d).path, (d).geom, ST_GeometryType((d).geom) AS geom_type
            FROM input_geom i, LATERAL ST_Dump(i.geom) d
            WHERE i.geom IS NOT NULL
        ),
        vertices AS (
            SELECT p.path, p.geom_type, (dp).path AS point_path, (dp).geom AS point_geom
            FROM parts p, LATERAL ST_DumpPoints(p.geom) dp
            WHERE p.geom_type IN ('ST_Point','ST_LineString','ST_Polygon')
        ),
        hit_tiles AS (
            SELECT r.rid, r.rast
            FROM %s r
            WHERE r.rast IS NOT NULL
              AND r.rast && (SELECT ST_Collect(point_geom) FROM vertices)
              AND ST_Intersects(r.rast, (SELECT ST_Collect(point_geom) FROM vertices))
        ),
        z_vertices AS (
            SELECT v.path, v.geom_type, v.point_path,
                   ST_MakePoint(
                       ST_X(v.point_geom),
                       ST_Y(v.point_geom),
                       COALESCE(h.elev, 0)
                   ) AS point_geom
            FROM vertices v
            LEFT JOIN LATERAL (
                SELECT ST_Value(ht.rast, 1, v.point_geom) AS elev
                FROM hit_tiles ht
                WHERE ht.rast && v.point_geom
                  AND ST_Intersects(ht.rast, v.point_geom)
                ORDER BY ht.rid LIMIT 1
            ) h ON true
        ),
        z_lines AS (
            SELECT path, ST_MakeLine(point_geom ORDER BY point_path[1]) AS geom
            FROM z_vertices WHERE geom_type='ST_LineString' GROUP BY path
        ),
        z_rings AS (
            SELECT path, point_path[1] AS ring_no,
                   ST_MakeLine(point_geom ORDER BY point_path[2]) AS ring_geom
            FROM z_vertices WHERE geom_type='ST_Polygon'
            GROUP BY path, point_path[1]
        ),
        z_polygons AS (
            SELECT path, ST_MakePolygon(
                (SELECT ring_geom FROM z_rings WHERE path=zr.path AND ring_no=1),
                COALESCE(ARRAY(SELECT ring_geom FROM z_rings WHERE path=zr.path AND ring_no>1 ORDER BY ring_no), ARRAY[]::geometry[])
            ) AS geom
            FROM z_rings zr GROUP BY path
        ),
        z_parts AS (
            SELECT p.path,
                CASE p.geom_type
                    WHEN 'ST_Point' THEN (SELECT point_geom FROM z_vertices WHERE path=p.path LIMIT 1)
                    WHEN 'ST_LineString' THEN (SELECT geom FROM z_lines WHERE path=p.path)
                    WHEN 'ST_Polygon' THEN (SELECT geom FROM z_polygons WHERE path=p.path)
                    ELSE NULL::geometry
                END AS geom
            FROM parts p
        )
        SELECT CASE
            WHEN (SELECT geom FROM input_geom) IS NULL THEN NULL::geometry
            WHEN NOT EXISTS (SELECT 1 FROM z_parts WHERE geom IS NOT NULL) THEN NULL::geometry
            WHEN ST_GeometryType((SELECT geom FROM input_geom)) IN ('ST_Point','ST_LineString','ST_Polygon')
                THEN ST_SetSRID((SELECT geom FROM z_parts ORDER BY path LIMIT 1), (SELECT srid FROM input_geom))
            WHEN ST_GeometryType((SELECT geom FROM input_geom))='ST_GeometryCollection'
                THEN ST_SetSRID(ST_Collect(zp.geom ORDER BY zp.path), (SELECT srid FROM input_geom))
            ELSE ST_SetSRID(
                ST_CollectionExtract(ST_Collect(zp.geom ORDER BY zp.path),
                    CASE ST_GeometryType((SELECT geom FROM input_geom))
                        WHEN 'ST_MultiPoint' THEN 1
                        WHEN 'ST_MultiLineString' THEN 2
                        WHEN 'ST_MultiPolygon' THEN 3
                        ELSE 0 END),
                (SELECT srid FROM input_geom))
        END
        FROM input_geom, z_parts AS zp WHERE zp.geom IS NOT NULL;
    $sql$, v_dem_reg) USING p_geom INTO v_result;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_base(geometry, text) IS 'DEM高程提取和补高程统一入口（唯一核心入口，p_dem_table 为空时按几何从jc_sheng自动获取）';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_parse_geometry_text');

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
-- 输出函数
-- =============================================================================
-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_elevation_point');

-- =============================================================================
-- 函数名称：gis_dem_elevation_point
-- 函数功能：点/多点补高程入口，返回带 DEM Z 值的新点或多点
-- 入参说明：p_point 支持 Point 和 MultiPoint。
-- 返回说明：Point 返回 PointZ；MultiPoint 返回 MultiPointZ。
-- 适用场景：业务语义明确为点位、航点或点集时使用；可避免误把线面传入点接口。
-- 注意事项：该函数是语义化包装，内部调用 gis_dem_elevation_base（p_dem_table 留空，由核心函数按几何从 jc_sheng 自动获取）；非点类型会直接抛错。
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

    RETURN public.gis_dem_elevation_base(p_point);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_point(geometry) IS '点/多点补DEM高程入口（自动获取DEM表）';


-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_elevation_line');

-- =============================================================================
-- 函数名称：gis_dem_elevation_line
-- 函数功能：线/多线补高程入口，返回带 DEM Z 值的新线或多线
-- 入参说明：p_line 支持 LineString 和 MultiLineString。
-- 返回说明：LineString 返回 LineStringZ；MultiLineString 返回 MultiLineStringZ。
-- 适用场景：业务语义明确为航线、轨迹或线路时使用；可避免误把面或点传入线接口。
-- 注意事项：该函数是语义化包装，内部调用 gis_dem_elevation_base（p_dem_table 留空，由核心函数按几何从 jc_sheng 自动获取）；非线类型会直接抛错。
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

    RETURN public.gis_dem_elevation_base(p_line);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_line(geometry) IS '线/多线补DEM高程入口（自动获取DEM表）';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_elevation_polygon');

-- =============================================================================
-- 函数名称：gis_dem_elevation_polygon
-- 函数功能：面/多面补高程入口，返回带 DEM Z 值的新面或多面
-- 入参说明：p_polygon 支持 Polygon 和 MultiPolygon。
-- 返回说明：Polygon 返回 PolygonZ；MultiPolygon 返回 MultiPolygonZ。
-- 适用场景：业务语义明确为面范围、作业区域或禁飞区范围时使用；可避免误把点线传入面接口。
-- 注意事项：该函数是语义化包装，内部调用 gis_dem_elevation_base（p_dem_table 留空，由核心函数按几何从 jc_sheng 自动获取）；非面类型会直接抛错。
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

    RETURN public.gis_dem_elevation_base(p_polygon);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_polygon(geometry) IS '面/多面补DEM高程入口（自动获取DEM表）';
-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_elevation_geometry');

-- =============================================================================
-- 函数名称：gis_dem_elevation_geometry
-- 函数功能：根据 geometry 类型分发到点/线/面专用入口
-- 入参说明：支持 Point/MultiPoint、LineString/MultiLineString、Polygon/MultiPolygon；其他几何回退基础入口。
-- 返回说明：返回对应专用入口的补 DEM 高程结果。
-- 适用场景：业务侧只有 geometry，不想自己判断几何类型时使用。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_elevation_geometry(
    p_geom geometry
)
RETURNS geometry
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_type text;
BEGIN
    IF p_geom IS NULL THEN
        RETURN NULL;
    END IF;

    v_type := ST_GeometryType(p_geom);

    IF v_type IN ('ST_Point', 'ST_MultiPoint') THEN
        RETURN public.gis_dem_elevation_point(p_geom);
    ELSIF v_type IN ('ST_LineString', 'ST_MultiLineString') THEN
        RETURN public.gis_dem_elevation_line(p_geom);
    ELSIF v_type IN ('ST_Polygon', 'ST_MultiPolygon') THEN
        RETURN public.gis_dem_elevation_polygon(p_geom);
    END IF;

    RETURN public.gis_dem_elevation_base(p_geom);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_elevation_geometry(geometry) IS '根据geometry类型自动分发到点线面补DEM高程入口';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_elevation_text_point');

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
SELECT public.gis_drop_function('gis_dem_elevation_text_line');

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
SELECT public.gis_drop_function('gis_dem_elevation_text_polygon');

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
SELECT public.gis_drop_function('gis_dem_elevation_text');

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

    -- 第三步：直接走 gis_dem_elevation_base，p_dem_table 留空由核心函数按几何从 jc_sheng 自动获取。
    v_result_geom := public.gis_dem_elevation_base(v_geom);

    -- 第四步：点/多点返回补高程后的结果几何；单点额外返回 elevation 字段。
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

    -- 第五步：线/多线通过基础入口补 DEM Z，返回 result_geom/result_wkt。
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

    -- 第六步：面/多面/集合通过基础入口补 DEM Z，返回 result_geom/result_wkt。
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

COMMENT ON FUNCTION public.gis_dem_elevation_text(text) IS '解析WKT、EWKT或GeoJSON并返回DEM高程结果（自动获取DEM表）';

-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_update_table_z0');

-- =============================================================================
-- 函数名称：gis_dem_update_table_z0
-- 函数功能：按表名和几何列名补 DEM 高程；点批量执行，线/面单条执行。
-- 入参说明：
--   1. p_table_name  表名，支持 'bo_electric_fence' 或 'public.bo_electric_fence'。
--   2. p_geom_column 几何列名，例如 'geom'。
-- 返回说明：
--   code=200 执行成功；updated_count 为实际更新行数；skipped_count 为未更新的非空几何行数。
-- 使用示例：
--   SELECT * FROM public.gis_dem_update_table_z0('public.bo_electric_fence', 'geom');
-- 注意事项：
--   1. 处理 Point/MultiPoint（批量）、LineString/MultiLineString（单条）、Polygon/MultiPolygon（单条）。
--   2. 二维 geometry 也会视为需要补高程。
--   3. 三维 geometry 只有 ST_ZMin=0 且 ST_ZMax=0 时才会补 DEM，已有真实高程不会覆盖。
--   4. 每行调用 gis_dem_elevation_base，p_dem_table 留空由核心函数按几何从 jc_sheng 自动获取。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_update_table_z0(
    -- p_table_name：目标表名；可以传不带 schema 的表名，也可以传 schema.table。
    p_table_name text,
    -- p_geom_column：目标几何列名；默认处理 geom 字段。
    p_geom_column text DEFAULT 'geom'
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
    -- candidate_count：需要补高程的候选行数。
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
    v_start_time timestamp := clock_timestamp();
    v_table_reg regclass;
    v_column_exists boolean;
    v_candidate_count bigint := 0;
    v_updated_count bigint := 0;
    v_total_nonnull_count bigint := 0;
    v_row_count bigint := 0;
    v_ctid text;
    v_line_ctids text[];
    v_polygon_ctids text[];
BEGIN
    -- 1. 基础参数校验
    IF NULLIF(trim(p_table_name), '') IS NULL THEN
        RETURN QUERY SELECT 400, '参数错误：表名不能为空'::text,
            p_table_name, p_geom_column, 0::bigint, 0::bigint, 0::bigint,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
        RETURN;
    END IF;

    IF NULLIF(trim(p_geom_column), '') IS NULL THEN
        RETURN QUERY SELECT 400, '参数错误：几何列名不能为空'::text,
            p_table_name, p_geom_column, 0::bigint, 0::bigint, 0::bigint,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
        RETURN;
    END IF;

    -- 2. 解析表名
    v_table_reg := to_regclass(p_table_name);
    IF v_table_reg IS NULL THEN
        RETURN QUERY SELECT 400, format('参数错误：表不存在：%s', p_table_name),
            p_table_name, p_geom_column, 0::bigint, 0::bigint, 0::bigint,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
        RETURN;
    END IF;

    -- 3. 校验几何列
    SELECT EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = v_table_reg AND attname = p_geom_column AND NOT attisdropped
    ) INTO v_column_exists;

    IF NOT v_column_exists THEN
        RETURN QUERY SELECT 400,
            format('参数错误：几何列不存在：%s.%s', v_table_reg::text, p_geom_column),
            v_table_reg::text, p_geom_column, 0::bigint, 0::bigint, 0::bigint,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
        RETURN;
    END IF;

    -- 4. 统计非空几何总数
    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NOT NULL', v_table_reg, p_geom_column)
    INTO v_total_nonnull_count;

    -- 5. 统计候选数据
    EXECUTE format(
        'SELECT count(*) FROM %s WHERE %I IS NOT NULL
          AND ST_GeometryType(%I) IN (''ST_Point'', ''ST_MultiPoint'', ''ST_LineString'', ''ST_MultiLineString'', ''ST_Polygon'', ''ST_MultiPolygon'')
          AND (ST_NDims(%I) < 3 OR (COALESCE(ST_ZMin(%I), 0) = 0 AND COALESCE(ST_ZMax(%I), 0) = 0))',
        v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column
    ) INTO v_candidate_count;

    -- 6. 执行 DEM 补高：点批量执行，线/面单条执行
    RAISE NOTICE '[DEM补高] 开始执行 | 表名: % | 候选: % 条', v_table_reg::text, v_candidate_count;

    -- 6.1 点类型：批量执行（一次性处理所有点）
    EXECUTE format(
        'WITH todo AS (
            SELECT ctid FROM %s
            WHERE %I IS NOT NULL
              AND ST_GeometryType(%I) = ANY (ARRAY[''ST_Point'', ''ST_MultiPoint'']::text[])
              AND (ST_NDims(%I) < 3 OR (COALESCE(ST_ZMin(%I), 0) = 0 AND COALESCE(ST_ZMax(%I), 0) = 0))
        )
        UPDATE %s t SET %I = public.gis_dem_elevation_base(t.%I)
        FROM todo WHERE t.ctid = todo.ctid',
        v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column,
        v_table_reg, p_geom_column, p_geom_column
    );
    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    v_updated_count := v_updated_count + v_row_count;
    RAISE NOTICE '[DEM补高] 点类型批量完成 | 更新: % 条 | 累计: % 条', v_row_count, v_updated_count;

    -- 6.2 线类型：单条执行（逐条处理，先用数组锁定 ctid）
        EXECUTE format(
            'SELECT array_agg(ctid::text) FROM (
                SELECT ctid FROM %s
                WHERE %I IS NOT NULL
                  AND ST_GeometryType(%I) = ANY (ARRAY[''ST_LineString'', ''ST_MultiLineString'']::text[])
                  AND (ST_NDims(%I) < 3 OR (COALESCE(ST_ZMin(%I), 0) = 0 AND COALESCE(ST_ZMax(%I), 0) = 0))
                ORDER BY ST_NPoints(%I), ctid
            ) t',
            v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column
        )
        INTO v_line_ctids;

        IF v_line_ctids IS NOT NULL THEN
            FOREACH v_ctid IN ARRAY v_line_ctids LOOP
                EXECUTE format(
                    'UPDATE %s t SET %I = public.gis_dem_elevation_base(t.%I)
                     WHERE t.ctid::text = %L',
                    v_table_reg, p_geom_column, p_geom_column, v_ctid
                );
                GET DIAGNOSTICS v_row_count = ROW_COUNT;
                v_updated_count := v_updated_count + v_row_count;
                RAISE NOTICE '[DEM补高] 线类型处理 | ctid: % | 累计: % 条', v_ctid, v_updated_count;
            END LOOP;
        END IF;

    -- 6.3 面类型：单条执行（逐条处理，先用数组锁定 ctid）
        EXECUTE format(
            'SELECT array_agg(ctid::text) FROM (
                SELECT ctid FROM %s
                WHERE %I IS NOT NULL
                  AND ST_GeometryType(%I) = ANY (ARRAY[''ST_Polygon'', ''ST_MultiPolygon'']::text[])
                  AND (ST_NDims(%I) < 3 OR (COALESCE(ST_ZMin(%I), 0) = 0 AND COALESCE(ST_ZMax(%I), 0) = 0))
                ORDER BY ST_NPoints(%I), ctid
            ) t',
            v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column
        )
        INTO v_polygon_ctids;

        IF v_polygon_ctids IS NOT NULL THEN
            FOREACH v_ctid IN ARRAY v_polygon_ctids LOOP
                EXECUTE format(
                    'UPDATE %s t SET %I = public.gis_dem_elevation_base(t.%I)
                     WHERE t.ctid::text = %L',
                    v_table_reg, p_geom_column, p_geom_column, v_ctid
                );
                GET DIAGNOSTICS v_row_count = ROW_COUNT;
                v_updated_count := v_updated_count + v_row_count;
                RAISE NOTICE '[DEM补高] 面类型处理 | ctid: % | 累计: % 条', v_ctid, v_updated_count;
            END LOOP;
        END IF;

    -- 7. 返回执行结果
    RETURN QUERY SELECT 200,
        format('DEM补高完成，候选 %s 条，更新 %s 条，跳过 %s 条，执行时间 %s 秒',
            v_candidate_count, v_updated_count,
            GREATEST(v_total_nonnull_count - v_updated_count, 0),
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::text,
        v_table_reg::text, p_geom_column, v_candidate_count, v_updated_count,
        GREATEST(v_total_nonnull_count - v_updated_count, 0),
        ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 500,
        format('DEM补高失败：%s，执行时间 %s 秒', SQLERRM,
            ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::text,
        COALESCE(v_table_reg::text, p_table_name), p_geom_column,
        v_candidate_count, v_updated_count, 0::bigint,
        ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3);
END;
$$;

COMMENT ON FUNCTION public.gis_dem_update_table_z0(text, text) IS '按表名、几何列名分类型补DEM高程：点批量执行，线/面单条执行；二维点线面或Z全为0的点线面会更新，已有非0 Z保持不变';
-- =============================================================================
-- 重建函数前清理
-- =============================================================================
SELECT public.gis_drop_function('gis_dem_reset_table_z0');

-- =============================================================================
-- 函数名称：gis_dem_reset_table_z0
-- 函数功能：按表名和几何列名清空 DEM 高程；点批量执行，线/面单条执行。
-- 入参说明：
--   1. p_table_name  表名，支持 'bo_electric_fence' 或 'public.bo_electric_fence'。
--   2. p_geom_column 几何列名，例如 'geom'。
-- 返回说明：
--   code=200 执行成功；updated_count 为实际更新行数；skipped_count 为未更新的非空几何行数。
-- 使用示例：
--   SELECT * FROM public.gis_dem_reset_table_z0('public.bo_electric_fence', 'geom');
-- 注意事项：
--   1. 处理 Point/MultiPoint（批量）、LineString/MultiLineString（单条）、Polygon/MultiPolygon（单条）。
--   2. 二维点/线/面会被转换为 Z=0 的三维几何。
--   3. 三维点/线/面只要存在非 0 Z 值，就会被重置为 Z=0。
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gis_dem_reset_table_z0(
    -- p_table_name：目标表名；可以传不带 schema 的表名，也可以传 schema.table。
    p_table_name text,
    -- p_geom_column：目标几何列名；默认处理 geom 字段。
    p_geom_column text DEFAULT 'geom'
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
    -- v_row_count：记录单条/批量更新行数。
    v_row_count bigint := 0;
    v_ctid text;
    v_line_ctids text[];
    v_polygon_ctids text[];
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

    -- 6. 执行 DEM 清零：点批量执行，线/面单条执行
    --    ST_Force2D 先去掉原始 Z，ST_Force3DZ(..., 0) 再统一补回 Z=0。
    RAISE NOTICE '[DEM清零] 开始执行 | 表名: % | 候选: % 条', v_table_reg::text, v_candidate_count;

    -- 6.1 点类型：批量执行（一次性处理所有点）
    EXECUTE format(
        'WITH todo AS (
            SELECT ctid FROM %s
            WHERE %I IS NOT NULL
              AND ST_GeometryType(%I) = ANY (ARRAY[''ST_Point'', ''ST_MultiPoint'']::text[])
              AND (ST_NDims(%I) < 3 OR COALESCE(ST_ZMin(%I), 0) <> 0 OR COALESCE(ST_ZMax(%I), 0) <> 0)
        )
        UPDATE %s t SET %I = ST_Force3DZ(ST_Force2D(t.%I), 0)
        FROM todo WHERE t.ctid = todo.ctid',
        v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column,
        v_table_reg, p_geom_column, p_geom_column
    );
    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    v_updated_count := v_updated_count + v_row_count;
    RAISE NOTICE '[DEM清零] 点类型批量完成 | 更新: % 条 | 累计: % 条', v_row_count, v_updated_count;

    -- 6.2 线类型：单条执行（逐条处理，先用数组锁定 ctid）
        EXECUTE format(
            'SELECT array_agg(ctid::text) FROM (
                SELECT ctid FROM %s
                WHERE %I IS NOT NULL
                  AND ST_GeometryType(%I) = ANY (ARRAY[''ST_LineString'', ''ST_MultiLineString'']::text[])
                  AND (ST_NDims(%I) < 3 OR COALESCE(ST_ZMin(%I), 0) <> 0 OR COALESCE(ST_ZMax(%I), 0) <> 0)
                ORDER BY ST_NPoints(%I), ctid
            ) t',
            v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column
        )
        INTO v_line_ctids;

        IF v_line_ctids IS NOT NULL THEN
            FOREACH v_ctid IN ARRAY v_line_ctids LOOP
                EXECUTE format(
                    'UPDATE %s t SET %I = ST_Force3DZ(ST_Force2D(t.%I), 0)
                     WHERE t.ctid::text = %L',
                    v_table_reg, p_geom_column, p_geom_column, v_ctid
                );
                GET DIAGNOSTICS v_row_count = ROW_COUNT;
                v_updated_count := v_updated_count + v_row_count;
                RAISE NOTICE '[DEM清零] 线类型处理 | ctid: % | 累计: % 条', v_ctid, v_updated_count;
            END LOOP;
        END IF;

    -- 6.3 面类型：单条执行（逐条处理，先用数组锁定 ctid）
        EXECUTE format(
            'SELECT array_agg(ctid::text) FROM (
                SELECT ctid FROM %s
                WHERE %I IS NOT NULL
                  AND ST_GeometryType(%I) = ANY (ARRAY[''ST_Polygon'', ''ST_MultiPolygon'']::text[])
                  AND (ST_NDims(%I) < 3 OR COALESCE(ST_ZMin(%I), 0) <> 0 OR COALESCE(ST_ZMax(%I), 0) <> 0)
                ORDER BY ST_NPoints(%I), ctid
            ) t',
            v_table_reg, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column, p_geom_column
        )
        INTO v_polygon_ctids;

        IF v_polygon_ctids IS NOT NULL THEN
            FOREACH v_ctid IN ARRAY v_polygon_ctids LOOP
                EXECUTE format(
                    'UPDATE %s t SET %I = ST_Force3DZ(ST_Force2D(t.%I), 0)
                     WHERE t.ctid::text = %L',
                    v_table_reg, p_geom_column, p_geom_column, v_ctid
                );
                GET DIAGNOSTICS v_row_count = ROW_COUNT;
                v_updated_count := v_updated_count + v_row_count;
                RAISE NOTICE '[DEM清零] 面类型处理 | ctid: % | 累计: % 条', v_ctid, v_updated_count;
            END LOOP;
        END IF;

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

COMMENT ON FUNCTION public.gis_dem_reset_table_z0(text, text) IS '按表名和几何列名分类型清空DEM高程：点批量执行，线/面单条执行';


-- =============================================================================
-- 调用示例
-- =============================================================================

-- 1. gis_dem_validate
-- 校验 public.jc_sheng 配置的 DEM 表是否可用。
-- SELECT * FROM public.gis_dem_validate();

-- 2. gis_dem_elevation_base
-- DEM 核心入口，p_dem_table 留空时按几何从 jc_sheng 自动获取。
-- SELECT ST_AsText(public.gis_dem_elevation_base(ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)));

-- 3. gis_dem_parse_geometry_text
-- 解析 WKT、EWKT 或 GeoJSON 文本为空间 geometry。
-- SELECT ST_AsText(public.gis_dem_parse_geometry_text('POINT(113.65 34.76)'));

-- 4. gis_dem_elevation_point
-- 点/多点 geometry 入口。
-- SELECT ST_AsText(public.gis_dem_elevation_point(ST_SetSRID(ST_MakePoint(113.65, 34.76), 4326)));

-- 5. gis_dem_elevation_line
-- 线/多线 geometry 入口。
-- SELECT ST_AsText(public.gis_dem_elevation_line(ST_GeomFromText('LINESTRING(113.60 34.70,113.70 34.80)', 4326)));

-- 6. gis_dem_elevation_polygon
-- 面/多面 geometry 入口。
-- SELECT ST_AsText(public.gis_dem_elevation_polygon(ST_GeomFromText('POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))', 4326)));

-- 7. gis_dem_elevation_geometry
-- 根据 geometry 自动分发到点/线/面专用入口。
-- SELECT ST_AsText(public.gis_dem_elevation_geometry(ST_GeomFromText('LINESTRING(113.60 34.70,113.70 34.80)', 4326)));

-- 8. gis_dem_elevation_text_point
-- 点/多点文本入口。
-- SELECT ST_AsText(public.gis_dem_elevation_text_point('POINT(113.65 34.76)'));

-- 9. gis_dem_elevation_text_line
-- 线/多线文本入口。
-- SELECT ST_AsText(public.gis_dem_elevation_text_line('LINESTRING(113.60 34.70,113.70 34.80)'));

-- 10. gis_dem_elevation_text_polygon
-- 面/多面文本入口。
-- SELECT ST_AsText(public.gis_dem_elevation_text_polygon('POLYGON((113.60 34.70,113.70 34.70,113.70 34.80,113.60 34.80,113.60 34.70))'));

-- 11. gis_dem_elevation_text
-- 统一文本入口。
-- SELECT * FROM public.gis_dem_elevation_text('POINT(113.65 34.76)');

-- 12. gis_dem_update_table_z0
-- 按表名和几何列名批量补 DEM 高程。
-- SELECT * FROM public.gis_dem_update_table_z0('public.bo_electric_fence', 'geom');

-- 13. gis_dem_reset_table_z0
-- 按表名和几何列名批量清空 DEM 高程。
-- SELECT * FROM public.gis_dem_reset_table_z0('public.bo_electric_fence', 'geom');
