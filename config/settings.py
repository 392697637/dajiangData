# -*- coding: utf-8 -*-
"""
项目配置文件

此文件包含所有爬虫相关的配置参数，分为通用配置、DJI禁飞区配置和高德POI配置三个部分。

配置说明:
- 通用配置: 适用于所有爬虫的基础参数
- DJI_CONFIG: DJI禁飞区爬虫专用配置
- AMAP_CONFIG: 高德POI爬虫专用配置

使用方式:
    from config import DEFAULT_LAT, DJI_CONFIG, AMAP_CONFIG
"""

import os

# ==================== 通用配置 ====================
# 默认中心点坐标（郑州市中心）
DEFAULT_LAT = 34.72  # 默认纬度（郑州）
DEFAULT_LNG = 113.62  # 默认经度（郑州）
DEFAULT_RADIUS = 50  # 默认搜索半径（公里）

TIMEOUT = 30  # 请求超时时间（秒）


# ==================== PostgreSQL数据库配置 ====================
# POI数据直接入库使用；优先读取环境变量，未设置时使用默认连接信息。
DATABASE_CONFIG = {
    "host": os.getenv("DB_HOST", "192.168.110.6"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "database": os.getenv("DB_NAME", "ktd_lx_gis_shp"),
    "user": os.getenv("DB_USER", "zhuoyi"),
    "password": os.getenv("DB_PASSWORD", "Ktd@postSQL@2026!@#"),
}


# ==================== 区域边界配置（DJI/POI 共用） ====================
REGION_CONFIG = {
    "china": {
        "name": "中国",
        "lat_min": 18.0,
        "lat_max": 54.0,
        "lng_min": 73.0,
        "lng_max": 135.0,
        "grid_size_km": 1000,
    },
    "beijing": {
        "name": "北京市",
        "lat_min": 39.4,
        "lat_max": 41.1,
        "lng_min": 115.4,
        "lng_max": 117.5,
        "grid_size_km": 100,
    },
    "tianjin": {
        "name": "天津市",
        "lat_min": 38.5,
        "lat_max": 40.3,
        "lng_min": 116.7,
        "lng_max": 118.3,
        "grid_size_km": 100,
    },
    "hebei": {
        "name": "河北省",
        "lat_min": 36.0,
        "lat_max": 42.6,
        "lng_min": 113.5,
        "lng_max": 119.9,
        "grid_size_km": 200,
    },
    "shanxi": {
        "name": "山西省",
        "lat_min": 34.5,
        "lat_max": 40.8,
        "lng_min": 110.2,
        "lng_max": 114.6,
        "grid_size_km": 200,
    },
    "neimenggu": {
        "name": "内蒙古自治区",
        "lat_min": 37.4,
        "lat_max": 53.2,
        "lng_min": 97.2,
        "lng_max": 126.0,
        "grid_size_km": 300,
    },
    "liaoning": {
        "name": "辽宁省",
        "lat_min": 38.7,
        "lat_max": 43.5,
        "lng_min": 118.8,
        "lng_max": 125.3,
        "grid_size_km": 200,
    },
    "jilin": {
        "name": "吉林省",
        "lat_min": 40.9,
        "lat_max": 46.3,
        "lng_min": 121.4,
        "lng_max": 131.2,
        "grid_size_km": 200,
    },
    "heilongjiang": {
        "name": "黑龙江省",
        "lat_min": 43.4,
        "lat_max": 53.5,
        "lng_min": 121.2,
        "lng_max": 135.0,
        "grid_size_km": 300,
    },
    "shanghai": {
        "name": "上海市",
        "lat_min": 30.7,
        "lat_max": 31.9,
        "lng_min": 120.9,
        "lng_max": 122.0,
        "grid_size_km": 100,
    },
    "jiangsu": {
        "name": "江苏省",
        "lat_min": 30.7,
        "lat_max": 35.1,
        "lng_min": 116.4,
        "lng_max": 121.9,
        "grid_size_km": 200,
    },
    "zhejiang": {
        "name": "浙江省",
        "lat_min": 27.0,
        "lat_max": 31.3,
        "lng_min": 118.0,
        "lng_max": 122.9,
        "grid_size_km": 200,
    },
    "anhui": {
        "name": "安徽省",
        "lat_min": 29.4,
        "lat_max": 34.7,
        "lng_min": 114.9,
        "lng_max": 119.6,
        "grid_size_km": 200,
    },
    "fujian": {
        "name": "福建省",
        "lat_min": 23.4,
        "lat_max": 28.3,
        "lng_min": 115.5,
        "lng_max": 120.8,
        "grid_size_km": 200,
    },
    "jiangxi": {
        "name": "江西省",
        "lat_min": 24.3,
        "lat_max": 30.1,
        "lng_min": 113.3,
        "lng_max": 118.3,
        "grid_size_km": 200,
    },
    "shandong": {
        "name": "山东省",
        "lat_min": 34.4,
        "lat_max": 38.4,
        "lng_min": 114.5,
        "lng_max": 122.7,
        "grid_size_km": 200,
    },
    "henan": {
        "name": "河南省",
        "lat_min": 31.4,
        "lat_max": 36.4,
        "lng_min": 110.4,
        "lng_max": 116.7,
        "grid_size_km": 200,
    },
    "zhengzhou": {
        "name": "郑州市",
        "lat_min": 34.53,
        "lat_max": 34.95,
        "lng_min": 113.45,
        "lng_max": 114.05,
        "grid_size_km": 20,
    },
    "hubei": {
        "name": "湖北省",
        "lat_min": 29.0,
        "lat_max": 33.3,
        "lng_min": 108.2,
        "lng_max": 116.1,
        "grid_size_km": 200,
    },
    "hunan": {
        "name": "湖南省",
        "lat_min": 24.6,
        "lat_max": 30.1,
        "lng_min": 108.8,
        "lng_max": 114.2,
        "grid_size_km": 200,
    },
    "guangdong": {
        "name": "广东省",
        "lat_min": 20.1,
        "lat_max": 25.6,
        "lng_min": 109.7,
        "lng_max": 117.5,
        "grid_size_km": 200,
    },
    "guangxi": {
        "name": "广西壮族自治区",
        "lat_min": 20.5,
        "lat_max": 26.4,
        "lng_min": 104.3,
        "lng_max": 112.0,
        "grid_size_km": 200,
    },
    "hainan": {
        "name": "海南省",
        "lat_min": 18.1,
        "lat_max": 20.2,
        "lng_min": 108.6,
        "lng_max": 111.1,
        "grid_size_km": 200,
    },
    "chongqing": {
        "name": "重庆市",
        "lat_min": 28.2,
        "lat_max": 32.2,
        "lng_min": 105.3,
        "lng_max": 110.2,
        "grid_size_km": 150,
    },
    "sichuan": {
        "name": "四川省",
        "lat_min": 26.0,
        "lat_max": 34.4,
        "lng_min": 97.3,
        "lng_max": 108.5,
        "grid_size_km": 200,
    },
    "guizhou": {
        "name": "贵州省",
        "lat_min": 24.4,
        "lat_max": 29.2,
        "lng_min": 103.6,
        "lng_max": 109.6,
        "grid_size_km": 200,
    },
    "yunnan": {
        "name": "云南省",
        "lat_min": 21.1,
        "lat_max": 29.2,
        "lng_min": 97.3,
        "lng_max": 106.1,
        "grid_size_km": 200,
    },
    "xizang": {
        "name": "西藏自治区",
        "lat_min": 26.5,
        "lat_max": 36.5,
        "lng_min": 78.4,
        "lng_max": 99.1,
        "grid_size_km": 300,
    },
    "shaanxi": {
        "name": "陕西省",
        "lat_min": 31.0,
        "lat_max": 39.4,
        "lng_min": 105.3,
        "lng_max": 111.1,
        "grid_size_km": 200,
    },
    "gansu": {
        "name": "甘肃省",
        "lat_min": 32.1,
        "lat_max": 42.8,
        "lng_min": 92.2,
        "lng_max": 108.7,
        "grid_size_km": 250,
    },
    "qinghai": {
        "name": "青海省",
        "lat_min": 31.6,
        "lat_max": 39.2,
        "lng_min": 89.4,
        "lng_max": 103.1,
        "grid_size_km": 300,
    },
    "ningxia": {
        "name": "宁夏回族自治区",
        "lat_min": 35.2,
        "lat_max": 39.3,
        "lng_min": 104.2,
        "lng_max": 106.9,
        "grid_size_km": 150,
    },
    "xinjiang": {
        "name": "新疆维吾尔自治区",
        "lat_min": 34.2,
        "lat_max": 49.2,
        "lng_min": 73.2,
        "lng_max": 96.4,
        "grid_size_km": 400,
    },
    "hongkong": {
        "name": "香港特别行政区",
        "lat_min": 22.1,
        "lat_max": 22.5,
        "lng_min": 113.8,
        "lng_max": 114.5,
        "grid_size_km": 50,
    },
    "macau": {
        "name": "澳门特别行政区",
        "lat_min": 22.1,
        "lat_max": 22.2,
        "lng_min": 113.5,
        "lng_max": 113.6,
        "grid_size_km": 50,
    },
    "taiwan": {
        "name": "台湾省",
        "lat_min": 21.9,
        "lat_max": 25.3,
        "lng_min": 119.3,
        "lng_max": 122.1,
        "grid_size_km": 200,
    },
}


# ==================== DJI禁飞区配置 ====================
DJI_CONFIG = {
    # API端点配置
    "api_url": "https://flysafe-api.dji.com/api/qep/geo/feedback/areas/in_rectangle",
    "drones_api_url": "https://flysafe-api.dji.com/dji/drones",
    # 输出配置
    "output_dir": "output/dji",
    # 请求参数配置
    "params": {
        "default_drone": "dji-mavic-3",  # 默认无人机型号
        "zones_mode": "flysafe_website",  # 区域模式（固定值）
        "levels": "0,1,2,3,7,8,10",  # 禁飞区级别筛选
    },
    # 禁飞区级别说明（用于日志和结果展示）
    "level_descriptions": {
        0: "机场禁飞区",
        1: "机场限飞区",
        2: "国家级机场禁飞区",
        3: "临时限飞区",
        7: "干扰源区域",
        8: "军事管理区",
        10: "特殊管控区",
    },
    # 区域分块配置（用于大面积爬取）
    "region_config": REGION_CONFIG,
}

# DJI API参数说明:
# - ltlat: 矩形区域左上角纬度
# - ltlng: 矩形区域左上角经度
# - rblat: 矩形区域右下角纬度
# - rblng: 矩形区域右下角经度
# - zones_mode: 区域模式，固定为"flysafe_website"
# - drone: 无人机型号slug（如 dji-mavic-3）
# - level: 禁飞区级别，逗号分隔（如 "0,1,2,3,7,8,10"）


# ==================== 高德POI配置 ====================
AMAP_CONFIG = {
    # API端点配置
    "around_api_url": "https://restapi.amap.com/v3/place/around",
    "polygon_api_url": "https://restapi.amap.com/v5/place/polygon",
    # 输出配置
    "output_dir": "output/amap",
    # POI数据直接入库配置
    "save_to_db": True,
    "db_table": "gis_poiType_gd",
    "db_config": DATABASE_CONFIG,
    # API认证配置（需要在高德地图开放平台申请，或通过环境变量 AMAP_API_KEY 设置）
    "api_key": os.environ.get("AMAP_API_KEY", "3db5913a17927510f547cbddab83d41c"),
    # 区域分块配置
    "region_config": REGION_CONFIG,
    # POI类型配置（高德POI分类码）
    "poi_types": [
        "110000",  # 交通设施服务
        "120000",  # 金融保险服务
        "130000",  # 科教文化服务
        "140000",  # 体育休闲服务
        "150000",  # 医疗保健服务
        "160000",  # 住宿服务
        "170000",  # 餐饮服务
        "180000",  # 购物服务
        "200000",  # 商务住宅
        "210000",  # 地名地址信息
        "220000",  # 公共设施
        "230000",  # 行政区域
        "970000",  # 风景名胜
        "980000",  # 商务大厦
    ],
    # 请求参数配置
    "radius": 5000,  # 周边搜索半径（米）
    "page_size": 20,  # v3 每页返回数量
    "polygon_page_size": 25,  # v5 多边形搜索每页数量（最大25）
    "extensions": "all",  # 返回信息类型（base: 基础信息, all: 详细信息）
    "request_delay": 0.2,  # 请求间隔（秒），避免限流
}

# 高德POI API参数说明:
# - key: 高德API Key（必需）
# - location: 中心点坐标，格式为"经度,纬度"
# - radius: 搜索半径（米）
# - types: POI类型编码
# - page: 页码
# - offset: 每页数量
# - extensions: 返回信息类型
# - keywords: 搜索关键词（可选）
# - output: 输出格式（json/xml）


# ==================== 天地图POI配置 ====================
TIANDITU_CONFIG = {
    # API端点配置
    "api_url": "https://api.tianditu.gov.cn/v2/search",
    # 输出配置
    "output_dir": "output/tianditu",
    # POI数据直接入库配置
    "save_to_db": True,
    "db_table": "gis_poiType_td",
    "db_config": DATABASE_CONFIG,
    # API认证配置（需要在天地图开放平台申请，或通过环境变量 TIANDITU_API_KEY 设置）
    "api_key": os.environ.get("TIANDITU_API_KEY", "cf128e0b51efeb7df5f1720de282678e"),
    # 区域分块配置
    "region_config": REGION_CONFIG,
    # POI数据分类（天地图分类编码/名称，多个用英文逗号分隔）
    "data_types": "",
    # 请求参数配置
    "level": 12,  # 地图级别（视野内搜索使用，1-18）
    "page_size": 100,  # 每页返回数量（最大300）
    "default_keyword": "POI",  # 无关键词时使用的默认搜索词
    "show": "2",  # 1: 基本信息, 2: 详细信息
    "request_delay": 0.2,  # 请求间隔（秒）
}

# 天地图 API 参数说明:
# - queryType=2: 视野内搜索（mapBound）
# - queryType=3: 周边搜索（pointLonlat + queryRadius）
# - queryType=10: 多边形搜索（polygon）
# - queryType=13: 分类搜索（specify + mapBound + dataTypes）
# - tk: 天地图 API Key
