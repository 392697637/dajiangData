-- 点 Point，XYZ；坐标顺序为 [X经度, Y纬度, Z高度]
'{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[115.984,36.454,120]}}'

-- 线 LineString，XYZ；至少需要2个点；每个点坐标顺序为 [X经度, Y纬度, Z高度]
'{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}'

-- 面 Polygon，XYZ；坐标环必须首尾闭合，即最后一个点必须和第一个点一致
'{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[115.984,36.454,120],[115.990,36.454,120],[115.990,36.458,120],[115.984,36.458,120],[115.984,36.454,120]]]}}'

-- 多点 MultiPoint，XYZ；包含多个点；每个点坐标顺序为 [X经度, Y纬度, Z高度]
'{"type":"Feature","properties":{},"geometry":{"type":"MultiPoint","coordinates":[[115.984,36.454,120],[115.990,36.458,120]]}}'

-- 多线 MultiLineString，XYZ；包含多条线；每条线至少需要2个点
'{"type":"Feature","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[115.984,36.454,120],[115.990,36.458,120]],[[115.992,36.460,130],[115.998,36.466,130]]]}}'

-- 多面 MultiPolygon，XYZ；包含多个面；每个面的每个坐标环都必须首尾闭合
'{"type":"Feature","properties":{},"geometry":{"type":"MultiPolygon","coordinates":[[[[115.984,36.454,120],[115.990,36.454,120],[115.990,36.458,120],[115.984,36.458,120],[115.984,36.454,120]]],[[[115.992,36.460,130],[115.998,36.460,130],[115.998,36.466,130],[115.992,36.466,130],[115.992,36.460,130]]]]}}'