# POI 数据爬取说明

本模块用于采集高德 POI 和天地图 POI 数据，统一通过 `main.py` 调用。

## 数据源

| 类型 | 数据源 | 输出目录 | 是否需要 Key |
|------|--------|----------|--------------|
| 高德 POI | 高德 Web 服务 API | `output/amap/` | 是 |
| 天地图 POI | 天地图搜索 V2.0 API | `output/tianditu/` | 是 |

## 配置 API Key

推荐使用环境变量：

```powershell
$env:AMAP_API_KEY="你的高德Web服务Key"
$env:TIANDITU_API_KEY="你的天地图搜索服务Key"
```

也可以在 `config/settings.py` 中配置：

```python
AMAP_CONFIG["api_key"]
TIANDITU_CONFIG["api_key"]
```

注意：天地图瓦片 Key 不能用于 POI 搜索。若返回 `301012 权限类型错误`，需要重新申请搜索服务 V2.0 Key。

## 支持模式

| 模式 | 触发参数 | 适用场景 |
|------|----------|----------|
| 单点周边 | `--lat --lng --radius` | 小范围快速验证 |
| 矩形范围 | `--lat-min --lat-max --lng-min --lng-max` | 城市局部区域 |
| 区域分块 | `--region --grid-size` | 城市、省份、全国大范围采集 |

## 按官网 POI 类型全量采集

高德和天地图的 POI 类型体系不同，不能混用。需要全量数据时，应分别按照各自官网 POI 类型表循环采集，并按类型单独存储结果。

| 平台 | 类型参数 | 类型来源 | 建议存储方式 |
|------|----------|----------|--------------|
| 高德 | `types` | 高德官网 POI 分类编码/typecode | `output/amap/{region}/{typecode}.json` |
| 天地图 | `dataTypes` | 天地图官网搜索服务数据分类 | `output/tianditu/{region}/{dataType}.json` |

### 高德类型采集

高德 POI 类型使用 `types` 参数，当前项目通过 `AMAP_CONFIG["poi_types"]` 配置：

```python
AMAP_CONFIG = {
    "poi_types": [
        "110000",
        "120000",
        "130000",
        "140000",
        "150000",
        "160000",
        "170000",
        "180000",
        "200000",
        "210000",
        "220000",
        "230000",
        "970000",
        "980000",
    ]
}
```

说明：

- 高德官网提供完整 POI 分类编码表。
- 如果要“全部数据”，需要把官网完整分类编码补齐到 `poi_types`。
- 程序会按 `poi_types` 中的每个类型请求数据。
- 范围搜索时多个类型会用 `|` 拼接传给高德接口。
- 建议后续按类型拆分输出文件，便于入库、统计和增量更新。

### 天地图类型采集

天地图 POI 类型使用 `dataTypes` 参数，当前项目通过 `TIANDITU_CONFIG["data_types"]` 配置：

```python
TIANDITU_CONFIG = {
    "data_types": ""
}
```

说明：

- 空字符串表示不限制类型，主要依赖 `keywords` 搜索。
- 如果要按官网类型全量采集，需要按照天地图官网搜索服务的数据分类逐类设置 `dataTypes`。
- 多个分类可用英文逗号分隔。
- 为了拿到全量且便于存储，推荐逐个 `dataTypes` 单独跑，而不是一次混合多个类型。

示例配置：

```python
TIANDITU_CONFIG = {
    "data_types": "学校,医院,公园"
}
```

### 全量采集建议

1. 从高德官网下载完整 POI 分类编码表，补齐 `AMAP_CONFIG["poi_types"]`。
2. 从天地图搜索服务文档整理完整 `dataTypes` 分类。
3. 按平台、区域、类型三层维度存储：

```text
output/amap/zhengzhou/130000.json
output/amap/zhengzhou/150000.json
output/tianditu/zhengzhou/学校.json
output/tianditu/zhengzhou/医院.json
```

4. 每类数据单独去重，高德按 `id`，天地图按 `hotPointID`。
5. 入库时保留平台、类型编码、类型名称、采集区域、采集时间，避免后期混在一起不好追溯。

## 高德 POI 示例

```bash
# 郑州市学校，20km 网格
python main.py --type amap --region zhengzhou --grid-size 20 --keywords "学校"

# 郑州市区医院，矩形范围
python main.py --type amap \
  --lat-min 34.65 --lat-max 34.80 \
  --lng-min 113.55 --lng-max 113.75 \
  --keywords "医院"

# 郑州中心 5km 内机场
python main.py --type amap --lat 34.72 --lng 113.62 --radius 5 --keywords "机场"
```

## 天地图 POI 示例

```bash
# 郑州市公园，20km 网格
python main.py --type tianditu --region zhengzhou --grid-size 20 --keywords "公园"

# 郑州市区医院，矩形范围
python main.py --type tianditu \
  --lat-min 34.65 --lat-max 34.80 \
  --lng-min 113.55 --lng-max 113.75 \
  --keywords "医院"

# 郑州中心 5km 内地铁
python main.py --type tianditu --lat 34.72 --lng 113.62 --radius 5 --keywords "地铁"
```

## 常用区域

| 地区 | 代码 | 推荐网格 |
|------|------|----------|
| 郑州市 | `zhengzhou` | 20km |
| 河南省 | `henan` | 50km 或 200km |
| 全国 | `china` | 1000km |
| 北京市 | `beijing` | 100km |
| 上海市 | `shanghai` | 100km |
| 广东省 | `guangdong` | 200km |

完整区域配置见 `config/settings.py` 的 `REGION_CONFIG`。

## 输出文件

```text
output/amap/poi_{lat}_{lng}_{radius}.json
output/amap/poi_bounds_{lat_min}_{lat_max}_{lng_min}_{lng_max}.json
output/amap/poi_{region}_{grid_size}km.json

output/tianditu/poi_{lat}_{lng}_{radius}.json
output/tianditu/poi_bounds_{lat_min}_{lat_max}_{lng_min}_{lng_max}.json
output/tianditu/poi_{region}_{grid_size}km.json
```

输出 JSON 大致结构：

```json
{
  "status": "success",
  "count": 128,
  "metadata": {
    "mode": "bounds",
    "keywords": "医院"
  },
  "data": []
}
```

## 相关代码

| 文件 | 说明 |
|------|------|
| `src/crawlers/amap.py` | 高德 POI 爬虫 |
| `src/crawlers/tianditu.py` | 天地图 POI 爬虫 |
| `src/crawlers/base.py` | 爬虫基类 |
| `src/utils/geo.py` | 坐标、网格、范围工具 |
| `config/settings.py` | API Key、区域配置、请求参数 |
