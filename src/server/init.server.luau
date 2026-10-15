--!strict
-- Точка входа сервера: строим карту, поднимаем сервисы, запускаем цикл раундов.

local StarterPlayer = game:GetService("StarterPlayer")
local Services = script:WaitForChild("Services")

local MapBuilder = require(Services:WaitForChild("MapBuilder"))
local BarricadeService = require(Services:WaitForChild("BarricadeService"))
local PlayerService = require(Services:WaitForChild("PlayerService"))
local ZombieService = require(Services:WaitForChild("ZombieService"))
local WeaponService = require(Services:WaitForChild("WeaponService"))
local DataService = require(Services:WaitForChild("DataService"))
local RoundService = require(Services:WaitForChild("RoundService"))

-- Пустой скрипт Health заменяет встроенный реген Roblox (реген свой — в PlayerService)
local scs = StarterPlayer:FindFirstChildOfClass("StarterCharacterScripts")
if scs and not scs:FindFirstChild("Health") then
	local stub = Instance.new("Script")
	stub.Name = "Health"
	stub.Parent = scs
end

local map = MapBuilder.build()
BarricadeService.init(map)
PlayerService.init(map.playerSpawn, RoundService.onAllDown)
ZombieService.init(map, RoundService.onZombieKilled)
WeaponService.init(map)
DataService.init()
RoundService.start()

print("[NightOfTheDead] сервер запущен")
