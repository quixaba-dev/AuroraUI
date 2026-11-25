# Aurora UI 2.0 — Theming Guide

## Built-in Presets
- `Aurora Dark` (default)
- `Aurora Light`
- `Midnight`
- `Graphite`
- `Lavender`
- `Crimson`
- `Ocean`
- `Custom`

## Design Tokens
- **Colors**: `Background`, `Surface`, `ElevatedSurface`, `HoverSurface`, `ActiveSurface`, `PrimaryText`, `SecondaryText`, `MutedText`, `Accent`, `AccentHover`, `Success`, `Warning`, `Danger`, `Border`, `Focus`, `Shadow`
- **Numbers**: `BackgroundTransparency`, `SurfaceTransparency`, `BorderThickness`, `ShadowTransparency`, `RadiusSmall`, `RadiusMedium`, `RadiusLarge`, `RadiusPill`, `SpacingXS/SM/MD/LG`, `TextSizeXS/SM/MD/LG/XL`, `AnimFast/Normal/Slow`
- **Fonts**: `FontRegular`, `FontMedium`, `FontBold`, `FontMono`

## Programmatic Usage
```lua
Aurora:ApplyPreset("Midnight")
Aurora:SetAccent(Color3.fromRGB(0, 200, 170))
Aurora:SetThemeToken("RadiusMedium", 10)

local json = Aurora:ExportTheme()
local ok, nameOrErr = Aurora:ImportTheme(json)
```
