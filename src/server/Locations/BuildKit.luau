--!strict
-- Общий набор для сборки локаций кодом: здания с проёмами-баррикадами, центральный магазин, реквизит.
-- Все локации собираются из одних и тех же кубиков, поэтому размеры и стиль единообразны.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))

local BuildKit = {}

export type Side = "N" | "E" | "S" | "W"
export type Opening = { side: Side, offset: number?, width: number? } -- offset — вдоль стены от её центра
export type Style = {
	point: string, -- имя точки обороны ("shop" — центральный магазин)
	weight: number?, -- шанс, что зомби выберут эти входы (по умолчанию 1)
	wallColor: Color3?,
	floorColor: Color3?,
	floorMaterial: Enum.Material?,
	roof: boolean?,
}

local WALL_H, WALL_T, OPEN_H = 12, 1, 8
local SIDES: { Side } = { "N", "E", "S", "W" }
local NORMAL: { [Side]: Vector3 } = {
	N = Vector3.new(0, 0, -1),
	S = Vector3.new(0, 0, 1),
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
}
local nextId = 1

-- Вызывать в начале сборки локации: нумерация входов начинается с 1.
function BuildKit.reset()
	nextId = 1
end

function BuildKit.part(props: { [string]: any }, parent: Instance): Part
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

local function pointLight(parent: Instance, range: number, brightness: number, color: Color3)
	local light = Instance.new("PointLight")
	light.Range = range
	light.Brightness = brightness
	light.Color = color
	light.Parent = parent
end

