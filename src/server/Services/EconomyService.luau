--!strict
-- Монеты: одна общая касса на всю команду (кто-то тратит — тратится у всех).
-- Каждому игроку зеркалим кассу в атрибут Coins (HUD читает его напрямую), общая сумма — ReplicatedStorage.TeamCoins.
-- Только сервер меняет монеты; клиент никогда не присылает суммы.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local EconomyService = {}

local team = Config.Player.StartCoins
local earnedThisWave = 0 -- заработано командой за текущую волну (для штрафа за потери)
local repairCoinsToday = 0

local function publish()
	ReplicatedStorage:SetAttribute("TeamCoins", math.floor(team))
	for _, p in Players:GetPlayers() do
		p:SetAttribute("Coins", math.floor(team))
	end
end

Players.PlayerAdded:Connect(function(p)
	p:SetAttribute("Coins", math.floor(team))
end)

function EconomyService.get(_player: Player?): number
	return math.floor(team)
end

-- Начислить в общую кассу (игрок указывается для совместимости и будущей статистики)
function EconomyService.add(_player: Player?, amount: number)
	if amount <= 0 then
		return
	end
	-- дробные монеты копятся в кассе (за убийство в толпе — доли монеты), на экране — целая часть
	team += amount
	earnedThisWave += amount
	publish()
end

function EconomyService.trySpend(_player: Player?, amount: number): boolean
	if math.floor(team) < amount then
		return false
	end
	team -= amount
	publish()
	return true
end

-- Награда за починку с дневным лимитом на команду (чтобы не фармили, ломая и чиня)
function EconomyService.addRepairReward(player: Player)
	if repairCoinsToday >= Config.Economy.MaxRepairCoinsPerDay then
		return
	end
	local amount = math.min(Config.Economy.CoinsPerPlankRepair, Config.Economy.MaxRepairCoinsPerDay - repairCoinsToday)
	repairCoinsToday += amount
	EconomyService.add(player, amount)
end

function EconomyService.newDay()
	repairCoinsToday = 0
end

-- Начало ночи: счётчик заработка волны с нуля
function EconomyService.newWave()
	earnedThisWave = 0
end

function EconomyService.earnedThisWave(): number
	return earnedThisWave
end

-- Штраф за потери: списывает долю заработанного за волну, но не больше, чем есть в кассе. Возвращает списанное.
function EconomyService.penalize(fraction: number): number
	local amount = math.min(math.floor(team), math.floor(earnedThisWave * math.clamp(fraction, 0, 1) + 0.5))
	if amount > 0 then
		team -= amount
		publish()
	end
	return amount
end

function EconomyService.resetRound(players: { Player })
	EconomyService.newDay()
	team = Config.Player.StartCoins
	earnedThisWave = 0
	publish()
	for _, p in players do
		p:SetAttribute("RoundKills", 0)
	end
end

function EconomyService.forget(_player: Player)
end

return EconomyService
