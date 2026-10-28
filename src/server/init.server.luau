--!strict
-- Точка входа сервера: строим первую локацию, поднимаем сервисы, запускаем цикл раундов.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
local RateLimit = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RateLimit"))
local ScoreService = require(Services:WaitForChild("ScoreService"))
local RatingService = require(Services:WaitForChild("RatingService"))
local PerkService = require(Services:WaitForChild("PerkService"))
local GeneralService = require(Services:WaitForChild("GeneralService"))
local StaminaService = require(Services:WaitForChild("StaminaService"))
local ShopService = require(Services:WaitForChild("ShopService"))
local VendorService = require(Services:WaitForChild("VendorService"))
local EquipmentService = require(Services:WaitForChild("EquipmentService"))
local SoldierService = require(Services:WaitForChild("SoldierService"))

-- Пустой скрипт Health заменяет встроенный реген Roblox (реген свой — в PlayerService)
local scs = StarterPlayer:FindFirstChildOfClass("StarterCharacterScripts")
if scs and not scs:FindFirstChild("Health") then
	local stub = Instance.new("Script")
	stub.Name = "Health"
	stub.Parent = scs
end

-- Тестовые стенды у спавна: оружие бесплатно (меню), вызов волны мутантов, особых, «Пропустить волну» и «Выбор волны».
-- Только в Studio: на живом сервере любой игрок пропускал бы ночи и брал оружие бесплатно, даже если флаг забыли выключить.
local testStandsOn = Config.TestStands and RunService:IsStudio()

