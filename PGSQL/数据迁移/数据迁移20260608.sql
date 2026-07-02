------------------------------------------------------------------ 方案一sql同步给 PG17 安装 mysql_fdw
-- -- 1. 安装 MySQL 连接扩展（PG 专用）
-- CREATE EXTENSION IF NOT EXISTS mysql_fdw;
-- 
-- -- 2. 创建 MySQL 服务器连接
-- CREATE SERVER mysql_ktd_server
-- FOREIGN DATA WRAPPER mysql_fdw
-- OPTIONS (
--   host '192.168.110.6',
--   port '3307',
--   dbname 'ktd_lx_2026dev'
-- );
-- 
-- -- 3. 配置 MySQL 账号密码
-- CREATE USER MAPPING FOR zhuoyi
-- SERVER mysql_ktd_server
-- OPTIONS (
--   username 'root',
--   password 'Ktdmysql@2026!@#'
-- );
-- 
-- -- =============================================
-- -- 4. 开始迁移：电子围栏 + 静态标注 3张表
-- -- 自动创建表结构 + 迁移全部数据
-- -- =============================================
-- 
-- -- 迁移 电子围栏信息
-- CREATE TABLE bo_electric_fence
-- AS SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_electric_fence;
-- 
-- -- 迁移 定时录像计划表
-- CREATE TABLE bo_time_plan
-- AS SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_time_plan;
-- 
-- -- 迁移 地物标注信息
-- CREATE TABLE bo_ground_ele
-- AS SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_ground_ele;
-- 
-- 
-- -- -- 增量同步电子围栏（按ID追加）
-- -- INSERT INTO bo_electric_fence
-- -- SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_electric_fence
-- -- WHERE id > (SELECT max(id) FROM bo_electric_fence);
-- -- 
-- -- -- 增量同步地物标注
-- -- INSERT INTO bo_ground_ele
-- -- SELECT * FROM mysql_ktd_server.ktd_lx_2026dev.bo_ground_ele
-- -- WHERE id > (SELECT max(id) FROM bo_ground_ele);

------------------------------------------------------------------------------------------ -- 方案二 Navicat同步数据
-- 电子围栏数据迁移
-- 同步 bo_electric_fence（电子围栏信息）、 bo_time_plan （定时录像计划表）表所有数据
-- 
-- 静态标注数据迁移
-- 同步 bo_ground_ele（地物标注信息）表所有数据

-- 打开 Navicat，同时连接：
-- MySQL：192.168.110.6:3307，库 ktd_lx_2026dev
-- PG：192.168.110.6:5432，库 ktd_lx_2026gis
-- 菜单栏 → 工具 → 数据传输
-- 源：选 MySQL 的 ktd_lx_2026dev
-- 目标：选 PG 的 ktd_lx_2026gis
-- 勾选要迁移的 3 张表：
-- bo_electric_fence
-- bo_time_plan
-- bo_ground_ele

-- 选项里勾选：包含表结构、包含数据、主键索引可酌情不勾
-- 开始 → 执行完成即可。


-- 电子围栏
SELECT COUNT(*) FROM bo_electric_fence;

-- 地物标注
SELECT COUNT(*) FROM bo_ground_ele;

-- 定时计划
SELECT COUNT(*) FROM bo_time_plan;

 -- 安装 PostGIS 空间扩展
CREATE EXTENSION IF NOT EXISTS postgis;

------------------------------------------------------------------------------------------ 给电子围栏表添加 time_plan 字段
-- 添加字段（varchar(4000)，默认值 default）
ALTER TABLE bo_electric_fence ADD COLUMN time_plan varchar(4000) DEFAULT 'default';
COMMENT ON COLUMN bo_electric_fence.time_plan IS '时间计划';--  给字段加注释


--  把 bo_time_plan 数据拼成 JSON 自动更新到 time_plan 字段
UPDATE bo_electric_fence f
SET time_plan = (
  SELECT json_agg(
    json_build_object(
		 'startTime', t.start_time,
      'endTime', t.end_time,
      'left', t.time_left,
      'width', t.width
    )
  )
  FROM bo_time_plan t
  WHERE t.pid = f.id  -- 关键：通过 pid 关联围栏ID
);
-- 修改后数据查看
-- SELECT id, time_plan FROM bo_electric_fence 
-- SELECT * FROM bo_time_plan 


