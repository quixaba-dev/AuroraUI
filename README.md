# Aurora UI 2.0

A commercial-grade, **single-file** Luau UI framework engineered for Roblox executors and official Roblox environments with zero external dependencies.

## Features

- **Single-File Distribution**: Everything lives in [`Aurora.luau`](Aurora.luau). Load via `loadstring`, `loadfile`, or direct execution.
- **Environment-Independent Core**: Capability detection isolates `gethui`, `getgenv`, `CoreGui`, `PlayerGui`, `setclipboard`, and filesystem APIs (`readfile`, `writefile`, `listfiles`, `delfile`) with automatic in-memory / Attribute fallbacks.
- **Reactive Theme Engine**: Centralized design tokens (surfaces, text, accents, borders, radii, spacing, typography, animation timings), 8 built-in presets (`Aurora Dark`, `Aurora Light`, `Midnight`, `Graphite`, `Lavender`, `Crimson`, `Ocean`, `Custom`), custom theme CRUD, and validated JSON import/export.
- **Live Theme Editor**: Built-in `Window:AddSettingsTab()` for live editing of colors, transparency, corner radius, borders, fonts, layout density, UI scale, sidebar position, animation speed, reduced motion, and config profiles.
- **25+ Components**: `Label`, `Paragraph`, `Divider`, `Image`, `ProgressBar`, `LoadingIndicator`, `EmptyState`, `Button`, `Toggle`, `Checkbox`, `RadioGroup`, `Slider`, `Dropdown`, `MultiDropdown`, `SearchBar`, `ColorPicker` (HSV + HEX), `Input`, `TextArea`, `Keybind`, `KeybindList`, `ProfileSelector`, `CollapsibleSection`, `Card`, `Groupbox`, `Tooltip`, `ContextMenu`, `ConfirmDialog`, `Notification`, `TabBadge`.
- **Multi-Window Application Shell**: Draggable, resizable, minimizable windows with `DisplayOrder` focus management, persistent positioning, collapsible/searchable sidebar, and mobile touch FAB.
- **Schema-Versioned Configs**: Profile save/load/delete/rename, JSON export/import, strict validation, and automatic v1.0 flat-table migration.

## Quick Start

```lua
local Aurora = loadstring(game:HttpGet("YOUR_RAW_URL/Aurora.luau"))()

local Window = Aurora:CreateWindow({
	Title = "My App",
	Subtitle = "v2.0",
	ToggleKey = Enum.KeyCode.RightShift,
	ConfigFolder = "MyApp",
})

local Tab = Window:AddTab({ Name = "General", Icon = "◆" })
local Sec = Tab:AddSection("Options")

Sec:AddToggle({
	Name = "Enable Feature",
	Default = true,
	Flag = "feature_enabled",
	Callback = function(value)
		print("Feature:", value)
	end,
})

Window:AddSettingsTab()
```

## Documentation

- [API Reference](docs/API_REFERENCE.md)
- [Components Guide](docs/COMPONENTS.md)
- [Theming Guide](docs/THEMING.md)
- [Configuration Guide](docs/CONFIGURATION.md)
- [Environment Compatibility](docs/ENVIRONMENTS.md)
