-- ============================================================================
-- 3.待对接接口.sql
-- 电子围栏校验相关接口最终调用示例。
-- 坐标系默认 WGS84(EPSG:4326)，示例中的项目ID、围栏ID、坐标按实际业务替换。
-- ============================================================================

-- ============================================================================
-- 2.3-1 gis_electric_fence_buffer
-- 功能：根据项目ID、围栏ID和缓冲半径，返回原始围栏、2D缓冲面、3D立体几何GeoJSON。
-- 参数：
--   p_project_id      text               项目ID；为空时只查公共表
--   p_fence_id        varchar(32)        围栏ID；为空返回项目/公共范围内全部围栏
--   p_buffer_radius   double precision   缓冲半径，单位：米；0表示不缓冲
-- 返回：
--   code, msg, id, geom_geojson, buffer_2d_geojson, solid_3d_geojson
-- ============================================================================
SELECT * FROM public.gis_electric_fence_buffer(
    '2c95908e958f3b75019593551f520126',
    '2052290479526682626',
    30
);

-- p_fence_id 为空：返回全部围栏缓冲数据
SELECT * FROM public.gis_electric_fence_buffer(
    '2c95908e958f3b75019593551f520126',
    NULL,
    30
);

-- ============================================================================
-- 2.3-2 gis_electric_fence_check_line_buffer
-- 功能：检测航线/轨迹是否闯入电子围栏缓冲区，支持项目专属围栏表。
-- 参数：
--   p_project_id      text               项目ID
--   p_line_geojson    text               LineString/MultiLineString GeoJSON
--   p_buffer_radius   double precision   缓冲半径，单位：米；0表示不缓冲
-- 返回：
--   code, msg, id, geom_geojson, buffer_2d_geojson, solid_3d_geojson
-- ============================================================================
SELECT * FROM public.gis_electric_fence_check_line_buffer(
    '2c95908e958f3b75019593551f520126',
    '{
        "type":"LineString",
        "coordinates":[
            [113.405861,34.769437,120],
            [113.4654075,34.8085025,120]
        ]
    }',
    10
);

-- ============================================================================
-- 2.3-3 gis_electric_fence_check_point_buffer
-- 功能：检测航点是否闯入电子围栏缓冲区，支持项目专属围栏表。
-- 参数：
--   p_project_id      text               项目ID
--   p_point_geojson   text               Point/PointZ GeoJSON，或 [lng,lat,alt]
--   p_buffer_radius   double precision   缓冲半径，单位：米；0表示不缓冲
-- 返回：
--   code, msg, id, geom_geojson, buffer_2d_geojson, solid_3d_geojson
-- ============================================================================
SELECT * FROM public.gis_electric_fence_check_point_buffer(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Point","coordinates":[113.405861,34.769437,120]}',
    10
);

SELECT * FROM public.gis_electric_fence_check_point_buffer(
    '2c95908e958f3b75019593551f520126',
    '[113.405861,34.769437,120]',
    10
);

-- ============================================================================
-- 2.3-4 gis_electric_fence_check_line
-- 功能：检测航线/轨迹是否直接穿越电子围栏，不做缓冲。
-- 参数：
--   p_project_id      text               项目ID
--   p_line_geojson    text               LineString/MultiLineString GeoJSON
-- 返回：
--   code, msg, ischeck, table_name, id, geom_geojson
-- ============================================================================
SELECT * FROM public.gis_electric_fence_check_line(
    '2c95908e958f3b75019593551f520126',
    '{
        "type":"LineString",
        "coordinates":[
            [113.405861,34.769437,120],
            [113.4654075,34.8085025,120]
        ]
    }'
);

-- ============================================================================
-- 2.3-5 gis_electric_fence_check_point
-- 功能：检测航点是否落入电子围栏，不做缓冲；边界点算命中。
-- 参数：
--   p_project_id      text               项目ID
--   p_point_geojson   text               Point/PointZ GeoJSON，或 [lng,lat,alt]
-- 返回：
--   code, msg, ischeck, table_name, id, geom_geojson
-- ============================================================================
SELECT * FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Point","coordinates":[113.405861,34.769437,10]}'
);

SELECT * FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '[113.405861,34.769437,10]'
);
