--!strict
-- Конвой (миссия escort): бронетранспортёр APC (Config.Convoy.Model, 1000 HP) едет по маршруту (контрольные точки района, затем остановка на дороге
-- у места шатра) в сопровождении двух военных (слабых: Config.Convoy.Soldier*). Зомби атакуют конвой наравне с игроками
-- (ZombieService.registerTarget). Погиб — миссия провалена. Машина настоящая физическая (детали сварены, не заякорены, сервер — владелец физики):
-- её скорость (линейная и угловая) каждый кадр задаёт код: едем кинематически по маршруту, а физика несёт машину и подтягивает к расчётной точке.
-- Клиенты плавно интерполируют физику, поэтому нет рывков, как у заякоренной модели, которую двигали PivotTo с частотой сети (~20 Гц).
-- (AlignPosition для этого не годился: когда машина стояла и «засыпала», он её не будил, и она оставалась на месте, а точка уезжала.)
-- Едет только по дорогам (Workspace.Roads): весь маршрут считается один раз при старте (RoadRoute, A* по клеткам дороги), прямой линии
-- через здания не бывает; точка, до которой дорогой не добраться, пропускается, не добраться до остановки — конвой не стартует.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local SoldierService = require(script.Parent:WaitForChild("SoldierService"))
local RoadRoute = require(script.Parent:WaitForChild("RoadRoute"))

local ConvoyService = {}

type Escort = { model: Model, hum: Humanoid, root: BasePart, hp: number, alive: boolean, offset: Vector3, nextShot: number, farSince: number }
-- Машина колонны: у каждой своё здоровье (Config.Convoy.Vehicles); ведущая (lead) — главная, её гибель проваливает миссию
type Vehicle = {
	model: Model, root: BasePart, name: string, hp: number, maxHp: number, bottom: number, yaw: number, bar: Frame,
	alive: boolean, lead: boolean, gap: number, -- gap: на сколько студов по пути она позади ведущей (центр к центру)
	heading: Vector3, gy: number?, parked: boolean,
}
type TrailPoint = { pos: Vector3, dist: number } -- след ведущей машины: ведомые идут по нему (значит, тоже по дорогам)
type State = {
	followers: { Vehicle },
	trail: { TrailPoint },
	maxHp: number, -- здоровье ведущей
	leadVehicle: Vehicle,
	truck: Model,
	root: BasePart,
	hp: number,
	bottom: number, -- расстояние от оси модели до низа (для посадки на землю)
	waypoints: { Vector3 }, -- весь маршрут по дорогам: от выезда до остановки
	wpIndex: number,
	length: number,
	escorts: { Escort },
	bar: Frame,
	arrived: boolean,
	failed: boolean,
	heading: Vector3,
	kpos: Vector3, -- расчётное положение машины на маршруте (физическая модель следует за ним)
	yaw: number, -- поворот модели вокруг Y, чтобы её перед (колёса FL/FR) смотрел по курсу

	curSpeed: number, -- текущая скорость: плавно разгоняется и тормозит (ожидание игрока, поворот)
	phase: number, -- фаза покачивания кузова
	roll: number, -- крен на повороте (сглаженный)
	gy: number?, -- сглаженная высота земли
	speed: number, -- студов в секунду (у миссии своя: Config.Missions[n].convoySpeed, иначе Config.Convoy.TruckSpeed)
	held: boolean, -- рядом нет живого игрока: грузовик стоит
}

local current: State? = nil
local moveConn: RBXScriptConnection? = nil
local startMotion: (any) -> () -- задаётся ниже, после moveTruck и updateEscorts
local folder: Folder? = nil
local lastOrder: { Vector3 } = {} -- контрольные точки в порядке объезда (после start)
local rng = Random.new()
local C = Config.Convoy

-- Высота земли под точкой: только дороги, земля и трава (не крыши, билборды и мосты над ними)
local function ground(x: number, z: number, _ignore: { Instance }): number?
	local include: { Instance } = {}
	for _, name in { "Roads", "Ground", "Grass" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(include, f)
		end
	end
	if #include == 0 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	local hit = workspace:Raycast(Vector3.new(x, 200, z), Vector3.new(0, -400, 0), params)
	if hit and hit.Normal.Y > 0.7 then
		return hit.Position.Y
	end
	return nil
end

local function makeBar(root: BasePart, caption: string): Frame
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 24)
	gui.StudsOffset = Vector3.new(0, 14, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 600
	gui.Parent = root
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	back.BackgroundTransparency = 0.2
	back.BorderSizePixel = 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(80, 200, 100)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = caption
	label.Parent = back
	return fill
end

local function tracer(from: Vector3, to: Vector3)
	local dist = (to - from).Magnitude
	if dist < 1 or not folder then
		return
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 230, 150)
	p.Size = Vector3.new(0.12, 0.12, dist)
	p.CFrame = CFrame.lookAt(from:Lerp(to, 0.5), to)
	p.Parent = folder
	Debris:AddItem(p, 0.07)
end

