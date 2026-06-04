# POI 数据爬取模块

## 概述

本模块用于采集高德地图和天地图的 POI（Point of Interest）数据，支持多种搜索模式，统一通过 `main.py` 入口调用。

---

## 命令行接口结构

```bash
main.py --category <poi|dji> [--provider <amap|tianditu>] [--action <poitype|poidata>]
```

### 接口层级

| 层级 | 参数 | 选项 | 说明 |
|------|------|------|------|
| 一级分类 | `--category` | `poi`, `dji` | **必填**，选择数据模块 |
| 数据源 | `--provider` | `amap`, `tianditu` | POI模块**必填**，选择地图数据源 |
| 操作类型 | `--action` | `poitype`, `poidata` | POI模块**必填**，选择操作类型 |

---

## 接口详细说明

### 1. POI 模块接口

#### 1.1 获取 POI 类型列表

**接口作用**：从数据库读取高德或天地图的 POI 分类类型列表，用于了解可用的 POI 分类编码和名称。

**调用方式**：

```bash
# 高德类型列表入库到 gis_poiType_gd
python main.py --category poi --provider amap --action poitype --save-to-db

# 天地图类型列表入库到 gis_poiType_td
python main.py --category poi --provider tianditu --action poitype --save-to-db

# 高德地图 - 从数据库读取POI类型
python main.py --category poi --provider amap --action poitype

# 天地图 - 从数据库读取POI类型
python main.py --category poi --provider tianditu --action poitype


```

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `--category` | string | 是 | 固定值 `poi` |
| `--provider` | string | 是 | `amap` 或 `tianditu` |
| `--action` | string | 是 | 固定值 `poitype` |
| `--save-to-db` | bool | 否 | 将 POI 类型写入对应数据库表 |

**接口实现说明**：

| 数据源 | 获取方式 | 入库表 |
|--------|----------|--------|
| 高德 | `main.py` 调用 `_get_amap_poi_types()`，从数据库 `gis_poiType_gd` 表读取 | `gis_poiType_gd` |
| 天地图 | `main.py` 调用 `_get_tianditu_poi_types()`，从数据库 `gis_poiType_td` 表读取 | `gis_poiType_td` |

**核心代码函数**：

| 函数名 | 功能 | 位置 |
|--------|------|------|
| `_get_amap_poi_types(db_config)` | 从数据库读取高德POI类型列表 | `main.py` 第34行 |
| `_get_tianditu_poi_types(db_config)` | 从数据库读取天地图POI类型列表 | `main.py` 第114行 |
| `_save_poi_types_to_db(types_data, provider, db_config, type_table)` | 将POI类型数据入库 | `main.py` 第194行 |
| `_print_poi_types(types_data, provider)` | 打印POI类型列表到控制台 | `main.py` 第294行 |

**数据库表结构**（`gis_poiType_gd` / `gis_poiType_td`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | BIGSERIAL | 主键自增 |
| `provider` | VARCHAR(32) | 数据源标识（amap/tianditu） |
| `type_code` | VARCHAR(32) | POI类型编码 |
| `type_name` | VARCHAR(128) | POI类型名称 |
| `parent_code` | VARCHAR(32) | 父类型编码（二级分类） |
| `level` | INT | 类型层级（1=一级分类，2=二级分类） |
| `created_at` | TIMESTAMPTZ | 创建时间 |

**返回结果**（控制台输出）：

**高德地图返回示例**：
```
============================================================
Amap POI Module
============================================================

Action: Get POI Types
[INFO] 从数据库读取高德POI类型成功

=== 高德 POI类型列表 ===

[110000] 交通设施服务
  └── [110100] 铁路与地铁
  └── [110200] 道路附属设施

[120000] 金融保险服务
  └── [120100] 银行
  └── [120200] ATM

...

共 14 个一级分类
```

**天地图返回示例**：
```
============================================================
Tianditu POI Module
============================================================

Action: Get POI Types
[INFO] 从数据库读取天地图POI类型成功

=== 天地图 POI类型列表 ===

[001] 学校
  └── [001001] 小学
  └── [001002] 中学

[002] 医院
  └── [002001] 综合医院
  └── [002002] 专科医院

...

共 8 个一级分类
```

**注意事项**：
- POI类型数据存储在数据库中，需要先执行 `--save-to-db` 入库后才能读取
- 首次使用时，如果数据库中没有数据，会提示"数据库中暂无POI类型数据，请先执行 --save-to-db 入库"
- 入库操作会先删除旧表再重建（`DROP TABLE IF EXISTS`），请注意数据备份
- 需要确保配置了正确的数据库连接信息（`config/settings.py` 中的 `DATABASE_CONFIG`）

---

#### 1.2 获取 POI 数据

**接口作用**：根据指定的搜索范围和条件，爬取高德或天地图的 POI 数据。

