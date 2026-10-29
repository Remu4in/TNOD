--!strict
-- Оповещение днём о ближайшей ночи: в начале дня панель на 9 с (название, задача, где, особенности) + строки в чате (системное сообщение),
-- за 30 с до ночи — короткое напоминание. Тексты и данные присылает сервер атрибутами ReplicatedStorage NextBrief* (GeneralService.publishBrief),
-- тексты — Config.DayBrief. Окно генерала по E (BriefingController) остаётся как есть.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DayBriefController = {}

-- Сторона света от игрока к точке: север — к −Z (восток — к +X)
local DIRECTIONS = { "north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest" }

local function whereText(target: Vector3?, from: Vector3?): string
	if not target then
		return Config.DayBrief.Here
	end
	if not from then
		return "will be marked on the map later"
	end
	local dx, dz = target.X - from.X, target.Z - from.Z
	local dist = math.floor(math.sqrt(dx * dx + dz * dz) / 5 + 0.5) * 5 -- с округлением до 5 студов («м» на метках)
	local angle = math.deg(math.atan2(dx, -dz)) % 360
	local name = DIRECTIONS[math.floor((angle + 22.5) / 45) % 8 + 1]
	return string.format("%d m to the %s", dist, name)
end

function DayBriefController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "DayBriefHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("CanvasGroup")
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 120)
	panel.Size = UDim2.fromOffset(480, 20)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(22, 26, 20)
	panel.BackgroundTransparency = 0.12
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(190, 160, 70)
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
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
		l.RichText = true
		l.LayoutOrder = order
		l.Parent = panel
		return l
	end
	local header = label(14, Enum.Font.GothamMedium, Color3.fromRGB(200, 180, 110), 1)
	local title = label(19, Enum.Font.GothamBold, Color3.fromRGB(255, 215, 80), 2)
	local taskLabel = label(15, Enum.Font.Gotham, Color3.fromRGB(235, 235, 235), 3)
	local whereLabel = label(15, Enum.Font.GothamMedium, Color3.fromRGB(150, 210, 255), 4)
	local tipLabel = label(14, Enum.Font.Gotham, Color3.fromRGB(215, 200, 170), 5)

	local shown = 0 -- номер последнего показа: отложенное скрытие прошлого показа не гасит новый
	local visibleUntil = 0

	local function playerPos(): Vector3?
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		return if root then root.Position else nil
	end

	local function chat(lines: { string })
		local ok = pcall(function()
			local channels = TextChatService:FindFirstChild("TextChannels")
			local sys = channels and channels:FindFirstChild("RBXSystem") :: TextChannel?
			if sys then
				for _, line in lines do
					sys:DisplaySystemMessage(line)
				end
			end
		end)
		if not ok then
			warn("[DayBriefController] chat unavailable")
		end
	end

	local function read(): (number, string, string, string, Vector3?)
		local night = (ReplicatedStorage:GetAttribute("NextBriefNight") :: number?) or 1
		local ttl = (ReplicatedStorage:GetAttribute("NextBriefTitle") :: string?) or ""
		local taskText = (ReplicatedStorage:GetAttribute("NextBriefTask") :: string?) or ""
		local tip = (ReplicatedStorage:GetAttribute("NextBriefTip") :: string?) or ""
		local pos = ReplicatedStorage:GetAttribute("NextBriefPos")
		return night, ttl, taskText, tip, if typeof(pos) == "Vector3" then pos else nil
	end

	local function show(full: boolean)
		local night, ttl, taskText, tip, pos = read()
		if ttl == "" then
			return
		end
		shown += 1
		local mine = shown
		header.Text = if full then "GENERAL NURSULTAN: TONIGHT'S ORDERS" else "GENERAL NURSULTAN: NIGHT IS COMING"
		title.Text = string.format("Night %d — %s", night, ttl)
		taskLabel.Text = "Objective: " .. taskText
		whereLabel.Text = "Where: " .. whereText(pos, playerPos())
		tipLabel.Text = tip
		panel.Visible = true
		TweenService:Create(panel, TweenInfo.new(0.4), { GroupTransparency = 0 }):Play()
		local seconds = if full then Config.DayBrief.ShowSeconds else Config.DayBrief.RemindSeconds
		visibleUntil = os.clock() + seconds
		-- «где» обновляется, пока панель на экране
		local conn: RBXScriptConnection
		conn = RunService.Heartbeat:Connect(function()
			if shown ~= mine or os.clock() > visibleUntil then
				conn:Disconnect()
				return
			end
			whereLabel.Text = "Where: " .. whereText(pos, playerPos())
		end)
		local lines = {
			string.format("[General Nursultan] Night %d — %s", night, ttl),
			"Objective: " .. taskText,
			"Where: " .. whereText(pos, playerPos()),
			tip,
		}
		if not full then
			lines = { string.format("[General Nursultan] %d seconds until night. Night %d — %s. Where: %s.", Config.DayBrief.RemindBefore, night, ttl, whereText(pos, playerPos())) }
		end
		chat(lines)
		-- скрытие
		local ref = os.clock() + seconds
		while os.clock() < ref do
			if shown ~= mine then
				return
			end
			RunService.Heartbeat:Wait()
		end
		if shown == mine then
			local tween = TweenService:Create(panel, TweenInfo.new(0.6), { GroupTransparency = 1 })
			tween:Play()
			tween.Completed:Once(function()
				if shown == mine then
					panel.Visible = false
				end
			end)
		end
	end

	local reminded = false
	local lastPhase = ""
	local function onPhase()
		local phase = (ReplicatedStorage:GetAttribute("Phase") :: string?) or ""
		if phase == lastPhase then
			return
		end
		lastPhase = phase
		if phase == "Day" then
			reminded = false
			task.delay(0.8, function() -- сервер публикует NextBrief* сразу после смены фазы
				if lastPhase == "Day" then
					show(true)
				end
			end)
		else
			shown += 1 -- ночью панель убираем
			panel.Visible = false
			panel.GroupTransparency = 1
		end
	end
	ReplicatedStorage:GetAttributeChangedSignal("Phase"):Connect(onPhase)
	onPhase()

	-- напоминание за RemindBefore секунд до ночи
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 1 then
			return
		end
		acc = 0
		if lastPhase ~= "Day" or reminded then
			return
		end
		local endsAt = (ReplicatedStorage:GetAttribute("PhaseEndsAt") :: number?) or 0
		if endsAt > 0 then
			local left = endsAt - workspace:GetServerTimeNow()
			if left <= Config.DayBrief.RemindBefore and left > 0 then
				reminded = true
				task.spawn(show, false)
			end
		end
	end)
end

return DayBriefController
