--!strict
-- «Каменные джунгли»: переулок Нью-Йорка. Сетка 4×4 кварталов по 64 студа, между ними улицы шириной 36
-- (проезжая часть 20 + тротуары по 8). Каждый квартал — 15–20-этажная башня. В шести башнях на первом этаже
-- есть помещения: Кафе (бесплатное стартовое укрытие), Медпункт, Склад холодного оружия, Склад проволоки,
-- Оружейная и Убежище — остальные открываются за монеты (см. Config.Buildings и BuildingService).
-- Магазин — шатёр, раскинутый на центральном перекрёстке. Зомби приходят через ворота в ограде на трёх улицах
-- с каждой стороны. Параметры сетки — константы ниже: COUNT = 6 даст карту ещё в 2 раза больше по площади.

local Types = require(script.Parent.Parent:WaitForChild("Types"))
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local BuildKit = require(script.Parent:WaitForChild("BuildKit"))

local City = {}

local COUNT = 4 -- кварталов по стороне (чётное: на перекрёстке в центре стоит шатёр магазина)
local PITCH = 100 -- расстояние между осями улиц
local ROAD = 20 -- проезжая часть
local WALK = 8 -- тротуар с каждой стороны
local STREET = ROAD + 2 * WALK
local FOOT = 60 -- сторона основания башни
local EDGE = (COUNT / 2) * PITCH + STREET / 2 -- ограда
local FLOOR_H = 4.2
local ROOM_D, ROOM_W, ROOM_H = 26, 44, 12.6 -- комната на первом этаже: глубина, ширина, верх крыши

local ASPHALT = Color3.fromRGB(46, 48, 52)
local COURTYARD = Color3.fromRGB(80, 81, 78)
local SIDEWALK = Color3.fromRGB(150, 150, 144)
local PAINT = Color3.fromRGB(215, 185, 60)
local CONCRETE = Color3.fromRGB(110, 110, 108)
local TOWER_COLORS = {
	Color3.fromRGB(120, 78, 62), -- кирпич
	Color3.fromRGB(98, 100, 104), -- серый камень
	Color3.fromRGB(150, 138, 118), -- песчаник
	Color3.fromRGB(70, 74, 84), -- тёмный гранит
	Color3.fromRGB(132, 112, 98),
}

-- Помещения: центр квартала, с какой стороны башни (к какой улице) выходит комната, боковые входы в переулки
local ROOMS = {
	Cafe = { bx = -50, bz = -50, side = "E", lateral = { "N", "S" } },
	Pharmacy = { bx = 50, bz = 50, side = "W", lateral = { "N", "S" } },
	ColdStore = { bx = -150, bz = 50, side = "E", lateral = { "N" } },
	Garage = { bx = 150, bz = -50, side = "W", lateral = { "N", "S" } },
	Armory = { bx = 150, bz = -150, side = "W", lateral = { "S" } },
	Shelter = { bx = -50, bz = 150, side = "E", lateral = { "N", "S" } },
}

local function costOf(id: string): number
	for _, def in Config.Buildings do
		if def.id == id then
			return def.cost
		end
	end
	return 0
end

