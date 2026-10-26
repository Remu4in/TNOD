--!strict
-- Конвой (миссия escort): грузовик Transport Truck (1000 HP) едет по маршруту (контрольные точки района, затем остановка на дороге у места шатра)
-- в сопровождении двух военных (300 HP, ~50 урона в секунду по зомби каждый). Зомби атакуют конвой наравне с игроками
-- (ZombieService.registerTarget). Погиб грузовик — миссия провалена. Грузовик двигается кинематически (CFrame), его нельзя толкнуть.
-- Едет только по дорогам (Workspace.Roads): весь маршрут считается один раз при старте (RoadRoute, A* по клеткам дороги), прямой линии
-- через здания не бывает; точка, до которой дорогой не добраться, пропускается, не добраться до остановки — конвой не стартует.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local SoldierService = require(script.Parent:WaitForChild("SoldierService"))
local RoadRoute = require(script.Parent:WaitForChild("RoadRoute"))

local ConvoyService = {}

type Escort = { model: Model, hum: Humanoid, root: BasePart, hp: number, alive: boolean, offset: Vector3, nextShot: number, farSince: number }
type State = {
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
	speed: number, -- студов в секунду (у миссии своя: Config.Missions[n].convoySpeed, иначе Config.Convoy.TruckSpeed)
	held: boolean, -- рядом нет живого игрока: грузовик стоит
}

local current: State? = nil
local moveConn: RBXScriptConnection? = nil
local startMotion: (any) -> () -- задаётся ниже, после moveTruck и updateEscorts
local folder: Folder? = nil
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

local function makeBar(root: BasePart): Frame
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
	label.Text = "КОНВОЙ"
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

-- Игрокам и зомби — обычная цель-НПС: урон по грузовику
local function damageTruck(amount: number)
	local s = current
	if not s or s.failed then
		return
	end
	s.hp = math.max(0, s.hp - amount)
	s.bar.Size = UDim2.fromScale(s.hp / C.TruckHp, 1)
	s.bar.BackgroundColor3 = if s.hp / C.TruckHp > 0.5 then Color3.fromRGB(80, 200, 100) elseif s.hp / C.TruckHp > 0.25 then Color3.fromRGB(230, 190, 60) else Color3.fromRGB(220, 70, 60)
	s.truck:SetAttribute("Hp", s.hp)
	if s.hp <= 0 then
		s.failed = true
	end
end

local function buildTruck(spawn: Vector3, heading: Vector3): (Model?, BasePart?, number)
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("Vehicles")
	local template = lib and lib:FindFirstChild("TransportTruck")
	if not template then
		warn("[ConvoyService] нет ServerStorage.Assets.Vehicles.TransportTruck")
		return nil, nil, 0
	end
	local truck = template:Clone() :: Model
	truck.Name = "ConvoyTruck"
	local biggest: BasePart? = nil
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = true
			if not biggest or d.Size.Magnitude > biggest.Size.Magnitude then
				biggest = d
			end
		elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("VehicleSeat") or d:IsA("Seat") then
			if d:IsA("Script") or d:IsA("LocalScript") then
				d:Destroy()
			end
		end
	end
	if not biggest then
		truck:Destroy()
		return nil, nil, 0
	end
	local cf, size = truck:GetBoundingBox()
	local bottom = truck:GetPivot().Position.Y - (cf.Position.Y - size.Y / 2)
	truck:PivotTo(CFrame.lookAt(spawn, spawn + heading))
	-- мотор грузовика: тихий зацикленный звук, слышен всем рядом
	local engine = Instance.new("Sound")
	engine.Name = "ConvoyEngine"
	engine.SoundId = "rbxassetid://520998094"
	engine.Looped = true
	engine.Volume = 0.12
	engine.PlaybackSpeed = 0.7
	engine.RollOffMode = Enum.RollOffMode.InverseTapered
	engine.RollOffMinDistance = 15
	engine.RollOffMaxDistance = 140
	engine.Parent = biggest
	engine:Play()
	truck.Parent = folder
	return truck, biggest, bottom
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

