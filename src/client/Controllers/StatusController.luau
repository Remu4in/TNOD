--!strict
-- Эффекты от атак боссов на экране (атрибуты игрока ставит сервер: PlayerService.stun / slow / noSprint, конец — по серверным часам):
-- оглушение (StunUntil) — затемнение с красным краем и надпись «ОГЛУШЕН»; замедление (SlowUntil) — зелёная строка «Растения опутали ноги»;
-- запрет бега (NoSprintUntil) — фиолетовая строка «Тьма: бег отключён». Скорость и ввод гасит MovementController.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local StatusController = {}

function StatusController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "StatusHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 30
	gui.Parent = player:WaitForChild("PlayerGui")

	-- оглушение: затемнение экрана (не перехватывает ввод)
	local veil = Instance.new("Frame")
	veil.Name = "StunVeil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
	veil.BackgroundTransparency = 0.55
	veil.BorderSizePixel = 0
	veil.Visible = false
	veil.Active = false
	veil.Parent = gui
	local stunText = Instance.new("TextLabel")
	stunText.AnchorPoint = Vector2.new(0.5, 0.5)
	stunText.Position = UDim2.fromScale(0.5, 0.42)
	stunText.Size = UDim2.fromOffset(360, 56)
	stunText.BackgroundTransparency = 1
	stunText.Font = Enum.Font.GothamBlack
	stunText.TextSize = 40
	stunText.TextColor3 = Color3.fromRGB(255, 190, 120)
	stunText.TextStrokeTransparency = 0.4
	stunText.Text = "ОГЛУШЕН"
	stunText.Parent = veil

	local function bar(order: number, color: Color3, text: string): TextLabel
		local l = Instance.new("TextLabel")
		l.AnchorPoint = Vector2.new(0.5, 1)
		l.Position = UDim2.new(0.5, 0, 1, -150 - order * 26)
		l.Size = UDim2.fromOffset(340, 22)
		l.BackgroundTransparency = 0.45
		l.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
		l.Font = Enum.Font.GothamBold
		l.TextSize = 14
		l.TextColor3 = color
		l.Text = text
		l.Visible = false
		l.Parent = gui
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = l
		return l
	end
	local slowBar = bar(0, Color3.fromRGB(150, 235, 120), "Растения опутали ноги: движение замедлено")
	local darkBar = bar(1, Color3.fromRGB(190, 150, 255), "Тьма: бег, подкат и кувырок отключены")

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		local now = workspace:GetServerTimeNow()
		veil.Visible = now < ((player:GetAttribute("StunUntil") :: number?) or 0)
		slowBar.Visible = now < ((player:GetAttribute("SlowUntil") :: number?) or 0)
		darkBar.Visible = now < ((player:GetAttribute("NoSprintUntil") :: number?) or 0)
	end)
end

return StatusController
