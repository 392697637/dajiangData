<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
 xsi:schemaLocation="http://www.opengis.net/sld StyledLayerDescriptor.xsd"
 xmlns="http://www.opengis.net/sld"
 xmlns:ogc="http://www.opengis.net/ogc"
 xmlns:xlink="http://www.w3.org/1999/xlink"
 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <NamedLayer>
    <Name>shifeiqu</Name>
    <UserStyle>
      <Title>shifeiqu</Title>
      <Abstract>A style that draws shifeiqu polygons</Abstract>
      <FeatureTypeStyle>
        <Rule>
          <Name>shifeiqu_fill_with_outline</Name>
          <Title>Shifeiqu Fill With Outline</Title>
          <Abstract>Show green fill and outline at all scales</Abstract>
          <PolygonSymbolizer>
            <Fill>
              <CssParameter name="fill">#8CF58A</CssParameter>
              <CssParameter name="fill-opacity">0.5</CssParameter>
            </Fill>
            <Stroke>
              <CssParameter name="stroke">#10A82A</CssParameter>
              <CssParameter name="stroke-opacity">1</CssParameter>
              <CssParameter name="stroke-width">0.5</CssParameter>
            </Stroke>
          </PolygonSymbolizer>
        </Rule>
      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>
