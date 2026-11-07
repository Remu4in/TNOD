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
local DonateService = require(script.Parent:WaitForChild("DonateService"))
local CutsceneService = require(script.Parent:WaitForChild("CutsceneService"))
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
local lobbyHooks: { begin: () -> (), after: () -> () }? = nil -- лобби включено: после раунда экран итогов и возврат в лобби
local fellAtNight = false
local finalePending = false -- убит финальный босс: следующий день — финал акта 1 (бункер)
local finaleDone = false -- акт 1 пройден: раунд кончается поздравлением, а не «все пали»
local rng = Random.new()
-- Донат в матче: каждый день (и сразу после покупки днём); разовое за раунд — один раз
local donateGiven: { [Player]: { [string]: boolean } } = {}
local function applyDonate(p: Player)
	if ReplicatedStorage:GetAttribute("Phase") ~= "Day" or not p.Parent then
		return
	end
	local given = donateGiven[p] or {}
	donateGiven[p] = given
	local function once(key: string, fn: () -> ())
		if p:GetAttribute("Has_" .. key) == true and not given[key] then
			given[key] = true
			fn()
		end
	end
	once("vip", function()
		EconomyService.applyStartCoins(p, Config.Donate.Vip.StartCoins)
	end)
	once("karambit", function()
		WeaponService.give(p, "Karambit")
	end)
	once("balisong", function()
		WeaponService.give(p, "Balisong")
	end)
	once("driver", function()
		BuildingService.unlockFree("Garage")
	end)
	once("commander", function()
		BuildingService.unlockFree("Armory")
		BuildingService.unlockFree("GunShop")
		EquipmentService.give(p, "Turret")
	end)
end
DonateService.setApplyHandler(applyDonate)

local roundSeed = 1 -- семя бросков прогрессии (WaveMath.roll): одно на раунд, чтобы рост по волнам был воспроизводим
local dayVotes: { [Player]: boolean } = {} -- голоса «завершить день»
local skipRequested = false -- тестовый стенд «Пропустить волну»: сейчас идёт ночь — завершить её как выполненную; днём — сразу начать ночь
local pendingNight: number? = nil -- тестовый стенд «Выбор волны»: какой должна быть следующая ночь (применяется, когда текущая закончится)

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
		if (need > 0 and votes >= need) or skipRequested then
			skipRequested = false
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

-- Свет, туман, цветокоррекцию и свечение ставит клиент (LookController) по пресетам Config.Visual.Presets: сервер говорит только,
-- какой вид нужен (атрибут Look: day | night | boss), и меняет небо.
local function setNight(night: boolean, bossNight: boolean?)
	setSky(if not night then "Sky" elseif bossNight then "RedNight" else "NightSky")
	ReplicatedStorage:SetAttribute("Look", if not night then "day" elseif bossNight then "boss" else "night")
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
	notifyAll("New location: " .. loc.name, 5)
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
	notifyAll("A new round starts soon", 3)
	task.wait(Config.Round.IntermissionTime)
end

local function startRound()
	gameOver = false
	fellAtNight = false
	finalePending = false
	finaleDone = false
	ReplicatedStorage:SetAttribute("Victory", nil)
	ReplicatedStorage:SetAttribute("ActComplete", nil)
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
	table.clear(donateGiven)
	for _, p in players do
		p:SetAttribute("Revives", 0)
		p:SetAttribute("Headshots", 0)
	end
	if currentMap then
		PlayerService.setSpawn(currentMap.playerSpawn)
	end
	PlayerService.spawnAll()
end

