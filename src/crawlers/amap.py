# -*- coding: utf-8 -*-
"""
高德POI爬虫

支持三种搜索模式:
1. 周边搜索 (v3/place/around) - 中心点 + 半径
2. 多边形/矩形范围搜索 (v5/place/polygon) - 指定边界
3. 区域分块搜索 - 按省份/自定义区域网格化爬取
"""

import time
import warnings

from .base import BaseCrawler
from src.utils.geo import (
    generate_grid_points,
    bounds_to_amap_polygon,
    latlng_to_rectangle,
)

warnings.filterwarnings('ignore', message='Unverified HTTPS request')


class AmapPOICrawler(BaseCrawler):
    """高德POI爬虫"""

    def __init__(self, config):
        super().__init__(config)

        self.around_api_url = config.get('around_api_url') or config.get('api_url')
        self.polygon_api_url = config.get('polygon_api_url', 'https://restapi.amap.com/v5/place/polygon')
        self.api_key = config.get('api_key', '')
        self.poi_types = config.get('poi_types', [])
        self.radius = config.get('radius', 5000)
        self.page_size = config.get('page_size', 20)
        self.polygon_page_size = config.get('polygon_page_size', 25)
        self.extensions = config.get('extensions', 'all')
        self.request_delay = config.get('request_delay', 0.2)
        self.region_config = config.get('region_config', {})

    def _check_api_key(self):
        if not self.api_key or self.api_key == 'your_amap_api_key':
            raise Exception("请先在config/settings.py中配置高德API Key")

    def _sleep(self):
        if self.request_delay > 0:
            time.sleep(self.request_delay)

    def _dedupe_pois(self, pois):
        seen = set()
        unique = []
        for poi in pois:
            poi_id = poi.get('id')
            if poi_id and poi_id in seen:
                continue
            if poi_id:
                seen.add(poi_id)
            unique.append(poi)
        return unique

    def _fetch_pois_around(self, lat, lng, keywords=None, radius=None):
        """周边搜索 (v3)"""
        radius = radius if radius is not None else self.radius
        all_results = []

        for poi_type in self.poi_types:
            page = 1
            while True:
                params = {
                    "key": self.api_key,
                    "location": "{},{}".format(lng, lat),
                    "radius": radius,
                    "types": poi_type,
                    "page": page,
                    "offset": self.page_size,
                    "extensions": self.extensions,
                    "output": "json",
                }
                if keywords:
                    params["keywords"] = keywords

                print("周边搜索 类型: {}, 页码: {}".format(poi_type, page))
                resp = self._make_request(self.around_api_url, params=params)
                data = resp.json()

                if data.get('status') != '1':
                    print("API返回错误: {}".format(data.get('info', 'Unknown error')))
                    break

                pois = data.get('pois', [])
                if not pois:
                    break

                all_results.extend(pois)
                page += 1

                total = int(data.get('count', 0))
                if (page - 1) * self.page_size >= total:
                    break

                self._sleep()

        return all_results

    def _fetch_pois_polygon(self, polygon, keywords=None):
        """多边形/矩形范围搜索 (v5)"""
        all_results = []
        types_param = "|".join(self.poi_types) if self.poi_types else None

        page_num = 1
        while True:
            params = {
                "key": self.api_key,
                "polygon": polygon,
                "page_num": page_num,
                "page_size": self.polygon_page_size,
                "output": "json",
            }
            if keywords:
                params["keywords"] = keywords
            if types_param:
                params["types"] = types_param

            print("范围搜索 页码: {}".format(page_num))
            resp = self._make_request(self.polygon_api_url, params=params)
            data = resp.json()

            if data.get('status') != '1':
                print("API返回错误: {}".format(data.get('info', 'Unknown error')))
                break

            pois = data.get('pois', [])
            if not pois:
                break

            all_results.extend(pois)
            page_num += 1

            total = int(data.get('count', 0))
            if (page_num - 1) * self.polygon_page_size >= total:
                break

            self._sleep()

        return all_results

    def _build_result(self, pois, output_file, metadata=None):
        result = {
            "status": "success",
            "count": len(pois),
            "data": pois,
        }
        if metadata:
            result["metadata"] = metadata

        saved_count = self._save_pois_to_db(pois, "amap", metadata=metadata)
        result["db_table"] = self.db_table
        result["db_count"] = saved_count
        print("\n成功！共获取 {} 个高德POI，已入库 {} 条".format(len(pois), saved_count))
        print("入库表: {}".format(self.db_table))
        return result

    def crawl(self, lat=None, lng=None, radius=None, keywords=None, output_file=None):
        """
        单点周边搜索

        Args:
            lat, lng: 中心坐标
            radius: 搜索半径（米），未指定时使用配置默认值
        """
        from config import DEFAULT_LAT, DEFAULT_LNG

        lat = lat if lat is not None else DEFAULT_LAT
        lng = lng if lng is not None else DEFAULT_LNG
        self._check_api_key()

        if output_file is None:
            output_file = "poi_{}_{}_{}.json".format(lat, lng, radius or self.radius)

        pois = self._fetch_pois_around(lat, lng, keywords=keywords, radius=radius)
        return self._build_result(pois, output_file, {
            "mode": "around",
            "location": {"lat": lat, "lng": lng},
            "radius": radius or self.radius,
            "keywords": keywords,
        })

    def crawl_bounds(self, lat_min, lat_max, lng_min, lng_max, keywords=None, output_file=None):
        """
        按矩形范围搜索POI

        Args:
            lat_min, lat_max, lng_min, lng_max: 矩形边界
        """
        self._check_api_key()

        if output_file is None:
            output_file = "poi_bounds_{}_{}_{}_{}.json".format(
                lat_min, lat_max, lng_min, lng_max
            )

        polygon = bounds_to_amap_polygon(lng_min, lat_min, lng_max, lat_max)
        print("矩形范围: 纬度 {:.4f}~{:.4f}, 经度 {:.4f}~{:.4f}".format(
            lat_min, lat_max, lng_min, lng_max
        ))

        pois = self._fetch_pois_polygon(polygon, keywords=keywords)
        pois = self._dedupe_pois(pois)

        return self._build_result(pois, output_file, {
            "mode": "bounds",
            "bounds": {
                "lat_min": lat_min, "lat_max": lat_max,
                "lng_min": lng_min, "lng_max": lng_max,
            },
            "keywords": keywords,
        })

    def crawl_region(self, region_name="henan", grid_size_km=None, keywords=None, output_file=None):
        """
        按区域分块搜索POI

        将区域划分为网格，对每个网格进行矩形范围搜索并合并去重。
        """
        self._check_api_key()

        region_info = self.region_config.get(region_name)
        if not region_info:
            raise Exception("区域配置不存在: {}".format(region_name))

        region_name_cn = region_info.get("name", region_name)
        lat_min = region_info.get("lat_min")
        lat_max = region_info.get("lat_max")
        lng_min = region_info.get("lng_min")
        lng_max = region_info.get("lng_max")
        grid_size_km = grid_size_km or region_info.get("grid_size_km", 200)

        print("=" * 70)
        print("开始按区域分块爬取高德POI")
        print("区域: {}".format(region_name_cn))
        print("边界: 纬度 {:.2f}~{:.2f}, 经度 {:.2f}~{:.2f}".format(
            lat_min, lat_max, lng_min, lng_max
        ))
        print("网格大小: {} km".format(grid_size_km))
        print("=" * 70)

        grid_points = generate_grid_points(lat_min, lat_max, lng_min, lng_max, grid_size_km)
        all_pois = []
        success_count = 0
        fail_count = 0

        for lat, lng, index in grid_points:
            print("\n[{}/{}] 爬取网格: ({:.4f}, {:.4f})".format(
                index, len(grid_points), lat, lng
            ))
            try:
                ltlat, ltlng, rblat, rblng = latlng_to_rectangle(lat, lng, grid_size_km / 2)
                polygon = bounds_to_amap_polygon(ltlng, rblat, rblng, ltlat)
                pois = self._fetch_pois_polygon(polygon, keywords=keywords)
                all_pois.extend(pois)
                success_count += 1
                print("  成功获取 {} 个POI".format(len(pois)))
            except Exception as e:
                fail_count += 1
                print("  爬取失败: {}".format(str(e)))

        unique_pois = self._dedupe_pois(all_pois)

        if output_file is None:
            output_file = "poi_{}_{}km.json".format(region_name, grid_size_km)

        return self._build_result(unique_pois, output_file, {
            "mode": "region",
            "region": region_name_cn,
            "grid_size_km": grid_size_km,
            "total_grids": len(grid_points),
            "success_grids": success_count,
            "fail_grids": fail_count,
            "total_before_dedup": len(all_pois),
            "keywords": keywords,
        })
