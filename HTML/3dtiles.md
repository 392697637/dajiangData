# 3DTiles 生成完整流程

## 环境要求

- PostgreSQL 17+
- PostGIS 3.6+
- pg2b3dm 2.27.0+

## 完整执行步骤

### 1. 连接数据库

```bash
psql -h localhost -p 5432 -d ktd_lx_2026gis -U zhuoyi
```

### 2. 数据预处理（构建完整立体几何）

执行以下 SQL 脚本：

```sql
-- 查看当前几何类型
SELECT 
  ST_GeometryType(geom3d) AS geom_type,
  COUNT(*) 
FROM gis_buildings_aaaaa 
GROUP BY geom_type;

-- 修改 geom3d 列类型为通用 geometry
ALTER TABLE gis_buildings_aaaaa 
ALTER COLUMN geom3d TYPE geometry;

-- 从底面 geom 和高度 height 构建完整立体
UPDATE gis_buildings_aaaaa 
SET geom3d = ST_MakeSolid(ST_Extrude(geom, 0, 0, height));

-- 验证生成结果
SELECT 
  ST_GeometryType(geom3d) AS geom_type,
  ST_IsSolid(geom3d) AS is_solid,
  COUNT(*) 
FROM gis_buildings_aaaaa 
GROUP BY geom_type, is_solid;

-- 添加空间索引（提升性能）
CREATE INDEX IF NOT EXISTS idx_gis_buildings_geom3d 
ON gis_buildings_aaaaa 
USING gist(st_centroid(st_envelope(geom3d)));
```

### 3. 生成 3DTiles

```bash
/usr/local/bin/pg2b3dm \
  --connection 'Host=localhost;Port=5432;Database=ktd_lx_2026gis;Username=zhuoyi;Password=Ktd@postSQL@2026!@#;CommandTimeOut=3600' \
  -t gis_buildings_aaaaa \
  -c geom3d \
  -o /home/postgres/pgdata/3dtiles/gis_buildings_aaaaa_full \
  -a "id,height,age,quality,function" \
  --max_features_per_tile 30 \
  --default_color "#ffffff" \
  --geometricerror 2000 \
  --subdivision QUADTREE \
  --add_outlines true
```

### 4. 验证生成结果

```bash
# 查看生成的文件结构
ls -la /home/postgres/pgdata/3dtiles/gis_buildings_aaaaa_full/

# 查看 tileset.json
cat /home/postgres/pgdata/3dtiles/gis_buildings_aaaaa_full/tileset.json
```

### 5. 部署到 Web 服务器

```bash
# 复制到 IIS 目录（Windows）
scp -r /home/postgres/pgdata/3dtiles/gis_buildings_aaaaa_full/ user@windows-server:/inetpub/wwwroot/3dtiles/

# 或者配置 Nginx（Linux）
# 修改 nginx.conf 添加 3DTiles 服务配置
```

### 6. 更新前端配置

修改 `3d.html` 中的 tilesUrl：

```javascript
CONFIG.tilesUrl = 'http://your-server/3dtiles/gis_buildings_aaaaa_full/tileset.json';
```

## 完整脚本文件

### generate_3dtiles.sh