local function day(first: boolean, finale: boolean?)
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
	local t = WaveMath.dayLength(Config.Round, Config.Waves, wave, first)
	table.clear(dayVotes)
	for _, p in Players:GetPlayers() do
		p:SetAttribute("VotedDay", false)
	end
	countVotes()
	if wave == Config.MetroCamp.afterNight and not finale then
		-- завтра метро: напоминаем закупиться у лагеря у входа (VendorService показывает его этим днём)
		task.delay(3, function()
			notifyAll(Config.MetroCamp.message, 10)
		end)
	end
	if finale then
		-- финал акта 1: день без таймера и без следующей ночи — миссия «зайти в бункер», затем поздравление
		setPhase("Day", nil)
		ReplicatedStorage:SetAttribute("NextBriefTitle", "") -- панель «ближайшая ночь» не показываем
		MissionService.beginFinale()
		notifyAll("Day 20. The boss is down — enter the bunker as a team!", 7)
		while not gameOver and not MissionService.finaleReady() do
			task.wait(0.5)
		end
		if not gameOver then
			MissionService.finish()
			ReplicatedStorage:SetAttribute("ActComplete", 1)
			for _, p in Players:GetPlayers() do
				Remotes.get("Briefing"):FireClient(p, "Command", Config.Finale.Title, Config.Finale.Lines)
			end
			notifyAll(Config.Finale.Title .. " The next act is in development.", 12)
			task.wait(Config.Finale.EndSeconds)
			finaleDone = true
			gameOver = true
		end
		return
	end
	setPhase("Day", t)
	GeneralService.announceDay()
	for _, p in Players:GetPlayers() do
		applyDonate(p)
	end
	CutsceneService.playDay(wave + 1, first)
	notifyAll(if first then "Stock up at the shop and open buildings — invest coins at the signs" else "Dawn. The mutants burn in the sun — run to the shops!", 4)
	local warn = Config.Round.DayWarnSeconds
	local early = false
	if t > warn + 2 then
		early = waitDayVote(t - warn)
		if not gameOver and not early then
			notifyAll(string.format("Night falls in %d seconds and the shops will close. Anyone outside stays outside! (V — end the day)", warn), 4)
			early = waitDayVote(warn)
		end
	else
		early = waitDayVote(t)
	end
	if early and not gameOver then
		notifyAll("Everyone is ready — the day ends early", 3)
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

-- Следующая ночь — nightNumber: счётчик волны ставим на одну меньше (night() прибавит единицу), атрибут Wave нужен брифингу генерала;
-- если по номеру ночи нужна другая локация, она подгружается так же, как в начале дня
local function applyNextNight(nightNumber: number)
	wave = nightNumber - 1
	ReplicatedStorage:SetAttribute("Wave", wave)
	local want = locationFor(nightNumber)
	if want ~= locationIndex then
		loadLocation(want)
	end
end

