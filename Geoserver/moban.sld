<?xml version="1.0" encoding="UTF-8"?>
<!-- SLD根节点：定义GeoServer样式文档，使用SLD 1.0.0规范。 -->
<StyledLayerDescriptor version="1.0.0" xmlns="http://www.opengis.net/sld" xmlns:ogc="http://www.opengis.net/ogc" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.opengis.net/sld http://schemas.opengis.net/sld/1.0.0/StyledLayerDescriptor.xsd">
  <!-- NamedLayer节点：一个命名图层的样式容器。 -->
  <NamedLayer>
    <!-- Name节点：样式名称，复制模板后建议改成实际样式名。 -->
    <Name>moban</Name>
    <!-- UserStyle节点：用户自定义样式内容。 -->
    <UserStyle>
      <!-- Title节点：样式标题，GeoServer界面中可见。 -->
      <Title>moban</Title>
      <!-- FeatureTypeStyle节点：用于存放一个或多个渲染规则。 -->
      <FeatureTypeStyle>
        <!-- Rule节点：一条渲染规则，可包含筛选条件、比例尺限制和符号样式。 -->
        <Rule>
          <!-- Name节点：规则名称，按业务可改成禁飞区、管控区、试飞区等。 -->
          <Name>template_rule</Name>
          <!-- MinScaleDenominator节点：最小显示比例尺分母，值越小越接近放大状态。 -->
          <MinScaleDenominator>1</MinScaleDenominator>
          <!-- MaxScaleDenominator节点：最大显示比例尺分母，超过该比例尺后不渲染。 -->
          <MaxScaleDenominator>1500000</MaxScaleDenominator>
          <!-- PolygonSymbolizer节点：面样式，适用于Polygon或MultiPolygon数据。 -->
          <PolygonSymbolizer>
            <!-- Fill节点：面内部填充样式。 -->
            <Fill>
              <!-- CssParameter节点：fill表示填充颜色，使用十六进制颜色值。 -->
              <CssParameter name="fill">#32CD32</CssParameter>
              <!-- CssParameter节点：fill-opacity表示填充透明度，0完全透明，1完全不透明。 -->
              <CssParameter name="fill-opacity">0.22</CssParameter>
            <!-- /Fill节点：结束面填充样式。 -->
            </Fill>
            <!-- Stroke节点：面边线样式。 -->
            <Stroke>
              <!-- CssParameter节点：stroke表示边线颜色。 -->
              <CssParameter name="stroke">#32CD32</CssParameter>
              <!-- CssParameter节点：stroke-opacity表示边线透明度，0完全透明，1完全不透明。 -->
              <CssParameter name="stroke-opacity">1</CssParameter>
              <!-- CssParameter节点：stroke-width表示边线宽度。 -->
              <CssParameter name="stroke-width">0.5</CssParameter>
              <!-- CssParameter节点：stroke-linejoin表示边线拐角样式，可用round、mitre、bevel。 -->
              <CssParameter name="stroke-linejoin">round</CssParameter>
              <!-- CssParameter节点：stroke-linecap表示线端点样式，可用round、butt、square。 -->
              <CssParameter name="stroke-linecap">round</CssParameter>
              <!-- 可选CssParameter节点：stroke-dasharray表示虚线样式，例如6 3表示画6空3。 -->
              <!-- <CssParameter name="stroke-dasharray">6 3</CssParameter> -->
            <!-- /Stroke节点：结束面边线样式。 -->
            </Stroke>
          <!-- /PolygonSymbolizer节点：结束面符号样式。 -->
          </PolygonSymbolizer>
          <!-- 可选Filter节点：属性筛选示例，没有分类字段时不要启用。 -->
          <!-- <ogc:Filter> -->
          <!-- 可选PropertyIsEqualTo节点：表示字段值等于指定值时才渲染。 -->
          <!-- <ogc:PropertyIsEqualTo> -->
          <!-- 可选PropertyName节点：字段名，例如fence_type、zone_type、name。 -->
          <!-- <ogc:PropertyName>字段名</ogc:PropertyName> -->
          <!-- 可选Literal节点：字段值，例如3或试飞区。 -->
          <!-- <ogc:Literal>字段值</ogc:Literal> -->
          <!-- 可选/PropertyIsEqualTo节点：结束相等判断。 -->
          <!-- </ogc:PropertyIsEqualTo> -->
          <!-- 可选/Filter节点：结束属性筛选。 -->
          <!-- </ogc:Filter> -->
          <!-- 可选LineSymbolizer节点：线图层样式开始，线数据需要时取消注释。 -->
          <!-- <LineSymbolizer> -->
          <!-- 可选Stroke节点：线样式的边线设置。 -->
          <!-- <Stroke> -->
          <!-- 可选CssParameter节点：线颜色。 -->
          <!-- <CssParameter name="stroke">#32CD32</CssParameter> -->
          <!-- 可选CssParameter节点：线透明度。 -->
          <!-- <CssParameter name="stroke-opacity">1</CssParameter> -->
          <!-- 可选CssParameter节点：线宽度。 -->
          <!-- <CssParameter name="stroke-width">2</CssParameter> -->
          <!-- 可选/Stroke节点：结束线样式。 -->
          <!-- </Stroke> -->
          <!-- 可选/LineSymbolizer节点：结束线符号样式。 -->
          <!-- </LineSymbolizer> -->
          <!-- 可选PointSymbolizer节点：点图层样式开始，点数据需要时取消注释。 -->
          <!-- <PointSymbolizer> -->
          <!-- 可选Graphic节点：点符号图形容器。 -->
          <!-- <Graphic> -->
          <!-- 可选Mark节点：使用内置符号绘制点。 -->
          <!-- <Mark> -->
          <!-- 可选WellKnownName节点：点形状，可用circle、square、triangle、star、cross、x。 -->
          <!-- <WellKnownName>circle</WellKnownName> -->
          <!-- 可选Fill节点：点内部填充样式。 -->
          <!-- <Fill> -->
          <!-- 可选CssParameter节点：点填充颜色。 -->
          <!-- <CssParameter name="fill">#32CD32</CssParameter> -->
          <!-- 可选/Fill节点：结束点填充样式。 -->
          <!-- </Fill> -->
          <!-- 可选/Mark节点：结束内置点符号。 -->
          <!-- </Mark> -->
          <!-- 可选Size节点：点符号大小。 -->
          <!-- <Size>8</Size> -->
          <!-- 可选/Graphic节点：结束点图形容器。 -->
          <!-- </Graphic> -->
          <!-- 可选/PointSymbolizer节点：结束点符号样式。 -->
          <!-- </PointSymbolizer> -->
          <!-- 可选TextSymbolizer节点：文字标注开始，有名称字段时可取消注释。 -->
          <!-- <TextSymbolizer> -->
          <!-- 可选Label节点：标注内容容器。 -->
          <!-- <Label> -->
          <!-- 可选PropertyName节点：标注字段名，常用name。 -->
          <!-- <ogc:PropertyName>name</ogc:PropertyName> -->
          <!-- 可选/Label节点：结束标注内容。 -->
          <!-- </Label> -->
          <!-- 可选Font节点：标注字体样式。 -->
          <!-- <Font> -->
          <!-- 可选CssParameter节点：字体名称。 -->
          <!-- <CssParameter name="font-family">Microsoft YaHei</CssParameter> -->
          <!-- 可选CssParameter节点：字体大小。 -->
          <!-- <CssParameter name="font-size">12</CssParameter> -->
          <!-- 可选/Font节点：结束字体样式。 -->
          <!-- </Font> -->
          <!-- 可选Halo节点：文字描边光晕，提高可读性。 -->
          <!-- <Halo> -->
          <!-- 可选Radius节点：文字光晕半径。 -->
          <!-- <Radius>1.5</Radius> -->
          <!-- 可选Fill节点：文字光晕填充样式。 -->
          <!-- <Fill> -->
          <!-- 可选CssParameter节点：文字光晕颜色。 -->
          <!-- <CssParameter name="fill">#FFFFFF</CssParameter> -->
          <!-- 可选/Fill节点：结束文字光晕填充。 -->
          <!-- </Fill> -->
          <!-- 可选/Halo节点：结束文字光晕。 -->
          <!-- </Halo> -->
          <!-- 可选Fill节点：文字颜色样式。 -->
          <!-- <Fill> -->
          <!-- 可选CssParameter节点：文字颜色。 -->
          <!-- <CssParameter name="fill">#1B5E20</CssParameter> -->
          <!-- 可选/Fill节点：结束文字颜色样式。 -->
          <!-- </Fill> -->
          <!-- 可选/TextSymbolizer节点：结束文字标注。 -->
          <!-- </TextSymbolizer> -->
        <!-- /Rule节点：结束当前渲染规则。 -->
        </Rule>
        <!-- 可选Rule节点：兜底规则开始，可用于隐藏未命中前面Filter的数据。 -->
        <!-- <Rule> -->
        <!-- 可选Name节点：兜底规则名称。 -->
        <!-- <Name>hide_other_features</Name> -->
        <!-- 可选ElseFilter节点：匹配前面规则没有命中的其他要素。 -->
        <!-- <ElseFilter/> -->
        <!-- 可选PolygonSymbolizer节点：透明面样式。 -->
        <!-- <PolygonSymbolizer> -->
        <!-- 可选Fill节点：透明填充。 -->
        <!-- <Fill> -->
        <!-- 可选CssParameter节点：透明填充颜色。 -->
        <!-- <CssParameter name="fill">#FFFFFF</CssParameter> -->
        <!-- 可选CssParameter节点：填充透明度为0，表示完全透明。 -->
        <!-- <CssParameter name="fill-opacity">0</CssParameter> -->
        <!-- 可选/Fill节点：结束透明填充。 -->
        <!-- </Fill> -->
        <!-- 可选Stroke节点：透明边线。 -->
        <!-- <Stroke> -->
        <!-- 可选CssParameter节点：透明边线颜色。 -->
        <!-- <CssParameter name="stroke">#FFFFFF</CssParameter> -->
        <!-- 可选CssParameter节点：边线透明度为0，表示完全透明。 -->
        <!-- <CssParameter name="stroke-opacity">0</CssParameter> -->
        <!-- 可选CssParameter节点：边线宽度为0。 -->
        <!-- <CssParameter name="stroke-width">0</CssParameter> -->
        <!-- 可选/Stroke节点：结束透明边线。 -->
        <!-- </Stroke> -->
        <!-- 可选/PolygonSymbolizer节点：结束透明面样式。 -->
        <!-- </PolygonSymbolizer> -->
        <!-- 可选/Rule节点：结束兜底规则。 -->
        <!-- </Rule> -->
      <!-- /FeatureTypeStyle节点：结束要素样式集合。 -->
      </FeatureTypeStyle>
    <!-- /UserStyle节点：结束用户自定义样式。 -->
    </UserStyle>
  <!-- /NamedLayer节点：结束命名图层。 -->
  </NamedLayer>
<!-- /StyledLayerDescriptor节点：结束SLD样式文档。 -->
</StyledLayerDescriptor>
