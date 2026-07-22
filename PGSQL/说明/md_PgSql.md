# PGSQL / PostGIS 函数说明

`PGSQL/` 目录保存电子围栏、三维网格、航线校验、自动规划相关 SQL 脚本。核心依赖 PostgreSQL + PostGIS。

## 脚本列表

| 文件 | 说明 |
|------|------|
| `PGSQL/1.对接接口函数.20260602.sql` | 项目创建、三维网格生成、围栏标记、刷新等接口调用 |
| `PGSQL/1.1接口校验.sql` | 接口调用校验示例 |
| `PGSQL/2.1电子围栏创建-函数.sql` | 按项目创建电子围栏表并导入禁飞区/试飞区数据 |
| `PGSQL/2.2电子围栏校验-函数..sql` | 新增/编辑电子围栏前的空间冲突校验 |
| `PGSQL/2.3电子围栏缓冲+线判断.sql` | 围栏缓冲、航线穿越检测、点位禁飞区检测 |
| `PGSQL/3.2线路自动规划.sql` | 三维 A* 自动航线规划、路径平滑、直线兜底 |

## 推荐执行顺序

```text
1. 创建基础表、PostGIS扩展和业务表
2. 执行 2.1电子围栏创建-函数.sql
3. 执行 2.2电子围栏校验-函数..sql
4. 执行 2.3电子围栏缓冲+线判断.sql
5. 执行 3.2线路自动规划.sql
6. 使用 1.对接接口函数.20260602.sql / 1.1接口校验.sql 做接口联调
```

实际顺序以数据库表是否已存在为准。

## 电子围栏冲突校验

函数：`gis_check_electric_fence`

规则：

| 新增类型 | 校验规则 |
|----------|----------|
| `1` 禁飞区 | 直接通过 |
| `2` 管控区 | 不允许与禁飞区冲突 |
| `3` 试飞区 | 不允许与禁飞区、管控区冲突 |

## 围栏缓冲与航线检测

常用函数：

| 函数 | 说明 |
|------|------|
| `gis_electric_fence_buffer` | 根据围栏 ID 和缓冲半径生成缓冲面和立体几何 |
| `gis_electric_fence_check_point` | 检测点位是否位于项目禁飞区内 |
| `gis_electric_fence_check_line` | 检测航线是否穿越原始围栏 |
| `gis_electric_fence_check_point_buffer` | 检测点位是否闯入缓冲后的围栏 |
| `gis_electric_fence_check_line_buffer` | 检测航线是否穿越缓冲后的围栏 |

点位/航线校验的 `chek_type`：

| chek_type | 说明 |
|-----------|------|
| `p_inner` | 点在内部 |
| `p_outer` | 点在外部 |
| `ln_within` | 线与面：包含于 |
| `ln_outside` | 线与面：相离 |
| `ln_crosses` | 线与面：交叉 |
| `ln_enters` | 线与面：穿入/穿出 |
| `ln_overlaps` | 线与面：重叠 |

缓冲区相关函数返回 `ischeck` 和 `chek_type`：

| 函数 | ischeck | chek_type |
|------|---------|-----------|
| `gis_electric_fence_buffer` | 生成到有效围栏为 `true`，未查询到或异常为 `false` | `b_generated` 已生成，`b_empty` 未查询到有效围栏数据 |
| `gis_electric_fence_check_point_buffer` | 命中缓冲区为 `true`，未命中为 `false` | `p_inner` 点在内部，`p_outer` 点在外部 |
| `gis_electric_fence_check_line_buffer` | 命中缓冲区为 `true`，未命中为 `false` | `ln_within`、`ln_outside`、`ln_crosses`、`ln_enters`、`ln_overlaps` |

点位/航线校验命中围栏时返回 `electric_id`、`fence_type`、`electric_name`、`electric_geom`、`electric_geojson`。

缓冲区检测函数统一在 `msg` 中追加 `chek_type` 编码和中文含义；围栏字段统一返回为：`electric_id`、`fence_type`、`electric_name`、`electric_geom`、`electric_geojson`、`electric_buffer_geom`、`electric_buffer_geojson`、`electric_solid_geom`、`electric_solid_geojson`。

`gis_electric_fence_buffer` 是缓冲生成函数，返回 `electric_id`、`fence_type`、`electric_geom`、`electric_geojson`、`electric_buffer_geom`、`electric_buffer_geojson`、`electric_solid_geom`、`electric_solid_geojson`。

缓冲区相关函数新增可选参数 `p_return_geojson boolean DEFAULT false`。默认不生成 GeoJSON，`electric_geojson`、`electric_buffer_geojson`、`electric_solid_geojson` 返回 `NULL`；`electric_geom`、`electric_buffer_geom`、`electric_solid_geom` 仍正常返回。需要前端直接使用 GeoJSON 时传 `true`。

## 三维自动线路规划

核心函数：`gis_astar_3d_flight_plan`

能力：

- 基于三维网格执行 A* 寻路。
- 支持项目网格表：`gis_grid_nodes_{project_id}`。
- 支持公共网格表：`gis_grid_nodes`。
- 自动避开禁飞区、管控区。
- 支持直升直降和平滑爬升/下降。
- A* 不可用或异常时自动返回直线兜底航线。
- 对规划结果进行可视连线简化，减少不必要中间点。

## 注意事项

1. 数据库必须安装并启用 PostGIS。
2. 动态项目表需要先创建，例如 `gis_electric_fence_{project_id}`、`gis_grid_nodes_{project_id}`。
3. 空间字段建议统一使用 SRID 4326。
4. 大范围网格会产生大量数据，建议按项目范围和合理分辨率生成。
5. 执行 SQL 前先确认依赖表字段是否一致，尤其是 `geom`、`height`、`fence_type`、`project_id`、`zone_type`。
