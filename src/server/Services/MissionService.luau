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
}

local current: State? = nil
local objects: Folder? = nil
local finalePos: Vector3? = nil -- финал акта 1: вход в бункер (MissionService.beginFinale)
local rng = Random.new()
local installedSites: { [number]: { instances: { Instance }, shop: Vector3?, vending: { string } } } = {}
local suppliedSites: { [number]: { Instance } } = {}

-- Подписи маяка места миссии по типу
local PLACE_LABELS: { [string]: string } = {
	scout = "Район разведки", build = "Место шатра", escort = "Место шатра", defend = "Шатёр: оборона", metro = "Вход в метро", classic = "Зона боя", clear = "Зона боя", bossfight = "Арена",
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
		warn(string.format("[MissionService] точек разведки района %d: нашлось %d из %d (радиус %d–%d)", anchorIndex, #list, count, rr[1], rr[2]))
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
	ShopService.addPoint("Военная палатка", center, math.max(size.X, size.Z) / 2 + 18, false, true, true)
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
	label.Text = "◆ Место шатра"
	label.Parent = gui
	part:SetAttribute("BaseText", "◆ Место шатра")
	CollectionService:AddTag(part, "MissionZone")
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Установить шатёр"
	prompt.ObjectText = "Шатёр"
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
			notify("Шатёр установлен!", 4)
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
		warn("[MissionService] ночь 19: на базе не нашлось точек появления — зомби идут кольцом вокруг базы")
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
	local def: Config.MissionDef = Config.Missions[night] or { type = "classic", title = string.format("Ночь %d", night), anchor = 1 }
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
		kills = 0, playerKills = 0, minKills = minKillsFor(players), metroKills = 0, phase = if kind == "build" then "kill" elseif kind == "metro" then "approach" else "drive", sitePart = nil, prompt = nil, installed = false, bossIndex = 0,
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
			table.insert(state.points, { pos = pos, part = makeBeacon(pos, string.format("Точка %d", i)), done = false })
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
			table.insert(routeBeacons, makeBeacon(p, "Маршрут"))
		end
		local stop = roadStopNear(grid, anchor)
		local groundStart = groundAt(start.X, start.Z) or start
		if not stop or not ConvoyService.start(groundStart, route, stop, def.convoySpeed) then
			warn("[MissionService] конвой не запущен — миссия играется как обычная ночь")
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
					nearest:SetAttribute("BaseText", string.format("◆ Маршрут %d", i))
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
	notify(string.format("Ночь %d — %s", night, def.title), 4)
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
		Remotes.get("Notify"):FireClient(player, "Вход в метро закрыт: завалено", 2)
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
		notify("Команда спустилась в метро — зачистите станцию", 4)
	end
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
						notify("Точка обследована", 2)
						break
					end
				end
			end
			if pt.done then
				done += 1
			end
		end
		text = string.format("Обследовано точек: %d из %d", done, #state.points)
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
			text = string.format("Держим шатёр: осталось %d с", math.ceil(state.secondsLeft))
		else
			text = string.format("Вернитесь к шатру! Осталось %d с", math.ceil(state.secondsLeft))
		end
		if state.secondsLeft <= 0 then
			result = "done"
		end
	elseif kind == "build" then
		local need = math.max(Config.MissionKillsFloor, math.floor((state.def.kills or 15) * (Config.Waves.CountScale or 1) + 0.5))
		if state.phase == "kill" then
			text = string.format("Зачистите зону: убито %d из %d", math.min(state.kills, need), need)
			if state.kills >= need then
				state.phase = "install"
				if state.prompt then
					state.prompt.Enabled = true
				end
				notify("Зона зачищена — установите шатёр на отмеченном месте (удерживайте E)", 5)
			end
		else
			text = if state.installed then "Шатёр установлен" else "Установите шатёр на отмеченном месте: удерживайте E"
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
				then string.format("Сопровождайте конвой. Прочность грузовика: %d%%", hp)
				else string.format("Подойдите к конвою: он ждёт (в радиусе %d студов). Прочность грузовика: %d%%", Config.Convoy.FollowRadius, hp)
			if status == "fail" then
				notify("Конвой уничтожен!", 5)
				result = "fail"
			elseif status == "arrived" then
				dropSupplies(state.site)
				if state.def.install then
					notify("Конвой прибыл — припасы доставлены", 4)
				else
					-- без установки руками шатёр ставится сам (если ночью 2 его не ставили, например при пропуске ночи)
					installTent(state.site)
					state.installed = true
					notify("Конвой прибыл — шатёр установлен, припасы доставлены", 4)
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
				notify("Конвой уничтожен!", 5)
				result = "fail"
			end
			ZombieService.moveAnchor(state.anchor)
			local hp = math.floor(ConvoyService.hpFraction() * 100 + 0.5)
			if state.phase == "install" then
				text = string.format("Установите шатёр: удерживайте E. Прочность грузовика: %d%%", hp)
				if state.installed and not result then
					result = "done"
				end
			else
				text = string.format("Конвой на месте. Прочность грузовика: %d%%", hp)
				if not result then
					result = "done"
				end
			end
		end
	elseif kind == "metro" then
		local need = math.max(Config.MissionKillsFloor, math.floor((state.def.kills or 40) * (Config.Waves.CountScale or 1) + 0.5))
		if state.phase == "approach" then
			text = "Спуститесь в метро: лестница у входа"
		else
			text = string.format("Зачистите станцию: убито %d из %d", math.min(state.metroKills, need), need)
			if state.metroKills >= need then
				result = "done"
			end
		end
	elseif kind == "bossfight" then
		local list = state.def.bosses or { "BossStrong" }
		local def = Config.Zombies[list[math.max(1, state.bossIndex)]]
		text = string.format("Убейте босса: %s (%d из %d)", if def then def.name else "?", state.bossIndex, #list)
		if ZombieService.remaining() == 0 then
			if state.bossIndex < #list then
				state.bossIndex += 1
				ZombieService.enqueue({ list[state.bossIndex] }, state.hpMult, state.night, true)
				notify("Следующий босс!", 4)
			else
				result = "done" -- последний босс убит
			end
		end
	elseif kind == "clear" or kind == "classic" then
		local left = ZombieService.remaining()
		text = string.format("Осталось зомби: %d", left)
		if state.def.baseBattle then
			text ..= string.format("\nСолдаты у точки сбора: %d из %d", BaseBattleService.alive(), Config.BaseBattle.Defenders)
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
			notify("Район успешно захвачен! Патроны пополнены", 6)
		else
			destroyTent(state.site)
			notify("Конвой не доехал — шатёр района уничтожен", 6)
		end
	end
	if state.minKills > 0 then
		text ..= string.format("\nУбито мутантов: %d из %d", math.min(state.playerKills, state.minKills), state.minKills)
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
		if char and root and root.Position.Y > inner.Position.Y - 200 then
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
		warn("[MissionService] нет Workspace.Bunker.BunkerEntrance — финал без бункера")
		return nil
	end
	local cf = entrance:GetBoundingBox()
	local g = groundAt(cf.Position.X, cf.Position.Z)
	local pos = if g then g else Vector3.new(cf.Position.X, 0.5, cf.Position.Z)
	finalePos = pos
	objects = Instance.new("Folder")
	objects.Name = "MissionObjects"
	objects.Parent = workspace
	makeBeacon(pos, "Бункер", Config.PlaceBeacon.Color, Config.Finale.Radius)
	setStatus("Финал: бункер", "Босс повержен. Зайдите в бункер всей командой", "finale")
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
