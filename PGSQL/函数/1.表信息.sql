-- ==============================================
-- PostgreSQL + PostGIS 无人机GIS系统 表结构脚本
-- 顺序说明：
-- 1. 三维网格节点表模板：系统空间计算底座
-- 2. 网格打标数据源：按 block_mask 顺序排列
--    1=电子围栏，2=建筑，4=地形，8=倾斜摄影，16=DEM，32=国家空域规则
-- 3. 正射/DOM：展示与辅助判读数据，不直接作为高度来源
-- 4. 飞行路径记录表：路径规划结果表
--
-- 项目表规则：
--   除 gis_flight_paths 飞行记录表外，其他表均为“一个项目一张表”。
--   本文件中的 *_template 表仅作为结构模板，不作为正式业务数据表。
--   实际项目表名由项目ID拼接生成，例如：
--     gis_grid_nodes_<project_id>
--     gis_buildings_<project_id>
--     gis_terrain_features_<project_id>
--     gis_oblique_models_<project_id>
--     gis_dem_sources_<project_id>
--     gis_dem_points_<project_id>
--     gis_dom_sources_<project_id>
-- ==============================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;


-- ====================================================================================
-- 1. 三维网格节点表模板 gis_grid_nodes_template
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_xyz;
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_flyable_xyz;
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_flyable_xy;
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_zone_type;
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_block_mask;
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_geom2d;
DROP INDEX IF EXISTS idx_gis_grid_nodes_template_geom;
DROP TABLE IF EXISTS gis_grid_nodes_template CASCADE;

CREATE UNLOGGED TABLE IF NOT EXISTS gis_grid_nodes_template (
    id BIGINT PRIMARY KEY,
    x INT NOT NULL,
    y INT NOT NULL,
    z INT NOT NULL,
    lon DOUBLE PRECISION,
    lat DOUBLE PRECISION,
    alt DOUBLE PRECISION,

    -- A*路径规划优先使用的综合可飞状态
    is_flyable BOOLEAN DEFAULT true NOT NULL,

    -- 电子围栏兼容字段
    zone_type VARCHAR(20) DEFAULT NULL,

    -- 多源阻塞位：1电子围栏，2建筑，4地形，8倾斜摄影，16 DEM，32国家空域规则
    block_mask INT DEFAULT 0 NOT NULL,

    -- 空间字段
    geom2d geometry(Point,4326),
    geom geometry(PointZ,4326)
) WITH (autovacuum_enabled = on);

COMMENT ON TABLE gis_grid_nodes_template IS '三维网格节点表模板：实际项目表名为 gis_grid_nodes_<project_id>';
COMMENT ON COLUMN gis_grid_nodes_template.id IS '网格节点主键ID，按x/y/z计算生成';
COMMENT ON COLUMN gis_grid_nodes_template.x IS '网格X索引，经度方向';
COMMENT ON COLUMN gis_grid_nodes_template.y IS '网格Y索引，纬度方向';
COMMENT ON COLUMN gis_grid_nodes_template.z IS '网格Z索引，高度方向';
COMMENT ON COLUMN gis_grid_nodes_template.lon IS '经度';
COMMENT ON COLUMN gis_grid_nodes_template.lat IS '纬度';
COMMENT ON COLUMN gis_grid_nodes_template.alt IS '绝对高度或当前系统统一高度基准，单位：米';
COMMENT ON COLUMN gis_grid_nodes_template.is_flyable IS '是否可飞：true=可参与路径规划，false=不可通行';
COMMENT ON COLUMN gis_grid_nodes_template.zone_type IS '电子围栏区域类型：禁飞区/管控区/适飞区';
COMMENT ON COLUMN gis_grid_nodes_template.block_mask IS '阻塞位标记：1电子围栏，2建筑，4地形，8倾斜摄影，16 DEM，32国家空域规则';
COMMENT ON COLUMN gis_grid_nodes_template.geom2d IS '二维空间点，WGS84经纬度坐标系';
COMMENT ON COLUMN gis_grid_nodes_template.geom IS '三维空间点，WGS84经纬度坐标系 + 高度';

