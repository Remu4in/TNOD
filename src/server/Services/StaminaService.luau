--!strict
-- Энергия и спринт. Клиент лишь просит «хочу спринтовать» (Remotes.Sprint); энергию, скорость и
-- ограничения считает сервер. Атрибуты игрока для HUD: Energy (0..EnergyMax), Sprinting (bool).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local StaminaService = {}

local TICK = 0.1
local P = Config.Player
local DRAIN_PER_SEC = P.EnergyMax / P.SprintSeconds
local REGEN_PER_SEC = P.EnergyMax / P.EnergyRegenSeconds

local energy: { [Player]: number } = {}
local wanted: { [Player]: boolean } = {}
local sprinting: { [Player]: boolean } = {}
local lastSprintAt: { [Player]: number } = {}
local lastDodgeAt: { [Player]: number } = {}

local function publish(player: Player)
	-- в атрибут пишем целое: меньше сетевого шума, для полоски HUD точности хватает
	local value = math.floor((energy[player] or 0) + 0.5)
	if player:GetAttribute("Energy") ~= value then
		player:SetAttribute("Energy", value)
	end
end

-- Энергетик: бесконечная энергия до конца ночи, которая наступит следующей (если выпит ночью — до конца этой)
local infinite: { [Player]: { target: number, seenNight: boolean } } = {}

function StaminaService.grantInfinite(player: Player, waves: number)
	local current = (ReplicatedStorage:GetAttribute("Wave") :: number?) or 0
	local nightNow = ReplicatedStorage:GetAttribute("Phase") == "Night"
	infinite[player] = { target = (if nightNow then current else current + 1) + (waves - 1), seenNight = nightNow }
end

local function isInfinite(player: Player): boolean
	local state = infinite[player]
	if not state then
		return false
	end
	local current = (ReplicatedStorage:GetAttribute("Wave") :: number?) or 0
	local night = ReplicatedStorage:GetAttribute("Phase") == "Night"
	if current == state.target and night then
		state.seenNight = true
	elseif current > state.target or (current == state.target and state.seenNight) then
		infinite[player] = nil
		return false
	end
	return true
end

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function setSprinting(player: Player, on: boolean)
	sprinting[player] = on
	player:SetAttribute("Sprinting", on)
	local h = humanoidOf(player)
	-- упавшим скорость задаёт PlayerService
	if h and not player:GetAttribute("Downed") then
		h.WalkSpeed = if on then P.SprintSpeed else P.WalkSpeed
	end
end

-- Полная энергия (возрождение, энергетик)
function StaminaService.refill(player: Player)
	energy[player] = P.EnergyMax
	publish(player)
end

-- Добавить энергию (энергетик за донат, награда): не больше максимума
function StaminaService.addEnergy(player: Player, amount: number)
	energy[player] = math.clamp((energy[player] or 0) + amount, 0, P.EnergyMax)
	publish(player)
end

local function track(player: Player)
	energy[player] = P.EnergyMax
	wanted[player] = false
	sprinting[player] = false
	lastSprintAt[player] = 0
	player:SetAttribute("Sprinting", false)
	publish(player)
	-- возрождённый начинает с полной энергией и без спринта
	player.CharacterAdded:Connect(function()
		wanted[player] = false
		sprinting[player] = false
		player:SetAttribute("Sprinting", false)
		StaminaService.refill(player)
	end)
end

function StaminaService.init()
	for _, p in Players:GetPlayers() do
		track(p)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player)
		energy[player] = nil
		infinite[player] = nil
		wanted[player] = nil
		sprinting[player] = nil
		lastSprintAt[player] = nil
		lastDodgeAt[player] = nil
	end)

	Remotes.get("Sprint").OnServerEvent:Connect(function(player: Player, on: unknown)
		if typeof(on) ~= "boolean" or not RateLimit.allow(player, "Sprint", 0.05) then
			return
		end
		-- начать можно только с достаточным запасом; остановить — всегда
		wanted[player] = on and (energy[player] or 0) >= P.SprintMinEnergy and PlayerService.isUp(player)
	end)

	-- подкат (только в спринте) и кувырок: сервер проверяет энергию и паузу, у кувырка даёт короткую неуязвимость.
	-- Само движение клиент делает у себя (как и обычную ходьбу).
	Remotes.get("Dodge").OnServerEvent:Connect(function(player: Player, kind: unknown)
		if (kind ~= "slide" and kind ~= "roll") or not RateLimit.allow(player, "Dodge", 0.1) then
			return
		end
		if not PlayerService.isUp(player) or energy[player] == nil then
			return
		end
		local now = os.clock()
		if now - (lastDodgeAt[player] or 0) < P.DodgeCooldown then
			return
		end
		-- подкат — из бега (допуск 0,5 с: сервер гасит спринт с задержкой, а игрок мог отпустить Shift в момент нажатия)
		if kind == "slide" and not sprinting[player] and now - (lastSprintAt[player] or 0) > 0.5 then
			return
		end
		local cost = if kind == "slide" then P.SlideEnergy else P.RollEnergy
		if (energy[player] or 0) < cost then
			return
		end
		energy[player] = (energy[player] or 0) - cost
		lastSprintAt[player] = now
		lastDodgeAt[player] = now
		publish(player)
		if kind == "roll" then
			PlayerService.setInvulnerable(player, P.RollInvulnSeconds)
		end
		local seconds = if kind == "slide" then P.SlideSeconds else P.RollSeconds
		player:SetAttribute("Dodge", kind)
		task.delay(seconds, function()
			if player:GetAttribute("Dodge") == kind then
				player:SetAttribute("Dodge", nil)
			end
		end)
	end)

	-- единый цикл на всех игроков
	task.spawn(function()
		while true do
			task.wait(TICK)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				local e = energy[player]
				if e then
					local h = humanoidOf(player)
					local moving = h ~= nil and h.MoveDirection.Magnitude > 0.1
					local active = (wanted[player] or false) and moving and e > 0 and PlayerService.isUp(player)
					local free = isInfinite(player)
					player:SetAttribute("InfiniteEnergy", free)
					if free then
						e = P.EnergyMax
						if active then
							lastSprintAt[player] = now
						end
					elseif active then
						e = math.max(0, e - DRAIN_PER_SEC * TICK)
						lastSprintAt[player] = now
						if e <= 0 then
							wanted[player] = false -- выдохлись: чтобы снова бежать, нужно отпустить и нажать заново
						end
					elseif e < P.EnergyMax and now - (lastSprintAt[player] or 0) >= P.EnergyRegenDelay then
						e = math.min(P.EnergyMax, e + REGEN_PER_SEC * TICK)
					end
					energy[player] = e
					publish(player)
					if active ~= (sprinting[player] or false) then
						setSprinting(player, active)
					end
				end
			end
		end
	end)
end

return StaminaService