local function night()
	wave += 1
	skipRequested = false
	ReplicatedStorage:SetAttribute("Wave", wave)
	BarricadeService.setOpen(false)
	BuildingService.closeShop() -- магазин на ночь закрыт, оставшихся внутри выталкивает на улицу
	if currentMap then
		PlayerService.setSpawn(currentMap.nightSpawn) -- ночью (воскрешение командой) появляемся в стартовом укрытии
	end
	local bossIds = WaveMath.bossTypes(Config.Waves, wave)
	-- финал (Config.Missions[20].day): бой днём — свет и небо дневные, но фаза остаётся «Night» (магазин закрыт, миссия идёт)
	local dayFight = (Config.Missions[wave] or { day = false }).day == true
	setNight(not dayFight, #bossIds > 0)
	setPhase("Night", nil)
	local nightLength = WaveMath.nightLength(Config.Round, wave)
	local nightStart = os.clock()
	local nightEndsAt = nightStart + nightLength
	local players = #Players:GetPlayers()
	local threat = WaveMath.makeThreat(Config.ThreatClasses, Config.Threat.Tiers, loadouts(), roundSeed)
	local comp = WaveMath.composition(Config.Waves, wave, players, threat)
	local aliveMinute = 1
	local missionDef = Config.Missions[wave]
	local aliveMul = if missionDef and missionDef.type == "escort" then (Config.Round.ConvoyAliveMul or 1) else 1 -- под колонну зомби больше
	ZombieService.setNightAliveCap(WaveMath.aliveCap(Config.Round, wave, players, threat, aliveMinute, aliveMul))
	ReplicatedStorage:SetAttribute("AliveCap", ZombieService.nightAliveCap())
	EconomyService.newWave()
	PlayerService.takeLosses()
	-- ночь, где босс выходит после bossAfterKills убийств (ночи 5, 10): боссов в начальную очередь не ставим — их выпустит MissionService
	local startComp = comp
	if missionDef and missionDef.bossAfterKills then
		startComp = {}
		for id, n in comp do
			if not WaveMath.isBossType(id) then
				startComp[id] = n
			end
		end
	end
	ZombieService.enqueue(WaveMath.spawnQueue(startComp, rng), WaveMath.hpMultiplier(Config.Waves, wave, threat), wave)
	print(string.format("[RoundService] night %d: players %d, zombies %d (alive at once up to %d, minute 1), threat %.1f (+%d alive per player), night %d s, weapons: %s", wave, players, WaveMath.total(comp), WaveMath.aliveCap(Config.Round, wave, players, threat), threat.score, threat.tier.alive, nightLength, table.concat(threat.classes, ",")))
	local bossName: string? = nil
	for _, bossId in WaveMath.bossTypes(Config.Waves, wave) do
		bossName = Config.Zombies[bossId].name
	end
	if bossName and not (missionDef and missionDef.bossAfterKills) then
		notifyAll(string.format("Boss incoming: %s!", bossName), 3)
	end
	-- миссия ночи (MissionService): точка, задача, поток зомби вокруг точки; ночь засчитана, когда задача выполнена и убит минимум зомби
	-- (classic/clear — когда убита вся волна и набран минимум; MissionService.update возвращает "done")
	MissionService.begin(wave, comp, WaveMath.hpMultiplier(Config.Waves, wave, threat), players)
	local missionDone = false
	while not gameOver do
		local left = ZombieService.remaining()
		ReplicatedStorage:SetAttribute("ZombiesLeft", left)
		-- с каждой минутой ночи предел живых растёт (давление на тех, кто тянет время)
		local minute = math.floor((os.clock() - nightStart) / 60) + 1
		if minute ~= aliveMinute then
			aliveMinute = minute
			ZombieService.setNightAliveCap(WaveMath.aliveCap(Config.Round, wave, players, threat, minute, aliveMul))
			ReplicatedStorage:SetAttribute("AliveCap", ZombieService.nightAliveCap())
		end
		local missionState = MissionService.update(0.25)
		if skipRequested then
			-- тестовый стенд: честно завершаем ночь, как будто миссия выполнена (награды и рейтинг ниже — как за пройденную)
			skipRequested = false
			missionDone = true
			break
		end
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
		-- награда за миссию (единственный доход монет): личная часть каждому + командная поровну (WaveMath.playerReward); стоящему на ногах — целиком,
		-- лежащему — DownedRewardFactor от неё; провал миссии — доля MissionFailShare; штраф за каждую потерю — доля того, что каждый заработал за волну
		local E = Config.Economy
		local everyone = Players:GetPlayers()
		local share = WaveMath.playerReward(E, wave, #everyone)
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
			local text = string.format("Wave %d cleared: +%d coins", wave, math.floor((gotBy[p] or 0) + 0.5))
			if fine > 0 then
				text ..= string.format(" (team penalty for losses −%d)", fine)
			end
			if p.Parent then
				Remotes.get("Notify"):FireClient(p, text, 5)
			end
		end
		if WaveMath.isBossWave(Config.Waves, wave) and cleared then
			PerkService.openOffers()
		end
		-- победа над финальным боссом (каркас): атрибут для будущих титров и награды, сообщение всем
		local finalDef = Config.Missions[wave]
		if finalDef and finalDef.type == "bossfight" and missionDone then
			ReplicatedStorage:SetAttribute("Victory", wave)
			finalePending = true
			notifyAll("VICTORY! The Bunker Guardian is down. One last step — the bunker!", 8)
		end
	end
	if pendingNight then
		local n = pendingNight
		pendingNight = nil
		applyNextNight(n)
	end
end

local function finishRound()
	ZombieService.clearAll()
	setPhase("GameOver", Config.Round.GameOverTime)
	if lobbyHooks then
		lobbyHooks.begin() -- экран итогов с кнопкой «Back to lobby»
	end
	-- ночь, на которой все пали, не засчитывается
	local reached = math.max(0, if fellAtNight then wave - 1 else wave)
	ReplicatedStorage:SetAttribute("LastRoundWave", reached)
	notifyAll(if finaleDone then "Act 1 complete! Round over" else string.format("Everyone has fallen. Nights survived: %d", reached), Config.Round.GameOverTime)
	-- через несколько секунд — итоги по очкам
	local bestPlayer, bestScore, bestKills = ScoreService.best()
	if bestPlayer then
		local team = (ReplicatedStorage:GetAttribute("TeamTotal") :: number?) or 0
		task.delay(4, function()
			notifyAll(
				string.format("Best: %s — %d points, %d kills. The team scored %d", bestPlayer.DisplayName, bestScore, bestKills, team),
				Config.Round.GameOverTime - 4
			)
		end)
	end
	-- сначала рекорд ночи в профиль: табло берёт лучшую ночь из него (иначе записывалась ночь прошлого раунда)
	for _, p in Players:GetPlayers() do
		DataService.recordRound(
			p,
			reached,
			(p:GetAttribute("RoundKills") :: number?) or 0,
			(p:GetAttribute("Revives") :: number?) or 0
		)
	end
	RatingService.finishRound(Players:GetPlayers(), reached)
	task.wait(Config.Round.GameOverTime)
end

-- Лобби (LobbyService): в конце раунда вместо нового раунда на этом же сервере — экран итогов и возврат в лобби
function RoundService.setLobbyHooks(begin: () -> (), after: () -> ())
	lobbyHooks = { begin = begin, after = after }
end

-- Тестовые стенды (только Studio, init.server): «Пропустить волну» — ночью завершает текущую ночь как выполненную, днём сразу начинает ночь
function RoundService.skip()
	local phase = ReplicatedStorage:GetAttribute("Phase")
	if phase == "Night" or phase == "Day" then
		skipRequested = true
	end
end

-- Тестовые стенды: «Выбор волны» — следующей будет ночь nightNumber (1…#Config.Missions). Днём — сразу; ночью — после конца текущей
-- (её награды считаются по её номеру, поэтому счётчик не трогаем). Вместе со «Пропустить волну» ночь можно сменить сразу.
function RoundService.setNextNight(nightNumber: number): boolean
	local phase = ReplicatedStorage:GetAttribute("Phase")
	if nightNumber % 1 ~= 0 or nightNumber < 1 or nightNumber > #Config.Missions then
		return false
	end
	if phase == "Day" then
		applyNextNight(nightNumber)
		return true
	elseif phase == "Night" then
		pendingNight = nightNumber
		return true
	end
	return false
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
			notifyAll("Extra life! The team gets back up", 4)
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
		-- убийства и хедшоты дают только очки (счёт раунда и рейтинг), монеты — только за миссии
		local head = zombie.headKill == true
		local bonusPoints = if head then math.floor(zombie.def.points * Config.Economy.HeadshotKillPointsBonus + 0.5) else 0
		if head then
			player:SetAttribute("Headshots", ((player:GetAttribute("Headshots") :: number?) or 0) + 1)
		end
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
			Remotes.get("Notify"):FireClient(player, "Night is on. You'll respawn at dawn", 4)
		end
	end)
	task.spawn(function()
		while true do
			intermission()
			startRound()
			local first = true
			while not gameOver do
				day(first, finalePending)
				finalePending = false
				first = false
				if gameOver then
					break
				end
				night()
			end
			finishRound()
			if lobbyHooks then
				lobbyHooks.after() -- ждёт возврата в лобби; вернулся — начинаем новый раунд на этом сервере
			end
		end
	end)
end

return RoundService
