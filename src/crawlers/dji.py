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

# 导入基类和工具函数
from .base import BaseCrawler
from src.utils.geo import latlng_to_rectangle, parse_dji_response, generate_grid_points

# 忽略SSL验证警告
warnings.filterwarnings("ignore", message="Unverified HTTPS request")


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
        self.api_url = config["api_url"]
        self.drones_api_url = config["drones_api_url"]

        # 保存请求参数配置
        self.params = config.get("params", {})

        # 设置默认无人机型号
        self.drone_model = self.params.get("default_drone", "dji-mavic-3")

        # 设置区域模式（固定值）
        self.zones_mode = self.params.get("zones_mode", "flysafe_website")

        # 设置禁飞区级别筛选
        self.levels = self.params.get("levels", "0,1,2,3,7,8,10")

        # 初始化无人机型号列表缓存
        self.drones_list = None

        # 保存区域分块配置
        self.region_config = config.get("region_config", {})

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
            resp.encoding = "utf-8"  # 设置正确编码
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

    def crawl(self, lat=None, lng=None, radius=None, output_file=None):
        """
        爬取单个区域的DJI禁飞区数据

        核心方法，负责发送API请求、解析响应并返回结果。

        Args:
            lat (float): 中心纬度（可选，默认为配置中的默认值）
            lng (float): 中心经度（可选，默认为配置中的默认值）
            radius (float): 搜索半径（米，可选，默认为配置中的默认值）
            output_file (str): 输出文件路径（可选，默认为None不输出文件）

        Returns:
            dict: 包含features的字典

        Raises:
            Exception: 请求失败、解析失败或数据异常时抛出异常
        """
        from config import DEFAULT_LAT, DEFAULT_LNG, DEFAULT_RADIUS

        # 使用传入参数或默认值
        lat = lat if lat is not None else DEFAULT_LAT
        lng = lng if lng is not None else DEFAULT_LNG
        radius = radius if radius is not None else DEFAULT_RADIUS

        # 将中心点和半径转换为矩形区域
        ltlat, ltlng, rblat, rblng = latlng_to_rectangle(lat, lng, radius)

        # 构建API请求参数
        params = {
            "ltlat": ltlat,  # 左上角纬度
            "ltlng": ltlng,  # 左上角经度
            "rblat": rblat,  # 右下角纬度
            "rblng": rblng,  # 右下角经度
            "zones_mode": self.zones_mode,  # 区域模式
            "drone": self.drone_model,  # 无人机型号
            "level": self.levels,  # 禁飞区级别
        }

        # 发送API请求
        resp = self._make_request(self.api_url, params=params)

        # 解析JSON响应
        data = resp.json()

        # 使用新的解析函数处理API响应
        features = parse_dji_response(data)

        # 检查是否获取到数据
        if not features:
            raise Exception("未获取到禁飞区数据")

        # 构建结果对象（不输出GeoJSON文件）
        result = {
            "type": "FeatureCollection",
            "features": features,
            "crs": {
                "type": "name",
                "properties": {"name": "urn:ogc:def:crs:EPSG::4326"},
            },
        }

        # 打印成功信息
        print("  ✓ 成功获取 {} 个禁飞区".format(len(features)))

        return result

    def _create_flyzone_table(self, conn):
        """
        创建禁飞区数据表（如果不存在），先删除现有表再创建

        Args:
            conn: 数据库连接对象

        Returns:
            bool: 创建成功返回True，失败返回False
        """
        try:
            with conn.cursor() as cur:
                # 先删除现有表
                drop_sql = f'DROP TABLE IF EXISTS "{self.db_table}"'
                cur.execute(drop_sql)
                print(f"  删除旧表: {self.db_table}")

                # 创建新表（PostgreSQL不支持在CREATE TABLE中直接使用COMMENT）
                create_sql = f'''
                    CREATE TABLE "{self.db_table}" (
                        "gid" SERIAL PRIMARY KEY,
                        "area_id" BIGINT,
                        "name" VARCHAR(254),
                        "type" NUMERIC,
                        "level" NUMERIC,
                        "color" VARCHAR(254),
                        "country" VARCHAR(254),
                        "city" VARCHAR(254),
                        "address" VARCHAR(254),
                        "descriptio" VARCHAR(254),
                        "height" NUMERIC,
                        "radius" NUMERIC,
                        "begin_at" NUMERIC,
                        "end_at" NUMERIC,
                        "data_sourc" NUMERIC,
                        "url" VARCHAR(254),
                        "__gid" NUMERIC,
                        "shiid" VARCHAR(10),
                        "shicode" VARCHAR(10),
                        "shiname" VARCHAR(30),
                        "shengcode" VARCHAR(10),
                        "shengid" VARCHAR(10),
                        "shengname" VARCHAR(24),
                        "type_name" VARCHAR(254),
                        "level_name" VARCHAR(254),
                        "geom" GEOMETRY(MULTIPOLYGON, 4326)
                    )
                '''
                cur.execute(create_sql)
                print(f"  创建新表: {self.db_table}")

                # 创建空间索引（先删除已存在的索引）
                drop_index_sql = f'DROP INDEX IF EXISTS "{self.db_table}_geom_idx"'
                cur.execute(drop_index_sql)
                index_sql = f'CREATE INDEX "{self.db_table}_geom_idx" ON "{self.db_table}" USING GIST (geom)'
                cur.execute(index_sql)
                print(f"  创建空间索引: {self.db_table}_geom_idx")

                # 添加字段注释（PostgreSQL使用COMMENT ON COLUMN语法）
                comments = [
                    ("area_id", "禁飞区唯一标识"),
                    ("name", "禁飞区名称"),
                    ("type", "禁飞区类型"),
                    (
                        "level",
                        "禁飞级别(0-机场禁飞区,1-机场限飞区,2-国家级机场禁飞区,3-临时限飞区,7-干扰源区域,8-军事管理区,10-特殊管控区)",
                    ),
                    ("color", "显示颜色"),
                    ("country", "国家"),
                    ("city", "城市"),
                    ("address", "详细地址"),
                    ("descriptio", "描述信息"),
                    ("height", "高度限制(米)"),
                    ("radius", "半径(米)"),
                    ("begin_at", "开始时间(时间戳)"),
                    ("end_at", "结束时间(时间戳)"),
                    ("data_sourc", "数据源标识"),
                    ("url", "详情链接"),
                    ("__gid", "内部ID"),
                    ("shiid", "市级ID"),
                    ("shicode", "市级编码"),
                    ("shiname", "市级名称"),
                    ("shengcode", "省级编码"),
                    ("shengid", "省级ID"),
                    ("shengname", "省级名称"),
                    ("type_name", "禁飞区类型名称"),
                    ("level_name", "禁飞区级别名称"),
                    ("geom", "几何数据(坐标系EPSG:4326)"),
                ]

                for col_name, comment in comments:
                    comment_sql = (
                        f'COMMENT ON COLUMN "{self.db_table}"."{col_name}" IS %s'
                    )
                    cur.execute(comment_sql, (comment,))
                print(f"  添加字段注释完成")

            conn.commit()
            return True
        except Exception as e:
            print(f"❌ 创建表失败: {str(e)}")
            return False

    def _save_flyzones_to_db(self, features, region_info=None):
        """
        将禁飞区数据保存到数据库（先删除旧表再创建新表）

        Args:
            features (list): GeoJSON features列表，每个feature包含禁飞区信息
            region_info (dict, optional): 区域信息，包含shengname, shengcode, shiname, shicode等

        Returns:
            int: 成功入库的记录数，失败返回0
        """
        if not self.save_to_db:
            return 0
        if not self.db_table:
            print("⚠️ 未配置禁飞区入库表名 db_table")
            return 0
        if not features:
            return 0

        try:
            import psycopg2
            from psycopg2.extras import execute_values
        except ImportError:
            print("⚠️ 缺少psycopg2-binary依赖，请先安装: pip install psycopg2-binary")
            return 0

        try:
            conn = psycopg2.connect(**self.db_config)

            # 先删除旧表并创建新表
            print(f"\n📦 准备创建禁飞区数据表: {self.db_table}")
            if not self._create_flyzone_table(conn):
                conn.close()
                return 0

            # 获取区域信息
            shengname = region_info.get("shengname") if region_info else None
            shengcode = region_info.get("shengcode") if region_info else None
            shengid = region_info.get("shengid") if region_info else None
            shiname = region_info.get("shiname") if region_info else None
            shicode = region_info.get("shicode") if region_info else None
            shiid = region_info.get("shiid") if region_info else None

            # 准备插入数据
            rows = []
            for feature in features:
                props = feature.get("properties", {})
                geometry = feature.get("geometry", {})

                # 解析几何数据
                geom_type = geometry.get("type")
                coordinates = geometry.get("coordinates", [])

                # 将坐标转换为WKT格式（限制精度为6位小数）
                def format_coord(coord):
                    return "{:.6f} {:.6f}".format(coord[0], coord[1])

                if geom_type == "Polygon":
                    # 单个多边形需要在 MultiPolygon 中再包一层圆括号，形成 "MULTIPOLYGON(((...)))"
                    ring = ",".join([format_coord(c) for c in coordinates[0]])
                    wkt_geom = "MULTIPOLYGON((({})))".format(ring)
                elif geom_type == "MultiPolygon":
                    polygons = []
                    for polygon in coordinates:
                        rings = []
                        for ring in polygon:
                            rings.append(
                                "(" + ",".join([format_coord(c) for c in ring]) + ")"
                            )
                        polygons.append("(" + ",".join(rings) + ")")
                    wkt_geom = "MULTIPOLYGON({})".format(",".join(polygons))
                else:
                    wkt_geom = None

                rows.append(
                    (
                        props.get("area_id"),
                        props.get("name"),
                        props.get("type"),
                        props.get("level"),
                        props.get("typeName"),
                        props.get("levelName"),
                        props.get("color"),
                        props.get("country"),
                        props.get("city"),
                        props.get("address"),
                        props.get("description"),
                        props.get("height"),
                        props.get("radius"),
                        props.get("begin_at"),
                        props.get("end_at"),
                        props.get("data_source"),
                        props.get("url"),
                        props.get("__gid"),
                        shiid,
                        shicode,
                        shiname,
                        shengcode,
                        shengid,
                        shengname,
                        wkt_geom,
                    )
                )

            # 批量插入数据（使用ST_GeomFromText解析WKT几何数据）
            # 使用EXECUTE动态执行，避免execute_values将ST_GeomFromText当作字符串
            insert_sql = f'''
                INSERT INTO "{self.db_table}" (
                    area_id, name, type, level, type_name, level_name, color, country, city, address,
                    descriptio, height, radius, begin_at, end_at, data_sourc, url,
                    __gid, shiid, shicode, shiname, shengcode, shengid, shengname, geom
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s, %s, %s,
                    ST_GeomFromText(%s, 4326)
                )
            '''

            with conn.cursor() as cur:
                for row in rows:
                    cur.execute(insert_sql, row)
            conn.commit()

            count = len(rows)
            print(f"\n✅ 成功入库 {count} 条禁飞区数据")
            print(f"   入库表: {self.db_table}")

            conn.close()
            return count
        except Exception as e:
            print(f"\n❌ 禁飞区入库失败: {str(e)}")
            return 0

    def crawl_region(self, region_name="中国", grid_size_km=1000):
        """
        按区域分块爬取DJI禁飞区数据（核心方法）

        将指定区域按网格分块，依次爬取每个网格的禁飞区数据，最后合并去重。

        工作流程：
        1. 优先从数据库获取区域边界（支持省/市两级）
        2. 根据网格大小将区域划分为多个网格点
        3. 对每个网格点进行矩形范围搜索
        4. 合并所有结果并去重（根据area_id）

        Args:
            region_name (str): 区域中文名称（如"河南省"、"郑州市"、"中国"），默认"中国"
            grid_size_km (float): 网格大小（**千米**，默认1000）。注意：与POI爬虫不同，DJI使用千米为单位

        Returns:
            dict: 合并后的GeoJSON格式禁飞区数据，结构如下：
                {
                    "type": "FeatureCollection",
                    "features": [...],
                    "crs": {...},
                    "metadata": {
                        "region": "区域名称",
                        "grid_size_km": 网格大小,
                        "total_grids": 总网格数,
                        "success_grids": 成功数,
                        "fail_grids": 失败数,
                        "total_features_before_dedup": 去重前数量,
                        "total_features_after_dedup": 去重后数量
                    }
                }

        Notes:
            - 区域边界优先从数据库 jc_sheng/jc_shi 表获取
            - 数据库查询失败时回退到配置文件中的 REGION_CONFIG
            - 网格大小单位为**千米**，与POI爬虫的米单位不同

        Raises:
            Exception: 区域配置不存在或爬取失败时抛出异常
        """
        # 获取区域配置
        region_info = None

        # 中文到英文区域名称映射（用于回退到配置文件时）
        cn_to_en_map = {
            "中国": "china",
            "河南省": "henan",
            "北京市": "beijing",
            "上海市": "shanghai",
            "广东省": "guangdong",
        }

        # 优先从数据库获取区域边界信息
        db_region_info = self._get_region_bounds_from_db(region_name)
        if db_region_info:
            print(f"✅ 从数据库获取区域边界信息: {db_region_info['name']}")
            region_info = db_region_info
            region_name_cn = db_region_info["name"]
            region_name = db_region_info["name_en"]
        else:
            # 数据库查询失败，回退到配置文件
            print(f"⚠️ 数据库查询失败，使用配置文件中的区域配置")

            # 尝试直接获取，或通过中文映射获取
            region_info = self.region_config.get(region_name)
            if not region_info and region_name in cn_to_en_map:
                region_info = self.region_config.get(cn_to_en_map[region_name])
                region_name_cn = region_name
                region_name = cn_to_en_map[region_name]

            if not region_info:
                raise Exception("区域配置不存在: {}".format(region_name))
            region_name_cn = region_info.get("name", region_name)

        lat_min = region_info.get("lat_min", 18.0)
        lat_max = region_info.get("lat_max", 54.0)
        lng_min = region_info.get("lng_min", 73.0)
        lng_max = region_info.get("lng_max", 135.0)

        # 使用传入的网格大小，或数据库/配置中的默认值（DJI使用千米为单位）
        if grid_size_km is None:
            grid_size_km = region_info.get("grid_size_km", 1000)

        # 将千米转换为米（generate_grid_points函数使用米为单位）
        grid_size_m = grid_size_km * 1000

        print("=" * 70)
        print("开始按区域分块爬取禁飞区数据")
        print("区域: {}".format(region_name_cn))
        print(
            "边界: 纬度 {:.2f}~{:.2f}, 经度 {:.2f}~{:.2f}".format(
                lat_min, lat_max, lng_min, lng_max
            )
        )
        print("网格大小: {} km".format(grid_size_km))
        print("=" * 70)

        # 生成网格中心点（传入米为单位）
        grid_points = generate_grid_points(
            lat_min, lat_max, lng_min, lng_max, grid_size_m
        )

        # 存储所有爬取的features
        all_features = []
        success_count = 0
        fail_count = 0

        # 遍历所有网格点进行爬取
        for lat, lng, index in grid_points:
            print(
                "\n[{}/{}] 爬取网格点: ({:.4f}, {:.4f})".format(
                    index, len(grid_points), lat, lng
                )
            )

            try:
                # 爬取当前网格点的禁飞区数据（radius使用米为单位）
                result = self.crawl(lat=lat, lng=lng, radius=grid_size_m / 2)

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

        # 构建结果对象
        result = {
            "type": "FeatureCollection",
            "features": unique_features,
            "crs": {
                "type": "name",
                "properties": {"name": "urn:ogc:def:crs:EPSG::4326"},
            },
            "metadata": {
                "region": region_name_cn,
                "grid_size_km": grid_size_km,
                "total_grids": len(grid_points),
                "success_grids": success_count,
                "fail_grids": fail_count,
                "total_features_before_dedup": len(all_features),
                "total_features_after_dedup": len(unique_features),
            },
        }

        # 打印汇总信息
        print("\n" + "=" * 70)
        print("区域爬取完成！")
        print("区域: {}".format(region_name_cn))
        print("网格大小: {} km".format(grid_size_km))
        print("总网格数: {}".format(len(grid_points)))
        print("成功: {}, 失败: {}".format(success_count, fail_count))
        print("合并前禁飞区数量: {}".format(len(all_features)))
        print("去重后禁飞区数量: {}".format(len(unique_features)))
        print("=" * 70)

        # 将禁飞区数据直接入库（不输出GeoJSON文件）
        if unique_features:
            db_region_info = {
                "shengname": region_info.get("shengname"),
                "shengcode": region_info.get("shengcode"),
                "shengid": region_info.get("shengid"),
                "shiname": region_info.get("shiname"),
                "shicode": region_info.get("shicode"),
                "shiid": region_info.get("shiid"),
            }
            self._save_flyzones_to_db(unique_features, db_region_info)

        return result
