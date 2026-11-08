--!strict
-- Донатный магазин (робуксы): вкладки, карточки товаров, кейсы. Шансы показываются до оплаты, покупку и выпадение решает сервер (DonateService).
-- Картинка товара — Config.Donate.Images[id]; нет её — 3D-модель оружия (icon) или название на подложке.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CaseRules = require(Shared:WaitForChild("CaseRules"))
local WeaponIcon = require(script.Parent:WaitForChild("WeaponIcon"))

local StoreController = {}

local U = Config.UiKhaki
local TABS = { "Featured", "Cases", "Knives", "Passes" }

local openStore: () -> () = function() end

function StoreController.open()
	openStore()
end

local function mk(class: string, props: { [string]: any }, parent: Instance?): any
	local o: any = Instance.new(class)
	for k, v in props do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function text(parent: Instance, value: string, size: number, color: Color3, pos: UDim2, dim: UDim2, align: Enum.TextXAlignment?): TextLabel
	return mk("TextLabel", {
		BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = size, TextColor3 = color, Text = value, Position = pos, Size = dim,
		TextXAlignment = align or Enum.TextXAlignment.Left, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
	}, parent)
end

local function outline(o: Instance, color: Color3, thick: number)
	mk("UIStroke", { Color = color, Thickness = thick, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end

local function button(parent: Instance, value: string, bg: Color3, fg: Color3, pos: UDim2, dim: UDim2, fn: () -> ()): TextButton
	local b = mk("TextButton", { BackgroundColor3 = bg, BorderSizePixel = 0, Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = fg, Text = value, Position = pos, Size = dim }, parent)
	b.Activated:Connect(fn)
	return b
end

function StoreController.start()
	local player = Players.LocalPlayer
	local byId: { [string]: any } = {}
	for _, item in Config.Donate.Items do
		byId[item.id] = item
	end
	for _, c in Config.Donate.Cases do
		byId[c.id] = c
	end
	local names: { [string]: string } = {}
	for id, def in Config.Weapons do
		names[id] = def.name
	end

	local gui = mk("ScreenGui", { Name = "RobuxStore", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 40, Enabled = false }, player:WaitForChild("PlayerGui"))
	mk("TextButton", { Size = UDim2.fromScale(0, 0), BackgroundTransparency = 1, Text = "", Modal = true }, gui)
	mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0 }, gui)
	local main = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(900, 570), BackgroundColor3 = U.Bg, BorderSizePixel = 0 }, gui)
	outline(main, U.Line, 2)
	local scale = mk("UIScale", {}, main)
	local head = mk("Frame", { Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -24, 0, 42), BackgroundColor3 = U.Header, BorderSizePixel = 0 }, main)
	outline(head, U.Line, 1)
	text(head, "SUPPLY DROP", 22, U.Text, UDim2.fromOffset(12, 9), UDim2.fromOffset(400, 28))
	local tabsRow = mk("Frame", { Position = UDim2.fromOffset(12, 62), Size = UDim2.new(1, -24, 0, 34), BackgroundTransparency = 1 }, main)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, tabsRow)
	local content = mk("Frame", { Position = UDim2.fromOffset(12, 104), Size = UDim2.new(1, -24, 1, -116), BackgroundTransparency = 1, ClipsDescendants = true }, main)
	local overlay = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = U.Bg, BorderSizePixel = 0, Visible = false, ZIndex = 5 }, main)

	local tab = 1
	local rolling = false
	local tabButtons: { TextButton } = {}

	local function has(perk: string): boolean
		return player:GetAttribute("Has_" .. perk) == true
	end
	local function poolOf(item: any): { CaseRules.Chance }
		return CaseRules.pool(item.pool, function(id: string): boolean
			return has(CaseRules.perkFor(id))
		end)
	end
	local function ownedItem(item: any): boolean
		if item.pool then
			return #poolOf(item) == 0
		end
		return not item.days and has(item.perk)
	end
	local function restricted(): boolean
		return player:GetAttribute("CasesRestricted") == true
	end

	local showCase: (item: any) -> () = function() end

	local function art(parent: Instance, item: any)
		local image = Config.Donate.Images[item.id]
		local holder = mk("Frame", { Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 1, -82), BackgroundColor3 = U.Dark, BorderSizePixel = 0 }, parent)
		if image and image ~= "" then
			mk("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = image, ScaleType = Enum.ScaleType.Crop }, holder)
		elseif item.icon then
			local v = WeaponIcon.make(holder, item.icon, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1))
			v.BackgroundColor3 = U.Dark
		else
			local t = text(holder, string.upper(item.name), 16, U.Dim, UDim2.fromOffset(8, 0), UDim2.new(1, -16, 1, 0), Enum.TextXAlignment.Center)
			t.TextYAlignment = Enum.TextYAlignment.Center
		end
	end

	local function card(parent: Instance, item: any)
		local f = mk("Frame", { BackgroundColor3 = U.Card, BorderSizePixel = 0 }, parent)
		outline(f, U.Line, 1)
		art(f, item)
		text(f, item.name, 15, U.Text, UDim2.new(0, 8, 1, -78), UDim2.new(1, -16, 0, 18))
		local d = text(f, item.desc, 12, U.Dim, UDim2.new(0, 8, 1, -60), UDim2.new(1, -16, 0, 30))
		d.Font = Enum.Font.Gotham
		local owned = ownedItem(item)
		local blocked = item.pool ~= nil and restricted()
		local label = if blocked then "Not available" elseif owned then (if item.pool then "All collected" else "Owned") else item.price
		button(f, label, if owned or blocked then U.Header else U.Gold, if owned or blocked then U.Dim else U.OnGold, UDim2.new(0, 0, 1, -26), UDim2.new(1, 0, 0, 26), function()
			if owned or blocked then
				return
			end
			if item.pool then
				showCase(item)
			else
				Remotes.get("DonateBuy"):FireServer(item.id)
			end
		end)
		return f
	end

	local function render()
		for _, c in content:GetChildren() do
			c:Destroy()
		end
		for i, b in tabButtons do
			b.BackgroundColor3 = if i == tab then U.Accent else U.Card
			b.TextColor3 = if i == tab then U.Text else U.Dim
		end
		if TABS[tab] == "Featured" then
			local list = Config.Donate.Featured
			local big = card(content, byId[list[1]])
			big.Size = UDim2.new(0.36, -6, 1, -4)
			big.Position = UDim2.fromOffset(2, 2)
			outline(big, U.Gold, 2)
			for i = 2, #list do
				local c = card(content, byId[list[i]])
				c.Size = UDim2.new(0.2133, -8, 1, -4)
				c.Position = UDim2.new(0.36 + 0.2133 * (i - 2), 2, 0, 2)
			end
			return
		end
		local scroll = mk("ScrollingFrame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 5, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, content)
		mk("UIGridLayout", { CellSize = UDim2.fromOffset(200, 240), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
		mk("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingLeft = UDim.new(0, 2) }, scroll)
		local source: { any } = {}
		if TABS[tab] == "Cases" then
			source = Config.Donate.Cases
		else
			for _, item in Config.Donate.Items do
				if (item.icon ~= nil) == (TABS[tab] == "Knives") then
					table.insert(source, item)
				end
			end
			if TABS[tab] == "Knives" then
				table.insert(source, 1, byId.case_knife)
			end
		end
		for i, item in source do
			card(scroll, item).LayoutOrder = i
		end
	end

	local function clearOverlay()
		for _, c in overlay:GetChildren() do
			c:Destroy()
		end
	end

	local function closeOverlay()
		if not rolling then
			overlay.Visible = false
			clearOverlay()
			render()
		end
	end

	-- Окно кейса: шансы до оплаты
	showCase = function(item: any)
		clearOverlay()
		overlay.Visible = true
		text(overlay, string.upper(item.name), 24, U.Text, UDim2.fromOffset(20, 16), UDim2.new(1, -120, 0, 30)).ZIndex = 6
		local sub = text(overlay, item.desc .. ". Yours forever, free to take in the weapon shop." .. (if item.id == "case_knife" then "" else " Ammo is paid."), 13, U.Dim, UDim2.fromOffset(20, 50), UDim2.new(1, -40, 0, 20))
		sub.Font, sub.ZIndex = Enum.Font.Gotham, 6
		button(overlay, "X", U.Header, U.Text, UDim2.new(1, -56, 0, 14), UDim2.fromOffset(40, 34), closeOverlay).ZIndex = 6
		local scroll = mk("ScrollingFrame", { Position = UDim2.fromOffset(20, 80), Size = UDim2.new(1, -40, 1, -150), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 5, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ZIndex = 6 }, overlay)
		mk("UIGridLayout", { CellSize = UDim2.fromOffset(200, 96), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
		local pool = poolOf(item)
		table.sort(pool, function(a: CaseRules.Chance, b: CaseRules.Chance)
			return a.chance < b.chance
		end)
		for i, c in pool do
			local cell = mk("Frame", { BackgroundColor3 = U.Card, BorderSizePixel = 0, LayoutOrder = i, ZIndex = 6 }, scroll)
			outline(cell, if c.chance < 0.1 then U.Gold else U.Line, 1)
			WeaponIcon.make(cell, c.id, UDim2.fromOffset(4, 4), UDim2.new(1, -8, 0, 58)).ZIndex = 6
			text(cell, names[c.id] or c.id, 13, U.Text, UDim2.fromOffset(8, 66), UDim2.new(1, -70, 0, 24)).ZIndex = 6
			text(cell, string.format("%.1f%%", c.chance * 100), 14, U.Gold, UDim2.new(1, -66, 0, 66), UDim2.fromOffset(60, 24), Enum.TextXAlignment.Right).ZIndex = 6
		end
		-- Правила Roblox о случайных платных предметах: если сумма округлённых шансов может не дать 100%, нужна эта оговорка
		text(overlay, "Drop rates shown are for your account: weapons you already own cannot drop. Probabilities are rounded; total of displayed individual probabilities may not equal 100%.", 12, U.Dim, UDim2.new(0, 20, 1, -62), UDim2.new(1, -300, 0, 52)).ZIndex = 6
		button(overlay, "OPEN  " .. item.price, U.Gold, U.OnGold, UDim2.new(1, -240, 1, -58), UDim2.fromOffset(220, 44), function()
			if not rolling then
				Remotes.get("DonateBuy"):FireServer(item.id)
			end
		end).ZIndex = 6
	end

	-- Лента выпадения: останавливается на том, что решил сервер
	local function roulette(item: any, result: string)
		rolling = true
		clearOverlay()
		overlay.Visible = true
		text(overlay, string.upper(item.name), 24, U.Text, UDim2.fromOffset(20, 16), UDim2.new(1, -40, 0, 30)).ZIndex = 6
		local clip = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.new(1, -40, 0, 150), BackgroundColor3 = U.Dark, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 6 }, overlay)
		local CELL, COUNT, STOP = 150, 30, 26
		local strip = mk("Frame", { Size = UDim2.fromOffset(CELL * COUNT, 150), BackgroundTransparency = 1, ZIndex = 6 }, clip)
		local total = 0
		for _, e in item.pool do
			total += e.w
		end
		for i = 1, COUNT do
			local id = result
			if i ~= STOP then
				local r = math.random() * total
				for _, e in item.pool do
					r -= e.w
					if r <= 0 then
						id = e.id
						break
					end
				end
			end
			local cell = mk("Frame", { Position = UDim2.fromOffset((i - 1) * CELL + 4, 6), Size = UDim2.fromOffset(CELL - 8, 138), BackgroundColor3 = U.Card, BorderSizePixel = 0, ZIndex = 6 }, strip)
			WeaponIcon.make(cell, id, UDim2.fromOffset(4, 4), UDim2.new(1, -8, 0, 100)).ZIndex = 6
			text(cell, names[id] or id, 13, U.Text, UDim2.fromOffset(6, 110), UDim2.new(1, -12, 0, 24), Enum.TextXAlignment.Center).ZIndex = 6
		end
		mk("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = U.Gold, BorderSizePixel = 0, ZIndex = 7 }, clip)
		local width = clip.AbsoluteSize.X / math.max(scale.Scale, 0.01)
		local final = -((STOP - 0.5) * CELL + (math.random() - 0.5) * (CELL - 40) - width / 2)
		strip.Position = UDim2.fromOffset(width / 2, 0)
		local tween = TweenService:Create(strip, TweenInfo.new(Config.Donate.RollSeconds, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(final, 0) })
		local last = 0
		local tick = RunService.RenderStepped:Connect(function()
			local n = math.floor(-strip.Position.X.Offset / CELL)
			if n ~= last then
				last = n
				local s = mk("Sound", { SoundId = Config.Sounds.click, Volume = 0.25, PlaybackSpeed = 1.5 }, SoundService)
				s:Play()
				s.Ended:Once(function()
					s:Destroy()
				end)
			end
		end)
		tween:Play()
		tween.Completed:Wait()
		tick:Disconnect()
		rolling = false
		local got = text(overlay, "YOU GOT: " .. string.upper(names[result] or result), 22, U.Gold, UDim2.new(0, 20, 0.72, 0), UDim2.new(1, -40, 0, 30), Enum.TextXAlignment.Center)
		got.ZIndex = 6
		button(overlay, "CONTINUE", U.Gold, U.OnGold, UDim2.new(0.5, -110, 1, -70), UDim2.fromOffset(220, 44), closeOverlay).ZIndex = 6
	end

	for i, name in TABS do
		local b = button(tabsRow, name, U.Card, U.Dim, UDim2.new(), UDim2.fromOffset(120, 34), function()
			tab = i
			render()
		end)
		b.LayoutOrder = i
		tabButtons[i] = b
	end

	local ACTION = "RobuxStoreClose"
	local function close()
		if rolling then
			return
		end
		gui.Enabled = false
		overlay.Visible = false
		clearOverlay()
		ContextActionService:UnbindAction(ACTION)
	end
	button(head, "X", U.Card, U.Text, UDim2.new(1, -40, 0, 4), UDim2.fromOffset(36, 34), close)

	openStore = function()
		local cam = workspace.CurrentCamera
		if cam then
			scale.Scale = math.min(1, cam.ViewportSize.Y / 620, cam.ViewportSize.X / 960)
		end
		tab = 1
		render()
		gui.Enabled = true
		ContextActionService:BindActionAtPriority(ACTION, function(_, state)
			if state == Enum.UserInputState.Begin then
				close()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 5, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB)
	end

	-- Esc перехватывает сам Roblox (клавишу нельзя привязать): закрываем магазин, когда открылось его меню
	GuiService.MenuOpened:Connect(function()
		if gui.Enabled then
			close()
		end
	end)

	Remotes.get("StoreOpen").OnClientEvent:Connect(openStore)
	Remotes.get("CaseResult").OnClientEvent:Connect(function(caseId: string, weaponId: string)
		local item = byId[caseId]
		if item and gui.Enabled then
			task.spawn(roulette, item, weaponId)
		end
	end)
	player.AttributeChanged:Connect(function(name: string)
		if gui.Enabled and not rolling and not overlay.Visible and (string.sub(name, 1, 4) == "Has_" or name == "CasesRestricted") then
			render()
		end
	end)
end

return StoreController
