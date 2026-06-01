
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
SELECT * FROM gis_check_electric_fence (
'{"projectId":"2c95908e958f3b75019593551f520126",
"name":"123",
"fenceType":"3",
"type":"1",
"frequency":"1",
"week":"",
"day":"",
"timePlans":[{"startTime":"00:00","endTime":"24:00","width":350,"left":0}],
"lngLatAlt":"{\"type\":\"Feature\",\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[113.289609,34.951427,0],[113.290607,34.615358,0],[113.979944,34.596458,0],[114.013926,34.930172,0]]]},\"properties\":{}}",
"height":120,"remark":"","area":"2412838531.27",
"areaName":"河南省郑州市金水区南阳路街道河南省万里建设发展有限公司",
"startTime":"2026-05-20","endTime":"2026-06-27"}'::jsonb,
'2c95908e958f3b75019593551f520126'
);

-- 示例：新增试飞区(3)，直接传Geometry格式的北京全域矩形
SELECT * FROM gis_check_electric_fence(
  '{
    "fenceType":"3",
    "lngLatAlt":"{\"type\":\"Polygon\",\"coordinates\":[[[115.72,39.41],[117.51,39.41],[117.51,41.05],[115.72,41.05],[115.72,39.41]]]}"
  }'::jsonb,'2c95908e958f3b75019593551f520126'
);
