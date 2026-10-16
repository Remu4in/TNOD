--!strict
-- Оружие: выдача инструментов, покупка со стен, стрельба и перезарядка.
-- Клиент присылает только «выстрелил отсюда туда»; сервер проверяет и сам делает рейкаст и урон.

local AssetService = game:GetService("AssetService")
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

-- Шаблоны мешей оружия (AssetService грузит меш по сети, поэтому один раз и с ожиданием)
local meshTemplates: { [string]: MeshPart } = {}
local meshState: { [string]: string } = {} -- "loading" | "ok" | "failed"

local function loadMesh(meshId: string): MeshPart?
	if not meshState[meshId] then
		meshState[meshId] = "loading"
		local ok, result = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromUri(meshId))
		end)
		if ok and result then
			meshTemplates[meshId] = result
			meshState[meshId] = "ok"
		else
			warn("[WeaponService] не удалось загрузить меш " .. meshId .. ": " .. tostring(result))
			meshState[meshId] = "failed"
		end
	end
	while meshState[meshId] == "loading" do
		task.wait(0.1)
	end
	return meshTemplates[meshId]
end

-- Handle — невидимая рукоять 1×1×1; внешний вид — меши из Config.WeaponVisuals, привязанные Weld'ами.
-- Если меш не загрузился, остаётся простой цветной блок.
local function buildTool(def: Config.WeaponDef): Tool
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("WeaponId", def.id)
	tool:SetAttribute("Automatic", def.automatic)
	tool:SetAttribute("FireRate", def.fireRate)
	tool:SetAttribute("Melee", def.melee == true)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.one
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local built = 0
	local hold = Config.WeaponHold[def.id]
	local scale = if hold then hold.scale else 1
	for _, vp in Config.WeaponVisuals[def.id] or {} do
		local template = loadMesh(vp.mesh)
		if template then
			local part = template:Clone()
			part.Size = vp.size * scale
			part.TextureID = vp.texture or ""
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.Anchored = false
			local weld = Instance.new("Weld")
			weld.Part0 = handle
			weld.Part1 = part
			weld.C0 = vp.offset.Rotation + vp.offset.Position * scale
			weld.Parent = part
			part.Parent = tool
			built += 1
		end
	end
	if built == 0 then
		handle.Size = Vector3.new(0.4, 0.6, if def.id == "Pistol" then 1.2 else 2.6)
		handle.Color = def.color
		handle.Material = Enum.Material.Metal
	else
		handle.Transparency = 1
	end
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
	Remotes.get("ReloadFx"):FireAllClients(player, weaponId)
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
				local applied, killed = ZombieService.damage(model, dmg, player, {
					dir = dir,
					push = math.min(14, def.damage * 0.25), -- попадание чуть отбрасывает и на миг останавливает зомби
					stagger = 0.1,
				})
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
	Remotes.get("ShotFx"):FireAllClients(player, head.Position, hits, weaponId)
	syncAmmo(player, weaponId)
	if st.mag <= 0 then
		startReload(player, weaponId)
	end
end

