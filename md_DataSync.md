# 数据库同步说明

本文档说明 `maindata.py`、`datasettings.py`、`src/dbsync.py` 的用途和配置方式。

## 功能概览

数据库同步用于将源库：

```text
192.168.110.6 / ktd_lx_2026gis
```

同步到目标库：

```text
192.168.110.15 / ktd_lx_2026gis
```

支持三类对象独立同步：

| 类型 | 配置项 | 说明 |
|------|--------|------|
| 表 | `SYNC_TABLES` | 同步表结构和数据 |
| 函数 | `SYNC_FUNCTIONS` | 单独同步 PostgreSQL 函数 |
| 视图 | `SYNC_VIEWS` | 单独同步普通视图 |

## 文件说明

| 文件 | 说明 |
|------|------|
| `datasettings.py` | 数据库连接、同步表、函数、视图配置 |
| `maindata.py` | 数据同步命令行入口 |
| `src/dbsync.py` | 同步逻辑实现 |

## 配置说明

### 数据库连接

在 `datasettings.py` 中配置源库和目标库：

```python
SOURCE_DB = {
    "host": "192.168.110.6",
    "port": 5432,
    "database": "ktd_lx_2026gis",
    "user": "zhuoyi",
    "password": "******",
}

TARGET_DB = {
    "host": "192.168.110.15",
    "port": 5432,
    "database": "ktd_lx_2026gis",
    "user": "zhuoyi",
    "password": "******",
}
```

也可以通过环境变量覆盖连接信息，例如：

```powershell
$env:SYNC_SOURCE_HOST="192.168.110.6"
$env:SYNC_TARGET_HOST="192.168.110.15"
```

### Schema 配置

当表、函数或视图配置为空时，会扫描 `SYNC_SCHEMAS` 下的全部对应对象：

```python
SYNC_SCHEMAS = [
    "public",
]
```

## 表同步

表配置项：

```python
SYNC_TABLES = [
    "public.jc_sheng",
    "public.jc_shi",
]
```

如果 `SYNC_TABLES = []`，则同步 `SYNC_SCHEMAS` 下全部普通表。

表同步使用 `pg_dump --table`，不是手写建表 SQL，因此会保留：

- 主键
- 唯一约束
- 外键
- 普通索引
- PostGIS 空间索引，例如 `GIST`
- 字段类型，包括 `geometry`
- 默认值
- 触发器
- 表注释
- 字段注释

默认同步表时会先判断目标库同名表是否存在。存在时删除，再重建并导入数据；不存在时跳过删除：

```text
SELECT EXISTS (...)
DROP TABLE ... CASCADE
```

如果不想删除目标表，可加 `--no-clean`。

## 函数同步

函数配置项：

```python
SYNC_FUNCTIONS = [
    "public.fn_name",
    "public.fn_name(integer, text)",
]
```

说明：

- `public.fn_name` 会同步该函数名下的全部重载函数。
- `public.fn_name(integer, text)` 只同步指定参数签名的函数。
- 如果 `SYNC_FUNCTIONS = []`，则同步 `SYNC_SCHEMAS` 下全部普通函数。

函数同步会先判断目标库对应签名函数是否存在。存在时删除，再写入源库函数定义；不存在时直接创建：

```text
SELECT EXISTS (...)
DROP FUNCTION ... CASCADE
CREATE OR REPLACE FUNCTION ...
```

## 视图同步

视图配置项：

```python
SYNC_VIEWS = [
    "public.vw_name",
]
```

如果 `SYNC_VIEWS = []`，则同步 `SYNC_SCHEMAS` 下全部普通视图。

视图同步会先判断目标库对应视图是否存在。存在时删除，再按源库定义重建；不存在时直接创建：

```text
SELECT EXISTS (...)
DROP VIEW ... CASCADE
CREATE VIEW ...
```

注意：视图依赖的表或函数需要先存在。通常建议执行顺序为：

```text
表 -> 函数 -> 视图
```

`maindata.py --only all` 会按这个顺序执行。

## 命令示例

## 传输日志

每次执行 `maindata.py` 都会写入传输日志：

```text
logs/dbsync_YYYYMMDD.log
```

日志会记录：

- 源库和目标库
- 同步模式
- 表、函数、视图数量
- 每个对象的开始同步时间
- 目标对象是否存在、是否删除
- 每个对象同步成功或失败
- 每个对象耗时
- 总耗时
- 失败异常信息

控制台会同步输出关键进度，日志文件会保留完整传输记录。

### 查看同步对象

