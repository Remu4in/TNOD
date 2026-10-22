--!strict
-- Оружие: выдача инструментов, покупка со стен, стрельба и перезарядка.
-- Клиент присылает только «выстрелил отсюда туда»; сервер проверяет и сам делает рейкаст и урон.

local AssetService = game:GetService("AssetService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Perks = require(Shared:WaitForChild("Perks"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local MeleeAnim = require(Shared:WaitForChild("MeleeAnim"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))

local WeaponService = {}

type WeaponState = { mag: number, reserve: number, lastShot: number, reloadingUntil: number, burst: number }

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

-- Готовая модель из библиотеки ServerStorage.Assets.Weapons.<ref> (запечена tools/WeaponBaker; сети не требует)
local function libraryModel(ref: string): Model?
	local node: Instance? = ServerStorage:FindFirstChild("Assets")
	for _, name in string.split("Weapons/" .. ref, "/") do
		node = if node then node:FindFirstChild(name) else nil
	end
	return if node and node:IsA("Model") then node else nil
end

-- Детали модели библиотеки → в Tool, привязаны к Handle (начало координат модели = хват, дуло в -Z).
-- Масштаб = нужная длина / длина модели. Возвращает число добавленных деталей.
local function addLibraryParts(tool: Tool, handle: BasePart, def: Config.WeaponModelDef): number
	local model = libraryModel(def.ref)
	if not model then
		return 0
	end
	local natural = model:GetAttribute("Length")
	local scale = if typeof(natural) == "number" and natural > 0 then def.length / natural else 1
	local shift = CFrame.new((def.grip or Vector3.zero)) * (def.rot or CFrame.identity)
	local added = 0
	for _, src in model:GetChildren() do
		if src:IsA("MeshPart") then
			local part = src:Clone()
			part.Size = src.Size * scale
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			local weld = Instance.new("Weld")
			weld.Part0 = handle
			weld.Part1 = part
			weld.C0 = shift * (src.CFrame.Rotation + src.Position * scale)
			weld.Parent = part
			part.Parent = tool
			added += 1
		end
	end
	if added > 0 then
		tool:SetAttribute("ModelRef", def.ref)
	end
	return added
end

-- Handle — невидимая рукоять 1×1×1; внешний вид — модель из библиотеки (Config.WeaponModels) или меши
-- из Config.WeaponVisuals, привязанные Weld'ами. Если ничего не получилось, остаётся простой цветной блок.
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
	local modelDef = Config.WeaponModels[def.id]
	if modelDef then
		built = addLibraryParts(tool, handle, modelDef)
	end
	local hold = Config.WeaponHold[def.id]
	local scale = if hold then hold.scale else 1
	local visuals: { Config.VisualPart } = if built == 0 then (Config.WeaponVisuals[def.id] or {}) else {}
	for _, vp in visuals do
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
	if def.melee then
		-- хват: остриё вперёд-вверх от кисти (MeleeHold), взмахи и осмотр двигают Grip относительно него
		local hold = Config.MeleeHold[def.id] or Config.MeleeHold.default
		tool.Grip = CFrame.lookAt(Vector3.zero, hold.dir.Unit, hold.up):Inverse()
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

-- Перки команды: магазин, запас патронов, перезарядка и урон
local function magCap(def: Config.WeaponDef): number
	return math.floor(def.magSize * Perks.mult("mag") + 0.5)
end

local function reserveCap(def: Config.WeaponDef): number
	return if def.reserve < 0 then def.reserve else math.floor(def.reserve * Perks.mult("ammo") + 0.5)
end

local function reloadSeconds(def: Config.WeaponDef): number
	return def.reloadTime * (1 - math.min(0.7, Perks.total("reload")))
end

local function grant(player: Player, weaponId: string)
	local def = Config.Weapons[weaponId]
	local inv = owned[player]
	if not inv then
		inv = {}
		owned[player] = inv
	end
	inv[weaponId] = { mag = magCap(def), reserve = reserveCap(def), lastShot = 0, reloadingUntil = 0, burst = 0 }
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
	if st.mag >= magCap(def) or st.reserve == 0 or os.clock() < st.reloadingUntil then
		return
	end
	local seconds = reloadSeconds(def)
	st.reloadingUntil = os.clock() + seconds
	Remotes.get("ReloadFx"):FireAllClients(player, weaponId)
	task.delay(seconds, function()
		local inv = owned[player]
		if not inv or inv[weaponId] ~= st then
			return
		end
		local need = magCap(def) - st.mag
		if st.reserve < 0 then
			st.mag = magCap(def)
		else
			local take = math.min(need, st.reserve)
			st.mag += take
			st.reserve -= take
		end
		syncAmmo(player, weaponId)
	end)
end

local function onFire(player: Player, origin: unknown, direction: unknown, adsFlag: unknown)
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
	-- номер выстрела в очереди: после паузы очередь начинается заново (отдача и разброс предсказуемы)
	local aim = Config.WeaponAim[weaponId]
	local resetTime = (if aim then aim.resetTime else 0.3) + 1 / def.fireRate
	st.burst = if now - st.lastShot > resetTime then 0 else st.burst + 1
	st.lastShot = now
	st.mag -= 1

	-- разброс зависит от состояния игрока: движение, прыжок, прицеливание (флаг прицела присылает клиент)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local vel = if root then root.AssemblyLinearVelocity else Vector3.zero
	local state: Ballistics.State = {
		ads = adsFlag == true,
		speed = Vector3.new(vel.X, 0, vel.Z).Magnitude,
		airborne = hum ~= nil and (hum.FloorMaterial == Enum.Material.Air),
		burst = st.burst,
	}
	local spreadDeg = if aim then Ballistics.spreadDeg(def.spreadDeg, aim, state, Config.Player.WalkSpeed) else def.spreadDeg

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
	for pellet = 1, def.pellets do
		-- фиксированное смещение пули в круге разброса (первая одиночная — точно в прицел, дробь — одна розетка)
		local ox, oy = Ballistics.pelletOffset(pellet, st.burst, def.pellets)
		local spread = math.rad(spreadDeg)
		local dir = (CFrame.lookAt(Vector3.zero, d) * CFrame.Angles(oy * spread, ox * spread, 0)).LookVector
		local result = workspace:Raycast(head.Position, dir * def.range, params)
		if result then
			table.insert(hits, result.Position)
			local hitPart = result.Instance :: BasePart
			local model, isHead = ZombieService.isZombiePart(hitPart)
			if model then
				local kind = ZombieService.partKind(hitPart)
				local mult = if isHead then Config.Economy.HeadshotMultiplier elseif kind == "Arm" or kind == "Leg" then Config.Economy.LimbMultiplier else 1
				local dmg = def.damage * mult * Perks.mult("power")
				local applied, killed = ZombieService.damage(model, dmg, player, {
					dir = dir,
					push = if aim then aim.push * 1.2 / def.pellets else 5, -- дробь: суммарный толчок по всем дробинкам ≈ aim.push
					stagger = if aim then aim.stagger else 0.1,
					part = hitPart,
					power = if def.pellets > 1 then 0.6 else 1,
					heavy = def.pellets > 1,
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
	-- звук/анимация взмаха идут сразу, а удар по зомби — в момент попадания в анимации (у топора и кувалды это после замаха)
	Remotes.get("MeleeFx"):FireAllClients(player, weaponId)
	local fx = Config.MeleeFx[weaponId]
	local hitDelay = if fx then fx.time * (MeleeAnim.HIT[fx.style] or 0.5) else 0

	local function strike()
		local head2 = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
		if not head2 or not PlayerService.isUp(player) or equippedWeapon(player) ~= weaponId then
			return
		end
		local origin = head2.Position
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
			local applied, killed = ZombieService.damage(c.model, def.damage * Perks.mult("power"), player, {
				dir = away,
				push = def.knockback,
				stagger = 0.35,
				heavy = def.knockback >= 40,
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
	end
	if hitDelay > 0.03 then
		task.delay(hitDelay, strike)
	else
		strike()
	end
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

-- Выбросить оружие из рук (G) и подобрать чужое/своё (E по ProximityPrompt): так можно делиться оружием с командой.
-- Выброшенное оружие — физическая модель с невидимой коллизией на Handle; патроны (магазин и запас) хранятся в атрибутах.
local DROP_LIFETIME = 180
local PICKUP_RANGE = 16

local function dropsFolder(): Folder
	local f = workspace:FindFirstChild("DroppedWeapons")
	if not f then
		f = Instance.new("Folder")
		f.Name = "DroppedWeapons"
		f.Parent = workspace
	end
	return f :: Folder
end

local function hasWeapon(player: Player, weaponId: string): boolean
	local inv = owned[player]
	return inv ~= nil and inv[weaponId] ~= nil
end

local function giveWithAmmo(player: Player, weaponId: string, mag: number, reserve: number)
	local def = Config.Weapons[weaponId]
	local inv = owned[player]
	if not inv then
		inv = {}
		owned[player] = inv
	end
	inv[weaponId] = { mag = math.min(mag, def.magSize), reserve = reserve, lastShot = 0, reloadingUntil = 0, burst = 0 }
	giveTool(player, weaponId)
end

local function equipWeapon(player: Player, weaponId: string)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local backpack = player:FindFirstChildOfClass("Backpack")
	if hum and backpack then
		for _, t in backpack:GetChildren() do
			if t:IsA("Tool") and t:GetAttribute("WeaponId") == weaponId then
				hum:EquipTool(t)
				return
			end
		end
	end
end

local function onPickup(player: Player, drop: Model)
	if not drop.Parent or not PlayerService.isUp(player) then
		return
	end
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local handle = drop.PrimaryPart
	if not hrp or not handle or (hrp.Position - handle.Position).Magnitude > PICKUP_RANGE then
		return
	end
	local weaponId = drop:GetAttribute("WeaponId")
	if typeof(weaponId) ~= "string" or not Config.Weapons[weaponId] then
		return
	end
	local def = Config.Weapons[weaponId]
	local mag = (drop:GetAttribute("Mag") :: number?) or 0
	local reserve = (drop:GetAttribute("Reserve") :: number?) or 0
	if hasWeapon(player, weaponId) then
		if def.melee then
			Remotes.get("Notify"):FireClient(player, "Уже есть", 1.5)
			return
		end
		-- такое оружие уже есть: забираем только патроны
		local st = owned[player][weaponId]
		if st.reserve >= 0 then
			st.reserve += mag + math.max(reserve, 0)
		end
		syncAmmo(player, weaponId)
		Remotes.get("Notify"):FireClient(player, "Патроны: " .. def.name, 1.5)
	else
		giveWithAmmo(player, weaponId, mag, reserve)
		equipWeapon(player, weaponId)
		Remotes.get("Notify"):FireClient(player, "Подобрано: " .. def.name, 1.5)
	end
	drop:Destroy()
end

local function spawnDrop(weaponId: string, mag: number, reserve: number, cf: CFrame, velocity: Vector3)
	local def = Config.Weapons[weaponId]
	local tool = buildTool(def)
	local model = Instance.new("Model")
	model.Name = "Drop_" .. weaponId
	local handle = tool:FindFirstChild("Handle") :: BasePart
	for _, c in tool:GetChildren() do
		if c:IsA("BasePart") then
			c.Anchored = false
			c.Parent = model
		end
	end
	tool:Destroy()
	handle.Size = Vector3.new(1.4, 0.5, 1.4)
	handle.Transparency = 1
	handle.CanCollide = true
	handle.CanQuery = true
	handle.Massless = false
	model.PrimaryPart = handle
	model:SetAttribute("WeaponId", weaponId)
	model:SetAttribute("Mag", mag)
	model:SetAttribute("Reserve", reserve)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Подобрать"
	prompt.ObjectText = def.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = handle
	prompt.Triggered:Connect(function(player: Player)
		onPickup(player, model)
	end)
	model:PivotTo(cf)
	model.Parent = dropsFolder()
	handle.AssemblyLinearVelocity = velocity
	handle.AssemblyAngularVelocity = Vector3.new(0, 4, 0)
	Debris:AddItem(model, DROP_LIFETIME)
end

local function onDrop(player: Player)
	if not RateLimit.allow(player, "Drop", 0.4) or not PlayerService.isUp(player) then
		return
	end
	local weaponId, tool = equippedWeapon(player)
	local inv = owned[player]
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not weaponId or not tool or not inv or not inv[weaponId] or not head then
		return
	end
	local st = inv[weaponId]
	inv[weaponId] = nil
	tool:Destroy()
	local look = head.CFrame.LookVector
	spawnDrop(weaponId, st.mag, st.reserve, CFrame.new(head.Position + look * 2.5), look * 24 + Vector3.new(0, 10, 0))
end

-- Покупка из меню (ShopController). В режиме осмотра всё бесплатно; иначе — как со стены (цена, ночью закрыто).
local shopIds: { [string]: boolean } = {}
for _, item in Config.ShopList do
	shopIds[item.id] = true
end

local function onShopBuy(player: Player, weaponId: unknown)
	if typeof(weaponId) ~= "string" or not shopIds[weaponId] or not RateLimit.allow(player, "Buy", 0.2) then
		return
	end
	if not PlayerService.isUp(player) then
		return
	end
	-- купить можно только у магазина: военная палатка (платно, днём) или тестовый стенд (бесплатно)
	local point = ShopService.pointFor(player)
	if not point then
		Remotes.get("Notify"):FireClient(player, "Оружие продаётся в военных палатках", 2)
		return
	end
	if Config.Explore or point.free then
		grant(player, weaponId)
	else
		onWallBuy(player, weaponId)
	end
	-- сразу берём купленное в руки
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local backpack = player:FindFirstChildOfClass("Backpack")
	if hum and backpack then
		for _, t in backpack:GetChildren() do
			if t:IsA("Tool") and t:GetAttribute("WeaponId") == weaponId then
				hum:EquipTool(t)
				break
			end
		end
	end
end

-- Выдать оружие (покупка, награда, отладка); только из серверного кода
-- Патроны к оружию в руках (автомат): (можно ли, сообщение) — проверка до списания монет
function WeaponService.canRefillHeld(player: Player): (boolean, string?)
	local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
	local id = if tool then tool:GetAttribute("WeaponId") else nil
	local def = if typeof(id) == "string" then Config.Weapons[id] else nil
	if not def or def.melee then
		return false, "Возьмите в руки огнестрельное оружие"
	end
	if def.reserve < 0 then
		return false, "Этому оружию патроны не нужны"
	end
	local st = owned[player] and owned[player][def.id]
	if st and st.reserve >= reserveCap(def) and st.mag >= magCap(def) then
		return false, "Патроны полные"
	end
	return true, nil
end

function WeaponService.refillHeld(player: Player): boolean
	local can = WeaponService.canRefillHeld(player)
	if not can then
		return false
	end
	local tool = (player.Character :: Model):FindFirstChildOfClass("Tool") :: Tool
	grant(player, tool:GetAttribute("WeaponId") :: string)
	return true
end

-- Пополнить патроны всего огнестрела игрока (ящики с патронами): true — что-то изменилось
function WeaponService.refillAll(player: Player): boolean
	local inv = owned[player]
	if not inv then
		return false
	end
	local changed = false
	for id, st in inv do
		local def = Config.Weapons[id]
		if def and not def.melee and def.reserve >= 0 then
			if st.mag < magCap(def) or st.reserve < reserveCap(def) then
				st.mag = magCap(def)
				st.reserve = reserveCap(def)
				changed = true
				syncAmmo(player, id)
			end
		end
	end
	return changed
end

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
	Remotes.get("BuyWeapon").OnServerEvent:Connect(onShopBuy)
	Remotes.get("DropWeapon").OnServerEvent:Connect(onDrop)
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
