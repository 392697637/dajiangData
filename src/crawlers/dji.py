# -*- coding: utf-8 -*-
"""
DJI禁飞区爬虫

此模块实现DJI禁飞区数据的爬取功能，使用公开API获取禁飞区信息。

API端点说明:
- 禁飞区API: https://flysafe-api.dji.com/api/qep/geo/feedback/areas/in_rectangle
- 无人机型号API: https://flysafe-api.dji.com/dji/drones

功能特性:
1. 支持动态获取无人机型号列表（72+型号）
2. 支持自定义坐标和搜索半径
3. 自动将圆形区域转换为多边形
4. 输出标准GeoJSON格式
5. 支持大面积区域分块爬取（如按1000km分块爬取中国区域）
6. 支持子区域解析（sub_areas）

使用方式:
    from src.crawlers import DJIFlySafeCrawler
    from config import DJI_CONFIG
    
    crawler = DJIFlySafeCrawler(DJI_CONFIG)
    
    # 单个区域爬取
    result = crawler.crawl(lat=34.72, lng=113.62, radius=50)
    
    # 按区域分块爬取（如爬取整个中国）
    result = crawler.crawl_region(region_name="china", grid_size_km=1000)
"""

import warnings
import json
import os
import math

# 导入基类和工具函数
from .base import BaseCrawler
from src.utils.geo import latlng_to_rectangle, parse_dji_response

# 忽略SSL验证警告
warnings.filterwarnings('ignore', message='Unverified HTTPS request')