-- Маршрут от точки выезда: по порядку через контрольные точки (недостижимые пропускаем), в конце — остановка. nil — до остановки не доехать
local function planFrom(grid: RoadRoute.Grid, start: Vector3, route: { Vector3 }, finalStop: Vector3): { Vector3 }?
	local waypoints: { Vector3 } = { start }
	local current = start
	local function leg(target: Vector3): boolean
		local path = grid.find(current, target)
		if not path then
			return false
		end
		for i = 2, #path do
			table.insert(waypoints, path[i])
		end
		current = path[#path]
		return true
	end
	for i, p in route do
		local onRoad = grid.snap(p, 60)
		if not onRoad or not leg(onRoad) then
			warn(string.format("[ConvoyService] до контрольной точки %d дорогой не доехать — пропущена", i))
		end
	end
	local stop = grid.snap(finalStop, 150)
	if not stop or not leg(stop) then
		return nil
	end
	return waypoints
end

-- Выезд из начальной зоны: дорога начинается в десятках студов от точки появления игроков. Берём ближайшую дорогу и ещё несколько вокруг,
-- из них — ту, с которой путь короче (вместе с прямым отрезком от начальной зоны до неё: до ближайшей дороги порой ехать в разы дальше, чем от другой).
local function planRoute(spawn: Vector3, route: { Vector3 }, finalStop: Vector3): { Vector3 }?
	local grid = RoadRoute.grid()
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
	local bestLen = math.huge
	for _, s in starts do
		local plan = planFrom(grid, s, route, finalStop)
		if plan then
			local len = pathLength(plan) + Vector3.new(s.X - spawn.X, 0, s.Z - spawn.Z).Magnitude
			if len < bestLen then
				best, bestLen = plan, len
			end
		end
	end
	return best
end

-- Старт: route — точки по порядку, finalStop — где остановиться; spawn — начальная зона (точка появления игроков): колонна стартует отсюда
-- и первым отрезком едет к ближайшей дороге. speed — скорость миссии (иначе Config.Convoy.TruckSpeed). true — запущен.
function ConvoyService.start(spawn: Vector3, route: { Vector3 }, finalStop: Vector3, speed: number?): boolean
	ConvoyService.finish()
	local waypoints = planRoute(spawn, route, finalStop)
	if not waypoints or #waypoints < 2 then
		warn("[ConvoyService] по дорогам до места шатра не доехать")
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
	local truck, root, bottom = buildTruck(Vector3.new(begin.X, gy + 0, begin.Z), heading)
	if not truck or not root then
		ConvoyService.finish()
		return false
	end
	local length = pathLength(waypoints)
	local v = speed or C.TruckSpeed
	print(string.format("[ConvoyService] маршрут по дорогам: %d студов, %d точек, в пути около %d с при скорости %.1f", length, #waypoints, length / v, v))
	local state: State = {
		truck = truck, root = root, hp = C.TruckHp, bottom = bottom, waypoints = waypoints, wpIndex = 2, length = length,
		escorts = {}, bar = makeBar(root), arrived = false, failed = false, heading = heading, speed = v, held = false,
	}
	truck:SetAttribute("Hp", C.TruckHp)
	truck:SetAttribute("RouteLength", math.floor(length)) -- для проверок: хватит ли ночи (длина / Speed)
	truck:SetAttribute("Speed", v)
	ZombieService.registerTarget(truck, root, damageTruck)
	for i = 1, 2 do
		-- смещение в системе грузовика: по бокам (за пределами кузова) и чуть позади
		local offset = Vector3.new(if i == 1 then -11 else 11, 0, 10)
		local e = buildEscort(offset, truck:GetPivot():PointToWorldSpace(offset) - Vector3.new(0, 0, 0), i)
		if e then
			table.insert(state.escorts, e)
		end
	end
	current = state
	startMotion(state)
	return true
end

function ConvoyService.position(): Vector3?
	return if current then current.root.Position else nil
end

function ConvoyService.hpFraction(): number
	return if current then current.hp / C.TruckHp else 0
end

-- Длина маршрута по дорогам и оценка времени в пути (для проверки, что колонна успеет за ночь)
function ConvoyService.routeInfo(): (number, number)
	local s = current
	return if s then s.length else 0, if s then s.length / s.speed else 0
end

local function moveTruck(s: State, dt: number)
	-- от точки привязки модели (pivot), а не от самой большой детали: деталь стоит в стороне от pivot, и грузовик на каждом шаге сдвигался
	-- ещё и на это смещение (ехал примерно вдвое быстрее заданной скорости)
	local pos = s.truck:GetPivot().Position
	local wp = s.waypoints[s.wpIndex]
	if not wp then
		s.arrived = true
		return
	end
	local flat = Vector3.new(wp.X - pos.X, 0, wp.Z - pos.Z)
	if flat.Magnitude < 3 then
		s.wpIndex += 1
		return
	end
	-- плавный поворот и движение вперёд по отрезку маршрута
	local want = flat.Unit
	s.heading = (s.heading + (want - s.heading) * math.min(1, dt * 6))
	if s.heading.Magnitude < 0.01 then
		s.heading = want
	end
	s.heading = s.heading.Unit
	local step = math.min(s.speed * dt, flat.Magnitude)
	local nx, nz = pos.X + s.heading.X * step, pos.Z + s.heading.Z * step
	local gy = ground(nx, nz, { s.truck, folder :: Instance }) or (pos.Y - s.bottom)
	s.truck:PivotTo(CFrame.lookAt(Vector3.new(nx, gy, nz), Vector3.new(nx, gy, nz) + s.heading))
end

local function updateEscorts(s: State, dt: number)
	local now = os.clock()
	for _, e in s.escorts do
		if e.alive then
			-- держимся у грузовика: отстали больше чем на 40 студов или не могут дойти больше 4 с (упёрлись в препятствие) — подтягиваем к колонне
			local anchorPos = s.root.Position + s.truck:GetPivot():VectorToWorldSpace(e.offset)
			local gap = (e.root.Position - anchorPos).Magnitude
			if gap > 7 then
				if e.farSince == 0 then
					e.farSince = now
				end
			else
				e.farSince = 0
			end
			if gap > 40 or (e.farSince > 0 and now - e.farSince > 4) then
				local near = s.root.Position + s.truck:GetPivot():VectorToWorldSpace(e.offset * 0.6)
				e.model:PivotTo(CFrame.new(near + Vector3.new(0, 4, 0)))
				e.farSince = 0
			elseif gap > 7 then
				e.hum:MoveTo(anchorPos)
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
			if not s.arrived and not s.held then
				moveTruck(s, frameDt)
			end
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
