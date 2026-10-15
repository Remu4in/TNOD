--!strict
-- Серый прототип карты, собирается кодом: двор с оградой, дом с 4 окнами-баррикадами,
-- стены с оружием, точки спавна. Финальная карта заменит этот модуль после выбора стиля.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))

local MapBuilder = {}

local HOUSE_X, HOUSE_Z = 40, 30 -- размеры дома
local WALL_H, WALL_T = 12, 1
local OPEN_W, OPEN_H = 6, 8 -- проём окна
local YARD = 150 -- сторона двора (ограда)
local FENCE_H = 6
local GAP = 12 -- проход в ограде

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

-- Стена вдоль оси от a до b (в плоскости XZ) с проёмом шириной OPEN_W по центру.
-- axis = "X": стена вдоль X на z = fixed; axis = "Z": вдоль Z на x = fixed.
local function wallWithOpening(parent: Instance, axis: string, fixed: number, from: number, to: number)
	local color = Color3.fromRGB(150, 140, 125)
	local function seg(a: number, b: number, y0: number, y1: number)
		local len = b - a
		if len <= 0 then
			return
		end
		local mid = (a + b) / 2
		local cy = (y0 + y1) / 2
		local size, pos
		if axis == "X" then
			size = Vector3.new(len, y1 - y0, WALL_T)
			pos = Vector3.new(mid, cy, fixed)
		else
			size = Vector3.new(WALL_T, y1 - y0, len)
			pos = Vector3.new(fixed, cy, mid)
		end
		part({ Name = "Wall", Size = size, Position = pos, Color = color }, parent)
	end
	local half = OPEN_W / 2
	seg(from, -half, 0, WALL_H)
	seg(half, to, 0, WALL_H)
	seg(-half, half, OPEN_H, WALL_H)
end

local function buildWindow(parent: Instance, id: number, axis: string, fixed: number, outwardSign: number): Types.Window
	local model = Instance.new("Model")
	model.Name = "Window" .. id
	model.Parent = parent

	local planks: { BasePart } = {}
	local n = Config.Barricade.Planks
	for i = 1, n do
		local y = 0.6 + (OPEN_H - 1.2) * (i - 0.5) / n
		local size = if axis == "X" then Vector3.new(OPEN_W + 1, 0.8, 0.4) else Vector3.new(0.4, 0.8, OPEN_W + 1)
		local pos = if axis == "X" then Vector3.new(0, y, fixed) else Vector3.new(fixed, y, 0)
		local plank = part({
			Name = "Plank" .. i,
			Size = size,
			Position = pos,
			Color = Color3.fromRGB(120, 85, 50),
			Material = Enum.Material.Wood,
		}, model)
		-- лёгкий наклон досок для читаемости
		plank.CFrame = plank.CFrame * CFrame.Angles(if axis == "X" then 0 else math.rad((i % 2) * 6 - 3), 0, if axis == "X" then math.rad((i % 2) * 6 - 3) else 0)
		table.insert(planks, plank)
	end

	local function point(offset: number): Vector3
		if axis == "X" then
			return Vector3.new(0, 3, fixed + outwardSign * offset)
		end
		return Vector3.new(fixed + outwardSign * offset, 3, 0)
	end

	-- Невидимая опора для подсказки починки (внутри дома)
	local anchor = part({
		Name = "RepairAnchor",
		Size = Vector3.new(1, 1, 1),
		Position = point(-2.5),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	}, model)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Починить"
	prompt.ObjectText = "Баррикада"
	prompt.HoldDuration = Config.Barricade.RepairHoldTime
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = anchor

	return {
		id = id,
		model = model,
		planks = planks,
		outside = point(5),
		inside = point(-5),
		prompt = prompt,
	}
end

local function buildWallBuy(parent: Instance, weaponId: string, pos: Vector3, facing: Vector3): ProximityPrompt
	local def = Config.Weapons[weaponId]
	local board = part({
		Name = "WallBuy_" .. weaponId,
		Size = Vector3.new(4, 2.5, 0.3),
		Color = Color3.fromRGB(40, 35, 30),
	}, parent)
	board.CFrame = CFrame.lookAt(pos, pos + facing)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 220, 120)
	label.Text = string.format("%s\n%d", def.name, def.price)
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = string.format("Купить (%d)", def.price)
	prompt.ObjectText = def.name
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 7
	prompt.Parent = board
	return prompt
