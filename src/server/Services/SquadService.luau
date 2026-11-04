--!strict
-- Данные для иконок тиммейтов, меток и мини-карты. Клиенту включён стриминг: дальние персонажи и дороги у него не загружены,
-- поэтому позиции игроков сервер публикует атрибутом SquadPos (пока игрок жив), а план карты отдаёт одним сообщением MinimapData.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Validate = require(Shared:WaitForChild("Validate"))

local SquadService = {}

local ROAD, BUILDING = 1, 2
local mapData: { number }? = nil
local sentMap: { [Player]: boolean } = {}

-- Габарит детали на плоскости с учётом поворота: половины по X, Y, Z
local function halfExtents(cf: CFrame, size: Vector3): Vector3
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local s = size / 2
	return Vector3.new(
		math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
		math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
		math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z
	)
end

-- План карты плоским списком: x, z, ширина, глубина, вид (дорога или здание); строится один раз
local function buildMap(): { number }
	local list: { number } = {}
	local function add(pos: Vector3, half: Vector3, kind: number)
		table.insert(list, math.floor(pos.X + 0.5))
		table.insert(list, math.floor(pos.Z + 0.5))
		table.insert(list, math.ceil(half.X * 2))
		table.insert(list, math.ceil(half.Z * 2))
		table.insert(list, kind)
	end
	local roads = workspace:FindFirstChild("Roads")
	if roads then
		for _, d in roads:GetDescendants() do
			if d:IsA("BasePart") then
				local half = halfExtents(d.CFrame, d.Size)
				-- плоское и низкое — дорога; машины, деревья и прочий декор в папке Roads не рисуем
				if half.X * half.Z * 4 >= 100 and half.Y <= 4 and math.abs(d.Position.Y) <= 6 then
					add(d.Position, half, ROAD)
				end
			end
		end
	end
	for _, name in { "Buildings", "Base" } do
		local folder = workspace:FindFirstChild(name)
		if folder then
			for _, m in folder:GetChildren() do
				if m:IsA("Model") then
					local cf, size = m:GetBoundingBox()
					local half = halfExtents(cf, size)
					local area = half.X * half.Z * 4
					if area >= 150 and area <= 40000 and half.Y >= 4 then
						add(cf.Position, half, BUILDING)
					end
				end
			end
		end
	end
	return list
end

function SquadService.init()
	Remotes.get("Ping").OnServerEvent:Connect(function(player: Player, position: unknown)
		if typeof(position) ~= "Vector3" or not Validate.finiteVector(position, 1e5) then
			return
		end
		if not RateLimit.allow(player, "Ping", Config.Squad.PingInterval) then
			return
		end
		Remotes.get("Ping"):FireAllClients(player, position)
	end)
	Remotes.get("MinimapData").OnServerEvent:Connect(function(player: Player)
		if sentMap[player] then
			return -- план отдаём один раз
		end
		sentMap[player] = true
		if not mapData then
			mapData = buildMap()
		end
		Remotes.get("MinimapData"):FireClient(player, mapData)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		sentMap[player] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < Config.Squad.PosInterval then
			return
		end
		acc = 0
		for _, p in Players:GetPlayers() do
			local char = p.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			p:SetAttribute("SquadPos", if hum and root and hum.Health > 0 then root.Position else nil)
		end
	end)
end

return SquadService
