--!strict
-- Интерфейс, собранный кодом: фаза/таймер/волна, HP, монеты, патроны, уведомления, экран падения.
-- Все данные — из атрибутов (их меняет только сервер).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
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

	-- прицел по центру экрана
	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(6, 6)
	crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
	crosshair.BackgroundTransparency = 0.2
	crosshair.BorderSizePixel = 0
	crosshair.Parent = gui
	local crossCorner = Instance.new("UICorner")
	crossCorner.CornerRadius = UDim.new(1, 0)
	crossCorner.Parent = crosshair
	local crossStroke = Instance.new("UIStroke")
	crossStroke.Color = Color3.new(0, 0, 0)
	crossStroke.Transparency = 0.4
	crossStroke.Parent = crosshair

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
		Text = "Вы упали! Ждите, пока товарищ поднимет вас",
		TextColor3 = Color3.fromRGB(255, 90, 90),
		Visible = false,
	})

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
		downed.Visible = player:GetAttribute("Downed") == true

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