-- 网格唯一坐标索引，保证同一个 x/y/z 只存在一个节点，同时加速邻居查询。
CREATE UNIQUE INDEX IF NOT EXISTS idx_gis_grid_nodes_template_xyz ON gis_grid_nodes_template (x, y, z);
COMMENT ON INDEX idx_gis_grid_nodes_template_xyz IS '网格三维索引唯一约束，加速A*邻居节点查询';

-- 仅索引可飞节点，A*搜索时减少索引体积和扫描范围。
CREATE INDEX IF NOT EXISTS idx_gis_grid_nodes_template_flyable_xyz ON gis_grid_nodes_template (x, y, z) WHERE is_flyable = true;
COMMENT ON INDEX idx_gis_grid_nodes_template_flyable_xyz IS '可飞网格三维局部索引，用于A*可通行节点查询';

-- 二维可飞范围索引，用于按 x/y 裁剪搜索区域。
CREATE INDEX IF NOT EXISTS idx_gis_grid_nodes_template_flyable_xy ON gis_grid_nodes_template (x, y) WHERE is_flyable = true;
COMMENT ON INDEX idx_gis_grid_nodes_template_flyable_xy IS '可飞网格二维局部索引，用于路径规划范围裁剪';

-- 多源阻塞位索引，仅索引被阻塞的网格，降低大表建索引成本。
CREATE INDEX IF NOT EXISTS idx_gis_grid_nodes_template_block_mask ON gis_grid_nodes_template (block_mask) WHERE block_mask <> 0;
COMMENT ON INDEX idx_gis_grid_nodes_template_block_mask IS '多源阻塞位索引，用于查询电子围栏/建筑/地形/倾斜摄影/DEM打标结果';

-- 二维点空间索引只建 z=0 层，电子围栏/建筑等二维叠加先算平面命中，再回填高度层。
CREATE INDEX IF NOT EXISTS idx_gis_grid_nodes_template_geom2d ON gis_grid_nodes_template USING GIST (geom2d) WHERE z = 0;
COMMENT ON INDEX idx_gis_grid_nodes_template_geom2d IS '二维网格点空间索引，用于面内判断和二维空间叠加分析';