-- Вход с баррикадой: доски, подсказка починки, точки снаружи/внутри для зомби.
local function entrance(parent: Instance, id: number, point: string, weight: number, wallPos: Vector3, normal: Vector3, width: number): Types.Window
	local model = Instance.new("Model")
	model.Name = "Window" .. id
	model.Parent = parent

	local alongX = normal.Z ~= 0
	local planks: { BasePart } = {}
	local n = Config.Barricade.Planks
	for i = 1, n do
		local y = 0.6 + (OPEN_H - 1.2) * (i - 0.5) / n
		local size = if alongX then Vector3.new(width + 1, 0.8, 0.4) else Vector3.new(0.4, 0.8, width + 1)
		local tilt = math.rad((i % 2) * 6 - 3)
		local plank = BuildKit.part({
			Name = "Plank" .. i,
			Size = size,
			CFrame = CFrame.new(wallPos + Vector3.new(0, y, 0)) * (if alongX then CFrame.Angles(0, 0, tilt) else CFrame.Angles(tilt, 0, 0)),
			Color = Color3.fromRGB(120, 85, 50),
			Material = Enum.Material.Wood,
		}, model)
		table.insert(planks, plank)
	end

	local function at(offset: number): Vector3
		return wallPos + normal * offset + Vector3.new(0, 3, 0)
	end

	-- Невидимая опора для подсказки починки (внутри)
	local anchor = BuildKit.part({
		Name = "RepairAnchor",
		Size = Vector3.one,
		Position = at(-2.5),
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

	-- «Разобрать» — игрок сам снимает баррикаду, чтобы выйти из укрытия (клавиша F, на геймпаде Y)
	local dismantle = Instance.new("ProximityPrompt")
	dismantle.ActionText = "Разобрать"
	dismantle.ObjectText = "Баррикада"
	dismantle.KeyboardKeyCode = Enum.KeyCode.F
	dismantle.GamepadKeyCode = Enum.KeyCode.ButtonY
	dismantle.HoldDuration = Config.Barricade.DismantleHoldTime
	dismantle.MaxActivationDistance = 8
	dismantle.RequiresLineOfSight = false
	dismantle.UIOffset = Vector2.new(0, 70)
	dismantle.Enabled = false
	dismantle.Parent = anchor

	-- Стальной щит: закрывает проём, пока здание не открыто (невидим и проходим, пока вход рабочий)
	local shutter = BuildKit.part({
		Name = "Shutter",
		Size = if alongX then Vector3.new(width + 0.4, OPEN_H, 0.6) else Vector3.new(0.6, OPEN_H, width + 0.4),
		Position = wallPos + Vector3.new(0, OPEN_H / 2, 0),
		Color = Color3.fromRGB(70, 75, 80),
		Material = Enum.Material.Metal,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	}, model)

	return {
		id = id,
		model = model,
		planks = planks,
		outside = at(5),
		inside = at(-5),
		shutter = shutter,
		prompt = prompt,
		dismantle = dismantle,
		point = point,
		weight = weight,
	}
end

-- Одна стена здания; на месте проёмов — перемычка выше OPEN_H.
local function wallSide(parent: Instance, center: Vector3, sx: number, sz: number, side: Side, openings: { Opening }, color: Color3)
	local n = NORMAL[side]
	local alongX = n.Z ~= 0
	local len = (if alongX then sx else sz) + WALL_T
	local wallCenter = center + Vector3.new(n.X * sx / 2, 0, n.Z * sz / 2)

	local list: { { c: number, w: number } } = {}
	for _, o in openings do
		if o.side == side then
			table.insert(list, { c = o.offset or 0, w = o.width or 8 })
		end
	end
	table.sort(list, function(a, b)
		return a.c < b.c
	end)

	local function seg(t0: number, t1: number, y0: number, y1: number)
		local l = t1 - t0
		if l <= 0.05 then
			return
		end
		local tc = (t0 + t1) / 2
		local size = if alongX then Vector3.new(l, y1 - y0, WALL_T) else Vector3.new(WALL_T, y1 - y0, l)
		local along = if alongX then Vector3.new(tc, 0, 0) else Vector3.new(0, 0, tc)
		BuildKit.part({ Name = "Wall", Size = size, Position = wallCenter + along + Vector3.new(0, (y0 + y1) / 2, 0), Color = color }, parent)
	end

	local cursor = -len / 2
	for _, o in list do
		seg(cursor, o.c - o.w / 2, 0, WALL_H)
		seg(o.c - o.w / 2, o.c + o.w / 2, OPEN_H, WALL_H)
		cursor = o.c + o.w / 2
	end
	seg(cursor, len / 2, 0, WALL_H)
end

-- Здание sx × sz (по X и Z) с центром на земле; проёмы закрыты баррикадами.
function BuildKit.building(parent: Instance, name: string, center: Vector3, sx: number, sz: number, openings: { Opening }, style: Style): (Model, { Types.Window })
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	BuildKit.part({
		Name = "Floor",
		Size = Vector3.new(sx, 0.2, sz),
		Position = center + Vector3.new(0, 0.1, 0),
		Color = style.floorColor or Color3.fromRGB(90, 70, 55),
		Material = style.floorMaterial or Enum.Material.WoodPlanks,
	}, model)

	local wallColor = style.wallColor or Color3.fromRGB(150, 140, 125)
	for _, side in SIDES do
		wallSide(model, center, sx, sz, side, openings, wallColor)
	end

	local windows: { Types.Window } = {}
	for _, o in openings do
		local n = NORMAL[o.side]
		local wallCenter = center + Vector3.new(n.X * sx / 2, 0, n.Z * sz / 2)
		local tangent = if n.Z ~= 0 then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
		local pos = wallCenter + tangent * (o.offset or 0)
		table.insert(windows, entrance(model, nextId, style.point, style.weight or 1, pos, n, o.width or 8))
		nextId += 1
	end

	if style.roof then
		BuildKit.part({
			Name = "Roof",
			Size = Vector3.new(sx + 1, 0.6, sz + 1),
			Position = center + Vector3.new(0, WALL_H + 0.3, 0),
			Color = Color3.fromRGB(60, 58, 58),
		}, model)
	end

	local lamp = BuildKit.part({
		Name = "Lamp",
		Size = Vector3.one,
		Position = center + Vector3.new(0, WALL_H - 1, 0),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 210, 150),
		CanCollide = false,
	}, model)
	pointLight(lamp, math.max(sx, sz) * 1.2, 1.5, Color3.fromRGB(255, 200, 140))

	return model, windows
end

local function buildWallBuy(parent: Instance, weaponId: string, pos: Vector3, facing: Vector3): ProximityPrompt
	local def = Config.Weapons[weaponId]
	local board = BuildKit.part({
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

-- Зона покупки: дом 40×30 в центре локации (одинаковый во всех локациях), 4 окна, стены с оружием.
function BuildKit.shop(parent: Instance): ({ Types.Window }, { { weaponId: string, prompt: ProximityPrompt } })
	local hx, hz = 20, 15
	local model, windows = BuildKit.building(parent, "Shop", Vector3.zero, hx * 2, hz * 2, {
		{ side = "S", width = 6 },
		{ side = "N", width = 6 },
		{ side = "E", width = 6 },
		{ side = "W", width = 6 },
	}, { point = "shop", weight = 0.15, roof = false })

	local wallBuys: { { weaponId: string, prompt: ProximityPrompt } } = {}
	local spots = {
		{ Vector3.new(-hx + 6, 5, hz - 0.8), Vector3.new(0, 0, -1) },
		{ Vector3.new(hx - 6, 5, -hz + 0.8), Vector3.new(0, 0, 1) },
		{ Vector3.new(hx - 0.8, 5, hz - 6), Vector3.new(-1, 0, 0) },
		{ Vector3.new(-hx + 0.8, 5, -hz + 6), Vector3.new(1, 0, 0) },
		{ Vector3.new(hx - 6, 5, hz - 0.8), Vector3.new(0, 0, -1) },
		{ Vector3.new(-hx + 6, 5, -hz + 0.8), Vector3.new(0, 0, 1) },
		{ Vector3.new(hx - 0.8, 5, -hz + 6), Vector3.new(-1, 0, 0) },
		{ Vector3.new(-hx + 0.8, 5, hz - 6), Vector3.new(1, 0, 0) },
	}
	for i, weaponId in Config.WallBuys do
		local spot = spots[i]
		if spot then
			table.insert(wallBuys, { weaponId = weaponId, prompt = buildWallBuy(model, weaponId, spot[1], spot[2]) })
		end
	end
	return windows, wallBuys
end

-- Реквизит ---------------------------------------------------------------

function BuildKit.box(parent: Instance, name: string, size: Vector3, pos: Vector3, color: Color3, material: Enum.Material?): Part
	-- pos — центр основания: куб стоит на земле
	return BuildKit.part({
		Name = name,
		Size = size,
		Position = pos + Vector3.new(0, size.Y / 2, 0),
		Color = color,
		Material = material or Enum.Material.SmoothPlastic,
	}, parent)
end

-- Сплошной «глухой» дом-декорация (в него не войти)
function BuildKit.block(parent: Instance, center: Vector3, sx: number, sz: number, h: number, color: Color3): Model
	local m = Instance.new("Model")
	m.Name = "Block"
	m.Parent = parent
	BuildKit.box(m, "Body", Vector3.new(sx, h, sz), center, color, Enum.Material.Brick)
	BuildKit.box(m, "Cap", Vector3.new(sx + 1, 1, sz + 1), center + Vector3.new(0, h, 0), Color3.fromRGB(45, 45, 48), Enum.Material.Concrete)
	return m
end

function BuildKit.car(parent: Instance, x: number, z: number, yawDeg: number, color: Color3)
	local m = Instance.new("Model")
	m.Name = "Car"
	m.Parent = parent
	local base = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
	local function piece(size: Vector3, off: Vector3, c: Color3, material: Enum.Material)
		BuildKit.part({ Name = "Part", Size = size, CFrame = base * CFrame.new(off), Color = c, Material = material }, m)
	end
	piece(Vector3.new(6, 2, 13), Vector3.new(0, 1.8, 0), color, Enum.Material.Metal)
	piece(Vector3.new(5.4, 1.6, 6.5), Vector3.new(0, 3.6, -0.5), Color3.fromRGB(40, 50, 60), Enum.Material.Glass)
	for _, wx in { -3, 3 } do
		for _, wz in { -4, 4 } do
			piece(Vector3.new(0.8, 2, 2), Vector3.new(wx, 1, wz), Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic)
		end
	end
end

function BuildKit.dumpster(parent: Instance, x: number, z: number)
	BuildKit.box(parent, "Dumpster", Vector3.new(6, 4, 3), Vector3.new(x, 0, z), Color3.fromRGB(50, 85, 60), Enum.Material.Metal)
end

function BuildKit.lamppost(parent: Instance, x: number, z: number)
	BuildKit.box(parent, "Pole", Vector3.new(0.7, 14, 0.7), Vector3.new(x, 0, z), Color3.fromRGB(40, 40, 45), Enum.Material.Metal)
	local head = BuildKit.part({
		Name = "LampHead",
		Size = Vector3.new(2, 0.5, 2),
		Position = Vector3.new(x, 14.3, z),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 225, 170),
		CanCollide = false,
	}, parent)
	pointLight(head, 30, 1, Color3.fromRGB(255, 215, 160))
end

-- Вывеска здания на столбе: название и прогресс «скидывания» монет + подсказка «Вложить».
-- facing — куда смотрит лицевая сторона (обычно к центру локации, откуда подходят игроки).
function BuildKit.sign(parent: Instance, text: string, pos: Vector3, facing: Vector3): (ProximityPrompt, TextLabel)
	BuildKit.box(parent, "SignPost", Vector3.new(0.5, 4.5, 0.5), pos, Color3.fromRGB(45, 45, 50), Enum.Material.Metal)
	local board = BuildKit.part({
		Name = "Sign",
		Size = Vector3.new(8, 3.6, 0.4),
		Color = Color3.fromRGB(30, 30, 34),
	}, parent)
	local center = pos + Vector3.new(0, 5.2, 0)
	board.CFrame = CFrame.lookAt(center, center + Vector3.new(facing.X, 0, facing.Z))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 220, 120)
	label.Text = text
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Вложить монеты"
	prompt.ObjectText = text
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = board
	return prompt, label
end

-- Место с действием внутри здания (стеллаж, прилавок): небольшой блок + подсказка.
function BuildKit.interact(parent: Instance, name: string, pos: Vector3, size: Vector3, color: Color3, actionText: string, objectText: string): ProximityPrompt
	local block = BuildKit.box(parent, name, size, pos, color, Enum.Material.Metal)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = block
	return prompt
end

-- Маркер под будущие турели/ловушки (невидимый, виден по атрибуту SlotType).
function BuildKit.slot(parent: Instance, pos: Vector3, kind: string)
	local p = BuildKit.part({
		Name = "BuildSlot",
		Size = Vector3.new(4, 0.2, 4),
		Position = pos + Vector3.new(0, 0.1, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	p:SetAttribute("SlotType", kind)
end

return BuildKit
