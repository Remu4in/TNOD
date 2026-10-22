--!strict
-- Миссии ночи (сюжет: docs/story.md). Ночь = миссия из Config.Missions[ночь]: точка миссии (место шатра района), задача и «поток» зомби,
-- который идёт со всех сторон на расстоянии 100–150 студов от точки (ZombieService.setAnchor), пока задача не выполнена.
--   scout   — разведка: обойти контрольные точки в 50–100 студах от места шатра (поток без конца)
--   build   — установка шатра: убить N мутантов, затем удерживать «Установить шатёр» у места (поток без конца)
--   escort  — конвой: грузовик с двумя солдатами объезжает контрольные точки и встаёт на дороге у места шатра (ConvoyService);
--             с install = true после приезда ещё надо установить шатёр
--   defend  — защита шатра: продержаться SECONDS секунд рядом (поток без конца)
--   clear / classic — убить всю волну
-- Места шатров — ServerStorage.Assets.TentSites.Site_<n> (шатёр + припасы + автомат), шатёр базы (Workspace.Base.Tent) — точка 5.
-- Статус для клиентов — атрибуты ReplicatedStorage: MissionTitle, MissionText, MissionKind.

local Players = game:GetService("Players")
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
local VendorService = require(script.Parent:WaitForChild("VendorService"))

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
	phase: string, -- escort: "drive" → "install"; build: "kill" → "install"
	sitePart: BasePart?,
	prompt: ProximityPrompt?,
	installed: boolean,
}

local current: State? = nil
local objects: Folder? = nil
local rng = Random.new()
local installedSites: { [number]: { instances: { Instance }, shop: Vector3? } } = {}
local suppliedSites: { [number]: { Instance } } = {}

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

-- Точка на земле под (x, z): только дороги, земля и трава (не крыши зданий)
local function groundAt(x: number, z: number, roadsOnly: boolean?): Vector3?
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0))
	if hit and hit.Normal.Y > 0.9 and isGround(hit.Instance) then
		if roadsOnly then
			local roads = workspace:FindFirstChild("Roads")
			if not roads or not hit.Instance:IsDescendantOf(roads) then
				return nil
			end
		end
		local up = workspace:Raycast(hit.Position + Vector3.new(0, 2, 0), Vector3.new(0, 40, 0))
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

