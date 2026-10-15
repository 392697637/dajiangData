-- =============================================================================
-- 2.空域区块.sql
-- 表说明：
--   1. 空域区块：第三方同步过来的空域区块基础信息，一条区块只保存一份。
--   2. 用空计划：区块下的计划明细，一个区块可以对应多个计划。
-- 依赖说明：
--   1. PostGIS 空间扩展。
--   2. PGSQL/函数/baseFunction/gis_drop_function.sql
--      public.gis_drop_function(text)：重建函数前按名称删除旧函数。
--   3. PGSQL/函数/baseFunction/gis_geojson_to_geom.sql
--      public.gis_geojson_to_geom(text)：GeoJSON Geometry/Feature/FeatureCollection转geometry，并自动修补未闭合面。
--   4. PGSQL/函数/6.1DEM.sql
--      public.gis_build_feature_geojson(geometry, text)：geometry转GeoJSON Feature，保留三维坐标。
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- =============================================================================
-- 删除用空计划明细表
-- =============================================================================
DROP TABLE IF EXISTS public.bo_airspace_plan CASCADE;

-- =============================================================================
-- 删除空域区块主表
-- =============================================================================
DROP TABLE IF EXISTS public.bo_airspace_block CASCADE;
DROP TABLE IF EXISTS public.bo_airspace CASCADE;

-- =============================================================================
-- 一、空域主表
-- =============================================================================
-- =============================================================================
-- 创建空域主表
-- =============================================================================
CREATE TABLE public.bo_airspace (
    id varchar(64) NOT NULL,
    airspace_code varchar(255),
    airspace_name varchar(255),
    min_height double precision NOT NULL DEFAULT 0,
    airspace_height double precision NOT NULL,
    airspace_radius double precision,
    airspace_area double precision,
    airspace_perimeter double precision,
    use_enabled boolean NOT NULL DEFAULT true,
    remark varchar(1000),
    create_time timestamp(6) without time zone NOT NULL DEFAULT now(),
    create_user varchar(32),
    update_time timestamp(6) without time zone NOT NULL DEFAULT now(),
    update_user varchar(32),
    project_id varchar(64),
    del_flag boolean NOT NULL DEFAULT false,
    geom geometry(GeometryZ, 4326),
    CONSTRAINT pk_bo_airspace PRIMARY KEY (id)
);

COMMENT ON TABLE public.bo_airspace IS '空域基础信息';

COMMENT ON COLUMN public.bo_airspace.id IS '主键，字符串，不可重复';
COMMENT ON COLUMN public.bo_airspace.airspace_code IS '空域编号';
COMMENT ON COLUMN public.bo_airspace.airspace_name IS '空域名称';
COMMENT ON COLUMN public.bo_airspace.min_height IS '空域最低高度，单位：米，默认0';
COMMENT ON COLUMN public.bo_airspace.airspace_height IS '空域最高高度，单位：米';
COMMENT ON COLUMN public.bo_airspace.airspace_radius IS '空域缓冲半径，单位：米';
COMMENT ON COLUMN public.bo_airspace.airspace_area IS '空域面积，单位：平方千米';
COMMENT ON COLUMN public.bo_airspace.airspace_perimeter IS '空域周长，单位：千米';
COMMENT ON COLUMN public.bo_airspace.use_enabled IS '启用状态：t启用；f停用';
COMMENT ON COLUMN public.bo_airspace.remark IS '备注';
COMMENT ON COLUMN public.bo_airspace.create_time IS '创建时间';
COMMENT ON COLUMN public.bo_airspace.create_user IS '创建者';
COMMENT ON COLUMN public.bo_airspace.update_time IS '更新时间';
COMMENT ON COLUMN public.bo_airspace.update_user IS '更新者';
COMMENT ON COLUMN public.bo_airspace.project_id IS '项目id';
COMMENT ON COLUMN public.bo_airspace.del_flag IS '是否删除：t删除；f未删除';
COMMENT ON COLUMN public.bo_airspace.geom IS '空域三维几何，WGS84坐标系';

