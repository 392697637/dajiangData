# 大疆禁飞区爬取说明

本模块用于采集 DJI FlySafe 禁飞区数据，输出 GeoJSON 文件。

## 特性

- 使用 DJI FlySafe 公开接口。
- 当前无需 API Key。
- 支持单点半径爬取。
- 支持省份、全国区域分块爬取。
- 输出标准 GeoJSON。
- 自动处理圆形、多边形和子区域。

## 快速命令

```bash
# 默认单点模式：郑州附近 50km
python main.py --type dji

# 指定坐标和半径
python main.py --type dji --lat 39.90 --lng 116.40 --radius 100

# 河南省分块爬取
python main.py --type dji --region henan --grid-size 200

# 全国分块爬取
python main.py --type dji --region china --grid-size 1000
```

## 参数说明

| 参数 | 说明 |
|------|------|
| `--type dji` | 使用 DJI 禁飞区爬虫 |
| `--lat` | 中心点纬度 |
| `--lng` | 中心点经度 |
| `--radius` | 搜索半径，单位 km |
| `--region` | 区域代码，例如 `zhengzhou`、`henan`、`china` |
| `--grid-size` | 区域分块大小，单位 km |

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

