<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
  xmlns="http://www.opengis.net/sld"
  xmlns:ogc="http://www.opengis.net/ogc"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <NamedLayer>
    <Name>contour_multi_level</Name>
    <UserStyle>
      <Title>Contour Multi Level</Title>
      <FeatureTypeStyle>

        <Rule>
          <Name>index_100m</Name>
          <Title>100m Index Contour</Title>
          <ogc:Filter>
            <ogc:PropertyIsEqualTo>
              <ogc:Function name="IEEEremainder">
                <ogc:PropertyName>elevation</ogc:PropertyName>
                <ogc:Literal>100</ogc:Literal>
              </ogc:Function>
              <ogc:Literal>0</ogc:Literal>
            </ogc:PropertyIsEqualTo>
          </ogc:Filter>
          <LineSymbolizer>
            <Stroke>
              <CssParameter name="stroke">#7A4F2A</CssParameter>
              <CssParameter name="stroke-width">1.3</CssParameter>
              <CssParameter name="stroke-opacity">0.9</CssParameter>
            </Stroke>
          </LineSymbolizer>
        </Rule>

        <Rule>
          <Name>index_50m</Name>
          <Title>50m Index Contour</Title>
          <ogc:Filter>
            <ogc:And>
              <ogc:PropertyIsEqualTo>
                <ogc:Function name="IEEEremainder">
                  <ogc:PropertyName>elevation</ogc:PropertyName>
                  <ogc:Literal>50</ogc:Literal>
                </ogc:Function>
                <ogc:Literal>0</ogc:Literal>
              </ogc:PropertyIsEqualTo>
              <ogc:PropertyIsNotEqualTo>
                <ogc:Function name="IEEEremainder">
                  <ogc:PropertyName>elevation</ogc:PropertyName>
                  <ogc:Literal>100</ogc:Literal>
                </ogc:Function>
                <ogc:Literal>0</ogc:Literal>
              </ogc:PropertyIsNotEqualTo>
            </ogc:And>
          </ogc:Filter>
          <LineSymbolizer>
            <Stroke>
              <CssParameter name="stroke">#9C7041</CssParameter>
              <CssParameter name="stroke-width">0.85</CssParameter>
              <CssParameter name="stroke-opacity">0.78</CssParameter>
            </Stroke>
          </LineSymbolizer>
        </Rule>

        <Rule>
          <Name>normal_10m</Name>
          <Title>10m Normal Contour</Title>
          <ElseFilter/>
          <LineSymbolizer>
            <Stroke>
              <CssParameter name="stroke">#C7A06A</CssParameter>
              <CssParameter name="stroke-width">0.45</CssParameter>
              <CssParameter name="stroke-opacity">0.6</CssParameter>
            </Stroke>
          </LineSymbolizer>
        </Rule>

      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>