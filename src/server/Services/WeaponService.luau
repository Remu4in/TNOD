--!strict
-- Оружие: выдача инструментов, покупка со стен, стрельба и перезарядка.
-- Клиент присылает только «выстрелил отсюда туда»; сервер проверяет и сам делает рейкаст и урон.

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local WeaponService = {}

type WeaponState = { mag: number, reserve: number, lastShot: number, reloadingUntil: number }

local owned: { [Player]: { [string]: WeaponState } } = {}
local rng = Random.new()

local MAX_ORIGIN_OFFSET = 8 -- насколько точка выстрела может отличаться от головы (лаг, камера)

local function isFiniteVector(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

local function buildTool(def: Config.WeaponDef): Tool
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("WeaponId", def.id)
	tool:SetAttribute("Automatic", def.automatic)
	tool:SetAttribute("FireRate", def.fireRate)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.6, if def.id == "Pistol" then 1.2 else 2.6)
	handle.Color = def.color
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	tool.Grip = CFrame.new(0, -0.1, 0.3)
	return tool
end

local function syncAmmo(player: Player, weaponId: string)
	local st = owned[player] and owned[player][weaponId]
	if not st then
		return
	end
	local function update(container: Instance?)
		if not container then
			return
		end
		for _, t in container:GetChildren() do
			if t:IsA("Tool") and t:GetAttribute("WeaponId") == weaponId then
				t:SetAttribute("Mag", st.mag)
				t:SetAttribute("Reserve", st.reserve)
			end
		end
	end
	update(player:FindFirstChildOfClass("Backpack"))
	update(player.Character)
end

local function giveTool(player: Player, weaponId: string)
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if not backpack then
		return
	end
	local function has(container: Instance?): boolean
		if not container then
			return false
		end
		for _, t in container:GetChildren() do
			if t:IsA("Tool") and t:GetAttribute("WeaponId") == weaponId then
				return true
			end
		end
		return false
	end
	if not has(backpack) and not has(player.Character) then
		buildTool(Config.Weapons[weaponId]).Parent = backpack
	end
	syncAmmo(player, weaponId)
end

local function grant(player: Player, weaponId: string)
	local def = Config.Weapons[weaponId]
	local inv = owned[player]
	if not inv then
		inv = {}
		owned[player] = inv
	end
	inv[weaponId] = { mag = def.magSize, reserve = def.reserve, lastShot = 0, reloadingUntil = 0 }
	giveTool(player, weaponId)
end

local function equippedWeapon(player: Player): (string?, Tool?)
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return nil, nil
	end
	local id = tool:GetAttribute("WeaponId")
	if typeof(id) ~= "string" or not Config.Weapons[id] then
		return nil, nil
	end
	return id, tool
end

local function startReload(player: Player, weaponId: string)
	local def = Config.Weapons[weaponId]
	local st = owned[player][weaponId]
	if st.mag >= def.magSize or st.reserve == 0 or os.clock() < st.reloadingUntil then
		return
	end
	st.reloadingUntil = os.clock() + def.reloadTime
	task.delay(def.reloadTime, function()
		local inv = owned[player]
		if not inv or inv[weaponId] ~= st then
			return
		end
		local need = def.magSize - st.mag
		if st.reserve < 0 then
			st.mag = def.magSize
		else
			local take = math.min(need, st.reserve)
			st.mag += take
			st.reserve -= take
		end
		syncAmmo(player, weaponId)
	end)
end

