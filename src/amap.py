# -*- coding: utf-8 -*-
"""
高德地图POI爬虫
从高德API获取POI数据并保存为GeoJSON
"""

import requests
import json
import os


class AmapPOICrawler:
    def __init__(self):
        # 从配置文件加载参数
        from config import AMAP_API_KEY, AMAP_POI_TYPES, AMAP_API_URL, TIMEOUT
        self.api_key = AMAP_API_KEY
        self.poi_types = AMAP_POI_TYPES
        self.base_url = AMAP_API_URL
        self.timeout = TIMEOUT
    
    def crawl(self, lat, lng, radius, output_file, keywords=None):
        """爬取POI数据"""
        os.makedirs(os.path.dirname(output_file) if os.path.dirname(output_file) else '.', exist_ok=True)
        
        # 检查API Key
        if not self.api_key or self.api_key == "your_amap_api_key":
            raise Exception("请在config.py中配置高德API Key")
        
        all_features = []
        
        for poi_type in self.poi_types:
            print(f"Fetching POI type: {poi_type}")
            
            page = 1
            while page <= 100:
                params = {
                    "key": self.api_key,
                    "location": f"{lng},{lat}",
                    "radius": radius * 1000,
                    "types": poi_type,
                    "keywords": keywords if keywords else "",
                    "page": page,
                    "offset": 20,
                    "extensions": "all"
                }
                
                try:
                    res = requests.get(self.base_url, params=params, timeout=self.timeout)
                    res.raise_for_status()
                    data = res.json()
                    
                    if data.get("status") != "1":
                        break
                    
                    pois = data.get("pois", [])
                    if not pois:
                        break
                    
                    for poi in pois:
                        feature = {
                            "type": "Feature",
                            "properties": {
                                "name": poi.get("name", ""),
                                "type": poi.get("type", ""),
                                "address": poi.get("address", ""),
                                "city": poi.get("cityname", ""),
                                "district": poi.get("adname", ""),
                                "tel": poi.get("tel", ""),
                                "distance": poi.get("distance", 0)
                            },
                            "geometry": {
                                "type": "Point",
                                "coordinates": [
                                    float(poi.get("location", "0,0").split(",")[0]),
                                    float(poi.get("location", "0,0").split(",")[1])
                                ]
                            }
                        }
                        all_features.append(feature)
                    
                    print(f"  Page {page}: {len(pois)} POIs")
                    page += 1
                except:
                    break
        
        geojson = {"type": "FeatureCollection", "features": all_features}
        with open(output_file, "w", encoding="utf-8") as f:
            json.dump(geojson, f, ensure_ascii=False, indent=2)
        
        return geojson