--!strict
-- Машины: сервер ставит модель (корпус-коробка + внешний вид + место водителя). Ездой управляет клиент водителя
-- (VehicleController): физикой сидящего владеет его клиент, поэтому ввод с клавиатуры работает без задержек.
-- Модель — шаблон из ServerStorage.CarModels (Root — невидимая коробка-корпус, остальное — внешний вид без столкновений).
-- Тип машины (скорость, прочность, масса, давка) — Config.VehicleTypes / Config.VehicleModels.
-- Прочность: атрибуты модели Hp / MaxHp / Wrecked. Давка зомби и авария считаются здесь по скорости корпуса (один цикл на все машины).
-- Место стрелка («GunnerSeat», номер 0) и встроенный пулемёт (детали «MG» шаблона) у типов с полем turret: стрелок наводит ствол
-- камерой (TurretAim), стреляет зажатой кнопкой (TurretFire) и перезаряжает (TurretReload); патроны и урон считает сервер.

local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))
local RateLimit = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RateLimit"))
local Validate = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Validate"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local VehicleService = {}

type Gun = {
	joint: Weld, -- шарнир ствола: Part0 — корпус, Part1 — невидимая ось с приваренными деталями пулемёта
	pivotLocal: Vector3,
	yaw: number,
	pitch: number,
	targetYaw: number,
	targetPitch: number,
	recoil: number,
	scale: number,
	barrel: BasePart,
	sound: Sound,
	mag: number,
	reserve: number,
	reloadingUntil: number,
	lastShot: number,
}

type VehicleState = {
	model: Model,
	root: BasePart,
	seats: { [number]: Seat | VehicleSeat }, -- по номеру места: 1 водитель, 2–4 пассажиры, 0 стрелок
	tune: Config.VehicleType,
	hp: number,
	maxHp: number,
	wrecked: boolean,
	lastSpeed: number,
	lastPos: Vector3?, -- где был корпус на прошлой проверке (раз в TICK): защита от телепорта клиентом водителя
	lastAt: number,
	jumpUntil: number, -- после скачка позиции давки и аварии нет до этого момента
	lastHit: { [Model]: number },
	smoke: Smoke?,
	gun: Gun?,
}

local R = Config.VehicleRam
local TICK = 0.1 -- период проверки давки и аварий, с
-- Позицией корпуса владеет клиент водителя: за проверку корпус не может уйти дальше maxSpeed × dt × JUMP_FACTOR + JUMP_SLACK
-- (запас на рывки репликации). Дальше — скачок (телепорт, сбой сети): ни давки, ни аварии в этой проверке и JUMP_PAUSE после неё,
-- иначе телепорт в толпу засчитывался бы следующей же проверкой.
local JUMP_FACTOR = 1.5
local JUMP_SLACK = 2
local JUMP_PAUSE = 0.5

local container: Folder
local vehicles: { [Model]: VehicleState } = {}
local layout: { { name: string, cf: CFrame } } = {} -- расстановка карты (spawnAll): по ней машины ставятся заново каждый раунд

local function occupantPlayer(seat: (Seat | VehicleSeat)?): Player?
	local hum = seat and seat.Occupant
	return if hum then Players:GetPlayerFromCharacter(hum.Parent) else nil
end

local function eject(seat: Seat | VehicleSeat)
	seat.Disabled = true
	local occ = seat.Occupant
	if occ then
		occ.Sit = false
	end
end

