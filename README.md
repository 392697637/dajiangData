# dajiangData

无人机地理数据工具集，包含三类核心能力：

1. **POI 数据爬取**：高德、天地图 POI 数据采集，支持单点搜索、矩形范围搜索、区域分块搜索
2. **大疆禁飞区数据**：DJI FlySafe 禁飞区 GeoJSON 采集，支持全国分块爬取
3. **PGSQL 空间函数**：电子围栏创建、冲突校验、航线碰撞检测、三维 A* 自动线路规划

## 文档入口

| 文档 | 内容 |
|------|------|
| [md_Poi.md](md_Poi.md) | 高德 POI、天地图 POI 爬取说明 |
| [md_DaJiang.md](md_DaJiang.md) | DJI 禁飞区爬取说明 |
| [md_PgSql.md](md_PgSql.md) | PostgreSQL/PostGIS 函数脚本说明 |

## 项目架构

```text
dajiangData/
├── main.py                    # Python 命令行入口
├── requirements.txt           # Python 依赖清单
├── config/
│   ├── __init__.py
│   └── settings.py            # 区域边界、API Key、爬虫参数配置
├── src/
│   ├── crawlers/
│   │   ├── base.py            # 爬虫基类（HTTP请求、JSON保存、数据库操作）
│   │   ├── dji.py             # DJI 禁飞区爬虫实现
│   │   ├── amap.py            # 高德 POI 爬虫实现
│   │   └── tianditu.py        # 天地图 POI 爬虫实现
│   └── utils/
│       └── geo.py             # 坐标转换、网格生成工具函数
├── PGSQL/                     # PostGIS 函数脚本目录
│   ├── 1.对接接口函数.20260602.sql
│   ├── 1.1接口校验.sql
│   ├── 2.1电子围栏创建-函数.sql
│   ├── 2.2电子围栏校验-函数..sql
│   ├── 2.3电子围栏缓冲+线判断.sql
│   └── 3.2线路自动规划.sql
└── output/                    # 爬取输出目录
    └── dji/                   # DJI 禁飞区输出
```

## 安装命令

```bash
# 创建虚拟环境
python -m venv .venv

# 激活虚拟环境（Windows）
.venv\Scripts\activate

# 安装依赖
pip install -r requirements.txt
```

## 快速命令

```bash
# 查看命令帮助
python main.py --help

# 高德 POI：郑州市学校（网格50000米=50公里）
python main.py --category poi --provider amap --action poidata --region "郑州市" --grid-size 50000 --keywords "学校"

# 高德 POI：河南省所有POI（网格200000米=200公里）
python main.py --category poi --provider amap --action poidata --region "河南省" --grid-size 200000 --keywords "all"

# 天地图 POI：郑州市公园
python main.py --category poi --provider tianditu --action poidata --region "郑州市" --grid-size 50000 --keywords "公园"

# DJI 禁飞区：河南省（网格200千米）
python main.py --category dji --action dji --region "河南省" --grid-size 200

# DJI 禁飞区：全国（网格1000千米）
python main.py --category dji --action dji --region "中国" --grid-size 1000
```

## 核心功能特性

| 功能 | 说明 |
|------|------|
| 区域边界自动获取 | 优先从数据库 `jc_sheng`/`jc_shi` 表获取，支持省/市两级 |
| 数据过滤 | 根据区域级别自动过滤，确保 city/province 字段与输入区域匹配 |
| 限流自动重试 | 触发限流时自动指数退避重试（最多5次） |
| 详细统计日志 | 输出每个网格和总体的POI类型统计信息 |
| 独立网格单位 | POI爬虫使用米，DJI爬虫使用千米，互不影响 |

## API Key 配置

### 环境变量方式（推荐）

```powershell
$env:AMAP_API_KEY="你的高德Web服务Key"
$env:TIANDITU_API_KEY="你的天地图搜索服务Key"
```

### 配置文件方式

在 `config/settings.py` 中配置：
```python
AMAP_CONFIG["api_key"] = "your_key"
TIANDITU_CONFIG["api_key"] = "your_key"
```

**注意**：DJI 禁飞区接口当前无需 API Key。

## 文件说明

| 文件/目录 | 说明 |
|-----------|------|
| `main.py` | 命令行入口，解析参数并调用对应爬虫模块 |
| `requirements.txt` | Python 依赖列表 |
| `config/settings.py` | 区域配置、API Key、爬虫参数 |
| `src/crawlers/base.py` | 爬虫基类，封装通用 HTTP 请求和数据库操作 |
| `src/crawlers/amap.py` | 高德地图 POI 爬虫实现 |
| `src/crawlers/tianditu.py` | 天地图 POI 爬虫实现 |
| `src/crawlers/dji.py` | DJI 禁飞区爬虫实现 |
| `src/utils/geo.py` | 地理工具函数（坐标转换、网格生成等） |
| `PGSQL/` | PostGIS 空间函数脚本 |
| `output/` | 爬取数据输出目录 |