```bash
#!/bin/bash

# 3DTiles 生成脚本
# 使用方法: ./generate_3dtiles.sh

# 配置参数
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="ktd_lx_2026gis"
DB_USER="zhuoyi"
DB_PASS="Ktd@postSQL@2026!@#"
TABLE_NAME="gis_buildings_aaaaa"
GEOM_COLUMN="geom3d"
OUTPUT_DIR="/home/postgres/pgdata/3dtiles/gis_buildings_aaaaa_full"
LOG_FILE="/var/log/pg2b3dm/generate_3dtiles.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 记录开始时间
START_TIME=$(date +%s)
START_TIME_STR=$(date "+%Y-%m-%d %H:%M:%S")

# 创建日志目录
mkdir -p $(dirname $LOG_FILE)

# 日志函数
log() {
  echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a $LOG_FILE
}

log "${BLUE}============================================"
log "${BLUE}3DTiles 生成任务开始"
log "${BLUE}============================================"
log "开始时间: $START_TIME_STR"
log "数据库: $DB_NAME"
log "表: $TABLE_NAME"
log "几何列: $GEOM_COLUMN"
log "输出目录: $OUTPUT_DIR"
log "日志文件: $LOG_FILE"

# 检查 pg2b3dm 是否存在
if [ ! -f "/usr/local/bin/pg2b3dm" ]; then
  log "${RED}错误: pg2b3dm 未安装或路径不正确!"
  exit 1
fi

# 创建输出目录
log "创建输出目录..."
mkdir -p $OUTPUT_DIR
if [ $? -ne 0 ]; then
  log "${RED}错误: 无法创建输出目录 $OUTPUT_DIR"
  exit 1
fi
log "${GREEN}✓ 输出目录创建成功"

# 检查数据库连接
log "测试数据库连接..."
psql -h $DB_HOST -p $DB_PORT -d $DB_NAME -U $DB_USER -c "SELECT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  log "${RED}错误: 无法连接到数据库!"
  exit 1
fi
log "${GREEN}✓ 数据库连接成功"

# 检查表是否存在
log "检查表 $TABLE_NAME 是否存在..."
psql -h $DB_HOST -p $DB_PORT -d $DB_NAME -U $DB_USER -c "SELECT COUNT(*) FROM $TABLE_NAME LIMIT 1" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  log "${RED}错误: 表 $TABLE_NAME 不存在!"
  exit 1
fi
log "${GREEN}✓ 表 $TABLE_NAME 存在"

# 执行 pg2b3dm
log "${YELLOW}开始生成 3DTiles (此过程可能需要几分钟)..."
log "执行命令: /usr/local/bin/pg2b3dm --connection 'Host=$DB_HOST;Port=$DB_PORT;Database=$DB_NAME;Username=$DB_USER;Password=***;CommandTimeOut=3600' -t $TABLE_NAME -c $GEOM_COLUMN -o $OUTPUT_DIR"

/usr/local/bin/pg2b3dm \
  --connection "Host=$DB_HOST;Port=$DB_PORT;Database=$DB_NAME;Username=$DB_USER;Password=$DB_PASS;CommandTimeOut=3600" \
  -t $TABLE_NAME \
  -c $GEOM_COLUMN \
  -o $OUTPUT_DIR \
  -a "id,height,age,quality,function" \
  --max_features_per_tile 30 \
  --default_color "#ffffff" \
  --geometricerror 2000 \
  --subdivision QUADTREE \
  --add_outlines true >> $LOG_FILE 2>&1

PG2B3DM_EXIT_CODE=$?
END_TIME=$(date +%s)
END_TIME_STR=$(date "+%Y-%m-%d %H:%M:%S")

# 计算执行时间
ELAPSED_TIME=$((END_TIME - START_TIME))
ELAPSED_HOURS=$((ELAPSED_TIME / 3600))
ELAPSED_MINUTES=$(( (ELAPSED_TIME % 3600) / 60 ))
ELAPSED_SECONDS=$((ELAPSED_TIME % 60))

# 格式化执行时间
if [ $ELAPSED_HOURS -gt 0 ]; then
  ELAPSED_STR="${ELAPSED_HOURS}小时${ELAPSED_MINUTES}分钟${ELAPSED_SECONDS}秒"
elif [ $ELAPSED_MINUTES -gt 0 ]; then
  ELAPSED_STR="${ELAPSED_MINUTES}分钟${ELAPSED_SECONDS}秒"
else
  ELAPSED_STR="${ELAPSED_SECONDS}秒"
fi

# 检查执行结果
if [ $PG2B3DM_EXIT_CODE -eq 0 ]; then
  # 验证输出文件
  TILESET_JSON="$OUTPUT_DIR/tileset.json"
  if [ -f "$TILESET_JSON" ]; then
    TILE_COUNT=$(ls -la $OUTPUT_DIR/*.glb 2>/dev/null | wc -l)
    SUBTREE_COUNT=$(ls -la $OUTPUT_DIR/*.subtree 2>/dev/null | wc -l)
    
    log "${GREEN}============================================"
    log "${GREEN}3DTiles 生成成功!"
    log "${GREEN}============================================"
    log "结束时间: $END_TIME_STR"
    log "执行时长: $ELAPSED_STR"
    log "输出目录: $OUTPUT_DIR"
    log "生成的瓦片数: $TILE_COUNT 个 .glb 文件"
    log "生成的子树数: $SUBTREE_COUNT 个 .subtree 文件"
    log "日志文件: $LOG_FILE"
    
    # 输出文件列表
    log "${BLUE}生成的文件列表:"
    ls -la $OUTPUT_DIR/ | tee -a $LOG_FILE
    
    exit 0
  else
    log "${RED}错误: tileset.json 未生成!"
    exit 1
  fi
else
  log "${RED}============================================"
  log "${RED}3DTiles 生成失败!"
  log "${RED}============================================"
  log "结束时间: $END_TIME_STR"
  log "执行时长: $ELAPSED_STR"
  log "错误码: $PG2B3DM_EXIT_CODE"
  log "${YELLOW}请查看日志文件获取详细错误信息: $LOG_FILE"
  log "${YELLOW}最近10条日志:"
  tail -10 $LOG_FILE | tee -a $LOG_FILE
  exit 1
fi
```

### init_geometry.sql

```sql
-- 几何初始化脚本
-- 使用方法: psql -d ktd_lx_2026gis -U zhuoyi -f init_geometry.sql

-- 修改列类型
ALTER TABLE gis_buildings_aaaaa 
ALTER COLUMN geom3d TYPE geometry;

-- 构建完整立体几何
UPDATE gis_buildings_aaaaa 
SET geom3d = ST_MakeSolid(ST_Extrude(geom, 0, 0, height));

-- 添加空间索引
CREATE INDEX IF NOT EXISTS idx_gis_buildings_geom3d 
ON gis_buildings_aaaaa 
USING gist(st_centroid(st_envelope(geom3d)));

-- 验证结果
SELECT 
  '几何类型' AS type,
  ST_GeometryType(geom3d) AS value,
  COUNT(*) AS count
FROM gis_buildings_aaaaa 
GROUP BY ST_GeometryType(geom3d)
UNION ALL
SELECT 
  '是否封闭',
  CASE WHEN ST_IsSolid(geom3d) THEN '是' ELSE '否' END,
  COUNT(*)
FROM gis_buildings_aaaaa 
GROUP BY ST_IsSolid(geom3d);

-- 更新统计信息
ANALYZE gis_buildings_aaaaa;

-- 输出结果
SELECT '处理完成' AS result, COUNT(*) AS total_buildings FROM gis_buildings_aaaaa;
```

## 一键执行

```bash
# 1. 先执行 SQL 脚本初始化几何
psql -h localhost -p 5432 -d ktd_lx_2026gis -U zhuoyi -f init_geometry.sql

# 2. 执行生成脚本
chmod +x generate_3dtiles.sh
./generate_3dtiles.sh
```

## 常见问题

### Q1: Geometry type GeometryCollection is not supported

**原因**：`ST_Extrude` 返回的是 `GeometryCollection` 类型，pg2b3dm 不支持

**解决方案**：确保使用 `ST_MakeSolid` 转换为 `Solid` 类型

```sql
UPDATE gis_buildings_aaaaa 
SET geom3d = ST_MakeSolid(ST_Extrude(geom, 0, 0, height));
```

### Q2: Geometry type (PolyhedralSurface) does not match column type (MultiPolygon)