function City.build(): Types.MapInfo
	BuildKit.reset()
	local root = Instance.new("Model")
	root.Name = "Map"
	local P = BuildKit.part
	local rng = Random.new(7)

	-- центры кварталов и оси улиц
	local centers: { number } = {}
	for i = 1, COUNT do
		centers[i] = (i - (COUNT + 1) / 2) * PITCH
	end
	local lines: { number } = {}
	for k = -COUNT / 2, COUNT / 2 do
		table.insert(lines, k * PITCH)
	end
	local gates = { -PITCH, 0, PITCH } -- улицы, на которых в ограде есть ворота

	-- земля, дороги, тротуары, разметка -------------------------------------------------------------
	P({ Name = "Ground", Size = Vector3.new(900, 2, 900), Position = Vector3.new(0, -1, 0), Color = COURTYARD, Material = Enum.Material.Pavement }, root)
	local roadLen = 2 * (EDGE + 70)
	for _, s in lines do
		P({ Name = "Road", Size = Vector3.new(ROAD, 0.1, roadLen), Position = Vector3.new(s, 0.05, 0), Color = ASPHALT, Material = Enum.Material.Asphalt, CanCollide = false, CanQuery = false }, root)
		P({ Name = "Road", Size = Vector3.new(roadLen, 0.1, ROAD), Position = Vector3.new(0, 0.05, s), Color = ASPHALT, Material = Enum.Material.Asphalt, CanCollide = false, CanQuery = false }, root)
	end
	for _, bx in centers do
		for _, bz in centers do
			P({ Name = "Sidewalk", Size = Vector3.new(PITCH - ROAD, 0.3, PITCH - ROAD), Position = Vector3.new(bx, 0.15, bz), Color = SIDEWALK, Material = Enum.Material.Concrete }, root)
		end
	end
	local function paint(name: string, cx: number, cz: number, sx: number, sz: number)
		P({ Name = name, Size = Vector3.new(sx, 0.04, sz), Position = Vector3.new(cx, 0.12, cz), Color = PAINT, CanCollide = false, CanQuery = false }, root)
	end
	local function nearCross(t: number): boolean
		return math.abs(((t + PITCH / 2) % PITCH) - PITCH / 2) < ROAD / 2 + 4
	end
	for _, s in lines do
		for t = -EDGE + 6, EDGE - 6, 10 do
			if not nearCross(t) then
				paint("Dash", s, t, 0.5, 4)
				paint("Dash", t, s, 4, 0.5)
			end
		end
	end
	for i = -3, 3 do -- «зебры» вокруг шатра на центральном перекрёстке
		for _, s in { 1, -1 } do
			paint("Crosswalk", i * 2.4, s * 22, 1.2, 3.5)
			paint("Crosswalk", s * 26, i * 2.4, 3.5, 1.2)
		end
	end

	-- ограда с воротами на трёх улицах и невидимые стены дальше -------------------------------------------
	local function fence(fixed: number, alongX: boolean)
		local function seg(t0: number, t1: number)
			local len = t1 - t0
			if len <= 0.5 then
				return
			end
			local size = if alongX then Vector3.new(len, 10, 2) else Vector3.new(2, 10, len)
			local pos = if alongX then Vector3.new((t0 + t1) / 2, 5, fixed) else Vector3.new(fixed, 5, (t0 + t1) / 2)
			P({ Name = "Barrier", Size = size, Position = pos, Color = CONCRETE, Material = Enum.Material.Concrete }, root)
		end
		local cur = -EDGE
		for _, g in gates do
			seg(cur, g - ROAD / 2)
			cur = g + ROAD / 2
		end
		seg(cur, EDGE)
	end
	for _, s in { 1, -1 } do
		fence(s * EDGE, true)
		fence(s * EDGE, false)
		P({ Name = "Bound", Size = Vector3.new(2 * EDGE + 200, 80, 2), Position = Vector3.new(0, 40, s * (EDGE + 80)), Transparency = 1 }, root)
		P({ Name = "Bound", Size = Vector3.new(2, 80, 2 * EDGE + 200), Position = Vector3.new(s * (EDGE + 80), 40, 0), Transparency = 1 }, root)
	end

	-- внешнее кольцо башен за оградой: стены-задники; обращена к карте только внутренняя грань
	do
		local ring = { -250, -150, -50, 50, 150, 250 }
		local function outer(x: number, z: number, inward: Vector3)
			local h = rng:NextInteger(60, 110)
			local shade = rng:NextInteger(34, 56)
			local body = Color3.fromRGB(shade, shade + 4, shade + 10)
			P({ Name = "OuterTower", Size = Vector3.new(FOOT, h, FOOT), Position = Vector3.new(x, h / 2, z), Color = body, Material = Enum.Material.Concrete }, root)
			BuildKit.facade(root, Vector3.new(x, 0, z), FOOT, FOOT, 0, h, rng, { inward })
		end
		for _, p in ring do
			outer(p, -EDGE - 32, Vector3.new(0, 0, 1))
			outer(p, EDGE + 32, Vector3.new(0, 0, -1))
		end
		for _, p in { -150, -50, 50, 150 } do
			outer(-EDGE - 32, p, Vector3.new(1, 0, 0))
			outer(EDGE + 32, p, Vector3.new(-1, 0, 0))
		end
	end

	-- башни кварталов -------------------------------------------------------------------------------------
	local windows: { Types.Window } = {}
	local buildings: { Types.BuildingInfo } = {}
	local function addAll(list: { Types.Window })
		for _, w in list do
			table.insert(windows, w)
		end
	end
	-- Зарегистрировать здание: входы, вывеска (если платное) и места с бонусами. signAt — основание столба вывески.
	local function register(id: string, name: string, ws: { Types.Window }, signAt: Vector3, facing: Vector3, spots: { Types.Spot })
		addAll(ws)
		local info: Types.BuildingInfo = { id = id, name = name, windows = ws, signPrompt = nil, signLabel = nil, spots = spots }
		if costOf(id) > 0 then
			local prompt, label = BuildKit.sign(root, name, signAt, facing)
			info.signPrompt = prompt
			info.signLabel = label
		end
		table.insert(buildings, info)
	end

	-- Корпус башни: сплошной блок + фасад + карниз (+ иногда уступ-надстройка)
	local function mass(center: Vector3, sx: number, sz: number, y0: number, y1: number, color: Color3, faces: { Vector3 }?)
		local h = y1 - y0
		P({ Name = "Tower", Size = Vector3.new(sx, h, sz), Position = Vector3.new(center.X, y0 + h / 2, center.Z), Color = color, Material = Enum.Material.Concrete }, root)
		BuildKit.facade(root, center, sx, sz, y0, h, rng, faces)
		P({ Name = "Cornice", Size = Vector3.new(sx + 1.2, 0.9, sz + 1.2), Position = Vector3.new(center.X, y1 + 0.45, center.Z), Color = Color3.fromRGB(48, 48, 52), Material = Enum.Material.Concrete }, root)
	end
	local function setback(center: Vector3, baseTop: number, color: Color3)
		if rng:NextNumber() < 0.55 then
			local f = rng:NextInteger(2, 4)
			mass(center, FOOT * 0.66, FOOT * 0.66, baseTop + 1, baseTop + 1 + f * FLOOR_H, color)
		end
	end
	local function pick(): Color3
		return TOWER_COLORS[rng:NextInteger(1, #TOWER_COLORS)]
	end

	-- обычная башня
	local function plainTower(bx: number, bz: number)
		local floors = if rng:NextNumber() < 0.2 then rng:NextInteger(7, 11) else rng:NextInteger(15, 20)
		local color = pick()
		local top = floors * FLOOR_H
		mass(Vector3.new(bx, 0, bz), FOOT, FOOT, 0, top, color)
		setback(Vector3.new(bx, 0, bz), top + 0.9, color)
	end

	-- башня с комнатой на первом этаже у улицы; по бокам комнаты — узкие переулки с боковыми входами
	local function roomTower(id: string, name: string, def: { bx: number, bz: number, side: string, lateral: { string } }, style: BuildKit.Style, furnish: (m: Model, at: (number, number) -> Vector3, fx: number) -> { Types.Spot }): ()
		local bx, bz = def.bx, def.bz
		local half = FOOT / 2
		local fx = if def.side == "E" then 1 else -1
		local floors = rng:NextInteger(15, 20)
		local top = floors * FLOOR_H
		local color = pick()
		local c = Vector3.new(bx + fx * (half - ROOM_D / 2), 0, bz)

		local openings: { BuildKit.Opening } = { { side = def.side :: BuildKit.Side, width = 9 } }
		for _, lat in def.lateral do
			table.insert(openings, { side = lat :: BuildKit.Side, width = 8 })
		end
		local m, ws = BuildKit.building(root, id, c, ROOM_D, ROOM_W, openings, style)

		-- задняя часть башни на всю высоту и надстройка над комнатой
		local backW = FOOT - ROOM_D
		mass(Vector3.new(bx - fx * ROOM_D / 2, 0, bz), backW, FOOT, 0, top, color)
		mass(Vector3.new(c.X, 0, bz), ROOM_D, ROOM_W, ROOM_H + 0.4, top, color, { Vector3.new(fx, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) })

		local function at(lx: number, lz: number): Vector3
			return Vector3.new(c.X + fx * lx, 0, c.Z + lz)
		end
		local spots = furnish(m, at, fx)
		BuildKit.dumpster(root, bx + fx * 24, bz + 26 * (if rng:NextNumber() < 0.5 then 1 else -1)) -- в переулке

		local signAt = Vector3.new(bx + fx * (half + 5), 0, bz + 14)
		register(id, name, ws, signAt, Vector3.new(fx, 0, 0), spots)
	end

	local V = Vector3.new

	roomTower("Cafe", "Кафе", ROOMS.Cafe, { point = "Cafe", wallColor = Color3.fromRGB(190, 160, 110), floorColor = Color3.fromRGB(95, 70, 50), roof = true }, function(m, at, fx)
		BuildKit.box(m, "Counter", V(2, 3.5, 14), at(-6, -11), Color3.fromRGB(110, 70, 40), Enum.Material.Wood)
		BuildKit.box(m, "BackShelf", V(1, 7, 14), at(-11.5, -11), Color3.fromRGB(80, 55, 35), Enum.Material.Wood)
		for _, t in { at(3, -13), at(3, 13), at(-3, 8) } do
			BuildKit.box(m, "Table", V(4, 2.6, 4), t, Color3.fromRGB(150, 120, 80), Enum.Material.Wood)
		end
		BuildKit.slot(m, at(9, -17), "Turret")
		BuildKit.slot(m, at(-9, 17), "Trap")
		return {}
	end)

	roomTower("Pharmacy", "Медпункт", ROOMS.Pharmacy, { point = "Pharmacy", wallColor = Color3.fromRGB(205, 215, 205), floorColor = Color3.fromRGB(190, 195, 190), floorMaterial = Enum.Material.Marble, roof = true }, function(m, at, fx)
		for _, z in { -10, 10 } do
			BuildKit.box(m, "Shelf", V(2, 7, 14), at(-10, z), Color3.fromRGB(235, 235, 235), Enum.Material.Metal)
		end
		BuildKit.box(m, "Counter", V(2, 3.5, 8), at(0, -12), Color3.fromRGB(70, 140, 90), Enum.Material.SmoothPlastic)
		local medkit = BuildKit.interact(m, "MedkitBox", at(0, -14) + V(0, 3.5, 0), V(1.4, 1, 1.8), Color3.fromRGB(240, 240, 240), "Взять аптечку", "Аптечки")
		local energy = BuildKit.interact(m, "EnergyBox", at(0, -10) + V(0, 3.5, 0), V(1.4, 1, 1.8), Color3.fromRGB(60, 190, 255), "Взять энергетик", "Энергетики")
		BuildKit.slot(m, at(8, 17), "Turret")
		BuildKit.slot(m, at(-4, 17), "Trap")
		return { { kind = "medkit", prompt = medkit }, { kind = "energy", prompt = energy } }
	end)

	roomTower("ColdStore", "Склад холодного оружия", ROOMS.ColdStore, { point = "ColdStore", wallColor = Color3.fromRGB(125, 105, 85), floorColor = Color3.fromRGB(70, 60, 50), floorMaterial = Enum.Material.Concrete, roof = true }, function(m, at, fx)
		BuildKit.box(m, "Bench", V(2, 3, 14), at(-10, 0), Color3.fromRGB(100, 80, 55), Enum.Material.Wood)
		local bat = BuildKit.interact(m, "BatRack", at(-10, -4) + V(0, 3, 0), V(1.2, 0.8, 2.4), Color3.fromRGB(150, 110, 60), "Взять биту", "Холодное оружие")
		local machete = BuildKit.interact(m, "MacheteRack", at(-10, 4) + V(0, 3, 0), V(1.2, 0.8, 2.4), Color3.fromRGB(130, 135, 140), "Взять мачете", "Холодное оружие")
		return { { kind = "melee:Bat", prompt = bat }, { kind = "melee:Machete", prompt = machete } }
	end)

	roomTower("Garage", "Склад проволоки", ROOMS.Garage, { point = "Garage", wallColor = Color3.fromRGB(120, 125, 130), floorColor = Color3.fromRGB(70, 70, 72), floorMaterial = Enum.Material.Concrete, roof = true }, function(m, at, fx)
		local p = at(-2, 0)
		BuildKit.car(m, p.X, p.Z, 0, Color3.fromRGB(150, 60, 50))
		BuildKit.box(m, "Workbench", V(2, 3.2, 10), at(-11.5, 0), Color3.fromRGB(180, 110, 40), Enum.Material.Metal)
		for _, z in { -12, 12 } do
			BuildKit.box(m, "Crate", V(3, 3, 3), at(-10, z), Color3.fromRGB(140, 105, 60), Enum.Material.Wood)
		end
		BuildKit.slot(m, at(8, -16), "Turret")
		BuildKit.slot(m, at(8, 16), "Turret")
		BuildKit.slot(m, at(-6, 16), "Trap")
		return {}
	end)

	roomTower("Armory", "Оружейная", ROOMS.Armory, { point = "Armory", wallColor = Color3.fromRGB(120, 70, 60), floorColor = Color3.fromRGB(80, 70, 70), floorMaterial = Enum.Material.Concrete, roof = true }, function(m, at, fx)
		for _, z in { -10, 0, 10 } do
			BuildKit.box(m, "WeaponRack", V(1.5, 4, 5), at(-11, z), Color3.fromRGB(55, 55, 60), Enum.Material.Metal)
		end
		BuildKit.box(m, "Crate", V(4, 4, 4), at(8, 14), Color3.fromRGB(90, 100, 70), Enum.Material.Wood)
		BuildKit.slot(m, at(8, -14), "Turret")
		return {}
	end)

	roomTower("Shelter", "Убежище", ROOMS.Shelter, { point = "Shelter", wallColor = Color3.fromRGB(95, 100, 115), floorColor = Color3.fromRGB(60, 62, 70), floorMaterial = Enum.Material.Concrete, roof = true }, function(m, at, fx)
		for _, z in { -12, 0, 12 } do
			BuildKit.box(m, "Bunk", V(3, 2.5, 8), at(-10, z), Color3.fromRGB(70, 80, 70), Enum.Material.Metal)
		end
		BuildKit.slot(m, at(8, -16), "Turret")
		return {}
	end)

	-- остальные кварталы — обычные башни
	local taken: { [string]: boolean } = {}
	for _, def in ROOMS do
		taken[def.bx .. "," .. def.bz] = true
	end
	for _, bx in centers do
		for _, bz in centers do
			if not taken[bx .. "," .. bz] then
				plainTower(bx, bz)
			end
		end
	end

	-- шатёр-магазин на центральном перекрёстке (ночью закрыт, см. BuildingService)
	local shopWindows, wallBuys = BuildKit.shop(root)
	addAll(shopWindows)

	-- улицы: машины-укрытия, фонари ----------------------------------------------------------------------
	local carColors = { Color3.fromRGB(140, 140, 145), Color3.fromRGB(60, 80, 130), Color3.fromRGB(150, 150, 60), Color3.fromRGB(120, 50, 50), Color3.fromRGB(40, 40, 44) }
	for _, s in lines do
		for k = -COUNT / 2, COUNT / 2 - 1 do
			local mid = k * PITCH + PITCH / 2 -- середина квартала вдоль улицы
			local side = if rng:NextNumber() < 0.5 then 1 else -1
			local jitter = rng:NextNumber(-14, 14)
			local color = carColors[rng:NextInteger(1, #carColors)]
			if rng:NextNumber() < 0.5 then
				BuildKit.car(root, s + side * 5.5, mid + jitter, 0, color)
			else
				BuildKit.car(root, mid + jitter, s + side * 5.5, 90, color)
			end
			BuildKit.lamppost(root, s + ROAD / 2 + 1.5, mid - 22)
			BuildKit.lamppost(root, s - ROAD / 2 - 1.5, mid + 22)
			BuildKit.lamppost(root, mid + 22, s + ROAD / 2 + 1.5)
			BuildKit.lamppost(root, mid - 22, s - ROAD / 2 - 1.5)
		end
	end

	root.Parent = workspace

	local spawns: { Vector3 } = {}
	for _, g in gates do
		table.insert(spawns, Vector3.new(g, 3, EDGE + 45))
		table.insert(spawns, Vector3.new(g, 3, -EDGE - 45))
		table.insert(spawns, Vector3.new(EDGE + 45, 3, g))
		table.insert(spawns, Vector3.new(-EDGE - 45, 3, g))
	end

	local cafe = ROOMS.Cafe
	return {
		id = "City",
		name = "Городской квартал",
		root = root,
		windows = windows,
		buildings = buildings,
		shop = { center = Vector3.zero, halfX = 20, halfZ = 15 },
		zombieSpawns = spawns,
		playerSpawn = Vector3.new(0, 3, 0),
		nightSpawn = Vector3.new(cafe.bx + 17, 3, cafe.bz),
		wallBuys = wallBuys,
	}
end

return City
