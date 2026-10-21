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

    IF p_plans_per_block > 14 THEN
        RAISE EXCEPTION 'p_plans_per_block must not exceed 14';
    END IF;

    IF p_days IS NULL THEN
        RAISE EXCEPTION 'p_days must not be null';
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
            generated.time_plan,
            generated.user_duration
        FROM public.bo_airspace_plan p
        JOIN random_block b
            ON b.id = p.block_id
        CROSS JOIN LATERAL (
            WITH RECURSIVE segments(seq, start_minute, end_minute) AS (
                SELECT 0, 360, 360
                WHERE p.id IS NOT NULL
                UNION ALL
                SELECT s.seq + 1,
                       s.end_minute + g.gap_minutes,
                       s.end_minute + g.gap_minutes + d.duration_minutes
                FROM segments s
                CROSS JOIN LATERAL (
                    -- Use 15-minute steps and reserve one hour for each remaining segment.
                    SELECT 60 + 15 * floor(random() * (
                        (least(360, 1200 - s.end_minute - (p_plans_per_block - s.seq - 1) * 60) - 60) / 15 + 1
                    ))::integer AS duration_minutes
                ) d
                CROSS JOIN LATERAL (
                    SELECT 15 * floor(random() * (
                        (1200 - s.end_minute - d.duration_minutes
                        - (p_plans_per_block - s.seq - 1) * 60) / 15 + 1
                    ))::integer AS gap_minutes
                ) g
                WHERE s.seq < p_plans_per_block
            )
            SELECT jsonb_agg(
                       jsonb_build_object(
                           'startTime', to_char(time '00:00:00' + start_minute * interval '1 minute', 'HH24:MI:SS'),
                           'endTime', to_char(time '00:00:00' + end_minute * interval '1 minute', 'HH24:MI:SS')
                       ) ORDER BY seq
                   )::text AS time_plan,
                   sum(end_minute - start_minute)::double precision AS user_duration
            FROM segments
            WHERE seq > 0
        ) generated
        WHERE p.use_date >= current_date + CASE WHEN p_days < 0 THEN p_days + 1 ELSE 0 END
          AND p.use_date < current_date + CASE WHEN p_days > 0 THEN p_days ELSE 1 END
    ),
    update_plan AS (
        UPDATE public.bo_airspace_plan p
        SET time_plan = t.time_plan,
            user_duration = t.user_duration,
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
IS '随机生成不重叠用空时段并更新使用时长';

-- 调用示例：将今天/明天已有计划更新为3段随机模拟时间。
SELECT public.gis_airspace_plan_demo(3, 2);
-- 负数向过去取天数（包含今天）：将昨天/今天已有计划更新为3段随机模拟时间。
-- SELECT public.gis_airspace_plan_demo(3, -2);
-- 0仅更新当天已有计划。
-- SELECT public.gis_airspace_plan_demo(3, 0);

-- =============================================================================
-- 已有库增量补字段
-- =============================================================================
-- 使用时长，单位分钟。
ALTER TABLE public.bo_airspace_plan
    ADD COLUMN IF NOT EXISTS user_duration float8;

COMMENT ON COLUMN public.bo_airspace_plan.user_duration IS '使用时长（单位分钟）';

-- =============================================================================
-- 附件边界数据更新：主区块 geom，使用 Polygon
-- 数据来源：LIAOCHENGBIANJIE 聊城市边界 GeoJSON。
-- Polygon 仅保留第一个外边界环，已删除原数据中的第二个空洞环。
-- 坐标系：WGS84 / EPSG:4326；本语句只更新 bo_airspace.geom。
-- =============================================================================
-- {
-- "type": "FeatureCollection",
-- "name": "LIAOCHENGBIANJIE",
-- "crs": { "type": "name", "properties": { "name": "urn:ogc:def:crs:OGC:1.3:CRS84" } },
-- "features": [
-- { "type": "Feature", "properties": { "id": "1", "name": "聊城市区", "site": null }, "geometry": { "type": "MultiPolygon", "coordinates": [ [ [ [ 115.339935, 36.389899 ], [ 115.333937, 36.397882 ], [ 115.32654, 36.40197 ], [ 115.318867, 36.404911 ], [ 115.307522, 36.406466 ], [ 115.305249, 36.407227 ], [ 115.300128, 36.408945 ], [ 115.294761, 36.41167 ], [ 115.293581, 36.412052 ], [ 115.292067, 36.412864 ], [ 115.291484, 36.413332 ], [ 115.291267, 36.414285 ], [ 115.291161, 36.415444 ], [ 115.291265, 36.416595 ], [ 115.29184, 36.41764 ], [ 115.292781, 36.418686 ], [ 115.293897, 36.419645 ], [ 115.295344, 36.420394 ], [ 115.297522, 36.421195 ], [ 115.298411, 36.421562 ], [ 115.299474, 36.422451 ], [ 115.300485, 36.423722 ], [ 115.301148, 36.424926 ], [ 115.301427, 36.426947 ], [ 115.301583, 36.428568 ], [ 115.301931, 36.429579 ], [ 115.30289, 36.430608 ], [ 115.304459, 36.431637 ], [ 115.305731, 36.432787 ], [ 115.306076, 36.433401 ], [ 115.30949, 36.432582 ], [ 115.310908, 36.43239 ], [ 115.311179, 36.435452 ], [ 115.308559, 36.435705 ], [ 115.308543, 36.437207 ], [ 115.311034, 36.437029 ], [ 115.311239, 36.437777 ], [ 115.310758, 36.43786 ], [ 115.310897, 36.438278 ], [ 115.310083, 36.438357 ], [ 115.310076, 36.438714 ], [ 115.310851, 36.438694 ], [ 115.311674, 36.442387 ], [ 115.311157, 36.442439 ], [ 115.311705, 36.445233 ], [ 115.31085, 36.44552 ], [ 115.311807, 36.449838 ], [ 115.309138, 36.450486 ], [ 115.309437, 36.451413 ], [ 115.310458, 36.451565 ], [ 115.311075, 36.453837 ], [ 115.309107, 36.454434 ], [ 115.309138, 36.454703 ], [ 115.308729, 36.454846 ], [ 115.309295, 36.455956 ], [ 115.309221, 36.456015 ], [ 115.307566, 36.45651 ], [ 115.306679, 36.456618 ], [ 115.305747, 36.457173 ], [ 115.306486, 36.458793 ], [ 115.304408, 36.459329 ], [ 115.303908, 36.458637 ], [ 115.303021, 36.458713 ], [ 115.302806, 36.458383 ], [ 115.30058, 36.458977 ], [ 115.30082, 36.459815 ], [ 115.301412, 36.459734 ], [ 115.301843, 36.461125 ], [ 115.30187, 36.461573 ], [ 115.301646, 36.461689 ], [ 115.301936, 36.461962 ], [ 115.302035, 36.462439 ], [ 115.301782, 36.462819 ], [ 115.300816, 36.463206 ], [ 115.300812, 36.463231 ], [ 115.300182, 36.463686 ], [ 115.29873, 36.464688 ], [ 115.296891, 36.465543 ], [ 115.295672, 36.465855 ], [ 115.294302, 36.465718 ], [ 115.293322, 36.465263 ], [ 115.292412, 36.464458 ], [ 115.290872, 36.462708 ], [ 115.290346, 36.461623 ], [ 115.289437, 36.459767 ], [ 115.288946, 36.459207 ], [ 115.288247, 36.458927 ], [ 115.287267, 36.458927 ], [ 115.286077, 36.459593 ], [ 115.285447, 36.460433 ], [ 115.285377, 36.461623 ], [ 115.285832, 36.462603 ], [ 115.285902, 36.463199 ], [ 115.285762, 36.463689 ], [ 115.284782, 36.465229 ], [ 115.283312, 36.468064 ], [ 115.283031, 36.468835 ], [ 115.282961, 36.46985 ], [ 115.283137, 36.470621 ], [ 115.283732, 36.47139 ], [ 115.284378, 36.471862 ], [ 115.286199, 36.472527 ], [ 115.287809, 36.473158 ], [ 115.288474, 36.473648 ], [ 115.288754, 36.474243 ], [ 115.288684, 36.474838 ], [ 115.28837, 36.475433 ], [ 115.287704, 36.475923 ], [ 115.287004, 36.476029 ], [ 115.286304, 36.476099 ], [ 115.280425, 36.476236 ], [ 115.278745, 36.476275 ], [ 115.27815, 36.476519 ], [ 115.277554, 36.47687 ], [ 115.277205, 36.47736 ], [ 115.276889, 36.47827 ], [ 115.276819, 36.479181 ], [ 115.27724, 36.480126 ], [ 115.277607, 36.481578 ], [ 115.277852, 36.482663 ], [ 115.277852, 36.483713 ], [ 115.277712, 36.485289 ], [ 115.277583, 36.48625 ], [ 115.275696, 36.486607 ], [ 115.273359, 36.48662 ], [ 115.270142, 36.486808 ], [ 115.270132, 36.487255 ], [ 115.269724, 36.487309 ], [ 115.269883, 36.488503 ], [ 115.267478, 36.488796 ], [ 115.267349, 36.48796 ], [ 115.266722, 36.487981 ], [ 115.267196, 36.490684 ], [ 115.265864, 36.490874 ], [ 115.265646, 36.490996 ], [ 115.265528, 36.491271 ], [ 115.265804, 36.491606 ], [ 115.266066, 36.49253 ], [ 115.266806, 36.495981 ], [ 115.266925, 36.497239 ], [ 115.275757, 36.495604 ], [ 115.27697, 36.498318 ], [ 115.277413, 36.498295 ], [ 115.277729, 36.499074 ], [ 115.278098, 36.49905 ], [ 115.278374, 36.499947 ], [ 115.279298, 36.499841 ], [ 115.28015, 36.498006 ], [ 115.283797, 36.49764 ], [ 115.285272, 36.499115 ], [ 115.286742, 36.500586 ], [ 115.287827, 36.501741 ], [ 115.288807, 36.50363 ], [ 115.289979, 36.506238 ], [ 115.290505, 36.508513 ], [ 115.290542, 36.508662 ], [ 115.289957, 36.509809 ], [ 115.289481, 36.510519 ], [ 115.288822, 36.511279 ], [ 115.288, 36.512366 ], [ 115.28749, 36.513223 ], [ 115.286664, 36.514209 ], [ 115.286469, 36.514951 ], [ 115.285929, 36.516257 ], [ 115.285917, 36.517697 ], [ 115.28622, 36.518783 ], [ 115.287151, 36.52049 ], [ 115.288584, 36.522293 ], [ 115.289167, 36.522807 ], [ 115.289227, 36.523024 ], [ 115.288594, 36.523207 ], [ 115.282885, 36.524134 ], [ 115.283298, 36.52501 ], [ 115.283499, 36.525638 ], [ 115.283533, 36.526056 ], [ 115.283353, 36.526367 ], [ 115.282263, 36.526977 ], [ 115.282083, 36.527288 ], [ 115.282384, 36.528335 ], [ 115.282932, 36.528865 ], [ 115.284463, 36.530027 ], [ 115.286057, 36.531554 ], [ 115.287641, 36.532555 ], [ 115.289111, 36.533065 ], [ 115.289737, 36.533192 ], [ 115.291162, 36.533257 ], [ 115.292333, 36.533056 ], [ 115.293591, 36.532568 ], [ 115.294072, 36.532157 ], [ 115.29441, 36.531546 ], [ 115.294542, 36.53065 ], [ 115.29449, 36.529961 ], [ 115.293862, 36.527595 ], [ 115.294555, 36.527431 ], [ 115.294435, 36.527011 ], [ 115.294506, 36.52576 ], [ 115.295493, 36.525983 ], [ 115.296989, 36.526491 ], [ 115.298961, 36.526936 ], [ 115.300035, 36.527125 ], [ 115.301478, 36.527225 ], [ 115.303244, 36.529061 ], [ 115.30412, 36.530286 ], [ 115.304645, 36.531511 ], [ 115.305345, 36.532526 ], [ 115.306167, 36.533418 ], [ 115.307287, 36.534329 ], [ 115.308512, 36.535239 ], [ 115.309877, 36.536044 ], [ 115.312713, 36.537829 ], [ 115.314988, 36.539369 ], [ 115.316773, 36.540524 ], [ 115.317719, 36.541365 ], [ 115.318637, 36.54242 ], [ 115.319656, 36.543313 ], [ 115.320537, 36.544252 ], [ 115.321622, 36.545477 ], [ 115.323232, 36.546948 ], [ 115.324212, 36.548103 ], [ 115.324843, 36.549118 ], [ 115.325228, 36.549958 ], [ 115.325227, 36.550903 ], [ 115.325315, 36.552601 ], [ 115.325069, 36.554247 ], [ 115.32507, 36.556557 ], [ 115.325315, 36.559148 ], [ 115.325595, 36.561738 ], [ 115.325892, 36.563926 ], [ 115.327188, 36.567392 ], [ 115.328308, 36.571488 ], [ 115.328885, 36.573535 ], [ 115.32906, 36.57546 ], [ 115.328921, 36.578051 ], [ 115.328395, 36.580921 ], [ 115.328238, 36.5822 ], [ 115.328938, 36.58388 ], [ 115.330549, 36.58696 ], [ 115.331768, 36.588686 ], [ 115.337035, 36.586999 ], [ 115.339324, 36.590846 ], [ 115.344432, 36.589752 ], [ 115.345459, 36.592472 ], [ 115.34546, 36.594661 ], [ 115.338859, 36.595323 ], [ 115.334299, 36.594926 ], [ 115.334347, 36.595484 ], [ 115.334207, 36.597269 ], [ 115.334207, 36.59909 ], [ 115.334679, 36.601138 ], [ 115.335099, 36.602714 ], [ 115.335414, 36.603168 ], [ 115.336219, 36.603588 ], [ 115.338566, 36.604884 ], [ 115.341891, 36.60569 ], [ 115.343467, 36.605795 ], [ 115.344342, 36.606144 ], [ 115.344648, 36.606338 ], [ 115.342826, 36.608041 ], [ 115.339294, 36.610199 ], [ 115.338592, 36.61106 ], [ 115.338958, 36.612061 ], [ 115.343246, 36.615194 ], [ 115.34629, 36.618325 ], [ 115.347367, 36.619896 ], [ 115.347909, 36.621036 ], [ 115.348457, 36.62275 ], [ 115.348823, 36.624325 ], [ 115.349023, 36.627046 ], [ 115.349739, 36.627043 ], [ 115.35309, 36.624594 ], [ 115.354501, 36.624014 ], [ 115.355203, 36.623582 ], [ 115.358775, 36.622274 ], [ 115.359916, 36.621597 ], [ 115.360759, 36.622241 ], [ 115.362009, 36.62308 ], [ 115.363015, 36.624313 ], [ 115.364184, 36.625644 ], [ 115.366391, 36.627591 ], [ 115.36824, 36.629409 ], [ 115.370026, 36.630771 ], [ 115.371568, 36.631891 ], [ 115.372347, 36.632476 ], [ 115.373061, 36.633287 ], [ 115.374208, 36.6352 ], [ 115.376523, 36.639913 ], [ 115.377553, 36.641484 ], [ 115.38096, 36.644944 ], [ 115.381804, 36.646034 ], [ 115.382041, 36.646824 ], [ 115.38218, 36.648363 ], [ 115.382212, 36.648685 ], [ 115.382212, 36.649684 ], [ 115.382082, 36.650808 ], [ 115.382076, 36.650855 ], [ 115.381451, 36.651873 ], [ 115.381142, 36.652397 ], [ 115.380088, 36.654595 ], [ 115.380027, 36.654721 ], [ 115.38002, 36.655253 ], [ 115.38015, 36.655891 ], [ 115.38061, 36.656399 ], [ 115.380798, 36.656534 ], [ 115.383063, 36.658145 ], [ 115.384419, 36.658887 ], [ 115.385592, 36.659393 ], [ 115.385907, 36.659512 ], [ 115.389114, 36.660382 ], [ 115.389767, 36.660519 ], [ 115.391395, 36.660915 ], [ 115.392791, 36.661256 ], [ 115.395952, 36.662019 ], [ 115.396853, 36.662092 ], [ 115.397719, 36.662214 ], [ 115.400259, 36.662818 ], [ 115.401592, 36.663383 ], [ 115.402293, 36.664062 ], [ 115.40269, 36.664929 ], [ 115.403205, 36.666521 ], [ 115.403544, 36.667539 ], [ 115.403544, 36.668922 ], [ 115.403179, 36.670356 ], [ 115.4031, 36.671216 ], [ 115.403439, 36.672078 ], [ 115.404771, 36.67453 ], [ 115.40597, 36.67607 ], [ 115.407119, 36.676879 ], [ 115.409441, 36.678235 ], [ 115.410745, 36.678757 ], [ 115.412455, 36.679266 ], [ 115.413264, 36.67971 ], [ 115.413759, 36.680258 ], [ 115.414046, 36.680936 ], [ 115.414151, 36.682657 ], [ 115.413942, 36.684222 ], [ 115.413994, 36.685318 ], [ 115.414229, 36.686178 ], [ 115.414424, 36.686348 ], [ 115.415938, 36.686661 ], [ 115.418521, 36.687002 ], [ 115.421496, 36.687316 ], [ 115.422461, 36.687342 ], [ 115.423427, 36.687447 ], [ 115.424653, 36.687812 ], [ 115.42601, 36.688516 ], [ 115.427536, 36.689573 ], [ 115.429049, 36.691086 ], [ 115.429782, 36.691624 ], [ 115.429832, 36.691661 ], [ 115.430301, 36.691869 ], [ 115.431007, 36.691974 ], [ 115.433015, 36.691947 ], [ 115.434406, 36.692048 ], [ 115.435734, 36.689453 ], [ 115.436439, 36.689655 ], [ 115.436646, 36.689714 ], [ 115.436787, 36.689399 ], [ 115.438815, 36.690017 ], [ 115.438845, 36.690117 ], [ 115.437856, 36.692046 ], [ 115.438512, 36.692312 ], [ 115.43844, 36.692646 ], [ 115.438955, 36.692805 ], [ 115.439984, 36.693528 ], [ 115.440579, 36.69424 ], [ 115.439918, 36.695787 ], [ 115.438956, 36.696495 ], [ 115.438025, 36.698115 ], [ 115.438094, 36.699222 ], [ 115.438506, 36.699985 ], [ 115.438681, 36.700557 ], [ 115.43901, 36.70098 ], [ 115.440041, 36.70138 ], [ 115.442543, 36.701626 ], [ 115.443459, 36.701619 ], [ 115.445322, 36.701826 ], [ 115.445878, 36.702214 ], [ 115.4461, 36.703055 ], [ 115.445984, 36.703966 ], [ 115.445642, 36.704493 ], [ 115.443816, 36.705409 ], [ 115.443909, 36.70597 ], [ 115.443974, 36.708801 ], [ 115.443776, 36.710437 ], [ 115.443811, 36.711571 ], [ 115.444125, 36.712756 ], [ 115.4444, 36.71323 ], [ 115.445757, 36.713012 ], [ 115.446557, 36.713175 ], [ 115.447489, 36.713602 ], [ 115.448336, 36.713805 ], [ 115.449091, 36.713663 ], [ 115.450274, 36.713795 ], [ 115.450832, 36.714103 ], [ 115.451808, 36.714917 ], [ 115.453701, 36.717034 ], [ 115.453968, 36.718139 ], [ 115.453716, 36.718742 ], [ 115.453235, 36.719115 ], [ 115.451106, 36.719543 ], [ 115.44973, 36.719605 ], [ 115.450444, 36.721322 ], [ 115.45107, 36.72247 ], [ 115.452349, 36.724531 ], [ 115.453271, 36.725679 ], [ 115.453815, 36.725662 ], [ 115.455472, 36.725303 ], [ 115.457684, 36.72564 ], [ 115.458814, 36.726032 ], [ 115.459326, 36.726422 ], [ 115.459646, 36.726879 ], [ 115.459783, 36.7273 ], [ 115.45963, 36.727791 ], [ 115.459195, 36.728241 ], [ 115.457852, 36.728944 ], [ 115.457097, 36.729317 ], [ 115.455754, 36.730099 ], [ 115.455372, 36.730587 ], [ 115.454884, 36.730999 ], [ 115.454831, 36.731495 ], [ 115.455692, 36.733101 ], [ 115.455823, 36.733749 ], [ 115.456234, 36.734554 ], [ 115.456509, 36.734826 ], [ 115.45741, 36.734986 ], [ 115.458165, 36.73496 ], [ 115.460531, 36.734182 ], [ 115.460875, 36.734083 ], [ 115.461935, 36.735465 ], [ 115.462771, 36.736183 ], [ 115.463411, 36.736896 ], [ 115.465237, 36.73854 ], [ 115.466711, 36.740405 ], [ 115.468368, 36.742375 ], [ 115.468511, 36.742544 ], [ 115.46945, 36.743874 ], [ 115.470246, 36.745582 ], [ 115.471341, 36.747774 ], [ 115.472131, 36.750017 ], [ 115.472387, 36.750815 ], [ 115.472486, 36.751395 ], [ 115.472517, 36.752075 ], [ 115.472496, 36.752814 ], [ 115.47232, 36.754338 ], [ 115.472225, 36.755169 ], [ 115.472133, 36.756507 ], [ 115.472199, 36.757577 ], [ 115.472402, 36.758429 ], [ 115.47272, 36.758977 ], [ 115.473275, 36.759371 ], [ 115.474034, 36.759705 ], [ 115.475094, 36.759941 ], [ 115.475849, 36.760134 ], [ 115.47723, 36.760506 ], [ 115.478422, 36.760786 ], [ 115.480098, 36.760958 ], [ 115.481688, 36.761028 ], [ 115.483912, 36.761149 ], [ 115.485166, 36.761255 ], [ 115.485444, 36.761285 ], [ 115.48588, 36.76216 ], [ 115.486521, 36.763232 ], [ 115.487208, 36.764419 ], [ 115.488085, 36.765381 ], [ 115.489672, 36.766507 ], [ 115.490977, 36.767208 ], [ 115.49196, 36.767865 ], [ 115.493174, 36.76845 ], [ 115.494494, 36.768924 ], [ 115.495425, 36.769279 ], [ 115.49618, 36.76963 ], [ 115.496974, 36.769904 ], [ 115.498339, 36.770072 ], [ 115.500193, 36.770118 ], [ 115.500299, 36.770126 ], [ 115.500608, 36.770168 ], [ 115.501024, 36.770045 ], [ 115.501268, 36.769947 ], [ 115.502436, 36.769135 ], [ 115.503924, 36.767901 ], [ 115.504794, 36.767162 ], [ 115.505335, 36.766815 ], [ 115.505747, 36.766603 ], [ 115.506717, 36.766427 ], [ 115.506819, 36.76644 ], [ 115.507995, 36.766483 ], [ 115.509256, 36.766531 ], [ 115.509876, 36.76655 ], [ 115.510552, 36.766459 ], [ 115.51138, 36.766196 ], [ 115.513164, 36.765407 ], [ 115.514913, 36.764641 ], [ 115.516492, 36.764037 ], [ 115.517749, 36.763608 ], [ 115.51905, 36.763368 ], [ 115.519635, 36.763368 ], [ 115.520015, 36.763524 ], [ 115.520492, 36.763934 ], [ 115.520745, 36.764372 ], [ 115.52095, 36.765113 ], [ 115.521141, 36.766287 ], [ 115.521033, 36.766775 ], [ 115.520877, 36.767292 ], [ 115.520636, 36.767778 ], [ 115.519486, 36.769872 ], [ 115.519316, 36.770475 ], [ 115.51934, 36.771103 ], [ 115.519529, 36.771742 ], [ 115.519757, 36.772243 ], [ 115.52018, 36.772842 ], [ 115.520697, 36.773388 ], [ 115.521233, 36.77369 ], [ 115.521827, 36.773837 ], [ 115.522393, 36.773856 ], [ 115.522958, 36.773729 ], [ 115.52346, 36.773506 ], [ 115.524406, 36.772625 ], [ 115.525445, 36.771911 ], [ 115.526404, 36.77134 ], [ 115.527222, 36.770946 ], [ 115.527699, 36.770848 ], [ 115.52806, 36.770868 ], [ 115.528449, 36.771024 ], [ 115.529711, 36.771886 ], [ 115.530637, 36.772296 ], [ 115.531041, 36.772451 ], [ 115.530956, 36.774422 ], [ 115.531558, 36.776931 ], [ 115.531448, 36.780455 ], [ 115.531308, 36.781829 ], [ 115.531453, 36.782434 ], [ 115.531849, 36.783131 ], [ 115.532908, 36.783941 ], [ 115.534567, 36.784416 ], [ 115.53554, 36.78453 ], [ 115.540777, 36.784161 ], [ 115.542582, 36.783615 ], [ 115.542997, 36.783346 ], [ 115.54373, 36.782696 ], [ 115.54385, 36.782357 ], [ 115.544086, 36.780392 ], [ 115.544065, 36.779231 ], [ 115.544426, 36.778065 ], [ 115.545164, 36.77713 ], [ 115.546878, 36.775706 ], [ 115.549058, 36.775954 ], [ 115.555569, 36.775605 ], [ 115.555693, 36.776002 ], [ 115.555718, 36.776922 ], [ 115.555395, 36.780177 ], [ 115.554789, 36.782777 ], [ 115.554789, 36.783648 ], [ 115.555099, 36.783958 ], [ 115.555627, 36.784113 ], [ 115.561186, 36.781098 ], [ 115.562614, 36.779949 ], [ 115.564789, 36.776904 ], [ 115.566393, 36.775208 ], [ 115.567018, 36.775187 ], [ 115.567583, 36.7751 ], [ 115.56806, 36.775007 ], [ 115.568558, 36.774909 ], [ 115.570061, 36.774769 ], [ 115.571987, 36.774682 ], [ 115.572809, 36.774735 ], [ 115.573566, 36.774854 ], [ 115.574078, 36.775025 ], [ 115.574633, 36.775453 ], [ 115.574847, 36.775765 ], [ 115.575003, 36.776281 ], [ 115.575232, 36.77688 ], [ 115.575524, 36.777415 ], [ 115.576206, 36.778283 ], [ 115.576757, 36.778997 ], [ 115.57746, 36.779733 ], [ 115.578249, 36.780433 ], [ 115.578979, 36.78091 ], [ 115.579768, 36.781272 ], [ 115.580947, 36.781719 ], [ 115.582492, 36.782328 ], [ 115.583953, 36.782844 ], [ 115.585454, 36.783224 ], [ 115.586833, 36.783531 ], [ 115.588089, 36.783638 ], [ 115.589201, 36.783744 ], [ 115.589668, 36.783774 ], [ 115.590107, 36.783871 ], [ 115.592411, 36.784568 ], [ 115.594253, 36.785064 ], [ 115.594906, 36.785239 ], [ 115.595792, 36.785542 ], [ 115.597522, 36.786218 ], [ 115.598116, 36.786403 ], [ 115.598789, 36.786598 ], [ 115.599705, 36.786978 ], [ 115.60066, 36.787309 ], [ 115.605254, 36.789019 ], [ 115.608382, 36.790207 ], [ 115.609453, 36.790665 ], [ 115.610695, 36.791083 ], [ 115.612325, 36.791622 ], [ 115.612983, 36.791735 ], [ 115.613557, 36.791843 ], [ 115.613965, 36.791941 ], [ 115.619106, 36.794206 ], [ 115.61989, 36.794659 ], [ 115.620698, 36.795146 ], [ 115.621761, 36.795798 ], [ 115.623262, 36.796832 ], [ 115.62508, 36.797957 ], [ 115.626238, 36.798792 ], [ 115.626702, 36.798915 ], [ 115.626928, 36.798883 ], [ 115.62698, 36.798869 ], [ 115.627497, 36.79873 ], [ 115.628293, 36.798478 ], [ 115.629344, 36.79816 ], [ 115.630055, 36.797929 ], [ 115.630767, 36.797641 ], [ 115.631407, 36.797445 ], [ 115.631678, 36.797356 ], [ 115.632003, 36.797326 ], [ 115.632385, 36.79733 ], [ 115.632864, 36.797382 ], [ 115.633358, 36.797478 ], [ 115.633764, 36.797664 ], [ 115.634101, 36.797827 ], [ 115.634393, 36.798058 ], [ 115.634683, 36.798494 ], [ 115.63502, 36.799407 ], [ 115.635301, 36.80032 ], [ 115.635325, 36.800514 ], [ 115.635472, 36.800982 ], [ 115.63573, 36.801621 ], [ 115.635904, 36.802193 ], [ 115.635916, 36.802225 ], [ 115.635983, 36.802405 ], [ 115.637404, 36.802811 ], [ 115.638526, 36.803372 ], [ 115.639683, 36.803956 ], [ 115.640984, 36.804791 ], [ 115.641896, 36.805477 ], [ 115.642421, 36.805787 ], [ 115.643161, 36.806098 ], [ 115.643686, 36.80636 ], [ 115.644043, 36.806646 ], [ 115.644389, 36.807135 ], [ 115.6447, 36.807326 ], [ 115.645904, 36.8076 ], [ 115.647998, 36.80812 ], [ 115.649919, 36.808358 ], [ 115.651189, 36.808567 ], [ 115.651977, 36.808805 ], [ 115.652812, 36.809222 ], [ 115.653659, 36.809701 ], [ 115.655903, 36.810738 ], [ 115.657042, 36.811245 ], [ 115.657913, 36.81171 ], [ 115.658748, 36.812068 ], [ 115.659225, 36.812235 ], [ 115.65994, 36.812307 ], [ 115.660382, 36.812247 ], [ 115.66151, 36.811823 ], [ 115.662715, 36.811119 ], [ 115.664134, 36.810141 ], [ 115.665304, 36.809378 ], [ 115.665781, 36.809043 ], [ 115.666247, 36.8089 ], [ 115.667088, 36.808859 ], [ 115.667672, 36.808941 ], [ 115.668174, 36.809311 ], [ 115.669056, 36.809908 ], [ 115.67093, 36.810541 ], [ 115.672696, 36.810982 ], [ 115.674193, 36.811286 ], [ 115.674684, 36.811421 ], [ 115.674775, 36.811417 ], [ 115.674829, 36.811364 ], [ 115.674825, 36.810772 ], [ 115.674877, 36.810205 ], [ 115.67477, 36.809816 ], [ 115.674705, 36.809521 ], [ 115.674665, 36.809395 ], [ 115.674667, 36.809293 ], [ 115.674668, 36.809224 ], [ 115.674726, 36.809157 ], [ 115.674994, 36.809136 ], [ 115.675532, 36.809143 ], [ 115.675745, 36.8091 ], [ 115.675916, 36.809011 ], [ 115.676003, 36.808897 ], [ 115.676165, 36.808513 ], [ 115.67631, 36.808321 ], [ 115.677694, 36.807649 ], [ 115.679506, 36.807653 ], [ 115.680057, 36.807901 ], [ 115.6805, 36.808324 ], [ 115.680814, 36.809609 ], [ 115.680813, 36.809657 ], [ 115.680691, 36.810144 ], [ 115.680496, 36.810825 ], [ 115.680185, 36.81164 ], [ 115.680126, 36.811799 ], [ 115.680053, 36.811889 ], [ 115.679767, 36.812067 ], [ 115.679382, 36.812233 ], [ 115.679069, 36.812366 ], [ 115.67867, 36.812498 ], [ 115.678624, 36.812526 ], [ 115.678342, 36.812687 ], [ 115.678847, 36.812933 ], [ 115.680082, 36.813821 ], [ 115.681382, 36.815684 ], [ 115.682092, 36.81724 ], [ 115.682463, 36.818315 ], [ 115.682498, 36.819042 ], [ 115.682582, 36.821214 ], [ 115.682492, 36.822759 ], [ 115.6826, 36.823451 ], [ 115.683149, 36.824536 ], [ 115.684056, 36.825754 ], [ 115.68523, 36.826774 ], [ 115.685935, 36.827753 ], [ 115.686328, 36.828397 ], [ 115.686376, 36.829041 ], [ 115.686031, 36.830688 ], [ 115.685617, 36.83318 ], [ 115.685487, 36.833743 ], [ 115.685242, 36.834458 ], [ 115.684866, 36.835196 ], [ 115.684409, 36.835817 ], [ 115.684069, 36.836133 ], [ 115.683941, 36.836345 ], [ 115.683366, 36.837528 ], [ 115.682984, 36.838671 ], [ 115.682774, 36.839281 ], [ 115.682745, 36.840013 ], [ 115.682838, 36.840904 ], [ 115.683015, 36.841735 ], [ 115.683201, 36.842346 ], [ 115.683589, 36.843154 ], [ 115.68404, 36.844004 ], [ 115.684474, 36.844684 ], [ 115.685013, 36.8452 ], [ 115.687739, 36.84748 ], [ 115.688547, 36.848089 ], [ 115.688957, 36.848523 ], [ 115.689596, 36.849349 ], [ 115.690229, 36.85044 ], [ 115.690657, 36.851735 ], [ 115.690856, 36.852684 ], [ 115.691056, 36.85381 ], [ 115.691419, 36.854876 ], [ 115.692011, 36.855843 ], [ 115.69282, 36.857086 ], [ 115.693652, 36.858269 ], [ 115.694397, 36.859295 ], [ 115.69469, 36.859881 ], [ 115.694925, 36.860421 ], [ 115.695099, 36.86103 ], [ 115.695329, 36.862173 ], [ 115.695376, 36.862946 ], [ 115.695188, 36.863708 ], [ 115.694561, 36.865273 ], [ 115.694279, 36.865941 ], [ 115.694103, 36.86661 ], [ 115.694203, 36.867013 ], [ 115.694473, 36.867435 ], [ 115.695094, 36.868045 ], [ 115.69673, 36.870032 ], [ 115.69714, 36.870689 ], [ 115.697445, 36.871064 ], [ 115.698078, 36.871615 ], [ 115.699596, 36.873073 ], [ 115.700417, 36.874012 ], [ 115.70163, 36.875518 ], [ 115.702216, 36.876432 ], [ 115.702661, 36.877241 ], [ 115.703277, 36.878478 ], [ 115.703839, 36.879545 ], [ 115.704379, 36.880494 ], [ 115.704901, 36.881391 ], [ 115.70544, 36.882024 ], [ 115.706131, 36.882739 ], [ 115.707011, 36.883583 ], [ 115.708165, 36.88455 ], [ 115.710029, 36.886168 ], [ 115.712204, 36.887733 ], [ 115.717063, 36.891162 ], [ 115.718517, 36.892124 ], [ 115.720259, 36.893232 ], [ 115.721044, 36.893631 ], [ 115.722709, 36.894299 ], [ 115.724866, 36.895144 ], [ 115.729316, 36.896627 ], [ 115.729644, 36.896791 ], [ 115.729901, 36.897026 ], [ 115.730195, 36.897471 ], [ 115.731174, 36.899423 ], [ 115.732921, 36.902366 ], [ 115.73448, 36.905624 ], [ 115.734703, 36.90601 ], [ 115.735067, 36.906374 ], [ 115.735558, 36.906656 ], [ 115.736133, 36.906761 ], [ 115.736643, 36.906838 ], [ 115.737006, 36.906978 ], [ 115.737828, 36.907355 ], [ 115.736318, 36.904248 ], [ 115.736351, 36.90416 ], [ 115.741277, 36.901999 ], [ 115.746106, 36.905739 ], [ 115.747542, 36.905237 ], [ 115.748363, 36.904819 ], [ 115.748587, 36.904595 ], [ 115.747904, 36.903191 ], [ 115.748509, 36.902668 ], [ 115.749631, 36.902039 ], [ 115.751275, 36.902098 ], [ 115.751495, 36.902156 ], [ 115.751931, 36.902628 ], [ 115.753899, 36.908695 ], [ 115.758363, 36.908505 ], [ 115.758596, 36.908664 ], [ 115.759289, 36.908694 ], [ 115.759363, 36.909251 ], [ 115.75933, 36.910486 ], [ 115.758844, 36.910547 ], [ 115.758941, 36.913041 ], [ 115.759007, 36.913231 ], [ 115.759311, 36.913323 ], [ 115.759515, 36.913559 ], [ 115.759518, 36.914227 ], [ 115.760375, 36.914392 ], [ 115.762106, 36.914544 ], [ 115.762187, 36.914634 ], [ 115.762205, 36.915235 ], [ 115.762799, 36.915397 ], [ 115.762849, 36.917479 ], [ 115.762761, 36.919447 ], [ 115.762845, 36.920596 ], [ 115.76446, 36.9206 ], [ 115.766999, 36.919649 ], [ 115.766975, 36.915665 ], [ 115.767531, 36.913193 ], [ 115.768454, 36.912843 ], [ 115.770978, 36.912928 ], [ 115.773644, 36.91285 ], [ 115.774425, 36.911823 ], [ 115.77394, 36.904613 ], [ 115.779797, 36.904367 ], [ 115.780254, 36.907814 ], [ 115.779099, 36.909028 ], [ 115.779389, 36.911051 ], [ 115.781256, 36.912574 ], [ 115.785322, 36.912309 ], [ 115.785538, 36.913979 ], [ 115.788013, 36.914324 ], [ 115.793076, 36.913917 ], [ 115.793707, 36.913753 ], [ 115.793755, 36.913222 ], [ 115.795303, 36.912987 ], [ 115.807262, 36.913072 ], [ 115.807706, 36.908827 ], [ 115.811762, 36.908277 ], [ 115.813007, 36.908252 ], [ 115.813967, 36.908979 ], [ 115.816478, 36.911361 ], [ 115.817527, 36.913178 ], [ 115.822304, 36.91203 ], [ 115.826082, 36.910565 ], [ 115.82661, 36.917072 ], [ 115.827244, 36.918254 ], [ 115.83296, 36.918312 ], [ 115.833087, 36.915863 ], [ 115.834298, 36.913835 ], [ 115.837023, 36.912827 ], [ 115.841359, 36.912009 ], [ 115.843317, 36.912365 ], [ 115.842599, 36.914482 ], [ 115.843007, 36.915442 ], [ 115.844097, 36.916063 ], [ 115.845763, 36.916156 ], [ 115.848312, 36.915944 ], [ 115.852311, 36.911959 ], [ 115.852867, 36.908082 ], [ 115.849707, 36.909394 ], [ 115.845523, 36.908898 ], [ 115.846067, 36.905877 ], [ 115.848029, 36.904531 ], [ 115.848876, 36.904293 ], [ 115.849452, 36.903986 ], [ 115.84996, 36.903571 ], [ 115.85066, 36.90314 ], [ 115.851018, 36.90305 ], [ 115.851451, 36.903059 ], [ 115.85191, 36.903217 ], [ 115.852577, 36.903334 ], [ 115.853176, 36.903377 ], [ 115.853801, 36.903286 ], [ 115.855401, 36.903255 ], [ 115.85775, 36.903259 ], [ 115.857758, 36.902785 ], [ 115.857967, 36.902769 ], [ 115.858073, 36.902372 ], [ 115.858059, 36.902213 ], [ 115.860874, 36.902273 ], [ 115.860844, 36.900932 ], [ 115.862756, 36.901231 ], [ 115.865109, 36.902628 ], [ 115.867132, 36.90452 ], [ 115.870244, 36.916033 ], [ 115.871085, 36.917254 ], [ 115.873184, 36.917161 ], [ 115.87357, 36.917353 ], [ 115.873431, 36.918265 ], [ 115.874528, 36.918102 ], [ 115.876073, 36.91733 ], [ 115.876106, 36.911772 ], [ 115.877678, 36.909693 ], [ 115.87958, 36.909737 ], [ 115.879615, 36.906806 ], [ 115.88224, 36.906727 ], [ 115.889199, 36.905428 ], [ 115.894874, 36.902349 ], [ 115.900047, 36.899401 ], [ 115.906321, 36.895963 ], [ 115.914868, 36.892752 ], [ 115.926566, 36.890684 ], [ 115.931241, 36.890072 ], [ 115.933975, 36.890047 ], [ 115.933975, 36.890907 ], [ 115.931832, 36.890876 ], [ 115.931832, 36.891511 ], [ 115.929312, 36.891663 ], [ 115.929564, 36.893484 ], [ 115.939398, 36.892797 ], [ 115.939567, 36.89124 ], [ 115.940554, 36.891094 ], [ 115.94173, 36.891115 ], [ 115.941623, 36.889674 ], [ 115.941916, 36.889661 ], [ 115.941873, 36.88942 ], [ 115.942203, 36.88942 ], [ 115.94209, 36.888321 ], [ 115.944688, 36.885494 ], [ 115.95628, 36.884616 ], [ 115.95687, 36.882928 ], [ 115.958111, 36.883103 ], [ 115.958199, 36.883457 ], [ 115.96062, 36.883274 ], [ 115.961489, 36.884745 ], [ 115.963765, 36.88731 ], [ 115.96462, 36.887317 ], [ 115.965062, 36.887329 ], [ 115.966118, 36.887357 ], [ 115.968, 36.887409 ], [ 115.9683, 36.890565 ], [ 115.970612, 36.890522 ], [ 115.970912, 36.891346 ], [ 115.972923, 36.891408 ], [ 115.973307, 36.892917 ], [ 115.975704, 36.892807 ], [ 115.975404, 36.890578 ], [ 115.976936, 36.890455 ], [ 115.976731, 36.888516 ], [ 115.979768, 36.888198 ], [ 115.97964, 36.886656 ], [ 115.980863, 36.886425 ], [ 115.980766, 36.88572 ], [ 115.980355, 36.885357 ], [ 115.980331, 36.884592 ], [ 115.983724, 36.884406 ], [ 115.983751, 36.883409 ], [ 115.984414, 36.883433 ], [ 115.984364, 36.881886 ], [ 115.986594, 36.881821 ], [ 115.986644, 36.882596 ], [ 115.986592, 36.883226 ], [ 115.987668, 36.883279 ], [ 115.987704, 36.884041 ], [ 115.990363, 36.884143 ], [ 115.99035, 36.885016 ], [ 115.991452, 36.884893 ], [ 115.99986, 36.883958 ], [ 116.008142, 36.885326 ], [ 116.01797, 36.887711 ], [ 116.018612, 36.892374 ], [ 116.017284, 36.893235 ], [ 116.017712, 36.895155 ], [ 116.02028, 36.89477 ], [ 116.020501, 36.896131 ], [ 116.021479, 36.896137 ], [ 116.02105, 36.89415 ], [ 116.022035, 36.893563 ], [ 116.021564, 36.890959 ], [ 116.023276, 36.891023 ], [ 116.023319, 36.888622 ], [ 116.023961, 36.888653 ], [ 116.023791, 36.886629 ], [ 116.028156, 36.887408 ], [ 116.029797, 36.890931 ], [ 116.036366, 36.892697 ], [ 116.039424, 36.892901 ], [ 116.044176, 36.893959 ], [ 116.046111, 36.890468 ], [ 116.048044, 36.889733 ], [ 116.053177, 36.889331 ], [ 116.05599, 36.888038 ], [ 116.060384, 36.888369 ], [ 116.060524, 36.888709 ], [ 116.064683, 36.887932 ], [ 116.065257, 36.889943 ], [ 116.067086, 36.890077 ], [ 116.070018, 36.888923 ], [ 116.069732, 36.88832 ], [ 116.071254, 36.887313 ], [ 116.076376, 36.885025 ], [ 116.076502, 36.883281 ], [ 116.090454, 36.883187 ], [ 116.091282, 36.883084 ], [ 116.092252, 36.883331 ], [ 116.092309, 36.886838 ], [ 116.090632, 36.885853 ], [ 116.090392, 36.886234 ], [ 116.09137, 36.890758 ], [ 116.093677, 36.891783 ], [ 116.101509, 36.893428 ], [ 116.101445, 36.893933 ], [ 116.10308, 36.894262 ], [ 116.104806, 36.895367 ], [ 116.10503, 36.896874 ], [ 116.106922, 36.897292 ], [ 116.107981, 36.897331 ], [ 116.109016, 36.897098 ], [ 116.109906, 36.89667 ], [ 116.112316, 36.895109 ], [ 116.113942, 36.896207 ], [ 116.116186, 36.894086 ], [ 116.116301, 36.893394 ], [ 116.11466, 36.892257 ], [ 116.117814, 36.890076 ], [ 116.119368, 36.891318 ], [ 116.120413, 36.892434 ], [ 116.126816, 36.897076 ], [ 116.127533, 36.897171 ], [ 116.133737, 36.902214 ], [ 116.13515, 36.903664 ], [ 116.136813, 36.905906 ], [ 116.140491, 36.910218 ], [ 116.144581, 36.912402 ], [ 116.14674, 36.912803 ], [ 116.147106, 36.913134 ], [ 116.155614, 36.915248 ], [ 116.158521, 36.916431 ], [ 116.162419, 36.919305 ], [ 116.164198, 36.920743 ], [ 116.165265, 36.924034 ], [ 116.166341, 36.925896 ], [ 116.167409, 36.929189 ], [ 116.167745, 36.932042 ], [ 116.167394, 36.937321 ], [ 116.167188, 36.937501 ], [ 116.167181, 36.939044 ], [ 116.167035, 36.940593 ], [ 116.166669, 36.942039 ], [ 116.166647, 36.944902 ], [ 116.167036, 36.945637 ], [ 116.167027, 36.947182 ], [ 116.167906, 36.947616 ], [ 116.169278, 36.949815 ], [ 116.174809, 36.955674 ], [ 116.174978, 36.956241 ], [ 116.177884, 36.959085 ], [ 116.178643, 36.960842 ], [ 116.179902, 36.960472 ], [ 116.17927, 36.958785 ], [ 116.180352, 36.958135 ], [ 116.181048, 36.959696 ], [ 116.183227, 36.958987 ], [ 116.18572, 36.962821 ], [ 116.188346, 36.961265 ], [ 116.189206, 36.961294 ], [ 116.193597, 36.965392 ], [ 116.194875, 36.964939 ], [ 116.194175, 36.963634 ], [ 116.194438, 36.963147 ], [ 116.195987, 36.962884 ], [ 116.196561, 36.963553 ], [ 116.20107, 36.962647 ], [ 116.205836, 36.962641 ], [ 116.206553, 36.965163 ], [ 116.207967, 36.968191 ], [ 116.206397, 36.968841 ], [ 116.205407, 36.967161 ], [ 116.2046, 36.967199 ], [ 116.205273, 36.969618 ], [ 116.204881, 36.969667 ], [ 116.209482, 36.974668 ], [ 116.210986, 36.974409 ], [ 116.213469, 36.979123 ], [ 116.210851, 36.979806 ], [ 116.206331, 36.981966 ], [ 116.204929, 36.983644 ], [ 116.20385, 36.98653 ], [ 116.20471, 36.988419 ], [ 116.205988, 36.989585 ], [ 116.21428, 36.992999 ], [ 116.217121, 36.993894 ], [ 116.219413, 36.993373 ], [ 116.220826, 36.993829 ], [ 116.220891, 36.993951 ], [ 116.223547, 36.995964 ], [ 116.225611, 36.999951 ], [ 116.225793, 36.999978 ], [ 116.225819, 36.999947 ], [ 116.225852, 36.999986 ], [ 116.227628, 37.000245 ], [ 116.227762, 37.000776 ], [ 116.228449, 37.000703 ], [ 116.228547, 37.000808 ], [ 116.228683, 37.007205 ], [ 116.230097, 37.009642 ], [ 116.223417, 37.009633 ], [ 116.222985, 37.011758 ], [ 116.221211, 37.012044 ], [ 116.220269, 37.011757 ], [ 116.220356, 37.009899 ], [ 116.218275, 37.009732 ], [ 116.216565, 37.009825 ], [ 116.216691, 37.01205 ], [ 116.219104, 37.015222 ], [ 116.219684, 37.016223 ], [ 116.219204, 37.01654 ], [ 116.219833, 37.018442 ], [ 116.218678, 37.018993 ], [ 116.219146, 37.0203 ], [ 116.219732, 37.022874 ], [ 116.219885, 37.024878 ], [ 116.221114, 37.027334 ], [ 116.222044, 37.028302 ], [ 116.222554, 37.029333 ], [ 116.227172, 37.031712 ], [ 116.229083, 37.030555 ], [ 116.231834, 37.029252 ], [ 116.231078, 37.027839 ], [ 116.231491, 37.027554 ], [ 116.236548, 37.026466 ], [ 116.238611, 37.026759 ], [ 116.241455, 37.026442 ], [ 116.244676, 37.024983 ], [ 116.244863, 37.024128 ], [ 116.243837, 37.023928 ], [ 116.242513, 37.022185 ], [ 116.241933, 37.019174 ], [ 116.243194, 37.017275 ], [ 116.24525, 37.01663 ], [ 116.24528, 37.016523 ], [ 116.244619, 37.015555 ], [ 116.243837, 37.014221 ], [ 116.245591, 37.013073 ], [ 116.247475, 37.011788 ], [ 116.249074, 37.007797 ], [ 116.249863, 37.007932 ], [ 116.251122, 37.010647 ], [ 116.255635, 37.010874 ], [ 116.262121, 37.010012 ], [ 116.263264, 37.009102 ], [ 116.263824, 37.007278 ], [ 116.264461, 37.006784 ], [ 116.269557, 37.005795 ], [ 116.277338, 36.999851 ], [ 116.282247, 36.996901 ], [ 116.285008, 36.995271 ], [ 116.288177, 36.995266 ], [ 116.288401, 36.997878 ], [ 116.292575, 36.997573 ], [ 116.293096, 36.99955 ], [ 116.294305, 36.99911 ], [ 116.293618, 36.996564 ], [ 116.295407, 36.996262 ], [ 116.295454, 36.995194 ], [ 116.299618, 36.994465 ], [ 116.299188, 36.989703 ], [ 116.301126, 36.988782 ], [ 116.301259, 36.98872 ], [ 116.302127, 36.988306 ], [ 116.305097, 36.986029 ], [ 116.311265, 36.981301 ], [ 116.318313, 36.971495 ], [ 116.323495, 36.969469 ], [ 116.327486, 36.968719 ], [ 116.327652, 36.969989 ], [ 116.332235, 36.969706 ], [ 116.334329, 36.971377 ], [ 116.33499, 36.97381 ], [ 116.333539, 36.974015 ], [ 116.335539, 36.979663 ], [ 116.336173, 36.979753 ], [ 116.339179, 36.978994 ], [ 116.339882, 36.980561 ], [ 116.340593, 36.98046 ], [ 116.342135, 36.979541 ], [ 116.341077, 36.976533 ], [ 116.343792, 36.976406 ], [ 116.343102, 36.973814 ], [ 116.342886, 36.972584 ], [ 116.344623, 36.972368 ], [ 116.345641, 36.976482 ], [ 116.348536, 36.976644 ], [ 116.34947, 36.976358 ], [ 116.350891, 36.974892 ], [ 116.355031, 36.974291 ], [ 116.354951, 36.971612 ], [ 116.360568, 36.971252 ], [ 116.35922, 36.966198 ], [ 116.364577, 36.96557 ], [ 116.36443, 36.964923 ], [ 116.364361, 36.962669 ], [ 116.368614, 36.961892 ], [ 116.368035, 36.964039 ], [ 116.372992, 36.963508 ], [ 116.373434, 36.965698 ], [ 116.389391, 36.967332 ], [ 116.399955, 36.968468 ], [ 116.403716, 36.970723 ], [ 116.406762, 36.973861 ], [ 116.409057, 36.975177 ], [ 116.41203, 36.975499 ], [ 116.415229, 36.975031 ], [ 116.419239, 36.972574 ], [ 116.423457, 36.968539 ], [ 116.426372, 36.968033 ], [ 116.426474, 36.967804 ], [ 116.428517, 36.967589 ], [ 116.428124, 36.96378 ], [ 116.430486, 36.961677 ], [ 116.43215, 36.958336 ], [ 116.434285, 36.957256 ], [ 116.437879, 36.957159 ], [ 116.437018, 36.95474 ], [ 116.436823, 36.953734 ], [ 116.443658, 36.952383 ], [ 116.444556, 36.952295 ], [ 116.448807, 36.954134 ], [ 116.452254, 36.954791 ], [ 116.454089, 36.953311 ], [ 116.454471, 36.951233 ], [ 116.456135, 36.951334 ], [ 116.456354, 36.950159 ], [ 116.456947, 36.949775 ], [ 116.459096, 36.949655 ], [ 116.459957, 36.949934 ], [ 116.461042, 36.948122 ], [ 116.462766, 36.946788 ], [ 116.464044, 36.946197 ], [ 116.465366, 36.946511 ], [ 116.464763, 36.939466 ], [ 116.460742, 36.939771 ], [ 116.455782, 36.940148 ], [ 116.453603, 36.938428 ], [ 116.452573, 36.936341 ], [ 116.451063, 36.936232 ], [ 116.447875, 36.935553 ], [ 116.447143, 36.933304 ], [ 116.446549, 36.933036 ], [ 116.443843, 36.934294 ], [ 116.443355, 36.937705 ], [ 116.440591, 36.937533 ], [ 116.439686, 36.936892 ], [ 116.438532, 36.932844 ], [ 116.437916, 36.932905 ], [ 116.437301, 36.931649 ], [ 116.439316, 36.930916 ], [ 116.439572, 36.929284 ], [ 116.438899, 36.923126 ], [ 116.436494, 36.919437 ], [ 116.4335, 36.9182 ], [ 116.433338, 36.917659 ], [ 116.43404, 36.915921 ], [ 116.439705, 36.916029 ], [ 116.440501, 36.916478 ], [ 116.440991, 36.915816 ], [ 116.441881, 36.915941 ], [ 116.44327, 36.9152 ], [ 116.44345, 36.914936 ], [ 116.444355, 36.912803 ], [ 116.445771, 36.909121 ], [ 116.444766, 36.908841 ], [ 116.445285, 36.907672 ], [ 116.44667, 36.905862 ], [ 116.447681, 36.906667 ], [ 116.449467, 36.90677 ], [ 116.449575, 36.903781 ], [ 116.448423, 36.903644 ], [ 116.448086, 36.903735 ], [ 116.448169, 36.902815 ], [ 116.447496, 36.902533 ], [ 116.443587, 36.902061 ], [ 116.442838, 36.902379 ], [ 116.44245, 36.900189 ], [ 116.442105, 36.899409 ], [ 116.439136, 36.900649 ], [ 116.436661, 36.899454 ], [ 116.435207, 36.899911 ], [ 116.433549, 36.901176 ], [ 116.435413, 36.904602 ], [ 116.435558, 36.905855 ], [ 116.428142, 36.907848 ], [ 116.427494, 36.90753 ], [ 116.425355, 36.906966 ], [ 116.424165, 36.907761 ], [ 116.419624, 36.90676 ], [ 116.419108, 36.905274 ], [ 116.415696, 36.904668 ], [ 116.414975, 36.902727 ], [ 116.415603, 36.90265 ], [ 116.414684, 36.899837 ], [ 116.412061, 36.893694 ], [ 116.413553, 36.8934 ], [ 116.414886, 36.890626 ], [ 116.415948, 36.89059 ], [ 116.416282, 36.889947 ], [ 116.416182, 36.887374 ], [ 116.414937, 36.887541 ], [ 116.414558, 36.888555 ], [ 116.413154, 36.888259 ], [ 116.413026, 36.886597 ], [ 116.414623, 36.886271 ], [ 116.414126, 36.884291 ], [ 116.410844, 36.88468 ], [ 116.410397, 36.883322 ], [ 116.410048, 36.880801 ], [ 116.411201, 36.879137 ], [ 116.413638, 36.876626 ], [ 116.417006, 36.876008 ], [ 116.424838, 36.876061 ], [ 116.425706, 36.877841 ], [ 116.427619, 36.877128 ], [ 116.428266, 36.875913 ], [ 116.427883, 36.873997 ], [ 116.426831, 36.871932 ], [ 116.425641, 36.871942 ], [ 116.424713, 36.868749 ], [ 116.423816, 36.864661 ], [ 116.422591, 36.864748 ], [ 116.422289, 36.864354 ], [ 116.422229, 36.863977 ], [ 116.418467, 36.864155 ], [ 116.415066, 36.864081 ], [ 116.412932, 36.863267 ], [ 116.406854, 36.860503 ], [ 116.406725, 36.860086 ], [ 116.406451, 36.858101 ], [ 116.406213, 36.857931 ], [ 116.408252, 36.856429 ], [ 116.409506, 36.856055 ], [ 116.409451, 36.855367 ], [ 116.407713, 36.850866 ], [ 116.405281, 36.851202 ], [ 116.404724, 36.850584 ], [ 116.40403, 36.846243 ], [ 116.401303, 36.846155 ], [ 116.400994, 36.844645 ], [ 116.400935, 36.844083 ], [ 116.400655, 36.840679 ], [ 116.403374, 36.83816 ], [ 116.403687, 36.837057 ], [ 116.399716, 36.826839 ], [ 116.399081, 36.826194 ], [ 116.397153, 36.825701 ], [ 116.396663, 36.824893 ], [ 116.396303, 36.824706 ], [ 116.395445, 36.825683 ], [ 116.393965, 36.823328 ], [ 116.394233, 36.822531 ], [ 116.396334, 36.820909 ], [ 116.393323, 36.819236 ], [ 116.396862, 36.816995 ], [ 116.396395, 36.815178 ], [ 116.397451, 36.81505 ], [ 116.402161, 36.8152 ], [ 116.402743, 36.81493 ], [ 116.402746, 36.814206 ], [ 116.40206, 36.81388 ], [ 116.402094, 36.809984 ], [ 116.404179, 36.809823 ], [ 116.403305, 36.806492 ], [ 116.398297, 36.806565 ], [ 116.397938, 36.806958 ], [ 116.399087, 36.810016 ], [ 116.398164, 36.810121 ], [ 116.393603, 36.808693 ], [ 116.392531, 36.809156 ], [ 116.3918, 36.808904 ], [ 116.386351, 36.804621 ], [ 116.386081, 36.802389 ], [ 116.379633, 36.801215 ], [ 116.378682, 36.801603 ], [ 116.37708, 36.802456 ], [ 116.375218, 36.803124 ], [ 116.373425, 36.801396 ], [ 116.37509, 36.800012 ], [ 116.372866, 36.799028 ], [ 116.371966, 36.798021 ], [ 116.370159, 36.796525 ], [ 116.370895, 36.795949 ], [ 116.373167, 36.79704 ], [ 116.374064, 36.796908 ], [ 116.37277, 36.794532 ], [ 116.373099, 36.793986 ], [ 116.374039, 36.794024 ], [ 116.375313, 36.795977 ], [ 116.379364, 36.795913 ], [ 116.378976, 36.793346 ], [ 116.380303, 36.792396 ], [ 116.383416, 36.791925 ], [ 116.390341, 36.791956 ], [ 116.390941, 36.791017 ], [ 116.390602, 36.790005 ], [ 116.391537, 36.788772 ], [ 116.390526, 36.78633 ], [ 116.390976, 36.786032 ], [ 116.392804, 36.785694 ], [ 116.394153, 36.784558 ], [ 116.3931, 36.779794 ], [ 116.396442, 36.772877 ], [ 116.397843, 36.767746 ], [ 116.397821, 36.767708 ], [ 116.397861, 36.767678 ], [ 116.399759, 36.760726 ], [ 116.398265, 36.751802 ], [ 116.395947, 36.74586 ], [ 116.392463, 36.741024 ], [ 116.388606, 36.741226 ], [ 116.385744, 36.734911 ], [ 116.383592, 36.733807 ], [ 116.385483, 36.732036 ], [ 116.382431, 36.730834 ], [ 116.380222, 36.72483 ], [ 116.381213, 36.724915 ], [ 116.380987, 36.721176 ], [ 116.382602, 36.721175 ], [ 116.381707, 36.719202 ], [ 116.390524, 36.717831 ], [ 116.391719, 36.71496 ], [ 116.398508, 36.709892 ], [ 116.401269, 36.704329 ], [ 116.401818, 36.696594 ], [ 116.401183, 36.688582 ], [ 116.402564, 36.682164 ], [ 116.405359, 36.6762 ], [ 116.405547, 36.672987 ], [ 116.404658, 36.672377 ], [ 116.404735, 36.67059 ], [ 116.405766, 36.669218 ], [ 116.406106, 36.663371 ], [ 116.406784, 36.656835 ], [ 116.408555, 36.648476 ], [ 116.407366, 36.642755 ], [ 116.40219, 36.636139 ], [ 116.400176, 36.631568 ], [ 116.400267, 36.624454 ], [ 116.400355, 36.622221 ], [ 116.401407, 36.618762 ], [ 116.405438, 36.614825 ], [ 116.406335, 36.610225 ], [ 116.405664, 36.607954 ], [ 116.405055, 36.602003 ], [ 116.404413, 36.59285 ], [ 116.40233, 36.580948 ], [ 116.396195, 36.571718 ], [ 116.394571, 36.565981 ], [ 116.394159, 36.559553 ], [ 116.393482, 36.53977 ], [ 116.39343, 36.53336 ], [ 116.395053, 36.524449 ], [ 116.397735, 36.522905 ], [ 116.407192, 36.518385 ], [ 116.406126, 36.515572 ], [ 116.409977, 36.515791 ], [ 116.417696, 36.508573 ], [ 116.419279, 36.507951 ], [ 116.420408, 36.509256 ], [ 116.419918, 36.507083 ], [ 116.42234, 36.505694 ], [ 116.421684, 36.504272 ], [ 116.424443, 36.503377 ], [ 116.423299, 36.501674 ], [ 116.42568, 36.501393 ], [ 116.425014, 36.499509 ], [ 116.437341, 36.497948 ], [ 116.436825, 36.496364 ], [ 116.439443, 36.49636 ], [ 116.438981, 36.494388 ], [ 116.440904, 36.493936 ], [ 116.440267, 36.488597 ], [ 116.443609, 36.487585 ], [ 116.44285, 36.4853 ], [ 116.449059, 36.482415 ], [ 116.447835, 36.478127 ], [ 116.451457, 36.480212 ], [ 116.453491, 36.479784 ], [ 116.453574, 36.475608 ], [ 116.453581, 36.475277 ], [ 116.453681, 36.470796 ], [ 116.451945, 36.466226 ], [ 116.449914, 36.461655 ], [ 116.450998, 36.455235 ], [ 116.455774, 36.449716 ], [ 116.46825, 36.449192 ], [ 116.475985, 36.448175 ], [ 116.477106, 36.44926 ], [ 116.477538, 36.449793 ], [ 116.478281, 36.450446 ], [ 116.47957, 36.450861 ], [ 116.480027, 36.451098 ], [ 116.482133, 36.453135 ], [ 116.482686, 36.45357 ], [ 116.483369, 36.453846 ], [ 116.483724, 36.454289 ], [ 116.485224, 36.453999 ], [ 116.485016, 36.453466 ], [ 116.485596, 36.452717 ], [ 116.488138, 36.450459 ], [ 116.49394, 36.449996 ], [ 116.500983, 36.448186 ], [ 116.50166, 36.447903 ], [ 116.500252, 36.444261 ], [ 116.502222, 36.444266 ], [ 116.502195, 36.441971 ], [ 116.504184, 36.44128 ], [ 116.50617, 36.441495 ], [ 116.507272, 36.441125 ], [ 116.507162, 36.440215 ], [ 116.504853, 36.433603 ], [ 116.505046, 36.432577 ], [ 116.506313, 36.429908 ], [ 116.507224, 36.429723 ], [ 116.509233, 36.428225 ], [ 116.511796, 36.427263 ], [ 116.512195, 36.428333 ], [ 116.512787, 36.428116 ], [ 116.517926, 36.424503 ], [ 116.518253, 36.423819 ], [ 116.518268, 36.423453 ], [ 116.521613, 36.424302 ], [ 116.530755, 36.429265 ], [ 116.533401, 36.428901 ], [ 116.534148, 36.428539 ], [ 116.534194, 36.427561 ], [ 116.530381, 36.418404 ], [ 116.532957, 36.41813 ], [ 116.532649, 36.416682 ], [ 116.532623, 36.416531 ], [ 116.533449, 36.41552 ], [ 116.533722, 36.415459 ], [ 116.536513, 36.416514 ], [ 116.538969, 36.418155 ], [ 116.540812, 36.419646 ], [ 116.542658, 36.41928 ], [ 116.544087, 36.417352 ], [ 116.540896, 36.412058 ], [ 116.541654, 36.410547 ], [ 116.540693, 36.410125 ], [ 116.540252, 36.41003 ], [ 116.540732, 36.40892 ], [ 116.537756, 36.406918 ], [ 116.537249, 36.406576 ], [ 116.530452, 36.397456 ], [ 116.527085, 36.393087 ], [ 116.52554, 36.389223 ], [ 116.523119, 36.387245 ], [ 116.518431, 36.385068 ], [ 116.514856, 36.384202 ], [ 116.514489, 36.384114 ], [ 116.508824, 36.37871 ], [ 116.503495, 36.373956 ], [ 116.498122, 36.36988 ], [ 116.494354, 36.364363 ], [ 116.491681, 36.358558 ], [ 116.49037, 36.354275 ], [ 116.488981, 36.352569 ], [ 116.485449, 36.350157 ], [ 116.483452, 36.347407 ], [ 116.481342, 36.342284 ], [ 116.480109, 36.338547 ], [ 116.478946, 36.336817 ], [ 116.476489, 36.335584 ], [ 116.473946, 36.33528 ], [ 116.462746, 36.337827 ], [ 116.453283, 36.338367 ], [ 116.447127, 36.338221 ], [ 116.443306, 36.336935 ], [ 116.439755, 36.332868 ], [ 116.436889, 36.327259 ], [ 116.435595, 36.321506 ], [ 116.431506, 36.318409 ], [ 116.42482, 36.317762 ], [ 116.411135, 36.318883 ], [ 116.400906, 36.318759 ], [ 116.393734, 36.31632 ], [ 116.384009, 36.311923 ], [ 116.375378, 36.307232 ], [ 116.368727, 36.303641 ], [ 116.357683, 36.301017 ], [ 116.345598, 36.297576 ], [ 116.334625, 36.293845 ], [ 116.325511, 36.290489 ], [ 116.316935, 36.284503 ], [ 116.309358, 36.276042 ], [ 116.30513, 36.270383 ], [ 116.303473, 36.265209 ], [ 116.301493, 36.259339 ], [ 116.29475, 36.251901 ], [ 116.286818, 36.245671 ], [ 116.280646, 36.239092 ], [ 116.278077, 36.233826 ], [ 116.27806, 36.2274 ], [ 116.274537, 36.221855 ], [ 116.265285, 36.214288 ], [ 116.256399, 36.209251 ], [ 116.249483, 36.20366 ], [ 116.241976, 36.195558 ], [ 116.238391, 36.192536 ], [ 116.235536, 36.188199 ], [ 116.229262, 36.180901 ], [ 116.221877, 36.174298 ], [ 116.220444, 36.173705 ], [ 116.218139, 36.172748 ], [ 116.218126, 36.172744 ], [ 116.218116, 36.172738 ], [ 116.212547, 36.170427 ], [ 116.207426, 36.169782 ], [ 116.198878, 36.169878 ], [ 116.190311, 36.170135 ], [ 116.182282, 36.170346 ], [ 116.174384, 36.171297 ], [ 116.163732, 36.171167 ], [ 116.15862, 36.168705 ], [ 116.159244, 36.160381 ], [ 116.160538, 36.151998 ], [ 116.158542, 36.145938 ], [ 116.148202, 36.142777 ], [ 116.138305, 36.141898 ], [ 116.130716, 36.140294 ], [ 116.127455, 36.139443 ], [ 116.122747, 36.137829 ], [ 116.118005, 36.136205 ], [ 116.112744, 36.132836 ], [ 116.111077, 36.130758 ], [ 116.109739, 36.126626 ], [ 116.108168, 36.121825 ], [ 116.104842, 36.118871 ], [ 116.099954, 36.116285 ], [ 116.093484, 36.111852 ], [ 116.071142, 36.108719 ], [ 116.057102, 36.106406 ], [ 116.051562, 36.104743 ], [ 116.048427, 36.100912 ], [ 116.023032, 36.072197 ], [ 116.010661, 36.061303 ], [ 115.993854, 36.051471 ], [ 115.987856, 36.047226 ], [ 115.984167, 36.045471 ], [ 115.977241, 36.044826 ], [ 115.958503, 36.04169 ], [ 115.943186, 36.037122 ], [ 115.930359, 36.031587 ], [ 115.917438, 36.021711 ], [ 115.913741, 36.019867 ], [ 115.911901, 36.019774 ], [ 115.9083, 36.020422 ], [ 115.897869, 36.024672 ], [ 115.893261, 36.026517 ], [ 115.890484, 36.026382 ], [ 115.866679, 36.016877 ], [ 115.863911, 36.015492 ], [ 115.862896, 36.014201 ], [ 115.862157, 36.011707 ], [ 115.860491, 36.008199 ], [ 115.859023, 36.006996 ], [ 115.855887, 36.005473 ], [ 115.854121, 36.003861 ], [ 115.848305, 36.003216 ], [ 115.844434, 36.003818 ], [ 115.84065, 36.005109 ], [ 115.836952, 36.00714 ], [ 115.831874, 36.01111 ], [ 115.829756, 36.011665 ], [ 115.826154, 36.011572 ], [ 115.820521, 36.011665 ], [ 115.817535, 36.011857 ], [ 115.817498, 36.012507 ], [ 115.814925, 36.012635 ], [ 115.81445, 36.012767 ], [ 115.811594, 36.012827 ], [ 115.809714, 36.012466 ], [ 115.808747, 36.012171 ], [ 115.807569, 36.011985 ], [ 115.807158, 36.011794 ], [ 115.806733, 36.011445 ], [ 115.798915, 36.009474 ], [ 115.794898, 36.008496 ], [ 115.79177, 36.007021 ], [ 115.790784, 36.006082 ], [ 115.790149, 36.005662 ], [ 115.789213, 36.005202 ], [ 115.788391, 36.004608 ], [ 115.787826, 36.003809 ], [ 115.78718, 36.00327 ], [ 115.786619, 36.002923 ], [ 115.786032, 36.002885 ], [ 115.785033, 36.002176 ], [ 115.783957, 36.001186 ], [ 115.783223, 36.000564 ], [ 115.781465, 35.999337 ], [ 115.779494, 35.998606 ], [ 115.777632, 35.997469 ], [ 115.775647, 35.99567 ], [ 115.774659, 35.99459 ], [ 115.774091, 35.993807 ], [ 115.774819, 35.993283 ], [ 115.775948, 35.992075 ], [ 115.776343, 35.991901 ], [ 115.777413, 35.991648 ], [ 115.780966, 35.991247 ], [ 115.768742, 35.981909 ], [ 115.768925, 35.974552 ], [ 115.765276, 35.972792 ], [ 115.762472, 35.972052 ], [ 115.758548, 35.970989 ], [ 115.754936, 35.970568 ], [ 115.75157, 35.970597 ], [ 115.750882, 35.97046 ], [ 115.748464, 35.970267 ], [ 115.735928, 35.968035 ], [ 115.733943, 35.967788 ], [ 115.733847, 35.967756 ], [ 115.733707, 35.967662 ], [ 115.733633, 35.967699 ], [ 115.730202, 35.966924 ], [ 115.727264, 35.966847 ], [ 115.72634, 35.967191 ], [ 115.725528, 35.96747 ], [ 115.724048, 35.968193 ], [ 115.722542, 35.968835 ], [ 115.719608, 35.969435 ], [ 115.715244, 35.970428 ], [ 115.713073, 35.971055 ], [ 115.712126, 35.971419 ], [ 115.711439, 35.971296 ], [ 115.707513, 35.96999 ], [ 115.705768, 35.969722 ], [ 115.704649, 35.969588 ], [ 115.704118, 35.969467 ], [ 115.703459, 35.96925 ], [ 115.702494, 35.968604 ], [ 115.702125, 35.96841 ], [ 115.701096, 35.967988 ], [ 115.699064, 35.967381 ], [ 115.698501, 35.967286 ], [ 115.697563, 35.967467 ], [ 115.697269, 35.967454 ], [ 115.693658, 35.966365 ], [ 115.692955, 35.966103 ], [ 115.692229, 35.965514 ], [ 115.691071, 35.965095 ], [ 115.689196, 35.964118 ], [ 115.687762, 35.963071 ], [ 115.685705, 35.961673 ], [ 115.685264, 35.961599 ], [ 115.684228, 35.961723 ], [ 115.684878, 35.960895 ], [ 115.68485, 35.960478 ], [ 115.682921, 35.958228 ], [ 115.68126, 35.955303 ], [ 115.680644, 35.953586 ], [ 115.679844, 35.950764 ], [ 115.67932, 35.94651 ], [ 115.678882, 35.945306 ], [ 115.678353, 35.944472 ], [ 115.674914, 35.941597 ], [ 115.673949, 35.94056 ], [ 115.671382, 35.939241 ], [ 115.669706, 35.938549 ], [ 115.662242, 35.936661 ], [ 115.658933, 35.935977 ], [ 115.65602, 35.93461 ], [ 115.650156, 35.932165 ], [ 115.647419, 35.93004 ], [ 115.646146, 35.929054 ], [ 115.645836, 35.927652 ], [ 115.6429, 35.92313 ], [ 115.642323, 35.922386 ], [ 115.640426, 35.92098 ], [ 115.636774, 35.920209 ], [ 115.634175, 35.920491 ], [ 115.631926, 35.920279 ], [ 115.630241, 35.920771 ], [ 115.629117, 35.921685 ], [ 115.628133, 35.922809 ], [ 115.626728, 35.923301 ], [ 115.623076, 35.923442 ], [ 115.613172, 35.924287 ], [ 115.605657, 35.925554 ], [ 115.601724, 35.926046 ], [ 115.598634, 35.925906 ], [ 115.592595, 35.924231 ], [ 115.591886, 35.924231 ], [ 115.583399, 35.923864 ], [ 115.578141, 35.921927 ], [ 115.548973, 35.902316 ], [ 115.542517, 35.898163 ], [ 115.536424, 35.896596 ], [ 115.526643, 35.894013 ], [ 115.50753, 35.890414 ], [ 115.497567, 35.888752 ], [ 115.482149, 35.88079 ], [ 115.478729, 35.878528 ], [ 115.470325, 35.875804 ], [ 115.454097, 35.867682 ], [ 115.448987, 35.862925 ], [ 115.446101, 35.860081 ], [ 115.437968, 35.850715 ], [ 115.434509, 35.846715 ], [ 115.427796, 35.838951 ], [ 115.426795, 35.833755 ], [ 115.42083, 35.833708 ], [ 115.421111, 35.830072 ], [ 115.411867, 35.824869 ], [ 115.401514, 35.808546 ], [ 115.399287, 35.807238 ], [ 115.390232, 35.80192 ], [ 115.385861, 35.800019 ], [ 115.378288, 35.796711 ], [ 115.375299, 35.795407 ], [ 115.373148, 35.794033 ], [ 115.371566, 35.792749 ], [ 115.369421, 35.791655 ], [ 115.364869, 35.788749 ], [ 115.357498, 35.779841 ], [ 115.355724, 35.780237 ], [ 115.33588, 35.792484 ], [ 115.329049, 35.796686 ], [ 115.328215, 35.797907 ], [ 115.328171, 35.798784 ], [ 115.329092, 35.802663 ], [ 115.329743, 35.81427 ], [ 115.332234, 35.824056 ], [ 115.333893, 35.829871 ], [ 115.337356, 35.836035 ], [ 115.338007, 35.837465 ], [ 115.338094, 35.838665 ], [ 115.337313, 35.840512 ], [ 115.335165, 35.843015 ], [ 115.335319, 35.84367 ], [ 115.338586, 35.84308 ], [ 115.339388, 35.847697 ], [ 115.338713, 35.847782 ], [ 115.338755, 35.848182 ], [ 115.340737, 35.847992 ], [ 115.343576, 35.860878 ], [ 115.336761, 35.861846 ], [ 115.336967, 35.862876 ], [ 115.336061, 35.862998 ], [ 115.335855, 35.863987 ], [ 115.332191, 35.864646 ], [ 115.333303, 35.870575 ], [ 115.336843, 35.870081 ], [ 115.337625, 35.872058 ], [ 115.348868, 35.869176 ], [ 115.349136, 35.870267 ], [ 115.350865, 35.870143 ], [ 115.351442, 35.878585 ], [ 115.354077, 35.87908 ], [ 115.356075, 35.88969 ], [ 115.358227, 35.893919 ], [ 115.358869, 35.897888 ], [ 115.360067, 35.908713 ], [ 115.360719, 35.912359 ], [ 115.361362, 35.920207 ], [ 115.360441, 35.924729 ], [ 115.358088, 35.929368 ], [ 115.353469, 35.93292 ], [ 115.350239, 35.93532 ], [ 115.348112, 35.937399 ], [ 115.347375, 35.938828 ], [ 115.347331, 35.940168 ], [ 115.348347, 35.945567 ], [ 115.350465, 35.954499 ], [ 115.355319, 35.967333 ], [ 115.357072, 35.971879 ], [ 115.358644, 35.973171 ], [ 115.361039, 35.97405 ], [ 115.365008, 35.974743 ], [ 115.369262, 35.974696 ], [ 115.380202, 35.974307 ], [ 115.382, 35.974952 ], [ 115.383294, 35.976107 ], [ 115.383988, 35.977537 ], [ 115.384493, 35.981739 ], [ 115.385464, 35.986954 ], [ 115.386759, 35.989009 ], [ 115.389893, 35.991502 ], [ 115.396041, 35.994782 ], [ 115.399827, 35.996444 ], [ 115.413582, 36.004572 ], [ 115.421709, 36.006513 ], [ 115.429377, 36.007161 ], [ 115.437036, 36.008732 ], [ 115.439901, 36.010302 ], [ 115.441473, 36.011686 ], [ 115.441723, 36.012526 ], [ 115.441709, 36.014372 ], [ 115.441662, 36.016008 ], [ 115.4416, 36.017317 ], [ 115.441475, 36.018999 ], [ 115.44128, 36.02097 ], [ 115.441311, 36.021641 ], [ 115.441546, 36.023293 ], [ 115.441872, 36.024478 ], [ 115.442176, 36.026636 ], [ 115.442363, 36.027882 ], [ 115.442908, 36.029581 ], [ 115.443337, 36.030789 ], [ 115.443368, 36.031178 ], [ 115.44312, 36.032409 ], [ 115.442917, 36.034918 ], [ 115.442753, 36.036204 ], [ 115.442644, 36.038089 ], [ 115.442722, 36.039414 ], [ 115.442745, 36.040357 ], [ 115.442823, 36.041775 ], [ 115.44287, 36.043691 ], [ 115.442894, 36.045101 ], [ 115.442878, 36.04638 ], [ 115.442839, 36.047259 ], [ 115.440896, 36.047378 ], [ 115.440927, 36.049672 ], [ 115.440144, 36.049646 ], [ 115.440029, 36.048699 ], [ 115.439609, 36.048694 ], [ 115.439566, 36.047034 ], [ 115.437848, 36.047012 ], [ 115.437911, 36.04894 ], [ 115.43718, 36.048732 ], [ 115.437192, 36.052211 ], [ 115.434897, 36.052477 ], [ 115.435539, 36.055599 ], [ 115.439732, 36.055081 ], [ 115.44009, 36.058202 ], [ 115.441863, 36.058278 ], [ 115.441951, 36.0592 ], [ 115.44348, 36.059191 ], [ 115.445139, 36.062046 ], [ 115.446319, 36.061864 ], [ 115.446078, 36.060937 ], [ 115.447087, 36.060696 ], [ 115.44743, 36.061523 ], [ 115.449543, 36.061086 ], [ 115.449417, 36.063564 ], [ 115.453566, 36.063237 ], [ 115.453489, 36.066267 ], [ 115.453068, 36.066324 ], [ 115.453275, 36.068403 ], [ 115.450462, 36.068723 ], [ 115.450824, 36.070696 ], [ 115.449082, 36.071144 ], [ 115.450463, 36.073344 ], [ 115.451895, 36.076437 ], [ 115.452739, 36.07879 ], [ 115.453788, 36.080273 ], [ 115.45641, 36.079945 ], [ 115.4604, 36.079587 ], [ 115.460754, 36.08178 ], [ 115.459089, 36.082615 ], [ 115.459696, 36.083802 ], [ 115.46169, 36.083486 ], [ 115.461898, 36.08352 ], [ 115.462795, 36.0875 ], [ 115.462506, 36.087604 ], [ 115.462784, 36.089049 ], [ 115.463032, 36.089037 ], [ 115.463461, 36.091092 ], [ 115.462843, 36.092123 ], [ 115.464467, 36.094357 ], [ 115.467239, 36.096706 ], [ 115.467983, 36.098048 ], [ 115.468238, 36.099726 ], [ 115.468717, 36.101676 ], [ 115.47006, 36.103945 ], [ 115.470827, 36.105799 ], [ 115.471083, 36.108515 ], [ 115.471627, 36.110944 ], [ 115.471867, 36.111246 ], [ 115.472906, 36.112024 ], [ 115.473419, 36.112999 ], [ 115.474074, 36.113996 ], [ 115.474799, 36.116079 ], [ 115.475283, 36.11767 ], [ 115.475221, 36.118201 ], [ 115.474831, 36.118885 ], [ 115.474799, 36.119494 ], [ 115.475104, 36.120205 ], [ 115.475805, 36.122231 ], [ 115.476508, 36.123729 ], [ 115.477912, 36.125304 ], [ 115.478321, 36.125768 ], [ 115.478963, 36.133874 ], [ 115.479241, 36.13962 ], [ 115.477618, 36.148897 ], [ 115.474709, 36.171653 ], [ 115.472709, 36.179167 ], [ 115.472233, 36.180173 ], [ 115.472159, 36.181235 ], [ 115.470655, 36.186885 ], [ 115.470004, 36.192931 ], [ 115.471297, 36.1957 ], [ 115.473147, 36.202995 ], [ 115.473146, 36.209457 ], [ 115.471297, 36.21398 ], [ 115.470004, 36.21878 ], [ 115.470003, 36.226903 ], [ 115.469908, 36.231935 ], [ 115.471115, 36.238305 ], [ 115.471306, 36.241143 ], [ 115.470096, 36.244808 ], [ 115.470546, 36.246392 ], [ 115.468498, 36.246828 ], [ 115.468754, 36.248301 ], [ 115.468284, 36.248378 ], [ 115.46823, 36.247997 ], [ 115.464648, 36.248628 ], [ 115.464662, 36.248942 ], [ 115.462042, 36.249403 ], [ 115.462097, 36.249718 ], [ 115.459374, 36.250228 ], [ 115.45944, 36.251005 ], [ 115.458478, 36.251191 ], [ 115.4586, 36.253273 ], [ 115.459255, 36.255249 ], [ 115.458906, 36.255393 ], [ 115.459039, 36.25584 ], [ 115.458732, 36.255919 ], [ 115.458904, 36.256516 ], [ 115.459395, 36.25644 ], [ 115.46016, 36.25901 ], [ 115.46063, 36.258983 ], [ 115.460524, 36.258172 ], [ 115.460892, 36.258128 ], [ 115.461039, 36.258906 ], [ 115.461591, 36.25888 ], [ 115.461642, 36.259409 ], [ 115.462133, 36.259333 ], [ 115.462263, 36.259996 ], [ 115.461894, 36.26009 ], [ 115.462309, 36.261813 ], [ 115.464189, 36.261639 ], [ 115.464377, 36.262452 ], [ 115.462392, 36.262723 ], [ 115.462935, 36.265225 ], [ 115.462505, 36.265285 ], [ 115.462136, 36.265396 ], [ 115.461667, 36.265406 ], [ 115.461825, 36.267738 ], [ 115.460864, 36.267857 ], [ 115.460915, 36.26837 ], [ 115.459159, 36.26843 ], [ 115.459166, 36.270131 ], [ 115.45843, 36.270204 ], [ 115.4584, 36.270666 ], [ 115.458789, 36.270638 ], [ 115.458782, 36.271002 ], [ 115.457371, 36.271132 ], [ 115.457411, 36.272223 ], [ 115.456612, 36.272378 ], [ 115.456642, 36.273981 ], [ 115.456681, 36.275944 ], [ 115.45574, 36.276295 ], [ 115.454112, 36.276765 ], [ 115.452875, 36.2766 ], [ 115.451626, 36.276563 ], [ 115.449117, 36.277088 ], [ 115.448398, 36.276815 ], [ 115.445344, 36.275123 ], [ 115.443766, 36.274066 ], [ 115.442244, 36.274518 ], [ 115.442338, 36.274883 ], [ 115.440617, 36.275255 ], [ 115.440048, 36.273571 ], [ 115.430261, 36.276138 ], [ 115.430581, 36.2776 ], [ 115.426527, 36.278324 ], [ 115.425499, 36.279039 ], [ 115.425256, 36.279429 ], [ 115.425326, 36.280585 ], [ 115.424608, 36.280725 ], [ 115.42471, 36.28175 ], [ 115.42381, 36.281837 ], [ 115.423882, 36.282317 ], [ 115.424516, 36.282277 ], [ 115.424844, 36.284214 ], [ 115.422075, 36.284736 ], [ 115.422391, 36.285992 ], [ 115.419431, 36.286437 ], [ 115.41948, 36.287033 ], [ 115.414509, 36.287593 ], [ 115.414562, 36.287973 ], [ 115.413617, 36.288291 ], [ 115.414038, 36.289635 ], [ 115.412472, 36.290422 ], [ 115.412296, 36.292023 ], [ 115.410958, 36.29255 ], [ 115.412058, 36.294713 ], [ 115.411708, 36.294857 ], [ 115.412102, 36.295556 ], [ 115.413169, 36.29529 ], [ 115.413457, 36.296201 ], [ 115.413928, 36.296109 ], [ 115.414782, 36.298285 ], [ 115.415438, 36.298177 ], [ 115.416791, 36.302114 ], [ 115.416843, 36.302359 ], [ 115.415079, 36.302799 ], [ 115.416022, 36.306643 ], [ 115.41429, 36.307496 ], [ 115.414693, 36.308747 ], [ 115.415328, 36.308828 ], [ 115.415651, 36.309373 ], [ 115.41605, 36.311286 ], [ 115.413265, 36.310654 ], [ 115.413626, 36.31198 ], [ 115.414076, 36.31197 ], [ 115.415233, 36.31633 ], [ 115.414677, 36.316537 ], [ 115.414714, 36.316736 ], [ 115.415524, 36.318962 ], [ 115.416817, 36.321939 ], [ 115.415989, 36.323595 ], [ 115.408885, 36.326312 ], [ 115.388514, 36.322335 ], [ 115.379761, 36.317261 ], [ 115.373265, 36.313567 ], [ 115.367335, 36.311712 ], [ 115.360555, 36.308703 ], [ 115.355163, 36.310512 ], [ 115.353696, 36.318518 ], [ 115.356787, 36.323113 ], [ 115.361014, 36.326566 ], [ 115.364375, 36.332536 ], [ 115.362613, 36.342373 ], [ 115.354929, 36.34875 ], [ 115.348087, 36.356271 ], [ 115.343512, 36.362893 ], [ 115.343456, 36.370397 ], [ 115.343474, 36.370557 ], [ 115.343476, 36.37062 ], [ 115.343472, 36.370652 ], [ 115.343454, 36.370732 ], [ 115.343451, 36.371138 ], [ 115.342522, 36.384412 ], [ 115.339935, 36.389899 ] ], [ [ 115.49269, 35.897653 ], [ 115.492658, 35.898345 ], [ 115.494901, 35.898487 ], [ 115.494741, 35.900413 ], [ 115.494666, 35.901254 ], [ 115.495183, 35.901334 ], [ 115.495172, 35.901464 ], [ 115.496895, 35.901434 ], [ 115.496981, 35.901895 ], [ 115.497013, 35.902486 ], [ 115.495796, 35.902473 ], [ 115.495775, 35.903725 ], [ 115.495947, 35.903733 ], [ 115.495807, 35.904533 ], [ 115.4957, 35.905575 ], [ 115.495894, 35.905602 ], [ 115.49579, 35.906595 ], [ 115.495387, 35.906608 ], [ 115.495333, 35.90745 ], [ 115.493696, 35.907376 ], [ 115.493566, 35.909817 ], [ 115.49506, 35.910321 ], [ 115.494977, 35.911297 ], [ 115.495354, 35.911325 ], [ 115.495344, 35.911689 ], [ 115.497228, 35.911774 ], [ 115.49725, 35.912452 ], [ 115.497551, 35.91247 ], [ 115.497583, 35.912192 ], [ 115.498897, 35.912152 ], [ 115.499307, 35.913353 ], [ 115.499641, 35.914092 ], [ 115.499974, 35.913998 ], [ 115.500125, 35.914286 ], [ 115.500598, 35.915198 ], [ 115.501234, 35.916051 ], [ 115.501988, 35.917192 ], [ 115.502353, 35.917586 ], [ 115.495475, 35.918223 ], [ 115.493339, 35.913519 ], [ 115.491036, 35.913045 ], [ 115.491016, 35.91368 ], [ 115.483437, 35.91044 ], [ 115.483157, 35.9103 ], [ 115.482791, 35.910125 ], [ 115.482467, 35.90983 ], [ 115.48152, 35.909253 ], [ 115.480723, 35.908903 ], [ 115.478892, 35.908116 ], [ 115.477428, 35.907625 ], [ 115.477476, 35.907058 ], [ 115.47705, 35.906961 ], [ 115.477606, 35.903422 ], [ 115.47779, 35.902055 ], [ 115.481363, 35.902185 ], [ 115.481495, 35.900421 ], [ 115.482995, 35.900469 ], [ 115.483083, 35.899138 ], [ 115.485133, 35.899244 ], [ 115.485319, 35.898211 ], [ 115.486177, 35.898265 ], [ 115.486073, 35.899347 ], [ 115.48677, 35.899431 ], [ 115.486784, 35.899718 ], [ 115.487195, 35.89976 ], [ 115.487414, 35.898915 ], [ 115.488235, 35.898973 ], [ 115.488536, 35.898223 ], [ 115.488755, 35.89742 ], [ 115.49269, 35.897653 ] ] ] ] } }
-- ]
-- }

 

WITH source_geom AS (
    SELECT public.gis_geojson_to_geom(
        '{"type":"Polygon","coordinates":[[[115.339935,36.389899],[115.333937,36.397882],[115.32654,36.40197],[115.318867,36.404911],[115.307522,36.406466],[115.305249,36.407227],[115.300128,36.408945],[115.294761,36.41167],[115.293581,36.412052],[115.292067,36.412864],[115.291484,36.413332],[115.291267,36.414285],[115.291161,36.415444],[115.291265,36.416595],[115.29184,36.41764],[115.292781,36.418686],[115.293897,36.419645],[115.295344,36.420394],[115.297522,36.421195],[115.298411,36.421562],[115.299474,36.422451],[115.300485,36.423722],[115.301148,36.424926],[115.301427,36.426947],[115.301583,36.428568],[115.301931,36.429579],[115.30289,36.430608],[115.304459,36.431637],[115.305731,36.432787],[115.306076,36.433401],[115.30949,36.432582],[115.310908,36.43239],[115.311179,36.435452],[115.308559,36.435705],[115.308543,36.437207],[115.311034,36.437029],[115.311239,36.437777],[115.310758,36.43786],[115.310897,36.438278],[115.310083,36.438357],[115.310076,36.438714],[115.310851,36.438694],[115.311674,36.442387],[115.311157,36.442439],[115.311705,36.445233],[115.31085,36.44552],[115.311807,36.449838],[115.309138,36.450486],[115.309437,36.451413],[115.310458,36.451565],[115.311075,36.453837],[115.309107,36.454434],[115.309138,36.454703],[115.308729,36.454846],[115.309295,36.455956],[115.309221,36.456015],[115.307566,36.45651],[115.306679,36.456618],[115.305747,36.457173],[115.306486,36.458793],[115.304408,36.459329],[115.303908,36.458637],[115.303021,36.458713],[115.302806,36.458383],[115.30058,36.458977],[115.30082,36.459815],[115.301412,36.459734],[115.301843,36.461125],[115.30187,36.461573],[115.301646,36.461689],[115.301936,36.461962],[115.302035,36.462439],[115.301782,36.462819],[115.300816,36.463206],[115.300812,36.463231],[115.300182,36.463686],[115.29873,36.464688],[115.296891,36.465543],[115.295672,36.465855],[115.294302,36.465718],[115.293322,36.465263],[115.292412,36.464458],[115.290872,36.462708],[115.290346,36.461623],[115.289437,36.459767],[115.288946,36.459207],[115.288247,36.458927],[115.287267,36.458927],[115.286077,36.459593],[115.285447,36.460433],[115.285377,36.461623],[115.285832,36.462603],[115.285902,36.463199],[115.285762,36.463689],[115.284782,36.465229],[115.283312,36.468064],[115.283031,36.468835],[115.282961,36.46985],[115.283137,36.470621],[115.283732,36.47139],[115.284378,36.471862],[115.286199,36.472527],[115.287809,36.473158],[115.288474,36.473648],[115.288754,36.474243],[115.288684,36.474838],[115.28837,36.475433],[115.287704,36.475923],[115.287004,36.476029],[115.286304,36.476099],[115.280425,36.476236],[115.278745,36.476275],[115.27815,36.476519],[115.277554,36.47687],[115.277205,36.47736],[115.276889,36.47827],[115.276819,36.479181],[115.27724,36.480126],[115.277607,36.481578],[115.277852,36.482663],[115.277852,36.483713],[115.277712,36.485289],[115.277583,36.48625],[115.275696,36.486607],[115.273359,36.48662],[115.270142,36.486808],[115.270132,36.487255],[115.269724,36.487309],[115.269883,36.488503],[115.267478,36.488796],[115.267349,36.48796],[115.266722,36.487981],[115.267196,36.490684],[115.265864,36.490874],[115.265646,36.490996],[115.265528,36.491271],[115.265804,36.491606],[115.266066,36.49253],[115.266806,36.495981],[115.266925,36.497239],[115.275757,36.495604],[115.27697,36.498318],[115.277413,36.498295],[115.277729,36.499074],[115.278098,36.49905],[115.278374,36.499947],[115.279298,36.499841],[115.28015,36.498006],[115.283797,36.49764],[115.285272,36.499115],[115.286742,36.500586],[115.287827,36.501741],[115.288807,36.50363],[115.289979,36.506238],[115.290505,36.508513],[115.290542,36.508662],[115.289957,36.509809],[115.289481,36.510519],[115.288822,36.511279],[115.288,36.512366],[115.28749,36.513223],[115.286664,36.514209],[115.286469,36.514951],[115.285929,36.516257],[115.285917,36.517697],[115.28622,36.518783],[115.287151,36.52049],[115.288584,36.522293],[115.289167,36.522807],[115.289227,36.523024],[115.288594,36.523207],[115.282885,36.524134],[115.283298,36.52501],[115.283499,36.525638],[115.283533,36.526056],[115.283353,36.526367],[115.282263,36.526977],[115.282083,36.527288],[115.282384,36.528335],[115.282932,36.528865],[115.284463,36.530027],[115.286057,36.531554],[115.287641,36.532555],[115.289111,36.533065],[115.289737,36.533192],[115.291162,36.533257],[115.292333,36.533056],[115.293591,36.532568],[115.294072,36.532157],[115.29441,36.531546],[115.294542,36.53065],[115.29449,36.529961],[115.293862,36.527595],[115.294555,36.527431],[115.294435,36.527011],[115.294506,36.52576],[115.295493,36.525983],[115.296989,36.526491],[115.298961,36.526936],[115.300035,36.527125],[115.301478,36.527225],[115.303244,36.529061],[115.30412,36.530286],[115.304645,36.531511],[115.305345,36.532526],[115.306167,36.533418],[115.307287,36.534329],[115.308512,36.535239],[115.309877,36.536044],[115.312713,36.537829],[115.314988,36.539369],[115.316773,36.540524],[115.317719,36.541365],[115.318637,36.54242],[115.319656,36.543313],[115.320537,36.544252],[115.321622,36.545477],[115.323232,36.546948],[115.324212,36.548103],[115.324843,36.549118],[115.325228,36.549958],[115.325227,36.550903],[115.325315,36.552601],[115.325069,36.554247],[115.32507,36.556557],[115.325315,36.559148],[115.325595,36.561738],[115.325892,36.563926],[115.327188,36.567392],[115.328308,36.571488],[115.328885,36.573535],[115.32906,36.57546],[115.328921,36.578051],[115.328395,36.580921],[115.328238,36.5822],[115.328938,36.58388],[115.330549,36.58696],[115.331768,36.588686],[115.337035,36.586999],[115.339324,36.590846],[115.344432,36.589752],[115.345459,36.592472],[115.34546,36.594661],[115.338859,36.595323],[115.334299,36.594926],[115.334347,36.595484],[115.334207,36.597269],[115.334207,36.59909],[115.334679,36.601138],[115.335099,36.602714],[115.335414,36.603168],[115.336219,36.603588],[115.338566,36.604884],[115.341891,36.60569],[115.343467,36.605795],[115.344342,36.606144],[115.344648,36.606338],[115.342826,36.608041],[115.339294,36.610199],[115.338592,36.61106],[115.338958,36.612061],[115.343246,36.615194],[115.34629,36.618325],[115.347367,36.619896],[115.347909,36.621036],[115.348457,36.62275],[115.348823,36.624325],[115.349023,36.627046],[115.349739,36.627043],[115.35309,36.624594],[115.354501,36.624014],[115.355203,36.623582],[115.358775,36.622274],[115.359916,36.621597],[115.360759,36.622241],[115.362009,36.62308],[115.363015,36.624313],[115.364184,36.625644],[115.366391,36.627591],[115.36824,36.629409],[115.370026,36.630771],[115.371568,36.631891],[115.372347,36.632476],[115.373061,36.633287],[115.374208,36.6352],[115.376523,36.639913],[115.377553,36.641484],[115.38096,36.644944],[115.381804,36.646034],[115.382041,36.646824],[115.38218,36.648363],[115.382212,36.648685],[115.382212,36.649684],[115.382082,36.650808],[115.382076,36.650855],[115.381451,36.651873],[115.381142,36.652397],[115.380088,36.654595],[115.380027,36.654721],[115.38002,36.655253],[115.38015,36.655891],[115.38061,36.656399],[115.380798,36.656534],[115.383063,36.658145],[115.384419,36.658887],[115.385592,36.659393],[115.385907,36.659512],[115.389114,36.660382],[115.389767,36.660519],[115.391395,36.660915],[115.392791,36.661256],[115.395952,36.662019],[115.396853,36.662092],[115.397719,36.662214],[115.400259,36.662818],[115.401592,36.663383],[115.402293,36.664062],[115.40269,36.664929],[115.403205,36.666521],[115.403544,36.667539],[115.403544,36.668922],[115.403179,36.670356],[115.4031,36.671216],[115.403439,36.672078],[115.404771,36.67453],[115.40597,36.67607],[115.407119,36.676879],[115.409441,36.678235],[115.410745,36.678757],[115.412455,36.679266],[115.413264,36.67971],[115.413759,36.680258],[115.414046,36.680936],[115.414151,36.682657],[115.413942,36.684222],[115.413994,36.685318],[115.414229,36.686178],[115.414424,36.686348],[115.415938,36.686661],[115.418521,36.687002],[115.421496,36.687316],[115.422461,36.687342],[115.423427,36.687447],[115.424653,36.687812],[115.42601,36.688516],[115.427536,36.689573],[115.429049,36.691086],[115.429782,36.691624],[115.429832,36.691661],[115.430301,36.691869],[115.431007,36.691974],[115.433015,36.691947],[115.434406,36.692048],[115.435734,36.689453],[115.436439,36.689655],[115.436646,36.689714],[115.436787,36.689399],[115.438815,36.690017],[115.438845,36.690117],[115.437856,36.692046],[115.438512,36.692312],[115.43844,36.692646],[115.438955,36.692805],[115.439984,36.693528],[115.440579,36.69424],[115.439918,36.695787],[115.438956,36.696495],[115.438025,36.698115],[115.438094,36.699222],[115.438506,36.699985],[115.438681,36.700557],[115.43901,36.70098],[115.440041,36.70138],[115.442543,36.701626],[115.443459,36.701619],[115.445322,36.701826],[115.445878,36.702214],[115.4461,36.703055],[115.445984,36.703966],[115.445642,36.704493],[115.443816,36.705409],[115.443909,36.70597],[115.443974,36.708801],[115.443776,36.710437],[115.443811,36.711571],[115.444125,36.712756],[115.4444,36.71323],[115.445757,36.713012],[115.446557,36.713175],[115.447489,36.713602],[115.448336,36.713805],[115.449091,36.713663],[115.450274,36.713795],[115.450832,36.714103],[115.451808,36.714917],[115.453701,36.717034],[115.453968,36.718139],[115.453716,36.718742],[115.453235,36.719115],[115.451106,36.719543],[115.44973,36.719605],[115.450444,36.721322],[115.45107,36.72247],[115.452349,36.724531],[115.453271,36.725679],[115.453815,36.725662],[115.455472,36.725303],[115.457684,36.72564],[115.458814,36.726032],[115.459326,36.726422],[115.459646,36.726879],[115.459783,36.7273],[115.45963,36.727791],[115.459195,36.728241],[115.457852,36.728944],[115.457097,36.729317],[115.455754,36.730099],[115.455372,36.730587],[115.454884,36.730999],[115.454831,36.731495],[115.455692,36.733101],[115.455823,36.733749],[115.456234,36.734554],[115.456509,36.734826],[115.45741,36.734986],[115.458165,36.73496],[115.460531,36.734182],[115.460875,36.734083],[115.461935,36.735465],[115.462771,36.736183],[115.463411,36.736896],[115.465237,36.73854],[115.466711,36.740405],[115.468368,36.742375],[115.468511,36.742544],[115.46945,36.743874],[115.470246,36.745582],[115.471341,36.747774],[115.472131,36.750017],[115.472387,36.750815],[115.472486,36.751395],[115.472517,36.752075],[115.472496,36.752814],[115.47232,36.754338],[115.472225,36.755169],[115.472133,36.756507],[115.472199,36.757577],[115.472402,36.758429],[115.47272,36.758977],[115.473275,36.759371],[115.474034,36.759705],[115.475094,36.759941],[115.475849,36.760134],[115.47723,36.760506],[115.478422,36.760786],[115.480098,36.760958],[115.481688,36.761028],[115.483912,36.761149],[115.485166,36.761255],[115.485444,36.761285],[115.48588,36.76216],[115.486521,36.763232],[115.487208,36.764419],[115.488085,36.765381],[115.489672,36.766507],[115.490977,36.767208],[115.49196,36.767865],[115.493174,36.76845],[115.494494,36.768924],[115.495425,36.769279],[115.49618,36.76963],[115.496974,36.769904],[115.498339,36.770072],[115.500193,36.770118],[115.500299,36.770126],[115.500608,36.770168],[115.501024,36.770045],[115.501268,36.769947],[115.502436,36.769135],[115.503924,36.767901],[115.504794,36.767162],[115.505335,36.766815],[115.505747,36.766603],[115.506717,36.766427],[115.506819,36.76644],[115.507995,36.766483],[115.509256,36.766531],[115.509876,36.76655],[115.510552,36.766459],[115.51138,36.766196],[115.513164,36.765407],[115.514913,36.764641],[115.516492,36.764037],[115.517749,36.763608],[115.51905,36.763368],[115.519635,36.763368],[115.520015,36.763524],[115.520492,36.763934],[115.520745,36.764372],[115.52095,36.765113],[115.521141,36.766287],[115.521033,36.766775],[115.520877,36.767292],[115.520636,36.767778],[115.519486,36.769872],[115.519316,36.770475],[115.51934,36.771103],[115.519529,36.771742],[115.519757,36.772243],[115.52018,36.772842],[115.520697,36.773388],[115.521233,36.77369],[115.521827,36.773837],[115.522393,36.773856],[115.522958,36.773729],[115.52346,36.773506],[115.524406,36.772625],[115.525445,36.771911],[115.526404,36.77134],[115.527222,36.770946],[115.527699,36.770848],[115.52806,36.770868],[115.528449,36.771024],[115.529711,36.771886],[115.530637,36.772296],[115.531041,36.772451],[115.530956,36.774422],[115.531558,36.776931],[115.531448,36.780455],[115.531308,36.781829],[115.531453,36.782434],[115.531849,36.783131],[115.532908,36.783941],[115.534567,36.784416],[115.53554,36.78453],[115.540777,36.784161],[115.542582,36.783615],[115.542997,36.783346],[115.54373,36.782696],[115.54385,36.782357],[115.544086,36.780392],[115.544065,36.779231],[115.544426,36.778065],[115.545164,36.77713],[115.546878,36.775706],[115.549058,36.775954],[115.555569,36.775605],[115.555693,36.776002],[115.555718,36.776922],[115.555395,36.780177],[115.554789,36.782777],[115.554789,36.783648],[115.555099,36.783958],[115.555627,36.784113],[115.561186,36.781098],[115.562614,36.779949],[115.564789,36.776904],[115.566393,36.775208],[115.567018,36.775187],[115.567583,36.7751],[115.56806,36.775007],[115.568558,36.774909],[115.570061,36.774769],[115.571987,36.774682],[115.572809,36.774735],[115.573566,36.774854],[115.574078,36.775025],[115.574633,36.775453],[115.574847,36.775765],[115.575003,36.776281],[115.575232,36.77688],[115.575524,36.777415],[115.576206,36.778283],[115.576757,36.778997],[115.57746,36.779733],[115.578249,36.780433],[115.578979,36.78091],[115.579768,36.781272],[115.580947,36.781719],[115.582492,36.782328],[115.583953,36.782844],[115.585454,36.783224],[115.586833,36.783531],[115.588089,36.783638],[115.589201,36.783744],[115.589668,36.783774],[115.590107,36.783871],[115.592411,36.784568],[115.594253,36.785064],[115.594906,36.785239],[115.595792,36.785542],[115.597522,36.786218],[115.598116,36.786403],[115.598789,36.786598],[115.599705,36.786978],[115.60066,36.787309],[115.605254,36.789019],[115.608382,36.790207],[115.609453,36.790665],[115.610695,36.791083],[115.612325,36.791622],[115.612983,36.791735],[115.613557,36.791843],[115.613965,36.791941],[115.619106,36.794206],[115.61989,36.794659],[115.620698,36.795146],[115.621761,36.795798],[115.623262,36.796832],[115.62508,36.797957],[115.626238,36.798792],[115.626702,36.798915],[115.626928,36.798883],[115.62698,36.798869],[115.627497,36.79873],[115.628293,36.798478],[115.629344,36.79816],[115.630055,36.797929],[115.630767,36.797641],[115.631407,36.797445],[115.631678,36.797356],[115.632003,36.797326],[115.632385,36.79733],[115.632864,36.797382],[115.633358,36.797478],[115.633764,36.797664],[115.634101,36.797827],[115.634393,36.798058],[115.634683,36.798494],[115.63502,36.799407],[115.635301,36.80032],[115.635325,36.800514],[115.635472,36.800982],[115.63573,36.801621],[115.635904,36.802193],[115.635916,36.802225],[115.635983,36.802405],[115.637404,36.802811],[115.638526,36.803372],[115.639683,36.803956],[115.640984,36.804791],[115.641896,36.805477],[115.642421,36.805787],[115.643161,36.806098],[115.643686,36.80636],[115.644043,36.806646],[115.644389,36.807135],[115.6447,36.807326],[115.645904,36.8076],[115.647998,36.80812],[115.649919,36.808358],[115.651189,36.808567],[115.651977,36.808805],[115.652812,36.809222],[115.653659,36.809701],[115.655903,36.810738],[115.657042,36.811245],[115.657913,36.81171],[115.658748,36.812068],[115.659225,36.812235],[115.65994,36.812307],[115.660382,36.812247],[115.66151,36.811823],[115.662715,36.811119],[115.664134,36.810141],[115.665304,36.809378],[115.665781,36.809043],[115.666247,36.8089],[115.667088,36.808859],[115.667672,36.808941],[115.668174,36.809311],[115.669056,36.809908],[115.67093,36.810541],[115.672696,36.810982],[115.674193,36.811286],[115.674684,36.811421],[115.674775,36.811417],[115.674829,36.811364],[115.674825,36.810772],[115.674877,36.810205],[115.67477,36.809816],[115.674705,36.809521],[115.674665,36.809395],[115.674667,36.809293],[115.674668,36.809224],[115.674726,36.809157],[115.674994,36.809136],[115.675532,36.809143],[115.675745,36.8091],[115.675916,36.809011],[115.676003,36.808897],[115.676165,36.808513],[115.67631,36.808321],[115.677694,36.807649],[115.679506,36.807653],[115.680057,36.807901],[115.6805,36.808324],[115.680814,36.809609],[115.680813,36.809657],[115.680691,36.810144],[115.680496,36.810825],[115.680185,36.81164],[115.680126,36.811799],[115.680053,36.811889],[115.679767,36.812067],[115.679382,36.812233],[115.679069,36.812366],[115.67867,36.812498],[115.678624,36.812526],[115.678342,36.812687],[115.678847,36.812933],[115.680082,36.813821],[115.681382,36.815684],[115.682092,36.81724],[115.682463,36.818315],[115.682498,36.819042],[115.682582,36.821214],[115.682492,36.822759],[115.6826,36.823451],[115.683149,36.824536],[115.684056,36.825754],[115.68523,36.826774],[115.685935,36.827753],[115.686328,36.828397],[115.686376,36.829041],[115.686031,36.830688],[115.685617,36.83318],[115.685487,36.833743],[115.685242,36.834458],[115.684866,36.835196],[115.684409,36.835817],[115.684069,36.836133],[115.683941,36.836345],[115.683366,36.837528],[115.682984,36.838671],[115.682774,36.839281],[115.682745,36.840013],[115.682838,36.840904],[115.683015,36.841735],[115.683201,36.842346],[115.683589,36.843154],[115.68404,36.844004],[115.684474,36.844684],[115.685013,36.8452],[115.687739,36.84748],[115.688547,36.848089],[115.688957,36.848523],[115.689596,36.849349],[115.690229,36.85044],[115.690657,36.851735],[115.690856,36.852684],[115.691056,36.85381],[115.691419,36.854876],[115.692011,36.855843],[115.69282,36.857086],[115.693652,36.858269],[115.694397,36.859295],[115.69469,36.859881],[115.694925,36.860421],[115.695099,36.86103],[115.695329,36.862173],[115.695376,36.862946],[115.695188,36.863708],[115.694561,36.865273],[115.694279,36.865941],[115.694103,36.86661],[115.694203,36.867013],[115.694473,36.867435],[115.695094,36.868045],[115.69673,36.870032],[115.69714,36.870689],[115.697445,36.871064],[115.698078,36.871615],[115.699596,36.873073],[115.700417,36.874012],[115.70163,36.875518],[115.702216,36.876432],[115.702661,36.877241],[115.703277,36.878478],[115.703839,36.879545],[115.704379,36.880494],[115.704901,36.881391],[115.70544,36.882024],[115.706131,36.882739],[115.707011,36.883583],[115.708165,36.88455],[115.710029,36.886168],[115.712204,36.887733],[115.717063,36.891162],[115.718517,36.892124],[115.720259,36.893232],[115.721044,36.893631],[115.722709,36.894299],[115.724866,36.895144],[115.729316,36.896627],[115.729644,36.896791],[115.729901,36.897026],[115.730195,36.897471],[115.731174,36.899423],[115.732921,36.902366],[115.73448,36.905624],[115.734703,36.90601],[115.735067,36.906374],[115.735558,36.906656],[115.736133,36.906761],[115.736643,36.906838],[115.737006,36.906978],[115.737828,36.907355],[115.736318,36.904248],[115.736351,36.90416],[115.741277,36.901999],[115.746106,36.905739],[115.747542,36.905237],[115.748363,36.904819],[115.748587,36.904595],[115.747904,36.903191],[115.748509,36.902668],[115.749631,36.902039],[115.751275,36.902098],[115.751495,36.902156],[115.751931,36.902628],[115.753899,36.908695],[115.758363,36.908505],[115.758596,36.908664],[115.759289,36.908694],[115.759363,36.909251],[115.75933,36.910486],[115.758844,36.910547],[115.758941,36.913041],[115.759007,36.913231],[115.759311,36.913323],[115.759515,36.913559],[115.759518,36.914227],[115.760375,36.914392],[115.762106,36.914544],[115.762187,36.914634],[115.762205,36.915235],[115.762799,36.915397],[115.762849,36.917479],[115.762761,36.919447],[115.762845,36.920596],[115.76446,36.9206],[115.766999,36.919649],[115.766975,36.915665],[115.767531,36.913193],[115.768454,36.912843],[115.770978,36.912928],[115.773644,36.91285],[115.774425,36.911823],[115.77394,36.904613],[115.779797,36.904367],[115.780254,36.907814],[115.779099,36.909028],[115.779389,36.911051],[115.781256,36.912574],[115.785322,36.912309],[115.785538,36.913979],[115.788013,36.914324],[115.793076,36.913917],[115.793707,36.913753],[115.793755,36.913222],[115.795303,36.912987],[115.807262,36.913072],[115.807706,36.908827],[115.811762,36.908277],[115.813007,36.908252],[115.813967,36.908979],[115.816478,36.911361],[115.817527,36.913178],[115.822304,36.91203],[115.826082,36.910565],[115.82661,36.917072],[115.827244,36.918254],[115.83296,36.918312],[115.833087,36.915863],[115.834298,36.913835],[115.837023,36.912827],[115.841359,36.912009],[115.843317,36.912365],[115.842599,36.914482],[115.843007,36.915442],[115.844097,36.916063],[115.845763,36.916156],[115.848312,36.915944],[115.852311,36.911959],[115.852867,36.908082],[115.849707,36.909394],[115.845523,36.908898],[115.846067,36.905877],[115.848029,36.904531],[115.848876,36.904293],[115.849452,36.903986],[115.84996,36.903571],[115.85066,36.90314],[115.851018,36.90305],[115.851451,36.903059],[115.85191,36.903217],[115.852577,36.903334],[115.853176,36.903377],[115.853801,36.903286],[115.855401,36.903255],[115.85775,36.903259],[115.857758,36.902785],[115.857967,36.902769],[115.858073,36.902372],[115.858059,36.902213],[115.860874,36.902273],[115.860844,36.900932],[115.862756,36.901231],[115.865109,36.902628],[115.867132,36.90452],[115.870244,36.916033],[115.871085,36.917254],[115.873184,36.917161],[115.87357,36.917353],[115.873431,36.918265],[115.874528,36.918102],[115.876073,36.91733],[115.876106,36.911772],[115.877678,36.909693],[115.87958,36.909737],[115.879615,36.906806],[115.88224,36.906727],[115.889199,36.905428],[115.894874,36.902349],[115.900047,36.899401],[115.906321,36.895963],[115.914868,36.892752],[115.926566,36.890684],[115.931241,36.890072],[115.933975,36.890047],[115.933975,36.890907],[115.931832,36.890876],[115.931832,36.891511],[115.929312,36.891663],[115.929564,36.893484],[115.939398,36.892797],[115.939567,36.89124],[115.940554,36.891094],[115.94173,36.891115],[115.941623,36.889674],[115.941916,36.889661],[115.941873,36.88942],[115.942203,36.88942],[115.94209,36.888321],[115.944688,36.885494],[115.95628,36.884616],[115.95687,36.882928],[115.958111,36.883103],[115.958199,36.883457],[115.96062,36.883274],[115.961489,36.884745],[115.963765,36.88731],[115.96462,36.887317],[115.965062,36.887329],[115.966118,36.887357],[115.968,36.887409],[115.9683,36.890565],[115.970612,36.890522],[115.970912,36.891346],[115.972923,36.891408],[115.973307,36.892917],[115.975704,36.892807],[115.975404,36.890578],[115.976936,36.890455],[115.976731,36.888516],[115.979768,36.888198],[115.97964,36.886656],[115.980863,36.886425],[115.980766,36.88572],[115.980355,36.885357],[115.980331,36.884592],[115.983724,36.884406],[115.983751,36.883409],[115.984414,36.883433],[115.984364,36.881886],[115.986594,36.881821],[115.986644,36.882596],[115.986592,36.883226],[115.987668,36.883279],[115.987704,36.884041],[115.990363,36.884143],[115.99035,36.885016],[115.991452,36.884893],[115.99986,36.883958],[116.008142,36.885326],[116.01797,36.887711],[116.018612,36.892374],[116.017284,36.893235],[116.017712,36.895155],[116.02028,36.89477],[116.020501,36.896131],[116.021479,36.896137],[116.02105,36.89415],[116.022035,36.893563],[116.021564,36.890959],[116.023276,36.891023],[116.023319,36.888622],[116.023961,36.888653],[116.023791,36.886629],[116.028156,36.887408],[116.029797,36.890931],[116.036366,36.892697],[116.039424,36.892901],[116.044176,36.893959],[116.046111,36.890468],[116.048044,36.889733],[116.053177,36.889331],[116.05599,36.888038],[116.060384,36.888369],[116.060524,36.888709],[116.064683,36.887932],[116.065257,36.889943],[116.067086,36.890077],[116.070018,36.888923],[116.069732,36.88832],[116.071254,36.887313],[116.076376,36.885025],[116.076502,36.883281],[116.090454,36.883187],[116.091282,36.883084],[116.092252,36.883331],[116.092309,36.886838],[116.090632,36.885853],[116.090392,36.886234],[116.09137,36.890758],[116.093677,36.891783],[116.101509,36.893428],[116.101445,36.893933],[116.10308,36.894262],[116.104806,36.895367],[116.10503,36.896874],[116.106922,36.897292],[116.107981,36.897331],[116.109016,36.897098],[116.109906,36.89667],[116.112316,36.895109],[116.113942,36.896207],[116.116186,36.894086],[116.116301,36.893394],[116.11466,36.892257],[116.117814,36.890076],[116.119368,36.891318],[116.120413,36.892434],[116.126816,36.897076],[116.127533,36.897171],[116.133737,36.902214],[116.13515,36.903664],[116.136813,36.905906],[116.140491,36.910218],[116.144581,36.912402],[116.14674,36.912803],[116.147106,36.913134],[116.155614,36.915248],[116.158521,36.916431],[116.162419,36.919305],[116.164198,36.920743],[116.165265,36.924034],[116.166341,36.925896],[116.167409,36.929189],[116.167745,36.932042],[116.167394,36.937321],[116.167188,36.937501],[116.167181,36.939044],[116.167035,36.940593],[116.166669,36.942039],[116.166647,36.944902],[116.167036,36.945637],[116.167027,36.947182],[116.167906,36.947616],[116.169278,36.949815],[116.174809,36.955674],[116.174978,36.956241],[116.177884,36.959085],[116.178643,36.960842],[116.179902,36.960472],[116.17927,36.958785],[116.180352,36.958135],[116.181048,36.959696],[116.183227,36.958987],[116.18572,36.962821],[116.188346,36.961265],[116.189206,36.961294],[116.193597,36.965392],[116.194875,36.964939],[116.194175,36.963634],[116.194438,36.963147],[116.195987,36.962884],[116.196561,36.963553],[116.20107,36.962647],[116.205836,36.962641],[116.206553,36.965163],[116.207967,36.968191],[116.206397,36.968841],[116.205407,36.967161],[116.2046,36.967199],[116.205273,36.969618],[116.204881,36.969667],[116.209482,36.974668],[116.210986,36.974409],[116.213469,36.979123],[116.210851,36.979806],[116.206331,36.981966],[116.204929,36.983644],[116.20385,36.98653],[116.20471,36.988419],[116.205988,36.989585],[116.21428,36.992999],[116.217121,36.993894],[116.219413,36.993373],[116.220826,36.993829],[116.220891,36.993951],[116.223547,36.995964],[116.225611,36.999951],[116.225793,36.999978],[116.225819,36.999947],[116.225852,36.999986],[116.227628,37.000245],[116.227762,37.000776],[116.228449,37.000703],[116.228547,37.000808],[116.228683,37.007205],[116.230097,37.009642],[116.223417,37.009633],[116.222985,37.011758],[116.221211,37.012044],[116.220269,37.011757],[116.220356,37.009899],[116.218275,37.009732],[116.216565,37.009825],[116.216691,37.01205],[116.219104,37.015222],[116.219684,37.016223],[116.219204,37.01654],[116.219833,37.018442],[116.218678,37.018993],[116.219146,37.0203],[116.219732,37.022874],[116.219885,37.024878],[116.221114,37.027334],[116.222044,37.028302],[116.222554,37.029333],[116.227172,37.031712],[116.229083,37.030555],[116.231834,37.029252],[116.231078,37.027839],[116.231491,37.027554],[116.236548,37.026466],[116.238611,37.026759],[116.241455,37.026442],[116.244676,37.024983],[116.244863,37.024128],[116.243837,37.023928],[116.242513,37.022185],[116.241933,37.019174],[116.243194,37.017275],[116.24525,37.01663],[116.24528,37.016523],[116.244619,37.015555],[116.243837,37.014221],[116.245591,37.013073],[116.247475,37.011788],[116.249074,37.007797],[116.249863,37.007932],[116.251122,37.010647],[116.255635,37.010874],[116.262121,37.010012],[116.263264,37.009102],[116.263824,37.007278],[116.264461,37.006784],[116.269557,37.005795],[116.277338,36.999851],[116.282247,36.996901],[116.285008,36.995271],[116.288177,36.995266],[116.288401,36.997878],[116.292575,36.997573],[116.293096,36.99955],[116.294305,36.99911],[116.293618,36.996564],[116.295407,36.996262],[116.295454,36.995194],[116.299618,36.994465],[116.299188,36.989703],[116.301126,36.988782],[116.301259,36.98872],[116.302127,36.988306],[116.305097,36.986029],[116.311265,36.981301],[116.318313,36.971495],[116.323495,36.969469],[116.327486,36.968719],[116.327652,36.969989],[116.332235,36.969706],[116.334329,36.971377],[116.33499,36.97381],[116.333539,36.974015],[116.335539,36.979663],[116.336173,36.979753],[116.339179,36.978994],[116.339882,36.980561],[116.340593,36.98046],[116.342135,36.979541],[116.341077,36.976533],[116.343792,36.976406],[116.343102,36.973814],[116.342886,36.972584],[116.344623,36.972368],[116.345641,36.976482],[116.348536,36.976644],[116.34947,36.976358],[116.350891,36.974892],[116.355031,36.974291],[116.354951,36.971612],[116.360568,36.971252],[116.35922,36.966198],[116.364577,36.96557],[116.36443,36.964923],[116.364361,36.962669],[116.368614,36.961892],[116.368035,36.964039],[116.372992,36.963508],[116.373434,36.965698],[116.389391,36.967332],[116.399955,36.968468],[116.403716,36.970723],[116.406762,36.973861],[116.409057,36.975177],[116.41203,36.975499],[116.415229,36.975031],[116.419239,36.972574],[116.423457,36.968539],[116.426372,36.968033],[116.426474,36.967804],[116.428517,36.967589],[116.428124,36.96378],[116.430486,36.961677],[116.43215,36.958336],[116.434285,36.957256],[116.437879,36.957159],[116.437018,36.95474],[116.436823,36.953734],[116.443658,36.952383],[116.444556,36.952295],[116.448807,36.954134],[116.452254,36.954791],[116.454089,36.953311],[116.454471,36.951233],[116.456135,36.951334],[116.456354,36.950159],[116.456947,36.949775],[116.459096,36.949655],[116.459957,36.949934],[116.461042,36.948122],[116.462766,36.946788],[116.464044,36.946197],[116.465366,36.946511],[116.464763,36.939466],[116.460742,36.939771],[116.455782,36.940148],[116.453603,36.938428],[116.452573,36.936341],[116.451063,36.936232],[116.447875,36.935553],[116.447143,36.933304],[116.446549,36.933036],[116.443843,36.934294],[116.443355,36.937705],[116.440591,36.937533],[116.439686,36.936892],[116.438532,36.932844],[116.437916,36.932905],[116.437301,36.931649],[116.439316,36.930916],[116.439572,36.929284],[116.438899,36.923126],[116.436494,36.919437],[116.4335,36.9182],[116.433338,36.917659],[116.43404,36.915921],[116.439705,36.916029],[116.440501,36.916478],[116.440991,36.915816],[116.441881,36.915941],[116.44327,36.9152],[116.44345,36.914936],[116.444355,36.912803],[116.445771,36.909121],[116.444766,36.908841],[116.445285,36.907672],[116.44667,36.905862],[116.447681,36.906667],[116.449467,36.90677],[116.449575,36.903781],[116.448423,36.903644],[116.448086,36.903735],[116.448169,36.902815],[116.447496,36.902533],[116.443587,36.902061],[116.442838,36.902379],[116.44245,36.900189],[116.442105,36.899409],[116.439136,36.900649],[116.436661,36.899454],[116.435207,36.899911],[116.433549,36.901176],[116.435413,36.904602],[116.435558,36.905855],[116.428142,36.907848],[116.427494,36.90753],[116.425355,36.906966],[116.424165,36.907761],[116.419624,36.90676],[116.419108,36.905274],[116.415696,36.904668],[116.414975,36.902727],[116.415603,36.90265],[116.414684,36.899837],[116.412061,36.893694],[116.413553,36.8934],[116.414886,36.890626],[116.415948,36.89059],[116.416282,36.889947],[116.416182,36.887374],[116.414937,36.887541],[116.414558,36.888555],[116.413154,36.888259],[116.413026,36.886597],[116.414623,36.886271],[116.414126,36.884291],[116.410844,36.88468],[116.410397,36.883322],[116.410048,36.880801],[116.411201,36.879137],[116.413638,36.876626],[116.417006,36.876008],[116.424838,36.876061],[116.425706,36.877841],[116.427619,36.877128],[116.428266,36.875913],[116.427883,36.873997],[116.426831,36.871932],[116.425641,36.871942],[116.424713,36.868749],[116.423816,36.864661],[116.422591,36.864748],[116.422289,36.864354],[116.422229,36.863977],[116.418467,36.864155],[116.415066,36.864081],[116.412932,36.863267],[116.406854,36.860503],[116.406725,36.860086],[116.406451,36.858101],[116.406213,36.857931],[116.408252,36.856429],[116.409506,36.856055],[116.409451,36.855367],[116.407713,36.850866],[116.405281,36.851202],[116.404724,36.850584],[116.40403,36.846243],[116.401303,36.846155],[116.400994,36.844645],[116.400935,36.844083],[116.400655,36.840679],[116.403374,36.83816],[116.403687,36.837057],[116.399716,36.826839],[116.399081,36.826194],[116.397153,36.825701],[116.396663,36.824893],[116.396303,36.824706],[116.395445,36.825683],[116.393965,36.823328],[116.394233,36.822531],[116.396334,36.820909],[116.393323,36.819236],[116.396862,36.816995],[116.396395,36.815178],[116.397451,36.81505],[116.402161,36.8152],[116.402743,36.81493],[116.402746,36.814206],[116.40206,36.81388],[116.402094,36.809984],[116.404179,36.809823],[116.403305,36.806492],[116.398297,36.806565],[116.397938,36.806958],[116.399087,36.810016],[116.398164,36.810121],[116.393603,36.808693],[116.392531,36.809156],[116.3918,36.808904],[116.386351,36.804621],[116.386081,36.802389],[116.379633,36.801215],[116.378682,36.801603],[116.37708,36.802456],[116.375218,36.803124],[116.373425,36.801396],[116.37509,36.800012],[116.372866,36.799028],[116.371966,36.798021],[116.370159,36.796525],[116.370895,36.795949],[116.373167,36.79704],[116.374064,36.796908],[116.37277,36.794532],[116.373099,36.793986],[116.374039,36.794024],[116.375313,36.795977],[116.379364,36.795913],[116.378976,36.793346],[116.380303,36.792396],[116.383416,36.791925],[116.390341,36.791956],[116.390941,36.791017],[116.390602,36.790005],[116.391537,36.788772],[116.390526,36.78633],[116.390976,36.786032],[116.392804,36.785694],[116.394153,36.784558],[116.3931,36.779794],[116.396442,36.772877],[116.397843,36.767746],[116.397821,36.767708],[116.397861,36.767678],[116.399759,36.760726],[116.398265,36.751802],[116.395947,36.74586],[116.392463,36.741024],[116.388606,36.741226],[116.385744,36.734911],[116.383592,36.733807],[116.385483,36.732036],[116.382431,36.730834],[116.380222,36.72483],[116.381213,36.724915],[116.380987,36.721176],[116.382602,36.721175],[116.381707,36.719202],[116.390524,36.717831],[116.391719,36.71496],[116.398508,36.709892],[116.401269,36.704329],[116.401818,36.696594],[116.401183,36.688582],[116.402564,36.682164],[116.405359,36.6762],[116.405547,36.672987],[116.404658,36.672377],[116.404735,36.67059],[116.405766,36.669218],[116.406106,36.663371],[116.406784,36.656835],[116.408555,36.648476],[116.407366,36.642755],[116.40219,36.636139],[116.400176,36.631568],[116.400267,36.624454],[116.400355,36.622221],[116.401407,36.618762],[116.405438,36.614825],[116.406335,36.610225],[116.405664,36.607954],[116.405055,36.602003],[116.404413,36.59285],[116.40233,36.580948],[116.396195,36.571718],[116.394571,36.565981],[116.394159,36.559553],[116.393482,36.53977],[116.39343,36.53336],[116.395053,36.524449],[116.397735,36.522905],[116.407192,36.518385],[116.406126,36.515572],[116.409977,36.515791],[116.417696,36.508573],[116.419279,36.507951],[116.420408,36.509256],[116.419918,36.507083],[116.42234,36.505694],[116.421684,36.504272],[116.424443,36.503377],[116.423299,36.501674],[116.42568,36.501393],[116.425014,36.499509],[116.437341,36.497948],[116.436825,36.496364],[116.439443,36.49636],[116.438981,36.494388],[116.440904,36.493936],[116.440267,36.488597],[116.443609,36.487585],[116.44285,36.4853],[116.449059,36.482415],[116.447835,36.478127],[116.451457,36.480212],[116.453491,36.479784],[116.453574,36.475608],[116.453581,36.475277],[116.453681,36.470796],[116.451945,36.466226],[116.449914,36.461655],[116.450998,36.455235],[116.455774,36.449716],[116.46825,36.449192],[116.475985,36.448175],[116.477106,36.44926],[116.477538,36.449793],[116.478281,36.450446],[116.47957,36.450861],[116.480027,36.451098],[116.482133,36.453135],[116.482686,36.45357],[116.483369,36.453846],[116.483724,36.454289],[116.485224,36.453999],[116.485016,36.453466],[116.485596,36.452717],[116.488138,36.450459],[116.49394,36.449996],[116.500983,36.448186],[116.50166,36.447903],[116.500252,36.444261],[116.502222,36.444266],[116.502195,36.441971],[116.504184,36.44128],[116.50617,36.441495],[116.507272,36.441125],[116.507162,36.440215],[116.504853,36.433603],[116.505046,36.432577],[116.506313,36.429908],[116.507224,36.429723],[116.509233,36.428225],[116.511796,36.427263],[116.512195,36.428333],[116.512787,36.428116],[116.517926,36.424503],[116.518253,36.423819],[116.518268,36.423453],[116.521613,36.424302],[116.530755,36.429265],[116.533401,36.428901],[116.534148,36.428539],[116.534194,36.427561],[116.530381,36.418404],[116.532957,36.41813],[116.532649,36.416682],[116.532623,36.416531],[116.533449,36.41552],[116.533722,36.415459],[116.536513,36.416514],[116.538969,36.418155],[116.540812,36.419646],[116.542658,36.41928],[116.544087,36.417352],[116.540896,36.412058],[116.541654,36.410547],[116.540693,36.410125],[116.540252,36.41003],[116.540732,36.40892],[116.537756,36.406918],[116.537249,36.406576],[116.530452,36.397456],[116.527085,36.393087],[116.52554,36.389223],[116.523119,36.387245],[116.518431,36.385068],[116.514856,36.384202],[116.514489,36.384114],[116.508824,36.37871],[116.503495,36.373956],[116.498122,36.36988],[116.494354,36.364363],[116.491681,36.358558],[116.49037,36.354275],[116.488981,36.352569],[116.485449,36.350157],[116.483452,36.347407],[116.481342,36.342284],[116.480109,36.338547],[116.478946,36.336817],[116.476489,36.335584],[116.473946,36.33528],[116.462746,36.337827],[116.453283,36.338367],[116.447127,36.338221],[116.443306,36.336935],[116.439755,36.332868],[116.436889,36.327259],[116.435595,36.321506],[116.431506,36.318409],[116.42482,36.317762],[116.411135,36.318883],[116.400906,36.318759],[116.393734,36.31632],[116.384009,36.311923],[116.375378,36.307232],[116.368727,36.303641],[116.357683,36.301017],[116.345598,36.297576],[116.334625,36.293845],[116.325511,36.290489],[116.316935,36.284503],[116.309358,36.276042],[116.30513,36.270383],[116.303473,36.265209],[116.301493,36.259339],[116.29475,36.251901],[116.286818,36.245671],[116.280646,36.239092],[116.278077,36.233826],[116.27806,36.2274],[116.274537,36.221855],[116.265285,36.214288],[116.256399,36.209251],[116.249483,36.20366],[116.241976,36.195558],[116.238391,36.192536],[116.235536,36.188199],[116.229262,36.180901],[116.221877,36.174298],[116.220444,36.173705],[116.218139,36.172748],[116.218126,36.172744],[116.218116,36.172738],[116.212547,36.170427],[116.207426,36.169782],[116.198878,36.169878],[116.190311,36.170135],[116.182282,36.170346],[116.174384,36.171297],[116.163732,36.171167],[116.15862,36.168705],[116.159244,36.160381],[116.160538,36.151998],[116.158542,36.145938],[116.148202,36.142777],[116.138305,36.141898],[116.130716,36.140294],[116.127455,36.139443],[116.122747,36.137829],[116.118005,36.136205],[116.112744,36.132836],[116.111077,36.130758],[116.109739,36.126626],[116.108168,36.121825],[116.104842,36.118871],[116.099954,36.116285],[116.093484,36.111852],[116.071142,36.108719],[116.057102,36.106406],[116.051562,36.104743],[116.048427,36.100912],[116.023032,36.072197],[116.010661,36.061303],[115.993854,36.051471],[115.987856,36.047226],[115.984167,36.045471],[115.977241,36.044826],[115.958503,36.04169],[115.943186,36.037122],[115.930359,36.031587],[115.917438,36.021711],[115.913741,36.019867],[115.911901,36.019774],[115.9083,36.020422],[115.897869,36.024672],[115.893261,36.026517],[115.890484,36.026382],[115.866679,36.016877],[115.863911,36.015492],[115.862896,36.014201],[115.862157,36.011707],[115.860491,36.008199],[115.859023,36.006996],[115.855887,36.005473],[115.854121,36.003861],[115.848305,36.003216],[115.844434,36.003818],[115.84065,36.005109],[115.836952,36.00714],[115.831874,36.01111],[115.829756,36.011665],[115.826154,36.011572],[115.820521,36.011665],[115.817535,36.011857],[115.817498,36.012507],[115.814925,36.012635],[115.81445,36.012767],[115.811594,36.012827],[115.809714,36.012466],[115.808747,36.012171],[115.807569,36.011985],[115.807158,36.011794],[115.806733,36.011445],[115.798915,36.009474],[115.794898,36.008496],[115.79177,36.007021],[115.790784,36.006082],[115.790149,36.005662],[115.789213,36.005202],[115.788391,36.004608],[115.787826,36.003809],[115.78718,36.00327],[115.786619,36.002923],[115.786032,36.002885],[115.785033,36.002176],[115.783957,36.001186],[115.783223,36.000564],[115.781465,35.999337],[115.779494,35.998606],[115.777632,35.997469],[115.775647,35.99567],[115.774659,35.99459],[115.774091,35.993807],[115.774819,35.993283],[115.775948,35.992075],[115.776343,35.991901],[115.777413,35.991648],[115.780966,35.991247],[115.768742,35.981909],[115.768925,35.974552],[115.765276,35.972792],[115.762472,35.972052],[115.758548,35.970989],[115.754936,35.970568],[115.75157,35.970597],[115.750882,35.97046],[115.748464,35.970267],[115.735928,35.968035],[115.733943,35.967788],[115.733847,35.967756],[115.733707,35.967662],[115.733633,35.967699],[115.730202,35.966924],[115.727264,35.966847],[115.72634,35.967191],[115.725528,35.96747],[115.724048,35.968193],[115.722542,35.968835],[115.719608,35.969435],[115.715244,35.970428],[115.713073,35.971055],[115.712126,35.971419],[115.711439,35.971296],[115.707513,35.96999],[115.705768,35.969722],[115.704649,35.969588],[115.704118,35.969467],[115.703459,35.96925],[115.702494,35.968604],[115.702125,35.96841],[115.701096,35.967988],[115.699064,35.967381],[115.698501,35.967286],[115.697563,35.967467],[115.697269,35.967454],[115.693658,35.966365],[115.692955,35.966103],[115.692229,35.965514],[115.691071,35.965095],[115.689196,35.964118],[115.687762,35.963071],[115.685705,35.961673],[115.685264,35.961599],[115.684228,35.961723],[115.684878,35.960895],[115.68485,35.960478],[115.682921,35.958228],[115.68126,35.955303],[115.680644,35.953586],[115.679844,35.950764],[115.67932,35.94651],[115.678882,35.945306],[115.678353,35.944472],[115.674914,35.941597],[115.673949,35.94056],[115.671382,35.939241],[115.669706,35.938549],[115.662242,35.936661],[115.658933,35.935977],[115.65602,35.93461],[115.650156,35.932165],[115.647419,35.93004],[115.646146,35.929054],[115.645836,35.927652],[115.6429,35.92313],[115.642323,35.922386],[115.640426,35.92098],[115.636774,35.920209],[115.634175,35.920491],[115.631926,35.920279],[115.630241,35.920771],[115.629117,35.921685],[115.628133,35.922809],[115.626728,35.923301],[115.623076,35.923442],[115.613172,35.924287],[115.605657,35.925554],[115.601724,35.926046],[115.598634,35.925906],[115.592595,35.924231],[115.591886,35.924231],[115.583399,35.923864],[115.578141,35.921927],[115.548973,35.902316],[115.542517,35.898163],[115.536424,35.896596],[115.526643,35.894013],[115.50753,35.890414],[115.497567,35.888752],[115.482149,35.88079],[115.478729,35.878528],[115.470325,35.875804],[115.454097,35.867682],[115.448987,35.862925],[115.446101,35.860081],[115.437968,35.850715],[115.434509,35.846715],[115.427796,35.838951],[115.426795,35.833755],[115.42083,35.833708],[115.421111,35.830072],[115.411867,35.824869],[115.401514,35.808546],[115.399287,35.807238],[115.390232,35.80192],[115.385861,35.800019],[115.378288,35.796711],[115.375299,35.795407],[115.373148,35.794033],[115.371566,35.792749],[115.369421,35.791655],[115.364869,35.788749],[115.357498,35.779841],[115.355724,35.780237],[115.33588,35.792484],[115.329049,35.796686],[115.328215,35.797907],[115.328171,35.798784],[115.329092,35.802663],[115.329743,35.81427],[115.332234,35.824056],[115.333893,35.829871],[115.337356,35.836035],[115.338007,35.837465],[115.338094,35.838665],[115.337313,35.840512],[115.335165,35.843015],[115.335319,35.84367],[115.338586,35.84308],[115.339388,35.847697],[115.338713,35.847782],[115.338755,35.848182],[115.340737,35.847992],[115.343576,35.860878],[115.336761,35.861846],[115.336967,35.862876],[115.336061,35.862998],[115.335855,35.863987],[115.332191,35.864646],[115.333303,35.870575],[115.336843,35.870081],[115.337625,35.872058],[115.348868,35.869176],[115.349136,35.870267],[115.350865,35.870143],[115.351442,35.878585],[115.354077,35.87908],[115.356075,35.88969],[115.358227,35.893919],[115.358869,35.897888],[115.360067,35.908713],[115.360719,35.912359],[115.361362,35.920207],[115.360441,35.924729],[115.358088,35.929368],[115.353469,35.93292],[115.350239,35.93532],[115.348112,35.937399],[115.347375,35.938828],[115.347331,35.940168],[115.348347,35.945567],[115.350465,35.954499],[115.355319,35.967333],[115.357072,35.971879],[115.358644,35.973171],[115.361039,35.97405],[115.365008,35.974743],[115.369262,35.974696],[115.380202,35.974307],[115.382,35.974952],[115.383294,35.976107],[115.383988,35.977537],[115.384493,35.981739],[115.385464,35.986954],[115.386759,35.989009],[115.389893,35.991502],[115.396041,35.994782],[115.399827,35.996444],[115.413582,36.004572],[115.421709,36.006513],[115.429377,36.007161],[115.437036,36.008732],[115.439901,36.010302],[115.441473,36.011686],[115.441723,36.012526],[115.441709,36.014372],[115.441662,36.016008],[115.4416,36.017317],[115.441475,36.018999],[115.44128,36.02097],[115.441311,36.021641],[115.441546,36.023293],[115.441872,36.024478],[115.442176,36.026636],[115.442363,36.027882],[115.442908,36.029581],[115.443337,36.030789],[115.443368,36.031178],[115.44312,36.032409],[115.442917,36.034918],[115.442753,36.036204],[115.442644,36.038089],[115.442722,36.039414],[115.442745,36.040357],[115.442823,36.041775],[115.44287,36.043691],[115.442894,36.045101],[115.442878,36.04638],[115.442839,36.047259],[115.440896,36.047378],[115.440927,36.049672],[115.440144,36.049646],[115.440029,36.048699],[115.439609,36.048694],[115.439566,36.047034],[115.437848,36.047012],[115.437911,36.04894],[115.43718,36.048732],[115.437192,36.052211],[115.434897,36.052477],[115.435539,36.055599],[115.439732,36.055081],[115.44009,36.058202],[115.441863,36.058278],[115.441951,36.0592],[115.44348,36.059191],[115.445139,36.062046],[115.446319,36.061864],[115.446078,36.060937],[115.447087,36.060696],[115.44743,36.061523],[115.449543,36.061086],[115.449417,36.063564],[115.453566,36.063237],[115.453489,36.066267],[115.453068,36.066324],[115.453275,36.068403],[115.450462,36.068723],[115.450824,36.070696],[115.449082,36.071144],[115.450463,36.073344],[115.451895,36.076437],[115.452739,36.07879],[115.453788,36.080273],[115.45641,36.079945],[115.4604,36.079587],[115.460754,36.08178],[115.459089,36.082615],[115.459696,36.083802],[115.46169,36.083486],[115.461898,36.08352],[115.462795,36.0875],[115.462506,36.087604],[115.462784,36.089049],[115.463032,36.089037],[115.463461,36.091092],[115.462843,36.092123],[115.464467,36.094357],[115.467239,36.096706],[115.467983,36.098048],[115.468238,36.099726],[115.468717,36.101676],[115.47006,36.103945],[115.470827,36.105799],[115.471083,36.108515],[115.471627,36.110944],[115.471867,36.111246],[115.472906,36.112024],[115.473419,36.112999],[115.474074,36.113996],[115.474799,36.116079],[115.475283,36.11767],[115.475221,36.118201],[115.474831,36.118885],[115.474799,36.119494],[115.475104,36.120205],[115.475805,36.122231],[115.476508,36.123729],[115.477912,36.125304],[115.478321,36.125768],[115.478963,36.133874],[115.479241,36.13962],[115.477618,36.148897],[115.474709,36.171653],[115.472709,36.179167],[115.472233,36.180173],[115.472159,36.181235],[115.470655,36.186885],[115.470004,36.192931],[115.471297,36.1957],[115.473147,36.202995],[115.473146,36.209457],[115.471297,36.21398],[115.470004,36.21878],[115.470003,36.226903],[115.469908,36.231935],[115.471115,36.238305],[115.471306,36.241143],[115.470096,36.244808],[115.470546,36.246392],[115.468498,36.246828],[115.468754,36.248301],[115.468284,36.248378],[115.46823,36.247997],[115.464648,36.248628],[115.464662,36.248942],[115.462042,36.249403],[115.462097,36.249718],[115.459374,36.250228],[115.45944,36.251005],[115.458478,36.251191],[115.4586,36.253273],[115.459255,36.255249],[115.458906,36.255393],[115.459039,36.25584],[115.458732,36.255919],[115.458904,36.256516],[115.459395,36.25644],[115.46016,36.25901],[115.46063,36.258983],[115.460524,36.258172],[115.460892,36.258128],[115.461039,36.258906],[115.461591,36.25888],[115.461642,36.259409],[115.462133,36.259333],[115.462263,36.259996],[115.461894,36.26009],[115.462309,36.261813],[115.464189,36.261639],[115.464377,36.262452],[115.462392,36.262723],[115.462935,36.265225],[115.462505,36.265285],[115.462136,36.265396],[115.461667,36.265406],[115.461825,36.267738],[115.460864,36.267857],[115.460915,36.26837],[115.459159,36.26843],[115.459166,36.270131],[115.45843,36.270204],[115.4584,36.270666],[115.458789,36.270638],[115.458782,36.271002],[115.457371,36.271132],[115.457411,36.272223],[115.456612,36.272378],[115.456642,36.273981],[115.456681,36.275944],[115.45574,36.276295],[115.454112,36.276765],[115.452875,36.2766],[115.451626,36.276563],[115.449117,36.277088],[115.448398,36.276815],[115.445344,36.275123],[115.443766,36.274066],[115.442244,36.274518],[115.442338,36.274883],[115.440617,36.275255],[115.440048,36.273571],[115.430261,36.276138],[115.430581,36.2776],[115.426527,36.278324],[115.425499,36.279039],[115.425256,36.279429],[115.425326,36.280585],[115.424608,36.280725],[115.42471,36.28175],[115.42381,36.281837],[115.423882,36.282317],[115.424516,36.282277],[115.424844,36.284214],[115.422075,36.284736],[115.422391,36.285992],[115.419431,36.286437],[115.41948,36.287033],[115.414509,36.287593],[115.414562,36.287973],[115.413617,36.288291],[115.414038,36.289635],[115.412472,36.290422],[115.412296,36.292023],[115.410958,36.29255],[115.412058,36.294713],[115.411708,36.294857],[115.412102,36.295556],[115.413169,36.29529],[115.413457,36.296201],[115.413928,36.296109],[115.414782,36.298285],[115.415438,36.298177],[115.416791,36.302114],[115.416843,36.302359],[115.415079,36.302799],[115.416022,36.306643],[115.41429,36.307496],[115.414693,36.308747],[115.415328,36.308828],[115.415651,36.309373],[115.41605,36.311286],[115.413265,36.310654],[115.413626,36.31198],[115.414076,36.31197],[115.415233,36.31633],[115.414677,36.316537],[115.414714,36.316736],[115.415524,36.318962],[115.416817,36.321939],[115.415989,36.323595],[115.408885,36.326312],[115.388514,36.322335],[115.379761,36.317261],[115.373265,36.313567],[115.367335,36.311712],[115.360555,36.308703],[115.355163,36.310512],[115.353696,36.318518],[115.356787,36.323113],[115.361014,36.326566],[115.364375,36.332536],[115.362613,36.342373],[115.354929,36.34875],[115.348087,36.356271],[115.343512,36.362893],[115.343456,36.370397],[115.343474,36.370557],[115.343476,36.37062],[115.343472,36.370652],[115.343454,36.370732],[115.343451,36.371138],[115.342522,36.384412],[115.339935,36.389899]]]}'::text
    ) AS geom
)
UPDATE public.bo_airspace b
SET geom = ST_Force3D(p.geom)
FROM (
    SELECT geom
    FROM source_geom
    WHERE GeometryType(geom) = 'POLYGON'
) p
WHERE b.id = 'liaochengzhuchengqu';

//可以点数量：
SELECT
    ST_NPoints(geom) AS original_points
FROM public.bo_airspace
WHERE id = 'liaochengzhuchengqu';

//只是边界展示，可以做简化
ALTER TABLE public.bo_airspace
ADD COLUMN IF NOT EXISTS display_geom geometry(Polygon, 4326);
-- 0.00001 度 ≈ 1 米
-- 相邻边界点偏差小于约 1 米的点可能被删除
-- 轮廓整体形状尽量保持
-- 尽量避免生成自相交、破面等拓扑错误
-- 原始边界点很多时，点数和地图渲染压力会下降
-- 边界会有轻微变化，不适合精确空间校验
UPDATE public.bo_airspace
SET display_geom = ST_SimplifyPreserveTopology(geom, 0.00001);  