-- =============================================
------------------------------------------------------------------------------------------ 函数：统一公共字段（create_time/update_time/del_flag等）
-- =============================================
SELECT gis_drop_function('lx_gis_base_common_columns');
CREATE OR REPLACE FUNCTION lx_gis_base_common_columns(tbl_name text)
RETURNS void AS $$
BEGIN
    -- 1. create_time
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'create_time' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN create_time timestamp NOT NULL DEFAULT now()', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.create_time IS ''创建时间''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_time TYPE timestamp USING create_time::timestamp', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_time SET NOT NULL', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_time SET DEFAULT now()', tbl_name);
    END IF;

    -- 2. create_user
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'create_user' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN create_user varchar(32)', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.create_user IS ''创建者''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN create_user TYPE varchar(32) USING create_user::varchar(32)', tbl_name);
    END IF;

    -- 3. update_time
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'update_time' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN update_time timestamp NOT NULL DEFAULT now()', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.update_time IS ''更新时间''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_time TYPE timestamp USING update_time::timestamp', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_time SET NOT NULL', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_time SET DEFAULT now()', tbl_name);
    END IF;

    -- 4. update_user
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'update_user' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN update_user varchar(32)', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.update_user IS ''更新者''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN update_user TYPE varchar(32) USING update_user::varchar(32)', tbl_name);
    END IF;

    -- 5. del_flag → boolean
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = tbl_name::regclass AND attname = 'del_flag' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN del_flag boolean NOT NULL DEFAULT false', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.del_flag IS ''是否删除：false未删除；true删除''', tbl_name);
    ELSE
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag DROP DEFAULT;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag TYPE varchar(5);', tbl_name);
        EXECUTE format('UPDATE %I SET del_flag = CASE WHEN del_flag IN (''1'',''true'',''t'') THEN ''true'' ELSE ''false'' END WHERE del_flag IS NOT NULL;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag TYPE boolean USING del_flag::boolean;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag SET NOT NULL;', tbl_name);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN del_flag SET DEFAULT false;', tbl_name);
        EXECUTE format('COMMENT ON COLUMN %I.del_flag IS ''是否删除：false未删除；true删除''', tbl_name);
    END IF;
    RAISE NOTICE '✅ 表 % 公共字段处理完成', tbl_name;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION lx_gis_base_common_columns(text) IS '统一公共字段';

-- =============================================
------------------------------------------------------------------------------------------ 函数：char 直接改为 varchar(32) + 清除字符串前后空格
-- =============================================
SELECT gis_drop_function('lx_gis_string_columns_varchar');

CREATE OR REPLACE FUNCTION lx_gis_string_columns_varchar(p_table_name text)
RETURNS void AS $$
DECLARE
    rec record;
BEGIN
    -- 1. 直接把所有 char 类型 → varchar(32)
    FOR rec IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = p_table_name
          AND data_type = 'character'  -- 只处理char
    LOOP
        EXECUTE format(
            'ALTER TABLE %I ALTER COLUMN %I TYPE varchar(32)',
            p_table_name, rec.column_name
        );
        RAISE NOTICE '✅ 字段 % 已从 char 直接改为 varchar(32)', rec.column_name;
    END LOOP;

    -- 2. 清除所有字符串字段前后空格
    FOR rec IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = p_table_name
          AND data_type IN ('character varying', 'text')
    LOOP
        EXECUTE format(
            'UPDATE %I SET %I = trim(%I) WHERE %I IS NOT NULL',
            p_table_name, rec.column_name, rec.column_name, rec.column_name
        );
    END LOOP;

    RAISE NOTICE '==================================================';
    RAISE NOTICE '✅ 表 % 处理完成：char→varchar(32)，空格已清除', p_table_name;
    RAISE NOTICE '==================================================';
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION lx_gis_string_columns_varchar(text) IS '字符串清洗';
 

-- =============================================
------------------------------------------------------------------------------------------  批量执行所有表
-- =============================================
 
SELECT lx_gis_base_common_columns('bo_electric_fence');
SELECT lx_gis_base_common_columns('bo_time_plan');
SELECT lx_gis_base_common_columns('bo_ground_ele');

  
SELECT lx_gis_string_columns_varchar('bo_electric_fence');
SELECT lx_gis_string_columns_varchar('bo_time_plan');
SELECT lx_gis_string_columns_varchar('bo_ground_ele');

 
-- GeoJSON 解析函数：
-- 1. 支持 FeatureCollection、Feature 和直接 Geometry 三种格式。
-- 2. Polygon / MultiPolygon 外环或内环未闭合时，自动追加第一个点完成闭合。
-- 3. 返回 PostGIS geometry，后续可同时生成 2D / 3D 空间字段。
SELECT gis_drop_function('gis_geojson_to_closed_geom');
CREATE OR REPLACE FUNCTION gis_geojson_to_closed_geom(p_geojson text)
RETURNS geometry
LANGUAGE plpgsql
AS $$
DECLARE
    v_json jsonb;
    v_geom_json jsonb;
    v_geom_type text;
    v_features jsonb;
    v_feature_count integer;
    v_bad_ring_count integer;
