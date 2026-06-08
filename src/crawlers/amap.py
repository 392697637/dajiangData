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

from psycopg2.extras import execute_values
from .base import BaseCrawler
from src.utils.geo import (
    generate_grid_points,
    bounds_to_amap_polygon,
    latlng_to_rectangle,
)

warnings.filterwarnings("ignore", message="Unverified HTTPS request")


class AmapPOICrawler(BaseCrawler):
    """
    高德地图POI爬虫类

    支持三种搜索模式：
    1. 周边搜索 (v3/place/around) - 给定中心点和半径搜索
    2. 多边形/矩形范围搜索 (v5/place/polygon) - 指定边界范围搜索
    3. 区域分块搜索 - 按省份/城市网格化爬取

    主要特性：
    - 支持从数据库动态获取区域边界（优先）
    - 支持按POI类型编码分表存储
    - 支持限流自动重试（指数退避策略）
    - 支持数据去重和类型统计
    """

    def __init__(self, config):
        """
        初始化高德POI爬虫

        Args:
            config (dict): 配置字典，包含以下关键字段：
                - api_key: 高德API密钥（必填）
                - around_api_url: 周边搜索API地址（v3）
                - polygon_api_url: 多边形搜索API地址（v5）
                - poi_types: POI类型编码列表（如 ['110000', '210000']）
                - radius: 默认搜索半径（米），默认5000
                - page_size: 周边搜索每页条数，默认20
                - polygon_page_size: 多边形搜索每页条数，默认25
                - extensions: 返回信息类型（'base'|'all'），默认'all'
                - request_delay: 请求间隔（秒），默认0.2
                - region_config: 区域配置字典（备用）
                - db_config: 数据库连接配置
        """
        super().__init__(config)

        self.around_api_url = config.get("around_api_url") or config.get("api_url")
        self.polygon_api_url = config.get(
            "polygon_api_url", "https://restapi.amap.com/v5/place/polygon"
        )
        self.api_key = config.get("api_key", "")
        self.poi_types = config.get("poi_types", [])
        self.radius = config.get("radius", 5000)
        self.page_size = config.get("page_size", 20)
        self.polygon_page_size = config.get("polygon_page_size", 25)
        self.extensions = config.get("extensions", "all")
        self.request_delay = config.get("request_delay", 0.2)
        self.region_config = config.get("region_config", {})

    def _get_region_code(self, region_name_cn):
        """
        根据区域中文名从数据库查询对应的区域代码

        Args:
            region_name_cn: 区域中文名称（如 "河南省"、"郑州市"）

        Returns:
            dict: {'type': 'sheng'|'shi', 'code': shengcode|shicode, 'name': region_name}
        """
        try:
            import psycopg2
        except ImportError:
            print("⚠️ 缺少psycopg2依赖，无法从数据库查询区域代码")
            return None

        conn = None
        try:
            conn = psycopg2.connect(**self.db_config)
            cur = conn.cursor()

            # 先查询市级表
            cur.execute(
                "SELECT shicode, shiname FROM jc_shi WHERE shiname = %s LIMIT 1",
                (region_name_cn,),
            )
            row = cur.fetchone()
            if row:
                return {"type": "shi", "code": row[0], "name": row[1]}

            # 查询省级表
            cur.execute(
                "SELECT shengcode, shengname FROM jc_sheng WHERE shengname = %s LIMIT 1",
                (region_name_cn,),
            )
            row = cur.fetchone()
            if row:
                return {"type": "sheng", "code": row[0], "name": row[1]}

            print(f"⚠️ 数据库中未找到区域: {region_name_cn}")
            return None

        except Exception as e:
            print(f"⚠️ 查询区域代码失败: {e}")
            return None
        finally:
            if conn:
                conn.close()

    def _get_region_bounds_from_db(self, region_name):
        """
        从数据库获取区域边界和城市名称

        仅支持中文名称查询，自动区分省和市：
        - 先查询省级表 jc_sheng（匹配 shengname）
        - 如果未找到，查询市级表 jc_shi（匹配 shiname）

        Args:
            region_name: 区域中文名称（如"河南省"、"郑州市"）

        Returns:
            dict: 包含区域信息的字典，格式如下：
                {
                    'name': '河南省',           # 区域中文名称
                    'name_en': 'henan',         # 区域英文名称
                    'lat_min': 31.4,            # 最小纬度（从geom计算）
                    'lat_max': 36.4,            # 最大纬度（从geom计算）
                    'lng_min': 110.4,           # 最小经度（从geom计算）
                    'lng_max': 116.7,           # 最大经度（从geom计算）
                    'grid_size_km': 200,        # 默认网格大小（公里）
                    'level': 'province'|'city'  # 区域级别
                }
                如果数据库查询失败，返回 None
        """
        try:
            import psycopg2
        except ImportError:
            print("⚠️ 缺少psycopg2依赖，无法从数据库查询区域边界")
            return None

        conn = None
        try:
            conn = psycopg2.connect(**self.db_config)
            cur = conn.cursor()

            # 第一步：查询省级表 jc_sheng
            print(f"🔍 尝试从 jc_sheng 表查询区域: {region_name}")
            cur.execute(
                """
                SELECT shengname, shengcode,
                       ST_YMin(geom) as min_lat, ST_YMax(geom) as max_lat,
                       ST_XMin(geom) as min_lng, ST_XMax(geom) as max_lng
                FROM jc_sheng 
                WHERE shengname = %s OR shengname LIKE %s OR shengname LIKE %s
                ORDER BY 
                    CASE WHEN shengname = %s THEN 1 
                         WHEN shengname LIKE %s THEN 2 
                         ELSE 3 END
                LIMIT 1
            """,
                (
                    region_name,
                    f"%{region_name}%",
                    f"{region_name}省",
                    region_name,
                    f"%{region_name}%",
                ),
            )
            row = cur.fetchone()
            if row:
                print(f"✅ 从 jc_sheng 表找到区域: {row[0]}")
                return {
                    "name": row[0],
                    "name_en": row[1].lower() if row[1] else region_name,
                    "lat_min": float(row[2]) if row[2] else None,
                    "lat_max": float(row[3]) if row[3] else None,
                    "lng_min": float(row[4]) if row[4] else None,
                    "lng_max": float(row[5]) if row[5] else None,
                    "grid_size_km": 200,
                    "level": "province",
                }

            # 第二步：查询市级表 jc_shi
            print(f"🔍 尝试从 jc_shi 表查询区域: {region_name}")
            cur.execute(
                """
                SELECT shiname, shicode, shengname,
                       ST_YMin(geom) as min_lat, ST_YMax(geom) as max_lat,
                       ST_XMin(geom) as min_lng, ST_XMax(geom) as max_lng
                FROM jc_shi 
                WHERE shiname = %s OR shiname LIKE %s OR shiname LIKE %s
                ORDER BY 
                    CASE WHEN shiname = %s THEN 1 
                         WHEN shiname LIKE %s THEN 2 
                         ELSE 3 END
                LIMIT 1
            """,
                (
                    region_name,
                    f"%{region_name}%",
                    f"{region_name}市",
                    region_name,
                    f"%{region_name}%",
                ),
            )
            row = cur.fetchone()
            if row:
                print(f"✅ 从 jc_shi 表找到区域: {row[0]}（属于{row[2]}）")
                return {
                    "name": row[0],
                    "name_en": row[1].lower() if row[1] else region_name,
                    "lat_min": float(row[3]) if row[3] else None,
                    "lat_max": float(row[4]) if row[4] else None,
                    "lng_min": float(row[5]) if row[5] else None,
                    "lng_max": float(row[6]) if row[6] else None,
                    "grid_size_km": 100,
                    "level": "city",
                    "province_name": row[2],
                }

            print(f"⚠️ 数据库中未找到区域边界信息: {region_name}")
            return None

        except Exception as e:
            print(f"⚠️ 查询区域边界失败: {e}")
            return None
        finally:
            if conn:
                conn.close()

    def _check_api_key(self):
        """
        检查API密钥是否已配置

        Raises:
            Exception: 如果API密钥未配置或为默认值
        """
        if not self.api_key or self.api_key == "your_amap_api_key":
            raise Exception("请先在config/settings.py中配置高德API Key")

    def _sleep(self):
        """
        根据配置的请求间隔进行休眠

        用于控制API请求频率，避免触发限流
        """
        if self.request_delay > 0:
            time.sleep(self.request_delay)

    def _dedupe_pois(self, pois):
        """
        对POI列表进行去重

        根据POI的id字段进行去重，保留首次出现的POI。

        Args:
            pois (list): POI字典列表

        Returns:
            list: 去重后的POI列表
        """
        seen = set()
        unique = []
        for poi in pois:
            poi_id = poi.get("id")
            if poi_id and poi_id in seen:
                continue
            if poi_id:
                seen.add(poi_id)
            unique.append(poi)
        return unique

    def _fetch_pois_around(self, lat, lng, keywords=None, radius=None):
        """
        周边搜索（使用高德地图v3 API）

        以指定坐标为中心，在给定半径范围内搜索POI数据。
        支持按POI类型分类搜索，并自动处理分页和限流重试。

        Args:
            lat (float): 中心点纬度
            lng (float): 中心点经度
            keywords (str, optional): 搜索关键词，用于过滤POI名称
            radius (int, optional): 搜索半径（米），默认使用配置值

        Returns:
            list: 搜索到的POI字典列表

        Notes:
            - 支持限流自动重试（指数退避，最多5次）
            - 自动处理分页，获取所有数据
            - 根据配置的poi_types进行分类搜索
        """
        radius = radius if radius is not None else self.radius
        all_results = []
        max_retries = 5

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

                success = False
                retry_count = 0
                while not success and retry_count < max_retries:
                    resp = self._make_request(self.around_api_url, params=params)
                    data = resp.json()

                    if data.get("status") != "1":
                        error_info = data.get("info", "Unknown error")
                        print(f"API返回错误: {error_info}")

                        if error_info == "CUQPS_HAS_EXCEEDED_THE_LIMIT":
                            retry_delay = 2**retry_count * 10
                            print(
                                f"⚠️ 触发限流，等待 {retry_delay} 秒后重试 (第 {retry_count + 1}/{max_retries} 次)"
                            )
                            time.sleep(retry_delay)
                            retry_count += 1
                            continue
                        else:
                            break
                    else:
                        success = True

                if not success:
                    break

                pois = data.get("pois", [])
                if not pois:
                    break

                all_results.extend(pois)
                page += 1

                total = int(data.get("count", 0))
                if (page - 1) * self.page_size >= total:
                    break

                self._sleep()

        return all_results

    def _fetch_pois_polygon(self, polygon, keywords=None):
        """
        多边形/矩形范围搜索（使用高德地图v5 API）

        在指定的多边形或矩形区域内搜索POI数据。
        支持按POI类型分类搜索，并自动处理分页和限流重试。
        搜索完成后会输出各类型POI数量统计。

        Args:
            polygon (str): 多边形边界字符串，格式为"lng1,lat1|lng2,lat2|..."
            keywords (str, optional): 搜索关键词，用于过滤POI名称

        Returns:
            list: 搜索到的POI字典列表

        Notes:
            - 支持限流自动重试（指数退避，最多5次）
            - 自动处理分页，获取所有数据
            - 输出各POI类型数量统计
            - 使用v5 API支持更大范围的批量搜索
        """
        all_results = []
        types_param = "|".join(self.poi_types) if self.poi_types else None
        type_count = {}
        max_retries = 5

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

            success = False
            retry_count = 0
            while not success and retry_count < max_retries:
                resp = self._make_request(self.polygon_api_url, params=params)
                data = resp.json()

                if data.get("status") != "1":
                    error_info = data.get("info", "Unknown error")
                    print(f"API返回错误: {error_info}")

                    if error_info == "CUQPS_HAS_EXCEEDED_THE_LIMIT":
                        retry_delay = 2**retry_count * 10
                        print(
                            f"⚠️ 触发限流，等待 {retry_delay} 秒后重试 (第 {retry_count + 1}/{max_retries} 次)"
                        )
                        time.sleep(retry_delay)
                        retry_count += 1
                        continue
                    else:
                        break
                else:
                    success = True

            if not success:
                break

            pois = data.get("pois", [])
            if not pois:
                break

            for poi in pois:
                poi_type = poi.get("typecode", "unknown")
                type_count[poi_type] = type_count.get(poi_type, 0) + 1
                all_results.append(poi)

            page_num += 1

            total = int(data.get("count", 0))
            if (page_num - 1) * self.polygon_page_size >= total:
                break

            self._sleep()

        if type_count:
            print("\n📊 当前网格POI类型统计:")
            for type_code, count in sorted(
                type_count.items(), key=lambda x: x[1], reverse=True
            ):
                type_name = self._get_type_name(type_code)
                print(f"  - {type_code} ({type_name}): {count} 条")
            print(f"  总计: {sum(type_count.values())} 条")

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
        print(
            "\n成功！共获取 {} 个高德POI，已入库 {} 条".format(len(pois), saved_count)
        )
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
        return self._build_result(
            pois,
            output_file,
            {
                "mode": "around",
                "location": {"lat": lat, "lng": lng},
                "radius": radius or self.radius,
                "keywords": keywords,
            },
        )

    def crawl_bounds(
        self, lat_min, lat_max, lng_min, lng_max, keywords=None, output_file=None
    ):
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
        print(
            "矩形范围: 纬度 {:.4f}~{:.4f}, 经度 {:.4f}~{:.4f}".format(
                lat_min, lat_max, lng_min, lng_max
            )
        )

        pois = self._fetch_pois_polygon(polygon, keywords=keywords)
        pois = self._dedupe_pois(pois)

        return self._build_result(
            pois,
            output_file,
            {
                "mode": "bounds",
                "bounds": {
                    "lat_min": lat_min,
                    "lat_max": lat_max,
                    "lng_min": lng_min,
                    "lng_max": lng_max,
                },
                "keywords": keywords,
            },
        )

    def crawl_region(
        self, region_name="河南省", grid_size_m=None, keywords=None, output_file=None
    ):
        """
        按区域分块搜索POI（核心方法）

        将指定区域划分为网格，对每个网格进行矩形范围搜索，最后合并去重并按类型分表存储。

        工作流程：
        1. 优先从数据库获取区域边界（支持省/市两级）
        2. 根据网格大小将区域划分为多个网格点
        3. 对每个网格点进行矩形范围搜索
        4. 合并所有结果并去重
        5. 按POI类型编码分表存储到数据库

        Args:
            region_name (str): 区域中文名称（如"河南省"、"郑州市"），默认"河南省"
            grid_size_m (int, optional): 网格大小（米），默认根据区域级别自动设置
                - 省级默认: 200000米（200公里）
                - 市级默认: 100000米（100公里）
            keywords (str, optional): 搜索关键词，用于过滤POI名称
            output_file (str, optional): 输出文件名，默认为自动生成

        Returns:
            dict: 包含爬取结果的字典，结构如下：
                {
                    'status': 'success',
                    'count': 总POI数量,
                    'db_table': 入库表名,
                    'db_count': 入库数量,
                    'tables': 各类型分表信息列表
                }

        Notes:
            - 区域边界优先从数据库 jc_sheng/jc_shi 表获取
            - 数据库查询失败时回退到配置文件中的 REGION_CONFIG
            - 支持按POI类型编码分表存储
            - 自动过滤不属于指定区域的POI数据
            - 输出详细的类型统计信息
        """
        self._check_api_key()

        region_info = None

        # 优先从数据库获取区域边界信息
        db_region_info = self._get_region_bounds_from_db(region_name)
        region_level = None
        if db_region_info:
            print(f"✅ 从数据库获取区域边界信息: {db_region_info['name']}")
            region_info = db_region_info
            region_name_cn = db_region_info["name"]
            region_name = db_region_info["name_en"]
            region_level = db_region_info.get("level")
        else:
            # 数据库查询失败，回退到配置文件
            print(f"⚠️ 数据库查询失败，使用配置文件中的区域配置")
            region_info = self.region_config.get(region_name)
            if not region_info:
                raise Exception("区域配置不存在: {}".format(region_name))
            region_name_cn = region_info.get("name", region_name)

        lat_min = region_info.get("lat_min")
        lat_max = region_info.get("lat_max")
        lng_min = region_info.get("lng_min")
        lng_max = region_info.get("lng_max")

        # 使用传入的网格大小（米），或数据库/配置中的默认值（转换为米）
        if grid_size_m is None:
            grid_size_m = region_info.get("grid_size_km", 200) * 1000

        print("=" * 70)
        print("开始按区域分块爬取高德POI")
        print("区域: {}".format(region_name_cn))
        print(
            "边界: 纬度 {:.2f}~{:.2f}, 经度 {:.2f}~{:.2f}".format(
                lat_min, lat_max, lng_min, lng_max
            )
        )
        print("网格大小: {} 米".format(grid_size_m))
        print("=" * 70)

        grid_points = generate_grid_points(
            lat_min, lat_max, lng_min, lng_max, grid_size_m
        )
        all_pois = []
        success_count = 0
        fail_count = 0

        for lat, lng, index in grid_points:
            print(
                "\n[{}/{}] 爬取网格: ({:.4f}, {:.4f})".format(
                    index, len(grid_points), lat, lng
                )
            )
            try:
                ltlat, ltlng, rblat, rblng = latlng_to_rectangle(
                    lat, lng, grid_size_m / 2
                )
                polygon = bounds_to_amap_polygon(ltlng, rblat, rblng, ltlat)
                pois = self._fetch_pois_polygon(polygon, keywords=keywords)
                all_pois.extend(pois)
                success_count += 1
                print("  成功获取 {} 个POI".format(len(pois)))
            except Exception as e:
                fail_count += 1
                print("  爬取失败: {}".format(str(e)))

        unique_pois = self._dedupe_pois(all_pois)

        print("\n" + "=" * 70)
        print("📊 爬取结果统计")
        print("=" * 70)
        print(f"总网格数: {len(grid_points)}")
        print(f"成功: {success_count}, 失败: {fail_count}")
        print(f"去重前: {len(all_pois)} 条")
        print(f"去重后: {len(unique_pois)} 条")

        type_stats = {}
        for poi in unique_pois:
            poi_type = poi.get("typecode", "unknown")
            type_stats[poi_type] = type_stats.get(poi_type, 0) + 1

        if type_stats:
            print("\n按类型统计:")
            for type_code, count in sorted(
                type_stats.items(), key=lambda x: x[1], reverse=True
            ):
                type_name = self._get_type_name(type_code)
                percentage = (count / len(unique_pois)) * 100
                print(f"  - {type_code} ({type_name}): {count} 条 ({percentage:.1f}%)")

        if output_file is None:
            output_file = "poi_{}_{}m.json".format(region_name, grid_size_m)

        # 根据POI类型编码分表存储，传递区域级别用于数据过滤
        return self._build_result_by_type(
            unique_pois,
            region_name,
            region_name_cn,
            grid_size_m,
            grid_points,
            success_count,
            fail_count,
            len(all_pois),
            keywords,
            output_file,
            region_level,
        )

    def _build_result_by_type(
        self,
        pois,
        region_name,
        region_name_cn,
        grid_size_m,
        grid_points,
        success_count,
        fail_count,
        total_before_dedup,
        keywords,
        output_file,
        region_level=None,
    ):
        """
        按POI类型编码分表存储POI数据（核心存储方法）

        该方法负责将爬取到的POI数据按类型编码进行分组，并分别存储到不同的数据库表中。
        同时支持按区域级别过滤数据，确保入库数据与查询区域严格匹配。

        表名格式规则：
        - 当keywords为"all"或None时: gis_poi_gd_{region_code}
        - 当有具体keywords时: gis_poi_gd_{region_code}_keywords

        Args:
            pois (list): POI字典列表
            region_name (str): 区域英文名称/代码
            region_name_cn (str): 区域中文名称（如"河南省"、"郑州市"）
            grid_size_m (int): 网格大小（米）
            grid_points (list): 网格点坐标列表
            success_count (int): 成功爬取的网格数
            fail_count (int): 失败的网格数
            total_before_dedup (int): 去重前的POI总数
            keywords (str): 搜索关键词（None表示"all"）
            output_file (str): 输出文件名
            region_level (str): 区域级别（'province' 或 'city'），用于数据过滤

        Returns:
            dict: 包含存储结果的字典

        Notes:
            - 根据region_level过滤POI数据，确保city/province字段与输入区域匹配
            - 市级区域只保留city匹配的POI
            - 省级区域只保留province匹配的POI
            - 输出各类型POI的统计信息
        """
        # 根据区域级别过滤POI数据
        filtered_pois = []
        for poi in pois:
            poi_province = poi.get("pname", "").strip()
            poi_city = poi.get("cityname", "").strip()

            # 如果是市级区域（如郑州市），只保留city匹配的POI
            if region_level == "city":
                if poi_city == region_name_cn or poi_city.startswith(
                    region_name_cn[:-1]
                ):
                    filtered_pois.append(poi)
            # 如果是省级区域（如河南省），只保留province匹配的POI
            elif region_level == "province":
                if poi_province == region_name_cn or poi_province.startswith(
                    region_name_cn[:-1]
                ):
                    filtered_pois.append(poi)
            # 默认不过滤
            else:
                filtered_pois.append(poi)

        filter_count = len(pois) - len(filtered_pois)
        if filter_count > 0:
            print(f"🔍 过滤掉 {filter_count} 条不属于 {region_name_cn} 的POI数据")

        # 按type_code分组
        pois_by_type = {}
        for poi in filtered_pois:
            type_code = poi.get("typecode", "unknown")
            if type_code not in pois_by_type:
                pois_by_type[type_code] = []
            pois_by_type[type_code].append(poi)

        total_saved = 0
        results = []

        # 查询区域代码
        region_code_info = self._get_region_code(region_name_cn)
        if region_code_info:
            region_code = region_code_info["code"]
            print(
                f"✅ 从数据库查询到区域代码: {region_code_info['name']} ({region_code_info['type']}): {region_code}"
            )
        else:
            region_code = region_name
            print(f"⚠️ 使用区域名称作为代码: {region_code}")

        # keywords为None表示用户传入了all/全部，获取所有POI类型，存入统一表
        if keywords is None:
            table_name = f"gis_poi_gd_{region_code}"
            table_comment = f"高德POI表（{region_name_cn}，所有类型）"
            self.db_table = table_name
            saved = self._save_pois_to_db_with_comment(
                filtered_pois,
                "amap",
                table_comment,
                {
                    "mode": "region",
                    "region": region_name_cn,
                    "grid_size_km": grid_size_m,
                    "keywords": "all",
                },
            )
            total_saved += saved
            results.append({"table": table_name, "count": saved})
        # 有具体搜索关键词时，存入带keywords后缀的表
        elif keywords:
            table_name = f"gis_poi_gd_{region_code}_keywords"
            table_comment = f"高德POI表（{region_name_cn}，关键词: {keywords}）"
            self.db_table = table_name
            saved = self._save_pois_to_db(
                filtered_pois,
                "amap",
                {
                    "mode": "region",
                    "region": region_name_cn,
                    "grid_size_km": grid_size_m,
                    "keywords": keywords,
                },
            )
            total_saved += saved
            results.append({"table": table_name, "count": saved})

        print(f"\n成功！共获取 {len(pois)} 个高德POI，已入库 {total_saved} 条")
        print("入库详情:")
        for r in results:
            print(f"  - {r['table']}: {r['count']} 条")

        return {
            "status": "success",
            "count": len(pois),
            "db_count": total_saved,
            "metadata": {
                "mode": "region",
                "region": region_name_cn,
                "grid_size_km": grid_size_m,
                "total_grids": len(grid_points),
                "success_grids": success_count,
                "fail_grids": fail_count,
                "total_before_dedup": total_before_dedup,
                "keywords": keywords,
            },
            "tables": results,
        }

    def _get_type_name(self, type_code):
        """根据类型编码获取类型名称"""
        for poi_type in self.poi_types:
            if isinstance(poi_type, dict):
                if poi_type.get("code") == type_code[:6]:
                    return poi_type.get("name", type_code)
                for sub in poi_type.get("subtypes", []):
                    if sub.get("code") == type_code:
                        return sub.get("name", type_code)
        return type_code

    def _save_pois_to_db_with_comment(
        self, pois, platform, table_comment, metadata=None
    ):
        """
        将POI列表写入数据库，包含表注释

        Args:
            pois: POI列表
            platform: 平台标识（amap/tianditu）
            table_comment: 表注释
            metadata: 元数据
        """
        if not self.save_to_db:
            return 0
        if not self.db_table:
            raise Exception("未配置POI入库表名 db_table")
        if not pois:
            return 0

        conn = self._get_db_connection()
        try:
            self._ensure_poi_table_with_comment(conn, self.db_table, table_comment)
            rows = [self._normalize_poi_row(poi, platform, metadata) for poi in pois]
            sql = f'''
                INSERT INTO "{self.db_table}" (
                    source_platform, poi_id, name, type_code, type_name, address,
                    province, city, district, lng, lat, raw_data, metadata, geom, updated_at
                ) VALUES %s
                ON CONFLICT (source_platform, poi_id) DO UPDATE SET
                    name = EXCLUDED.name,
                    type_code = EXCLUDED.type_code,
                    type_name = EXCLUDED.type_name,
                    address = EXCLUDED.address,
                    province = EXCLUDED.province,
                    city = EXCLUDED.city,
                    district = EXCLUDED.district,
                    lng = EXCLUDED.lng,
                    lat = EXCLUDED.lat,
                    raw_data = EXCLUDED.raw_data,
                    metadata = EXCLUDED.metadata,
                    geom = EXCLUDED.geom,
                    updated_at = now()
            '''
            template = """
                (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                 CASE WHEN %s IS NOT NULL AND %s IS NOT NULL THEN ST_SetSRID(ST_MakePoint(%s, %s), 4326) ELSE NULL END,
                 now())
            """
            expanded_rows = []
            for row in rows:
                lng = row[9]
                lat = row[10]
                expanded_rows.append(row + (lng, lat, lng, lat))

            with conn.cursor() as cur:
                execute_values(
                    cur, sql, expanded_rows, template=template, page_size=500
                )
            conn.commit()
            return len(rows)
        finally:
            conn.close()

    def _ensure_poi_table_with_comment(self, conn, table_name, table_comment):
        """
        创建POI入库表（如果存在则删除重建），并添加表注释和字段注释

        Args:
            conn: 数据库连接
            table_name: 表名
            table_comment: 表注释
        """
        # 先删除已存在的表
        drop_sql = f'DROP TABLE IF EXISTS "{table_name}" CASCADE;'
        create_sql = f'''
        CREATE TABLE "{table_name}" (
            id BIGSERIAL PRIMARY KEY,
            source_platform VARCHAR(32) NOT NULL,
            poi_id VARCHAR(128),
            name TEXT,
            type_code TEXT,
            type_name TEXT,
            address TEXT,
            province TEXT,
            city TEXT,
            district TEXT,
            lng DOUBLE PRECISION,
            lat DOUBLE PRECISION,
            geom geometry(Point, 4326),
            raw_data JSONB NOT NULL,
            metadata JSONB,
            created_at TIMESTAMPTZ DEFAULT now(),
            updated_at TIMESTAMPTZ DEFAULT now(),
            UNIQUE (source_platform, poi_id)
        );
        CREATE INDEX "idx_{table_name}_geom" ON "{table_name}" USING GIST (geom);
        CREATE INDEX "idx_{table_name}_type_code" ON "{table_name}" (type_code);
        CREATE INDEX "idx_{table_name}_name" ON "{table_name}" (name);
        '''
        with conn.cursor() as cur:
            cur.execute(drop_sql)
            cur.execute(create_sql)

        # 添加表注释和字段注释
        comment_sql = f'''
        COMMENT ON TABLE "{table_name}" IS '{table_comment}';
        COMMENT ON COLUMN "{table_name}".id IS '主键ID';
        COMMENT ON COLUMN "{table_name}".source_platform IS '数据源平台（amap/tianditu）';
        COMMENT ON COLUMN "{table_name}".poi_id IS 'POI唯一标识';
        COMMENT ON COLUMN "{table_name}".name IS 'POI名称';
        COMMENT ON COLUMN "{table_name}".type_code IS 'POI类型编码';
        COMMENT ON COLUMN "{table_name}".type_name IS 'POI类型名称';
        COMMENT ON COLUMN "{table_name}".address IS '详细地址';
        COMMENT ON COLUMN "{table_name}".province IS '省份';
        COMMENT ON COLUMN "{table_name}".city IS '城市';
        COMMENT ON COLUMN "{table_name}".district IS '区县';
        COMMENT ON COLUMN "{table_name}".lng IS '经度';
        COMMENT ON COLUMN "{table_name}".lat IS '纬度';
        COMMENT ON COLUMN "{table_name}".geom IS '空间点位（SRID=4326）';
        COMMENT ON COLUMN "{table_name}".raw_data IS '原始JSON数据';
        COMMENT ON COLUMN "{table_name}".metadata IS '采集元数据';
        COMMENT ON COLUMN "{table_name}".created_at IS '创建时间';
        COMMENT ON COLUMN "{table_name}".updated_at IS '更新时间';
        '''
        with conn.cursor() as cur:
            cur.execute(comment_sql)

        conn.commit()
        print(f"表 {table_name} 已创建（带注释）")
