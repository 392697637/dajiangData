# -*- coding: utf-8 -*-
"""
工具函数模块初始化

此模块提供地理相关的工具函数，用于坐标转换和几何图形处理。

导出的函数:
    latlng_to_rectangle: 将中心点和半径转换为矩形区域
    circle_to_polygon: 将圆形转换为近似多边形
    deg2rad: 角度转弧度
"""

# 从geo模块导入工具函数
from .geo import (
    latlng_to_rectangle,
    circle_to_polygon,
    deg2rad,
    create_geometry,
    generate_grid_points,
    bounds_to_map_bound,
    bounds_to_amap_polygon,
    bounds_to_tianditu_polygon,
)

# 定义公开导出的函数列表
__all__ = [
    'latlng_to_rectangle',
    'circle_to_polygon',
    'deg2rad',
    'create_geometry',
    'generate_grid_points',
    'bounds_to_map_bound',
    'bounds_to_amap_polygon',
    'bounds_to_tianditu_polygon',
]