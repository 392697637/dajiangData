# -*- coding: utf-8 -*-
"""
地理相关工具函数

此模块提供坐标转换和几何图形处理的工具函数，主要用于：
1. 角度与弧度转换
2. 将中心点和半径转换为矩形区域（用于API请求）
3. 将圆形转换为近似多边形（用于GeoJSON输出）
4. 根据shape类型创建GeoJSON几何对象

使用方式:
    from src.utils.geo import latlng_to_rectangle, create_geometry
"""

import math


def deg2rad(deg):
    """
    角度转弧度
    
    将角度值转换为弧度值，用于三角函数计算。
    
    Args:
        deg (float): 角度值
        
    Returns:
        float: 弧度值
        
    Example:
        >>> deg2rad(180)
        3.141592653589793
    """
    return deg * (math.pi / 180.0)


def latlng_to_rectangle(lat, lng, radius_km):
    """
    将中心点和半径转换为矩形区域
    
    根据给定的中心点坐标和搜索半径，计算出一个矩形区域的边界坐标。
    该矩形区域用于DJI禁飞区API的矩形查询参数。
    
    计算原理:
    - 地球表面1度纬度约等于111公里
    - 经度的距离随纬度变化，需要乘以cos(lat)进行修正
    
    Args:
        lat (float): 中心点纬度
        lng (float): 中心点经度
        radius_km (float): 搜索半径（公里）
        
    Returns:
        tuple: (ltlat, ltlng, rblat, rblng)
            - ltlat: 左上角纬度
            - ltlng: 左上角经度
            - rblat: 右下角纬度
            - rblng: 右下角经度
        
    Example:
        >>> latlng_to_rectangle(34.72, 113.62, 50)
        (35.17045045, 112.87665583, 34.26954955, 114.36334417)
    """
    # 计算纬度方向的增量（1度 ≈ 111公里）
    delta_lat = radius_km / 111.0
    
    # 计算经度方向的增量（需要考虑纬度的影响）
    delta_lng = radius_km / (111.0 * abs(math.cos(deg2rad(lat))))
    
    # 计算矩形四个边界点的坐标
    ltlat = lat + delta_lat  # 左上角纬度
    ltlng = lng - delta_lng  # 左上角经度
    rblat = lat - delta_lat  # 右下角纬度
    rblng = lng + delta_lng  # 右下角经度
    
    return (ltlat, ltlng, rblat, rblng)


def circle_to_polygon(lat, lng, radius_m):
    """
    将圆形转换为近似多边形
    
    将给定中心点和半径的圆形转换为一个36边的正多边形，用于GeoJSON输出。
    GeoJSON标准不支持圆形类型，因此需要转换为多边形。
    
    Args:
        lat (float): 中心点纬度
        lng (float): 中心点经度
        radius_m (float): 半径（米）
        
    Returns:
        dict: GeoJSON Polygon格式的几何对象
        
    Example:
        >>> circle_to_polygon(34.72, 113.62, 1000)
        {
            "type": "Polygon",
            "coordinates": [[[113.629, 34.72], ...]]
        }
    """
    # 存储多边形顶点
    points = []
    
    # 使用36个顶点近似圆形（每个顶点间隔10度）
    num_points = 36
    
    # 将半径从米转换为度数（1度纬度 ≈ 111000米）
    radius_deg = radius_m / 111000.0
    
    # 生成每个顶点的坐标
    for i in range(num_points):
        # 计算当前顶点的角度（弧度）
        angle = (2 * math.pi * i) / num_points
        
        # 计算经度偏移（需要考虑纬度影响）
        x = lng + radius_deg * math.cos(angle) / math.cos(deg2rad(lat))
        
        # 计算纬度偏移
        y = lat + radius_deg * math.sin(angle)
        
        # 添加顶点坐标
        points.append([x, y])
    
    # 闭合多边形（最后一个点等于第一个点）
    points.append(points[0])
    
    # 返回GeoJSON格式的Polygon对象
    return {
        "type": "Polygon",
        "coordinates": [points]
    }


