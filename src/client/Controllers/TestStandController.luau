--!strict
-- Окно выбора ночи для тестового стенда «Выбор волны» (только Studio, сервер: init.server buildTestStands). Кнопки 1…N: нажатие отправляет серверу
-- номер ночи (TestSetWave), сервер сам проверяет тип, диапазон, частоту и дистанцию до стенда.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local TestStandController = {}

function TestStandController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "TestWavePicker"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Modal отпускает курсор в виде от первого лица, пока окно открыто
	local frame = Instance.new("TextButton")
	frame.Name = "Window"
	frame.Text = ""
	frame.AutoButtonColor = false
	frame.Modal = true
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(380, 330)
	frame.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -60, 0, 40)
	title.Position = UDim2.fromOffset(16, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(255, 215, 80)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Night select (test)"
	title.Parent = frame

	local close = Instance.new("TextButton")
	close.Size = UDim2.fromOffset(34, 34)
	close.Position = UDim2.new(1, -44, 0, 9)
	close.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
	close.Font = Enum.Font.GothamBold
	close.TextSize = 18
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Text = "X"
	close.Parent = frame
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = close
	close.Activated:Connect(function()
		gui.Enabled = false
	end)

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -32, 0, 22)
	hint.Position = UDim2.fromOffset(16, 46)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 14
	hint.TextColor3 = Color3.fromRGB(190, 190, 200)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = "The selected night will be next"
	hint.Parent = frame

	local grid = Instance.new("Frame")
	grid.Position = UDim2.fromOffset(16, 76)
	grid.Size = UDim2.new(1, -32, 1, -92)
	grid.BackgroundTransparency = 1
	grid.Parent = frame
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(60, 48)
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	local built = 0
	local function build(maxNight: number)
		if built == maxNight then
			return
		end
		for _, c in grid:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		for n = 1, maxNight do
			local b = Instance.new("TextButton")
			b.LayoutOrder = n
			b.BackgroundColor3 = Color3.fromRGB(46, 78, 128)
			b.Font = Enum.Font.GothamBold
			b.TextSize = 20
			b.TextColor3 = Color3.new(1, 1, 1)
			b.Text = tostring(n)
			b.Parent = grid
			local bc = Instance.new("UICorner")
			bc.CornerRadius = UDim.new(0, 6)
			bc.Parent = b
			b.Activated:Connect(function()
				Remotes.get("TestSetWave"):FireServer(n)
				gui.Enabled = false
			end)
		end
		built = maxNight
	end

	Remotes.get("TestPickWave").OnClientEvent:Connect(function(maxNight: unknown)
		if typeof(maxNight) == "number" and maxNight >= 1 and maxNight <= 60 then
			build(maxNight)
			gui.Enabled = true
		end
	end)
end

return TestStandController
