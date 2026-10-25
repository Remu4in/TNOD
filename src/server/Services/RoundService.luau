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
local GeneralService = require(script.Parent:WaitForChild("GeneralService"))
local MissionService = require(script.Parent:WaitForChild("MissionService"))
local PerkService = require(script.Parent:WaitForChild("PerkService"))
local Perks = require(Shared:WaitForChild("Perks"))
local RatingService = require(script.Parent:WaitForChild("RatingService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))

local RoundService = {}

local currentMap: Types.MapInfo? = nil
local reviveLockUntil = 0 -- пока идёт воскрешение командой, повторные «все пали» игнорируем
local wave = 0
local locationIndex = 1 -- init.server строит первую локацию из Config.Locations
local gameOver = false
local fellAtNight = false
local rng = Random.new()
local killUnits: { [string]: number } = {} -- монеты за убийство в голову по типам на текущую ночь (WaveMath.killUnits)
local killEarned: { [Player]: number } = {} -- сколько монет за убийства игрок уже получил за эту ночь (потолок WaveMath.killCap)
local roundSeed = 1 -- семя бросков прогрессии (WaveMath.roll): одно на раунд, чтобы рост по волнам был воспроизводим
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

-- Ночной город: света почти нет, видно только то, что освещают фонари, окна магазинов и (позже) фонарики оружия.
-- Эффекты (туман, цветокоррекция, свечение) плавно меняются между днём и ночью; дневные значения берём из того, что настроено в Studio.
local TweenService = game:GetService("TweenService")
local NIGHT = {
	lighting = { Brightness = 0.3, Ambient = Color3.fromRGB(58, 66, 100), OutdoorAmbient = Color3.fromRGB(70, 82, 120), ExposureCompensation = 0.1, EnvironmentDiffuseScale = 0.5, EnvironmentSpecularScale = 0.3 },
	atmosphere = { Density = 0.3, Offset = 0.2, Color = Color3.fromRGB(44, 54, 88), Decay = Color3.fromRGB(30, 36, 60), Haze = 1.2, Glare = 0 },
	bloom = { Intensity = 0.9, Size = 30, Threshold = 0.85 },
	sunRays = { Intensity = 0, Spread = 0.2 },
	grade = { Brightness = 0.04, Contrast = 0.08, Saturation = -0.3, TintColor = Color3.fromRGB(205, 218, 255) },
}
local dayEffects: { [string]: { [string]: any } } = {}

local function lerpGrade(night: boolean)
	local info = TweenInfo.new(night and 4 or 3, Enum.EasingStyle.Sine)
	local grade = Lighting:FindFirstChild("NightGrade") :: ColorCorrectionEffect?
	if not grade then
		local g = Instance.new("ColorCorrectionEffect")
		g.Name = "NightGrade"
		g.Parent = Lighting
		grade = g
	end
	local function go(inst: Instance?, key: string, target: { [string]: any })
		if not inst then
			return
		end
		if not dayEffects[key] then
			local snap: { [string]: any } = {}
			for prop in target do
				snap[prop] = (inst :: any)[prop]
			end
			dayEffects[key] = snap
		end
		TweenService:Create(inst, info, if night then target else dayEffects[key]):Play()
	end
	if not dayEffects.grade then
		dayEffects.grade = { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1) }
	end
	go(grade, "grade", NIGHT.grade)
	go(Lighting:FindFirstChildOfClass("Atmosphere"), "atmosphere", NIGHT.atmosphere)
	go(Lighting:FindFirstChildOfClass("BloomEffect"), "bloom", NIGHT.bloom)
	go(Lighting:FindFirstChildOfClass("SunRaysEffect"), "sunRays", NIGHT.sunRays)
	go(Lighting, "lighting", NIGHT.lighting)
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
	setSky(if not night then "Sky" elseif bossNight then "RedNight" else "NightSky")
	lerpGrade(night)
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
	wave = math.max(0, Config.DebugStartNight - 1)
	local players = Players:GetPlayers()
	if locationIndex ~= 1 then
		loadLocation(1)
	end
	BarricadeService.repairAll()
	BuildingService.reset()
	EquipmentService.clearAll()
	VehicleService.resetRound() -- разбитые машины и пустой пулемёт прошлого раунда — заново
	EconomyService.resetRound(players)
	ScoreService.resetRound(players)
	PerkService.reset()
	MissionService.resetRound()
	RatingService.resetRound(players)
	roundSeed = rng:NextInteger(1, 1000000)
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
		if wave > 0 and Config.MissionReturnTeam then
			MissionService.returnTeam(currentMap.playerSpawn)
		end
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
	GeneralService.announceDay()
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

-- Классы оружия у каждого игрока на начало ночи (рюкзак + в руках) — для уровня угрозы
local function loadouts(): { { string } }
	local list: { { string } } = {}
	for _, p in Players:GetPlayers() do
		local classes: { string } = {}
		local containers: { Instance? } = { p:FindFirstChildOfClass("Backpack"), p.Character }
		for _, container in containers do
			if container then
				for _, tool in container:GetChildren() do
					if tool:IsA("Tool") then
						local id = tool:GetAttribute("WeaponId")
						local class = if typeof(id) == "string" then Config.WeaponThreat[id] else nil
						if class then
							table.insert(classes, class)
						end
					end
				end
			end
		end
		table.insert(list, classes)
	end
	return list
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
	local nightLength = math.min(Config.Round.NightMaxTime, Config.Round.NightMinTime + Config.Round.NightPerWave * (wave - 1))
	local nightStart = os.clock()
	local nightEndsAt = nightStart + nightLength
	local players = #Players:GetPlayers()
	local threat = WaveMath.makeThreat(Config.ThreatClasses, Config.Threat.Tiers, loadouts(), roundSeed)
	local comp = WaveMath.composition(Config.Waves, wave, players, threat)
	killUnits = WaveMath.killUnits(Config.Economy, wave, comp, players)
	table.clear(killEarned)
	EconomyService.newWave()
	PlayerService.takeLosses()
	ZombieService.enqueue(WaveMath.spawnQueue(comp, rng), WaveMath.hpMultiplier(Config.Waves, wave, threat), wave)
	print(string.format("[RoundService] ночь %d: игроков %d, зомби %d, угроза %.1f (уровень x%.2f HP), оружие: %s", wave, players, WaveMath.total(comp), threat.score, threat.tier.hp, table.concat(threat.classes, ",")))
	local bossName: string? = nil
	for _, bossId in WaveMath.bossTypes(Config.Waves, wave) do
		bossName = Config.Zombies[bossId].name
	end
	if bossName then
		notifyAll(string.format("Идёт босс: %s!", bossName), 3)
	end
	-- миссия ночи (MissionService): точка, задача, поток зомби вокруг точки; ночь засчитана, когда задача выполнена и убит минимум зомби
	-- (classic/clear — когда убита вся волна и набран минимум; MissionService.update возвращает "done")
	MissionService.begin(wave, comp, WaveMath.hpMultiplier(Config.Waves, wave, threat), players)
	local missionDone = false
	while not gameOver do
		local left = ZombieService.remaining()
		ReplicatedStorage:SetAttribute("ZombiesLeft", left)
		local missionState = MissionService.update(0.25)
		if missionState == "done" then
			missionDone = true
			break
		elseif missionState == "fail" then
			break
		end
		if os.clock() > nightEndsAt then
			break
		end
		task.wait(0.25)
	end
	MissionService.finish()
	if not gameOver then
		local cleared = missionDone or ZombieService.remaining() == 0
		RatingService.onNightEnd(wave, cleared, (os.clock() - nightStart) / nightLength)
		-- награда за миссию: личная часть каждому + командная поровну; стоящему на ногах — целиком, лежащему — DownedRewardFactor от неё;
		-- провал миссии — доля MissionFailShare; штраф за каждую потерю — доля того, что каждый заработал за волну
		local E = Config.Economy
		local everyone = Players:GetPlayers()
		local personal, team = WaveMath.missionReward(E, wave)
		local share = personal + (if #everyone > 0 then team / #everyone else 0)
		if not cleared then
			share *= E.MissionFailShare
		end
		share *= Perks.mult("coins")
		local gotBy: { [Player]: number } = {}
		for _, p in everyone do
			local amount = if PlayerService.isUp(p) then share else share * E.DownedRewardFactor
			EconomyService.add(p, amount)
			gotBy[p] = amount
		end
		local losses = PlayerService.takeLosses()
		local fine = if losses > 0 then EconomyService.penalize(E.LossPenalty * losses) else 0
		for _, p in everyone do
			local text = string.format("Волна %d пройдена: +%d монет", wave, math.floor((gotBy[p] or 0) + 0.5))
			if fine > 0 then
				text ..= string.format(" (штраф команды за потери −%d)", fine)
			end
			if p.Parent then
				Remotes.get("Notify"):FireClient(p, text, 5)
			end
		end
		if WaveMath.isBossWave(Config.Waves, wave) and cleared then
			PerkService.openOffers()
		end
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
	RatingService.finishRound(Players:GetPlayers())
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
	MissionService.onKill(player)
	if player then
		-- убийство выстрелом в голову: больше монет и очков
		local head = zombie.headKill == true
		local unit = killUnits[zombie.def.id] or 0
		local coins = unit * (if head then 1 else Config.Economy.KillBodyShare) * Perks.mult("coins")
		-- потолок за ночь: поток зомби во время миссии не даёт фармить
		local earned = killEarned[player] or 0
		coins = math.min(coins, math.max(0, WaveMath.killCap(Config.Economy, wave) - earned))
		killEarned[player] = earned + coins
		local bonusPoints = if head then math.floor(zombie.def.points * Config.Economy.HeadshotKillPointsBonus + 0.5) else 0
		if head then
			player:SetAttribute("Headshots", ((player:GetAttribute("Headshots") :: number?) or 0) + 1)
		end
		EconomyService.add(player, coins)
		ScoreService.recordKill(player, zombie.def.points + bonusPoints)
		RatingService.onKill(player, zombie)
	end
end

function RoundService.start(map: Types.MapInfo)
	currentMap = map
	BuildingService.setUnlockHandler(function(player: Player, _id: string)
		RatingService.onBuildingOpened(player)
	end)
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