def create_geometry(item):
    """
    根据shape类型创建GeoJSON geometry
    
    根据DJI API返回的区域数据，创建对应的GeoJSON几何对象。
    支持三种几何类型：多边形、圆形（转换为多边形）、点。
    
    API返回数据格式说明（根据实际返回数据）:
    {
        "area_id": 1791,
        "name": "Xinzheng Airport",
        "type": 10,
        "shape": 2,           // 0:点, 1:多边形, 2:圆形
        "lat": 34.520638,
        "lng": 113.841789,
        "radius": 6000,       // 半径（米）
        "polygon_points": null,
        "sub_areas": [...]    // 子区域数组（可能包含多个多边形）
    }
    
    Args:
        item (dict): DJI API返回的区域数据项
        
    Returns:
        dict or None: GeoJSON几何对象，如果无法解析则返回None
    """
    # 获取形状类型（0:点, 1:多边形, 2:圆形）
    shape_type = item.get("shape", 2)
    
    # 获取坐标和半径信息
    lat = item.get("lat")
    lng = item.get("lng")
    radius = item.get("radius")
    polygon_points = item.get("polygon_points")
    sub_areas = item.get("sub_areas")
    
    # 优先处理子区域（如果有子区域，使用子区域的几何信息）
    if sub_areas and isinstance(sub_areas, list) and len(sub_areas) > 0:
        geometries = []
        for sub_area in sub_areas:
            sub_shape = sub_area.get("shape", 1)
            sub_lat = sub_area.get("lat", lat)
            sub_lng = sub_area.get("lng", lng)
            sub_radius = sub_area.get("radius", radius)
            sub_points = sub_area.get("polygon_points")
            
            if sub_shape == 1 and sub_points:
                # 多边形子区域
                geometries.append({
                    "type": "Polygon",
                    "coordinates": sub_points
                })
            elif sub_shape == 2 and sub_lat and sub_lng and sub_radius:
                # 圆形子区域
                geometries.append(circle_to_polygon(sub_lat, sub_lng, sub_radius))
        
        if geometries:
            if len(geometries) == 1:
                return geometries[0]
            else:
                # 多个子区域，返回MultiPolygon
                return {
                    "type": "MultiPolygon",
                    "coordinates": [g["coordinates"] for g in geometries if g["type"] == "Polygon"]
                }
    
    # 如果没有子区域或子区域为空，使用主区域的几何信息
    if shape_type == 1 and polygon_points:
        # 多边形类型：直接使用返回的多边形顶点
        return {
            "type": "Polygon",
            "coordinates": polygon_points
        }
    elif shape_type == 2 and lat and lng and radius:
        # 圆形类型：转换为近似多边形
        return circle_to_polygon(lat, lng, radius)
    elif lat and lng:
        # 点类型或其他未知类型：创建Point对象
        return {
            "type": "Point",
            "coordinates": [lng, lat]
        }
    
    # 如果无法解析，返回None
    return None


def parse_dji_response(data):
    """
    解析DJI禁飞区API响应数据
    
    将DJI API返回的原始数据转换为GeoJSON格式的features列表。
    
    API响应格式:
    {
        "code": 0,
        "message": {"chinese": "成功", "english": "OK"},
        "data": {
            "areas": [...],  // 禁飞区数组
            "country": "CN",
            "lat": 34.523725,
            "lng": 113.80879,
            "radius": 28406
        }
    }
    
    Args:
        data (dict): DJI API返回的原始数据
        
    Returns:
        list: GeoJSON features列表
    """
    features = []
    
    # 检查API返回状态
    if data.get("code") != 0:
        return features
    
    # 获取禁飞区数据
    areas = data.get("data", {}).get("areas", [])
    
    for item in areas:
        # 创建几何对象
        geometry = create_geometry(item)
        
        if geometry:
            # 构建属性字典
            properties = {
                "area_id": item.get("area_id"),
                "name": item.get("name"),
                "type": item.get("type"),
                "level": item.get("level"),
                "color": item.get("color"),
                "country": item.get("country"),
                "city": item.get("city"),
                "address": item.get("address"),
                "description": item.get("description"),
                "height": item.get("height"),
                "radius": item.get("radius"),
                "begin_at": item.get("begin_at"),
                "end_at": item.get("end_at"),
                "data_source": item.get("data_source"),
                "url": item.get("url")
            }
            
            # 创建Feature对象
            feature = {
                "type": "Feature",
                "geometry": geometry,
                "properties": properties
            }
            
            features.append(feature)
    
    return features