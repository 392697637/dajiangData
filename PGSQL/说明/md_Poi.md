# POI 数据爬取模块

## 概述

本模块用于采集高德地图和天地图的 POI（Point of Interest）数据，支持多种搜索模式，统一通过 `main.py` 入口调用。

**核心特性：**
- 支持从数据库动态获取区域边界（省/市两级）
- 支持按区域级别过滤数据（市级只保留city匹配，省级只保留province匹配）
- 支持限流自动重试（指数退避策略）
- 支持详细的POI类型统计日志
- 网格大小单位为**米**，便于精细控制

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

POI数据获取支持**两种搜索模式**，系统会根据传入参数自动判断使用哪种模式，优先级从高到低为：**区域分块模式 > 矩形范围模式**。

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

**两种搜索模式**（优先级：区域分块 > 矩形范围）：

##### 模式一：矩形范围搜索（Bounds Crawl）

**适用场景**：自定义矩形区域搜索，如搜索某个城市范围内的POI

**调用方式**：
```bash
# 搜索郑州市指定矩形范围内的医院
python main.py --category poi --provider amap --action poidata \
  --lat-min 34.65 --lat-max 34.80 --lng-min 113.55 --lng-max 113.75 --keywords "医院"

# 获取矩形范围内所有POI类型
python main.py --category poi --provider amap --action poidata \
  --lat-min 34.65 --lat-max 34.80 --lng-min 113.55 --lng-max 113.75 --keywords "全部"
```

##### 天地图矩形范围示例
```bash
# 天地图矩形范围搜索 郑州市指定区域内的公园
python main.py --category poi --provider tianditu --action poidata --lat-min 34.65 --lat-max 34.80 --lng-min 113.55 --lng-max 113.75 --keywords "公园"
```

> 注意：天地图支持 `all` / `全部` 全类型模式，但会按类型表中的每个分类名称循环搜索，效率较低。推荐直接使用具体关键词，例如 `学校`、`医院`、`公园`。

### 郑州高新区（示例矩形范围）

以下为 `郑州高新区` 的近似矩形边界示例，供快速测试使用；请根据实际需要调整边界以精确覆盖目标区域。

```bash
# 示例：爬取郑州高新区范围内所有POI（近似边界）
python main.py --category poi --provider amap --action poidata --lat-min 34.70 --lat-max 34.78 --lng-min 113.56 --lng-max 113.66 --keywords "全部"
```

> 说明：上述坐标为近似值，若需精确行政边界建议从 `jc_shi`/`jc_xian` 等矢量表或在线地图工具获取多边形边界。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `--category` | string | 是 | 固定值 `poi` |
| `--provider` | string | 是 | `amap` 或 `tianditu` |
| `--action` | string | 是 | 固定值 `poidata` |
| `--lat-min` | float | 是 | 最小纬度（矩形左下角） |
| `--lat-max` | float | 是 | 最大纬度（矩形右上角） |
| `--lng-min` | float | 是 | 最小经度（矩形左下角） |
| `--lng-max` | float | 是 | 最大经度（矩形右上角） |
| `--keywords` | string | 否 | 搜索关键词；高德支持 `all` 或 `全部` 获取所有类型，天地图需使用具体关键词，例如 `学校`、`医院`、`公园` |

**模式特点**：
- 灵活定义搜索范围，适合不规则区域
- 四个边界参数必须同时提供
- 范围不宜过大，建议单次搜索面积不超过 100 平方公里
- 天地图矩形搜索优先使用多边形搜索，失败后自动降级为视野内搜索

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

##### 模式二：区域分块搜索（Region Crawl）

**适用场景**：大规模区域采集，如城市、省份、全国范围的POI数据采集

**调用方式**：
```bash
# 搜索郑州市范围内的学校（网格大小50000米=50公里）
python main.py --category poi --provider amap --action poidata --region "郑州市" --grid-size 50000 --keywords "学校"

# 获取河南省范围内所有POI类型（网格大小200000米=200公里）
python main.py --category poi --provider amap --action poidata --region "河南省" --grid-size 200000 --keywords "all"
```

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `--category` | string | 是 | 固定值 `poi` |
| `--provider` | string | 是 | `amap` 或 `tianditu` |
| `--action` | string | 是 | 固定值 `poidata` |
| `--region` | string | 是 | **中文区域名称**（如"河南省"、"郑州市"） |
| `--grid-size` | int | 否 | 网格大小（**米**），默认根据区域级别自动设置 |
| `--keywords` | string | 否 | 搜索关键词；高德支持 `all` 或 `全部` 获取所有类型，天地图需使用具体关键词，例如 `学校`、`医院`、`公园` |