local function weldTo(root: BasePart, part: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = part
	w.Parent = part
end

-- Сиденье стрелка у люка (точка TurretMount); сам пулемёт — встроенные детали «MG» шаблона, их собирает setupGun
local function mountTurret(state: VehicleState, k: number)
	local spec = state.tune.turret
	if not spec then
		return
	end
	local model, root = state.model, state.root
	local mountAttr = model:GetAttribute("MountOffset")
	local mount = if typeof(mountAttr) == "Vector3" then mountAttr * k else Vector3.new(0, root.Size.Y / 2, root.Size.Z * 0.1)
	local att = Instance.new("Attachment")
	att.Name = "TurretMount"
	att.Position = mount
	att.Parent = root

	local seat = Instance.new("Seat")
	seat.Name = "GunnerSeat"
	seat.Size = Vector3.new(2, 0.6, 2)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.Massless = true
	seat.CFrame = root.CFrame * CFrame.new(mount + spec.seat)
	seat.Parent = model
	weldTo(root, seat)
	seat.CanTouch = false
	seat:SetAttribute("SeatIndex", 0)
	state.seats[0] = seat
	model:SetAttribute("Turret", true)
	model:SetAttribute("TurretReady", false) -- станет true, когда пулемёт собран (setupGun)
end

-- Детали встроенного пулемёта в шаблоне: MeshPart’ы внутри группы «MG» (кроме башни «Tower»)
local function findGunParts(model: Model): { BasePart }
	local list: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") and d.Parent and d.Parent.Name == "MG" and d.Name ~= "Tower" then
			table.insert(list, d)
		end
	end
	return list
end

-- Пулемёт на шарнире: невидимая ось в точке крепления, детали приварены к ней, шарнир крутит сервер (yaw/pitch/откат)
local function setupGun(state: VehicleState, k: number, parts: { BasePart })
	local spec = state.tune.turret
	if not spec or not spec.gunPivot or #parts == 0 then
		return
	end
	local root = state.root
	local pivotLocal = spec.gunPivot * k
	local pivot = Instance.new("Part")
	pivot.Name = "GunPivot"
	pivot.Size = Vector3.new(0.4, 0.4, 0.4)
	pivot.Transparency = 1
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.CanTouch = false
	pivot.Massless = true
	pivot.CFrame = root.CFrame * CFrame.new(pivotLocal)
	pivot.Parent = state.model
	local joint = Instance.new("Weld")
	joint.Name = "GunJoint"
	joint.Part0 = root
	joint.Part1 = pivot
	joint.C0 = CFrame.new(pivotLocal)
	joint.Parent = pivot
	local barrel = parts[1]
	for _, part in parts do
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
		local w = Instance.new("WeldConstraint")
		w.Part0 = pivot
		w.Part1 = part
		w.Parent = part
		if part.Size.Z > barrel.Size.Z then
			barrel = part
		end
	end
	local sound = Instance.new("Sound")
	sound.SoundId = Config.Sounds.fire
	sound.Volume = 0.9
	sound.PlaybackSpeed = 0.8
	sound.RollOffMaxDistance = 250
	sound.Parent = pivot
	local cfg = Config.TurretGun
	state.gun = {
		joint = joint, pivotLocal = pivotLocal, yaw = 0, pitch = 0, targetYaw = 0, targetPitch = 0, recoil = 0, scale = k,
		barrel = barrel, sound = sound, mag = cfg.mag, reserve = cfg.reserve, reloadingUntil = 0, lastShot = 0,
	}
	state.model:SetAttribute("TurretMag", cfg.mag)
	state.model:SetAttribute("TurretReserve", cfg.reserve)
	state.model:SetAttribute("TurretReloading", false)
	state.model:SetAttribute("TurretReady", true)
end

local function setSmoke(state: VehicleState, on: boolean)
	if on and not state.smoke then
		local smoke = Instance.new("Smoke")
		smoke.Size = 6
		smoke.Opacity = 0.5
		smoke.RiseVelocity = 6
		smoke.Color = Color3.fromRGB(60, 60, 60)
		smoke.Parent = state.root
		state.smoke = smoke
	elseif not on and state.smoke then
		state.smoke:Destroy()
		state.smoke = nil
	end
end

-- Поломка: все высажены, управление отключено, остов горит и через время исчезает
local function wreck(state: VehicleState)
	state.wrecked = true
	ZombieService.unregisterTarget(state.model)
	state.model:SetAttribute("Wrecked", true)
	for _, seat in state.seats do
		eject(seat)
	end
	local root = state.root
	root.CustomPhysicalProperties = PhysicalProperties.new(state.tune.density, 1, 0, 100, 1) -- трение: остов не скользит
	local fire = Instance.new("Fire")
	fire.Size = 9
	fire.Heat = 8
	fire.Parent = root
	setSmoke(state, true)
	if R.wreckRemoveAfter > 0 then
		Debris:AddItem(state.model, R.wreckRemoveAfter)
	end
end

-- Зомби бьют машину, в которой кто-то сидит (как игрока): урон идёт в прочность; пустая машина зомби не интересует
local function refreshTarget(state: VehicleState)
	local occupied = false
	for _, seat in state.seats do
		if seat.Occupant then
			occupied = true
			break
		end
	end
	if occupied and not state.wrecked then
		ZombieService.registerTarget(state.model, state.root, function(amount: number)
			VehicleService.damage(state.model, amount)
		end)
	else
		ZombieService.unregisterTarget(state.model)
	end
end

-- Урон машине (давка боссов, авария, зомби и взрывы в будущем). Только сервер.
function VehicleService.damage(model: Model, amount: number)
	local state = vehicles[model]
	if not state or state.wrecked or amount <= 0 then
		return
	end
	state.hp = math.max(0, state.hp - amount)
	model:SetAttribute("Hp", state.hp)
	setSmoke(state, state.hp / state.maxHp < R.smokeFrac)
	if state.hp <= 0 then
		wreck(state)
	end
end

-- Починка (механик, ящик; будущее). Остов не чинится.
function VehicleService.repair(model: Model, amount: number)
	local state = vehicles[model]
	if not state or state.wrecked then
		return
	end
	state.hp = math.min(state.maxHp, state.hp + amount)
	model:SetAttribute("Hp", state.hp)
	setSmoke(state, state.hp / state.maxHp < R.smokeFrac)
end

-- Поставить машину (имя из Config.VehicleModels / шаблон из ServerStorage.CarModels) в точку cf (основание на землю y = cf.Y)
function VehicleService.spawn(modelName: string, cf: CFrame): Model?
	local spec = Config.VehicleModels[modelName]
	local tune = Config.VehicleTypes[if spec then spec.type else "Car"] or Config.VehicleTypes.Car
	local length = if spec then spec.length else Config.Vehicle.length
	local templateName = if spec and spec.template then spec.template else modelName

	local store = ServerStorage:FindFirstChild("CarModels")
	local template = store and store:FindFirstChild(templateName)
	if not template or not template:IsA("Model") or not template.PrimaryPart then
		warn("[VehicleService] no vehicle template " .. templateName)
		return nil
	end
	local model = template:Clone()
	model.Name = "Vehicle_" .. modelName
	local root = model.PrimaryPart :: BasePart
	local k = length / root.Size.Z -- масштаб относительно шаблона
	model:ScaleTo(k)
	model.Parent = container

	-- в шаблонах из Creator Store бывают свои сиденья (Seat/VehicleSeat) — убираем, водитель сядет на наше.
	-- Детали далеко от корпуса — забытые копии (у Coupe диски колёс в 840 студах): они раздувают сборку, и камера машины уезжает
	for _, d in model:GetDescendants() do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then
			d:Destroy()
		elseif d:IsA("BasePart") and d ~= root and root.CFrame:PointToObjectSpace(d.Position).Magnitude > length * 1.5 then
			d:Destroy()
		end
	end

	-- физика: корпус-коробка скользит почти без трения, остальные детали приварены и не мешают; плотность задаёт тип
	root.Anchored = false
	root.CanCollide = true
	root.CanQuery = true
	root.CollisionGroup = "Vehicle" -- с группой Curb (бордюры) не сталкивается: машины заезжают на тротуары
	root.CustomPhysicalProperties = PhysicalProperties.new(tune.density, 0, 0, 100, 1)
	local gunParts = if tune.turret and tune.turret.gunPivot then findGunParts(model) else {}
	local gunSet: { [BasePart]: boolean } = {}
	for _, gp in gunParts do
		gunSet[gp] = true
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root and not gunSet[d] then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			weldTo(root, d)
		end
	end

	model:PivotTo(cf * CFrame.new(0, root.Size.Y / 2 + 0.3, 0))
	model:SetAttribute("Vehicle", true)
	model:SetAttribute("VehicleType", tune.id)
	model:SetAttribute("Hp", tune.hp)
	model:SetAttribute("MaxHp", tune.hp)
	model:SetAttribute("Wrecked", false)

	local state: VehicleState = {
		model = model,
		root = root,
		seats = {},
		tune = tune,
		hp = tune.hp,
		maxHp = tune.hp,
		wrecked = false,
		lastSpeed = 0,
		lastPos = nil,
		lastAt = 0,
		jumpUntil = 0,
		lastHit = {},
		smoke = nil,
		gun = nil,
	}
	vehicles[model] = state
	if tune.seats <= 0 then
		return model -- не ездовая (декор): ни сидений, ни кнопки «Сесть»
	end

	-- места: 1 — водитель (ввод читает VehicleController на клиенте водителя), 2 — переднее пассажирское, 3–4 — задние,
	-- 0 — стрелок (если у типа есть турель). Сиденья невидимы и не садят по касанию, только по кнопке E или панели мест.
	local half = root.Size / 2
	local driverAttr = template:GetAttribute("DriverOffset")
	local frontZ = -root.Size.Z * 0.08
	local sideX = root.Size.X * 0.22
	if typeof(driverAttr) == "Vector3" then
		frontZ = math.clamp(driverAttr.Z * k, -half.Z + 1, half.Z - 3)
		sideX = math.clamp(math.abs(driverAttr.X * k), 1, half.X - 1)
	end
	local rearZ = math.min(frontZ + root.Size.Z * 0.28, half.Z - 1)
	local y = -half.Y + 1.6
	local spots: { [number]: Vector3 } = {
		[1] = Vector3.new(-sideX, y, frontZ),
		[2] = Vector3.new(sideX, y, frontZ),
		[3] = Vector3.new(-sideX, y, rearZ),
		[4] = Vector3.new(sideX, y, rearZ),
	}
	for index = 1, math.min(tune.seats, 4) do
		local seat: Seat | VehicleSeat
		if index == 1 then
			local vs = Instance.new("VehicleSeat")
			vs.Name = "DriverSeat"
			vs.MaxSpeed = 0
			vs.Torque = 0
			vs.TurnSpeed = 0
			seat = vs
		else
			local ps = Instance.new("Seat")
			ps.Name = "Seat" .. index
			seat = ps
		end
		seat.Size = Vector3.new(2, 0.6, 2)
		seat.Transparency = 1
		seat.CanCollide = false
		seat.CanTouch = false
		seat.Massless = true
		seat.Anchored = false
		seat:SetAttribute("SeatIndex", index)
		seat.CFrame = root.CFrame * CFrame.new(spots[index])
		seat.Parent = model
		weldTo(root, seat)
		state.seats[index] = seat
	end
	mountTurret(state, k)
	setupGun(state, k, gunParts)
	for _, seat in state.seats do
		-- севший отпускает оружие из рук (в машине не стреляем)
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occ = seat.Occupant
			if occ then
				occ:UnequipTools()
				-- сел водитель: физику корпуса — его клиенту (её мог забрать сервер, пока машина тормозила без водителя)
				local driver = if seat.Name == "DriverSeat" then Players:GetPlayerFromCharacter(occ.Parent) else nil
				if driver then
					pcall(function()
						root:SetNetworkOwner(driver)
					end)
				end
			end
			refreshTarget(state)
		end)
	end

	-- посадка по кнопке E: первое свободное место 1–4, потом турель
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Get in"
	prompt.ObjectText = tune.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = math.max(root.Size.X, root.Size.Z) / 2 + 6
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(player: Player)
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 or state.wrecked or hum.SeatPart or not PlayerService.isUp(player) then
			return
		end
		for _, index in { 1, 2, 3, 4, 0 } do
			local seat = state.seats[index]
			if seat and not seat.Occupant then
				seat:Sit(hum)
				return
			end
		end
	end)
	return model