-- Контрольные точки района: одни и те же для разведки и конвоя (детерминированно по номеру района), 50–100 студов от места шатра
local function districtPoints(anchorIndex: number, count: number): { Vector3 }
	local seeded = Random.new(7000 + anchorIndex * 31)
	local anchor = MissionService.anchorPosition(anchorIndex)
	local list: { Vector3 } = {}
	local tries = 0
	while #list < count and tries < 120 do
		tries += 1
		local angle = ((#list) / count) * math.pi * 2 + (seeded:NextNumber() - 0.5) * 0.8
		local radius = 50 + seeded:NextNumber() * 50
		local ground = groundAt(anchor.X + math.cos(angle) * radius, anchor.Z + math.sin(angle) * radius)
		if ground then
			table.insert(list, ground)
		end
	end
	return list
end

-- Ближайшая к месту шатра дорога (для остановки конвоя)
local function roadStopNear(site: Vector3): Vector3
	local best: Vector3? = nil
	local bestDist = math.huge
	for r = 12, 60, 8 do
		for i = 0, 15 do
			local a = i / 16 * math.pi * 2
			local p = groundAt(site.X + math.cos(a) * r, site.Z + math.sin(a) * r, true)
			if p and r < bestDist then
				best, bestDist = p, r
			end
		end
		if best then
			break
		end
	end
	return best or Vector3.new(site.X + 25, site.Y, site.Z)
end

local function setStatus(title: string, text: string, kind: string)
	ReplicatedStorage:SetAttribute("MissionTitle", title)
	ReplicatedStorage:SetAttribute("MissionText", text)
	ReplicatedStorage:SetAttribute("MissionKind", kind)
end

local function notify(text: string, seconds: number)
	Remotes.get("Notify"):FireAllClients(text, seconds)
end

local function makeBeacon(pos: Vector3, label: string): BasePart
	local part = Instance.new("Part")
	part.Name = "ScoutBeacon"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(80, 200, 255)
	part.Transparency = 0.35
	part.Size = Vector3.new(2, 30, 2)
	part.Position = pos + Vector3.new(0, 15, 0)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(200, 44)
	gui.StudsOffset = Vector3.new(0, 18, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 1500
	gui.Parent = part
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(120, 220, 255)
	text.TextStrokeTransparency = 0.3
	text.Text = label
	text.Parent = gui
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
	local rec: { instances: { Instance }, shop: Vector3? } = { instances = {}, shop = nil }
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

-- Новый раунд: убираем установленные шатры и припасы
function MissionService.resetRound()
	MissionService.finish()
	for _, rec in installedSites do
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
	gui.Size = UDim2.fromOffset(240, 40)
	gui.StudsOffset = Vector3.new(0, 10, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 1500
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 220, 90)
	label.TextStrokeTransparency = 0.3
	label.Text = "Место шатра"
	label.Parent = gui
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

-- Начало ночи: comp/hpMult — состав и здоровье волны (для подпитки бесконечного потока)
function MissionService.begin(night: number, comp: WaveMath.Composition, hpMult: number): (boolean, string)
	MissionService.finish()
	local def: Config.MissionDef = Config.Missions[night] or { type = "classic", title = string.format("Ночь %d", night), anchor = 1 }
	local anchor = MissionService.anchorPosition(def.anchor)
	objects = Instance.new("Folder")
	objects.Name = "MissionObjects"
	objects.Parent = workspace
	local kind = def.type
	local known = { scout = true, defend = true, clear = true, build = true, escort = true }
	if not known[kind] then
		kind = "classic"
	end
	local state: State = {
		def = def, kind = kind, night = night, anchor = anchor, site = def.anchor, points = {}, secondsLeft = def.seconds or 0,
		infinite = kind == "scout" or kind == "defend" or kind == "build" or kind == "escort", comp = comp, hpMult = hpMult, lastText = "",
		kills = 0, phase = if kind == "build" then "kill" else "drive", sitePart = nil, prompt = nil, installed = false,
	}
	current = state
	ZombieService.setAnchor(anchor)
	if Config.MissionMoveTeam and kind ~= "escort" then
		moveTeam(anchor)
	end
	if kind == "scout" then
		for i, pos in districtPoints(def.anchor, def.points or 3) do
			table.insert(state.points, { pos = pos, part = makeBeacon(pos, string.format("Точка %d", i)), done = false })
		end
	elseif kind == "build" then
		makeSiteMarker(state, false)
	elseif kind == "escort" then
		-- маршрут: контрольные точки района ближайшим соседом от базы, затем дорога у места шатра
		local start = playerSpawnPosition()
		local pts = districtPoints(def.anchor, def.points or 3)
		local route: { Vector3 } = {}
		local from = start
		while #pts > 0 do
			local bi, bd = 1, math.huge
			for i, p in pts do
				local d = (p - from).Magnitude
				if d < bd then
					bi, bd = i, d
				end
			end
			local p = table.remove(pts, bi) :: Vector3
			table.insert(route, p)
			from = p
			makeBeacon(p, string.format("Маршрут %d", #route))
		end
		local stop = roadStopNear(anchor)
		local groundStart = groundAt(start.X, start.Z) or start
		if not ConvoyService.start(groundStart, route, stop) then
			warn("[MissionService] конвой не запущен — миссия играется как обычная ночь")
			state.kind = "classic"
			state.infinite = false
		else
			ZombieService.setAnchor(groundStart)
			ZombieService.setAliveCap(Config.Convoy.AliveCap)
			if def.install then
				makeSiteMarker(state, false)
			end
		end
	end
	setStatus(def.title, def.hint or "", state.kind)
	notify(string.format("Ночь %d — %s", night, def.title), 4)
	return state.infinite, state.kind
end

local function topUp(state: State)
	if state.infinite and ZombieService.queueSize() < 8 then
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
function MissionService.onKill()
	local s = current
	if s then
		s.kills += 1
	end
end

-- Раз в 0,25 с: "done" — миссия выполнена, "fail" — провалена; nil — идёт (classic/clear завершает RoundService по числу зомби)
function MissionService.update(dt: number): string?
	local state = current
	if not state then
		return nil
	end
	topUp(state)
	local kind = state.kind
	local text = ""
	local result: string? = nil
	if kind == "scout" then
		local done = 0
		local ups = upPositions()
		for _, pt in state.points do
			if not pt.done then
				for _, pos in ups do
					if flatDist(pos, pt.pos) < 10 then
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
		local need = state.def.kills or 15
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
			text = "Установите шатёр на отмеченном месте: удерживайте E"
			if state.installed then
				result = "done"
			end
		end
	elseif kind == "escort" then
		if state.phase == "drive" then
			local status = ConvoyService.update(dt)
			text = string.format("Сопровождайте конвой. Прочность грузовика: %d%%", math.floor(ConvoyService.hpFraction() * 100 + 0.5))
			if status == "fail" then
				notify("Конвой уничтожен!", 5)
				result = "fail"
			elseif status == "arrived" then
				dropSupplies(state.site)
				notify("Конвой прибыл — припасы доставлены", 4)
				if state.def.install then
					state.phase = "install"
					if state.prompt then
						state.prompt.Enabled = true
					end
				else
					result = "done"
				end
			end
		else
			ZombieService.moveAnchor(state.anchor)
			text = "Установите шатёр на отмеченном месте: удерживайте E"
			if state.installed then
				result = "done"
			end
		end
	elseif kind == "clear" or kind == "classic" then
		text = string.format("Осталось зомби: %d", (ReplicatedStorage:GetAttribute("ZombiesLeft") :: number?) or 0)
	end
	if text ~= state.lastText then
		state.lastText = text
		ReplicatedStorage:SetAttribute("MissionText", text)
	end
	return result
end

function MissionService.finish()
	ConvoyService.finish()
	if objects then
		objects:Destroy()
		objects = nil
	end
	current = nil
	ZombieService.setAnchor(nil)
	ZombieService.setAliveCap(nil)
	setStatus("", "", "")
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
