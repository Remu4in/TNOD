--!strict
-- Мини-карта справа сверху: север вверху, игрок в центре (стрелка — куда смотрит камера). План дорог и зданий приходит от сервера одним сообщением
-- (MinimapData, SquadService): клиенту включён стриминг, дальних деталей у него нет. На карте: тиммейты, цели миссии (тег MissionZone), метки игроков.
-- Цели и метки за краем карты прижимаются к краю. Под землёй (метро) карта скрыта.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local MinimapController = {}

local ROAD_COLOR = Color3.fromRGB(125, 127, 135)
local BUILDING_COLOR = Color3.fromRGB(58, 62, 52)
local TEAM_COLOR = Color3.fromRGB(120, 220, 255)
local GOAL_COLOR = Color3.fromRGB(255, 215, 80)
local PING_COLOR = Color3.fromRGB(255, 150, 50)

function MinimapController.start()
	local player = Players.LocalPlayer
	local S = Config.Squad
	local scale = S.MapSize / (S.MapRadius * 2)

	local gui = Instance.new("ScreenGui")
	gui.Name = "Minimap"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 3
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -14, 0, 72)
	panel.Size = UDim2.fromOffset(S.MapSize, S.MapSize)
	panel.BackgroundColor3 = Color3.fromRGB(22, 25, 30)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 125, 110)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = panel

	-- мир: нулевой размер, детали — в студах × scale; двигаем только его
	local world = Instance.new("Frame")
	world.Name = "World"
	world.Size = UDim2.fromOffset(0, 0)
	world.BackgroundTransparency = 1
	world.Parent = panel

	local function rect(x: number, z: number, w: number, d: number, color: Color3, order: number)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromOffset(x * scale, z * scale)
		f.Size = UDim2.fromOffset(math.max(1, w * scale), math.max(1, d * scale))
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		f.ZIndex = order
		f.Parent = world
	end
	Remotes.get("MinimapData").OnClientEvent:Connect(function(data: { number })
		for i = 1, #data, 5 do
			local kind = data[i + 4]
			rect(data[i], data[i + 1], data[i + 2], data[i + 3], if kind == 1 then ROAD_COLOR else BUILDING_COLOR, kind)
		end
	end)
	Remotes.get("MinimapData"):FireServer()

	local function makeDot(color: Color3, size: number): Frame
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(size, size)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		dot.ZIndex = 5
		dot.Visible = false
		dot.Parent = panel
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dot
		return dot
	end

	local arrow = Instance.new("TextLabel")
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromScale(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(22, 22)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.GothamBold
	arrow.TextSize = 20
	arrow.TextColor3 = Color3.fromRGB(120, 255, 130)
	arrow.TextStrokeTransparency = 0.3
	arrow.Text = "▲"
	arrow.ZIndex = 6
	arrow.Parent = panel

	local teamDots: { [Player]: Frame } = {}
	Players.PlayerRemoving:Connect(function(p: Player)
		local d = teamDots[p]
		if d then
			d:Destroy()
			teamDots[p] = nil
		end
	end)
	local goalDots: { [Instance]: Frame } = {}
	local pings: { { dot: Frame, pos: Vector3, untilAt: number } } = {}
	Remotes.get("Ping").OnClientEvent:Connect(function(_from: Player, pos: Vector3)
		table.insert(pings, { dot = makeDot(PING_COLOR, 9), pos = pos, untilAt = os.clock() + S.PingSeconds })
	end)

	-- Точка на карте; clamp — прижать к краю, если за пределами
	local half = S.MapSize / 2
	local function place(dot: Frame, pos: Vector3, center: Vector3, clamp: boolean)
		local dx, dz = (pos.X - center.X) * scale, (pos.Z - center.Z) * scale
		local inside = math.abs(dx) <= half and math.abs(dz) <= half
		if not inside and clamp then
			local k = (half - 4) / math.max(math.abs(dx), math.abs(dz))
			dx, dz = dx * k, dz * k
			inside = true
		end
		dot.Visible = inside
		if inside then
			dot.Position = UDim2.fromOffset(half + dx, half + dz)
		end
	end

	RunService.Heartbeat:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		-- живой — по персонажу, наблюдатель — по камере
		local center = if root and hum and hum.Health > 0 then root.Position else cam.CFrame.Position
		panel.Visible = center.Y > Config.Metro.InsideMaxY
		if not panel.Visible then
			return
		end
		world.Position = UDim2.fromOffset(half - center.X * scale, half - center.Z * scale)
		local look = cam.CFrame.LookVector
		arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))

		for _, p in Players:GetPlayers() do
			if p ~= player then
				local dot = teamDots[p]
				if not dot then
					dot = makeDot(TEAM_COLOR, 8)
					teamDots[p] = dot
				end
				local attr = p:GetAttribute("SquadPos")
				if typeof(attr) == "Vector3" then
					dot.BackgroundColor3 = if p:GetAttribute("Downed") == true then Color3.fromRGB(255, 80, 70) else TEAM_COLOR
					place(dot, attr, center, true)
				else
					dot.Visible = false
				end
			end
		end
		local seen: { [Instance]: boolean } = {}
		for _, part in CollectionService:GetTagged("MissionZone") do
			if part:IsA("BasePart") then
				seen[part] = true
				local dot = goalDots[part]
				if not dot then
					dot = makeDot(GOAL_COLOR, 8)
					goalDots[part] = dot
				end
				place(dot, part.Position, center, true)
			end
		end
		for part, dot in goalDots do
			if not seen[part] then
				dot:Destroy()
				goalDots[part] = nil
			end
		end
		local now = os.clock()
		for i = #pings, 1, -1 do
			local ping = pings[i]
			if now >= ping.untilAt then
				ping.dot:Destroy()
				table.remove(pings, i)
			else
				place(ping.dot, ping.pos, center, true)
			end
		end
	end)
end

return MinimapController
