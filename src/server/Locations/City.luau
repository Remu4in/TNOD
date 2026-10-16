--!strict
-- Городской квартал 180×180 (≈27 площадей магазина). В центре — магазин, вокруг три точки обороны
-- с 2–3 входами (кафе, гараж, аптека), глухие дома, машины и баррикады-«бетонка» по периметру.
-- Зомби заходят через четыре прохода в ограде (середины сторон).

local Types = require(script.Parent.Parent:WaitForChild("Types"))
local BuildKit = require(script.Parent:WaitForChild("BuildKit"))

local City = {}

local HALF = 90 -- половина стороны квартала
local GATE = 12 -- ширина прохода в ограде
local ASPHALT = Color3.fromRGB(58, 60, 64)
local SIDEWALK = Color3.fromRGB(125, 125, 120)
local CONCRETE = Color3.fromRGB(110, 110, 108)

function City.build(): Types.MapInfo
	BuildKit.reset()
	local root = Instance.new("Model")
	root.Name = "Map"
	local P = BuildKit.part
	local rng = Random.new(7)

	-- земля и разметка вдоль подходов к магазину
	P({ Name = "Ground", Size = Vector3.new(300, 2, 300), Position = Vector3.new(0, -1, 0), Color = ASPHALT, Material = Enum.Material.Asphalt }, root)
	local paint = Color3.fromRGB(215, 185, 60)
	for d = 30, HALF - 4, 8 do
		for _, s in { 1, -1 } do
			P({ Name = "Marking", Size = Vector3.new(0.8, 0.1, 4), Position = Vector3.new(0, 0.05, s * d), Color = paint, CanCollide = false }, root)
			P({ Name = "Marking", Size = Vector3.new(4, 0.1, 0.8), Position = Vector3.new(s * (d - 2), 0.05, 0), Color = paint, CanCollide = false }, root)
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
	local function addAll(list: { Types.Window })
		for _, w in list do
			table.insert(windows, w)
		end
	end
	local function sidewalk(center: Vector3, sx: number, sz: number)
		P({ Name = "Sidewalk", Size = Vector3.new(sx + 8, 0.3, sz + 8), Position = Vector3.new(center.X, 0.15, center.Z), Color = SIDEWALK, Material = Enum.Material.Concrete }, root)
	end

	-- центр: магазин
	local shopWindows, wallBuys = BuildKit.shop(root)
	addAll(shopWindows)
	sidewalk(Vector3.zero, 40, 30)

	-- 1. Кафе (северо-запад): 3 входа — к центру, к югу и тыловой
	do
		local c = Vector3.new(-58, 0, -50)
		sidewalk(c, 30, 22)
		local m, ws = BuildKit.building(root, "Cafe", c, 30, 22, {
			{ side = "E" },
			{ side = "S", offset = -8 },
			{ side = "W" },
		}, { point = "Cafe", wallColor = Color3.fromRGB(190, 160, 110), floorColor = Color3.fromRGB(95, 70, 50), roof = true })
		addAll(ws)
		BuildKit.box(m, "Counter", Vector3.new(14, 3.5, 2), c + Vector3.new(-4, 0, -8), Color3.fromRGB(110, 70, 40), Enum.Material.Wood)
		BuildKit.box(m, "BackShelf", Vector3.new(14, 7, 1), c + Vector3.new(-4, 0, -10.5), Color3.fromRGB(80, 55, 35), Enum.Material.Wood)
		for _, t in { Vector3.new(7, 0, -5), Vector3.new(7, 0, 5), Vector3.new(1, 0, 3) } do
			BuildKit.box(m, "Table", Vector3.new(4, 2.6, 4), c + t, Color3.fromRGB(150, 120, 80), Enum.Material.Wood)
		end
		BuildKit.slot(m, c + Vector3.new(11, 0, -7), "Turret")
		BuildKit.slot(m, c + Vector3.new(-11, 0, 6), "Trap")
	end

	-- 2. Гараж (восток): 3 входа — широкие ворота к центру и две двери
	do
		local c = Vector3.new(62, 0, 22)
		sidewalk(c, 34, 24)
		local m, ws = BuildKit.building(root, "Garage", c, 34, 24, {
			{ side = "W", width = 9 },
			{ side = "N", offset = 6 },
			{ side = "S", offset = -6 },
		}, { point = "Garage", wallColor = Color3.fromRGB(120, 125, 130), floorColor = Color3.fromRGB(70, 70, 72), floorMaterial = Enum.Material.Concrete, roof = true })
		addAll(ws)
		BuildKit.car(m, c.X + 3, c.Z, 90, Color3.fromRGB(150, 60, 50))
		BuildKit.box(m, "Workbench", Vector3.new(2, 3.2, 10), c + Vector3.new(15.5, 0, 0), Color3.fromRGB(180, 110, 40), Enum.Material.Metal)
		for _, z in { -8, 8 } do
			BuildKit.box(m, "Crate", Vector3.new(3, 3, 3), c + Vector3.new(14, 0, z), Color3.fromRGB(140, 105, 60), Enum.Material.Wood)
		end
		BuildKit.slot(m, c + Vector3.new(-10, 0, -8), "Turret")
		BuildKit.slot(m, c + Vector3.new(-10, 0, 8), "Turret")
		BuildKit.slot(m, c + Vector3.new(10, 0, 8), "Trap")
	end

	-- 3. Аптека (юго-запад): 2 входа
	do
		local c = Vector3.new(-52, 0, 56)
		sidewalk(c, 26, 22)
		local m, ws = BuildKit.building(root, "Pharmacy", c, 26, 22, {
			{ side = "E" },
			{ side = "N" },
		}, { point = "Pharmacy", wallColor = Color3.fromRGB(205, 215, 205), floorColor = Color3.fromRGB(190, 195, 190), floorMaterial = Enum.Material.Marble, roof = true })
		addAll(ws)
		for _, x in { -9, -3 } do
			BuildKit.box(m, "Shelf", Vector3.new(2, 7, 12), c + Vector3.new(x, 0, 2), Color3.fromRGB(235, 235, 235), Enum.Material.Metal)
		end
		BuildKit.box(m, "Counter", Vector3.new(8, 3.5, 2), c + Vector3.new(8, 0, 6), Color3.fromRGB(70, 140, 90), Enum.Material.SmoothPlastic)
		BuildKit.slot(m, c + Vector3.new(8, 0, -6), "Turret")
		BuildKit.slot(m, c + Vector3.new(0, 0, 8), "Trap")
	end

	-- глухие дома: два высоких и четыре малых (повторяющиеся блоки)
	BuildKit.block(root, Vector3.new(62, 0, -58), 30, 30, 26, Color3.fromRGB(120, 70, 60))
	BuildKit.block(root, Vector3.new(62, 0, 66), 26, 26, 22, Color3.fromRGB(95, 100, 115))
	for _, spot in { Vector3.new(30, 0, -62), Vector3.new(-24, 0, -72), Vector3.new(28, 0, 78), Vector3.new(-24, 0, 76) } do
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
		zombieSpawns = {
			Vector3.new(0, 3, HALF + 8),
			Vector3.new(0, 3, -HALF - 8),
			Vector3.new(HALF + 8, 3, 0),
			Vector3.new(-HALF - 8, 3, 0),
		},
		playerSpawn = Vector3.new(0, 3, 0),
		wallBuys = wallBuys,
	}
end

return City
