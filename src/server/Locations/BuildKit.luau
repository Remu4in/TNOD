--!strict
-- Общий набор для сборки локаций кодом: здания с проёмами-баррикадами, центральный магазин, реквизит.
-- Все локации собираются из одних и тех же кубиков, поэтому размеры и стиль единообразны.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local AssetService = game:GetService("AssetService")

local BuildKit = {}

export type Side = "N" | "E" | "S" | "W"
export type Opening = { side: Side, offset: number?, width: number? } -- offset — вдоль стены от её центра
export type Style = {
	point: string, -- имя точки обороны ("shop" — центральный магазин)
	weight: number?, -- шанс, что зомби выберут эти входы (по умолчанию 1)
	wallColor: Color3?,
	floorColor: Color3?,
	floorMaterial: Enum.Material?,
	wallMaterial: Enum.Material?, -- по умолчанию гладкий пластик (шатёр — ткань)
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
local function wallSide(parent: Instance, center: Vector3, sx: number, sz: number, side: Side, openings: { Opening }, color: Color3, material: Enum.Material?)
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
		BuildKit.part({
			Name = "Wall",
			Size = size,
			Position = wallCenter + along + Vector3.new(0, (y0 + y1) / 2, 0),
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
		}, parent)
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
		wallSide(model, center, sx, sz, side, openings, wallColor, style.wallMaterial)
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
	}, {
		point = "shop",
		weight = 0.15,
		roof = false,
		wallColor = Color3.fromRGB(176, 160, 112),
		wallMaterial = Enum.Material.Fabric,
		floorColor = Color3.fromRGB(88, 84, 76),
		floorMaterial = Enum.Material.Concrete,
	})

	-- Шатёр, раскинутый на перекрёстке: двускатная брезентовая крыша, мачты по углам и коньковая балка
	local ridgeY, eaveY = WALL_H + 6, WALL_H + 0.3
	local slope = math.atan2(ridgeY - eaveY, hz)
	local slopeLen = math.sqrt(hz * hz + (ridgeY - eaveY) ^ 2)
	for _, s in { 1, -1 } do
		local center = Vector3.new(0, (ridgeY + eaveY) / 2, s * hz / 2)
		BuildKit.part({
			Name = "TentRoof",
			Size = Vector3.new(hx * 2 + 4, 0.4, slopeLen + 2),
			CFrame = CFrame.new(center) * CFrame.Angles(s * slope, 0, 0),
			Color = Color3.fromRGB(150, 138, 96),
			Material = Enum.Material.Fabric,
		}, model)
	end
	BuildKit.part({ Name = "Ridge", Size = Vector3.new(hx * 2 + 6, 0.8, 0.8), Position = Vector3.new(0, ridgeY + 0.2, 0), Color = Color3.fromRGB(70, 55, 40), Material = Enum.Material.Wood }, model)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			BuildKit.part({ Name = "Pole", Size = Vector3.new(0.8, WALL_H + 1, 0.8), Position = Vector3.new(sx * (hx + 0.5), (WALL_H + 1) / 2, sz * (hz + 0.5)), Color = Color3.fromRGB(70, 55, 40), Material = Enum.Material.Wood }, model)
		end
		BuildKit.part({ Name = "MastPole", Size = Vector3.new(0.9, ridgeY + 1, 0.9), Position = Vector3.new(sx * hx, (ridgeY + 1) / 2, 0), Color = Color3.fromRGB(70, 55, 40), Material = Enum.Material.Wood }, model)
	end
	-- мешки с песком у входов
	for _, p in { Vector3.new(-6, 0, hz + 2.5), Vector3.new(6, 0, hz + 2.5), Vector3.new(-6, 0, -hz - 2.5), Vector3.new(6, 0, -hz - 2.5), Vector3.new(hx + 2.5, 0, -6), Vector3.new(hx + 2.5, 0, 6), Vector3.new(-hx - 2.5, 0, -6), Vector3.new(-hx - 2.5, 0, 6) } do
		BuildKit.box(model, "Sandbags", Vector3.new(3, 1.6, 2), p, Color3.fromRGB(150, 135, 100), Enum.Material.Fabric)
	end

	-- ящики и бочки у углов шатра
	for i, corner in { Vector3.new(hx + 3, 0, hz + 3), Vector3.new(-hx - 3, 0, hz + 3), Vector3.new(hx + 3, 0, -hz - 3), Vector3.new(-hx - 3, 0, -hz - 3) } do
		local def = Config.Props[if i % 2 == 0 then "barrel" else "crates"]
		BuildKit.meshProp(model, def.id, def, CFrame.new(corner) * CFrame.Angles(0, math.rad(i * 70), 0))
	end

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