local function buildTestStands(sp: Vector3)
	local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
	local function pad(name: string, offset: Vector3, color: Color3, label: string, action: string, onTrigger: (Player) -> ()): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = Vector3.new(4, 5, 2)
		part.Position = Vector3.new(sp.X, 0, sp.Z) + offset + Vector3.new(0, 2.5, 0)
		part.Color = color
		part.Material = Enum.Material.Neon
		part.Parent = workspace
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(180, 36)
		gui.StudsOffset = Vector3.new(0, 4, 0)
		gui.AlwaysOnTop = true
		gui.Parent = part
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 0.3
		text.BackgroundColor3 = Color3.new(0, 0, 0)
		text.TextColor3 = Color3.new(1, 1, 1)
		text.Font = Enum.Font.GothamBold
		text.TextScaled = true
		text.Text = label
		text.Parent = gui
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = action
		prompt.ObjectText = label
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = part
		prompt.Triggered:Connect(onTrigger)
		return part
	end
	ShopService.addPoint("Тестовый стенд", Vector3.new(sp.X - 12, sp.Y, sp.Z + 8), 16, true, false, false)
	pad("TestShop", Vector3.new(-12, 0, 8), Color3.fromRGB(255, 170, 40), "ОРУЖИЕ (тест)", "Открыть меню", function(player)
		Remotes.get("ShopOpen"):FireClient(player)
	end)
	local waves: { [string]: { string } } = {
		["Волна"] = { "Walker", "Walker", "Walker", "Walker", "Walker", "Walker", "Runner", "Runner", "Runner", "Brute" },
		["Особые"] = { "Military", "Military", "Chemist", "Dark", "Dark", "BucketHead", "BucketHead", "Crawler", "Crawler" },
	}
	pad("TestWave", Vector3.new(-4, 0, 8), Color3.fromRGB(220, 60, 60), "ВОЛНА ЗОМБИ", "Вызвать волну", function()
		ZombieService.enqueue(waves["Волна"]) -- без множителей: сила текущей ночи не сбрасывается
	end)
	pad("TestSpecial", Vector3.new(4, 0, 8), Color3.fromRGB(150, 60, 200), "ОСОБЫЕ ЗОМБИ", "Вызвать особых", function()
		ZombieService.enqueue(waves["Особые"])
	end)
	-- вызывает босса (по кругу: Качок, Гаргантюа, Повелитель тёмных) — проверить его атаки и полоску здоровья, не дожидаясь 5-й ночи
	local bossCycle, bossNext = { "BossBuff", "BossGarg", "BossStrong", "BossFinal" }, 0
	pad("TestBoss", Vector3.new(28, 0, 8), Color3.fromRGB(160, 40, 40), "БОСС", "Вызвать босса", function()
		bossNext = bossNext % #bossCycle + 1
		ZombieService.enqueue({ bossCycle[bossNext] }, nil, nil, true)
	end)
	-- ночью честно завершает текущую ночь (как будто миссия выполнена: награды, рейтинг), днём сразу начинает ночь
	pad("TestSkip", Vector3.new(12, 0, 8), Color3.fromRGB(70, 160, 90), "СКИП ВОЛНЫ", "Пропустить волну", function()
		RoundService.skip()
	end)
	-- открывает окно выбора ночи 1…20 (клиент: TestStandController); выбранную ночь присылают событием TestSetWave
	local pickPad = pad("TestPick", Vector3.new(20, 0, 8), Color3.fromRGB(70, 130, 220), "ВЫБОР ВОЛНЫ", "Выбрать ночь", function(player)
		Remotes.get("TestPickWave"):FireClient(player, #Config.Missions)
	end)
	Remotes.get("TestSetWave").OnServerEvent:Connect(function(player: Player, nightNumber: unknown)
		-- клиент недоверенный: тип, целое число в пределах ночей, частота, и игрок должен стоять у стенда
		if typeof(nightNumber) ~= "number" or nightNumber ~= nightNumber or nightNumber % 1 ~= 0 or nightNumber < 1 or nightNumber > #Config.Missions then
			return
		end
		if not RateLimit.allow(player, "TestSetWave", 1) then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root or (root.Position - pickPad.Position).Magnitude > 40 then
			return
		end
		if RoundService.setNextNight(nightNumber) then
			Remotes.get("Notify"):FireClient(player, string.format("Следующая ночь: %d. Чтобы начать её сразу — «Скип волны»", nightNumber), 5)
		end
	end)
end

-- Режим осмотра: строим большой мир, без раундов и зомби (см. Config.Explore)
if Config.Explore then
	-- карту строит Руслан руками в Studio: код ничего не генерирует и не трогает освещение (Locations/Custom только читает маркеры)
	local exploreMap = MapBuilder.build("Custom")
	ReplicatedStorage:SetAttribute("Location", exploreMap.name)
	ReplicatedStorage:SetAttribute("Phase", "Day")
	PlayerService.init(exploreMap.playerSpawn, function() end)
	ShopService.init(exploreMap)
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
	-- игрок, вошедший позже запуска скрипта (карта теперь грузится мгновенно), тоже должен получить персонажа
	Players.PlayerAdded:Connect(function(player)
		watch(player)
		player:LoadCharacter()
	end)
	for _, player in Players:GetPlayers() do
		watch(player)
		player:LoadCharacter()
	end
	local VehicleService = require(Services:WaitForChild("VehicleService"))
	VehicleService.init()
	-- ездовые: Mercedes (Coupe), Toyota (Prius), военный джип с турелью; остальные машины пока без посадки
	-- места машин — маркеры Workspace.Markers.VehicleSpawn_<Шаблон> (Coupe, Prius, GunJeep …)
	for i, cf in exploreMap.carSpawns or {} do
		VehicleService.spawn((exploreMap.carNames :: { string })[i], cf)
	end
	-- проверочные зомби (Зомби 3.0): по 3 штуки (Ходок, Бегун, Громила) в 50 студах от спавна, пополняются
	if Config.ExploreZombies then
		ZombieService.init({ zombieSpawns = exploreMap.zombieSpawns } :: any, function() end)
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
	end
	if testStandsOn then
		buildTestStands(exploreMap.playerSpawn)
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
RatingService.init()
PerkService.init()
GeneralService.init()
require(Services:WaitForChild("AmmoCrateService")).init()
require(Services:WaitForChild("MissionService")).init()
StaminaService.init()
ShopService.init(map)
RoundService.start(map)
EquipmentService.init()
VendorService.init(map)
SoldierService.init()

-- ездовые машины: маркеры Workspace.Markers.VehicleSpawn_<Шаблон>
local VehicleService = require(Services:WaitForChild("VehicleService"))
VehicleService.init()
VehicleService.spawnAll(map.carSpawns, map.carNames) -- каждый раунд ставятся заново (RoundService → VehicleService.resetRound)
if testStandsOn then
	buildTestStands(map.playerSpawn)
end

print("[NightOfTheDead] сервер запущен, локация: " .. first.name)
