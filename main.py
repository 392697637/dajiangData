# -*- coding: utf-8 -*-
"""
DJI禁飞区与高德POI爬虫 - 主入口文件

此文件是项目的命令行入口，负责解析命令行参数并调用相应的爬虫。

支持的命令行参数:
    --type: 爬取类型（必需），可选值: dji 或 amap
    --lat: 中心纬度（可选，默认为郑州坐标）
    --lng: 中心经度（可选，默认为郑州坐标）
    --radius: 搜索半径（公里，可选）
    --drone: DJI无人机型号slug（可选，仅DJI爬虫使用）
    --keywords: 高德POI搜索关键词（可选，仅高德爬虫使用）
    --region: 区域名称（可选，用于大面积分块爬取，仅DJI爬虫使用）
    --grid-size: 网格大小（公里，默认1000，用于区域分块爬取）

使用示例:
    # 爬取DJI禁飞区（郑州50公里范围）
    python main.py --type dji
    
    # 指定区域（北京100公里范围）
    python main.py --type dji --lat 39.90 --lng 116.40 --radius 100
    
    # 指定无人机型号
    python main.py --type dji --drone dji-mini-4-pro
    
    # 按区域分块爬取（爬取整个中国，按1000km分块）
    python main.py --type dji --region china --grid-size 1000
    
    # 爬取高德POI
    python main.py --type amap --keywords "机场"
"""

import argparse

# 导入配置和爬虫类
from config import DJI_CONFIG, AMAP_CONFIG
from src.crawlers import DJIFlySafeCrawler, AmapPOICrawler


def main():
    """
    主函数，负责解析命令行参数并执行爬虫
    
    流程:
    1. 创建命令行参数解析器
    2. 解析命令行参数
    3. 根据参数选择对应的爬虫
    4. 执行爬取并处理结果
    """
    # 创建命令行参数解析器
    parser = argparse.ArgumentParser(
        description='DJI禁飞区与高德POI爬虫',
        formatter_class=argparse.RawTextHelpFormatter
    )
    
    # 添加必需参数：爬取类型
    parser.add_argument(
        '--type', 
        type=str, 
        required=True, 
        choices=['dji', 'amap'],
        help='爬取类型:\n  dji - DJI禁飞区\n  amap - 高德POI'
    )
    
    # 添加可选参数：坐标和半径
    parser.add_argument('--lat', type=float, help='中心纬度')
    parser.add_argument('--lng', type=float, help='中心经度')
    parser.add_argument('--radius', type=float, help='搜索半径(公里)')
    
    # 添加爬虫特定参数
    parser.add_argument('--drone', type=str, help='DJI无人机型号slug（仅dji类型）')
    parser.add_argument('--keywords', type=str, help='高德POI搜索关键词（仅amap类型）')
    
    # 添加区域分块爬取参数（仅DJI爬虫使用）
    parser.add_argument(
        '--region', 
        type=str, 
        help='区域名称（用于大面积分块爬取，如china）'
    )
    parser.add_argument(
        '--grid-size', 
        type=float, 
        default=1000,
        help='网格大小（公里），用于区域分块爬取（默认1000）'
    )
    
    # 解析命令行参数
    args = parser.parse_args()
    
    # 根据爬取类型执行相应的爬虫
    if args.type == 'dji':
        # DJI禁飞区爬虫
        print("=" * 60)
        print("DJI Fly Safe Zone Crawler")
        
        # 判断是区域分块爬取还是单点爬取
        if args.region:
            # 区域分块爬取模式
            print("Mode: Region Crawl")
            print("Region: {}".format(args.region))
            print("Grid Size: {} km".format(args.grid_size))
        else:
            # 单点爬取模式
            print("Mode: Single Point Crawl")
            print("Center: ({}, {}), Radius: {} km".format(
                args.lat or DJI_CONFIG.get('default_lat', 34.72),
                args.lng or DJI_CONFIG.get('default_lng', 113.62),
                args.radius or DJI_CONFIG.get('default_radius', 50)
            ))
        print("=" * 60)
        
        # 创建DJI禁飞区爬虫实例
        crawler = DJIFlySafeCrawler(DJI_CONFIG)
        
        # 如果指定了无人机型号，设置型号
        if args.drone:
            crawler.set_drone_model(args.drone)
        
        # 执行爬取
        try:
            if args.region:
                # 区域分块爬取
                crawler.crawl_region(region_name=args.region, grid_size_km=args.grid_size)
            else:
                # 单点爬取
                crawler.crawl(lat=args.lat, lng=args.lng, radius=args.radius)
            print("\nSUCCESS!")
        except Exception as e:
            print("\nFAILED: {}".format(e))
    
    elif args.type == 'amap':
        # 高德POI爬虫
        print("=" * 60)
        print("Amap POI Crawler")
        print("Center: ({}, {})".format(
            args.lat or AMAP_CONFIG.get('default_lat', 34.72),
            args.lng or AMAP_CONFIG.get('default_lng', 113.62)
        ))
        if args.keywords:
            print("Keywords: {}".format(args.keywords))
        print("=" * 60)
        
        # 创建高德POI爬虫实例
        crawler = AmapPOICrawler(AMAP_CONFIG)
        
        # 执行爬取
        try:
            crawler.crawl(lat=args.lat, lng=args.lng, keywords=args.keywords)
            print("\nSUCCESS!")
        except Exception as e:
            print("\nFAILED: {}".format(e))


# 程序入口
if __name__ == '__main__':
    main()