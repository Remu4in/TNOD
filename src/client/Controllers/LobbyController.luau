--!strict
-- Интерфейс лобби: кнопки Squad / Play solo, окно отряда (создать, режим Public / Friends only / Invite only, вступить, пригласить,
-- Start), приглашения, личная статистика. Он же — экран итогов раунда с кнопкой «Back to lobby» (атрибут ReturnAt).
-- Все решения принимает сервер: клиент шлёт только LobbyCmd и рисует снимок LobbyState. Большие кнопки: работают мышью, пальцем и геймпадом.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local LobbyController = {}

local player = Players.LocalPlayer

local COLORS = {
	panel = Color3.fromRGB(22, 26, 30),
	row = Color3.fromRGB(38, 44, 50),
	button = Color3.fromRGB(56, 66, 76),
	good = Color3.fromRGB(60, 150, 80),
	warn = Color3.fromRGB(190, 80, 60),
	accent = Color3.fromRGB(230, 190, 70),
	text = Color3.fromRGB(235, 238, 235),
	dim = Color3.fromRGB(150, 158, 150),
}
local MODE_NAMES = { Public = "Public", Friends = "Friends only", Invite = "Invite only" }
local MODE_ORDER = { "Public", "Friends", "Invite" }

local function corner(inst: GuiObject, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = inst
end

local function frame(parent: Instance, size: UDim2, pos: UDim2?, color: Color3?): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = pos or UDim2.new()
	f.BackgroundColor3 = color or COLORS.panel
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function text(parent: Instance, str: string, size: UDim2, pos: UDim2?, textSize: number, color: Color3?, bold: boolean?): TextLabel
	local t = Instance.new("TextLabel")
	t.Size = size
	t.Position = pos or UDim2.new()
	t.BackgroundTransparency = 1
	t.Text = str
	t.TextColor3 = color or COLORS.text
	t.TextSize = textSize
	t.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.Parent = parent
	return t
end

local function button(parent: Instance, str: string, size: UDim2, pos: UDim2?, color: Color3?, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos or UDim2.new()
	b.BackgroundColor3 = color or COLORS.button
	b.AutoButtonColor = true
	b.Text = str
	b.TextColor3 = COLORS.text
	b.TextSize = 20
	b.Font = Enum.Font.GothamBold
	b.BorderSizePixel = 0
	b.Parent = parent
	corner(b)
	b.Activated:Connect(onClick)
	return b
end

function LobbyController.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Lobby"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 40
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local cmd = Remotes.get("LobbyCmd")
	local state: { [string]: any } = {}
	local inLobby = false

	-- ===== Верх слева: личная статистика =====
	local stats = frame(gui, UDim2.fromOffset(250, 70), UDim2.fromOffset(12, 12))
	corner(stats)
	local statsTitle = text(stats, "", UDim2.new(1, -20, 0, 28), UDim2.fromOffset(10, 6), 20, COLORS.accent, true)
	local statsLine = text(stats, "", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, 36), 17, COLORS.dim)
	local function refreshStats()
		statsTitle.Text = player.DisplayName
		statsLine.Text = string.format("Best night: %d   Rating: %d", (player:GetAttribute("BestWave") :: number?) or 0, (player:GetAttribute("RatingTotal") :: number?) or 0)
	end
	player:GetAttributeChangedSignal("BestWave"):Connect(refreshStats)
	player:GetAttributeChangedSignal("RatingTotal"):Connect(refreshStats)
	refreshStats()

	-- ===== Низ: большие кнопки =====
	local bar = frame(gui, UDim2.fromOffset(360, 76), UDim2.new(0.5, -180, 1, -92), COLORS.panel)
	bar.BackgroundTransparency = 0.25
	corner(bar, 12)
	local panel: Frame -- окно отряда (создаётся ниже)
	local function togglePanel(show: boolean?)
		panel.Visible = if show == nil then not panel.Visible else show
		if panel.Visible and UserInputService.GamepadEnabled then
			task.defer(function()
				local first = panel:FindFirstChildWhichIsA("TextButton", true)
				if first then
					GuiService.SelectedObject = first
				end
			end)
		end
	end
	button(bar, "SQUAD", UDim2.new(0.5, -14, 1, -16), UDim2.fromOffset(8, 8), COLORS.button, function()
		togglePanel(nil)
	end)
	button(bar, "PLAY SOLO", UDim2.new(0.5, -14, 1, -16), UDim2.new(0.5, 6, 0, 8), COLORS.good, function()
		cmd:FireServer("solo")
	end)

	-- ===== Окно отряда =====
	panel = frame(gui, UDim2.fromOffset(380, 460), UDim2.new(1, -392, 0.5, -230))
	panel.Visible = false
	corner(panel, 12)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 12), UDim.new(0, 12), UDim.new(0, 12), UDim.new(0, 12)
	pad.Parent = panel
	local panelTitle = text(panel, "Squad", UDim2.new(1, -52, 0, 32), nil, 24, COLORS.accent, true)
	button(panel, "X", UDim2.fromOffset(40, 32), UDim2.new(1, -40, 0, 0), COLORS.warn, function()
		togglePanel(false)
	end)
	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.new(1, 0, 1, -44)
	body.Position = UDim2.fromOffset(0, 40)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 5
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	local function row(height: number): Frame
		local r = frame(body, UDim2.new(1, -8, 0, height), nil, COLORS.row)
		r.LayoutOrder = nextOrder()
		corner(r, 6)
		return r
	end
	local function heading(str: string)
		local t = text(body, str, UDim2.new(1, -8, 0, 24), nil, 17, COLORS.dim, true)
		t.LayoutOrder = nextOrder()
	end

	local function render()
		for _, c in body:GetChildren() do
			if not c:IsA("UIListLayout") then
				c:Destroy()
			end
		end
		order = 0
		local squad = state.squad
		local myUid = player.UserId
		if squad then
			local leader = squad.owner == myUid
			panelTitle.Text = string.format("Your squad  %d/%d", #squad.members, squad.max)
			heading("MODE" .. (if leader then "" else "  (set by the leader)"))
			local modes = row(46)
			for i, m in MODE_ORDER do
				local b = button(modes, MODE_NAMES[m], UDim2.new(1 / 3, -6, 1, -8), UDim2.new((i - 1) / 3, 4, 0, 4), if squad.mode == m then COLORS.accent else COLORS.button, function()
					if leader and squad.mode ~= m then
						cmd:FireServer("mode", m)
					end
				end)
				b.TextSize = 15
				b.TextColor3 = if squad.mode == m then Color3.new(0, 0, 0) else COLORS.text
			end
			heading("MEMBERS")
			for _, m in squad.members do
				local r = row(40)
				text(r, (if m.uid == squad.owner then "★ " else "") .. m.name, UDim2.new(1, -90, 1, 0), UDim2.fromOffset(10, 0), 18)
				if leader and m.uid ~= myUid then
					button(r, "Kick", UDim2.fromOffset(70, 30), UDim2.new(1, -76, 0, 5), COLORS.warn, function()
						cmd:FireServer("kick", m.uid)
					end).TextSize = 16
				end
			end
			if leader and #squad.members < squad.max then
				heading("INVITE")
				local inSquad: { [number]: boolean } = {}
				for _, m in squad.members do
					inSquad[m.uid] = true
				end
				local any = false
				for _, other in Players:GetPlayers() do
					if not inSquad[other.UserId] then
						any = true
						local r = row(40)
						text(r, other.DisplayName, UDim2.new(1, -100, 1, 0), UDim2.fromOffset(10, 0), 18)
						button(r, "Invite", UDim2.fromOffset(80, 30), UDim2.new(1, -86, 0, 5), COLORS.button, function()
							cmd:FireServer("invite", other.UserId)
						end).TextSize = 16
					end
				end
				if not any then
					text(body, "No one else in the lobby yet", UDim2.new(1, -8, 0, 24), nil, 16, COLORS.dim).LayoutOrder = nextOrder()
				end
			end
			if leader then
				local start = button(body, if squad.locked then "Starting…" else "START", UDim2.new(1, -8, 0, 54), nil, COLORS.good, function()
					cmd:FireServer("start")
				end)
				start.LayoutOrder = nextOrder()
				start.TextSize = 26
			end
			local leave = button(body, "Leave squad", UDim2.new(1, -8, 0, 40), nil, COLORS.warn, function()
				cmd:FireServer("leave")
			end)
			leave.LayoutOrder = nextOrder()
		else
			panelTitle.Text = "Squad"
			heading("CREATE A SQUAD")
			local create = row(46)
			for i, m in MODE_ORDER do
				local b = button(create, MODE_NAMES[m], UDim2.new(1 / 3, -6, 1, -8), UDim2.new((i - 1) / 3, 4, 0, 4), COLORS.good, function()
					cmd:FireServer("create", m)
				end)
				b.TextSize = 15
			end
			text(body, "Create: Public, Friends only or Invite only", UDim2.new(1, -8, 0, 20), nil, 14, COLORS.dim).LayoutOrder = nextOrder()
			heading("OPEN SQUADS")
			local list = state.squads or {}
			if #list == 0 then
				text(body, "None yet. Create one or step on a truck", UDim2.new(1, -8, 0, 24), nil, 16, COLORS.dim).LayoutOrder = nextOrder()
			end
			for _, sq in list do
				local r = row(48)
				text(r, sq.owner .. "'s squad", UDim2.new(1, -110, 0, 24), UDim2.fromOffset(10, 2), 18)
				text(r, string.format("%s   %d/%d", MODE_NAMES[sq.mode] or sq.mode, sq.count, sq.max), UDim2.new(1, -110, 0, 18), UDim2.fromOffset(10, 26), 14, COLORS.dim)
				local join = button(r, "Join", UDim2.fromOffset(84, 34), UDim2.new(1, -90, 0, 7), if sq.joinable then COLORS.good else COLORS.button, function()
					cmd:FireServer("join", sq.id)
				end)
				join.TextSize = 17
				join.Active = sq.joinable
				join.AutoButtonColor = sq.joinable
			end
		end
	end

	-- ===== Приглашения и сообщения =====
	local toasts = Instance.new("Frame")
	toasts.Size = UDim2.fromOffset(340, 300)
	toasts.Position = UDim2.new(0.5, -170, 0, 12)
	toasts.BackgroundTransparency = 1
	toasts.Parent = gui
	local tl = Instance.new("UIListLayout")
	tl.Padding = UDim.new(0, 6)
	tl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tl.SortOrder = Enum.SortOrder.LayoutOrder
	tl.Parent = toasts

	local function toast(msg: string, seconds: number)
		local t = frame(toasts, UDim2.new(1, 0, 0, 40), nil, COLORS.panel)
		t.BackgroundTransparency = 0.15
		corner(t)
		local label = text(t, msg, UDim2.new(1, -16, 1, 0), UDim2.fromOffset(8, 0), 17)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextWrapped = true
		task.delay(seconds, function()
			t:Destroy()
		end)
	end

	Remotes.get("Notify").OnClientEvent:Connect(function(msg: string, seconds: number)
		if inLobby then
			toast(msg, seconds)
		end
	end)

	Remotes.get("LobbyInvite").OnClientEvent:Connect(function(squadId: number, fromName: string, seconds: number)
		if not inLobby then
			return
		end
		local t = frame(toasts, UDim2.new(1, 0, 0, 92), nil, COLORS.panel)
		corner(t)
		text(t, fromName .. " invites you to a squad", UDim2.new(1, -16, 0, 30), UDim2.fromOffset(8, 4), 17, COLORS.accent, true)
		button(t, "Accept", UDim2.new(0.5, -14, 0, 40), UDim2.fromOffset(8, 42), COLORS.good, function()
			cmd:FireServer("accept", squadId)
			t:Destroy()
			togglePanel(true)
		end)
		button(t, "Decline", UDim2.new(0.5, -14, 0, 40), UDim2.new(0.5, 6, 0, 42), COLORS.warn, function()
			cmd:FireServer("decline", squadId)
			t:Destroy()
		end)
		task.delay(seconds, function()
			if t.Parent then
				t:Destroy()
			end
		end)
	end)

	Remotes.get("LobbyState").OnClientEvent:Connect(function(s: { [string]: any })
		state = s
		if s.open then
			togglePanel(true)
		end
		if panel.Visible then
			render()
		end
	end)
	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible then
			render()
		end
	end)

	-- ===== Экран итогов раунда =====
	local results = frame(gui, UDim2.fromOffset(420, 300), UDim2.new(0.5, -210, 0.5, -150))
	results.Visible = false
	results.ZIndex = 5
	corner(results, 14)
	local resTitle = text(results, "", UDim2.new(1, -24, 0, 50), UDim2.fromOffset(12, 14), 36, COLORS.accent, true)
	resTitle.TextXAlignment = Enum.TextXAlignment.Center
	local resLines = text(results, "", UDim2.new(1, -24, 0, 110), UDim2.fromOffset(12, 70), 20)
	resLines.TextXAlignment = Enum.TextXAlignment.Center
	resLines.TextYAlignment = Enum.TextYAlignment.Top
	resLines.TextWrapped = true
	resLines.TextTruncate = Enum.TextTruncate.None
	local resTimer = text(results, "", UDim2.new(1, -24, 0, 24), UDim2.fromOffset(12, 186), 16, COLORS.dim)
	resTimer.TextXAlignment = Enum.TextXAlignment.Center
	local backBtn: TextButton
	backBtn = button(results, "BACK TO LOBBY", UDim2.new(1, -40, 0, 56), UDim2.fromOffset(20, 224), COLORS.good, function()
		Remotes.get("BackToLobby"):FireServer()
		backBtn.Text = "Returning…"
		backBtn.Active = false
	end)
	backBtn.TextSize = 24

	-- ===== Режимы =====
	-- В лобби прячем чужие экраны (HUD и т.п., если они запускались раньше в этом же клиенте — только Studio-заглушка)
	local hidden: { ScreenGui } = {}
	local function setLobbyVisible(on: boolean)
		inLobby = on
		gui.Enabled = on or results.Visible
		bar.Visible = on
		stats.Visible = on
		if not on then
			panel.Visible = false
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
					backBtn.Text = "BACK TO LOBBY"
					backBtn.Active = true
					if UserInputService.GamepadEnabled then
						GuiService.SelectedObject = backBtn
					end
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
