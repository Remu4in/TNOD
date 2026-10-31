--!strict
-- Интерфейс лобби: меню хоста зоны сбора (число игроков, доступ, приглашения; кнопки Open squad / Start now / Cancel), панель
-- команды после открытия зоны (состав, отсчёт, Start now), окна торговца и автомата («Coming soon»), приглашения, личная статистика.
-- Он же — экран итогов раунда с кнопкой «Back to lobby» (атрибут ReturnAt).
-- Все решения принимает сервер: клиент шлёт только LobbyCmd и рисует снимок LobbyState. Единый военный стиль: тёмные панели с
-- золотым акцентом, крупные кнопки (телефон — касание, геймпад — выбор через GuiService и SelectionImageObject).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local LobbyController = {}

local player = Players.LocalPlayer

local C = {
	panel = Color3.fromRGB(15, 19, 17),
	panel2 = Color3.fromRGB(26, 32, 28),
	row = Color3.fromRGB(34, 41, 36),
	button = Color3.fromRGB(52, 62, 56),
	good = Color3.fromRGB(62, 160, 92),
	warn = Color3.fromRGB(190, 66, 56),
	amber = Color3.fromRGB(226, 160, 44),
	gold = Color3.fromRGB(255, 204, 92),
	text = Color3.fromRGB(236, 238, 230),
	dim = Color3.fromRGB(150, 158, 146),
	dark = Color3.fromRGB(10, 12, 11),
}
local HEAD = Enum.Font.Oswald
local BODY = Enum.Font.GothamBold
local ACCESS = { { id = "Public", name = "Public", desc = "Anyone can join" }, { id = "Friends", name = "Friends only", desc = "Only your friends" }, { id = "Invite", name = "Invite only", desc = "Only players you invite" } }
local ACCESS_NAME = { Public = "Public", Friends = "Friends only", Invite = "Invite only" }

local function mk(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(inst: Instance, radius: number?)
	mk("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, inst)
end

local function stroke(inst: Instance, color: Color3?, thickness: number?, transparency: number?)
	mk("UIStroke", { Color = color or C.gold, Thickness = thickness or 1.5, Transparency = transparency or 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, inst)
end

local function gradient(inst: Instance, a: Color3, b: Color3, rotation: number?)
	mk("UIGradient", { Color = ColorSequence.new(a, b), Rotation = rotation or 90 }, inst)
end

local function pad(inst: Instance, px: number)
	mk("UIPadding", { PaddingTop = UDim.new(0, px), PaddingBottom = UDim.new(0, px), PaddingLeft = UDim.new(0, px), PaddingRight = UDim.new(0, px) }, inst)
end

-- Подсветка выбранной геймпадом кнопки
local selection = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, nil)
corner(selection, 10)
mk("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 3 }, selection)

local function label(parent: Instance, text: string, size: number, color: Color3?, font: Enum.Font?, align: Enum.TextXAlignment?): TextLabel
	return mk("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		TextColor3 = color or C.text,
		Font = font or BODY,
		TextXAlignment = align or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, parent)
end

-- Большая кнопка: минимум 48 px по высоте для касания, геймпад выбирает рамкой
local function button(parent: Instance, text: string, color: Color3, onClick: () -> ()): TextButton
	local b = mk("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = C.text,
		TextSize = 22,
		Font = HEAD,
		SelectionImageObject = selection,
	}, parent)
	corner(b, 10)
	stroke(b, Color3.new(1, 1, 1), 1, 0.8) -- без UIGradient: градиент красил бы и текст кнопки
	b.Activated:Connect(onClick)
	return b
end

local function setSelected(b: GuiObject?)
	if UserInputService.GamepadEnabled and b then
		task.defer(function()
			GuiService.SelectedObject = b
		end)
	end
end

-- Появление окна: плавный подъём прозрачности и масштаба
local function popIn(group: CanvasGroup, scale: UIScale, target: number)
	group.GroupTransparency = 1
	scale.Scale = target * 0.92
	TweenService:Create(group, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { GroupTransparency = 0 }):Play()
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back), { Scale = target }):Play()
end

