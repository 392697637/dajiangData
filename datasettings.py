# -*- coding: utf-8 -*-
"""
PostgreSQL database sync settings.

Default task:
    192.168.110.6 / ktd_lx_2026gis  ->  192.168.110.15 / ktd_lx_2026gis

Set SYNC_TABLES, SYNC_FUNCTIONS, and SYNC_VIEWS to the objects that should be
synchronized. Leave each list empty to sync all supported objects in SYNC_SCHEMAS.
"""

import os


SOURCE_DB = {
    "host": os.getenv("SYNC_SOURCE_HOST", "192.168.110.6"),
    "port": int(os.getenv("SYNC_SOURCE_PORT", "5432")),
    "database": os.getenv("SYNC_SOURCE_DB", "ktd_lx_2026gis"),
    "user": os.getenv("SYNC_SOURCE_USER", "zhuoyi"),
    "password": os.getenv("SYNC_SOURCE_PASSWORD", "Ktd@postSQL@2026!@#"),
}

TARGET_DB = {
    "host": os.getenv("SYNC_TARGET_HOST", "192.168.110.15"),
    "port": int(os.getenv("SYNC_TARGET_PORT", "5432")),
    "database": os.getenv("SYNC_TARGET_DB", "ktd_lx_2026gis"),
    "user": os.getenv("SYNC_TARGET_USER", "postgres"),
    "password": os.getenv("SYNC_TARGET_PASSWORD", "Ktd@postSQL@2026!@#"),
}

# Schemas used when SYNC_TABLES is empty.
SYNC_SCHEMAS = [
    "public",
]

# 表配置：同步表结构和数据。
# 说明：表同步使用 pg_dump --table，会保留主键、唯一约束、外键、普通索引、
# PostGIS 空间索引、字段默认值、触发器、表/字段注释等对象。
# 留空时同步 SYNC_SCHEMAS 下全部普通表。
# SYNC_TABLES = [
#     "public.jc_sheng",
#     "public.jc_shi",
#     "public.gis_poi_gd_410100",
# ]
SYNC_TABLES = [
    "public.bo_electric_fence",
    "public.bo_ground_ele",
]

# 函数配置：单独同步函数定义。
# 格式支持：
#   "public.fn_name"                  # 同步该名称下全部重载函数
#   "public.fn_name(integer, text)"   # 只同步指定参数签名
# 留空时同步 SYNC_SCHEMAS 下全部函数。
SYNC_FUNCTIONS = []

# 视图配置：单独同步普通视图定义。
# 格式示例：
#   "public.vw_name"
# 留空时同步 SYNC_SCHEMAS 下全部普通视图。
SYNC_VIEWS = []

# pg_dump/psql executable names or absolute paths.
PG_DUMP_BIN = os.getenv("PG_DUMP_BIN", "pg_dump")
PSQL_BIN = os.getenv("PSQL_BIN", "psql")

# Extra pg_dump options. Keep this list small and explicit.
PG_DUMP_EXTRA_ARGS = [
    "--no-owner",
    "--no-privileges",
]