end

-- Машины по точкам карты (map.carSpawns / map.carNames); расстановка запоминается для resetRound
function VehicleService.spawnAll(carSpawns: { CFrame }?, carNames: { string }?)
	table.clear(layout)
	for i, cf in carSpawns or {} do
		local name = carNames and carNames[i]
		if name then
			table.insert(layout, { name = name, cf = cf })
			VehicleService.spawn(name, cf)
		end
	end
end

-- Новый раунд: все машины (и разбитые остовы) убираем, сидящих высаживаем, ставим заново целыми и с полным пулемётом
function VehicleService.resetRound()
	if not container then
		return
	end
	for model, state in vehicles do
		ZombieService.unregisterTarget(model)
		for _, seat in state.seats do
			local occ = seat.Occupant
			if occ then
				occ.Sit = false
			end
		end
		model:Destroy()
	end
	table.clear(vehicles)
	for _, c in container:GetChildren() do
		c:Destroy()
	end
	for _, entry in layout do
		VehicleService.spawn(entry.name, entry.cf)
	end
end

-- Пулемёт ---------------------------------------------------------------------------------------------------------------

local rng = Random.new()

-- Машина, в чьём месте стрелка сидит игрок (и у которой есть пулемёт)
local function gunnerState(player: Player): VehicleState?
	if not PlayerService.isUp(player) then
		return nil
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local model = seat and seat.Parent
	local st = model and vehicles[model :: Model]
	if st and st.gun and not st.wrecked and st.seats[0] == seat then
		return st
	end
	return nil
