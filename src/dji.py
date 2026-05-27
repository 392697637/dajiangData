# -*- coding: utf-8 -*-
"""
DJI禁飞区爬虫 - 使用公开API版本

API说明:
- 禁飞区API: https://flysafe-api.dji.com/api/qep/geo/feedback/areas/in_rectangle
- 无人机型号API: https://flysafe-api.dji.com/dji/drones

禁飞区API参数:
- ltlat: 左上角纬度
- ltlng: 左上角经度
- rblat: 右下角纬度
- rblng: 右下角经度
- zones_mode: 区域模式 (flysafe_website)
- drone: 无人机型号slug
- level: 禁飞区级别 (0,1,2,3,7,8,10)
"""

import requests
import json
import warnings
import os

warnings.filterwarnings('ignore', message='Unverified HTTPS request')


class DJIFlySafeCrawler:
    def __init__(self):
        from config import DJI_API_URL, DJI_DRONES_API_URL, DJI_PARAMS, TIMEOUT, DEFAULT_LAT, DEFAULT_LNG, DEFAULT_RADIUS
        
        self.api_url = DJI_API_URL
        self.drones_api_url = DJI_DRONES_API_URL
        self.drone_model = DJI_PARAMS.get("default_drone", "dji-mavic-3")
        self.zones_mode = DJI_PARAMS.get("zones_mode", "flysafe_website")
        self.levels = DJI_PARAMS.get("levels", "0,1,2,3,7,8,10")
        self.timeout = TIMEOUT
        self.default_lat = DEFAULT_LAT
        self.default_lng = DEFAULT_LNG
        self.default_radius = DEFAULT_RADIUS
        self.drones_list = None
    
    def get_drones_list(self, force_refresh=False):
        if self.drones_list and not force_refresh:
            return self.drones_list
        
        print("正在获取无人机型号列表...")
        
        try:
            resp = requests.get(self.drones_api_url, timeout=self.timeout, verify=False)
            resp.encoding = 'utf-8'
            data = resp.json()
            
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
        drones = self.get_drones_list()
        slugs = [d["slug"] for d in drones] if drones else []
        
        if drones and drone_slug not in slugs:
            print("警告: 无人机型号 {} 不在支持列表中".format(drone_slug))
            print("可用型号: {}".format(", ".join(slugs[:5])))
            if len(slugs) > 5:
                print("... 还有 {} 个型号".format(len(slugs) - 5))
        
        self.drone_model = drone_slug
        print("已设置无人机型号: {}".format(drone_slug))
    
    def set_levels(self, levels):
        self.levels = levels
        print("已设置禁飞区级别: {}".format(levels))
    
    def _latlng_to_rectangle(self, lat, lng, radius_km):
        delta_lat = radius_km / 111.0
        delta_lng = radius_km / (111.0 * abs(self._deg2rad(lat)))
        
        ltlat = lat + delta_lat
        ltlng = lng - delta_lng
        rblat = lat - delta_lat
        rblng = lng + delta_lng
        
        return (ltlat, ltlng, rblat, rblng)
    
    def _deg2rad(self, deg):
        import math
        return deg * (math.pi / 180.0)
    
    def _create_geometry(self, item):
        shape_type = item.get("shape", 2)
        lat = item.get("lat")
        lng = item.get("lng")
        radius = item.get("radius")
        polygon_points = item.get("polygon_points")
        
        if shape_type == 1 and polygon_points:
            return {
                "type": "Polygon",
                "coordinates": polygon_points
            }
        elif shape_type == 2 and lat and lng and radius:
            return self._circle_to_polygon(lat, lng, radius)
        elif lat and lng:
            return {
                "type": "Point",
                "coordinates": [lng, lat]
            }
        return None
    
    def _circle_to_polygon(self, lat, lng, radius_m):
        import math
        
        points = []
        num_points = 36
        radius_deg = radius_m / 111000.0
        
        for i in range(num_points):
            angle = (2 * math.pi * i) / num_points
            x = lng + radius_deg * math.cos(angle) / math.cos(self._deg2rad(lat))
            y = lat + radius_deg * math.sin(angle)
            points.append([x, y])
        
        points.append(points[0])
        
        return {
            "type": "Polygon",
            "coordinates": [points]
        }
    
    def crawl(self, lat=None, lng=None, radius=None, output_file=None):
        lat = lat if lat is not None else self.default_lat
        lng = lng if lng is not None else self.default_lng
        radius = radius if radius is not None else self.default_radius
        
        if output_file is None:
            output_file = "output/dji/flyzones_{}_{}_{}.geojson".format(lat, lng, radius)
        
        os.makedirs(os.path.dirname(output_file) if os.path.dirname(output_file) else '.', exist_ok=True)
        
        ltlat, ltlng, rblat, rblng = self._latlng_to_rectangle(lat, lng, radius)
        
        params = {
            "ltlat": ltlat,
            "ltlng": ltlng,
            "rblat": rblat,
            "rblng": rblng,
            "zones_mode": self.zones_mode,
            "drone": self.drone_model,
            "level": self.levels
        }
        
        print("请求参数:")
        print("  矩形区域: ltlat={:.8f}, ltlng={:.8f}, rblat={:.8f}, rblng={:.8f}".format(ltlat, ltlng, rblat, rblng))
        print("  无人机型号: {}".format(self.drone_model))
        print("  禁飞区级别: {}".format(self.levels))
        
        try:
            resp = requests.get(self.api_url, params=params, timeout=self.timeout, verify=False)
            print("\n响应状态码: {}".format(resp.status_code))
            
            data = resp.json()
            
            if data.get("code") != 0:
                msg = data.get("message", {}).get("chinese", "Unknown error")
                raise Exception("API错误: {}".format(msg))
            
            areas = data.get("data", {}).get("areas", [])
            
            if not areas:
                raise Exception("未获取到禁飞区数据")
            
            features = []
            for item in areas:
                geometry = self._create_geometry(item)
                if geometry:
                    properties = {
                        "area_id": item.get("area_id"),
                        "name": item.get("name"),
                        "type": item.get("type"),
                        "level": item.get("level"),
                        "color": item.get("color"),
                        "country": item.get("country"),
                        "city": item.get("city"),
                        "address": item.get("address"),
                        "description": item.get("description"),
                        "height": item.get("height"),
                        "radius": item.get("radius"),
                        "begin_at": item.get("begin_at"),
                        "end_at": item.get("end_at"),
                        "data_source": item.get("data_source")
                    }
                    feature = {
                        "type": "Feature",
                        "geometry": geometry,
                        "properties": properties
                    }
                    features.append(feature)
            
            geojson = {
                "type": "FeatureCollection",
                "features": features,
                "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:EPSG::4326"}}
            }
            
            with open(output_file, "w", encoding="utf-8") as f:
                json.dump(geojson, f, ensure_ascii=False, indent=2)
            
            print("\n成功！共获取 {} 个禁飞区".format(len(features)))
            print("输出文件: {}".format(output_file))
            
            return geojson
        
        except requests.exceptions.RequestException as e:
            raise Exception("请求失败: {}".format(str(e)))
        except json.JSONDecodeError as e:
            raise Exception("JSON解析失败: {}".format(str(e)))
        except Exception as e:
            raise Exception("错误: {}".format(str(e)))