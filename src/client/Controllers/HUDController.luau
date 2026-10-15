--!strict
-- Интерфейс, собранный кодом: фаза/таймер/волна, HP, монеты, патроны, уведомления, экран падения.
-- Все данные — из атрибутов (их меняет только сервер).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

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

		local tool = currentTool()
		if tool then
			local mag = (tool:GetAttribute("Mag") :: number?) or 0
			local reserve = (tool:GetAttribute("Reserve") :: number?) or 0
			ammo.Text = string.format("%d / %s", mag, if reserve < 0 then "∞" else tostring(reserve))
		else
			ammo.Text = ""
		end
	end)
end

return HUDController
