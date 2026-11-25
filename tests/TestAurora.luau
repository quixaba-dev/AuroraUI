--[[
	Aurora UI 2.0 — Automated QA Test Suite
	Verifies standalone Aurora.luau in both Official Roblox and Executor modes.
]]

local function runTests(Aurora)
	local passed, failed = 0, 0
	local function check(name, cond)
		if cond then
			passed += 1
		else
			failed += 1
			warn("[FAIL] " .. name)
		end
	end

	check("Version is 2.0.0", Aurora.Version == "2.0.0")
	check("Capabilities detected", type(Aurora.Capabilities) == "table")
	check("CreateWindow exists", type(Aurora.CreateWindow) == "function")
	check("ApplyPreset Midnight", Aurora:ApplyPreset("Midnight") == true)
	check("ApplyPreset Aurora Light", Aurora:ApplyPreset("Aurora Light") == true)
	check("ApplyPreset Aurora Dark", Aurora:ApplyPreset("Aurora Dark") == true)

	local exportedTheme = Aurora:ExportTheme()
	check("ExportTheme returns JSON", type(exportedTheme) == "string" and #exportedTheme > 20)
	local okTheme = Aurora:ImportTheme(exportedTheme)
	check("ImportTheme validates & applies", okTheme == true)

	local win = Aurora:CreateWindow({ Title = "QA Window", Loading = false })
	check("Window created", win ~= nil)
	check("Window registered in Aurora.Windows", #Aurora.Windows >= 1)

	local tab = win:AddTab({ Name = "QA", Description = "Test tab", Icon = "★", Badge = "1" })
	local sec = tab:AddCollapsibleSection({ Name = "Controls", Default = true })
	local lbl = sec:AddLabel("Initial")
	lbl:Set("Updated")
	check("Label Set/Get", lbl:Get() == "Updated")

	local tgl = sec:AddToggle({ Name = "Toggle", Default = false, Flag = "qa_toggle" })
	tgl:Set(true)
	check("Toggle Set/Get & Flag sync", tgl:Get() == true and Aurora.Flags.qa_toggle == true)

	local chk = sec:AddCheckbox({ Name = "Check", Default = true, Flag = "qa_check" })
	check("Checkbox Flag sync", chk:Get() == true and Aurora.Flags.qa_check == true)

	local sld = sec:AddSlider({ Name = "Slider", Min = 0, Max = 100, Default = 50, Flag = "qa_slider" })
	sld:Set(75)
	check("Slider Set/Get", sld:Get() == 75 and Aurora.Flags.qa_slider == 75)

	local drp = sec:AddDropdown({ Name = "Drop", Options = { "A", "B", "C" }, Default = "B", Flag = "qa_drop" })
	check("Dropdown default", drp:Get() == "B")
	drp:Set("C")
	check("Dropdown Set", drp:Get() == "C")

	local mdrp = sec:AddMultiDropdown({ Name = "Multi", Options = { "X", "Y" }, Default = { "X" }, Flag = "qa_multi" })
	check("MultiDropdown default", #mdrp:Get() == 1 and mdrp:Get()[1] == "X")

	local cp = sec:AddColorPicker({ Name = "Color", Default = Color3.fromRGB(255, 0, 0), Flag = "qa_color" })
	check("ColorPicker GetHex", cp:GetHex() == "#FF0000")

	local inp = sec:AddInput({ Name = "Input", Default = "hello", Flag = "qa_input" })
	check("Input Get", inp:Get() == "hello")

	local ta = sec:AddTextArea({ Name = "Area", Default = "line1", Flag = "qa_area" })
	check("TextArea Get", ta:Get() == "line1")

	local kb = sec:AddKeybind({ Name = "Key", Default = Enum.KeyCode.G, Flag = "qa_key" })
	check("Keybind Get", kb:Get() == "G")

	local cfgJson = Aurora:ExportConfig()
	check("ExportConfig returns JSON", type(cfgJson) == "string" and #cfgJson > 20)
	local okCfg = Aurora:ImportConfig(cfgJson)
	check("ImportConfig succeeds", okCfg == true)

	-- v1.0 flat config migration test
	local okMig = Aurora:ImportConfig('{"qa_slider": 25, "qa_toggle": false}')
	check("v1.0 config migration succeeds", okMig == true and Aurora.Flags.qa_slider == 25 and Aurora.Flags.qa_toggle == false)

	-- Cleanup test
	win:Destroy()
	check("Window destroyed & flags unregistered", Aurora.Flags.qa_toggle == nil)

	Aurora:Destroy()
	print(string.format("[Aurora QA] Passed: %d | Failed: %d", passed, failed))
	return failed == 0
end

return runTests
