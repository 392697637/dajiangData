# 大疆禁飞区爬取说明

本模块用于采集 DJI FlySafe 禁飞区数据，输出 GeoJSON 文件。

## 特性

- 使用 DJI FlySafe 公开接口。
- 当前无需 API Key。
- 支持单点半径爬取。
- 支持省份、全国区域分块爬取。
- **区域边界优先从数据库获取**（支持省/市两级）。
- 输出标准 GeoJSON。
- 自动处理圆形、多边形和子区域。

## 快速命令

```bash
# 默认单点模式：郑州附近 50km
python main.py --category dji --action dji

# 指定坐标和半径（半径单位：米）
python main.py --category dji --action dji --lat 39.90 --lng 116.40 --radius 100000

# 河南省分块爬取（网格大小单位：千米）
python main.py --category dji --action dji --region "河南省" --grid-size 200

# 全国分块爬取（网格大小单位：千米）
python main.py --category dji --action dji --region "中国" --grid-size 1000
```

## 参数说明

| 参数 | 说明 |
|------|------|
| `--category dji` | 使用 DJI 禁飞区爬虫 |
| `--action dji` | 执行禁飞区爬取操作 |
| `--lat` | 中心点纬度 |
| `--lng` | 中心点经度 |
| `--radius` | 搜索半径，单位 **米** |
| `--region` | 区域中文名称，例如 `"河南省"`、`"郑州市"`、`"中国"` |
| `--grid-size` | 区域分块大小，单位 **千米**（与POI爬虫不同） |

## 与 POI 爬虫的区别

| 特性 | DJI 禁飞区 | POI 爬虫 |
|------|-----------|----------|
| `--grid-size` 单位 | **千米 (km)** | **米 (m)** |
| 默认网格大小 | 1000 km（全国） | 200000 米（省级） |
| 区域名称格式 | 中文（如"河南省"） | 中文（如"河南省"） |
| 数据来源 | DJI FlySafe API | 高德/天地图 API |
| API Key 需求 | 不需要 | 需要 |

## 输出文件

```text
output/dji/flyzones_{lat}_{lng}_{radius}.geojson
output/dji/flyzones_{region}_{grid_size}km.geojson
```

示例：

```text
output/dji/flyzones_henan_200.0km.geojson
output/dji/flyzones_china_500.0km.geojson
```

## 相关代码

| 文件 | 说明 |
|------|------|
| `src/crawlers/dji.py` | DJI 禁飞区爬虫 |
| `src/dji.py` | DJI 相关脚本入口或辅助代码 |
| `src/utils/geo.py` | 区域分块、坐标处理工具 |
| `config/settings.py` | 默认坐标、区域配置 |

## 注意事项

1. 大范围爬取建议设置较大的 `--grid-size`，避免请求过多。
2. 输出为 GeoJSON，适合导入 PostGIS、GeoServer、QGIS 或前端地图。
3. 若 DJI 接口返回结构变化，需要优先检查 `src/crawlers/dji.py` 的解析逻辑。

