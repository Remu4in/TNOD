--!strict
-- Катсцены: камера идёт по кадрам с сервера (CutsceneService), снизу реплика, полосы сверху и снизу. Пропуск — Space, кнопка или геймпад B.
-- На время катсцены: управление персонажем выключено, остальной интерфейс и руки от первого лица скрыты. Клавиша K у хоста выключает катсцены всей команде.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local CutsceneController = {}

local BAR = 0.11

function CutsceneController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "Cutscene"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	gui.Enabled = false
	gui.Parent = playerGui

	-- перехватывает клики (стрельба) и отпускает мышь для кнопки
	local shield = Instance.new("TextButton")
	shield.Size = UDim2.fromScale(1, 1)
	shield.BackgroundTransparency = 1
	shield.AutoButtonColor = false
	shield.Text = ""
	shield.Modal = true
	shield.Parent = gui
	local function bar(y: number)
		local f = Instance.new("Frame")
		f.Position = UDim2.fromScale(0, y)
		f.Size = UDim2.fromScale(1, BAR)
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.Parent = gui
	end
	bar(0)
	bar(1 - BAR)
	local speaker = Instance.new("TextLabel")
	speaker.AnchorPoint = Vector2.new(0.5, 1)
	speaker.Position = UDim2.new(0.5, 0, 1 - BAR, 26)
	speaker.Size = UDim2.new(0.8, 0, 0, 24)
	speaker.BackgroundTransparency = 1
	speaker.Font = Enum.Font.GothamBold
	speaker.TextSize = 18
	speaker.TextColor3 = Color3.fromRGB(255, 205, 90)
	speaker.Parent = gui
	local line = Instance.new("TextLabel")
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.Position = UDim2.new(0.5, 0, 1 - BAR, 28)
	line.Size = UDim2.new(0.8, 0, 0, 48)
	line.BackgroundTransparency = 1
	line.Font = Enum.Font.GothamMedium
	line.TextSize = 22
	line.TextWrapped = true
	line.TextColor3 = Color3.new(1, 1, 1)
	line.Parent = gui
	local skip = Instance.new("TextButton")
	skip.AnchorPoint = Vector2.new(1, 0.5)
	skip.Position = UDim2.new(1, -20, BAR / 2, 0)
	skip.Size = UDim2.fromOffset(130, 34)
	skip.BackgroundColor3 = Color3.fromRGB(40, 44, 40)
	skip.BackgroundTransparency = 0.2
	skip.Font = Enum.Font.GothamBold
	skip.TextSize = 15
	skip.TextColor3 = Color3.new(1, 1, 1)
	skip.Text = "Skip ▶ (Space)"
	skip.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = skip

	local playing = false
	local skipped = false
	skip.Activated:Connect(function()
		skipped = true
	end)

	local function play(shots: { any })
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if playing or #shots == 0 or not hum or hum.Health <= 0 then
			return -- мёртвый наблюдает сам (SpectateController)
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		playing = true
		skipped = false
		player:SetAttribute("InCutscene", true)
		-- скрыть интерфейс и руки от первого лица
		local hidden: { ScreenGui } = {}
		for _, g in playerGui:GetChildren() do
			if g:IsA("ScreenGui") and g ~= gui and g.Enabled then
				g.Enabled = false
				table.insert(hidden, g)
			end
		end
		local stashed: { Instance } = {}
		for _, c in cam:GetChildren() do
			if c:IsA("Model") then
				table.insert(stashed, c)
				c.Parent = nil
			end
		end
		-- персонаж стоит: клавиши движения перехватываем
		ContextActionService:BindActionAtPriority("CutsceneFreeze", function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Thumbstick1)
		ContextActionService:BindActionAtPriority("CutsceneSkip", function(_, state)
			if state == Enum.UserInputState.Begin then
				skipped = true
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.Space, Enum.KeyCode.ButtonB)
		gui.Enabled = true
		cam.CameraType = Enum.CameraType.Scriptable

		for _, shot in shots do
			if skipped then
				break
			end
			speaker.Text = shot.speaker or ""
			line.Text = shot.text
			task.spawn(function()
				pcall(function()
					player:RequestStreamAroundAsync(shot.look)
				end)
			end)
			local t0 = os.clock()
			while not skipped do
				local u = (os.clock() - t0) / shot.seconds
				if u >= 1 then
					break
				end
				local e = u * u * (3 - 2 * u)
				cam.CameraType = Enum.CameraType.Scriptable
				cam.CFrame = CFrame.lookAt(shot.from:Lerp(shot.fromEnd, e), shot.look:Lerp(shot.lookEnd, e))
				RunService.RenderStepped:Wait()
			end
		end

		ContextActionService:UnbindAction("CutsceneSkip")
		gui.Enabled = false
		for _, g in hidden do
			g.Enabled = true
		end
		for _, c in stashed do
			c.Parent = cam
		end
		ContextActionService:UnbindAction("CutsceneFreeze")
		cam.CameraType = Enum.CameraType.Custom
		local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if h then
			cam.CameraSubject = h
		end
		player:SetAttribute("InCutscene", nil)
		playing = false
	end

	Remotes.get("Cutscene").OnClientEvent:Connect(function(shots: { any })
		task.spawn(play, shots)
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.K then
			Remotes.get("CutsceneToggle"):FireServer()
		end
	end)
end

return CutsceneController