end

local function onTurretAim(player: Player, dir: unknown)
	if typeof(dir) ~= "Vector3" or not RateLimit.allow(player, "TurretAim", 0.03) then
		return
	end
	local d = dir :: Vector3
	if not Validate.finiteVector(d) or d.Magnitude < 0.5 or d.Magnitude > 1.5 then
		return
	end
	local st = gunnerState(player)
	if not st or not st.gun then
		return
	end
	local v = st.root.CFrame:VectorToObjectSpace(d.Unit)
	local cfg = Config.TurretGun
	st.gun.targetYaw = math.atan2(-v.X, -v.Z)
	st.gun.targetPitch = math.clamp(math.asin(math.clamp(v.Y, -1, 1)), math.rad(cfg.minPitch), math.rad(cfg.maxPitch))
end

local function startReload(st: VehicleState)
	local g = st.gun
	local cfg = Config.TurretGun
	if not g or os.clock() < g.reloadingUntil or g.mag >= cfg.mag or g.reserve <= 0 then
		return
	end
	g.reloadingUntil = os.clock() + cfg.reload
	st.model:SetAttribute("TurretReloading", true)
	task.delay(cfg.reload, function()
		if not st.model.Parent or not st.gun then
			return
		end
		local take = math.min(cfg.mag - g.mag, g.reserve)
		g.mag += take
		g.reserve -= take
		st.model:SetAttribute("TurretMag", g.mag)
		st.model:SetAttribute("TurretReserve", g.reserve)
		st.model:SetAttribute("TurretReloading", false)
	end)
