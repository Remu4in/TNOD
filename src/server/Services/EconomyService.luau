--!strict
-- Монеты раунда (атрибут Coins у игрока — HUD читает его напрямую).
-- Только сервер меняет монеты; клиент никогда не присылает суммы.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local EconomyService = {}

local repairCoinsToday: { [Player]: number } = {}

function EconomyService.get(player: Player): number
	return (player:GetAttribute("Coins") :: number?) or 0
end

function EconomyService.add(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	player:SetAttribute("Coins", EconomyService.get(player) + math.floor(amount))
end

function EconomyService.trySpend(player: Player, amount: number): boolean
	local coins = EconomyService.get(player)
	if coins < amount then
		return false
	end
	player:SetAttribute("Coins", coins - amount)
	return true
end

-- Награда за починку с дневным лимитом (чтобы не фармили, ломая и чиня)
function EconomyService.addRepairReward(player: Player)
	local got = repairCoinsToday[player] or 0
	if got >= Config.Economy.MaxRepairCoinsPerDay then
		return
	end
	local amount = math.min(Config.Economy.CoinsPerPlankRepair, Config.Economy.MaxRepairCoinsPerDay - got)
	repairCoinsToday[player] = got + amount
	EconomyService.add(player, amount)
end

function EconomyService.newDay()
	table.clear(repairCoinsToday)
end

function EconomyService.resetRound(players: { Player })
	EconomyService.newDay()
	for _, p in players do
		p:SetAttribute("Coins", Config.Player.StartCoins)
		p:SetAttribute("RoundKills", 0)
	end
end

function EconomyService.forget(player: Player)
	repairCoinsToday[player] = nil
end

return EconomyService