-- ====================================================================================
-- 2. block_mask=1 电子围栏/国家空域规则表 bo_electric_fence（先注释）
-- 说明：
--   1. 用于业务电子围栏、国家/监管禁飞区、管控区、试飞区/适飞区统一入库。
--   2. 国家/监管来源的数据建议 source_level='国家' 或 '监管'，rule_priority 设置更高。
--   3. 规则优先级建议：国家禁飞区 > 监管管控区 > 建筑/地形硬障碍 > 项目禁飞区 > 项目管控区 > 试飞区/适飞区。
--   4. 因当前库中可能已经存在 bo_electric_fence，以下建表语句先保持注释，避免覆盖业务表。
-- ====================================================================================
-- CREATE TABLE IF NOT EXISTS bo_electric_fence (
--     id varchar(32) PRIMARY KEY,
--     project_id varchar(32),
--     create_user varchar(32),
--     create_time timestamp NOT NULL DEFAULT NOW(),
--     update_user varchar(32),
--     update_time timestamp NOT NULL DEFAULT NOW(),
--     del_flag boolean NOT NULL DEFAULT false,
--     name varchar(200),
--     code varchar(255),
--     status varchar(32),
--     fence_type varchar(20) NOT NULL,
--     fence_name varchar(50),
--     airspace_class varchar(50),
--     source_level varchar(20) DEFAULT '项目',
--     source_org varchar(100),
--     source_doc varchar(500),
--     rule_priority smallint DEFAULT 50,
--     min_alt double precision DEFAULT 0,
--     max_alt double precision,
--     height double precision,
--     effective_start timestamp,
--     effective_end timestamp,
--     time_plan varchar(4000),
--     remark varchar(1000),
--     geom geometry(Geometry,4326),
--     geom_3d geometry(GeometryZ,4326)
-- );
--
-- COMMENT ON TABLE bo_electric_fence IS '电子围栏/国家空域规则表：禁飞区、管控区、试飞区、适飞区等';
-- COMMENT ON COLUMN bo_electric_fence.fence_type IS '围栏类型：1=禁飞区，2=管控区，3=试飞区/适飞区，4=警示区';
-- COMMENT ON COLUMN bo_electric_fence.airspace_class IS '空域分类：国家禁飞区/临时禁飞区/管控区/试飞区/适飞区/警示区等';
-- COMMENT ON COLUMN bo_electric_fence.source_level IS '规则来源级别：国家/监管/省级/市级/项目';
-- COMMENT ON COLUMN bo_electric_fence.source_org IS '规则发布或维护单位';
-- COMMENT ON COLUMN bo_electric_fence.source_doc IS '规则来源文件、公告、批复或数据版本说明';
-- COMMENT ON COLUMN bo_electric_fence.rule_priority IS '规则优先级，数值越小优先级越高；国家禁飞区建议为1';
-- COMMENT ON COLUMN bo_electric_fence.min_alt IS '规则生效最低高度，单位：米';
-- COMMENT ON COLUMN bo_electric_fence.max_alt IS '规则生效最高高度，单位：米';
-- COMMENT ON COLUMN bo_electric_fence.geom IS '二维空域范围，WGS84坐标系';
-- COMMENT ON COLUMN bo_electric_fence.geom_3d IS '三维空域几何，可选';
--
-- CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_project_del ON bo_electric_fence (project_id, del_flag);
-- COMMENT ON INDEX idx_bo_electric_fence_project_del IS '按项目和删除标识筛选电子围栏';
-- CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_type_priority ON bo_electric_fence (fence_type, rule_priority);
-- COMMENT ON INDEX idx_bo_electric_fence_type_priority IS '按围栏类型和规则优先级筛选空域规则';
-- CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_source_level ON bo_electric_fence (source_level);
-- COMMENT ON INDEX idx_bo_electric_fence_source_level IS '按国家/监管/项目等规则来源级别筛选';
-- CREATE INDEX IF NOT EXISTS idx_bo_electric_fence_geom ON bo_electric_fence USING GIST (geom);
-- COMMENT ON INDEX idx_bo_electric_fence_geom IS '电子围栏二维空间索引，用于网格打标和路径相交检查';


-- ====================================================================================
-- 3. block_mask=2 建筑模型表 gis_buildings_template
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_buildings_template_geom;
DROP INDEX IF EXISTS idx_gis_buildings_template_geom3d;
DROP INDEX IF EXISTS idx_gis_buildings_template_id;
DROP TABLE IF EXISTS gis_buildings_template CASCADE;

CREATE TABLE IF NOT EXISTS gis_buildings_template (
    gid int4 NOT NULL GENERATED BY DEFAULT AS IDENTITY,
    merged_id float8,
    height numeric,
    function varchar(80) COLLATE "pg_catalog"."default",
    age varchar(80) COLLATE "pg_catalog"."default",
    quality varchar(80) COLLATE "pg_catalog"."default",
    geom geometry(MULTIPOLYGONZ,4326),
    id int4,
    geom3d geometry(MULTIPOLYGONZ,4326),
    CONSTRAINT gis_buildings_template_pkey PRIMARY KEY (gid),
    CONSTRAINT gis_buildings_template_id_key UNIQUE (id)
);

-- 如部署环境存在 zhuoyi 角色，可按需打开：
-- ALTER TABLE public.gis_buildings_<project_id> OWNER TO zhuoyi;

