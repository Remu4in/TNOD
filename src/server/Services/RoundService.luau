--!strict
-- Конечный автомат раунда: Перерыв → (День → Ночь)×N → Конец.
-- Состояние для клиентов — атрибуты ReplicatedStorage: Phase, Wave, PhaseEndsAt, ZombiesLeft.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local BarricadeService = require(script.Parent:WaitForChild("BarricadeService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))
local DataService = require(script.Parent:WaitForChild("DataService"))
local MapBuilder = require(script.Parent:WaitForChild("MapBuilder"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))
local BuildingService = require(script.Parent:WaitForChild("BuildingService"))
local EquipmentService = require(script.Parent:WaitForChild("EquipmentService"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))

local RoundService = {}

local currentMap: Types.MapInfo? = nil
local reviveLockUntil = 0 -- пока идёт воскрешение командой, повторные «все пали» игнорируем
local wave = 0
local locationIndex = 1 -- init.server строит первую локацию из Config.Locations
local gameOver = false
local fellAtNight = false
local rng = Random.new()
local dayVotes: { [Player]: boolean } = {} -- голоса «завершить день»

-- Голоса: считаем среди игроков, которые сейчас в игре; атрибуты для HUD (DayVotes / DayVoteNeed)
local function countVotes(): (number, number)
	local votes, need = 0, 0
	for _, p in Players:GetPlayers() do
		need += 1
		if dayVotes[p] then
			votes += 1
		end
	end
	ReplicatedStorage:SetAttribute("DayVotes", votes)
	ReplicatedStorage:SetAttribute("DayVoteNeed", need)
	return votes, need
end

-- Ждём seconds секунд дня; true — если все игроки проголосовали и день надо завершить досрочно
local function waitDayVote(seconds: number): boolean
	local endsAt = os.clock() + seconds
	while os.clock() < endsAt and not gameOver do
		local votes, need = countVotes()
		if need > 0 and votes >= need then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function setPhase(phase: string, duration: number?)
	ReplicatedStorage:SetAttribute("Phase", phase)
	ReplicatedStorage:SetAttribute("PhaseEndsAt", if duration then workspace:GetServerTimeNow() + duration else 0)
end

local function notifyAll(text: string, seconds: number)
	Remotes.get("Notify"):FireAllClients(text, seconds)
end

-- Свет дня берётся таким, каким Руслан настроил его в Studio (снимок при старте); ночью — свой, с другим небом
local dayLook: { clock: number, brightness: number, ambient: Color3, fogEnd: number, fogColor: Color3 }? = nil

-- Оставляем в Lighting одно небо с именем name; остальные лежат в ServerStorage.Skies (Sky — день, NightSky — ночь, RedNight — ночь с боссом)
local function setSky(name: string)
	local storage = ServerStorage:FindFirstChild("Skies")
	if not storage then
		return
	end
	for _, s in Lighting:GetChildren() do
		if s:IsA("Sky") and s.Name ~= name then
			s.Parent = storage
		end
	end
	if not Lighting:FindFirstChild(name) then
		local s = storage:FindFirstChild(name)
		if s then
			s.Parent = Lighting
		end
	end
end

local function setNight(night: boolean, bossNight: boolean?)
	if not dayLook then
		dayLook = {
			clock = Lighting.ClockTime, brightness = Lighting.Brightness, ambient = Lighting.OutdoorAmbient,
			fogEnd = Lighting.FogEnd, fogColor = Lighting.FogColor,
		}
	end
	local d = dayLook :: { clock: number, brightness: number, ambient: Color3, fogEnd: number, fogColor: Color3 }
	Lighting.ClockTime = if night then 0 else d.clock
	Lighting.Brightness = if night then 0.5 else d.brightness
	Lighting.OutdoorAmbient = if night then Color3.fromRGB(40, 45, 70) else d.ambient
	Lighting.FogEnd = if night then 400 else d.fogEnd
	Lighting.FogColor = if night then Color3.fromRGB(15, 18, 30) else d.fogColor
	setSky(if not night then "Sky" elseif bossNight then "RedNight" else "NightSky")
end

-- Какая локация нужна для ночи N: смена каждые LocationNights ночей; ещё не построенные пропускаем.
local function locationFor(night: number): number
	local idx = math.min(math.floor((night - 1) / Config.LocationNights) + 1, #Config.Locations)
	while idx > 1 and not MapBuilder.has(Config.Locations[idx].id) do
		idx -= 1
	end
	return idx
end

local function loadLocation(idx: number)
	local loc = Config.Locations[idx]
	local map = MapBuilder.build(loc.id)
	locationIndex = idx
	BarricadeService.setMap(map)
	ZombieService.setMap(map)
	WeaponService.setMap(map)
	BuildingService.setMap(map)
	currentMap = map
	PlayerService.setSpawn(map.playerSpawn)
	ReplicatedStorage:SetAttribute("Location", loc.name)
	-- живых игроков переносим в новый магазин
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if char then
			char:PivotTo(CFrame.new(map.playerSpawn + Vector3.new(math.random(-6, 6), 0, math.random(-4, 4))))
		end
	end
	notifyAll("Новая локация: " .. loc.name, 5)
end

local function waitPhase(seconds: number)
	local endsAt = os.clock() + seconds
	while os.clock() < endsAt and not gameOver do
		task.wait(0.25)
	end
end

local function intermission()
	ZombieService.clearAll()
	if locationIndex ~= 1 then
		loadLocation(1)
	end
	BarricadeService.setOpen(true)
	BuildingService.openShop()
	setNight(false)
	ReplicatedStorage:SetAttribute("Wave", 0)
	ReplicatedStorage:SetAttribute("ZombiesLeft", 0)
	while #Players:GetPlayers() == 0 do
		task.wait(1)
	end
	setPhase("Intermission", Config.Round.IntermissionTime)
	if currentMap then
		PlayerService.setSpawn(currentMap.playerSpawn) -- днём (и в перерыве) появляемся в магазине
	end
	PlayerService.spawnAll()
	notifyAll("Новый раунд скоро начнётся", 3)
	task.wait(Config.Round.IntermissionTime)
end

local function startRound()
	gameOver = false
	fellAtNight = false
	wave = 0
	local players = Players:GetPlayers()
	if locationIndex ~= 1 then
		loadLocation(1)
	end
	BarricadeService.repairAll()
	BuildingService.reset()
	EquipmentService.clearAll()
	EconomyService.resetRound(players)
	ScoreService.resetRound(players)
	WeaponService.resetRound(players)
	for _, p in players do
		p:SetAttribute("Revives", 0)
		p:SetAttribute("Headshots", 0)
	end
	if currentMap then
		PlayerService.setSpawn(currentMap.playerSpawn)
	end
	PlayerService.spawnAll()
end

local function day(first: boolean)
	local want = locationFor(wave + 1)
	if want ~= locationIndex then
		loadLocation(want)
	end
	EconomyService.newDay()
	if wave > 0 then
		ZombieService.sunrise() -- мутанты не переносят солнце: оставшиеся ночью сгорают
		EquipmentService.onDay() -- электро-проволока обесточена
	end
	BuildingService.openShop()
	if currentMap then
		PlayerService.setSpawn(currentMap.playerSpawn)
	end
	PlayerService.respawnDead()
	setNight(false)
	BarricadeService.setOpen(true)
	local t = if first then Config.Round.FirstDayTime else Config.Round.DayTime
	table.clear(dayVotes)
	for _, p in Players:GetPlayers() do
		p:SetAttribute("VotedDay", false)
	end
	countVotes()
	setPhase("Day", t)
	notifyAll(if first then "Закупайтесь в магазине и открывайте здания — вносите монеты у вывесок" else "Рассвет. Мутанты сгорают на солнце — бегите за покупками!", 4)
	local warn = Config.Round.DayWarnSeconds
	local early = false
	if t > warn + 2 then
		early = waitDayVote(t - warn)
		if not gameOver and not early then
			notifyAll(string.format("Через %d секунд наступит ночь, магазины закроются. Кто снаружи — останется снаружи! (V — завершить день)", warn), 4)
			early = waitDayVote(warn)
		end
	else
		early = waitDayVote(t)
	end
	if early and not gameOver then
		notifyAll("Все готовы — день завершён досрочно", 3)
	end
	table.clear(dayVotes)
	ReplicatedStorage:SetAttribute("DayVotes", 0)
end

local function night()
	wave += 1
	ReplicatedStorage:SetAttribute("Wave", wave)
	BarricadeService.setOpen(false)
	BuildingService.closeShop() -- магазин на ночь закрыт, оставшихся внутри выталкивает на улицу
	if currentMap then
		PlayerService.setSpawn(currentMap.nightSpawn) -- ночью (воскрешение командой) появляемся в стартовом укрытии
	end
	local bossIds = WaveMath.bossTypes(Config.Waves, wave)
	setNight(true, #bossIds > 0)
	setPhase("Night", nil)
	local nightEndsAt = os.clock() + Config.Round.NightMaxTime
	local players = #Players:GetPlayers()
	local comp = WaveMath.composition(Config.Waves, wave, players)
	ZombieService.enqueue(WaveMath.spawnQueue(comp, rng), WaveMath.hpMultiplier(Config.Waves, wave))
	local bossName: string? = nil
	for _, bossId in WaveMath.bossTypes(Config.Waves, wave) do
		bossName = Config.Zombies[bossId].name
	end
	notifyAll(if bossName then string.format("Ночь %d. Идёт босс: %s!", wave, bossName) else string.format("Ночь %d", wave), 3)
	while not gameOver do
		local left = ZombieService.remaining()
		ReplicatedStorage:SetAttribute("ZombiesLeft", left)
		if left == 0 or os.clock() > nightEndsAt then
			break
		end
		task.wait(0.25)
	end
end

local function finishRound()
	ZombieService.clearAll()
	setPhase("GameOver", Config.Round.GameOverTime)
	-- ночь, на которой все пали, не засчитывается
	local reached = math.max(0, if fellAtNight then wave - 1 else wave)
	ReplicatedStorage:SetAttribute("LastRoundWave", reached)
	notifyAll(string.format("Все пали. Продержались %d ночей", reached), Config.Round.GameOverTime)
	-- через несколько секунд — итоги по очкам
	local bestPlayer, bestScore, bestKills = ScoreService.best()
	if bestPlayer then
		local team = (ReplicatedStorage:GetAttribute("TeamTotal") :: number?) or 0
		task.delay(4, function()
			notifyAll(
				string.format("Лучший: %s — %d очков, %d убийств. Команда набрала %d", bestPlayer.DisplayName, bestScore, bestKills, team),
				Config.Round.GameOverTime - 4
			)
		end)
	end
	for _, p in Players:GetPlayers() do
		DataService.recordRound(
			p,
			reached,
			(p:GetAttribute("RoundKills") :: number?) or 0,
			(p:GetAttribute("Revives") :: number?) or 0
		)
	end
	task.wait(Config.Round.GameOverTime)
end

function RoundService.onAllDown()
	local phase = ReplicatedStorage:GetAttribute("Phase")
	if phase == "Night" or phase == "Day" then
		if os.clock() < reviveLockUntil then
			return
		end
		-- дополнительная жизнь команды (Убежище): все поднимаются, раунд продолжается
		local lives = (ReplicatedStorage:GetAttribute("TeamLives") :: number?) or 0
		if lives > 0 then
			ReplicatedStorage:SetAttribute("TeamLives", lives - 1)
			reviveLockUntil = os.clock() + 5
			notifyAll("Дополнительная жизнь! Команда поднимается", 4)
			PlayerService.reviveAll()
			return
		end
		fellAtNight = phase == "Night"
		gameOver = true
	end
end

function RoundService.onZombieKilled(player: Player?, zombie: any)
	if player then
		-- убийство выстрелом в голову: больше монет и очков
		local head = zombie.headKill == true
		local bonusCoins = if head then math.floor(zombie.def.reward * Config.Economy.HeadshotKillCoinsBonus + 0.5) else 0
		local bonusPoints = if head then math.floor(zombie.def.points * Config.Economy.HeadshotKillPointsBonus + 0.5) else 0
		if head then
			player:SetAttribute("Headshots", ((player:GetAttribute("Headshots") :: number?) or 0) + 1)
		end
		EconomyService.add(player, zombie.def.reward + bonusCoins)
		ScoreService.recordKill(player, zombie.def.points + bonusPoints)
	end
end

function RoundService.start(map: Types.MapInfo)
	currentMap = map
	Remotes.get("VoteDay").OnServerEvent:Connect(function(player: Player)
		if ReplicatedStorage:GetAttribute("Phase") ~= "Day" or not RateLimit.allow(player, "VoteDay", 0.4) then
			return
		end
		dayVotes[player] = if dayVotes[player] then nil else true
		player:SetAttribute("VotedDay", dayVotes[player] == true)
		countVotes()
	end)
	Players.PlayerRemoving:Connect(function(player)
		dayVotes[player] = nil
	end)
	BuildingService.setMap(map)
	-- зашедшие в перерыв или днём сразу получают персонажа; ночью — ждут рассвета
	Players.PlayerAdded:Connect(function(player)
		local phase = ReplicatedStorage:GetAttribute("Phase")
		if phase == "Intermission" or phase == "Day" then
			PlayerService.spawn(player)
		else
			Remotes.get("Notify"):FireClient(player, "Идёт ночь. Вы появитесь на рассвете", 4)
		end
	end)
	task.spawn(function()
		while true do
			intermission()
			startRound()
			local first = true
			while not gameOver do
				day(first)
				first = false
				if gameOver then
					break
				end
				night()
			end
			finishRound()
		end
	end)
end

return RoundService
