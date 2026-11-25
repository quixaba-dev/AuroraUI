--[[
	Aurora UI 2.0.0 — Commercial-Grade Single-File Luau UI Framework
	Standalone executor & Roblox compatible library (zero external dependencies).

	Sections:
	  1. Core (Janitor, Signal, State)
	  2. Environment & Storage Adapters
	  3. AnimationEngine
	  4. ThemeEngine (Design Tokens, 8 Presets, Reactive Bindings, JSON Import/Export)
	  5. Renderer
	  6. InputManager
	  7. NotificationManager, DialogManager, TooltipManager, ContextMenuManager
	  8. ConfigManager (Schema v2, v1 Migration, Profiles, JSON Import/Export)
	  9. WindowManager
	 10. Components (25+ interactive & layout components)
	 11. ThemeEditor
	 12. PublicAPI
]]

local Aurora = (function()
	local Players = game:GetService("Players")
	local TweenService = game:GetService("TweenService")
	local UserInputService = game:GetService("UserInputService")
	local HttpService = game:GetService("HttpService")
	local RunService = game:GetService("RunService")

	-- =========================================================================
	-- 1. CORE (Janitor, Signal, State)
	-- =========================================================================
	local Janitor = {}
	Janitor.__index = Janitor

	function Janitor.new()
		return setmetatable({
			_tasks = {},
			_destroyed = false,
		}, Janitor)
	end

	local function cleanupTask(taskItem)
		local t = typeof(taskItem)
		if t == "RBXScriptConnection" then
			if taskItem.Connected then
				taskItem:Disconnect()
			end
		elseif t == "Instance" then
			pcall(function()
				taskItem:Destroy()
			end)
		elseif t == "function" then
			pcall(taskItem)
		elseif t == "thread" then
			pcall(task.cancel, taskItem)
		elseif t == "table" then
			if typeof(taskItem.Destroy) == "function" then
				pcall(function()
					taskItem:Destroy()
				end)
			elseif typeof(taskItem.Disconnect) == "function" then
				pcall(function()
					taskItem:Disconnect()
				end)
			elseif typeof(taskItem.Cancel) == "function" then
				pcall(function()
					taskItem:Cancel()
				end)
			end
		end
	end

	function Janitor:Add(taskItem, index)
		if self._destroyed then
			cleanupTask(taskItem)
			return taskItem
		end
		local key = index or newproxy(false)
		if index ~= nil and self._tasks[index] ~= nil then
			self:Remove(index)
		end
		self._tasks[key] = taskItem
		return taskItem
	end

	function Janitor:Connect(signal, fn, index)
		local conn = signal:Connect(fn)
		return self:Add(conn, index)
	end

	function Janitor:Remove(index)
		local existing = self._tasks[index]
		if existing ~= nil then
			self._tasks[index] = nil
			cleanupTask(existing)
		end
	end

	function Janitor:Cleanup()
		local tasks = self._tasks
		self._tasks = {}
		for _, taskItem in pairs(tasks) do
			cleanupTask(taskItem)
		end
	end

	function Janitor:Destroy()
		if self._destroyed then
			return
		end
		self._destroyed = true
		self:Cleanup()
	end

	local Signal = {}
	Signal.__index = Signal

	function Signal.new()
		return setmetatable({
			_listeners = {},
			_destroyed = false,
		}, Signal)
	end

	function Signal:Connect(fn)
		if typeof(fn) ~= "function" then
			error("[Aurora.Signal] Connect requires a function")
		end
		if self._destroyed then
			return { Connected = false, Disconnect = function() end }
		end
		local node = { fn = fn, Connected = true }
		table.insert(self._listeners, node)
		local conn = { Connected = true }
		function conn:Disconnect()
			if not self.Connected then
				return
			end
			self.Connected = false
			node.Connected = false
			local idx = table.find(self._listeners or {}, node)
			if idx then
				table.remove(self._listeners, idx)
			end
		end
		-- Bind parent listeners ref cleanly
		local listeners = self._listeners
		function conn:Disconnect()
			if not self.Connected then
				return
			end
			self.Connected = false
			node.Connected = false
			local idx = table.find(listeners, node)
			if idx then
				table.remove(listeners, idx)
			end
		end
		return conn
	end

	function Signal:Once(fn)
		local conn
		conn = self:Connect(function(...)
			if conn.Connected then
				conn:Disconnect()
			end
			fn(...)
		end)
		return conn
	end

	function Signal:Fire(...)
		if self._destroyed then
			return
		end
		local snapshot = table.clone(self._listeners)
		for _, node in ipairs(snapshot) do
			if node.Connected then
				local ok, err = pcall(node.fn, ...)
				if not ok then
					warn("[Aurora.Signal] " .. tostring(err))
				end
			end
		end
	end

	function Signal:Destroy()
		self._destroyed = true
		for _, node in ipairs(self._listeners) do
			node.Connected = false
		end
		table.clear(self._listeners)
	end

	local State = {}
	State.__index = State

	function State.new(globalFlags)
		return setmetatable({
			_flags = globalFlags or {},
			_components = {},
			Changed = Signal.new(),
		}, State)
	end

	function State:Register(flag, component, windowId)
		if not flag or flag == "" then
			return
		end
		self._components[flag] = { component = component, windowId = windowId }
		self._flags[flag] = component.Get and component:Get() or component.Value
	end

	function State:Unregister(flag)
		if not flag then
			return
		end
		self._components[flag] = nil
		self._flags[flag] = nil
	end

	function State:UnregisterWindow(windowId)
		for flag, entry in pairs(self._components) do
			if entry.windowId == windowId then
				self._components[flag] = nil
				self._flags[flag] = nil
			end
		end
	end

	function State:Sync(flag, value)
		if not flag or flag == "" then
			return
		end
		local prev = self._flags[flag]
		self._flags[flag] = value
		if prev ~= value then
			self.Changed:Fire(flag, value, prev)
		end
	end

	function State:Get(flag)
		return self._flags[flag]
	end

	function State:GetComponent(flag)
		local entry = self._components[flag]
		return entry and entry.component or nil
	end

	function State:GetAllFlags()
		return table.clone(self._flags)
	end

	function State:Destroy()
		self.Changed:Destroy()
		table.clear(self._components)
	end

	-- =========================================================================
	-- 2. ENVIRONMENT & STORAGE ADAPTERS
	-- =========================================================================
	local Environment = {}

	local function resolveGlobal(name)
		local ok, env = pcall(function()
			return (getfenv and getfenv(0)) or _G
		end)
		if ok and typeof(env) == "table" then
			local val = rawget(env, name)
			if val ~= nil then
				return val
			end
		end
		if typeof(_G) == "table" then
			return rawget(_G, name)
		end
		return nil
	end

	local cachedCaps = nil

	function Environment.GetCapabilities()
		if cachedCaps then
			return cachedCaps
		end
		local gethuiFn = resolveGlobal("gethui")
		local getgenvFn = resolveGlobal("getgenv")
		local writefileFn = resolveGlobal("writefile")
		local readfileFn = resolveGlobal("readfile")
		local isfolderFn = resolveGlobal("isfolder")
		local makefolderFn = resolveGlobal("makefolder")
		local listfilesFn = resolveGlobal("listfiles")
		local delfileFn = resolveGlobal("delfile")
		local setclipboardFn = resolveGlobal("setclipboard") or resolveGlobal("toclipboard")

		local hasCoreGui = pcall(function()
			return game:GetService("CoreGui").Name
		end)

		local hasFS = typeof(writefileFn) == "function"
			and typeof(readfileFn) == "function"
			and typeof(isfolderFn) == "function"
			and typeof(makefolderFn) == "function"

		cachedCaps = {
			IsExecutor = typeof(getgenvFn) == "function" or typeof(gethuiFn) == "function" or hasFS,
			IsStudio = RunService:IsStudio(),
			HasGetHui = typeof(gethuiFn) == "function",
			HasGetGenv = typeof(getgenvFn) == "function",
			HasCoreGui = hasCoreGui,
			HasFileSystem = hasFS,
			HasListFiles = typeof(listfilesFn) == "function",
			HasDelFile = typeof(delfileFn) == "function",
			HasClipboard = typeof(setclipboardFn) == "function",
			IsTouchDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled,
			HasKeyboard = UserInputService.KeyboardEnabled,
		}
		return cachedCaps
	end

	function Environment.GetGlobalStore()
		local getgenvFn = resolveGlobal("getgenv")
		if typeof(getgenvFn) == "function" then
			local ok, env = pcall(getgenvFn)
			if ok and typeof(env) == "table" then
				return env
			end
		end
		return _G
	end

	function Environment.GetLocalPlayer()
		return Players.LocalPlayer
	end

	function Environment.MountGui(gui, preferPlayerGui)
		if not preferPlayerGui then
			local gethuiFn = resolveGlobal("gethui")
			if typeof(gethuiFn) == "function" then
				local ok, container = pcall(gethuiFn)
				if ok and typeof(container) == "Instance" then
					local mounted = pcall(function()
						gui.Parent = container
					end)
					if mounted and gui.Parent then
						return true, "gethui"
					end
				end
			end

			local okCore = pcall(function()
				gui.Parent = game:GetService("CoreGui")
			end)
			if okCore and gui.Parent then
				return true, "CoreGui"
			end
		end

		local lp = Environment.GetLocalPlayer()
		if lp then
			local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 5)
			if pg then
				local okPg = pcall(function()
					gui.Parent = pg
				end)
				if okPg and gui.Parent then
					return true, "PlayerGui"
				end
			end
		end

		return false, "None"
	end

	function Environment.SetClipboard(text)
		local fn = resolveGlobal("setclipboard") or resolveGlobal("toclipboard")
		if typeof(fn) == "function" then
			return pcall(fn, tostring(text))
		end
		return false
	end

	function Environment.GetViewportSize()
		local cam = workspace.CurrentCamera
		if cam then
			return cam.ViewportSize
		end
		return Vector2.new(1280, 720)
	end

	function Environment.GetFileSystem()
		local caps = Environment.GetCapabilities()
		if not caps.HasFileSystem then
			return nil
		end
		return {
			readfile = resolveGlobal("readfile"),
			writefile = resolveGlobal("writefile"),
			isfile = resolveGlobal("isfile"),
			isfolder = resolveGlobal("isfolder"),
			makefolder = resolveGlobal("makefolder"),
			listfiles = resolveGlobal("listfiles"),
			delfile = resolveGlobal("delfile"),
		}
	end

	local Storage = {}
	Storage.__index = Storage

	function Storage.new(rootFolder)
		local fs = Environment.GetFileSystem()
		local self = setmetatable({
			_folder = rootFolder or "AuroraUI",
			_fs = fs,
			_memory = {},
			Backend = fs ~= nil and "FileSystem" or "Memory",
		}, Storage)
		if self._fs then
			pcall(function()
				if not self._fs.isfolder(self._folder) then
					self._fs.makefolder(self._folder)
				end
			end)
		end
		return self
	end

	function Storage:SetFolder(folder)
		self._folder = folder
		if self._fs then
			pcall(function()
				if not self._fs.isfolder(self._folder) then
					self._fs.makefolder(self._folder)
				end
			end)
		end
	end

	function Storage:GetFolder()
		return self._folder
	end

	local function normalizePath(folder, key)
		local sanitized = tostring(key):gsub("[^%w%._%-/]", "_")
		return folder .. "/" .. sanitized
	end

	function Storage:EnsureSubfolder(sub)
		if not self._fs then
			return
		end
		local path = self._folder .. "/" .. sub
		pcall(function()
			if not self._fs.isfolder(self._folder) then
				self._fs.makefolder(self._folder)
			end
			if not self._fs.isfolder(path) then
				self._fs.makefolder(path)
			end
		end)
	end

	function Storage:Write(key, content)
		local path = normalizePath(self._folder, key)
		self._memory[path] = content
		if self._fs then
			local ok, err = pcall(self._fs.writefile, path, content)
			if ok then
				return true, nil
			end
			return false, tostring(err)
		end
		local lp = Environment.GetLocalPlayer()
		if lp then
			pcall(function()
				lp:SetAttribute("Aurora_" .. key:gsub("[^%w_]", "_"), content)
			end)
		end
		return true, nil
	end

	function Storage:Read(key)
		local path = normalizePath(self._folder, key)
		if self._fs then
			local exists = true
			if typeof(self._fs.isfile) == "function" then
				local okExist, res = pcall(self._fs.isfile, path)
				exists = okExist and res == true
			end
			if exists then
				local ok, data = pcall(self._fs.readfile, path)
				if ok and typeof(data) == "string" then
					self._memory[path] = data
					return true, data
				end
			end
		end
		if self._memory[path] ~= nil then
			return true, self._memory[path]
		end
		local lp = Environment.GetLocalPlayer()
		if lp then
			local ok, attr = pcall(function()
				return lp:GetAttribute("Aurora_" .. key:gsub("[^%w_]", "_"))
			end)
			if ok and typeof(attr) == "string" then
				return true, attr
			end
		end
		return false, nil
	end

	function Storage:Delete(key)
		local path = normalizePath(self._folder, key)
		self._memory[path] = nil
		if self._fs and typeof(self._fs.delfile) == "function" then
			pcall(self._fs.delfile, path)
		end
		local lp = Environment.GetLocalPlayer()
		if lp then
			pcall(function()
				lp:SetAttribute("Aurora_" .. key:gsub("[^%w_]", "_"), nil)
			end)
		end
		return true
	end

	function Storage:List(subfolder, extension)
		local ext = extension or ".json"
		local results, seen = {}, {}
		local dir = subfolder and (self._folder .. "/" .. subfolder) or self._folder

		if self._fs and typeof(self._fs.listfiles) == "function" then
			local ok, files = pcall(self._fs.listfiles, dir)
			if ok and typeof(files) == "table" then
				for _, fullPath in ipairs(files) do
					local fileName = tostring(fullPath):match("([^/\\]+)$")
					if fileName and fileName:sub(-#ext) == ext then
						local base = fileName:sub(1, #fileName - #ext)
						if not seen[base] then
							seen[base] = true
							table.insert(results, base)
						end
					end
				end
			end
		end

		local prefix = dir .. "/"
		for path in pairs(self._memory) do
			if path:sub(1, #prefix) == prefix and path:sub(-#ext) == ext then
				local rest = path:sub(#prefix + 1)
				if not rest:find("/") then
					local base = rest:sub(1, #rest - #ext)
					if not seen[base] then
						seen[base] = true
						table.insert(results, base)
					end
				end
			end
		end

		table.sort(results)
		return results
	end

	-- =========================================================================
	-- 3. ANIMATION ENGINE
	-- =========================================================================
	local AnimationEngine = {}
	AnimationEngine.__index = AnimationEngine

	function AnimationEngine.new(behaviorConfig)
		return setmetatable({
			_running = setmetatable({}, { __mode = "k" }),
			_behavior = behaviorConfig,
			_destroyed = false,
		}, AnimationEngine)
	end

	function AnimationEngine:ShouldAnimate()
		local b = self._behavior
		return not self._destroyed and b ~= nil and b.AnimationsEnabled == true and b.ReduceMotion ~= true
	end

	function AnimationEngine:GetDuration(baseDuration)
		local dur = baseDuration or 0.2
		if not self:ShouldAnimate() then
			return 0
		end
		local speed = math.clamp(tonumber(self._behavior.AnimationSpeed) or 1, 0.25, 4)
		return dur / speed
	end

	local function makePropKey(props)
		local names = {}
		for k in pairs(props) do
			table.insert(names, k)
		end
		table.sort(names)
		return table.concat(names, ",")
	end

	function AnimationEngine:Cancel(obj, propKey)
		local per = self._running[obj]
		if not per then
			return
		end
		if propKey then
			if per[propKey] then
				pcall(function()
					per[propKey]:Cancel()
				end)
				per[propKey] = nil
			end
		else
			for k, t in pairs(per) do
				pcall(function()
					t:Cancel()
				end)
				per[k] = nil
			end
		end
	end

	function AnimationEngine:Tween(obj, props, duration, style, dir)
		if self._destroyed or not obj then
			return nil
		end
		local key = makePropKey(props)
		self:Cancel(obj, key)

		local effectiveDur = self:GetDuration(duration)
		if effectiveDur <= 0 or not obj.Parent then
			for k, v in pairs(props) do
				pcall(function()
					obj[k] = v
				end)
			end
			return nil
		end

		local per = self._running[obj]
		if not per then
			per = {}
			self._running[obj] = per
		end

		local ok, tween = pcall(function()
			return TweenService:Create(
				obj,
				TweenInfo.new(effectiveDur, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out),
				props
			)
		end)
		if not ok or not tween then
			for k, v in pairs(props) do
				pcall(function()
					obj[k] = v
				end)
			end
			return nil
		end

		per[key] = tween
		tween.Completed:Once(function()
			if per[key] == tween then
				per[key] = nil
			end
		end)
		tween:Play()
		return tween
	end

	function AnimationEngine:CancelAll()
		for obj, per in pairs(self._running) do
			for k, t in pairs(per) do
				pcall(function()
					t:Cancel()
				end)
				per[k] = nil
			end
			self._running[obj] = nil
		end
	end

	function AnimationEngine:Destroy()
		self._destroyed = true
		self:CancelAll()
	end

	-- =========================================================================
	-- 4. THEME ENGINE
	-- =========================================================================
	local ThemeEngine = {}
	ThemeEngine.__index = ThemeEngine

	local COLOR_TOKENS = {
		"Background", "Surface", "ElevatedSurface", "HoverSurface", "ActiveSurface",
		"PrimaryText", "SecondaryText", "MutedText",
		"Accent", "AccentHover", "Success", "Warning", "Danger",
		"Border", "Focus", "Shadow",
	}

	local NUMBER_TOKENS = {
		"BackgroundTransparency", "SurfaceTransparency", "BorderThickness", "ShadowTransparency",
		"RadiusSmall", "RadiusMedium", "RadiusLarge", "RadiusPill",
		"SpacingXS", "SpacingSM", "SpacingMD", "SpacingLG",
		"TextSizeXS", "TextSizeSM", "TextSizeMD", "TextSizeLG", "TextSizeXL",
		"AnimFast", "AnimNormal", "AnimSlow",
	}

	local FONT_TOKENS = { "FontRegular", "FontMedium", "FontBold", "FontMono" }

	local function baseTokens()
		return {
			BackgroundTransparency = 0,
			SurfaceTransparency = 0,
			BorderThickness = 1,
			ShadowTransparency = 0.65,
			RadiusSmall = 5,
			RadiusMedium = 8,
			RadiusLarge = 12,
			RadiusPill = 999,
			SpacingXS = 4,
			SpacingSM = 8,
			SpacingMD = 12,
			SpacingLG = 16,
			FontRegular = Enum.Font.Gotham,
			FontMedium = Enum.Font.GothamMedium,
			FontBold = Enum.Font.GothamBold,
			FontMono = Enum.Font.RobotoMono,
			TextSizeXS = 11,
			TextSizeSM = 12,
			TextSizeMD = 13,
			TextSizeLG = 15,
			TextSizeXL = 18,
			AnimFast = 0.14,
			AnimNormal = 0.22,
			AnimSlow = 0.34,
		}
	end

	local function makePreset(name, mode, colors, overrides)
		local t = baseTokens()
		t.Name = name
		t.Mode = mode
		for k, v in pairs(colors) do
			t[k] = v
		end
		if overrides then
			for k, v in pairs(overrides) do
				t[k] = v
			end
		end
		return t
	end

	local function deriveHover(c)
		local h, s, v = c:ToHSV()
		return Color3.fromHSV(h, math.clamp(s * 0.9, 0, 1), math.clamp(v + 0.12, 0, 1))
	end

	local Presets = {
		["Aurora Dark"] = makePreset("Aurora Dark", "Dark", {
			Background = Color3.fromRGB(13, 14, 19),
			Surface = Color3.fromRGB(19, 21, 28),
			ElevatedSurface = Color3.fromRGB(26, 29, 39),
			HoverSurface = Color3.fromRGB(35, 39, 52),
			ActiveSurface = Color3.fromRGB(44, 49, 66),
			PrimaryText = Color3.fromRGB(241, 243, 249),
			SecondaryText = Color3.fromRGB(168, 174, 192),
			MutedText = Color3.fromRGB(110, 117, 138),
			Accent = Color3.fromRGB(114, 102, 255),
			AccentHover = Color3.fromRGB(136, 126, 255),
			Success = Color3.fromRGB(64, 196, 134),
			Warning = Color3.fromRGB(242, 174, 62),
			Danger = Color3.fromRGB(238, 84, 96),
			Border = Color3.fromRGB(45, 49, 65),
			Focus = Color3.fromRGB(136, 126, 255),
			Shadow = Color3.fromRGB(0, 0, 0),
		}),
		["Aurora Light"] = makePreset("Aurora Light", "Light", {
			Background = Color3.fromRGB(244, 245, 248),
			Surface = Color3.fromRGB(255, 255, 255),
			ElevatedSurface = Color3.fromRGB(248, 249, 252),
			HoverSurface = Color3.fromRGB(234, 237, 244),
			ActiveSurface = Color3.fromRGB(222, 226, 236),
			PrimaryText = Color3.fromRGB(22, 25, 34),
			SecondaryText = Color3.fromRGB(84, 92, 112),
			MutedText = Color3.fromRGB(134, 142, 162),
			Accent = Color3.fromRGB(92, 78, 240),
			AccentHover = Color3.fromRGB(74, 60, 224),
			Success = Color3.fromRGB(28, 166, 104),
			Warning = Color3.fromRGB(218, 138, 22),
			Danger = Color3.fromRGB(216, 58, 72),
			Border = Color3.fromRGB(214, 219, 230),
			Focus = Color3.fromRGB(92, 78, 240),
			Shadow = Color3.fromRGB(20, 24, 38),
		}, { ShadowTransparency = 0.85 }),
		["Midnight"] = makePreset("Midnight", "Dark", {
			Background = Color3.fromRGB(8, 10, 16),
			Surface = Color3.fromRGB(13, 16, 25),
			ElevatedSurface = Color3.fromRGB(19, 24, 36),
			HoverSurface = Color3.fromRGB(27, 34, 50),
			ActiveSurface = Color3.fromRGB(36, 45, 66),
			PrimaryText = Color3.fromRGB(236, 240, 250),
			SecondaryText = Color3.fromRGB(148, 160, 186),
			MutedText = Color3.fromRGB(96, 108, 134),
			Accent = Color3.fromRGB(56, 142, 255),
			AccentHover = Color3.fromRGB(88, 162, 255),
			Success = Color3.fromRGB(58, 198, 140),
			Warning = Color3.fromRGB(240, 172, 60),
			Danger = Color3.fromRGB(236, 80, 96),
			Border = Color3.fromRGB(34, 42, 62),
			Focus = Color3.fromRGB(88, 162, 255),
			Shadow = Color3.fromRGB(0, 0, 0),
		}),
		["Graphite"] = makePreset("Graphite", "Dark", {
			Background = Color3.fromRGB(18, 18, 20),
			Surface = Color3.fromRGB(25, 25, 28),
			ElevatedSurface = Color3.fromRGB(33, 33, 37),
			HoverSurface = Color3.fromRGB(43, 43, 48),
			ActiveSurface = Color3.fromRGB(54, 54, 60),
			PrimaryText = Color3.fromRGB(242, 242, 244),
			SecondaryText = Color3.fromRGB(172, 172, 178),
			MutedText = Color3.fromRGB(115, 115, 122),
			Accent = Color3.fromRGB(220, 220, 228),
			AccentHover = Color3.fromRGB(245, 245, 250),
			Success = Color3.fromRGB(74, 198, 132),
			Warning = Color3.fromRGB(235, 175, 65),
			Danger = Color3.fromRGB(232, 86, 94),
			Border = Color3.fromRGB(52, 52, 58),
			Focus = Color3.fromRGB(200, 200, 210),
			Shadow = Color3.fromRGB(0, 0, 0),
		}),
		["Lavender"] = makePreset("Lavender", "Dark", {
			Background = Color3.fromRGB(16, 14, 22),
			Surface = Color3.fromRGB(23, 20, 32),
			ElevatedSurface = Color3.fromRGB(31, 27, 43),
			HoverSurface = Color3.fromRGB(42, 37, 58),
			ActiveSurface = Color3.fromRGB(52, 46, 72),
			PrimaryText = Color3.fromRGB(244, 240, 252),
			SecondaryText = Color3.fromRGB(180, 170, 204),
			MutedText = Color3.fromRGB(122, 112, 148),
			Accent = Color3.fromRGB(166, 128, 255),
			AccentHover = Color3.fromRGB(186, 156, 255),
			Success = Color3.fromRGB(78, 206, 148),
			Warning = Color3.fromRGB(242, 178, 76),
			Danger = Color3.fromRGB(238, 92, 116),
			Border = Color3.fromRGB(54, 47, 74),
			Focus = Color3.fromRGB(186, 156, 255),
			Shadow = Color3.fromRGB(0, 0, 0),
		}),
		["Crimson"] = makePreset("Crimson", "Dark", {
			Background = Color3.fromRGB(17, 13, 15),
			Surface = Color3.fromRGB(25, 19, 22),
			ElevatedSurface = Color3.fromRGB(34, 26, 30),
			HoverSurface = Color3.fromRGB(46, 35, 40),
			ActiveSurface = Color3.fromRGB(58, 44, 50),
			PrimaryText = Color3.fromRGB(246, 240, 242),
			SecondaryText = Color3.fromRGB(186, 168, 174),
			MutedText = Color3.fromRGB(128, 110, 116),
			Accent = Color3.fromRGB(224, 68, 88),
			AccentHover = Color3.fromRGB(240, 94, 112),
			Success = Color3.fromRGB(70, 198, 136),
			Warning = Color3.fromRGB(240, 174, 66),
			Danger = Color3.fromRGB(244, 72, 86),
			Border = Color3.fromRGB(58, 42, 48),
			Focus = Color3.fromRGB(240, 94, 112),
			Shadow = Color3.fromRGB(0, 0, 0),
		}),
		["Ocean"] = makePreset("Ocean", "Dark", {
			Background = Color3.fromRGB(11, 16, 21),
			Surface = Color3.fromRGB(16, 24, 31),
			ElevatedSurface = Color3.fromRGB(22, 33, 42),
			HoverSurface = Color3.fromRGB(30, 44, 56),
			ActiveSurface = Color3.fromRGB(38, 56, 70),
			PrimaryText = Color3.fromRGB(236, 246, 250),
			SecondaryText = Color3.fromRGB(154, 180, 196),
			MutedText = Color3.fromRGB(102, 126, 142),
			Accent = Color3.fromRGB(46, 188, 198),
			AccentHover = Color3.fromRGB(74, 208, 216),
			Success = Color3.fromRGB(64, 204, 144),
			Warning = Color3.fromRGB(242, 176, 68),
			Danger = Color3.fromRGB(236, 86, 98),
			Border = Color3.fromRGB(38, 55, 68),
			Focus = Color3.fromRGB(74, 208, 216),
			Shadow = Color3.fromRGB(0, 0, 0),
		}),
	}
	Presets["Custom"] = table.clone(Presets["Aurora Dark"])
	Presets["Custom"].Name = "Custom"
	Presets["Custom"].Mode = "Custom"

	function ThemeEngine.new(animEngine, storage)
		return setmetatable({
			_anim = animEngine,
			_storage = storage,
			_tokens = table.clone(Presets["Aurora Dark"]),
			_customThemes = {},
			_bindings = {},
			_hooks = {},
			Changed = Signal.new(),
			_destroyed = false,
		}, ThemeEngine)
	end

	function ThemeEngine:GetTokens()
		return self._tokens
	end

	function ThemeEngine:Get(token)
		return self._tokens[token]
	end

	function ThemeEngine:GetPresetNames()
		return { "Aurora Dark", "Aurora Light", "Midnight", "Graphite", "Lavender", "Crimson", "Ocean", "Custom" }
	end

	function ThemeEngine:GetAllThemeNames()
		local list = self:GetPresetNames()
		for name in pairs(self._customThemes) do
			if not table.find(list, name) then
				table.insert(list, name)
			end
		end
		return list
	end

	function ThemeEngine:Bind(inst, prop, token, transform)
		local val = self._tokens[token]
		if val ~= nil then
			local finalVal = transform and transform(val) or val
			pcall(function()
				inst[prop] = finalVal
			end)
		end
		table.insert(self._bindings, { inst = inst, prop = prop, token = token, transform = transform })
		return inst
	end

	function ThemeEngine:OnChange(fn, aliveCheck)
		local entry = {
			fn = fn,
			alive = aliveCheck or function()
				return not self._destroyed
			end,
		}
		table.insert(self._hooks, entry)
		return function()
			local idx = table.find(self._hooks, entry)
			if idx then
				table.remove(self._hooks, idx)
			end
		end
	end

	function ThemeEngine:Propagate(onlyToken, animate)
		if self._destroyed then
			return
		end
		local shouldAnim = animate ~= false and self._anim ~= nil and self._anim:ShouldAnimate()

		for i = #self._bindings, 1, -1 do
			local b = self._bindings[i]
			local okAlive = pcall(function()
				return b.inst.ClassName
			end)
			if not okAlive then
				table.remove(self._bindings, i)
			elseif onlyToken == nil or b.token == onlyToken then
				local val = self._tokens[b.token]
				if val ~= nil then
					local finalVal = b.transform and b.transform(val) or val
					if shouldAnim and typeof(finalVal) == "Color3" and b.inst.Parent then
						self._anim:Tween(b.inst, { [b.prop] = finalVal }, self._tokens.AnimFast)
					else
						pcall(function()
							b.inst[b.prop] = finalVal
						end)
					end
				end
			end
		end

		for i = #self._hooks, 1, -1 do
			local h = self._hooks[i]
			if not h.alive() then
				table.remove(self._hooks, i)
			else
				pcall(h.fn)
			end
		end

		self.Changed:Fire(onlyToken, self._tokens)
	end

	function ThemeEngine:SetToken(token, value, animate)
		if self._tokens[token] == value then
			return
		end
		self._tokens[token] = value
		if token == "Accent" and typeof(value) == "Color3" then
			self._tokens.AccentHover = deriveHover(value)
			self._tokens.Focus = value
			self:Propagate("Accent", animate)
			self:Propagate("AccentHover", animate)
			self:Propagate("Focus", animate)
		else
			self:Propagate(token, animate)
		end
	end

	function ThemeEngine:SetAccent(color)
		self:SetToken("Accent", color, true)
	end

	function ThemeEngine:ApplyPreset(name, animate)
		local source = Presets[name] or self._customThemes[name]
		if not source then
			return false
		end
		for k, v in pairs(source) do
			self._tokens[k] = v
		end
		self:Propagate(nil, animate)
		return true
	end

	function ThemeEngine:SerializeTheme(tokens)
		local t = tokens or self._tokens
		local out = { Version = 2, Name = t.Name or "Custom", Mode = t.Mode or "Custom", Colors = {}, Numbers = {}, Fonts = {} }
		for _, k in ipairs(COLOR_TOKENS) do
			local c = t[k]
			if typeof(c) == "Color3" then
				out.Colors[k] = { math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255) }
			end
		end
		for _, k in ipairs(NUMBER_TOKENS) do
			if typeof(t[k]) == "number" then
				out.Numbers[k] = t[k]
			end
		end
		for _, k in ipairs(FONT_TOKENS) do
			if typeof(t[k]) == "EnumItem" then
				out.Fonts[k] = t[k].Name
			end
		end
		return out
	end

	function ThemeEngine:ValidateAndBuildTheme(raw)
		if typeof(raw) ~= "table" then
			return false, nil, "Theme payload must be a table"
		end
		local built = table.clone(Presets["Aurora Dark"])
		built.Name = typeof(raw.Name) == "string" and raw.Name ~= "" and raw.Name:sub(1, 40) or "Imported"
		built.Mode = (raw.Mode == "Dark" or raw.Mode == "Light" or raw.Mode == "Custom") and raw.Mode or "Custom"

		if typeof(raw.Colors) == "table" then
			for _, k in ipairs(COLOR_TOKENS) do
				local c = raw.Colors[k]
				if typeof(c) == "table" and #c == 3 then
					local r, g, b = tonumber(c[1]), tonumber(c[2]), tonumber(c[3])
					if r and g and b then
						built[k] = Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
					end
				elseif typeof(c) == "string" then
					local hex = c:gsub("#", "")
					if #hex == 6 then
						local num = tonumber(hex, 16)
						if num then
							built[k] = Color3.fromRGB(bit32.rshift(num, 16), bit32.band(bit32.rshift(num, 8), 255), bit32.band(num, 255))
						end
					end
				end
			end
		end

		if typeof(raw.Numbers) == "table" then
			for _, k in ipairs(NUMBER_TOKENS) do
				local n = tonumber(raw.Numbers[k])
				if n then
					built[k] = math.clamp(n, 0, 999)
				end
			end
		end

		if typeof(raw.Fonts) == "table" then
			for _, k in ipairs(FONT_TOKENS) do
				local fn = raw.Fonts[k]
				if typeof(fn) == "string" then
					local ok, enumVal = pcall(function()
						return Enum.Font[fn]
					end)
					if ok and typeof(enumVal) == "EnumItem" then
						built[k] = enumVal
					end
				end
			end
		end

		return true, built, nil
	end

	function ThemeEngine:ExportJSON()
		return HttpService:JSONEncode(self:SerializeTheme(self._tokens))
	end

	function ThemeEngine:ImportJSON(jsonStr, applyNow)
		if typeof(jsonStr) ~= "string" or jsonStr == "" then
			return false, "Empty theme JSON"
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, jsonStr)
		if not ok then
			return false, "Invalid JSON syntax"
		end
		local valid, built, err = self:ValidateAndBuildTheme(decoded)
		if not valid then
			return false, err
		end
		self._customThemes[built.Name] = built
		if applyNow ~= false then
			for k, v in pairs(built) do
				self._tokens[k] = v
			end
			self:Propagate(nil, true)
		end
		return true, built.Name
	end

	function ThemeEngine:SaveCustomTheme(name)
		if not name or name == "" then
			return false
		end
		local copy = table.clone(self._tokens)
		copy.Name = name
		copy.Mode = "Custom"
		self._customThemes[name] = copy
		if self._storage then
			self._storage:EnsureSubfolder("themes")
			self._storage:Write("themes/" .. name .. ".json", HttpService:JSONEncode(self:SerializeTheme(copy)))
		end
		return true
	end

	function ThemeEngine:RenameCustomTheme(oldName, newName)
		if not self._customThemes[oldName] or not newName or newName == "" then
			return false
		end
		local theme = self._customThemes[oldName]
		theme.Name = newName
		self._customThemes[newName] = theme
		self._customThemes[oldName] = nil
		if self._storage then
			self._storage:Delete("themes/" .. oldName .. ".json")
			self._storage:Write("themes/" .. newName .. ".json", HttpService:JSONEncode(self:SerializeTheme(theme)))
		end
		return true
	end

	function ThemeEngine:DeleteCustomTheme(name)
		if not self._customThemes[name] then
			return false
		end
		self._customThemes[name] = nil
		if self._storage then
			self._storage:Delete("themes/" .. name .. ".json")
		end
		if self._tokens.Name == name then
			self:ApplyPreset("Aurora Dark", true)
		end
		return true
	end

	function ThemeEngine:LoadSavedCustomThemes()
		if not self._storage then
			return
		end
		for _, name in ipairs(self._storage:List("themes", ".json")) do
			local ok, raw = self._storage:Read("themes/" .. name .. ".json")
			if ok and raw then
				self:ImportJSON(raw, false)
			end
		end
	end

	function ThemeEngine:Destroy()
		self._destroyed = true
		table.clear(self._bindings)
		table.clear(self._hooks)
		self.Changed:Destroy()
	end

	-- =========================================================================
	-- 5. RENDERER
	-- =========================================================================
	local Renderer = {}
	Renderer.__index = Renderer

	function Renderer.new(themeEngine, animEngine)
		return setmetatable({ Theme = themeEngine, Anim = animEngine }, Renderer)
	end

	function Renderer.SafeCall(cb, ...)
		if typeof(cb) ~= "function" then
			return
		end
		local ok, err = pcall(cb, ...)
		if not ok then
			warn("[Aurora] Callback error: " .. tostring(err))
		end
	end

	function Renderer:New(className, props, children)
		local inst = Instance.new(className)
		if props then
			for k, v in pairs(props) do
				if k ~= "Parent" then
					inst[k] = v
				end
			end
		end
		if children then
			for _, child in ipairs(children) do
				child.Parent = inst
			end
		end
		if props and props.Parent then
			inst.Parent = props.Parent
		end
		return inst
	end

	function Renderer:Corner(radiusOrToken)
		local c = Instance.new("UICorner")
		if typeof(radiusOrToken) == "string" then
			self.Theme:Bind(c, "CornerRadius", radiusOrToken, function(v)
				return UDim.new(0, v)
			end)
		else
			c.CornerRadius = UDim.new(0, radiusOrToken or self.Theme:Get("RadiusMedium"))
		end
		return c
	end

	function Renderer:Stroke(colorToken, thicknessOrToken, transparency)
		local s = Instance.new("UIStroke")
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Transparency = transparency or 0
		self.Theme:Bind(s, "Color", colorToken or "Border")
		if typeof(thicknessOrToken) == "string" then
			self.Theme:Bind(s, "Thickness", thicknessOrToken)
		else
			s.Thickness = thicknessOrToken or self.Theme:Get("BorderThickness") or 1
		end
		return s
	end

	function Renderer:Padding(top, right, bottom, left)
		local r = right or top
		local b = bottom or top
		local l = left or r
		return self:New("UIPadding", {
			PaddingTop = UDim.new(0, top),
			PaddingRight = UDim.new(0, r),
			PaddingBottom = UDim.new(0, b),
			PaddingLeft = UDim.new(0, l),
		})
	end

	function Renderer:ListLayout(padding, direction, hAlign, vAlign)
		return self:New("UIListLayout", {
			Padding = UDim.new(0, padding or 6),
			FillDirection = direction or Enum.FillDirection.Vertical,
			HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
			VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
			SortOrder = Enum.SortOrder.LayoutOrder,
		})
	end

	function Renderer:Label(props, colorToken, sizeToken, fontToken)
		local defaults = {
			BackgroundTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
			RichText = false,
		}
		for k, v in pairs(props) do
			defaults[k] = v
		end
		local lbl = self:New("TextLabel", defaults)
		self.Theme:Bind(lbl, "TextColor3", colorToken or "PrimaryText")
		if not props.Font then
			self.Theme:Bind(lbl, "Font", fontToken or "FontMedium")
		end
		if not props.TextSize then
			self.Theme:Bind(lbl, "TextSize", sizeToken or "TextSizeMD")
		end
		return lbl
	end

	function Renderer:AttachHover(target, normalToken, hoverToken, janitor)
		local norm = normalToken or "ElevatedSurface"
		local hov = hoverToken or "HoverSurface"
		local c1 = target.MouseEnter:Connect(function()
			self.Anim:Tween(target, { BackgroundColor3 = self.Theme:Get(hov) }, self.Theme:Get("AnimFast"))
		end)
		local c2 = target.MouseLeave:Connect(function()
			self.Anim:Tween(target, { BackgroundColor3 = self.Theme:Get(norm) }, self.Theme:Get("AnimFast"))
		end)
		if janitor then
			janitor:Add(c1)
			janitor:Add(c2)
		end
		return c1, c2
	end

	-- =========================================================================
	-- 6. INPUT MANAGER
	-- =========================================================================
	local InputManager = {}
	InputManager.__index = InputManager

	function InputManager.new()
		local self = setmetatable({
			_janitor = Janitor.new(),
			_keybinds = {},
			_toggleHandlers = {},
			_activeListener = nil,
		}, InputManager)

		self._janitor:Connect(UserInputService.InputBegan, function(input, gameProcessed)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end
			if self._activeListener then
				local entry = self._keybinds[self._activeListener]
				self._activeListener = nil
				if entry then
					entry.listening = false
					local captured = input.KeyCode == Enum.KeyCode.Escape and Enum.KeyCode.Unknown or input.KeyCode
					pcall(entry.onCapture, captured)
				end
				return
			end
			if gameProcessed then
				return
			end
			for _, handler in ipairs(self._toggleHandlers) do
				if input.KeyCode == handler.getKey() then
					pcall(handler.toggle)
					return
				end
			end
			for _, entry in pairs(self._keybinds) do
				if entry.key ~= Enum.KeyCode.Unknown and entry.key == input.KeyCode then
					local ok, err = pcall(entry.callback, entry.key)
					if not ok then
						warn("[Aurora.InputManager] " .. tostring(err))
					end
				end
			end
		end, "GlobalInputBegan")

		return self
	end

	function InputManager.IsPress(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	function InputManager.IsRightClick(input)
		return input.UserInputType == Enum.UserInputType.MouseButton2
	end

	function InputManager.IsMove(input)
		return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
	end

	function InputManager:RegisterToggle(getKeyFn, toggleFn)
		local entry = { getKey = getKeyFn, toggle = toggleFn }
		table.insert(self._toggleHandlers, entry)
		return function()
			local idx = table.find(self._toggleHandlers, entry)
			if idx then
				table.remove(self._toggleHandlers, idx)
			end
		end
	end

	function InputManager:RegisterKeybind(id, key, labelText, callback, onCapture)
		self._keybinds[id] = { key = key, label = labelText or "Keybind", callback = callback, onCapture = onCapture, listening = false }
	end

	function InputManager:UpdateKeybind(id, key)
		local entry = self._keybinds[id]
		if entry then
			entry.key = key
		end
	end

	function InputManager:StartListening(id)
		if self._activeListener and self._activeListener ~= id then
			local prev = self._keybinds[self._activeListener]
			if prev then
				prev.listening = false
				pcall(prev.onCapture, prev.key)
			end
		end
		local entry = self._keybinds[id]
		if entry then
			entry.listening = true
			self._activeListener = id
		end
	end

	function InputManager:UnregisterKeybind(id)
		if self._activeListener == id then
			self._activeListener = nil
		end
		self._keybinds[id] = nil
	end

	function InputManager:GetAllKeybinds()
		local list = {}
		for id, entry in pairs(self._keybinds) do
			table.insert(list, { id = id, label = entry.label, key = entry.key })
		end
		table.sort(list, function(a, b)
			return tostring(a.label) < tostring(b.label)
		end)
		return list
	end

	function InputManager:Destroy()
		self._activeListener = nil
		table.clear(self._keybinds)
		table.clear(self._toggleHandlers)
		self._janitor:Destroy()
	end

	-- =========================================================================
	-- 7. NOTIFICATION, DIALOG, TOOLTIP & CONTEXT MENU MANAGERS
	-- =========================================================================
	local NotificationManager = {}
	NotificationManager.__index = NotificationManager

	local TYPE_ICONS = {
		info = "i",
		success = "✓",
		warn = "!",
		warning = "!",
		error = "×",
		danger = "×",
	}

	function NotificationManager.new(renderer, behaviorConfig, preferPlayerGui)
		return setmetatable({
			_r = renderer,
			_behavior = behaviorConfig,
			_preferPlayerGui = preferPlayerGui or false,
			_janitor = Janitor.new(),
			_gui = nil,
			_holder = nil,
			_layout = nil,
			_activeCount = 0,
			_maxVisible = 5,
			_queue = {},
			_destroyed = false,
		}, NotificationManager)
	end

	function NotificationManager:_applyPosition()
		if not self._holder or not self._layout then
			return
		end
		local pos = (self._behavior and self._behavior.NotificationPosition) or "BottomRight"
		local pad = 16
		if pos == "TopRight" then
			self._holder.AnchorPoint = Vector2.new(1, 0)
			self._holder.Position = UDim2.new(1, -pad, 0, pad)
			self._layout.VerticalAlignment = Enum.VerticalAlignment.Top
		elseif pos == "TopLeft" then
			self._holder.AnchorPoint = Vector2.new(0, 0)
			self._holder.Position = UDim2.new(0, pad, 0, pad)
			self._layout.VerticalAlignment = Enum.VerticalAlignment.Top
		elseif pos == "BottomLeft" then
			self._holder.AnchorPoint = Vector2.new(0, 1)
			self._holder.Position = UDim2.new(0, pad, 1, -pad)
			self._layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		else
			self._holder.AnchorPoint = Vector2.new(1, 1)
			self._holder.Position = UDim2.new(1, -pad, 1, -pad)
			self._layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		end
	end

	function NotificationManager:SetPosition(position)
		if self._behavior then
			self._behavior.NotificationPosition = position
		end
		self:_applyPosition()
	end

	function NotificationManager:_ensureGui()
		if self._destroyed or (self._gui and self._gui.Parent) then
			return
		end
		local gui = self._r:New("ScreenGui", {
			Name = "AuroraNotifications_" .. HttpService:GenerateGUID(false):sub(1, 8),
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = 1100,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		})
		Environment.MountGui(gui, self._preferPlayerGui)
		self._janitor:Add(gui, "NotifyGui")
		self._gui = gui

		local layout = self._r:ListLayout(8)
		self._layout = layout
		local holder = self._r:New("Frame", {
			Size = UDim2.new(0, 310, 1, -32),
			BackgroundTransparency = 1,
			Parent = gui,
		}, { layout })
		self._holder = holder
		self:_applyPosition()
	end

	function NotificationManager:_pumpQueue()
		while self._activeCount < self._maxVisible and #self._queue > 0 and not self._destroyed do
			local nextItem = table.remove(self._queue, 1)
			self:_spawn(nextItem)
		end
	end

	function NotificationManager:_spawn(o)
		self:_ensureGui()
		if not self._holder or self._destroyed then
			return
		end
		self._activeCount += 1
		local theme = self._r.Theme
		local anim = self._r.Anim

		local kind = string.lower(tostring(o.Type or "info"))
		local colorMap = {
			info = theme:Get("Accent"),
			success = theme:Get("Success"),
			warn = theme:Get("Warning"),
			warning = theme:Get("Warning"),
			error = theme:Get("Danger"),
			danger = theme:Get("Danger"),
		}
		local accentColor = o.Color or colorMap[kind] or theme:Get("Accent")
		local dur = o.Duration or (self._behavior and self._behavior.NotificationDuration) or 4
		local pos = (self._behavior and self._behavior.NotificationPosition) or "BottomRight"
		local slideX = (pos == "TopLeft" or pos == "BottomLeft") and -330 or 330

		local wrap = self._r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = self._holder,
		})

		local card = self._r:New("CanvasGroup", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.fromOffset(slideX, 0),
			GroupTransparency = 1,
			Parent = wrap,
		}, {
			self._r:Corner("RadiusMedium"),
			self._r:Stroke("Border", "BorderThickness", 0.2),
		})
		theme:Bind(card, "BackgroundColor3", "Surface")

		self._r:New("Frame", {
			Size = UDim2.new(0, 3, 1, -12),
			Position = UDim2.fromOffset(4, 6),
			BackgroundColor3 = accentColor,
			BorderSizePixel = 0,
			Parent = card,
		}, { self._r:Corner(2) })

		local body = self._r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = card,
		}, {
			self._r:Padding(10, 12, 10, 16),
			self._r:ListLayout(4),
		})

		local header = self._r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Parent = body,
		})

		local badge = self._r:New("Frame", {
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = accentColor,
			BackgroundTransparency = 0.82,
			Parent = header,
		}, { self._r:Corner("RadiusPill") })
		self._r:New("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = o.Icon or TYPE_ICONS[kind] or "•",
			TextColor3 = accentColor,
			Font = theme:Get("FontBold"),
			TextSize = 11,
			Parent = badge,
		})

		self._r:Label({
			Text = o.Title or "Notification",
			Position = UDim2.fromOffset(24, 0),
			Size = UDim2.new(1, -48, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = header,
		}, "PrimaryText", "TextSizeMD", "FontBold")

		local closeBtn = self._r:New("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			BackgroundTransparency = 1,
			Text = "×",
			TextSize = 14,
			Font = theme:Get("FontBold"),
			AutoButtonColor = false,
			Parent = header,
		})
		theme:Bind(closeBtn, "TextColor3", "MutedText")

		if o.Content and o.Content ~= "" then
			self._r:Label({
				Text = o.Content,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = 2,
				Parent = body,
			}, "SecondaryText", "TextSizeSM", "FontRegular")
		end

		local track = self._r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 3),
			LayoutOrder = 3,
			Parent = body,
		}, { self._r:Corner(2) })
		theme:Bind(track, "BackgroundColor3", "ElevatedSurface")

		local fill = self._r:New("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = accentColor,
			Parent = track,
		}, { self._r:Corner(2) })

		local dismissed = false
		local function dismiss()
			if dismissed then
				return
			end
			dismissed = true
			anim:Tween(card, { Position = UDim2.fromOffset(slideX, 0), GroupTransparency = 1 }, 0.22)
			task.delay(0.24, function()
				if wrap.Parent then
					wrap:Destroy()
				end
				self._activeCount = math.max(0, self._activeCount - 1)
				self:_pumpQueue()
			end)
		end

		closeBtn.MouseButton1Click:Connect(dismiss)
		anim:Tween(card, { Position = UDim2.new(), GroupTransparency = 0 }, 0.3)
		anim:Tween(fill, { Size = UDim2.fromScale(0, 1) }, dur, Enum.EasingStyle.Linear)

		task.delay(dur, function()
			if card.Parent and not dismissed then
				dismiss()
			end
		end)
	end

	function NotificationManager:Notify(o)
		if self._destroyed then
			return
		end
		local opts = o or {}
		if self._activeCount >= self._maxVisible then
			table.insert(self._queue, opts)
		else
			self:_spawn(opts)
		end
	end

	function NotificationManager:Destroy()
		self._destroyed = true
		table.clear(self._queue)
		self._janitor:Destroy()
		self._gui = nil
		self._holder = nil
	end

	local DialogManager = {}
	DialogManager.__index = DialogManager

	function DialogManager.new(renderer)
		return setmetatable({ _r = renderer }, DialogManager)
	end

	function DialogManager:Confirm(parentGui, opts)
		local o = opts or {}
		local theme = self._r.Theme
		local anim = self._r.Anim

		local backdrop = self._r:New("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 500,
			Parent = parentGui,
		})

		local modal = self._r:New("CanvasGroup", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(360, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			GroupTransparency = 1,
			ZIndex = 501,
			Parent = backdrop,
		}, {
			self._r:Corner("RadiusLarge"),
			self._r:Stroke("Border", "BorderThickness", 0.15),
			self._r:Padding(16),
			self._r:ListLayout(10),
		})
		theme:Bind(modal, "BackgroundColor3", "Surface")
		local scale = self._r:New("UIScale", { Scale = 0.94, Parent = modal })

		self._r:Label({
			Text = o.Title or "Confirm Action",
			Size = UDim2.new(1, 0, 0, 20),
			LayoutOrder = 1,
			Parent = modal,
		}, "PrimaryText", "TextSizeLG", "FontBold")

		if o.Message or o.Content then
			self._r:Label({
				Text = o.Message or o.Content,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = 2,
				Parent = modal,
			}, "SecondaryText", "TextSizeSM", "FontRegular")
		end

		local actions = self._r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundTransparency = 1,
			LayoutOrder = 3,
			Parent = modal,
		}, {
			self._r:ListLayout(8, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center),
		})

		local closed = false
		local function close(confirmed)
			if closed then
				return
			end
			closed = true
			anim:Tween(backdrop, { BackgroundTransparency = 1 }, 0.18)
			anim:Tween(modal, { GroupTransparency = 1 }, 0.16)
			anim:Tween(scale, { Scale = 0.94 }, 0.16)
			task.delay(0.19, function()
				if backdrop.Parent then
					backdrop:Destroy()
				end
			end)
			if confirmed then
				self._r.SafeCall(o.OnConfirm)
			else
				self._r.SafeCall(o.OnCancel)
			end
		end

		local cancelBtn = self._r:New("TextButton", {
			Size = UDim2.fromOffset(92, 30),
			Text = o.CancelText or "Cancel",
			Font = theme:Get("FontMedium"),
			TextSize = theme:Get("TextSizeSM"),
			AutoButtonColor = false,
			LayoutOrder = 1,
			Parent = actions,
		}, { self._r:Corner("RadiusSmall"), self._r:Stroke("Border", 1, 0.3) })
		theme:Bind(cancelBtn, "BackgroundColor3", "ElevatedSurface")
		theme:Bind(cancelBtn, "TextColor3", "PrimaryText")
		self._r:AttachHover(cancelBtn, "ElevatedSurface", "HoverSurface")

		local confirmBtn = self._r:New("TextButton", {
			Size = UDim2.fromOffset(102, 30),
			Text = o.ConfirmText or "Confirm",
			Font = theme:Get("FontBold"),
			TextSize = theme:Get("TextSizeSM"),
			TextColor3 = Color3.new(1, 1, 1),
			AutoButtonColor = false,
			LayoutOrder = 2,
			Parent = actions,
		}, { self._r:Corner("RadiusSmall") })
		theme:Bind(confirmBtn, "BackgroundColor3", o.Danger and "Danger" or "Accent")

		cancelBtn.MouseButton1Click:Connect(function() close(false) end)
		confirmBtn.MouseButton1Click:Connect(function() close(true) end)
		backdrop.MouseButton1Click:Connect(function()
			if o.DismissOnBackdrop ~= false then
				close(false)
			end
		end)

		anim:Tween(backdrop, { BackgroundTransparency = 0.45 }, 0.2)
		anim:Tween(modal, { GroupTransparency = 0 }, 0.22)
		anim:Tween(scale, { Scale = 1 }, 0.24, Enum.EasingStyle.Back)
	end

	local TooltipManager = {}
	TooltipManager.__index = TooltipManager

	function TooltipManager.new(renderer)
		return setmetatable({ _r = renderer, _current = nil, _activeTarget = nil }, TooltipManager)
	end

	function TooltipManager:Attach(target, text, janitor)
		local function show()
			if not target.Parent or not text or text == "" then
				return
			end
			self:Hide()
			self._activeTarget = target
			local gui = target:FindFirstAncestorOfClass("ScreenGui")
			if not gui then
				return
			end
			local tip = self._r:New("Frame", {
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				ZIndex = 900,
				Parent = gui,
			}, {
				self._r:Corner("RadiusSmall"),
				self._r:Stroke("Border", 1, 0.2),
				self._r:Padding(6, 10, 6, 10),
			})
			self._r.Theme:Bind(tip, "BackgroundColor3", "ElevatedSurface")
			self._r:Label({
				Text = text,
				AutomaticSize = Enum.AutomaticSize.XY,
				Size = UDim2.fromOffset(0, 0),
				ZIndex = 901,
				Parent = tip,
			}, "PrimaryText", "TextSizeXS", "FontMedium")

			local mouse = UserInputService:GetMouseLocation()
			local vp = Environment.GetViewportSize()
			tip.Position = UDim2.fromOffset(
				math.clamp(mouse.X + 14, 8, math.max(8, vp.X - 220)),
				math.clamp(mouse.Y + 14, 8, math.max(8, vp.Y - 60))
			)
			self._current = tip
		end

		local c1 = target.MouseEnter:Connect(show)
		local c2 = target.MouseLeave:Connect(function()
			if self._activeTarget == target then
				self:Hide()
			end
		end)
		local c3 = target.Destroying:Connect(function()
			if self._activeTarget == target then
				self:Hide()
			end
		end)
		if janitor then
			janitor:Add(c1)
			janitor:Add(c2)
			janitor:Add(c3)
		end
	end

	function TooltipManager:Hide()
		self._activeTarget = nil
		if self._current and self._current.Parent then
			self._current:Destroy()
		end
		self._current = nil
	end

	function TooltipManager:Destroy()
		self:Hide()
	end

	local ContextMenuManager = {}
	ContextMenuManager.__index = ContextMenuManager

	function ContextMenuManager.new(renderer)
		return setmetatable({ _r = renderer, _active = nil, _outsideConn = nil }, ContextMenuManager)
	end

	function ContextMenuManager:Close()
		if self._outsideConn then
			self._outsideConn:Disconnect()
			self._outsideConn = nil
		end
		if self._active and self._active.Parent then
			self._active:Destroy()
		end
		self._active = nil
	end

	function ContextMenuManager:Show(parentGui, items, position)
		self:Close()
		local theme = self._r.Theme
		local anim = self._r.Anim
		local pos = position or UserInputService:GetMouseLocation()
		local vp = Environment.GetViewportSize()

		local menu = self._r:New("CanvasGroup", {
			Size = UDim2.fromOffset(186, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			GroupTransparency = 1,
			ZIndex = 950,
			Parent = parentGui,
		}, {
			self._r:Corner("RadiusMedium"),
			self._r:Stroke("Border", 1, 0.15),
			self._r:Padding(6),
			self._r:ListLayout(2),
		})
		theme:Bind(menu, "BackgroundColor3", "Surface")

		for idx, item in ipairs(items or {}) do
			if item.Divider then
				local div = self._r:New("Frame", {
					Size = UDim2.new(1, 0, 0, 1),
					BorderSizePixel = 0,
					LayoutOrder = idx,
					Parent = menu,
				})
				theme:Bind(div, "BackgroundColor3", "Border")
			else
				local btn = self._r:New("TextButton", {
					Size = UDim2.new(1, 0, 0, 28),
					BackgroundTransparency = 1,
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = idx,
					Parent = menu,
				}, { self._r:Corner("RadiusSmall") })
				theme:Bind(btn, "BackgroundColor3", "HoverSurface")

				local colorTok = item.Disabled and "MutedText" or (item.Danger and "Danger" or "PrimaryText")
				local textOffset = item.Icon and 26 or 10
				if item.Icon then
					self._r:Label({
						Text = item.Icon,
						Position = UDim2.fromOffset(8, 0),
						Size = UDim2.fromOffset(16, 28),
						TextXAlignment = Enum.TextXAlignment.Center,
						Parent = btn,
					}, colorTok, "TextSizeSM", "FontMedium")
				end
				self._r:Label({
					Text = item.Label or "Item",
					Position = UDim2.fromOffset(textOffset, 0),
					Size = UDim2.new(1, -textOffset - 8, 1, 0),
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = btn,
				}, colorTok, "TextSizeSM", "FontMedium")

				if not item.Disabled then
					btn.MouseEnter:Connect(function() anim:Tween(btn, { BackgroundTransparency = 0 }, 0.1) end)
					btn.MouseLeave:Connect(function() anim:Tween(btn, { BackgroundTransparency = 1 }, 0.1) end)
					btn.MouseButton1Click:Connect(function()
						self:Close()
						self._r.SafeCall(item.Callback)
					end)
				end
			end
		end

		local estH = math.min(#(items or {}) * 30 + 16, 320)
		menu.Position = UDim2.fromOffset(
			math.clamp(pos.X, 8, math.max(8, vp.X - 196)),
			math.clamp(pos.Y, 8, math.max(8, vp.Y - estH))
		)
		self._active = menu
		anim:Tween(menu, { GroupTransparency = 0 }, 0.14)

		task.defer(function()
			if self._active ~= menu then
				return
			end
			self._outsideConn = UserInputService.InputBegan:Connect(function(input)
				if InputManager.IsPress(input) then
					local p = input.Position
					local mp, ms = menu.AbsolutePosition, menu.AbsoluteSize
					if p.X < mp.X or p.X > mp.X + ms.X or p.Y < mp.Y or p.Y > mp.Y + ms.Y then
						self:Close()
					end
				end
			end)
		end)
	end

	function ContextMenuManager:Destroy()
		self:Close()
	end

	-- =========================================================================
	-- 8. CONFIG MANAGER
	-- =========================================================================
	local ConfigManager = {}
	ConfigManager.__index = ConfigManager

	local CURRENT_SCHEMA_VERSION = 2

	function ConfigManager.new(storage, state, themeEngine, layoutState, behaviorState)
		return setmetatable({
			_storage = storage,
			_state = state,
			_theme = themeEngine,
			_layout = layoutState,
			_behavior = behaviorState,
			_activeProfile = "default",
			OnProfileChanged = Signal.new(),
		}, ConfigManager)
	end

	function ConfigManager:GetActiveProfile()
		return self._activeProfile
	end

	function ConfigManager:SetFolder(folder)
		self._storage:SetFolder(folder)
	end

	local function sanitizeValue(v)
		local t = typeof(v)
		if t == "string" or t == "number" or t == "boolean" then
			return v
		elseif t == "Color3" then
			return { __auroraType = "Color3", r = math.round(v.R * 255), g = math.round(v.G * 255), b = math.round(v.B * 255) }
		elseif t == "EnumItem" then
			return { __auroraType = "EnumItem", enumType = tostring(v.EnumType), name = v.Name }
		elseif t == "table" then
			local out = {}
			for k, sub in pairs(v) do
				if typeof(k) == "string" or typeof(k) == "number" then
					local sv = sanitizeValue(sub)
					if sv ~= nil then
						out[k] = sv
					end
				end
			end
			return out
		end
		return nil
	end

	local function deserializeValue(v)
		if typeof(v) ~= "table" then
			return v
		end
		if v.__auroraType == "Color3" then
			return Color3.fromRGB(
				math.clamp(tonumber(v.r) or 255, 0, 255),
				math.clamp(tonumber(v.g) or 255, 0, 255),
				math.clamp(tonumber(v.b) or 255, 0, 255)
			)
		elseif v.__auroraType == "EnumItem" and typeof(v.name) == "string" then
			local ok, kc = pcall(function()
				return Enum.KeyCode[v.name]
			end)
			if ok and typeof(kc) == "EnumItem" then
				return kc
			end
			return v.name
		end
		local out = {}
		for k, sub in pairs(v) do
			out[k] = deserializeValue(sub)
		end
		return out
	end

	function ConfigManager:BuildSnapshot()
		local flagsOut, layoutOut, behaviorOut = {}, {}, {}
		for flag, val in pairs(self._state:GetAllFlags()) do
			local sv = sanitizeValue(val)
			if sv ~= nil then
				flagsOut[flag] = sv
			end
		end
		for k, v in pairs(self._layout) do
			local sv = sanitizeValue(v)
			if sv ~= nil then
				layoutOut[k] = sv
			end
		end
		for k, v in pairs(self._behavior) do
			local sv = sanitizeValue(v)
			if sv ~= nil then
				behaviorOut[k] = sv
			end
		end
		return {
			SchemaVersion = CURRENT_SCHEMA_VERSION,
			Profile = self._activeProfile,
			SavedAt = os.time(),
			Flags = flagsOut,
			Theme = self._theme:SerializeTheme(),
			Layout = layoutOut,
			Behavior = behaviorOut,
		}
	end

	function ConfigManager:Migrate(raw)
		if typeof(raw) ~= "table" then
			return false, nil, "Configuration payload must be a JSON object"
		end
		if raw.SchemaVersion == nil and raw.Flags == nil then
			local migrated = { SchemaVersion = CURRENT_SCHEMA_VERSION, Profile = self._activeProfile, Flags = {} }
			for k, v in pairs(raw) do
				if typeof(k) == "string" then
					migrated.Flags[k] = v
				end
			end
			return true, migrated, nil
		end
		local ver = tonumber(raw.SchemaVersion) or 1
		if ver > CURRENT_SCHEMA_VERSION then
			return false, nil, "Unsupported future schema version: " .. tostring(ver)
		end
		return true, {
			SchemaVersion = CURRENT_SCHEMA_VERSION,
			Profile = typeof(raw.Profile) == "string" and raw.Profile or self._activeProfile,
			Flags = typeof(raw.Flags) == "table" and raw.Flags or {},
			Theme = typeof(raw.Theme) == "table" and raw.Theme or nil,
			Layout = typeof(raw.Layout) == "table" and raw.Layout or nil,
			Behavior = typeof(raw.Behavior) == "table" and raw.Behavior or nil,
		}, nil
	end

	function ConfigManager:ApplySnapshot(data, applyThemeAndSettings)
		if typeof(data.Flags) == "table" then
			for flag, rawVal in pairs(data.Flags) do
				local comp = self._state:GetComponent(flag)
				if comp and typeof(comp.Set) == "function" then
					pcall(comp.Set, comp, deserializeValue(rawVal))
				end
			end
		end
		if applyThemeAndSettings ~= false then
			if typeof(data.Theme) == "table" then
				local valid, built = self._theme:ValidateAndBuildTheme(data.Theme)
				if valid and built then
					for k, v in pairs(built) do
						self._theme._tokens[k] = v
					end
					self._theme:Propagate(nil, true)
				end
			end
			if typeof(data.Layout) == "table" then
				for k, v in pairs(data.Layout) do
					if self._layout[k] ~= nil then
						local dv = deserializeValue(v)
						if typeof(dv) == typeof(self._layout[k]) then
							self._layout[k] = dv
						end
					end
				end
			end
			if typeof(data.Behavior) == "table" then
				for k, v in pairs(data.Behavior) do
					if self._behavior[k] ~= nil then
						local dv = deserializeValue(v)
						if typeof(dv) == typeof(self._behavior[k]) then
							self._behavior[k] = dv
						end
					end
				end
			end
		end
	end

	function ConfigManager:ExportJSON()
		return HttpService:JSONEncode(self:BuildSnapshot())
	end

	function ConfigManager:ImportJSON(jsonStr)
		if typeof(jsonStr) ~= "string" or jsonStr == "" then
			return false, "Empty configuration JSON"
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, jsonStr)
		if not ok then
			return false, "Invalid JSON syntax"
		end
		local valid, migrated, err = self:Migrate(decoded)
		if not valid or not migrated then
			return false, err
		end
		self:ApplySnapshot(migrated, true)
		return true, nil
	end

	function ConfigManager:Save(name)
		local profile = (name and name ~= "") and name or self._activeProfile
		self._activeProfile = profile
		self._storage:EnsureSubfolder("configs")
		local ok, err = self._storage:Write("configs/" .. profile .. ".json", self:ExportJSON())
		if ok then
			self.OnProfileChanged:Fire(profile)
		end
		return ok, err
	end

	function ConfigManager:Load(name)
		local profile = (name and name ~= "") and name or self._activeProfile
		local ok, raw = self._storage:Read("configs/" .. profile .. ".json")
		if not ok or not raw then
			return false, "Profile not found: " .. profile
		end
		local imported, err = self:ImportJSON(raw)
		if imported then
			self._activeProfile = profile
			self.OnProfileChanged:Fire(profile)
		end
		return imported, err
	end

	function ConfigManager:Delete(name)
		if not name or name == "" then
			return false
		end
		self._storage:Delete("configs/" .. name .. ".json")
		if self._activeProfile == name then
			self._activeProfile = "default"
		end
		self.OnProfileChanged:Fire(self._activeProfile)
		return true
	end

	function ConfigManager:Rename(oldName, newName)
		if not oldName or oldName == "" or not newName or newName == "" then
			return false, "Invalid profile name"
		end
		local ok, raw = self._storage:Read("configs/" .. oldName .. ".json")
		if not ok or not raw then
			return false, "Source profile not found"
		end
		local wrote, err = self._storage:Write("configs/" .. newName .. ".json", raw)
		if not wrote then
			return false, err
		end
		self._storage:Delete("configs/" .. oldName .. ".json")
		if self._activeProfile == oldName then
			self._activeProfile = newName
		end
		self.OnProfileChanged:Fire(self._activeProfile)
		return true, nil
	end

	function ConfigManager:List()
		local list = self._storage:List("configs", ".json")
		if not table.find(list, "default") then
			table.insert(list, 1, "default")
		end
		return list
	end

	function ConfigManager:Destroy()
		self.OnProfileChanged:Destroy()
	end

	-- =========================================================================
	-- 9. WINDOW MANAGER
	-- =========================================================================
	local WindowManager = {}
	WindowManager.__index = WindowManager

	function WindowManager.new(ctx)
		return setmetatable({
			_ctx = ctx,
			_windows = {},
			_topDisplayOrder = 100,
			_destroyed = false,
		}, WindowManager)
	end

	function WindowManager:FocusWindow(win)
		self._topDisplayOrder += 1
		if win._gui then
			win._gui.DisplayOrder = self._topDisplayOrder
		end
		for _, w in ipairs(self._windows) do
			if w.OnFocusChanged then
				w.OnFocusChanged:Fire(w == win)
			end
		end
	end

	function WindowManager:ApplyLayoutAll()
		for _, w in ipairs(self._windows) do
			if w._applyLayout then
				w:_applyLayout()
			end
		end
	end

	function WindowManager:CreateWindow(opts)
		local o = opts or {}
		local ctx = self._ctx
		local r = ctx.Renderer
		local theme = ctx.Theme
		local anim = ctx.Anim
		local inputMgr = ctx.Input
		local caps = Environment.GetCapabilities()
		local layoutCfg = ctx.Layout
		local behaviorCfg = ctx.Behavior

		local winId = o.Id or ("win_" .. HttpService:GenerateGUID(false):sub(1, 8))
		local janitor = Janitor.new()

		if o.ConfigFolder and ctx.Config then
			ctx.Config:SetFolder(o.ConfigFolder)
		end

		local vp = Environment.GetViewportSize()
		local isMobile = caps.IsTouchDevice or vp.X < 680
		local W = math.clamp(o.Width or (isMobile and 460 or layoutCfg.WindowWidth or 680), 320, math.max(340, vp.X - 24))
		local H = math.clamp(o.Height or (isMobile and 320 or layoutCfg.WindowHeight or 460), 240, math.max(260, vp.Y - 24))
		local sideW = isMobile and math.min(140, layoutCfg.SidebarWidth or 175) or (layoutCfg.SidebarWidth or 175)

		self._topDisplayOrder += 1
		local gui = r:New("ScreenGui", {
			Name = "Aurora_" .. winId,
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = self._topDisplayOrder,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		})
		Environment.MountGui(gui, o.PreferPlayerGui or ctx.PreferPlayerGui)
		janitor:Add(gui, "ScreenGui")

		local root = r:New("CanvasGroup", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(W, H),
			GroupTransparency = 1,
			ClipsDescendants = true,
			Parent = gui,
		}, {
			r:Corner("RadiusLarge"),
			r:Stroke("Border", "BorderThickness", 0.15),
		})
		theme:Bind(root, "BackgroundColor3", "Background")
		theme:Bind(root, "BackgroundTransparency", "BackgroundTransparency")

		local uiScale = r:New("UIScale", { Scale = 0.94, Parent = root })

		local win = {
			Id = winId,
			Title = o.Title or "Aurora",
			Subtitle = o.Subtitle or "",
			Tabs = {},
			Visible = true,
			Minimized = false,
			SidebarCollapsed = false,
			ToggleKey = o.ToggleKey or behaviorCfg.ToggleKey or Enum.KeyCode.RightShift,
			_gui = gui,
			_root = root,
			_uiScale = uiScale,
			_janitor = janitor,
			_active = nil,
			_width = W,
			_height = H,
			_minWidth = o.MinWidth or 380,
			_minHeight = o.MinHeight or 280,
			_sidebarWidth = sideW,
			_destroyed = false,
			OnClosed = Signal.new(),
			OnFocusChanged = Signal.new(),
		}

		if o.PersistPosition ~= false and ctx.Storage then
			local okPos, rawPos = ctx.Storage:Read("window_" .. winId .. ".json")
			if okPos and rawPos then
				local okDec, posData = pcall(HttpService.JSONDecode, HttpService, rawPos)
				if okDec and typeof(posData) == "table" then
					if tonumber(posData.x) and tonumber(posData.y) then
						root.Position = UDim2.new(0.5, posData.x, 0.5, posData.y)
					end
					if tonumber(posData.w) and tonumber(posData.h) then
						W = math.clamp(posData.w, win._minWidth, math.max(win._minWidth, vp.X - 24))
						H = math.clamp(posData.h, win._minHeight, math.max(win._minHeight, vp.Y - 24))
						win._width, win._height = W, H
						root.Size = UDim2.fromOffset(W, H)
					end
				end
			end
		end

		local function savePosition()
			if o.PersistPosition == false or not ctx.Storage then
				return
			end
			ctx.Storage:Write("window_" .. winId .. ".json", HttpService:JSONEncode({
				x = math.round(root.Position.X.Offset),
				y = math.round(root.Position.Y.Offset),
				w = math.round(win._width),
				h = math.round(win._height),
			}))
		end

		local topHeight = 44
		local top = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, topHeight),
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = root,
		})
		theme:Bind(top, "BackgroundColor3", "Surface")
		theme:Bind(top, "BackgroundTransparency", "SurfaceTransparency")

		local topDivider = r:New("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 1),
			BorderSizePixel = 0,
			Parent = top,
		})
		theme:Bind(topDivider, "BackgroundColor3", "Border")

		local leftCluster = r:New("Frame", {
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -100, 1, 0),
			BackgroundTransparency = 1,
			Parent = top,
		}, { r:ListLayout(8, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })

		local sideToggleBtn = r:New("TextButton", {
			Size = UDim2.fromOffset(26, 26),
			BackgroundTransparency = 1,
			Text = "≡",
			TextSize = 16,
			AutoButtonColor = false,
			LayoutOrder = 1,
			Parent = leftCluster,
		}, { r:Corner("RadiusSmall") })
		theme:Bind(sideToggleBtn, "BackgroundColor3", "HoverSurface")
		theme:Bind(sideToggleBtn, "TextColor3", "SecondaryText")
		theme:Bind(sideToggleBtn, "Font", "FontBold")

		r:Label({
			Text = win.Title,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			LayoutOrder = 2,
			Parent = leftCluster,
		}, "PrimaryText", "TextSizeLG", "FontBold")

		if win.Subtitle ~= "" then
			local pill = r:New("Frame", {
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, 20),
				LayoutOrder = 3,
				Parent = leftCluster,
			}, { r:Corner("RadiusSmall"), r:Padding(0, 7, 0, 7) })
			theme:Bind(pill, "BackgroundColor3", "ElevatedSurface")
			r:Label({
				Text = win.Subtitle,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				Parent = pill,
			}, "MutedText", "TextSizeXS", "FontMedium")
		end

		local rightCluster = r:New("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(64, 28),
			BackgroundTransparency = 1,
			Parent = top,
		}, { r:ListLayout(6, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })

		local function makeTopBtn(txt, hoverColorToken, order)
			local b = r:New("TextButton", {
				Size = UDim2.fromOffset(26, 26),
				BackgroundTransparency = 1,
				Text = txt,
				TextSize = 14,
				AutoButtonColor = false,
				LayoutOrder = order,
				Parent = rightCluster,
			}, { r:Corner("RadiusSmall") })
			theme:Bind(b, "BackgroundColor3", "HoverSurface")
			theme:Bind(b, "TextColor3", "SecondaryText")
			theme:Bind(b, "Font", "FontBold")
			b.MouseEnter:Connect(function()
				anim:Tween(b, { BackgroundTransparency = 0, TextColor3 = theme:Get(hoverColorToken) }, 0.12)
			end)
			b.MouseLeave:Connect(function()
				anim:Tween(b, { BackgroundTransparency = 1, TextColor3 = theme:Get("SecondaryText") }, 0.12)
			end)
			return b
		end

		local minBtn = makeTopBtn("–", "PrimaryText", 1)
		local closeBtn = makeTopBtn("×", "Danger", 2)

		local side = r:New("Frame", {
			Position = UDim2.fromOffset(0, topHeight),
			Size = UDim2.new(0, sideW, 1, -topHeight),
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Parent = root,
		})
		theme:Bind(side, "BackgroundColor3", "Surface")
		theme:Bind(side, "BackgroundTransparency", "SurfaceTransparency")

		local sideDivider = r:New("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 1, 1, 0),
			BorderSizePixel = 0,
			Parent = side,
		})
		theme:Bind(sideDivider, "BackgroundColor3", "Border")

		local searchWrap = r:New("Frame", {
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.new(1, -16, 0, 30),
			Parent = side,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.35) })
		theme:Bind(searchWrap, "BackgroundColor3", "ElevatedSurface")

		local searchBox = r:New("TextBox", {
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -16, 1, 0),
			BackgroundTransparency = 1,
			Text = "",
			PlaceholderText = "Search tabs...",
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = searchWrap,
		})
		theme:Bind(searchBox, "TextColor3", "PrimaryText")
		theme:Bind(searchBox, "PlaceholderColor3", "MutedText")
		theme:Bind(searchBox, "Font", "FontMedium")
		theme:Bind(searchBox, "TextSize", "TextSizeSM")

		local tabList = r:New("ScrollingFrame", {
			Position = UDim2.fromOffset(0, 44),
			Size = UDim2.new(1, 0, 1, -44),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 2,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Parent = side,
		}, { r:ListLayout(4), r:Padding(4, 8, 8, 8) })
		theme:Bind(tabList, "ScrollBarImageColor3", "Border")

		local content = r:New("Frame", {
			Position = UDim2.fromOffset(sideW, topHeight),
			Size = UDim2.new(1, -sideW, 1, -topHeight),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Parent = root,
		})

		local resizeGrip = r:New("TextButton", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromOffset(18, 18),
			BackgroundTransparency = 1,
			Text = "◢",
			TextSize = 11,
			AutoButtonColor = false,
			ZIndex = 20,
			Parent = root,
		})
		theme:Bind(resizeGrip, "TextColor3", "MutedText")

		function win:_applyLayout()
			if self._destroyed then
				return
			end
			local sw = self.SidebarCollapsed and 0 or (isMobile and math.min(140, layoutCfg.SidebarWidth or 175) or (layoutCfg.SidebarWidth or 175))
			self._sidebarWidth = sw
			local isRight = layoutCfg.SidebarPosition == "Right"

			anim:Tween(side, { Size = UDim2.new(0, sw, 1, -topHeight) }, 0.2)
			if isRight then
				anim:Tween(side, { Position = UDim2.new(1, -sw, 0, topHeight) }, 0.2)
				anim:Tween(content, { Position = UDim2.fromOffset(0, topHeight), Size = UDim2.new(1, -sw, 1, -topHeight) }, 0.2)
				sideDivider.AnchorPoint = Vector2.new(0, 0)
				sideDivider.Position = UDim2.fromScale(0, 0)
			else
				anim:Tween(side, { Position = UDim2.fromOffset(0, topHeight) }, 0.2)
				anim:Tween(content, { Position = UDim2.fromOffset(sw, topHeight), Size = UDim2.new(1, -sw, 1, -topHeight) }, 0.2)
				sideDivider.AnchorPoint = Vector2.new(1, 0)
				sideDivider.Position = UDim2.fromScale(1, 0)
			end

			if self.Visible and not self.Minimized then
				uiScale.Scale = layoutCfg.UIScale or 1
			end

			for _, tab in ipairs(self.Tabs) do
				if tab._listLayout then
					tab._listLayout.Padding = UDim.new(0, layoutCfg.ComponentSpacing or 8)
				end
				if tab._pad then
					local p = UDim.new(0, layoutCfg.ContentPadding or 14)
					tab._pad.PaddingTop = p
					tab._pad.PaddingBottom = p
					tab._pad.PaddingLeft = p
					tab._pad.PaddingRight = p
				end
			end
		end

		sideToggleBtn.MouseButton1Click:Connect(function()
			win.SidebarCollapsed = not win.SidebarCollapsed
			win:_applyLayout()
		end)

		local winMgr = self
		janitor:Connect(root.InputBegan, function(input)
			if inputMgr.IsPress(input) then
				winMgr:FocusWindow(win)
			end
		end)

		local dragging, dragStart, startPos = false, nil, nil
		janitor:Connect(top.InputBegan, function(input)
			if inputMgr.IsPress(input) and behaviorCfg.DraggableWindows ~= false then
				winMgr:FocusWindow(win)
				dragging = true
				dragStart = input.Position
				startPos = root.Position
			end
		end)

		local resizing, resizeStart, startSize = false, nil, nil
		janitor:Connect(resizeGrip.InputBegan, function(input)
			if inputMgr.IsPress(input) and behaviorCfg.ResizableWindows ~= false and not win.Minimized then
				winMgr:FocusWindow(win)
				resizing = true
				resizeStart = input.Position
				startSize = Vector2.new(win._width, win._height)
			end
		end)

		janitor:Connect(UserInputService.InputChanged, function(input)
			if dragging and dragStart and startPos and inputMgr.IsMove(input) then
				local d = input.Position - dragStart
				local curVp = Environment.GetViewportSize()
				root.Position = UDim2.new(
					startPos.X.Scale,
					math.clamp(startPos.X.Offset + d.X, -curVp.X / 2 + 80, curVp.X / 2 - 80),
					startPos.Y.Scale,
					math.clamp(startPos.Y.Offset + d.Y, -curVp.Y / 2 + 30, curVp.Y / 2 - 30)
				)
			elseif resizing and resizeStart and startSize and inputMgr.IsMove(input) then
				local d = input.Position - resizeStart
				local curVp = Environment.GetViewportSize()
				win._width = math.clamp(startSize.X + d.X, win._minWidth, curVp.X - 24)
				win._height = math.clamp(startSize.Y + d.Y, win._minHeight, curVp.Y - 24)
				root.Size = UDim2.fromOffset(win._width, win._height)
			end
		end)

		janitor:Connect(UserInputService.InputEnded, function(input)
			if inputMgr.IsPress(input) and (dragging or resizing) then
				dragging = false
				resizing = false
				savePosition()
			end
		end)

		function win:SetVisible(v)
			self.Visible = v
			if v then
				root.Visible = true
				anim:Tween(root, { GroupTransparency = 0 }, theme:Get("AnimNormal"))
				anim:Tween(uiScale, { Scale = layoutCfg.UIScale or 1 }, theme:Get("AnimSlow"), Enum.EasingStyle.Back)
				winMgr:FocusWindow(self)
			else
				anim:Tween(root, { GroupTransparency = 1 }, theme:Get("AnimFast"))
				anim:Tween(uiScale, { Scale = (layoutCfg.UIScale or 1) * 0.94 }, theme:Get("AnimFast"))
				task.delay(0.2, function()
					if not self.Visible and root.Parent then
						root.Visible = false
					end
				end)
			end
		end

		function win:Toggle()
			self:SetVisible(not self.Visible)
		end

		function win:Minimize(state)
			local target = state ~= nil and state or not self.Minimized
			if behaviorCfg.MinimizeBehavior == "Hide" then
				self:SetVisible(not target)
				return
			end
			self.Minimized = target
			anim:Tween(root, { Size = UDim2.fromOffset(self._width, self.Minimized and topHeight or self._height) }, theme:Get("AnimNormal"))
		end

		function win:SetSize(newW, newH)
			local curVp = Environment.GetViewportSize()
			self._width = math.clamp(newW, self._minWidth, curVp.X - 24)
			self._height = math.clamp(newH, self._minHeight, curVp.Y - 24)
			if not self.Minimized then
				anim:Tween(root, { Size = UDim2.fromOffset(self._width, self._height) }, theme:Get("AnimNormal"))
			end
		end

		minBtn.MouseButton1Click:Connect(function() win:Minimize() end)
		closeBtn.MouseButton1Click:Connect(function()
			if o.DestroyOnClose then
				win:Destroy()
			else
				win:SetVisible(false)
			end
		end)

		janitor:Add(inputMgr:RegisterToggle(function()
			return win.ToggleKey
		end, function()
			win:Toggle()
		end))

		if isMobile then
			local fab = r:New("TextButton", {
				Position = UDim2.new(0, 14, 0.5, -22),
				Size = UDim2.fromOffset(44, 44),
				Text = "☰",
				TextSize = 18,
				AutoButtonColor = false,
				ZIndex = 50,
				Parent = gui,
			}, { r:Corner("RadiusPill"), r:Stroke("Accent", 1.5, 0.2) })
			theme:Bind(fab, "BackgroundColor3", "Surface")
			theme:Bind(fab, "TextColor3", "PrimaryText")
			theme:Bind(fab, "Font", "FontBold")
			fab.MouseButton1Click:Connect(function() win:Toggle() end)
		end

		if o.Loading ~= false then
			local splash = r:New("CanvasGroup", { Size = UDim2.fromScale(1, 1), ZIndex = 100, Parent = root })
			theme:Bind(splash, "BackgroundColor3", "Background")
			r:Label({
				Text = win.Title,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.new(0, 0, 0.5, -36),
				Size = UDim2.new(1, 0, 0, 26),
				Parent = splash,
			}, "PrimaryText", "TextSizeXL", "FontBold")
			local statusLbl = r:Label({
				Text = "Loading...",
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.new(0, 0, 0.5, -6),
				Size = UDim2.new(1, 0, 0, 18),
				Parent = splash,
			}, "SecondaryText", "TextSizeSM", "FontRegular")
			local barBg = r:New("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0.5, 22),
				Size = UDim2.fromOffset(180, 4),
				Parent = splash,
			}, { r:Corner(2) })
			theme:Bind(barBg, "BackgroundColor3", "ElevatedSurface")
			local barFill = r:New("Frame", { Size = UDim2.fromScale(0, 1), Parent = barBg }, { r:Corner(2) })
			theme:Bind(barFill, "BackgroundColor3", "Accent")

			task.spawn(function()
				local steps = o.LoadingSteps or { "Initializing", "Applying theme", "Ready" }
				for i, stepText in ipairs(steps) do
					if win._destroyed then
						return
					end
					statusLbl.Text = stepText
					anim:Tween(barFill, { Size = UDim2.fromScale(i / #steps, 1) }, 0.18)
					task.wait(0.18)
				end
				anim:Tween(splash, { GroupTransparency = 1 }, 0.25)
				task.wait(0.26)
				if splash.Parent then
					splash:Destroy()
				end
			end)
		end

		anim:Tween(root, { GroupTransparency = 0 }, theme:Get("AnimNormal"))
		anim:Tween(uiScale, { Scale = layoutCfg.UIScale or 1 }, theme:Get("AnimSlow"), Enum.EasingStyle.Back)

		janitor:Connect(searchBox:GetPropertyChangedSignal("Text"), function()
			local q = string.lower(searchBox.Text)
			for _, tab in ipairs(win.Tabs) do
				if tab._navBtn then
					local match = q == ""
						or string.find(string.lower(tab.Name), q, 1, true) ~= nil
						or (tab.Description ~= "" and string.find(string.lower(tab.Description), q, 1, true) ~= nil)
					tab._navBtn.Visible = match
				end
			end
		end)

		function win:AddTab(nameOrOpts)
			local tabOpts = typeof(nameOrOpts) == "table" and nameOrOpts or { Name = tostring(nameOrOpts or "Tab") }
			local tabName = tabOpts.Name or "Tab"
			local tabDesc = tabOpts.Description or ""
			local tabIcon = tabOpts.Icon

			local btnH = tabDesc ~= "" and 44 or 34
			local btn = r:New("TextButton", {
				Size = UDim2.new(1, 0, 0, btnH),
				BackgroundTransparency = 1,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = #self.Tabs + 1,
				Parent = tabList,
			}, { r:Corner("RadiusSmall") })
			theme:Bind(btn, "BackgroundColor3", "ElevatedSurface")

			local indicator = r:New("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 0, 0.5, 0),
				Size = UDim2.fromOffset(3, 0),
				Parent = btn,
			}, { r:Corner(2) })
			theme:Bind(indicator, "BackgroundColor3", "Accent")

			local textX = 12
			if tabIcon and tabIcon ~= "" then
				r:Label({
					Text = tabIcon,
					Position = UDim2.fromOffset(10, 0),
					Size = UDim2.fromOffset(18, btnH),
					TextXAlignment = Enum.TextXAlignment.Center,
					Parent = btn,
				}, "SecondaryText", "TextSizeMD", "FontMedium")
				textX = 32
			end

			local titleText = r:Label({
				Text = tabName,
				Position = UDim2.fromOffset(textX, tabDesc ~= "" and 4 or 0),
				Size = UDim2.new(1, -textX - 28, 0, tabDesc ~= "" and 18 or btnH),
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = btn,
			}, "SecondaryText", "TextSizeSM", "FontMedium")

			if tabDesc ~= "" then
				r:Label({
					Text = tabDesc,
					Position = UDim2.fromOffset(textX, 22),
					Size = UDim2.new(1, -textX - 10, 0, 14),
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = btn,
				}, "MutedText", "TextSizeXS", "FontRegular")
			end

			local badgeFrame = r:New("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, 18),
				Visible = false,
				Parent = btn,
			}, { r:Corner("RadiusPill"), r:Padding(0, 6, 0, 6) })
			theme:Bind(badgeFrame, "BackgroundColor3", "Accent")

			local badgeLbl = r:Label({
				Text = "",
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = badgeFrame,
			}, "PrimaryText", "TextSizeXS", "FontBold")
			badgeLbl.TextColor3 = Color3.new(1, 1, 1)

			local page = r:New("CanvasGroup", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				GroupTransparency = 1,
				Visible = false,
				Parent = content,
			})

			local pageLayout = r:ListLayout(layoutCfg.ComponentSpacing or 8)
			local pagePad = r:Padding(layoutCfg.ContentPadding or 14)

			local scroll = r:New("ScrollingFrame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 3,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				Parent = page,
			}, { pageLayout, pagePad })
			theme:Bind(scroll, "ScrollBarImageColor3", "Border")

			local tab = setmetatable({
				Name = tabName,
				Description = tabDesc,
				_win = self,
				_ctx = ctx,
				_parent = scroll,
				_page = page,
				_navBtn = btn,
				_listLayout = pageLayout,
				_pad = pagePad,
				_order = 0,
			}, ctx.ContainerClass)

			local function deselect()
				anim:Tween(page, { GroupTransparency = 1 }, theme:Get("AnimFast"))
				task.delay(0.15, function()
					if win._active ~= tab and page.Parent then
						page.Visible = false
					end
				end)
				anim:Tween(btn, { BackgroundTransparency = 1 }, theme:Get("AnimFast"))
				anim:Tween(indicator, { Size = UDim2.fromOffset(3, 0) }, theme:Get("AnimFast"))
				anim:Tween(titleText, { TextColor3 = theme:Get("SecondaryText") }, theme:Get("AnimFast"))
			end

			function tab:Select()
				if win._active == tab then
					return
				end
				if win._active then
					win._active._deselect()
				end
				win._active = tab
				page.Visible = true
				page.Position = UDim2.fromOffset(0, 10)
				anim:Tween(page, { GroupTransparency = 0, Position = UDim2.new() }, theme:Get("AnimNormal"))
				anim:Tween(btn, { BackgroundTransparency = 0 }, theme:Get("AnimFast"))
				anim:Tween(indicator, { Size = UDim2.fromOffset(3, 18) }, theme:Get("AnimNormal"), Enum.EasingStyle.Back)
				anim:Tween(titleText, { TextColor3 = theme:Get("PrimaryText") }, theme:Get("AnimFast"))
			end

			function tab:SetBadge(text, color)
				if not text or text == "" then
					badgeFrame.Visible = false
				else
					badgeLbl.Text = tostring(text)
					if color then
						badgeFrame.BackgroundColor3 = color
					end
					badgeFrame.Visible = true
				end
			end

			tab._deselect = deselect
			btn.MouseButton1Click:Connect(function() tab:Select() end)
			if tabOpts.Badge then
				tab:SetBadge(tabOpts.Badge)
			end

			table.insert(self.Tabs, tab)
			if #self.Tabs == 1 then
				tab:Select()
			end
			return tab
		end

		function win:SaveConfig(name)
			local ok, err = ctx.Config:Save(name)
			ctx.Notifications:Notify({
				Title = "Config",
				Content = ok and ("Saved: " .. (name or ctx.Config:GetActiveProfile())) or (err or "Save failed"),
				Type = ok and "success" or "error",
			})
			return ok
		end

		function win:LoadConfig(name)
			local ok, err = ctx.Config:Load(name)
			ctx.Notifications:Notify({
				Title = "Config",
				Content = ok and ("Loaded: " .. (name or ctx.Config:GetActiveProfile())) or (err or "Load failed"),
				Type = ok and "success" or "warn",
			})
			return ok
		end

		function win:Confirm(confirmOpts)
			ctx.Dialogs:Confirm(gui, confirmOpts)
		end

		function win:ContextMenu(items, pos)
			ctx.ContextMenu:Show(gui, items, pos)
		end

		function win:AddSettingsTab()
			return ctx.ThemeEditor.BuildTab(self, ctx)
		end

		function win:Destroy()
			if self._destroyed then
				return
			end
			self._destroyed = true
			savePosition()
			self.OnClosed:Fire()
			self.OnClosed:Destroy()
			self.OnFocusChanged:Destroy()
			if ctx.State then
				ctx.State:UnregisterWindow(self.Id)
			end
			self._janitor:Destroy()
			local idx = table.find(winMgr._windows, self)
			if idx then
				table.remove(winMgr._windows, idx)
			end
		end

		table.insert(self._windows, win)
		return win
	end

	function WindowManager:DestroyAll()
		for i = #self._windows, 1, -1 do
			self._windows[i]:Destroy()
		end
	end

	-- =========================================================================
	-- 10. COMPONENTS
	-- =========================================================================
	local Container = {}
	Container.__index = Container

	local function nextOrder(self)
		self._order = (self._order or 0) + 1
		return self._order
	end

	local function createRow(self, height, opts)
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local row = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, height or 38),
			ClipsDescendants = true,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, {
			r:Corner("RadiusMedium"),
			r:Stroke("Border", 1, 0.45),
		})
		theme:Bind(row, "BackgroundColor3", "ElevatedSurface")
		if opts and opts.Tooltip and self._ctx.Tooltips then
			self._ctx.Tooltips:Attach(row, opts.Tooltip, self._win._janitor)
		end
		return row
	end

	local function makeLifecycleHandle(self, row, flag, compObj)
		local win = self._win
		local state = self._ctx.State
		local janitor = Janitor.new()
		janitor:Add(row)
		if flag then
			compObj._flag = flag
			state:Register(flag, compObj, win.Id)
		end
		compObj._janitor = janitor
		function compObj:SetVisible(v)
			row.Visible = v == true
		end
		function compObj:Destroy()
			if flag then
				state:Unregister(flag)
			end
			janitor:Destroy()
		end
		win._janitor:Add(function()
			if flag then
				state:Unregister(flag)
			end
			janitor:Destroy()
		end)
		return compObj, janitor
	end

	-- Containers: Section, CollapsibleSection, Card, Groupbox
	function Container:AddSection(name)
		local r = self._ctx.Renderer
		local sec = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, { r:ListLayout(self._ctx.Layout.ComponentSpacing or 8) })

		r:Label({
			Text = string.upper(name or "Section"),
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			Parent = sec,
		}, "MutedText", "TextSizeXS", "FontBold")

		return setmetatable({ _win = self._win, _ctx = self._ctx, _parent = sec, _order = 0 }, Container)
	end

	function Container:AddCollapsibleSection(nameOrOpts)
		local o = typeof(nameOrOpts) == "table" and nameOrOpts or { Name = tostring(nameOrOpts or "Section") }
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local expanded = o.Default ~= false

		local wrap = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, { r:ListLayout(6) })

		local header = r:New("TextButton", {
			Size = UDim2.new(1, 0, 0, 32),
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = 1,
			Parent = wrap,
		}, { r:Corner("RadiusMedium"), r:Stroke("Border", 1, 0.4) })
		theme:Bind(header, "BackgroundColor3", "Surface")

		r:Label({
			Text = o.Name or "Collapsible Section",
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -40, 1, 0),
			Parent = header,
		}, "PrimaryText", "TextSizeSM", "FontBold")

		local arrow = r:Label({
			Text = "▾",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			TextXAlignment = Enum.TextXAlignment.Center,
			Rotation = expanded and 0 or -90,
			Parent = header,
		}, "SecondaryText", "TextSizeSM", "FontBold")

		local body = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Visible = expanded,
			LayoutOrder = 2,
			Parent = wrap,
		}, { r:ListLayout(self._ctx.Layout.ComponentSpacing or 8) })

		local sec = setmetatable({ _win = self._win, _ctx = self._ctx, _parent = body, _order = 0 }, Container)
		function sec:SetExpanded(v)
			expanded = v == true
			body.Visible = expanded
			anim:Tween(arrow, { Rotation = expanded and 0 or -90 }, 0.18)
		end
		function sec:IsExpanded()
			return expanded
		end

		header.MouseButton1Click:Connect(function()
			sec:SetExpanded(not expanded)
		end)
		return sec
	end

	function Container:AddCard(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local card = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, {
			r:Corner("RadiusMedium"),
			r:Stroke("Border", 1, 0.3),
			r:Padding(12),
			r:ListLayout(self._ctx.Layout.ComponentSpacing or 8),
		})
		theme:Bind(card, "BackgroundColor3", "Surface")

		if o.Title then
			r:Label({
				Text = o.Title,
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = 0,
				Parent = card,
			}, "PrimaryText", "TextSizeMD", "FontBold")
		end
		if o.Subtitle then
			r:Label({
				Text = o.Subtitle,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = 0,
				Parent = card,
			}, "SecondaryText", "TextSizeXS", "FontRegular")
		end
		return setmetatable({ _win = self._win, _ctx = self._ctx, _parent = card, _order = 1 }, Container)
	end

	function Container:AddGroupbox(name)
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local box = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, {
			r:Corner("RadiusMedium"),
			r:Stroke("Border", 1, 0.2),
			r:Padding(10),
			r:ListLayout(self._ctx.Layout.ComponentSpacing or 8),
		})
		theme:Bind(box, "BackgroundColor3", "Background")

		local hdr = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = 0,
			Parent = box,
		})
		r:Label({
			Text = name or "Group",
			Size = UDim2.new(1, 0, 0, 18),
			Parent = hdr,
		}, "Accent", "TextSizeSM", "FontBold")
		local line = r:New("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 1),
			BorderSizePixel = 0,
			Parent = hdr,
		})
		theme:Bind(line, "BackgroundColor3", "Border")

		return setmetatable({ _win = self._win, _ctx = self._ctx, _parent = box, _order = 1 }, Container)
	end

	-- Basic & Display Components
	function Container:AddLabel(text)
		local r = self._ctx.Renderer
		local lbl = r:Label({
			Text = text or "",
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, "SecondaryText", "TextSizeSM", "FontRegular")
		local obj = { Value = text or "" }
		function obj:Set(t)
			self.Value = tostring(t or "")
			lbl.Text = self.Value
		end
		function obj:Get()
			return self.Value
		end
		return makeLifecycleHandle(self, lbl, nil, obj)
	end

	function Container:AddParagraph(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local box = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, {
			r:Corner("RadiusMedium"),
			r:Stroke("Border", 1, 0.45),
			r:Padding(10, 12, 10, 12),
			r:ListLayout(4),
		})
		theme:Bind(box, "BackgroundColor3", "ElevatedSurface")

		local titleLbl = r:Label({
			Text = o.Title or "Info",
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 1,
			Parent = box,
		}, "PrimaryText", "TextSizeMD", "FontBold")

		local bodyLbl = r:Label({
			Text = o.Content or "",
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 2,
			Parent = box,
		}, "SecondaryText", "TextSizeSM", "FontRegular")

		local obj = { Value = o.Content or "" }
		function obj:Set(content)
			self.Value = tostring(content or "")
			bodyLbl.Text = self.Value
		end
		function obj:SetTitle(title)
			titleLbl.Text = tostring(title or "")
		end
		function obj:Get()
			return self.Value
		end
		return makeLifecycleHandle(self, box, nil, obj)
	end

	function Container:AddDivider(text)
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local row = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, text and 18 or 8),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		})
		if text and text ~= "" then
			local l = r:Label({
				Text = text,
				AutomaticSize = Enum.AutomaticSize.X,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(0, 16),
				Parent = row,
			}, "MutedText", "TextSizeXS", "FontMedium")
			local leftLine = r:New("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 0, 0.5, 0),
				Size = UDim2.new(0.42, 0, 0, 1),
				BorderSizePixel = 0,
				Parent = row,
			})
			local rightLine = r:New("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0.42, 0, 0, 1),
				BorderSizePixel = 0,
				Parent = row,
			})
			theme:Bind(leftLine, "BackgroundColor3", "Border")
			theme:Bind(rightLine, "BackgroundColor3", "Border")
		else
			local line = r:New("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(1, 0, 0, 1),
				BorderSizePixel = 0,
				Parent = row,
			})
			theme:Bind(line, "BackgroundColor3", "Border")
		end
		return makeLifecycleHandle(self, row, nil, {})
	end

	function Container:AddImage(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local h = o.Height or 120
		local card = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, h + (o.Caption and 26 or 12)),
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, { r:Corner("RadiusMedium"), r:Stroke("Border", 1, 0.4), r:Padding(6) })
		theme:Bind(card, "BackgroundColor3", "ElevatedSurface")

		local img = r:New("ImageLabel", {
			Size = UDim2.new(1, 0, 0, h),
			BackgroundTransparency = 1,
			Image = o.Image or "",
			ScaleType = o.ScaleType or Enum.ScaleType.Fit,
			Parent = card,
		}, { r:Corner("RadiusSmall") })

		if o.Caption then
			r:Label({
				Text = o.Caption,
				Position = UDim2.fromOffset(4, h + 4),
				Size = UDim2.new(1, -8, 0, 16),
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = card,
			}, "MutedText", "TextSizeXS", "FontRegular")
		end

		local obj = { Value = o.Image or "" }
		function obj:Set(assetId)
			self.Value = tostring(assetId or "")
			img.Image = self.Value
		end
		function obj:Get()
			return self.Value
		end
		return makeLifecycleHandle(self, card, nil, obj)
	end

	function Container:AddProgressBar(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local min, max = o.Min or 0, o.Max or 100
		local row = createRow(self, 48, o)

		r:Label({
			Text = o.Name or "Progress",
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(0.65, 0, 0, 18),
			Parent = row,
		}, "PrimaryText", "TextSizeSM", "FontMedium")

		local valLbl = r:Label({
			Text = "0%",
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(0.65, 0, 0, 6),
			Size = UDim2.new(0.35, -12, 0, 18),
			Parent = row,
		}, "SecondaryText", "TextSizeXS", "FontMono")

		local track = r:New("Frame", {
			Position = UDim2.new(0, 12, 1, -16),
			Size = UDim2.new(1, -24, 0, 6),
			Parent = row,
		}, { r:Corner("RadiusPill") })
		theme:Bind(track, "BackgroundColor3", "HoverSurface")

		local fill = r:New("Frame", { Size = UDim2.fromScale(0, 1), Parent = track }, { r:Corner("RadiusPill") })
		theme:Bind(fill, "BackgroundColor3", "Accent")

		local obj = { Value = o.Default or min }
		function obj:Set(v)
			v = math.clamp(tonumber(v) or min, min, max)
			self.Value = v
			local rel = max > min and (v - min) / (max - min) or 0
			valLbl.Text = o.Suffix and (tostring(v) .. o.Suffix) or (math.round(rel * 100) .. "%")
			anim:Tween(fill, { Size = UDim2.fromScale(rel, 1) }, 0.2)
		end
		function obj:Get()
			return self.Value
		end
		obj:Set(obj.Value)
		return makeLifecycleHandle(self, row, o.Flag, obj)
	end

	function Container:AddLoadingIndicator(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local row = createRow(self, 38, o)

		local dot = r:New("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 12, 0.5, 0),
			Size = UDim2.fromOffset(14, 14),
			Parent = row,
		}, { r:Corner("RadiusPill"), r:Stroke("Accent", 2, 0) })
		dot.BackgroundTransparency = 1

		local lbl = r:Label({
			Text = o.Text or "Loading...",
			Position = UDim2.fromOffset(34, 0),
			Size = UDim2.new(1, -46, 1, 0),
			Parent = row,
		}, "SecondaryText", "TextSizeSM", "FontMedium")

		local active = o.Active ~= false
		local obj = { Active = active }
		local handle, janitor = makeLifecycleHandle(self, row, nil, obj)

		janitor:Connect(RunService.RenderStepped, function(dt)
			if active and row.Visible and row.Parent then
				dot.Rotation = (dot.Rotation + dt * 260) % 360
			end
		end)

		function obj:SetText(t)
			lbl.Text = tostring(t or "")
		end
		function obj:SetActive(v)
			active = v == true
			self.Active = active
			dot.Visible = active
		end
		return handle
	end

	function Container:AddEmptyState(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local card = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, {
			r:Corner("RadiusMedium"),
			r:Stroke("Border", 1, 0.35),
			r:Padding(20),
			r:ListLayout(6, Enum.FillDirection.Vertical, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
		})
		theme:Bind(card, "BackgroundColor3", "Surface")

		r:Label({
			Text = o.Icon or "◌",
			Size = UDim2.fromOffset(32, 32),
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 1,
			Parent = card,
		}, "Accent", "TextSizeXL", "FontBold")

		local titleLbl = r:Label({
			Text = o.Title or "Nothing here yet",
			Size = UDim2.new(1, 0, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 2,
			Parent = card,
		}, "PrimaryText", "TextSizeMD", "FontBold")

		local descLbl = r:Label({
			Text = o.Description or "Items will appear here once available.",
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 3,
			Parent = card,
		}, "MutedText", "TextSizeSM", "FontRegular")

		if o.ActionText and o.OnAction then
			local btn = r:New("TextButton", {
				Size = UDim2.fromOffset(120, 30),
				Text = o.ActionText,
				TextColor3 = Color3.new(1, 1, 1),
				Font = theme:Get("FontBold"),
				TextSize = theme:Get("TextSizeSM"),
				AutoButtonColor = false,
				LayoutOrder = 4,
				Parent = card,
			}, { r:Corner("RadiusSmall") })
			theme:Bind(btn, "BackgroundColor3", "Accent")
			btn.MouseButton1Click:Connect(function()
				r.SafeCall(o.OnAction)
			end)
		end

		local obj = {}
		function obj:Set(title, desc)
			if title then titleLbl.Text = title end
			if desc then descLbl.Text = desc end
		end
		return makeLifecycleHandle(self, card, nil, obj)
	end

	-- Interactive Components: Button, Toggle, Checkbox, RadioGroup, Slider
	function Container:AddButton(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local hasDesc = o.Description and o.Description ~= ""
		local row = createRow(self, hasDesc and 52 or 38, o)

		local titleLbl = r:Label({
			Text = o.Name or "Button",
			Position = UDim2.fromOffset(12, hasDesc and 6 or 0),
			Size = UDim2.new(1, -24, 0, hasDesc and 20 or 38),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		if hasDesc then
			r:Label({
				Text = o.Description,
				Position = UDim2.fromOffset(12, 26),
				Size = UDim2.new(1, -24, 0, 16),
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			}, "MutedText", "TextSizeXS", "FontRegular")
		end

		local btn = r:New("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row })
		local obj = {}
		local handle, janitor = makeLifecycleHandle(self, row, nil, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		local function trigger()
			row.BackgroundColor3 = theme:Get("Accent")
			anim:Tween(row, { BackgroundColor3 = theme:Get("ElevatedSurface") }, 0.35)
			if o.Confirm then
				self._win:Confirm({
					Title = o.ConfirmTitle or (o.Name or "Confirm"),
					Message = typeof(o.Confirm) == "string" and o.Confirm or "Are you sure you want to continue?",
					Danger = o.Danger,
					OnConfirm = function() r.SafeCall(o.Callback) end,
				})
			else
				r.SafeCall(o.Callback)
			end
		end

		btn.MouseButton1Click:Connect(trigger)
		function obj:Fire() trigger() end
		function obj:SetText(t) titleLbl.Text = tostring(t or "") end
		return handle
	end

	function Container:AddToggle(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local hasDesc = o.Description and o.Description ~= ""
		local row = createRow(self, hasDesc and 52 or 38, o)

		r:Label({
			Text = o.Name or "Toggle",
			Position = UDim2.fromOffset(12, hasDesc and 6 or 0),
			Size = UDim2.new(1, -70, 0, hasDesc and 20 or 38),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		if hasDesc then
			r:Label({
				Text = o.Description,
				Position = UDim2.fromOffset(12, 26),
				Size = UDim2.new(1, -70, 0, 16),
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			}, "MutedText", "TextSizeXS", "FontRegular")
		end

		local track = r:New("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(40, 22),
			Parent = row,
		}, { r:Corner("RadiusPill") })

		local knob = r:New("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 3, 0.5, 0),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = Color3.new(1, 1, 1),
			Parent = track,
		}, { r:Corner("RadiusPill") })

		local click = r:New("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row })
		local obj = { Value = false }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		local function render()
			anim:Tween(track, { BackgroundColor3 = obj.Value and theme:Get("Accent") or theme:Get("HoverSurface") }, 0.18)
			anim:Tween(knob, { Position = obj.Value and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, 0.2, Enum.EasingStyle.Back)
		end

		local unsub = theme:OnChange(render, function() return row.Parent ~= nil end)
		janitor:Add(unsub)

		function obj:Set(v, silent)
			v = v and true or false
			if v == self.Value and self._init then
				return
			end
			self._init = true
			self.Value = v
			state:Sync(self._flag, v)
			render()
			if not silent then
				r.SafeCall(o.Callback, v)
			end
		end
		function obj:Get()
			return self.Value
		end

		click.MouseButton1Click:Connect(function() obj:Set(not obj.Value) end)
		obj:Set(o.Default == true, true)
		return handle
	end

	function Container:AddCheckbox(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local row = createRow(self, 36, o)

		local box = r:New("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 12, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			Parent = row,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.2) })

		local check = r:Label({
			Text = "✓",
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTransparency = 1,
			Parent = box,
		}, "PrimaryText", "TextSizeXS", "FontBold")
		check.TextColor3 = Color3.new(1, 1, 1)

		r:Label({
			Text = o.Name or "Checkbox",
			Position = UDim2.fromOffset(38, 0),
			Size = UDim2.new(1, -50, 1, 0),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		local click = r:New("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row })
		local obj = { Value = false }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		local function render()
			anim:Tween(box, { BackgroundColor3 = obj.Value and theme:Get("Accent") or theme:Get("Surface") }, 0.16)
			anim:Tween(check, { TextTransparency = obj.Value and 0 or 1 }, 0.16)
		end
		janitor:Add(theme:OnChange(render, function() return row.Parent ~= nil end))

		function obj:Set(v, silent)
			v = v and true or false
			self.Value = v
			state:Sync(self._flag, v)
			render()
			if not silent then
				r.SafeCall(o.Callback, v)
			end
		end
		function obj:Get()
			return self.Value
		end

		click.MouseButton1Click:Connect(function() obj:Set(not obj.Value) end)
		obj:Set(o.Default == true, true)
		return handle
	end

	function Container:AddRadioGroup(opts)
		local o = opts or {}
		local options = o.Options or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State

		local card = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, { r:Corner("RadiusMedium"), r:Stroke("Border", 1, 0.45), r:Padding(10), r:ListLayout(6) })
		theme:Bind(card, "BackgroundColor3", "ElevatedSurface")

		r:Label({
			Text = o.Name or "Select One",
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			Parent = card,
		}, "PrimaryText", "TextSizeSM", "FontBold")

		local obj = { Value = o.Default or options[1] }
		local handle, janitor = makeLifecycleHandle(self, card, o.Flag, obj)
		local dots = {}

		local function render()
			for optName, dot in pairs(dots) do
				local on = obj.Value == optName
				anim:Tween(dot, { BackgroundTransparency = on and 0 or 1 }, 0.15)
			end
		end

		for i, optName in ipairs(options) do
			local btn = r:New("TextButton", {
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundTransparency = 1,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = i,
				Parent = card,
			}, { r:Corner("RadiusSmall") })

			local outer = r:New("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 4, 0.5, 0),
				Size = UDim2.fromOffset(16, 16),
				Parent = btn,
			}, { r:Corner("RadiusPill"), r:Stroke("Border", 1.5, 0.1) })
			theme:Bind(outer, "BackgroundColor3", "Surface")

			local inner = r:New("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(8, 8),
				BackgroundTransparency = 1,
				Parent = outer,
			}, { r:Corner("RadiusPill") })
			theme:Bind(inner, "BackgroundColor3", "Accent")
			dots[optName] = inner

			r:Label({
				Text = tostring(optName),
				Position = UDim2.fromOffset(28, 0),
				Size = UDim2.new(1, -32, 1, 0),
				Parent = btn,
			}, "PrimaryText", "TextSizeSM", "FontMedium")

			btn.MouseButton1Click:Connect(function()
				obj:Set(optName)
			end)
		end

		janitor:Add(theme:OnChange(render, function() return card.Parent ~= nil end))
		function obj:Set(v, silent)
			if table.find(options, v) then
				self.Value = v
				state:Sync(self._flag, v)
				render()
				if not silent then
					r.SafeCall(o.Callback, v)
				end
			end
		end
		function obj:Get()
			return self.Value
		end
		render()
		return handle
	end

	function Container:AddSlider(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local inputMgr = self._ctx.Input

		local min, max = o.Min or 0, o.Max or 100
		local inc = o.Increment or 1
		local dec = #((tostring(inc):match("%.(%d+)")) or "")
		local suffix = o.Suffix or ""

		local row = createRow(self, 52, o)
		r:Label({
			Text = o.Name or "Slider",
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(0.65, 0, 0, 18),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		local valLbl = r:Label({
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(0.55, 0, 0, 6),
			Size = UDim2.new(0.45, -12, 0, 18),
			Parent = row,
		}, "SecondaryText", "TextSizeSM", "FontMono")

		local bar = r:New("Frame", {
			Position = UDim2.new(0, 12, 1, -16),
			Size = UDim2.new(1, -24, 0, 6),
			Parent = row,
		}, { r:Corner("RadiusPill") })
		theme:Bind(bar, "BackgroundColor3", "HoverSurface")

		local fill = r:New("Frame", { Size = UDim2.fromScale(0, 1), Parent = bar }, { r:Corner("RadiusPill") })
		theme:Bind(fill, "BackgroundColor3", "Accent")

		local knob = r:New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(13, 13),
			BackgroundColor3 = Color3.new(1, 1, 1),
			Parent = fill,
		}, { r:Corner("RadiusPill"), r:Stroke("Accent", 1.5, 0) })

		local hit = r:New("TextButton", {
			Position = UDim2.new(0, 0, 1, -30),
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundTransparency = 1,
			Text = "",
			Parent = row,
		})

		local obj = { Value = min }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		function obj:Set(v, silent)
			v = tonumber(v)
			if not v then
				return
			end
			v = math.clamp(math.floor((v - min) / inc + 0.5) * inc + min, min, max)
			v = tonumber(string.format("%." .. dec .. "f", v)) or v
			if v == self.Value and self._init then
				return
			end
			self._init = true
			self.Value = v
			state:Sync(self._flag, v)
			valLbl.Text = tostring(v) .. suffix
			local rel = max > min and (v - min) / (max - min) or 0
			anim:Tween(fill, { Size = UDim2.fromScale(rel, 1) }, 0.08, Enum.EasingStyle.Linear)
			if not silent then
				r.SafeCall(o.Callback, v)
			end
		end
		function obj:Get()
			return self.Value
		end

		local dragging = false
		local function fromX(x)
			local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
			obj:Set(min + (max - min) * rel)
		end

		janitor:Connect(hit.InputBegan, function(i)
			if inputMgr.IsPress(i) then
				dragging = true
				fromX(i.Position.X)
			end
		end)
		janitor:Connect(UserInputService.InputChanged, function(i)
			if dragging and inputMgr.IsMove(i) then
				fromX(i.Position.X)
			end
		end)
		janitor:Connect(UserInputService.InputEnded, function(i)
			if inputMgr.IsPress(i) then
				dragging = false
			end
		end)

		obj:Set(o.Default ~= nil and o.Default or min, true)
		return handle
	end

	-- Selection & Color Components: Dropdown, MultiDropdown, SearchBar, ColorPicker
	function Container:AddDropdown(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local options = o.Options or {}
		local multi = o.Multi == true

		local row = createRow(self, 38, o)
		local head = r:New("TextButton", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, Text = "", Parent = row })
		r:Label({
			Text = o.Name or "Dropdown",
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.48, -12, 0, 38),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		local shown = r:Label({
			Text = "—",
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.new(0.42, 0, 0, 0),
			Size = UDim2.new(0.58, -34, 0, 38),
			Parent = row,
		}, "SecondaryText", "TextSizeSM", "FontRegular")

		local arrow = r:Label({
			Text = "▾",
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.new(1, -28, 0, 0),
			Size = UDim2.fromOffset(20, 38),
			Parent = row,
		}, "MutedText", "TextSizeMD", "FontBold")

		local list = r:New("ScrollingFrame", {
			Position = UDim2.fromOffset(6, 42),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 2,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Parent = row,
		}, { r:ListLayout(3) })
		theme:Bind(list, "ScrollBarImageColor3", "Border")

		local sel, single, btns = {}, nil, {}
		local obj = { Value = multi and {} or nil }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		local open, fullH = false, 38

		local function paint()
			for name, b in pairs(btns) do
				local on = multi and sel[name] or (single == name)
				anim:Tween(b, {
					BackgroundTransparency = on and 0.25 or 1,
					TextColor3 = on and theme:Get("Accent") or theme:Get("SecondaryText"),
				}, 0.14)
			end
			if multi then
				local t = {}
				for _, n in ipairs(options) do
					if sel[n] then
						table.insert(t, n)
					end
				end
				obj.Value = t
				shown.Text = #t > 0 and table.concat(t, ", ") or "—"
			else
				obj.Value = single
				shown.Text = single and tostring(single) or "—"
			end
			state:Sync(obj._flag, obj.Value)
		end

		local function setOpen(v)
			open = v
			anim:Tween(row, { Size = UDim2.new(1, 0, 0, open and fullH or 38) }, 0.22)
			anim:Tween(arrow, { Rotation = open and 180 or 0 }, 0.22)
		end

		local function build()
			for _, c in ipairs(list:GetChildren()) do
				if c:IsA("TextButton") then
					c:Destroy()
				end
			end
			btns = {}
			local visible = math.min(#options, 5)
			local listH = visible * 29
			list.Size = UDim2.new(1, -12, 0, listH)
			fullH = 38 + listH + 10
			if open then
				row.Size = UDim2.new(1, 0, 0, fullH)
			end
			for _, name in ipairs(options) do
				local b = r:New("TextButton", {
					Size = UDim2.new(1, -4, 0, 26),
					BackgroundTransparency = 1,
					Text = "  " .. tostring(name),
					TextXAlignment = Enum.TextXAlignment.Left,
					AutoButtonColor = false,
					Parent = list,
				}, { r:Corner("RadiusSmall") })
				theme:Bind(b, "BackgroundColor3", "HoverSurface")
				theme:Bind(b, "Font", "FontMedium")
				theme:Bind(b, "TextSize", "TextSizeSM")
				b.MouseButton1Click:Connect(function()
					if multi then
						sel[name] = not sel[name] or nil
					else
						single = name
						setOpen(false)
					end
					paint()
					r.SafeCall(o.Callback, obj.Value)
				end)
				btns[name] = b
			end
			paint()
		end

		janitor:Add(theme:OnChange(paint, function() return row.Parent ~= nil end))

		function obj:Set(v, silent)
			if multi then
				sel = {}
				for _, n in ipairs(typeof(v) == "table" and v or {}) do
					sel[n] = true
				end
			else
				single = table.find(options, v) and v or nil
			end
			paint()
			if not silent then
				r.SafeCall(o.Callback, self.Value)
			end
		end
		function obj:Get()
			return self.Value
		end
		function obj:Refresh(newOpts)
			options = newOpts or {}
			build()
		end

		head.MouseButton1Click:Connect(function() setOpen(not open) end)
		build()
		if o.Default ~= nil then
			obj:Set(o.Default, true)
		end
		return handle
	end

	function Container:AddMultiDropdown(opts)
		local o = table.clone(opts or {})
		o.Multi = true
		return self:AddDropdown(o)
	end

	function Container:AddSearchBar(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local row = createRow(self, 36, o)

		r:Label({
			Text = "⌕",
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.fromOffset(18, 36),
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = row,
		}, "MutedText", "TextSizeMD", "FontBold")

		local box = r:New("TextBox", {
			Position = UDim2.fromOffset(32, 0),
			Size = UDim2.new(1, -66, 1, 0),
			BackgroundTransparency = 1,
			Text = "",
			PlaceholderText = o.Placeholder or "Search...",
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		theme:Bind(box, "TextColor3", "PrimaryText")
		theme:Bind(box, "PlaceholderColor3", "MutedText")
		theme:Bind(box, "Font", "FontMedium")
		theme:Bind(box, "TextSize", "TextSizeSM")

		local clearBtn = r:New("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(22, 22),
			BackgroundTransparency = 1,
			Text = "×",
			TextSize = 14,
			Visible = false,
			AutoButtonColor = false,
			Parent = row,
		})
		theme:Bind(clearBtn, "TextColor3", "MutedText")

		local obj = { Value = "" }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)

		janitor:Connect(box:GetPropertyChangedSignal("Text"), function()
			obj.Value = box.Text
			clearBtn.Visible = box.Text ~= ""
			self._ctx.State:Sync(obj._flag, obj.Value)
			r.SafeCall(o.Callback, box.Text)
		end)
		clearBtn.MouseButton1Click:Connect(function()
			box.Text = ""
		end)

		function obj:Set(v) box.Text = tostring(v or "") end
		function obj:Get() return obj.Value end
		function obj:Clear() box.Text = "" end
		return handle
	end

	function Container:AddColorPicker(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local inputMgr = self._ctx.Input

		local current = typeof(o.Default) == "Color3" and o.Default or Color3.fromRGB(114, 102, 255)
		local h, s, v = current:ToHSV()
		local open = false

		local row = createRow(self, 38, o)
		local head = r:New("TextButton", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, Text = "", Parent = row })
		r:Label({
			Text = o.Name or "Color",
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -110, 0, 38),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		local hexLbl = r:Label({
			Text = "#000000",
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(1, -116, 0, 0),
			Size = UDim2.fromOffset(64, 38),
			Parent = row,
		}, "MutedText", "TextSizeXS", "FontMono")

		local swatch = r:New("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0, 19),
			Size = UDim2.fromOffset(30, 20),
			BackgroundColor3 = current,
			Parent = row,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.2) })

		-- Picker panel
		local panel = r:New("Frame", {
			Position = UDim2.fromOffset(10, 44),
			Size = UDim2.new(1, -20, 0, 140),
			BackgroundTransparency = 1,
			Parent = row,
		})

		local svPad = r:New("Frame", {
			Size = UDim2.new(1, -30, 0, 106),
			BackgroundColor3 = Color3.fromHSV(h, 1, 1),
			ClipsDescendants = true,
			Parent = panel,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.3) })

		local satOverlay = r:New("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Parent = svPad,
		}, {
			r:New("UIGradient", {
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
			}),
		})

		local valOverlay = r:New("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			Parent = svPad,
		}, {
			r:New("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
			}),
		})

		local svCursor = r:New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(s, 1 - v),
			Size = UDim2.fromOffset(10, 10),
			BackgroundTransparency = 1,
			ZIndex = 4,
			Parent = svPad,
		}, { r:Corner("RadiusPill"), r:Stroke("PrimaryText", 1.5, 0) })

		local hueBar = r:New("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 20, 0, 106),
			Parent = panel,
		}, {
			r:Corner("RadiusSmall"),
			r:Stroke("Border", 1, 0.3),
			r:New("UIGradient", {
				Rotation = 90,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
					ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
					ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
					ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
					ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
				}),
			}),
		})

		local hueCursor = r:New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, h),
			Size = UDim2.new(1, 4, 0, 4),
			BackgroundColor3 = Color3.new(1, 1, 1),
			Parent = hueBar,
		}, { r:Corner(2) })

		local hexBox = r:New("TextBox", {
			Position = UDim2.fromOffset(0, 114),
			Size = UDim2.new(1, 0, 0, 24),
			Text = "",
			PlaceholderText = "#RRGGBB",
			ClearTextOnFocus = false,
			Parent = panel,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.3) })
		theme:Bind(hexBox, "BackgroundColor3", "Surface")
		theme:Bind(hexBox, "TextColor3", "PrimaryText")
		theme:Bind(hexBox, "Font", "FontMono")
		theme:Bind(hexBox, "TextSize", "TextSizeXS")

		local obj = { Value = current }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		local function toHex(c)
			return string.format("#%02X%02X%02X", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
		end

		local function updateVisuals()
			local col = Color3.fromHSV(h, s, v)
			obj.Value = col
			swatch.BackgroundColor3 = col
			svPad.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
			svCursor.Position = UDim2.fromScale(s, 1 - v)
			hueCursor.Position = UDim2.fromScale(0.5, h)
			local hx = toHex(col)
			hexLbl.Text = hx
			if not hexBox:IsFocused() then
				hexBox.Text = hx
			end
			state:Sync(obj._flag, col)
		end

		function obj:Set(c, silent)
			if typeof(c) == "Color3" then
				h, s, v = c:ToHSV()
				updateVisuals()
				if not silent then
					r.SafeCall(o.Callback, self.Value)
				end
			end
		end
		function obj:Get() return obj.Value end
		function obj:GetHex() return toHex(obj.Value) end
		function obj:SetHex(hexStr, silent)
			local clean = tostring(hexStr or ""):gsub("#", "")
			if #clean == 6 then
				local n = tonumber(clean, 16)
				if n then
					obj:Set(Color3.fromRGB(bit32.rshift(n, 16), bit32.band(bit32.rshift(n, 8), 255), bit32.band(n, 255)), silent)
				end
			end
		end

		local dragSV, dragHue = false, false
		local function updateSV(pos)
			s = math.clamp((pos.X - svPad.AbsolutePosition.X) / math.max(svPad.AbsoluteSize.X, 1), 0, 1)
			v = 1 - math.clamp((pos.Y - svPad.AbsolutePosition.Y) / math.max(svPad.AbsoluteSize.Y, 1), 0, 1)
			updateVisuals()
			r.SafeCall(o.Callback, obj.Value)
		end
		local function updateHue(pos)
			h = math.clamp((pos.Y - hueBar.AbsolutePosition.Y) / math.max(hueBar.AbsoluteSize.Y, 1), 0, 1)
			updateVisuals()
			r.SafeCall(o.Callback, obj.Value)
		end

		janitor:Connect(svPad.InputBegan, function(i)
			if inputMgr.IsPress(i) then dragSV = true; updateSV(i.Position) end
		end)
		janitor:Connect(hueBar.InputBegan, function(i)
			if inputMgr.IsPress(i) then dragHue = true; updateHue(i.Position) end
		end)
		janitor:Connect(UserInputService.InputChanged, function(i)
			if inputMgr.IsMove(i) then
				if dragSV then updateSV(i.Position) elseif dragHue then updateHue(i.Position) end
			end
		end)
		janitor:Connect(UserInputService.InputEnded, function(i)
			if inputMgr.IsPress(i) then dragSV = false; dragHue = false end
		end)

		hexBox.FocusLost:Connect(function()
			obj:SetHex(hexBox.Text, false)
		end)

		head.MouseButton1Click:Connect(function()
			open = not open
			anim:Tween(row, { Size = UDim2.new(1, 0, 0, open and 194 or 38) }, 0.22)
		end)

		updateVisuals()
		return handle
	end

	-- Inputs & System Components: Input, TextArea, Keybind, KeybindList, ProfileSelector
	function Container:AddInput(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local row = createRow(self, 38, o)

		r:Label({
			Text = o.Name or "Input",
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.46, -12, 1, 0),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		local box = r:New("TextBox", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.new(0.54, -8, 0, 26),
			Text = "",
			PlaceholderText = o.Placeholder or "",
			ClearTextOnFocus = false,
			Parent = row,
		}, { r:Corner("RadiusSmall"), r:Padding(0, 8, 0, 8) })
		theme:Bind(box, "BackgroundColor3", "Surface")
		theme:Bind(box, "TextColor3", "PrimaryText")
		theme:Bind(box, "PlaceholderColor3", "MutedText")
		theme:Bind(box, "Font", "FontMedium")
		theme:Bind(box, "TextSize", "TextSizeSM")

		local ring = r:Stroke("Focus", 1, 1)
		ring.Parent = box

		local obj = { Value = "" }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)

		function obj:Set(v, silent)
			v = tostring(v or "")
			if o.Numeric then
				v = v:gsub("[^%d%.%-]", "")
			end
			self.Value = v
			box.Text = v
			state:Sync(self._flag, v)
			if not silent then
				r.SafeCall(o.Callback, v)
			end
		end
		function obj:Get() return self.Value end

		box.Focused:Connect(function() anim:Tween(ring, { Transparency = 0 }, 0.15) end)
		box.FocusLost:Connect(function()
			anim:Tween(ring, { Transparency = 1 }, 0.15)
			obj:Set(box.Text)
		end)

		obj:Set(o.Default or "", true)
		return handle
	end

	function Container:AddTextArea(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local state = self._ctx.State
		local h = o.Height or 84
		local row = createRow(self, h + 30, o)

		r:Label({
			Text = o.Name or "Text Area",
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(1, -24, 0, 18),
			Parent = row,
		}, "PrimaryText", "TextSizeSM", "FontBold")

		local box = r:New("TextBox", {
			Position = UDim2.fromOffset(10, 28),
			Size = UDim2.new(1, -20, 0, h - 6),
			Text = "",
			PlaceholderText = o.Placeholder or "Enter text...",
			MultiLine = true,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			ClearTextOnFocus = false,
			Parent = row,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.3), r:Padding(6) })
		theme:Bind(box, "BackgroundColor3", "Surface")
		theme:Bind(box, "TextColor3", "PrimaryText")
		theme:Bind(box, "PlaceholderColor3", "MutedText")
		theme:Bind(box, "Font", "FontMono")
		theme:Bind(box, "TextSize", "TextSizeXS")

		local obj = { Value = "" }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)

		function obj:Set(v, silent)
			v = tostring(v or "")
			self.Value = v
			box.Text = v
			state:Sync(self._flag, v)
			if not silent then
				r.SafeCall(o.Callback, v)
			end
		end
		function obj:Get() return self.Value end
		box.FocusLost:Connect(function() obj:Set(box.Text) end)
		obj:Set(o.Default or "", true)
		return handle
	end

	function Container:AddKeybind(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local anim = self._ctx.Anim
		local state = self._ctx.State
		local inputMgr = self._ctx.Input
		local row = createRow(self, 38, o)

		r:Label({
			Text = o.Name or "Keybind",
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -110, 1, 0),
			Parent = row,
		}, "PrimaryText", "TextSizeMD", "FontMedium")

		local btn = r:New("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(88, 24),
			AutoButtonColor = false,
			Text = "None",
			Parent = row,
		}, { r:Corner("RadiusSmall"), r:Stroke("Border", 1, 0.35) })
		theme:Bind(btn, "BackgroundColor3", "Surface")
		theme:Bind(btn, "TextColor3", "SecondaryText")
		theme:Bind(btn, "Font", "FontMono")
		theme:Bind(btn, "TextSize", "TextSizeXS")

		local obj = { Value = "Unknown", _key = Enum.KeyCode.Unknown, Callback = o.Callback }
		local handle, janitor = makeLifecycleHandle(self, row, o.Flag, obj)
		r:AttachHover(row, "ElevatedSurface", "HoverSurface", janitor)

		function obj:Set(v, silent)
			if typeof(v) == "string" then
				local ok, kc = pcall(function() return Enum.KeyCode[v] end)
				v = ok and kc or Enum.KeyCode.Unknown
			end
			if typeof(v) ~= "EnumItem" then
				v = Enum.KeyCode.Unknown
			end
			self._key = v
			self.Value = v.Name
			btn.Text = v == Enum.KeyCode.Unknown and "None" or v.Name
			inputMgr:UpdateKeybind(obj, v)
			state:Sync(self._flag, self.Value)
			if not silent then
				r.SafeCall(o.OnChange, v)
			end
		end
		function obj:Get() return self.Value end

		inputMgr:RegisterKeybind(obj, Enum.KeyCode.Unknown, o.Name or "Keybind", function(k)
			r.SafeCall(obj.Callback, k)
		end, function(captured)
			anim:Tween(btn, { TextColor3 = theme:Get("SecondaryText") }, 0.14)
			obj:Set(captured, false)
		end)
		janitor:Add(function() inputMgr:UnregisterKeybind(obj) end)

		btn.MouseButton1Click:Connect(function()
			btn.Text = "..."
			anim:Tween(btn, { TextColor3 = theme:Get("Accent") }, 0.14)
			inputMgr:StartListening(obj)
		end)

		obj:Set(o.Default or Enum.KeyCode.Unknown, true)
		return handle
	end

	function Container:AddKeybindList(opts)
		local o = opts or {}
		local r = self._ctx.Renderer
		local theme = self._ctx.Theme
		local inputMgr = self._ctx.Input

		local card = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(self),
			Parent = self._parent,
		}, { r:Corner("RadiusMedium"), r:Stroke("Border", 1, 0.35), r:Padding(10), r:ListLayout(4) })
		theme:Bind(card, "BackgroundColor3", "Surface")

		r:Label({
			Text = o.Name or "Active Keybinds",
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 0,
			Parent = card,
		}, "PrimaryText", "TextSizeSM", "FontBold")

		local listFrame = r:New("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Parent = card,
		}, { r:ListLayout(3) })

		local obj = {}
		local handle = makeLifecycleHandle(self, card, nil, obj)

		function obj:Refresh()
			for _, c in ipairs(listFrame:GetChildren()) do
				if not c:IsA("UIListLayout") then
					c:Destroy()
				end
			end
			local all = inputMgr:GetAllKeybinds()
			if #all == 0 then
				r:Label({ Text = "No keybinds registered.", Size = UDim2.new(1, 0, 0, 18), Parent = listFrame }, "MutedText", "TextSizeXS", "FontRegular")
				return
			end
			for idx, entry in ipairs(all) do
				local item = r:New("Frame", {
					Size = UDim2.new(1, 0, 0, 22),
					BackgroundTransparency = 1,
					LayoutOrder = idx,
					Parent = listFrame,
				})
				r:Label({ Text = tostring(entry.label), Size = UDim2.new(0.65, 0, 1, 0), Parent = item }, "SecondaryText", "TextSizeXS", "FontMedium")
				r:Label({
					Text = entry.key == Enum.KeyCode.Unknown and "None" or entry.key.Name,
					TextXAlignment = Enum.TextXAlignment.Right,
					Position = UDim2.fromScale(0.65, 0),
					Size = UDim2.fromScale(0.35, 1),
					Parent = item,
				}, "Accent", "TextSizeXS", "FontMono")
			end
		end

		obj:Refresh()
		return handle
	end

	function Container:AddProfileSelector(opts)
		local o = opts or {}
		local cfg = self._ctx.Config
		local notify = self._ctx.Notifications
		local sec = self:AddCard({ Title = o.Name or "Configuration Profiles", Subtitle = "Manage, export and import configuration profiles" })

		local profileDrop = sec:AddDropdown({
			Name = "Active Profile",
			Options = cfg:List(),
			Default = cfg:GetActiveProfile(),
		})
		local nameInput = sec:AddInput({
			Name = "Profile Name",
			Placeholder = "default",
			Default = cfg:GetActiveProfile(),
		})
		sec:AddButton({
			Name = "Save Profile",
			Callback = function()
				local target = nameInput:Get()
				if target == "" then target = profileDrop:Get() or "default" end
				local ok, err = cfg:Save(target)
				profileDrop:Refresh(cfg:List())
				profileDrop:Set(target, true)
				notify:Notify({ Title = "Profile", Content = ok and ("Saved: " .. target) or (err or "Error"), Type = ok and "success" or "error" })
			end,
		})
		sec:AddButton({
			Name = "Load Selected",
			Callback = function()
				local target = profileDrop:Get() or nameInput:Get()
				local ok, err = cfg:Load(target)
				notify:Notify({ Title = "Profile", Content = ok and ("Loaded: " .. target) or (err or "Not found"), Type = ok and "success" or "warn" })
			end,
		})
		sec:AddButton({
			Name = "Delete Selected",
			Confirm = "Delete this configuration profile?",
			Danger = true,
			Callback = function()
				local target = profileDrop:Get()
				if target then
					cfg:Delete(target)
					profileDrop:Refresh(cfg:List())
					profileDrop:Set("default", true)
					notify:Notify({ Title = "Profile", Content = "Deleted: " .. target, Type = "info" })
				end
			end,
		})

		local obj = {}
		function obj:Refresh()
			profileDrop:Refresh(cfg:List())
		end
		return obj
	end

	-- =========================================================================
	-- 11. THEME EDITOR & CUSTOMIZATION SYSTEM
	-- =========================================================================
	local ThemeEditor = {}

	function ThemeEditor.BuildTab(win, ctx)
		local theme = ctx.Theme
		local cfg = ctx.Config
		local notify = ctx.Notifications
		local layoutCfg = ctx.Layout
		local behaviorCfg = ctx.Behavior

		local tab = win:AddTab({
			Name = "Settings",
			Description = "Theme, layout & profiles",
			Icon = "⚙",
		})

		-- Presets & Custom Themes
		local presetSec = tab:AddCollapsibleSection({ Name = "Theme Presets & Custom Themes", Default = true })
		local themeDropdown = presetSec:AddDropdown({
			Name = "Active Theme",
			Options = theme:GetAllThemeNames(),
			Default = theme:Get("Name"),
			Flag = "_aurora_theme_preset",
			Callback = function(name)
				theme:ApplyPreset(name, true)
			end,
		})

		local customThemeName = presetSec:AddInput({
			Name = "Custom Theme Name",
			Placeholder = "MyTheme",
			Default = "MyTheme",
		})

		presetSec:AddButton({
			Name = "Save as Custom Theme",
			Callback = function()
				local name = customThemeName:Get()
				if name == "" then name = "Custom_" .. tostring(os.time()) end
				theme:SaveCustomTheme(name)
				themeDropdown:Refresh(theme:GetAllThemeNames())
				themeDropdown:Set(name, true)
				notify:Notify({ Title = "Theme", Content = "Saved custom theme: " .. name, Type = "success" })
			end,
		})

		presetSec:AddButton({
			Name = "Delete Selected Custom Theme",
			Confirm = "Delete this custom theme?",
			Danger = true,
			Callback = function()
				local cur = themeDropdown:Get()
				if theme:DeleteCustomTheme(cur) then
					themeDropdown:Refresh(theme:GetAllThemeNames())
					themeDropdown:Set("Aurora Dark", true)
					notify:Notify({ Title = "Theme", Content = "Deleted: " .. cur, Type = "info" })
				else
					notify:Notify({ Title = "Theme", Content = "Built-in presets cannot be deleted.", Type = "warn" })
				end
			end,
		})

		local themeJsonArea = presetSec:AddTextArea({
			Name = "Theme JSON (Export / Import)",
			Placeholder = "Paste theme JSON here...",
			Height = 64,
		})

		presetSec:AddButton({
			Name = "Export Current Theme JSON",
			Callback = function()
				local json = theme:ExportJSON()
				themeJsonArea:Set(json, true)
				local copied = Environment.SetClipboard(json)
				notify:Notify({
					Title = "Theme Exported",
					Content = copied and "JSON copied to clipboard." or "JSON placed in text area.",
					Type = "success",
				})
			end,
		})

		presetSec:AddButton({
			Name = "Import Theme JSON",
			Callback = function()
				local ok, res = theme:ImportJSON(themeJsonArea:Get(), true)
				if ok then
					themeDropdown:Refresh(theme:GetAllThemeNames())
					themeDropdown:Set(res, true)
					notify:Notify({ Title = "Theme Imported", Content = "Applied: " .. tostring(res), Type = "success" })
				else
					notify:Notify({ Title = "Import Failed", Content = tostring(res), Type = "error" })
				end
			end,
		})

		-- Appearance
		local appSec = tab:AddCollapsibleSection({ Name = "Appearance", Default = true })
		appSec:AddColorPicker({
			Name = "Accent Color",
			Default = theme:Get("Accent"),
			Flag = "_aurora_accent",
			Callback = function(c) theme:SetAccent(c) end,
		})
		appSec:AddColorPicker({
			Name = "Background Color",
			Default = theme:Get("Background"),
			Flag = "_aurora_bg",
			Callback = function(c) theme:SetToken("Background", c, false) end,
		})
		appSec:AddColorPicker({
			Name = "Surface Color",
			Default = theme:Get("Surface"),
			Flag = "_aurora_surface",
			Callback = function(c) theme:SetToken("Surface", c, false) end,
		})
		appSec:AddSlider({
			Name = "Background Transparency",
			Min = 0, Max = 0.85, Increment = 0.05,
			Default = theme:Get("BackgroundTransparency"),
			Flag = "_aurora_bg_trans",
			Callback = function(v) theme:SetToken("BackgroundTransparency", v, false) end,
		})
		appSec:AddSlider({
			Name = "Corner Radius",
			Min = 0, Max = 16, Increment = 1, Suffix = "px",
			Default = theme:Get("RadiusMedium"),
			Flag = "_aurora_radius",
			Callback = function(v)
				theme:SetToken("RadiusMedium", v, false)
				theme:SetToken("RadiusLarge", math.min(20, v + 4), false)
			end,
		})
		appSec:AddSlider({
			Name = "Border Thickness",
			Min = 0, Max = 3, Increment = 0.5, Suffix = "px",
			Default = theme:Get("BorderThickness"),
			Flag = "_aurora_border_thick",
			Callback = function(v) theme:SetToken("BorderThickness", v, false) end,
		})
		appSec:AddDropdown({
			Name = "Font Family",
			Options = { "Gotham", "GothamMedium", "SourceSans", "Roboto", "Ubuntu", "Code" },
			Default = "GothamMedium",
			Flag = "_aurora_font",
			Callback = function(fontName)
				local ok, f = pcall(function() return Enum.Font[fontName] end)
				if ok and f then
					theme:SetToken("FontMedium", f, false)
					theme:SetToken("FontRegular", f, false)
				end
			end,
		})
		appSec:AddSlider({
			Name = "Base Font Size",
			Min = 10, Max = 18, Increment = 1, Suffix = "px",
			Default = theme:Get("TextSizeMD"),
			Flag = "_aurora_font_size",
			Callback = function(v)
				theme:SetToken("TextSizeMD", v, false)
				theme:SetToken("TextSizeSM", math.max(9, v - 1), false)
			end,
		})

		-- Layout
		local laySec = tab:AddCollapsibleSection({ Name = "Layout & Scaling", Default = false })
		laySec:AddDropdown({
			Name = "Layout Density",
			Options = { "Compact", "Default", "Spacious" },
			Default = layoutCfg.Preset,
			Flag = "_aurora_layout_preset",
			Callback = function(p)
				layoutCfg.Preset = p
				if p == "Compact" then
					layoutCfg.ComponentSpacing = 4
					layoutCfg.ContentPadding = 8
				elseif p == "Spacious" then
					layoutCfg.ComponentSpacing = 12
					layoutCfg.ContentPadding = 18
				else
					layoutCfg.ComponentSpacing = 8
					layoutCfg.ContentPadding = 14
				end
				ctx.WindowManager:ApplyLayoutAll()
			end,
		})
		laySec:AddSlider({
			Name = "UI Scale",
			Min = 0.75, Max = 1.35, Increment = 0.05, Suffix = "x",
			Default = layoutCfg.UIScale,
			Flag = "_aurora_ui_scale",
			Callback = function(v)
				layoutCfg.UIScale = v
				ctx.WindowManager:ApplyLayoutAll()
			end,
		})
		laySec:AddSlider({
			Name = "Sidebar Width",
			Min = 120, Max = 260, Increment = 5, Suffix = "px",
			Default = layoutCfg.SidebarWidth,
			Flag = "_aurora_sidebar_w",
			Callback = function(v)
				layoutCfg.SidebarWidth = v
				ctx.WindowManager:ApplyLayoutAll()
			end,
		})
		laySec:AddDropdown({
			Name = "Sidebar Position",
			Options = { "Left", "Right" },
			Default = layoutCfg.SidebarPosition,
			Flag = "_aurora_sidebar_pos",
			Callback = function(v)
				layoutCfg.SidebarPosition = v
				ctx.WindowManager:ApplyLayoutAll()
			end,
		})

		-- Behavior
		local behSec = tab:AddCollapsibleSection({ Name = "Behavior & Motion", Default = false })
		behSec:AddToggle({
			Name = "Enable Animations",
			Default = behaviorCfg.AnimationsEnabled,
			Flag = "_aurora_anim_enabled",
			Callback = function(v) behaviorCfg.AnimationsEnabled = v end,
		})
		behSec:AddToggle({
			Name = "Reduce Motion",
			Default = behaviorCfg.ReduceMotion,
			Flag = "_aurora_reduce_motion",
			Callback = function(v) behaviorCfg.ReduceMotion = v end,
		})
		behSec:AddSlider({
			Name = "Animation Speed",
			Min = 0.5, Max = 2.5, Increment = 0.25, Suffix = "x",
			Default = behaviorCfg.AnimationSpeed,
			Flag = "_aurora_anim_speed",
			Callback = function(v) behaviorCfg.AnimationSpeed = v end,
		})
		behSec:AddToggle({
			Name = "Draggable Windows",
			Default = behaviorCfg.DraggableWindows,
			Flag = "_aurora_draggable",
			Callback = function(v) behaviorCfg.DraggableWindows = v end,
		})
		behSec:AddToggle({
			Name = "Resizable Windows",
			Default = behaviorCfg.ResizableWindows,
			Flag = "_aurora_resizable",
			Callback = function(v) behaviorCfg.ResizableWindows = v end,
		})
		behSec:AddDropdown({
			Name = "Notification Position",
			Options = { "TopRight", "TopLeft", "BottomRight", "BottomLeft" },
			Default = behaviorCfg.NotificationPosition,
			Flag = "_aurora_notify_pos",
			Callback = function(v) notify:SetPosition(v) end,
		})
		behSec:AddKeybind({
			Name = "UI Toggle Key",
			Default = win.ToggleKey,
			Flag = "_aurora_toggle_key",
			OnChange = function(k)
				if k ~= Enum.KeyCode.Unknown then
					win.ToggleKey = k
				end
			end,
		})

		-- Profiles & JSON Config
		local cfgSec = tab:AddCollapsibleSection({ Name = "Configuration & Profiles", Default = false })
		cfgSec:AddProfileSelector({ Name = "Profiles" })

		local cfgJson = cfgSec:AddTextArea({
			Name = "Config JSON (Export / Import)",
			Placeholder = "Paste config JSON here...",
			Height = 64,
		})
		cfgSec:AddButton({
			Name = "Export Config JSON",
			Callback = function()
				local json = cfg:ExportJSON()
				cfgJson:Set(json, true)
				local copied = Environment.SetClipboard(json)
				notify:Notify({
					Title = "Config Exported",
					Content = copied and "Copied to clipboard." or "Placed in text area.",
					Type = "success",
				})
			end,
		})
		cfgSec:AddButton({
			Name = "Import Config JSON",
			Callback = function()
				local ok, err = cfg:ImportJSON(cfgJson:Get())
				notify:Notify({
					Title = "Config Import",
					Content = ok and "Configuration applied." or tostring(err),
					Type = ok and "success" or "error",
				})
			end,
		})

		local sysSec = tab:AddSection("System")
		sysSec:AddButton({
			Name = "Destroy Aurora UI",
			Confirm = "This will close and clean up all Aurora windows.",
			Danger = true,
			Callback = function()
				win:Destroy()
			end,
		})

		return tab
	end

	-- =========================================================================
	-- 12. PUBLIC API & INITIALIZATION
	-- =========================================================================
	local globalStore = Environment.GetGlobalStore()
	if globalStore.__AuroraUI then
		pcall(function()
			globalStore.__AuroraUI:Destroy()
		end)
	end

	local LayoutDefaults = {
		Preset = "Default",
		UIScale = 1,
		SidebarWidth = 175,
		SidebarPosition = "Left",
		WindowWidth = 680,
		WindowHeight = 460,
		ComponentSpacing = 8,
		ContentPadding = 14,
	}

	local BehaviorDefaults = {
		AnimationsEnabled = true,
		ReduceMotion = false,
		AnimationSpeed = 1,
		AnimationIntensity = 1,
		DraggableWindows = true,
		ResizableWindows = true,
		MinimizeBehavior = "Collapse",
		NotificationPosition = "BottomRight",
		NotificationDuration = 4,
		KeybindVisibility = true,
		ToggleKey = Enum.KeyCode.RightShift,
	}

	local Library = {
		Version = "2.0.0",
		Flags = {},
		Windows = {},
	}

	local storage = Storage.new("AuroraUI")
	local state = State.new(Library.Flags)
	local animEngine = AnimationEngine.new(BehaviorDefaults)
	local themeEngine = ThemeEngine.new(animEngine, storage)
	local renderer = Renderer.new(themeEngine, animEngine)
	local inputManager = InputManager.new()
	local notifyManager = NotificationManager.new(renderer, BehaviorDefaults, false)
	local dialogManager = DialogManager.new(renderer)
	local tooltipManager = TooltipManager.new(renderer)
	local contextMenuManager = ContextMenuManager.new(renderer)
	local configManager = ConfigManager.new(storage, state, themeEngine, LayoutDefaults, BehaviorDefaults)

	themeEngine:LoadSavedCustomThemes()

	local ctx = {
		Storage = storage,
		State = state,
		Anim = animEngine,
		Theme = themeEngine,
		Renderer = renderer,
		Input = inputManager,
		Notifications = notifyManager,
		Dialogs = dialogManager,
		Tooltips = tooltipManager,
		ContextMenu = contextMenuManager,
		Config = configManager,
		Layout = LayoutDefaults,
		Behavior = BehaviorDefaults,
		ContainerClass = Container,
		ThemeEditor = ThemeEditor,
		PreferPlayerGui = false,
	}

	local windowManager = WindowManager.new(ctx)
	ctx.WindowManager = windowManager
	Library.Windows = windowManager._windows

	-- Expose managers & adapters
	Library.Environment = Environment
	Library.Capabilities = Environment.GetCapabilities()
	Library.Theme = themeEngine
	Library.Animation = animEngine
	Library.Config = configManager
	Library.Input = inputManager
	Library.State = state

	-- Core Public Methods (v1.0 compatible + v2.0 extensions)
	function Library:CreateWindow(opts)
		return windowManager:CreateWindow(opts)
	end

	function Library:Notify(opts)
		notifyManager:Notify(opts)
	end

	function Library:SetAccent(color)
		themeEngine:SetAccent(color)
	end

	function Library:ApplyPreset(name)
		return themeEngine:ApplyPreset(name, true)
	end

	function Library:SetThemeToken(token, value)
		themeEngine:SetToken(token, value, true)
	end

	function Library:ExportTheme()
		return themeEngine:ExportJSON()
	end

	function Library:ImportTheme(jsonStr)
		return themeEngine:ImportJSON(jsonStr, true)
	end

	function Library:ExportConfig()
		return configManager:ExportJSON()
	end

	function Library:ImportConfig(jsonStr)
		return configManager:ImportJSON(jsonStr)
	end

	function Library:SetUIScale(scale)
		LayoutDefaults.UIScale = math.clamp(tonumber(scale) or 1, 0.5, 2)
		windowManager:ApplyLayoutAll()
	end

	function Library:Destroy()
		windowManager:DestroyAll()
		notifyManager:Destroy()
		tooltipManager:Destroy()
		contextMenuManager:Destroy()
		inputManager:Destroy()
		configManager:Destroy()
		themeEngine:Destroy()
		animEngine:Destroy()
		state:Destroy()
		if globalStore.__AuroraUI == Library then
			globalStore.__AuroraUI = nil
		end
	end

	globalStore.__AuroraUI = Library
	return Library
end)()

return Aurora