**支持三种搜索模式**：

##### 模式一：单点周边搜索

**调用方式**：
```bash
python main.py --category poi --provider amap --action poidata \
  --lat 34.72 --lng 113.62 --radius 5 --keywords "学校"
```

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `--category` | string | 是 | 固定值 `poi` |
| `--provider` | string | 是 | `amap` 或 `tianditu` |
| `--action` | string | 是 | 固定值 `poidata` |
| `--lat` | float | 否 | 中心纬度，默认使用配置的默认值 |
| `--lng` | float | 否 | 中心经度，默认使用配置的默认值 |
| `--radius` | float | 否 | 搜索半径（公里），默认 5 公里 |
| `--keywords` | string | 否 | 搜索关键词，如"学校"、"医院" |

**返回结果**：

POI 数据默认不再只输出 JSON 文件，而是直接写入 PostgreSQL：

| 数据源 | 入库表 |
|--------|--------|
| 高德 | `gis_poiType_gd` |
| 天地图 | `gis_poiType_td` |

控制台会输出入库数量：

```text
成功！共获取 128 个高德POI，已入库 128 条
入库表: gis_poiType_gd
```

入库表会自动创建，核心字段如下：

| 字段 | 说明 |
|------|------|
| `source_platform` | 数据源：`amap` 或 `tianditu` |
| `poi_id` | 平台 POI 唯一 ID |
| `name` | POI 名称 |
| `type_code` | POI 类型编码 |
| `type_name` | POI 类型名称 |
| `address` | 地址 |
| `province/city/district` | 行政区信息 |
| `lng/lat` | 坐标 |
| `geom` | PostGIS 点位，SRID=4326 |
| `raw_data` | 平台原始 JSON |
| `metadata` | 采集参数，例如模式、区域、关键词 |

函数返回结构仍保留原始数据，便于调试：

```json
{
  "status": "success",
  "count": 128,
  "metadata": {
    "mode": "around",
    "location": {"lat": 34.72, "lng": 113.62},
    "radius": 5000,
    "keywords": "学校"
  },
  "data": [
    {
      "id": "B0FFFHB25F",
      "name": "郑州市第一中学",
      "type": "科教文化服务|学校|中学",
      "typecode": "130201",
      "location": "113.6453,34.7521",
      "address": "郑州市金水区文化路60号",
      "cityname": "郑州市",
      "adname": "金水区"
    }
  ]
}
```

**注意事项**：
- 坐标使用 WGS84 坐标系
- radius 参数单位为公里，内部转换为米
- keywords 为空时返回所有类型 POI

---

##### 模式二：矩形范围搜索

**调用方式**：
```bash
python main.py --category poi --provider amap --action poidata \
  --lat-min 34.65 --lat-max 34.80 --lng-min 113.55 --lng-max 113.75 --keywords "医院"
```

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `--category` | string | 是 | 固定值 `poi` |
| `--provider` | string | 是 | `amap` 或 `tianditu` |
| `--action` | string | 是 | 固定值 `poidata` |
| `--lat-min` | float | 是 | 最小纬度 |
| `--lat-max` | float | 是 | 最大纬度 |
| `--lng-min` | float | 是 | 最小经度 |
| `--lng-max` | float | 是 | 最大经度 |
| `--keywords` | string | 否 | 搜索关键词 |

**返回结果**：

POI 数据默认直接入库：

| 数据源 | 入库表 |
|--------|--------|
| 高德 | `gis_poiType_gd` |
| 天地图 | `gis_poiType_td` |

```json
{
  "status": "success",
  "count": 45,
  "metadata": {
    "mode": "bounds",
    "bounds": {
      "lat_min": 34.65, "lat_max": 34.80,
      "lng_min": 113.55, "lng_max": 113.75
    },
    "keywords": "医院"
  },
  "data": [...]
}
```

**注意事项**：
- 四个边界参数必须同时提供
- 范围不宜过大，建议单次搜索面积不超过 100 平方公里
- 天地图矩形搜索优先使用多边形搜索，失败后自动降级为视野内搜索

---

##### 模式三：区域分块搜索

**调用方式**：
```bash
python main.py --category poi --provider amap --action poidata \
  --region zhengzhou --grid-size 20 --keywords "学校"
```

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `--category` | string | 是 | 固定值 `poi` |
| `--provider` | string | 是 | `amap` 或 `tianditu` |
| `--action` | string | 是 | 固定值 `poidata` |
| `--region` | string | 是 | 预定义区域名称（见下表） |
| `--grid-size` | float | 否 | 网格大小（公里），使用区域默认值 |
| `--keywords` | string | 否 | 搜索关键词 |

**支持的区域**：

