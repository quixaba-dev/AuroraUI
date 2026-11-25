-- Aurora UI + Exemplo (script único). Execute direto no executor.
local Aurora = (function()
--[[
	Aurora UI v1.0 — biblioteca de UI single-file para Roblox (Luau)
	Uso:  local Aurora = loadstring(game:HttpGet("SUA_URL/Aurora.luau"))()

	Seções internas:
	  1. Utilitários (tween com cancelamento, criação de instâncias, tema reativo)
	  2. Notificações
	  3. Elementos (Label, Button, Toggle, Slider, Dropdown, Input, Keybind)
	  4. Janela (loading, abas, drag, minimizar, config, aba de ajustes)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local env = (getgenv and getgenv()) or _G
if env.__AuroraUI then
	pcall(function() env.__AuroraUI:Destroy() end)
end

local Library = { Flags = {}, Windows = {}, Version = "1.0.0" }

------------------------------------------------------------------
-- 1. UTILITÁRIOS
------------------------------------------------------------------
local Theme = {
	Background = Color3.fromRGB(14, 14, 19),
	Surface = Color3.fromRGB(21, 21, 29),
	Elevated = Color3.fromRGB(29, 29, 40),
	Hover = Color3.fromRGB(40, 40, 55),
	Stroke = Color3.fromRGB(52, 52, 72),
	Text = Color3.fromRGB(240, 240, 248),
	SubText = Color3.fromRGB(148, 148, 170),
	Accent = Color3.fromRGB(124, 108, 255),
	Success = Color3.fromRGB(80, 210, 140),
	Warn = Color3.fromRGB(255, 180, 70),
	Danger = Color3.fromRGB(255, 90, 100),
}

local Accents = {
	Roxo = Color3.fromRGB(124, 108, 255),
	Azul = Color3.fromRGB(70, 150, 255),
	Verde = Color3.fromRGB(70, 210, 140),
	Rosa = Color3.fromRGB(255, 100, 170),
	Laranja = Color3.fromRGB(255, 150, 70),
}

local themed = {}
local function bind(inst, prop, token)
	inst[prop] = Theme[token]
	table.insert(themed, { inst, prop, token })
end

-- Tween com cancelamento: iniciar um tween nas mesmas propriedades cancela o anterior
local running = setmetatable({}, { __mode = "k" })
local function tw(obj, props, dur, style, dir)
	local per = running[obj]
	if not per then
		per = {}
		running[obj] = per
	end
	local names = {}
	for k in pairs(props) do names[#names + 1] = k end
	table.sort(names)
	local id = table.concat(names, ",")
	if per[id] then per[id]:Cancel() end
	local t = TweenService:Create(
		obj,
		TweenInfo.new(dur or 0.2, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out),
		props
	)
	per[id] = t
	t.Completed:Once(function()
		if per[id] == t then per[id] = nil end
	end)
	t:Play()
	return t
end

local function new(class, props, kids)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then o[k] = v end
	end
	for _, k in ipairs(kids or {}) do k.Parent = o end
	if props and props.Parent then o.Parent = props.Parent end
	return o
end

local function round(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end

local function stroke(token, thick, trans)
	local s = new("UIStroke", {
		Thickness = thick or 1,
		Transparency = trans or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	bind(s, "Color", token or "Stroke")
	return s
end

local function pad(a)
	local u = UDim.new(0, a)
	return new("UIPadding", { PaddingTop = u, PaddingBottom = u, PaddingLeft = u, PaddingRight = u })
end

local function label(props, token)
	local p = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in pairs(props) do p[k] = v end
	local l = new("TextLabel", p)
	bind(l, "TextColor3", token or "Text")
	return l
end

local function hover(row)
	row.MouseEnter:Connect(function() tw(row, { BackgroundColor3 = Theme.Hover }, 0.15) end)
	row.MouseLeave:Connect(function() tw(row, { BackgroundColor3 = Theme.Elevated }, 0.15) end)
end

local function safe(cb, ...)
	if typeof(cb) ~= "function" then return end
	local ok, err = pcall(cb, ...)
	if not ok then warn("[Aurora] " .. tostring(err)) end
end

local function protectGui(gui)
	local ok = pcall(function()
		if gethui then
			gui.Parent = gethui()
		else
			gui.Parent = game:GetService("CoreGui")
		end
	end)
	if not ok or not gui.Parent then
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	end
end

local function isPress(i)
	return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
end

local function isMove(i)
	return i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch
end

function Library:SetAccent(c)
	Theme.Accent = c
	for i = #themed, 1, -1 do
		local t = themed[i]
		if not t[1].Parent then
			table.remove(themed, i)
		elseif t[3] == "Accent" then
			tw(t[1], { [t[2]] = c }, 0.3)
		end
	end
	for _, w in ipairs(Library.Windows) do
		for _, hook in ipairs(w._themeHooks) do pcall(hook) end
	end
end

------------------------------------------------------------------
-- 2. NOTIFICAÇÕES
------------------------------------------------------------------
local notifyGui, notifyHolder
local function ensureNotify()
	if notifyGui and notifyGui.Parent then return end
	notifyGui = new("ScreenGui", {
		Name = HttpService:GenerateGUID(false),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	protectGui(notifyGui)
	notifyHolder = new("Frame", {
		Position = UDim2.new(1, -296, 0, 16),
		Size = UDim2.new(0, 280, 1, -32),
		BackgroundTransparency = 1,
		Parent = notifyGui,
	}, {
		new("UIListLayout", {
			Padding = UDim.new(0, 8),
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

function Library:Notify(o)
	o = o or {}
	ensureNotify()
	local dur = o.Duration or 4
	local colors = { info = Theme.Accent, success = Theme.Success, warn = Theme.Warn, error = Theme.Danger }
	local color = colors[o.Type or "info"] or Theme.Accent

	local wrap = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = notifyHolder,
	})
	local card = new("CanvasGroup", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(300, 0),
		GroupTransparency = 1,
		BackgroundColor3 = Theme.Surface,
		Parent = wrap,
	}, {
		round(8),
		stroke("Stroke", 1, 0.3),
		pad(12),
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	label({
		Text = o.Title or "Aviso",
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
		Parent = card,
	})
	if o.Content then
		label({
			Text = o.Content,
			TextSize = 12,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 2,
			Parent = card,
		}, "SubText")
	end
	local track = new("Frame", {
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = Theme.Elevated,
		LayoutOrder = 3,
		Parent = card,
	}, { round(2) })
	local fill = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		Parent = track,
	}, { round(2) })

	tw(card, { Position = UDim2.new(), GroupTransparency = 0 }, 0.4)
	tw(fill, { Size = UDim2.fromScale(0, 1) }, dur, Enum.EasingStyle.Linear)
	task.delay(dur, function()
		if not card.Parent then return end
		tw(card, { Position = UDim2.fromOffset(300, 0), GroupTransparency = 1 }, 0.3)
		task.wait(0.32)
		wrap:Destroy()
	end)
end

------------------------------------------------------------------
-- 3. ELEMENTOS (compartilhados por Tab e Section)
------------------------------------------------------------------
local Container = {}
Container.__index = Container

local function nextOrder(self)
	self._order = (self._order or 0) + 1
	return self._order
end

local function baseRow(self, h)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, h or 36),
		ClipsDescendants = true,
		LayoutOrder = nextOrder(self),
		Parent = self._parent,
	}, { round(6), stroke("Stroke", 1, 0.5) })
	bind(row, "BackgroundColor3", "Elevated")
	return row
end

local function register(self, flag, obj)
	if flag then
		obj._flag = flag
		self._win._flags[flag] = obj
		Library.Flags[flag] = obj.Value
	end
end

local function sync(obj)
	if obj._flag then Library.Flags[obj._flag] = obj.Value end
end

function Container:AddSection(name)
	local sec = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(self),
		Parent = self._parent,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	label({
		Text = string.upper(name or "Seção"),
		TextSize = 11,
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 0,
		Parent = sec,
	}, "SubText")
	return setmetatable({ _win = self._win, _parent = sec }, Container)
end

function Container:AddLabel(text)
	local l = label({
		Text = text or "",
		TextWrapped = true,
		TextSize = 12,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = nextOrder(self),
		Parent = self._parent,
	}, "SubText")
	return { Set = function(_, t) l.Text = t end }
end

function Container:AddButton(o)
	local row = baseRow(self, 36)
	hover(row)
	label({ Text = o.Name or "Botão", Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0), Parent = row })
	local btn = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row })
	btn.MouseButton1Click:Connect(function()
		row.BackgroundColor3 = Theme.Accent
		tw(row, { BackgroundColor3 = Theme.Elevated }, 0.45)
		safe(o.Callback)
	end)
	return { Fire = function() safe(o.Callback) end }
end

function Container:AddToggle(o)
	local win = self._win
	local row = baseRow(self, 36)
	hover(row)
	label({ Text = o.Name or "Toggle", Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -70, 1, 0), Parent = row })
	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(38, 20),
		BackgroundColor3 = Theme.Hover,
		Parent = row,
	}, { round(10) })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Theme.Text,
		Parent = track,
	}, { round(7) })
	local click = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row })

	local obj = { Value = false }
	local function render()
		tw(track, { BackgroundColor3 = obj.Value and Theme.Accent or Theme.Hover }, 0.2)
		tw(knob, { Position = obj.Value and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, 0.22, Enum.EasingStyle.Back)
	end
	function obj:Set(v, silent)
		v = v and true or false
		if v == self.Value then return end
		self.Value = v
		sync(self)
		render()
		if not silent then safe(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	click.MouseButton1Click:Connect(function() obj:Set(not obj.Value) end)
	table.insert(win._themeHooks, render)
	register(self, o.Flag, obj)
	if o.Default then obj:Set(true) end
	return obj
end

function Container:AddSlider(o)
	local min, max = o.Min or 0, o.Max or 100
	local inc = o.Increment or 1
	local dec = #((tostring(inc):match("%.(%d+)")) or "")
	local suffix = o.Suffix or ""
	local row = baseRow(self, 48)
	hover(row)
	label({ Text = o.Name or "Slider", Position = UDim2.fromOffset(12, 6), Size = UDim2.new(0.6, 0, 0, 18), Parent = row })
	local val = label({
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0.5, -12, 0, 18),
		Parent = row,
	}, "SubText")
	local bar = new("Frame", {
		Position = UDim2.new(0, 12, 1, -16),
		Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = Theme.Hover,
		Parent = row,
	}, { round(3) })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), Parent = bar }, { round(3) })
	bind(fill, "BackgroundColor3", "Accent")
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Theme.Text,
		Parent = fill,
	}, { round(6) })
	local hit = new("TextButton", {
		Position = UDim2.new(0, 0, 1, -28),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		Text = "",
		Parent = row,
	})

	local obj = { Value = min }
	function obj:Set(v, silent)
		v = tonumber(v)
		if not v then return end
		v = math.clamp(math.floor((v - min) / inc + 0.5) * inc + min, min, max)
		v = tonumber(string.format("%." .. dec .. "f", v))
		if v == self.Value and self._init then return end
		self._init = true
		self.Value = v
		sync(self)
		val.Text = tostring(v) .. suffix
		local rel = (max > min) and (v - min) / (max - min) or 0
		tw(fill, { Size = UDim2.fromScale(rel, 1) }, 0.08, Enum.EasingStyle.Linear)
		if not silent then safe(o.Callback, v) end
	end
	function obj:Get() return self.Value end

	local dragging = false
	local function fromX(x)
		local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		obj:Set(min + (max - min) * rel)
	end
	hit.InputBegan:Connect(function(i)
		if isPress(i) then
			dragging = true
			fromX(i.Position.X)
		end
	end)
	self._win:_conn(UserInputService.InputChanged:Connect(function(i)
		if dragging and isMove(i) then fromX(i.Position.X) end
	end))
	self._win:_conn(UserInputService.InputEnded:Connect(function(i)
		if isPress(i) then dragging = false end
	end))

	register(self, o.Flag, obj)
	obj:Set(o.Default or min, true)
	return obj
