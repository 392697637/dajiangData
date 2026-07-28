-- =============================================================================
-- 7.反制设备.sql
--   gis_counter_device         保存/更新反制设备规则
--   gis_counter_device_check   实时点位校验
--
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- ============================================================
-- 函数名称：gis_counter_device
-- 函数功能：保存或更新反制设备规则
-- 函数描述：
--   1. 接收项目ID、设备GeoJSON点数据、反制作用半径、预警半径、通知半径、高度范围。
--   2. 函数内部自动创建并维护规则存储表 public.gis_counter_device_rule。
--   3. 按“项目ID + 设备点位”生成规则ID，同项目同点位重复传入时更新原规则。
--   4. 半径单位统一为米，半径为空表示对应级别不启用。
--   5. 有效最低高度、有效最高高度为空表示不限制。
-- 函数说明：依赖PostGIS空间扩展，坐标系使用WGS84(4326)
-- 适用场景：保存反制设备点位及其作用/预警/通知规则，供实时点位校验使用
-- ============================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_counter_device');

-- =============================================================================
-- 函数介绍：gis_counter_device
-- 主要作用：根据项目ID、设备GeoJSON点数据和半径高度参数保存/更新反制设备规则
-- 入参说明：
--   p_project_id        项目ID
--   p_device_geojson    设备GeoJSON点数据，支持Point、Feature或[lng,lat]
--   p_action_radius_m   反制作用半径，单位：米；为空表示不启用
--   p_warning_radius_m  预警半径，单位：米；为空表示不启用
--   p_notice_radius_m   通知半径，单位：米；为空表示不启用
--   p_min_alt           有效最低高度，单位：米；为空表示不限制
--   p_max_alt           有效最高高度，单位：米；为空表示不限制
-- 返回说明：标准基础返回
--   code        integer     状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg         varchar     状态描述信息
-- 注意事项：保存/更新依据为“项目ID + 设备点位”，不是设备名称或业务ID
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_counter_device(
    p_project_id text,
    p_device_geojson text,
    p_action_radius_m double precision DEFAULT NULL,
    p_warning_radius_m double precision DEFAULT NULL,
    p_notice_radius_m double precision DEFAULT NULL,
    p_min_alt double precision DEFAULT NULL,
    p_max_alt double precision DEFAULT NULL
)
RETURNS TABLE (
    code integer,       -- 返回：状态码
    msg varchar         -- 返回：状态信息
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_json jsonb;
    v_geom geometry(Point, 4326);
    v_rule_id varchar(64);
    v_project_id varchar(64);
BEGIN
    CREATE TABLE IF NOT EXISTS public.gis_counter_device_rule (
        id varchar(64) PRIMARY KEY,
        project_id varchar(64) NOT NULL,
        action_radius_m double precision,
        warning_radius_m double precision,
        notice_radius_m double precision,
        min_alt double precision,
        max_alt double precision,
        lng double precision NOT NULL,
        lat double precision NOT NULL,
        geom geometry(Point, 4326) NOT NULL,
        geog geography(Point, 4326) NOT NULL,
        create_time timestamptz NOT NULL DEFAULT now(),
        update_time timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT chk_counter_device_rule_radius CHECK (
            COALESCE(action_radius_m, 0) >= 0
            AND COALESCE(warning_radius_m, 0) >= 0
            AND COALESCE(notice_radius_m, 0) >= 0
        ),
        CONSTRAINT chk_counter_device_rule_alt CHECK (
            min_alt IS NULL OR max_alt IS NULL OR min_alt <= max_alt
        )
    );

    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS project_id varchar(64);
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS action_radius_m double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS warning_radius_m double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS notice_radius_m double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS min_alt double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS max_alt double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS lng double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS lat double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS geom geometry(Point, 4326);
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS geog geography(Point, 4326);
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS create_time timestamptz DEFAULT now();
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS update_time timestamptz DEFAULT now();

    CREATE INDEX IF NOT EXISTS idx_counter_device_rule_project
        ON public.gis_counter_device_rule (project_id);

    CREATE INDEX IF NOT EXISTS idx_counter_device_rule_geog
        ON public.gis_counter_device_rule USING GIST (geog);

    CREATE INDEX IF NOT EXISTS idx_counter_device_rule_alt
        ON public.gis_counter_device_rule (min_alt, max_alt);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        RETURN QUERY SELECT 400, '项目ID不能为空'::varchar;
        RETURN;
    END IF;

    IF p_device_geojson IS NULL OR btrim(p_device_geojson) = '' THEN
        RETURN QUERY SELECT 400, '设备GeoJSON点数据不能为空'::varchar;
        RETURN;
    END IF;

    IF COALESCE(p_action_radius_m, 0) < 0
       OR COALESCE(p_warning_radius_m, 0) < 0
       OR COALESCE(p_notice_radius_m, 0) < 0 THEN
        RETURN QUERY SELECT 400, '半径不能小于0'::varchar;
        RETURN;
    END IF;

    IF p_min_alt IS NOT NULL AND p_max_alt IS NOT NULL AND p_min_alt > p_max_alt THEN
        RETURN QUERY SELECT 400, '有效最低高度不能大于有效最高高度'::varchar;
        RETURN;
    END IF;

    BEGIN
        v_json := p_device_geojson::jsonb;

        IF jsonb_typeof(v_json) = 'array' THEN
            v_geom := ST_SetSRID(ST_MakePoint((v_json ->> 0)::double precision, (v_json ->> 1)::double precision), 4326);
        ELSIF v_json ->> 'type' = 'Feature' THEN
            v_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON((v_json -> 'geometry')::text)), 4326);
        ELSE
            v_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(v_json::text)), 4326);
        END IF;

        IF GeometryType(v_geom) <> 'POINT' OR ST_IsEmpty(v_geom) THEN
            RETURN QUERY SELECT 400, '设备GeoJSON必须是Point点数据'::varchar;
            RETURN;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 400, format('设备GeoJSON点数据解析失败：%s', SQLERRM)::varchar;
        RETURN;
    END;

    v_project_id := btrim(p_project_id)::varchar(64);
    v_rule_id := md5(v_project_id || ':' || ST_AsText(ST_SnapToGrid(v_geom, 0.0000001)))::varchar(64);

    INSERT INTO public.gis_counter_device_rule (
        id, project_id, action_radius_m, warning_radius_m, notice_radius_m,
        min_alt, max_alt, lng, lat, geom, geog, update_time
    )
    VALUES (
        v_rule_id, v_project_id, p_action_radius_m, p_warning_radius_m, p_notice_radius_m,
        p_min_alt, p_max_alt, ST_X(v_geom), ST_Y(v_geom), v_geom, v_geom::geography, now()
    )
    ON CONFLICT (id) DO UPDATE SET
        project_id = EXCLUDED.project_id,
        action_radius_m = EXCLUDED.action_radius_m,
        warning_radius_m = EXCLUDED.warning_radius_m,
        notice_radius_m = EXCLUDED.notice_radius_m,
        min_alt = EXCLUDED.min_alt,
        max_alt = EXCLUDED.max_alt,
        lng = EXCLUDED.lng,
        lat = EXCLUDED.lat,
        geom = EXCLUDED.geom,
        geog = EXCLUDED.geog,
        update_time = now();

    RETURN QUERY SELECT 200, '反制设备规则保存成功'::varchar;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 500, format('反制设备规则保存失败：%s', SQLERRM)::varchar;
