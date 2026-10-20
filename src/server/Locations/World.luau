--!strict
-- «Большой мир» v2: неправильная сетка улиц (разная ширина и шаг), в каждом квартале — шаблон (ряды зданий лицом к улицам,
-- одно большое здание, площадь, «крест» из четырёх), по периметру — пояс неигровых зданий и горы в ~15 студах за ним,
-- два шоссе с тоннелями, военная база к югу, вход в бункер в скале за базой. Все модели — чистые копии из
-- ServerStorage.Assets (скрипты вычищены «печью» tools/Baker.luau; см. docs/asset_plan.md). Локация для осмотра
-- (Config.Explore): зомби, раундов и баррикад в ней нет; рядом со спавном — машины и телепорт-площадки.

local ServerStorage = game:GetService("ServerStorage")
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local BuildKit = require(script.Parent:WaitForChild("BuildKit"))

local World = {}

local V3 = Vector3.new
local PI = math.pi

-- улицы: {координата оси, ширина}; кварталы — между соседними улицами
local VX: { { number } } = { { -330, 22 }, { -170, 26 }, { 0, 34 }, { 165, 24 }, { 330, 22 } }
local HZ: { { number } } = { { -300, 22 }, { -150, 26 }, { 0, 34 }, { 140, 24 }, { 290, 22 } }
local WALK = 6 -- тротуар между проезжей частью и зданиями
local BELT = 46 -- глубина пояса неигровых зданий снаружи крайних улиц
local MOUNT_GAP = 15 -- горы начинаются в ~15 студах за поясом

