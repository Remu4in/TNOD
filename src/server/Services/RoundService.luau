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

local RoundService = {}

local wave = 0
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

local function waitPhase(seconds: number)
	local endsAt = os.clock() + seconds
	while os.clock() < endsAt and not gameOver do
		task.wait(0.25)
	end
end

local function intermission()
	ZombieService.clearAll()
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
	BarricadeService.repairAll()
	EconomyService.resetRound(players)
	WeaponService.resetRound(players)
	for _, p in players do
		p:SetAttribute("Revives", 0)
	end
	PlayerService.spawnAll()
end

local function day(first: boolean)
	EconomyService.newDay()
	PlayerService.respawnDead()
	setNight(false)
	local t = if first then Config.Round.FirstDayTime else Config.Round.DayTime
	setPhase("Day", t)
	notifyAll(if first then "Готовьтесь: покупайте оружие и держите окна" else "Рассвет. Чините баррикады!", 3)
	waitPhase(t)
end

local function night()
	wave += 1
	ReplicatedStorage:SetAttribute("Wave", wave)
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
		player:SetAttribute("RoundKills", ((player:GetAttribute("RoundKills") :: number?) or 0) + 1)
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
