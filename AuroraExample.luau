--[[
	Aurora UI 2.0 — Standalone Example
	Works directly in a Roblox executor alongside Aurora.luau (or via loadstring).
]]

-- Option A: Load from URL in executor
-- local Aurora = loadstring(game:HttpGet("https://your-host/Aurora.luau"))()

-- Option B: Load local file in executor / workspace
local Aurora = (loadfile and loadfile("Aurora.luau")()) or require(script.Parent.Aurora)

local Window = Aurora:CreateWindow({
	Title = "Aurora Studio",
	Subtitle = "v2.0.0",
	Width = 700,
	Height = 470,
	ToggleKey = Enum.KeyCode.RightShift,
	ConfigFolder = "AuroraExample",
	Loading = true,
	LoadingSteps = { "Detecting environment", "Loading tokens", "Mounting workspace" },
})

local MainTab = Window:AddTab({
	Name = "Workspace",
	Description = "Controls & live state",
	Icon = "◆",
	Badge = "NEW",
})

local ControlsSec = MainTab:AddCollapsibleSection({ Name = "Core Controls", Default = true })

ControlsSec:AddToggle({
	Name = "Enable Performance Mode",
	Description = "Reduces background effects for higher FPS",
	Default = false,
	Flag = "perf_mode",
	Tooltip = "Toggle lightweight rendering",
	Callback = function(v)
		print("Performance Mode:", v)
	end,
})

ControlsSec:AddCheckbox({
	Name = "Auto-Save Session",
	Default = true,
	Flag = "auto_save",
	Callback = function(v)
		print("Auto-Save:", v)
	end,
})

ControlsSec:AddSlider({
	Name = "Field of View",
	Min = 40,
	Max = 120,
	Increment = 1,
	Default = 70,
	Suffix = "°",
	Flag = "fov",
	Callback = function(v)
		if workspace.CurrentCamera then
			workspace.CurrentCamera.FieldOfView = v
		end
	end,
})

ControlsSec:AddDropdown({
	Name = "Render Preset",
	Options = { "Low", "Balanced", "Ultra", "Custom" },
	Default = "Balanced",
	Flag = "render_preset",
	Callback = function(v)
		Aurora:Notify({ Title = "Preset", Content = "Switched to " .. tostring(v), Type = "info" })
	end,
})

ControlsSec:AddMultiDropdown({
	Name = "Active Layers",
	Options = { "HUD", "Grid", "Telemetry", "Debug" },
	Default = { "HUD", "Telemetry" },
	Flag = "layers",
	Callback = function(list)
		print("Layers:", table.concat(list, ", "))
	end,
})

ControlsSec:AddColorPicker({
	Name = "Highlight Tint",
	Default = Color3.fromRGB(114, 102, 255),
	Flag = "tint_color",
	Callback = function(c)
		Aurora:SetAccent(c)
	end,
})

local FeedbackTab = Window:AddTab({
	Name = "Components",
	Description = "Dialogs, inputs & status",
	Icon = "◈",
})

local Card = FeedbackTab:AddCard({
	Title = "System Telemetry",
	Subtitle = "Real-time progress and status indicators",
})
local prog = Card:AddProgressBar({ Name = "Buffer Usage", Min = 0, Max = 100, Default = 64 })
local loader = Card:AddLoadingIndicator({ Text = "Syncing state...", Active = true })

Card:AddButton({
	Name = "Simulate Progress",
	Callback = function()
		prog:Set(math.random(10, 100))
		Aurora:Notify({ Title = "Updated", Content = "Buffer sampled.", Type = "success", Duration = 2.5 })
	end,
})

Card:AddButton({
	Name = "Open Confirm Dialog",
	Confirm = "Proceed with resetting temporary session data?",
	Danger = true,
	Callback = function()
		loader:SetActive(false)
		loader:SetText("Idle")
		Aurora:Notify({ Title = "Reset", Content = "Session data cleared.", Type = "warn" })
	end,
})

local InputGroup = FeedbackTab:AddGroupbox("Inputs & Keybinds")
InputGroup:AddRadioGroup({
	Name = "Execution Mode",
	Options = { "Standard", "Silent", "Verbose" },
	Default = "Standard",
	Flag = "exec_mode",
})
InputGroup:AddInput({
	Name = "Session Tag",
	Placeholder = "alpha-01",
	Flag = "session_tag",
})
InputGroup:AddKeybind({
	Name = "Quick Action",
	Default = Enum.KeyCode.F,
	Flag = "quick_action",
	Callback = function()
		Aurora:Notify({ Title = "Hotkey", Content = "Quick Action triggered!", Type = "info" })
	end,
})
InputGroup:AddKeybindList({ Name = "Registered Keybinds" })

-- Built-in Theme Editor, Layout, Behavior & Config Profiles tab
Window:AddSettingsTab()