end

function Container:AddDropdown(o)
	local opts = o.Options or {}
	local multi = o.Multi
	local row = baseRow(self, 36)
	hover(row)
	local head = new("TextButton", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Text = "", Parent = row })
	label({ Text = o.Name or "Dropdown", Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.5, -12, 0, 36), Parent = row })
	local shown = label({
		Text = "—",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.new(0.4, 0, 0, 0),
		Size = UDim2.new(0.6, -34, 0, 36),
		Parent = row,
	}, "SubText")
	local arrow = label({
		Text = "▾",
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(1, -28, 0, 0),
		Size = UDim2.fromOffset(20, 36),
		Parent = row,
	}, "SubText")
	local list = new("ScrollingFrame", {
		Position = UDim2.fromOffset(6, 40),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = row,
	}, { new("UIListLayout", { Padding = UDim.new(0, 2) }) })

	local sel = {} -- mapa nome -> true
	local single = nil
	local btns = {}
	local obj = { Value = multi and {} or nil }
	local open = false
	local fullH = 36

	local function paint()
		for name, b in pairs(btns) do
			local on = multi and sel[name] or (single == name)
			tw(b, { BackgroundTransparency = on and 0.35 or 1, TextColor3 = on and Theme.Accent or Theme.SubText }, 0.15)
		end
		if multi then
			local t = {}
			for _, n in ipairs(opts) do if sel[n] then t[#t + 1] = n end end
			obj.Value = t
			shown.Text = #t > 0 and table.concat(t, ", ") or "—"
		else
			obj.Value = single
			shown.Text = single and tostring(single) or "—"
		end
		sync(obj)
	end

	local function setOpen(v)
		open = v
		tw(row, { Size = UDim2.new(1, 0, 0, open and fullH or 36) }, 0.25)
		tw(arrow, { Rotation = open and 180 or 0 }, 0.25)
	end

	local function build()
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("TextButton") then c:Destroy() end
		end
		btns = {}
		local visible = math.min(#opts, 5)
		local listH = visible * 28
		list.Size = UDim2.new(1, -12, 0, listH)
		fullH = 36 + listH + 10
		for _, name in ipairs(opts) do
			local b = new("TextButton", {
				Size = UDim2.new(1, -4, 0, 26),
				BackgroundColor3 = Theme.Hover,
				BackgroundTransparency = 1,
				Text = tostring(name),
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = Theme.SubText,
				AutoButtonColor = false,
				Parent = list,
			}, { round(5) })
			b.MouseButton1Click:Connect(function()
				if multi then
					sel[name] = not sel[name] or nil
				else
					single = name
					setOpen(false)
				end
				paint()
				safe(o.Callback, obj.Value)
			end)
			btns[name] = b
		end
		paint()
	end

	function obj:Set(v, silent)
		if multi then
			sel = {}
			for _, n in ipairs(typeof(v) == "table" and v or {}) do sel[n] = true end
		else
			single = table.find(opts, v) and v or nil
		end
		paint()
		if not silent then safe(o.Callback, self.Value) end
	end
	function obj:Get() return self.Value end
	function obj:Refresh(newOpts)
		opts = newOpts
		build()
	end

	head.MouseButton1Click:Connect(function() setOpen(not open) end)
	register(self, o.Flag, obj)
	build()
	if o.Default ~= nil then obj:Set(o.Default, true) end
	return obj
end

function Container:AddInput(o)
	local row = baseRow(self, 36)
	hover(row)
	label({ Text = o.Name or "Input", Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.5, -12, 1, 0), Parent = row })
	local box = new("TextBox", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0.5, -8, 0, 24),
		BackgroundColor3 = Theme.Hover,
		Text = "",
		PlaceholderText = o.Placeholder or "",
		PlaceholderColor3 = Theme.SubText,
		TextColor3 = Theme.Text,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		ClearTextOnFocus = false,
		Parent = row,
	}, { round(5) })
	local ring = stroke("Accent", 1, 1)
	ring.Parent = box

	local obj = { Value = "" }
	function obj:Set(v, silent)
		v = tostring(v or "")
		self.Value = v
		box.Text = v
		sync(self)
		if not silent then safe(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	box.Focused:Connect(function() tw(ring, { Transparency = 0 }, 0.15) end)
	box.FocusLost:Connect(function()
		tw(ring, { Transparency = 1 }, 0.15)
		obj:Set(box.Text)
	end)
	register(self, o.Flag, obj)
	obj:Set(o.Default or "", true)
	return obj
end

function Container:AddKeybind(o)
	local win = self._win
	local row = baseRow(self, 36)
	hover(row)
	label({ Text = o.Name or "Keybind", Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -110, 1, 0), Parent = row })
	local btn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(84, 24),
		BackgroundColor3 = Theme.Hover,
		TextColor3 = Theme.SubText,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		AutoButtonColor = false,
		Text = "Nenhuma",
		Parent = row,
	}, { round(5) })

	local obj = { Value = "Unknown", _key = Enum.KeyCode.Unknown, _listening = false, Callback = o.Callback }
	function obj:Set(v, silent)
		if typeof(v) == "string" then
			local ok, kc = pcall(function() return Enum.KeyCode[v] end)
			v = ok and kc or Enum.KeyCode.Unknown
		end
		if typeof(v) ~= "EnumItem" then v = Enum.KeyCode.Unknown end
		self._key = v
		self.Value = v.Name
		btn.Text = v == Enum.KeyCode.Unknown and "Nenhuma" or v.Name
		sync(self)
		if not silent then safe(o.OnChange, v) end
	end
	function obj:Get() return self.Value end

	btn.MouseButton1Click:Connect(function()
		obj._listening = true
		btn.Text = "..."
		tw(btn, { TextColor3 = Theme.Accent }, 0.15)
	end)
	win._keybinds[obj] = function(input)
		obj._listening = false
		tw(btn, { TextColor3 = Theme.SubText }, 0.15)
		obj:Set(input.KeyCode == Enum.KeyCode.Escape and Enum.KeyCode.Unknown or input.KeyCode)
	end

	register(self, o.Flag, obj)
	obj:Set(o.Default or Enum.KeyCode.Unknown, true)
	return obj
