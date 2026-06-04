# -*- coding: utf-8 -*-
"""
DJI禁飞区与POI爬虫 - 主入口文件

接口结构:
    main.py --category <poi|dji> [--provider <amap|tianditu>] [--action <poitype|poidata>]

POI 模块 (--category poi):
    --provider amap     - 高德POI
    --provider tianditu - 天地图POI
    --action poitype    - 获取POI类型列表
    --action poidata    - 获取POI数据

    POI数据获取模式:
        1. 单点周边: --lat --lng [--radius]
        2. 矩形范围: --lat-min --lat-max --lng-min --lng-max
        3. 区域分块: --region [--grid-size]

DJI 模块 (--category dji):
    保持原有参数不变
"""

import argparse
import requests

from config import DJI_CONFIG, AMAP_CONFIG, TIANDITU_CONFIG
from src.crawlers import DJIFlySafeCrawler, AmapPOICrawler, TiandituPOICrawler


def _has_bounds(args):
    return all(v is not None for v in [args.lat_min, args.lat_max, args.lng_min, args.lng_max])


# 高德POI类型本地备用列表（当API不可用时使用）
_AMAP_POI_TYPES_FALLBACK = [
    {"code": "110000", "name": "交通设施服务", "subtypes": [
        {"code": "110100", "name": "铁路与地铁"},
        {"code": "110200", "name": "道路附属设施"},
        {"code": "110300", "name": "机场"},
        {"code": "110400", "name": "港口码头"},
        {"code": "110500", "name": "停车场"},
        {"code": "110600", "name": "加油站"},
    ]},
    {"code": "120000", "name": "金融保险服务", "subtypes": [
        {"code": "120100", "name": "银行"},
        {"code": "120200", "name": "ATM"},
        {"code": "120300", "name": "保险公司"},
        {"code": "120400", "name": "证券公司"},
    ]},
    {"code": "130000", "name": "科教文化服务", "subtypes": [
        {"code": "130100", "name": "高等院校"},
        {"code": "130200", "name": "中小学校"},
        {"code": "130300", "name": "幼儿园"},
        {"code": "130400", "name": "图书馆"},
        {"code": "130500", "name": "博物馆"},
        {"code": "130600", "name": "科技馆"},
    ]},
    {"code": "140000", "name": "体育休闲服务", "subtypes": [
        {"code": "140100", "name": "体育场馆"},
        {"code": "140200", "name": "运动健身"},
        {"code": "140300", "name": "公园广场"},
        {"code": "140400", "name": "旅游景点"},
    ]},
    {"code": "150000", "name": "医疗保健服务", "subtypes": [
        {"code": "150100", "name": "综合医院"},
        {"code": "150200", "name": "专科医院"},
        {"code": "150300", "name": "诊所"},
        {"code": "150400", "name": "药店"},
    ]},
    {"code": "160000", "name": "住宿服务", "subtypes": [
        {"code": "160100", "name": "星级酒店"},
        {"code": "160200", "name": "经济型酒店"},
        {"code": "160300", "name": "民宿客栈"},
        {"code": "160400", "name": "度假村"},
    ]},
    {"code": "170000", "name": "餐饮服务", "subtypes": [
        {"code": "170100", "name": "中餐馆"},
        {"code": "170200", "name": "西餐厅"},
        {"code": "170300", "name": "快餐店"},
        {"code": "170400", "name": "咖啡厅"},
        {"code": "170500", "name": "茶馆"},
    ]},
    {"code": "180000", "name": "购物服务", "subtypes": [
        {"code": "180100", "name": "商场"},
        {"code": "180200", "name": "超市"},
        {"code": "180300", "name": "便利店"},
        {"code": "180400", "name": "专卖店"},
        {"code": "180500", "name": "农贸市场"},
    ]},
    {"code": "200000", "name": "商务住宅", "subtypes": [
        {"code": "200100", "name": "写字楼"},
        {"code": "200200", "name": "住宅区"},
        {"code": "200300", "name": "公寓"},
    ]},
    {"code": "210000", "name": "地名地址信息", "subtypes": [
        {"code": "210100", "name": "行政区域"},
        {"code": "210200", "name": "道路"},
        {"code": "210300", "name": "门牌号"},
        {"code": "210400", "name": "村庄"},
    ]},
    {"code": "220000", "name": "公共设施", "subtypes": [
        {"code": "220100", "name": "公共厕所"},
        {"code": "220200", "name": "垃圾站"},
        {"code": "220300", "name": "邮政电信"},
        {"code": "220400", "name": "电力设施"},
    ]},
    {"code": "230000", "name": "行政区域", "subtypes": [
        {"code": "230100", "name": "省级行政区"},
        {"code": "230200", "name": "地级行政区"},
        {"code": "230300", "name": "县级行政区"},
        {"code": "230400", "name": "乡级行政区"},
    ]},
    {"code": "970000", "name": "风景名胜", "subtypes": [
        {"code": "970100", "name": "自然景观"},
        {"code": "970200", "name": "人文古迹"},
        {"code": "970300", "name": "城市公园"},
        {"code": "970400", "name": "旅游度假区"},
    ]},
    {"code": "980000", "name": "商务大厦", "subtypes": [
        {"code": "980100", "name": "商务办公楼"},
        {"code": "980200", "name": "商业中心"},
        {"code": "980300", "name": "产业园区"},
    ]},
]


