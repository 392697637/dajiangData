# -*- coding: utf-8 -*-
"""
爬虫模块初始化

此模块提供爬虫基类和具体爬虫实现的统一入口。

导出的类:
    BaseCrawler: 爬虫基类，提供通用功能
    DJIFlySafeCrawler: DJI禁飞区爬虫
    AmapPOICrawler: 高德POI爬虫

使用方式:
    from src.crawlers import DJIFlySafeCrawler, AmapPOICrawler
"""

# 导入爬虫类
from .base import BaseCrawler
from .dji import DJIFlySafeCrawler
from .amap import AmapPOICrawler
from .tianditu import TiandituPOICrawler

# 定义公开导出的类列表
__all__ = [
    'BaseCrawler',
    'DJIFlySafeCrawler',
    'AmapPOICrawler',
    'TiandituPOICrawler',
]