-- Масштаб интерфейса под экран: крупно на телефоне и на 4K
local function uiScale(): number
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local s = math.min(vp.X / 1100, vp.Y / 640)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		s = math.min(vp.X / 900, vp.Y / 520)
	end
	return math.clamp(s, 0.62, 1.4)
end

local function window(gui: ScreenGui, name: string, width: number, height: number, anchor: Vector2, position: UDim2): (CanvasGroup, UIScale, Frame)
	local group = mk("CanvasGroup", {
		Name = name,
		AnchorPoint = anchor,
		Position = position,
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.06,
		BorderSizePixel = 0,
		Visible = false,
	}, gui)
	corner(group, 16)
	gradient(group, Color3.fromRGB(30, 38, 33), Color3.fromRGB(12, 15, 13))
	stroke(group, C.gold, 2, 0.35)
	local scale = mk("UIScale", { Scale = uiScale() }, group)
	local body = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, group)
	return group, scale, body
end

function LobbyController.start()
	local gui = mk("ScreenGui", {
		Name = "Lobby",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 40,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		Enabled = false,
	}, player:WaitForChild("PlayerGui"))

	local cmd = Remotes.get("LobbyCmd")
	local state: { [string]: any } = {}
	local inLobby = false
	local rescale: { UIScale } = {}

	-- ===== Верх слева: личная статистика =====
	local stats = mk("Frame", { Size = UDim2.fromOffset(270, 76), Position = UDim2.fromOffset(12, 12), BackgroundColor3 = C.panel, BackgroundTransparency = 0.15, BorderSizePixel = 0 }, gui)
	corner(stats, 12)
	stroke(stats, C.gold, 1.5, 0.6)
	local statsTitle = label(stats, "", 24, C.gold, HEAD)
	statsTitle.Size, statsTitle.Position = UDim2.new(1, -24, 0, 30), UDim2.fromOffset(12, 8)
	local statsLine = label(stats, "", 17, C.dim)
	statsLine.Size, statsLine.Position = UDim2.new(1, -24, 0, 26), UDim2.fromOffset(12, 40)
	local function refreshStats()
		statsTitle.Text = string.upper(player.DisplayName)
		statsLine.Text = string.format("Best night %d   ·   Rating %d", (player:GetAttribute("BestWave") :: number?) or 0, (player:GetAttribute("RatingTotal") :: number?) or 0)
	end
	player:GetAttributeChangedSignal("BestWave"):Connect(refreshStats)
	player:GetAttributeChangedSignal("RatingTotal"):Connect(refreshStats)
	refreshStats()

	-- подсказка сверху по центру
	local tip = mk("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(560, 30),
		BackgroundTransparency = 1,
		Text = "Step into a glowing zone to host a squad  ·  Solo mission: east gate",
		TextColor3 = C.text,
		TextStrokeTransparency = 0.5,
		TextSize = 18,
		Font = BODY,
	}, gui)

	-- ===== Тосты =====
	local toasts = mk("Frame", { Size = UDim2.fromOffset(380, 360), Position = UDim2.new(0.5, -190, 0, 48), BackgroundTransparency = 1 }, gui)
	mk("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, toasts)
	local function toast(msg: string, seconds: number)
		local t = mk("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = C.panel, BackgroundTransparency = 0.1, BorderSizePixel = 0 }, toasts)
		corner(t, 10)
		stroke(t, C.gold, 1.5, 0.55)
		local l = label(t, msg, 18, C.text, BODY, Enum.TextXAlignment.Center)
		l.Size, l.Position, l.TextWrapped = UDim2.new(1, -20, 1, 0), UDim2.fromOffset(10, 0), true
		task.delay(seconds, function()
			t:Destroy()
		end)
	end
	Remotes.get("Notify").OnClientEvent:Connect(function(msg: string, seconds: number)
		if inLobby then
			toast(msg, seconds)
		end
	end)
	Remotes.get("LobbyInvite").OnClientEvent:Connect(function(zoneIndex: number, fromName: string, seconds: number)
		if not inLobby then
			return
		end
		local t = mk("Frame", { Size = UDim2.new(1, 0, 0, 96), BackgroundColor3 = C.panel, BackgroundTransparency = 0.05, BorderSizePixel = 0 }, toasts)
		corner(t, 12)
		stroke(t, C.gold, 2, 0.3)
		local l = label(t, string.format("%s invites you to Squad %d", fromName, zoneIndex), 19, C.gold, HEAD)
		l.Size, l.Position = UDim2.new(1, -20, 0, 30), UDim2.fromOffset(12, 8)
		local l2 = label(t, "Walk into the zone to join", 16, C.dim)
		l2.Size, l2.Position = UDim2.new(1, -20, 0, 24), UDim2.fromOffset(12, 38)
		local ok = button(t, "Got it", C.good, function()
			t:Destroy()
		end)
		ok.Size, ok.Position = UDim2.new(1, -24, 0, 36), UDim2.fromOffset(12, 56)
		task.delay(seconds, function()
			if t.Parent then
				t:Destroy()
			end
		end)
	end)

	-- ===== Окно хоста: настройки зоны =====
	local setupWin, setupScale, setupBody = window(gui, "SquadSetup", 540, 600, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5))
	table.insert(rescale, setupScale)
	local setupChoice = { size = 4, access = "Public" }
	local setupKey = ""
	local editing = false

	local function renderSetup(zone: { [string]: any })
		for _, c in setupBody:GetChildren() do
			c:Destroy()
		end
		local isSetup = zone.state == "setup"
		pad(setupBody, 18)
		local title = label(setupBody, if isSetup then "SQUAD SETUP" else "SQUAD SETTINGS", 34, C.gold, HEAD)
		title.Size = UDim2.new(1, 0, 0, 40)
		local sub = label(setupBody, string.format("Zone %d  ·  You are the host", zone.id), 16, C.dim)
		sub.Size, sub.Position = UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 40)

		-- число игроков
		local h1 = label(setupBody, "SQUAD SIZE", 16, C.dim, HEAD)
		h1.Size, h1.Position = UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 74)
		local minSize = #zone.members
		for n = 1, zone.max do
			local chip = button(setupBody, tostring(n), if n == setupChoice.size then C.gold else C.button, function()
				if n >= minSize then
					setupChoice.size = n
					renderSetup(zone)
				end
			end)
			chip.TextColor3 = if n == setupChoice.size then C.dark else (if n < minSize then C.dim else C.text)
			chip.TextSize = 30
			local w = (500 - (zone.max - 1) * 8) / zone.max
			chip.Size, chip.Position = UDim2.fromOffset(w, 58), UDim2.fromOffset((n - 1) * (w + 8), 98)
		end

		-- доступ
		local h2 = label(setupBody, "ACCESS", 16, C.dim, HEAD)
		h2.Size, h2.Position = UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 172)
		for i, a in ACCESS do
			local on = setupChoice.access == a.id
			local b = button(setupBody, a.name, if on then C.gold else C.button, function()
				setupChoice.access = a.id
				renderSetup(zone)
			end)
			b.TextColor3 = if on then C.dark else C.text
			b.TextSize = 22
			b.Size, b.Position = UDim2.new(1 / 3, -6, 0, 52), UDim2.new((i - 1) / 3, if i == 1 then 0 else 4, 0, 196)
		end
		local desc = "Anyone can join"
		for _, a in ACCESS do
			if a.id == setupChoice.access then
				desc = a.desc
			end
		end
		local d = label(setupBody, desc, 15, C.dim)
		d.Size, d.Position = UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 252)

		-- приглашения
		local h3 = label(setupBody, "INVITE PLAYERS", 16, C.dim, HEAD)
		h3.Size, h3.Position = UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 282)
		local list = mk("ScrollingFrame", {
			BackgroundColor3 = C.panel2, BackgroundTransparency = 0.3, BorderSizePixel = 0, ScrollBarThickness = 5,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
			Size = UDim2.new(1, 0, 0, 120), Position = UDim2.fromOffset(0, 306),
		}, setupBody)
		corner(list, 10)
		pad(list, 6)
		mk("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		local others = 0
		local inZone: { [number]: boolean } = {}
		for _, m in zone.members do
			inZone[m.uid] = true
		end
		for _, other in Players:GetPlayers() do
			if other ~= player and not inZone[other.UserId] then
				others += 1
				local r = mk("Frame", { Size = UDim2.new(1, -8, 0, 40), BackgroundColor3 = C.row, BorderSizePixel = 0 }, list)
				corner(r, 8)
				local n = label(r, other.DisplayName, 18)
				n.Size, n.Position = UDim2.new(1, -110, 1, 0), UDim2.fromOffset(10, 0)
				local inv: TextButton
				inv = button(r, "Invite", C.button, function()
					cmd:FireServer("invite", other.UserId)
					inv.Text = "Sent"
				end)
				inv.TextSize = 18
				inv.Size, inv.Position = UDim2.fromOffset(88, 32), UDim2.new(1, -94, 0, 4)
			end
		end
		if others == 0 then
			local e = label(list, "No other players in the lobby yet", 16, C.dim)
			e.Size = UDim2.new(1, -8, 0, 36)
		end

		-- состав (если зона открыта и в ней уже есть люди)
		if not isSetup and #zone.members > 1 then
			local m = label(setupBody, string.format("In the zone now: %d", #zone.members), 15, C.dim)
			m.Size, m.Position = UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 430)
		end

		-- кнопки
		local primary = button(setupBody, if isSetup then "OPEN SQUAD" else "APPLY", C.good, function()
			cmd:FireServer(if isSetup then "open" else "config", { size = setupChoice.size, access = setupChoice.access })
			editing = false
			if not isSetup then
				setupWin.Visible = false
			end
		end)
		primary.TextSize = 26
		primary.Size, primary.Position = UDim2.new(0.5, -4, 0, 56), UDim2.new(0, 0, 1, -112)
		local startB = button(setupBody, "START NOW", C.amber, function()
			cmd:FireServer("start")
			editing = false
		end)
		startB.TextSize = 26
		startB.Size, startB.Position = UDim2.new(0.5, -4, 0, 56), UDim2.new(0.5, 4, 1, -112)
		local cancelB = button(setupBody, if isSetup then "CANCEL" else "BACK", C.warn, function()
			if isSetup then
				cmd:FireServer("cancel")
			end
			editing = false
			setupWin.Visible = false
		end)
		cancelB.TextSize = 22
		cancelB.Size, cancelB.Position = UDim2.new(1, 0, 0, 44), UDim2.new(0, 0, 1, -50)
		if not setupWin.Visible then
			setupWin.Visible = true
			popIn(setupWin, setupScale, uiScale())
			setSelected(primary)
		end
	end

	-- ===== Панель команды (зона открыта) =====
	local teamWin, teamScale, teamBody = window(gui, "SquadPanel", 320, 420, Vector2.new(1, 0.5), UDim2.new(1, -16, 0.5, 0))
	table.insert(rescale, teamScale)
	local teamBar: Frame? = nil
	local teamTimer: TextLabel? = nil
	local teamEndsAt: number? = nil
	local teamTotal = 12
	local teamKey = ""

	local function renderTeam(zone: { [string]: any })
		for _, c in teamBody:GetChildren() do
			c:Destroy()
		end
		pad(teamBody, 14)
		local isHost = zone.role == "host"
		local title = label(teamBody, string.format("SQUAD %d", zone.id), 30, C.gold, HEAD)
		title.Size = UDim2.new(1, 0, 0, 34)
		local sub = label(teamBody, string.format("%s  ·  %d/%d", ACCESS_NAME[zone.access] or zone.access, #zone.members, zone.size), 17, C.dim)
		sub.Size, sub.Position = UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 34)
		local list = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 210), Position = UDim2.fromOffset(0, 64) }, teamBody)
		mk("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		for _, m in zone.members do
			local r = mk("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.row, BorderSizePixel = 0 }, list)
			corner(r, 8)
			local isH = m.uid == zone.hostUid
			local n = label(r, (if isH then "★ " else "") .. m.name, 18, if isH then C.gold else C.text)
			n.Size, n.Position = UDim2.new(1, -70, 1, 0), UDim2.fromOffset(10, 0)
			if isHost and m.uid ~= player.UserId then
				local k = button(r, "Kick", C.warn, function()
					cmd:FireServer("kick", m.uid)
				end)
				k.TextSize = 16
				k.Size, k.Position = UDim2.fromOffset(56, 26), UDim2.new(1, -62, 0, 4)
			end
		end
		-- отсчёт
		local barBg = mk("Frame", { BackgroundColor3 = C.row, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 1, -112) }, teamBody)
		corner(barBg, 7)
		local bar = mk("Frame", { BackgroundColor3 = C.gold, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1) }, barBg)
		corner(bar, 7)
		teamBar = bar
		local timer = label(teamBody, "", 20, C.text, HEAD, Enum.TextXAlignment.Center)
		timer.Size, timer.Position = UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 1, -136)
		teamTimer = timer
		teamEndsAt = zone.endsAt
		teamTotal = zone.countdown or 12
		if isHost then
			local s = button(teamBody, "START NOW", C.good, function()
				cmd:FireServer("start")
			end)
			s.TextSize = 24
			s.Size, s.Position = UDim2.new(1, 0, 0, 48), UDim2.new(0, 0, 1, -92)
			local e = button(teamBody, "SETTINGS", C.button, function()
				editing = true
				setupKey = ""
				setupChoice.size, setupChoice.access = zone.size, zone.access
				teamWin.Visible = false
				renderSetup(zone)
			end)
			e.TextSize = 18
			e.Size, e.Position = UDim2.new(0.5, -4, 0, 36), UDim2.new(0, 0, 1, -40)
			local x = button(teamBody, "DISBAND", C.warn, function()
				cmd:FireServer("cancel")
			end)
			x.TextSize = 18
			x.Size, x.Position = UDim2.new(0.5, -4, 0, 36), UDim2.new(0.5, 4, 1, -40)
		else
			local w = label(teamBody, "Waiting for the host…", 18, C.dim, BODY, Enum.TextXAlignment.Center)
			w.Size, w.Position = UDim2.new(1, 0, 0, 40), UDim2.new(0, 0, 1, -70)
		end
		if not teamWin.Visible then
			teamWin.Visible = true
			popIn(teamWin, teamScale, uiScale())
		end
	end

	task.spawn(function()
		while true do
			local bar, timer = teamBar, teamTimer
			if teamWin.Visible and bar and timer and bar.Parent then
				local z = state.zone
				if teamEndsAt then
					local left = math.max(0, teamEndsAt - workspace:GetServerTimeNow())
					timer.Text = string.format("Starting in %d", math.ceil(left))
					bar.Size = UDim2.fromScale(math.clamp(1 - left / teamTotal, 0, 1), 1)
				elseif z and z.state == "launching" then
					timer.Text = "Launching…"
					bar.Size = UDim2.fromScale(1, 1)
				else
					timer.Text = if z and #z.members >= z.size then "Zone full" else "Waiting for players"
					bar.Size = UDim2.fromScale(0, 1)
				end
			end
			task.wait(0.1)
		end
	end)

	local function hideZoneWindows()
		setupWin.Visible = false
		teamWin.Visible = false
		editing = false
		setupKey = ""
		teamKey = ""
	end

	-- Окна перерисовываются, только когда изменилось содержимое (снимок приходит каждые 0.5–2 с)
	local function onState()
		if not inLobby then
			return
		end
		local zone = state.zone
		if not zone then
			hideZoneWindows()
			return
		end
		local names = {}
		for _, m in zone.members do
			table.insert(names, m.uid)
		end
		local content = string.format("%d:%s:%s:%d:%s:%d:%s", zone.id, zone.state, zone.role, #Players:GetPlayers(), table.concat(names, ","), zone.size, zone.access)
		if zone.role == "host" and (zone.state == "setup" or editing) then
			teamWin.Visible = false
			teamKey = ""
			local key = content .. tostring(editing)
			if key ~= setupKey then
				if not setupWin.Visible then
					setupChoice.size = if zone.state == "setup" then math.max(4, #zone.members) else zone.size
					setupChoice.access = zone.access
				end
				setupKey = key
				renderSetup(zone)
			end
		else
			setupWin.Visible = false
			setupKey = ""
			local key = content .. tostring(zone.endsAt ~= nil)
			if key ~= teamKey or not teamWin.Visible then
				teamKey = key
				renderTeam(zone)
			end
		end
	end

	-- ===== Окна торговца и автомата =====
	local menuWin, menuScale, menuBody = window(gui, "LobbyMenu", 640, 470, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5))
	table.insert(rescale, menuScale)
	local function closeMenu()
		menuWin.Visible = false
	end
	local function openMenu(kind: string, payload: { title: string, items: { { id: string, name: string, desc: string, price: string } } })
		for _, c in menuBody:GetChildren() do
			c:Destroy()
		end
		pad(menuBody, 18)
		local accent = if kind == "vending" then C.amber else C.gold
		local t = label(menuBody, string.upper(payload.title), 34, accent, HEAD)
		t.Size = UDim2.new(1, -60, 0, 40)
		local s = label(menuBody, if kind == "vending" then "Support the project: donation items" else "Cosmetics for your survivor", 16, C.dim)
		s.Size, s.Position = UDim2.new(1, -60, 0, 20), UDim2.fromOffset(0, 40)
		local x = button(menuBody, "X", C.warn, closeMenu)
		x.Size, x.Position = UDim2.fromOffset(48, 40), UDim2.new(1, -48, 0, 0)
		local grid = mk("ScrollingFrame", {
			BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 5,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
			Size = UDim2.new(1, 0, 1, -112), Position = UDim2.fromOffset(0, 72),
		}, menuBody)
		mk("UIGridLayout", { CellSize = UDim2.new(0.5, -6, 0, 116), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
		for _, item in payload.items do
			local card = mk("Frame", { BackgroundColor3 = C.row, BorderSizePixel = 0 }, grid)
			corner(card, 12)
			stroke(card, accent, 1.5, 0.75)
			local n = label(card, item.name, 22, C.text, HEAD)
			n.Size, n.Position = UDim2.new(1, -20, 0, 26), UDim2.fromOffset(12, 8)
			local d = label(card, item.desc, 14, C.dim)
			d.Size, d.Position, d.TextWrapped, d.TextTruncate = UDim2.new(1, -20, 0, 34), UDim2.fromOffset(12, 36), true, Enum.TextTruncate.None
			d.TextYAlignment = Enum.TextYAlignment.Top
			local price = label(card, item.price, 16, accent, HEAD)
			price.Size, price.Position = UDim2.new(0.5, -12, 0, 30), UDim2.new(0, 12, 1, -36)
			local buy = button(card, "BUY", C.button, function()
				cmd:FireServer("buy", item.id)
			end)
			buy.TextSize = 18
			buy.Size, buy.Position = UDim2.fromOffset(84, 32), UDim2.new(1, -96, 1, -38)
		end
		local foot = label(menuBody, "Purchases are not available yet — they will appear in a coming update", 14, C.dim, BODY, Enum.TextXAlignment.Center)
		foot.Size, foot.Position = UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 1, -26)
		if not menuWin.Visible then
			menuWin.Visible = true
			popIn(menuWin, menuScale, uiScale())
			setSelected(x)
		end
	end
	Remotes.get("LobbyMenu").OnClientEvent:Connect(function(kind: string, payload: any)
		if inLobby and typeof(kind) == "string" and typeof(payload) == "table" then
			openMenu(kind, payload)
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if input.KeyCode == Enum.KeyCode.ButtonB and menuWin.Visible then
			closeMenu()
		end
	end)

	Remotes.get("LobbyState").OnClientEvent:Connect(function(s: { [string]: any })
		state = s
		onState()
	end)

	-- ===== Экран итогов раунда =====
	local results, resultsScale, resultsBody = window(gui, "Results", 460, 380, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5))
	table.insert(rescale, resultsScale)
	pad(resultsBody, 20)
	local resTitle = label(resultsBody, "", 44, C.gold, HEAD, Enum.TextXAlignment.Center)
	resTitle.Size = UDim2.new(1, 0, 0, 52)
	local resLines = label(resultsBody, "", 22, C.text, BODY, Enum.TextXAlignment.Center)
	resLines.Size, resLines.Position = UDim2.new(1, 0, 0, 120), UDim2.fromOffset(0, 66)
	resLines.TextWrapped, resLines.TextTruncate, resLines.TextYAlignment = true, Enum.TextTruncate.None, Enum.TextYAlignment.Top
	local resTimer = label(resultsBody, "", 17, C.dim, BODY, Enum.TextXAlignment.Center)
	resTimer.Size, resTimer.Position = UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 1, -112)
	local backBtn: TextButton
	backBtn = button(resultsBody, "BACK TO LOBBY", C.good, function()
		Remotes.get("BackToLobby"):FireServer()
		backBtn.Text = "Returning…"
		backBtn.Active = false
	end)
	backBtn.TextSize = 28
	backBtn.Size, backBtn.Position = UDim2.new(1, 0, 0, 62), UDim2.new(0, 0, 1, -76)

	-- ===== Режимы =====
	local hidden: { ScreenGui } = {}
	local function setLobbyVisible(on: boolean)
		inLobby = on
		gui.Enabled = on or results.Visible
		stats.Visible = on
		tip.Visible = on
		toasts.Visible = on
		if not on then
			hideZoneWindows()
			menuWin.Visible = false
		end
		if on then
			for _, g in player.PlayerGui:GetChildren() do
				if g:IsA("ScreenGui") and g ~= gui and g.Enabled then
					g.Enabled = false
					table.insert(hidden, g)
				end
			end
		else
			for _, g in hidden do
				g.Enabled = true
			end
			table.clear(hidden)
		end
	end

	local function onMode()
		setLobbyVisible(ReplicatedStorage:GetAttribute("Mode") == "lobby")
	end
	ReplicatedStorage:GetAttributeChangedSignal("Mode"):Connect(onMode)
	onMode()

	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			for _, sc in rescale do
				sc.Scale = uiScale()
			end
		end)
	end

	local function resultsVisible(): boolean
		return (ReplicatedStorage:GetAttribute("ReturnAt") :: number?) ~= nil and not inLobby
	end
	local lastShown = false
	task.spawn(function()
		while true do
			local show = resultsVisible()
			if show ~= lastShown then
				lastShown = show
				results.Visible = show
				gui.Enabled = show or inLobby
				if show then
					local won = ReplicatedStorage:GetAttribute("Victory") ~= nil or ReplicatedStorage:GetAttribute("ActComplete") ~= nil
					resTitle.Text = if won then "VICTORY!" else "ROUND OVER"
					resTitle.TextColor3 = if won then C.gold else Color3.fromRGB(230, 96, 80)
					backBtn.Text = "BACK TO LOBBY"
					backBtn.Active = true
					popIn(results, resultsScale, uiScale())
					setSelected(backBtn)
				end
			end
			if show then
				local endsAt = (ReplicatedStorage:GetAttribute("ReturnAt") :: number?) or 0
				local left = math.max(0, math.ceil(endsAt - workspace:GetServerTimeNow()))
				resTimer.Text = string.format("Returning to the lobby in %d s", left)
				resLines.Text = string.format(
					"Nights survived: %d\nYour kills: %d\nRating earned: +%d",
					(ReplicatedStorage:GetAttribute("LastRoundWave") :: number?) or 0,
					(player:GetAttribute("RoundKills") :: number?) or 0,
					(player:GetAttribute("Rating") :: number?) or 0
				)
			end
			task.wait(0.25)
		end
	end)
end

return LobbyController