**原因**：列类型限制为 `MultiPolygon`，不支持 `PolyhedralSurface`

**解决方案**：修改列类型为通用 `geometry`

```sql
ALTER TABLE gis_buildings_aaaaa 
ALTER COLUMN geom3d TYPE geometry;
```

### Q3: 生成的模型只有顶面没有侧面

**原因**：原始 `geom3d` 可能只包含顶面几何

**解决方案**：使用 `ST_Extrude` 从底面拉伸构建完整立体

### Q4: 模型位置不对

**原因**：坐标系不匹配

**解决方案**：确保数据库中的几何是 EPSG:4326 (WGS84)

```sql
-- 检查坐标系
SELECT ST_SRID(geom3d) FROM gis_buildings_aaaaa LIMIT 1;

-- 转换为 WGS84（如果需要）
UPDATE gis_buildings_aaaaa 
SET geom3d = ST_Transform(geom3d, 4326) 
WHERE ST_SRID(geom3d) != 4326;
```

## 技术说明

### 坐标系要求

pg2b3dm 默认将几何转换为 ECEF（地心地固坐标系）用于 Cesium。确保数据库中的几何是：
- **EPSG:4326 (WGS84)** - 经纬度坐标系
- 不要使用 `--keep_projection true`（除非明确知道自己在做什么）

### 几何类型支持

pg2b3dm 支持的几何类型：
- ✅ PolyhedralSurface
- ✅ Solid
- ✅ MultiPolygon（2D，会被拉伸）
- ❌ GeometryCollection（需要转换）

### 性能优化建议

1. 添加空间索引
2. 控制 `--max_features_per_tile` 参数（建议 30-100）
3. 根据数据量调整 `--geometricerror`
4. 对于大规模数据，考虑使用 `--use_implicit_tiling`（默认启用）

## PostgreSQL PL/Shell 函数

### 概述

通过 PostgreSQL 函数直接调用 pg2b3dm 生成 3DTiles，支持传入项目名称动态生成。

### 前提条件

```sql
-- 1. 确保已安装 plsh 扩展
CREATE EXTENSION IF NOT EXISTS plsh;

-- 2. 确保 pg2b3dm 可执行文件路径正确
-- 默认路径: /usr/local/bin/pg2b3dm
```

### 函数定义

#### 1. gis_generate_3dtiles - 基础版本

