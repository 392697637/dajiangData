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

SELECT* FROM gis_electric_fence_project(
    '2c95908e958f3b75019593551f520126', --  输入参数：项目唯一ID（用于生成表名）
    '{"type":"Polygon","coordinates":[[[113.0,34.5],[114.0,34.5],[114.0,35.0],[113.0,35.0],[113.0,34.5]]]}'  -- 输入参数：项目范围的GeoJSON多边形字符串
);
