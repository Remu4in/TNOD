--!strict
-- Зомби: очередь спавна, пул моделей, единый цикл ИИ для всех (без скрипта в каждом зомби),
-- урон по зомби только через ZombieService.damage на сервере.

local PhysicsService = game:GetService("PhysicsService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local BarricadeService = require(script.Parent:WaitForChild("BarricadeService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local ZombieService = {}

type State = "ToWindow" | "Breaking" | "Entering" | "Hunt"

type Zombie = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	head: BasePart,
	def: Config.ZombieDef,
	hp: number,
	maxHp: number,
	state: State,
	window: Types.Window?,
	lastAttack: number,
	lastPos: Vector3,
	stuckTime: number,
	alive: boolean,
	gen: number, -- номер «жизни» из пула: отсеивает устаревшие результаты поиска пути
	waypoints: { PathWaypoint }?,
	wpIdx: number,
	pathGoal: Vector3,
	pathAt: number,
	pathBusy: boolean,
	pathFailed: boolean, -- последний расчёт пути не нашёл маршрут (цель за баррикадой)
	staggerUntil: number, -- до этого момента зомби «вздрогнул» от попадания и стоит
	windupUntil: number, -- 0 — не замахивается; иначе момент удара (замах: стоит, руки подняты, глаза светлеют)
	windupTarget: Player?,
	welds: { [string]: JointInstance }, -- детали тела на Weld (меши) или Motor6D (риг): сервер двигает C0 при замахе, ударе и реакции на попадание
	rest: { [string]: CFrame }, -- их положение в покое
	slowUntil: number, -- до этого момента зомби хромает (попали в ногу)
	vaultResetAt: number, -- не раньше этого момента зомби снова может перелезать забор
	vaultLockUntil: number, -- до этого момента зомби в прыжке через забор и не думает
	headKill: boolean, -- убит выстрелом в голову (бонус очков и монет в RoundService)
	pivots: { [string]: Vector3 }, -- точки вращения частей тела (шея, плечи, бёдра) в системе корня
	hipPivot: Vector3, -- ось, вокруг которой корпус откидывается от попадания
	armRaise: number, -- угол поднятых рук при замахе, градусов
	armStrike: number, -- угол руки в ударе
	eyes: { BasePart },
	rig: boolean, -- настоящий риг R15 (Humanoid + Animator), а не меши на сварке
	tracks: { [string]: AnimationTrack },
	animIds: { [string]: string },
	nextSpecial: number, -- когда снова можно бросить колбу / телепортироваться
	throwing: boolean, -- замах — бросок колбы, а не удар -- анимации рига: idle, walk
	animName: string, -- какая анимация сейчас играет
	animSpeed: number, -- скорость шага, при которой анимация ходьбы идёт 1:1
}

local map: Types.MapInfo
local active: { [Model]: Zombie } = {}
local pool: { [string]: { Zombie } } = {}
local queue: { string } = {}
local hpMultiplier = 1
local storage: Folder
local container: Folder
local onKilled: ((player: Player?, zombie: Zombie) -> ())? = nil

local COLLISION_GROUP = "Zombies"

-- Поиск пути: не больше PATH_BUDGET новых расчётов за такт ИИ, маршрут обновляется раз в PATH_REFRESH секунд
local PATH_BUDGET = 8
local PATH_REFRESH = 1.5
local PATH_GOAL_DRIFT = 8
local pathBudget = 0

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

-- Шаблоны мешей частей тела (AssetService грузит меш по сети: один раз, с ожиданием, как у оружия)
local meshTemplates: { [string]: MeshPart } = {}
local meshState: { [string]: string } = {} -- "loading" | "ok" | "failed"

local function loadMesh(meshId: string): MeshPart?
	if not meshState[meshId] then
		meshState[meshId] = "loading"
		local ok, result = pcall(function()
			-- коллизия «коробкой»: попадания по частям тела дёшевы и предсказуемы (CollisionFidelity у готовой части менять нельзя)
			return AssetService:CreateMeshPartAsync(Content.fromUri(meshId), { CollisionFidelity = Enum.CollisionFidelity.Box })
		end)
		if ok then
			meshTemplates[meshId] = result
			meshState[meshId] = "ok"
		else
			warn("[ZombieService] не удалось загрузить меш " .. meshId .. ": " .. tostring(result))
			meshState[meshId] = "failed"
		end
	end
	while meshState[meshId] == "loading" do
		task.wait(0.05)
	end
	return meshTemplates[meshId]
end

-- Humanoid, коллизии и группа столкновений: общая часть для модели из мешей и запасной модели из блоков
local function finishModel(model: Model, def: Config.ZombieDef, root: BasePart, hipHeight: number): Model
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = hipHeight
	humanoid.WalkSpeed = def.speed
	humanoid.JumpHeight = 3 -- (прыжок у блочных зомби не срабатывает, перелезание заборов — в think)
	humanoid.RigType = Enum.HumanoidRigType.R15 -- высота по HipHeight, без суставов ног
	humanoid.MaxHealth = 1e6 -- HP зомби считаем сами
	humanoid.Health = 1e6
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.Parent = model

	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = COLLISION_GROUP
		end
	end
	return model
end

-- Все части тела на Weld (а не WeldConstraint): сервер двигает C0 при замахе, ударе и реакции на попадание, и это
-- видно всем. Имя сварки — "W_" .. имя части (Head, Torso, LeftArm, RightArm, LeftLeg, RightLeg)
local function weldBody(root: BasePart, p: BasePart)
	local w = Instance.new("Weld")
	w.Name = "W_" .. p.Name
	w.Part0 = root
	w.Part1 = p
	w.C0 = root.CFrame:ToObjectSpace(p.CFrame)
	w.Parent = root
end

-- Модель из сгенерированных мешей (Config.ZombieVisuals): корень-невидимка (хитбокс и физика) + части тела
-- Меш из шаблона: размер, текстура и (если заданы) цвет с материалом. BaseColor — цвет «в покое» для подсветки замаха.
local function makePiece(template: MeshPart, name: string, vp: { mesh: string, texture: string, size: Vector3, pos: Vector3, color: Color3?, material: string? }): MeshPart
	local p = template:Clone()
	p.Name = name
	p.Size = vp.size
	p.TextureID = vp.texture
	p.Color = vp.color or Color3.new(1, 1, 1)
	p:SetAttribute("BaseColor", p.Color)
	if vp.material then
		p.Material = (Enum.Material :: any)[vp.material]
	end
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Anchored = false
	p.CFrame = CFrame.new(vp.pos)
	return p
