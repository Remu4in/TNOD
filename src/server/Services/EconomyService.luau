--!strict
-- Монеты: у каждого игрока свой счёт (атрибут Coins, HUD читает его напрямую). Покупки — со своего счёта;
-- на здания игроки скидываются у вывески (BuildingService). Награда за волну делится поровну между игроками.
-- Только сервер меняет монеты; клиент никогда не присылает суммы.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local EconomyService = {}

type Wallet = { coins: number, earnedThisWave: number }

local wallets: { [Player]: Wallet } = {}
-- счёт ушедшего игрока до конца раунда: перезаход не даёт стартовые монеты заново и не сжигает накопленное
local parked: { [number]: Wallet } = {}
local repairCoinsToday = 0 -- лимит на ремонт — на всю команду (чтобы не фармили, ломая и чиня)

local function walletOf(player: Player): Wallet
	local w = wallets[player]
	if not w then
		w = parked[player.UserId] or { coins = Config.Player.StartCoins, earnedThisWave = 0 }
		parked[player.UserId] = nil
		wallets[player] = w
	end
	return w
end

local function publish(player: Player)
	local w = wallets[player]
	if w and player.Parent then
		-- дробные монеты копятся на счёте (за убийство в толпе — доли монеты), на экране — целая часть
		player:SetAttribute("Coins", math.floor(w.coins))
	end
end

Players.PlayerAdded:Connect(function(p)
	walletOf(p)
	publish(p)
end)
for _, p in Players:GetPlayers() do
	walletOf(p)
	publish(p)
end
Players.PlayerRemoving:Connect(function(p)
	local w = wallets[p]
	if w then
		parked[p.UserId] = w
		wallets[p] = nil
	end
end)

function EconomyService.get(player: Player): number
	return math.floor(walletOf(player).coins)
end

-- Начислить игроку (без игрока — некому: такие начисления делятся через addEach)
function EconomyService.add(player: Player?, amount: number)
	if not player or amount <= 0 then
		return
	end
	local w = walletOf(player)
	w.coins += amount
	w.earnedThisWave += amount
	publish(player)
end

-- Начислить каждому из списка (награда за волну)
function EconomyService.addEach(players: { Player }, amount: number)
	for _, p in players do
		EconomyService.add(p, amount)
	end
end

function EconomyService.trySpend(player: Player, amount: number): boolean
	local w = walletOf(player)
	if math.floor(w.coins) < amount then
		return false
	end
	w.coins -= amount
	publish(player)
	return true
end

-- Награда за починку: тому, кто чинит, с дневным лимитом на команду
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

-- Начало ночи: счётчики заработка волны с нуля
function EconomyService.newWave()
	for _, w in wallets do
		w.earnedThisWave = 0
	end
	for _, w in parked do
		w.earnedThisWave = 0
	end
end

-- Штраф за потери: каждый игрок теряет долю того, что сам заработал за волну (не больше, чем у него есть).
-- Возвращает сумму списанного со всех.
function EconomyService.penalize(fraction: number): number
	local total = 0
	for p, w in wallets do
		local amount = math.min(math.floor(w.coins), math.floor(w.earnedThisWave * math.clamp(fraction, 0, 1) + 0.5))
		if amount > 0 then
			w.coins -= amount
			total += amount
			publish(p)
		end
	end
	return total
end

-- VIP: стартовые монеты больше (только если игрок ещё ничего не заработал и не потратил на этом счёте)
function EconomyService.applyStartCoins(player: Player, coins: number)
	local w = walletOf(player)
	if w.coins == Config.Player.StartCoins then
		w.coins = coins
		publish(player)
	end
end

function EconomyService.resetRound(players: { Player })
	EconomyService.newDay()
	table.clear(parked)
	for p in wallets do
		wallets[p] = { coins = Config.Player.StartCoins, earnedThisWave = 0 }
		publish(p)
	end
	for _, p in players do
		walletOf(p)
		publish(p)
		p:SetAttribute("RoundKills", 0)
	end
end

function EconomyService.forget(_player: Player)
end

return EconomyService
