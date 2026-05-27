# DJI禁飞区与高德POI爬虫

一个用于爬取DJI禁飞区数据和高德POI数据的Python项目，采用模块化架构设计，支持多种数据源扩展。

## 项目简介

本项目提供了两个核心爬虫功能：
- **DJI禁飞区爬虫**：爬取大疆无人机禁飞区/限飞区数据，输出标准GeoJSON格式
- **高德POI爬虫**：爬取高德地图兴趣点(POI)数据，支持多种类型和关键词搜索

## 项目架构

```
dajiangData/
├── main.py                    # 命令行入口文件
├── requirements.txt           # Python依赖列表
├── README.md                  # 项目文档
├── config/                    # 配置模块
│   ├── __init__.py            # 配置导出
│   └── settings.py            # 配置参数
├── src/                       # 源代码
│   ├── __init__.py            # 模块初始化
│   ├── crawlers/              # 爬虫模块
│   │   ├── __init__.py        # 爬虫导出
│   │   ├── base.py            # 爬虫基类
│   │   ├── dji.py             # DJI禁飞区爬虫
│   │   └── amap.py            # 高德POI爬虫
│   └── utils/                 # 工具函数
│       ├── __init__.py        # 工具导出
│       └── geo.py             # 地理工具函数
└── output/                    # 输出目录（自动创建）
    ├── dji/                   # DJI禁飞区数据
    └── amap/                  # 高德POI数据
```

## 架构说明