```sql
/**
 * @function gis_generate_3dtiles
 * @description 通过项目名称生成 3DTiles（基础版本）
 * 
 * @param p_project_name text - 项目名称（如 'aaaaa'，对应表 gis_buildings_aaaaa）
 * @param p_output_dir text - 输出目录，默认为 '/home/postgres/pgdata/3dtiles'
 * 
 * @return text - 返回结果状态
 *                - SUCCESS: <输出路径> 表示生成成功
 *                - FAILED: <表名> 表示生成失败
 * 
 * @example
 * -- 使用默认输出目录
 * SELECT gis_generate_3dtiles('aaaaa');
 * 
 * -- 指定输出目录
 * SELECT gis_generate_3dtiles('bbbbb', '/custom/output/path');
 * 
 * @dependency 需要安装 plsh 扩展和 pg2b3dm 工具
 */
CREATE OR REPLACE FUNCTION gis_generate_3dtiles(
    p_project_name text,           -- 项目名称，用于动态拼接表名
    p_output_dir text DEFAULT '/home/postgres/pgdata/3dtiles'  -- 3DTiles 输出目录
) RETURNS text AS $$
#!/bin/bash

# ========== 参数处理 ==========
PROJECT_NAME="$1"       # 项目名称参数
OUTPUT_DIR="$2"         # 输出目录参数

# ========== 数据库配置 ==========
DB_HOST="localhost"     # PostgreSQL 数据库主机地址
DB_PORT="5432"          # PostgreSQL 数据库端口
DB_NAME="ktd_lx_2026gis"  # 数据库名称
DB_USER="zhuoyi"        # 数据库用户名
DB_PASS="Ktd@postSQL@2026!@#"  # 数据库密码

# ========== 表配置 ==========
TABLE_NAME="gis_buildings_${PROJECT_NAME}"  # 动态表名：gis_buildings_{项目名}
GEOM_COLUMN="geom3d"    # 3D几何列名称
FINAL_OUTPUT_DIR="${OUTPUT_DIR}/gis_buildings_${PROJECT_NAME}"  # 最终输出路径

# ========== 输出目录准备 ==========
# 确保输出目录存在，不存在则创建
mkdir -p "$FINAL_OUTPUT_DIR"

# ========== 执行 pg2b3dm（3DTiles生成核心命令）==========
# 
# pg2b3dm 是一个将 PostgreSQL 3D几何数据转换为 3DTiles 格式的工具
# 官方文档: https://github.com/Geodan/pg2b3dm
# 版本: 2.27.0
# 
# 【工具概述】
# pg2b3dm 从 PostgreSQL 数据库读取 3D 几何数据（如建筑、地形），将其转换为
# Cesium 支持的 3DTiles 格式（.glb 文件 + tileset.json）。
# 
# 【工作原理】
# 1. 连接 PostgreSQL 数据库，读取指定表的几何数据
# 2. 将几何数据转换为 glTF 2.0 格式（.glb 二进制文件）
# 3. 根据空间范围构建瓦片树结构（四叉树/八叉树）
# 4. 生成 tileset.json 元数据文件，描述瓦片层级关系
# 5. 输出到指定目录，供 Cesium 加载使用
# 
# 【性能特点】
# - 支持百万级数据处理（需配置合适的参数）
# - 自动空间分区，优化瓦片加载性能
# - 支持 3DTiles 1.1 隐式瓦片技术
# - 单线程处理（可通过分区并行化）
# 
# ========================================================================
# 【必选参数详解】
# ========================================================================
# 
# --connection: 数据库连接字符串
#   格式: "Host=主机;Port=端口;Database=数据库名;Username=用户名;Password=密码;CommandTimeOut=超时秒数"
#   作用: 建立与 PostgreSQL 数据库的连接，获取几何数据
#   效果: 
#     - CommandTimeOut 控制单个查询的最大执行时间
#     - 超时后查询会被取消，防止长时间占用数据库资源
#   示例: --connection "Host=localhost;Port=5432;Database=gis_db;Username=user;Password=pass;CommandTimeOut=3600"
#   建议: 
#     - 小数据量（<1万）: CommandTimeOut=600（10分钟）
#     - 中等数据（1-10万）: CommandTimeOut=1800（30分钟）
#     - 大数据量（>10万）: CommandTimeOut=3600（1小时）或更长
# 
# -t, --table: 表名
#   作用: 指定包含 3D 几何数据的数据库表
#   效果: 
#     - 支持带 schema 的表名（如 public.buildings）
#     - 表必须包含几何列（geometry 类型）
#     - 表应有空间索引，否则查询性能会很差
#   示例: -t gis_buildings_aaaaa 或 -t public.gis_buildings
#   建议: 
#     - 确保表有空间索引: CREATE INDEX idx_geom ON table USING gist(geom)
#     - 表名遵循命名规范，便于批量处理
# 
# -c, --column: 几何列名
#   作用: 指定表中包含 3D 几何数据的列
#   效果: 
#     - 列必须是 geometry 或 geography 类型
#     - 支持 2D（Polygon）、3D（PolyhedralSurface、Solid）
#     - 坐标系应为 EPSG:4326（WGS84），否则需转换
#   示例: -c geom3d 或 -c geom
#   建议: 
#     - 3D 建筑使用 PolyhedralSurface 或 Solid 类型
#     - 确保坐标系正确: SELECT ST_SRID(column) FROM table LIMIT 1
# 
# -o, --output: 输出目录
#   作用: 指定 3DTiles 文件的输出目录
#   效果: 
#     - 目录不存在会自动创建
#     - 输出文件包括: tileset.json、*.glb、*.subtree（隐式瓦片）
#     - 输出后可直接部署到 Web 服务器供 Cesium 加载
#   示例: -o /home/postgres/3dtiles/buildings
#   建议: 
#     - 使用 SSD 存储提升写入性能
#     - 目录命名包含项目名和时间戳，便于管理
# 
# ========================================================================
# 【可选参数详解】
# ========================================================================
# 
# -a, --attributecolumns: 属性列（逗号分隔）
#   默认值: 无（不保留任何属性）
#   作用: 指定要保留的属性列，存储在 3DTiles 的 batch table 中
#   效果: 
#     - 属性可通过 Cesium API 访问（如 feature.getProperty('height')）
#     - 增加属性会增大 .glb 文件大小
#     - 支持前端交互（如点击建筑显示信息）
#   示例: -a "id,height,name,type,age"
#   建议: 
#     - 只保留必要的属性，减少文件大小
#     - 避免保留大文本字段（如 description）
#   性能影响: 每增加一个属性列，文件大小增加约 10-20%
# 
# --max_features_per_tile: 每个瓦片的最大要素数
#   默认值: 1000
#   作用: 控制单个瓦片包含的几何要素数量上限
#   效果: 
#     - 值越小: 瓦片数量越多，加载更平滑，但文件数更多
#     - 值越大: 瓦片数量越少，加载可能卡顿，但文件数更少
#     - 影响瓦片树深度和空间分区粒度
#   示例: --max_features_per_tile 50
#   建议: 
#     - 小规模数据（<1万）: 30-50，瓦片多但加载流畅
#     - 中等规模（1-10万）: 50-100，平衡性能和文件数
#     - 大规模数据（>10万）: 100-500，减少瓦片数量
#   性能影响: 
#     - 值=30: 可能生成数百个瓦片，适合精细加载
#     - 值=500: 可能生成数十个瓦片，适合快速加载
# 
# --default_color: 默认颜色（十六进制）
#   默认值: #FFFFFF（白色）
#   作用: 设置几何的默认渲染颜色
#   效果: 
#     - 所有几何使用统一颜色渲染
#     - 可通过前端 Cesium API 动态修改颜色
#     - 格式支持透明度（#AARRGGBB）
#   示例: 
#     - --default_color "#ffffff"（白色）
#     - --default_color "#ff5733"（橙红色）
#     - --default_color "#80ffffff"（半透明白色）
#   建议: 
#     - 建筑数据常用白色或灰色
#     - 不同类型建筑可使用不同颜色（需多次生成）
#   视觉效果: 直接影响 Cesium 中的渲染外观
# 
# --default_metallic_roughness: 金属粗糙度
#   默认值: #008000
#   作用: 控制材质的 PBR（物理渲染）属性
#   效果: 
#     - 格式: #RRGGBB
#     - RR（红色通道）: 金属度（00=非金属，FF=纯金属）
#     - GG（绿色通道）: 粗糙度（00=光滑如镜，FF=完全粗糙）
#     - BB（蓝色通道）: 保留，通常为 00
#   示例: 
#     - --default_metallic_roughness "#008000"（非金属，中等粗糙）
#     - --default_metallic_roughness "#ff0000"（纯金属，光滑）
#     - --default_metallic_roughness "#00ff00"（非金属，完全粗糙）
#   建议: 
#     - 建筑通常使用非金属材质（RR=00）
#     - 玻璃建筑可增加金属度（RR=40-80）
#   视觉效果: 
#     - 高金属度: 反射环境光，金属质感
#     - 高粗糙度: 表面漫反射，哑光效果
# 
# --geometricerror: 几何误差（单位：米）
#   默认值: 2000
#   作用: 定义瓦片的几何简化程度，控制 LOD 加载时机
#   效果: 
#     - Cesium 根据屏幕像素误差判断何时加载更详细瓦片
#     - 值越大: 低精度瓦片显示范围越大，减少加载请求
#     - 值越小: 更早加载高精度瓦片，视觉更精细
#     - 影响瓦片树根节点的 geometricError 值
#   示例: 
#     - --geometricerror 500（小范围数据，精细加载）
#     - --geometricerror 2000（中等范围，平衡性能）
#     - --geometricerror 5000（大范围数据，优化加载）
#   建议: 
#     - 建筑数据: 数据范围的 1%-5%
#     - 城市级数据（数公里）: 2000-5000
#     - 区域级数据（数十公里）: 5000-10000
#   性能影响: 
#     - 值过大: 远距离时显示粗糙，可能错过细节
#     - 值过小: 过早加载高精度瓦片，增加网络请求
# 
# --geometricerrorfactor: 几何误差因子
#   默认值: 2
#   作用: 控制 LOD 层级之间的误差比率
#   效果: 
#     - 每层 LOD 的 geometricError = 上层误差 / factor
#     - 值越大: LOD 层级差异更大，加载更激进
#     - 值越小: LOD 层级差异更小，加载更平滑
#   示例: 
#     - --geometricerrorfactor 2（默认，每层误差减半）
#     - --geometricerrorfactor 4（激进，每层误差减为1/4）
#   建议: 
#     - 通常使用默认值 2
#     - 数据量极大时可尝试 4，减少 LOD 层级
# 
# --subdivision: 细分方案
#   可选值: QUADTREE（四叉树）, OCTREE（八叉树）
#   默认值: QUADTREE
#   作用: 定义瓦片树的空间分割方式
#   效果: 
#     - QUADTREE: 将空间按 2D 平面分割为 4 个子区域
#       适合: 建筑数据、城市模型（高度变化不大）
#       特点: 瓦片数量较少，加载效率高
#     - OCTREE: 将空间按 3D 体积分割为 8 个子区域
#       适合: 地形数据、地下模型（高度变化大）
#       特点: 瓦片数量较多，3D 分布更均匀
#   示例: 
#     - --subdivision QUADTREE（建筑数据推荐）
#     - --subdivision OCTREE（地形或复杂 3D 数据）
#   建议: 
#     - 建筑数据使用 QUADTREE
#     - 地形、矿山、地下设施使用 OCTREE
#   性能影响: 
#     - QUADTREE: 瓦片数约 N/4^depth，适合平面分布
#     - OCTREE: 瓦片数约 N/8^depth，适合立体分布
# 
# --refinement: 细化策略
#   可选值: ADD（添加）, REPLACE（替换）
#   默认值: ADD
#   作用: 定义子瓦片如何替换父瓦片的显示方式
#   效果: 
#     - ADD: 子瓦片叠加显示在父瓦片上
#       优点: 平滑过渡，不会突然消失
#       缺点: 可能同时显示多层，增加渲染负担
#       适合: 需要平滑视觉过渡的场景
#     - REPLACE: 子瓦片完全替换父瓦片
#       优点: 只显示一层，渲染效率高
#       缺点: 加载瞬间可能有闪烁
#       适合: 性能优先、数据量大的场景
#   示例: 
#     - --refinement ADD（推荐用于建筑）
#     - --refinement REPLACE（推荐用于大数据量）
#   建议: 
#     - 建筑数据使用 ADD，视觉效果更好
#     - 百万级数据使用 REPLACE，减少渲染负担
# 
# --add_outlines: 是否添加轮廓线
#   默认值: false
#   作用: 为几何添加边缘轮廓线
#   效果: 
#     - 增加建筑轮廓线，增强视觉辨识度
#     - 文件大小增加约 5-10%
#     - 渲染时额外绘制线框
#   示例: --add_outlines true
#   建议: 
#     - 建筑数据推荐开启，增强立体感
#     - 地形数据不推荐，会增加文件大小
#   视觉效果: 建筑边缘有清晰的轮廓线
# 
# --double_sided: 是否双面渲染
#   默认值: true
#   作用: 控制几何是否双面可见
#   效果: 
#     - true: 几何内外两面都渲染（从内部也能看到）
#     - false: 只渲染外表面（从内部看不到，性能更好）
#   示例: 
#     - --double_sided true（推荐用于建筑）
#     - --double_sided false（推荐用于封闭地形）
#   建议: 
#     - 建筑数据使用 true，允许进入建筑内部查看
#     - 地形、封闭体使用 false，提升渲染性能
# 
# --default_alpha_mode: Alpha 模式
#   可选值: OPAQUE（不透明）, BLEND（混合）, MASK（遮罩）
#   默认值: OPAQUE
#   作用: 控制几何的透明度渲染方式
#   效果: 
#     - OPAQUE: 完全不透明，渲染最快
#       适合: 实体建筑、地面
#     - BLEND: 透明度混合，支持半透明效果
#       适合: 玻璃建筑、水体
#       注意: 需配合颜色透明度使用（#AARRGGBB）
#     - MASK: 基于阈值裁剪，低于阈值完全不显示
#       适合: 栅栏、网格等部分透明物体
#   示例: 
#     - --default_alpha_mode OPAQUE（推荐用于建筑）
#     - --default_alpha_mode BLEND（玻璃建筑）
#   建议: 
#     - 大部分建筑使用 OPAQUE，性能最佳
#     - 特殊效果（玻璃、水体）使用 BLEND
# 
# --alpha_cutoff: Alpha 裁剪阈值
#   默认值: 0.5
#   作用: 当 alpha_mode=MASK 时，控制裁剪阈值
#   效果: 
#     - Alpha 值低于阈值的部分完全不渲染
#     - 范围: 0.0-1.0
#   示例: --alpha_cutoff 0.5
#   建议: 
#     - 仅在 alpha_mode=MASK 时使用
#     - 通常使用默认值
# 
# --keep_projection: 是否保持原始投影
#   默认值: false
#   作用: 控制坐标系转换行为
#   效果: 
#     - true: 保持数据库中的原始坐标系
#       注意: Cesium 可能无法正确显示非 WGS84 坐标
#     - false: 自动转换为 ECEF（地心地固坐标系）
#       优点: Cesium 默认支持，无需额外配置
#   示例: 
#     - --keep_projection false（推荐）
#     - --keep_projection true（仅用于特殊坐标系调试）
#   建议: 
#     - 绝大多数情况使用 false
#     - 数据库坐标系应为 EPSG:4326（WGS84）
# 
# --use_implicit_tiling: 是否使用隐式瓦片
#   默认值: true
#   作用: 使用 3DTiles 1.1 规范的隐式瓦片技术
#   效果: 
#     - true: 使用隐式瓦片（.subtree 文件）
#       优点: tileset.json 极小，支持大规模数据
#       特点: 瓦片索引通过数学计算，无需遍历 JSON
#     - false: 使用传统显式瓦片
#       优点: 兼容旧版 Cesium
#       缺点: tileset.json 可能很大（百万级数据）
#   示例: --use_implicit_tiling true
#   建议: 
#     - 大数据量（>10万）必须使用 true
#     - 小数据量可以使用 false，兼容性更好
#   性能影响: 
#     - 隐式瓦片: tileset.json 约 1KB，加载极快
#     - 显式瓦片: tileset.json 可能数 MB，加载慢
# 
# --tileset_version: 瓦片集版本
#   作用: 设置 tileset.json 中的 version 字段
#   效果: 
#     - 用于版本管理和缓存控制
#     - 前端可通过 version 判断是否需要更新
#   示例: --tileset_version "1.1"
#   建议: 
#     - 使用语义化版本号（如 1.0.0, 1.1.0）
#     - 数据更新后修改版本号
# 
# --copyright: 版权信息
#   作用: 设置 glTF asset 的 copyright 字段
#   效果: 
#     - 嵌入版权信息到每个 .glb 文件
#     - 用于数据版权声明
#   示例: --copyright "© 2026 City GIS Department"
#   建议: 
#     - 生产环境添加版权信息
#     - 包含数据来源和授权信息
# 
# -q, --query: 额外查询条件
#   作用: 添加 WHERE 子句过滤数据
#   效果: 
#     - 只处理满足条件的几何
#     - 支持复杂 SQL 条件
#   示例: 
#     - -q "WHERE height > 10"（只处理高度大于10的建筑）
#     - -q "WHERE district = 'center'"（只处理中心区建筑）
#   建议: 
#     - 用于数据分区处理
#     - 可配合并行处理（按区域分别处理）
# 
# ========================================================================
# 【高级参数（可选）】
# ========================================================================
# 
# -l, --lodcolumn: LOD 列名
#   作用: 指定包含 LOD 层级信息的列
#   效果: 
#     - 支持多 LOD 数据（如 LOD0、LOD1、LOD2）
#     - 不同 LOD 存储在不同列或不同行
#   示例: -l lod_level
#   建议: 
#     - 仅用于多 LOD 建模数据
#     - 大部分情况不需要
# 
# --radiuscolumn: 半径列（用于点云）
#   作用: 指定包含点云半径信息的列
#   效果: 
#     - 用于点云数据渲染大小控制
#   示例: --radiuscolumn radius
#   建议: 仅用于点云数据
# 
# --shaderscolumn: 着色器列
#   作用: 指定包含自定义着色器信息的列
#   效果: 
#     - 支持自定义渲染效果
#   示例: --shaderscolumn shader_code
#   建议: 仅用于高级自定义渲染
# 
# --skip_create_tiles: 是否跳过创建瓦片
#   默认值: false
#   作用: 只生成 tileset.json，不生成 .glb 文件
#   效果: 
#     - 用于测试瓦片结构
#     - 快速验证空间分区是否合理
#   示例: --skip_create_tiles true
#   建议: 仅用于调试
# 
# ========================================================================
# 【参数组合建议】
# ========================================================================
# 
# 【小规模数据（<1万条）】
# --max_features_per_tile 30
# --geometricerror 500-1000
# --subdivision QUADTREE
# --refinement ADD
# --use_implicit_tiling false（可选）
# 
# 【中等规模数据（1-10万条）】
# --max_features_per_tile 50-100
# --geometricerror 2000
# --subdivision QUADTREE
# --refinement ADD
# --use_implicit_tiling true
# 
# 【大规模数据（>10万条）】
# --max_features_per_tile 100-500
# --geometricerror 5000
# --subdivision QUADTREE
# --refinement REPLACE
# --use_implicit_tiling true（必须）
# 
# 【建筑数据推荐配置】
# --default_color "#ffffff"
# --default_metallic_roughness "#008000"
# --add_outlines true
# --double_sided true
# --default_alpha_mode OPAQUE
# 
# 【玻璃/透明建筑配置】
# --default_color "#80ffffff"（半透明白色）
# --default_alpha_mode BLEND
# --double_sided true
# 
# ========================================================================
# 【性能优化建议】
# ========================================================================
# 
# 1. 数据库优化:
#    - 添加空间索引: CREATE INDEX idx_geom ON table USING gist(geom)
#    - 增加 work_mem: SET work_mem = '1GB'
#    - 禁用自动清理（临时）: SET autovacuum = off
# 
# 2. 参数优化:
#    - 大数据量增加 max_features_per_tile
#    - 大范围数据增加 geometricerror
#    - 使用隐式瓦片减少 tileset.json 大小
# 
# 3. 并行处理:
#    - 按空间范围分区，分别执行 pg2b3dm
#    - 使用 -q 参数过滤不同区域
#    - 最后合并 tileset.json
# 
# 4. 存储优化:
#    - 输出到 SSD 存储
#    - 使用压缩（gzip）减少传输大小
#    - 配置 Web 服务器启用 gzip
# 
# ========================================================================
# 【常见问题】
# ========================================================================
# 
# Q: 生成的瓦片加载很慢？
# A: 检查 max_features_per_tile 是否过小，增加该值减少瓦片数量
# 
# Q: 远距离时建筑显示粗糙？
# A: 检查 geometricerror 是否过大，减小该值提前加载高精度瓦片
# 
# Q: tileset.json 文件很大？
# A: 启用隐式瓦片: --use_implicit_tiling true
# 
# Q: 建筑颜色不对？
# A: 检查 default_color 格式，确保是 #RRGGBB 格式
# 
# Q: 数据库查询超时？
# A: 增加 CommandTimeOut 参数值，或添加空间索引
# 
# ========================================================================
# 【执行命令】
# ========================================================================
# 
/usr/local/bin/pg2b3dm \
  --connection "Host=$DB_HOST;Port=$DB_PORT;Database=$DB_NAME;Username=$DB_USER;Password=$DB_PASS;CommandTimeOut=3600" \
  -t "$TABLE_NAME" \                          # 指定数据库表名（必选）
  -c "$GEOM_COLUMN" \                         # 指定3D几何列名（必选）
  -o "$FINAL_OUTPUT_DIR" \                    # 指定输出目录（必选）
  -a "id,height,age,quality,function" \       # 保留的属性列（可选，逗号分隔）
  --max_features_per_tile 30 \                # 每瓦片最大要素数（默认1000）
  --default_color "#ffffff" \                 # 默认渲染颜色（默认#FFFFFF）
  --default_metallic_roughness "#008000" \    # 金属粗糙度（默认#008000）
  --geometricerror 2000 \                     # 几何误差（默认2000米）
  --geometricerrorfactor 2 \                  # 误差因子（默认2）
  --subdivision QUADTREE \                    # 细分方案（默认QUADTREE）
  --refinement ADD \                          # 细化策略（默认ADD）
  --add_outlines true \                       # 添加轮廓线（默认false）
  --double_sided true \                       # 双面渲染（默认true）
  --default_alpha_mode OPAQUE \                # Alpha模式（默认OPAQUE）
  --keep_projection false \                   # 保持投影（默认false）
  --use_implicit_tiling true                  # 隐式瓦片（默认true）

# ========== 结果判断 ==========
# 检查 pg2b3dm 退出码，0 表示成功，非0表示失败
if [ $? -eq 0 ]; then
  echo "SUCCESS: $FINAL_OUTPUT_DIR"
else
  echo "FAILED: $TABLE_NAME"
fi

$$ LANGUAGE plsh STRICT;  -- 使用 plsh 语言（PostgreSQL Shell 扩展）
```

