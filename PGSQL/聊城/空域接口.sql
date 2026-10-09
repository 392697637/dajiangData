
-- =============================================================================
-- 五、空域区块查询接口及后台SQL
-- =============================================================================
-- 1.1 空域区块查询
-- 接口：GET /api/airspace/blocks
-- 用途：查询空域区块界面列表和地图展示数据。
--
--  查询空域前端请求参数
-- 参数：
--   airspace_code  string    否，空域编号，支持模糊查询
--   airspace_name  string    否，空域名称，支持模糊查询
--
-- 查询规则：
--   1. 一个接口直接查询符合条件的全部未删除空域区块。
--   2. 页面列表展示空域编号、空域名称、启用状态。
--   3. 同时返回lngLatAlt和final_geom，供前端地图定位、编辑、绘制使用。
--
--  后端返回参数
-- 返回格式：
--   code       integer   0表示成功，非0表示失败
--   message    string    返回说明
--   data       array     空域区块集合
--
-- data数组元素字段：
--   id             bigint    区块主键
--   airspace_code  string    空域编号
--   airspace_name  string    空域名称
--   use_enabled    boolean   启用状态
--   use_enabled_name string   启用状态名称：启用/停用
--   lngLatAlt      object    原始点/线/面GeoJSON Feature
--   final_geom     object    生成后的最终范围GeoJSON Feature
--
-- 空间字段返回规则：
--   1. lngLatAlt和final_geom使用GeoJSON格式，坐标系为WGS84（EPSG:4326）。
--   2. lngLatAlt用于展示原始点/线/面，final_geom用于空间校验、相交、包含等范围判断。
--   3. 前端地图建议接收GeoJSON Geometry；如果地图组件要求Feature，
--      后端再将属性字段组装为GeoJSON Feature。
--
--   PostgreSQL语句
-- 接口：GET /api/airspace/blocks
-- 查询符合条件的全部区块数据。
SELECT
    b.id,
    b.airspace_code,
    b.airspace_name,
    b.use_enabled,
    CASE
        WHEN b.use_enabled THEN '启用'
        ELSE '停用'
    END AS use_enabled_name,
    public.gis_build_feature_geojson(b.geom, '{"type":"Feature","properties":{}}')::json AS lngLatAlt,
    public.gis_build_feature_geojson(b.final_geom, '{"type":"Feature","properties":{}}')::json AS final_geom,
    b.create_time,
    b.update_time
FROM public.bo_airspace_block b
WHERE b.del_flag = false
  AND (
      NULLIF(btrim(:airspace_code), '') IS NULL
      OR b.airspace_code ILIKE '%' || btrim(:airspace_code) || '%'
  )
  AND (
      NULLIF(btrim(:airspace_name), '') IS NULL
      OR b.airspace_name ILIKE '%' || btrim(:airspace_name) || '%'
  )
ORDER BY b.airspace_code NULLS LAST, b.id;