end

------------------------------------------------------------------
-- 4. JANELA
------------------------------------------------------------------
local function hasFS()
	return typeof(writefile) == "function" and typeof(readfile) == "function"
		and typeof(isfolder) == "function" and typeof(makefolder) == "function"
end

function Library:CreateWindow(opts)
	opts = opts or {}
	local win = {
		Tabs = {},
		Visible = true,
		Minimized = false,
		ToggleKey = opts.ToggleKey or Enum.KeyCode.RightShift,
		_conns = {},
		_flags = {},
		_keybinds = {},
		_themeHooks = {},
		_folder = opts.ConfigFolder or "AuroraUI",
	}
	function win:_conn(c)
		table.insert(self._conns, c)
		return c
	end

	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local mobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local W = math.min(opts.Width or (mobile and 440 or 580), vp.X - 24)
	local H = math.min(opts.Height or (mobile and 280 or 380), vp.Y - 24)
	local sideW = mobile and 110 or 150

	local gui = new("ScreenGui", {
		Name = HttpService:GenerateGUID(false),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 999,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	protectGui(gui)

	local root = new("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(W, H),
		GroupTransparency = 1,
		Parent = gui,
	}, { round(10), stroke("Stroke", 1, 0.2) })
	bind(root, "BackgroundColor3", "Background")
	local scale = new("UIScale", { Scale = 0.92, Parent = root })

	-- Barra superior
	local top = new("Frame", { Size = UDim2.new(1, 0, 0, 42), Parent = root })
	bind(top, "BackgroundColor3", "Surface")
	label({
		Text = opts.Title or "Aurora",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(0, 200, 1, 0),
		Parent = top,
	})
	if opts.Subtitle then
		label({
			Text = opts.Subtitle,
			TextSize = 11,
			Position = UDim2.fromOffset(14 + 8 + #(opts.Title or "Aurora") * 8, 1),
			Size = UDim2.new(0, 200, 1, 0),
			Parent = top,
		}, "SubText")
	end
	local function topBtn(txt, x, color)
		local b = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, x, 0.5, 0),
			Size = UDim2.fromOffset(26, 26),
			BackgroundColor3 = Theme.Hover,
			BackgroundTransparency = 1,
			Text = txt,
			TextColor3 = Theme.SubText,
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			AutoButtonColor = false,
			Parent = top,
		}, { round(6) })
		b.MouseEnter:Connect(function()
			tw(b, { BackgroundTransparency = 0, TextColor3 = color or Theme.Text }, 0.12)
		end)
		b.MouseLeave:Connect(function()
			tw(b, { BackgroundTransparency = 1, TextColor3 = Theme.SubText }, 0.12)
		end)
		return b
	end
	local closeBtn = topBtn("×", -10, Theme.Danger)
	local minBtn = topBtn("–", -40)

	-- Barra lateral e conteúdo
	local side = new("Frame", {
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(0, sideW, 1, -42),
		Parent = root,
	})
	bind(side, "BackgroundColor3", "Surface")
	local tabList = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = side,
	}, { new("UIListLayout", { Padding = UDim.new(0, 4) }), pad(8) })
	local content = new("Frame", {
		Position = UDim2.fromOffset(sideW, 42),
		Size = UDim2.new(1, -sideW, 1, -42),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = root,
	})

	-- Splash de loading
	local splash = new("CanvasGroup", {
		Size = UDim2.fromScale(1, 1),
		ZIndex = 100,
		BackgroundColor3 = Theme.Background,
		Parent = root,
	})
	label({
		Text = opts.Title or "Aurora",
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 0.5, -38),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = splash,
	})
	local status = label({
		Text = "",
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 0.5, -8),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = splash,
	}, "SubText")
	local barBg = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 20),
		Size = UDim2.fromOffset(180, 4),
		BackgroundColor3 = Theme.Elevated,
		Parent = splash,
	}, { round(2) })
	local barFill = new("Frame", { Size = UDim2.fromScale(0, 1), Parent = barBg }, { round(2) })
	bind(barFill, "BackgroundColor3", "Accent")

	-- Entrada animada + loading
	tw(root, { GroupTransparency = 0 }, 0.3)
	tw(scale, { Scale = 1 }, 0.4, Enum.EasingStyle.Back)
	task.spawn(function()
		local steps = opts.LoadingSteps or { "Inicializando", "Carregando tema", "Montando interface", "Pronto" }
		if opts.Loading == false then steps = {} end
		for i, s in ipairs(steps) do
			status.Text = s
			tw(barFill, { Size = UDim2.fromScale(i / #steps, 1) }, 0.25)
			task.wait(0.28)
		end
		tw(splash, { GroupTransparency = 1 }, 0.35)
		task.wait(0.36)
		splash:Destroy()
	end)

	-- Drag com clamp
	local dragging, dragStart, startPos
	top.InputBegan:Connect(function(i)
		if isPress(i) then
			dragging = true
			dragStart = i.Position
			startPos = root.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	win:_conn(UserInputService.InputChanged:Connect(function(i)
		if dragging and isMove(i) then
			local d = i.Position - dragStart
			local v = (workspace.CurrentCamera or cam).ViewportSize
			local x = math.clamp(startPos.X.Offset + d.X, -v.X / 2 + 80, v.X / 2 - 80)
			local y = math.clamp(startPos.Y.Offset + d.Y, -v.Y / 2 + 30, v.Y / 2 - 30)
			root.Position = UDim2.new(startPos.X.Scale, x, startPos.Y.Scale, y)
		end
	end))

	-- Visibilidade / minimizar
	function win:SetVisible(v)
		self.Visible = v
		if v then
			root.Visible = true
			tw(root, { GroupTransparency = 0 }, 0.25)
			tw(scale, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
		else
			tw(root, { GroupTransparency = 1 }, 0.18)
			tw(scale, { Scale = 0.95 }, 0.18)
			task.delay(0.19, function()
				if not self.Visible and root.Parent then root.Visible = false end
			end)
		end
	end
	function win:Toggle() self:SetVisible(not self.Visible) end
	function win:Minimize()
		self.Minimized = not self.Minimized
		tw(root, { Size = UDim2.fromOffset(W, self.Minimized and 42 or H) }, 0.3)
	end
	minBtn.MouseButton1Click:Connect(function() win:Minimize() end)
	closeBtn.MouseButton1Click:Connect(function() win:SetVisible(false) end)

	-- Input global: tecla de toggle + keybinds
	win:_conn(UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		for kb, finish in pairs(win._keybinds) do
			if kb._listening then
				finish(input)
				return
			end
		end
		if processed then return end
		if input.KeyCode == win.ToggleKey then
			win:Toggle()
			return
		end
		for kb in pairs(win._keybinds) do
			if kb._key ~= Enum.KeyCode.Unknown and kb._key == input.KeyCode then
				safe(kb.Callback, kb._key)
			end
		end
	end))

	-- Botão flutuante para mobile
	if mobile then
		local fab = new("TextButton", {
			Position = UDim2.new(0, 12, 0.5, -20),
			Size = UDim2.fromOffset(40, 40),
			BackgroundColor3 = Theme.Surface,
			Text = "☰",
			TextColor3 = Theme.Text,
			TextSize = 18,
			Font = Enum.Font.GothamBold,
			Parent = gui,
		}, { round(20), stroke("Accent", 1, 0.2) })
		fab.MouseButton1Click:Connect(function() win:Toggle() end)
	end

	-- Abas
	function win:AddTab(name)
		local tab = setmetatable({ _win = self }, Container)
		local btn = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 32),
			BackgroundColor3 = Theme.Elevated,
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Parent = tabList,
		}, { round(6) })
		local ind = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(3, 0),
			Parent = btn,
		}, { round(2) })
		bind(ind, "BackgroundColor3", "Accent")
		local txt = label({
			Text = name,
			Position = UDim2.fromOffset(14, 0),
			Size = UDim2.new(1, -18, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = btn,
		}, "SubText")

		local page = new("CanvasGroup", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			GroupTransparency = 1,
			Visible = false,
			Parent = content,
		})
		tab._parent = new("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.Stroke,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Parent = page,
		}, {
			new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }),
			pad(10),
		})

		local function deselect()
			tw(page, { GroupTransparency = 1 }, 0.15)
			task.delay(0.16, function()
				if win._active ~= tab and page.Parent then page.Visible = false end
			end)
			tw(btn, { BackgroundTransparency = 1 }, 0.2)
			tw(ind, { Size = UDim2.fromOffset(3, 0) }, 0.2)
			tw(txt, { TextColor3 = Theme.SubText }, 0.2)
		end
		function tab:Select()
			if win._active == tab then return end
			local prev = win._active
			if prev then prev._deselect() end
			win._active = tab
			page.Visible = true
			page.Position = UDim2.fromOffset(0, 14)
			tw(page, { GroupTransparency = 0, Position = UDim2.new() }, 0.3)
			tw(btn, { BackgroundTransparency = 0 }, 0.2)
			tw(ind, { Size = UDim2.fromOffset(3, 16) }, 0.25, Enum.EasingStyle.Back)
			tw(txt, { TextColor3 = Theme.Text }, 0.2)
		end
		tab._deselect = deselect
		btn.MouseButton1Click:Connect(function() tab:Select() end)

		table.insert(self.Tabs, tab)
		if #self.Tabs == 1 then tab:Select() end
		return tab
	end

	-- Config
	function win:SaveConfig(name)
		if not hasFS() then
			Library:Notify({ Title = "Config", Content = "Executor sem suporte a arquivos.", Type = "error" })
			return false
		end
		pcall(function() if not isfolder(self._folder) then makefolder(self._folder) end end)
		local data = {}
		for flag, o in pairs(self._flags) do data[flag] = o.Value end
		local ok = pcall(writefile, self._folder .. "/" .. name .. ".json", HttpService:JSONEncode(data))
		Library:Notify({
			Title = "Config",
			Content = ok and ("Salva: " .. name) or "Falha ao salvar.",
			Type = ok and "success" or "error",
		})
		return ok
	end
	function win:LoadConfig(name)
		if not hasFS() then return false end
		local path = self._folder .. "/" .. name .. ".json"
		local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
		if not ok or typeof(data) ~= "table" then
			Library:Notify({ Title = "Config", Content = "Não encontrada: " .. name, Type = "warn" })
			return false
		end
		for flag, v in pairs(data) do
			local o = self._flags[flag]
			if o then pcall(o.Set, o, v) end
		end
		Library:Notify({ Title = "Config", Content = "Carregada: " .. name, Type = "success" })
		return true
	end

	-- Aba de ajustes pronta (tema, tecla, config, destruir)
	function win:AddSettingsTab()
		local tab = self:AddTab("Ajustes")
		local ui = tab:AddSection("Interface")
		ui:AddDropdown({
			Name = "Cor de destaque",
			Options = { "Roxo", "Azul", "Verde", "Rosa", "Laranja" },
			Default = "Roxo",
			Flag = "_accent",
			Callback = function(v)
				if Accents[v] then Library:SetAccent(Accents[v]) end
			end,
		})
		ui:AddKeybind({
			Name = "Abrir/fechar",
			Default = self.ToggleKey,
			Flag = "_togglekey",
			OnChange = function(k)
				if k ~= Enum.KeyCode.Unknown then self.ToggleKey = k end
			end,
		})
		local cfg = tab:AddSection("Configurações")
		local nameBox = cfg:AddInput({ Name = "Nome", Default = "default", Placeholder = "default" })
		cfg:AddButton({ Name = "Salvar", Callback = function() self:SaveConfig(nameBox.Value ~= "" and nameBox.Value or "default") end })
		cfg:AddButton({ Name = "Carregar", Callback = function() self:LoadConfig(nameBox.Value ~= "" and nameBox.Value or "default") end })
		local misc = tab:AddSection("Geral")
		misc:AddButton({ Name = "Destruir interface", Callback = function() self:Destroy() end })
		return tab
	end

	function win:Destroy()
		for _, c in ipairs(self._conns) do pcall(function() c:Disconnect() end) end
		self._conns = {}
		gui:Destroy()
		local idx = table.find(Library.Windows, self)
		if idx then table.remove(Library.Windows, idx) end
	end

	table.insert(Library.Windows, win)
	return win
