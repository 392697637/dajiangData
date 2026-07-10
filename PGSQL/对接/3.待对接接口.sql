-- ============================================================================
-- 3.待对接接口.sql
-- 日期：2026-07-06
-- 范围：电子围栏缓冲区相关接口。
-- 说明：以下接口会生成或使用围栏缓冲区/立体几何。
-- 坐标系默认 WGS84(EPSG:4326)，示例中的项目ID、围栏ID、坐标按实际业务替换。
-- ============================================================================

-- ============================================================================
-- 2.3-1 gis_electric_fence_buffer
-- 功能：根据项目ID、围栏ID和缓冲半径，返回原始围栏、缓冲面、立体几何。
-- 参数：
--   p_project_id      text               项目ID；为空时只查公共表
--   p_fence_id        varchar(32)        围栏ID；为空返回项目/公共范围内全部围栏
--   p_buffer_radius   double precision   缓冲半径，单位：米；0表示不缓冲
--   p_return_geojson  boolean            是否返回GeoJSON，默认false；需要前端直接使用GeoJSON时传true
-- 返回：
--   code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
-- chek_type：
--   b_generated  已生成缓冲/立体几何
--   b_empty      未查询到有效围栏数据
-- ============================================================================
SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_buffer(
    '2c95908e958f3b75019593551f520126',
    '2052290479526682626',
    30,
    true
);

-- p_fence_id 为空：返回全部围栏缓冲数据
SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_buffer(
    '2c95908e958f3b75019593551f520126',
    NULL,
    30,
    false
);

-- 无项目ID且 p_fence_id 为空：返回公共表全部围栏
SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_buffer(
    NULL,
    NULL,
    0,
    false
);

-- ============================================================================
-- 2.3-2 gis_electric_fence_check_point_buffer
-- 功能：检测航点是否闯入电子围栏缓冲区，支持项目专属围栏表。
-- 参数：
--   p_project_id      text               项目ID；为空时只查公共表
--   p_point_geojson   text               Point/PointZ GeoJSON、Feature，或 [lng,lat,alt]
--   p_buffer_radius   double precision   缓冲半径，单位：米；0表示不缓冲
--   p_return_geojson  boolean            是否返回围栏/缓冲/立体GeoJSON，默认false；需要前端直接使用GeoJSON时传true
-- 返回：
--   code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
-- chek_type：
--   p_inner  点在内部
--   p_outer  点在外部
-- ============================================================================
SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_check_point_buffer(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Point","coordinates":[113.405861,34.769437,120]}',
    10,
    true
);

SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_check_point_buffer(
    '2c95908e958f3b75019593551f520126',
    '[113.405861,34.769437,120]',
    10,
    false
);

-- ============================================================================
-- 2.3-3 gis_electric_fence_check_line_buffer
-- 功能：检测航线是否闯入电子围栏缓冲区，支持项目专属围栏表。
-- 参数：
--   p_project_id      text               项目ID；为空时只查公共表
--   p_line_geojson    text               LineString/MultiLineString GeoJSON、Feature，或 [[lng,lat,alt], ...]
--   p_buffer_radius   double precision   缓冲半径，单位：米；0表示不缓冲
--   p_return_geojson  boolean            是否返回围栏/缓冲/立体GeoJSON，默认false；需要前端直接使用GeoJSON时传true
-- 返回：
--   code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
-- chek_type：
--   l_within    线完全在面内
--   l_outside   线完全在面外
--   l_crosses   线穿过面（贯穿，两端在外）
--   l_entering  线穿入/穿出面（一端在内，一端在外）
-- ============================================================================
SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_check_line_buffer(
    '2c95908e958f3b75019593551f520126',
    '{
        "type":"LineString",
        "coordinates":[
            [113.405861,34.769437,120],
            [113.4654075,34.8085025,120]
        ]
    }',
    10,
    true
);

SELECT code, msg, ischeck, chek_type, electric_id, electric_geom, electric_geojson, electric_buffer_geom, electric_buffer_geojson, electric_solid_geom, electric_solid_geojson
FROM public.gis_electric_fence_check_line_buffer(
    '2c95908e958f3b75019593551f520126',
    '[
        [113.405861,34.769437,120],
        [113.4654075,34.8085025,120]
    ]',
    10,
    false
);