-- Сгенерированные меши (Studio generate_mesh): шаблоны грузятся один раз, дальше — клоны с нужным размером.
-- Если меш не загрузился, вызывающий код рисует запасной вариант из блоков.
local meshTemplates: { [string]: MeshPart } = {}
local meshState: { [string]: string } = {} -- "loading" | "ok" | "failed"

local function loadMesh(meshId: string): MeshPart?
	if not meshState[meshId] then
		meshState[meshId] = "loading"
		local ok, result = pcall(function()
			-- коллизия «коробкой»: дёшево для навигации и укрытий
			return AssetService:CreateMeshPartAsync(Content.fromUri(meshId), { CollisionFidelity = Enum.CollisionFidelity.Box })
		end)
		if ok then
			meshTemplates[meshId] = result
			meshState[meshId] = "ok"
		else
			warn("[BuildKit] не удалось загрузить меш " .. meshId .. ": " .. tostring(result))
			meshState[meshId] = "failed"
		end
	end
	while meshState[meshId] == "loading" do
		task.wait(0.05)
	end
	return meshTemplates[meshId]
end

-- Предмет из меша: base — CFrame основания (стоит на земле); size — итоговый размер в студах.
function BuildKit.meshProp(parent: Instance, name: string, def: { mesh: string, texture: string, size: Vector3 }, base: CFrame, collide: boolean?): Part?
	local template = loadMesh(def.mesh)
	if not template then
		return nil
	end
	local p = template:Clone()
	p.Name = name
	p.Size = def.size
	p.TextureID = def.texture
	p.Anchored = true
	p.CanCollide = collide ~= false
	p.CanQuery = collide ~= false -- без коллизии предмет — чистая декорация: и рейкасты его не видят
	p.CFrame = base * CFrame.new(0, def.size.Y / 2, 0)
	p.Parent = parent
	return p
end

function BuildKit.car(parent: Instance, x: number, z: number, yawDeg: number, color: Color3)
	-- вариант модели по координате, чтобы на улице чередовались седан, такси и пикап
	local variants = Config.CarVisuals
	local models = Config.CarModels
	local pick = math.floor(math.abs(x * 7 + z * 13)) % (#variants + #models) + 1
	local base0 = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
	local modelDef = models[pick - #variants]
	if modelDef then
		local carModels = game:GetService("ServerStorage"):FindFirstChild("CarModels")
		local template = carModels and carModels:FindFirstChild(modelDef.id)
		if template and template:IsA("Model") and template.PrimaryPart then
			local car = template:Clone()
			car.Name = "Car"
			car:ScaleTo(modelDef.length / template.PrimaryPart.Size.Z)
			car:PivotTo(base0 * CFrame.new(0, car.PrimaryPart.Size.Y / 2, 0))
			car.Parent = parent
			return
		end
		warn("[BuildKit] нет шаблона машины " .. modelDef.id .. " в ServerStorage.CarModels")
	end
	local v = variants[(pick - 1) % #variants + 1]
	if BuildKit.meshProp(parent, "Car", v, CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)) then
		return
	end
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
	local def = Config.Props.dumpster
	-- поворот по координатам, чтобы контейнеры не стояли одинаково
	local yaw = ((math.floor(math.abs(x * 3 + z * 5)) % 4) * 90)
	if not BuildKit.meshProp(parent, "Dumpster", def, CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0)) then
		BuildKit.box(parent, "Dumpster", Vector3.new(6, 4, 3), Vector3.new(x, 0, z), Color3.fromRGB(50, 85, 60), Enum.Material.Metal)
	end
end

function BuildKit.lamppost(parent: Instance, x: number, z: number, withLight: boolean?)
	-- Фонарь из меша: сам меш без коллизии и рейкастов (у его «коробки» были бы широкие плечи), вместо этого —
	-- невидимый тонкий ствол для столкновений и невидимая точка света у фонаря.
	local def = Config.Props.lamp
	local yaw = (math.floor(math.abs(x * 5 + z * 3)) % 2) * 90
	if BuildKit.meshProp(parent, "Lamp", def, CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0), false) then
		BuildKit.part({ Name = "LampPole", Size = Vector3.new(0.9, def.size.Y, 0.9), Position = Vector3.new(x, def.size.Y / 2, z), Transparency = 1, CanQuery = false }, parent)
		if withLight ~= false then
			local light = BuildKit.part({ Name = "LampLight", Size = Vector3.one * 0.2, Position = Vector3.new(x, def.size.Y - 1.5, z), Transparency = 1, CanCollide = false, CanQuery = false }, parent)
			pointLight(light, 30, 1, Color3.fromRGB(255, 215, 160))
		end
		return
	end
	BuildKit.box(parent, "Pole", Vector3.new(0.7, 14, 0.7), Vector3.new(x, 0, z), Color3.fromRGB(40, 40, 45), Enum.Material.Metal)
	local head = BuildKit.part({
		Name = "LampHead",
		Size = Vector3.new(2, 0.5, 2),
		Position = Vector3.new(x, 14.3, z),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 225, 170),
		CanCollide = false,
	}, parent)
	if withLight ~= false then
		pointLight(head, 30, 1, Color3.fromRGB(255, 215, 160))
	end