#### 2. gis_generate_3dtiles_with_log - 带日志版本

```sql
/**
 * @function gis_generate_3dtiles_with_log
 * @description 通过项目名称生成 3DTiles（带详细日志和执行时间）
 * 
 * @param p_project_name text - 项目名称（如 'aaaaa'，对应表 gis_buildings_aaaaa）
 * @param p_output_dir text - 输出目录，默认为 '/home/postgres/pgdata/3dtiles'
 * 
 * @return json - 返回包含详细信息的 JSON 对象：
 *                {
 *                  "project_name": "项目名称",
 *                  "output_path": "输出路径",
 *                  "status": "success|failed",
 *                  "start_time": "开始时间（timestamp格式）",
 *                  "end_time": "结束时间（timestamp格式）",
 *                  "elapsed_seconds": "耗时（秒，整数）",
 *                  "message": "结果消息"
 *                }
 * 
 * @example
 * -- 生成并获取详细日志
 * SELECT gis_generate_3dtiles_with_log('aaaaa');
 * 
 * @see gis_generate_3dtiles - 调用基础生成函数
 */
CREATE OR REPLACE FUNCTION gis_generate_3dtiles_with_log(
    p_project_name text,           -- 项目名称参数
    p_output_dir text DEFAULT '/home/postgres/pgdata/3dtiles'  -- 输出目录参数
) RETURNS json AS $$
DECLARE
    v_start_time timestamp;   -- 任务开始时间（高精度）
    v_end_time timestamp;     -- 任务结束时间（高精度）
    v_elapsed_sec integer;    -- 任务耗时（秒）
    v_result text;            -- 基础函数返回结果
    v_output_path text;       -- 构建的输出路径
BEGIN
    -- ========== 记录开始时间 ==========
    -- 使用 clock_timestamp() 获取高精度时间戳
    v_start_time := clock_timestamp();
    
    -- ========== 调用基础生成函数 ==========
    -- 调用 gis_generate_3dtiles 执行实际的 3DTiles 生成
    v_result := gis_generate_3dtiles(p_project_name, p_output_dir);
    
    -- ========== 计算执行时间 ==========
    -- 记录结束时间
    v_end_time := clock_timestamp();
    -- 计算耗时（将时间差转换为秒）
    v_elapsed_sec := EXTRACT(EPOCH FROM (v_end_time - v_start_time))::integer;
    
    -- ========== 构建输出路径 ==========
    v_output_path := p_output_dir || '/gis_buildings_' || p_project_name;
    
    -- ========== 返回 JSON 结果 ==========
    -- 使用 json_build_object 构建结构化返回值
    RETURN json_build_object(
        'project_name', p_project_name,      -- 项目名称
        'output_path', v_output_path,        -- 输出路径
        'status', CASE WHEN v_result LIKE 'SUCCESS:%' THEN 'success' ELSE 'failed' END,  -- 状态
        'start_time', v_start_time,          -- 开始时间
        'end_time', v_end_time,              -- 结束时间
        'elapsed_seconds', v_elapsed_sec,    -- 耗时（秒）
        'message', v_result                  -- 详细消息
    );
END;
$$ LANGUAGE plpgsql STRICT;  -- 使用 plpgsql 语言
```