COMMENT ON TABLE gis_buildings_template IS '建筑模型表模板：实际项目表名为 gis_buildings_<project_id>，用于网格建筑障碍打标';
COMMENT ON COLUMN gis_buildings_template.gid IS '建筑表主键，自增ID';
COMMENT ON COLUMN gis_buildings_template.merged_id IS '合并建筑ID或外部合并标识';
COMMENT ON COLUMN gis_buildings_template.height IS '建筑高度，单位：米';
COMMENT ON COLUMN gis_buildings_template.function IS '建筑功能类型';
COMMENT ON COLUMN gis_buildings_template.age IS '建筑年代';
COMMENT ON COLUMN gis_buildings_template.quality IS '建筑质量等级';
COMMENT ON COLUMN gis_buildings_template.geom IS '建筑三维面几何，MULTIPOLYGONZ，SRID=4326';
COMMENT ON COLUMN gis_buildings_template.id IS '业务建筑ID，保持唯一';
COMMENT ON COLUMN gis_buildings_template.geom3d IS '建筑三维体块几何，MULTIPOLYGONZ，SRID=4326';

-- 建筑原始三维轮廓空间索引，用于网格点与建筑轮廓叠加判断。
CREATE INDEX IF NOT EXISTS idx_gis_buildings_template_geom ON gis_buildings_template USING GIST (geom gist_geometry_ops_2d);
COMMENT ON INDEX idx_gis_buildings_template_geom IS '建筑geom空间索引，用于建筑轮廓与网格点二维叠加';

-- 建筑三维体块空间索引，用于后续建筑体块相交判断。
CREATE INDEX IF NOT EXISTS idx_gis_buildings_template_geom3d ON gis_buildings_template USING GIST (geom3d gist_geometry_ops_2d);
COMMENT ON INDEX idx_gis_buildings_template_geom3d IS '建筑geom3d空间索引，用于建筑三维体块空间检索';

-- 业务建筑ID索引，用于按外部ID关联和更新建筑。
CREATE INDEX IF NOT EXISTS idx_gis_buildings_template_id ON gis_buildings_template (id);
COMMENT ON INDEX idx_gis_buildings_template_id IS '建筑业务ID索引，用于按id关联、更新和去重';


-- ====================================================================================
-- 4. block_mask=4 地形/地物障碍表 gis_terrain_features_template
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_terrain_template_project_del;
DROP INDEX IF EXISTS idx_gis_terrain_template_risk;
DROP INDEX IF EXISTS idx_gis_terrain_template_geom;
DROP TABLE IF EXISTS gis_terrain_features_template CASCADE;

CREATE TABLE IF NOT EXISTS gis_terrain_features_template (
    id varchar(64) PRIMARY KEY,
    project_id varchar(32),
    name varchar(200),
    terrain_type varchar(50),
    source_level varchar(20) DEFAULT '项目',
    data_source varchar(100),
    min_alt double precision,
    max_alt double precision,
    risk_level smallint DEFAULT 3,
    is_obstacle boolean NOT NULL DEFAULT false,
    del_flag boolean NOT NULL DEFAULT false,
    create_time timestamp NOT NULL DEFAULT NOW(),
    update_time timestamp NOT NULL DEFAULT NOW(),
    attrs jsonb DEFAULT '{}'::jsonb NOT NULL,
    geom geometry(Geometry,4326)
);

COMMENT ON TABLE gis_terrain_features_template IS '地形/地物障碍表模板：实际项目表名为 gis_terrain_features_<project_id>';
COMMENT ON COLUMN gis_terrain_features_template.terrain_type IS '地形/地物类型：山体/水域/林地/高压线走廊/施工区等';
COMMENT ON COLUMN gis_terrain_features_template.min_alt IS '影响最低高度，单位：米';
COMMENT ON COLUMN gis_terrain_features_template.max_alt IS '影响最高高度，单位：米';
COMMENT ON COLUMN gis_terrain_features_template.is_obstacle IS '是否作为硬障碍参与不可飞打标';
COMMENT ON COLUMN gis_terrain_features_template.geom IS '地形/地物空间范围';

-- 项目地形数据过滤。
CREATE INDEX IF NOT EXISTS idx_gis_terrain_template_project_del ON gis_terrain_features_template (project_id, del_flag);
COMMENT ON INDEX idx_gis_terrain_template_project_del IS '按项目和删除标识筛选地形/地物数据';

