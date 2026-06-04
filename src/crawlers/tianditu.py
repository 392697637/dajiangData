# -*- coding: utf-8 -*-
"""
天地图POI爬虫

支持三种搜索模式:
1. 视野内搜索 (queryType=2) - mapBound 矩形范围
2. 多边形搜索 (queryType=10) - polygon 多边形/矩形范围
3. 周边搜索 (queryType=3) - 中心点 + 半径
4. 区域分块搜索 - 按省份/自定义区域网格化爬取
"""

import json
import time
import warnings

from .base import BaseCrawler
from src.utils.geo import (
    generate_grid_points,
    bounds_to_map_bound,
    bounds_to_tianditu_polygon,
    latlng_to_rectangle,
)

warnings.filterwarnings('ignore', message='Unverified HTTPS request')


class TiandituPOICrawler(BaseCrawler):
    """天地图POI爬虫"""

    QUERY_MAPBOUND = 2
    QUERY_AROUND = 3
    QUERY_POLYGON = 10

    def __init__(self, config):
        super().__init__(config)

        self.api_url = config['api_url']
        self.api_key = config.get('api_key', '')
        self.data_types = config.get('data_types', '')
        self.level = config.get('level', 12)
        self.page_size = config.get('page_size', 100)
        self.default_keyword = config.get('default_keyword', 'POI')
        self.show = config.get('show', '2')
        self.request_delay = config.get('request_delay', 0.2)
        self.region_config = config.get('region_config', {})

    def _check_api_key(self):
        if not self.api_key or self.api_key == 'your_tianditu_api_key':
            raise Exception("请先在config/settings.py中配置天地图API Key")

    def _sleep(self):
        if self.request_delay > 0:
            time.sleep(self.request_delay)

    def _search(self, post_data):
        """发送天地图搜索请求"""
        params = {
            "postStr": json.dumps(post_data, ensure_ascii=False, separators=(',', ':')),
            "type": "query",
            "tk": self.api_key,
        }
        resp = self._make_request(self.api_url, params=params)
        return resp.json()

    def _extract_pois(self, data):
        if not data:
            return []

        status = data.get('status', {})
        infocode = status.get('infocode', -1)
        if infocode != 1000 and infocode != 0:
            cndesc = status.get('cndesc', 'Unknown error')
            print("API返回错误: {} ({})".format(cndesc, infocode))
            return []

        if data.get('resultType') != 1:
            return []

        return data.get('pois', [])

    def _fetch_pois_paged(self, base_post_data):
        """分页获取POI"""
        all_results = []
        start = 0

        while True:
            post_data = dict(base_post_data)
            post_data['start'] = str(start)
            post_data['count'] = str(self.page_size)

            print("请求 queryType={}, start={}".format(
                post_data.get('queryType'), start
            ))
            data = self._search(post_data)
            pois = self._extract_pois(data)

            if not pois:
                break

            all_results.extend(pois)
            start += len(pois)

            total = data.get('count', 0)
            if start >= total or len(pois) < self.page_size:
                break

            self._sleep()

        return all_results

    def _dedupe_pois(self, pois):
        seen = set()
        unique = []
        for poi in pois:
            poi_id = poi.get('hotPointID')
            if poi_id and poi_id in seen:
                continue
            if poi_id:
                seen.add(poi_id)
            unique.append(poi)
        return unique

    def _resolve_keyword(self, keywords):
        return keywords if keywords else self.default_keyword

    def _build_post_data(self, query_type, keywords=None, **extra):
        post_data = {
            "queryType": str(query_type),
            "keyWord": self._resolve_keyword(keywords),
        }
        if self.data_types:
            post_data["dataTypes"] = self.data_types
        if self.show:
            post_data["show"] = self.show
        post_data.update(extra)
        return post_data

    def _fetch_by_map_bound(self, lng_min, lat_min, lng_max, lat_max, keywords=None):
        map_bound = bounds_to_map_bound(lng_min, lat_min, lng_max, lat_max)
        post_data = self._build_post_data(
            self.QUERY_MAPBOUND,
            keywords=keywords,
            mapBound=map_bound,
            level=str(self.level),
        )
        return self._fetch_pois_paged(post_data)

    def _fetch_by_polygon(self, polygon, keywords=None):
        post_data = self._build_post_data(
            self.QUERY_POLYGON,
            keywords=keywords,
            polygon=polygon,
        )
        return self._fetch_pois_paged(post_data)

    def _fetch_by_around(self, lat, lng, radius_m, keywords=None):
        post_data = self._build_post_data(
            self.QUERY_AROUND,
            keywords=keywords,
            pointLonlat="{},{}".format(lng, lat),
            queryRadius=str(radius_m),
            level=str(self.level),
        )
        return self._fetch_pois_paged(post_data)

    def _build_result(self, pois, output_file, metadata=None):
        result = {
            "status": "success",
            "count": len(pois),
            "data": pois,
        }
        if metadata:
            result["metadata"] = metadata

        saved_count = self._save_pois_to_db(pois, "tianditu", metadata=metadata)
        result["db_table"] = self.db_table
        result["db_count"] = saved_count
        print("\n成功！共获取 {} 个天地图POI，已入库 {} 条".format(len(pois), saved_count))
        print("入库表: {}".format(self.db_table))
        return result

    def crawl(self, lat=None, lng=None, radius=None, keywords=None, output_file=None):
        """单点周边搜索"""
        from config import DEFAULT_LAT, DEFAULT_LNG

        lat = lat if lat is not None else DEFAULT_LAT
        lng = lng if lng is not None else DEFAULT_LNG
        radius_m = int(radius * 1000) if radius else 5000
        self._check_api_key()

        if output_file is None:
            output_file = "poi_{}_{}_{}.json".format(lat, lng, radius_m)

        pois = self._fetch_by_around(lat, lng, radius_m, keywords=keywords)
        return self._build_result(pois, output_file, {
            "mode": "around",
            "location": {"lat": lat, "lng": lng},
            "radius": radius_m,
            "keywords": keywords,
        })

    def crawl_bounds(self, lat_min, lat_max, lng_min, lng_max, keywords=None, output_file=None):
        """按矩形范围搜索POI（优先使用多边形搜索）"""
        self._check_api_key()

        if output_file is None:
            output_file = "poi_bounds_{}_{}_{}_{}.json".format(
                lat_min, lat_max, lng_min, lng_max
            )

        print("矩形范围: 纬度 {:.4f}~{:.4f}, 经度 {:.4f}~{:.4f}".format(
            lat_min, lat_max, lng_min, lng_max
        ))

        polygon = bounds_to_tianditu_polygon(lng_min, lat_min, lng_max, lat_max)
        pois = self._fetch_by_polygon(polygon, keywords=keywords)

        if not pois:
            print("多边形搜索无结果，尝试视野内搜索...")
            pois = self._fetch_by_map_bound(
                lng_min, lat_min, lng_max, lat_max, keywords=keywords
            )

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
        """按区域分块搜索POI"""
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
        print("开始按区域分块爬取天地图POI")
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
                polygon = bounds_to_tianditu_polygon(ltlng, rblat, rblng, ltlat)
                pois = self._fetch_by_polygon(polygon, keywords=keywords)
                if not pois:
                    pois = self._fetch_by_map_bound(
                        ltlng, rblat, rblng, ltlat, keywords=keywords
                    )
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
