--!strict
-- Иконки тиммейтов сквозь стены (почти прозрачные, постоянные) и метки на колёсико мыши (нажатие правого стика на геймпаде).
-- Всё рисуется в ScreenGui по позиции на экране: персонажи и детали вдали могут быть не загружены стримингом (позиции — атрибут SquadPos от SquadService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local SquadController = {}

local TEAM_COLOR = Color3.fromRGB(120, 220, 255)
local DOWN_COLOR = Color3.fromRGB(255, 80, 70)
local PING_COLOR = Color3.fromRGB(255, 190, 60)

type Icon = { frame: Frame, dot: Frame, name: TextLabel }
type Ping = { frame: Frame, dist: TextLabel, pos: Vector3, untilAt: number }

function SquadController.start()
	local player = Players.LocalPlayer
	local S = Config.Squad
	local gui = Instance.new("ScreenGui")
	gui.Name = "SquadHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- координаты экрана совпадают с WorldToViewportPoint
	gui.DisplayOrder = 2
	gui.Parent = player:WaitForChild("PlayerGui")

	local icons: { [Player]: Icon } = {}
	local pings: { Ping } = {}

	local function makeIcon(p: Player): Icon
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Size = UDim2.fromOffset(120, S.IconSize + 16)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = gui
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0)
		dot.Position = UDim2.fromScale(0.5, 0)
		dot.Size = UDim2.fromOffset(S.IconSize, S.IconSize)
		dot.BackgroundColor3 = TEAM_COLOR
		dot.BackgroundTransparency = S.IconTransparency
		dot.BorderSizePixel = 0
		dot.Parent = frame
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dot
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Transparency = S.IconTransparency
		stroke.Thickness = 1
		stroke.Parent = dot
		local name = Instance.new("TextLabel")
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.fromScale(0.5, 1)
		name.Size = UDim2.new(1, 0, 0, 14)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBold
		name.TextSize = 12
		name.TextColor3 = Color3.new(1, 1, 1)
		name.TextTransparency = S.IconTransparency - 0.2
		name.Text = p.DisplayName
		name.Parent = frame
		return { frame = frame, dot = dot, name = name }
	end

	Players.PlayerRemoving:Connect(function(p: Player)
		local icon = icons[p]
		if icon then
			icon.frame:Destroy()
			icons[p] = nil
		end
	end)

	-- Метка: поставить (луч из центра камеры), сервер рассылает всем
	local function sendPing()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local at = UserInputService:GetMouseLocation()
		local ray = cam:ViewportPointToRay(at.X, at.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = if player.Character then { player.Character } else {}
		local hit = workspace:Raycast(ray.Origin, ray.Direction * S.PingRange, params)
		if hit then
			Remotes.get("Ping"):FireServer(hit.Position)
		end
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton3 or input.KeyCode == Enum.KeyCode.ButtonR3 then
			sendPing()
		end
	end)

	Remotes.get("Ping").OnClientEvent:Connect(function(from: Player, pos: Vector3)
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 1)
		frame.Size = UDim2.fromOffset(120, 52)
		frame.BackgroundTransparency = 1
		frame.Parent = gui
		local mark = Instance.new("TextLabel")
		mark.Size = UDim2.new(1, 0, 0, 24)
		mark.BackgroundTransparency = 1
		mark.Font = Enum.Font.GothamBold
		mark.TextSize = 24
		mark.TextColor3 = PING_COLOR
		mark.TextStrokeTransparency = 0.4
		mark.Text = "◆"
		mark.Parent = frame
		local who = Instance.new("TextLabel")
		who.Position = UDim2.fromOffset(0, 24)
		who.Size = UDim2.new(1, 0, 0, 14)
		who.BackgroundTransparency = 1
		who.Font = Enum.Font.GothamBold
		who.TextSize = 12
		who.TextColor3 = PING_COLOR
		who.TextStrokeTransparency = 0.5
		who.Text = from.DisplayName
		who.Parent = frame
		local dist = Instance.new("TextLabel")
		dist.Position = UDim2.fromOffset(0, 38)
		dist.Size = UDim2.new(1, 0, 0, 14)
		dist.BackgroundTransparency = 1
		dist.Font = Enum.Font.Gotham
		dist.TextSize = 12
		dist.TextColor3 = Color3.new(1, 1, 1)
		dist.TextStrokeTransparency = 0.5
		dist.Parent = frame
		table.insert(pings, { frame = frame, dist = dist, pos = pos, untilAt = os.clock() + S.PingSeconds })
		local s = Instance.new("Sound")
		s.SoundId = Config.Sounds.click
		s.Volume = 0.5
		s.PlaybackSpeed = 1.6
		s.Parent = SoundService
		s:Play()
		s.Ended:Once(function()
			s:Destroy()
		end)
	end)

	RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local camPos = cam.CFrame.Position
		for _, p in Players:GetPlayers() do
			if p ~= player then
				local icon = icons[p]
				if not icon then
					icon = makeIcon(p)
					icons[p] = icon
				end
				local char = p.Character
				local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				local attr = p:GetAttribute("SquadPos")
				-- живой тиммейт: точная позиция, если персонаж загружен, иначе позиция от сервера
				local pos: Vector3? = if typeof(attr) == "Vector3" then (if root then root.Position else attr) else nil
				local visible = false
				if pos then
					local screen, onScreen = cam:WorldToViewportPoint(pos + Vector3.new(0, 3.5, 0))
					if onScreen and (pos - camPos).Magnitude > 8 then
						visible = true
						icon.frame.Position = UDim2.fromOffset(screen.X, screen.Y)
						local color = if p:GetAttribute("Downed") == true then DOWN_COLOR else TEAM_COLOR
						icon.dot.BackgroundColor3 = color
					end
				end
				icon.frame.Visible = visible
			end
		end
		local now = os.clock()
		for i = #pings, 1, -1 do
			local ping = pings[i]
			if now >= ping.untilAt then
				ping.frame:Destroy()
				table.remove(pings, i)
			else
				local screen, onScreen = cam:WorldToViewportPoint(ping.pos)
				ping.frame.Visible = onScreen
				if onScreen then
					ping.frame.Position = UDim2.fromOffset(screen.X, screen.Y)
					ping.dist.Text = string.format("%d m", math.floor((ping.pos - camPos).Magnitude + 0.5))
				end
			end
		end
	end)
end

return SquadController
