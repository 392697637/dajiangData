-- =============================================================================
-- 5.POI查询.sql
--   gis_query_poi                           按名称和范围查询兴趣点
--
-- =============================================================================

-- ============================================================
-- POI 查询函数：public.gis_query_poi
-- ============================================================
-- 功能：
--   按项目 ID 查询项目专属 POI 表，统一返回高德(gd)或天地(td)来源的数据。
--
-- 表名规则：
--   高德 POI：public.gis_poi_gd_项目ID
--   天地 POI：public.gis_poi_td_项目ID
--
-- 查询规则：
--   1. p_name 必填，按 name LIKE '%关键词%' 模糊匹配。
--   2. p_lng_lat 为空时，只按名称查询。
--   3. p_lng_lat 非空时，按圆心半径过滤；p_radius_km 为空时默认 5 公里。
--   4. p_lng_lat 支持两种格式：
--      - 对象：{'lon':113.531770706177,'lat':34.818162918091}
--      - 数组：[113.531770706177,34.818162918091]，顺序为 [经度,纬度]
--      对象格式也兼容标准 JSON 双引号：
--      {"lon":113.531770706177,"lat":34.818162918091}
--   5. p_radius_km 单位为公里，默认 5；内部换算为米后用 geography 计算距离。
--   6. p_source 支持 gd、td；为空默认 gd。
--
-- 参数：
--   p_project_id   text              项目 ID，必填；只能包含字母、数字、下划线。
--   p_name         text              POI 名称关键词，必填。
--   p_lng_lat      text              经纬度字符串；NULL/空字符串表示不做空间过滤。
--   p_radius_km    double precision  半径，单位公里；传经纬度时为空默认 5，传入时必须 > 0。
--   p_source       text              数据来源：gd=高德，td=天地；默认 gd。
--
-- 返回字段：
--   source_platform text              数据来源：gd 或 td。
--   id              bigint            POI 主键。
--   poi_id          text              来源平台 POI ID。
--   name            text              名称。
--   type_code       text              类型编码。
--   type_name       text              类型名称。
--   address         text              地址。
--   province        text              省。
--   city            text              市。
--   district        text              区县。
--   lng             double precision  经度。
--   lat             double precision  纬度。
--   geom            geometry(Point,4326) 数据库原始空间字段，不做 GeoJSON 转换。
--   distance_km     double precision  到传入圆心的距离；未传经纬度时默认为 0。
--   raw_data        jsonb             原始行 JSON，已去除原始 geom 字段。
--
-- 依赖：
--   PostgreSQL plpgsql；PostGIS geometry/geography。
--   建议 POI 表 geom 字段建立 GIST 索引，以提升半径查询性能。
-- ============================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_query_poi');

