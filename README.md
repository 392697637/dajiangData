# DJI禁飞区与POI爬虫

一个用于爬取 DJI 禁飞区数据、高德 POI 和天地图 POI 的 Python 项目，采用模块化架构，支持单点、矩形范围和区域分块三种爬取模式。

## 项目简介

本项目提供三个核心爬虫：

| 爬虫 | 数据源 | 输出格式 | 是否需要 Key |
|------|--------|----------|--------------|
| **DJI禁飞区** | 大疆 FlySafe API | GeoJSON | 否 |
| **高德POI** | 高德 Web 服务 API | JSON | 是 |
| **天地图POI** | 天地图搜索 V2.0 API | JSON | 是 |

## 项目架构

```
dajiangData/
├── main.py                    # 命令行入口
├── requirements.txt           # Python 依赖
├── README.md
├── config/
│   ├── __init__.py
│   └── settings.py            # 全局配置（含区域边界、API Key）
├── src/
│   ├── crawlers/
│   │   ├── base.py            # 爬虫基类
│   │   ├── dji.py             # DJI 禁飞区爬虫
│   │   ├── amap.py            # 高德 POI 爬虫
│   │   └── tianditu.py        # 天地图 POI 爬虫
│   └── utils/
│       └── geo.py             # 坐标转换、网格分块、范围格式化
└── output/
    ├── dji/                   # 禁飞区 GeoJSON
    ├── amap/                  # 高德 POI JSON
    └── tianditu/              # 天地图 POI JSON
```

## 功能特性

### DJI 禁飞区爬虫
- 无需认证，使用公开 API
- 支持 72+ 无人机型号
- 支持单点爬取和省份/全国分块爬取
- 输出标准 GeoJSON，自动处理圆形/多边形/子区域

### 高德 POI 爬虫
- **单点周边搜索**：v3 `place/around`（中心点 + 半径）
- **矩形范围搜索**：v5 `place/polygon`（指定边界）
- **区域分块搜索**：网格化爬取 + 按 POI `id` 去重
- 支持多种 POI 类型和关键词过滤
- 支持分页与请求限速

### 天地图 POI 爬虫
- **单点周边搜索**：queryType=3
- **矩形范围搜索**：queryType=10（多边形）/ queryType=2（视野内，自动回退）
- **区域分块搜索**：网格化爬取 + 按 `hotPointID` 去重
- 支持关键词和数据分类过滤

## 安装

```bash
# 创建虚拟环境（推荐）
python -m venv .venv

# Windows 激活
.venv\Scripts\activate

# 安装依赖
pip install -r requirements.txt
```

## 配置 API Key

在 `config/settings.py` 中直接填写，或通过环境变量注入（推荐，避免密钥入库）：

```bash
# Windows PowerShell
$env:AMAP_API_KEY="你的高德Web服务Key"
$env:TIANDITU_API_KEY="你的天地图搜索服务Key"

# Linux / macOS
export AMAP_API_KEY="你的高德Web服务Key"
export TIANDITU_API_KEY="你的天地图搜索服务Key"
```

### Key 申请说明