-- Ближний бой: клиент присылает только направление взгляда; сектор, дальность, видимость и урон считает сервер.
local function onMelee(player: Player, direction: unknown)
	if typeof(direction) ~= "Vector3" then
		return
	end
	local d = direction :: Vector3
	if not isFiniteVector(d) or d.Magnitude < 0.5 or d.Magnitude > 1.5 then
		return
	end
	d = d.Unit
	if not PlayerService.isUp(player) then
		return
	end
	local weaponId = equippedWeapon(player)
	local inv = owned[player]
	if not weaponId or not inv or not inv[weaponId] then
		return
	end
	local def = Config.Weapons[weaponId]
	if not def.melee then
		return
	end
	local st = inv[weaponId]
	local now = os.clock()
	if now - st.lastShot < (1 / def.fireRate) * 0.8 or not RateLimit.allow(player, "Melee", 0.08) then
		return
	end
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	st.lastShot = now

	local origin = head.Position
	local halfArc = math.rad((def.arcDeg or 90) / 2)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	local zombiesFolder = workspace:FindFirstChild("Zombies")
	if zombiesFolder then
		table.insert(exclude, zombiesFolder)
	end
	params.FilterDescendantsInstances = exclude

	-- кандидаты: в радиусе, внутри сектора и без стены между игроком и зомби
	local candidates: { { model: Model, root: BasePart, dist: number } } = {}
	for _, z in ZombieService.queryNear(origin, def.range + 3) do
		local toZombie = z.root.Position - origin
		local dist = toZombie.Magnitude
		if dist > 0.01 and dist - 1.5 <= def.range then
			local angle = math.acos(math.clamp(d:Dot(toZombie.Unit), -1, 1))
			if angle <= halfArc and not workspace:Raycast(origin, toZombie, params) then
				table.insert(candidates, { model = z.model, root = z.root, dist = dist })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)

	local totalDamage = 0
	local killedAny = false
	local firstPos: Vector3? = nil
	for i = 1, math.min(#candidates, def.maxTargets or 1) do
		local c = candidates[i]
		local away = Vector3.new(c.root.Position.X - origin.X, 0, c.root.Position.Z - origin.Z)
		local applied, killed = ZombieService.damage(c.model, def.damage, player, {
			dir = away,
			push = def.knockback,
			stagger = 0.35,
		})
		if applied then
			totalDamage += def.damage
			killedAny = killedAny or killed
			firstPos = firstPos or c.root.Position
		end
	end
	if totalDamage > 0 then
		EconomyService.add(player, Config.Economy.CoinsPerHit)
		Remotes.get("HitFeedback"):FireClient(player, firstPos, totalDamage, killedAny, false)
	end
	Remotes.get("MeleeFx"):FireAllClients(player, weaponId)
end

local function onWallBuy(player: Player, weaponId: string)
	if not PlayerService.isUp(player) then
		return
	end
	if game:GetService("ReplicatedStorage"):GetAttribute("Phase") == "Night" then
		Remotes.get("Notify"):FireClient(player, "Магазин закрыт ночью", 1.5)
		return
	end
	local def = Config.Weapons[weaponId]
	local inv = owned[player]
	if inv and inv[weaponId] and def.melee then
		-- патроны не нужны: второй раз то же самое не покупаем
		Remotes.get("Notify"):FireClient(player, "Уже есть", 1.5)
		return
	end
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

-- Выдать оружие (покупка, награда, отладка); только из серверного кода
function WeaponService.give(player: Player, weaponId: string)
	if Config.Weapons[weaponId] then
		grant(player, weaponId)
	end
end

-- Новый раунд: у всех только пистолет
function WeaponService.resetRound(players: { Player })
	for _, p in players do
		owned[p] = {}
	end
end

-- Привязать стены с оружием новой локации; вызывается и при смене локации.
function WeaponService.setMap(map: Types.MapInfo)
	for _, wb in map.wallBuys do
		wb.prompt.Triggered:Connect(function(player: Player)
			onWallBuy(player, wb.weaponId)
		end)
	end
end

function WeaponService.init(map: Types.MapInfo)
	-- заранее подгружаем меши всех стволов, чтобы первая покупка не тормозила
	task.spawn(function()
		for _, parts in Config.WeaponVisuals do
			for _, vp in parts do
				loadMesh(vp.mesh)
			end
		end
	end)
	Remotes.get("Fire").OnServerEvent:Connect(onFire)
	Remotes.get("Melee").OnServerEvent:Connect(onMelee)
	Remotes.get("Reload").OnServerEvent:Connect(function(player: Player)
		if not RateLimit.allow(player, "Reload", 0.3) then
			return
		end
		local weaponId = equippedWeapon(player)
		if weaponId and owned[player] and owned[player][weaponId] then
			startReload(player, weaponId)
		end
	end)

	WeaponService.setMap(map)

	-- после (воз)рождения — выдать пистолет и всё купленное в этом раунде
	local function onCharacter(player: Player)
		task.defer(function()
			local inv = owned[player]
			if not inv then
				inv = {}
				owned[player] = inv
			end
			for _, weaponId in Config.StartWeapons do
				if not inv[weaponId] then
					grant(player, weaponId)
				end
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