END;
$$;

COMMENT ON FUNCTION public.gis_counter_device(
    text, text, double precision, double precision, double precision, double precision, double precision
) IS '根据项目ID、设备GeoJSON点数据和半径高度参数保存/更新反制设备规则';

-- ============================================================
-- 函数名称：gis_counter_device_check
-- 函数功能：实时点位反制设备规则校验
-- 函数描述：
--   1. 接收项目ID、设备GeoJSON点数据和实时点位GeoJSON。
--   2. 根据“项目ID + 设备点位”定位已保存的反制设备规则。
--   3. 根据实时点位与设备点位的平面距离，判断命中action、warning、notice或outside。
--   4. 实时点位支持PointZ、Feature.properties.alt/height/z、[lng,lat,alt]。
--   5. 高度为空时不参与高度限制判断。
-- 函数说明：距离使用geography按米计算，坐标系使用WGS84(4326)
-- 适用场景：实时无人机点位进入反制作用区、预警区、通知区时返回对应结果
-- ============================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_counter_device_check');

-- =============================================================================
-- 函数介绍：gis_counter_device_check
-- 主要作用：根据项目ID、设备GeoJSON点数据、实时点位GeoJSON校验命中范围
-- 入参说明：
--   p_project_id         项目ID
--   p_device_geojson     设备GeoJSON点数据，支持Point、Feature或[lng,lat]
--   p_realtime_geojson   实时点位GeoJSON，支持PointZ、Feature.properties.alt/height/z或[lng,lat,alt]
-- 返回说明：标准基础返回
--   code        integer     状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg         varchar     状态描述信息
-- 注意事项：本函数只校验传入设备点对应的规则，不扫描项目下所有设备
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_counter_device_check(
    p_project_id text,
    p_device_geojson text,
    p_realtime_geojson text
)
RETURNS TABLE (
    code integer,       -- 返回：状态码
    msg varchar         -- 返回：状态信息
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_project_id varchar(64);
    v_device_json jsonb;
    v_realtime_json jsonb;
    v_device_geom geometry(Point, 4326);
    v_realtime_geom geometry(Point, 4326);
    v_realtime_geog geography(Point, 4326);
    v_alt double precision;
BEGIN
    CREATE TABLE IF NOT EXISTS public.gis_counter_device_rule (
        id varchar(64) PRIMARY KEY,
        project_id varchar(64) NOT NULL,
        action_radius_m double precision,
        warning_radius_m double precision,
        notice_radius_m double precision,
        min_alt double precision,
        max_alt double precision,
        lng double precision NOT NULL,
        lat double precision NOT NULL,
        geom geometry(Point, 4326) NOT NULL,
        geog geography(Point, 4326) NOT NULL,
        create_time timestamptz NOT NULL DEFAULT now(),
        update_time timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT chk_counter_device_rule_radius CHECK (
            COALESCE(action_radius_m, 0) >= 0
            AND COALESCE(warning_radius_m, 0) >= 0
            AND COALESCE(notice_radius_m, 0) >= 0
        ),
        CONSTRAINT chk_counter_device_rule_alt CHECK (
            min_alt IS NULL OR max_alt IS NULL OR min_alt <= max_alt
        )
    );

    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS project_id varchar(64);
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS action_radius_m double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS warning_radius_m double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS notice_radius_m double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS min_alt double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS max_alt double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS lng double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS lat double precision;
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS geom geometry(Point, 4326);
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS geog geography(Point, 4326);
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS create_time timestamptz DEFAULT now();
    ALTER TABLE public.gis_counter_device_rule ADD COLUMN IF NOT EXISTS update_time timestamptz DEFAULT now();

    CREATE INDEX IF NOT EXISTS idx_counter_device_rule_project
        ON public.gis_counter_device_rule (project_id);

    CREATE INDEX IF NOT EXISTS idx_counter_device_rule_geog
        ON public.gis_counter_device_rule USING GIST (geog);

    CREATE INDEX IF NOT EXISTS idx_counter_device_rule_alt
        ON public.gis_counter_device_rule (min_alt, max_alt);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        RETURN QUERY SELECT 400, '项目ID不能为空'::varchar;
        RETURN;
    END IF;

    IF p_device_geojson IS NULL OR btrim(p_device_geojson) = '' OR p_realtime_geojson IS NULL OR btrim(p_realtime_geojson) = '' THEN
        RETURN QUERY SELECT 400, '设备GeoJSON点数据和实时点位不能为空'::varchar;
        RETURN;
    END IF;

    BEGIN
        v_device_json := p_device_geojson::jsonb;
        IF jsonb_typeof(v_device_json) = 'array' THEN
            v_device_geom := ST_SetSRID(ST_MakePoint((v_device_json ->> 0)::double precision, (v_device_json ->> 1)::double precision), 4326);
        ELSIF v_device_json ->> 'type' = 'Feature' THEN
            v_device_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON((v_device_json -> 'geometry')::text)), 4326);
        ELSE
            v_device_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(v_device_json::text)), 4326);
        END IF;

        v_realtime_json := p_realtime_geojson::jsonb;
        IF jsonb_typeof(v_realtime_json) = 'array' THEN
            v_alt := NULLIF(v_realtime_json ->> 2, '')::double precision;
            v_realtime_geom := ST_SetSRID(ST_MakePoint((v_realtime_json ->> 0)::double precision, (v_realtime_json ->> 1)::double precision), 4326);
        ELSIF v_realtime_json ->> 'type' = 'Feature' THEN
            v_realtime_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON((v_realtime_json -> 'geometry')::text)), 4326);
            v_alt := COALESCE(
                NULLIF(v_realtime_json #>> '{properties,alt}', '')::double precision,
                NULLIF(v_realtime_json #>> '{properties,height}', '')::double precision,
                NULLIF(v_realtime_json #>> '{properties,z}', '')::double precision,
                ST_Z(ST_GeomFromGeoJSON((v_realtime_json -> 'geometry')::text))
            );
        ELSE
            v_realtime_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(v_realtime_json::text)), 4326);
            v_alt := ST_Z(ST_GeomFromGeoJSON(v_realtime_json::text));
        END IF;

        IF GeometryType(v_device_geom) <> 'POINT'
           OR ST_IsEmpty(v_device_geom)
           OR GeometryType(v_realtime_geom) <> 'POINT'
           OR ST_IsEmpty(v_realtime_geom) THEN
            RETURN QUERY SELECT 400, '设备GeoJSON和实时点位必须是Point点数据'::varchar;
            RETURN;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 400, format('GeoJSON点数据解析失败：%s', SQLERRM)::varchar;
        RETURN;
    END;

    v_project_id := btrim(p_project_id)::varchar(64);
    v_realtime_geog := v_realtime_geom::geography;

    RETURN QUERY
    WITH target_rule AS (
        SELECT
            r.*,
            ST_Distance(v_realtime_geog, r.geog) AS distance_m
        FROM public.gis_counter_device_rule r
        WHERE r.project_id = v_project_id
          AND r.id = md5(v_project_id || ':' || ST_AsText(ST_SnapToGrid(v_device_geom, 0.0000001)))
          AND (v_alt IS NULL OR r.min_alt IS NULL OR v_alt >= r.min_alt)
          AND (v_alt IS NULL OR r.max_alt IS NULL OR v_alt <= r.max_alt)
    ),
    hits AS (
        SELECT
            t.*,
            CASE
                WHEN t.action_radius_m IS NOT NULL AND t.distance_m <= t.action_radius_m THEN 'action'
                WHEN t.warning_radius_m IS NOT NULL AND t.distance_m <= t.warning_radius_m THEN 'warning'
                WHEN t.notice_radius_m IS NOT NULL AND t.distance_m <= t.notice_radius_m THEN 'notice'
            END::varchar AS hit_type,
            CASE
                WHEN t.action_radius_m IS NOT NULL AND t.distance_m <= t.action_radius_m THEN 1
                WHEN t.warning_radius_m IS NOT NULL AND t.distance_m <= t.warning_radius_m THEN 2
                WHEN t.notice_radius_m IS NOT NULL AND t.distance_m <= t.notice_radius_m THEN 3
            END::smallint AS hit_level,
            CASE
                WHEN t.action_radius_m IS NOT NULL AND t.distance_m <= t.action_radius_m THEN t.action_radius_m
                WHEN t.warning_radius_m IS NOT NULL AND t.distance_m <= t.warning_radius_m THEN t.warning_radius_m
                WHEN t.notice_radius_m IS NOT NULL AND t.distance_m <= t.notice_radius_m THEN t.notice_radius_m
            END::double precision AS hit_radius
        FROM target_rule t
    )
    SELECT
        200,
        format('命中反制设备规则：%s，等级：%s，距离：%s米，命中半径：%s米',
            h.hit_type,
            h.hit_level,
            ROUND(h.distance_m::numeric, 2),
            ROUND(h.hit_radius::numeric, 2))::varchar
    FROM hits h
    WHERE h.hit_type IS NOT NULL
    ORDER BY h.hit_level, h.distance_m
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            200,
            '未命中反制设备规则'::varchar;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 500, format('反制设备实时点位校验失败：%s', SQLERRM)::varchar;
END;
$$;

COMMENT ON FUNCTION public.gis_counter_device_check(text, text, text) IS '根据项目ID、设备GeoJSON点数据、实时点位校验反制设备命中范围';

-- 示例1：保存/更新反制设备规则。
-- SELECT * FROM public.gis_counter_device(
--     'project_001',
--     '{"type":"Point","coordinates":[113.405861,34.769437]}',
--     1000,
--     1500,
--     2000,
--     NULL,
--     NULL
-- );
--
-- 示例2：实时点位校验。
-- SELECT * FROM public.gis_counter_device_check(
--     'project_001',
--     '{"type":"Point","coordinates":[113.405861,34.769437]}',
--     '{"type":"Point","coordinates":[113.406,34.769,120]}'
-- );