| 区域代码 | 名称 | 默认网格 |
|----------|------|----------|
| `zhengzhou` | 郑州市 | 20km |
| `henan` | 河南省 | 200km |
| `china` | 中国 | 1000km |
| `beijing` | 北京市 | 100km |
| `shanghai` | 上海市 | 100km |
| `guangdong` | 广东省 | 200km |

**返回结果**：

POI 数据默认直接入库：

| 数据源 | 入库表 |
|--------|--------|
| 高德 | `gis_poiType_gd` |
| 天地图 | `gis_poiType_td` |

```json
{
  "status": "success",
  "count": 256,
  "metadata": {
    "mode": "region",
    "region": "郑州市",
    "grid_size_km": 20,
    "total_grids": 25,
    "success_grids": 24,
    "fail_grids": 1,
    "total_before_dedup": 289,
    "keywords": "学校"
  },
  "data": [...]
}
```

**注意事项**：
- 区域配置定义在 `config/settings.py` 的 `REGION_CONFIG` 中
- 会自动对网格边界进行去重，避免重复数据
- 适合大规模区域采集，如城市、省份、全国

---

## 数据源配置

| 平台 | 数据源 | API 版本 | 输出目录 | 是否需要 Key |
|------|--------|----------|----------|--------------|
| 高德 POI | 高德 Web 服务 API | v3/v5 | `output/amap/` | 是 |
| 天地图 POI | 天地图搜索 V2.0 API | V2.0 | `output/tianditu/` | 是 |

---

## API Key 配置

### 方式一：环境变量（推荐）

```powershell
$env:AMAP_API_KEY="你的高德Web服务Key"
$env:TIANDITU_API_KEY="你的天地图搜索服务Key"
```

### 方式二：配置文件

在 `config/settings.py` 中配置：

```python
AMAP_CONFIG["api_key"] = "your_key"
TIANDITU_CONFIG["api_key"] = "your_key"
```

**注意事项**：
- 天地图瓦片 Key 不能用于 POI 搜索，需申请搜索服务 V2.0 Key
- 若返回 `301012 权限类型错误`，需要重新申请正确的 Key

---

## POI 类型编码体系

### 高德 POI 一级分类

| 编码 | 名称 | 说明 |
|------|------|------|
| 110000 | 交通设施服务 | 铁路、地铁、公交、停车场等 |
| 120000 | 金融保险服务 | 银行、ATM、保险公司等 |
| 130000 | 科教文化服务 | 学校、图书馆、博物馆等 |
| 140000 | 体育休闲服务 | 体育场馆、公园、景区等 |
| 150000 | 医疗保健服务 | 医院、药店、诊所等 |
| 160000 | 住宿服务 | 酒店、宾馆、民宿等 |
| 170000 | 餐饮服务 | 餐厅、快餐、咖啡馆等 |
| 180000 | 购物服务 | 商场、超市、便利店等 |
| 200000 | 商务住宅 | 写字楼、住宅区等 |
| 210000 | 地名地址信息 | 行政区划、道路、门牌号等 |
| 220000 | 公共设施 | 公厕、垃圾站、加油站等 |
| 230000 | 行政区域 | 省、市、区、县等 |
| 970000 | 风景名胜 | 自然景观、古迹等 |
| 980000 | 商务大厦 | 写字楼、商业中心等 |

---

## 输出格式说明

### JSON 结构字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | 执行状态：`success` 或 `failed` |
| `count` | int | 获取的 POI/禁飞区数量 |
| `metadata` | object | 元数据信息 |
| `metadata.mode` | string | 搜索模式：`around`/`bounds`/`region` |
| `metadata.location` | object | 中心点坐标（around 模式） |
| `metadata.bounds` | object | 边界范围（bounds 模式） |
| `metadata.region` | string | 区域名称（region 模式） |
| `data` | array | POI/禁飞区数据列表 |

---

## 通用注意事项

1. **API 限流**：每个请求之间有 0.2 秒间隔，避免触发限流
2. **数据去重**：区域分块模式会自动去重，高德按 `id`，天地图按 `hotPointID`
3. **坐标系统**：统一使用 WGS84 坐标系（EPSG:4326）
4. **网络超时**：请求超时时间为 30 秒，可在配置中调整
5. **数据库入库**：当前 POI 数据默认写入 PostgreSQL；高德写入 `gis_poiType_gd`，天地图写入 `gis_poiType_td`

---

## 相关代码文件

| 文件 | 说明 |
|------|------|
| `main.py` | 命令行入口 |
| `src/crawlers/amap.py` | 高德 POI 爬虫实现 |
| `src/crawlers/tianditu.py` | 天地图 POI 爬虫实现 |
| `src/crawlers/base.py` | 爬虫基类（HTTP请求、JSON保存、数据库操作） |
| `src/utils/geo.py` | 坐标转换、网格生成工具函数 |
| `config/settings.py` | API Key、区域、类型配置 |