local XMIN, XMAX = VX[1][1] - VX[1][2] / 2, VX[#VX][1] + VX[#VX][2] / 2
local ZMIN, ZMAX = HZ[1][1] - HZ[1][2] / 2, HZ[#HZ][1] + HZ[#HZ][2] / 2
local BASE_Z = ZMAX + 260 -- центр военной базы
local BUNKER_Z = BASE_Z + 440 -- вход в бункер
local WALL_X = XMAX + WALK + BELT -- линия невидимых стен за поясом
local WALL_N = ZMIN - WALK - BELT
local WALL_S = ZMAX + WALK + BELT
local BASE_WALL_X = WALL_X -- долина базы той же ширины, что город

-- какой стороной смотрит модель «из коробки» (единичный вектор в осях мира после запекания); по умолчанию +Z
local FRONT: { [string]: Vector3 } = {
	Cafe = V3(1, 0, 0), Shelter = V3(1, 0, 0), GunShop = V3(-1, 0, 0), ColdStore = V3(0, 0, -1), Garage = V3(0, 0, -1),
	BunkerEntrance = V3(-1, 0, 0),
}

local function yawFor(front: Vector3, want: Vector3): number
	for k = 0, 3 do
		local th = k * PI / 2
		local c, s = math.round(math.cos(th)), math.round(math.sin(th))
		local rx, rz = front.X * c + front.Z * s, -front.X * s + front.Z * c
		if math.abs(rx - want.X) + math.abs(rz - want.Z) < 0.1 then
			return th
		end
	end
	return 0
end

-- «Всё открыто» (режим осмотра): двери и ворота проходимы, тонкие плоскости-створки тоже
local function openDoors(m: Model, thin: boolean)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			local cur: Instance? = d
			while cur and cur ~= m do
				local n = cur.Name:lower()
				if n:find("door") or n:find("gate") then
					d.CanCollide = false
					break
				end
				cur = cur.Parent
			end
			if thin then
				-- створка бункера — тонкая высокая плоскость без имени
				local mn = math.min(d.Size.X, d.Size.Y, d.Size.Z)
				if mn < 0.5 and math.max(d.Size.X, d.Size.Y, d.Size.Z) >= 8 and d.Transparency < 0.95 then
					d.CanCollide = false
				end
			end
		end
	end
end

-- Проём у функциональных зданий (режим осмотра): створки-двери (узкие высокие стёкла/двери) на фасаде проходимы, а у центра
-- фасада убираем низкие прилавки и подоконники (до 5 студов) шириной 8, чтобы в здание можно было зайти.
-- Витрины и окна остаются твёрдыми. Вызывать, когда модель уже в Workspace
local function cutDoorway(m: Model, face: Vector3)
	-- габариты по осям мира (GetExtentsSize у повёрнутой модели даёт размеры в её собственных осях)
	local mn, mx = V3(math.huge, math.huge, math.huge), V3(-math.huge, -math.huge, -math.huge)
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			local pcf, hs = p.CFrame, p.Size / 2
			for ix = -1, 1, 2 do
				for iy = -1, 1, 2 do
					for iz = -1, 1, 2 do
						local w = pcf:PointToWorldSpace(V3(hs.X * ix, hs.Y * iy, hs.Z * iz))
						mn = V3(math.min(mn.X, w.X), math.min(mn.Y, w.Y), math.min(mn.Z, w.Z))
						mx = V3(math.max(mx.X, w.X), math.max(mx.Y, w.Y), math.max(mx.Z, w.Z))
					end
				end
			end
		end
	end
	local ext = mx - mn
	local center = (mn + mx) / 2
	local depth = if face.X ~= 0 then ext.X else ext.Z
	local width = if face.X ~= 0 then ext.Z else ext.X
	local c = center + face * (depth / 2 - 2.5)
	local size = if face.X ~= 0 then V3(7, 9, width) else V3(width, 9, 7)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { m }
	local ground = mn.Y + (m:GetAttribute("GroundY") or 0) * m:GetScale()
	for _, p in workspace:GetPartBoundsInBox(CFrame.new(c.X, ground + 5, c.Z), size, params) do
		if p.CanCollide then
			-- габариты детали по осям мира
			local pcf, hs = p.CFrame, p.Size / 2
			local lo, hi = V3(math.huge, math.huge, math.huge), V3(-math.huge, -math.huge, -math.huge)
			for ix = -1, 1, 2 do
				for iy = -1, 1, 2 do
					for iz = -1, 1, 2 do
						local w = pcf:PointToWorldSpace(V3(hs.X * ix, hs.Y * iy, hs.Z * iz))
						lo = V3(math.min(lo.X, w.X), math.min(lo.Y, w.Y), math.min(lo.Z, w.Z))
						hi = V3(math.max(hi.X, w.X), math.max(hi.Y, w.Y), math.max(hi.Z, w.Z))
					end
				end
			end
			local e = hi - lo
			local isDoorName = p.Name:lower():find("door") ~= nil or (p.Parent ~= nil and p.Parent.Name:lower():find("door") ~= nil)
			local thinAxis = math.min(e.X, e.Z)
			local doorLeaf = (p.Material == Enum.Material.Glass or p.Transparency > 0.3) and e.Y >= 6.5 and thinAxis <= 1.5 and math.max(e.X, e.Z) <= 6.5
			-- низкий прилавок/подоконник в центре фасада
			local latCentre = if face.X ~= 0 then (lo.Z + hi.Z) / 2 - center.Z else (lo.X + hi.X) / 2 - center.X
			local low = hi.Y - ground > 1.0 and hi.Y - ground < 5.4 and math.abs(latCentre) <= 4.5
			if isDoorName or doorLeaf or low then
				p.CanCollide = false
			end
		end
	end
end

type Opts = { face: Vector3?, yaw: number?, scale: number?, fit: number?, y: number?, noOpen: boolean?, open: boolean?, thinDoors: boolean? }

-- Положить модель из библиотеки: основание — на уровень земли (GroundY модели учтён), перед — к `face`
local function place(assets: Instance, parent: Instance, folder: string, name: string, pos: Vector3, o: Opts?): (Model?, number)
	local f = assets:FindFirstChild(folder)
	local src = f and f:FindFirstChild(name)
	if not src then
		warn("[World] нет ассета " .. folder .. "/" .. name)
		return nil, 0
	end
	local opts: Opts = o or {}
	local m = src:Clone() :: Model
	local scale = opts.scale or 1
	if opts.fit then
		scale = math.min(scale, opts.fit / math.max(src:GetAttribute("SizeX") :: number, src:GetAttribute("SizeZ") :: number))
	end
	if scale ~= 1 then
		m:ScaleTo(scale)
	end
	local yaw = opts.yaw or 0
	if opts.face then
		yaw = yawFor(FRONT[name] or V3(0, 0, 1), opts.face)
	end
	local ground = ((src:GetAttribute("GroundY") :: number?) or 0) * scale
	m:PivotTo(CFrame.new(pos + V3(0, (opts.y or 0) - ground, 0)) * CFrame.Angles(0, yaw, 0))
	-- двери и ворота открываем только у функциональных зданий (открыть: open = true); у остальных стекло и двери остаются твёрдыми
	if opts.open then
		openDoors(m, opts.thinDoors == true)
	end
	m.Parent = parent
	return m, yaw
end

-- габариты модели после поворота на yaw (кратен 90°)
local function dims(src: Instance, yaw: number, scale: number): (number, number)
	local sx, sz = (src:GetAttribute("SizeX") :: number) * scale, (src:GetAttribute("SizeZ") :: number) * scale
	if math.abs(math.round(yaw / (PI / 2))) % 2 == 1 then
		return sz, sx
	end
	return sx, sz
end

-- пул зданий для рядов: {имя, максимум штук (тяжёлые — реже)}
local POOL: { { any } } = {
	{ "Hardware", 3 }, { "Pizza", 3 }, { "Diner", 3 }, { "DinerBunk", 3 }, { "Motel", 3 }, { "Cafe2", 3 }, { "NycBrick1", 4 }, { "NycBrick2", 4 },
	{ "PreWar", 5 }, { "Destroyed", 5 }, { "LowPoly", 4 }, { "GasStation2", 2 }, { "GasStation1", 2 }, { "ShopApt", 4 },
	{ "Burning", 1 }, { "Apt1406", 5 }, { "Tower108", 3 }, { "Tower174", 2 }, { "CornerApt", 2 }, { "Block51", 3 }, { "Block52", 4 },
	{ "Block97", 3 }, { "Block85", 3 }, { "Wide142", 2 }, { "Warehouse", 2 }, { "Factory", 2 },
}
-- для пояса по периметру (неигровые, лучше высокие и сплошные)
-- облегчённые (мало деталей) и высокие: пояс длинный, на нём можно повторяться
local BELT_POOL: { string } = { "Tower108", "Tower174", "Destroyed", "Block51", "Warehouse", "Factory", "Wide142", "Block85", "ShopApt", "Pizza", "Cafe2", "Hardware", "Block52" }

function World.build(): Types.MapInfo
	BuildKit.reset()
	local assets = ServerStorage:WaitForChild("Assets")
	local baseplate = workspace:FindFirstChild("Baseplate") -- шаблонная плита студии не нужна: у мира своя земля
	if baseplate then
		baseplate:Destroy()
	end
	local root = Instance.new("Model")
	root.Name = "Map"
	local P = BuildKit.part
	local rng = Random.new(23)
	local used: { [string]: number } = {}
	local function put(folder: string, name: string, pos: Vector3, o: Opts?): Model?
		local m = place(assets, root, folder, name, pos, o)
		return m
	end

	-- земля (плитки: одна деталь не больше 2048 студов) и пятно города ----------------------------------------
	for _, gx in { -1800, 0, 1800 } do
		for _, gz in { -1000, 800, 2600 } do
			P({ Name = "Ground", Size = V3(1800, 4, 1800), Position = V3(gx, -1.92, gz), Color = Color3.fromRGB(86, 96, 70), Material = Enum.Material.Grass }, root)
		end
	end
	P({ Name = "CityGround", Size = V3(XMAX - XMIN + 2 * (WALK + BELT), 2, ZMAX - ZMIN + 2 * (WALK + BELT)), Position = V3(0, -0.9, (ZMAX + ZMIN) / 2), Color = Color3.fromRGB(80, 81, 78), Material = Enum.Material.Pavement }, root)

	-- улицы, разметка, тротуары ---------------------------------------------------------------------------------
	local ASPHALT = Color3.fromRGB(46, 48, 52)
	local function road(cx: number, cz: number, sx: number, sz: number)
		P({ Name = "Road", Size = V3(sx, 0.2, sz), Position = V3(cx, 0.1, cz), Color = ASPHALT, Material = Enum.Material.Asphalt, CanCollide = false, CanQuery = false }, root)
	end
	local function paint(cx: number, cz: number, sx: number, sz: number)
		P({ Name = "Paint", Size = V3(sx, 0.04, sz), Position = V3(cx, 0.24, cz), Color = Color3.fromRGB(215, 185, 60), CanCollide = false, CanQuery = false }, root)
	end
	for _, v in VX do
		road(v[1], (ZMIN + ZMAX) / 2, v[2], ZMAX - ZMIN)
		for t = ZMIN + 10, ZMAX - 10, 22 do
			paint(v[1], t, 0.5, 7)
		end
	end
	for _, h in HZ do
		road((XMIN + XMAX) / 2, h[1], XMAX - XMIN, h[2])
		for t = XMIN + 10, XMAX - 10, 22 do
			paint(t, h[1], 7, 0.5)
		end
	end
	-- круговые перекрёстки (асфальтовый диск + остров)
	local function roundabout(cx: number, cz: number, r: number)
		local disk = P({ Name = "Roundabout", Size = V3(0.3, r * 2, r * 2), CFrame = CFrame.new(cx, 0.22, cz) * CFrame.Angles(0, 0, PI / 2), Color = ASPHALT, Material = Enum.Material.Asphalt, CanCollide = false, CanQuery = false }, root)
		disk.Shape = Enum.PartType.Cylinder
		local island = P({ Name = "Island", Size = V3(0.8, r * 0.9, r * 0.9), CFrame = CFrame.new(cx, 0.55, cz) * CFrame.Angles(0, 0, PI / 2), Color = Color3.fromRGB(96, 110, 78), Material = Enum.Material.Grass }, root)
		island.Shape = Enum.PartType.Cylinder
	end
	roundabout(0, 0, 30)
	roundabout(165, 140, 24)
	roundabout(-170, -150, 24)

	-- прямоугольники кварталов (без проезжей части и тротуаров)
	type Block = { x0: number, x1: number, z0: number, z1: number }
	local blocks: { { Block } } = {}
	for i = 1, #VX - 1 do
		blocks[i] = {}
		for j = 1, #HZ - 1 do
			local b: Block = {
				x0 = VX[i][1] + VX[i][2] / 2 + WALK, x1 = VX[i + 1][1] - VX[i + 1][2] / 2 - WALK,
				z0 = HZ[j][1] + HZ[j][2] / 2 + WALK, z1 = HZ[j + 1][1] - HZ[j + 1][2] / 2 - WALK,
			}
			blocks[i][j] = b
			P({ Name = "Sidewalk", Size = V3(b.x1 - b.x0 + 2 * WALK, 0.4, b.z1 - b.z0 + 2 * WALK), Position = V3((b.x0 + b.x1) / 2, 0.2, (b.z0 + b.z1) / 2), Color = Color3.fromRGB(150, 150, 144), Material = Enum.Material.Concrete }, root)
		end
	end

	-- ряд зданий вдоль кромки: axis "x" — ряд идёт по X, здания растут в сторону dir по Z (лицо — к улице) ---------
	local doorways: { { any } } = {}
	local function pickFrom(names: { string }, room: number, depth: number, minScale: number, ignoreLimit: boolean): (string?, number)
		-- случайный кандидат, влезающий по ширине и глубине (при необходимости — с масштабом ≥ minScale)
		local order = table.clone(names)
		for i = #order, 2, -1 do
			local k = rng:NextInteger(1, i)
			order[i], order[k] = order[k], order[i]
		end
		for _, n in order do
			local src = assets.Buildings:FindFirstChild(n)
			if src then
				local limit = 99
				for _, e in POOL do
					if e[1] == n then limit = e[2] :: number end
				end
				if ignoreLimit or (used[n] or 0) < limit then
					local sx, sz = src:GetAttribute("SizeX") :: number, src:GetAttribute("SizeZ") :: number
					-- глубина ряда — по меньшей стороне: большие блоки поворачиваем боком
					local w, d = sx, sz
					if d > depth * 1.15 and sx <= depth * 1.3 then w, d = sz, sx end
					local s = math.min(1, depth / d, room / w)
					if s >= minScale then
						return n, s
					end
				end
			end
		end
		return nil, 1
	end

	-- «must» — обязательные здания (с лицом к улице) идут первыми
	local function fillRow(axis: string, a0: number, a1: number, edge: number, dir: number, depth: number, must: { string }, names: { string }, gap: number, minScale: number, solid: boolean)
		local face = if axis == "x" then V3(0, 0, -dir) else V3(-dir, 0, 0)
		-- (вдоль ряда, вглубь): для рядов по Z оси меняются местами
		local function rowDims(src: Instance, yaw: number, scale: number): (number, number)
			local ax, az = dims(src, yaw, scale)
			if axis == "z" then
				return az, ax
			end
			return ax, az
		end
		local cursor = a0
		local queue = table.clone(must)
		local guard = 0
		while cursor < a1 - 6 and guard < 40 do
			guard += 1
			local name: string?, s: number = nil, 1
			if #queue > 0 then
				name = table.remove(queue, 1)
				local src = assets.Buildings:FindFirstChild(name :: string)
				if src then
					local yaw0 = yawFor(FRONT[name :: string] or V3(0, 0, 1), face)
					local w0, d0 = rowDims(src, yaw0, 1)
					s = math.min(1, depth / d0, (a1 - cursor) / w0)
				end
			else
				name, s = pickFrom(names, a1 - cursor, depth, minScale, solid)
			end
			if not name then
				cursor += 8 -- не нашлось подходящего: оставляем двор
			else
				local src = assets.Buildings[name]
				local yawFace = yawFor(FRONT[name] or V3(0, 0, 1), face)
				local yaw = yawFace
				local w, d = rowDims(src, yaw, s)
				-- большой блок не по лицу: поворачиваем боком, если так он ближе к глубине ряда
				if FRONT[name] == nil and d > depth * 1.15 then
					yaw = yawFace + PI / 2
					w, d = rowDims(src, yaw, s)
					s = math.min(s, depth / d, (a1 - cursor) / w)
					w, d = rowDims(src, yaw, s)
				end
				local center = cursor + w / 2
				local gy = if solid then 0.1 else 0.4 -- пояс стоит на общем покрытии, кварталы — на тротуаре (0,4)
				local pos = if axis == "x" then V3(center, gy, edge + dir * d / 2) else V3(edge + dir * d / 2, gy, center)
				local m = place(assets, root, "Buildings", name, pos, { yaw = yaw, scale = s, open = FRONT[name] ~= nil })
				used[name] = (used[name] or 0) + 1
				if m and not solid and FRONT[name] then
					table.insert(doorways, { m, face })
				end
				cursor += w + gap
			end
		end
		return cursor
	end

	-- шаблоны кварталов -------------------------------------------------------------------------------------------
	local function yardProps(b: Block, cx: number, cz: number, n: number)
		local carColors = { Color3.fromRGB(140, 140, 145), Color3.fromRGB(60, 80, 130), Color3.fromRGB(150, 150, 60), Color3.fromRGB(120, 50, 50), Color3.fromRGB(40, 40, 44) }
		for i = 1, n do
			local px = cx + rng:NextNumber(-(b.x1 - b.x0) / 2 + 8, (b.x1 - b.x0) / 2 - 8)
			local kind = rng:NextInteger(1, 4)
			if kind == 1 then
				BuildKit.car(root, px, cz + rng:NextNumber(-3, 3), if rng:NextNumber() < 0.5 then 90 else 270, carColors[rng:NextInteger(1, #carColors)])
			elseif kind == 2 then
				BuildKit.dumpster(root, px, cz)
			elseif kind == 3 then
				put("Base", "Crates", V3(px, 0.4, cz), { yaw = rng:NextNumber(0, PI * 2), noOpen = true })
			else
				put("Props", "Vending", V3(px, 0.4, cz), { yaw = if rng:NextNumber() < 0.5 then 0 else PI, noOpen = true })
			end
		end
	end

	-- must: { [ряд "N"/"S"] = { имена } }
	local function rowsBlock(b: Block, mustN: { string }, mustS: { string }, depthMax: number)
		local alley = 10
		local depth = math.min(depthMax, (b.z1 - b.z0 - alley) / 2)
		fillRow("x", b.x0, b.x1, b.z0, 1, depth, mustN, {}, 3, 0.62, false) -- северный ряд: растёт к +Z, лицо к -Z
		fillRow("x", b.x0, b.x1, b.z1, -1, depth, mustS, {}, 3, 0.62, false) -- южный ряд: растёт к -Z, лицо к +Z
		yardProps(b, (b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2, 3)
	end

	local function names(): { string }
		local t = {}
		for _, e in POOL do table.insert(t, e[1] :: string) end
		return t
	end
	local ALL = names()
	-- fillRow берёт пул из последнего аргумента: подменим пустой на общий пул
	local rawFill = fillRow
	fillRow = function(axis, a0, a1, edge, dir, depth, must, pool, gap, minScale, solid)
		return rawFill(axis, a0, a1, edge, dir, depth, must, if #pool == 0 then ALL else pool, gap, minScale, solid)
	end

	-- план: [i][j] — 1..4 запад→восток, 1..4 север→юг
	local B = blocks
	local function plaza(b: Block, withCrash: boolean)
		local cx, cz = (b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2
		if withCrash then
			put("Vehicles", "CrashFire", V3(cx, 0.4, cz), { yaw = 0.4, noOpen = true })
			put("Vehicles", "Sprinter", V3(cx - 26, 0.4, cz + 20), { yaw = 1.2, noOpen = true })
			put("Vehicles", "X6M", V3(cx + 24, 0.4, cz - 18), { yaw = 2.2, noOpen = true })
		end
		put("Props", "Billboard", V3(cx, 0.4, b.z0 + 24), { yaw = PI, scale = 0.8, noOpen = true })
		for k = -2, 2 do
			put("Base", "Sandbags", V3(cx + k * 22, 0.4, b.z1 - 6), { yaw = 0, scale = 0.45, noOpen = true })
		end
		put("Props", "Barricade", V3(cx - 40, 0.4, cz + 28), { yaw = 0.3, noOpen = true })
		put("Props", "Barricade", V3(cx + 38, 0.4, cz - 30), { yaw = -0.4, noOpen = true })
		yardProps(b, cx, cz + 34, 3)
	end
	local function bigBlock(b: Block, name: string, extra: { string })
		local cx, cz = (b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2
		local src = assets.Buildings[name]
		local s = math.min(1, (b.x1 - b.x0) / (src:GetAttribute("SizeX") :: number), (b.z1 - b.z0 - 30) / (src:GetAttribute("SizeZ") :: number))
		put("Buildings", name, V3(cx, 0.4, b.z0 + (src:GetAttribute("SizeZ") :: number) * s / 2), { scale = s, yaw = PI })
		-- остальное — ряд мелких зданий вдоль южной кромки
		fillRow("x", b.x0, b.x1, b.z1, -1, math.max(20, (b.z1 - b.z0) - (src:GetAttribute("SizeZ") :: number) * s - 12), extra, ALL, 3, 0.6, false)
		yardProps(b, cx, cz, 2)
	end
	local function crossBlock(b: Block, must: { string })
		local cx, cz = (b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2
		local hw, hd = (b.x1 - b.x0) / 2 - 4, (b.z1 - b.z0) / 2 - 4
		local q = 0
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				q += 1
				local nm = must[q]
				local x0, x1 = if sx < 0 then cx - hw - 4 else cx + 4, if sx < 0 then cx - 4 else cx + hw + 4
				local edge = if sz < 0 then cz - hd - 4 else cz + hd + 4
				fillRow("x", x0, x1, edge, -sz, hd, if nm then { nm } else {}, ALL, 2, 0.55, false)
			end
		end
	end

	-- кварталы запад→восток (i), север→юг (j)
	rowsBlock(B[1][1], {}, {}, 56)
	rowsBlock(B[2][1], { "Garage" }, {}, 56)
	bigBlock(B[3][1], "Factory", {})
	rowsBlock(B[4][1], {}, { "Shelter" }, 56)
	rowsBlock(B[1][2], { "ColdStore" }, {}, 56)
	plaza(B[2][2], false)
	rowsBlock(B[3][2], {}, { "Armory" }, 56)
	crossBlock(B[4][2], { "GunShop" })
	rowsBlock(B[1][3], {}, {}, 56)
	rowsBlock(B[2][3], {}, {}, 56)
	plaza(B[3][3], true)
	rowsBlock(B[4][3], {}, {}, 56)
	bigBlock(B[1][4], "Warehouse", {})
	rowsBlock(B[2][4], {}, { "Cafe" }, 56)
	rowsBlock(B[3][4], {}, { "Pharmacy" }, 56)
	crossBlock(B[4][4], {})

	-- пояс неигровых зданий снаружи крайних улиц: плотный ряд (зазоры ≤ 1.5), перекрыт проёмами под шоссе и дорогу к базе --
	local function beltSegment(axis: string, a0: number, a1: number, edge: number, dir: number)
		rawFill(axis, a0, a1, edge, dir, BELT, {}, BELT_POOL, 1.2, 0.5, true)
	end
	local GAP_N, GAP_E, GAP_S = 44, 44, 40 -- ширина проёма под шоссе и под дорогу на базу
	beltSegment("x", XMIN - WALK - BELT, -GAP_N, ZMIN - WALK, -1)
	beltSegment("x", GAP_N, XMAX + WALK + BELT, ZMIN - WALK, -1)
	beltSegment("x", XMIN - WALK - BELT, -GAP_S, ZMAX + WALK, 1)
	beltSegment("x", GAP_S, XMAX + WALK + BELT, ZMAX + WALK, 1)
	beltSegment("z", ZMIN - WALK, -GAP_E, XMIN - WALK, -1)
	beltSegment("z", GAP_E, ZMAX + WALK, XMIN - WALK, -1)
	beltSegment("z", ZMIN - WALK, -GAP_E, XMAX + WALK, 1)
	beltSegment("z", GAP_E, ZMAX + WALK, XMAX + WALK, 1)

	-- уличная мебель: машины и фонари по периметру кварталов
	local carColors = { Color3.fromRGB(140, 140, 145), Color3.fromRGB(60, 80, 130), Color3.fromRGB(150, 150, 60), Color3.fromRGB(120, 50, 50), Color3.fromRGB(40, 40, 44) }
	-- фонарь не ставим в проезжую часть перекрёстка (вдоль улицы на уровне другой улицы)
	local function inCross(list: { { number } }, coord: number): boolean
		for _, l in list do
			if math.abs(coord - l[1]) < l[2] / 2 + 4 then
				return true
			end
		end
		return false
	end
	for _, h in HZ do
		for t = XMIN + 40, XMAX - 40, 70 do
			if rng:NextNumber() < 0.55 and math.abs(t) > 30 then
				BuildKit.car(root, t + rng:NextNumber(-12, 12), h[1] + (if rng:NextNumber() < 0.5 then 1 else -1) * (h[2] / 2 - 5), 90, carColors[rng:NextInteger(1, #carColors)])
			end
			if not inCross(VX, t + 20) then
				BuildKit.lamppost(root, t + 20, h[1] + h[2] / 2 + 1.5)
			end
			if not inCross(VX, t - 20) then
				BuildKit.lamppost(root, t - 20, h[1] - h[2] / 2 - 1.5)
			end
		end
	end
	for _, v in VX do
		for t = ZMIN + 40, ZMAX - 40, 70 do
			if rng:NextNumber() < 0.55 and math.abs(t) > 30 then
				BuildKit.car(root, v[1] + (if rng:NextNumber() < 0.5 then 1 else -1) * (v[2] / 2 - 5), t + rng:NextNumber(-12, 12), 0, carColors[rng:NextInteger(1, #carColors)])
			end
			if not inCross(HZ, t + 20) then
				BuildKit.lamppost(root, v[1] + v[2] / 2 + 1.5, t + 20)
			end
			if not inCross(HZ, t - 20) then
				BuildKit.lamppost(root, v[1] - v[2] / 2 - 1.5, t - 20)
			end
		end
	end

	-- шоссе (север x = 0, восток z = 0) и тоннели в скале -------------------------------------------------------
	local function highway(alongZ: boolean)
		local TL, RK = 144, 40 -- длина тоннеля и толщина замыкающей скалы
		if alongZ then
			local zEnd = WALL_N - MOUNT_GAP - TL - RK
			road(0, (zEnd + ZMIN) / 2, 28, ZMIN - zEnd)
			P({ Name = "Shoulder", Size = V3(36, 0.1, ZMIN - zEnd), Position = V3(0, 0.05, (zEnd + ZMIN) / 2), Color = Color3.fromRGB(70, 66, 58), Material = Enum.Material.Ground, CanCollide = false, CanQuery = false }, root)
			local tc = WALL_N - MOUNT_GAP - TL / 2
			put("Highway", "Tunnel", V3(0, 0, tc), { yaw = 0, noOpen = true })
			for _, lat in { -1, 1 } do
				put("Mountains", "TerrainB", V3(lat * 100, -6, tc), { yaw = 0, scale = 3.6, noOpen = true })
			end
			put("Mountains", "TerrainB", V3(0, -6, zEnd - 30), { yaw = PI / 2, scale = 4.2, noOpen = true })
			for i = -1, 1 do
				put("Base", "Sandbags", V3(i * 38, 0.1, ZMIN - 22), { yaw = 0, scale = 0.5, noOpen = true })
			end
		else
			local xEnd = WALL_X + MOUNT_GAP + TL + RK
			road((XMAX + xEnd) / 2, 0, xEnd - XMAX, 28)
			P({ Name = "Shoulder", Size = V3(xEnd - XMAX, 0.1, 36), Position = V3((XMAX + xEnd) / 2, 0.05, 0), Color = Color3.fromRGB(70, 66, 58), Material = Enum.Material.Ground, CanCollide = false, CanQuery = false }, root)
			local tc = WALL_X + MOUNT_GAP + TL / 2
			put("Highway", "Tunnel", V3(tc, 0, 0), { yaw = PI / 2, noOpen = true })
			for _, lat in { -1, 1 } do
				put("Mountains", "TerrainB", V3(tc, -6, lat * 100), { yaw = PI / 2, scale = 3.6, noOpen = true })
			end
			put("Mountains", "TerrainB", V3(xEnd + 30, -6, 0), { yaw = 0, scale = 4.2, noOpen = true })
			for i = -1, 1 do
				put("Base", "Sandbags", V3(XMAX + 22, 0.1, i * 38), { yaw = PI / 2, scale = 0.5, noOpen = true })
			end
		end
	end
	highway(true)
	highway(false)

	-- ограждение и коридор к базе: барьеры вдоль дороги, чтобы не уйти на луг ----------------------------------------
	local corridorEnd = BASE_Z - 112
	for z = ZMAX + WALK + BELT - 10, corridorEnd, 62 do
		for _, sx in { -1, 1 } do
			put("Props", "Barricade", V3(sx * 56, 0.1, z), { yaw = 0, noOpen = true })
		end
	end
	road(0, (ZMAX + corridorEnd) / 2, 28, corridorEnd - ZMAX)

	-- горы по периметру долины: ОДИН ассет (MountainA); центры отодвинуты так, чтобы подошва начиналась в ~15 студах за поясом
	local MS = 4.3
	local half = 74 * MS / 2
	local ZS = BUNKER_Z + 200 -- южная граница долины (за бункером)
	local function mountain(x: number, z: number, yaw: number)
		put("Mountains", "MountainA", V3(x, -10, z), { yaw = yaw, scale = MS, noOpen = true })
	end
	for t2 = -WALL_X - 200, WALL_X + 200, 190 do
		if math.abs(t2) > 190 then mountain(t2, WALL_N - MOUNT_GAP - half, 0) end -- север; проём под шоссе закрывают скалы тоннеля
		if math.abs(t2) > 150 then mountain(t2, ZS + MOUNT_GAP + half, 0) end -- юг; посередине — скалы бункера
	end
	for t2 = WALL_N - 200, ZS + 200, 190 do
		mountain(-WALL_X - MOUNT_GAP - half, t2, PI / 2)
		if math.abs(t2) > 190 then mountain(WALL_X + MOUNT_GAP + half, t2, PI / 2) end -- восток; проём под шоссе
	end

	-- военная база к югу от города ------------------------------------------------------------------------------------
	put("Base", "BaseMain", V3(0, 0.1, BASE_Z), { open = true })
	P({ Name = "BasePad", Size = V3(214, 0.4, 236), Position = V3(0, 0.05, BASE_Z), Color = Color3.fromRGB(96, 92, 80), Material = Enum.Material.Ground, CanCollide = true, CanQuery = false }, root)
	put("Base", "Tent", V3(70, 0.5, BASE_Z - 10), { yaw = PI / 2 })
	put("Base", "Helipad", V3(-250, 0.1, BASE_Z + 10), {})
	local pool = { "HumveeArmored", "HumveeMedic", "Ambulance", "MilitaryBus", "Abrams", "APC", "TransportTruck", "MilitaryTank", "MiningDasa" }
	for i, name in pool do
		local col = (i - 1) % 3
		local row = math.floor((i - 1) / 3)
		put("Vehicles", name, V3(190 + col * 55, 0.1, BASE_Z - 80 + row * 60), { yaw = (if i % 2 == 0 then 0.1 else -0.1), noOpen = true })
	end
	for i = -2, 2 do
		put("Base", "WatchTower", V3(i * 45, 0, BASE_Z - 122), {})
	end
	-- забор и мешки по краям долины базы, ящики и форты у подъездов
	for k = -3, 3 do
		put("Base", "Fort", V3(-300 + k * 6, 0.1, BASE_Z + 120), { yaw = 0.4 * k, noOpen = true })
		put("Base", "Fort", V3(300 + k * 6, 0.1, BASE_Z + 120), { yaw = 0.4 * k, noOpen = true })
		put("Base", "Sandbags", V3(-300 + k * 30, 0.1, BASE_Z - 150), { yaw = 0, scale = 0.7, noOpen = true })
		put("Base", "Sandbags", V3(300 + k * 30, 0.1, BASE_Z - 150), { yaw = 0, scale = 0.7, noOpen = true })
	end
	for k = 0, 5 do
		put("Base", "Crates", V3(-290 + (k % 3) * 9, 0.1, BASE_Z - 90 + math.floor(k / 3) * 8), { yaw = k * 0.5, noOpen = true })
	end

	-- бункер в скале за базой ----------------------------------------------------------------------------------------
	road(0, BASE_Z + 112 + (BUNKER_Z - BASE_Z - 112) / 2, 28, BUNKER_Z - BASE_Z - 112)
	put("Bunker", "BunkerEntrance", V3(0, 0.1, BUNKER_Z), { face = V3(0, 0, -1), open = true, thinDoors = true })
	put("Bunker", "BunkerHall", V3(0, 0.1, BUNKER_Z + 34), {})
	for _, lat in { -1, 1 } do
		put("Mountains", "TerrainB", V3(lat * 110, -6, BUNKER_Z + 60), { yaw = 0, scale = 3.8, noOpen = true })
	end
	put("Mountains", "TerrainB", V3(0, -6, BUNKER_Z + 140), { yaw = PI / 2, scale = 4.6, noOpen = true })

	-- невидимые стены по границе долины (зазоры под шоссе: на север и на восток) -------------------------------------------
	local function wall(x0: number, x1: number, z0: number, z1: number)
		P({ Name = "Bound", Size = V3(math.max(4, x1 - x0), 300, math.max(4, z1 - z0)), Position = V3((x0 + x1) / 2, 150, (z0 + z1) / 2), Transparency = 1 }, root)
	end
	local ZS2 = BUNKER_Z + 200
	wall(-WALL_X - 4, -30, WALL_N - 4, WALL_N) -- север (две половины)
	wall(30, WALL_X + 4, WALL_N - 4, WALL_N)
	wall(-WALL_X - 4, -WALL_X, WALL_N, ZS2) -- запад
	wall(WALL_X, WALL_X + 4, WALL_N, -30) -- восток (две половины)
	wall(WALL_X, WALL_X + 4, 30, ZS2)
	wall(-WALL_X - 4, WALL_X + 4, ZS2, ZS2 + 4) -- юг

	-- точка появления, машины и телепорт-площадки -------------------------------------------------------------------------
	local spawnZ = BASE_Z - 150
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = V3(8, 1, 8)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.Position = V3(0, 0.6, spawnZ)
	spawn.Parent = root

	local tp: { { any } } = {
		{ "База (старт)", V3(0, 4, spawnZ) },
		{ "Центр города", V3(0, 4, 40) },
		{ "Кафе", V3(B[2][4].x0 + 30, 4, B[2][4].z1 + 20) },
		{ "Аптека", V3(B[3][4].x0 + 30, 4, B[3][4].z1 + 20) },
		{ "Оружейная", V3(B[3][2].x0 + 30, 4, B[3][2].z1 + 20) },
		{ "Холодное оружие", V3(B[1][2].x0 + 30, 4, B[1][2].z0 - 18) },
		{ "Гараж", V3(B[2][1].x0 + 30, 4, B[2][1].z0 - 18) },
		{ "Убежище", V3(B[4][1].x0 + 30, 4, B[4][1].z1 + 20) },
		{ "Военная база", V3(0, 4, BASE_Z) },
		{ "Шатёр", V3(70, 4, BASE_Z + 40) },
		{ "Вертолётка", V3(-250, 4, BASE_Z - 40) },
		{ "Вход в бункер", V3(0, 4, BUNKER_Z - 40) },
		{ "Северный тоннель", V3(0, 4, WALL_N - 40) },
		{ "Восточный тоннель", V3(WALL_X + 40, 4, 0) },
	}
	for i, e in tp do
		local col = (i - 1) % 7
		local row = math.floor((i - 1) / 7)
		local pad = P({ Name = "TeleportPad", Size = V3(5, 0.6, 5), Position = V3(-18 + col * 6, 0.3, spawnZ - 26 - row * 6), Color = Color3.fromRGB(60, 140, 220), Material = Enum.Material.Neon }, root)
		pad.CanCollide = false -- машины и персонажи проезжают поверх площадок
		local att = Instance.new("Attachment")
		att.Position = V3(0, 1.2, 0)
		att.Parent = pad
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Телепорт"
		prompt.ObjectText = e[1] :: string
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 6
		prompt.RequiresLineOfSight = false
		prompt.Parent = att
		local target = e[2] :: Vector3
		prompt.Triggered:Connect(function(player: Player)
			local ch = player.Character
			if ch then
				ch:PivotTo(CFrame.new(target + V3(0, 3, 0)))
			end
		end)
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(110, 26)
		bb.StudsOffset = V3(0, 3 + (col % 3) * 2.6, 0) -- подписи на разной высоте, чтобы не слипались
		bb.MaxDistance = 80
		bb.Parent = pad
		local tl = Instance.new("TextLabel")
		tl.Size = UDim2.fromScale(1, 1)
		tl.BackgroundTransparency = 0.3
		tl.BackgroundColor3 = Color3.new(0, 0, 0)
		tl.TextColor3 = Color3.new(1, 1, 1)
		tl.Font = Enum.Font.GothamBold
		tl.TextScaled = true
		tl.Text = e[1] :: string
		tl.Parent = bb
	end

	root.Parent = workspace
	for _, d in doorways do
		cutDoorway(d[1] :: Model, d[2] :: Vector3)
	end

	return {
		id = "World",
		name = "Большой мир",
		root = root,
		windows = {},
		buildings = {},
		shop = { center = V3(70, 0, BASE_Z), halfX = 0, halfZ = 0 },
		zombieSpawns = {},
		playerSpawn = V3(0, 4, spawnZ),
		nightSpawn = V3(0, 4, spawnZ),
		wallBuys = {},
		-- первые три — легковые (Coupe, Sedan, Prius), дальше военные: джип, джип с турелью, грузовик, автобус (имена — в init.server)
		carSpawns = {
			CFrame.new(-26, 0, spawnZ + 22), CFrame.new(0, 0, spawnZ + 22), CFrame.new(26, 0, spawnZ + 22),
			CFrame.new(-52, 0, spawnZ + 22), CFrame.new(52, 0, spawnZ + 22), CFrame.new(-82, 0, spawnZ + 22), CFrame.new(82, 0, spawnZ + 22),
		},
	}
end

return World