end

local function onTurretFire(player: Player)
	if not RateLimit.allow(player, "TurretFire", 0.03) then
		return
	end
	local st = gunnerState(player)
	local g = st and st.gun
	if not st or not g then
		return
	end
	local cfg = Config.TurretGun
	local now = os.clock()
	if now < g.reloadingUntil or now - g.lastShot < (1 / cfg.rate) * 0.85 then
		return
	end
	if g.mag <= 0 then
		startReload(st)
		return
	end
	g.mag -= 1
	g.lastShot = now
	g.recoil = cfg.recoil * g.scale
	st.model:SetAttribute("TurretMag", g.mag)
	local pivotCf = g.joint.Part1.CFrame
	local muzzle = g.barrel.CFrame:PointToWorldSpace(Vector3.new(0, 0, -g.barrel.Size.Z / 2))
	local spread = math.rad(cfg.spreadDeg)
	local dir = (CFrame.lookAt(Vector3.zero, pivotCf.LookVector) * CFrame.Angles(rng:NextNumber(-spread, spread), rng:NextNumber(-spread, spread), 0)).LookVector
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { st.model }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(muzzle, dir * cfg.range, params)
	local endPos = if result then result.Position else muzzle + dir * cfg.range
	if result then
		local zombie, isHead = ZombieService.isZombiePart(result.Instance :: BasePart)
		if zombie then
			local kind = ZombieService.partKind(result.Instance :: BasePart)
			local mult = if isHead then Config.Economy.HeadshotMultiplier elseif kind == "Arm" or kind == "Leg" then Config.Economy.LimbMultiplier else 1
			local dmg = cfg.damage * mult
			local applied, killed = ZombieService.damage(zombie, dmg, player, { dir = dir, push = 3, stagger = 0.1, part = result.Instance :: BasePart, power = 0.5 })
			if applied then
				EconomyService.add(player, Config.Economy.CoinsPerHit)
				Remotes.get("HitFeedback"):FireClient(player, result.Position, math.floor(dmg + 0.5), killed, isHead)
			end
		end
	end
	-- вспышка, трассер, звук
	local length = (endPos - muzzle).Magnitude
	local tracer = Instance.new("Part")
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 215, 120)
	tracer.Size = Vector3.new(0.12, 0.12, math.max(length, 0.1))
	tracer.CFrame = CFrame.lookAt(muzzle + dir * length / 2, endPos)
	tracer.Parent = workspace
	Debris:AddItem(tracer, 0.05)
	local flash = Instance.new("Part")
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 190, 80)
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.one * 1.6
	flash.CFrame = CFrame.new(muzzle + dir * 0.6)
	flash.Parent = workspace
	Debris:AddItem(flash, 0.04)
	g.sound.TimePosition = 0
	g.sound:Play()
	if g.mag <= 0 then
		startReload(st)
	end
