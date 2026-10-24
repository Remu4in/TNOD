--!strict
-- Интерфейс, собранный кодом: фаза/таймер/волна, HP, монеты, патроны, уведомления, экран падения.
-- Все данные — из атрибутов (их меняет только сервер).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local HUDController = {}

local player = Players.LocalPlayer

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextScaled = true
	l.TextStrokeTransparency = 0.5
	for k, v in props do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

local PHASE_TEXT = {
	Intermission = "Перерыв",
	Day = "День",
	Night = "Ночь",
	GameOver = "Конец раунда",
}

function HUDController.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Прицел: отдельный ScreenGui без отступа под верхнюю панель. В обычном GUI центр на ~18 px ниже настоящего центра
	-- экрана, куда летят пули, — из-за этого прицел «врал». Четыре чёрточки расходятся по текущему разбросу
	-- (атрибут AimSpread ставит WeaponController), точка в центре, поверх — маркер попадания.
	local aimGui = Instance.new("ScreenGui")
	aimGui.Name = "AimHUD"
	aimGui.ResetOnSpawn = false
	aimGui.IgnoreGuiInset = true
	aimGui.DisplayOrder = 5
	aimGui.Parent = player:WaitForChild("PlayerGui")

	local function mark(size: Vector2, rotation: number?): Frame
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Size = UDim2.fromOffset(size.X, size.Y)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Rotation = rotation or 0
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BorderSizePixel = 0
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.45
		stroke.Parent = f
		f.Parent = aimGui
		return f
	end
	local dot = mark(Vector2.new(4, 4))
	dot.BackgroundTransparency = 0.1
	local bars = { mark(Vector2.new(3, 10)), mark(Vector2.new(3, 10)), mark(Vector2.new(10, 3)), mark(Vector2.new(10, 3)) } -- верх, низ, лево, право
	local hitMarks: { Frame } = {}
	for _, d in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
		local m = mark(Vector2.new(2, 9), if d.X * d.Y > 0 then -45 else 45)
		m.Position = UDim2.new(0.5, d.X * 11, 0.5, d.Y * 11)
		m.BackgroundTransparency = 1
		m.Visible = false -- иначе обводка (UIStroke) остаётся видимой и выглядит как второй прицел
		table.insert(hitMarks, m)
	end
	local hitToken = 0
	player:GetAttributeChangedSignal("HitMark"):Connect(function()
		local kind = tostring(player:GetAttribute("HitMark")):match("^(.-)|") or "hit"
		local color = if kind == "kill" then Color3.fromRGB(255, 70, 50) elseif kind == "head" then Color3.fromRGB(255, 215, 60) else Color3.new(1, 1, 1)
		hitToken += 1
		local token = hitToken
		for _, m in hitMarks do
			m.Visible = true
			m.BackgroundColor3 = color
			m.BackgroundTransparency = 0
			m.Size = UDim2.fromOffset(if kind == "head" then 3 else 2, if kind == "head" then 12 else 9)
			TweenService:Create(m, TweenInfo.new(0.28), { BackgroundTransparency = 1 }):Play()
		end
		task.delay(0.3, function()
			if token == hitToken then
				for _, m in hitMarks do
					m.BackgroundTransparency = 1
					m.Visible = false
				end
			end
		end)
	end)
	-- верх: фаза, таймер, волна, зомби
	local top = label(gui, {
		Name = "Top",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.02),
		Size = UDim2.fromScale(0.4, 0.06),
	})
	local sub = label(gui, {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.08),
		Size = UDim2.fromScale(0.3, 0.035),
		TextColor3 = Color3.fromRGB(220, 220, 220),
	})

	-- низ слева: HP и монеты
	local hpBack = Instance.new("Frame")
	hpBack.Name = "HP"
	hpBack.AnchorPoint = Vector2.new(0, 1)
	hpBack.Position = UDim2.fromScale(0.02, 0.95)
	hpBack.Size = UDim2.fromScale(0.22, 0.035)
	hpBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hpBack.BackgroundTransparency = 0.3
	hpBack.Parent = gui
	local hpFill = Instance.new("Frame")
	hpFill.Size = UDim2.fromScale(1, 1)
	hpFill.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBack
	local coins = label(gui, {
		Name = "Coins",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0.02, 0.9),
		Size = UDim2.fromScale(0.2, 0.045),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(255, 215, 90),
	})

	-- энергия (спринт) — тонкая полоска под здоровьем
	local energyBack = Instance.new("Frame")
	energyBack.Name = "Energy"
	energyBack.AnchorPoint = Vector2.new(0, 1)
	energyBack.Position = UDim2.fromScale(0.02, 0.978)
	energyBack.Size = UDim2.fromScale(0.22, 0.016)
	energyBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	energyBack.BackgroundTransparency = 0.3
	energyBack.Parent = gui
	local energyFill = Instance.new("Frame")
	energyFill.Size = UDim2.fromScale(1, 1)
	energyFill.BackgroundColor3 = Color3.fromRGB(80, 170, 255)
	energyFill.BorderSizePixel = 0
	energyFill.Parent = energyBack

	-- очки: личные и командные (справа сверху)
	local scoreLabel = label(gui, {
		Name = "Score",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.98, 0.02),
		Size = UDim2.fromScale(0.2, 0.04),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(255, 215, 90),
	})
	local teamLabel = label(gui, {
		Name = "Team",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.98, 0.063),
		Size = UDim2.fromScale(0.2, 0.03),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(190, 215, 255),
	})

	-- низ справа: патроны
	local ammo = label(gui, {
		Name = "Ammo",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(0.98, 0.95),
		Size = UDim2.fromScale(0.2, 0.06),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- подсказка по движению (на телефоне есть кнопки, там не нужна)
	if not (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		local hint = label(gui, {
			Name = "MoveHint",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.985),
			Size = UDim2.fromScale(0.42, 0.028),
			Text = "Shift — бег   ·   Q на бегу — подкат   ·   C — кувырок",
			TextTransparency = 0.35,
			TextStrokeTransparency = 0.7,
			TextColor3 = Color3.fromRGB(230, 230, 230),
		})
		local normalText = hint.Text
		local hintToken = 0
		-- отказ подката/кувырка (нет энергии, пауза) — красным вместо молчания
		player:GetAttributeChangedSignal("DodgeDenied"):Connect(function()
			local reason = tostring(player:GetAttribute("DodgeDenied")):match("^(.-)|") or ""
			hintToken += 1
			local token = hintToken
			hint.Text = reason
			hint.TextColor3 = Color3.fromRGB(255, 120, 100)
			hint.TextTransparency = 0
			task.delay(1.6, function()
				if token == hintToken then
					hint.Text = normalText
					hint.TextColor3 = Color3.fromRGB(230, 230, 230)
					hint.TextTransparency = 0.35
				end
			end)
		end)
	end

	-- центр: уведомления и экран падения
	local notice = label(gui, {
		Name = "Notice",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromScale(0.6, 0.05),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	local downed = label(gui, {
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromScale(0.5, 0.05),
		Text = "Вы упали! Товарищ может поднять вас",
		TextColor3 = Color3.fromRGB(255, 90, 90),
		Visible = false,
	})
	-- «Сдаться»: кнопка (Modal освобождает курсор в виде от первого лица) или удержание X / Y на геймпаде.
	-- Привязка клавиш — только пока игрок лежит, чтобы не занимать их в бою.
	local giveUp = Instance.new("TextButton")
	giveUp.Name = "GiveUp"
	giveUp.AnchorPoint = Vector2.new(0.5, 0)
	giveUp.Position = UDim2.fromScale(0.5, 0.66)
	giveUp.Size = UDim2.fromScale(0.2, 0.05)
	giveUp.BackgroundColor3 = Color3.fromRGB(60, 20, 20)
	giveUp.BackgroundTransparency = 0.2
	giveUp.Font = Enum.Font.GothamBold
	giveUp.TextScaled = true
	giveUp.TextColor3 = Color3.new(1, 1, 1)
	giveUp.Text = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "Сдаться" else "Сдаться (держите X)"
	giveUp.Modal = true
	giveUp.Visible = false
	giveUp.Parent = gui
	local function sendGiveUp()
		if player:GetAttribute("Downed") == true then
			Remotes.get("GiveUp"):FireServer()
		end
	end
	giveUp.Activated:Connect(sendGiveUp)
	local holdToken = 0
	local function onGiveUpKey(_: string, state: Enum.UserInputState): Enum.ContextActionResult
		holdToken += 1
		if state == Enum.UserInputState.Begin then
			local token = holdToken
			task.delay(1, function()
				if token == holdToken then -- клавишу не отпускали секунду
					sendGiveUp()
				end
			end)
		end
		return Enum.ContextActionResult.Sink
	end
	local function onDownedChanged()
		local isDown = player:GetAttribute("Downed") == true
		giveUp.Visible = isDown
		if isDown then
			ContextActionService:BindAction("NotdGiveUp", onGiveUpKey, false, Enum.KeyCode.X, Enum.KeyCode.ButtonY)
			-- свою подсказку «Поднять» себе не показываем (поднять себя нельзя, сервер это и так отклоняет)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root then
				task.spawn(function()
					local prompt = root:WaitForChild("RevivePrompt", 3) -- сервер ставит подсказку в том же кадре, что и Downed
					if prompt and prompt:IsA("ProximityPrompt") then
						prompt.Enabled = false
					end
				end)
			end
		else
			holdToken += 1
			ContextActionService:UnbindAction("NotdGiveUp")
		end
	end
	player:GetAttributeChangedSignal("Downed"):Connect(onDownedChanged)
	onDownedChanged()

	local noticeToken = 0
	Remotes.get("Notify").OnClientEvent:Connect(function(text: string, seconds: number)
		noticeToken += 1
		local token = noticeToken
		notice.Text = text
		notice.TextTransparency = 0
		notice.TextStrokeTransparency = 0.5
		task.delay(seconds, function()
			if token == noticeToken then
				TweenService:Create(notice, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end)
	end)

	local function currentTool(): Tool?
		local char = player.Character
		return char and char:FindFirstChildOfClass("Tool")
	end

	RunService.RenderStepped:Connect(function()
		-- перекрестие: зазор растёт с разбросом (в пикселях по текущему полю зрения), у ближнего боя чёрточек нет
		local camera = workspace.CurrentCamera
		local spread = (player:GetAttribute("AimSpread") :: number?) or 0
		local show = spread > 0
		local px = if camera then math.tan(math.rad(spread)) / math.tan(math.rad(camera.FieldOfView / 2)) * (camera.ViewportSize.Y / 2) else 0
		local gap = math.clamp(4 + px, 4, 160)
		bars[1].Position = UDim2.new(0.5, 0, 0.5, -(gap + 5))
		bars[2].Position = UDim2.new(0.5, 0, 0.5, gap + 5)
		bars[3].Position = UDim2.new(0.5, -(gap + 5), 0.5, 0)
		bars[4].Position = UDim2.new(0.5, gap + 5, 0.5, 0)
		for _, b in bars do
			b.Visible = show
		end

		local phase = ReplicatedStorage:GetAttribute("Phase") :: string?
		local wave = (ReplicatedStorage:GetAttribute("Wave") :: number?) or 0
		local endsAt = (ReplicatedStorage:GetAttribute("PhaseEndsAt") :: number?) or 0
		local left = math.max(0, math.ceil(endsAt - workspace:GetServerTimeNow()))
		local name = phase and PHASE_TEXT[phase] or "..."
		if phase == "Night" then
			top.Text = string.format("Ночь %d", wave)
			sub.Text = string.format("Зомби: %d", (ReplicatedStorage:GetAttribute("ZombiesLeft") :: number?) or 0)
		elseif phase == "GameOver" then
			top.Text = name
			sub.Text = string.format("Продержались ночей: %d", (ReplicatedStorage:GetAttribute("LastRoundWave") :: number?) or 0)
		else
			top.Text = string.format("%s  %d", name, left)
			sub.Text = if wave > 0 then string.format("Пережито ночей: %d", wave) else string.format("Рекорд: %d", (player:GetAttribute("BestWave") :: number?) or 0)
		end

		local char = player.Character
		local h = char and char:FindFirstChildOfClass("Humanoid")
		local frac = if h and h.MaxHealth > 0 then math.clamp(h.Health / h.MaxHealth, 0, 1) else 0
		hpFill.Size = UDim2.fromScale(frac, 1)
		coins.Text = string.format("● %d", (player:GetAttribute("Coins") :: number?) or 0)
		local isDown = player:GetAttribute("Downed") == true
		downed.Visible = isDown
		if isDown then
			local untilAt = (player:GetAttribute("DownedUntil") :: number?) or 0
			local leftDown = math.max(0, math.ceil(untilAt - workspace:GetServerTimeNow()))
			downed.Text = string.format("Вы упали! Товарищ может поднять вас (E) · осталось %d с", leftDown)
		end

		-- энергия: синяя, при спринте ярче, на исходе — красная
		local energy = (player:GetAttribute("Energy") :: number?) or Config.Player.EnergyMax
		energyFill.Size = UDim2.fromScale(math.clamp(energy / Config.Player.EnergyMax, 0, 1), 1)
		energyFill.BackgroundColor3 = if energy < Config.Player.SprintMinEnergy
			then Color3.fromRGB(230, 90, 70)
			elseif player:GetAttribute("Sprinting") == true then Color3.fromRGB(130, 210, 255)
			else Color3.fromRGB(80, 170, 255)

		scoreLabel.Text = string.format("Очки: %d", (player:GetAttribute("Score") :: number?) or 0)
		local lives = (ReplicatedStorage:GetAttribute("TeamLives") :: number?) or 0
		teamLabel.Text = string.format("Команда: %d", (ReplicatedStorage:GetAttribute("TeamPoints") :: number?) or 0)
			.. (if lives > 0 then string.format("   ♥ жизнь: %d", lives) else "")

		local tool = currentTool()
		if tool then
			if tool:GetAttribute("Melee") == true then
				ammo.Text = tool.Name
			else
				local mag = (tool:GetAttribute("Mag") :: number?) or 0
				local reserve = (tool:GetAttribute("Reserve") :: number?) or 0
				ammo.Text = string.format("%d / %s", mag, if reserve < 0 then "∞" else tostring(reserve))
			end
		else
			ammo.Text = ""
		end
	end)
end

return HUDController
