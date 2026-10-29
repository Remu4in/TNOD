--!strict
-- Миссии ночи (сюжет: docs/story.md). Ночь = миссия из Config.Missions[ночь]: точка миссии (место шатра района), задача и «поток» зомби,
-- который идёт со всех сторон на расстоянии 100–150 студов от точки (ZombieService.setAnchor), пока задача не выполнена.
--   scout   — разведка: обойти контрольные точки вокруг места шатра (радиус — radius в Config.Missions, по умолчанию Config.ScoutRadius 50–100 студов; поток без конца)
--   build   — установка шатра: убить N мутантов, затем удерживать «Установить шатёр» у места (поток без конца)
--   escort  — конвой: грузовик с двумя солдатами объезжает контрольные точки и встаёт на дороге у места шатра (ConvoyService);
--             с install = true после приезда ещё надо установить шатёр (иначе шатёр района ставится сам при прибытии)
--   defend  — защита шатра: продержаться SECONDS секунд рядом (поток без конца)
--   clear / classic — убить всю волну
-- Места шатров — ServerStorage.Assets.TentSites.Site_<n> (шатёр + припасы + автомат), шатёр базы (Workspace.Base.Tent) — точка 5.
-- Игроки идут к месту миссии сами (Config.MissionMoveTeam = false), место отмечено высоким маяком.
-- Статус для клиентов — атрибуты ReplicatedStorage: MissionTitle, MissionText, MissionKind.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local ConvoyService = require(script.Parent:WaitForChild("ConvoyService"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))
local RoadRoute = require(script.Parent:WaitForChild("RoadRoute"))
local VendorService = require(script.Parent:WaitForChild("VendorService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))
local DebrisKit = require(script.Parent:WaitForChild("DebrisKit"))
local BarricadeService = require(script.Parent:WaitForChild("BarricadeService"))
local BaseBattleService = require(script.Parent:WaitForChild("BaseBattleService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local AmmoCrateService = require(script.Parent:WaitForChild("AmmoCrateService"))

local MissionService = {}

type Point = { pos: Vector3, part: BasePart, done: boolean }
type State = {
	def: Config.MissionDef,
	kind: string,
	night: number,
	anchor: Vector3,
	site: number,
	points: { Point },
	secondsLeft: number,
	infinite: boolean,
	comp: WaveMath.Composition,
	hpMult: number,
	lastText: string,
	kills: number,
	playerKills: number, -- убийства игроков (турель и машина — владельцу) за ночь
	minKills: number, -- сколько их нужно, чтобы миссия засчиталась (Config.MissionMinKills)
	phase: string, -- escort: "drive" → "install"; build: "kill" → "install"; metro: "approach" → "inside"
	metroKills: number,
	sitePart: BasePart?,
	prompt: ProximityPrompt?,
	installed: boolean,
	bossIndex: number, -- bossfight: номер вышедшего босса из def.bosses
	nestsBurned: number, -- metro: сожжено гнёзд
	bossOut: boolean, -- metro: босс станции уже вызван
	bossSeen: boolean, -- metro: босс появился (миссия ждёт его смерти)
	gensOn: number, -- metro: запущено генераторов
	tnt: number, -- metro: установлено зарядов ТНТ
	detStage: number, -- metro: детонатор: 0 — выключен, 1 — оборона, 2 — заряды сработали
	defendLeft: number, -- metro: секунд обороны детонатора осталось
	detPos: Vector3, -- metro: позиция детонатора
	hasKey: boolean, -- metro: SkeletonKey у команды
	keyOut: boolean, -- metro: ключ уже выпал
	tntModels: { Model }, -- metro: установленные заряды
	actions: { [string]: (Player) -> () }, -- metro: обработчики подсказок финала (в Studio их вызывает MissionService.debugInteract)
}

local current: State? = nil
local hubFolder: Folder? = nil -- тоннель в горе после метро: майор, ящики с припасами (джип создаёт VehicleService)
local objects: Folder? = nil
local finalePos: Vector3? = nil -- финал акта 1: вход в бункер (MissionService.beginFinale)
local rng = Random.new()
local installedSites: { [number]: { instances: { Instance }, shop: Vector3?, vending: { string } } } = {}
local suppliedSites: { [number]: { Instance } } = {}

-- Подписи маяка места миссии по типу
local PLACE_LABELS: { [string]: string } = {
	scout = "Scouting area", build = "Tent site", escort = "Tent site", defend = "Tent: defense", metro = "Metro entrance", classic = "Combat zone", clear = "Combat zone", bossfight = "Arena",
}

local GROUND_FOLDERS = { "Roads", "Ground", "Grass" }

local function isGround(inst: Instance): boolean
	for _, name in GROUND_FOLDERS do
		local f = workspace:FindFirstChild(name)
		if f and inst:IsDescendantOf(f) then
			return true
		end
	end
	return false
end

-- Точка на земле под (x, z): только дороги, земля и трава (не крыши зданий). Луч идёт только по этим папкам: раньше он останавливался на
-- первой же крыше, и в застроенном районе (ночь 4, 100–150 студов) почти все точки отбраковывались; «пол внутри здания» отсекает проверка крыши ниже
local function groundAt(x: number, z: number, roadsOnly: boolean?): Vector3?
	local include: { Instance } = {}
	for _, name in GROUND_FOLDERS do
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
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0), params)
	if hit and hit.Normal.Y > 0.9 and isGround(hit.Instance) then
		if roadsOnly then
			local roads = workspace:FindFirstChild("Roads")
			if not roads or not hit.Instance:IsDescendantOf(roads) then
				return nil
			end
		end
		local up = workspace:Raycast(hit.Position + Vector3.new(0, 2, 0), Vector3.new(0, 60, 0))
		if not up then
			return hit.Position
		end
	end
	return nil
end

local function siteFolder(site: number): Folder?
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("TentSites")
	return lib and lib:FindFirstChild("Site_" .. site) :: Folder?
end

local function playerSpawnPosition(): Vector3
	local markers = workspace:FindFirstChild("Markers")
	local ps = markers and markers:FindFirstChild("PlayerSpawn") :: BasePart?
	return if ps then ps.Position else Vector3.zero
end

-- Место шатра района (1–4 — места установки, 5 — шатёр на базе)
function MissionService.anchorPosition(index: number): Vector3
	if index == 6 then
		-- вход в метро (маркер у верхней площадки лестницы)
		local markers = workspace:FindFirstChild("Markers")
		local top = markers and markers:FindFirstChild("Metro_EntranceTop") :: BasePart?
		if top then
			return top.Position
		end
	end
	local f = siteFolder(index)
	local pos = f and f:GetAttribute("SitePos")
	if typeof(pos) == "Vector3" then
		return pos
	end
	local base = workspace:FindFirstChild("Base")
	if base then
		for _, c in base:GetChildren() do
			if c.Name == "Tent" and c:IsA("Model") then
				return c:GetPivot().Position
			end
		end
	end
	return playerSpawnPosition()
end

-- Пешком можно дойти от a до b (PathfindingService): точка не должна оказаться за забором или на недоступном пятачке.
-- Сам сервис недоступен (pcall) — считаем, что дойти можно.
local function walkable(a: Vector3, b: Vector3): boolean
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local ok = pcall(function()
		path:ComputeAsync(a + Vector3.new(0, 3, 0), b + Vector3.new(0, 3, 0))
	end)
	return not ok or path.Status ~= Enum.PathStatus.NoPath
end

-- Свободно ли над землёй место для маяка: нет твёрдых деталей (стены, машины, ящики) в коробке 6×6×6 над точкой
local function openSpot(p: Vector3): boolean
	for _, part in workspace:GetPartBoundsInBox(CFrame.new(p + Vector3.new(0, 3.5, 0)), Vector3.new(6, 6, 6)) do
		if part.CanCollide and not isGround(part) then
			return false
		end
	end
	return true
end

-- Контрольные точки района: одни и те же для разведки и конвоя (детерминированно по номеру района), радиус radius (по умолчанию
-- Config.ScoutRadius = 50–100 студов) от места шатра, поровну по кругу: сектор на каждую точку.
-- grid — для конвоя: точки ставятся на дорогу (ближайшая проходимая клетка в 45 студах), без дороги точка не берётся;
-- без grid (разведка) — на землю (Roads / Ground / Grass, ровно, без крыши над головой, не в коробке из деталей) и только там, куда можно дойти
-- пешком от места шатра. Если в секторе точка не нашлась, угол и радиус меняются (до 24 попыток на сектор); не хватило — любой угол
-- (ещё 120 попыток); не нашлось ни одной — последний проход без проверки пути. Меньше нужного — warn и столько, сколько нашлось.
local function districtPoints(anchorIndex: number, count: number, grid: RoadRoute.Grid?, radiusRange: { number }?): { Vector3 }
	local seeded = Random.new(7000 + anchorIndex * 31)
	local anchor = MissionService.anchorPosition(anchorIndex)
	local rr = radiusRange or Config.ScoutRadius
	local list: { Vector3 } = {}
	local function farEnough(p: Vector3): boolean
		for _, q in list do
			if Vector3.new(p.X - q.X, 0, p.Z - q.Z).Magnitude < 20 then
				return false
			end
		end
		return true
	end
	if grid then
		local tries = 0
		while #list < count and tries < 120 do
			tries += 1
			-- на дороге сектор, где её нет, не должен держать поиск: сектора идут по кругу, каждая попытка — следующий
			local sector = (tries - 1) % count
			local angle = (sector / count) * math.pi * 2 + (seeded:NextNumber() - 0.5) * 0.3
			local radius = rr[1] + seeded:NextNumber() * (rr[2] - rr[1])
			local p = grid.snap(Vector3.new(anchor.X + math.cos(angle) * radius, 0, anchor.Z + math.sin(angle) * radius), 45)
			if p and farEnough(p) then
				table.insert(list, p)
			end
		end
		return list
	end
	local width = math.pi * 2 / count
	local function candidate(angle: number, needWalk: boolean): Vector3?
		local radius = rr[1] + seeded:NextNumber() * (rr[2] - rr[1])
		local p = groundAt(anchor.X + math.cos(angle) * radius, anchor.Z + math.sin(angle) * radius)
		if p and farEnough(p) and openSpot(p) and (not needWalk or walkable(anchor, p)) then
			return p
		end
		return nil
	end
	for sector = 0, count - 1 do
		for _ = 1, 24 do
			local p = candidate((sector + seeded:NextNumber()) * width, true)
			if p then
				table.insert(list, p)
				break
			end
		end
	end
	local tries = 0
	while #list < count and tries < 120 do
		tries += 1
		local p = candidate(seeded:NextNumber() * math.pi * 2, true)
		if p then
			table.insert(list, p)
		end
	end
	tries = 0
	while #list == 0 and tries < 120 do
		tries += 1
		local p = candidate(seeded:NextNumber() * math.pi * 2, false)
		if p then
			table.insert(list, p)
		end
	end
	if #list < count then
		warn(string.format("[MissionService] scouting points of the area %d: found %d of %d (radius %d–%d)", anchorIndex, #list, count, rr[1], rr[2]))
	end
	return list
end

-- Ближайшая к месту шатра дорога (для остановки конвоя): проходимая клетка дороги в 150 студах
local function roadStopNear(grid: RoadRoute.Grid, site: Vector3): Vector3?
	return grid.snap(site, 150)
end

-- Минимум убийств игроков для засчёта миссии: от Solo (1 игрок) до Full (FullPlayers игроков), линейно по числу игроков в начале ночи;
-- тестовый масштаб волн применяется так же, как к убийствам метро
local function minKillsFor(players: number): number
	local K = Config.MissionMinKills
	local k = math.clamp((players - 1) / math.max(1, K.FullPlayers - 1), 0, 1)
	local base = math.floor(K.Solo + (K.Full - K.Solo) * k + 0.5)
	return math.max(Config.MissionKillsFloor, math.floor(base * (Config.Waves.CountScale or 1) + 0.5))
end

-- Мешки с песком (Base.Fort), перекрывающие выезд из начальной зоны: на ночь конвоя (clearSandbags) уносим в ServerStorage, на рассвете возвращаем
local hiddenSandbags: { { model: Instance, parent: Instance } } = {}
local resolvedState: any = nil -- миссия, итог которой (награда или разрушение шатра) уже применён

local function setSandbags(removed: boolean)
	if removed then
		if #hiddenSandbags > 0 then
			return
		end
		local folder = workspace:FindFirstChild(Config.Convoy.SandbagFolder)
		if not folder then
			return
		end
		local holder = ServerStorage:FindFirstChild("HiddenSandbags")
		if not holder then
			holder = Instance.new("Folder")
			holder.Name = "HiddenSandbags"
			holder.Parent = ServerStorage
		end
		for _, c in folder:GetChildren() do
			if c.Name == Config.Convoy.SandbagName then
				table.insert(hiddenSandbags, { model = c, parent = folder })
				c.Parent = holder
			end
		end
	else
		for _, e in hiddenSandbags do
			if e.parent.Parent then
				e.model.Parent = e.parent
			end
		end
		table.clear(hiddenSandbags)
	end
end

local function setStatus(title: string, text: string, kind: string)
	ReplicatedStorage:SetAttribute("MissionTitle", title)
	ReplicatedStorage:SetAttribute("MissionText", text)
	ReplicatedStorage:SetAttribute("MissionKind", kind)
end

local function notify(text: string, seconds: number)
	Remotes.get("Notify"):FireAllClients(text, seconds)
end

-- Метка на земле (контрольные точки разведки, маршрут конвоя, место миссии): полупрозрачный светящийся круг радиуса radius с яркой кромкой,
-- мягкий свет и медленные искры вверх. Издалека видна метка в HUD (BillboardGui поверх всего с дистанцией — её обновляет MissionController
-- по тегу MissionZone): столб не нужен, а метка видна и сквозь дома, и в тумане. Радиус точки разведки = радиус засчитывания (Config.ScoutPointRadius).
local function makeBeacon(pos: Vector3, label: string, color: Color3?, radius: number?): BasePart
	local r = radius or Config.ScoutPointRadius
	local col = color or Config.ScoutPointColor
	local function disc(name: string, diameter: number, thick: number, transparency: number, lift: number): Part
		local d = Instance.new("Part")
		d.Name = name
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.CastShadow = false
		d.Shape = Enum.PartType.Cylinder
		d.Material = Enum.Material.Neon
		d.Color = col
		d.Transparency = transparency
		d.Size = Vector3.new(thick, diameter, diameter)
		d.CFrame = CFrame.new(pos + Vector3.new(0, lift, 0)) * CFrame.Angles(0, 0, math.rad(90))
		return d
	end
	local part = disc("ScoutBeacon", r * 2, 0.2, 0.5, 0.2) -- кромка: внешний диск ярче внутреннего
	local inner = disc("Fill", r * 2 - 1.2, 0.2, 0.78, 0.26)
	inner.Parent = part
	local light = Instance.new("PointLight")
	light.Color = col
	light.Brightness = 1.6
	light.Range = r * 2 + 8
	light.Shadows = false
	light.Parent = part
	-- искры поднимаются над кругом (вписанный квадрат, чтобы не вылетали за круг)
	local emitterPart = Instance.new("Part")
	emitterPart.Name = "Sparks"
	emitterPart.Anchored = true
	emitterPart.CanCollide = false
	emitterPart.CanQuery = false
	emitterPart.CanTouch = false
	emitterPart.Transparency = 1
	emitterPart.Size = Vector3.new(r * 1.4, 0.2, r * 1.4)
	emitterPart.CFrame = CFrame.new(pos + Vector3.new(0, 0.4, 0))
	emitterPart.Parent = part
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(col)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.3), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(2.5, 4)
	emitter.Speed = NumberRange.new(1, 2.5)
	emitter.Rate = math.max(4, r * 0.9)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Drag = 0.5
	emitter.Parent = emitterPart
	-- метка в HUD
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(Config.MissionLabel.Width, Config.MissionLabel.Height)
	gui.StudsOffset = Vector3.new(0, 7, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = Config.MissionLabel.MaxDistance
	gui.Parent = part
	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextColor3 = col:Lerp(Color3.new(1, 1, 1), 0.4)
	text.TextTransparency = Config.MissionLabel.TextTransparency
	text.TextStrokeTransparency = Config.MissionLabel.StrokeTransparency
	text.Text = "◆ " .. label
	text.Parent = gui
	part:SetAttribute("BaseText", "◆ " .. label)
	CollectionService:AddTag(part, "MissionZone")
	part.Parent = objects
	return part
end

local function upPositions(): { Vector3 }
	local list: { Vector3 } = {}
	for _, p in PlayerService.upPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			table.insert(list, r.Position)
		end
	end
	return list
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Команда выдвигается к точке миссии: ставим игроков на землю рядом с ней
local function moveTeam(anchor: Vector3)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if char then
			local angle = rng:NextNumber() * math.pi * 2
			local radius = 8 + rng:NextNumber() * 8
			local x, z = anchor.X + math.cos(angle) * radius, anchor.Z + math.sin(angle) * radius
			local ground = groundAt(x, z) or anchor
			char:PivotTo(CFrame.new(ground + Vector3.new(0, 4, 0)))
		end
	end
end

-- Припасы района: ящики из Site_<n>/Supplies появляются рядом и внутри шатра (с конвоем или при установке)
local function dropSupplies(site: number)
	if suppliedSites[site] then
		return
	end
	local f = siteFolder(site)
	local supplies = f and f:FindFirstChild("Supplies")
	local list: { Instance } = {}
	if supplies then
		local target = workspace:FindFirstChild("Decor")
		local dest = target and target:FindFirstChild("TentCrates") or workspace
		for _, c in supplies:GetChildren() do
			local clone = c:Clone()
			clone.Parent = dest
			table.insert(list, clone)
		end
	end
	suppliedSites[site] = list
end

-- Установка шатра района: модель, припасы, автомат и магазин (ShopService)
local function installTent(site: number)
	if installedSites[site] then
		return
	end
	local f = siteFolder(site)
	local tent = f and f:FindFirstChild("Tent") :: Model?
	if not f or not tent then
		return
	end
	local rec: { instances: { Instance }, shop: Vector3?, vending: { string } } = { instances = {}, shop = nil, vending = {} }
	local clone = tent:Clone()
	clone.Parent = workspace:FindFirstChild("Base") or workspace
	table.insert(rec.instances, clone)
	dropSupplies(site)
	local vend = f:FindFirstChild("Vending")
	local markers = workspace:FindFirstChild("Markers")
	if vend and markers then
		for _, m in vend:GetChildren() do
			local mc = m:Clone()
			mc.Parent = markers
			table.insert(rec.instances, mc)
			if mc:IsA("BasePart") then
				VendorService.addVending(mc)
				table.insert(rec.vending, mc.Name)
			end
		end
	end
	local cf, size = clone:GetBoundingBox()
	local center = Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z)
	ShopService.addPoint("Military tent", center, math.max(size.X, size.Z) / 2 + 18, false, true, true)
	rec.shop = center
	installedSites[site] = rec
end

function MissionService.isInstalled(site: number): boolean
	return installedSites[site] ~= nil
end

-- Новый раунд: убираем установленные шатры, их автоматы и припасы
-- Шатёр района, разрушенный провалом конвоя: на его месте лежат обломки (до конца раунда)
local rubbleSites: { [number]: { Instance } } = {}

local function clearRubble()
	for _, list in rubbleSites do
		for _, i in list do
			i:Destroy()
		end
	end
	table.clear(rubbleSites)
end

-- Обломки на месте шатра при провале конвоя: процедурная куча (остов грузовика, ящики, бочки, шины, ткань, бетон, копоть, дым — DebrisKit, числа Config.Rubble).
-- Убирается при сбросе раунда (clearRubble). Сид по номеру района — картина повторяется.
local function buildRubble(site: number, center: Vector3): { Instance }
	return { DebrisKit.build("TentRubble_" .. site, center, site * 97, Config.Rubble) }
end

-- Провал конвоя: шатёр района (если уже стоял) убирается с автоматом, магазином и припасами; на его месте — обломки (всегда, даже если шатёр
-- ещё не ставили: ночи 12 и 17, конвой погиб до установки)
local function destroyTent(site: number)
	local rec = installedSites[site]
	local center = rec and rec.shop
	if not center then
		local f = siteFolder(site)
		local sp = f and f:GetAttribute("SitePos")
		center = if typeof(sp) == "Vector3" then sp else MissionService.anchorPosition(site)
	end
	if rec then
		for _, name in rec.vending do
			VendorService.removeVending(name)
		end
		for _, i in rec.instances do
			i:Destroy()
		end
		if rec.shop then
			ShopService.removePointAt(rec.shop)
		end
		installedSites[site] = nil
	end
	local supplies = suppliedSites[site]
	if supplies then
		for _, i in supplies do
			i:Destroy()
		end
		suppliedSites[site] = nil
	end
	local old = rubbleSites[site]
	if old then
		for _, i in old do
			i:Destroy()
		end
	end
	rubbleSites[site] = buildRubble(site, center :: Vector3)
end

function MissionService.resetRound()
	MissionService.finish()
	BaseBattleService.reset()
	clearRubble()
	for _, rec in installedSites do
		for _, name in rec.vending do
			VendorService.removeVending(name)
		end
		for _, i in rec.instances do
			i:Destroy()
		end
		if rec.shop then
			ShopService.removePointAt(rec.shop)
		end
	end
	table.clear(installedSites)
	for _, list in suppliedSites do
		for _, i in list do
			i:Destroy()
		end
	end
	table.clear(suppliedSites)
end

-- Метка места шатра с подсказкой «удерживайте E»
local function makeSiteMarker(state: State, enabled: boolean)
	local part = Instance.new("Part")
	part.Name = "TentSiteMarker"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 200, 60)
	part.Transparency = 0.5
	part.Size = Vector3.new(26, 0.4, 26)
	part.Shape = Enum.PartType.Cylinder
	part.CFrame = CFrame.new(state.anchor + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(Config.MissionLabel.Width, Config.MissionLabel.Height)
	gui.StudsOffset = Vector3.new(0, 10, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = Config.MissionLabel.MaxDistance
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 220, 90)
	label.TextTransparency = Config.MissionLabel.TextTransparency
	label.TextStrokeTransparency = Config.MissionLabel.StrokeTransparency
	label.Name = "Label"
	label.Text = "◆ Tent site"
	label.Parent = gui
	part:SetAttribute("BaseText", "◆ Tent site")
	CollectionService:AddTag(part, "MissionZone")
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Set up the tent"
	prompt.ObjectText = "Tent"
	prompt.HoldDuration = Config.Convoy.InstallHold
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.Enabled = enabled
	prompt.Parent = part
	prompt.Triggered:Connect(function(player: Player)
		local s = current
		if s and s == state and s.phase == "install" and PlayerService.isUp(player) then
			installTent(s.site)
			s.installed = true
			notify("Tent set up!", 4)
		end
	end)
	part.Parent = objects
	state.sitePart = part
	state.prompt = prompt
end

-- Ночь 19, «бойня на базе»: вместо состава волны — Config.BaseBattle.Total зомби потоком со стороны базы (точки появления внутри Config.BaseZone, одновременно
-- не больше AliveCap), баррикады на базе убраны, защитники у стартовой точки игроков, убитые солдаты и обломки (BaseBattleService)
local function setupBaseBattle(night: number, comp: WaveMath.Composition, hpMult: number)
	local B = Config.BaseBattle
	local Z = Config.BaseZone
	local total = math.max(10, math.floor(B.Total * (Config.Waves.CountScale or 1) + 0.5))
	-- состав волны пересчитываем на нужное число (боссов в потоке нет)
	local normal: WaveMath.Composition = {}
	local sum = 0
	for id, n in comp do
		if not WaveMath.isBossType(id) then
			normal[id] = n
			sum += n
		end
	end
	local scaled: WaveMath.Composition = {}
	local given, biggest = 0, "Walker"
	for id, n in normal do
		local k = math.floor(n / math.max(sum, 1) * total)
		scaled[id] = k
		given += k
		if k > (scaled[biggest] or 0) then
			biggest = id
		end
	end
	scaled[biggest] = (scaled[biggest] or 0) + (total - given) -- остаток от округления — самому частому
	ZombieService.clearQueue()
	ZombieService.enqueue(WaveMath.spawnQueue(scaled, rng), hpMult, night)
	-- точки появления: на земле внутри базы, подальше от ворот (z растёт вглубь базы), не на крышах
	local points: { Vector3 } = {}
	local seeded = Random.new(1901)
	local tries = 0
	while #points < B.SpawnPoints and tries < 600 do
		tries += 1
		local p = groundAt(seeded:NextNumber(Z.minX + 10, Z.maxX - 10), seeded:NextNumber(Z.minZ + 25, Z.maxZ - 10))
		if p and openSpot(p) then
			local near = false
			for _, q in points do
				if flatDist(p, q) < 16 then
					near = true
					break
				end
			end
			if not near then
				table.insert(points, p)
			end
		end
	end
	if #points == 0 then
		warn("[MissionService] night 19: no spawn points found at the base — zombies will form a ring around the base")
		ZombieService.setAnchor(MissionService.anchorPosition(5))
	else
		ZombieService.setAnchor(nil)
		ZombieService.setSpawnPoints(points)
	end
	ZombieService.setAliveCap(B.AliveCap)
	BarricadeService.clearRegion(Z.minX, Z.maxX, Z.minZ, Z.maxZ)
	BaseBattleService.start(playerSpawnPosition())
end

-- Начало ночи: comp/hpMult — состав и здоровье волны (для подпитки бесконечного потока)
function MissionService.begin(night: number, comp: WaveMath.Composition, hpMult: number, players: number): (boolean, string)
	MissionService.finish()
	if hubFolder then
		hubFolder:Destroy() -- майор и припасы тоннеля нужны только до начала следующей ночи
		hubFolder = nil
	end
	local def: Config.MissionDef = Config.Missions[night] or { type = "classic", title = string.format("Night %d", night), anchor = 1 }
	local anchor = MissionService.anchorPosition(def.anchor)
	objects = Instance.new("Folder")
	objects.Name = "MissionObjects"
	objects.Parent = workspace
	local kind = def.type
	local known = { scout = true, defend = true, clear = true, build = true, escort = true, metro = true, bossfight = true }
	if not known[kind] then
		kind = "classic"
	end
	local state: State = {
		def = def, kind = kind, night = night, anchor = anchor, site = def.anchor, points = {}, secondsLeft = def.seconds or 0,
		infinite = kind == "scout" or kind == "defend" or kind == "build" or kind == "escort" or kind == "metro", comp = comp, hpMult = hpMult, lastText = "",
		kills = 0, playerKills = 0, minKills = minKillsFor(players), metroKills = 0, phase = if kind == "build" then "kill" elseif kind == "metro" then "approach" else "drive", sitePart = nil, prompt = nil, installed = false, bossIndex = 0, nestsBurned = 0, bossOut = false, bossSeen = false, gensOn = 0, tnt = 0, detStage = 0, defendLeft = 0, detPos = Vector3.zero, hasKey = false, keyOut = false, tntModels = {}, actions = {},
	}
	current = state
	ZombieService.setAnchor(anchor)
	if def.baseBattle then
		setupBaseBattle(night, comp, hpMult)
	end
	if kind == "bossfight" then
		-- финальный босс-файт: вместо состава волны — только боссы из def.bosses по очереди, обычных зомби нет, минимума убийств нет
		state.minKills = 0
		ZombieService.clearQueue()
		local list = def.bosses or { "BossStrong" }
		state.bossIndex = 1
		ZombieService.enqueue({ list[1] }, hpMult, night, true)
		ZombieService.setAliveCap(Config.Round.ZombiesAliveMin)
	end
	if Config.MissionMoveTeam and kind ~= "escort" then
		moveTeam(anchor)
	end
	-- место миссии отмечено высоким маяком: команда идёт к нему сама (телепорта нет)
	if kind ~= "build" then -- у «build» место шатра отмечает собственный круг (makeSiteMarker)
		makeBeacon(anchor, PLACE_LABELS[kind] or PLACE_LABELS.classic, Config.PlaceBeacon.Color, Config.PlaceBeacon.Radius)
	end
	if kind == "scout" then
		for i, pos in districtPoints(def.anchor, def.points or 3, nil, def.radius) do
			table.insert(state.points, { pos = pos, part = makeBeacon(pos, string.format("Point %d", i)), done = false })
		end
	elseif kind == "build" then
		makeSiteMarker(state, false)
	elseif kind == "escort" then
		-- маршрут: контрольные точки района ближайшим соседом от базы, затем дорога у места шатра
		local start = playerSpawnPosition()
		if def.clearSandbags then
			setSandbags(true)
		end
		local grid = RoadRoute.grid()
		-- порядок объезда выбирает ConvoyService (кратчайший по дорогам, каждая точка один раз); метки подписываем после старта
		local route = districtPoints(def.anchor, def.points or 3, grid, def.radius)
		local routeBeacons: { BasePart } = {}
		for _, p in route do
			table.insert(routeBeacons, makeBeacon(p, "Route"))
		end
		local stop = roadStopNear(grid, anchor)
		local groundStart = groundAt(start.X, start.Z) or start
		if not stop or not ConvoyService.start(groundStart, route, stop, def.convoySpeed) then
			warn("[MissionService] convoy not started — the mission plays as a regular night")
			state.kind = "classic"
			state.infinite = false
		else
			ZombieService.setAnchor(groundStart)
			ZombieService.setAliveCap(Config.Convoy.AliveCap)
			for i, p in ConvoyService.routeOrder() do
				local nearest, nd = nil :: BasePart?, math.huge
				for _, b in routeBeacons do
					local d = flatDist(b.Position, p)
					if d < nd then
						nearest, nd = b, d
					end
				end
				if nearest then
					nearest:SetAttribute("BaseText", string.format("◆ Route %d", i))
					table.remove(routeBeacons, table.find(routeBeacons, nearest) :: number)
				end
			end
			for _, b in routeBeacons do -- точки, до которых дорогой не доехать, колонна пропускает: метка не нужна
				b:Destroy()
			end
			if def.install then
				makeSiteMarker(state, false)
			end
		end
	end
	ZombieService.setStreamMode(state.infinite)
	setStatus(def.title, def.hint or "", state.kind)
	notify(string.format("Night %d — %s", night, def.title), 4)
	return state.infinite, state.kind
end

local function topUp(state: State)
	-- classic/clear: волна может быть меньше минимума убийств — тогда подсылаем ещё, пока не наберётся
	local short = not state.infinite and (state.kind == "classic" or state.kind == "clear")
		and ZombieService.remaining() + state.playerKills < state.minKills
	if (state.infinite or short) and ZombieService.queueSize() < 8 then
		-- подпитка потока: обычные зомби волны (боссы приходят один раз, в начале ночи)
		local normal: WaveMath.Composition = {}
		for id, n in state.comp do
			if not WaveMath.isBossType(id) then
				normal[id] = n
			end
		end
		ZombieService.enqueue(WaveMath.spawnQueue(normal, rng), state.hpMult, state.night)
	end
end

-- Убийство зомби (для миссии «установка шатра»: сначала нужно зачистить зону)
function MissionService.onKill(killer: Player?)
	local s = current
	if s then
		s.kills += 1
		if killer then
			s.playerKills += 1
		end
		if s.kind == "metro" and s.phase == "inside" then
			s.metroKills += 1
		end
	end
end

-- Гнездо мутантов (цель миссии метро): кокон из слипшихся овалов, паутина (ассет из Assets.Metro.New, если есть), зеленоватый свет. Удержание E (Config.Metro.NestHold)
-- сжигает его: огонь на коконе, через 2 с исчезает, счётчик растёт. Лежит в MissionObjects и убирается вместе с миссией.
local function buildNest(state: State, marker: BasePart, index: number)
	local base = Vector3.new(marker.Position.X, marker.Position.Y - marker.Size.Y / 2, marker.Position.Z)
	local model = Instance.new("Model")
	model.Name = "MetroNest_" .. index
	local function ball(size: Vector3, offset: Vector3): Part
		local p = Instance.new("Part")
		p.Name = "Cocoon"
		p.Shape = Enum.PartType.Ball
		p.Size = size
		p.CFrame = CFrame.new(base + offset)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.Material = Enum.Material.Fabric
		p.Color = Color3.fromRGB(205, 200, 180)
		p.Parent = model
		return p
	end
	local core = ball(Vector3.new(6, 8, 6), Vector3.new(0, 4, 0))
	ball(Vector3.new(4, 5, 4), Vector3.new(3, 2.5, 1))
	ball(Vector3.new(4, 4, 4), Vector3.new(-3, 2, -1.5))
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("Metro") and ServerStorage.Assets.Metro:FindFirstChild("New")
	local webSrc = lib and lib:FindFirstChild("C_Web_Model_18471692316")
	if webSrc then
		local web = webSrc:Clone() :: Model
		for _, d in web:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
			end
		end
		web:ScaleTo(9)
		web:PivotTo(CFrame.new(base + Vector3.new(0, 5, 0)) * CFrame.Angles(0, math.rad(index * 70), 0))
		web.Parent = model
	end
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(120, 255, 140)
	light.Range = 18
	light.Brightness = 0.9
	light.Parent = core
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Burn the nest"
	prompt.ObjectText = "Mutant nest"
	prompt.HoldDuration = Config.Metro.NestHold
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = core
	local burned = false
	local function act(player: Player)
		local s = current
		if burned or not s or s ~= state or s.phase ~= "inside" or not PlayerService.isUp(player) then
			return
		end
		burned = true
		prompt.Enabled = false
		s.nestsBurned += 1
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "Cocoon" then
				local fire = Instance.new("Fire")
				fire.Size = 8
				fire.Heat = 6
				fire.Parent = d
			end
		end
		light.Color = Color3.fromRGB(255, 150, 60)
		notify(string.format("Nest burned (%d of %d)", s.nestsBurned, s.def.nests or 0), 3)
		task.delay(2.5, function()
			model:Destroy()
		end)
	end
	state.actions["nest" .. tostring(index)] = act
	prompt.Triggered:Connect(act)
	model.Parent = objects
end

-- Пол под точкой метро: луч вниз по Workspace.Metro (иначе nil)
local function metroFloor(x: number, z: number, startY: number): Vector3?
	local metro = workspace:FindFirstChild("Metro")
	if not metro then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { metro, workspace.Terrain }
	local hit = workspace:Raycast(Vector3.new(x, startY, z), Vector3.new(0, -30, 0), params)
	return if hit then hit.Position else nil
end

local function metroLib(name: string): Model?
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("Metro") and ServerStorage.Assets.Metro:FindFirstChild("New")
	local m = lib and lib:FindFirstChild(name)
	return if m and m:IsA("Model") then m else nil
end

-- Тоннель в горе после метро (Config.Metro.Hub): джип с турелью, ящики с припасами (одно оружие на игрока) и майор с брифингом о потерянной базе.
-- Живёт до начала следующей миссии (MissionService.begin), игроков с рассветом больше не уводим на базу — дальше они едут на джипе.
local function buildOfficer(folder: Folder)
	local H = Config.Metro.Hub
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("NPC")
	local template = lib and lib:FindFirstChild("General")
	if not template then
		warn("[MissionService] no ServerStorage.Assets.NPC.General — no major in the tunnel")
		return
	end
	local model = template:Clone() :: Model
	model.Name = "HubOfficer"
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		model:Destroy()
		return
	end
	model:PivotTo(CFrame.lookAt(H.officer + Vector3.new(0, 3.2, 0), H.officer + Vector3.new(0, 3.2, 0) + Vector3.new(0.3, 0, -1)))
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanQuery = d == root
		elseif d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 30)
	gui.StudsOffset = Vector3.new(0, 3.8, 0)
	gui.MaxDistance = 80
	gui.Parent = root
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.fromRGB(255, 200, 80)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = H.OfficerName
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Talk"
	prompt.ObjectText = H.OfficerName
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(player: Player)
		Remotes.get("Briefing"):FireClient(player, H.OfficerName, H.BriefTitle, H.BriefLines)
	end)
	model.Parent = folder
end

local function setupHub()
	if hubFolder then
		hubFolder:Destroy()
	end
	local H = Config.Metro.Hub
	local folder = Instance.new("Folder")
	folder.Name = "HubObjects"
	folder.Parent = workspace
	hubFolder = folder
	local jeep = VehicleService.spawn("GunJeep", CFrame.lookAt(H.vehicle, H.vehicle + Vector3.new(0, 0, 1)))
	if jeep and jeep.PrimaryPart then
		-- корпус машины почти без трения: на неровной дороге тоннеля она уезжала сама. Пока никто не сел, держим её на месте
		local root = jeep.PrimaryPart
		root.Anchored = true
		for _, d in jeep:GetDescendants() do
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				d:GetPropertyChangedSignal("Occupant"):Connect(function()
					if d.Occupant then
						root.Anchored = false
					end
				end)
			end
		end
	else
		warn("[MissionService] failed to place the turret jeep in the tunnel")
	end
	AmmoCrateService.resetSupply()
	for i, pos in H.supplies do
		AmmoCrateService.supply(folder, pos, i * 0.9)
	end
	buildOfficer(folder)
end

-- Костяная дверь у Metro_Exit — выход из метро в тоннель в горе. Открывается, когда собран ключ, сожжены гнёзда и убит босс; тогда всех, кто на станции,
-- переносит в тоннель (Config.Metro.Hub.spawn) — миссия выполнена (MissionService.update, фаза «hub»).
local function buildExitDoor(state: State, metro: Instance)
	local marker = metro:FindFirstChild("Markers") and metro.Markers:FindFirstChild("Metro_Exit")
	local src = metroLib("C_Door_Skeleton_122782716925668")
	local caveFolder = metro:FindFirstChild("Cave")
	local pre = caveFolder and caveFolder:FindFirstChild("BoneDoor")
	if not marker or not marker:IsA("BasePart") or (not src and not (pre and pre:IsA("Model"))) then
		warn("[MissionService] metro: no Metro_Exit marker or bone door model — there will be no exit")
		return
	end
	local floor = metroFloor(marker.Position.X, marker.Position.Z, marker.Position.Y + 2) or Vector3.new(marker.Position.X, marker.Position.Y - 8, marker.Position.Z)
	local prePlaced = pre ~= nil and pre:IsA("Model")
	local door: Model = if prePlaced then pre :: Model else (src :: Model):Clone()
	door.Name = "BoneDoor"
	if not prePlaced then
		for _, d in door:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanQuery = false
			end
		end
		door:PivotTo(CFrame.new(door:GetPivot().Position) * CFrame.Angles(0, math.atan2(-marker.CFrame.LookVector.X, -marker.CFrame.LookVector.Z), 0))
		local bbox, size = door:GetBoundingBox()
		door:PivotTo(door:GetPivot() + (floor + Vector3.new(0, size.Y / 2, 0)) - bbox.Position)
	end
	local anchor: BasePart? = nil
	for _, d in door:GetDescendants() do
		if d:IsA("BasePart") and (not anchor or d.Size.Magnitude > anchor.Size.Magnitude) then
			anchor = d
		end
	end
	if not anchor then
		if not prePlaced then
			door:Destroy()
		end
		return
	end
	-- готовая дверь стоит в карте всегда: подсказку вешаем на деталь в objects, чтобы она исчезала вместе с миссией
	local holder: BasePart = anchor
	if prePlaced then
		local h = Instance.new("Part")
		h.Name = "BoneDoorPrompt"
		h.Size = Vector3.one
		h.Transparency = 1
		h.Anchored = true
		h.CanCollide = false
		h.CanQuery = false
		h.CFrame = anchor.CFrame
		h.Parent = objects
		holder = h
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open the bone door"
	prompt.ObjectText = "Catacomb exit"
	prompt.HoldDuration = 1.5
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = holder
	local function act(player: Player)
		local s = current
		if not s or s ~= state or s.phase ~= "inside" or not PlayerService.isUp(player) then
			return
		end
		local missing: { string } = {}
		if not s.hasKey then
			table.insert(missing, "SkeletonKey (given after defending the detonator)")
		end
		if s.nestsBurned < (s.def.nests or 0) then
			table.insert(missing, "mutant nests")
		end
		if s.def.boss and (not s.bossSeen or ZombieService.bossAlive()) then
			table.insert(missing, "station boss")
		end
		if #missing > 0 then
			Remotes.get("Notify"):FireClient(player, "The door is locked. Needed: " .. table.concat(missing, ", "), 4)
			return
		end
		s.phase = "hub"
		ZombieService.clearAll()
		ZombieService.setSpawnPoints(nil)
		local spawn = Config.Metro.Hub.spawn
		for _, p in PlayerService.upPlayers() do
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if char and root and root.Position.Y < Config.Metro.InsideMaxY then
				char:PivotTo(CFrame.new(spawn + Vector3.new(math.random(-6, 6), 3, math.random(-6, 6))))
			end
		end
		setupHub()
		notify("The bone door is open — you've come out into the tunnel in the mountain. Talk to the major, grab supplies and the turret jeep!", 8)
	end
	state.actions["door"] = act
	prompt.Triggered:Connect(act)
	if not prePlaced then
		door.Parent = objects
	end
end

-- Финал метро (решение Руслана 2026-10-30): запустить 5 генераторов (Workspace.Metro.Generators, удержание E), поставить 20 зарядов ТНТ на отмеченные места
-- (маркеры Metro_Tnt_1…20, призрак заряда и метка видны в радиусе MarkDistance), включить детонатор (Workspace.Metro.Cave.Detonator) и 60 с защищать его зону;
-- после этого, набрав нужное число убийств, команда получает SkeletonKey у детонатора — он открывает костяную дверь выхода.
local function holderPart(pos: Vector3): BasePart
	local h = Instance.new("Part")
	h.Name = "MetroHolder"
	h.Size = Vector3.one
	h.Transparency = 1
	h.Anchored = true
	h.CanCollide = false
	h.CanQuery = false
	h.CanTouch = false
	h.Position = pos
	h.Parent = objects
	return h
end

-- Небольшая метка над предметом: видна на расстоянии до maxDist студов
local function markerGui(adornee: BasePart, text: string, color: Color3, maxDist: number, width: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "MetroMark"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(width, 16)
	gui.StudsOffset = Vector3.new(0, 2.4, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = maxDist
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = color
	label.BackgroundTransparency = 0.4
	label.Text = text
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = label
	gui.Parent = adornee
	return gui
end

local function holdPrompt(parent: BasePart, action: string, object: string, hold: number, distance: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = distance
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

local function buildGenerators(state: State, metro: Instance)
	local folder = metro:FindFirstChild("Generators")
	if not folder then
		warn("[MissionService] metro: no Workspace.Metro.Generators — there will be no generators")
		return
	end
	for _, model in folder:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("MissionGenerator") then
			local cf, size = model:GetBoundingBox()
			local holder = holderPart(cf.Position + Vector3.new(0, size.Y / 2 - 0.4, 0))
			local mark = markerGui(holder, "GENERATOR", Color3.fromRGB(230, 150, 40), 220, 74)
			local prompt = holdPrompt(holder, "Start the generator", "Generator", Config.Metro.GenHold, 12)
			local function act(player: Player)
				local s = current
				if not s or s ~= state or s.phase ~= "inside" or not prompt.Enabled or not PlayerService.isUp(player) then
					return
				end
				prompt.Enabled = false
				mark:Destroy()
				s.gensOn += 1
				local light = Instance.new("PointLight")
				light.Color = Color3.fromRGB(120, 255, 140)
				light.Brightness = 2.5
				light.Range = 30
				light.Shadows = false
				light.Parent = holder
				notify(string.format("Generator started (%d of %d)", s.gensOn, Config.Metro.Gens), 3)
			end
			state.actions["gen" .. tostring(model.Name)] = act
			prompt.Triggered:Connect(act)
		end
	end
end

local function buildTnt(state: State, metro: Instance)
	local src = metroLib("C_TNT_11684524329")
	local markers = metro:FindFirstChild("Markers")
	if not src or not markers then
		warn("[MissionService] metro: no TNT model or markers — there will be no charges")
		return
	end
	for i = 1, Config.Metro.Tnt do
		local marker = markers:FindFirstChild("Metro_Tnt_" .. i)
		if marker and marker:IsA("BasePart") then
			local floor = metroFloor(marker.Position.X, marker.Position.Z, marker.Position.Y + 3) or marker.Position
			local function make(ghost: boolean): Model
				local m = src:Clone()
				m.Name = "Tnt_" .. i
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
						d.CanQuery = false
						if ghost then
							d.Transparency = 0.6
							d.Color = Color3.fromRGB(110, 225, 255)
							d.Material = Enum.Material.Neon
						end
					end
				end
				m:ScaleTo(1.3)
				m:PivotTo(CFrame.new(m:GetPivot().Position) * CFrame.Angles(0, i * 1.7, 0))
				local bbox, size = m:GetBoundingBox()
				m:PivotTo(m:GetPivot() + (floor + Vector3.new(0, size.Y / 2 + 0.05, 0)) - bbox.Position)
				m.Parent = objects
				return m
			end
			local ghost = make(true)
			local part = ghost:FindFirstChildWhichIsA("BasePart", true)
			if part then
				markerGui(part, "TNT", Color3.fromRGB(70, 190, 230), Config.Metro.MarkDistance, 30)
				local prompt = holdPrompt(part, "Plant the charge", "TNT", Config.Metro.TntHold, 9)
				local function act(player: Player)
					local s = current
					if not s or s ~= state or s.phase ~= "inside" or not prompt.Enabled or not PlayerService.isUp(player) then
						return
					end
					prompt.Enabled = false
					ghost:Destroy()
					table.insert(s.tntModels, make(false))
					s.tnt += 1
					notify(string.format("Charge planted (%d of %d)", s.tnt, Config.Metro.Tnt), 3)
				end
				state.actions["tnt" .. tostring(i)] = act
				prompt.Triggered:Connect(act)
			end
		end
	end
end

-- Взрыв всех зарядов после обороны (без урона и разрушения — только эффект)
local function blastTnt(state: State)
	for i, m in state.tntModels do
		task.delay(i * 0.12, function()
			if m.Parent then
				local boom = Instance.new("Explosion")
				boom.Position = m:GetPivot().Position
				boom.BlastRadius = 7
				boom.BlastPressure = 0
				boom.DestroyJointRadiusPercent = 0
				boom.Parent = workspace
			end
		end)
	end
end

local function spawnKey(state: State)
	local src = metroLib("C_SkeletonKey_12740503653")
	if not src then
		state.hasKey = true -- нет модели: ключ выдаём сразу, чтобы миссия не зависла
		return
	end
	local key = src:Clone()
	key.Name = "SkeletonKey"
	for _, d in key:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
		end
	end
	key:ScaleTo(3)
	key:PivotTo(CFrame.new(state.detPos + Vector3.new(0, 7, 0)))
	key.Parent = objects
	local holder = holderPart(state.detPos + Vector3.new(0, 6, 0))
	markerGui(holder, "KEY", Color3.fromRGB(240, 220, 120), 300, 46)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 235, 150)
	light.Brightness = 2
	light.Range = 24
	light.Parent = holder
	local prompt = holdPrompt(holder, "Take the SkeletonKey", "Bone key", 1, 14)
	local function act(player: Player)
		local s = current
		if not s or s ~= state or s.hasKey or not PlayerService.isUp(player) then
			return
		end
		s.hasKey = true
		prompt.Enabled = false
		key:Destroy()
		notify("The team has the SkeletonKey — open the bone door on the upper level of the cave!", 6)
	end
	state.actions["key"] = act
	prompt.Triggered:Connect(act)
end

local function buildDetonator(state: State, metro: Instance)
	local cave = metro:FindFirstChild("Cave")
	local det = cave and cave:FindFirstChild("Detonator")
	if not det or not det:IsA("Model") then
		warn("[MissionService] metro: no Workspace.Metro.Cave.Detonator — there will be no detonator")
		return
	end
	local cf, size = det:GetBoundingBox()
	local holder = holderPart(cf.Position + Vector3.new(0, size.Y / 2 - 0.4, 0))
	markerGui(holder, "DETONATOR", Color3.fromRGB(230, 70, 60), 300, 82)
	local prompt = holdPrompt(holder, "Activate the detonator", "Detonator", 3, 14)
	local function act(player: Player)
		local s = current
		if not s or s ~= state or s.phase ~= "inside" or s.detStage ~= 0 or not PlayerService.isUp(player) then
			return
		end
		local missing: { string } = {}
		if s.gensOn < Config.Metro.Gens then
			table.insert(missing, string.format("generators (%d of %d)", s.gensOn, Config.Metro.Gens))
		end
		if s.tnt < Config.Metro.Tnt then
			table.insert(missing, string.format("TNT charges (%d of %d)", s.tnt, Config.Metro.Tnt))
		end
		if #missing > 0 then
			Remotes.get("Notify"):FireClient(player, "The detonator isn't ready. Needed: " .. table.concat(missing, ", "), 4)
			return
		end
		s.detStage = 1
		s.defendLeft = Config.Metro.DefendSeconds
		s.detPos = holder.Position
		prompt.Enabled = false
		-- зомби лезут из пещерных маркеров
		local points: { Vector3 } = {}
		local markers = metro:FindFirstChild("Markers")
		local list: { Instance } = if markers then markers:GetChildren() else {}
		for _, mk in list do
			local n = tonumber(string.match(mk.Name, "^Metro_ZombieSpawn_(%d+)$"))
			if n and n >= 15 and mk:IsA("BasePart") then
				table.insert(points, mk.Position)
			end
		end
		if #points > 0 then
			ZombieService.setSpawnPoints(points)
		end
		notify(string.format("Detonator activated! Defend the zone for %d seconds", Config.Metro.DefendSeconds), 6)
	end
	state.actions["det"] = act
	prompt.Triggered:Connect(act)
end

-- Раз в 0,25 с (из update): текст задачи и переходы финала метро после босса
local function finaleStep(state: State, dt: number, need: number): string
	local cfg = Config.Metro
	if state.hasKey then
		return "Open the bone door on the upper level of the cave"
	end
	if state.detStage == 1 then
		local near = false
		for _, pos in upPositions() do
			if flatDist(pos, state.detPos) < cfg.DefendRadius and math.abs(pos.Y - state.detPos.Y) < 40 then
				near = true
				break
			end
		end
		if near then
			state.defendLeft = math.max(0, state.defendLeft - dt)
		end
		if state.defendLeft > 0 then
			return if near
				then string.format("Defend the detonator: %d s left", math.ceil(state.defendLeft))
				else string.format("Get back to the detonator! %d s left", math.ceil(state.defendLeft))
		end
		state.detStage = 2
		blastTnt(state)
		notify("The charges went off!", 5)
	end
	if state.detStage == 2 then
		if state.metroKills < need then
			return string.format("Finish off the mutants: killed %d of %d", state.metroKills, need)
		end
		if not state.keyOut then
			state.keyOut = true
			spawnKey(state)
			if not state.hasKey then
				notify("The SkeletonKey dropped — take it from the detonator!", 6)
			end
		end
		return "Take the SkeletonKey from the detonator"
	end
	local text = string.format("Start the generators: %d of %d (hold E)\nPlant the TNT charges: %d of %d (markers within %d studs)", state.gensOn, cfg.Gens, state.tnt, cfg.Tnt, cfg.MarkDistance)
	if state.gensOn >= cfg.Gens and state.tnt >= cfg.Tnt then
		text = "All set — activate the detonator in the big cave hall"
	end
	return text
end

-- Вход в метро: игрок на лестнице. Только на ночи с миссией «metro»: первого спустившегося переносим на станцию, поток зомби
-- переключается на точки метро. В остальные ночи вход закрыт.
local metroDebounce: { [Player]: number } = {}

function MissionService.onEntranceTouched(player: Player)
	local now = os.clock()
	if (metroDebounce[player] or 0) > now - 2 then
		return
	end
	metroDebounce[player] = now
	local s = current
	if not s or s.kind ~= "metro" then
		Remotes.get("Notify"):FireClient(player, "The metro entrance is closed: collapsed", 2)
		return
	end
	local metro = workspace:FindFirstChild("Metro")
	local spawn = metro and metro:FindFirstChild("Markers") and metro.Markers:FindFirstChild("Metro_Spawn") :: BasePart?
	local char = player.Character
	if not spawn or not char or not PlayerService.isUp(player) then
		return
	end
	char:PivotTo(CFrame.new(spawn.Position + Vector3.new(math.random(-6, 6), 3, math.random(-3, 3))))
	if s.phase == "approach" then
		s.phase = "inside"
		local points: { Vector3 } = {}
		for _, m in (metro :: Folder).Markers:GetChildren() do
			if string.sub(m.Name, 1, 18) == "Metro_ZombieSpawn_" and m:IsA("BasePart") then
				table.insert(points, m.Position)
			end
		end
		ZombieService.clearAll() -- зомби снаружи больше не нужны (и не должны занимать места в потоке метро)
		ZombieService.setAnchor(nil)
		ZombieService.setSpawnPoints(points)
		-- гнёзда: по маркерам Metro_Objective_<n> (сколько — def.nests)
		for i = 1, s.def.nests or 0 do
			local marker = (metro :: Folder).Markers:FindFirstChild("Metro_Objective_" .. i)
			if marker and marker:IsA("BasePart") then
				buildNest(s, marker, i)
			end
		end
		if (s.def.nests or 0) > 0 then
			-- финал: генераторы, места под ТНТ, детонатор и костяная дверь выхода
			buildGenerators(s, metro :: Instance)
			buildTnt(s, metro :: Instance)
			buildDetonator(s, metro :: Instance)
			buildExitDoor(s, metro :: Instance)
		end
		notify(if (s.def.nests or 0) > 0 then "The team went down into the metro — burn the nests, kill the boss, start the generators and plant the charges!" else "The team went down into the metro — clear the station", 4)
	end
end

-- Только в Studio: вызвать обработчик подсказки финала метро напрямую («gen<имя модели>», "tnt<n>", "det", "key") — удержание E в тестах из-за
-- неотрисованного окна не срабатывает. В игре (не Studio) ничего не делает.
function MissionService.debugInteract(name: string, player: Player): boolean
	if not RunService:IsStudio() then
		return false
	end
	local s = current
	local act = s and s.actions[name]
	if act then
		act(player)
		return true
	end
	return false
end

function MissionService.init()
	local markers = workspace:FindFirstChild("Markers")
	local trigger = markers and markers:FindFirstChild("Metro_EntranceTrigger") :: BasePart?
	if trigger then
		trigger.Touched:Connect(function(hit: BasePart)
			local player = Players:GetPlayerFromCharacter(hit.Parent)
			if player then
				MissionService.onEntranceTouched(player)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		metroDebounce[player] = nil
	end)
end

-- Раз в 0,25 с: "done" — миссия выполнена, "fail" — провалена; nil — идёт (classic/clear завершает RoundService по числу зомби)
function MissionService.update(dt: number): string?
	local state = current
	if not state then
		return nil
	end
	topUp(state)
	if state.def.baseBattle then
		BaseBattleService.update(os.clock())
	end
	local kind = state.kind
	local text = ""
	local result: string? = nil
	if kind == "scout" then
		local done = 0
		local ups = upPositions()
		for _, pt in state.points do
			if not pt.done then
				for _, pos in ups do
					if flatDist(pos, pt.pos) < Config.ScoutPointRadius then
						pt.done = true
						pt.part:Destroy()
						notify("Point scouted", 2)
						break
					end
				end
			end
			if pt.done then
				done += 1
			end
		end
		text = string.format("Points scouted: %d of %d", done, #state.points)
		if #state.points > 0 and done >= #state.points then
			result = "done"
		end
	elseif kind == "defend" then
		local near = false
		for _, pos in upPositions() do
			if flatDist(pos, state.anchor) < 80 then
				near = true
				break
			end
		end
		if near then
			state.secondsLeft = math.max(0, state.secondsLeft - dt)
			text = string.format("Holding the tent: %d s left", math.ceil(state.secondsLeft))
		else
			text = string.format("Get back to the tent! %d s left", math.ceil(state.secondsLeft))
		end
		if state.secondsLeft <= 0 then
			result = "done"
		end
	elseif kind == "build" then
		local need = math.max(Config.MissionKillsFloor, math.floor((state.def.kills or 15) * (Config.Waves.CountScale or 1) + 0.5))
		if state.phase == "kill" then
			text = string.format("Clear the zone: killed %d of %d", math.min(state.kills, need), need)
			if state.kills >= need then
				state.phase = "install"
				if state.prompt then
					state.prompt.Enabled = true
				end
				notify("Zone cleared — set up the tent at the marked spot (hold E)", 5)
			end
		else
			text = if state.installed then "Tent set up" else "Set up the tent at the marked spot: hold E"
			if state.installed then
				result = "done"
			end
		end
	elseif kind == "escort" then
		if state.phase == "drive" then
			-- едет, только пока рядом (Config.Convoy.FollowRadius) есть живой игрок
			local near = false
			local truckPos = ConvoyService.position()
			if truckPos then
				for _, pos in upPositions() do
					if flatDist(pos, truckPos) <= Config.Convoy.FollowRadius then
						near = true
						break
					end
				end
			end
			local status = ConvoyService.update(dt, near)
			local hp = math.floor(ConvoyService.hpFraction() * 100 + 0.5)
			text = if near
				then string.format("Escort the convoy. Truck durability: %d%%", hp)
				else string.format("Get close to the convoy: it's waiting (within %d studs). Truck durability: %d%%", Config.Convoy.FollowRadius, hp)
			if status == "fail" then
				notify("The convoy was destroyed!", 5)
				result = "fail"
			elseif status == "arrived" then
				dropSupplies(state.site)
				if state.def.install then
					notify("The convoy has arrived — supplies delivered", 4)
				else
					-- без установки руками шатёр ставится сам (если ночью 2 его не ставили, например при пропуске ночи)
					installTent(state.site)
					state.installed = true
					notify("The convoy has arrived — tent set up, supplies delivered", 4)
				end
				if state.def.install then
					state.phase = "install"
					if state.prompt then
						state.prompt.Enabled = true
					end
				else
					state.phase = "hold" -- без установки: ждём, пока команда добьёт минимум убийств
				end
			end
		else
			-- колонна стоит у места шатра: солдаты продолжают стрелять, гибель грузовика до установки — провал
			-- (иначе грузовик и солдаты остаются целями зомби, но ни на что не влияют)
			if ConvoyService.update(dt) == "fail" then
				notify("The convoy was destroyed!", 5)
				result = "fail"
			end
			ZombieService.moveAnchor(state.anchor)
			local hp = math.floor(ConvoyService.hpFraction() * 100 + 0.5)
			if state.phase == "install" then
				text = string.format("Set up the tent: hold E. Truck durability: %d%%", hp)
				if state.installed and not result then
					result = "done"
				end
			else
				text = string.format("The convoy is in place. Truck durability: %d%%", hp)
				if not result then
					result = "done"
				end
			end
		end
	elseif kind == "metro" then
		local need = math.max(Config.MissionKillsFloor, math.floor((state.def.kills or 40) * (Config.Waves.CountScale or 1) + 0.5))
		if state.phase == "approach" then
			text = "Go down into the metro: stairs by the entrance"
		else
			local nests = state.def.nests or 0
			if state.phase == "hub" then
				text = "You left through the bone door into the tunnel in the mountain. Metro mission complete"
				result = "done"
			elseif state.nestsBurned < nests then
				text = string.format("Burn the mutant nests: %d of %d (hold E at a nest)", state.nestsBurned, nests)
			elseif state.def.boss and not state.bossOut then
				-- гнёзда сожжены: на станцию выходит босс (из туннелей, вне очереди)
				state.bossOut = true
				ZombieService.enqueue({ state.def.boss }, state.hpMult, state.night, true)
				notify("Nests burned — the boss has come out onto the station!", 5)
				text = "Kill the station boss"
			elseif state.def.boss and not state.bossSeen then
				state.bossSeen = ZombieService.bossAlive() -- ждём, пока босс появится
				text = "Kill the station boss"
			elseif state.def.boss and ZombieService.bossAlive() then
				text = "Kill the station boss"
			elseif nests > 0 then
				text = finaleStep(state, dt, need)
			else
				text = string.format("Clear the station: killed %d of %d", math.min(state.metroKills, need), need)
				if state.metroKills >= need then
					result = "done"
				end
			end
		end
	elseif kind == "bossfight" then
		local list = state.def.bosses or { "BossStrong" }
		local def = Config.Zombies[list[math.max(1, state.bossIndex)]]
		text = string.format("Kill the boss: %s (%d of %d)", if def then def.name else "?", state.bossIndex, #list)
		if ZombieService.remaining() == 0 then
			if state.bossIndex < #list then
				state.bossIndex += 1
				ZombieService.enqueue({ list[state.bossIndex] }, state.hpMult, state.night, true)
				notify("Next boss!", 4)
			else
				result = "done" -- последний босс убит
			end
		end
	elseif kind == "clear" or kind == "classic" then
		local left = ZombieService.remaining()
		text = string.format("Zombies left: %d", left)
		if state.def.baseBattle then
			text ..= string.format("\nSoldiers at the rally point: %d of %d", BaseBattleService.alive(), Config.BaseBattle.Defenders)
		end
		if left == 0 then
			result = "done"
		end
	end
	-- на каждой ночи: задача выполнена И убито не меньше минимума (считаются только убийства игроков); время ночи — по-прежнему лимит
	if result == "done" and state.playerKills < state.minKills then
		result = nil
	end
	-- итог конвоя: доехал и миссия выполнена — патроны всем и «район захвачен»; не доехал — шатёр района разрушен, награды нет (Economy.MissionFailShare = 0)
	if result and kind == "escort" and resolvedState ~= state then
		resolvedState = state
		if result == "done" then
			for _, p in Players:GetPlayers() do
				WeaponService.refillAll(p)
			end
			notify("District captured! Ammo refilled", 6)
		else
			destroyTent(state.site)
			notify("The convoy didn't make it — the district tent was destroyed", 6)
		end
	end
	if state.minKills > 0 then
		text ..= string.format("\nMutants killed: %d of %d", math.min(state.playerKills, state.minKills), state.minKills)
	end
	if text ~= state.lastText then
		state.lastText = text
		ReplicatedStorage:SetAttribute("MissionText", text)
	end
	return result
end

-- Метро: станция лежит высоко над картой (Metro_Spawn, y ≈ 600), и с рассветом команду никто оттуда не забирал (MissionReturnTeam выключен):
-- игроки оставались внизу. Пока миссия «metro» идёт внутри станции, при её завершении (рассвет, провал, новый раунд) всех, кто внутри,
-- поднимаем к лестнице наверху (Markers.Metro_EntranceTop).
local function leaveMetro()
	local s = current
	if s and s.kind == "metro" and s.phase == "hub" then
		return -- команда остаётся в тоннеле в горе: дальше она едет на джипе на военную базу (ночь 19)
	end
	if not s or s.kind ~= "metro" or s.phase ~= "inside" then
		return
	end
	local markers = workspace:FindFirstChild("Markers")
	local top = markers and markers:FindFirstChild("Metro_EntranceTop") :: BasePart?
	local metro = workspace:FindFirstChild("Metro")
	local inner = metro and metro:FindFirstChild("Markers") and metro.Markers:FindFirstChild("Metro_Spawn") :: BasePart?
	if not top or not inner then
		return
	end
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if char and root and root.Position.Y < Config.Metro.InsideMaxY then
			char:PivotTo(CFrame.new(top.Position + Vector3.new(math.random(-4, 4), 4, math.random(-4, 4))))
		end
	end
end

function MissionService.finish()
	finalePos = nil
	leaveMetro()
	BaseBattleService.finish()
	ConvoyService.finish()
	setSandbags(false)
	if objects then
		objects:Destroy()
		objects = nil
	end
	current = nil
	ZombieService.setAnchor(nil)
	ZombieService.setSpawnPoints(nil)
	ZombieService.setAliveCap(nil)
	ZombieService.setStreamMode(false)
	setStatus("", "", "")
end

-- Финал акта 1: день 20, миссия «зайти в бункер». Маяк над входом (Workspace.Bunker.BunkerEntrance), радиус — Config.Finale.Radius. Возвращает точку входа
function MissionService.beginFinale(): Vector3?
	MissionService.finish()
	local bunker = workspace:FindFirstChild("Bunker")
	local entrance = bunker and bunker:FindFirstChild("BunkerEntrance")
	if not entrance or not entrance:IsA("Model") then
		warn("[MissionService] no Workspace.Bunker.BunkerEntrance — finale without a bunker")
		return nil
	end
	local cf = entrance:GetBoundingBox()
	local g = groundAt(cf.Position.X, cf.Position.Z)
	local pos = if g then g else Vector3.new(cf.Position.X, 0.5, cf.Position.Z)
	finalePos = pos
	objects = Instance.new("Folder")
	objects.Name = "MissionObjects"
	objects.Parent = workspace
	makeBeacon(pos, "Bunker", Config.PlaceBeacon.Color, Config.Finale.Radius)
	setStatus("Finale: the bunker", "The boss is down. Enter the bunker as a team", "finale")
	return pos
end

-- Все живые игроки у входа в бункер (хотя бы один жив)
function MissionService.finaleReady(): boolean
	local pos = finalePos
	if not pos then
		return false
	end
	local ups = upPositions()
	if #ups == 0 then
		return false
	end
	for _, p in ups do
		if flatDist(p, pos) > Config.Finale.Radius or math.abs(p.Y - pos.Y) > 30 then
			return false
		end
	end
	return true
end

-- Рассвет: команда возвращается к магазину
function MissionService.returnTeam(spawn: Vector3)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if char then
			char:PivotTo(CFrame.new(spawn + Vector3.new(math.random(-6, 6), 3, math.random(-4, 4))))
		end
	end
end

function MissionService.isInfinite(): boolean
	return current ~= nil and current.infinite
end

return MissionService
