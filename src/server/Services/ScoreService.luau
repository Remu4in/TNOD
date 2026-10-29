--!strict
-- Счёт раунда: личные очки каждого игрока и общий командный счёт.
-- Игрок: атрибут Score (очки), RoundKills (убийства); в таблице игроков Roblox (leaderstats) — «Убийства» и «Очки».
-- Команда: атрибут ReplicatedStorage.TeamPoints — копилка команды (на неё позже открываем здания).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ScoreService = {}

local function stat(player: Player, name: string): IntValue?
	local folder = player:FindFirstChild("leaderstats")
	return folder and folder:FindFirstChild(name) :: IntValue?
end

local function setupPlayer(player: Player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	for _, name in { "Kills", "Score" } do
		local v = Instance.new("IntValue")
		v.Name = name
		v.Value = 0
		v.Parent = folder
	end
	folder.Parent = player
	player:SetAttribute("Score", 0)
	player:SetAttribute("RoundKills", 0)
end

local function refresh(player: Player)
	local kills = stat(player, "Kills")
	local points = stat(player, "Score")
	if kills then
		kills.Value = (player:GetAttribute("RoundKills") :: number?) or 0
	end
	if points then
		points.Value = (player:GetAttribute("Score") :: number?) or 0
	end
end

function ScoreService.init()
	ReplicatedStorage:SetAttribute("TeamPoints", 0)
	ReplicatedStorage:SetAttribute("TeamTotal", 0)
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
	Players.PlayerAdded:Connect(setupPlayer)
end

-- Начислить очки игроку и в командную копилку
function ScoreService.add(player: Player, points: number)
	if points <= 0 then
		return
	end
	player:SetAttribute("Score", ((player:GetAttribute("Score") :: number?) or 0) + points)
	ReplicatedStorage:SetAttribute("TeamPoints", ((ReplicatedStorage:GetAttribute("TeamPoints") :: number?) or 0) + points)
	ReplicatedStorage:SetAttribute("TeamTotal", ((ReplicatedStorage:GetAttribute("TeamTotal") :: number?) or 0) + points)
	refresh(player)
end

-- Убийство зомби: счётчик убийств + очки
function ScoreService.recordKill(player: Player, points: number)
	player:SetAttribute("RoundKills", ((player:GetAttribute("RoundKills") :: number?) or 0) + 1)
	ScoreService.add(player, points)
	refresh(player)
end

-- Потратить командные очки (разблокировка зданий, этап 2). true — если хватило.
function ScoreService.spendTeam(amount: number): boolean
	local have = (ReplicatedStorage:GetAttribute("TeamPoints") :: number?) or 0
	if have < amount then
		return false
	end
	ReplicatedStorage:SetAttribute("TeamPoints", have - amount)
	return true
end

-- Новый раунд: всё с нуля
function ScoreService.resetRound(players: { Player })
	ReplicatedStorage:SetAttribute("TeamPoints", 0)
	ReplicatedStorage:SetAttribute("TeamTotal", 0)
	for _, p in players do
		p:SetAttribute("Score", 0)
		p:SetAttribute("RoundKills", 0)
		refresh(p)
	end
end

-- Лучший игрок раунда (для итоговой надписи)
function ScoreService.best(): (Player?, number, number)
	local bestPlayer: Player? = nil
	local bestScore = -1
	for _, p in Players:GetPlayers() do
		local score = (p:GetAttribute("Score") :: number?) or 0
		if score > bestScore then
			bestPlayer, bestScore = p, score
		end
	end
	local kills = if bestPlayer then ((bestPlayer:GetAttribute("RoundKills") :: number?) or 0) else 0
	return bestPlayer, math.max(0, bestScore), kills
end

return ScoreService
