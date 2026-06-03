# -*- coding: utf-8 -*-
"""
DJI禁飞区与POI爬虫 - 主入口文件

支持的爬取类型:
    dji      - DJI禁飞区
    amap     - 高德POI
    tianditu - 天地图POI

POI 爬取模式:
    1. 单点周边: --lat --lng [--radius]
    2. 矩形范围: --lat-min --lat-max --lng-min --lng-max
    3. 区域分块: --region [--grid-size]
"""

import argparse

from config import DJI_CONFIG, AMAP_CONFIG, TIANDITU_CONFIG
from src.crawlers import DJIFlySafeCrawler, AmapPOICrawler, TiandituPOICrawler


def _has_bounds(args):
    return all(v is not None for v in [args.lat_min, args.lat_max, args.lng_min, args.lng_max])


def _run_poi_crawler(crawler, args, config):
    """执行 POI 爬虫（高德/天地图通用逻辑）"""
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


def main():
    parser = argparse.ArgumentParser(
        description='DJI禁飞区与POI爬虫',
        formatter_class=argparse.RawTextHelpFormatter
    )

    parser.add_argument(
        '--type',
        type=str,
        required=True,
        choices=['dji', 'amap', 'tianditu'],
        help='爬取类型:\n  dji - DJI禁飞区\n  amap - 高德POI\n  tianditu - 天地图POI'
    )

    parser.add_argument('--lat', type=float, help='中心纬度（单点模式）')
    parser.add_argument('--lng', type=float, help='中心经度（单点模式）')
    parser.add_argument('--radius', type=float, help='搜索半径(公里，单点模式)')

    parser.add_argument('--lat-min', type=float, help='范围最小纬度（范围模式）')
    parser.add_argument('--lat-max', type=float, help='范围最大纬度（范围模式）')
    parser.add_argument('--lng-min', type=float, help='范围最小经度（范围模式）')
    parser.add_argument('--lng-max', type=float, help='范围最大经度（范围模式）')

    parser.add_argument('--drone', type=str, help='DJI无人机型号slug（仅dji类型）')
    parser.add_argument('--keywords', type=str, help='POI搜索关键词（amap/tianditu）')

    parser.add_argument('--region', type=str, help='区域名称（分块爬取，如 henan、beijing）')
    parser.add_argument('--grid-size', type=float, default=1000, help='网格大小（公里，默认1000）')

    args = parser.parse_args()

    if args.type == 'dji':
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

    elif args.type == 'amap':
        print("=" * 60)
        print("Amap POI Crawler")
        print("=" * 60)

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

    elif args.type == 'tianditu':
        print("=" * 60)
        print("Tianditu POI Crawler")
        print("=" * 60)

        crawler = TiandituPOICrawler(TIANDITU_CONFIG)
        try:
            _run_poi_crawler(crawler, args, TIANDITU_CONFIG)
            print("\nSUCCESS!")
        except Exception as e:
            print("\nFAILED: {}".format(e))


if __name__ == '__main__':
    main()