-- 空域原始几何空间索引：用于加快geom字段的地图展示、编辑查询。
CREATE INDEX idx_bo_airspace_geom
    ON public.bo_airspace
    USING gist (geom);

-- =============================================================================
-- 二、空域区块主表
-- =============================================================================
-- =============================================================================
-- 创建空域区块主表
-- =============================================================================
CREATE TABLE public.bo_airspace_block (
    id varchar(64) NOT NULL,
    airspace_code varchar(255),
    airspace_name varchar(255),
    min_height double precision NOT NULL DEFAULT 0,
    airspace_height double precision NOT NULL,
    airspace_type varchar(20),
    airspace_radius double precision,
    airspace_area double precision,
    airspace_perimeter double precision,
    use_enabled boolean NOT NULL DEFAULT true,
    remark varchar(1000),
    create_time timestamp(6) without time zone NOT NULL DEFAULT now(),
    create_user varchar(32),
    update_time timestamp(6) without time zone NOT NULL DEFAULT now(),
    update_user varchar(32),
    project_id varchar(64),
    del_flag boolean NOT NULL DEFAULT false,
    geom geometry(GeometryZ, 4326),
    final_geom geometry(GeometryZ, 4326),
    -- 主键约束：id作为表内每条空域区块记录的唯一标识。
    CONSTRAINT pk_bo_airspace_block PRIMARY KEY (id)
);

COMMENT ON TABLE public.bo_airspace_block IS '空域区块区块基础信息';

COMMENT ON COLUMN public.bo_airspace_block.id IS '主键，字符串，不可重复';
COMMENT ON COLUMN public.bo_airspace_block.airspace_code IS '空域编号';
COMMENT ON COLUMN public.bo_airspace_block.airspace_name IS '空域名称';
COMMENT ON COLUMN public.bo_airspace_block.min_height IS '空域最低高度，单位：米，默认0';
COMMENT ON COLUMN public.bo_airspace_block.airspace_height IS '空域最高高度，单位：米';
COMMENT ON COLUMN public.bo_airspace_block.airspace_type IS '空域类型：POINT点、LINE线、POLYGON面';
COMMENT ON COLUMN public.bo_airspace_block.airspace_radius IS '空域缓冲半径，单位：米';
COMMENT ON COLUMN public.bo_airspace_block.airspace_area IS '空域面积，单位：平方千米';
COMMENT ON COLUMN public.bo_airspace_block.airspace_perimeter IS '空域周长，单位：千米';
COMMENT ON COLUMN public.bo_airspace_block.use_enabled IS '启用状态：t启用；f停用';
COMMENT ON COLUMN public.bo_airspace_block.remark IS '备注';
COMMENT ON COLUMN public.bo_airspace_block.create_time IS '创建时间';
COMMENT ON COLUMN public.bo_airspace_block.create_user IS '创建者';
COMMENT ON COLUMN public.bo_airspace_block.update_time IS '更新时间';
COMMENT ON COLUMN public.bo_airspace_block.update_user IS '更新者';
COMMENT ON COLUMN public.bo_airspace_block.project_id IS '项目id';
COMMENT ON COLUMN public.bo_airspace_block.del_flag IS '是否删除：t删除；f未删除';
COMMENT ON COLUMN public.bo_airspace_block.geom IS '空域原始三维几何，WGS84坐标系：点、线或面，坐标为XYZ';
COMMENT ON COLUMN public.bo_airspace_block.final_geom IS '空域生成后的三维最终范围，WGS84坐标系：点/线按半径缓冲后的面或原始面，坐标为XYZ';

-- =============================================================================
-- 删除空域区块最终范围生成函数
-- =============================================================================
SELECT gis_drop_function('gis_bo_airspace_block_final_geom');

-- 自动生成最终范围：插入或修改原始几何、缓冲半径时，自动维护final_geom、面积、周长。
CREATE OR REPLACE FUNCTION public.gis_bo_airspace_block_final_geom()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_altitude double precision;
    v_dem_code integer;
    v_dem_msg text;
    v_dem_geom geometry;
