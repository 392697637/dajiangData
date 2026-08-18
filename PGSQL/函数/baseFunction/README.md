# baseFunction 公共函数说明

本目录存放 GIS SQL 脚本的公共基础函数。这里的函数会被多个业务脚本复用，通常需要在业务函数脚本之前执行。

## 执行顺序

1. `gis_drop_function.sql`
   - 创建 `public.gis_drop_function(text)`。
   - 用于删除同名重载函数，后续大多数函数脚本会先调用它再重建函数。
   - 这是本目录中优先级最高的基础函数。

2. `gis_geojson_to_geom.sql`
   - 创建 `public.gis_geojson_to_geom(text)`。
   - 用于把 GeoJSON Geometry、Feature、FeatureCollection 解析为 PostGIS `geometry`。
   - Polygon/MultiPolygon 的面环未闭合时会自动追加首点闭合。
   - 依赖 `gis_drop_function.sql`。

3. `gis_refresh_all_tables.sql`
   - 创建并执行 `public.gis_refresh_all_tables()`。
   - 用于对所有用户表执行 `ANALYZE`，刷新 PostgreSQL 统计信息。
   - 依赖 `gis_drop_function.sql`。

## 使用约定

- 新增公共函数时，优先放在本目录。
- 每个 SQL 文件开头必须写清：函数名称、功能、依赖、入参、返回值、使用示例。
- 业务脚本引用本目录函数时，只写调用，不重复定义公共函数。
- 如果函数会被其他 SQL 脚本用于重建流程，应先确认 `gis_drop_function.sql` 已执行。