#### 3. gis_generate_3dtiles_batch - 批量生成版本

```sql
/**
 * @function gis_generate_3dtiles_batch
 * @description 批量生成多个项目的 3DTiles
 * 
 * @param p_project_names text[] - 项目名称数组（如 ARRAY['aaaaa', 'bbbbb', 'ccccc']）
 * @param p_output_dir text - 输出目录，默认为 '/home/postgres/pgdata/3dtiles'
 * 
 * @return json[] - 返回每个项目的生成结果数组（json[]类型）
 * 
 * @example
 * -- 批量生成多个项目
 * SELECT gis_generate_3dtiles_batch(ARRAY['aaaaa', 'bbbbb', 'ccccc']);
 * 
 * @see gis_generate_3dtiles_with_log - 调用带日志的生成函数
 */
CREATE OR REPLACE FUNCTION gis_generate_3dtiles_batch(
    p_project_names text[],       -- 项目名称数组
    p_output_dir text DEFAULT '/home/postgres/pgdata/3dtiles'  -- 输出目录参数
) RETURNS json[] AS $$
DECLARE
    v_results json[];      -- 存储所有项目的生成结果
    v_result json;         -- 单个项目的生成结果
    v_project_name text;   -- 当前遍历的项目名称
BEGIN
    -- ========== 初始化结果数组 ==========
    -- 创建空的 JSON 数组
    v_results := '[]'::json[];
    
    -- ========== 遍历项目名称数组 ==========
    -- 使用 FOREACH 循环遍历数组中的每个项目名称
    FOREACH v_project_name IN ARRAY p_project_names LOOP
        -- 调用带日志的生成函数
        v_result := gis_generate_3dtiles_with_log(v_project_name, p_output_dir);
        
        -- 将单个结果添加到结果数组
        v_results := array_append(v_results, v_result);
    END LOOP;
    
    -- ========== 返回结果数组 ==========
    -- 返回包含所有项目结果的 JSON 数组
    RETURN v_results;
END;
$$ LANGUAGE plpgsql STRICT;  -- 使用 plpgsql 语言
```