BEGIN
    -- 原始几何为空时，最终范围和统计值一并置空或置零。
    IF NEW.geom IS NULL THEN
        NEW.final_geom := NULL;
        NEW.airspace_area := 0;
        NEW.airspace_perimeter := 0;
        RETURN NEW;
    END IF;

    -- geom必须由GeoJSON显式传入XYZ；Z表示海拔高度，不能用空域最低/最高高度替代。
    IF ST_NDims(NEW.geom) < 3 THEN
        RAISE EXCEPTION 'geom must include XYZ coordinates with altitude';
    END IF;

    SELECT ST_Z((dp).geom)
    INTO v_altitude
    FROM ST_DumpPoints(NEW.geom) AS dp
    LIMIT 1;

    -- 点且配置了缓冲半径时生成圆形范围；线且配置了缓冲半径时生成平头矩形走廊。
    IF GeometryType(NEW.geom) IN ('POINT', 'MULTIPOINT')
       AND COALESCE(NEW.airspace_radius, 0) > 0 THEN
        NEW.final_geom := ST_Force3D(
            ST_Buffer(NEW.geom::geography, NEW.airspace_radius, 16)::geometry,
            v_altitude
        );
    ELSIF GeometryType(NEW.geom) IN ('LINESTRING', 'MULTILINESTRING')
       AND COALESCE(NEW.airspace_radius, 0) > 0 THEN
        NEW.final_geom := ST_Force3D(
            ST_Buffer(
                NEW.geom::geography,
                NEW.airspace_radius,
                'endcap=flat join=mitre'
            )::geometry,
            v_altitude
        );
    ELSE
        NEW.final_geom := NEW.geom;
    END IF;

    -- final_geom为面时，优先调用DEM函数补充海拔高程；函数不存在或执行失败时写日志并保留原几何。
    IF GeometryType(NEW.final_geom) IN ('POLYGON', 'MULTIPOLYGON') THEN
        IF to_regprocedure('public.gis_dem_elevation_polygon(geometry)') IS NOT NULL THEN
            BEGIN
                SELECT r.code, r.msg, r.geom
                INTO v_dem_code, v_dem_msg, v_dem_geom
                FROM public.gis_dem_elevation_polygon(NEW.final_geom) AS r
                LIMIT 1;

                IF v_dem_code = 200 AND v_dem_geom IS NOT NULL THEN
                    NEW.final_geom := v_dem_geom;
                ELSE
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (
                        COALESCE(v_dem_code, 500),
                        COALESCE(v_dem_msg, 'gis_dem_elevation_polygon未返回有效DEM结果'),
                        'public.gis_bo_airspace_block_final_geom'
                    );
                END IF;
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO public.gis_error_log(code, msg, sqlstring)
                VALUES (
                    500,
                    format('bo_airspace_block final_geom补DEM海拔失败：%s', SQLERRM),
                    'public.gis_bo_airspace_block_final_geom'
                );
            END;
        ELSE
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (
                500,
                'gis_dem_elevation_polygon(geometry)函数不存在，bo_airspace_block final_geom未补DEM海拔',
                'public.gis_bo_airspace_block_final_geom'
            );
        END IF;
    END IF;

    -- final_geom为面时计算面积，单位：平方千米；已有有效面积则保留。
    IF COALESCE(NEW.airspace_area, 0) = 0 THEN
        NEW.airspace_area := CASE
            WHEN GeometryType(NEW.final_geom) IN ('POLYGON', 'MULTIPOLYGON')
            THEN round((ST_Area(NEW.final_geom::geography) / 1000000.0)::numeric, 6)::double precision
            ELSE 0
        END;
    END IF;

    -- final_geom为线时计算长度，为面时计算周长，单位：千米；已有有效周长则保留。
    IF COALESCE(NEW.airspace_perimeter, 0) = 0 THEN
        NEW.airspace_perimeter := CASE
            WHEN GeometryType(NEW.final_geom) IN ('LINESTRING', 'MULTILINESTRING')
            THEN round((ST_Length(NEW.final_geom::geography) / 1000.0)::numeric, 6)::double precision
            WHEN GeometryType(NEW.final_geom) IN ('POLYGON', 'MULTIPOLYGON')
            THEN round((ST_Perimeter(NEW.final_geom::geography) / 1000.0)::numeric, 6)::double precision
            ELSE 0
        END;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.gis_bo_airspace_block_final_geom()
