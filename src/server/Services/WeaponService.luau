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
local Validate = require(Shared:WaitForChild("Validate"))
local MeleeAnim = require(Shared:WaitForChild("MeleeAnim"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))

local WeaponService = {}

type WeaponState = { mag: number, reserve: number, lastShot: number, reloadingUntil: number, burst: number }

local owned: { [Player]: { [string]: WeaponState } } = {}
local rng = Random.new()

local MAX_ORIGIN_OFFSET = 8 -- насколько точка выстрела может отличаться от головы (лаг, камера)

-- Сидящий в машине не стреляет из ручного оружия (пулемёт машины — отдельное событие TurretFire)
local function isSeated(player: Player): boolean
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.SeatPart ~= nil
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
			warn("[WeaponService] failed to load mesh " .. meshId .. ": " .. tostring(result))
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
		-- быстрозарядник револьвера (Speedloader) лежит в модели отдельной деталью и в кадре «висел в воздухе» рядом со стволом: не берём
		if src:IsA("MeshPart") and not string.find(src.Name, "^Speedloader") then
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

-- Хотбар (стандартный Backpack Roblox): слоты идут по порядку добавления, и после выброса оружия в середине остаётся пустой слот.
-- Каждому инструменту при появлении ставим сквозной номер Order (по нему же колёсико мыши листает оружие на клиенте), а compactBackpack
-- снимает инструменты рюкзака и возвращает их в порядке Order: слоты снова идут подряд с 1. Клиент в этом не участвует.
local toolOrder = 0

local function stampTool(tool: Instance)
	if tool:IsA("Tool") and tool:GetAttribute("Order") == nil then
		toolOrder += 1
		tool:SetAttribute("Order", toolOrder)
	end
end

local compacting: { [Player]: boolean } = {}
local compactAgain: { [Player]: boolean } = {}