end

local function onTurretReload(player: Player)
	if not RateLimit.allow(player, "TurretReload", 0.3) then
		return
	end
	local st = gunnerState(player)
	if st then
		startReload(st)
	end
end

-- Пересесть: клиент присылает номер места; сервер проверяет, что игрок сидит в этой же машине и место свободно
local function onSwitchSeat(player: Player, index: unknown)
	if typeof(index) ~= "number" or index % 1 ~= 0 or index < 0 or index > 4 or not RateLimit.allow(player, "SeatSwitch", 0.4) then
		return
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local current = hum and hum.SeatPart
	local state = current and current.Parent and vehicles[current.Parent :: Model]
	if not hum or not current or not state or state.wrecked or not PlayerService.isUp(player) then
		return
	end
	local target = state.seats[index]
	if not target or target.Occupant or target == current then
		return
	end
	hum.Sit = false
	task.defer(function()
		if not state.wrecked and not target.Occupant and hum.Health > 0 then
			target:Sit(hum)
		end
	end)
end

-- Давка и авария одной машины (раз в TICK)
local function step(state: VehicleState, now: number)
	local root = state.root
	local v = root.AssemblyLinearVelocity
	local planar = Vector3.new(v.X, 0, v.Z)
	local speed = planar.Magnitude

	-- скачок позиции с прошлой проверки: не давим и не считаем аварию (иначе изменённый клиент «телепортирует» машину в толпу)
	local pos = root.Position
	local lastPos = state.lastPos
	local elapsed = now - state.lastAt
	state.lastPos = pos
	state.lastAt = now
	if lastPos then
		local moved = Vector3.new(pos.X - lastPos.X, 0, pos.Z - lastPos.Z).Magnitude
		if moved > state.tune.maxSpeed * elapsed * JUMP_FACTOR + JUMP_SLACK then
			state.jumpUntil = now + JUMP_PAUSE
		end
	end
	if now < state.jumpUntil then
		state.lastSpeed = speed
		return
	end

	local driver = occupantPlayer(state.seats[1])
	-- авария: резкая потеря скорости (удар о стену, босса); считаем только с водителем, чтобы не ловить физические артефакты
	local drop = state.lastSpeed - speed
	state.lastSpeed = speed
	if driver and drop > R.crashDecel then
		VehicleService.damage(state.model, (drop - R.crashDecel) * R.crashDamage)
		if state.wrecked then
			return
		end
	end
	if not driver or speed < R.minSpeed then
		return
	end

	-- давка: зомби, чьи корни внутри коробки корпуса (с запасом) впереди по ходу движения
	local cf = root.CFrame
	local half = root.Size / 2
	local dir = planar.Unit
	local effSpeed = math.min(speed, state.tune.maxSpeed * 1.2) -- скорость присылает клиент водителя: берём с потолком типа
	for _, z in ZombieService.queryNear(root.Position, half.Magnitude + R.margin + 2) do
		local last = state.lastHit[z.model]
		if last and now - last < R.cooldown then
			continue
		end
		local rel = cf:PointToObjectSpace(z.root.Position)
		if
			math.abs(rel.X) <= half.X + R.margin
			and math.abs(rel.Z) <= half.Z + R.margin
			and math.abs(rel.Y) <= half.Y + 3
			and (z.root.Position - cf.Position):Dot(dir) > 0
		then
			local def = ZombieService.defOf(z.model)
			if def then
				state.lastHit[z.model] = now
				if string.sub(def.id, 1, 4) == "Boss" then
					VehicleService.damage(state.model, R.bossHit) -- боссов не давим: бьёмся о них
				else
					local dmg = (R.base + R.perSpeed * (effSpeed - R.minSpeed)) * state.tune.ramMult
					ZombieService.damage(z.model, dmg, driver, { dir = dir, push = R.push, stagger = 1, power = 2 })
					VehicleService.damage(state.model, R.selfPerHit)
				end
				if state.wrecked then
					return
				end
			end
		end
	end
