--!strict
-- Задача ночи на экране: название и прогресс миссии (атрибуты ReplicatedStorage: MissionTitle, MissionText). Логика — MissionService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	ReplicatedStorage:GetAttributeChangedSignal("MissionTitle"):Connect(refresh)
	ReplicatedStorage:GetAttributeChangedSignal("MissionText"):Connect(refresh)
	refresh()
end

return MissionController