local function onFire(player: Player, origin: unknown, direction: unknown)
	-- 1. типы и конечность
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	local o = origin :: Vector3
	local d = direction :: Vector3
	if not isFiniteVector(o) or not isFiniteVector(d) or d.Magnitude < 0.5 or d.Magnitude > 1.5 then
		return
	end
	d = d.Unit
	-- 2. состояние игрока и оружия
	if not PlayerService.isUp(player) then
		return
	end
	local weaponId = equippedWeapon(player)
	local inv = owned[player]
	if not weaponId or not inv or not inv[weaponId] then
		return
	end
	local def = Config.Weapons[weaponId]
	local st = inv[weaponId]
	local now = os.clock()
	if now < st.reloadingUntil then
		return
	end
	-- 3. темп стрельбы (с запасом на джиттер сети)
	if now - st.lastShot < (1 / def.fireRate) * 0.8 then
		return
	end
	if not RateLimit.allow(player, "Fire", 0.05) then
		return
	end
	-- 4. точка выстрела рядом с головой
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not head or (head.Position - o).Magnitude > MAX_ORIGIN_OFFSET then
		return
	end
	if st.mag <= 0 then
		startReload(player, weaponId)
		return
	end
	st.lastShot = now
	st.mag -= 1

	-- 5. рейкаст на сервере, без попаданий по игрокам
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude

	local hits: { Vector3 } = {}
	local totalDamage = 0
	local killedAny = false
	local headshotAny = false
	local lastHitPos: Vector3? = nil
	for _ = 1, def.pellets do
		local spread = math.rad(def.spreadDeg)
		local dir = (CFrame.lookAt(Vector3.zero, d) * CFrame.Angles(rng:NextNumber(-spread, spread), rng:NextNumber(-spread, spread), 0)).LookVector
		local result = workspace:Raycast(head.Position, dir * def.range, params)
		if result then
			table.insert(hits, result.Position)
			local model, isHead = ZombieService.isZombiePart(result.Instance :: BasePart)
			if model then
				local dmg = def.damage * (if isHead then Config.Economy.HeadshotMultiplier else 1)
				local applied, killed = ZombieService.damage(model, dmg, player)
				if applied then
					totalDamage += dmg
					killedAny = killedAny or killed
					headshotAny = headshotAny or isHead
					lastHitPos = result.Position
				end
			end
		else
			table.insert(hits, head.Position + dir * def.range)
		end
	end
	if totalDamage > 0 then
		EconomyService.add(player, Config.Economy.CoinsPerHit)
		Remotes.get("HitFeedback"):FireClient(player, lastHitPos, math.floor(totalDamage + 0.5), killedAny, headshotAny)
	end
	Remotes.get("ShotFx"):FireAllClients(player, head.Position, hits)
	syncAmmo(player, weaponId)
	if st.mag <= 0 then
		startReload(player, weaponId)
	end
end

local function onWallBuy(player: Player, weaponId: string)
	if not PlayerService.isUp(player) then
		return
	end
	local def = Config.Weapons[weaponId]
	local inv = owned[player]
	if inv and inv[weaponId] then
		-- уже есть — пополнение патронов за часть цены
		local price = math.floor(def.price * Config.Economy.RefillPriceFactor)
		if EconomyService.trySpend(player, price) then
			grant(player, weaponId)
			Remotes.get("Notify"):FireClient(player, "Патроны пополнены", 1.5)
		else
			Remotes.get("Notify"):FireClient(player, "Не хватает монет", 1.5)
		end
		return
	end
	if EconomyService.trySpend(player, def.price) then
		grant(player, weaponId)
		Remotes.get("Notify"):FireClient(player, "Куплено: " .. def.name, 1.5)
	else
		Remotes.get("Notify"):FireClient(player, "Не хватает монет", 1.5)
	end
end

-- Новый раунд: у всех только пистолет
function WeaponService.resetRound(players: { Player })
	for _, p in players do
		owned[p] = {}
	end
end

function WeaponService.init(map: Types.MapInfo)
	Remotes.get("Fire").OnServerEvent:Connect(onFire)
	Remotes.get("Reload").OnServerEvent:Connect(function(player: Player)
		if not RateLimit.allow(player, "Reload", 0.3) then
			return
		end
		local weaponId = equippedWeapon(player)
		if weaponId and owned[player] and owned[player][weaponId] then
			startReload(player, weaponId)
		end
	end)

	for _, wb in map.wallBuys do
		wb.prompt.Triggered:Connect(function(player: Player)
			onWallBuy(player, wb.weaponId)
		end)
	end

	-- после (воз)рождения — выдать пистолет и всё купленное в этом раунде
	local function onCharacter(player: Player)
		task.defer(function()
			local inv = owned[player]
			if not inv then
				inv = {}
				owned[player] = inv
			end
			if not inv.Pistol then
				grant(player, "Pistol")
			end
			for weaponId in inv do
				giveTool(player, weaponId)
			end
		end)
	end
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			onCharacter(player)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
		RateLimit.forget(player)
	end)
end

return WeaponService