end

function Library:Destroy()
	for i = #self.Windows, 1, -1 do self.Windows[i]:Destroy() end
	if notifyGui then notifyGui:Destroy() end
	env.__AuroraUI = nil
end

env.__AuroraUI = Library
return Library
end)()


local Window = Aurora:CreateWindow({
	Title = "Assistente",
	Subtitle = "v1.0",
	ToggleKey = Enum.KeyCode.RightShift,
	ConfigFolder = "MeuAssistente",
})

-- Aba de utilidades
local Util = Window:AddTab("Utilidades")
local view = Util:AddSection("Visualização")

view:AddSlider({
	Name = "Campo de visão (FOV)",
	Min = 40, Max = 120, Default = 70, Suffix = "°",
	Flag = "fov",
	Callback = function(v)
		workspace.CurrentCamera.FieldOfView = v
	end,
})

local fpsLabel = view:AddLabel("FPS: --")
local fpsOn = false
view:AddToggle({
	Name = "Mostrar FPS",
	Flag = "showfps",
	Callback = function(v) fpsOn = v end,
})

task.spawn(function()
	local RunService = game:GetService("RunService")
	local frames, last = 0, os.clock()
	RunService.RenderStepped:Connect(function()
		frames += 1
		local now = os.clock()
		if now - last >= 0.5 then
			if fpsOn then fpsLabel:Set(("FPS: %d"):format(frames / (now - last))) end
			frames, last = 0, now
		end
	end)
end)

local misc = Util:AddSection("Sessão")
misc:AddToggle({
	Name = "Anti-AFK",
	Flag = "antiafk",
	Callback = function(v)
		-- aqui você conecta/desconecta a lógica do seu módulo
		Aurora:Notify({ Title = "Anti-AFK", Content = v and "Ativado" or "Desativado", Type = v and "success" or "info" })
	end,
})
misc:AddDropdown({
	Name = "Modo",
	Options = { "Leve", "Normal", "Agressivo" },
	Default = "Normal",
	Flag = "mode",
	Callback = function(v) print("Modo:", v) end,
})
misc:AddButton({
	Name = "Testar notificação",
	Callback = function()
		Aurora:Notify({ Title = "Olá!", Content = "Tudo funcionando.", Type = "info", Duration = 3 })
	end,
})

-- Aba de ajustes pronta (cor, tecla, salvar/carregar config)
Window:AddSettingsTab()
