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

local ShopController = {}

local ACCENT = Color3.fromRGB(255, 170, 40)
local BG = Color3.fromRGB(22, 24, 29)
local PANEL = Color3.fromRGB(34, 37, 44)

local function statsText(def: Config.WeaponDef): string
	if def.melee then
		return string.format("Урон %d · %.1f уд/с · дальность %.1f", def.damage, def.fireRate, def.range)
	end
	local dmg = if def.pellets > 1 then string.format("%d×%d", def.damage, def.pellets) else tostring(def.damage)
	local reserve = if def.reserve < 0 then "∞" else tostring(def.reserve)
	return string.format("Урон %s · %.1f выстр/с · магазин %d / %s%s", dmg, def.fireRate, def.magSize, reserve, if def.automatic then " · авто" else "")
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
	main.Size = UDim2.fromOffset(760, 460)
	main.BackgroundColor3 = BG
	main.BackgroundTransparency = 0.05
	main.BorderSizePixel = 0
	main.Parent = gui
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(760, 460)
	limit.Parent = main
	local scale = Instance.new("UIScale")
	scale.Parent = main
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = main

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0, 36)
	title.Position = UDim2.fromOffset(14, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = ACCENT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "ОРУЖИЕ"
	title.Parent = main

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -20, 0, 20)
	hint.Position = UDim2.new(0, 14, 1, -26)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 14
	hint.TextColor3 = Color3.fromRGB(150, 155, 165)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = "B / Esc — закрыть · 1–6 — категория · клик — взять в руки"
	hint.Parent = main

	local cats = Instance.new("Frame")
	cats.Position = UDim2.fromOffset(14, 48)
	cats.Size = UDim2.fromOffset(170, 370)
	cats.BackgroundTransparency = 1
	cats.Parent = main
	local catLayout = Instance.new("UIListLayout")
	catLayout.Padding = UDim.new(0, 6)
	catLayout.Parent = cats

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(196, 48)
	list.Size = UDim2.new(1, -210, 0, 370)
	list.BackgroundColor3 = PANEL
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = main
	local listCorner = Instance.new("UICorner")
	listCorner.CornerRadius = UDim.new(0, 6)
	listCorner.Parent = list
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.Parent = list
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop, listPad.PaddingLeft, listPad.PaddingRight, listPad.PaddingBottom =
		UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6)
	listPad.Parent = list

	local catButtons: { TextButton } = {}
	local current = 1
	-- режим продавца (НПС): вместо оружия по категориям — список товаров продавца за монеты
	local vendor: { vendorId: string, title: string, greeting: string, items: { { id: string, name: string, desc: string, price: number, kind: string } } }? = nil

	local function populateVendor(v: { vendorId: string, title: string, greeting: string, items: { { id: string, name: string, desc: string, price: number, kind: string } } })
		title.Text = v.title
		hint.Text = v.greeting .. "  ·  Esc — закрыть"
		for order, item in v.items do
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, 0, 0, 54)
			row.LayoutOrder = order
			row.BackgroundColor3 = Color3.fromRGB(48, 52, 62)
			row.Text = ""
			row.Parent = list
			local rc = Instance.new("UICorner")
			rc.CornerRadius = UDim.new(0, 5)
			rc.Parent = row
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
			desc.TextColor3 = Color3.fromRGB(165, 170, 180)
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
			row.Activated:Connect(function()
				Remotes.get("VendorBuy"):FireServer(v.vendorId, item.id)
			end)
		end
	end

	local function populate()
		for _, c in list:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		cats.Visible = vendor == nil
		if vendor then
			populateVendor(vendor)
			list.CanvasPosition = Vector2.zero
			return
		end
		title.Text = "ОРУЖИЕ"
		hint.Text = "B / Esc — закрыть · 1–6 — категория · клик — взять в руки"
		for i, b in catButtons do
			b.BackgroundColor3 = if i == current then ACCENT else PANEL
			b.TextColor3 = if i == current then Color3.new(0, 0, 0) else Color3.fromRGB(225, 228, 235)
		end
		for order, item in Config.ShopList do
			if item.category == current then
				local def = Config.Weapons[item.id]
				local row = Instance.new("TextButton")
				row.Size = UDim2.new(1, 0, 0, 54)
				row.LayoutOrder = order
				row.BackgroundColor3 = Color3.fromRGB(48, 52, 62)
				row.AutoButtonColor = true
				row.Text = ""
				row.Parent = list
				local rc = Instance.new("UICorner")
				rc.CornerRadius = UDim.new(0, 5)
				rc.Parent = row
				local name = Instance.new("TextLabel")
				name.Position = UDim2.fromOffset(12, 5)
				name.Size = UDim2.new(1, -150, 0, 22)
				name.BackgroundTransparency = 1
				name.Font = Enum.Font.GothamBold
				name.TextSize = 18
				name.TextColor3 = Color3.new(1, 1, 1)
				name.TextXAlignment = Enum.TextXAlignment.Left
				name.Text = def.name
				name.Parent = row
				local stats = Instance.new("TextLabel")
				stats.Position = UDim2.fromOffset(12, 29)
				stats.Size = UDim2.new(1, -150, 0, 18)
				stats.BackgroundTransparency = 1
				stats.Font = Enum.Font.Gotham
				stats.TextSize = 13
				stats.TextColor3 = Color3.fromRGB(165, 170, 180)
				stats.TextXAlignment = Enum.TextXAlignment.Left
				stats.Text = statsText(def)
				stats.Parent = row
				local price = Instance.new("TextLabel")
				price.AnchorPoint = Vector2.new(1, 0.5)
				price.Position = UDim2.new(1, -12, 0.5, 0)
				price.Size = UDim2.fromOffset(120, 24)
				price.BackgroundTransparency = 1
				price.Font = Enum.Font.GothamBold
				price.TextSize = 18
				price.TextColor3 = ACCENT
				price.TextXAlignment = Enum.TextXAlignment.Right
				price.Text = if player:GetAttribute("ShopFree") == true or def.price == 0 then "ВЗЯТЬ" else "$" .. def.price
				price.Parent = row
				row.Activated:Connect(function()
					Remotes.get("BuyWeapon"):FireServer(item.id)
				end)
			end
		end
		list.CanvasPosition = Vector2.zero
	end

	for i, name in Config.ShopCategories do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 44)
		b.BackgroundColor3 = PANEL
		b.Font = Enum.Font.GothamBold
		b.TextSize = 17
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.Text = "  " .. i .. "  " .. name
		b.AutoButtonColor = true
		b.LayoutOrder = i
		b.Parent = cats
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 5)
		bc.Parent = b
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
					m.label.Text = string.format("%s\n%d ст.", m.name, math.floor((m.part.Position - cam.CFrame.Position).Magnitude))
				end
			end
		end
	end)
end

return ShopController