**模式特点**：
- 自动将大区域划分为多个网格进行爬取
- 支持自动去重，避免重复数据
- 适合大规模区域采集，如城市、省份、全国
- **区域边界优先从数据库获取**（`jc_sheng` 表查省级，`jc_shi` 表查市级）
- 数据库查询失败时回退到配置文件 `config/settings.py` 中的 `REGION_CONFIG`
- 根据区域级别自动过滤数据（市级只保留city匹配，省级只保留province匹配）

**区域级别与默认网格大小**：

| 区域级别 | 默认网格大小 | 说明 |
|----------|--------------|------|
| 省级 | 200000 米（200公里） | 如河南省 |
| 市级 | 100000 米（100公里） | 如郑州市 |

**数据库表结构**（用于获取区域边界）：

**省级表 `jc_sheng`**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `gid` | int4 | 主键 |
| `shengname` | varchar(24) | 省份名称（中文） |
| `shengcode` | varchar(10) | 省份代码 |
| `geom` | geometry(MULTIPOLYGON, 4326) | 几何边界 |

**市级表 `jc_shi`**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `gid` | int4 | 主键 |
| `shiname` | varchar(30) | 城市名称（中文） |
| `shicode` | varchar(10) | 城市代码 |
| `shengname` | varchar(24) | 所属省份名称 |
| `geom` | geometry(MULTIPOLYGON, 4326) | 几何边界 |

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
- 天地图 POI 搜索必须使用“天地图搜索服务 V2.0 Key”，不能使用瓦片 Key、浏览器端 Key、或其它非搜索服务 Key。
- 如果出现 `301012 权限类型错误`，或提示 `Key权限类型为:浏览器端，请使用浏览器访问！`，说明当前 Key 类型不对。
- 天地图 `TK` 必须是服务器端搜索服务 Key，不能直接使用浏览器端 JS/静态瓦片 Key。
- 在天地图开放平台中选择“搜索服务”/“POI搜索服务”类型的 Key，确保是服务器端调用权限。
- 可通过环境变量临时覆盖当前 Key：
  ```powershell
  $env:TIANDITU_API_KEY="你的天地图搜索服务Key"
  ```

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

## 限流处理机制

当触发高德 API 限流（错误码 `CUQPS_HAS_EXCEEDED_THE_LIMIT`）时，系统会自动重试：

| 参数 | 值 | 说明 |
|------|----|------|
| 最大重试次数 | 5 次 | 超过后放弃当前请求 |
| 重试延迟策略 | 指数退避 | 10s → 20s → 40s → 80s → 160s |
| 触发条件 | `info == 'CUQPS_HAS_EXCEEDED_THE_LIMIT'` | 仅针对限流错误重试 |

**日志输出示例**：
```
范围搜索 页码: 1
API返回错误: CUQPS_HAS_EXCEEDED_THE_LIMIT
⚠️ 触发限流，等待 10 秒后重试 (第 1/5 次)
```

---

## 日志统计说明

爬取过程中会输出详细的统计信息：

### 网格级别统计
```
📊 当前网格POI类型统计:
  - 110000 (交通设施服务): 45 条
  - 210000 (地名地址信息): 32 条
  - 120000 (金融保险服务): 18 条
  总计: 95 条
```

### 总体统计
```
📊 爬取结果统计
==========================================
总网格数: 9
成功: 9, 失败: 0
去重前: 1256 条
去重后: 987 条

按类型统计:
  - 110000 (交通设施服务): 234 条 (23.7%)
  - 210000 (地名地址信息): 189 条 (19.1%)
```

---

## 通用注意事项

1. **API 限流**：每个请求之间有 0.2 秒间隔，避免触发限流；触发限流时自动指数退避重试
2. **数据去重**：区域分块模式会自动去重，高德按 `id`，天地图按 `hotPointID`
3. **坐标系统**：统一使用 WGS84 坐标系（EPSG:4326）
4. **网络超时**：请求超时时间为 30 秒，可在配置中调整
5. **数据库入库**：当前 POI 数据默认写入 PostgreSQL；高德写入 `gis_poiType_gd`，天地图写入 `gis_poiType_td`
6. **区域匹配**：传入中文区域名称（如"河南省"、"郑州市"），系统自动区分省/市级别并过滤数据

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