-- =============================================================================
-- 函数介绍：gis_query_poi
-- 主要作用：按名称关键字、项目范围或指定范围查询兴趣点POI数据。
-- 入参说明：包含查询关键字、范围GeoJSON、项目ID、半径或类型等过滤条件。
-- 返回说明：返回POI名称、位置、类型、距离和几何信息，供地图搜索和周边查询使用。
-- 注意事项：依赖POI基础数据和PostGIS空间索引；范围越大、关键字越宽泛查询耗时越高。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_query_poi(
    p_project_id text,
    p_name text,
    p_lng_lat text DEFAULT NULL,
    p_radius_km double precision DEFAULT 5,
    p_source text DEFAULT 'gd'
)
RETURNS TABLE (
    source_platform text,
    id bigint,
    poi_id text,
    name text,
    type_code text,
    type_name text,
    address text,
    province text,
    city text,
    district text,
    lng double precision,
    lat double precision,
    geom geometry(Point, 4326),
    distance_km double precision,
    raw_data jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_project_id text := btrim(p_project_id);
    v_name text := btrim(p_name);
    v_source text := lower(coalesce(nullif(btrim(p_source), ''), 'gd'));

    v_gd_table text := 'gis_poi_gd_' || btrim(p_project_id);
    v_td_table text := 'gis_poi_td_' || btrim(p_project_id);

    v_lng_lat text := btrim(p_lng_lat);
    v_lng_lat_json jsonb;
    v_lng double precision;
    v_lat double precision;
    v_radius_m double precision := 0;
    v_center_geom geometry(Point, 4326);

    v_sql_parts text[] := ARRAY[]::text[];
    v_sql text;
BEGIN
    -- 1. 基础参数校验。
    IF v_project_id IS NULL OR v_project_id = '' THEN
        RAISE EXCEPTION '参数错误：项目ID不能为空';
    END IF;

    IF v_project_id !~ '^[a-zA-Z0-9_]+$' THEN
        RAISE EXCEPTION '参数错误：项目ID只能包含字母、数字、下划线，当前值为 %', p_project_id;
    END IF;

    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION '参数错误：名称不能为空';
    END IF;

    IF v_source NOT IN ('gd', 'td') THEN
        RAISE EXCEPTION '参数错误：数据来源只能是 gd、td，当前值为 %', p_source;
    END IF;

    -- 2. 解析经纬度和半径；未传经纬度时跳过空间过滤。
    IF v_lng_lat IS NOT NULL AND v_lng_lat <> '' THEN
        BEGIN
            v_lng_lat_json := replace(v_lng_lat, '''', '"')::jsonb;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION
                '参数错误：经纬度必须是对象或数组，例如 {''lon'':113.531770706177,''lat'':34.818162918091} 或 [113.531770706177,34.818162918091]，当前值为 %',
                p_lng_lat;
        END;

        IF jsonb_typeof(v_lng_lat_json) = 'object' THEN
            IF NOT (v_lng_lat_json ? 'lon') OR NOT (v_lng_lat_json ? 'lat') THEN
                RAISE EXCEPTION '参数错误：经纬度对象必须包含 lon、lat 两个字段，当前值为 %', p_lng_lat;
            END IF;

            BEGIN
                v_lng := (v_lng_lat_json ->> 'lon')::double precision;
                v_lat := (v_lng_lat_json ->> 'lat')::double precision;
            EXCEPTION WHEN others THEN
                RAISE EXCEPTION '参数错误：经纬度对象中的 lon、lat 必须是数字，当前值为 %', p_lng_lat;
            END;
        ELSIF jsonb_typeof(v_lng_lat_json) = 'array' THEN
            IF jsonb_array_length(v_lng_lat_json) <> 2 THEN
                RAISE EXCEPTION '参数错误：经纬度数组必须是 [经度,纬度] 两个元素，当前值为 %', p_lng_lat;
            END IF;

            BEGIN
                v_lng := (v_lng_lat_json ->> 0)::double precision;
                v_lat := (v_lng_lat_json ->> 1)::double precision;
            EXCEPTION WHEN others THEN
                RAISE EXCEPTION '参数错误：经纬度数组中的经度、纬度必须是数字，当前值为 %', p_lng_lat;
            END;
        ELSE
            RAISE EXCEPTION '参数错误：经纬度必须是对象或数组，当前值为 %', p_lng_lat;
        END IF;

        IF v_lng < -180 OR v_lng > 180 THEN
            RAISE EXCEPTION '参数错误：经度必须在 -180 到 180 之间，当前值为 %', v_lng;
        END IF;

        IF v_lat < -90 OR v_lat > 90 THEN
            RAISE EXCEPTION '参数错误：纬度必须在 -90 到 90 之间，当前值为 %', v_lat;
        END IF;

        IF coalesce(p_radius_km, 5) <= 0 THEN
            RAISE EXCEPTION '参数错误：传入经纬度时，半径必须大于 0 公里，当前值为 %', p_radius_km;
        END IF;

        v_radius_m := coalesce(p_radius_km, 5) * 1000.0;
        v_center_geom := ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326);
    END IF;

    -- 3. 按来源拼接查询 SQL。不同来源字段名不同，在这里统一映射返回结构。
    IF v_source = 'gd' THEN
        IF to_regclass(format('%I.%I', 'public', v_gd_table)) IS NULL THEN
            IF v_source = 'gd' THEN
                RAISE EXCEPTION '参数错误：表 public.% 不存在', v_gd_table;
            END IF;
        ELSIF v_radius_m > 0 THEN
            v_sql_parts := array_append(v_sql_parts, format($sql$
                SELECT
                    'gd'::text AS source_platform,
                    p.id::bigint AS id,
                    p.poi_id::text AS poi_id,
                    p.name::text AS name,
                    p.typecode::text AS type_code,
                    p.type::text AS type_name,
                    p.address::text AS address,
                    p.pname::text AS province,
                    p.cityname::text AS city,
                    p.adname::text AS district,
                    ST_X(p.geom)::double precision AS lng,
                    ST_Y(p.geom)::double precision AS lat,
                    p.geom::geometry(Point,4326) AS geom,
                    round((ST_Distance(p.geom::geography, $2::geography) / 1000.0)::numeric, 6)::double precision AS distance_km,
                    (to_jsonb(p) - 'geom') AS raw_data
                FROM public.%I p
                WHERE p.geom IS NOT NULL
                  AND p.name LIKE ('%%' || $1 || '%%')
                  AND ST_DWithin(p.geom::geography, $2::geography, $3)
            $sql$, v_gd_table));
        ELSE
            v_sql_parts := array_append(v_sql_parts, format($sql$
                SELECT
                    'gd'::text AS source_platform,
                    p.id::bigint AS id,
                    p.poi_id::text AS poi_id,
                    p.name::text AS name,
                    p.typecode::text AS type_code,
                    p.type::text AS type_name,
                    p.address::text AS address,
                    p.pname::text AS province,
                    p.cityname::text AS city,
                    p.adname::text AS district,
                    CASE WHEN p.geom IS NULL THEN NULL ELSE ST_X(p.geom)::double precision END AS lng,
                    CASE WHEN p.geom IS NULL THEN NULL ELSE ST_Y(p.geom)::double precision END AS lat,
                    p.geom::geometry(Point,4326) AS geom,
                    0::double precision AS distance_km,
                    (to_jsonb(p) - 'geom') AS raw_data
                FROM public.%I p
                WHERE p.name LIKE ('%%' || $1 || '%%')
            $sql$, v_gd_table));
        END IF;
    END IF;

    IF v_source = 'td' THEN
        IF to_regclass(format('%I.%I', 'public', v_td_table)) IS NULL THEN
            IF v_source = 'td' THEN
                RAISE EXCEPTION '参数错误：表 public.% 不存在', v_td_table;
            END IF;
        ELSIF v_radius_m > 0 THEN
            v_sql_parts := array_append(v_sql_parts, format($sql$
                SELECT
                    'td'::text AS source_platform,
                    p.id::bigint AS id,
                    p.poi_id::text AS poi_id,
                    p.name::text AS name,
                    p.type_code::text AS type_code,
                    p.type_name::text AS type_name,
                    p.address::text AS address,
                    p.province::text AS province,
                    p.city::text AS city,
                    p.district::text AS district,
                    coalesce(p.lng, ST_X(p.geom))::double precision AS lng,
                    coalesce(p.lat, ST_Y(p.geom))::double precision AS lat,
                    p.geom::geometry(Point,4326) AS geom,
                    round((ST_Distance(p.geom::geography, $2::geography) / 1000.0)::numeric, 6)::double precision AS distance_km,
                    (to_jsonb(p) - 'geom') AS raw_data
                FROM public.%I p
                WHERE p.geom IS NOT NULL
                  AND p.name LIKE ('%%' || $1 || '%%')
                  AND ST_DWithin(p.geom::geography, $2::geography, $3)
            $sql$, v_td_table));
        ELSE
            v_sql_parts := array_append(v_sql_parts, format($sql$
                SELECT
                    'td'::text AS source_platform,
                    p.id::bigint AS id,
                    p.poi_id::text AS poi_id,
                    p.name::text AS name,
                    p.type_code::text AS type_code,
                    p.type_name::text AS type_name,
                    p.address::text AS address,
                    p.province::text AS province,
                    p.city::text AS city,
                    p.district::text AS district,
                    coalesce(p.lng, ST_X(p.geom))::double precision AS lng,
                    coalesce(p.lat, ST_Y(p.geom))::double precision AS lat,
                    p.geom::geometry(Point,4326) AS geom,
                    0::double precision AS distance_km,
                    (to_jsonb(p) - 'geom') AS raw_data
                FROM public.%I p
                WHERE p.name LIKE ('%%' || $1 || '%%')
            $sql$, v_td_table));
        END IF;
    END IF;

    IF array_length(v_sql_parts, 1) IS NULL THEN
        RAISE EXCEPTION '参数错误：项目 % 未找到可查询的 POI 表', v_project_id;
    END IF;

    -- 4. 生成最终 SQL、排序并执行。
    v_sql := array_to_string(v_sql_parts, E'\nUNION ALL\n');

    IF v_radius_m > 0 THEN
        v_sql := format(
            'SELECT q.* FROM (%s) q ORDER BY q.distance_km NULLS LAST, q.source_platform, q.id',
            v_sql
        );
    ELSE
        v_sql := format(
            'SELECT q.* FROM (%s) q ORDER BY q.source_platform, q.id',
            v_sql
        );
    END IF;

    IF v_radius_m > 0 THEN
        RETURN QUERY EXECUTE v_sql USING v_name, v_center_geom, v_radius_m;
    ELSE
        RETURN QUERY EXECUTE v_sql USING v_name;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.gis_query_poi(text, text, text, double precision, text) IS '按名称和范围查询兴趣点';

-- ============================================================
-- 调用示例
-- ============================================================

-- 示例 1：默认查询高德，按名称模糊查询。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园'
);

-- 示例 2：显式查询高德，按名称模糊查询。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    NULL,
    NULL,
    'gd'
);

-- 示例 3：查询天地，按名称模糊查询。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    NULL,
    NULL,
    'td'
);

-- 示例 4：查询天地，只传经纬度，不传半径，默认 5 公里。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    '[113.531770706177,34.818162918091]',
    NULL,
    'td'
);

-- 示例 5：按经纬度对象查询高德 1 公里内的 POI。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    '{''lon'':113.531770706177,''lat'':34.818162918091}',
    1,
    'gd'
);

-- 示例 6：按经纬度数组查询天地 2 公里内的 POI。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    '[113.531770706177,34.818162918091]',
    2,
    'td'
);

-- 示例 7：只传经纬度，不传半径，默认查询 5 公里内的高德 POI。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    '{''lon'':113.531770706177,''lat'':34.818162918091}'
);

-- 示例 8：查询高德，半径 3 公里。
SELECT * FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    '{''lon'':113.531770706177,''lat'':34.818162918091}',
    3,
    'gd'
);

-- 示例 9：只取接口常用字段。
SELECT
    source_platform,
    id,
    poi_id,
    name,
    type_name,
    address,
    lng,
    lat,
    distance_km
FROM public.gis_query_poi(
    '2c95908e958f3b75019593551f520126',
    '天健湖公园',
    '[113.531770706177,34.818162918091]',
    3,
    'td'
);

-- 示例 10：错误示例，来源只能是 gd、td。
-- SELECT * FROM public.gis_query_poi(
--     '2c95908e958f3b75019593551f520126',
--     '天健湖公园',
--     '[113.531770706177,34.818162918091]',
--     3,
--     'amap'
-- );
