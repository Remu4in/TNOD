--!strict
-- Конечный автомат раунда: Перерыв → (День → Ночь)×N → Конец.
-- Состояние для клиентов — атрибуты ReplicatedStorage: Phase, Wave, PhaseEndsAt, ZombiesLeft.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local BarricadeService = require(script.Parent:WaitForChild("BarricadeService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))
local DataService = require(script.Parent:WaitForChild("DataService"))
local MapBuilder = require(script.Parent:WaitForChild("MapBuilder"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))

local RoundService = {}

local wave = 0
local locationIndex = 1 -- init.server строит первую локацию из Config.Locations
local gameOver = false
local fellAtNight = false
local rng = Random.new()

local function setPhase(phase: string, duration: number?)
	ReplicatedStorage:SetAttribute("Phase", phase)
	ReplicatedStorage:SetAttribute("PhaseEndsAt", if duration then workspace:GetServerTimeNow() + duration else 0)
end

local function notifyAll(text: string, seconds: number)
	Remotes.get("Notify"):FireAllClients(text, seconds)
end

local function setNight(night: boolean)
	Lighting.ClockTime = if night then 0 else 17.5
	Lighting.Brightness = if night then 0.5 else 2
	Lighting.OutdoorAmbient = if night then Color3.fromRGB(40, 45, 70) else Color3.fromRGB(130, 120, 110)
	Lighting.FogEnd = if night then 160 else 600
	Lighting.FogColor = if night then Color3.fromRGB(15, 18, 30) else Color3.fromRGB(190, 170, 150)
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
	setNight(false)
	ReplicatedStorage:SetAttribute("Wave", 0)
	ReplicatedStorage:SetAttribute("ZombiesLeft", 0)
	while #Players:GetPlayers() == 0 do
		task.wait(1)
	end
	setPhase("Intermission", Config.Round.IntermissionTime)
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
	EconomyService.resetRound(players)
	ScoreService.resetRound(players)
	WeaponService.resetRound(players)
	for _, p in players do
		p:SetAttribute("Revives", 0)
	end
	PlayerService.spawnAll()
end

local function day(first: boolean)
	local want = locationFor(wave + 1)
	if want ~= locationIndex then
		loadLocation(want)
	end
	EconomyService.newDay()
	PlayerService.respawnDead()
	setNight(false)
	BarricadeService.setOpen(true)
	local t = if first then Config.Round.FirstDayTime else Config.Round.DayTime
	setPhase("Day", t)
	notifyAll(if first then "Закупайтесь в доме и займите точки обороны" else "Рассвет. Баррикады убраны — бегите за покупками!", 4)
	local warn = Config.Round.DayWarnSeconds
	if t > warn + 2 then
		waitPhase(t - warn)
		if not gameOver then
			notifyAll(string.format("Через %d секунд баррикады встанут. Кто снаружи — останется снаружи!", warn), 4)
		end
		waitPhase(warn)
	else
		waitPhase(t)
	end
end

local function night()
	wave += 1
	ReplicatedStorage:SetAttribute("Wave", wave)
	BarricadeService.setOpen(false)
	setNight(true)
	setPhase("Night", nil)
	local players = #Players:GetPlayers()
	local comp = WaveMath.composition(Config.Waves, wave, players)
	ZombieService.enqueue(WaveMath.spawnQueue(comp, rng), WaveMath.hpMultiplier(Config.Waves, wave))
	notifyAll(if comp.Brute > 0 then string.format("Ночь %d. Идёт Громила!", wave) else string.format("Ночь %d", wave), 3)
	while not gameOver do
		local left = ZombieService.remaining()
		ReplicatedStorage:SetAttribute("ZombiesLeft", left)
		if left == 0 then
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
		fellAtNight = phase == "Night"
		gameOver = true
	end
end

function RoundService.onZombieKilled(player: Player?, zombie: any)
	if player then
		EconomyService.add(player, zombie.def.reward)
		ScoreService.recordKill(player, zombie.def.points)
	end
end

function RoundService.start()
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