def _get_amap_poi_types(api_key):
    """获取高德地图完整POI类型列表（优先API，失败时使用本地备用列表）"""
    url = "https://restapi.amap.com/v3/assistantimetypes"
    params = {"key": api_key, "output": "json"}

    try:
        resp = requests.get(url, params=params, verify=False, timeout=10)
        data = resp.json()

        if data.get("status") == "1" and data.get("types"):
            return data
        else:
            print("API返回数据异常，使用本地备用类型列表")
            return {"status": "1", "info": "使用本地备用数据", "types": _AMAP_POI_TYPES_FALLBACK}
    except Exception as e:
        print("API调用失败: {}".format(str(e)))
        print("使用本地备用类型列表")
        return {"status": "1", "info": "使用本地备用数据", "types": _AMAP_POI_TYPES_FALLBACK}


def _save_poi_types_to_db(types_data, provider, db_config):
    """将POI类型数据保存到数据库"""
    try:
        import psycopg2
        from psycopg2.extras import execute_values
    except ImportError:
        print("错误：缺少psycopg2-binary依赖，请先安装")
        return 0

    if types_data.get("status") != "1":
        print("数据无效，无法入库")
        return 0

    types = types_data.get("types", [])
    if not types:
        print("没有数据需要入库")
        return 0

    try:
        conn = psycopg2.connect(
            host=db_config.get("host"),
            port=db_config.get("port"),
            dbname=db_config.get("database"),
            user=db_config.get("user"),
            password=db_config.get("password"),
        )

        # 创建表
        table_name = "gis_poi_types"
        create_table_sql = f'''
        CREATE TABLE IF NOT EXISTS "{table_name}" (
            id BIGSERIAL PRIMARY KEY,
            provider VARCHAR(32) NOT NULL,
            type_code VARCHAR(32) NOT NULL,
            type_name VARCHAR(128) NOT NULL,
            parent_code VARCHAR(32),
            level INT NOT NULL DEFAULT 1,
            created_at TIMESTAMPTZ DEFAULT now(),
            UNIQUE (provider, type_code)
        );
        CREATE INDEX IF NOT EXISTS "idx_{table_name}_provider" ON "{table_name}" (provider);
        CREATE INDEX IF NOT EXISTS "idx_{table_name}_type_code" ON "{table_name}" (type_code);
        '''

        with conn.cursor() as cur:
            cur.execute(create_table_sql)
        conn.commit()

        # 准备数据
        rows = []
        for item in types:
            code = item.get("code", "")
            name = item.get("name", "")
            rows.append((provider, code, name, None, 1))

            subtypes = item.get("subtypes", [])
            for sub in subtypes:
                sub_code = sub.get("code", "")
                sub_name = sub.get("name", "")
                rows.append((provider, sub_code, sub_name, code, 2))

        # 插入数据
        insert_sql = f'''
            INSERT INTO "{table_name}" (provider, type_code, type_name, parent_code, level)
            VALUES %s
            ON CONFLICT (provider, type_code) DO UPDATE SET
                type_name = EXCLUDED.type_name,
                parent_code = EXCLUDED.parent_code,
                level = EXCLUDED.level
        '''

        with conn.cursor() as cur:
            execute_values(cur, insert_sql, rows)
        conn.commit()

        count = len(rows)
        print(f"\n成功！POI类型数据已入库 {count} 条")
        print(f"入库表: {table_name}")

        conn.close()
        return count
    except Exception as e:
        print(f"\n入库失败: {str(e)}")
        return 0