### 使用示例

#### 示例1：生成单个项目

```sql
-- 简单调用（基础版本）
SELECT gis_generate_3dtiles('aaaaa');

-- 返回结果
-- SUCCESS: /home/postgres/pgdata/3dtiles/gis_buildings_aaaaa
```

#### 示例2：生成单个项目（带详细日志）

```sql
-- 调用带日志版本
SELECT gis_generate_3dtiles_with_log('aaaaa');

-- 返回结果（JSON格式）
-- {
--   "project_name": "aaaaa",
--   "output_path": "/home/postgres/pgdata/3dtiles/gis_buildings_aaaaa",
--   "status": "success",
--   "start_time": "2026-06-13 10:30:00.123456",
--   "end_time": "2026-06-13 10:30:45.678901",
--   "elapsed_seconds": 45,
--   "message": "SUCCESS: /home/postgres/pgdata/3dtiles/gis_buildings_aaaaa"
-- }
```

#### 示例3：批量生成多个项目

```sql
-- 批量生成多个项目
SELECT gis_generate_3dtiles_batch(ARRAY['aaaaa', 'bbbbb', 'ccccc']);

-- 返回结果（JSON数组格式）
-- [
--   {"project_name": "aaaaa", "status": "success", ...},
--   {"project_name": "bbbbb", "status": "success", ...},
--   {"project_name": "ccccc", "status": "failed", ...}
-- ]
```

