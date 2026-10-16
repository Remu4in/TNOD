--!strict
-- Городской квартал 180×180 (≈27 площадей магазина). В центре — магазин (ночью закрыт), вокруг шесть
-- зданий с 2–3 входами: Кафе (бесплатное стартовое укрытие), Медпункт, Склад холодного оружия, Склад проволоки,
-- Оружейная и Убежище — остальные открываются за монеты (см. Config.Buildings и BuildingService).
-- Зомби заходят через четыре прохода в ограде (середины сторон).

local Types = require(script.Parent.Parent:WaitForChild("Types"))
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local BuildKit = require(script.Parent:WaitForChild("BuildKit"))

local City = {}

local HALF = 90 -- половина стороны квартала
local GATE = 12 -- ширина прохода в ограде
local ASPHALT = Color3.fromRGB(46, 48, 52)
local COURTYARD = Color3.fromRGB(98, 99, 95) -- дворы между дорогами
local SIDEWALK = Color3.fromRGB(150, 150, 144)
local PAINT = Color3.fromRGB(215, 185, 60)
local CONCRETE = Color3.fromRGB(110, 110, 108)

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

	-- земля: бетонные дворы. Дороги — асфальтовые полосы (две оси от проходов в ограде + кольцо у ограды),
	-- вдоль осей — приподнятые тротуары, у площади магазина — пешеходные переходы.
	P({ Name = "Ground", Size = Vector3.new(300, 2, 300), Position = Vector3.new(0, -1, 0), Color = COURTYARD, Material = Enum.Material.Pavement }, root)
	local function road(cx: number, cz: number, sx: number, sz: number)
		P({ Name = "Road", Size = Vector3.new(sx, 0.1, sz), Position = Vector3.new(cx, 0.05, cz), Color = ASPHALT, Material = Enum.Material.Asphalt, CanCollide = false, CanQuery = false }, root)
	end
	local function walk(cx: number, cz: number, sx: number, sz: number)
		P({ Name = "Sidewalk", Size = Vector3.new(sx, 0.3, sz), Position = Vector3.new(cx, 0.15, cz), Color = SIDEWALK, Material = Enum.Material.Concrete }, root)
	end
	local function paint(name: string, cx: number, cz: number, sx: number, sz: number)
		P({ Name = name, Size = Vector3.new(sx, 0.04, sz), Position = Vector3.new(cx, 0.12, cz), Color = PAINT, CanCollide = false, CanQuery = false }, root)
	end
	local ROAD_W = GATE -- ширина оси = ширина прохода в ограде
	local RING = HALF - 5 -- кольцо у ограды: центр 85, ширина 6
	road(0, 0, ROAD_W, 2 * (HALF - 2))
	road(0, 0, 2 * (HALF - 2), ROAD_W)
	road(0, RING, 2 * (HALF - 2), 6)
	road(0, -RING, 2 * (HALF - 2), 6)
	road(RING, 0, 6, 2 * (HALF - 2))
	road(-RING, 0, 6, 2 * (HALF - 2))
	-- тротуары вдоль осей (от площади магазина до кольца), по 4 студа с каждой стороны
	local wLen = (RING - 4) - 19
	local wMid = 19 + wLen / 2
	for _, s in { 1, -1 } do
		for _, side in { 1, -1 } do
			walk(side * (ROAD_W / 2 + 2), s * wMid, 4, wLen)
			walk(s * wMid, side * (ROAD_W / 2 + 2), wLen, 4)
		end
	end
	-- осевые пунктиры и «зебры» у площади
	for d = 32, RING - 6, 8 do
		for _, s in { 1, -1 } do
			paint("Dash", 0, s * d, 0.5, 3.5)
			paint("Dash", s * d, 0, 3.5, 0.5)
		end
	end
	for t = -76, 76, 8 do
		if math.abs(t) > 10 then
			for _, s in { 1, -1 } do
				paint("Dash", t, s * RING, 3.5, 0.4)
				paint("Dash", s * RING, t, 0.4, 3.5)
			end
		end
	end
	for i = -3, 3 do
		for _, s in { 1, -1 } do
			paint("Crosswalk", i * 1.6, s * 23.5, 1, 3)
			paint("Crosswalk", s * 28.5, i * 1.6, 3, 1)
		end
	end

	-- ограда квартала с проходами посередине сторон + невидимые стены дальше (чтобы не уйти за карту)
	local function barrier(x0: number, z0: number, x1: number, z1: number)
		local len = math.abs(x1 - x0) + math.abs(z1 - z0)
		local size = if z0 == z1 then Vector3.new(len, 10, 2) else Vector3.new(2, 10, len)
		P({ Name = "Barrier", Size = size, Position = Vector3.new((x0 + x1) / 2, 5, (z0 + z1) / 2), Color = CONCRETE, Material = Enum.Material.Concrete }, root)
	end
	local g = GATE / 2
	for _, s in { 1, -1 } do
		barrier(-HALF, s * HALF, -g, s * HALF)
		barrier(g, s * HALF, HALF, s * HALF)
		barrier(s * HALF, -HALF, s * HALF, -g)
		barrier(s * HALF, g, s * HALF, HALF)
	end
	for _, s in { 1, -1 } do
		P({ Name = "Bound", Size = Vector3.new(260, 60, 2), Position = Vector3.new(0, 30, s * 120), Transparency = 1 }, root)
		P({ Name = "Bound", Size = Vector3.new(2, 60, 260), Position = Vector3.new(s * 120, 30, 0), Transparency = 1 }, root)
	end

	-- силуэт города за оградой
	for i = -3, 3 do
		for _, s in { 1, -1 } do
			local h = 30 + rng:NextInteger(0, 30)
			local shade = rng:NextInteger(38, 62)
			local c = Color3.fromRGB(shade, shade + 4, shade + 10)
			P({ Name = "Skyline", Size = Vector3.new(36, h, 30), Position = Vector3.new(i * 45, h / 2, s * 138), Color = c, Material = Enum.Material.Concrete }, root)
			P({ Name = "Skyline", Size = Vector3.new(30, h, 36), Position = Vector3.new(s * 138, h / 2, i * 45), Color = c, Material = Enum.Material.Concrete }, root)
		end
	end

	local windows: { Types.Window } = {}
	local buildings: { Types.BuildingInfo } = {}
	local function addAll(list: { Types.Window })
		for _, w in list do
			table.insert(windows, w)
		end
	end
	local function sidewalk(center: Vector3, sx: number, sz: number)
		P({ Name = "Sidewalk", Size = Vector3.new(sx + 8, 0.3, sz + 8), Position = Vector3.new(center.X, 0.15, center.Z), Color = SIDEWALK, Material = Enum.Material.Concrete }, root)
	end
	-- Зарегистрировать здание: входы, вывеска (если платное) и места с бонусами. signAt — основание столба вывески.
	local function register(id: string, name: string, ws: { Types.Window }, signAt: Vector3?, spots: { Types.Spot })
		addAll(ws)
		local info: Types.BuildingInfo = { id = id, name = name, windows = ws, signPrompt = nil, signLabel = nil, spots = spots }
		if signAt and costOf(id) > 0 then
			local toCenter = Vector3.new(-signAt.X, 0, -signAt.Z)
			local prompt, label = BuildKit.sign(root, name, signAt, if toCenter.Magnitude > 0.1 then toCenter.Unit else Vector3.new(0, 0, 1))
			info.signPrompt = prompt
			info.signLabel = label
		end
		table.insert(buildings, info)
	end

	-- центр: магазин (ночью закрыт, см. BuildingService)
	local shopWindows, wallBuys = BuildKit.shop(root)
	addAll(shopWindows)
	sidewalk(Vector3.zero, 40, 30)

	-- 1. Кафе (северо-запад, бесплатное): 3 входа — к центру, к югу и тыловой
	do
		local c = Vector3.new(-58, 0, -50)
		sidewalk(c, 30, 22)
		local m, ws = BuildKit.building(root, "Cafe", c, 30, 22, {
			{ side = "E" },
			{ side = "S", offset = -8 },
			{ side = "W" },
		}, { point = "Cafe", wallColor = Color3.fromRGB(190, 160, 110), floorColor = Color3.fromRGB(95, 70, 50), roof = true })
		BuildKit.box(m, "Counter", Vector3.new(14, 3.5, 2), c + Vector3.new(-4, 0, -8), Color3.fromRGB(110, 70, 40), Enum.Material.Wood)
		BuildKit.box(m, "BackShelf", Vector3.new(14, 7, 1), c + Vector3.new(-4, 0, -10.5), Color3.fromRGB(80, 55, 35), Enum.Material.Wood)
		for _, t in { Vector3.new(7, 0, -5), Vector3.new(7, 0, 5), Vector3.new(1, 0, 3) } do
			BuildKit.box(m, "Table", Vector3.new(4, 2.6, 4), c + t, Color3.fromRGB(150, 120, 80), Enum.Material.Wood)
		end
		BuildKit.slot(m, c + Vector3.new(11, 0, -7), "Turret")
		BuildKit.slot(m, c + Vector3.new(-11, 0, 6), "Trap")
		register("Cafe", "Кафе", ws, nil, {})
	end

	-- 2. Медпункт (юго-запад, 500): 2 входа, на прилавке — аптечки и энергетики
	do
		local c = Vector3.new(-52, 0, 56)
		sidewalk(c, 26, 22)
		local m, ws = BuildKit.building(root, "Pharmacy", c, 26, 22, {
			{ side = "E" },
			{ side = "N" },
		}, { point = "Pharmacy", wallColor = Color3.fromRGB(205, 215, 205), floorColor = Color3.fromRGB(190, 195, 190), floorMaterial = Enum.Material.Marble, roof = true })
		for _, x in { -9, -3 } do
			BuildKit.box(m, "Shelf", Vector3.new(2, 7, 12), c + Vector3.new(x, 0, 2), Color3.fromRGB(235, 235, 235), Enum.Material.Metal)
		end
		BuildKit.box(m, "Counter", Vector3.new(8, 3.5, 2), c + Vector3.new(8, 0, 6), Color3.fromRGB(70, 140, 90), Enum.Material.SmoothPlastic)
		local medkit = BuildKit.interact(m, "MedkitBox", c + Vector3.new(6, 3.5, 6), Vector3.new(1.8, 1, 1.4), Color3.fromRGB(240, 240, 240), "Взять аптечку", "Аптечки")
		local energy = BuildKit.interact(m, "EnergyBox", c + Vector3.new(10, 3.5, 6), Vector3.new(1.8, 1, 1.4), Color3.fromRGB(60, 190, 255), "Взять энергетик", "Энергетики")
		BuildKit.slot(m, c + Vector3.new(8, 0, -6), "Turret")
		BuildKit.slot(m, c + Vector3.new(0, 0, 8), "Trap")
		register("Pharmacy", "Медпункт", ws, Vector3.new(-34, 0, 44), {
			{ kind = "medkit", prompt = medkit },
			{ kind = "energy", prompt = energy },
		})
	end

	-- 3. Склад холодного оружия (север, 1000): 2 входа, стойки с битой и мачете
	do
		local c = Vector3.new(30, 0, -62)
		sidewalk(c, 16, 14)
		local m, ws = BuildKit.building(root, "ColdStore", c, 16, 14, {
			{ side = "S" },
			{ side = "W" },
		}, { point = "ColdStore", wallColor = Color3.fromRGB(125, 105, 85), floorColor = Color3.fromRGB(70, 60, 50), floorMaterial = Enum.Material.Concrete, roof = true })
		BuildKit.box(m, "Bench", Vector3.new(10, 3, 2), c + Vector3.new(0, 0, -5), Color3.fromRGB(100, 80, 55), Enum.Material.Wood)
		local bat = BuildKit.interact(m, "BatRack", c + Vector3.new(-3, 3, -5), Vector3.new(2.4, 0.8, 1.2), Color3.fromRGB(150, 110, 60), "Взять биту", "Холодное оружие")
		local machete = BuildKit.interact(m, "MacheteRack", c + Vector3.new(3, 3, -5), Vector3.new(2.4, 0.8, 1.2), Color3.fromRGB(130, 135, 140), "Взять мачете", "Холодное оружие")
		register("ColdStore", "Склад холодного оружия", ws, Vector3.new(24, 0, -48), {
			{ kind = "melee:Bat", prompt = bat },
			{ kind = "melee:Machete", prompt = machete },
		})
	end

	-- 4. Гараж / Склад проволоки (восток, 2000): 3 входа — широкие ворота к центру и две двери
	do
		local c = Vector3.new(62, 0, 22)
		sidewalk(c, 34, 24)
		local m, ws = BuildKit.building(root, "Garage", c, 34, 24, {
			{ side = "W", width = 9 },
			{ side = "N", offset = 6 },
			{ side = "S", offset = -6 },
		}, { point = "Garage", wallColor = Color3.fromRGB(120, 125, 130), floorColor = Color3.fromRGB(70, 70, 72), floorMaterial = Enum.Material.Concrete, roof = true })
		BuildKit.car(m, c.X + 3, c.Z, 90, Color3.fromRGB(150, 60, 50))
		BuildKit.box(m, "Workbench", Vector3.new(2, 3.2, 10), c + Vector3.new(15.5, 0, 0), Color3.fromRGB(180, 110, 40), Enum.Material.Metal)
		for _, z in { -8, 8 } do
			BuildKit.box(m, "Crate", Vector3.new(3, 3, 3), c + Vector3.new(14, 0, z), Color3.fromRGB(140, 105, 60), Enum.Material.Wood)
		end
		BuildKit.slot(m, c + Vector3.new(-10, 0, -8), "Turret")
		BuildKit.slot(m, c + Vector3.new(-10, 0, 8), "Turret")
		BuildKit.slot(m, c + Vector3.new(10, 0, 8), "Trap")
		register("Garage", "Склад проволоки", ws, Vector3.new(39, 0, 28), {})
	end

	-- 5. Оружейная (северо-восток, 3000): большое здание, 2 входа
	do
		local c = Vector3.new(62, 0, -58)
		sidewalk(c, 30, 30)
		local m, ws = BuildKit.building(root, "Armory", c, 30, 30, {
			{ side = "S", offset = -6 },
			{ side = "W" },
		}, { point = "Armory", wallColor = Color3.fromRGB(120, 70, 60), floorColor = Color3.fromRGB(80, 70, 70), floorMaterial = Enum.Material.Concrete, roof = true })
		for _, x in { -8, 0, 8 } do
			BuildKit.box(m, "WeaponRack", Vector3.new(5, 4, 1.5), c + Vector3.new(x, 0, -11), Color3.fromRGB(55, 55, 60), Enum.Material.Metal)
		end
		BuildKit.box(m, "Crate", Vector3.new(4, 4, 4), c + Vector3.new(10, 0, 8), Color3.fromRGB(90, 100, 70), Enum.Material.Wood)
		BuildKit.slot(m, c + Vector3.new(-8, 0, 8), "Turret")
		register("Armory", "Оружейная", ws, Vector3.new(50, 0, -34), {})
	end

	-- 6. Убежище (юго-восток, 4000): 3 входа
	do
		local c = Vector3.new(62, 0, 66)
		sidewalk(c, 26, 26)
		local m, ws = BuildKit.building(root, "Shelter", c, 26, 26, {
			{ side = "N" },
			{ side = "W" },
			{ side = "S", offset = 4 },
		}, { point = "Shelter", wallColor = Color3.fromRGB(95, 100, 115), floorColor = Color3.fromRGB(60, 62, 70), floorMaterial = Enum.Material.Concrete, roof = true })
		for _, z in { -6, 0, 6 } do
			BuildKit.box(m, "Bunk", Vector3.new(8, 2.5, 3), c + Vector3.new(7, 0, z), Color3.fromRGB(70, 80, 70), Enum.Material.Metal)
		end
		BuildKit.slot(m, c + Vector3.new(-8, 0, 0), "Turret")
		register("Shelter", "Убежище", ws, Vector3.new(48, 0, 50), {})
	end

	-- глухие дома-декорации (повторяющиеся блоки)
	for _, spot in { Vector3.new(-24, 0, -72), Vector3.new(28, 0, 70), Vector3.new(-24, 0, 68) } do
		local shade = rng:NextInteger(90, 140)
		BuildKit.block(root, spot, 16, 14, 10, Color3.fromRGB(shade, shade - 10, shade - 20))
	end

	-- машины-укрытия на подходах и в проулках
	local carColors = { Color3.fromRGB(140, 140, 145), Color3.fromRGB(60, 80, 130), Color3.fromRGB(150, 150, 60), Color3.fromRGB(120, 50, 50) }
	local cars = {
		{ 4, -44, 15 }, { -5, -66, 90 }, { 6, -80, -10 }, { -3, 44, 170 }, { 5, 62, 80 }, { -6, 82, 10 },
		{ 44, 3, 100 }, { 66, -4, 10 }, { 82, 5, 95 }, { -44, -4, 80 }, { -64, 5, 170 }, { -82, -5, 95 },
		{ 30, -30, 45 }, { -32, 34, -30 }, { 36, 40, 60 }, { -28, -34, 20 },
	}
	for i, car in cars do
		BuildKit.car(root, car[1], car[2], car[3], carColors[(i % #carColors) + 1])
	end
	for _, d in { Vector2.new(12, -30), Vector2.new(-12, 32), Vector2.new(40, -12), Vector2.new(-38, 16) } do
		BuildKit.dumpster(root, d.X, d.Y)
	end
	for _, l in { Vector2.new(-15, -40), Vector2.new(15, 40), Vector2.new(40, 15), Vector2.new(-40, -15) } do
		BuildKit.lamppost(root, l.X, l.Y)
	end

	root.Parent = workspace

	return {
		id = "City",
		name = "Городской квартал",
		root = root,
		windows = windows,
		buildings = buildings,
		shop = { center = Vector3.zero, halfX = 20, halfZ = 15 },
		zombieSpawns = {
			Vector3.new(0, 3, HALF + 8),
			Vector3.new(0, 3, -HALF - 8),
			Vector3.new(HALF + 8, 3, 0),
			Vector3.new(-HALF - 8, 3, 0),
		},
		playerSpawn = Vector3.new(0, 3, 0),
		nightSpawn = Vector3.new(-58, 3, -50),
		wallBuys = wallBuys,
	}
end

return City