-- =============================================================================
-- 2.1 用空计划查询
-- =============================================================================
-- 接口：GET /api/airspace/plans
-- 用途：根据空域区块条件和使用日期查询用空计划明细。
-- 关联关系：
--   bo_airspace_plan.block_id = bo_airspace_block.id
--   一条 bo_airspace_block 记录可以关联多条 bo_airspace_plan 记录（一对多）。
--   本接口按计划明细返回，一条用空计划返回一条记录。
--   同一区块存在多条计划时，区块字段会随每条计划重复返回，这是正常结果。
--
--   查询用空计划前端请求参数
-- 参数：
--   airspace_code  string    否，空域编号，支持模糊查询
--   airspace_name  string    否，空域名称，支持模糊查询
--   airspace_type  string    否，空域类型：POINT点、LINE线、POLYGON面
--   use_enabled        boolean   否，启用状态
--   use_date       date      是，使用日期，格式：YYYY-MM-DD
--
-- 查询规则：
--   1. 以上四个空域区块查询条件关联 bo_airspace_block 使用。
--   2. use_date 关联 bo_airspace_plan.use_date 查询。
--   3. 只返回存在指定日期有效用空计划的空域区块和计划。
--   4. 本接口只返回空域区块，不返回plans计划数组。
--   5. 当前 SQL 示例日期先写死为 DATE '2026-09-28'，便于直接执行测试；
--      后端正式调用时，将 DATE '2026-09-28' 替换为 :use_date::date。
--
--   用空计划后端返回参数
-- 返回格式：
--   code       integer   0表示成功，非0表示失败
--   message    string    返回说明
--   data       array     空域区块集合
--   注意：data数组元素是一个空域区块，不包含plans计划数组。
--
-- data数组元素（区块）字段：
--   id             bigint    区块主键
--   airspace_code  string    空域编号
--   airspace_name  string    空域名称
--   airspace_height number   空域高度，米
--   airspace_type  string    空域类型：POINT点、LINE线、POLYGON面
--   airspace_radius number 空域缓冲半径，米
--   airspace_area  number    空域面积，平方千米
--   airspace_perimeter number 空域周长，千米
--   parent_id      bigint    父级空域区块ID：-1表示主区域；子区域填写主区域id
--   use_enabled        boolean   启用状态
--   geom           object    原始点/线/面GeoJSON Feature
--   final_geom     object    生成后的最终范围GeoJSON Feature
--
--   PostgreSQL语句
-- 查询符合条件且在指定日期存在有效用空计划的全部空域区块。
SELECT
    b.id,
    b.airspace_code,
    b.airspace_name,
    b.airspace_height,
    b.airspace_type,
    b.airspace_radius,
    b.airspace_area,
    b.airspace_perimeter,
    b.parent_id,
    b.use_enabled,
    public.gis_build_feature_geojson(b.geom, '{"type":"Feature","properties":{}}')::json AS geom,
    public.gis_build_feature_geojson(b.final_geom, '{"type":"Feature","properties":{}}')::json AS final_geom
FROM public.bo_airspace_block b
WHERE b.del_flag = false
  AND (
      NULLIF(btrim(:airspace_code), '') IS NULL
      OR b.airspace_code ILIKE '%' || btrim(:airspace_code) || '%'
  )
  AND (
      NULLIF(btrim(:airspace_name), '') IS NULL
      OR b.airspace_name ILIKE '%' || btrim(:airspace_name) || '%'
  )
  AND (
      NULLIF(btrim(:airspace_type), '') IS NULL
      OR b.airspace_type = btrim(:airspace_type)
  )
  AND (
      :use_enabled IS NULL
      OR b.use_enabled = :use_enabled::boolean
  )
  AND EXISTS (
      SELECT 1
      FROM public.bo_airspace_plan p
      WHERE p.block_id = b.id
        AND p.del_flag = false
        AND p.use_date = DATE '2026-09-28'
  )
ORDER BY b.airspace_code NULLS LAST, b.id;

-- =============================================================================
-- 2.2 根据区块ID查询用空计划
-- =============================================================================
-- 接口：GET /api/airspace/blocks/{block_id}/plans
-- 用途：根据空域区块ID和使用日期查询该区块下的用空计划数组。
--
--  查询用空计划前端请求参数
-- 参数：
--   block_id       bigint    必填，空域区块主键
--   use_date       date      必填，使用日期，格式：YYYY-MM-DD
--
--   用空计划后端返回参数
-- 返回格式：
--   code       integer   0表示成功，非0表示失败
--   message    string    返回说明
--   data       array     当前区块下的用空计划集合
--
-- data数组元素字段：
--   id             bigint    用空计划主键
--   block_id       bigint    空域区块主键
--   use_date       date      使用日期
--   time_plan      string    时间计划，仅保存时分秒
--   plan_status    boolean   计划状态：t可用；f不可用
--   remark         string    计划备注
--
--   PostgreSQL语句
-- 当前 SQL 示例日期先写死为 DATE '2026-09-28'，后端调用时替换为 :use_date::date。
-- 后端查询结果统一封装为 data 数组；SQL 每条计划返回一行。
SELECT
    p.id,
    p.block_id,
    p.use_date,
    p.time_plan,
    p.plan_status,
    p.remark
FROM public.bo_airspace_plan p
WHERE p.block_id = :block_id
  AND p.del_flag = false
  AND p.use_date = DATE '2026-09-28'
ORDER BY p.id;