```powershell
.\.venv\Scripts\python.exe maindata.py --list-tables
.\.venv\Scripts\python.exe maindata.py --list-functions
.\.venv\Scripts\python.exe maindata.py --list-views
```

### 同步全部对象

```powershell
.\.venv\Scripts\python.exe maindata.py --only all
```

### 只同步表

```powershell
.\.venv\Scripts\python.exe maindata.py --only tables
```

### 只同步函数

```powershell
.\.venv\Scripts\python.exe maindata.py --only functions
```

### 只同步视图

```powershell
.\.venv\Scripts\python.exe maindata.py --only views
```

### 临时指定表

```powershell
.\.venv\Scripts\python.exe maindata.py --only tables --tables public.jc_sheng public.jc_shi
```

### 临时指定函数

```powershell
.\.venv\Scripts\python.exe maindata.py --only functions --functions public.fn_name
```

### 临时指定视图

```powershell
.\.venv\Scripts\python.exe maindata.py --only views --views public.vw_name
```

## 依赖工具

同步表依赖 PostgreSQL 客户端工具：

- `pg_dump`
- `psql`

如果系统 PATH 中没有这两个命令，可以在 `datasettings.py` 中指定完整路径：

```python
PG_DUMP_BIN = r"C:\Program Files\PostgreSQL\17\bin\pg_dump.exe"
PSQL_BIN = r"C:\Program Files\PostgreSQL\17\bin\psql.exe"
```

## 注意事项

- 目标库必须已经存在。
- 表同步默认会删除目标库同名表，请确认目标库数据可以被覆盖。
- 视图依赖的表和函数应先同步。
- 函数同步使用 `CASCADE` 删除旧函数，依赖该函数的视图可能会被删除，因此建议最后再同步视图。
- 如果同步 PostGIS 表，目标库需要已经安装 PostGIS 扩展。
## 同步原理

本同步工具不是简单地把数据 `SELECT` 出来再 `INSERT` 到目标库，而是按 PostgreSQL 对象类型分开处理。这样可以保证表结构、约束、索引、空间字段、函数定义和视图定义尽量保持和源库一致。

整体执行入口是：

```powershell
.\.venv\Scripts\python.exe maindata.py
```

核心配置文件是：

```text
datasettings.py
```

核心同步逻辑文件是：

```text
src/dbsync.py
```

执行顺序如下：

```text
读取 datasettings.py 配置
    ↓
连接源库 192.168.110.6
    ↓
连接目标库 192.168.110.15
    ↓
解析需要同步的表、函数、视图
    ↓
按顺序同步：表 -> 函数 -> 视图
    ↓
写入 logs/dbsync_YYYYMMDD.log 传输日志
```

### 1. 配置解析原理

`datasettings.py` 中有三类同步配置：

```python
SYNC_TABLES = []
SYNC_FUNCTIONS = []
SYNC_VIEWS = []
```

每个配置项有两种工作方式。

第一种：手动指定对象。

```python
SYNC_TABLES = [
    "public.bo_electric_fence",
    "public.bo_ground_ele",
]
```

这种情况下只同步配置里的对象。

第二种：配置为空。

```python
SYNC_TABLES = []
```

这种情况下程序会扫描 `SYNC_SCHEMAS` 下的全部普通表：

```python
SYNC_SCHEMAS = [
    "public",
]
```

函数和视图也是同样逻辑：

- `SYNC_FUNCTIONS = []` 表示扫描 schema 下全部普通函数。
- `SYNC_VIEWS = []` 表示扫描 schema 下全部普通视图。

### 2. 表同步原理

表同步使用 PostgreSQL 官方工具：

```text
pg_dump
psql
```

程序内部相当于执行：

```text
pg_dump 源库 --table public.xxx
    |
psql 目标库
```

也就是把源库指定表的结构和数据导出，然后直接导入到目标库。

这种方式的好处是：不用手写建表 SQL，PostgreSQL 会把表相关对象一起导出来。

表同步会保留：

- 表结构
- 字段类型
- `geometry` / `geography` 空间字段
- 主键
- 唯一约束
- 外键
- 默认值
- 普通索引
- PostGIS 空间索引，例如 `GIST`
- 触发器
- 表注释
- 字段注释
- 表数据

所以如果源库表里有主键和空间索引，目标库同步后也应该有对应主键和空间索引。

### 3. 表删除和重建原理

默认情况下，同步表之前会先判断目标库是否已经存在同名表。

判断 SQL 逻辑是查询：

```sql
information_schema.tables
```

如果目标表存在，程序执行：

