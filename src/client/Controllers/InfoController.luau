--!strict
-- Подсказки и карта объектов (баланс v4):
--  1) панель горячих клавиш справа — тёмная полупрозрачная подложка, значки клавиш; на телефоне и геймпаде вместо клавиш — их кнопки;
--  2) переключатель меток важных объектов (шатры, магазины припасов, здания, донатный магазин): клавиша M / D-pad вверх / кнопка на экране;
--     состояние живёт на время сессии (атрибут игрока MarksOn, его читает и ShopController);
--  3) справочник зданий: клавиша H / D-pad вниз / кнопка — название, цена, что внутри, сколько вложено.
-- Только отображение: цены и состояние зданий считает сервер (атрибут ReplicatedStorage.BuildingStates, Config.Buildings, Config.Vendors).

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local InfoController = {}

local PANEL = Color3.fromRGB(16, 20, 16)
local OLIVE = Color3.fromRGB(96, 110, 78)
local TEXT = Color3.fromRGB(226, 222, 204)
local DIM = Color3.fromRGB(150, 156, 140)
local GOLD = Color3.fromRGB(214, 190, 96)

local KEYS: { { key: string, text: string } } = {
	{ key = "LMB", text = "Fire" },
	{ key = "R", text = "Reload" },
	{ key = "E", text = "Use (hold: supplies)" },
	{ key = "B", text = "Weapon shop (tent)" },
	{ key = "Shift", text = "Sprint" },
	{ key = "Q", text = "Slide (sprinting)" },
	{ key = "C", text = "Roll" },
	{ key = "G", text = "Drop weapon" },
	{ key = "Z/X/T", text = "Emote: wave/cheer/dance" },
	{ key = "V", text = "End the day" },
	{ key = "MMB", text = "Ping" },
	{ key = "K", text = "Cutscenes on / off (host)" },
	{ key = "M", text = "Map marks on / off" },
	{ key = "H", text = "Buildings guide" },
}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

