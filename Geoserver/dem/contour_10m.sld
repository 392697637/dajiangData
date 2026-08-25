<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
  xmlns="http://www.opengis.net/sld"
  xmlns:ogc="http://www.opengis.net/ogc"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <NamedLayer>
    <Name>contour_10m</Name>
    <UserStyle>
      <Title>Contour 10m</Title>
      <FeatureTypeStyle>
        <Rule>
          <Name>10m_contour</Name>
          <LineSymbolizer>
            <Stroke>
              <CssParameter name="stroke">#C7A06A</CssParameter>
              <CssParameter name="stroke-width">0.45</CssParameter>
              <CssParameter name="stroke-opacity">0.65</CssParameter>
            </Stroke>
          </LineSymbolizer>
        </Rule>
      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>