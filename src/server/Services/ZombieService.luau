--!strict
-- Зомби: очередь спавна, пул моделей, единый цикл ИИ для всех (без скрипта в каждом зомби),
-- урон по зомби только через ZombieService.damage на сервере.

local PhysicsService = game:GetService("PhysicsService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
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

-- Простая модель зомби из блоков (заменим на нормальные модели после выбора стиля)
local function buildModel(def: Config.ZombieDef): Model
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
		weld(root, p)
	end
	-- светящиеся глаза
	for _, x in { -0.25, 0.25 } do
		local eye = mk("Eye", Vector3.new(0.2, 0.2, 0.1), Vector3.new(x, 1.75, -0.62), Color3.fromRGB(255, 60, 40))
		eye.Material = Enum.Material.Neon
		weld(root, eye)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 3 * s - 1 * s
	humanoid.WalkSpeed = def.speed
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

local function acquire(typeId: string): Zombie
	local list = pool[typeId]
	if list and #list > 0 then
		return table.remove(list) :: Zombie
	end
	local def = Config.Zombies[typeId]
	local model = buildModel(def)
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
			AgentCanJump = true,
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

local function release(z: Zombie)
	z.alive = false
	active[z.model] = nil
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
	z.stuckTime = 0
	z.lastPos = spawnPos
	z.alive = true
	z.humanoid.WalkSpeed = z.def.speed
	z.model:SetAttribute("Hp", z.hp)
	z.model:SetAttribute("MaxHp", z.maxHp)
	z.model:PivotTo(CFrame.new(spawnPos))
	z.model.Parent = container
	z.root:SetNetworkOwner(nil) -- двигает только сервер
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

local function think(z: Zombie, now: number, dt: number)
	local pos = z.root.Position
	local reach = 3.5 * z.def.scale + 1.5

	-- после попадания зомби на миг замирает (чувствуется удар)
	if now < z.staggerUntil then
		z.humanoid:MoveTo(pos)
		return
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
		if now - z.lastAttack >= z.def.attackCooldown then
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
		goTo(z, targetRoot.Position, now)
		if dist <= reach and now - z.lastAttack >= z.def.attackCooldown then
			z.lastAttack = now
			PlayerService.damage(player, z.def.damage)
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
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local parts: { BasePart } = {}
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
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
	if z.hp > 0 and impact then
		if impact.stagger then
			z.staggerUntil = math.max(z.staggerUntil, os.clock() + impact.stagger)
		end
		if impact.push and flat ~= Vector3.zero then
			z.root:ApplyImpulse(flat * impact.push * z.root.AssemblyMass)
		end
	end
	if z.hp <= 0 then
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
		return model, part.Name == "Head"
	end
	return nil, false
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
				end
			end
		end
	end)

end

return ZombieService
