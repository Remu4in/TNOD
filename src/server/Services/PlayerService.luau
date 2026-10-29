--!strict
-- Здоровье, падение и поднятие игроков, реген, возрождение между волнами.
-- Урон игрокам наносится только через PlayerService.damage на сервере.
-- HP кончилось → игрок падает (и в одиночной игре): лежит BleedOutTime секунд, товарищ может поднять (E), можно сдаться (GiveUp).
-- Раунд кончается, когда никто не стоит и никто не лежит (все погибли); жизнь команды поднимает всех, как только все упали.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Perks = require(Shared:WaitForChild("Perks"))
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))

local PlayerService = {}

local lastDamage: { [Player]: number } = {}
local bleedToken: { [Player]: number } = {}
local invulnUntil: { [Player]: number } = {}
local onAllDown: (() -> ())? = nil
local spawnPoint = Vector3.new(0, 3, 0)

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

function PlayerService.isUp(player: Player): boolean
	local h = humanoidOf(player)
	return h ~= nil and h.Health > 0 and not player:GetAttribute("Downed")
end

function PlayerService.upPlayers(): { Player }
	local list = {}
	for _, p in Players:GetPlayers() do
		if PlayerService.isUp(p) then
			table.insert(list, p)
		end
	end
	return list
end

function PlayerService.anyoneUp(): boolean
	return #PlayerService.upPlayers() > 0
end

local lostPlayers = 0 -- потерь за текущую волну: упал и не был поднят (истёк кровью)

function PlayerService.takeLosses(): number
	local n = lostPlayers
	lostPlayers = 0
	return n
end

local function clearDowned(player: Player)
	player:SetAttribute("Downed", false)
	player:SetAttribute("DownedUntil", nil)
	local char = player.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart")
		local prompt = root and root:FindFirstChild("RevivePrompt")
		if prompt then
			prompt:Destroy()
		end
	end
end

local function anyoneDowned(): boolean
	for _, p in Players:GetPlayers() do
		local h = humanoidOf(p)
		if h and h.Health > 0 and p:GetAttribute("Downed") == true then
			return true
		end
	end
	return false
end

-- Никто не стоит: при жизни команды — сразу (поднимет всех), иначе — когда лежащих не осталось (истекли кровью или сдались)
local function checkAllDown()
	if PlayerService.anyoneUp() or not onAllDown then
		return
	end
	local lives = (ReplicatedStorage:GetAttribute("TeamLives") :: number?) or 0
	if lives > 0 or not anyoneDowned() then
		(onAllDown :: () -> ())()
	end
end

-- Упавший погибает: истёк кровью или сдался (потеря для штрафа волны)
local function bleedOut(player: Player, h: Humanoid)
	bleedToken[player] = (bleedToken[player] or 0) + 1
	clearDowned(player)
	lostPlayers += 1
	h.Health = 0
end

local function down(player: Player, h: Humanoid)
	player:SetAttribute("Downed", true)
	player:SetAttribute("DownedUntil", workspace:GetServerTimeNow() + Config.Player.BleedOutTime) -- таймер на экране падения
	if h.SeatPart then
		h.Sit = false -- упавший не водит и не стреляет из машины
	end
	h.Health = 1
	h.WalkSpeed = Config.Player.DownedWalkSpeed
	h.JumpPower = 0
	local root = (player.Character :: Model):FindFirstChild("HumanoidRootPart")
	if root then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "RevivePrompt"
		prompt.ActionText = "Pick up"
		prompt.ObjectText = player.DisplayName
		prompt.HoldDuration = Config.Player.ReviveHoldTime * (1 - math.min(0.8, Perks.total("revive")))
		prompt.MaxActivationDistance = 7
		prompt.RequiresLineOfSight = false
		prompt.Parent = root
		prompt.Triggered:Connect(function(helper: Player)
			if helper == player or not PlayerService.isUp(helper) then
				return
			end
			if not player:GetAttribute("Downed") then
				return
			end
			clearDowned(player)
			h.Health = Config.Player.ReviveHealth
			h.WalkSpeed = Perks.walkSpeed()
			h.JumpPower = 50
			bleedToken[player] = (bleedToken[player] or 0) + 1
			helper:SetAttribute("Revives", ((helper:GetAttribute("Revives") :: number?) or 0) + 1)
			ScoreService.add(helper, Config.Score.Revive)
		end)
	end
	-- истечение кровью
	local token = (bleedToken[player] or 0) + 1
	bleedToken[player] = token
	task.delay(Config.Player.BleedOutTime, function()
		if bleedToken[player] == token and player:GetAttribute("Downed") then
			bleedOut(player, h)
		end
	end)
	checkAllDown()
end

-- Неуязвимость (кувырок): до этого момента по серверным часам урон по игроку не проходит
function PlayerService.setInvulnerable(player: Player, seconds: number)
	invulnUntil[player] = os.clock() + seconds
end

function PlayerService.isInvulnerable(player: Player): boolean
	return os.clock() < (invulnUntil[player] or 0)
end

-- Эффекты от атак боссов. Конец эффекта пишется в атрибут игрока по серверному времени (GetServerTimeNow): клиент (MovementController, StatusController)
-- по нему гасит скорость, показывает значок и не даёт бежать, а сервер проверяет сам (стрельба и ближний бой — isStunned в WeaponService, спринт — StaminaService).
-- Кувырок (неуязвимость) защищает от всех трёх так же, как от урона. true — эффект наложен.
local function statusFree(player: Player): boolean
	return PlayerService.isUp(player) and not PlayerService.isInvulnerable(player)
end

