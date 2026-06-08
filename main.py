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
import logging
import os
from datetime import datetime


# 配置日志
def _setup_logging():
    """配置日志记录，将日志写入文件"""
    log_dir = "logs"
    if not os.path.exists(log_dir):
        os.makedirs(log_dir)

    log_filename = f"{log_dir}/poi_crawler_{datetime.now().strftime('%Y%m%d')}.log"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[
            logging.FileHandler(log_filename, encoding="utf-8"),
            # logging.StreamHandler()  # 不输出到控制台
        ],
    )
    return logging.getLogger(__name__)


logger = _setup_logging()

# 每次执行添加日志分隔符
logger.info("=" * 60)
logger.info(f"执行开始 - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
logger.info("=" * 60)

from config import DJI_CONFIG, AMAP_CONFIG, TIANDITU_CONFIG
from src.crawlers import DJIFlySafeCrawler, AmapPOICrawler, TiandituPOICrawler


def _has_bounds(args):
    return all(
        v is not None for v in [args.lat_min, args.lat_max, args.lng_min, args.lng_max]
    )


# 高德POI类型本地备用列表（当API不可用时使用）
_AMAP_POI_TYPES_FALLBACK = [
    {
        "code": "110000",
        "name": "交通设施服务",
        "subtypes": [
            {"code": "110100", "name": "铁路与地铁"},
            {"code": "110200", "name": "道路附属设施"},
            {"code": "110300", "name": "机场"},
            {"code": "110400", "name": "港口码头"},
            {"code": "110500", "name": "停车场"},
            {"code": "110600", "name": "加油站"},
        ],
    },
    {
        "code": "120000",
        "name": "金融保险服务",
        "subtypes": [
            {"code": "120100", "name": "银行"},
            {"code": "120200", "name": "ATM"},
            {"code": "120300", "name": "保险公司"},
            {"code": "120400", "name": "证券公司"},
        ],
    },
    {
        "code": "130000",
        "name": "科教文化服务",
        "subtypes": [
            {"code": "130100", "name": "高等院校"},
            {"code": "130200", "name": "中小学校"},
            {"code": "130300", "name": "幼儿园"},
            {"code": "130400", "name": "图书馆"},
            {"code": "130500", "name": "博物馆"},
            {"code": "130600", "name": "科技馆"},
        ],
    },
    {
        "code": "140000",
        "name": "体育休闲服务",
        "subtypes": [
            {"code": "140100", "name": "体育场馆"},
            {"code": "140200", "name": "运动健身"},
            {"code": "140300", "name": "公园广场"},
            {"code": "140400", "name": "旅游景点"},
        ],
    },
    {
        "code": "150000",
        "name": "医疗保健服务",
        "subtypes": [
            {"code": "150100", "name": "综合医院"},
            {"code": "150200", "name": "专科医院"},
            {"code": "150300", "name": "诊所"},
            {"code": "150400", "name": "药店"},
        ],
    },
    {
        "code": "160000",
        "name": "住宿服务",
        "subtypes": [
            {"code": "160100", "name": "星级酒店"},
            {"code": "160200", "name": "经济型酒店"},
            {"code": "160300", "name": "民宿客栈"},
            {"code": "160400", "name": "度假村"},
        ],
    },
    {
        "code": "170000",
        "name": "餐饮服务",
        "subtypes": [
            {"code": "170100", "name": "中餐馆"},
            {"code": "170200", "name": "西餐厅"},
            {"code": "170300", "name": "快餐店"},
            {"code": "170400", "name": "咖啡厅"},
            {"code": "170500", "name": "茶馆"},
        ],
    },
    {
        "code": "180000",
        "name": "购物服务",
        "subtypes": [
            {"code": "180100", "name": "商场"},
            {"code": "180200", "name": "超市"},
            {"code": "180300", "name": "便利店"},
            {"code": "180400", "name": "专卖店"},
            {"code": "180500", "name": "农贸市场"},
        ],
    },
    {
        "code": "200000",
        "name": "商务住宅",
        "subtypes": [
            {"code": "200100", "name": "写字楼"},
            {"code": "200200", "name": "住宅区"},
            {"code": "200300", "name": "公寓"},
        ],
    },
    {
        "code": "210000",
        "name": "地名地址信息",
        "subtypes": [
            {"code": "210100", "name": "行政区域"},
            {"code": "210200", "name": "道路"},
            {"code": "210300", "name": "门牌号"},
            {"code": "210400", "name": "村庄"},
        ],
    },
    {
        "code": "220000",
        "name": "公共设施",
        "subtypes": [
            {"code": "220100", "name": "公共厕所"},
            {"code": "220200", "name": "垃圾站"},
            {"code": "220300", "name": "邮政电信"},
            {"code": "220400", "name": "电力设施"},
        ],
    },
    {
        "code": "230000",
        "name": "行政区域",
        "subtypes": [
            {"code": "230100", "name": "省级行政区"},
            {"code": "230200", "name": "地级行政区"},
            {"code": "230300", "name": "县级行政区"},
            {"code": "230400", "name": "乡级行政区"},
        ],
    },
    {
        "code": "970000",
        "name": "风景名胜",
        "subtypes": [
            {"code": "970100", "name": "自然景观"},
            {"code": "970200", "name": "人文古迹"},
            {"code": "970300", "name": "城市公园"},
            {"code": "970400", "name": "旅游度假区"},
        ],
    },
    {
        "code": "980000",
        "name": "商务大厦",
        "subtypes": [
            {"code": "980100", "name": "商务办公楼"},
            {"code": "980200", "name": "商业中心"},
            {"code": "980300", "name": "产业园区"},
        ],
    },
]


def _fetch_amap_poi_types_from_api(api_key):
    """
    从高德API获取POI类型列表（备用方法），失败时返回本地备用数据

    Args:
        api_key (str): 高德API Key

    Returns:
        dict: 返回POI类型数据结构
    """
    url = "https://restapi.amap.com/v3/assistantimetypes"
    params = {"key": api_key, "output": "json"}

    try:
        resp = requests.get(url, params=params, verify=False, timeout=10)
        data = resp.json()

        if data.get("status") == "1" and data.get("types"):
            logger.info("获取POI类型: 从高德API获取成功")
            return data
        else:
            logger.warning("获取POI类型: 高德API返回数据异常，使用本地备用数据")
            return {
                "status": "1",
                "info": "使用本地备用数据",
                "types": _AMAP_POI_TYPES_FALLBACK,
            }
    except Exception as e:
        logger.error(f"获取POI类型: 调用高德API失败: {str(e)}")
        logger.info("获取POI类型: 使用本地备用数据")
        return {
            "status": "1",
            "info": "使用本地备用数据",
            "types": _AMAP_POI_TYPES_FALLBACK,
        }


def _get_amap_poi_types(db_config=None, api_key=None):
    """
    获取高德POI类型列表（优先从API获取最新数据）

    Args:
        db_config (dict, optional): 数据库配置字典，包含host/port/database/user/password
                                    如果不提供，将从config.DATABASE_CONFIG获取
        api_key (str, optional): 高德API Key，优先使用API获取最新数据

    Returns:
        dict: 返回POI类型数据结构
            - status: "1"表示成功，"0"表示失败
            - info: 状态信息
            - types: POI类型列表，每个元素包含code/name/subtypes
    """
    # 优先从API获取最新数据
    if api_key:
        logger.info("获取POI类型: 正在从高德API获取最新数据")
        return _fetch_amap_poi_types_from_api(api_key)

    # 如果没有API Key，尝试从数据库读取（降级方案）
    try:
        import psycopg2
    except ImportError:
        logger.error("缺少psycopg2-binary依赖，请先安装")
        return {"status": "0", "info": "缺少依赖"}

    # 获取数据库配置
    if not db_config:
        from config import DATABASE_CONFIG

        db_config = DATABASE_CONFIG

    try:
        # 建立数据库连接
        conn = psycopg2.connect(
            host=db_config.get("host"),
            port=db_config.get("port"),
            dbname=db_config.get("database"),
            user=db_config.get("user"),
            password=db_config.get("password"),
        )

        # 查询一级分类（level=1）
        query = """
            SELECT type_code, type_name 
            FROM gis_poi_type_gd 
            WHERE level = 1 
            ORDER BY type_code
        """

        with conn.cursor() as cur:
            cur.execute(query)
            primary_types = cur.fetchall()

        # 检查是否有数据
        if not primary_types:
            conn.close()
            return {
                "status": "0",
                "info": "数据库中暂无高德POI类型数据，请先执行 --save-to-db 入库",
            }

        # 构建类型树结构
        types = []
        for code, name in primary_types:
            # 查询子类型（level=2）
            sub_query = """
                SELECT type_code, type_name 
                FROM gis_poi_type_gd 
                WHERE parent_code = %s 
                ORDER BY type_code
            """
            cur.execute(sub_query, (code,))
            subtypes = [{"code": sc, "name": sn} for sc, sn in cur.fetchall()]

            types.append({"code": code, "name": name, "subtypes": subtypes})

        conn.close()
        logger.info("获取POI类型: 从数据库读取成功")
        return {"status": "1", "info": "从数据库读取", "types": types}

    except psycopg2.errors.UndefinedTable:
        # 表不存在，尝试从API获取
        conn.close()
        if api_key:
            logger.info("获取POI类型: 数据库表尚未创建，尝试从高德API获取")
            return _fetch_amap_poi_types_from_api(api_key)
        return {"status": "0", "info": "数据库表不存在，请先执行 --save-to-db 入库"}
    except Exception as e:
        logger.error(f"获取POI类型: 数据库读取失败: {str(e)}")
        # 降级到API获取
        if api_key:
            logger.info("获取POI类型: 尝试从高德API获取")
            return _fetch_amap_poi_types_from_api(api_key)
        return {"status": "0", "info": f"数据库读取失败: {str(e)}"}


# 天地图POI类型本地备用列表（当数据库不存在时使用）
_TIANDITU_POI_TYPES_FALLBACK = [
    {
        "code": "001",
        "name": "学校",
        "subtypes": [
            {"code": "001001", "name": "小学"},
            {"code": "001002", "name": "中学"},
            {"code": "001003", "name": "大学"},
            {"code": "001004", "name": "幼儿园"},
        ],
    },
    {
        "code": "002",
        "name": "医院",
        "subtypes": [
            {"code": "002001", "name": "综合医院"},
            {"code": "002002", "name": "专科医院"},
            {"code": "002003", "name": "诊所"},
            {"code": "002004", "name": "药店"},
        ],
    },
    {
        "code": "003",
        "name": "公园",
        "subtypes": [
            {"code": "003001", "name": "城市公园"},
            {"code": "003002", "name": "湿地公园"},
            {"code": "003003", "name": "森林公园"},
            {"code": "003004", "name": "植物园"},
        ],
    },
    {
        "code": "004",
        "name": "商场",
        "subtypes": [
            {"code": "004001", "name": "购物中心"},
            {"code": "004002", "name": "超市"},
            {"code": "004003", "name": "便利店"},
            {"code": "004004", "name": "专卖店"},
        ],
    },
    {
        "code": "005",
        "name": "酒店",
        "subtypes": [
            {"code": "005001", "name": "星级酒店"},
            {"code": "005002", "name": "经济型酒店"},
            {"code": "005003", "name": "民宿"},
            {"code": "005004", "name": "度假村"},
        ],
    },
    {
        "code": "006",
        "name": "餐厅",
        "subtypes": [
            {"code": "006001", "name": "中餐馆"},
            {"code": "006002", "name": "西餐厅"},
            {"code": "006003", "name": "快餐店"},
            {"code": "006004", "name": "咖啡厅"},
        ],
    },
    {
        "code": "007",
        "name": "银行",
        "subtypes": [
            {"code": "007001", "name": "商业银行"},
            {"code": "007002", "name": "ATM"},
            {"code": "007003", "name": "证券公司"},
            {"code": "007004", "name": "保险公司"},
        ],
    },
    {
        "code": "008",
        "name": "交通设施",
        "subtypes": [
            {"code": "008001", "name": "火车站"},
            {"code": "008002", "name": "地铁站"},
            {"code": "008003", "name": "机场"},
            {"code": "008004", "name": "公交站"},
        ],
    },
]


def _get_tianditu_poi_types(db_config=None):
    """
    获取天地图POI类型列表（优先从数据库读取，失败时使用本地备用数据）

    Args:
        db_config (dict, optional): 数据库配置字典，包含host/port/database/user/password
                                    如果不提供，将从config.DATABASE_CONFIG获取

    Returns:
        dict: 返回POI类型数据结构
            - status: "1"表示成功，"0"表示失败
            - info: 状态信息
            - types: POI类型列表，每个元素包含code/name/subtypes
    """
    try:
        import psycopg2
    except ImportError:
        logger.warning("获取POI类型: 缺少psycopg2-binary依赖，使用本地备用数据")
        return {
            "status": "1",
            "info": "使用本地备用数据",
            "types": _TIANDITU_POI_TYPES_FALLBACK,
        }

    # 获取数据库配置
    if not db_config:
        from config import DATABASE_CONFIG

        db_config = DATABASE_CONFIG

    try:
        # 建立数据库连接
        conn = psycopg2.connect(
            host=db_config.get("host"),
            port=db_config.get("port"),
            dbname=db_config.get("database"),
            user=db_config.get("user"),
            password=db_config.get("password"),
        )

        # 查询一级分类（level=1）
        query = """
            SELECT type_code, type_name 
            FROM gis_poi_type_td 
            WHERE level = 1 
            ORDER BY type_code
        """

        with conn.cursor() as cur:
            cur.execute(query)
            primary_types = cur.fetchall()

        # 检查是否有数据
        if not primary_types:
            conn.close()
            logger.info("获取POI类型: 数据库中暂无数据，使用本地备用数据")
            return {
                "status": "1",
                "info": "使用本地备用数据",
                "types": _TIANDITU_POI_TYPES_FALLBACK,
            }

        # 构建类型树结构
        types = []
        for code, name in primary_types:
            # 查询子类型（level=2）
            sub_query = """
                SELECT type_code, type_name 
                FROM gis_poi_type_td 
                WHERE parent_code = %s 
                ORDER BY type_code
            """
            cur.execute(sub_query, (code,))
            subtypes = [{"code": sc, "name": sn} for sc, sn in cur.fetchall()]

            types.append({"code": code, "name": name, "subtypes": subtypes})

        conn.close()
        logger.info("获取POI类型: 从数据库读取成功")
        return {"status": "1", "info": "从数据库读取", "types": types}

    except psycopg2.errors.UndefinedTable:
        # 表不存在，使用本地备用数据
        conn.close()
        logger.info("获取POI类型: 数据库表尚未创建，使用本地备用数据")
        return {
            "status": "1",
            "info": "使用本地备用数据",
            "types": _TIANDITU_POI_TYPES_FALLBACK,
        }
    except Exception as e:
        logger.error(f"获取POI类型: 数据库读取失败: {str(e)}")
        logger.info("获取POI类型: 使用本地备用数据")
        return {
            "status": "1",
            "info": "使用本地备用数据",
            "types": _TIANDITU_POI_TYPES_FALLBACK,
        }


def _save_poi_types_to_db(types_data, provider, db_config, type_table):
    """
    将POI类型数据保存到数据库（覆盖写入，先删除旧表再重建）

    Args:
        types_data (dict): POI类型数据，需包含status和types字段
        provider (str): 数据源标识，如 'amap' 或 'tianditu'
        db_config (dict): 数据库配置字典
        type_table (str): 目标表名

    Returns:
        int: 成功入库的记录数，失败返回0
    """
    try:
        import psycopg2
        from psycopg2.extras import execute_values
    except ImportError:
        logger.error(
            "POI类型入库: 缺少psycopg2-binary依赖，请先安装: pip install psycopg2-binary"
        )
        return 0

    # 验证数据有效性
    if types_data.get("status") != "1":
        logger.error("POI类型入库: POI类型数据无效，无法入库")
        return 0

    types = types_data.get("types", [])
    if not types:
        logger.warning("POI类型入库: 没有POI类型数据需要入库")
        return 0

    try:
        # 建立数据库连接
        conn = psycopg2.connect(
            host=db_config.get("host"),
            port=db_config.get("port"),
            dbname=db_config.get("database"),
            user=db_config.get("user"),
            password=db_config.get("password"),
        )

        # 创建表（如果存在则删除重建）
        table_name = type_table
        drop_sql = f'DROP TABLE IF EXISTS "{table_name}" CASCADE;'
        create_table_sql = f'''
        CREATE TABLE "{table_name}" (
            id BIGSERIAL PRIMARY KEY,
            provider VARCHAR(32) NOT NULL,
            type_code VARCHAR(32) NOT NULL,
            type_name VARCHAR(128) NOT NULL,
            parent_code VARCHAR(32),
            level INT NOT NULL DEFAULT 1,
            created_at TIMESTAMPTZ DEFAULT now(),
            UNIQUE (provider, type_code)
        );
        CREATE INDEX "idx_{table_name}_provider" ON "{table_name}" (provider);
        CREATE INDEX "idx_{table_name}_type_code" ON "{table_name}" (type_code);
        '''

        with conn.cursor() as cur:
            cur.execute(drop_sql)
            cur.execute(create_table_sql)
        conn.commit()

        # 添加表注释和字段注释
        provider_name = "高德" if provider == "amap" else "天地图"
        comment_sql = f'''
        COMMENT ON TABLE "{table_name}" IS 'POI类型表（{provider_name}）';
        COMMENT ON COLUMN "{table_name}".id IS '主键ID';
        COMMENT ON COLUMN "{table_name}".provider IS '数据源标识（amap/tianditu）';
        COMMENT ON COLUMN "{table_name}".type_code IS '类型编码';
        COMMENT ON COLUMN "{table_name}".type_name IS '类型名称';
        COMMENT ON COLUMN "{table_name}".parent_code IS '父类型编码（二级分类）';
        COMMENT ON COLUMN "{table_name}".level IS '层级（1=一级分类，2=二级分类）';
        COMMENT ON COLUMN "{table_name}".created_at IS '创建时间';
        '''
        with conn.cursor() as cur:
            cur.execute(comment_sql)
        conn.commit()

        logger.info(f"POI类型入库: 表 {table_name} 已创建（带注释）")

        # 准备插入数据
        rows = []
        for item in types:
            code = item.get("code", "")
            name = item.get("name", "")
            # 一级分类
            rows.append((provider, code, name, None, 1))

            # 二级分类
            subtypes = item.get("subtypes", [])
            for sub in subtypes:
                sub_code = sub.get("code", "")
                sub_name = sub.get("name", "")
                rows.append((provider, sub_code, sub_name, code, 2))

        # 批量插入数据
        insert_sql = f'''
            INSERT INTO "{table_name}" (provider, type_code, type_name, parent_code, level)
            VALUES %s
        '''

        with conn.cursor() as cur:
            execute_values(cur, insert_sql, rows)
        conn.commit()

        count = len(rows)
        logger.info(f"POI类型入库: 成功入库 {count} 条")
        logger.info(f"POI类型入库: 入库表: {table_name}")

        conn.close()
        return count
    except Exception as e:
        logger.error(f"POI类型入库: 入库失败: {str(e)}")
        return 0


def _print_poi_types(types_data, provider):
    """
    将POI类型列表输出到日志文件

    Args:
        types_data (dict): POI类型数据字典
        provider (str): 数据源名称，如 '高德' 或 '天地图'
    """
    logger.info(f"=== {provider} POI类型列表 ===")

    # 检查数据状态
    if types_data.get("status") != "1":
        logger.error(f"获取类型列表失败: {types_data.get('info', 'Unknown error')}")
        return

    # 获取类型列表
    types = types_data.get("types", [])
    if not types:
        logger.info("暂无POI类型数据")
        return

    # 将类型树写入日志
    for item in types:
        code = item.get("code", "")
        name = item.get("name", "")
        logger.info(f"[{code}] {name}")

        # 写入子类型
        subtypes = item.get("subtypes", [])
        if subtypes:
            for sub in subtypes:
                sub_code = sub.get("code", "")
                sub_name = sub.get("name", "")
                logger.info(f"  └── [{sub_code}] {sub_name}")
    logger.info(f"共 {len(types)} 个一级分类")


def _normalize_keywords(keywords):
    """
    标准化keywords参数：如果为 'all' 或 '全部'（支持带引号或前后空格），返回 None 以获取所有POI类型。
    """
    if keywords:
        # 去除前后空格和可能的引号
        normalized = keywords.strip().strip("'\"")
        # 判断是否为"全部"类型
        if normalized.lower() in ["all", "全部"]:
            return None
    return keywords


def _is_all_keywords(keywords):
    if not keywords:
        return False
    normalized = keywords.strip().strip("'\"")
    return normalized.lower() in ["all", "全部"]


def _extract_tianditu_search_keywords(types_data):
    """
    从天地图 POI 类型数据中提取关键词，用于全类型循环搜索。
    """
    if types_data.get("status") != "1":
        return []

    keywords = []
    for item in types_data.get("types", []):
        name = item.get("name")
        if name:
            keywords.append(name)
        for sub in item.get("subtypes", []):
            sub_name = sub.get("name")
            if sub_name:
                keywords.append(sub_name)

    return list(dict.fromkeys(keywords))


def _run_poi_crawler(crawler, args, config):
    """
    执行POI数据爬取（高德/天地图通用逻辑）

    POI数据获取支持两种模式，优先级从高到低：
    1. 区域分块模式 (Region Crawl)：通过 --region 指定预定义区域，自动分块爬取
    2. 矩形范围模式 (Bounds Crawl)：通过 --lat-min/--lat-max/--lng-min/--lng-max 指定矩形区域

    Args:
        crawler: POI爬虫实例（AmapPOICrawler 或 TiandituPOICrawler）
        args: 命令行参数对象
        config: 数据源配置字典
    """
    # 标准化keywords参数：支持 'all' 或 '全部' 获取所有POI类型
    keywords = _normalize_keywords(args.keywords)

    # 天地图 all/全部 模式改为按类型表循环搜索具体关键词
    if args.provider == "tianditu" and _is_all_keywords(args.keywords):
        types_data = _get_tianditu_poi_types(config.get("db_config", {}))
        keyword_list = _extract_tianditu_search_keywords(types_data)
        if not keyword_list:
            raise ValueError(
                "天地图全类型模式无法获取搜索关键词，请先执行 --action poitype 获取类型表。"
            )
        print(
            "│ 天地图全类型模式: 按类型表循环搜索 {} 个关键词".format(len(keyword_list))
        )
        keywords = keyword_list

    # 模式一：区域分块爬取（最高优先级）
    # 适用于大规模区域采集，如城市、省份、全国
    # 自动将区域划分为网格，逐块爬取后合并去重
    if args.region:
        print("\n┌─────────────────────────────────────────────────────────┐")
        print("│ 【模式一】区域分块爬取 (Region Crawl)                   │")
        print("├─────────────────────────────────────────────────────────┤")
        print("│ 区域名称: {}".format(args.region))
        print("│ 网格大小: {} 米".format(args.grid_size))
        if args.keywords and keywords is None:
            print("│ 搜索关键词: ALL（获取所有POI类型）")
        elif args.keywords and isinstance(keywords, list):
            print("│ 搜索关键词: ALL（按类型表循环搜索）")
        elif args.keywords:
            print("│ 搜索关键词: {}".format(args.keywords))
        print("└─────────────────────────────────────────────────────────┘")

        crawler.crawl_region(
            region_name=args.region,
            grid_size_m=args.grid_size,
            keywords=keywords,
        )

    # 模式二：矩形范围爬取（唯一其他模式）
    # 适用于自定义矩形区域采集
    elif _has_bounds(args):
        print("\n┌─────────────────────────────────────────────────────────┐")
        print("│ 【模式二】矩形范围爬取 (Bounds Crawl)                   │")
        print("├─────────────────────────────────────────────────────────┤")
        print("│ 纬度范围: {:.4f} ~ {:.4f}".format(args.lat_min, args.lat_max))
        print("│ 经度范围: {:.4f} ~ {:.4f}".format(args.lng_min, args.lng_max))
        if args.keywords and keywords is None:
            print("│ 搜索关键词: ALL（获取所有POI类型）")
        elif args.keywords and isinstance(keywords, list):
            print("│ 搜索关键词: ALL（按类型表循环搜索）")
        elif args.keywords:
            print("│ 搜索关键词: {}".format(args.keywords))
        print("└─────────────────────────────────────────────────────────┘")

        crawler.crawl_bounds(
            lat_min=args.lat_min,
            lat_max=args.lat_max,
            lng_min=args.lng_min,
            lng_max=args.lng_max,
            keywords=keywords,
        )

    # 未指定有效模式
    else:
        print("\n❌ 请指定有效的搜索模式：")
        print("   - 区域分块模式：--region <区域名称>")
        print("   - 矩形范围模式：--lat-min --lat-max --lng-min --lng-max")
        raise ValueError("未指定有效的POI搜索模式")


def handle_poi_category(args):
    """处理POI分类"""
    provider = args.provider

    if provider == "amap":
        print("=" * 60)
        print("Amap POI Module")
        print("=" * 60)

        if args.action == "poitype":
            print("\n【操作类型】: Get POI Types")
            types_data = _get_amap_poi_types(
                AMAP_CONFIG.get("db_config", {}), AMAP_CONFIG.get("api_key")
            )
            data_source = types_data.get("info", "未知来源")
            print(f"【数据来源】: {data_source}")
            _print_poi_types(types_data, "高德")

            if args.save_to_db:
                table_name = AMAP_CONFIG.get("type_table", "gis_poi_type_gd")
                count = _save_poi_types_to_db(
                    types_data, "amap", AMAP_CONFIG.get("db_config", {}), table_name
                )
                if count > 0:
                    print(
                        f"\n【入库结果】: ✅ 入库成功，共 {count} 条（表名: {table_name}）"
                    )
                else:
                    print("\n【入库结果】: ❌ 入库失败")

        elif args.action == "poidata":
            print("\n【操作类型】: Get POI Data")
            crawler = AmapPOICrawler(AMAP_CONFIG)
            try:
                # 使用通用爬取逻辑处理区域分块和矩形范围模式
                _run_poi_crawler(crawler, args, AMAP_CONFIG)
                print("\n✅ SUCCESS!")
            except Exception as e:
                print("\n❌ FAILED: {}".format(e))

    elif provider == "tianditu":
        print("=" * 60)
        print("Tianditu POI Module")
        print("=" * 60)

        if args.action == "poitype":
            print("\n【操作类型】: Get POI Types")
            types_data = _get_tianditu_poi_types(TIANDITU_CONFIG.get("db_config", {}))
            data_source = types_data.get("info", "未知来源")
            print(f"【数据来源】: {data_source}")
            if data_source == "使用本地备用数据":
                print(
                    f"【提示】: 天地图POI类型数据来自本地预设，共 {len(types_data.get('types', []))} 个一级分类"
                )
            _print_poi_types(types_data, "天地图")

            if args.save_to_db:
                table_name = TIANDITU_CONFIG.get("type_table", "gis_poi_type_td")
                count = _save_poi_types_to_db(
                    types_data,
                    "tianditu",
                    TIANDITU_CONFIG.get("db_config", {}),
                    table_name,
                )
                if count > 0:
                    print(
                        f"\n【入库结果】: ✅ 入库成功，共 {count} 条（表名: {table_name}）"
                    )
                else:
                    print("\n【入库结果】: ❌ 入库失败")

        elif args.action == "poidata":
            print("\n【操作类型】: Get POI Data")
            crawler = TiandituPOICrawler(TIANDITU_CONFIG)
            try:
                # 使用通用爬取逻辑处理三种模式
                _run_poi_crawler(crawler, args, TIANDITU_CONFIG)
                print("\n✅ SUCCESS!")
            except Exception as e:
                print("\n❌ FAILED: {}".format(e))


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
        print(
            "Center: ({}, {}), Radius: {} km".format(
                args.lat or DJI_CONFIG.get("default_lat", 34.72),
                args.lng or DJI_CONFIG.get("default_lng", 113.62),
                args.radius or DJI_CONFIG.get("default_radius", 50),
            )
        )

    # 检查是否需要入库
    if args.save_dji_to_db:
        print("Save to DB: Yes")
        DJI_CONFIG["save_to_db"] = True

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
        description="DJI禁飞区与POI爬虫", formatter_class=argparse.RawTextHelpFormatter
    )

    # 一级分类
    parser.add_argument(
        "--category",
        type=str,
        required=True,
        choices=["poi", "dji"],
        help="模块分类:\n  poi - POI数据爬取\n  dji - DJI禁飞区爬取",
    )

    # POI模块参数
    parser.add_argument(
        "--provider",
        type=str,
        choices=["amap", "tianditu"],
        help="POI数据源（仅poi分类）:\n  amap - 高德地图\n  tianditu - 天地图",
    )

    parser.add_argument(
        "--action",
        type=str,
        choices=["poitype", "poidata"],
        help="POI操作类型（仅poi分类）:\n  poitype - 获取POI类型列表\n  poidata - 获取POI数据",
    )

    # 范围搜索参数（POI模块专用）
    parser.add_argument("--lat-min", type=float, help="范围最小纬度（矩形范围模式）")
    parser.add_argument("--lat-max", type=float, help="范围最大纬度（矩形范围模式）")
    parser.add_argument("--lng-min", type=float, help="范围最小经度（矩形范围模式）")
    parser.add_argument("--lng-max", type=float, help="范围最大经度（矩形范围模式）")

    # DJI专用参数
    parser.add_argument("--drone", type=str, help="DJI无人机型号slug")
    parser.add_argument("--lat", type=float, help="中心纬度（仅DJI模块）")
    parser.add_argument("--lng", type=float, help="中心经度（仅DJI模块）")
    parser.add_argument("--radius", type=float, help="搜索半径(公里)（仅DJI模块）")
    parser.add_argument(
        "--save-dji-to-db",
        action="store_true",
        help="将禁飞区数据保存到数据库（仅DJI模块）",
    )

    # POI专用参数
    parser.add_argument(
        "--keywords",
        type=str,
        help="POI搜索关键词；高德支持 all 或 全部 获取所有类型，天地图支持 all/全部 全类型模式，但建议直接使用具体关键词，例如 学校/医院/公园。",
    )
    parser.add_argument(
        "--save-poi-to-db",
        action="store_true",
        help="将POI类型数据保存到数据库（仅poitype操作）",
    )

    # 区域分块参数
    parser.add_argument("--region", type=str, help='区域名称（如 "河南省"、"郑州市"）')
    parser.add_argument(
        "--grid-size",
        type=float,
        default=1000,
        help="网格大小（默认：DJI用公里，POI用米）",
    )

    args = parser.parse_args()

    # 参数校验
    if args.category == "poi":
        if not args.provider:
            parser.error("使用poi分类时必须指定--provider")
        if not args.action:
            parser.error("使用poi分类时必须指定--action")

    # 路由分发
    if args.category == "poi":
        handle_poi_category(args)
    elif args.category == "dji":
        handle_dji_category(args)


if __name__ == "__main__":
    main()
