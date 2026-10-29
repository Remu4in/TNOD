--!strict
-- Задача ночи на экране: название и прогресс миссии (атрибуты ReplicatedStorage: MissionTitle, MissionText). Логика — MissionService.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MissionController = {}

function MissionController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "MissionHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Position = UDim2.new(0, 12, 0, 96)
	frame.Size = UDim2.fromOffset(320, 20)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	frame.BackgroundTransparency = 0.35
	frame.Visible = false
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	local function label(size: number, font: Enum.Font, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, 0, 0, size + 4)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundTransparency = 1
		l.Font = font
		l.TextSize = size
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = true
		l.Parent = frame
		return l
	end
	local title = label(18, Enum.Font.GothamBold, Color3.fromRGB(255, 215, 80))
	local text = label(15, Enum.Font.Gotham, Color3.fromRGB(230, 230, 230))

	local function refresh()
		local t = (ReplicatedStorage:GetAttribute("MissionTitle") :: string?) or ""
		local x = (ReplicatedStorage:GetAttribute("MissionText") :: string?) or ""
		frame.Visible = t ~= ""
		title.Text = "ЗАДАЧА: " .. t
		text.Text = x
		text.Visible = x ~= ""
	end
	-- метки на земле (тег MissionZone, MissionService.makeBeacon): в подпись добавляем расстояние до игрока
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.3 then
			return
		end
		acc = 0
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return
		end
		for _, part in CollectionService:GetTagged("MissionZone") do
			local gui = part:FindFirstChildOfClass("BillboardGui")
			local lab = gui and gui:FindFirstChild("Label") :: TextLabel?
			local base = part:GetAttribute("BaseText")
			if lab and typeof(base) == "string" and part:IsA("BasePart") then
				local d = Vector3.new(part.Position.X - root.Position.X, 0, part.Position.Z - root.Position.Z).Magnitude
				lab.Text = string.format("%s · %d м", base, math.floor(d + 0.5))
			end
		end
	end)
	ReplicatedStorage:GetAttributeChangedSignal("MissionTitle"):Connect(refresh)
	ReplicatedStorage:GetAttributeChangedSignal("MissionText"):Connect(refresh)
	refresh()
end

return MissionController