IS '空域区块写入时根据geom和airspace_radius自动生成final_geom，并维护面积、周长';

CREATE TRIGGER trg_airspace_block_geom
BEFORE INSERT OR UPDATE OF geom, airspace_radius
ON public.bo_airspace_block
FOR EACH ROW
EXECUTE FUNCTION public.gis_bo_airspace_block_final_geom();

-- 原始几何空间索引：用于加快geom字段的地图展示、编辑查询。
CREATE INDEX idx_bo_airspace_block_geom
    ON public.bo_airspace_block
    USING gist (geom);

-- 最终范围空间索引：用于加快final_geom字段的空域校验、相交、包含等空间查询。
CREATE INDEX idx_bo_airspace_block_final_geom
    ON public.bo_airspace_block
    USING gist (final_geom);

 

-- =============================================================================
-- 二、用空计划明细表
-- =============================================================================
-- =============================================================================
-- 创建用空计划明细表
-- =============================================================================
CREATE TABLE public.bo_airspace_plan (
    id bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    block_id varchar(64) NOT NULL,
    use_date date NOT NULL,
    time_plan varchar(4000),
    user_duration float8,
    plan_status boolean NOT NULL DEFAULT false,
    remark varchar(1000),
    create_time timestamp(6) without time zone NOT NULL DEFAULT now(),
    create_user varchar(32),
    update_time timestamp(6) without time zone NOT NULL DEFAULT now(),
    update_user varchar(32),
    del_flag boolean NOT NULL DEFAULT false,
    -- 复合主键约束：id为计划主键，use_date为分区键，分区表主键需要包含分区键。
    CONSTRAINT pk_bo_airspace_plan PRIMARY KEY (id, use_date),
    -- 唯一约束：同一个空域区块同一天只保留一条用空计划，time_plan中保存多段时间。
    CONSTRAINT uk_bo_airspace_plan_block_date UNIQUE (block_id, use_date),
    -- 外键约束：block_id必须关联已存在的空域区块bo_airspace_block.id。
    CONSTRAINT fk_bo_airspace_plan_block FOREIGN KEY (block_id)
        REFERENCES public.bo_airspace_block (id)
) PARTITION BY RANGE (use_date);

COMMENT ON TABLE public.bo_airspace_plan IS '用空计划明细表';

COMMENT ON COLUMN public.bo_airspace_plan.id IS '计划主键';
COMMENT ON COLUMN public.bo_airspace_plan.block_id IS '空域区块ID，关联bo_airspace_block.id';
COMMENT ON COLUMN public.bo_airspace_plan.use_date IS '使用日期，分区键';
COMMENT ON COLUMN public.bo_airspace_plan.time_plan IS '时间计划，仅保存时分秒，支持多段时间';
COMMENT ON COLUMN public.bo_airspace_plan.user_duration IS '使用时长（单位分钟）';
COMMENT ON COLUMN public.bo_airspace_plan.plan_status IS '计划状态：t可用；f不可用';
COMMENT ON COLUMN public.bo_airspace_plan.remark IS '计划备注';
COMMENT ON COLUMN public.bo_airspace_plan.create_time IS '计划创建时间';
COMMENT ON COLUMN public.bo_airspace_plan.create_user IS '计划创建者';
COMMENT ON COLUMN public.bo_airspace_plan.update_time IS '计划更新时间';
COMMENT ON COLUMN public.bo_airspace_plan.update_user IS '计划更新者';
COMMENT ON COLUMN public.bo_airspace_plan.del_flag IS '计划是否删除：t删除；f未删除';

