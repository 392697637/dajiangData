-- ==================================================gis_electric_fence_project动态创建项目专属电子围栏表======================================================
-- 删除函数
DROP FUNCTION IF EXISTS gis_electric_fence_project(text, text);
-- ============================================================
-- 函数名称： gis_electric_fence_project
-- 函数功能： 动态创建项目专属电子围栏表，并自动导入相交的禁飞区、试飞区数据
-- 函数描述： 1. 根据传入项目ID，自动创建电子围栏独立表
--            2. 自动抽取与项目地理范围相交的禁飞区、各省试飞区数据
--            3. 兼容源表字段缺失，不会因字段不存在报错
--            4. 保留完整原始几何，不做相交裁剪，只做相交筛选
--            5. 返回统一标准结果集，方便前端/业务系统直接使用
-- 函数说明： 依赖PostGIS空间扩展，坐标系使用WGS84(4326)
-- 参数说明：
--   p_project_id    text        输入参数：项目唯一ID（用于生成表名）
--   p_geom_json     text        输入参数：项目范围的GeoJSON多边形字符串
-- 返回值： 标准TABLE结构
--   code        integer     状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg         varchar     状态描述信息
--   tablename   varchar     生成的项目电子围栏表名
--   count       bigint      导入围栏数据总条数
-- 函数注意：
--   1. 依赖基础表：wrj_jfq_dj（禁飞区）、jc_sheng（省份）、各省试飞区表
--   2. 空间判断使用ST_Intersects，仅筛选相交，保留完整原始几何
--   3. 每次执行会先删除旧表再重建，保证数据最新
--   4. 自动创建空间索引，提升查询效率
-- 适用场景： 按项目生成独立电子围栏库，用于无人机飞行区域合规校验
-- ============================================================
CREATE OR REPLACE FUNCTION gis_electric_fence_project(
    p_project_id text,  -- 输入：项目唯一ID
    p_geom_json text    -- 输入：项目范围GeoJSON字符串
)
RETURNS TABLE (
    code integer,       -- 返回：状态码
    msg varchar,        -- 返回：状态信息
    tablename varchar,  -- 返回：生成的表名
    count bigint        -- 返回：数据条数
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- 说明：
    -- 1. 本函数按项目ID动态生成一张独立电子围栏表，表名规则为 gis_electric_fence_{项目ID}。
    -- 2. 查询数据来源包含固定禁飞区表 wrj_jfq_dj，以及项目范围相交省份对应的试飞区表。
    -- 3. 源表字段可能不完全一致，下面通过 information_schema.columns 判断字段是否存在，缺失字段统一补 NULL。
    -- 4. 动态对象名统一使用 format('%I', ...) 拼接，避免表名、索引名等标识符注入风险。
    v_target_table text := 'gis_electric_fence_' || p_project_id;  -- 最终生成的项目电子围栏表名
    v_geom geometry;                                               -- 存储解析后的项目范围空间几何对象
    v_sql text := '';                                              -- 动态拼接的查询/插入SQL语句
    v_index_name text;                                             -- 动态生成的空间索引名
    v_table_suffix text;                                           -- 循环中：省份试飞区表名后缀
    v_row_count BIGINT := 0;                                       -- 插入数据的总行数
    v_columns text[];                                              -- 存储源表的字段名数组
BEGIN
    -- =============================================
    -- 第一步：必填参数合法性校验
    -- =============================================
    -- 判断项目ID和GeoJSON是否为空
    IF p_project_id IS NULL OR p_project_id = '' OR p_geom_json IS NULL OR p_geom_json = '' THEN
        -- 为空则返回参数错误
        RETURN QUERY SELECT 400, '项目ID或地理范围GeoJSON不能为空'::varchar, ''::varchar, 0::bigint;
        RETURN;
    END IF;

    -- =============================================
    -- 第二步：解析项目范围GeoJSON
    -- =============================================
    BEGIN
        -- 将GeoJSON字符串转为几何对象，并设置坐标系为WGS84(4326)
        v_geom := ST_SetSRID(ST_GeomFromGeoJSON(p_geom_json), 4326);
    -- 捕获GeoJSON解析异常
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 400, ('GeoJSON格式错误：' || SQLERRM)::varchar, ''::varchar, 0::bigint;
        RETURN;
    END;

    -- =============================================
    -- 第三步：删除已存在的旧表
    -- =============================================
    -- 安全删除已存在的项目围栏表，避免冲突
    EXECUTE format('DROP TABLE IF EXISTS %I', v_target_table);

    -- =============================================
    -- 第四步：创建全新的项目电子围栏表
    -- =============================================
    -- 创建标准结构的电子围栏表
    -- 注意：geom统一使用4326坐标系；area保存基于geography计算的平方米面积。
    -- fence_type用于区分围栏来源类型：1=禁飞区，3=试飞区。
    EXECUTE format('
        CREATE TABLE %I (
            id             BIGSERIAL PRIMARY KEY,  -- 自增主键
            area_id        integer,                -- 区域ID
            name           varchar(254),           -- 名称
            lat            float8,                 -- 中心点纬度
            lng            float8,                 -- 中心点经度
            radius         float8,                 -- 半径
            fence_type     varchar(254),           -- 围栏类型（修改为蛇形命名）
            level          float8,                 -- 等级
            color          varchar(254),           -- 颜色
            city           varchar(254),           -- 城市
            address        varchar(254),           -- 地址
            description    varchar(254),           -- 描述
            height         float8,                 -- 高度
            begin_at       float8,                 -- 开始时间
            end_at         float8,                 -- 结束时间
            create_time    timestamptz DEFAULT now(), -- 创建时间，默认当前时间
            area           numeric,                -- 面积
            geom           geometry(Geometry, 4326) -- 空间几何对象
        )', v_target_table);

    -- =============================================
    -- 第五步：创建geom空间索引
    -- =============================================
    -- 为geom字段创建GIST空间索引，提升空间查询效率
    -- 注意：%I必须包裹完整标识符，不能写成 idx_%I_geom，否则会生成 idx_"表名"_geom 这类非法SQL。
    v_index_name := 'idx_' || v_target_table || '_geom';
    EXECUTE format('CREATE INDEX %I ON %I USING GIST (geom)', v_index_name, v_target_table);

    -- =============================================
    -- 第六步：获取禁飞区表字段
    -- =============================================
    -- 查询禁飞区表wrj_jfq_dj的所有字段名，存入数组
    -- 后续拼接SELECT时会基于该数组决定取真实字段，还是补类型明确的NULL。
    SELECT array_agg(column_name) INTO v_columns
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'wrj_jfq_dj';

    -- =============================================
    -- 第七步：拼接禁飞区查询SQL
    -- =============================================
    -- 动态拼接禁飞区查询SQL，兼容字段不存在自动补NULL
    -- 这里先生成基础SELECT，不立即执行；最终会作为INSERT INTO ... SELECT ...的一部分写入项目表。
    -- WHERE ST_Intersects(geom, $1) 中的 $1 由 EXECUTE ... USING v_geom 绑定，避免把GeoJSON文本直接拼进SQL。
    v_sql := format('
        SELECT
            gid::integer AS area_id,             -- 区域ID
            name,                                -- 名称
            ST_Y(ST_Centroid(geom)) AS lat,      -- 几何中心点纬度
            ST_X(ST_Centroid(geom)) AS lng,      -- 几何中心点经度
            %s AS radius,                        -- 半径（兼容字段）
            ''1'' AS fence_type,                 -- 围栏类型：1=禁飞区
            %s AS level,                         -- 等级（兼容字段）
            %s AS color,                         -- 颜色（兼容字段）
            %s AS city,                          -- 城市（兼容字段）
            %s AS address,                       -- 地址（兼容字段）
            %s AS description,                   -- 描述（兼容字段）
            %s AS height,                        -- 高度（兼容字段）
            %s AS begin_at,                      -- 开始时间（兼容字段）
            %s AS end_at,                        -- 结束时间（兼容字段）
            now() AS create_time,                -- 创建时间
            ST_Area(geom::geography) AS area,    -- 地理面积（平方米）
            geom                                 -- 空间几何
        FROM wrj_jfq_dj
        WHERE ST_Intersects(geom, $1)',          -- 空间相交筛选条件

        -- 判断字段是否存在，存在则取字段，不存在则置NULL
        -- 每个NULL都显式转换类型，保证UNION ALL各分支字段类型一致，避免PostgreSQL类型推断错误。
        CASE WHEN 'radius' = ANY(v_columns) THEN 'radius' ELSE 'NULL::float8' END,
        CASE WHEN 'level'   = ANY(v_columns) THEN '"level"' ELSE 'NULL::float8' END,
        CASE WHEN 'color'   = ANY(v_columns) THEN 'color' ELSE 'NULL::varchar(254)' END,
        CASE WHEN 'city'    = ANY(v_columns) THEN 'city' ELSE 'NULL::varchar(254)' END,
        CASE WHEN 'address' = ANY(v_columns) THEN 'address' ELSE 'NULL::varchar(254)' END,
        CASE WHEN 'descriptio' = ANY(v_columns) THEN 'descriptio'
             WHEN 'description' = ANY(v_columns) THEN 'description'
             ELSE 'NULL::varchar(254)' END,
        CASE WHEN 'height'   = ANY(v_columns) THEN 'height' ELSE 'NULL::float8' END,
        CASE WHEN 'begin_at' = ANY(v_columns) THEN 'begin_at' ELSE 'NULL::float8' END,
        CASE WHEN 'end_at'   = ANY(v_columns) THEN 'end_at' ELSE 'NULL::float8' END
    );

    -- =============================================
    -- 第八步：遍历省份试飞区表
    -- =============================================
    -- 循环查询与项目范围相交的省份，并获取对应的试飞区表名
    -- jc_sheng.wrj_sfky_table保存省份试飞区表名；只处理与项目范围相交且表名非空的省份。
    FOR v_table_suffix IN
        SELECT DISTINCT "wrj_sfky_table"
        FROM jc_sheng
        WHERE ST_Intersects(geom, v_geom)
          AND "wrj_sfky_table" IS NOT NULL AND "wrj_sfky_table" != ''
    LOOP
        -- 获取当前试飞区表的所有字段
        -- 不同省份试飞区表结构可能不一致，因此每次循环都重新读取字段列表。
        SELECT array_agg(column_name) INTO v_columns
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = v_table_suffix;

        -- 拼接UNION ALL，追加试飞区数据，fence_type=3
        -- 使用%I安全引用试飞区表名；空间筛选仍复用同一个$1项目范围几何。
        v_sql := v_sql || format('
            UNION ALL
            SELECT
                id::integer AS area_id,             -- 区域ID
                name,                                -- 名称
                ST_Y(ST_Centroid(geom)) AS lat,      -- 中心点纬度
                ST_X(ST_Centroid(geom)) AS lng,      -- 中心点经度
                %s AS radius,                        -- 半径（兼容字段）
                ''3'' AS fence_type,                 -- 围栏类型：3=试飞区
                %s AS level,                         -- 等级（兼容字段）
                %s AS color,                         -- 颜色（兼容字段）
                %s AS city,                          -- 城市（兼容字段）
                %s AS address,                       -- 地址（兼容字段）
                %s AS description,                   -- 描述（兼容字段）
                %s AS height,                        -- 高度（兼容字段）
                %s AS begin_at,                      -- 开始时间（兼容字段）
                %s AS end_at,                        -- 结束时间（兼容字段）
                now() AS create_time,                -- 创建时间
                ST_Area(geom::geography) AS area,    -- 面积
                geom                                 -- 空间几何
            FROM %I
            WHERE ST_Intersects(geom, $1)',         -- 相交筛选

            CASE WHEN 'radius' = ANY(v_columns) THEN 'radius' ELSE 'NULL::float8' END,
            CASE WHEN 'level'   = ANY(v_columns) THEN '"level"' ELSE 'NULL::float8' END,
            CASE WHEN 'color'   = ANY(v_columns) THEN 'color' ELSE 'NULL::varchar(254)' END,
            CASE WHEN 'city'    = ANY(v_columns) THEN 'city' ELSE 'NULL::varchar(254)' END,
            CASE WHEN 'address' = ANY(v_columns) THEN 'address' ELSE 'NULL::varchar(254)' END,
            CASE WHEN 'descriptio' = ANY(v_columns) THEN 'descriptio'
                 WHEN 'description' = ANY(v_columns) THEN 'description'
                 ELSE 'NULL::varchar(254)' END,
            CASE WHEN 'height'   = ANY(v_columns) THEN 'height' ELSE 'NULL::float8' END,
            CASE WHEN 'begin_at' = ANY(v_columns) THEN 'begin_at' ELSE 'NULL::float8' END,
            CASE WHEN 'end_at'   = ANY(v_columns) THEN 'end_at' ELSE 'NULL::float8' END,
            v_table_suffix
        );
    END LOOP;

    -- =============================================
    -- 第九步：执行插入数据
    -- =============================================
    -- 如果拼接的SQL不为空，则执行插入
    IF v_sql <> '' THEN
        -- 执行INSERT，把查询到的禁飞区+试飞区数据写入项目表
        -- INSERT列顺序必须与上方动态SELECT输出列顺序保持一致。
        EXECUTE format('
            INSERT INTO %I (
                area_id, name, lat, lng, radius, fence_type, level,
                color, city, address, description, height, begin_at, end_at, create_time, area, geom
            ) %s', v_target_table, v_sql
        ) USING v_geom;  -- 传入项目范围几何对象
        -- 获取实际插入的行数
        -- ROW_COUNT返回本次INSERT写入项目电子围栏表的总记录数。
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
    END IF;

    -- =============================================
    -- 第十步：返回结果
    -- =============================================
    -- 根据插入行数返回成功或无数据
    IF v_row_count > 0 THEN
        RETURN QUERY SELECT 200, '执行成功，电子围栏已生成'::varchar, v_target_table::varchar, v_row_count;
    ELSE
        RETURN QUERY SELECT 400, '未查询到相交电子围栏数据'::varchar, v_target_table::varchar, 0::bigint;
    END IF;

-- =============================================
-- 异常捕获
-- =============================================
-- 捕获所有未处理异常，返回500错误
EXCEPTION WHEN OTHERS THEN
    -- 兜底异常处理：保留数据库原始错误信息，便于接口调用方定位失败原因。
    RETURN QUERY SELECT 500, ('执行异常：' || SQLERRM)::varchar, v_target_table::varchar, 0::bigint;
END;
$$;
-- ============================================================
-- 函数名称： gis_electric_fence_project
-- 函数功能： 动态创建项目专属电子围栏表，并自动导入相交的禁飞区、试飞区数据
-- 参数说明：
--   p_project_id    text        输入参数：项目唯一ID（用于生成表名）
--   p_geom_json     text        输入参数：项目范围的GeoJSON多边形字符串
-- 返回值： 标准TABLE结构
--   code        integer     状态码：200=执行成功 400=参数错误/无数据 500=执行异常
--   msg         varchar     状态描述信息
--   tablename   varchar     生成的项目电子围栏表名
--   count       bigint      导入围栏数据总条数
-- ============================================================
 
SELECT gis_electric_fence_project(
    'zhengzhou_demo', 
    '{"type":"Polygon","coordinates":[[[113.0,34.5],[114.0,34.5],[114.0,35.0],[113.0,35.0],[113.0,34.5]]]}'
);

-- 示例：按真实项目ID创建项目电子围栏表，并返回创建结果。
SELECT* FROM gis_electric_fence_project(
    '2c95908e958f3b75019593551f520126', --  输入参数：项目唯一ID（用于生成表名）
    '{"type":"Polygon","coordinates":[[[113.0,34.5],[114.0,34.5],[114.0,35.0],[113.0,35.0],[113.0,34.5]]]}'  -- 输入参数：项目范围的GeoJSON多边形字符串
);

------------------------------------------------------------------------------geoserver 自动调用项目服务------------------------------------------------------
 
-- =============================================
-- 函数名称：gis_get_electric_fence_project
-- 函数功能：根据项目ID + 围栏类型，动态查询项目电子围栏数据
-- 函数描述：
--    1. 仅当 fence_type = 1、2、3 时进行筛选
--    2. 传入其他值、空、NULL 都返回全部数据
--    3. 动态表名，安全防SQL注入
-- 适用场景：GeoServer 调用、项目独立电子围栏表
-- 依赖插件：PostGIS
-- 参数说明：
--    p_project_id    项目ID（必填）
--    p_fence_type    围栏类型：1/2/3 筛选，其他全部
-- =============================================
DROP FUNCTION IF EXISTS gis_get_electric_fence_project(text, text); 

CREATE OR REPLACE FUNCTION gis_get_electric_fence_project(
    p_project_id TEXT,                                   -- 入参1：项目ID，用于拼接动态表名
    p_fence_type TEXT DEFAULT NULL                       -- 入参2：1/2/3筛选，其他全部
)
RETURNS TABLE (                                          -- 定义返回结果集字段
    area_id        INTEGER,
    name           VARCHAR(254),
    lat            FLOAT8,
    lng            FLOAT8,
    radius         FLOAT8,
    fenceType      VARCHAR(254),                         -- 接口返回字段名，来自表字段 fence_type
    level          FLOAT8,
    color          VARCHAR(254),
    city           VARCHAR(254),
    address        VARCHAR(254),
    description    VARCHAR(254),
    height         FLOAT8,
    begin_at       FLOAT8,
    end_at       FLOAT8,
    create_time    TIMESTAMPTZ,
    area           NUMERIC,
    geom           GEOMETRY
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- GeoServer调用时只需要传项目ID和可选围栏类型，本函数负责定位对应的项目独立表。
    -- 表名使用format('%I')引用，围栏类型值使用format('%L')引用，分别处理标识符和值的转义。
    v_table_name TEXT := 'gis_electric_fence_' || p_project_id;  -- 动态拼接项目表名
    v_sql TEXT;                                                  -- 动态SQL语句
BEGIN
    -- 构建基础查询SQL
    -- 默认返回项目电子围栏表中的全部记录。
    -- 项目表中的真实字段为 fence_type；这里通过 AS "fenceType" 转为接口需要的驼峰字段名。
    v_sql := format('
        SELECT 
            area_id, name, lat, lng, radius, fence_type AS "fenceType", level, color,
            city, address, description, height, begin_at, end_at,
            create_time, area, geom
        FROM %I ', v_table_name);

    -- =============================================
    -- 关键修改：只有 1、2、3 才加 WHERE 条件
    -- 其他所有情况（空、NULL、非法值）都返回全部
    -- =============================================
    IF p_fence_type IN ('1', '2', '3') THEN
        -- 仅白名单类型参与筛选，避免非法类型造成空数据或拼接风险。
        -- WHERE条件必须使用表内真实字段 fence_type，不能使用SELECT别名 fenceType。
        v_sql := v_sql || format(' WHERE fence_type = %L ', p_fence_type);
    END IF;

    -- 执行动态SQL并返回结果
    -- RETURN QUERY EXECUTE会把动态查询结果映射到RETURNS TABLE定义的字段。
    RETURN QUERY EXECUTE v_sql;
END;
$$;

-- =============================================
-- 函数调用示例
-- 功能：查询项目ID为 taiyuan_demo 的电子围栏数据
-- 注意：实际调用时不需要 %%，直接传项目ID
-- =============================================
-- PG库调用
SELECT * FROM gis_get_electric_fence_project('%project_id%', '%fence_type%');


-- 查询全部围栏数据。
SELECT * FROM gis_get_electric_fence_project('zhengzhou_demo');
-- 第二个参数传NULL时不按围栏类型过滤。
SELECT * FROM gis_get_electric_fence_project('2c95908e958f3b75019593551f520126', NULL);