BEGIN
    IF p_geojson IS NULL OR trim(p_geojson) = '' THEN
        RETURN NULL;
    END IF;

    BEGIN
        v_json := p_geojson::jsonb;
    EXCEPTION WHEN others THEN
        RETURN NULL;
    END;

    IF v_json ->> 'type' = 'FeatureCollection' THEN
        v_features := CASE
            WHEN jsonb_typeof(v_json -> 'features') = 'array' THEN v_json -> 'features'
            ELSE '[]'::jsonb
        END;

        SELECT count(*)
        INTO v_feature_count
        FROM jsonb_array_elements(v_features) AS f(feature)
        WHERE f.feature -> 'geometry' IS NOT NULL;

        IF v_feature_count = 0 THEN
            RETURN NULL;
        END IF;

        IF v_feature_count = 1 THEN
            SELECT f.feature -> 'geometry'
            INTO v_geom_json
            FROM jsonb_array_elements(v_features) AS f(feature)
            WHERE f.feature -> 'geometry' IS NOT NULL
            LIMIT 1;
        ELSE
            SELECT
                CASE
                    WHEN bool_and(f.feature -> 'geometry' ->> 'type' = 'Polygon')
                        THEN jsonb_build_object(
                            'type', 'MultiPolygon',
                            'coordinates', jsonb_agg(f.feature -> 'geometry' -> 'coordinates' ORDER BY feature_ord)
                        )
                    ELSE jsonb_build_object(
                        'type', 'GeometryCollection',
                        'geometries', jsonb_agg(f.feature -> 'geometry' ORDER BY feature_ord)
                    )
                END
            INTO v_geom_json
            FROM jsonb_array_elements(v_features) WITH ORDINALITY AS f(feature, feature_ord)
            WHERE f.feature -> 'geometry' IS NOT NULL;
        END IF;
    ELSIF v_json ->> 'type' = 'Feature' THEN
        v_geom_json := v_json -> 'geometry';
    ELSE
        v_geom_json := v_json;
    END IF;

    IF v_geom_json IS NULL THEN
        RETURN NULL;
    END IF;

    v_geom_type := v_geom_json ->> 'type';

    IF v_geom_type = 'Polygon' THEN
        IF jsonb_typeof(v_geom_json -> 'coordinates') IS DISTINCT FROM 'array' THEN
            RETURN NULL;
        END IF;

        IF jsonb_array_length(v_geom_json -> 'coordinates') = 0 THEN
            RETURN NULL;
        END IF;

        SELECT count(*)
        INTO v_bad_ring_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS r(ring)
        WHERE CASE
            WHEN jsonb_typeof(ring) = 'array' THEN jsonb_array_length(ring) < 3
            ELSE true
        END;

        IF v_bad_ring_count > 0 THEN
            RETURN NULL;
        END IF;

        SELECT jsonb_set(
            v_geom_json,
            '{coordinates}',
            COALESCE(
                jsonb_agg(
                    CASE
                        WHEN jsonb_array_length(ring) > 0
                             AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1)
                            THEN ring || jsonb_build_array(ring -> 0)
                        ELSE ring
                    END
                    ORDER BY ring_ord
                ),
                '[]'::jsonb
            ),
            false
        )
        INTO v_geom_json
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') WITH ORDINALITY AS r(ring, ring_ord);

    ELSIF v_geom_type = 'MultiPolygon' THEN
        IF jsonb_typeof(v_geom_json -> 'coordinates') IS DISTINCT FROM 'array' THEN
            RETURN NULL;
        END IF;

        IF jsonb_array_length(v_geom_json -> 'coordinates') = 0 THEN
            RETURN NULL;
        END IF;

        SELECT count(*)
        INTO v_bad_ring_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS p(poly)
        WHERE jsonb_typeof(poly) IS DISTINCT FROM 'array'
           OR jsonb_array_length(poly) = 0;

        IF v_bad_ring_count > 0 THEN
            RETURN NULL;
        END IF;

        SELECT count(*)
        INTO v_bad_ring_count
        FROM jsonb_array_elements(v_geom_json -> 'coordinates') AS p(poly)
        CROSS JOIN LATERAL jsonb_array_elements(p.poly) AS r(ring)
        WHERE CASE
            WHEN jsonb_typeof(ring) = 'array' THEN jsonb_array_length(ring) < 3
            ELSE true
        END;

        IF v_bad_ring_count > 0 THEN
            RETURN NULL;
        END IF;

        SELECT jsonb_set(
            v_geom_json,
            '{coordinates}',
            COALESCE(jsonb_agg(poly_closed ORDER BY poly_ord), '[]'::jsonb),
            false
        )
        INTO v_geom_json
        FROM (
            SELECT
                poly_ord,
                jsonb_agg(
                    CASE
                        WHEN jsonb_array_length(ring) > 0
                             AND ring -> 0 <> ring -> (jsonb_array_length(ring) - 1)
                            THEN ring || jsonb_build_array(ring -> 0)
                        ELSE ring
                    END
                    ORDER BY ring_ord
                ) AS poly_closed
            FROM jsonb_array_elements(v_geom_json -> 'coordinates') WITH ORDINALITY AS p(poly, poly_ord)
            CROSS JOIN LATERAL jsonb_array_elements(p.poly) WITH ORDINALITY AS r(ring, ring_ord)
            GROUP BY poly_ord
        ) s;
    END IF;

    BEGIN
        RETURN ST_GeomFromGeoJSON(v_geom_json::text);
    EXCEPTION WHEN others THEN
        RETURN NULL;
    END;