end

-- Фасад небоскрёба: оконные ленты по этажам, колонны-рёбра и редкие светящиеся окна. Всё без коллизий —
-- настоящий объём даёт сплошной «корпус» башни. faces — какие грани одевать (по умолчанию все четыре).
local FLOOR_H = 4.2
local FACES = { Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0) }
function BuildKit.facade(parent: Instance, center: Vector3, sx: number, sz: number, y0: number, h: number, rng: Random, faces: { Vector3 }?)
	local floors = math.max(1, math.floor(h / FLOOR_H))
	local glass = Color3.fromRGB(28, 36, 48)
	local rib = Color3.fromRGB(70, 70, 72)
	for _, n in faces or FACES do
		local alongX = n.Z ~= 0
		local len = if alongX then sx else sz
		local half = if alongX then sz / 2 else sx / 2
		local origin = Vector3.new(center.X, 0, center.Z) + n * half
		local along = if alongX then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
		local function deco(name: string, size: Vector3, pos: Vector3, color: Color3, material: Enum.Material)
			BuildKit.part({ Name = name, Size = size, Position = pos, Color = color, Material = material, CanCollide = false, CanQuery = false, CanTouch = false }, parent)
		end
		for f = 1, floors do
			local y = y0 + (f - 0.5) * FLOOR_H
			local size = if alongX then Vector3.new(len - 2, 2.2, 0.3) else Vector3.new(0.3, 2.2, len - 2)
			deco("Windows", size, origin + n * 0.15 + Vector3.new(0, y, 0), glass, Enum.Material.Glass)
		end
		local ribs = math.max(1, math.floor(len / 8))
		for i = 0, ribs do
			local t = -len / 2 + 0.7 + (len - 1.4) * i / ribs
			local size = if alongX then Vector3.new(1.4, floors * FLOOR_H, 0.9) else Vector3.new(0.9, floors * FLOOR_H, 1.4)
			deco("Rib", size, origin + along * t + n * 0.3 + Vector3.new(0, y0 + floors * FLOOR_H / 2, 0), rib, Enum.Material.Concrete)
		end
		for _ = 1, math.max(2, math.floor(floors / 2)) do
			local f = rng:NextInteger(1, floors)
			local t = rng:NextNumber(-len / 2 + 4, len / 2 - 4)
			local size = if alongX then Vector3.new(3.4, 1.8, 0.2) else Vector3.new(0.2, 1.8, 3.4)
			deco("Lit", size, origin + along * t + n * 0.3 + Vector3.new(0, y0 + (f - 0.5) * FLOOR_H, 0), Color3.fromRGB(255, 214, 140), Enum.Material.Neon)
		end
	end
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