-- 默认分区：未命中已创建日期分区的用空计划，会先落到默认分区。
CREATE TABLE public.bo_airspace_plan_default
    PARTITION OF public.bo_airspace_plan
    DEFAULT;

-- 区块日期索引：用于加快按空域区块和使用日期查询计划。
CREATE INDEX idx_bo_airspace_plan_block
    ON public.bo_airspace_plan (block_id, use_date);

-- 日期状态索引：用于加快按使用日期和计划状态筛选计划。
CREATE INDEX idx_bo_airspace_plan_date_status
    ON public.bo_airspace_plan (use_date, plan_status);

-- =============================================================================
-- 数据调用示例
-- =============================================================================
-- 第一次调用：生成空域表数据。
INSERT INTO public.bo_airspace (
    id,
    project_id,
    airspace_code,
    airspace_name,
    min_height,
    airspace_height,
    use_enabled,
    remark,
    create_user,
    update_user,
    geom
)
VALUES (
    'liaochengzhuchengqu',
    'd10326d5a9894cd6b8b5bd365a103394',
    '100000',
    '空域16主区域',
    0,
    200,
    true,
    '主区域，十点连线范围内，真高200米（含）以下',
    'system',
    'system',
    public.gis_geojson_to_geom('{"type":"Polygon","coordinates":[[[115.741667,36.717778,0],[115.708056,36.695833,0],[115.735833,36.541944,0],[115.653889,36.432778,0],[115.705278,36.255833,0],[116.264167,36.270833,0],[116.262778,36.558889,0],[116.055000,36.566389,0],[115.926111,36.700556,0],[115.890556,36.724444,0],[115.741667,36.717778,0]]]}'::text)
);
-- 第二次调用：生成空域1-15区块数据。
INSERT INTO public.bo_airspace_block (
    id,
    project_id,
    airspace_code,
    airspace_name,
    min_height,
    airspace_height,
    airspace_type,
    airspace_radius,
    use_enabled,
    remark,
    create_user,
    update_user,
    geom
)
VALUES
    ('AIRSPACE-01', 'd10326d5a9894cd6b8b5bd365a103394', '101', '空域1', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.951111,36.468056,0]}'::text)),
    ('AIRSPACE-02', 'd10326d5a9894cd6b8b5bd365a103394', '102', '空域2', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.039167,36.492778,0]}'::text)),
    ('AIRSPACE-03', 'd10326d5a9894cd6b8b5bd365a103394', '103', '空域3', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.050278,36.440833,0]}'::text)),
    ('AIRSPACE-04', 'd10326d5a9894cd6b8b5bd365a103394', '104', '空域4', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.989444,36.451667,0]}'::text)),
    ('AIRSPACE-05', 'd10326d5a9894cd6b8b5bd365a103394', '105', '空域5', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.001667,36.483333,0]}'::text)),
    ('AIRSPACE-06', 'd10326d5a9894cd6b8b5bd365a103394', '106', '空域6', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.016389,36.427222,0]}'::text)),
    ('AIRSPACE-07', 'd10326d5a9894cd6b8b5bd365a103394', '107', '空域7', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.040556,36.448056,0]}'::text)),
    ('AIRSPACE-08', 'd10326d5a9894cd6b8b5bd365a103394', '108', '空域8', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.054722,36.459167,0]}'::text)),
    ('AIRSPACE-09', 'd10326d5a9894cd6b8b5bd365a103394', '109', '空域9', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.930556,36.430556,0]}'::text)),
    ('AIRSPACE-10', 'd10326d5a9894cd6b8b5bd365a103394', '110', '空域10', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.967500,36.420000,0]}'::text)),
    ('AIRSPACE-11', 'd10326d5a9894cd6b8b5bd365a103394', '111', '空域11', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.943056,36.510556,0]}'::text)),
    ('AIRSPACE-12', 'd10326d5a9894cd6b8b5bd365a103394', '112', '空域12', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.940556,36.444167,0]}'::text)),
    ('AIRSPACE-13', 'd10326d5a9894cd6b8b5bd365a103394', '113', '空域13', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.731389,36.441389,0]}'::text)),
    ('AIRSPACE-14', 'd10326d5a9894cd6b8b5bd365a103394', '114', '空域14', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[116.013333,36.386667,0]}'::text)),
    ('AIRSPACE-15', 'd10326d5a9894cd6b8b5bd365a103394', '115', '空域15', 0, 200, 'POINT', 5000, true, '子区域，以中心点为圆心，半径5000米范围内', 'system', 'system', public.gis_geojson_to_geom('{"type":"Point","coordinates":[115.999722,36.447222,0]}'::text));



