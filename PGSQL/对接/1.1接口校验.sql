-- ====================================================================================
-- 1.1 接口校验
-- 功能：集中放置电子围栏相关函数的接口调用示例，便于数据库侧联调验证。
-- 说明：
--   1. 执行前需先创建对应函数。
--   2. 示例中的项目ID、围栏ID、坐标需按实际业务数据替换。
--   3. GeoJSON坐标系默认使用WGS84(EPSG:4326)。
-- ====================================================================================


-- ====================================================================================
-- 2.3-1 gis_electric_fence_buffer
-- 功能：根据电子围栏ID和缓冲半径，返回原始围栏、2D缓冲面、3D立体几何GeoJSON。
-- 参数：
--   p_fence_id       varchar(32)        围栏ID
--   p_buffer_radius  double precision   缓冲半径，单位：米；0表示不缓冲
-- ====================================================================================
SELECT * FROM public.gis_electric_fence_buffer(
    '2052290479526682626',
    30
);


-- ====================================================================================
-- 2.3-2 gis_electric_fence_check_line_buffer
-- 功能：检测航线/轨迹是否穿入电子围栏，支持围栏2D缓冲和3D高度判断。
-- 参数：
--   p_line_geojson   text               LineString/MultiLineString GeoJSON
--   p_buffer_radius  double precision   缓冲半径，单位：米；0表示不缓冲
-- ====================================================================================
SELECT * FROM public.gis_electric_fence_check_line_buffer(
    '{
        "type":"LineString",
        "coordinates":[
            [113.405861,34.769437,120],
            [113.405861,34.769437,120]
        ]
    }',
    10
);


-- ====================================================================================
-- 2.3-3 gis_electric_fence_check_line
-- 功能：检测航线/轨迹是否穿入电子围栏，不做缓冲，直接使用原始围栏3D判断。
-- 参数：
--   p_line_geojson   text   LineString/MultiLineString GeoJSON
-- ====================================================================================
SELECT * FROM public.gis_electric_fence_check_line(
    '{
        "type":"LineString",
        "coordinates":[
            [113.405861,34.769437,120],
            [113.405861,34.769437,120]
        ]
    }'
);


-- ====================================================================================
-- 2.3-4 gis_electric_fence_check_point
-- 功能：检测无人机定位点是否在禁飞区内。
-- 参数：
--   p_project_id     text   项目ID；为空时按函数内部逻辑处理
--   p_point_geojson  text   点GeoJSON，支持Point或Feature<Point>
-- ====================================================================================

-- 示例1：传项目ID，使用Point格式。
SELECT * FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Point","coordinates":[113.405861,34.769437,10000]}'
);

-- 示例2：传项目ID，使用Feature<Point>格式，并通过properties.z传高度。
SELECT * FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Feature","geometry":{"type":"Point","coordinates":[113.405861,34.769437]},"properties":{"z":10000}}'
);

-- 示例3：项目ID为空。
SELECT * FROM public.gis_electric_fence_check_point(
    '',
    '{"type":"Point","coordinates":[113.405861,34.769437,10000]}'
);

-- 示例4：项目ID为NULL。
SELECT * FROM public.gis_electric_fence_check_point(
    NULL,
    '{"type":"Point","coordinates":[113.405861,34.769437]}'
);