end

function VehicleService.init()
	container = Instance.new("Folder")
	container.Name = "Vehicles"
	container.Parent = workspace

	-- бордюры и тротуары (низкие бетонные детали дорог) не мешают корпусу машины; потерю скорости считает VehicleController
	for _, g in { "Vehicle", "Curb" } do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(g)
		end)
	end
	PhysicsService:CollisionGroupSetCollidable("Vehicle", "Curb", false)
	local roads = workspace:FindFirstChild("Roads")
	if roads then
		local tagged = 0
		for _, d in roads:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "Road" and d.CanCollide and d.Material == Enum.Material.Concrete and d.Size.Y >= 0.35 and d.Size.Y <= 1.6 then
				d.CollisionGroup = "Curb"
				tagged += 1
			end
		end
		print("[VehicleService] curbs/sidewalks marked: " .. tagged)
	end
	Remotes.get("SwitchSeat").OnServerEvent:Connect(onSwitchSeat)
	Remotes.get("TurretAim").OnServerEvent:Connect(onTurretAim)
	Remotes.get("TurretFire").OnServerEvent:Connect(onTurretFire)
	Remotes.get("TurretReload").OnServerEvent:Connect(onTurretReload)

	-- каждый кадр: ствол плавно доворачивается к цели, откат после выстрела
	RunService.Heartbeat:Connect(function(dt: number)
		local cfg = Config.TurretGun
		for _, st in vehicles do
			local g = st.gun
			if g and not st.wrecked then
				local dy = (g.targetYaw - g.yaw + math.pi) % (2 * math.pi) - math.pi
				local dp = g.targetPitch - g.pitch
				g.yaw += math.clamp(dy, -dt * cfg.yawRate, dt * cfg.yawRate)
				g.pitch += math.clamp(dp, -dt * 3, dt * 3)
				g.recoil *= math.exp(-18 * dt)
				if math.abs(dy) > 1e-4 or math.abs(dp) > 1e-4 or g.recoil > 1e-3 then
					g.joint.C0 = CFrame.new(g.pivotLocal) * CFrame.Angles(0, g.yaw, 0) * CFrame.Angles(g.pitch, 0, 0) * CFrame.new(0, 0, g.recoil)
				end
			end
		end
	end)

	-- Водитель вышел: машину ведёт сервер и сам тормозит (Config.Vehicle.parkBrake студов/с²), а не катится по инерции как по льду
	RunService.Heartbeat:Connect(function(dt: number)
		for _, st in vehicles do
			local seat = st.seats[1]
			if seat and not seat.Occupant and not st.wrecked and st.root.Parent then
				local v = st.root.AssemblyLinearVelocity
				local planar = Vector3.new(v.X, 0, v.Z)
				if planar.Magnitude > 0.2 or st.root.AssemblyAngularVelocity.Magnitude > 0.05 then
					if st.root:GetNetworkOwner() ~= nil then
						pcall(function()
							st.root:SetNetworkOwner(nil)
						end)
					end
					local slow = math.max(0, planar.Magnitude - Config.Vehicle.parkBrake * dt)
					local kept = if planar.Magnitude > 0 then planar.Unit * slow else Vector3.zero
					st.root.AssemblyLinearVelocity = Vector3.new(kept.X, v.Y, kept.Z)
					st.root.AssemblyAngularVelocity = st.root.AssemblyAngularVelocity * math.max(0, 1 - 6 * dt)
				end
			end
		end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < TICK then
			return
		end
		acc = 0
		local now = os.clock()
		for model, state in vehicles do
			if not model.Parent then
				vehicles[model] = nil
			elseif not state.wrecked then
				step(state, now)
			end
		end
	end)
end

return VehicleService
