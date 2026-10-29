--!strict
-- Полоска здоровья босса сверху экрана (босс-файт): имя и сколько осталось. Данные — атрибуты ReplicatedStorage BossName, BossHp, BossMaxHp
-- (сервер: ZombieService.refreshBossBar); нет босса — полоска скрыта.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BossBarController = {}

function BossBarController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "BossBar"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 7
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 96)
	frame.Size = UDim2.fromOffset(460, 44)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 20)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextColor3 = Color3.fromRGB(255, 225, 200)
	title.TextStrokeTransparency = 0.4
	title.Parent = frame

	local back = Instance.new("Frame")
	back.Position = UDim2.fromOffset(0, 22)
	back.Size = UDim2.new(1, 0, 0, 18)
	back.BackgroundColor3 = Color3.fromRGB(20, 12, 12)
	back.BackgroundTransparency = 0.15
	back.BorderSizePixel = 0
	back.Parent = frame
	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 6)
	backCorner.Parent = back
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 30, 30)
	stroke.Thickness = 2
	stroke.Parent = back

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(205, 40, 40)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	local amount = Instance.new("TextLabel")
	amount.Size = UDim2.fromScale(1, 1)
	amount.BackgroundTransparency = 1
	amount.Font = Enum.Font.GothamBold
	amount.TextSize = 13
	amount.TextColor3 = Color3.new(1, 1, 1)
	amount.TextStrokeTransparency = 0.5
	amount.Parent = back

	-- вторая фаза финального босса: подсказка под полоской
	local hint = Instance.new("TextLabel")
	hint.Position = UDim2.fromOffset(0, 42)
	hint.Size = UDim2.new(1, 0, 0, 18)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextSize = 14
	hint.TextColor3 = Color3.fromRGB(190, 150, 255)
	hint.TextStrokeTransparency = 0.4
	hint.Text = "Immune to firearms — use melee weapons"
	hint.Visible = false
	hint.Parent = frame

	local function refresh()
		hint.Visible = ReplicatedStorage:GetAttribute("BossImmune") == true
		local maxHp = ReplicatedStorage:GetAttribute("BossMaxHp")
		local hp = ReplicatedStorage:GetAttribute("BossHp")
		if typeof(maxHp) ~= "number" or typeof(hp) ~= "number" or maxHp <= 0 then
			frame.Visible = false
			return
		end
		frame.Visible = true
		local name = ReplicatedStorage:GetAttribute("BossName")
		title.Text = if typeof(name) == "string" then string.upper(name) else "BOSS"
		local k = math.clamp(hp / maxHp, 0, 1)
		TweenService:Create(fill, TweenInfo.new(0.15), { Size = UDim2.fromScale(k, 1) }):Play()
		amount.Text = string.format("%d / %d", math.ceil(hp), math.floor(maxHp))
	end
	for _, n in { "BossName", "BossHp", "BossMaxHp", "BossImmune" } do
		ReplicatedStorage:GetAttributeChangedSignal(n):Connect(refresh)
	end
	refresh()
end

return BossBarController
