--!strict
-- Данные для иконок тиммейтов и меток. Клиенту включён стриминг: дальние персонажи у него не загружены,
-- поэтому позиции игроков сервер публикует атрибутом SquadPos (пока игрок жив). Лимит активных меток считает сервер.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Validate = require(Shared:WaitForChild("Validate"))

local SquadService = {}

-- когда истекают активные метки каждого игрока
local activePings: { [Player]: { number } } = {}

function SquadService.init()
	Remotes.get("Ping").OnServerEvent:Connect(function(player: Player, position: unknown)
		if typeof(position) ~= "Vector3" or not Validate.finiteVector(position, 1e5) then
			return
		end
		if not RateLimit.allow(player, "Ping", Config.Squad.PingInterval) then
			return
		end
		local now = os.clock()
		local active = activePings[player] or {}
		activePings[player] = active
		for i = #active, 1, -1 do
			if active[i] <= now then
				table.remove(active, i)
			end
		end
		if #active >= Config.Squad.MaxActivePings then
			return
		end
		table.insert(active, now + Config.Squad.PingSeconds)
		Remotes.get("Ping"):FireAllClients(player, position)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		activePings[player] = nil
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