local function paintBar(v: Vehicle)
	local f = v.hp / v.maxHp
	v.bar.Size = UDim2.fromScale(math.max(0, f), 1)
	v.bar.BackgroundColor3 = if f > 0.5 then Color3.fromRGB(80, 200, 100) elseif f > 0.25 then Color3.fromRGB(230, 190, 60) else Color3.fromRGB(220, 70, 60)
end

-- Игрокам и зомби — обычная цель-НПС: урон по машине колонны. Ведущая погибла — провал; ведомая погибла — остаётся остовом, колонна едет дальше
local function damageVehicle(v: Vehicle, amount: number)
	local s = current
	if not s or s.failed or not v.alive then
		return
	end
	v.hp = math.max(0, v.hp - amount)
	paintBar(v)
	v.model:SetAttribute("Hp", v.hp)
	if v.lead then
		s.hp = v.hp
	end
	if v.hp <= 0 then
		v.alive = false
		ZombieService.unregisterTarget(v.model)
		if v.lead then
			s.failed = true
		else
			v.root.AssemblyLinearVelocity = Vector3.zero
			v.root.AssemblyAngularVelocity = Vector3.zero
			v.root.Anchored = true -- остов встаёт на месте
			local smoke = Instance.new("Smoke")
			smoke.Color = Color3.fromRGB(40, 40, 40)
			smoke.Opacity = 0.5
			smoke.Size = 6
			smoke.Parent = v.root
		end
	end
end

-- Поза модели: перед смотрит по heading (yaw — поправка, если перед модели не вдоль её -Z)
local function poseFor(at: Vector3, heading: Vector3, yaw: number): CFrame
	return CFrame.lookAt(at, at + heading) * CFrame.Angles(0, yaw, 0)
end

-- Где перед модели (по колёсам FL/FR против RL/RR) в системе pivot → поворот вокруг Y, который совмещает его с -Z
local function frontYaw(model: Model): number
	local pv = model:GetPivot()
	local front, rear, nf, nr = Vector3.zero, Vector3.zero, 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local rel = pv:PointToObjectSpace(d.Position)
			if d.Name == "FL" or d.Name == "FR" then
				front, nf = front + rel, nf + 1
			elseif d.Name == "RL" or d.Name == "RR" then
				rear, nr = rear + rel, nr + 1
			end
		end
	end
	if nf == 0 or nr == 0 then
		return 0
	end
	local f = front / nf - rear / nr
	f = Vector3.new(f.X, 0, f.Z)
	if f.Magnitude < 0.1 then
		return 0
	end
	f = f.Unit
	return math.atan2(f.X, -f.Z)
end

-- Физическая машина: все детали сварены с корпусом и не заякорены (кроме корпуса — Massless), корпус следует за невидимой точкой
local function buildTruck(modelName: string, vehicleName: string, spawn: Vector3, heading: Vector3): (Model?, BasePart?, number, number)
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("Vehicles")
	local template = lib and (lib:FindFirstChild(modelName) or lib:FindFirstChild("TransportTruck"))
	if not template then
		warn("[ConvoyService] no ServerStorage.Assets.Vehicles." .. modelName)
		return nil, nil, 0, 0
	end
	local truck = template:Clone() :: Model
	truck.Name = vehicleName
	local biggest: BasePart? = nil
	for _, d in truck:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ClickDetector") or (d:IsA("BasePart") and d.Name == "Regen Button") then
			d:Destroy()
		end
	end
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") then
			if not biggest or d.Size.Magnitude > biggest.Size.Magnitude then
				biggest = d
			end
		elseif d:IsA("VehicleSeat") or d:IsA("Seat") then
			d.Disabled = true -- в конвое не ездят
		end
	end
	if not biggest then
		truck:Destroy()
		return nil, nil, 0, 0
	end
	local cf, size = truck:GetBoundingBox()
	local bottom = truck:GetPivot().Position.Y - (cf.Position.Y - size.Y / 2)
	local yaw = frontYaw(truck)
	truck:PivotTo(poseFor(spawn + Vector3.new(0, bottom, 0), heading, yaw))
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") and d ~= biggest then
			local w = Instance.new("WeldConstraint")
			w.Part0 = biggest
			w.Part1 = d
			w.Parent = d
		end
	end
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Massless = d ~= biggest
			-- не твёрдая: стыки дороги и колёса-коллайдеры давали толчки и неровную скорость (±40%); игроки и зомби проходят сквозь, цели — по расстоянию
			d.CanCollide = C.Solid
		end
	end
	-- невидимая твёрдая коробка по размеру корпуса: зомби её не проходят (раньше заходили внутрь машины и пропадали из виду), а игроки, земля и
	-- расчёт движения её не замечают (отдельная группа столкновений: сталкивается только с зомби); лучи пуль её тоже не видят (CanQuery = false)
	local bcf, bsize = truck:GetBoundingBox()
	local block = Instance.new("Part")
	block.Name = "ConvoyBlock"
	block.Size = bsize
	block.CFrame = bcf
	block.Transparency = 1
	block.Anchored = false
	block.Massless = true
	block.CanCollide = true
	block.CanQuery = false
	block.CanTouch = false
	pcall(function()
		PhysicsService:RegisterCollisionGroup("ConvoyVehicle")
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ConvoyVehicle", "Default", false)
		PhysicsService:CollisionGroupSetCollidable("ConvoyVehicle", "ConvoyVehicle", false)
		PhysicsService:CollisionGroupSetCollidable("ConvoyVehicle", "Zombies", true)
	end)
	block.CollisionGroup = "ConvoyVehicle"
	block.Parent = truck
	local bw = Instance.new("WeldConstraint")
	bw.Part0 = biggest
	bw.Part1 = block
	bw.Parent = block
	-- точка привязки модели привязана к корпусу: без PrimaryPart GetPivot отставал от физики, и расчёт ошибки «улетал» вместе с машиной
	biggest.PivotOffset = biggest.CFrame:ToObjectSpace(truck:GetPivot())
	truck.PrimaryPart = biggest
	truck.Parent = folder
	biggest:SetNetworkOwner(nil)
	-- мотор грузовика: тихий зацикленный звук, слышен всем рядом
	local engine = Instance.new("Sound")
	engine.Name = "ConvoyEngine"
	engine.SoundId = "rbxassetid://520998094"
	engine.Looped = true
	engine.Volume = C.EngineVolume
	engine.PlaybackSpeed = 0.7
	engine.RollOffMode = Enum.RollOffMode.InverseTapered
	engine.RollOffMinDistance = 15
	engine.RollOffMaxDistance = 90
	engine.Parent = biggest
	engine:Play()
	return truck, biggest, bottom, yaw
