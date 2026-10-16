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

-- Пустой скрипт Health заменяет встроенный реген Roblox (реген свой — в PlayerService)
local scs = StarterPlayer:FindFirstChildOfClass("StarterCharacterScripts")
if scs and not scs:FindFirstChild("Health") then
	local stub = Instance.new("Script")
	stub.Name = "Health"
	stub.Parent = scs
end

local first = Config.Locations[1]
local map = MapBuilder.build(first.id)
ReplicatedStorage:SetAttribute("Location", first.name)
BarricadeService.init(map)
PlayerService.init(map.playerSpawn, RoundService.onAllDown)
ZombieService.init(map, RoundService.onZombieKilled)
WeaponService.init(map)
DataService.init()
RoundService.start()

print("[NightOfTheDead] сервер запущен, локация: " .. first.name)