def _print_poi_types(types_data, provider):
    """打印POI类型列表"""
    print("\n=== {} POI类型列表 ===".format(provider))

    if types_data.get("status") != "1":
        print("获取类型列表失败:", types_data.get("info", "Unknown error"))
        return

    if types_data.get("info") == "使用本地备用数据":
        print("（本地备用数据）")

    types = types_data.get("types", [])
    for item in types:
        code = item.get("code", "")
        name = item.get("name", "")
        print(f"\n[{code}] {name}")

        subtypes = item.get("subtypes", [])
        if subtypes:
            for sub in subtypes:
                sub_code = sub.get("code", "")
                sub_name = sub.get("name", "")
                print(f"  └── [{sub_code}] {sub_name}")
    print(f"\n共 {len(types)} 个一级分类")


def _run_poi_crawler(crawler, args, config):
    """执行POI数据爬取（高德/天地图通用逻辑）"""
    if args.region:
        print("Mode: Region Crawl")
        print("Region: {}".format(args.region))
        print("Grid Size: {} km".format(args.grid_size))
        crawler.crawl_region(
            region_name=args.region,
            grid_size_km=args.grid_size,
            keywords=args.keywords,
        )
    elif _has_bounds(args):
        print("Mode: Bounds Crawl")
        print("Bounds: lat {:.4f}~{:.4f}, lng {:.4f}~{:.4f}".format(
            args.lat_min, args.lat_max, args.lng_min, args.lng_max
        ))
        crawler.crawl_bounds(
            lat_min=args.lat_min,
            lat_max=args.lat_max,
            lng_min=args.lng_min,
            lng_max=args.lng_max,
            keywords=args.keywords,
        )
    else:
        from config import DEFAULT_LAT, DEFAULT_LNG
        lat = args.lat or DEFAULT_LAT
        lng = args.lng or DEFAULT_LNG
        print("Mode: Around Search")
        print("Center: ({}, {})".format(lat, lng))
        if args.radius:
            print("Radius: {} km".format(args.radius))
        if args.keywords:
            print("Keywords: {}".format(args.keywords))
        crawler.crawl(
            lat=lat,
            lng=lng,
            radius=args.radius,
            keywords=args.keywords,
        )


def handle_poi_category(args):
    """处理POI分类"""
    provider = args.provider

    if provider == 'amap':
        print("=" * 60)
        print("Amap POI Module")
        print("=" * 60)

        if args.action == 'poitype':
            print("\nAction: Get POI Types")
            types_data = _get_amap_poi_types(AMAP_CONFIG["api_key"])
            _print_poi_types(types_data, "高德")

            if args.save_to_db:
                print("\n正在将POI类型数据入库...")
                _save_poi_types_to_db(types_data, "amap", AMAP_CONFIG.get("db_config", {}))

        elif args.action == 'poidata':
            print("\nAction: Get POI Data")
            crawler = AmapPOICrawler(AMAP_CONFIG)
            try:
                if not args.region and not _has_bounds(args) and args.radius:
                    from config import DEFAULT_LAT, DEFAULT_LNG
                    lat = args.lat or DEFAULT_LAT
                    lng = args.lng or DEFAULT_LNG
                    radius_m = int(args.radius * 1000)
                    print("Mode: Around Search")
                    print("Center: ({}, {}), Radius: {} m".format(lat, lng, radius_m))
                    if args.keywords:
                        print("Keywords: {}".format(args.keywords))
                    crawler.crawl(lat=lat, lng=lng, radius=radius_m, keywords=args.keywords)
                else:
                    _run_poi_crawler(crawler, args, AMAP_CONFIG)
                print("\nSUCCESS!")
            except Exception as e:
                print("\nFAILED: {}".format(e))

    elif provider == 'tianditu':
        print("=" * 60)
        print("Tianditu POI Module")
        print("=" * 60)

        if args.action == 'poitype':
            print("\nAction: Get POI Types")
            print("天地图POI类型配置: {}".format(TIANDITU_CONFIG.get("data_types", "未配置")))
            print("\n天地图类型参数说明:")
            print("  - dataTypes: 分类名称，多个用英文逗号分隔")
            print("  - 常用类型: 学校,医院,公园,商场,酒店,餐厅等")
            print("  - 空字符串表示不限制类型")

        elif args.action == 'poidata':
            print("\nAction: Get POI Data")
            crawler = TiandituPOICrawler(TIANDITU_CONFIG)
            try:
                _run_poi_crawler(crawler, args, TIANDITU_CONFIG)
                print("\nSUCCESS!")
            except Exception as e:
                print("\nFAILED: {}".format(e))


