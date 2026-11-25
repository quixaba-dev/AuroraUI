# Aurora UI 2.0 — API Reference

## Library (`Aurora`)

| Method / Property | Description |
|---|---|
| `Aurora.Version` | `"2.0.0"` |
| `Aurora.Flags` | Global flag value map `[flag] = value` |
| `Aurora.Windows` | Array of active windows |
| `Aurora.Capabilities` | Detected environment capabilities table |
| `Aurora:CreateWindow(opts)` | Creates a new independent window |
| `Aurora:Notify(opts)` | Queues a toast notification (`info`, `success`, `warn`, `error`, or custom `Color`) |
| `Aurora:SetAccent(color3)` | Updates `Accent`, `AccentHover`, and `Focus` reactively |
| `Aurora:ApplyPreset(name)` | Applies a built-in or saved custom theme preset |
| `Aurora:SetThemeToken(token, value)` | Updates any design token reactively |
| `Aurora:ExportTheme()` | Returns current theme as JSON string |
| `Aurora:ImportTheme(json)` | Validates, registers, and applies a theme JSON |
| `Aurora:ExportConfig()` | Returns full v2 config snapshot as JSON string |
| `Aurora:ImportConfig(json)` | Validates/migrates and applies a config JSON |
| `Aurora:SetUIScale(scale)` | Updates `UIScale` across all windows (`0.5`–`2.0`) |
| `Aurora:Destroy()` | Destroys all windows, notifications, inputs, and managers |

## Window (`win`)

| Method | Description |
|---|---|
| `win:AddTab(nameOrOpts)` | Adds a tab (`string` or `{ Name, Description, Icon, Badge }`) |
| `win:AddSettingsTab()` | Adds the full Theme Editor, Layout, Behavior & Profiles tab |
| `win:SetVisible(bool)` | Shows/hides the window with animation |
| `win:Toggle()` | Toggles visibility |
| `win:Minimize(bool?)` | Collapses/restores (or hides if `MinimizeBehavior == "Hide"`) |
| `win:SetSize(w, h)` | Resizes the window within viewport bounds |
| `win:SaveConfig(name)` | Saves active profile and shows notification |
| `win:LoadConfig(name)` | Loads profile and shows notification |
| `win:Confirm(opts)` | Opens a modal `ConfirmDialog` |
| `win:ContextMenu(items, pos?)` | Opens a floating context menu |
| `win:Destroy()` | Unregisters window flags, disconnects all events, destroys GUI |

## Tab (`tab`)

| Method | Description |
|---|---|
| `tab:Select()` | Activates this tab |
| `tab:SetBadge(text?, color?)` | Sets or clears the tab badge pill |
| `tab:AddSection(name)` | Adds a titled section container |
| `tab:AddCollapsibleSection(opts)` | Adds a collapsible section container |
| `tab:AddCard(opts)` | Adds an elevated card container |
| `tab:AddGroupbox(name)` | Adds a bordered groupbox container |
