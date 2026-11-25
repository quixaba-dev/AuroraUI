# Aurora UI 2.0 — Configuration Guide

Configurations use **Schema Version 2**, storing:
- `Flags` (component values, `Color3`, `Enum.KeyCode`)
- `Theme` (serialized design tokens)
- `Layout` (density preset, `UIScale`, sidebar width & position)
- `Behavior` (animations, reduced motion, speed, drag/resize, notification position)

## v1.0 Migration
Legacy v1.0 flat flag JSON files (`{ "fov": 90, "showfps": true }`) are automatically detected and migrated to Schema v2 on load/import.

## Programmatic Usage
```lua
Aurora.Config:Save("legit")
Aurora.Config:Load("legit")
Aurora.Config:Rename("legit", "tournament")
Aurora.Config:Delete("old_profile")

local exported = Aurora:ExportConfig()
local ok, err = Aurora:ImportConfig(exported)
```