end

local function buildEscort(offset: Vector3, spawn: Vector3, index: number): Escort?
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("NPC")
	local template = lib and lib:FindFirstChild("Soldier")
	if not template then
		return nil
	end
	local model = template:Clone() :: Model
	model.Name = "ConvoySoldier" .. index
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then
		model:Destroy()
		return nil
	end
	model:PivotTo(CFrame.new(spawn + Vector3.new(0, 3, 0)))
	SoldierService.attachLooseParts(model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CollisionGroup = "Default"
		end
	end
	hum.MaxHealth = C.SoldierHp
	hum.Health = C.SoldierHp
	hum.WalkSpeed = 17
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	model.Parent = folder
	root:SetNetworkOwner(nil)
	local escort: Escort = { model = model, hum = hum, root = root, hp = C.SoldierHp, alive = true, offset = offset, nextShot = 0, farSince = 0 }
	ZombieService.registerTarget(model, root, function(amount: number)
		if not escort.alive then
			return
		end
		escort.hp -= amount
		hum.Health = math.max(0, escort.hp)
		if escort.hp <= 0 then
			escort.alive = false
			ZombieService.unregisterTarget(model)
			hum.Health = 0
			Debris:AddItem(model, 4)
		end
	end)
	return escort
end

local function pathLength(points: { Vector3 }): number
	local len = 0
	for i = 2, #points do
		len += (points[i] - points[i - 1]).Magnitude
	end
	return len
end

-- Путь по дорогам между двумя точками с кэшем (поиск A* недешёвый, а перебор порядка точек запрашивает одни и те же отрезки)
type LegCache = { [string]: { Vector3 }? | boolean }
local function legPath(grid: RoadRoute.Grid, cache: LegCache, a: Vector3, b: Vector3): { Vector3 }?
	local key = string.format("%d,%d>%d,%d", math.floor(a.X + 0.5), math.floor(a.Z + 0.5), math.floor(b.X + 0.5), math.floor(b.Z + 0.5))
	local hit = cache[key]
	if hit == nil then
		hit = grid.find(a, b) or false
		cache[key] = hit
	end
	return if hit then hit :: { Vector3 } else nil
end

local function legLength(path: { Vector3 }?): number
	return if path then pathLength(path) else math.huge
end

-- Лучший порядок точек (перебор, их до 6): минимум длины пути start → точки → stop. Каждая точка ровно один раз.
local function bestOrder(grid: RoadRoute.Grid, cache: LegCache, start: Vector3, pts: { Vector3 }, stop: Vector3, keepOrder: boolean?): ({ Vector3 }, number)
	local n = #pts
	if keepOrder then
		return table.clone(pts), 0 -- порядок задан миссией (Config.Missions.*.keepOrder): точки по очереди, как в списке
	end
	local best: { Vector3 } = table.clone(pts)
	local bestLen = math.huge
	local used: { boolean } = {}
	local cur: { Vector3 } = {}
	local function walk(from: Vector3, len: number)
		if len >= bestLen then
			return
		end
		if #cur == n then
			len += legLength(legPath(grid, cache, from, stop))
			if len < bestLen then
				bestLen, best = len, table.clone(cur)
			end
			return
		end
		for i = 1, n do
			if not used[i] then
				used[i] = true
				table.insert(cur, pts[i])
				walk(pts[i], len + legLength(legPath(grid, cache, from, pts[i])))
				table.remove(cur)
				used[i] = false
			end
		end
	end
	if n <= 6 then
		walk(start, 0)
	else
		-- много точек: ближайший по пути сосед
		local from, left, order = start, table.clone(pts), {}
		while #left > 0 do
			local bi, bd = 1, math.huge
			for i, p in left do
				local d = legLength(legPath(grid, cache, from, p))
				if d < bd then
					bi, bd = i, d
				end
			end
			from = table.remove(left, bi) :: Vector3
			table.insert(order, from)
		end
		best = order
	end
	return best, bestLen
end

-- Убирает петли: если путь второй раз проходит ту же точку, всё, что между, вырезаем (круг по тем же дорогам не нужен).
-- Петлю с контрольной точкой внутри не вырезаем: иначе колонна пропустит точку, а выбор выезда (planRoute) примет такой урезанный путь
-- за самый короткий (ночь 3: выезд налево через точку 2 вместо прямой дороги к точке 1)
local function cutLoops(waypoints: { Vector3 }, keep: { [string]: boolean }): { Vector3 }
	local out: { Vector3 } = {}
	local seen: { [string]: number } = {}
	for _, p in waypoints do
		local key = string.format("%d,%d", math.floor(p.X + 0.5), math.floor(p.Z + 0.5))
		local at = seen[key]
		if at then
			for i = at + 1, #out do
				local q = out[i]
				if keep[string.format("%d,%d", math.floor(q.X + 0.5), math.floor(q.Z + 0.5))] then
					at = nil
					break
				end
			end
		end
		if at then
			for _ = #out, at + 1, -1 do
				local q = table.remove(out) :: Vector3
				seen[string.format("%d,%d", math.floor(q.X + 0.5), math.floor(q.Z + 0.5))] = nil
			end
		else
			table.insert(out, p)
			seen[key] = #out
		end
	end
	return out
end

-- Маршрут от точки выезда: контрольные точки в лучшем порядке (каждая один раз), в конце — остановка. nil — до остановки не доехать.
-- Вторым значением — точки в порядке объезда (для подписей меток)
local function planFrom(grid: RoadRoute.Grid, cache: LegCache, start: Vector3, route: { Vector3 }, finalStop: Vector3, keepOrder: boolean?): ({ Vector3 }?, { Vector3 })
	local stop = grid.snap(finalStop, 150)
	if not stop then
		return nil, {}
	end
	local pts: { Vector3 } = {}
	for i, p in route do
		local onRoad = grid.snap(p, 60)
		if onRoad and legPath(grid, cache, start, onRoad) and legPath(grid, cache, onRoad, stop) then
			table.insert(pts, onRoad)
		else
			warn(string.format("[ConvoyService] checkpoint %d can't be reached by road — skipped", i))
		end
	end
	if not legPath(grid, cache, start, stop) then
		return nil, {}
	end
	local order = bestOrder(grid, cache, start, pts, stop, keepOrder)
	local waypoints: { Vector3 } = { start }
	local current = start
	for _, target in order do
		local path = legPath(grid, cache, current, target)
		if path then
			for i = 2, #path do
				table.insert(waypoints, path[i])
			end
			current = path[#path]
		end
	end
	local last = legPath(grid, cache, current, stop)
	if not last then
		return nil, {}
	end
	for i = 2, #last do
		table.insert(waypoints, last[i])
	end
	local keep: { [string]: boolean } = {}
	for _, p in order do
		keep[string.format("%d,%d", math.floor(p.X + 0.5), math.floor(p.Z + 0.5))] = true
	end
	return cutLoops(waypoints, keep), order
end

-- Выезд из начальной зоны: дорога начинается в десятках студов от точки появления игроков. Берём ближайшую дорогу и ещё несколько вокруг,
-- из них — ту, с которой путь короче (вместе с прямым отрезком от начальной зоны до неё: до ближайшей дороги порой ехать в разы дальше, чем от другой).
local function planRoute(spawn: Vector3, route: { Vector3 }, finalStop: Vector3, keepOrder: boolean?): ({ Vector3 }?, { Vector3 })
	local grid = RoadRoute.grid()
	local cache: LegCache = {}
	local starts: { Vector3 } = {}
	local function addStart(p: Vector3?)
		if not p then
			return
		end
		for _, s in starts do
			if (s - p).Magnitude < 30 then
				return
			end
		end
		table.insert(starts, p)
	end
	addStart(grid.snap(spawn, 150))
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		addStart(grid.snap(spawn + Vector3.new(math.cos(a) * 90, 0, math.sin(a) * 90), 50))
	end
	local best: { Vector3 }? = nil
	local bestOrder: { Vector3 } = {}
	local bestLen = math.huge
	for _, s in starts do
		local plan, order = planFrom(grid, cache, s, route, finalStop, keepOrder)
		if plan then
			local len = pathLength(plan) + Vector3.new(s.X - spawn.X, 0, s.Z - spawn.Z).Magnitude
			if len < bestLen then
				best, bestOrder, bestLen = plan, order, len
			end
		end
	end
	return best, bestOrder
end

-- Смещение сопровождающего в мире: X — вправо от курса, Z — назад
local function escortWorldOffset(heading: Vector3, offset: Vector3): Vector3
	local right = Vector3.new(-heading.Z, 0, heading.X)
	return right * offset.X - heading * offset.Z
end

-- Старт: route — точки по порядку, finalStop — где остановиться; spawn — начальная зона (точка появления игроков): колонна стартует отсюда
-- и первым отрезком едет к ближайшей дороге. speed — скорость миссии (иначе Config.Convoy.TruckSpeed). true — запущен.
function ConvoyService.start(spawn: Vector3, route: { Vector3 }, finalStop: Vector3, speed: number?, column: string?, keepOrder: boolean?): boolean
	ConvoyService.finish()
	local waypoints, order = planRoute(spawn, route, finalStop, keepOrder)
	lastOrder = order
	if not waypoints or #waypoints < 2 then
		warn("[ConvoyService] the tent site can't be reached by road")
		return false
	end
	-- грузовик стоит в начальной зоне: на StartOffset студов от точки появления игроков к первой дороге (не на самой точке, где появляются игроки)
	local toRoad = Vector3.new(waypoints[1].X - spawn.X, 0, waypoints[1].Z - spawn.Z)
	if toRoad.Magnitude > C.StartOffset + 6 then
		local from = spawn + toRoad.Unit * C.StartOffset
		table.insert(waypoints, 1, Vector3.new(from.X, spawn.Y, from.Z))
	end
	local begin = waypoints[1]
	local heading = Vector3.new(waypoints[2].X - begin.X, 0, waypoints[2].Z - begin.Z)
	heading = if heading.Magnitude > 0.1 then heading.Unit else Vector3.new(0, 0, -1)
	folder = Instance.new("Folder")
	folder.Name = "Convoy"
	folder.Parent = workspace
	local gy = ground(begin.X, begin.Z, {}) or begin.Y
	-- состав колонны: ColumnSize случайных машин из набора миссии (первая — ведущая)
	local pool = table.clone(C.Columns[column or "Light"] or C.Columns.Light)
	local columnDef: { string } = {}
	while #pool > 0 and #columnDef < (C.ColumnSize or #pool) do
		table.insert(columnDef, table.remove(pool, math.random(1, #pool)) :: string)
	end
	local leadSpec = C.Vehicles[columnDef[1]]
	local truck, root, bottom, yaw = buildTruck(columnDef[1], "ConvoyTruck", Vector3.new(begin.X, gy, begin.Z), heading)
	if not truck or not root then
		ConvoyService.finish()
		return false
	end
	local length = pathLength(waypoints)
	local v = speed or C.TruckSpeed
	print(string.format("[ConvoyService] road route: %d studs, %d points, about %d s en route at speed %.1f, column %s (%d vehicles)", length, #waypoints, length / v, v, column or "Light", #columnDef))
	local leadMax = leadSpec.hp
	local leadVehicle: Vehicle = {
		model = truck, root = root, name = columnDef[1], hp = leadMax, maxHp = leadMax, bottom = bottom, yaw = yaw, bar = makeBar(root, "CONVOY"),
		alive = true, lead = true, gap = 0, heading = heading, gy = nil, parked = false,
	}
	local _, leadSize = truck:GetBoundingBox()
	local prevLen = math.max(leadSize.X, leadSize.Z)
	local state: State = {
		followers = {}, trail = {}, maxHp = leadMax, leadVehicle = leadVehicle,
		truck = truck, root = root, hp = leadMax, bottom = bottom, kpos = Vector3.new(begin.X, gy, begin.Z), yaw = yaw, waypoints = waypoints, wpIndex = 2, length = length,
		escorts = {}, bar = leadVehicle.bar, arrived = false, failed = false, heading = heading, speed = v, held = false, curSpeed = 0, phase = 0, roll = 0, gy = nil,
	}
	truck:SetAttribute("Hp", leadMax)
	truck:SetAttribute("RouteLength", math.floor(length)) -- для проверок: хватит ли ночи (длина / Speed)
	truck:SetAttribute("Speed", v)
	ZombieService.registerTarget(truck, root, function(amount: number)
		damageVehicle(leadVehicle, amount)
	end)
	-- ведомые машины: позади ведущей на своём месте, ставятся по прямой назад от начала маршрута и дальше идут по следу ведущей
	local gap = 0
	for i = 2, #columnDef do
		local spec = C.Vehicles[columnDef[i]]
		local tmpPos = Vector3.new(begin.X, gy, begin.Z) - heading * (gap + prevLen / 2 + 8)
		local fgy = ground(tmpPos.X, tmpPos.Z, {}) or gy
		local fm, froot, fbottom, fyaw = buildTruck(columnDef[i], "ConvoyVehicle" .. i, Vector3.new(tmpPos.X, fgy, tmpPos.Z), heading)
		if fm and froot then
			local _, fsize = fm:GetBoundingBox()
			local flen = math.max(fsize.X, fsize.Z)
			gap += prevLen / 2 + 8 + flen / 2
			prevLen = flen
			fm:PivotTo(poseFor(Vector3.new(begin.X, fgy, begin.Z) - heading * gap + Vector3.new(0, fbottom, 0), heading, fyaw))
			local fv: Vehicle = {
				model = fm, root = froot, name = columnDef[i], hp = spec.hp, maxHp = spec.hp, bottom = fbottom, yaw = fyaw, bar = makeBar(froot, string.upper(columnDef[i])),
				alive = true, lead = false, gap = gap, heading = heading, gy = nil, parked = false,
			}
			fm:SetAttribute("Hp", spec.hp)
			ZombieService.registerTarget(fm, froot, function(amount: number)
				damageVehicle(fv, amount)
			end)
			table.insert(state.followers, fv)
		else
			warn("[ConvoyService] can't build column vehicle " .. columnDef[i])
		end
	end
	-- начало следа: прямо назад от начала маршрута на длину колонны
	local back = gap + prevLen + 20
	state.trail = { { pos = Vector3.new(begin.X, gy, begin.Z) - heading * back, dist = 0 }, { pos = Vector3.new(begin.X, gy, begin.Z), dist = back } }
	for i = 1, 2 do
		-- смещение: X — вбок от курса (за пределами кузова), Z — назад; считаем по размеру машины
		local _, bsize = truck:GetBoundingBox()
		local width, len = math.min(bsize.X, bsize.Z), math.max(bsize.X, bsize.Z)
		local offset = Vector3.new((if i == 1 then -1 else 1) * (width / 2 + 4), 0, len * 0.3)
		local e = buildEscort(offset, state.kpos + escortWorldOffset(heading, offset), i)
		if e then
			table.insert(state.escorts, e)
		end
	end
	current = state
	startMotion(state)
	return true
end

-- Контрольные точки в том порядке, в каком колонна их объезжает (для подписей меток)
function ConvoyService.routeOrder(): { Vector3 }
	return lastOrder
end

function ConvoyService.position(): Vector3?
	return if current then current.root.Position else nil
end

function ConvoyService.hpFraction(): number
	return if current then current.hp / current.maxHp else 0
end

-- Живых машин колонны / всего (для текста миссии)
function ConvoyService.vehicleCount(): (number, number)
	local s = current
	if not s then
		return 0, 0
	end
	local alive, total = if s.leadVehicle.alive then 1 else 0, 1
	for _, f in s.followers do
		total += 1
		if f.alive then
			alive += 1
		end
	end
	return alive, total
end

-- Длина маршрута по дорогам и оценка времени в пути (для проверки, что колонна успеет за ночь)
function ConvoyService.routeInfo(): (number, number)
	local s = current
	return if s then s.length else 0, if s then s.length / s.speed else 0
end

local function moveTruck(s: State, dt: number)
	-- едем по расчётному положению (kpos): физическая машина следует за ним с небольшой задержкой, сравнивать с её положением нельзя
	local pos = s.kpos
	local wp = s.waypoints[s.wpIndex]
	if not wp then
		-- приехали: машина встаёт на месте намертво
		s.arrived = true
		s.root.AssemblyLinearVelocity = Vector3.zero
		s.root.AssemblyAngularVelocity = Vector3.zero
		s.root.Anchored = true
		return
	end
	local flat = Vector3.new(wp.X - pos.X, 0, wp.Z - pos.Z)
	if flat.Magnitude < 3 then
		s.wpIndex += 1
		return
	end
	-- плавный поворот и движение вперёд по отрезку маршрута
	local want = flat.Unit
	local prevHeading = s.heading
	local blended = s.heading + (want - s.heading) * math.min(1, dt * 6)
	s.heading = if blended.Magnitude < 0.01 then want else blended.Unit
	-- скорость: плавный разгон и торможение; в повороте сбрасываем до 55%, чтобы не «заносило»
	local turn = math.abs(prevHeading.X * s.heading.Z - prevHeading.Z * s.heading.X)
	local target = if s.held then 0 else s.speed * (1 - math.min(0.45, turn * 8))
	if s.wpIndex >= #s.waypoints and flat.Magnitude < 8 then -- замедляемся только перед конечной остановкой, а не у каждой точки пути
		target = math.min(target, s.speed * 0.6)
	end
	local rate = if target > s.curSpeed then C.Accel else C.Brake
	s.curSpeed += math.clamp(target - s.curSpeed, -rate * dt, rate * dt)
	if s.curSpeed < 0.01 then
		s.curSpeed = 0
	end
	local step = math.min(s.curSpeed * dt, flat.Magnitude)
	local nx, nz = pos.X + s.heading.X * step, pos.Z + s.heading.Z * step
	local gyNow = ground(nx, nz, { s.truck, folder :: Instance }) or pos.Y
	local gy = if s.gy then s.gy + (gyNow - s.gy) * math.min(1, dt * 6) else gyNow -- высота земли сглажена: без подпрыгивания на стыках
	s.gy = gy
	-- кузов: лёгкая качка по ходу, крен на повороте (чем быстрее и круче — тем заметнее)
	s.phase += s.curSpeed * dt * 0.9
	local cross = prevHeading.X * s.heading.Z - prevHeading.Z * s.heading.X
	local rollTarget = math.clamp(cross / math.max(dt, 1e-3) * 0.05, -0.05, 0.05) * math.min(1, s.curSpeed / s.speed)
	s.roll += (rollTarget - s.roll) * math.min(1, dt * 4)
	local k = math.min(1, s.curSpeed / s.speed)
	local bob = math.sin(s.phase * 2.2) * 0.05 * k
	local pitch = math.sin(s.phase * 1.1) * 0.008 * k
	s.kpos = Vector3.new(nx, gy, nz)
	local lastPoint = s.trail[#s.trail]
	if lastPoint and (s.kpos - lastPoint.pos).Magnitude >= 2 then
		table.insert(s.trail, { pos = s.kpos, dist = lastPoint.dist + (s.kpos - lastPoint.pos).Magnitude })
		if #s.trail > 400 then
			table.remove(s.trail, 1)
		end
	end
	local at = Vector3.new(nx, gy + s.bottom + bob, nz)
	local pose = poseFor(at, s.heading, s.yaw) * CFrame.Angles(pitch, 0, s.roll)
	local cur = s.truck:GetPivot()
	local err = at - cur.Position
	-- «вверх» кузова держим по мировой оси: накренило больше MaxTilt (уклон, ребро, столкновение) — ставим на колёса по курсу
	local tilted = cur.UpVector.Y < math.cos(math.rad(C.MaxTilt))
	if tilted or err.Magnitude > C.MaxLag then
		-- машину зажало (стена, ящики), она улетела или накренилась: возвращаем на маршрут
		s.truck:PivotTo(pose)
		s.root.AssemblyLinearVelocity = Vector3.zero
		s.root.AssemblyAngularVelocity = Vector3.zero
		return
	end
	-- скорость задаёт код каждый кадр (это же будит «уснувшую» физику): вперёд по курсу + подтягивание к расчётной точке; поворот — к расчётной позе
	local vel = s.heading * s.curSpeed + err * C.FollowGain
	s.root.AssemblyLinearVelocity = vel
	local axis, angle = (pose.Rotation * cur.Rotation:Inverse()):ToAxisAngle()
	-- при нулевом повороте ось не определена (NaN): угловую скорость тогда не трогаем, иначе физика ломается и машина улетает
	if angle == angle and angle > 1e-4 and axis.X == axis.X and axis.Y == axis.Y and axis.Z == axis.Z then
		s.root.AssemblyAngularVelocity = axis * math.clamp(angle * C.TurnGain, -3, 3)
	else
		s.root.AssemblyAngularVelocity = Vector3.zero
	end
end

-- Ведомые машины: на своём расстоянии позади ведущей по её следу (дорогам); физика та же, что у ведущей: код задаёт скорость каждый кадр
local function moveFollowers(s: State, dt: number)
	local trail = s.trail
	local lastPoint = trail[#trail]
	local leadDist = lastPoint.dist + (s.kpos - lastPoint.pos).Magnitude
	for _, v in s.followers do
		if v.alive and not v.parked then
			local want = math.max(0, leadDist - v.gap)
			-- сегмент следа, на который приходится want (ищем с конца: нужный участок всегда близко к хвосту)
			local i = #trail
			while i > 1 and trail[i].dist > want do
				i -= 1
			end
			local a, b = trail[i], trail[math.min(#trail, i + 1)]
			local span = b.dist - a.dist
			local pos = if span > 0.01 then a.pos:Lerp(b.pos, (want - a.dist) / span) else a.pos
			local dir = Vector3.new(b.pos.X - a.pos.X, 0, b.pos.Z - a.pos.Z)
			if dir.Magnitude > 0.05 then
				local blended = v.heading + (dir.Unit - v.heading) * math.min(1, dt * 6)
				v.heading = if blended.Magnitude < 0.01 then dir.Unit else blended.Unit
			end
			local gyNow = ground(pos.X, pos.Z, {}) or pos.Y
			local gy = if v.gy then v.gy + (gyNow - v.gy) * math.min(1, dt * 6) else gyNow
			v.gy = gy
			local at = Vector3.new(pos.X, gy + v.bottom, pos.Z)
			local pose = poseFor(at, v.heading, v.yaw)
			local cur = v.model:GetPivot()
			local err = at - cur.Position
			local tilted = cur.UpVector.Y < math.cos(math.rad(C.MaxTilt))
			if tilted or err.Magnitude > C.MaxLag then
				v.model:PivotTo(pose)
				v.root.AssemblyLinearVelocity = Vector3.zero
				v.root.AssemblyAngularVelocity = Vector3.zero
			else
				v.root.AssemblyLinearVelocity = v.heading * s.curSpeed + err * C.FollowGain
				local axis, angle = (pose.Rotation * cur.Rotation:Inverse()):ToAxisAngle()
				if angle == angle and angle > 1e-4 and axis.X == axis.X and axis.Y == axis.Y and axis.Z == axis.Z then
					v.root.AssemblyAngularVelocity = axis * math.clamp(angle * C.TurnGain, -3, 3)
				else
					v.root.AssemblyAngularVelocity = Vector3.zero
				end
			end
			if s.arrived and err.Magnitude < 1.5 and want >= leadDist - v.gap - 0.5 then
				v.parked = true -- ведущая встала, ведомая заняла место: встаёт намертво
				v.root.AssemblyLinearVelocity = Vector3.zero
				v.root.AssemblyAngularVelocity = Vector3.zero
				v.root.Anchored = true
			end
		end
	end
end

local function updateEscorts(s: State, dt: number)
	local now = os.clock()
	for _, e in s.escorts do
		if e.alive then
			-- держимся у машины на своём месте: скорость ходьбы подстраивается под машину и расстояние (без «туда-обратно»); не могут дойти
			-- (упёрлись) или отстали — подтягиваем к колонне, ставя на землю, а не роняя сверху
			local anchorPos = s.root.Position + escortWorldOffset(s.heading, e.offset)
			local gap = (e.root.Position - anchorPos).Magnitude
			if gap > 12 then
				if e.farSince == 0 then
					e.farSince = now
				end
			else
				e.farSince = 0
			end
			if gap > 45 or (e.farSince > 0 and now - e.farSince > 7) then
				local nearPos = s.root.Position + escortWorldOffset(s.heading, e.offset)
				local gy = ground(nearPos.X, nearPos.Z, {}) or nearPos.Y
				e.model:PivotTo(CFrame.new(nearPos.X, gy + 3, nearPos.Z))
				e.root.AssemblyLinearVelocity = Vector3.zero
				e.farSince = 0
			elseif gap > 2.5 then
				e.hum.WalkSpeed = math.clamp(s.curSpeed + gap * 1.5, 4, 18)
				e.hum:MoveTo(anchorPos)
			else
				e.hum.WalkSpeed = math.max(s.curSpeed, 1)
				e.hum:MoveTo(e.root.Position + s.heading * 2) -- на месте: идёт вместе с машиной
			end
			-- стреляем по ближайшему зомби в 55 студах
			local best: { model: Model, root: BasePart }? = nil
			local bestDist = C.SoldierRange
			for _, z in ZombieService.queryNear(e.root.Position, C.SoldierRange) do
				local d = (z.root.Position - e.root.Position).Magnitude
				if d < bestDist then
					best, bestDist = z, d
				end
			end
			if best and now >= e.nextShot then
				e.nextShot = now + C.SoldierShotInterval
				local from = e.root.Position + Vector3.new(0, 1.2, 0)
				local to = best.root.Position + Vector3.new(0, 1, 0)
				tracer(from, to)
				local shot = e.root:FindFirstChild("ShotSound") :: Sound?
				if not shot then
					local created = Instance.new("Sound")
					created.Name = "ShotSound"
					created.SoundId = "rbxassetid://168436671"
					created.Volume = 0.1
					created.RollOffMaxDistance = 90
					created.Parent = e.root
					shot = created
				end
				if shot then
					shot:Play()
				end
				ZombieService.damage(best.model, C.SoldierDps * C.SoldierShotInterval, nil, { dir = to - from, push = 2, stagger = 0.1 })
			end
		end
	end
end

startMotion = function(state: State)
	if moveConn then
		moveConn:Disconnect()
	end
	moveConn = RunService.Heartbeat:Connect(function(frameDt: number)
		local s = current
		if s and s == state and not s.failed then
			if not s.arrived then
				moveTruck(s, frameDt) -- и в ожидании: плавно тормозит
			end
			moveFollowers(s, frameDt)
			updateEscorts(s, frameDt)
		end
	end)
end

-- Стоит ли колонна, ожидая игроков (для текста миссии)
function ConvoyService.isHeld(): boolean
	return current ~= nil and current.held
end

-- playerNear: рядом (Config.Convoy.FollowRadius) есть живой игрок; без него грузовик стоит.
-- "arrived" — грузовик стоит у места шатра, "fail" — грузовик уничтожен
function ConvoyService.update(dt: number, playerNear: boolean?): string?
	local s = current
	if not s then
		return nil
	end
	if s.failed then
		return "fail"
	end
	s.held = playerNear == false
	-- движение и солдаты считаются каждый кадр (moveConn): при шаге раз в 0,25 с грузовик ехал рывками
	ZombieService.moveAnchor(s.root.Position)
	if s.arrived then
		return "arrived"
	end
	return nil
end

function ConvoyService.finish()
	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
	local s = current
	if s then
		ZombieService.unregisterTarget(s.truck)
		for _, f in s.followers do
			ZombieService.unregisterTarget(f.model)
		end
		for _, e in s.escorts do
			ZombieService.unregisterTarget(e.model)
		end
	end
	current = nil
	if folder then
		folder:Destroy()
		folder = nil
	end
end

return ConvoyService