| 平台 | 申请地址 | 所需权限 |
|------|----------|----------|
| 高德 | [lbs.amap.com](https://lbs.amap.com/) | **Web 服务** Key，开通「搜索」服务 |
| 天地图 | [lbs.tianditu.gov.cn](https://lbs.tianditu.gov.cn/) | **搜索服务 V2.0** Key（瓦片 Key 不能用于 POI 搜索） |

> 若天地图返回 `301012 权限类型错误`，说明当前 Key 仅开通了地图瓦片，需重新申请搜索服务 Key。

## 使用方法

### 查看帮助

```bash
python main.py --help
```

---

### DJI 禁飞区

```bash
# 单点模式（默认郑州 50km）
python main.py --type dji

# 指定坐标和半径
python main.py --type dji --lat 39.90 --lng 116.40 --radius 100

# 区域分块（河南省 200km 网格）
python main.py --type dji --region henan --grid-size 200
```

---

### POI 爬取（高德 / 天地图通用）

POI 爬虫支持三种模式，通过参数组合自动选择：

| 模式 | 触发条件 | 适用场景 |
|------|----------|----------|
| 单点周边 | `--lat --lng [--radius]` | 小范围、快速验证 |
| 矩形范围 | `--lat-min --lat-max --lng-min --lng-max` | 城市/自定义边界 |
| 区域分块 | `--region [--grid-size]` | 大范围、全省/全国 |

#### 郑州市 POI 示例（推荐）

郑州市已在 `REGION_CONFIG` 中预置边界：

- 纬度：34.53 ~ 34.95
- 经度：113.45 ~ 114.05
- 推荐网格：20 km

**1. 矩形范围 — 郑州市区（金水/二七附近）**

```bash
# 高德
python main.py --type amap \
  --lat-min 34.65 --lat-max 34.80 \
  --lng-min 113.55 --lng-max 113.75 \
  --keywords "医院"

# 天地图
python main.py --type tianditu \
  --lat-min 34.65 --lat-max 34.80 \
  --lng-min 113.55 --lng-max 113.75 \
  --keywords "医院"
```

**2. 区域分块 — 整个郑州市**

```bash
# 高德（20km 网格）
python main.py --type amap --region zhengzhou --grid-size 20 --keywords "学校"

# 天地图
python main.py --type tianditu --region zhengzhou --grid-size 20 --keywords "公园"
```

**3. 单点周边 — 郑州中心（默认坐标 34.72, 113.62）**

```bash
# 高德（半径 5 公里）
python main.py --type amap --lat 34.72 --lng 113.62 --radius 5 --keywords "机场"

# 天地图
python main.py --type tianditu --lat 34.72 --lng 113.62 --radius 5 --keywords "地铁"
```

**4. 河南省范围（更大区域）**

```bash
python main.py --type amap --region henan --grid-size 50 --keywords "加油站"
```

---

### 支持的省份/区域

| 地区 | 代码 | 推荐网格 |
|------|------|----------|
| **郑州市** | zhengzhou | 20km |
| **河南省** | henan | 200km |
| **全国** | china | 1000km |
| 北京市 | beijing | 100km |
| 上海市 | shanghai | 100km |
| 广东省 | guangdong | 200km |
| … | … | … |

完整列表见 `config/settings.py` 中的 `REGION_CONFIG`（含全国 34 个省级行政区 + 郑州市）。

## 配置说明

配置文件：`config/settings.py`

### 通用配置

```python
DEFAULT_LAT = 34.72    # 默认纬度（郑州）
DEFAULT_LNG = 113.62   # 默认经度（郑州）
DEFAULT_RADIUS = 50    # 默认搜索半径（公里）
TIMEOUT = 30           # 请求超时（秒）
```

### 高德 POI 配置

```python
AMAP_CONFIG = {
    "around_api_url": "https://restapi.amap.com/v3/place/around",
    "polygon_api_url": "https://restapi.amap.com/v5/place/polygon",
    "api_key": os.environ.get("AMAP_API_KEY", "your_amap_api_key"),
    "poi_types": ["110000", "120000", ...],
    "radius": 5000,              # 周边搜索半径（米）
    "polygon_page_size": 25,
    "request_delay": 0.2,
    "region_config": REGION_CONFIG,
}
```

### 天地图 POI 配置

```python
TIANDITU_CONFIG = {
    "api_url": "https://api.tianditu.gov.cn/v2/search",
    "api_key": os.environ.get("TIANDITU_API_KEY", "your_tianditu_api_key"),
    "default_keyword": "POI",
    "page_size": 100,
    "level": 12,
    "request_delay": 0.2,
    "region_config": REGION_CONFIG,
}
```

## 输出文件

### DJI 禁飞区

```
output/dji/flyzones_{lat}_{lng}_{radius}.geojson      # 单点
output/dji/flyzones_{region}_{grid_size}km.geojson    # 区域
```

### POI（高德 / 天地图）

```
output/amap/poi_{lat}_{lng}_{radius}.json                          # 单点
output/amap/poi_bounds_{lat_min}_{lat_max}_{lng_min}_{lng_max}.json  # 范围
output/amap/poi_{region}_{grid_size}km.json                        # 区域

output/tianditu/   # 同上命名规则
```

输出 JSON 结构：

```json
{
  "status": "success",
  "count": 128,
  "metadata": {
    "mode": "bounds",
    "bounds": { "lat_min": 34.65, "lat_max": 34.80, "lng_min": 113.55, "lng_max": 113.75 },
    "keywords": "医院"
  },
  "data": [ ... ]
}
```

## 核心类与方法

| 类 | 方法 | 说明 |
|----|------|------|
| `DJIFlySafeCrawler` | `crawl()` | 单点禁飞区 |
| | `crawl_region()` | 区域分块 |
| `AmapPOICrawler` | `crawl()` | 单点周边 POI |
| | `crawl_bounds()` | 矩形范围 POI |
| | `crawl_region()` | 区域分块 POI |
| `TiandituPOICrawler` | `crawl()` | 单点周边 POI |
| | `crawl_bounds()` | 矩形范围 POI |
| | `crawl_region()` | 区域分块 POI |

## 测试验证（郑州市）

本地已验证 CLI 和范围参数解析正常。POI 实际爬取需配置具备**搜索权限**的 API Key：

```bash
# 1. 设置 Key
$env:AMAP_API_KEY="你的高德Key"
$env:TIANDITU_API_KEY="你的天地图搜索Key"

# 2. 郑州市区小范围测试（推荐先用此命令验证）
python main.py --type amap \
  --lat-min 34.65 --lat-max 34.80 \
  --lng-min 113.55 --lng-max 113.75 \
  --keywords "医院"

python main.py --type tianditu \
  --lat-min 34.65 --lat-max 34.80 \
  --lng-min 113.55 --lng-max 113.75 \
  --keywords "医院"

# 3. 成功后检查输出
# output/amap/poi_bounds_34.65_34.8_113.55_113.75.json
# output/tianditu/poi_bounds_34.65_34.8_113.55_113.75.json
```

## 注意事项

1. **DJI API 无需认证**，可直接使用
2. **POI 需配置搜索类 API Key**，瓦片/JS API Key 不能用于 POI 爬取
3. 大范围分块爬取请合理设置 `--grid-size`，避免请求过多触发限流
4. 可通过 `request_delay` 调整请求间隔（默认 0.2 秒）
5. 区域分块结果会自动去重（高德按 `id`，天地图按 `hotPointID`）

## 扩展指南

添加新数据源：

1. 在 `config/settings.py` 添加配置
2. 在 `src/crawlers/` 创建爬虫类（继承 `BaseCrawler`）
3. 在 `src/crawlers/__init__.py` 导出
4. 在 `main.py` 添加 `--type` 选项

## License

MIT License
