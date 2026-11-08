--!strict
-- Меню покупки оружия в стиле CS2: слева категории (клавиши 1–6), справа список оружия с характеристиками.
-- Открывается клавишей B или терминалом на спавне (сервер шлёт ShopOpen). Покупку проверяет и выполняет сервер (BuyWeapon);
-- в режиме осмотра (Config.Explore) всё бесплатно — для тестов оружия.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CaseRules = require(Shared:WaitForChild("CaseRules"))
local WeaponIcon = require(script.Parent:WaitForChild("WeaponIcon"))

local ShopController = {}

local U = Config.UiKhaki
local ACCENT = U.Gold
local BG = U.Bg
local PANEL = U.Panel

local function statsText(def: Config.WeaponDef): string
	if def.melee then
		return string.format("Damage %d · %.1f hits/s · range %.1f", def.damage, def.fireRate, def.range)
	end
	local dmg = if def.pellets > 1 then string.format("%d×%d", def.damage, def.pellets) else tostring(def.damage)
	local reserve = if def.reserve < 0 then "∞" else tostring(def.reserve)
	return string.format("Damage %s · %.1f shots/s · mag %d / %s%s", dmg, def.fireRate, def.magSize, reserve, if def.automatic then " · auto" else "")
end

function ShopController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "BuyMenu"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- невидимая модальная кнопка освобождает курсор в режиме от первого лица
	local modal = Instance.new("TextButton")
	modal.Size = UDim2.fromScale(0, 0)
	modal.BackgroundTransparency = 1
	modal.Text = ""
	modal.Modal = true
	modal.Parent = gui

	local main = Instance.new("Frame")
	main.AnchorPoint = Vector2.new(0.5, 0.5)
	main.Position = UDim2.fromScale(0.5, 0.5)
	main.Size = UDim2.fromOffset(880, 540)
	main.BackgroundColor3 = BG
	main.BackgroundTransparency = 0.02
	main.BorderSizePixel = 0
	main.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = main
	local outline = Instance.new("UIStroke")
	outline.Color = U.Line
	outline.Thickness = 2
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = main

	local header = Instance.new("Frame")
	header.Position = UDim2.fromOffset(12, 10)
	header.Size = UDim2.new(1, -24, 0, 38)
	header.BackgroundColor3 = U.Header
	header.BorderSizePixel = 0
	header.Parent = main

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(0.6, 0, 1, 0)
	title.Position = UDim2.fromOffset(12, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = U.Text
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "ARMORY"
	title.Parent = header

	local coins = Instance.new("TextLabel")
	coins.AnchorPoint = Vector2.new(1, 0)
	coins.Size = UDim2.new(0.35, 0, 1, 0)
	coins.Position = UDim2.new(1, -12, 0, 0)
	coins.BackgroundTransparency = 1
	coins.Font = Enum.Font.GothamBold
	coins.TextSize = 18
	coins.TextColor3 = ACCENT
	coins.TextXAlignment = Enum.TextXAlignment.Right
	coins.Parent = header
	local function refreshCoins()
		coins.Text = string.format("$%d", (player:GetAttribute("Coins") :: number?) or 0)
	end
	refreshCoins()
	player:GetAttributeChangedSignal("Coins"):Connect(refreshCoins)

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -20, 0, 20)
	hint.Position = UDim2.new(0, 14, 1, -26)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 14
	hint.TextColor3 = U.Dim
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Parent = main

	local cats = Instance.new("Frame")
	cats.Position = UDim2.fromOffset(12, 56)
	cats.Size = UDim2.fromOffset(120, 450)
	cats.BackgroundTransparency = 1
	cats.Parent = main
	local catLayout = Instance.new("UIListLayout")
	catLayout.Padding = UDim.new(0, 6)
	catLayout.Parent = cats

	local list = Instance.new("ScrollingFrame")
	list.BackgroundColor3 = PANEL
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = main
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(150, 148)
	gridLayout.CellPadding = UDim2.fromOffset(8, 8)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder -- товары, затем раздел доната (иначе строки шли по имени)
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop, listPad.PaddingLeft, listPad.PaddingRight, listPad.PaddingBottom =
		UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6)
	listPad.Parent = list

	-- Панель выбранного оружия справа
	local detail = Instance.new("Frame")
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.new(1, -12, 0, 56)
	detail.Size = UDim2.fromOffset(220, 450)
	detail.BackgroundColor3 = U.Header
	detail.BorderSizePixel = 0
	detail.Parent = main
	local dName = Instance.new("TextLabel")
	dName.Position = UDim2.fromOffset(10, 136)
	dName.Size = UDim2.new(1, -20, 0, 26)
	dName.BackgroundTransparency = 1
	dName.Font = Enum.Font.GothamBold
	dName.TextSize = 18
	dName.TextColor3 = U.Text
	dName.TextXAlignment = Enum.TextXAlignment.Left
	dName.Parent = detail
	local statRows: { { label: TextLabel, fill: Frame } } = {}
	for i = 1, 3 do
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromOffset(10, 124 + i * 46)
		label.Size = UDim2.new(1, -20, 0, 18)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Gotham
		label.TextSize = 13
		label.TextColor3 = U.Dim
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = detail
		local track = Instance.new("Frame")
		track.Position = UDim2.fromOffset(10, 144 + i * 46)
		track.Size = UDim2.new(1, -20, 0, 7)
		track.BackgroundColor3 = U.Dark
		track.BorderSizePixel = 0
		track.Parent = detail
		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = U.Sand
		fill.BorderSizePixel = 0
		fill.Parent = track
		statRows[i] = { label = label, fill = fill }
	end
	local dButton = Instance.new("TextButton")
	dButton.AnchorPoint = Vector2.new(0.5, 1)
	dButton.Position = UDim2.new(0.5, 0, 1, -10)
	dButton.Size = UDim2.new(1, -20, 0, 44)
	dButton.BackgroundColor3 = U.Gold
	dButton.BorderSizePixel = 0
	dButton.Font = Enum.Font.GothamBold
	dButton.TextSize = 18
	dButton.TextColor3 = U.OnGold
	dButton.Parent = detail

	local catButtons: { TextButton } = {}
	local current = 1
	-- режим продавца (НПС): вместо оружия по категориям — список товаров продавца за монеты
	local vendor: { vendorId: string, title: string, greeting: string, items: { { id: string, name: string, desc: string, price: number, kind: string, requires: string? } }, store: boolean? }? = nil

	local function populateVendor(v: { vendorId: string, title: string, greeting: string, items: { { id: string, name: string, desc: string, price: number, kind: string, requires: string? } }, store: boolean? })
		title.Text = v.title
		hint.Text = v.greeting .. "  ·  Esc — close"
		for order, item in v.items do
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, 0, 0, 54)
			row.LayoutOrder = order
			row.BackgroundColor3 = U.Card
			row.Text = ""
			row.Parent = list
			local name = Instance.new("TextLabel")
			name.Position = UDim2.fromOffset(12, 5)
			name.Size = UDim2.new(1, -150, 0, 22)
			name.BackgroundTransparency = 1
			name.Font = Enum.Font.GothamBold
			name.TextSize = 18
			name.TextColor3 = Color3.new(1, 1, 1)
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.Text = item.name
			name.Parent = row
			local desc = Instance.new("TextLabel")
			desc.Position = UDim2.fromOffset(12, 29)
			desc.Size = UDim2.new(1, -150, 0, 18)
			desc.BackgroundTransparency = 1
			desc.Font = Enum.Font.Gotham
			desc.TextSize = 13
			desc.TextColor3 = U.Dim
			desc.TextXAlignment = Enum.TextXAlignment.Left
			desc.Text = item.desc
			desc.Parent = row
			local price = Instance.new("TextLabel")
			price.AnchorPoint = Vector2.new(1, 0.5)
			price.Position = UDim2.new(1, -12, 0.5, 0)
			price.Size = UDim2.fromOffset(120, 24)
			price.BackgroundTransparency = 1
			price.Font = Enum.Font.GothamBold
			price.TextSize = 18
			price.TextColor3 = ACCENT
			price.TextXAlignment = Enum.TextXAlignment.Right
			price.Text = "$" .. item.price
			price.Parent = row
			-- товар привязан к зданию (аптечка в автомате): пока оно не открыто — товар виден, но недоступен
			local lockedBy: string? = nil
			if item.requires then
				local states = game:GetService("ReplicatedStorage"):GetAttribute("BuildingStates")
				if typeof(states) ~= "string" or not string.find(states, item.requires .. "=open", 1, true) then
					lockedBy = item.requires
				end
			end
			if lockedBy then
				local def: any = nil
				for _, b in Config.Buildings do
					if b.id == lockedBy then
						def = b
					end
				end
				row.AutoButtonColor = false
				row.BackgroundColor3 = U.Dark
				name.TextColor3 = Color3.fromRGB(140, 142, 150)
				price.TextColor3 = Color3.fromRGB(215, 120, 100)
				price.TextSize = 14
				price.Text = "Open " .. (if def then def.name else lockedBy) .. " first"
				desc.Text = item.desc .. " · locked"
			end
			row.Activated:Connect(function()
				if lockedBy then
					return
				end
				Remotes.get("VendorBuy"):FireServer(v.vendorId, item.id)
			end)
		end
		-- робуксовый магазин — отдельное окно
		if v.store then
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, 0, 0, 50)
			row.LayoutOrder = #v.items + 1
			row.BackgroundColor3 = U.Gold
			row.BorderSizePixel = 0
			row.Font = Enum.Font.GothamBold
			row.TextSize = 18
			row.TextColor3 = U.OnGold
			row.Text = "OPEN ROBUX SHOP"
			row.Parent = list
			row.Activated:Connect(function()
				require(script.Parent:WaitForChild("StoreController")).open()
			end)
		end
	end

	local selected: string? = nil
	local preview: ViewportFrame? = nil
	local strokes: { [string]: UIStroke } = {}

	local function ownedFree(id: string): boolean
		return player:GetAttribute("Has_" .. CaseRules.perkFor(id)) == true
	end

	local function priceText(def: Config.WeaponDef): string
		if player:GetAttribute("ShopFree") == true or ownedFree(def.id) or def.price == 0 then
			return "FREE"
		end
		return "$" .. def.price
	end

	-- Полоски характеристик: доля от лучшего значения среди всего оружия этого типа
	local maxima = { dmg = 1, rate = 1, mag = 1, meleeDmg = 1, meleeRate = 1, range = 1 }
	for _, item in Config.ShopList do
		local d = Config.Weapons[item.id]
		if d.melee then
			maxima.meleeDmg, maxima.meleeRate, maxima.range = math.max(maxima.meleeDmg, d.damage), math.max(maxima.meleeRate, d.fireRate), math.max(maxima.range, d.range)
		else
			maxima.dmg, maxima.rate, maxima.mag = math.max(maxima.dmg, d.damage * d.pellets), math.max(maxima.rate, d.fireRate), math.max(maxima.mag, d.magSize)
		end
	end

	local function showDetail(id: string)
		selected = id
		local def = Config.Weapons[id]
		for key, s in strokes do
			s.Color = if key == id then U.Gold else U.Line
			s.Thickness = if key == id then 2 else 1
		end
		if preview then
			preview:Destroy()
		end
		preview = WeaponIcon.make(detail, id, UDim2.fromOffset(10, 10), UDim2.new(1, -20, 0, 120))
		dName.Text = def.name
		local rows = if def.melee
			then { { "Damage", def.damage, maxima.meleeDmg }, { "Hits per second", def.fireRate, maxima.meleeRate }, { "Reach", def.range, maxima.range } }
			else { { "Damage", def.damage * def.pellets, maxima.dmg }, { "Fire rate", def.fireRate, maxima.rate }, { "Magazine", def.magSize, maxima.mag } }
		for i, r in rows do
			statRows[i].label.Text = string.format("%s  %s", r[1] :: string, tostring(math.floor((r[2] :: number) * 10 + 0.5) / 10))
			statRows[i].fill.Size = UDim2.fromScale(math.clamp((r[2] :: number) / (r[3] :: number), 0.04, 1), 1)
		end
		local price = priceText(def)
		dButton.Text = if price == "FREE" then "TAKE" else "BUY  " .. price
	end
	dButton.Activated:Connect(function()
		if selected then
			Remotes.get("BuyWeapon"):FireServer(selected)
		end
	end)

	local function populate()
		for _, c in list:GetChildren() do
			if c:IsA("TextButton") or c:IsA("Frame") or c:IsA("TextLabel") then
				c:Destroy()
			end
		end
		table.clear(strokes)
		cats.Visible = vendor == nil
		detail.Visible = vendor == nil
		gridLayout.Parent = if vendor then nil else list
		listLayout.Parent = if vendor then list else nil
		if vendor then
			list.Position = UDim2.fromOffset(12, 56)
			list.Size = UDim2.new(1, -24, 0, 450)
			populateVendor(vendor)
			list.CanvasPosition = Vector2.zero
			return
		end
		list.Position = UDim2.fromOffset(140, 56)
		list.Size = UDim2.new(1, -372, 0, 450)
		title.Text = "ARMORY"
		hint.Text = "B / Esc — close · 1–6 — category · click a weapon, then buy"
		for i, b in catButtons do
			b.BackgroundColor3 = if i == current then U.Accent else U.Card
			b.TextColor3 = if i == current then U.Text else U.Dim
		end
		local first: string? = nil
		for order, item in Config.ShopList do
			if item.category == current and (not Config.DonateOnly[item.id] or ownedFree(item.id)) then
				local def = Config.Weapons[item.id]
				first = first or item.id
				local card = Instance.new("TextButton")
				card.LayoutOrder = order
				card.BackgroundColor3 = U.Card
				card.AutoButtonColor = false
				card.BorderSizePixel = 0
				card.Text = ""
				card.Parent = list
				local stroke = Instance.new("UIStroke")
				stroke.Color = U.Line
				stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				stroke.Parent = card
				strokes[item.id] = stroke
				WeaponIcon.make(card, item.id, UDim2.fromOffset(6, 6), UDim2.new(1, -12, 0, 84))
				local name = Instance.new("TextLabel")
				name.Position = UDim2.fromOffset(8, 94)
				name.Size = UDim2.new(1, -16, 0, 20)
				name.BackgroundTransparency = 1
				name.Font = Enum.Font.GothamBold
				name.TextSize = 14
				name.TextColor3 = U.Text
				name.TextXAlignment = Enum.TextXAlignment.Left
				name.TextTruncate = Enum.TextTruncate.AtEnd
				name.Text = def.name
				name.Parent = card
				local price = Instance.new("TextLabel")
				price.AnchorPoint = Vector2.new(0, 1)
				price.Position = UDim2.new(0, 0, 1, 0)
				price.Size = UDim2.new(1, 0, 0, 26)
				price.BackgroundColor3 = if priceText(def) == "FREE" then U.Header else U.Accent
				price.BorderSizePixel = 0
				price.Font = Enum.Font.GothamBold
				price.TextSize = 15
				price.TextColor3 = U.Text
				price.Text = priceText(def)
				price.Parent = card
				card.Activated:Connect(function()
					showDetail(item.id)
				end)
			end
		end
		if first then
			showDetail(if selected and strokes[selected] then selected else first)
		end
		list.CanvasPosition = Vector2.zero
	end

	for i, name in Config.ShopCategories do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 44)
		b.BackgroundColor3 = U.Card
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 17
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.Text = "  " .. name
		b.AutoButtonColor = true
		b.LayoutOrder = i
		b.Parent = cats
		b.Activated:Connect(function()
			current = i
			populate()
		end)
		catButtons[i] = b
	end

	local ACTION = "BuyMenuKeys"
	local function close()
		gui.Enabled = false
		vendor = nil
		ContextActionService:UnbindAction(ACTION)
	end
	local function open()
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return
		end
		populate()
		gui.Enabled = true
		-- пока меню открыто, цифры и Esc принадлежат ему (иначе цифры переключают оружие)
		ContextActionService:BindActionAtPriority(ACTION, function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.B then
				close()
			else
				local n = input.KeyCode.Value - Enum.KeyCode.One.Value + 1
				if vendor == nil and n >= 1 and n <= #catButtons then
					current = n
					populate()
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value,
			Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six,
			Enum.KeyCode.Escape, Enum.KeyCode.B)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or gui.Enabled then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			if player:GetAttribute("NearShop") == true then
				open()
			end
		end
	end)
	Remotes.get("ShopOpen").OnClientEvent:Connect(function(payload: any)
		if gui.Enabled then
			close()
		else
			vendor = if typeof(payload) == "table" then payload else nil
			open()
		end
	end)
	player.CharacterAdded:Connect(close)
	-- ушёл от палатки — меню закрывается само
	player:GetAttributeChangedSignal("NearShop"):Connect(function()
		if player:GetAttribute("NearShop") ~= true and gui.Enabled and vendor == nil then
			close()
		end
	end)

	-- метки на военные палатки поблизости (приходят каждое утро)
	local markerGui = Instance.new("ScreenGui")
	markerGui.Name = "TentMarkers"
	markerGui.ResetOnSpawn = false
	markerGui.DisplayOrder = 5
	markerGui.Enabled = player:GetAttribute("MarksOn") ~= false -- переключатель меток (InfoController, клавиша M)
	player:GetAttributeChangedSignal("MarksOn"):Connect(function()
		local on = player:GetAttribute("MarksOn") ~= false
		markerGui.Enabled = on
		for _, d in markerGui:GetChildren() do
			if d:IsA("BillboardGui") then
				d.Enabled = on -- BillboardGui не гаснет вместе с ScreenGui
			end
		end
	end)
	markerGui.Parent = player:WaitForChild("PlayerGui")
	local markers: { { part: Part, label: TextLabel, name: string } } = {}
	local function clearMarkers()
		for _, m in markers do
			m.part:Destroy()
		end
		table.clear(markers)
	end
	Remotes.get("TentMarkers").OnClientEvent:Connect(function(list: { { pos: Vector3, name: string } })
		clearMarkers()
		for _, item in list do
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = 1
			part.Size = Vector3.one
			part.Position = item.pos + Vector3.new(0, 24, 0)
			part.Parent = workspace
			local bb = Instance.new("BillboardGui")
			bb.Adornee = part
			bb.AlwaysOnTop = true
			bb.Size = UDim2.fromOffset(170, 44)
			bb.MaxDistance = math.huge
			bb.Enabled = player:GetAttribute("MarksOn") ~= false
			bb.Parent = markerGui
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundColor3 = Color3.fromRGB(22, 24, 29)
			label.BackgroundTransparency = 0.25
			label.TextColor3 = ACCENT
			label.Font = Enum.Font.GothamBold
			label.TextSize = 15
			label.Text = item.name
			label.Parent = bb
			table.insert(markers, { part = part, label = label, name = item.name })
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.4)
			local cam = workspace.CurrentCamera
			if cam then
				for _, m in markers do
					m.label.Text = string.format("%s\n%d st.", m.name, math.floor((m.part.Position - cam.CFrame.Position).Magnitude))
				end
			end
		end
	end)
end

return ShopController
