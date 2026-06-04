# dajiangData

本仓库包含三类能力：

1. POI 数据爬取：高德、天地图 POI 数据采集。
2. 大疆禁飞区数据：DJI FlySafe 禁飞区 GeoJSON 采集。
3. PGSQL 空间函数：电子围栏创建、校验、航线碰撞检测、自动线路规划等 PostGIS SQL。

## 文档入口

| 文档 | 内容 |
|------|------|
| [md_Poi.md](md_Poi.md) | 高德 POI、天地图 POI 爬取说明，支持按官网类型全量采集 |
| [md_DaJiang.md](md_DaJiang.md) | DJI 禁飞区爬取说明 |
| [md_PgSql.md](md_PgSql.md) | PostgreSQL/PostGIS 函数脚本说明 |

## 项目结构

```text
dajiangData/
├── main.py                    # Python 命令行入口
├── requirements.txt           # Python 依赖
├── config/
│   ├── __init__.py
│   └── settings.py            # 区域边界、API Key、爬虫参数
├── src/
│   ├── crawlers/
│   │   ├── base.py
│   │   ├── dji.py
│   │   ├── amap.py
│   │   └── tianditu.py
│   └── utils/
│       └── geo.py
├── PGSQL/                     # PostGIS 函数脚本
└── output/                    # 爬取输出目录
```

## 快速安装

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

## 快速命令

```bash
# 查看命令帮助
python main.py --help

# 高德 POI：郑州市学校
python main.py --type amap --region zhengzhou --grid-size 20 --keywords "学校"

# 天地图 POI：郑州市公园
python main.py --type tianditu --region zhengzhou --grid-size 20 --keywords "公园"

# DJI 禁飞区：河南省
python main.py --type dji --region henan --grid-size 200
```

## API Key

POI 爬取需要配置搜索服务 Key：

```powershell
$env:AMAP_API_KEY="你的高德Web服务Key"
$env:TIANDITU_API_KEY="你的天地图搜索服务Key"
```

DJI 禁飞区接口当前无需 Key。