def handle_dji_category(args):
    """处理DJI分类"""
    print("=" * 60)
    print("DJI Fly Safe Zone Crawler")

    if args.region:
        print("Mode: Region Crawl")
        print("Region: {}".format(args.region))
        print("Grid Size: {} km".format(args.grid_size))
    else:
        print("Mode: Single Point Crawl")
        print("Center: ({}, {}), Radius: {} km".format(
            args.lat or DJI_CONFIG.get('default_lat', 34.72),
            args.lng or DJI_CONFIG.get('default_lng', 113.62),
            args.radius or DJI_CONFIG.get('default_radius', 50)
        ))
    print("=" * 60)

    crawler = DJIFlySafeCrawler(DJI_CONFIG)
    if args.drone:
        crawler.set_drone_model(args.drone)

    try:
        if args.region:
            crawler.crawl_region(region_name=args.region, grid_size_km=args.grid_size)
        else:
            crawler.crawl(lat=args.lat, lng=args.lng, radius=args.radius)
        print("\nSUCCESS!")
    except Exception as e:
        print("\nFAILED: {}".format(e))


def main():
    parser = argparse.ArgumentParser(
        description='DJI禁飞区与POI爬虫',
        formatter_class=argparse.RawTextHelpFormatter
    )

    # 一级分类
    parser.add_argument(
        '--category',
        type=str,
        required=True,
        choices=['poi', 'dji'],
        help='模块分类:\n  poi - POI数据爬取\n  dji - DJI禁飞区爬取'
    )

    # POI模块参数
    parser.add_argument(
        '--provider',
        type=str,
        choices=['amap', 'tianditu'],
        help='POI数据源（仅poi分类）:\n  amap - 高德地图\n  tianditu - 天地图'
    )

    parser.add_argument(
        '--action',
        type=str,
        choices=['poitype', 'poidata'],
        help='POI操作类型（仅poi分类）:\n  poitype - 获取POI类型列表\n  poidata - 获取POI数据'
    )

    # 通用坐标参数
    parser.add_argument('--lat', type=float, help='中心纬度')
    parser.add_argument('--lng', type=float, help='中心经度')
    parser.add_argument('--radius', type=float, help='搜索半径(公里)')

    # 范围搜索参数
    parser.add_argument('--lat-min', type=float, help='范围最小纬度')
    parser.add_argument('--lat-max', type=float, help='范围最大纬度')
    parser.add_argument('--lng-min', type=float, help='范围最小经度')
    parser.add_argument('--lng-max', type=float, help='范围最大经度')

    # DJI专用参数
    parser.add_argument('--drone', type=str, help='DJI无人机型号slug')

    # POI专用参数
    parser.add_argument('--keywords', type=str, help='POI搜索关键词')
    parser.add_argument('--save-to-db', action='store_true', help='将POI类型数据保存到数据库（仅poitype操作）')

    # 区域分块参数
    parser.add_argument('--region', type=str, help='区域名称（如 henan、beijing）')
    parser.add_argument('--grid-size', type=float, default=1000, help='网格大小（公里，默认1000）')

    args = parser.parse_args()

    # 参数校验
    if args.category == 'poi':
        if not args.provider:
            parser.error("使用poi分类时必须指定--provider")
        if not args.action:
            parser.error("使用poi分类时必须指定--action")

    # 路由分发
    if args.category == 'poi':
        handle_poi_category(args)
    elif args.category == 'dji':
        handle_dji_category(args)


if __name__ == '__main__':
    main()