-- 风险和障碍筛选。
CREATE INDEX IF NOT EXISTS idx_gis_terrain_template_risk ON gis_terrain_features_template (project_id, is_obstacle, risk_level) WHERE del_flag = false;
COMMENT ON INDEX idx_gis_terrain_template_risk IS '按障碍标识和风险等级筛选地形/地物数据';

-- 地形/地物空间索引。
CREATE INDEX IF NOT EXISTS idx_gis_terrain_template_geom ON gis_terrain_features_template USING GIST (geom);
COMMENT ON INDEX idx_gis_terrain_template_geom IS '地形/地物空间索引，用于网格叠加打标';


-- ====================================================================================
-- 5. block_mask=8 倾斜摄影模型表 gis_oblique_models_template
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_oblique_template_project_del;
DROP INDEX IF EXISTS idx_gis_oblique_template_risk;
DROP INDEX IF EXISTS idx_gis_oblique_template_footprint;
DROP INDEX IF EXISTS idx_gis_oblique_template_bbox;
DROP TABLE IF EXISTS gis_oblique_models_template CASCADE;

CREATE TABLE IF NOT EXISTS gis_oblique_models_template (
    id varchar(64) PRIMARY KEY,
    project_id varchar(32),
    name varchar(200),
    model_url varchar(1000),
    tileset_url varchar(1000),
    data_source varchar(100),
    source_level varchar(20) DEFAULT '项目',
    min_alt double precision,
    max_alt double precision,
    risk_level smallint DEFAULT 2,
    is_obstacle boolean NOT NULL DEFAULT false,
    del_flag boolean NOT NULL DEFAULT false,
    create_time timestamp NOT NULL DEFAULT NOW(),
    update_time timestamp NOT NULL DEFAULT NOW(),
    transform jsonb DEFAULT '{}'::jsonb NOT NULL,
    attrs jsonb DEFAULT '{}'::jsonb NOT NULL,
    footprint geometry(Geometry,4326),
    bbox geometry(Polygon,4326)
);

COMMENT ON TABLE gis_oblique_models_template IS '倾斜摄影模型表模板：实际项目表名为 gis_oblique_models_<project_id>';
COMMENT ON COLUMN gis_oblique_models_template.footprint IS '倾斜摄影模型精确覆盖范围';
COMMENT ON COLUMN gis_oblique_models_template.bbox IS '倾斜摄影模型外接范围，用于快速预筛选';
COMMENT ON COLUMN gis_oblique_models_template.min_alt IS '模型影响最低高度，单位：米';
COMMENT ON COLUMN gis_oblique_models_template.max_alt IS '模型影响最高高度，单位：米';
COMMENT ON COLUMN gis_oblique_models_template.transform IS '模型姿态、偏移、缩放等转换参数';

-- 项目倾斜模型列表过滤。
CREATE INDEX IF NOT EXISTS idx_gis_oblique_template_project_del ON gis_oblique_models_template (project_id, del_flag);
COMMENT ON INDEX idx_gis_oblique_template_project_del IS '按项目和删除标识筛选倾斜摄影模型';

-- 倾斜模型风险筛选。
CREATE INDEX IF NOT EXISTS idx_gis_oblique_template_risk ON gis_oblique_models_template (project_id, is_obstacle, risk_level) WHERE del_flag = false;
COMMENT ON INDEX idx_gis_oblique_template_risk IS '按障碍标识和风险等级筛选倾斜摄影模型';

-- 倾斜模型覆盖范围空间索引。
CREATE INDEX IF NOT EXISTS idx_gis_oblique_template_footprint ON gis_oblique_models_template USING GIST (footprint);
COMMENT ON INDEX idx_gis_oblique_template_footprint IS '倾斜摄影模型覆盖范围空间索引，用于网格叠加打标';

