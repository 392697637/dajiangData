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
 
SELECT * FROM gis_electric_fence_project(
    'zhengzhou_demo', 
    '{"type":"Polygon","coordinates":[[[113.0,34.5],[114.0,34.5],[114.0,35.0],[113.0,35.0],[113.0,34.5]]]}'
);

SELECT* FROM gis_electric_fence_project(
    '2c95908e958f3b75019593551f520126', --  输入参数：项目唯一ID（用于生成表名）
    '{"type":"Polygon","coordinates":[[[113.0,34.5],[114.0,34.5],[114.0,35.0],[113.0,35.0],[113.0,34.5]]]}'  -- 输入参数：项目范围的GeoJSON多边形字符串
);


-- ========================================================================================校验电子围栏==========================================================================================
-- =============================================
-- 函数名称： gis_check_electric_fence
-- 函数功能： 电子围栏空间冲突校验（禁飞区/管控区/试飞区互斥规则校验）
-- 参数说明：
--   param_json     jsonb       入参JSON：包含围栏类型、坐标信息
--   project_id     varchar     项目ID（可选），用于区分项目专属围栏表
-- 返回值： 标准TABLE结构
--   code               integer     返回码：200成功，400参数错误，500空间冲突
--   table_name         text        冲突对应的表名
--   orig_fence_type    text        传入的原始围栏类型
--   conflict_fence_type text       冲突的围栏类型(数字)
--   msg                text        详细提示信息（区分相交/包含 + 中文名称）
--   new_geom           text        标准化后的新围栏几何JSON
--   conflict_geom      text        冲突围栏的几何JSON
-- 调用说明：
--   1. fenceType：1=禁飞区，2=管控区，3=试飞区
--   2. lngLatAlt：支持GeoJSON Feature，也支持直接传Polygon/MultiPolygon等Geometry字符串
--   3. project_id：用于校验项目专属围栏表 gis_electric_fence_{project_id} 及业务表 bo_electric_fence
-- =============================================
SELECT * FROM gis_check_electric_fence(
  '{
    "fenceType":"3",
    "lngLatAlt":"{\"type\":\"Polygon\",\"coordinates\":[[[115.72,39.41],[117.51,39.41],[117.51,41.05],[115.72,41.05],[115.72,39.41]]]}"
  }'::jsonb,'2c95908e958f3b75019593551f520126'
);
