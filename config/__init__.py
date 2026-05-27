# -*- coding: utf-8 -*-
"""
配置模块初始化

此模块负责加载和导出所有配置参数，为整个项目提供统一的配置管理入口。

导出的配置项:
    DEFAULT_LAT: 默认纬度（郑州）
    DEFAULT_LNG: 默认经度（郑州）
    DEFAULT_RADIUS: 默认搜索半径（公里）
    TIMEOUT: 请求超时时间（秒）
    DJI_CONFIG: DJI禁飞区爬虫配置
    AMAP_CONFIG: 高德POI爬虫配置
"""

# 从settings模块导入所有配置项
from .settings import (
    DEFAULT_LAT,
    DEFAULT_LNG,
    DEFAULT_RADIUS,
    TIMEOUT,
    DJI_CONFIG,
    AMAP_CONFIG
)

# 定义公开导出的配置项列表
__all__ = [
    'DEFAULT_LAT',
    'DEFAULT_LNG',
    'DEFAULT_RADIUS',
    'TIMEOUT',
    'DJI_CONFIG',
    'AMAP_CONFIG'
]