| 模块 | 说明 | 职责 |
|------|------|------|
| **main.py** | 入口文件 | 解析命令行参数，调用对应爬虫 |
| **config/** | 配置模块 | 集中管理所有配置参数 |
| **src/crawlers/** | 爬虫模块 | 实现具体的爬取逻辑 |
| **src/utils/** | 工具模块 | 提供通用工具函数 |
| **output/** | 输出目录 | 存储爬取结果文件 |

## 功能特性

### DJI禁飞区爬虫
- ✅ 无需认证，使用公开API
- ✅ 支持动态获取无人机型号列表（72+型号）
- ✅ 支持自定义坐标和搜索半径
- ✅ 自动将圆形区域转换为多边形
- ✅ 输出标准GeoJSON格式
- ✅ 支持多种禁飞区级别筛选
- ✅ 支持按省份/区域分块爬取（支持全国34个省份/直辖市/自治区/特别行政区）

### 高德POI爬虫
- ✅ 支持周边POI搜索
- ✅ 支持多种POI类型
- ✅ 支持分页获取数据
- ✅ 支持关键词搜索
- ✅ 输出JSON格式

## 安装依赖

```bash
# 安装基础依赖
pip install -r requirements.txt
```

## 使用方法

### 爬取DJI禁飞区数据 - 单点模式

```bash
# 使用默认配置（郑州50公里范围）
python main.py --type dji

# 指定区域（北京100公里范围）
python main.py --type dji --lat 39.90 --lng 116.40 --radius 100

# 指定无人机型号
python main.py --type dji --drone dji-mini-4-pro
```

### 爬取DJI禁飞区数据 - 省份/区域模式

```bash
# 爬取北京市（100km分块）
python main.py --type dji --region beijing --grid-size 100

# 爬取河南省（200km分块）
python main.py --type dji --region henan --grid-size 200

# 爬取整个中国（1000km分块）
python main.py --type dji --region china --grid-size 1000

# 爬取其他省份
python main.py --type dji --region guangdong --grid-size 200
python main.py --type dji --region sichuan --grid-size 200
```

### 支持的省份/区域列表

| 地区 | 代码 | 说明 | 推荐网格大小 |
|------|------|------|--------------|
| **全国** | china | 中国全境 | 1000km |
| **华北** | beijing | 北京市 | 100km |
| | tianjin | 天津市 | 100km |
| | hebei | 河北省 | 200km |
| | shanxi | 山西省 | 200km |
| | neimenggu | 内蒙古自治区 | 300km |
| **东北** | liaoning | 辽宁省 | 200km |
| | jilin | 吉林省 | 200km |
| | heilongjiang | 黑龙江省 | 300km |
| **华东** | shanghai | 上海市 | 100km |
| | jiangsu | 江苏省 | 200km |
| | zhejiang | 浙江省 | 200km |
| | anhui | 安徽省 | 200km |
| | fujian | 福建省 | 200km |
| | jiangxi | 江西省 | 200km |
| | shandong | 山东省 | 200km |
| **华中** | henan | 河南省 | 200km |
| | hubei | 湖北省 | 200km |
| | hunan | 湖南省 | 200km |
| **华南** | guangdong | 广东省 | 200km |
| | guangxi | 广西壮族自治区 | 200km |
| | hainan | 海南省 | 200km |
| **西南** | chongqing | 重庆市 | 150km |
| | sichuan | 四川省 | 200km |
| | guizhou | 贵州省 | 200km |
| | yunnan | 云南省 | 200km |
| | xizang | 西藏自治区 | 300km |
| **西北** | shaanxi | 陕西省 | 200km |
| | gansu | 甘肃省 | 250km |
| | qinghai | 青海省 | 300km |
| | ningxia | 宁夏回族自治区 | 150km |
| | xinjiang | 新疆维吾尔自治区 | 400km |
| **港澳台** | hongkong | 香港特别行政区 | 50km |
| | macau | 澳门特别行政区 | 50km |
| | taiwan | 台湾省 | 200km |

### 爬取高德POI数据

```bash
# 爬取POI数据（需先配置API Key）
python main.py --type amap

# 指定关键词搜索
python main.py --type amap --keywords "机场"
```

### 查看帮助

```bash
python main.py --help
```

## 配置说明

配置文件位于 `config/settings.py`：

### 通用配置
```python
DEFAULT_LAT = 34.72    # 默认纬度（郑州）
DEFAULT_LNG = 113.62   # 默认经度（郑州）
DEFAULT_RADIUS = 50    # 默认搜索半径（公里）
TIMEOUT = 30           # 请求超时时间（秒）
```

### DJI禁飞区配置
```python
DJI_CONFIG = {
    "api_url": "https://flysafe-api.dji.com/api/qep/geo/feedback/areas/in_rectangle",
    "drones_api_url": "https://flysafe-api.dji.com/dji/drones",
    "output_dir": "output/dji",
    "params": {
        "default_drone": "dji-mavic-3",
        "zones_mode": "flysafe_website",
        "levels": "0,1,2,3,7,8,10"
    },
    "region_config": {  # 包含全国34个省份/区域配置
        "beijing": {...},
        "henan": {...},
        "china": {...}
    }
}
```

### 高德POI配置
```python
AMAP_CONFIG = {
    "api_url": "https://restapi.amap.com/v3/place/around",
    "output_dir": "output/amap",
    "api_key": "your_amap_api_key",  # 需要配置
    "poi_types": [...],
    "radius": 5000
}
```

## DJI禁飞区级别说明

| 级别 | 说明 |
|------|------|
| 0 | 机场禁飞区 |
| 1 | 机场限飞区 |
| 2 | 国家级机场禁飞区 |
| 3 | 临时限飞区 |
| 7 | 干扰源区域 |
| 8 | 军事管理区 |
| 10 | 特殊管控区 |

## 支持的无人机型号

项目支持72+种DJI无人机型号，包括：
- DJI Mavic 3 / Mavic 3 Pro / Mavic 3 Classic
- DJI Mini 3 Pro / Mini 4 Pro / Mini 5 Pro
- DJI Air 2S / Air 3 / Air 3S
- DJI Avata / Avata 2
- DJI Inspire 2 / Inspire 3
- DJI Matrice 300 / 350 / 400 系列
- 以及更多农业无人机型号

## 输出文件

### DJI禁飞区
```
# 单点模式
output/dji/flyzones_{lat}_{lng}_{radius}.geojson

# 区域模式
output/dji/flyzones_{region_name}_{grid_size}km.geojson
```

### 高德POI
```
output/amap/poi_{lat}_{lng}_{radius}.json
```

## 核心类与方法

### BaseCrawler（爬虫基类）
| 方法 | 说明 |
|------|------|
| `_make_request()` | 发送HTTP请求 |
| `_save_json()` | 保存JSON数据到文件 |

### DJIFlySafeCrawler
| 方法 | 说明 |
|------|------|
| `get_drones_list()` | 获取无人机型号列表 |
| `set_drone_model()` | 设置无人机型号 |
| `crawl()` | 爬取单点禁飞区数据 |
| `crawl_region()` | 按区域分块爬取禁飞区数据 |

### AmapPOICrawler
| 方法 | 说明 |
|------|------|
| `crawl()` | 爬取POI数据 |

## 扩展指南

如需添加新的数据源爬虫，只需：

1. 在 `config/settings.py` 中添加新配置
2. 在 `src/crawlers/` 中创建新爬虫类（继承BaseCrawler）
3. 在 `src/crawlers/__init__.py` 中导出新类
4. 在 `main.py` 中添加命令行参数支持

## 注意事项

1. **DJI API无需认证**，可直接访问
2. **高德POI需要配置API Key**（在高德地图开放平台申请）
3. 建议合理控制请求频率，避免被限流
4. 网络环境需要能访问DJI和高德服务器
5. 区域分块爬取时，建议根据区域大小设置合适的网格大小（小省份用50-100km，大省份用200-300km）

## License

MIT License