-- 倾斜模型外接范围空间索引，用于快速粗筛。
CREATE INDEX IF NOT EXISTS idx_gis_oblique_template_bbox ON gis_oblique_models_template USING GIST (bbox);
COMMENT ON INDEX idx_gis_oblique_template_bbox IS '倾斜摄影模型外接范围空间索引，用于快速预筛选';


-- ====================================================================================
-- 6. block_mask=16 DEM 数据源表 gis_dem_sources_template
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_dem_sources_template_project_active;
DROP INDEX IF EXISTS idx_gis_dem_sources_template_coverage;
DROP TABLE IF EXISTS gis_dem_sources_template CASCADE;

CREATE TABLE IF NOT EXISTS gis_dem_sources_template (
    id varchar(64) PRIMARY KEY,
    project_id varchar(32),
    name varchar(200),
    dem_type varchar(50) DEFAULT 'DEM',
    data_source varchar(100),
    source_level varchar(20) DEFAULT '项目',
    vertical_datum varchar(50),
    resolution_m double precision,
    min_alt double precision,
    max_alt double precision,
    file_url varchar(1000),
    table_name varchar(128),
    is_active boolean NOT NULL DEFAULT true,
    del_flag boolean NOT NULL DEFAULT false,
    create_time timestamp NOT NULL DEFAULT NOW(),
    update_time timestamp NOT NULL DEFAULT NOW(),
    attrs jsonb DEFAULT '{}'::jsonb NOT NULL,
    coverage geometry(Geometry,4326)
);

COMMENT ON TABLE gis_dem_sources_template IS 'DEM数据源表模板：实际项目表名为 gis_dem_sources_<project_id>';
COMMENT ON COLUMN gis_dem_sources_template.vertical_datum IS '高程基准，如CGCS2000/1985国家高程基准/EGM96等';
COMMENT ON COLUMN gis_dem_sources_template.resolution_m IS 'DEM水平分辨率，单位：米';
COMMENT ON COLUMN gis_dem_sources_template.table_name IS '实际DEM栅格或采样点表名';
COMMENT ON COLUMN gis_dem_sources_template.coverage IS 'DEM覆盖范围';

-- 当前项目可用DEM筛选。
CREATE INDEX IF NOT EXISTS idx_gis_dem_sources_template_project_active ON gis_dem_sources_template (project_id, is_active, del_flag);
COMMENT ON INDEX idx_gis_dem_sources_template_project_active IS '按项目筛选启用状态DEM数据源';

-- DEM覆盖范围空间索引。
CREATE INDEX IF NOT EXISTS idx_gis_dem_sources_template_coverage ON gis_dem_sources_template USING GIST (coverage);
COMMENT ON INDEX idx_gis_dem_sources_template_coverage IS 'DEM覆盖范围空间索引，用于选择覆盖网格的DEM数据源';


-- ====================================================================================
-- 7. DEM 采样点表模板 gis_dem_points_template
-- 说明：如果直接使用 PostGIS raster，可保留 gis_dem_sources_<project_id> 并另建 raster 表；
--      如果使用采样点/等距点方式，则使用本表参与网格 ground_alt 更新。
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_dem_points_template_project;
DROP INDEX IF EXISTS idx_gis_dem_points_template_geom;
DROP TABLE IF EXISTS gis_dem_points_template CASCADE;

CREATE TABLE IF NOT EXISTS gis_dem_points_template (
    id BIGSERIAL PRIMARY KEY,
    dem_source_id varchar(64),
    project_id varchar(32),
    lon double precision,
    lat double precision,
    elevation double precision NOT NULL,
    geom geometry(Point,4326)
);

COMMENT ON TABLE gis_dem_points_template IS 'DEM采样点表模板：实际项目表名为 gis_dem_points_<project_id>';
COMMENT ON COLUMN gis_dem_points_template.dem_source_id IS 'DEM数据源ID';
COMMENT ON COLUMN gis_dem_points_template.elevation IS '地面高程，单位：米';
COMMENT ON COLUMN gis_dem_points_template.geom IS 'DEM采样点二维位置';