### 函数参数说明

| 参数名 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| p_project_name | text | - | 项目名称，用于拼接表名（gis_buildings_{项目名}） |
| p_output_dir | text | /home/postgres/pgdata/3dtiles | 3DTiles 输出目录 |
| p_project_names | text[] | - | 批量生成时的项目名称数组 |

### 返回值说明

#### gis_generate_3dtiles 返回值

| 返回格式 | 说明 |
|----------|------|
| SUCCESS: {路径} | 生成成功，包含输出路径 |
| FAILED: {表名} | 生成失败，包含失败的表名 |

#### gis_generate_3dtiles_with_log 返回值（JSON）

| 字段名 | 类型 | 说明 |
|--------|------|------|
| project_name | text | 项目名称 |
| output_path | text | 输出路径 |
| status | text | 状态（success/failed） |
| start_time | timestamp | 开始时间（高精度） |
| end_time | timestamp | 结束时间（高精度） |
| elapsed_seconds | integer | 耗时（秒） |
| message | text | 详细消息 |

#### gis_generate_3dtiles_batch 返回值（JSON数组）

| 元素类型 | 说明 |
|----------|------|
| json | 每个元素是 gis_generate_3dtiles_with_log 的返回值 |

### 注意事项

1. **权限要求**：执行函数的 PostgreSQL 用户需要有执行 shell 命令的权限
2. **路径配置**：确保 `/usr/local/bin/pg2b3dm` 路径正确，可根据实际安装路径修改
3. **数据库密码**：函数中硬编码了密码，生产环境建议使用 PostgreSQL 密码文件或连接服务文件
4. **表名约定**：表名必须遵循 `gis_buildings_{项目名}` 的命名规则
5. **错误处理**：函数会捕获 pg2b3dm 的退出码，但不会捕获数据库连接错误

### 安全建议

```sql
-- 生产环境建议使用连接服务文件
-- 创建 ~/.pgpass 文件
-- localhost:5432:ktd_lx_2026gis:zhuoyi:Ktd@postSQL@2026!@#

-- 修改函数使用服务名连接
-- --connection "Service=my_service"
```