-- Оглушение: нельзя двигаться и стрелять
function PlayerService.stun(player: Player, seconds: number): boolean
	if not statusFree(player) then
		return false
	end
	local untilT = workspace:GetServerTimeNow() + seconds
	if untilT > ((player:GetAttribute("StunUntil") :: number?) or 0) then
		player:SetAttribute("StunUntil", untilT)
	end
	local h = humanoidOf(player)
	if h then
		h.WalkSpeed = 0
		h.JumpPower = 0
		task.delay(seconds + 0.05, function()
			if workspace:GetServerTimeNow() >= ((player:GetAttribute("StunUntil") :: number?) or 0) and PlayerService.isUp(player) then
				h.WalkSpeed = if player:GetAttribute("Sprinting") == true then Perks.sprintSpeed() else Perks.walkSpeed()
				h.JumpPower = 50
			end
		end)
	end
	return true
end

function PlayerService.isStunned(player: Player): boolean
	return workspace:GetServerTimeNow() < ((player:GetAttribute("StunUntil") :: number?) or 0)
end

-- Замедление: скорость умножается на mult (0..1) на seconds
function PlayerService.slow(player: Player, mult: number, seconds: number): boolean
	if not statusFree(player) then
		return false
	end
	local untilT = workspace:GetServerTimeNow() + seconds
	if untilT > ((player:GetAttribute("SlowUntil") :: number?) or 0) then
		player:SetAttribute("SlowUntil", untilT)
	end
	player:SetAttribute("SlowMult", mult)
	return true
end

-- Запрет бега: спринт и энергия отключены (StaminaService читает атрибут)
function PlayerService.noSprint(player: Player, seconds: number): boolean
	if not statusFree(player) then
		return false
	end
	local untilT = workspace:GetServerTimeNow() + seconds
	if untilT > ((player:GetAttribute("NoSprintUntil") :: number?) or 0) then
		player:SetAttribute("NoSprintUntil", untilT)
	end
	return true
end

function PlayerService.damage(player: Player, amount: number)
	if not PlayerService.isUp(player) or PlayerService.isInvulnerable(player) then
		return
	end
	local h = humanoidOf(player)
	if not h then
		return
	end
	lastDamage[player] = os.clock()
	if h.Health - amount <= 0 then
		down(player, h)
	else
		h.Health -= amount
	end
end

function PlayerService.spawn(player: Player)
	clearDowned(player)
	player:LoadCharacterAsync()
end

-- Возродить всех, у кого нет живого персонажа (начало дня)
function PlayerService.respawnDead()
	for _, p in Players:GetPlayers() do
		local h = humanoidOf(p)
		if not h or h.Health <= 0 then
			PlayerService.spawn(p)
		elseif p:GetAttribute("Downed") then
			-- упавших в конце волны поднимаем автоматически
			clearDowned(p)
			h.Health = Config.Player.ReviveHealth
			h.WalkSpeed = Perks.walkSpeed()
			h.JumpPower = 50
		end
	end
end

-- Дополнительная жизнь команды: погибшие возрождаются, упавшие поднимаются
function PlayerService.reviveAll()
	for _, p in Players:GetPlayers() do
		local h = humanoidOf(p)
		if not h or h.Health <= 0 then
			task.spawn(PlayerService.spawn, p)
		elseif p:GetAttribute("Downed") then
			clearDowned(p)
			bleedToken[p] = (bleedToken[p] or 0) + 1
			h.Health = Config.Player.ReviveHealth
			h.WalkSpeed = Perks.walkSpeed()
			h.JumpPower = 50
		end
	end
end

function PlayerService.spawnAll()
	for _, p in Players:GetPlayers() do
		PlayerService.spawn(p)
	end
end

function PlayerService.setSpawn(spawnAt: Vector3)
	spawnPoint = spawnAt
end

function PlayerService.init(spawnAt: Vector3, allDownCallback: () -> ())
	spawnPoint = spawnAt
	onAllDown = allDownCallback
	Players.CharacterAutoLoads = false

	local function onCharacter(player: Player, char: Model)
		local h = char:WaitForChild("Humanoid") :: Humanoid
		local maxHealth = Config.Player.MaxHealth + Perks.total("health")
		h.MaxHealth = maxHealth
		h.Health = maxHealth
		h.WalkSpeed = Perks.walkSpeed()
		h.BreakJointsOnDeath = false
		char:PivotTo(CFrame.new(spawnPoint + Vector3.new(math.random(-6, 6), 0, math.random(-4, 4))))
		-- встроенный реген отключаем: свой, с задержкой после урона
		local regen = char:FindFirstChild("Health")
		if regen then
			regen:Destroy()
		end
		h.Died:Connect(function()
			clearDowned(player)
			checkAllDown()
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			onCharacter(player, char)
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(char)
			onCharacter(player, char)
		end)
	end
	-- сдаться: только упавший, сам за себя
	Remotes.get("GiveUp").OnServerEvent:Connect(function(player: Player)
		if not RateLimit.allow(player, "GiveUp", 1) or player:GetAttribute("Downed") ~= true then
			return
		end
		local h = humanoidOf(player)
		if h and h.Health > 0 then
			bleedOut(player, h)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastDamage[player] = nil
		bleedToken[player] = nil
		invulnUntil[player] = nil
		task.defer(checkAllDown)
	end)

	-- свой реген
	task.spawn(function()
		while true do
			local dt = task.wait(0.5)
			for _, p in Players:GetPlayers() do
				local h = humanoidOf(p)
				if h and PlayerService.isUp(p) and h.Health < h.MaxHealth then
					if os.clock() - (lastDamage[p] or 0) >= Config.Player.RegenDelay then
						h.Health = math.min(h.MaxHealth, h.Health + Config.Player.RegenPerSecond * dt)
					end
				end
			end
		end
	end)
end

return PlayerService
