# -*- coding: utf-8 -*-
"""
爬虫基类

此模块定义了爬虫的基类BaseCrawler，提供所有爬虫通用的功能：
1. HTTP请求封装
2. JSON数据保存
3. 配置管理

所有具体爬虫类都应继承此类，并实现crawl方法。

使用方式:
    class MyCrawler(BaseCrawler):
        def crawl(self, **kwargs):
            # 实现具体爬取逻辑
            pass
"""

import os
import json
import requests
from datetime import datetime

try:
    import psycopg2
    from psycopg2.extras import Json, execute_values
except ImportError:  # pragma: no cover - handled at runtime when DB saving is enabled
    psycopg2 = None
    Json = None
    execute_values = None


class BaseCrawler:
    """
    爬虫基类，提供通用功能
    
    Attributes:
        config (dict): 爬虫配置字典
        timeout (int): 请求超时时间（秒）
        output_dir (str): 输出目录路径
    """
    
    def __init__(self, config):
        """
        初始化爬虫基类
        
        Args:
            config (dict): 爬虫配置字典，应包含以下关键字:
                - timeout: 请求超时时间（可选，默认30秒）
                - output_dir: 输出目录（可选，默认'output'）
        """
        # 保存配置
        self.config = config
        
        # 设置超时时间，默认为30秒
        self.timeout = config.get('timeout', 30)
        
        # 设置输出目录，默认为'output'
        self.output_dir = config.get('output_dir', 'output')

        # POI数据入库配置。默认关闭，避免影响DJI等非POI爬虫。
        self.save_to_db = config.get('save_to_db', False)
        self.db_table = config.get('db_table')
        self.db_config = config.get('db_config', {})
    
    def _make_request(self, url, method='GET', params=None, headers=None, data=None):
        """
        发送HTTP请求（私有方法）
        
        封装requests库，提供统一的请求接口和错误处理。
        
        Args:
            url (str): 请求URL
            method (str): 请求方法，支持'GET'和'POST'（默认'GET'）
            params (dict): URL参数（查询字符串）
            headers (dict): 请求头
            data (dict): 请求体数据（POST时使用）
        
        Returns:
            requests.Response: 响应对象
        
        Raises:
            ValueError: 不支持的请求方法
            Exception: 请求失败时抛出异常
        """
        try:
            # 根据请求方法选择对应的requests方法
            if method.upper() == 'GET':
                resp = requests.get(
                    url,
                    params=params,
                    headers=headers,
                    timeout=self.timeout,
                    verify=False  # 禁用SSL验证（部分环境可能需要）
                )
            elif method.upper() == 'POST':
                resp = requests.post(
                    url,
                    params=params,
                    headers=headers,
                    data=data,
                    timeout=self.timeout,
                    verify=False
                )
            else:
                raise ValueError(f"不支持的请求方法: {method}")
            
            # 检查HTTP状态码，非200则抛出异常
            resp.raise_for_status()
            
            return resp

        except requests.exceptions.HTTPError as e:
            detail = ""
            if e.response is not None:
                try:
                    detail = e.response.text[:300]
                except Exception:
                    pass
            if detail:
                raise Exception("请求失败: {} | 响应: {}".format(str(e), detail))
            raise Exception("请求失败: {}".format(str(e)))
        except requests.exceptions.RequestException as e:
            raise Exception("请求失败: {}".format(str(e)))
    
    def _save_json(self, data, filename):
        """
        保存JSON数据到文件（私有方法）
        
        Args:
            data (dict or list): 要保存的JSON数据
            filename (str): 输出文件名（不含路径）
        
        Returns:
            str: 输出文件的完整路径
        """
        # 确保输出目录存在
        os.makedirs(self.output_dir, exist_ok=True)
        
        # 构建完整文件路径
        filepath = os.path.join(self.output_dir, filename)
        
        # 写入JSON文件（使用UTF-8编码，格式化输出）
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        
        return filepath

    def _get_db_connection(self):
        """创建PostgreSQL连接。"""
        if psycopg2 is None:
            raise Exception("缺少psycopg2-binary依赖，请先执行 pip install -r requirements.txt")
        return psycopg2.connect(
            host=self.db_config.get("host"),
            port=self.db_config.get("port"),
            dbname=self.db_config.get("database"),
            user=self.db_config.get("user"),
            password=self.db_config.get("password"),
        )

    def _ensure_poi_table(self, conn, table_name):
        """创建POI入库表；高德/天地图分别使用各自表名。"""
        sql = f'''
        CREATE TABLE IF NOT EXISTS "{table_name}" (
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
        CREATE INDEX IF NOT EXISTS "idx_{table_name}_geom" ON "{table_name}" USING GIST (geom);
        CREATE INDEX IF NOT EXISTS "idx_{table_name}_type_code" ON "{table_name}" (type_code);
        CREATE INDEX IF NOT EXISTS "idx_{table_name}_name" ON "{table_name}" (name);
        '''
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()

    def _parse_lng_lat(self, poi, platform):
        """从不同平台POI结构中解析经纬度。"""
        if platform == "amap":
            location = poi.get("location")
            if isinstance(location, str) and "," in location:
                lng, lat = location.split(",", 1)
                return float(lng), float(lat)

        if platform == "tianditu":
            lon = poi.get("lon") or poi.get("lng") or poi.get("longitude")
            lat = poi.get("lat") or poi.get("latitude")
            if lon is not None and lat is not None:
                return float(lon), float(lat)

        return None, None

    def _normalize_poi_row(self, poi, platform, metadata):
        """转换为统一入库字段。"""
        lng, lat = self._parse_lng_lat(poi, platform)

        if platform == "amap":
            poi_id = poi.get("id")
            type_code = poi.get("typecode")
            type_name = poi.get("type")
            province = poi.get("pname")
            city = poi.get("cityname")
            district = poi.get("adname")
        else:
            poi_id = poi.get("hotPointID") or poi.get("id")
            type_code = poi.get("typeCode") or poi.get("typecode")
            type_name = poi.get("typeName") or poi.get("type")
            province = poi.get("province")
            city = poi.get("city")
            district = poi.get("county") or poi.get("district")

        return (
            platform,
            poi_id,
            poi.get("name"),
            type_code,
            type_name,
            poi.get("address") or poi.get("addr"),
            province,
            city,
            district,
            lng,
            lat,
            Json(poi),
            Json(metadata or {}),
        )

    def _save_pois_to_db(self, pois, platform, metadata=None):
        """将POI列表直接写入数据库，按平台落到对应POI类型表。"""
        if not self.save_to_db:
            return 0
        if not self.db_table:
            raise Exception("未配置POI入库表名 db_table")
        if not pois:
            return 0

        conn = self._get_db_connection()
        try:
            self._ensure_poi_table(conn, self.db_table)
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
            template = '''
                (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                 CASE WHEN %s IS NOT NULL AND %s IS NOT NULL THEN ST_SetSRID(ST_MakePoint(%s, %s), 4326) ELSE NULL END,
                 now())
            '''
            expanded_rows = []
            for row in rows:
                lng = row[9]
                lat = row[10]
                expanded_rows.append(row + (lng, lat, lng, lat))

            with conn.cursor() as cur:
                execute_values(cur, sql, expanded_rows, template=template, page_size=500)
            conn.commit()
            return len(rows)
        finally:
            conn.close()
    
    def crawl(self, **kwargs):
        """
        爬取数据（抽象方法，子类必须实现）
        
        子类应重写此方法实现具体的爬取逻辑。
        
        Args:
            **kwargs: 爬取参数（如坐标、半径等）
        
        Returns:
            爬取结果（具体类型由子类定义）
        
        Raises:
            NotImplementedError: 如果子类未实现此方法
        """
        raise NotImplementedError("子类必须实现crawl方法")
