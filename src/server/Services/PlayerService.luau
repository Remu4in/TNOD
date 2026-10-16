--!strict
-- Здоровье, падение и поднятие игроков, реген, возрождение между волнами.
-- Урон игрокам наносится только через PlayerService.damage на сервере.

local Players = game:GetService("Players")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
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

local function clearDowned(player: Player)
	player:SetAttribute("Downed", false)
	local char = player.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart")
		local prompt = root and root:FindFirstChild("RevivePrompt")
		if prompt then
			prompt:Destroy()
		end
	end
end

local function checkAllDown()
	if not PlayerService.anyoneUp() and onAllDown then
		(onAllDown :: () -> ())()
	end
end

local function down(player: Player, h: Humanoid)
	player:SetAttribute("Downed", true)
	h.Health = 1
	h.WalkSpeed = Config.Player.DownedWalkSpeed
	h.JumpPower = 0
	local root = (player.Character :: Model):FindFirstChild("HumanoidRootPart")
	if root then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "RevivePrompt"
		prompt.ActionText = "Поднять"
		prompt.ObjectText = player.DisplayName
		prompt.HoldDuration = Config.Player.ReviveHoldTime
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
			h.WalkSpeed = Config.Player.WalkSpeed
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
			clearDowned(player)
			h.Health = 0
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
		-- в одиночной игре сразу конец: поднимать некому
		if #Players:GetPlayers() <= 1 then
			h.Health = 0
			checkAllDown()
		else
			down(player, h)
		end
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
			h.WalkSpeed = Config.Player.WalkSpeed
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
			h.WalkSpeed = Config.Player.WalkSpeed
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
		h.MaxHealth = Config.Player.MaxHealth
		h.Health = Config.Player.MaxHealth
		h.WalkSpeed = Config.Player.WalkSpeed
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