local function compactBackpack(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	if compacting[player] then
		compactAgain[player] = true -- ещё одна выброшенная пушка, пока идёт пересборка: повторим после
		return
	end
	compacting[player] = true
	local tools: { Tool } = {}
	for _, t in backpack:GetChildren() do
		if t:IsA("Tool") then
			stampTool(t)
			table.insert(tools, t)
		end
	end
	table.sort(tools, function(a: Tool, b: Tool)
		return (a:GetAttribute("Order") :: number) < (b:GetAttribute("Order") :: number)
	end)
	-- холодное оружие всегда в слоте MeleeSlot (план релиза 2026-11-11): до него — огнестрел и прочее по порядку, пустые места
	-- держат временные заглушки (хотбар Roblox оставляет слот пустым, когда инструмент убран), после — остальное
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local held = char and char:FindFirstChildOfClass("Tool")
	local heldId = if held then held:GetAttribute("WeaponId") else nil
	if held and hum then
		hum:UnequipTools()
		stampTool(held)
		table.insert(tools, held)
		table.sort(tools, function(a: Tool, b: Tool)
			return (a:GetAttribute("Order") :: number) < (b:GetAttribute("Order") :: number)
		end)
	end
	local melee: Tool? = nil
	local others: { Tool } = {}
	for _, t in tools do
		local id = t:GetAttribute("WeaponId")
		local def = if typeof(id) == "string" then Config.Weapons[id] else nil
		if def and def.melee and not melee then
			melee = t
		else
			table.insert(others, t)
		end
	end
	local layout: { Tool } = {}
	local fillers: { Tool } = {}
	if melee then
		for i = 1, Config.Inventory.MeleeSlot - 1 do
			local t = others[i]
			if not t then
				t = Instance.new("Tool")
				t.Name = " "
				t.RequiresHandle = false
				t.CanBeDropped = false
				t:SetAttribute("Filler", true)
				table.insert(fillers, t)
			end
			table.insert(layout, t)
		end
		table.insert(layout, melee)
		for i = Config.Inventory.MeleeSlot, #others do
			table.insert(layout, others[i])
		end
	else
		layout = others
	end
	for _, t in tools do
		t.Parent = nil
	end
	-- хотбар убирает слоты не мгновенно, а добавляемые одним пакетом инструменты занимают слоты в произвольном порядке (проверено в Studio):
	-- поэтому пауза после снятия и возврат по одному
	task.wait(0.4)
	for _, t in layout do
		if not backpack.Parent then
			break
		end
		t.Parent = backpack
		task.wait(0.1)
	end
	for _, f in fillers do
		f:Destroy()
	end
	if heldId and hum and hum.Parent then
		for _, t in backpack:GetChildren() do
			if t:IsA("Tool") and t:GetAttribute("WeaponId") == heldId then
				hum:EquipTool(t)
				break
			end
		end
	end
	compacting[player] = nil
	if compactAgain[player] then
		compactAgain[player] = nil
		compactBackpack(player)
	end
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
		local tool = buildTool(Config.Weapons[weaponId])
		stampTool(tool)
		tool.Parent = backpack
	end
	syncAmmo(player, weaponId)
end

-- Перки команды: магазин, запас патронов, перезарядка и урон
local function magCap(def: Config.WeaponDef, player: Player?): number
	local vip = if player and player:GetAttribute("Has_vip") == true then Config.Donate.Vip.Mag else 1
	return math.floor(def.magSize * Perks.mult("mag") * vip + 0.5)
end

local function vipDamage(player: Player): number
	return if player:GetAttribute("Has_vip") == true then Config.Donate.Vip.Damage else 1
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
	inv[weaponId] = { mag = magCap(def, player), reserve = reserveCap(def), lastShot = 0, reloadingUntil = 0, burst = 0 }
	giveTool(player, weaponId)
end

-- Холодное оружие (план релиза 2026-11-11): у игрока всегда одно, в слоте MeleeSlot. Новое заменяет старое, старое до конца раунда
-- бесплатно в магазине (атрибут FreeMelee — id через запятую, его читает ShopController)
local freeMelee: { [Player]: { [string]: boolean } } = {}

local function publishFreeMelee(player: Player)
	local list: { string } = {}
	for id in freeMelee[player] or {} do
		table.insert(list, id)
	end
	table.sort(list)
	player:SetAttribute("FreeMelee", table.concat(list, ","))
end

local function meleeOf(player: Player): string?
	for id in owned[player] or {} do
		local def = Config.Weapons[id]
		if def and def.melee then
			return id
		end
	end
	return nil
end

local function removeTools(player: Player, weaponId: string)
	for _, container in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if container then
			for _, t in (container :: Instance):GetChildren() do
				if t:IsA("Tool") and t:GetAttribute("WeaponId") == weaponId then
					t:Destroy()
				end
			end
		end
	end
end

local function replaceMelee(player: Player, weaponId: string)
	local old = meleeOf(player)
	if old == weaponId then
		return
	end
	if old then
		(owned[player] :: any)[old] = nil
		removeTools(player, old)
		local free = freeMelee[player] or {}
		freeMelee[player] = free
		free[old] = true
	end
	if freeMelee[player] then
		(freeMelee[player] :: any)[weaponId] = nil
	end
	publishFreeMelee(player)
	grant(player, weaponId)
	task.defer(compactBackpack, player)
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
	if st.mag >= magCap(def, player) or st.reserve == 0 or os.clock() < st.reloadingUntil then
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
		local need = magCap(def, player) - st.mag
		if st.reserve < 0 then
			st.mag = magCap(def, player)
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
	if not Validate.finiteVector(o) or not Validate.finiteVector(d) or d.Magnitude < 0.5 or d.Magnitude > 1.5 then
		return
	end
	d = d.Unit
	-- 2. состояние игрока и оружия
	if not PlayerService.isUp(player) or isSeated(player) or PlayerService.isStunned(player) then -- оглушённый (знак Гаргантюа) не стреляет и не бьёт
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
		-- пробитие (Config.Pierce): задетого зомби исключаем и пускаем луч дальше, урон по следующему ниже
		local pierce = Config.Pierce[weaponId] or Config.Pierce.Default
		local pierceLeft = pierce.count
		local factor = 1
		local passed: { Instance } = {}
		params.FilterDescendantsInstances = exclude
		local result = workspace:Raycast(head.Position, dir * def.range, params)
		while result do
			table.insert(hits, result.Position)
			local hitPart = result.Instance :: BasePart
			local model, isHead = ZombieService.isZombiePart(hitPart)
			if not model then
				break
			end
			do
				local kind = ZombieService.partKind(hitPart)
				local mult = if isHead then Config.Economy.HeadshotMultiplier elseif kind == "Arm" or kind == "Leg" then Config.Economy.LimbMultiplier else 1
				local dmg = def.damage * mult * factor * Perks.mult("power") * vipDamage(player)
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
			pierceLeft -= 1
			if pierceLeft <= 0 or (result.Position - head.Position).Magnitude > (pierce.range or def.range) then
				break
			end
			factor *= pierce.factor
			table.insert(passed, model)
			local list = table.clone(exclude)
			for _, m in passed do
				table.insert(list, m)
			end
			params.FilterDescendantsInstances = list
			result = workspace:Raycast(head.Position, dir * def.range, params)
		end
		if not result then
			table.insert(hits, head.Position + dir * def.range)
		end
	end
	params.FilterDescendantsInstances = exclude
	if totalDamage > 0 then
		EconomyService.add(player, Config.Economy.CoinsPerHit)
		Remotes.get("HitFeedback"):FireClient(player, lastHitPos, math.floor(totalDamage + 0.5), killedAny, headshotAny, def.pellets > 1)
	end
	Remotes.get("ShotFx"):FireAllClients(player, head.Position, hits, weaponId)
	syncAmmo(player, weaponId)
	if st.mag <= 0 then
		startReload(player, weaponId)
	end
end

-- Серия ударов (Config.MeleeCombo): номер последнего удара и время его начала у каждого игрока. Номер считает сервер, клиенту не доверяем.
local comboState: { [Player]: { index: number, at: number, weaponId: string } } = {}

-- Ближний бой: клиент присылает только направление взгляда; сектор, дальность, видимость и урон считает сервер.
local function onMelee(player: Player, direction: unknown)
	if typeof(direction) ~= "Vector3" then
		return
	end
	local d = direction :: Vector3
	if not Validate.finiteVector(d) or d.Magnitude < 0.5 or d.Magnitude > 1.5 then
		return
	end
	d = d.Unit
	if not PlayerService.isUp(player) or isSeated(player) or PlayerService.isStunned(player) then -- оглушённый (знак Гаргантюа) не стреляет и не бьёт
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
	local last = comboState[player]
	local prev, since = 0, math.huge
	if last and last.weaponId == weaponId then
		prev, since = last.index, now - last.at
	end
	local comboIndex = MeleeAnim.nextIndex(weaponId, prev, since)
	comboState[player] = { index = comboIndex, at = now, weaponId = weaponId }
	Remotes.get("MeleeFx"):FireAllClients(player, weaponId, comboIndex)
	local style, swingTime = MeleeAnim.stepAt(weaponId, comboIndex)
	local hitDelay = if Config.MeleeFx[weaponId] then swingTime * (MeleeAnim.HIT[style] or 0.5) else 0

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
			local applied, killed = ZombieService.damage(c.model, def.damage * Perks.mult("power") * vipDamage(player), player, {
				dir = away,
				push = def.knockback,
				stagger = 0.35,
				heavy = def.knockback >= 40,
				melee = true, -- холодное оружие: единственное, что берёт финального босса во второй фазе
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
		Remotes.get("Notify"):FireClient(player, "The shop is closed at night", 1.5)
		return
	end
	local def = Config.Weapons[weaponId]
	local inv = owned[player]
	if inv and inv[weaponId] and def.melee then
		-- патроны не нужны: второй раз то же самое не покупаем
		Remotes.get("Notify"):FireClient(player, "Already owned", 1.5)
		return
	end
	if def.melee then
		-- холодное заменяет то, что в руках на слоте MeleeSlot; места в инвентаре не занимает. Прежнее — бесплатно до конца раунда
		local free = freeMelee[player] ~= nil and (freeMelee[player] :: any)[weaponId] == true
		if free or EconomyService.trySpend(player, def.price) then
			replaceMelee(player, weaponId)
			Remotes.get("Notify"):FireClient(player, (if free then "Taken: " else "Purchased: ") .. def.name, 1.5)
		else
			Remotes.get("Notify"):FireClient(player, "Not enough coins", 1.5)
		end
		return
	end
	if inv and inv[weaponId] then
		-- уже есть — пополнение патронов за часть цены
		local price = math.floor(def.price * Config.Economy.RefillPriceFactor)
		if EconomyService.trySpend(player, price) then
			grant(player, weaponId)
			Remotes.get("Notify"):FireClient(player, "Ammo refilled", 1.5)
		else
			Remotes.get("Notify"):FireClient(player, "Not enough coins", 1.5)
		end
		return
	end
	if InventoryService.isFull(player) then
		Remotes.get("Notify"):FireClient(player, string.format("Inventory full (%d items): drop something first", Config.Inventory.MaxItems), 2)
		return
	end
	if EconomyService.trySpend(player, def.price) then
		grant(player, weaponId)
		Remotes.get("Notify"):FireClient(player, "Purchased: " .. def.name, 1.5)
	else
		Remotes.get("Notify"):FireClient(player, "Not enough coins", 1.5)
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
	inv[weaponId] = { mag = math.min(mag, magCap(def, player)), reserve = reserve, lastShot = 0, reloadingUntil = 0, burst = 0 }
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
	if not drop.Parent or drop:GetAttribute("Taken") or not PlayerService.isUp(player) then
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
			Remotes.get("Notify"):FireClient(player, "Already owned", 1.5)
			return
		end
		-- такое оружие уже есть: забираем только патроны
		drop:SetAttribute("Taken", true)
		drop:Destroy()
		local st = owned[player][weaponId]
		if st.reserve >= 0 then
			st.reserve = math.min(st.reserve + mag + math.max(reserve, 0), reserveCap(def))
		end
		syncAmmo(player, weaponId)
		Remotes.get("Notify"):FireClient(player, "Ammo: " .. def.name, 1.5)
	else
		if InventoryService.isFull(player) then
			Remotes.get("Notify"):FireClient(player, string.format("Inventory full (%d items)", Config.Inventory.MaxItems), 1.5)
			return
		end
		-- дроп гасим до выдачи: giveTool может уступить управление (загрузка меша), и второй игрок подобрал бы тот же ствол
		drop:SetAttribute("Taken", true)
		drop:Destroy()
		giveWithAmmo(player, weaponId, mag, reserve)
		equipWeapon(player, weaponId)
		task.defer(compactBackpack, player)
		Remotes.get("Notify"):FireClient(player, "Picked up: " .. def.name, 1.5)
	end
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
	prompt.ActionText = "Pick up"
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
	pcall(function()
		handle:SetNetworkOwner(nil) -- физикой дропа владеет сервер, а не ближайший клиент
	end)
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
	if Config.Weapons[weaponId].melee then
		Remotes.get("Notify"):FireClient(player, "Melee weapons can't be dropped: swap them in the shop or your loadout", 2)
		return
	end
	local st = inv[weaponId]
	inv[weaponId] = nil
	tool:Destroy()
	task.defer(compactBackpack, player) -- закрыть пустой слот хотбара: оружие из следующих слотов сдвигается к началу
	local look = head.CFrame.LookVector
	spawnDrop(weaponId, st.mag, st.reserve, CFrame.new(head.Position + look * 2.5), look * 24 + Vector3.new(0, 10, 0))
end

local CaseRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("CaseRules"))
local Loadout = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Loadout"))
local DataService = require(script.Parent:WaitForChild("DataService"))

-- Оружие, полученное за донат: взять бесплатно, с полным магазином и без запаса (патроны платные, у стартового пистолета бесконечные)
local function ownsDonated(player: Player, weaponId: string): boolean
	return player:GetAttribute("Has_" .. CaseRules.perkFor(weaponId)) == true
end

local function onFreeTake(player: Player, weaponId: string)
	if hasWeapon(player, weaponId) then
		onWallBuy(player, weaponId) -- нож второй раз не выдаём, патроны к оружию — за монеты
		return
	end
	if game:GetService("ReplicatedStorage"):GetAttribute("Phase") == "Night" then
		Remotes.get("Notify"):FireClient(player, "The shop is closed at night", 1.5)
		return
	end
	local def = Config.Weapons[weaponId]
	if def.melee then
		replaceMelee(player, weaponId)
		Remotes.get("Notify"):FireClient(player, "Taken: " .. def.name, 1.5)
		return
	end
	if InventoryService.isFull(player) then
		Remotes.get("Notify"):FireClient(player, string.format("Inventory full (%d items): drop something first", Config.Inventory.MaxItems), 2)
		return
	end
	giveWithAmmo(player, weaponId, magCap(def, player), if def.reserve < 0 then def.reserve else 0)
	Remotes.get("Notify"):FireClient(player, "Taken: " .. def.name, 1.5)
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
		Remotes.get("Notify"):FireClient(player, "Weapons are sold in military tents", 2)
		return
	end
	local donated = ownsDonated(player, weaponId)
	if Config.DonateOnly[weaponId] and not donated and not Config.Explore and not point.free then
		return -- донатное оружие выдаётся только получившим его
	end
	if (Config.Explore or point.free) and Config.Weapons[weaponId].melee then
		replaceMelee(player, weaponId)
	elseif Config.Explore or point.free then
		grant(player, weaponId)
	elseif donated then
		onFreeTake(player, weaponId)
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

-- Патроны к выбранному оружию игрока (продавец: игрок выбирает ствол в меню, брать в руки не нужно): (можно ли, сообщение) — проверка до списания монет
function WeaponService.canRefill(player: Player, weaponId: string): (boolean, string?)
	local def = Config.Weapons[weaponId]
	if not def or def.melee then
		return false, "Pick a firearm"
	end
	if def.reserve < 0 then
		return false, "This weapon doesn't need ammo"
	end
	local st = owned[player] and owned[player][weaponId]
	if not st then
		return false, "You don't have this weapon"
	end
	if st.reserve >= reserveCap(def) and st.mag >= magCap(def, player) then
		return false, "Ammo is full"
	end
	return true, nil
end

function WeaponService.refill(player: Player, weaponId: string): boolean
	if not WeaponService.canRefill(player, weaponId) then
		return false
	end
	local def = Config.Weapons[weaponId]
	local st = owned[player][weaponId]
	st.mag = magCap(def, player)
	st.reserve = reserveCap(def)
	syncAmmo(player, weaponId)
	return true
end

-- Оружие в руках (ящик с припасами): id или nil
local function heldId(player: Player): string?
	local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
	local id = if tool then tool:GetAttribute("WeaponId") else nil
	return if typeof(id) == "string" then id else nil
end

-- Патроны к оружию в руках (ящик с припасами): (можно ли, сообщение) — проверка до списания
function WeaponService.canRefillHeld(player: Player): (boolean, string?)
	local id = heldId(player)
	if not id then
		return false, "Equip a firearm"
	end
	return WeaponService.canRefill(player, id)
end

function WeaponService.refillHeld(player: Player): boolean
	local id = heldId(player)
	return id ~= nil and WeaponService.refill(player, id)
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
			if st.mag < magCap(def, player) or st.reserve < reserveCap(def) then
				st.mag = magCap(def, player)
				st.reserve = reserveCap(def)
				changed = true
				syncAmmo(player, id)
			end
		end
	end
	return changed
end

function WeaponService.give(player: Player, weaponId: string)
	local def = Config.Weapons[weaponId]
	if def and def.melee then
		replaceMelee(player, weaponId)
	elseif def then
		grant(player, weaponId)
	end
end

-- Новый раунд: у всех только пистолет
function WeaponService.resetRound(players: { Player })
	for _, p in players do
		owned[p] = {}
		freeMelee[p] = {}
		publishFreeMelee(p)
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
		if not RateLimit.allow(player, "Reload", 0.3) or PlayerService.isStunned(player) then
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
			-- стартовый набор (план релиза 2026-11-11): пистолет, оружие из набора (своё навсегда — полный магазин, запас платный)
			-- и выбранное холодное. Набор выбирается в лобби и лежит в профиле (атрибуты LoadoutGun, LoadoutMelee)
			local fresh = next(inv) == nil
			for _, weaponId in Config.StartWeapons do
				local def = Config.Weapons[weaponId]
				if def and not def.melee and not inv[weaponId] then
					grant(player, weaponId)
				end
			end
			if fresh then
				-- профиль грузится параллельно со спавном: ждём его (до 10 с), иначе выбранное в лобби не попадёт в матч
				local waitStart = os.clock()
				while player.Parent and player:GetAttribute("ProfileReady") ~= true and os.clock() - waitStart < 10 do
					task.wait(0.2)
				end
				local perks = DataService.perks(player)
				local now = os.time()
				local gun, melee = Loadout.pick(player:GetAttribute("LoadoutGun"), player:GetAttribute("LoadoutMelee"), function(perk: string): boolean
					return (perks ~= nil and (perks[perk] or 0) > now) or player:GetAttribute("Has_" .. perk) == true
				end)
				if gun and not inv[gun] then
					local def = Config.Weapons[gun]
					giveWithAmmo(player, gun, magCap(def, player), if def.reserve < 0 then def.reserve else 0)
				end
				if not meleeOf(player) then
					grant(player, melee)
				end
			elseif not meleeOf(player) then
				grant(player, "Knife")
			end
			for weaponId in inv do
				giveTool(player, weaponId)
			end
			compactBackpack(player)
		end)
	end
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			onCharacter(player)
			-- рюкзак создаётся заново при каждом возрождении: нумеруем всё, что в него попадает (оружие, аптечки, турели)
			task.spawn(function()
				local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
				if backpack then
					for _, t in backpack:GetChildren() do
						stampTool(t)
					end
					backpack.ChildAdded:Connect(stampTool)
				end
			end)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
		RateLimit.forget(player)
		comboState[player] = nil
	end)
end

return WeaponService
