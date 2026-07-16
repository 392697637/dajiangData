-- ============================================================================
-- 2.在对接接口.sql
-- 日期：2026-07-06
-- 范围：电子围栏非缓冲检测接口。
-- 说明：以下接口不做缓冲区计算，直接基于原始围栏几何进行校验。
-- 坐标系默认 WGS84(EPSG:4326)，示例中的项目ID、围栏ID、坐标按实际业务替换。
-- ============================================================================

-- ============================================================================
-- 2.2-1 gis_electric_fence_check_point
-- 功能：检测航点是否落入电子围栏，不做缓冲；边界点算命中。
-- 参数：
--   p_project_id      text     项目ID；为空时只查公共表
--   p_point_geojson   text     Point/PointZ/MultiPoint GeoJSON、Feature，或 [lng,lat,alt] / [[lng,lat,alt], ...]
-- 返回：
--   code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson；多点按点数返回多行
-- check_type：
--   p_inner  点在内部
--   p_outer  点在外部
-- ============================================================================
SELECT code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '{"type":"Point","coordinates":[113.405861,34.769437,10]}'
);

SELECT code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '[113.405861,34.769437,10]'
);

SELECT code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
FROM public.gis_electric_fence_check_point(
    '2c95908e958f3b75019593551f520126',
    '[
        [113.405861,34.769437,10],
        [113.4654075,34.8085025,120]
    ]'
);

-- ============================================================================
-- 2.2-2 gis_electric_fence_check_line
-- 功能：检测航线/轨迹是否直接穿越电子围栏，不做缓冲。
-- 参数：
--   p_project_id     text     项目ID；为空时只查公共表
--   p_line_geojson   text     LineString/MultiLineString GeoJSON、Feature，或 [[lng,lat,alt], ...] / [[[lng,lat,alt], ...], ...]
-- 返回：
--   code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson；多线按线数返回多行
-- check_type：
--   ln_within    线与面：包含于
--   ln_outside   线与面：相离
--   ln_crosses   线与面：交叉
--   ln_enters    线与面：穿入/穿出
--   ln_overlaps  线与面：重叠
-- ============================================================================
SELECT code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
FROM public.gis_electric_fence_check_line(
    '2c95908e958f3b75019593551f520126',
    '{
        "type":"LineString",
        "coordinates":[
            [113.405861,34.769437,120],
            [113.4654075,34.8085025,120]
        ]
    }'
);

SELECT code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
FROM public.gis_electric_fence_check_line(
    '2c95908e958f3b75019593551f520126',
    '[
        [113.405861,34.769437,120],
        [113.4654075,34.8085025,120]
    ]'
);

SELECT code, msg, ischeck, check_type, table_name, geom, electric_id, fence_type, electric_geom, electric_geojson
FROM public.gis_electric_fence_check_line(
    '2c95908e958f3b75019593551f520126',
    '[
        [
            [113.405861,34.769437,120],
            [113.4654075,34.8085025,120]
        ],
        [
            [113.4654075,34.8085025,120],
            [113.499782,34.856890,120]
        ]
    ]'
);
