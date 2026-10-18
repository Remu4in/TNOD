--!strict
-- Точка входа сервера: строим первую локацию, поднимаем сервисы, запускаем цикл раундов.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Services = script:WaitForChild("Services")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MapBuilder = require(Services:WaitForChild("MapBuilder"))
local BarricadeService = require(Services:WaitForChild("BarricadeService"))
local PlayerService = require(Services:WaitForChild("PlayerService"))
local ZombieService = require(Services:WaitForChild("ZombieService"))
local WeaponService = require(Services:WaitForChild("WeaponService"))
local DataService = require(Services:WaitForChild("DataService"))
local RoundService = require(Services:WaitForChild("RoundService"))
local ScoreService = require(Services:WaitForChild("ScoreService"))
local StaminaService = require(Services:WaitForChild("StaminaService"))

-- Пустой скрипт Health заменяет встроенный реген Roblox (реген свой — в PlayerService)
local scs = StarterPlayer:FindFirstChildOfClass("StarterCharacterScripts")
if scs and not scs:FindFirstChild("Health") then
	local stub = Instance.new("Script")
	stub.Name = "Health"
	stub.Parent = scs
end

-- Режим осмотра: строим большой мир, без раундов и зомби (см. Config.Explore)
if Config.Explore then
	local Lighting = game:GetService("Lighting")
	Lighting.ClockTime = 14
	Lighting.Brightness = 3
	Lighting.FogEnd = 100000
	for _, c in Lighting:GetChildren() do -- ночные Sky не нужны днём: убираем только на время игры
		if c:IsA("Sky") then
			c.Parent = nil
		end
	end
	local exploreMap = MapBuilder.build("World")
	ReplicatedStorage:SetAttribute("Location", exploreMap.name)
	ReplicatedStorage:SetAttribute("Phase", "Day")
	PlayerService.init(exploreMap.playerSpawn, function() end)
	WeaponService.init(exploreMap)
	DataService.init()
	ScoreService.init()
	StaminaService.init()
	-- игроки, появившиеся до готовности карты, падали в пустоту: перезагружаем персонажей и возрождаем после гибели
	local Players = game:GetService("Players")
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			local hum = character:WaitForChild("Humanoid", 5) :: Humanoid?
			if hum then
				hum.Died:Connect(function()
					task.wait(2)
					player:LoadCharacter()
				end)
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
		player:LoadCharacter()
	end
	local VehicleService = require(Services:WaitForChild("VehicleService"))
	VehicleService.init()
	local carNames = { "Coupe", "Sedan", "Prius" }
	for i, cf in exploreMap.carSpawns or {} do
		VehicleService.spawn(carNames[(i - 1) % #carNames + 1], cf)
	end
	-- проверочные зомби (Зомби 3.0): по 3 штуки (Ходок, Бегун, Громила) в 50 студах от спавна, пополняются
	if Config.ExploreZombies then
		local sp = exploreMap.playerSpawn
		ZombieService.init({ zombieSpawns = { sp + Vector3.new(0, 3, -50) } } :: any, function() end)
		-- отладочный вход для тестов из Studio (execute_luau получает свою копию модуля, а не рабочую)
		local debugFn = Instance.new("BindableFunction")
		debugFn.Name = "ExploreZombieDebug"
		debugFn.OnInvoke = function(cmd: string, a: any, b: any, c: any)
			if cmd == "enqueue" then
				ZombieService.enqueue(a, 1)
			elseif cmd == "damage" then
				return ZombieService.damage(a, b, nil, c)
			elseif cmd == "kind" then
				return ZombieService.partKind(a)
			elseif cmd == "remaining" then
				return ZombieService.remaining()
			end
			return nil
		end
		debugFn.Parent = game:GetService("ServerStorage")
		task.spawn(function()
			while true do
				if ZombieService.remaining() < 3 and #Players:GetPlayers() > 0 then
					ZombieService.enqueue(Config.ExploreZombieTypes, 1)
				end
				task.wait(8)
			end
		end)
	end
	print("[NightOfTheDead] режим осмотра: " .. exploreMap.name)
	return
end

local first = Config.Locations[1]
local map = MapBuilder.build(first.id)
ReplicatedStorage:SetAttribute("Location", first.name)
BarricadeService.init(map)
PlayerService.init(map.playerSpawn, RoundService.onAllDown)
ZombieService.init(map, RoundService.onZombieKilled)
WeaponService.init(map)
DataService.init()
ScoreService.init()
StaminaService.init()
RoundService.start(map)

print("[NightOfTheDead] сервер запущен, локация: " .. first.name)