END;
$$;
COMMENT ON FUNCTION gis_geojson_to_closed_geom(text) IS 'GeoJSON转几何';


------------------------------------------------------------------------------------------空间数据创建bo_electric_fence
DROP INDEX IF EXISTS idx_bo_electric_fence_geom;
ALTER TABLE bo_electric_fence DROP COLUMN IF EXISTS geom;
DROP INDEX IF EXISTS idx_bo_electric_fence_geom_3d;
ALTER TABLE bo_electric_fence DROP COLUMN IF EXISTS geom_3d;
 
--  添加   字段（必用）GEOMETRY
ALTER TABLE bo_electric_fence ADD COLUMN geom geometry(Geometry);
ALTER TABLE bo_electric_fence ADD COLUMN geom_3d geometry(GeometryZ);
CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_geom ON bo_electric_fence USING GIST (geom);
-- CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_geom3d ON bo_electric_fence USING GIST (geom_3d);
COMMENT ON COLUMN bo_electric_fence.geom IS '空间数据';
COMMENT ON COLUMN bo_electric_fence.geom_3d IS '空间数据';

--  同时更新 2D / 3D 围栏
--  支持三种 GeoJSON：
--  1. FeatureCollection：{"type":"FeatureCollection","features":[...]}
--  2. Feature：{"type":"Feature","geometry":{...},"properties":{...}}
--  3. Geometry：{"type":"Polygon","coordinates":[...]} / {"type":"MultiPolygon","coordinates":[...]}
UPDATE bo_electric_fence t
SET
    geom = ST_SetSRID(ST_Force2D(ST_MakeValid(src.raw_geom)), 4326),
    geom_3d = ST_SetSRID(ST_Force3D(ST_MakeValid(src.raw_geom)), 4326)
FROM (
    SELECT
        id,
        gis_geojson_to_closed_geom(lng_lat_alt) AS raw_geom
    FROM bo_electric_fence
    WHERE
        lng_lat_alt IS NOT NULL
        AND trim(lng_lat_alt) <> ''
) src
WHERE
    t.id = src.id
    AND ST_GeometryType(src.raw_geom) IN ('ST_Polygon','ST_MultiPolygon');
--   查询无效数据
SELECT * FROM bo_electric_fence WHERE geom IS NULL;
--   删除无效数据
DELETE FROM bo_electric_fence WHERE geom IS NULL;

------------------------------------------------------------------------------------------空间数据创建bo_electric_fence
-- 删除旧字段
DROP INDEX IF EXISTS idx_bo_ground_ele_geom;
ALTER TABLE bo_ground_ele DROP COLUMN IF EXISTS geom;
DROP INDEX IF EXISTS idx_bo_ground_ele_geom_3d;
ALTER TABLE bo_ground_ele DROP COLUMN IF EXISTS geom_3d;
  

-- 创建通用空间字段（兼容 点 Point、线 Line、面 Polygon、混合集合 GeometryCollection）
ALTER TABLE bo_ground_ele ADD COLUMN geom geometry(Geometry);
ALTER TABLE bo_ground_ele ADD COLUMN geom_3d geometry(GeometryZ);
CREATE INDEX IF NOT EXISTS idx_bo_ground_ele_geom ON bo_ground_ele USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_bo_ground_ele_geom3d ON bo_ground_ele USING GIST (geom_3d);
COMMENT ON COLUMN bo_ground_ele.geom IS '空间数据';
COMMENT ON COLUMN bo_ground_ele.geom_3d IS '空间数据';