end

local function buildMeshModel(def: Config.ZombieDef, vis: Config.ZombieVisual, templates: { [string]: MeshPart }): Model
	local s = def.scale
	local model = Instance.new("Model")
	model.Name = "Zombie_" .. def.id
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1) * s
	root.Transparency = 1
	root.CanCollide = true
	root.CFrame = CFrame.new()
	root.Parent = model
	-- Видимые меши в рейкастах не участвуют: их коробки перекрывают друг друга (у громилы голова внутри коробки торса,
	-- и выстрелы в голову засчитывались в корпус). Попадания принимают отдельные невидимые хитбоксы "Hit<Часть>"
	-- по каждой части тела; они сварены с мешем и двигаются вместе с ним при замахе и реакции на попадание.
	for _, vp in vis.parts do
		local p = makePiece(templates[vp.mesh], vp.part, vp)
		p.Parent = model
		weldBody(root, p)
		-- остальные меши части (предплечье, кисть, голень, стопа, таз) держатся за основной
		for _, ex in vp.extra or {} do
			local e = makePiece(templates[ex.mesh], vp.part .. "Extra", ex)
			e.Parent = model
			weld(p, e)
		end

		local hit = Instance.new("Part")
		hit.Name = "Hit" .. vp.part
		hit.Size = vp.hitSize
		hit.Transparency = 1
		hit.CanCollide = false
		hit.CanTouch = false
		hit.Massless = true
		hit.CFrame = CFrame.new(vp.hitPos)
		hit.Parent = model
		weld(p, hit)
	end
	root.CanQuery = false -- попадания принимают хитбоксы частей, а не корень
	-- таз на высоте vis.pelvis над стопами; центр корня = низ корня + половина высоты
	return finishModel(model, def, root, vis.pelvis - 1 * s)
end