-- =============================================================================
-- 用空计划分区及计划刷新函数
-- =============================================================================
SELECT gis_drop_function('gis_airspace_plan_part');

CREATE OR REPLACE FUNCTION public.gis_airspace_plan_part(
    p_start_date date DEFAULT current_date,
    p_months integer DEFAULT 36
)
RETURNS TABLE (
    insert_count integer,
    delete_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_date date;
    v_end_date date;
    v_month_start date;
    v_month_end date;
    v_partition_name text;
    v_user varchar := 'system';
    i integer;
BEGIN
    IF p_start_date IS NULL THEN
        RAISE EXCEPTION 'p_start_date must not be null';
    END IF;

    IF p_months IS NULL OR p_months <= 0 THEN
        RAISE EXCEPTION 'p_months must be greater than 0';
    END IF;

    v_start_date := p_start_date;
    v_end_date := (p_start_date + (p_months || ' month')::interval)::date;

    -- 先检查并创建未来月份分区；已存在的分区不重复创建。
    FOR i IN 0..(p_months - 1) LOOP
        v_month_start := (date_trunc('month', p_start_date)::date + (i || ' month')::interval)::date;
        v_month_end := (v_month_start + interval '1 month')::date;
        v_partition_name := format('bo_airspace_plan_%s', to_char(v_month_start, 'YYYY_MM'));

        IF to_regclass(format('public.%I', v_partition_name)) IS NULL THEN
            -- 如果默认分区里已经有该月份数据，先挪出；否则创建新分区会因默认分区约束冲突失败。
            CREATE TEMP TABLE IF NOT EXISTS tmp_bo_airspace_plan_move
                (LIKE public.bo_airspace_plan INCLUDING DEFAULTS)
                ON COMMIT DROP;

            TRUNCATE TABLE tmp_bo_airspace_plan_move;

            INSERT INTO tmp_bo_airspace_plan_move
            SELECT *
            FROM public.bo_airspace_plan_default
            WHERE use_date >= v_month_start
              AND use_date < v_month_end;

            DELETE FROM public.bo_airspace_plan_default
            WHERE use_date >= v_month_start
              AND use_date < v_month_end;

            EXECUTE format(
                'CREATE TABLE public.%I PARTITION OF public.bo_airspace_plan FOR VALUES FROM (%L) TO (%L)',
                v_partition_name,
                v_month_start,
                v_month_end
            );

            INSERT INTO public.bo_airspace_plan
            SELECT *
            FROM tmp_bo_airspace_plan_move;
        END IF;
    END LOOP;

    -- 删除没有对应有效空域区块的计划。
    DELETE FROM public.bo_airspace_plan p
    WHERE p.use_date >= v_start_date
      AND p.use_date < v_end_date
      AND NOT EXISTS (
          SELECT 1
          FROM public.bo_airspace_block b
          WHERE b.id = p.block_id
            AND b.del_flag = false
      );

    GET DIAGNOSTICS delete_count = ROW_COUNT;

    -- 根据有效子区域空域区块和日期补齐缺失计划；已有计划不修改。
    WITH block_days AS (
        SELECT
            b.id AS block_id,
            d::date AS use_date
        FROM public.bo_airspace_block b
        CROSS JOIN generate_series(v_start_date, v_end_date - 1, interval '1 day') AS gs(d)
        WHERE b.del_flag = false
    ),
    ins AS (
        INSERT INTO public.bo_airspace_plan (
            block_id,
            use_date,
            time_plan,
            plan_status,
            remark,
            create_time,
            create_user,
            update_time,
            update_user,
            del_flag
        )
        SELECT
            bd.block_id,
            bd.use_date,
            NULL,
            false,
            '自动生成用空计划',
            (bd.use_date - 1 + time '23:55:55')::timestamp,
            v_user,
            (bd.use_date - 1 + time '23:55:55')::timestamp,
            v_user,
            false
        FROM block_days bd
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.bo_airspace_plan p
            WHERE p.block_id = bd.block_id
              AND p.use_date = bd.use_date
        )
        RETURNING id
    )
    SELECT count(*)::integer
    INTO insert_count
    FROM ins;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.gis_airspace_plan_part(date, integer)