end

function MapBuilder.build(): Types.MapInfo
	local old = workspace:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Model")
	root.Name = "Map"

	-- земля
	part({
		Name = "Ground",
		Size = Vector3.new(YARD + 60, 2, YARD + 60),
		Position = Vector3.new(0, -1, 0),
		Color = Color3.fromRGB(55, 70, 45),
		Material = Enum.Material.Grass,
	}, root)
	-- пол дома
	part({
		Name = "Floor",
		Size = Vector3.new(HOUSE_X, 0.2, HOUSE_Z),
		Position = Vector3.new(0, 0.1, 0),
		Color = Color3.fromRGB(90, 70, 55),
		Material = Enum.Material.WoodPlanks,
	}, root)

	-- стены дома с окнами
	local hx, hz = HOUSE_X / 2, HOUSE_Z / 2
	wallWithOpening(root, "X", hz, -hx, hx)
	wallWithOpening(root, "X", -hz, -hx, hx)
	wallWithOpening(root, "Z", hx, -hz, hz)
	wallWithOpening(root, "Z", -hx, -hz, hz)

	local windows: { Types.Window } = {
		buildWindow(root, 1, "X", hz, 1),
		buildWindow(root, 2, "X", -hz, -1),
		buildWindow(root, 3, "Z", hx, 1),
		buildWindow(root, 4, "Z", -hx, -1),
	}

	-- свет в доме
	local lamp = part({
		Name = "Lamp",
		Size = Vector3.new(1, 1, 1),
		Position = Vector3.new(0, WALL_H - 1, 0),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 210, 150),
		CanCollide = false,
	}, root)
	local light = Instance.new("PointLight")
	light.Range = 30
	light.Brightness = 1.5
	light.Color = Color3.fromRGB(255, 200, 140)
	light.Parent = lamp

	-- ограда двора с проходами посередине сторон (там спавнятся зомби)
	local fh = YARD / 2
	local fenceColor = Color3.fromRGB(70, 60, 50)
	local function fence(a: Vector3, b: Vector3)
		local mid = (a + b) / 2
		local len = (b - a).Magnitude
		local p = part({ Name = "Fence", Size = Vector3.new(len, FENCE_H, 1), Color = fenceColor, Material = Enum.Material.Wood }, root)
		p.CFrame = CFrame.lookAt(mid + Vector3.new(0, FENCE_H / 2, 0), b + Vector3.new(0, FENCE_H / 2, 0)) * CFrame.Angles(0, math.rad(90), 0)
	end
	local g = GAP / 2
	for _, s in { 1, -1 } do
		fence(Vector3.new(-fh, 0, s * fh), Vector3.new(-g, 0, s * fh))
		fence(Vector3.new(g, 0, s * fh), Vector3.new(fh, 0, s * fh))
		fence(Vector3.new(s * fh, 0, -fh), Vector3.new(s * fh, 0, -g))
		fence(Vector3.new(s * fh, 0, g), Vector3.new(s * fh, 0, fh))
	end
	local zombieSpawns = {
		Vector3.new(0, 3, fh + 8),
		Vector3.new(0, 3, -fh - 8),
		Vector3.new(fh + 8, 3, 0),
		Vector3.new(-fh - 8, 3, 0),
	}

	-- стены с оружием (внутри дома, у углов)
	local wallBuys = {}
	local spots = {
		{ Vector3.new(-hx + 6, 5, hz - 0.8), Vector3.new(0, 0, -1) },
		{ Vector3.new(hx - 6, 5, -hz + 0.8), Vector3.new(0, 0, 1) },
		{ Vector3.new(hx - 0.8, 5, hz - 6), Vector3.new(-1, 0, 0) },
		{ Vector3.new(-hx + 0.8, 5, -hz + 6), Vector3.new(1, 0, 0) },
	}
	for i, weaponId in Config.WallBuys do
		local spot = spots[i]
		if spot then
			table.insert(wallBuys, { weaponId = weaponId, prompt = buildWallBuy(root, weaponId, spot[1], spot[2]) })
		end
	end

	root.Parent = workspace

	return {
		root = root,
		windows = windows,
		zombieSpawns = zombieSpawns,
		playerSpawn = Vector3.new(0, 3, 0),
		wallBuys = wallBuys,
	}
end

return MapBuilder
