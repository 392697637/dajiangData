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
        
        except requests.exceptions.RequestException as e:
            raise Exception(f"请求失败: {str(e)}")
    
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