class DJIFlySafeCrawler(BaseCrawler):
    """
    DJI禁飞区爬虫，继承自BaseCrawler
    
    Attributes:
        api_url (str): 禁飞区API端点
        drones_api_url (str): 无人机型号API端点
        params (dict): 请求参数配置
        drone_model (str): 当前选择的无人机型号slug
        zones_mode (str): 区域模式（固定为'flysafe_website'）
        levels (str): 禁飞区级别筛选（逗号分隔）
        drones_list (list): 缓存的无人机型号列表
        region_config (dict): 区域分块配置
    """
    
    def __init__(self, config):
        """
        初始化DJI禁飞区爬虫
        
        Args:
            config (dict): DJI配置字典，应包含以下关键字:
                - api_url: 禁飞区API端点
                - drones_api_url: 无人机型号API端点
                - output_dir: 输出目录
                - params: 请求参数配置
                - region_config: 区域分块配置
        """
        # 调用父类初始化
        super().__init__(config)
        
        # 保存API端点
        self.api_url = config['api_url']
        self.drones_api_url = config['drones_api_url']
        
        # 保存请求参数配置
        self.params = config.get('params', {})
        
        # 设置默认无人机型号
        self.drone_model = self.params.get('default_drone', 'dji-mavic-3')
        
        # 设置区域模式（固定值）
        self.zones_mode = self.params.get('zones_mode', 'flysafe_website')
        
        # 设置禁飞区级别筛选
        self.levels = self.params.get('levels', '0,1,2,3,7,8,10')
        
        # 初始化无人机型号列表缓存
        self.drones_list = None
        
        # 保存区域分块配置
        self.region_config = config.get('region_config', {})
    
    def get_drones_list(self, force_refresh=False):
        """
        获取支持的无人机型号列表
        
        从DJI API获取所有支持的无人机型号，并缓存结果。
        
        Args:
            force_refresh (bool): 是否强制刷新缓存（默认False）
        
        Returns:
            list: 无人机型号列表，每个元素为dict，包含'name'和'slug'字段
        
        Example:
            >>> crawler.get_drones_list()
            [{'name': 'DJI Mavic 3', 'slug': 'dji-mavic-3'}, ...]
        """
        # 如果缓存存在且不需要强制刷新，直接返回缓存
        if self.drones_list and not force_refresh:
            return self.drones_list
        
        print("正在获取无人机型号列表...")
        
        try:
            # 发送请求获取无人机型号列表
            resp = self._make_request(self.drones_api_url)
            resp.encoding = 'utf-8'  # 设置正确编码
            data = resp.json()
            
            # 提取无人机列表
            if "drones" in data:
                self.drones_list = data["drones"]
                print("OK 获取到 {} 个无人机型号".format(len(self.drones_list)))
                return self.drones_list
            else:
                print("警告: 无法获取无人机型号列表")
                return []
        except Exception as e:
            print("获取无人机型号列表失败: {}".format(str(e)))
            return []
    
    def list_drones(self):
        """打印所有支持的无人机型号"""
        drones = self.get_drones_list()
        if drones:
            print("\n支持的无人机型号:")
            print("-" * 60)
            for i, drone in enumerate(drones, 1):
                print("{:2d}. {}".format(i, drone["name"]))
                print("    slug: {}".format(drone["slug"]))
            print("-" * 60)
        else:
            print("无法获取无人机型号列表")
    
    def set_drone_model(self, drone_slug):
        """
        设置无人机型号
        
        Args:
            drone_slug (str): 无人机型号的slug（如 'dji-mavic-3'）
        """
        # 获取无人机列表进行验证
        drones = self.get_drones_list()
        slugs = [d["slug"] for d in drones] if drones else []
        
        # 如果无人机型号不在支持列表中，输出警告
        if drones and drone_slug not in slugs:
            print("警告: 无人机型号 {} 不在支持列表中".format(drone_slug))
        
        # 设置无人机型号
        self.drone_model = drone_slug
        print("已设置无人机型号: {}".format(drone_slug))
    
    def _generate_grid_points(self, lat_min, lat_max, lng_min, lng_max, grid_size_km):
        """
        生成网格中心点坐标
        
        将指定区域按指定网格大小分块，生成每个网格的中心点坐标。
        
        Args:
            lat_min (float): 最小纬度（最南端）
            lat_max (float): 最大纬度（最北端）
            lng_min (float): 最小经度（最西端）
            lng_max (float): 最大经度（最东端）
            grid_size_km (float): 网格大小（公里）
        
        Returns:
            list: 网格中心点坐标列表，每个元素为 (lat, lng, index)
        """
        # 使用平均纬度计算经度方向的距离
        avg_lat = (lat_min + lat_max) / 2
        lat_grid_count = int((lat_max - lat_min) * 111 / grid_size_km) + 1
        lng_grid_count = int((lng_max - lng_min) * 111 * abs(math.cos(math.pi * avg_lat / 180.0)) / grid_size_km) + 1
        
        # 确保至少有1个网格
        lat_grid_count = max(lat_grid_count, 1)
        lng_grid_count = max(lng_grid_count, 1)
        
        print("生成网格: {} × {} = {} 个中心点".format(lng_grid_count, lat_grid_count, lng_grid_count * lat_grid_count))
        
        # 计算每个网格的间距
        lat_step = (lat_max - lat_min) / lat_grid_count if lat_grid_count > 1 else 0
        lng_step = (lng_max - lng_min) / lng_grid_count if lng_grid_count > 1 else 0
        
        # 生成网格中心点
        points = []
        index = 1
        for lat_idx in range(lat_grid_count):
            for lng_idx in range(lng_grid_count):
                lat = lat_max - lat_idx * lat_step - lat_step / 2
                lng = lng_min + lng_idx * lng_step + lng_step / 2
                
                # 确保坐标在边界内
                lat = max(lat_min, min(lat_max, lat))
                lng = max(lng_min, min(lng_max, lng))
                
                points.append((lat, lng, index))
                index += 1
        
        return points
    
    def crawl(self, lat=None, lng=None, radius=None, output_file=None):
        """
        爬取单个区域的DJI禁飞区数据
        
        核心方法，负责发送API请求、解析响应并保存结果。
        
        Args:
            lat (float): 中心纬度（可选，默认为配置中的默认值）
            lng (float): 中心经度（可选，默认为配置中的默认值）
            radius (float): 搜索半径（公里，可选，默认为配置中的默认值）
            output_file (str): 输出文件路径（可选，自动生成）
        
        Returns:
            dict: GeoJSON格式的禁飞区数据
        
        Raises:
            Exception: 请求失败、解析失败或数据异常时抛出异常
        """
        import math
        from config import DEFAULT_LAT, DEFAULT_LNG, DEFAULT_RADIUS
        
        # 使用传入参数或默认值
        lat = lat if lat is not None else DEFAULT_LAT
        lng = lng if lng is not None else DEFAULT_LNG
        radius = radius if radius is not None else DEFAULT_RADIUS
        
        # 生成输出文件名（如果未指定）
        if output_file is None:
            output_file = "flyzones_{}_{}_{}.geojson".format(lat, lng, radius)
        
        # 将中心点和半径转换为矩形区域
        ltlat, ltlng, rblat, rblng = latlng_to_rectangle(lat, lng, radius)
        
        # 构建API请求参数
        params = {
            "ltlat": ltlat,      # 左上角纬度
            "ltlng": ltlng,      # 左上角经度
            "rblat": rblat,      # 右下角纬度
            "rblng": rblng,      # 右下角经度
            "zones_mode": self.zones_mode,  # 区域模式
            "drone": self.drone_model,      # 无人机型号
            "level": self.levels            # 禁飞区级别
        }
        
        # 打印请求参数信息
        print("请求参数:")
        print("  矩形区域: ltlat={:.8f}, ltlng={:.8f}, rblat={:.8f}, rblng={:.8f}".format(ltlat, ltlng, rblat, rblng))
        print("  无人机型号: {}".format(self.drone_model))
        print("  禁飞区级别: {}".format(self.levels))
        
        # 发送API请求
        resp = self._make_request(self.api_url, params=params)
        print("\n响应状态码: {}".format(resp.status_code))
        
        # 解析JSON响应
        data = resp.json()
        
        # 使用新的解析函数处理API响应
        features = parse_dji_response(data)
        
        # 检查是否获取到数据
        if not features:
            raise Exception("未获取到禁飞区数据")
        
        # 构建完整的GeoJSON对象
        geojson = {
            "type": "FeatureCollection",
            "features": features,
            "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:EPSG::4326"}}
        }
        
        # 保存GeoJSON文件
        filepath = self._save_json(geojson, output_file)
        
        # 打印成功信息
        print("\n成功！共获取 {} 个禁飞区".format(len(features)))
        print("输出文件: {}".format(filepath))
        
        return geojson
    
    def crawl_region(self, region_name="china", grid_size_km=1000):
        """
        按区域分块爬取DJI禁飞区数据
        
        将指定区域按网格分块，依次爬取每个网格的禁飞区数据，最后合并结果。
        
        Args:
            region_name (str): 区域名称（默认为"china"，需在配置中定义）
            grid_size_km (float): 网格大小（公里，默认1000）
        
        Returns:
            dict: 合并后的GeoJSON格式禁飞区数据
        
        Raises:
            Exception: 区域配置不存在或爬取失败时抛出异常
        """
        import math
        
        # 获取区域配置
        region_info = self.region_config.get(region_name)
        if not region_info:
            raise Exception("区域配置不存在: {}".format(region_name))
        
        region_name_cn = region_info.get("name", region_name)
        lat_min = region_info.get("lat_min", 18.0)
        lat_max = region_info.get("lat_max", 54.0)
        lng_min = region_info.get("lng_min", 73.0)
        lng_max = region_info.get("lng_max", 135.0)
        
        print("=" * 70)
        print("开始按区域分块爬取禁飞区数据")
        print("区域: {}".format(region_name_cn))
        print("边界: 纬度 {:.2f}~{:.2f}, 经度 {:.2f}~{:.2f}".format(lat_min, lat_max, lng_min, lng_max))
        print("网格大小: {} km".format(grid_size_km))
        print("=" * 70)
        
        # 生成网格中心点
        grid_points = self._generate_grid_points(lat_min, lat_max, lng_min, lng_max, grid_size_km)
        
        # 存储所有爬取的features
        all_features = []
        success_count = 0
        fail_count = 0
        
        # 遍历所有网格点进行爬取
        for lat, lng, index in grid_points:
            print("\n[{}/{}] 爬取网格点: ({:.4f}, {:.4f})".format(index, len(grid_points), lat, lng))
            
            try:
                # 爬取当前网格点的禁飞区数据
                result = self.crawl(lat=lat, lng=lng, radius=grid_size_km / 2)
                
                # 添加到总结果
                features = result.get("features", [])
                all_features.extend(features)
                
                # 记录成功数
                success_count += 1
                print("  ✓ 成功获取 {} 个禁飞区".format(len(features)))
                
            except Exception as e:
                # 记录失败数
                fail_count += 1
                print("  ✗ 爬取失败: {}".format(str(e)))
        
        # 去重（根据area_id）
        seen_ids = set()
        unique_features = []
        for feature in all_features:
            area_id = feature.get("properties", {}).get("area_id")
            if area_id and area_id not in seen_ids:
                seen_ids.add(area_id)
                unique_features.append(feature)
        
        # 构建合并后的GeoJSON
        merged_geojson = {
            "type": "FeatureCollection",
            "features": unique_features,
            "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:EPSG::4326"}},
            "metadata": {
                "region": region_name_cn,
                "grid_size_km": grid_size_km,
                "total_grids": len(grid_points),
                "success_grids": success_count,
                "fail_grids": fail_count,
                "total_features_before_dedup": len(all_features),
                "total_features_after_dedup": len(unique_features)
            }
        }
        
        # 生成输出文件名
        output_file = "flyzones_{}_{}km.geojson".format(region_name, grid_size_km)
        
        # 保存合并后的文件
        filepath = self._save_json(merged_geojson, output_file)
        
        # 打印汇总信息
        print("\n" + "=" * 70)
        print("区域爬取完成！")
        print("区域: {}".format(region_name_cn))
        print("网格大小: {} km".format(grid_size_km))
        print("总网格数: {}".format(len(grid_points)))
        print("成功: {}, 失败: {}".format(success_count, fail_count))
        print("合并前禁飞区数量: {}".format(len(all_features)))
        print("去重后禁飞区数量: {}".format(len(unique_features)))
        print("输出文件: {}".format(filepath))
        print("=" * 70)
        
        return merged_geojson