```sql
DROP TABLE "schema"."table" CASCADE;
```

然后再用 `pg_dump` 导出的内容重建表并导入数据。

如果目标表不存在，则跳过删除，直接创建并导入。

日志里会看到类似：

```text
Target table does not exist, skip drop: public.bo_electric_fence
[TABLE] Start sync: public.bo_electric_fence
[TABLE] Success: public.bo_electric_fence, elapsed=1.23s
```

如果不希望删除目标表，可以加：

```powershell
.\.venv\Scripts\python.exe maindata.py --only tables --no-clean
```

注意：`--no-clean` 不删除目标表。如果目标表已经存在且结构冲突，导入可能失败。

### 4. 函数同步原理

函数同步不走 `pg_dump --table`，而是直接从 PostgreSQL 系统表读取函数定义。

程序查询：

```sql
pg_proc
pg_namespace
pg_get_function_identity_arguments(...)
pg_get_functiondef(...)
```

其中：

- `pg_proc` 保存函数元信息。
- `pg_namespace` 保存 schema 信息。
- `pg_get_function_identity_arguments` 获取函数参数签名。
- `pg_get_functiondef` 获取完整的 `CREATE OR REPLACE FUNCTION` 定义。

函数支持重载，所以同步函数时要注意参数签名。

例如：

```python
SYNC_FUNCTIONS = [
    "public.fn_check_fence(integer, text)",
]
```

只同步这个参数签名的函数。

如果写成：

```python
SYNC_FUNCTIONS = [
    "public.fn_check_fence",
]
```

则同步这个名字下的全部重载函数。

同步前会先判断目标库是否存在同签名函数。存在时执行：

```sql
DROP FUNCTION "schema"."function"(args) CASCADE;
```

然后执行源库里的函数定义：

```sql
CREATE OR REPLACE FUNCTION ...
```

### 5. 视图同步原理

视图同步通过 PostgreSQL 视图元数据读取定义。

程序查询：

```sql
information_schema.views
```

读取字段：

```sql
view_definition
```

同步前会先判断目标库是否存在同名视图。存在时执行：

```sql
DROP VIEW "schema"."view" CASCADE;
```

然后按源库定义重新创建：

```sql
CREATE VIEW "schema"."view" AS
...
```

视图依赖表和函数，所以建议先同步表和函数，再同步视图。

默认 `--only all` 的执行顺序就是：

```text
表 -> 函数 -> 视图
```

### 6. list 模式原理

以下命令只查看对象清单，不会同步：

```powershell
.\.venv\Scripts\python.exe maindata.py --list-tables
.\.venv\Scripts\python.exe maindata.py --list-functions
.\.venv\Scripts\python.exe maindata.py --list-views
```

只要命令中带了 `--list-tables`、`--list-functions` 或 `--list-views`，程序就会在打印清单后退出。

日志里会出现：

```text
List mode only: no objects will be synced to target database.
Database sync list command finished without transfer
```

这表示只是查看，没有向 15 数据库写入任何表、数据、函数或视图。

真正同步表时不要加 `--list-tables`，应执行：

```powershell
.\.venv\Scripts\python.exe maindata.py --only tables
```

### 7. 传输日志原理

每次执行 `maindata.py` 都会创建或追加当天日志：

```text
logs/dbsync_YYYYMMDD.log
```

日志记录内容包括：

- 同步开始时间
- 源库地址
- 目标库地址
- 同步模式
- 表数量
- 函数数量
- 视图数量
- 每个对象是否开始同步
- 目标对象是否存在
- 是否执行删除
- 每个对象是否成功
- 每个对象耗时
- 总耗时
- 失败异常

真正发生同步时，日志中应该能看到：

```text
[TABLE] Start sync: public.xxx
[TABLE] Success: public.xxx, elapsed=...
```

如果只看到：

```text
Table list item: public.xxx
Database sync list command finished without transfer
```

说明没有同步，只是列出了表。

### 8. 常见情况说明

如果 15 数据库中没有表和数据，先检查日志。

如果日志中出现：

```text
Database sync list command finished
```

或：

```text
List mode only: no objects will be synced to target database.
```

说明执行的是查看清单命令，不是同步命令。

正确同步表命令：

```powershell
.\.venv\Scripts\python.exe maindata.py --only tables
```

正确同步全部对象命令：

```powershell
.\.venv\Scripts\python.exe maindata.py --only all
```

如果同步 PostGIS 空间表，目标库需要先安装 PostGIS 扩展：

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
```

否则空间字段或空间索引恢复时可能失败。