-- 项目DEM采样点过滤。
CREATE INDEX IF NOT EXISTS idx_gis_dem_points_template_project ON gis_dem_points_template (project_id);
COMMENT ON INDEX idx_gis_dem_points_template_project IS '按项目筛选DEM采样点';

-- DEM采样点空间索引，用于最近邻高程采样。
CREATE INDEX IF NOT EXISTS idx_gis_dem_points_template_geom ON gis_dem_points_template USING GIST (geom);
COMMENT ON INDEX idx_gis_dem_points_template_geom IS 'DEM采样点空间索引，用于网格点最近邻高程匹配';


-- ====================================================================================
-- 8. 正射影像/DOM 数据源表 gis_dom_sources_template
-- 说明：DOM主要用于展示、辅助判读和贴图，不直接写入网格 ground_alt。
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_dom_sources_template_project_active;
DROP INDEX IF EXISTS idx_gis_dom_sources_template_coverage;
DROP TABLE IF EXISTS gis_dom_sources_template CASCADE;

CREATE TABLE IF NOT EXISTS gis_dom_sources_template (
    id varchar(64) PRIMARY KEY,
    project_id varchar(32),
    name varchar(200),
    dom_type varchar(50) DEFAULT 'DOM',
    data_source varchar(100),
    source_level varchar(20) DEFAULT '项目',
    resolution_m double precision,
    capture_time timestamp,
    file_url varchar(1000),
    tile_url varchar(1000),
    service_url varchar(1000),
    is_active boolean NOT NULL DEFAULT true,
    del_flag boolean NOT NULL DEFAULT false,
    create_time timestamp NOT NULL DEFAULT NOW(),
    update_time timestamp NOT NULL DEFAULT NOW(),
    attrs jsonb DEFAULT '{}'::jsonb NOT NULL,
    coverage geometry(Geometry,4326)
);

COMMENT ON TABLE gis_dom_sources_template IS '正射影像/DOM数据源表模板：实际项目表名为 gis_dom_sources_<project_id>';
COMMENT ON COLUMN gis_dom_sources_template.resolution_m IS '正射影像分辨率，单位：米';
COMMENT ON COLUMN gis_dom_sources_template.capture_time IS '影像采集时间';
COMMENT ON COLUMN gis_dom_sources_template.file_url IS '原始影像文件地址';
COMMENT ON COLUMN gis_dom_sources_template.tile_url IS '切片地址';
COMMENT ON COLUMN gis_dom_sources_template.service_url IS '影像服务地址，如WMTS/WMS/XYZ等';
COMMENT ON COLUMN gis_dom_sources_template.coverage IS '正射影像覆盖范围';

-- 当前项目可用正射影像筛选。
CREATE INDEX IF NOT EXISTS idx_gis_dom_sources_template_project_active ON gis_dom_sources_template (project_id, is_active, del_flag);
COMMENT ON INDEX idx_gis_dom_sources_template_project_active IS '按项目筛选启用状态正射影像数据源';

-- 正射影像覆盖范围空间索引。
CREATE INDEX IF NOT EXISTS idx_gis_dom_sources_template_coverage ON gis_dom_sources_template USING GIST (coverage);
COMMENT ON INDEX idx_gis_dom_sources_template_coverage IS '正射影像覆盖范围空间索引，用于选择覆盖项目区域的影像';


-- ====================================================================================
-- 9. 飞行路径记录表 gis_flight_paths
-- ====================================================================================
DROP INDEX IF EXISTS idx_gis_flight_paths_project_id;
DROP INDEX IF EXISTS idx_gis_flight_paths_del_flag;
DROP INDEX IF EXISTS idx_gis_flight_paths_project_del;
DROP INDEX IF EXISTS idx_gis_flight_paths_start_point;
DROP INDEX IF EXISTS idx_gis_flight_paths_end_point;
DROP TABLE IF EXISTS gis_flight_paths CASCADE;