-- Запасная модель из блоков (если меши не загрузились)
local function buildBlockModel(def: Config.ZombieDef): Model
	local s = def.scale
	local model = Instance.new("Model")
	model.Name = "Zombie_" .. def.id

	local function mk(name: string, size: Vector3, offset: Vector3, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size * s
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.Massless = true
		p.CFrame = CFrame.new(offset * s)
		p.Parent = model
		return p
	end

	local root = mk("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0), def.color)
	root.Transparency = 1
	root.CanCollide = true
	root.Massless = false
	local torso = mk("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0), Color3.fromRGB(80, 70, 90))
	local head = mk("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0), def.color)
	local armL = mk("LeftArm", Vector3.new(0.8, 0.8, 2), Vector3.new(-1.3, 0.6, -0.9), def.color)
	local armR = mk("RightArm", Vector3.new(0.8, 0.8, 2), Vector3.new(1.3, 0.6, -0.9), def.color)
	local legL = mk("LeftLeg", Vector3.new(0.9, 2, 0.9), Vector3.new(-0.5, -2, 0), Color3.fromRGB(60, 55, 70))
	local legR = mk("RightLeg", Vector3.new(0.9, 2, 0.9), Vector3.new(0.5, -2, 0), Color3.fromRGB(60, 55, 70))
	for _, p in { torso, head, armL, armR, legL, legR } do
		weldBody(root, p)
	end
	-- светящиеся глаза
	for _, x in { -0.25, 0.25 } do
		local eye = mk("Eye", Vector3.new(0.2, 0.2, 0.1), Vector3.new(x, 1.75, -0.62), Color3.fromRGB(255, 60, 40))
		eye.Material = Enum.Material.Neon
		weld(root, eye)
	end
	return finishModel(model, def, root, 3 * s - 1 * s)
end

-- Риг R6 из библиотеки ServerStorage.Assets.Zombies (Config.ZombieRigs): случайная модель из пула типа, живой Humanoid, суставы Motor6D.
-- Попадания принимают сами части тела (Head, Torso, руки, ноги); корень-невидимка попаданий не принимает.
local function buildRigModel(def: Config.ZombieDef, rigDef: Config.ZombieRig): Model?
	local lib = ServerStorage:FindFirstChild("Assets")
	local folder = lib and lib:FindFirstChild("Zombies")
	if not folder then
		return nil
	end
	local candidates = {}
	for _, name in rigDef.pool do
		local m = folder:FindFirstChild(name)
		if m and m:IsA("Model") then
			table.insert(candidates, m)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local src = candidates[math.random(1, #candidates)]
	local model = src:Clone()
	model.Name = "Zombie_" .. def.id
	model:ScaleTo(if rigDef.absolute then rigDef.scale else rigDef.scale * def.scale)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.WalkSpeed = def.speed
	humanoid.JumpHeight = 3
	humanoid.MaxHealth = 1e6 -- HP зомби считаем сами
	humanoid.Health = 1e6
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	root.Transparency = 1
	root.CanQuery = false -- иначе корень перехватывает пули, летящие в корпус
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = COLLISION_GROUP
			d.Anchored = false
			d.CanTouch = false
			if d.Name == "Handle" then
				d.CanCollide = false -- аксессуары не мешают
			end
			d:SetAttribute("BaseColor", d.Color) -- цвет «в покое» для подсветки замаха
			if rigDef.tint and d.Name ~= "HumanoidRootPart" and d.Name ~= "Handle" then
				d.Color = rigDef.tint
				d:SetAttribute("BaseColor", rigDef.tint)
			end
		end
	end
	if rigDef.crawl then
		-- ползун: корпус наклонён вперёд почти до горизонтали и опущен к земле (поворот в системе корня, до чтения суставов)
		for _, d in model:GetDescendants() do
			if d:IsA("Motor6D") and d.Part0 == root and d.Part1 and d.Part1.Name == "Torso" then
				d.C0 = CFrame.new(0, -1.5 * model:GetScale(), 0) * CFrame.Angles(math.rad(-80), 0, 0) * d.C0
			end
		end
	end
	model:SetAttribute("Rig", true)
	model:SetAttribute("RigAsset", src.Name)
	return model
end

local function buildModel(def: Config.ZombieDef): Model
	if Config.UseRigZombies then
		local rigDef = Config.ZombieRigs[def.id]
		if rigDef then
			local rigModel = buildRigModel(def, rigDef)
			if rigModel then
				return rigModel
			end
			warn("[ZombieService] нет моделей из пула в ServerStorage.Assets.Zombies — зомби " .. def.id .. " собран из мешей")
		end
	end
	local vis = Config.ZombieVisuals[def.id]
	if vis then
		local templates: { [string]: MeshPart } = {}
		local complete = true
		local function need(meshId: string)
			local t = loadMesh(meshId)
			if t then
				templates[meshId] = t
			else
				complete = false
			end
		end
		for _, vp in vis.parts do
			need(vp.mesh)
			for _, ex in vp.extra or {} do
				need(ex.mesh)
			end
		end
		if complete then
			return buildMeshModel(def, vis, templates)
		end
	end
	return buildBlockModel(def)
end

-- id анимаций модели: атрибуты Anim_<роль> (из ассета), иначе стандартные R6 (Config.ZombieAnimDefaults)
local function resolveAnimIds(model: Model, rigDef: Config.ZombieRig): { [string]: string }
	local function pick(role: string): string
		local own = model:GetAttribute("Anim_" .. role)
		return if type(own) == "string" and own ~= "" then own else Config.ZombieAnimDefaults[role]
	end
	return {
		idle = pick("idle"),
		walk = pick(if rigDef.useRun then "run" else "walk"),
	}
end

-- Анимации рига: проигрываются на сервере через Animator (видны всем). Анимация, к которой у плейса нет доступа
-- (длина так и остаётся 0), заменяется стандартной R6.
local function loadTracks(model: Model, ids: { [string]: string }): { [string]: AnimationTrack }
	local tracks: { [string]: AnimationTrack } = {}
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator
	local function make(name: string, id: string): AnimationTrack?
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. id
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if not ok then
			warn("[ZombieService] не загрузилась анимация " .. name .. " " .. id .. ": " .. tostring(track))
			return nil
		end
		track.Looped = true
		track.Priority = if name == "idle" then Enum.AnimationPriority.Idle else Enum.AnimationPriority.Movement
		return track
	end
	for name, id in ids do
		local track = make(name, id)
		if track then
			tracks[name] = track
			local default = Config.ZombieAnimDefaults[if name == "idle" then "idle" else "walk"]
			if id ~= default then
				task.delay(4, function()
					if track.Length == 0 and tracks[name] == track then
						warn("[ZombieService] анимация " .. id .. " недоступна, заменена стандартной")
						local wasPlaying = track.IsPlaying
						track:Stop(0)
						local fallback = make(name, default)
						if fallback then
							tracks[name] = fallback
							if wasPlaying then
								fallback:Play(0.2)
							end
						end
					end
				end)
			end
		end
	end
	return tracks
end

local function acquire(typeId: string): Zombie
	local list = pool[typeId]
	if list and #list > 0 then
		return table.remove(list) :: Zombie
	end
	local def = Config.Zombies[typeId]
	local model = buildModel(def)
	local isRig = model:GetAttribute("Rig") == true
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local welds: { [string]: JointInstance } = {}
	local rest: { [string]: CFrame } = {}
	if isRig then
		-- сустав каждой части находим по тому, какую деталь он держит (имена у ассетов разные: RootJoint / Root Hip)
		local limbs = { Torso = "Torso", Head = "Head", LeftArm = "Left Arm", RightArm = "Right Arm", LeftLeg = "Left Leg", RightLeg = "Right Leg" }
		for name, partName in limbs do
			local found: Motor6D? = nil
			for _, d in model:GetDescendants() do
				if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == partName and d.Part0 and (partName ~= "Torso" or d.Part0 == root) then
					found = d
					break
				end
			end
			local j = found :: Motor6D
			welds[name] = j
			rest[name] = j.C0
		end
	else
		for _, name in { "Torso", "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg" } do
			local w = root:FindFirstChild("W_" .. name) :: Weld
			welds[name] = w
			rest[name] = w.C0
		end
	end
	local eyes: { BasePart } = {}
	for _, d in model:GetChildren() do
		if d.Name == "Eye" and d:IsA("BasePart") then
			table.insert(eyes, d)
		end
	end
	-- точки вращения и углы замаха зависят от вида модели: у мешей руки висят вниз, у блоков — вытянуты вперёд
	local isMesh = not isRig and (model:FindFirstChild("Torso") :: Instance):IsA("MeshPart")
	local s = def.scale
	local pivots: { [string]: Vector3 } = {}
	local hipPivot = Vector3.new(0, -0.9 * s, 0)
	if isRig then
		for name, w in welds do
			pivots[name] = rest[name].Position
		end
		pivots.Torso += Vector3.new(0, -1, 0) -- корпус наклоняется от пояса (RootJoint стоит в центре торса)
		hipPivot = pivots.Torso
	elseif isMesh then
		for _, vp in (Config.ZombieVisuals[typeId] :: Config.ZombieVisual).parts do
			pivots[vp.part] = vp.pivot
		end
		hipPivot = Vector3.new(0, -0.3, 0)
	else
		pivots = {
			Head = Vector3.new(0, 1.0 * s, 0),
			LeftArm = Vector3.new(-1.3 * s, 0.6 * s, 0),
			RightArm = Vector3.new(1.3 * s, 0.6 * s, 0),
			LeftLeg = Vector3.new(-0.5 * s, -1 * s, 0),
			RightLeg = Vector3.new(0.5 * s, -1 * s, 0),
			Torso = Vector3.zero,
		}
	end
	return {
		model = model,
		humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid,
		root = model:FindFirstChild("HumanoidRootPart") :: BasePart,
		head = model:FindFirstChild("Head") :: BasePart,
		def = def,
		hp = 0,
		maxHp = 0,
		state = "ToWindow",
		window = nil,
		lastAttack = 0,
		lastPos = Vector3.zero,
		stuckTime = 0,
		alive = false,
		gen = 0,
		waypoints = nil,
		wpIdx = 1,
		pathGoal = Vector3.zero,
		pathAt = 0,
		pathBusy = false,
		pathFailed = false,
		staggerUntil = 0,
		windupUntil = 0,
		windupTarget = nil,
		welds = welds,
		rest = rest,
		pivots = pivots,
		hipPivot = hipPivot,
		armRaise = if isRig then 100 elseif isMesh then 140 else 75,
		armStrike = if isRig then 35 elseif isMesh then 50 else -25,
		rig = isRig,
		tracks = {}, -- анимации грузим при первом выходе в мир (Animator должен быть в Workspace)
		animName = "",
		animSpeed = if isRig then Config.ZombieRigs[def.id].animSpeed else 1,
		nextSpecial = 0,
		throwing = false,
		animIds = if isRig then resolveAnimIds(model, Config.ZombieRigs[def.id]) else {},
		slowUntil = 0,
		vaultResetAt = 0,
		vaultLockUntil = 0,
		headKill = false,
		eyes = eyes,
	}
end

local function requestPath(z: Zombie, goal: Vector3, now: number)
	z.pathBusy = true
	z.pathGoal = goal
	z.pathAt = now
	pathBudget -= 1
	local gen = z.gen
	local from = z.root.Position
	local scale = z.def.scale
	task.spawn(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = math.max(2, 1.5 * scale),
			AgentHeight = 5,
			AgentCanJump = false, -- зомби не прыгают через заборы переулков (высота 4,4 > их прыжок 3)
			WaypointSpacing = 8,
		})
		local ok = pcall(function()
			path:ComputeAsync(from, goal)
		end)
		if z.gen == gen then
			if ok and path.Status == Enum.PathStatus.Success then
				z.waypoints = path:GetWaypoints()
				z.wpIdx = 2
				z.pathFailed = false
			else
				z.waypoints = nil
				z.pathFailed = true
			end
			z.pathBusy = false
		end
	end)
end

-- Идём к цели по маршруту (обходя дома и машины); вблизи или без маршрута — напрямик.
local function goTo(z: Zombie, goal: Vector3, now: number)
	local pos = z.root.Position
	local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z).Magnitude
	if flat < 8 then
		z.waypoints = nil
		z.humanoid:MoveTo(goal)
		return
	end
	if not z.pathBusy and pathBudget > 0 and (z.waypoints == nil or now - z.pathAt > PATH_REFRESH or (goal - z.pathGoal).Magnitude > PATH_GOAL_DRIFT) then
		requestPath(z, goal, now)
	end
	local wps = z.waypoints
	if wps then
		local wp = wps[z.wpIdx]
		while wp and Vector3.new(wp.Position.X - pos.X, 0, wp.Position.Z - pos.Z).Magnitude < 3 do
			z.wpIdx += 1
			wp = wps[z.wpIdx]
		end
		if wp then
			if wp.Action == Enum.PathWaypointAction.Jump then
				z.humanoid.Jump = true
			end
			z.humanoid:MoveTo(wp.Position)
			return
		end
		z.waypoints = nil
	end
	z.humanoid:MoveTo(goal)
end

-- Атака: замах (стоит с поднятыми руками, глаза светлеют) → удар. За время замаха можно отойти за радиус удара
-- или перекатиться (кувырок неуязвим): тогда удар «в пустоту». Между ударами — длинная пауза attackCooldown.
local EYE_NORMAL = Color3.fromRGB(255, 60, 40)
local EYE_ALERT = Color3.fromRGB(255, 240, 160)

-- deg: 0 — руки в покое; иначе поворот рук вокруг плеч на столько градусов (положительный — вперёд и вверх)
local function armPose(z: Zombie, deg: number, time: number)
	for _, name in { "LeftArm", "RightArm" } do
		local pivot = CFrame.new(z.pivots[name])
		local target = if deg == 0 then z.rest[name] else pivot * CFrame.Angles(math.rad(deg), 0, 0) * pivot:Inverse() * z.rest[name]
		TweenService:Create(z.welds[name], TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C0 = target }):Play()
	end
end

-- Знак замаха: у блочных зомби светлеют глаза, у модельных зомби — тело слегка краснеет (подсветка попавшего в замах)
local TINT_ALERT = Color3.fromRGB(255, 150, 130)
local function setEyes(z: Zombie, alert: boolean)
	if #z.eyes > 0 then
		for _, eye in z.eyes do
			eye.Color = if alert then EYE_ALERT else EYE_NORMAL
		end
	else
		for _, d in z.model:GetChildren() do
			if d:IsA("MeshPart") then
				d.Color = if alert then TINT_ALERT else (d:GetAttribute("BaseColor") or Color3.new(1, 1, 1))
			end
		end
	end
end

-- Колба химика: летит по дуге к месту, где стоял игрок; в точке падения — взрыв яда и лужа
local function flaskBurst(def: Config.ZombieDef, landing: Vector3)
	local fl = def.flask :: { range: number, minRange: number, cooldown: number, damage: number, tick: number, radius: number }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { container }
	local hit = workspace:Raycast(landing + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), params)
	local ground = if hit then hit.Position else landing
	local puddle = Instance.new("Part")
	puddle.Name = "PoisonPuddle"
	puddle.Shape = Enum.PartType.Cylinder
	puddle.Size = Vector3.new(0.25, fl.radius * 2, fl.radius * 2)
	puddle.CFrame = CFrame.new(ground + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
	puddle.Anchored = true
	puddle.CanCollide = false
	puddle.CanQuery = false
	puddle.CanTouch = false
	puddle.Material = Enum.Material.Neon
	puddle.Color = Color3.fromRGB(110, 220, 70)
	puddle.Transparency = 0.45
	puddle.Parent = workspace
	local function strike(amount: number)
		for _, p in PlayerService.upPlayers() do
			local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r and (r.Position - ground).Magnitude <= fl.radius then
				PlayerService.damage(p, amount)
			end
		end
	end
	strike(fl.damage)
	task.spawn(function()
		for _ = 1, 6 do
			task.wait(0.5)
			strike(fl.tick)
		end
		puddle:Destroy()
	end)
end

local function launchFlask(z: Zombie, target: Player)
	local char = target.Character
	local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not r then
		return
	end
	local origin = z.head.Position + Vector3.new(0, 0.5, 0)
	local landing = r.Position
	local dist = (landing - origin).Magnitude
	local t = math.clamp(dist / 45, 0.5, 1.3)
	local gravity = Vector3.new(0, -workspace.Gravity, 0)
	local flask = Instance.new("Part")
	flask.Name = "Flask"
	flask.Shape = Enum.PartType.Ball
	flask.Size = Vector3.new(1.2, 1.2, 1.2)
	flask.Material = Enum.Material.Neon
	flask.Color = Color3.fromRGB(110, 220, 70)
	flask.CanCollide = false
	flask.CanQuery = false
	flask.CanTouch = false
	flask.Position = origin
	flask.Parent = workspace
	flask.AssemblyLinearVelocity = (landing - origin) / t - 0.5 * gravity * t
	local def = z.def
	task.delay(t, function()
		flask:Destroy()
		flaskBurst(def, landing)
	end)
end

local function resetAttack(z: Zombie)
	z.throwing = false
	z.nextSpecial = 0
	z.windupUntil = 0
	z.windupTarget = nil
	for name, w in z.welds do
		w.C0 = z.rest[name]
	end
	z.slowUntil = 0
	z.vaultResetAt = 0
	z.vaultLockUntil = 0
	z.root.Anchored = false
	z.headKill = false
	setEyes(z, false)
end

local function cancelWindup(z: Zombie)
	z.throwing = false
	z.windupUntil = 0
	z.windupTarget = nil
	armPose(z, 0, 0.2)
	setEyes(z, false)
end

local function startWindup(z: Zombie, player: Player, now: number)
	z.windupUntil = now + z.def.windup
	z.windupTarget = player
	armPose(z, z.armRaise, z.def.windup * 0.85)
	setEyes(z, true)
end

local function finishStrike(z: Zombie, now: number)
	local target = z.windupTarget
	local throwing = z.throwing
	z.throwing = false
	z.windupUntil = 0
	z.windupTarget = nil
	z.lastAttack = now + math.random() * 0.6 -- небольшой разброс, чтобы стая не била залпом в один такт
	armPose(z, z.armStrike, 0.08)
	task.delay(0.3, function()
		if z.alive then
			armPose(z, 0, 0.25)
		end
	end)
	setEyes(z, false)
	if throwing then
		if target and PlayerService.isUp(target) then
			launchFlask(z, target)
		end
		return
	end
	-- удар достаёт, только если игрок всё ещё рядом (отошёл — промах) и не в кувырке (PlayerService.damage)
	if target and PlayerService.isUp(target) then
		local char = target.Character
		local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local reach = (3.5 * z.def.scale + 1.5) * 1.25
		if r and (r.Position - z.root.Position).Magnitude <= reach then
			PlayerService.damage(target, z.def.damage)
		end
	end
end

-- Реакция на попадание: часть тела, в которую попали, дёргается (корпус откидывается от выстрела, голова запрокидывается,
-- рука отлетает, нога подгибается). kind: "Head" | "Torso" | "Arm" | "Leg"; power — сила удара (0,5..2).
local function partKind(part: BasePart): string
	local name = string.gsub(part.Name, "^Hit", "") -- хитбоксы мешей называются Hit<Часть>; у рига R6 — Head/Torso/Left Arm…
	if name == "Handle" then -- аксессуар: считаем попаданием в ту часть, к которой он приварен
		local weld = part:FindFirstChildWhichIsA("JointInstance")
		if weld and weld.Part0 then
			name = weld.Part0.Name
		end
	end
	if name == "Head" then
		return "Head"
	elseif string.find(name, "Arm") or string.find(name, "Hand") then
		return "Arm"
	elseif string.find(name, "Leg") or string.find(name, "Foot") then
		return "Leg"
	end
	return "Torso"
end

local function jerk(z: Zombie, name: string, offset: CFrame, tIn: number, tOut: number)
	local w = z.welds[name]
	TweenService:Create(w, TweenInfo.new(tIn, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C0 = offset * z.rest[name] }):Play()
	task.delay(tIn, function()
		if z.alive then
			TweenService:Create(w, TweenInfo.new(tOut, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { C0 = z.rest[name] }):Play()
		end
	end)
end

-- Откинуть верхнюю часть тела от выстрела вокруг бёдер (angleDeg), остальные части — по списку names
local function leanBody(z: Zombie, localDir: Vector3, angleDeg: number, names: { string })
	local axis = Vector3.yAxis:Cross(localDir)
	if axis.Magnitude < 0.01 then
		return
	end
	if z.rig then
		-- у рига голова и руки — дети верхней части корпуса: достаточно наклонить пояс, остальное следует за ним
		local waist = CFrame.new(z.pivots.Torso)
		jerk(z, "Torso", waist * CFrame.fromAxisAngle(axis.Unit, math.rad(angleDeg)) * waist:Inverse(), 0.05, 0.3)
		return
	end
	local pivot = CFrame.new(z.hipPivot)
	local lean = pivot * CFrame.fromAxisAngle(axis.Unit, math.rad(angleDeg)) * pivot:Inverse()
	for _, name in names do
		jerk(z, name, lean, 0.05, 0.3)
	end
end

local function flinch(z: Zombie, kind: string, hitName: string, flat: Vector3, power: number, now: number)
	-- у рига части называются LeftUpperArm, RightLowerLeg…: приводим к логическим именам LeftArm/RightLeg
	local partName = hitName
	if z.rig and (kind == "Arm" or kind == "Leg") then
		partName = (if string.find(hitName, "Left") then "Left" else "Right") .. kind
	end
	local localDir = if flat == Vector3.zero then Vector3.new(0, 0, 1) else z.root.CFrame:VectorToObjectSpace(flat)
	if kind == "Head" then
		local neck = CFrame.new(z.pivots.Head)
		jerk(z, "Head", neck * CFrame.Angles(math.rad(38) * power, math.rad((math.random() - 0.5) * 40), 0) * neck:Inverse(), 0.05, 0.28)
		leanBody(z, localDir, 10 * power, { "Torso", "LeftArm", "RightArm" })
	elseif kind == "Arm" then
		local sx = if partName == "LeftArm" then -1 else 1
		local shoulder = CFrame.new(z.pivots[partName])
		jerk(z, partName, shoulder * CFrame.Angles(math.rad(-55) * power, 0, math.rad(sx * 18)) * shoulder:Inverse(), 0.05, 0.3)
		leanBody(z, localDir, 6 * power, { "Torso" })
	elseif kind == "Leg" then
		local hip = CFrame.new(z.pivots[partName])
		jerk(z, partName, hip * CFrame.Angles(math.rad(50) * power, 0, 0) * hip:Inverse(), 0.06, 0.4)
		z.slowUntil = now + 1.6 -- подстреленная нога: хромает
		z.humanoid.WalkSpeed = z.def.speed * 0.5
		local pivot = CFrame.new(z.hipPivot)
		local names = if z.rig then { "Torso" } else { "Torso", "Head", "LeftArm", "RightArm" }
		for _, name in names do
			jerk(z, name, pivot * CFrame.Angles(math.rad(-9), 0, 0) * pivot:Inverse(), 0.07, 0.35)
		end
	else -- корпус: откидывается от выстрела
		leanBody(z, localDir, 16 * power, { "Torso", "Head", "LeftArm", "RightArm" })
	end
end

local function release(z: Zombie)
	z.alive = false
	active[z.model] = nil
	for _, track in z.tracks do
		track:Stop(0)
	end
	z.animName = ""
	z.model.Parent = storage
	local list = pool[z.def.id]
	if not list then
		list = {}
		pool[z.def.id] = list
	end
	table.insert(list, z)
end

local function spawnOne(typeId: string)
	local z = acquire(typeId)
	local spawnPos = map.zombieSpawns[math.random(1, #map.zombieSpawns)]
		+ Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
	z.maxHp = math.floor(z.def.hp * hpMultiplier + 0.5)
	z.hp = z.maxHp
	-- сразу охотимся на игрока; к баррикадам идём, только если они закрывают путь к нему (см. Hunt)
	z.state = "Hunt"
	z.window = nil
	z.staggerUntil = 0
	z.gen += 1
	z.waypoints = nil
	z.pathBusy = false
	z.pathFailed = false
	z.lastAttack = 0
	resetAttack(z)
	z.stuckTime = 0
	z.lastPos = spawnPos
	z.alive = true
	z.humanoid.WalkSpeed = z.def.speed
	z.model:SetAttribute("Hp", z.hp)
	z.model:SetAttribute("MaxHp", z.maxHp)
	z.model:PivotTo(CFrame.new(spawnPos))
	z.model.Parent = container
	z.root:SetNetworkOwner(nil) -- двигает только сервер
	if z.rig and next(z.tracks) == nil then
		z.tracks = loadTracks(z.model, z.animIds)
	end
	active[z.model] = z
end

local function nearestUpCharacter(pos: Vector3): (Player?, BasePart?, number)
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDist = math.huge
	for _, p in PlayerService.upPlayers() do
		local char = p.Character
		local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			local d = (r.Position - pos).Magnitude
			if d < bestDist then
				best, bestRoot, bestDist = p, r, d
			end
		end
	end
	return best, bestRoot, bestDist
end

-- Анимация рига: по скорости корпуса — стоит (idle) или идёт (walk, темп по скорости). На замахе и в оцепенении — idle.
local function animate(z: Zombie)
	if not z.rig then
		return
	end
	local v = z.root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local want = if speed > 1.5 and z.windupUntil == 0 then "walk" else "idle"
	if want ~= z.animName then
		for name, track in z.tracks do
			if name == want then
				track:Play(0.2)
			else
				track:Stop(0.2)
			end
		end
		z.animName = want
	end
	local walk = z.tracks.walk
	if walk and want == "walk" then
		walk:AdjustSpeed(math.clamp(speed / z.animSpeed, 0.4, 2.4))
	end
end

-- Тёмный: перепрыгивает к игроку, но не ближе tp.distance
local function teleportNear(z: Zombie, targetRoot: BasePart, now: number)
	local tp = z.def.teleport :: { cooldown: number, distance: number }
	z.nextSpecial = now + tp.cooldown
	local angle = math.random() * math.pi * 2
	local spot = targetRoot.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (tp.distance + math.random() * 4)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { container, targetRoot.Parent :: Instance }
	local hit = workspace:Raycast(spot + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), params)
	if hit then
		z.model:PivotTo(CFrame.new(hit.Position + Vector3.new(0, 4, 0)))
		z.waypoints = nil
		z.pathFailed = false
	end
end

local function hasLineOfSight(z: Zombie, targetRoot: BasePart): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { container, targetRoot.Parent :: Instance }
	local from = z.head.Position
	return workspace:Raycast(from, targetRoot.Position - from, params) == nil
end

local function think(z: Zombie, now: number, dt: number)
	local pos = z.root.Position
	local reach = 3.5 * z.def.scale + 1.5

	-- хромота после попадания в ногу проходит
	if z.slowUntil > 0 and now >= z.slowUntil then
		z.slowUntil = 0
		z.humanoid.WalkSpeed = z.def.speed
	end

	-- после попадания зомби на миг замирает (чувствуется удар); замах при этом срывается
	if now < z.staggerUntil then
		if z.windupUntil > 0 then
			cancelWindup(z)
		end
		z.humanoid:MoveTo(pos)
		return
	end

	-- замах: стоим на месте; в конце — удар
	if z.windupUntil > 0 then
		z.humanoid:MoveTo(pos)
		if now >= z.windupUntil then
			finishStrike(z, now)
		end
		return
	end

	-- перелезание забора: заборы переулков (4,4) выше обычного прыжка зомби (3), поэтому упёршись в забор, зомби
	-- через секунду делает усиленный прыжок. Игроку это даёт 1–2 с форы; стенки (5,6) и балки зомби не берут.
	-- Зомби собраны из блоков, Humanoid.Jump у них не срабатывает, а скорость корня гасит сам Humanoid. Поэтому
	-- перелезание — короткая дуга над забором: корень на 0,7 с закрепляется и летит по твину, потом отпускается.
	if now < z.vaultLockUntil then
		return
	end
	if z.stuckTime > 1 and now >= z.vaultResetAt then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { container }
		local look = z.root.CFrame.LookVector
		local hit = workspace:Raycast(pos + Vector3.new(0, 1, 0), look * 4, params)
		if hit and string.sub(hit.Instance.Name, 1, 5) == "Fence" then
			local start = z.root.CFrame
			local base = Vector3.new(hit.Position.X, pos.Y, hit.Position.Z)
			local apex = CFrame.new(base + Vector3.new(0, 3.8, 0)) * start.Rotation
			local landing = CFrame.new(base + look * 3.4) * start.Rotation
			z.vaultLockUntil = now + 0.8
			z.vaultResetAt = now + 2.2 -- пауза до следующего перелезания
			z.stuckTime = 0
			z.root.Anchored = true
			local up = TweenService:Create(z.root, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = apex })
			up.Completed:Once(function()
				local down = TweenService:Create(z.root, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = landing })
				down.Completed:Once(function()
					z.root.Anchored = false
				end)
				down:Play()
			end)
			up:Play()
			return
		end
	end
	-- застревание: долго почти не двигаемся — прыгаем
	if (pos - z.lastPos).Magnitude < 0.3 and z.state ~= "Breaking" then
		z.stuckTime += dt
		if z.stuckTime > 2 then
			z.humanoid.Jump = true
			z.stuckTime = 0
		end
	else
		z.stuckTime = 0
	end
	z.lastPos = pos

	if z.state == "ToWindow" then
		local w = z.window
		if not w then
			z.state = "Hunt"
			return
		end
		if (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(w.outside.X, 0, w.outside.Z)).Magnitude < 3 then
			z.state = if BarricadeService.isOpen(w) then "Entering" else "Breaking"
		else
			goTo(z, w.outside, now)
		end
	elseif z.state == "Breaking" then
		local w = z.window :: Types.Window
		if BarricadeService.isOpen(w) then
			z.state = "Entering"
			return
		end
		z.humanoid:MoveTo(w.outside)
		if now - z.lastAttack >= z.def.breakCooldown then
			z.lastAttack = now
			BarricadeService.damage(w, z.def.planksPerHit)
		end
	elseif z.state == "Entering" then
		local w = z.window :: Types.Window
		z.humanoid:MoveTo(w.inside)
		local flat = Vector3.new(pos.X, 0, pos.Z) - Vector3.new(w.inside.X, 0, w.inside.Z)
		if flat.Magnitude < 3 then
			z.state = "Hunt"
		end
	else -- Hunt
		local player, targetRoot, dist = nearestUpCharacter(pos)
		if not player or not targetRoot then
			return
		end
		-- упёрся в баррикаду (почти не двигаемся, а рядом закрытый вход): ломаем её
		if z.stuckTime > 0.6 then
			local near = BarricadeService.closedEntranceNear(pos, 8)
			if near then
				z.window = near
				z.state = "ToWindow"
				z.waypoints = nil
				z.stuckTime = 0
				return
			end
		end
		-- пути к игроку нет (он за баррикадой): идём ломать вход, который его защищает, где бы зомби ни стоял
		if z.pathFailed and not z.pathBusy then
			local w = BarricadeService.guardingEntrance(targetRoot.Position, 45)
			if w then
				z.window = w
				z.state = "ToWindow"
				z.pathFailed = false
				z.waypoints = nil
				return
			end
		end
		local tp = z.def.teleport
		if tp and now >= z.nextSpecial and dist > tp.distance + 10 then
			teleportNear(z, targetRoot, now)
			return
		end
		goTo(z, targetRoot.Position, now)
		local fl = z.def.flask
		if fl and now >= z.nextSpecial and dist <= fl.range and dist >= fl.minRange and hasLineOfSight(z, targetRoot) then
			z.nextSpecial = now + fl.cooldown
			z.throwing = true
			startWindup(z, player, now)
		elseif dist <= reach and now - z.lastAttack >= z.def.attackCooldown then
			startWindup(z, player, now)
		end
	end
end

-- Тело убитого зомби: на миг замирает, затем отлетает от стрелка (клон модели, живёт пару секунд)
local MAX_CORPSES = 10
local corpses: { Model } = {}

local function spawnCorpse(z: Zombie, dir: Vector3)
	local folder = workspace:FindFirstChild("Corpses")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Corpses"
		folder.Parent = workspace
	end
	if #corpses >= MAX_CORPSES then
		local oldest = table.remove(corpses, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	local c = z.model:Clone()
	c.Name = "Corpse"
	local hum = c:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:Destroy()
	end
	if z.rig then
		-- риг: суставы Motor6D заменяем шаровыми — тело разваливается как тряпичная кукла
		for _, m in c:GetDescendants() do
			if m:IsA("Motor6D") and m.Part0 and m.Part1 then
				local a0 = Instance.new("Attachment")
				a0.CFrame = m.C0
				a0.Parent = m.Part0
				local a1 = Instance.new("Attachment")
				a1.CFrame = m.C1
				a1.Parent = m.Part1
				local ball = Instance.new("BallSocketConstraint")
				ball.Attachment0 = a0
				ball.Attachment1 = a1
				ball.LimitsEnabled = true
				ball.UpperAngle = 55
				ball.TwistLimitsEnabled = true
				ball.TwistLowerAngle = -35
				ball.TwistUpperAngle = 35
				ball.Parent = m.Part0
				m:Destroy()
			end
		end
	end
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local parts: { BasePart } = {}
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = z.rig and d.Name ~= "HumanoidRootPart" and d.Name ~= "Handle" -- у рига ударяются о землю все части (рэгдолл), у мешей — только корень
			d.CanQuery = false
			d.CanTouch = false
			d.CollisionGroup = "Default"
			table.insert(parts, d)
		end
	end
	if not root then
		c:Destroy()
		return
	end
	root.CanCollide = true
	root.Transparency = 1
	c.Parent = folder
	table.insert(corpses, c)
	-- «заморозка» на 0,07 с, потом бросок
	task.delay(0.07, function()
		if not c.Parent then
			return
		end
		for _, p in parts do
			p.Anchored = false
		end
		local mass = root.AssemblyMass
		root:ApplyImpulse((dir * 34 + Vector3.new(0, 20, 0)) * mass)
		root.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-4, 4), math.random(-8, 8))
	end)
	task.delay(2.4, function()
		for _, p in parts do
			if p.Parent then
				TweenService:Create(p, TweenInfo.new(0.8), { Transparency = 1 }):Play()
			end
		end
	end)
	Debris:AddItem(c, 3.4)
end

export type Impact = {
	dir: Vector3?, -- направление удара/выстрела (от стрелка к зомби)
	push: number?, -- отбрасывание, студов/с
	stagger: number?, -- на сколько секунд зомби замирает
	part: BasePart?, -- часть тела, в которую попали (для реакции: голова, корпус, рука, нога)
	power: number?, -- сила удара для анимации реакции (1 — обычная)
}

-- Урон по зомби (только сервер). Возвращает: нанесён ли урон, убит ли.
function ZombieService.damage(model: Model, amount: number, attacker: Player?, impact: Impact?): (boolean, boolean)
	local z = active[model]
	if not z or not z.alive then
		return false, false
	end
	z.hp -= amount
	z.model:SetAttribute("Hp", math.max(0, z.hp))
	-- горизонтальное направление удара: из импакта или от стрелка к зомби
	local flat = Vector3.zero
	if impact and impact.dir then
		flat = Vector3.new(impact.dir.X, 0, impact.dir.Z)
	elseif attacker and attacker.Character then
		local ar = attacker.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if ar then
			flat = Vector3.new(z.root.Position.X - ar.Position.X, 0, z.root.Position.Z - ar.Position.Z)
		end
	end
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zero
	local kind = if impact and impact.part then partKind(impact.part) else "Torso"
	if z.hp > 0 and impact then
		local now = os.clock()
		-- выстрел в голову останавливает дольше, в ногу — почти нет (зато хромает)
		local staggerScale = if kind == "Head" then 1.4 elseif kind == "Leg" then 0.5 else 1
		if impact.stagger then
			z.staggerUntil = math.max(z.staggerUntil, now + impact.stagger * staggerScale)
		end
		if impact.push and flat ~= Vector3.zero then
			z.root:ApplyImpulse(flat * impact.push * z.root.AssemblyMass)
		end
		if impact.part then
			flinch(z, kind, (string.gsub(impact.part.Name, "^Hit", "")), flat, impact.power or 1, now)
		end
	end
	if z.hp <= 0 then
		z.headKill = kind == "Head"
		spawnCorpse(z, flat)
		release(z)
		if onKilled then
			(onKilled :: (Player?, Zombie) -> ())(attacker, z)
		end
		return true, true
	end
	return true, false
end

-- Живые зомби в радиусе от точки (для ближнего боя и ловушек): модель и корневая часть
function ZombieService.queryNear(pos: Vector3, radius: number): { { model: Model, root: BasePart } }
	local result: { { model: Model, root: BasePart } } = {}
	for model, z in active do
		if z.alive and (z.root.Position - pos).Magnitude <= radius then
			table.insert(result, { model = model, root = z.root })
		end
	end
	return result
end

function ZombieService.isZombiePart(part: BasePart): (Model?, boolean)
	local model = part:FindFirstAncestorOfClass("Model")
	if model and active[model] then
		return model, part.Name == "Head" or part.Name == "HitHead"
	end
	return nil, false
end

-- Вид части тела для множителей урона: "Head" | "Torso" | "Arm" | "Leg"
function ZombieService.partKind(part: BasePart): string
	return partKind(part)
end

function ZombieService.enqueue(types: { string }, hpMult: number)
	hpMultiplier = hpMult
	for _, t in types do
		table.insert(queue, t)
	end
end

function ZombieService.remaining(): number
	local n = #queue
	for _ in active do
		n += 1
	end
	return n
end

function ZombieService.clearAll()
	table.clear(queue)
	local list = {}
	for _, z in active do
		table.insert(list, z)
	end
	for _, z in list do
		release(z)
	end
end

-- Привязать сервис к новой локации (точки спавна); вызывается и при смене локации.
function ZombieService.setMap(mapInfo: Types.MapInfo)
	map = mapInfo
end

function ZombieService.init(mapInfo: Types.MapInfo, killedCallback: (Player?, any) -> ())
	map = mapInfo
	onKilled = killedCallback
	storage = Instance.new("Folder")
	storage.Name = "ZombiePool"
	storage.Parent = game:GetService("ServerStorage")
	container = Instance.new("Folder")
	container.Name = "Zombies"
	container.Parent = workspace

	PhysicsService:RegisterCollisionGroup(COLLISION_GROUP)
	-- зомби не толкаются друг с другом (толпа не застревает в окнах)
	PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, COLLISION_GROUP, false)

	-- меши частей тела грузим заранее, чтобы первый зомби не появлялся с задержкой
	task.spawn(function()
		for _, vis in Config.ZombieVisuals do
			for _, vp in vis.parts do
				loadMesh(vp.mesh)
				for _, ex in vp.extra or {} do
					loadMesh(ex.mesh)
				end
			end
		end
	end)

	-- спавн очередью: не больше N за тик и не больше лимита на карте
	task.spawn(function()
		while true do
			task.wait(Config.Round.SpawnTick)
			local alive = 0
			for _ in active do
				alive += 1
			end
			local n = 0
			while #queue > 0 and n < Config.Round.SpawnsPerTick and alive < Config.Round.MaxZombiesAlive do
				spawnOne(table.remove(queue, 1) :: string)
				n += 1
				alive += 1
			end
		end
	end)

	-- единый цикл ИИ
	task.spawn(function()
		while true do
			local dt = task.wait(Config.Round.AiTick)
			local now = os.clock()
			pathBudget = PATH_BUDGET
			for _, z in active do
				if z.alive then
					think(z, now, dt)
					animate(z)
				end
			end
		end
	end)

end

return ZombieService
