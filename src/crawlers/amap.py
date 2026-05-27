# -*- coding: utf-8 -*-
"""
高德POI爬虫

此模块实现高德地图POI（兴趣点）数据的爬取功能。

API端点说明:
- POI搜索API: https://restapi.amap.com/v3/place/around

功能特性:
1. 支持周边POI搜索
2. 支持多种POI类型
3. 支持分页获取数据
4. 支持关键词搜索

使用方式:
    from src.crawlers import AmapPOICrawler
    from config import AMAP_CONFIG
    
    crawler = AmapPOICrawler(AMAP_CONFIG)
    result = crawler.crawl(lat=34.72, lng=113.62, keywords="机场")

注意:
    需要在高德地图开放平台申请API Key，并配置到config/settings.py中。
"""

import warnings

# 导入基类
from .base import BaseCrawler

# 忽略SSL验证警告
warnings.filterwarnings('ignore', message='Unverified HTTPS request')


class AmapPOICrawler(BaseCrawler):
    """
    高德POI爬虫，继承自BaseCrawler
    
    Attributes:
        api_url (str): POI搜索API端点
        api_key (str): 高德API Key
        poi_types (list): POI类型编码列表
        radius (int): 搜索半径（米）
        page_size (int): 每页返回数量
        extensions (str): 返回信息类型（base/all）
    """
    
    def __init__(self, config):
        """
        初始化高德POI爬虫
        
        Args:
            config (dict): 高德配置字典，应包含以下关键字:
                - api_url: POI搜索API端点
                - api_key: 高德API Key
                - poi_types: POI类型编码列表
                - output_dir: 输出目录
                - radius: 搜索半径（米）
                - page_size: 每页返回数量
                - extensions: 返回信息类型
        """
        # 调用父类初始化
        super().__init__(config)
        
        # 保存API端点
        self.api_url = config['api_url']
        
        # 保存API Key（需要在高德地图开放平台申请）
        self.api_key = config.get('api_key', '')
        
        # 保存POI类型列表
        self.poi_types = config.get('poi_types', [])
        
        # 设置搜索半径（米）
        self.radius = config.get('radius', 5000)
        
        # 设置每页返回数量
        self.page_size = config.get('page_size', 20)
        
        # 设置返回信息类型（base: 基础信息, all: 详细信息）
        self.extensions = config.get('extensions', 'all')
    
    def crawl(self, lat=None, lng=None, keywords=None, output_file=None):
        """
        爬取高德POI数据
        
        核心方法，负责发送API请求、分页获取数据并保存结果。
        
        Args:
            lat (float): 中心纬度（可选，默认为配置中的默认值）
            lng (float): 中心经度（可选，默认为配置中的默认值）
            keywords (str): 搜索关键词（可选）
            output_file (str): 输出文件路径（可选，自动生成）
        
        Returns:
            dict: POI数据结果，包含状态、数量和数据列表
        
        Raises:
            Exception: 请求失败、API Key未配置或数据异常时抛出异常
        
        Example:
            >>> crawler.crawl(lat=34.72, lng=113.62, keywords="机场")
            {"status": "success", "count": 10, "location": {...}, "data": [...]}
        """
        # 导入默认配置
        from config import DEFAULT_LAT, DEFAULT_LNG
        
        # 使用传入参数或默认值
        lat = lat if lat is not None else DEFAULT_LAT
        lng = lng if lng is not None else DEFAULT_LNG
        
        # 检查API Key是否已配置
        if not self.api_key or self.api_key == 'your_amap_api_key':
            raise Exception("请先在config/settings.py中配置高德API Key")
        
        # 生成输出文件名（如果未指定）
        if output_file is None:
            output_file = "poi_{}_{}_{}.json".format(lat, lng, self.radius)
        
        # 存储所有POI数据
        all_results = []
        
        # 遍历所有POI类型
        for poi_type in self.poi_types:
            # 初始化页码
            page = 1
            
            # 分页获取数据
            while True:
                # 构建API请求参数
                params = {
                    "key": self.api_key,                  # API Key（必需）
                    "location": "{},{}".format(lng, lat),  # 中心点坐标（格式：经度,纬度）
                    "radius": self.radius,                 # 搜索半径（米）
                    "types": poi_type,                     # POI类型编码
                    "page": page,                          # 页码
                    "offset": self.page_size,              # 每页数量
                    "extensions": self.extensions,         # 返回信息类型
                    "output": "json"                       # 输出格式
                }
                
                # 如果指定了关键词，添加到请求参数
                if keywords:
                    params["keywords"] = keywords
                
                # 打印请求信息
                print("请求POI类型: {}, 页码: {}".format(poi_type, page))
                
                # 发送API请求
                resp = self._make_request(self.api_url, params=params)
                
                # 解析JSON响应
                data = resp.json()
                
                # 检查API返回状态
                status = data.get('status')
                if status != '1':
                    # 获取错误信息
                    error_info = data.get('info', 'Unknown error')
                    print("API返回错误: {}".format(error_info))
                    break
                
                # 提取POI数据
                pois = data.get('pois', [])
                
                # 如果当前页没有数据，跳出循环
                if not pois:
                    break
                
                # 将当前页数据添加到总结果
                all_results.extend(pois)
                
                # 增加页码
                page += 1
                
                # 检查是否还有更多数据
                total = int(data.get('count', 0))
                if (page - 1) * self.page_size >= total:
                    break
        
        # 构建结果字典
        result = {
            "status": "success",
            "count": len(all_results),
            "location": {"lat": lat, "lng": lng},
            "radius": self.radius,
            "keywords": keywords,
            "data": all_results
        }
        
        # 保存结果到文件
        filepath = self._save_json(result, output_file)
        
        # 打印成功信息
        print("\n成功！共获取 {} 个POI".format(len(all_results)))
        print("输出文件: {}".format(filepath))
        
        return result