CREATE TABLE IF NOT EXISTS gis_flight_paths (
    id SERIAL PRIMARY KEY,
    project_id char(32) DEFAULT NULL,
    create_user varchar(32) DEFAULT NULL,
    create_time timestamp NOT NULL DEFAULT NOW(),
    update_user varchar(32) DEFAULT NULL,
    update_time timestamp NOT NULL DEFAULT NOW(),
    del_flag boolean DEFAULT false NOT NULL,
    start_point geometry(PointZ,4326),
    end_point geometry(PointZ,4326),
    safe_altitude double precision,
    path_line geometry(LineStringZ,4326),
    smooth_path_line geometry(LineStringZ,4326),
    waypoints jsonb,
    smooth_waypoints jsonb,
    total_distance double precision,
    smooth_ratio double precision DEFAULT 0
);

COMMENT ON TABLE gis_flight_paths IS '无人机3D规划飞行路径记录表';
COMMENT ON COLUMN gis_flight_paths.id IS '自增主键ID';
COMMENT ON COLUMN gis_flight_paths.project_id IS '项目ID';
COMMENT ON COLUMN gis_flight_paths.create_user IS '创建者';
COMMENT ON COLUMN gis_flight_paths.create_time IS '创建时间';
COMMENT ON COLUMN gis_flight_paths.update_user IS '更新者';
COMMENT ON COLUMN gis_flight_paths.update_time IS '更新时间';
COMMENT ON COLUMN gis_flight_paths.del_flag IS '是否删除：true=删除，false=未删除';
COMMENT ON COLUMN gis_flight_paths.start_point IS '航线起点3D空间坐标（经纬度+高度）';
COMMENT ON COLUMN gis_flight_paths.end_point IS '航线终点3D空间坐标（经纬度+高度）';
COMMENT ON COLUMN gis_flight_paths.safe_altitude IS '规划安全飞行高度，单位：米';
COMMENT ON COLUMN gis_flight_paths.path_line IS '原始规划3D路径线几何';
COMMENT ON COLUMN gis_flight_paths.smooth_path_line IS '处理后3D路径线几何';
COMMENT ON COLUMN gis_flight_paths.waypoints IS '原始规划航点JSON数组';
COMMENT ON COLUMN gis_flight_paths.smooth_waypoints IS '处理后航点JSON数组';
COMMENT ON COLUMN gis_flight_paths.total_distance IS '处理后航线总长度，单位：米';
COMMENT ON COLUMN gis_flight_paths.smooth_ratio IS '高度平滑比例：0=直升-平飞-直降，0<ratio<1=爬升-平飞-降落';

-- 按项目查询历史航线、项目航线列表。
CREATE INDEX IF NOT EXISTS idx_gis_flight_paths_project_id ON gis_flight_paths (project_id);
COMMENT ON INDEX idx_gis_flight_paths_project_id IS '按项目ID查询飞行路径记录';

-- 按逻辑删除状态过滤有效航线。
CREATE INDEX IF NOT EXISTS idx_gis_flight_paths_del_flag ON gis_flight_paths (del_flag);
COMMENT ON INDEX idx_gis_flight_paths_del_flag IS '按逻辑删除标识过滤飞行路径记录';

-- 高频组合条件：项目 + 未删除。
CREATE INDEX IF NOT EXISTS idx_gis_flight_paths_project_del ON gis_flight_paths (project_id, del_flag);
COMMENT ON INDEX idx_gis_flight_paths_project_del IS '按项目ID和删除标识组合查询飞行路径记录';

-- 起点空间索引，用于起点附近航线检索。
CREATE INDEX IF NOT EXISTS idx_gis_flight_paths_start_point ON gis_flight_paths USING GIST (start_point);
COMMENT ON INDEX idx_gis_flight_paths_start_point IS '航线起点空间索引，用于起点附近查询';

-- 终点空间索引，用于终点附近航线检索。
CREATE INDEX IF NOT EXISTS idx_gis_flight_paths_end_point ON gis_flight_paths USING GIST (end_point);
COMMENT ON INDEX idx_gis_flight_paths_end_point IS '航线终点空间索引，用于终点附近查询';