-- =============================================================================
-- 四、按日期和24小时时间轴查询空域区块
-- =============================================================================
-- 用途：选择某一天后，时间轴按24小时移动，查询当前时刻对应的空域区块。
-- 关联关系：
--   bo_airspace_plan.block_id = bo_airspace_block.id
--   一个空域区块可以对应多条用空计划。
--   只要区块下有一条计划在当前时间段内生效，就返回该区块。
--
-- 4.1 查询空域区块前端请求参数
-- 参数：
--   airspace_code  string    否，空域编号，支持模糊查询
--   airspace_name  string    否，空域名称，支持模糊查询
--   airspace_type  string    否，空域类型：POINT点、LINE线、POLYGON面
--   use_enabled        boolean   否，启用状态
--   use_date       date      必填，查询日期，格式：YYYY-MM-DD
--   axis_time      time      必填，24小时时间轴当前时间，格式：HH24:MI:SS
--
-- 4.2 查询结果
-- 返回符合空域区块筛选条件、指定日期、指定时间段内有效的区块。
-- 一个区块如果同时匹配多条计划，SQL按计划返回多行，后端可按block_id合并；
-- 如果前端只需要区块列表，可在后端按block_id去重。
-- 返回字段：
--   block_id       bigint    空域区块主键
--   airspace_code  string    空域编号
--   airspace_name  string    空域名称
--   airspace_height number   空域高度，米
--   airspace_type  string    空域类型：POINT点、LINE线、POLYGON面
--   airspace_radius number 空域缓冲半径，米
--   airspace_area  number    空域面积，平方千米
--   airspace_perimeter number 空域周长，千米
--   parent_id      bigint    父级空域区块ID：-1表示主区域；子区域填写主区域id
--   use_enabled        boolean   启用状态
--   id             bigint    当前生效计划主键
--   use_date       date      使用日期
--   time_plan      string    时间计划
--   plan_status    boolean   计划状态：t可用；f不可用
--   geom           object    原始点/线/面GeoJSON Feature
--   final_geom     object    生成后的最终范围GeoJSON Feature
--
-- 4.3 PostgreSQL语句
-- 当前 SQL 示例日期和时间先写死，后端调用时替换为 :use_date::date
-- 和 :axis_time::time。
SELECT
    b.id AS block_id,
    b.airspace_code,
    b.airspace_name,
    b.airspace_height,
    b.airspace_type,
    b.airspace_radius,
    b.airspace_area,
    b.airspace_perimeter,
    b.parent_id,
    b.use_enabled,
    p.id,
    p.use_date,
    p.time_plan,
    p.plan_status,
    p.remark,
    public.gis_build_feature_geojson(b.geom, '{"type":"Feature","properties":{}}')::json AS geom,
    public.gis_build_feature_geojson(b.final_geom, '{"type":"Feature","properties":{}}')::json AS final_geom
FROM public.bo_airspace_block b
JOIN public.bo_airspace_plan p
    ON p.block_id = b.id
WHERE b.del_flag = false
  AND p.del_flag = false
  AND p.plan_status = true
  AND p.use_date = DATE '2026-09-28'
  AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(
          CASE
              WHEN btrim(COALESCE(p.time_plan, '')) ~ '^\s*\['
              THEN p.time_plan::jsonb
              ELSE '[]'::jsonb
          END
      ) AS time_item(item)
      WHERE
          (
              :axis_time::time >= (time_item.item->>'startTime')::time
              AND :axis_time::time < (time_item.item->>'endTime')::time
          )
          OR (
              (time_item.item->>'startTime')::time >
                  (time_item.item->>'endTime')::time
              AND (
                  :axis_time::time >= (time_item.item->>'startTime')::time
                  OR :axis_time::time < (time_item.item->>'endTime')::time
              )
          )
  )
  AND (
      NULLIF(btrim(:airspace_code), '') IS NULL
      OR b.airspace_code ILIKE '%' || btrim(:airspace_code) || '%'
  )
  AND (
      NULLIF(btrim(:airspace_name), '') IS NULL
      OR b.airspace_name ILIKE '%' || btrim(:airspace_name) || '%'
  )
  AND (
      NULLIF(btrim(:airspace_type), '') IS NULL
      OR b.airspace_type = btrim(:airspace_type)
  )
  AND (
      :use_enabled IS NULL
      OR b.use_enabled = :use_enabled::boolean
  )
ORDER BY b.airspace_code NULLS LAST, b.id, p.id;