function InfoController.start()
	local player = Players.LocalPlayer
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local gamepad = UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled
	local gui = Instance.new("ScreenGui")
	gui.Name = "InfoHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 7
	gui.Parent = player:WaitForChild("PlayerGui")
	player:SetAttribute("MarksOn", player:GetAttribute("MarksOn") ~= false)

	-- ===== окно справочника зданий =====
	local guide = Instance.new("Frame")
	guide.Name = "BuildingsGuide"
	guide.AnchorPoint = Vector2.new(0.5, 0.5)
	guide.Position = UDim2.fromScale(0.5, 0.5)
	guide.Size = UDim2.fromOffset(620, 470)
	guide.BackgroundColor3 = PANEL
	guide.BackgroundTransparency = 0.06
	guide.Visible = false
	guide.Parent = gui
	corner(guide, 8)
	local gs = Instance.new("UIStroke")
	gs.Color = OLIVE
	gs.Thickness = 2
	gs.Parent = guide
	local gScale = Instance.new("UIScale")
	gScale.Parent = guide
	local function fit()
		local view = gui.AbsoluteSize
		gScale.Scale = math.clamp(math.min(view.X / 700, view.Y / 540), 0.55, 1.1)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	local gTitle = Instance.new("TextLabel")
	gTitle.Position = UDim2.fromOffset(16, 8)
	gTitle.Size = UDim2.new(1, -90, 0, 38)
	gTitle.BackgroundTransparency = 1
	gTitle.Font = Enum.Font.Oswald
	gTitle.TextSize = 30
	gTitle.TextColor3 = GOLD
	gTitle.TextXAlignment = Enum.TextXAlignment.Left
	gTitle.Text = "BUILDINGS"
	gTitle.Parent = guide
	local gHint = Instance.new("TextLabel")
	gHint.Position = UDim2.fromOffset(16, 44)
	gHint.Size = UDim2.new(1, -32, 0, 20)
	gHint.BackgroundTransparency = 1
	gHint.Font = Enum.Font.Gotham
	gHint.TextSize = 14
	gHint.TextColor3 = DIM
	gHint.TextXAlignment = Enum.TextXAlignment.Left
	gHint.Text = "Invest coins at a building's sign during the day. Everyone's contributions add up."
	gHint.Parent = guide
	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 12)
	closeBtn.Size = UDim2.fromOffset(60, 32)
	closeBtn.BackgroundColor3 = Color3.fromRGB(46, 52, 44)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = TEXT
	closeBtn.Text = "Close"
	closeBtn.Parent = guide
	corner(closeBtn, 5)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(12, 72)
	scroll.Size = UDim2.new(1, -24, 1, -84)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = guide
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.Parent = scroll
	local modal = Instance.new("TextButton")
	modal.Size = UDim2.fromOffset(0, 0)
	modal.BackgroundTransparency = 1
	modal.Text = ""
	modal.Modal = false
	modal.Parent = guide

	local function stateOf(id: string): string
		local text = ReplicatedStorage:GetAttribute("BuildingStates")
		if typeof(text) == "string" then
			for key, value in string.gmatch(text, "(%w+)=([^;]+)") do
				if key == id then
					return value
				end
			end
		end
		return ""
	end

	-- что внутри: торговец и его товары (Config.Vendors), бонус здания
	local function insideOf(def: Config.BuildingDef): string
		local v = (Config.Vendors :: any)[def.id]
		local parts: { string } = {}
		if v then
			local names: { string } = {}
			for _, item in v.items do
				table.insert(names, item.name)
			end
			table.insert(parts, string.format("%s sells: %s", v.name, table.concat(names, ", ")))
		end
		if def.bonus == "teamLife" then
			table.insert(parts, "Bonus: an extra team life")
		end
		return if #parts > 0 then table.concat(parts, " · ") else def.info
	end

	local function rebuild()
		for _, c in scroll:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		for order, def in Config.Buildings do
			local state = if def.cost <= 0 then "open" else stateOf(def.id)
			local row = Instance.new("Frame")
			row.LayoutOrder = order
			row.Size = UDim2.new(1, -8, 0, 84)
			row.BackgroundColor3 = Color3.fromRGB(28, 34, 28)
			row.Parent = scroll
			corner(row, 6)
			local stroke = Instance.new("UIStroke")
			stroke.Color = if state == "open" then Color3.fromRGB(90, 180, 100) else OLIVE
			stroke.Thickness = 1.5
			stroke.Transparency = 0.3
			stroke.Parent = row
			local name = Instance.new("TextLabel")
			name.Position = UDim2.fromOffset(12, 6)
			name.Size = UDim2.new(1, -190, 0, 24)
			name.BackgroundTransparency = 1
			name.Font = Enum.Font.Oswald
			name.TextSize = 22
			name.TextColor3 = TEXT
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.Text = string.upper(def.name)
			name.Parent = row
			local status = Instance.new("TextLabel")
			status.AnchorPoint = Vector2.new(1, 0)
			status.Position = UDim2.new(1, -12, 0, 6)
			status.Size = UDim2.fromOffset(170, 24)
			status.BackgroundTransparency = 1
			status.Font = Enum.Font.GothamBold
			status.TextSize = 15
			status.TextColor3 = if state == "open" then Color3.fromRGB(110, 210, 120) else GOLD
			status.TextXAlignment = Enum.TextXAlignment.Right
			status.Text = if state == "open" then (if def.cost <= 0 then "FREE · OPEN" else "OPEN") else (if state ~= "" then state else "0/" .. def.cost) .. " ●"
			status.Parent = row
			local inside = Instance.new("TextLabel")
			inside.Position = UDim2.fromOffset(12, 32)
			inside.Size = UDim2.new(1, -24, 0, 18)
			inside.BackgroundTransparency = 1
			inside.Font = Enum.Font.GothamMedium
			inside.TextSize = 14
			inside.TextColor3 = Color3.fromRGB(190, 200, 170)
			inside.TextXAlignment = Enum.TextXAlignment.Left
			inside.Text = if def.cost <= 0 then def.info else string.format("Price %d ●  ·  %s", def.cost, insideOf(def))
			inside.Parent = row
			local desc = Instance.new("TextLabel")
			desc.Position = UDim2.fromOffset(12, 52)
			desc.Size = UDim2.new(1, -24, 0, 28)
			desc.BackgroundTransparency = 1
			desc.Font = Enum.Font.Gotham
			desc.TextSize = 13
			desc.TextWrapped = true
			desc.TextYAlignment = Enum.TextYAlignment.Top
			desc.TextColor3 = DIM
			desc.TextXAlignment = Enum.TextXAlignment.Left
			desc.Text = if def.desc then def.desc else (if def.cost <= 0 then "Always open: your first line of defense." else def.info)
			desc.Parent = row
		end
	end

	local function setGuide(visible: boolean)
		if visible == guide.Visible then
			return
		end
		if visible then
			rebuild()
			guide.Visible = true
			modal.Modal = true -- свободный курсор в виде от первого лица
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			gScale.Scale = gScale.Scale * 0.9
			TweenService:Create(gScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = math.clamp(math.min(gui.AbsoluteSize.X / 700, gui.AbsoluteSize.Y / 540), 0.55, 1.1) }):Play()
			if UserInputService.GamepadEnabled then
				GuiService.SelectedObject = closeBtn
			end
		else
			guide.Visible = false
			modal.Modal = false
			GuiService.SelectedObject = nil
		end
		player:SetAttribute("GuideOpen", visible)
	end
	-- состояние окна виден атрибутом игрока GuideOpen (его можно переключить и снаружи — для проверок)
	player:GetAttributeChangedSignal("GuideOpen"):Connect(function()
		setGuide(player:GetAttribute("GuideOpen") == true)
	end)
	ReplicatedStorage:GetAttributeChangedSignal("BuildingStates"):Connect(function()
		if guide.Visible then
			rebuild()
		end
	end)
	closeBtn.Activated:Connect(function()
		setGuide(false)
	end)

	-- ===== переключатель меток =====
	local marksGui = Instance.new("ScreenGui")
	marksGui.Name = "ImportantMarks"
	marksGui.ResetOnSpawn = false
	marksGui.DisplayOrder = 4
	marksGui.Parent = player:WaitForChild("PlayerGui")
	local marks: { [Instance]: { part: Part, gui: BillboardGui, label: TextLabel, base: string } } = {}

	local function marksVisible(): boolean
		return player:GetAttribute("MarksOn") ~= false and ReplicatedStorage:GetAttribute("Phase") ~= "Night"
	end

	local function addMark(key: Instance, pos: Vector3, text: string, color: Color3)
		local m = marks[key]
		if m then
			m.part.Position = pos + Vector3.new(0, 14, 0)
			return
		end
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Size = Vector3.one
		part.Position = pos + Vector3.new(0, 14, 0)
		part.Parent = workspace
		local bb = Instance.new("BillboardGui")
		bb.Adornee = part
		bb.AlwaysOnTop = true
		bb.Size = UDim2.fromOffset(130, 34)
		bb.MaxDistance = 900
		bb.Enabled = marksVisible()
		bb.Parent = marksGui
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = PANEL
		label.BackgroundTransparency = 0.35
		label.TextColor3 = color
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextTransparency = 0.1
		label.Text = text
		label.Parent = bb
		corner(label, 4)
		marks[key] = { part = part, gui = bb, label = label, base = text }
	end

	-- вендинговые автоматы: список ведём по событиям (обход всей карты раз в 2 с давал рывок кадра)
	local vending: { [Instance]: boolean } = {}
	local function trackVending(d: Instance)
		if d:IsA("Model") and string.sub(d.Name, 1, 8) == "Vending_" then
			vending[d] = true
		end
	end
	for _, d in workspace:GetDescendants() do
		trackVending(d)
	end
	workspace.DescendantAdded:Connect(trackVending)
	workspace.DescendantRemoving:Connect(function(d: Instance)
		vending[d] = nil
	end)

	local function scan()
		local seen: { [Instance]: boolean } = {}
		local function mark(key: Instance, pos: Vector3, text: string, color: Color3)
			seen[key] = true
			addMark(key, pos, text, color)
		end
		-- магазины оружия: шатры (ShopService создаёт ShopPrompt на каждую точку)
		local points = workspace:FindFirstChild("ShopPoints")
		if points then
			for _, p in points:GetChildren() do
				if p:IsA("BasePart") then
					mark(p, p.Position, "WEAPONS (B)", Color3.fromRGB(255, 190, 80))
				end
			end
		end
		-- магазины припасов: вендинговые автоматы (модели Vending_<n>)
		for d in vending do
			if d.Parent and d:IsA("Model") then
				mark(d, d:GetPivot().Position, "SUPPLIES (hold E)", Color3.fromRGB(120, 210, 255))
			end
		end
		-- донатный магазин на базе
		local donate = workspace:FindFirstChild("BaseDonateShop")
		if donate and donate:IsA("Model") then
			mark(donate, donate:GetPivot().Position, "DONATE SHOP", Color3.fromRGB(230, 170, 255))
		end
		-- здания (Workspace.Buildings.<id>)
		local buildings = workspace:FindFirstChild("Buildings")
		if buildings then
			for _, def in Config.Buildings do
				local m = buildings:FindFirstChild(def.id)
				if m and def.cost > 0 and m:IsA("Model") then
					local state = stateOf(def.id)
					mark(m, m:GetPivot().Position, string.upper(def.name) .. (if state == "open" then " ✓" else ""), if state == "open" then Color3.fromRGB(110, 210, 120) else GOLD)
				end
			end
		end
		for key, m in marks do
			if not seen[key] then
				m.part:Destroy()
				m.gui:Destroy()
				marks[key] = nil
			end
		end
	end

	-- ночью метки скрыты сами (магазины и здания закрыты, ночью они только сбивают с миссии); днём — по переключателю M
	local function applyMarks()
		marksGui.Enabled = marksVisible()
		for _, m in marks do
			m.gui.Enabled = marksVisible() -- BillboardGui сам по себе не гаснет вместе с ScreenGui: выключаем каждую метку
		end
	end
	player:GetAttributeChangedSignal("MarksOn"):Connect(applyMarks)
	ReplicatedStorage:GetAttributeChangedSignal("Phase"):Connect(applyMarks)
	applyMarks()
	local function toggleMarks()
		player:SetAttribute("MarksOn", player:GetAttribute("MarksOn") == false)
	end
	task.spawn(function()
		while true do
			if marksGui.Enabled then
				local ok, err = pcall(scan)
				if not ok then
					warn("[InfoController] " .. tostring(err))
				end
				local cam = workspace.CurrentCamera
				if cam then
					for _, m in marks do
						local d = math.floor((m.part.Position - cam.CFrame.Position).Magnitude)
						m.label.Text = string.format("%s\n%d st.", m.base, d)
					end
				end
			end
			task.wait(2)
		end
	end)
	-- расстояние в подписи обновляем чаще, чем ищем новые объекты
	task.spawn(function()
		while true do
			task.wait(0.4)
			local cam = workspace.CurrentCamera
			if cam and marksGui.Enabled then
				for _, m in marks do
					m.label.Text = string.format("%s\n%d st.", m.base, math.floor((m.part.Position - cam.CFrame.Position).Magnitude))
				end
			end
		end
	end)

	-- ===== клавиши =====
	-- UserInputService.InputBegan, а не ContextActionService: клавиши M и H не должны зависеть от чужих привязок и порядка приоритетов
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.M or input.KeyCode == Enum.KeyCode.DPadUp then
			toggleMarks()
		elseif input.KeyCode == Enum.KeyCode.H or input.KeyCode == Enum.KeyCode.DPadDown then
			setGuide(not guide.Visible)
		end
	end)
	ContextActionService:BindAction("NotdGuideClose", function(_, state)
		if state == Enum.UserInputState.Begin and guide.Visible then
			setGuide(false)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB)

	-- ===== панель клавиш справа (и кнопки на экране для телефона / геймпада) =====
	local panel = Instance.new("Frame")
	panel.Name = "KeyPanel"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -10, 0.52, 0)
	panel.AutomaticSize = Enum.AutomaticSize.XY
	panel.Size = UDim2.fromOffset(0, 0)
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.8
	panel.Parent = gui
	corner(panel, 6)
	local ps = Instance.new("UIStroke")
	ps.Color = OLIVE
	ps.Transparency = 0.8
	ps.Thickness = 1
	ps.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = panel
	local pl = Instance.new("UIListLayout")
	pl.Padding = UDim.new(0, 3)
	pl.SortOrder = Enum.SortOrder.LayoutOrder
	pl.Parent = panel
	local function makeRow(order: number, key: string, text: string): Frame
		local row = Instance.new("Frame")
		row.LayoutOrder = order
		row.Size = UDim2.fromOffset(176, 18)
		row.BackgroundTransparency = 1
		row.Parent = panel
		local chip = Instance.new("TextLabel")
		chip.Size = UDim2.fromOffset(38, 16)
		chip.AnchorPoint = Vector2.new(0, 0.5)
		chip.Position = UDim2.new(0, 0, 0.5, 0)
		chip.BackgroundColor3 = Color3.fromRGB(46, 54, 44)
		chip.BackgroundTransparency = 0.6
		chip.TextTransparency = 0.35
		chip.Font = Enum.Font.GothamBold
		chip.TextSize = 11
		chip.TextColor3 = GOLD
		chip.Text = key
		chip.Parent = row
		corner(chip, 3)
		local cs = Instance.new("UIStroke")
		cs.Color = OLIVE
		cs.Thickness = 1
		cs.Transparency = 0.7
		cs.Parent = chip
		local t = Instance.new("TextLabel")
		t.Position = UDim2.fromOffset(44, 0)
		t.Size = UDim2.new(1, -44, 1, 0)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamMedium
		t.TextSize = 12
		t.TextColor3 = TEXT
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTransparency = 0.35
		t.Text = text
		t.Parent = row
		return row
	end
	local function makeButton(name: string, text: string, y: number, onClick: () -> ())
		local b = Instance.new("TextButton")
		b.Name = name
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -10, 0.52, y)
		b.Size = UDim2.fromOffset(64, 40)
		b.BackgroundColor3 = PANEL
		b.BackgroundTransparency = 0.3
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.TextColor3 = GOLD
		b.Text = text
		b.Parent = gui
		corner(b, 6)
		local st = Instance.new("UIStroke")
		st.Color = OLIVE
		st.Parent = b
		b.Activated:Connect(onClick)
	end
	if touchOnly then
		panel.Visible = false
		makeButton("MarksButton", "MARKS", -24, toggleMarks)
		makeButton("GuideButton", "BUILD", 24, function()
			setGuide(not guide.Visible)
		end)
	elseif gamepad then
		panel.Visible = false
		makeButton("MarksButton", "MARKS", -24, toggleMarks)
		makeButton("GuideButton", "BUILD", 24, function()
			setGuide(not guide.Visible)
		end)
	else
		for i, k in KEYS do
			makeRow(i, k.key, k.text)
		end
	end
end

return InfoController