IS '按月创建用空计划分区，并按有效空域区块和日期补齐缺失计划、删除无对应区块计划';

-- 调用示例：
-- 默认从今天开始创建未来36个月月分区，并补齐已有空域区块的用空计划。
SELECT * FROM public.gis_airspace_plan_part();
-- 从指定日期开始创建未来36个月月分区，并补齐用空计划。
-- SELECT * FROM public.gis_airspace_plan_part(DATE '2026-10-01');
-- 从指定日期开始创建指定月份数的月分区，并补齐用空计划。
-- SELECT * FROM public.gis_airspace_plan_part(DATE '2026-10-01', 12);

-- =============================================================================
-- 四、模拟用空计划函数
-- =============================================================================
SELECT gis_drop_function('gis_airspace_plan_demo');

CREATE OR REPLACE FUNCTION public.gis_airspace_plan_demo(
    p_plans_per_block integer DEFAULT 3,
    p_days integer DEFAULT 2
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN
    IF p_plans_per_block IS NULL OR p_plans_per_block <= 0 THEN
        RAISE EXCEPTION 'p_plans_per_block must be greater than 0';
    END IF;

    IF p_days IS NULL OR p_days <= 0 THEN
        RAISE EXCEPTION 'p_days must be greater than 0';
    END IF;

    WITH random_block AS (
        SELECT
            b.id
        FROM public.bo_airspace_block b
        WHERE b.del_flag = false
        ORDER BY random()
    ),
    target_plan AS (
        SELECT
            p.id,
            p.use_date,
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'startTime', to_char(t.start_time, 'HH24:MI:SS'),
                        'endTime', to_char(t.start_time + interval '1 hour', 'HH24:MI:SS')
                    )
                    ORDER BY t.start_time
                )::text
                FROM (
                    SELECT
                        time '08:00:00' + (floor(random() * 10)::integer * interval '1 hour') AS start_time
                    FROM generate_series(1, p_plans_per_block) AS segment(segment_seq)
                    WHERE p.id IS NOT NULL
                ) t
            ) AS time_plan
        FROM public.bo_airspace_plan p
        JOIN random_block b
            ON b.id = p.block_id
        WHERE p.use_date >= current_date
          AND p.use_date < current_date + p_days
    ),
    update_plan AS (
        UPDATE public.bo_airspace_plan p
        SET time_plan = t.time_plan,
            update_time = now(),
            update_user = 'demo'
        FROM target_plan t
        WHERE p.id = t.id
          AND p.use_date = t.use_date
        RETURNING p.id
    )
    SELECT count(*)::integer
    INTO v_count
    FROM update_plan;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.gis_airspace_plan_demo(integer, integer)
IS '根据空域区块已有用空计划随机生成计划时间，只更新计划时间、修改人和修改时间';

-- 调用示例：将今天/明天已有计划更新为3段随机模拟时间。
SELECT public.gis_airspace_plan_demo(3, 2);

-- =============================================================================
-- 已有库增量补字段
-- =============================================================================
-- 使用时长，单位分钟。
ALTER TABLE public.bo_airspace_plan
    ADD COLUMN IF NOT EXISTS user_duration float8;

COMMENT ON COLUMN public.bo_airspace_plan.user_duration IS '使用时长（单位分钟）';