-- 同时生成 2D 和 3D 空间数据
-- 支持三种 GeoJSON：
-- 1. FeatureCollection：{"type":"FeatureCollection","features":[...]}
-- 2. Feature：{"type":"Feature","geometry":{...},"properties":{...}}
-- 3. Geometry：{"type":"Point/LineString/Polygon/MultiPolygon","coordinates":[...]}
-- 4. GeometryCollection：{"type":"GeometryCollection","geometries":[...]}
-- 兼容点、线、面、混合集合；对无效面/线使用 ST_MakeValid 尝试修复。
UPDATE bo_ground_ele t
SET 
    geom = ST_SetSRID(ST_Force2D(ST_MakeValid(src.raw_geom)), 4326),
    geom_3d = ST_SetSRID(ST_Force3D(ST_MakeValid(src.raw_geom)), 4326)
FROM (
    SELECT
        id,
        gis_geojson_to_closed_geom(lng_lat_alt) AS raw_geom
    FROM bo_ground_ele
    WHERE
        lng_lat_alt IS NOT NULL
        AND trim(lng_lat_alt) <> ''
) src
WHERE
    t.id = src.id
    AND ST_GeometryType(src.raw_geom) IN (
        'ST_Point',
        'ST_LineString',
        'ST_MultiLineString',
        'ST_Polygon',
        'ST_MultiPolygon',
        'ST_GeometryCollection'
    );

SELECT * FROM bo_ground_ele WHERE geom IS NULL;

--   删除无效数据
DELETE FROM bo_ground_ele WHERE geom IS NULL;


--------------------------------------------------------------------------------------------  函数：清理字段 + 重命名 geom_3d 为 geom
SELECT gis_drop_function('update_geom_columns');
CREATE OR REPLACE FUNCTION update_geom_columns(p_table_name text)
RETURNS void AS $$
BEGIN
    -- 1. 删除不需要的字段（安全判断，不存在也不报错）
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = p_table_name AND column_name = 'geom') THEN
        EXECUTE format('ALTER TABLE %I DROP COLUMN geom', p_table_name);
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = p_table_name AND column_name = 'lng_lat_alt') THEN
        EXECUTE format('ALTER TABLE %I DROP COLUMN lng_lat_alt', p_table_name);
    END IF;

    -- 2. 把 geom_3d 重命名为 geom
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = p_table_name AND column_name = 'geom_3d') THEN
        EXECUTE format('ALTER TABLE %I RENAME COLUMN geom_3d TO geom', p_table_name);
        RAISE NOTICE '✅ 字段 geom_3d 已重命名为 geom';
    ELSE
        RAISE NOTICE 'ℹ️ 表 % 中不存在 geom_3d 字段，无需重命名', p_table_name;
    END IF;

    RAISE NOTICE '✅ 表 % 字段处理完成：已删除 geom、lng_lat_alt，geom_3d → geom', p_table_name;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION update_geom_columns(text) IS '整理空间字段';


SELECT update_geom_columns('bo_electric_fence');
SELECT update_geom_columns('bo_ground_ele');

-- 1. 字段改名
ALTER TABLE bo_ground_ele RENAME COLUMN enable TO enabled; 
ALTER TABLE bo_ground_ele RENAME COLUMN position TO location; 

------------------------------------------------------------------------------------------ --   Navicat同步数据
 

-- 打开 Navicat，同时连接：
-- MySQL：192.168.110.6:3307，库 ktd_lx_2026dev
-- PG：192.168.110.6:5432，库 ktd_lx_2026gis
-- 菜单栏 → 工具 → 数据传输
-- 源：选 MySQL 的 ktd_lx_2026dev
-- 目标：选 PG 的 ktd_lx_2026gis
-- 勾选要迁移的  表：
-- bo_electric_fence
-- bo_ground_ele
-- bo_time_plan
-- gis_flight_paths
-- gis_poi_type_gd
-- gis_poi_type_td
-- jc_sheng
-- jc_shi
-- jc_xian 
-- wrj_jfq_dj
-- wrj_sfky_fujian
-- wrj_sfky_hubei
-- wrj_sfky_hunan
-- wrj_sfky_jilin
-- wrj_sfky_shandong
-- wrj_sfky_shanxi
-- wrj_sfky_yunnan
-- wrj_sfky_zhejiang

-- 选项里勾选：包含表结构、包含数据、主键索引可酌情不勾
-- 开始 → 执行完成即可。



-- -----------------------------------------------geoserver 自动调用项目服务------------------------------------------
-- -- PG库调用
-- SELECT * FROM gis_get_electric_fence_project('%project_id%', '%fence_type%')


