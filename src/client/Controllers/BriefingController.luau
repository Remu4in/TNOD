--!strict
-- Окно задания от генерала: имя, заголовок ночи и текст. Закрывается кнопкой, E или Esc. Содержимое присылает сервер (GeneralService).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local BriefingController = {}

function BriefingController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "BriefingHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 25
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(640, 20)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(24, 28, 22)
	panel.BackgroundTransparency = 0.08
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(190, 160, 70)
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 16)
	pad.PaddingBottom = UDim.new(0, 16)
	pad.PaddingLeft = UDim.new(0, 20)
	pad.PaddingRight = UDim.new(0, 20)
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local function label(size: number, font: Enum.Font, color: Color3, order: number): TextLabel
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, 0, 0, size + 4)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundTransparency = 1
		l.Font = font
		l.TextSize = size
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.TextWrapped = true
		l.LayoutOrder = order
		l.Parent = panel
		return l
	end
	local speaker = label(16, Enum.Font.GothamMedium, Color3.fromRGB(200, 180, 110), 1)
	local title = label(26, Enum.Font.GothamBold, Color3.fromRGB(255, 220, 100), 2)
	local body = label(19, Enum.Font.Gotham, Color3.fromRGB(235, 235, 230), 3)
	local close = Instance.new("TextButton")
	close.LayoutOrder = 4
	close.Size = UDim2.fromOffset(200, 40)
	close.BackgroundColor3 = Color3.fromRGB(70, 90, 50)
	close.Font = Enum.Font.GothamBold
	close.TextSize = 20
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Text = "Есть, генерал! (E)"
	close.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 8)
	cc.Parent = close

	local function hide()
		gui.Enabled = false
		ContextActionService:UnbindAction("NotdBriefingClose")
	end
	close.Activated:Connect(hide)

	Remotes.get("Briefing").OnClientEvent:Connect(function(name: string, header: string, lines: { string })
		speaker.Text = name
		title.Text = header
		body.Text = table.concat(lines, "\n\n")
		gui.Enabled = true
		ContextActionService:BindActionAtPriority("NotdBriefingClose", function(_, state)
			if state == Enum.UserInputState.Begin then
				hide()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.E, Enum.KeyCode.Escape)
	end)
end

return BriefingController
