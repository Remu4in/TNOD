--!strict
-- Наполнение метро (Workspace.Metro.Decor): коммуникации под потолком, плитка, указатели, лавки, мусор, лагеря выживших, кровь, лужи,
-- крепи и сигналы в тоннелях, станция B и двор. Запуск: Studio → Edit (execute_luau), после BuildMetro.luau; идемпотентно (Decor пересоздаётся).
-- Берёт готовые ассеты из ServerStorage.Assets.Metro (Bench, TicketMachine, SignBoard) и Assets.Props.Vending, остальное — детали.

local OY = 600
local V = Vector3.new
local rng = Random.new(42)
local ROOT = workspace:FindFirstChild("Metro")
assert(ROOT, "сначала tools/BuildMetro.luau")
local old = ROOT:FindFirstChild("Decor")
if old then
	old:Destroy()
end
local DECOR = Instance.new("Folder")
DECOR.Name = "Decor"
DECOR.Parent = ROOT
local function folder(name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = DECOR
	return f
end
local Utilities, Walls, Furniture, Debris, Camps, Stains, TunnelDecor, StationB, Fx = folder("Utilities"), folder("Walls"), folder("Furniture"), folder("Debris"), folder("Camps"), folder("Stains"), folder("TunnelDecor"), folder("StationB"), folder("Fx")

local lib = game.ServerStorage:WaitForChild("Assets"):WaitForChild("Metro")
local LINES = { -24, 0, 24 }
local STATION_HALF = 160
local TUNNEL = 480
local BX0, BX1 = STATION_HALF + TUNNEL, STATION_HALF + TUNNEL + 160

local function box(parent: Instance, name: string, size: Vector3, x: number, y: number, z: number, color: Color3, material: Enum.Material?, extra: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.new(x, OY + y, z)
	p.Color = color
	p.Material = material or Enum.Material.Concrete
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in extra do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function cylinder(parent: Instance, name: string, length: number, diameter: number, x: number, y: number, z: number, color: Color3, alongX: boolean?)
	local p = box(parent, name, V(length, diameter, diameter), x, y, z, color, Enum.Material.Metal, { Shape = Enum.PartType.Cylinder })
	if alongX == false then
		p.CFrame = CFrame.new(x, OY + y, z) * CFrame.Angles(0, 0, math.rad(90))
		p.Size = V(length, diameter, diameter)
	end
	return p
end

local function panel(parent: Instance, text: string, w: number, h: number, x: number, y: number, z: number, faceDir: number, bg: Color3, fg: Color3, tilt: number?)
	local p = box(parent, "Panel", V(w, h, 0.3), x, y, z, bg, Enum.Material.SmoothPlastic, { CanCollide = false })
	p.CFrame = CFrame.new(x, OY + y, z) * CFrame.Angles(0, if faceDir > 0 then math.rad(180) else 0, math.rad(tilt or 0))
	-- надписи не нужны (решение Руслана): панель остаётся пустым щитом, текст не рисуем
	if true then
		return p
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = p
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = fg
	label.Text = text
	label.Parent = gui
	return p
end

local function lamp(parent: Instance, x: number, y: number, z: number, color: Color3, brightness: number, range: number)
	local p = box(parent, "DecorLamp", V(1.2, 1.2, 1.2), x, y, z, Color3.fromRGB(255, 220, 160), Enum.Material.Neon, { CanCollide = false, Shape = Enum.PartType.Ball })
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Parent = p
end

-- вставить готовую модель из библиотеки: центр (x, z), низ на bottomY, длинная ось по X (или по Z)
local function aabb(m: Instance): (Vector3, Vector3)
	local minV, maxV = V(1e9, 1e9, 1e9), V(-1e9, -1e9, -1e9)
	local list = if m:IsA("BasePart") then { m } else m:GetDescendants()
	for _, d in list do
		if d:IsA("BasePart") then
			local cf, s = d.CFrame, d.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local p = cf:PointToWorldSpace(V(sx * s.X, sy * s.Y, sz * s.Z))
						minV = V(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z))
						maxV = V(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z))
					end
				end
			end
		end
	end
	return minV, maxV
end

local function put(src: Instance, parent: Instance, name: string, x: number, bottomY: number, z: number, yawDeg: number?): Instance
	local c = src:Clone()
	c.Name = name
	c.Parent = parent
	local a, b = aabb(c)
	local center = (a + b) / 2
	local rot = CFrame.new(center) * CFrame.Angles(0, math.rad(yawDeg or 0), 0) * CFrame.new(-center)
	if c:IsA("Model") then
		c:PivotTo(rot * c:GetPivot())
	else
		(c :: BasePart).CFrame = rot * (c :: BasePart).CFrame
	end
	a, b = aabb(c)
	center = (a + b) / 2
	local target = V(x, OY + bottomY + (b.Y - a.Y) / 2, z)
	if c:IsA("Model") then
		c:PivotTo(c:GetPivot() + (target - center))
	else
		(c :: BasePart).CFrame += target - center
	end
	return c
end

local GREY, DARK, RUST = Color3.fromRGB(110, 112, 116), Color3.fromRGB(48, 50, 54), Color3.fromRGB(92, 58, 44)
local LINE_COLORS = { Color3.fromRGB(200, 50, 50), Color3.fromRGB(50, 110, 200), Color3.fromRGB(50, 160, 90) }
local LINE_NAMES = { "ЛИНИЯ 1", "ЛИНИЯ 2", "ЛИНИЯ 3" }

------------------------------------------------------------------------------------------------ главная станция: стены и потолок
-- нижняя плитка и пояса на стенах (внутри станции)
for _, side in { { 37.7, 0 }, { -37.7, 180 } } do
	box(Walls, "TileBand", V(320, 3.2, 0.3), 0, 1.6, side[1], Color3.fromRGB(150, 150, 146), Enum.Material.Marble, { CanCollide = false })
	box(Walls, "TileTrim", V(320, 0.4, 0.4), 0, 3.4, side[1], RUST, Enum.Material.Metal, { CanCollide = false })
	box(Walls, "DirtBand", V(320, 5, 0.2), 0, 7.5, side[1], Color3.fromRGB(72, 70, 64), Enum.Material.Slate, { CanCollide = false })
end
-- плитка у колонн
for x = -140, 140, 20 do
	for _, z in { -34, -12, 12, 34 } do
		box(Walls, "PillarBase", V(2.6, 3, 2.6), x, 1.5, z, Color3.fromRGB(140, 140, 136), Enum.Material.Marble)
		box(Walls, "PillarTrim", V(2.2, 0.5, 2.2), x, 3.2, z, RUST, Enum.Material.Metal, { CanCollide = false })
	end
end
-- названия станции, указатели линий, стрелки
local stationNames = { "ПЛОЩАДЬ ПОБЕДЫ", "ПЛОЩАДЬ ПОБЕДЫ", "ПЛОЩАДЬ ПОБЕДЫ" }
for i, x in { -110, 0, 110 } do
	panel(Walls, "«" .. stationNames[i] .. "»", 18, 3.4, x, 8.5, 37.4, 0, Color3.fromRGB(20, 40, 90), Color3.fromRGB(235, 235, 235), (i == 2) and 4 or 0)
	panel(Walls, "«" .. stationNames[i] .. "»", 18, 3.4, x, 8.5, -37.4, 1, Color3.fromRGB(20, 40, 90), Color3.fromRGB(235, 235, 235), (i == 1) and -3 or 0)
end
for k, zt in LINES do
	for _, x in { -120, -40, 40, 120 } do
		-- табличка линии над путями, висит под потолком
		local p = panel(Walls, LINE_NAMES[k] .. (if x < 0 then "  ←" else "  →"), 12, 2, x, 10.2, zt, 0, LINE_COLORS[k], Color3.new(1, 1, 1))
		p.Size = V(12, 2, 0.3)
		box(Walls, "Hanger", V(0.2, 2.6, 0.2), x - 5, 11.7, zt, DARK, Enum.Material.Metal, { CanCollide = false })
		box(Walls, "Hanger", V(0.2, 2.6, 0.2), x + 5, 11.7, zt, DARK, Enum.Material.Metal, { CanCollide = false })
	end
end
-- рекламные щиты на колоннах (потрёпанные, разные цвета)
local ads = { "ЖИВИ БЕЗОПАСНО", "ДЕЖУРНАЯ СТАНЦИЯ", "НЕ ВЫХОДИТЬ ПОСЛЕ 22:00", "ВАШ КОРИДОР ЧИСТ?", "ПРОВЕРЬ ПАЙКИ", "ЭВАКУАЦИЯ ЦЕНТР 4" }
local n = 0
for x = -130, 130, 40 do
	for _, z in { -12, 12 } do
		n += 1
		local face = if z > 0 then 1 else 0
		panel(Walls, ads[(n % #ads) + 1], 3.2, 4.4, x, 5.2, z + (if z > 0 then 1.1 else -1.1), face, Color3.fromRGB(rng:NextInteger(40, 110), rng:NextInteger(40, 110), rng:NextInteger(40, 110)), Color3.fromRGB(230, 220, 190), rng:NextInteger(-4, 4))
	end
end

------------------------------------------------------------------------------------------------ коммуникации под потолком
for _, z in { -30, -12, 12, 30 } do
	box(Utilities, "CableTray", V(316, 0.5, 2), 0, 12.0, z, DARK, Enum.Material.Metal, { CanCollide = false })
	cylinder(Utilities, "Pipe", 316, 0.9, 0, 11.0, z + 1.4, Color3.fromRGB(88, 90, 94))
	cylinder(Utilities, "PipeRust", 316, 0.6, 0, 11.3, z - 1.4, RUST)
end
for _ = 1, 160 do
	local x = rng:NextNumber(-150, 150)
	local z = ({ -30, -12, 12, 30 })[rng:NextInteger(1, 4)] + rng:NextNumber(-0.8, 0.8)
	local len = rng:NextNumber(1.5, 6)
	box(Utilities, "HangingCable", V(0.15, len, 0.15), x, 11.7 - len / 2, z, Color3.fromRGB(20, 20, 22), Enum.Material.SmoothPlastic, { CanCollide = false })
end
-- вентиляционные короба у торцов
for _, x in { -150, 150 } do
	for _, z in { -34, 34 } do
		box(Utilities, "Duct", V(10, 3, 5), x, 11.0, z, Color3.fromRGB(128, 130, 134), Enum.Material.Metal)
	end
end
-- провисший светильник и упавшая плита потолка (местами)
for _, x in { -85, 25, 95 } do
	box(Debris, "FallenSlab", V(6, 0.6, 4), x, 0.4, 14 + rng:NextNumber(-3, 3), Color3.fromRGB(100, 100, 96), Enum.Material.Slate, { Orientation = V(0, rng:NextInteger(0, 90), rng:NextInteger(-12, 12)) })
end

------------------------------------------------------------------------------------------------ мебель: лавки, урны, автоматы, билетные автоматы
local bench = lib:WaitForChild("Bench")
for _, row in { { -12, 0 }, { 12, 0 }, { -34, 0 }, { 34, 0 } } do
	for x = -120, 120, 40 do
		if rng:NextNumber() > 0.25 then
			local b = put(bench, Furniture, "Bench", x + rng:NextNumber(-6, 6), 0.0, row[1] + (if row[1] > 0 then -2.5 else 2.5), if rng:NextNumber() > 0.8 then 90 else 0)
		end
	end
end
local binPositions = {}
for x = -130, 130, 26 do
	for _, z in { -36.2, 36.2, -15.5, 15.5 } do
		if rng:NextNumber() > 0.4 then
			local tipped = rng:NextNumber() > 0.7
			local p = cylinder(Furniture, "Bin", 2.2, 1.5, x, if tipped then 0.75 else 1.1, z, Color3.fromRGB(46, 78, 52), false)
			if tipped then
				p.CFrame = CFrame.new(x, OY + 0.75, z) * CFrame.Angles(math.rad(90), 0, math.rad(rng:NextInteger(0, 180)))
			end
		end
	end
end
local vend = game.ServerStorage:WaitForChild("Assets"):WaitForChild("Props"):FindFirstChild("Vending")
if vend then
	for _, spec in { { -130, -37.5, 0 }, { 130, 37.5, 180 }, { 0, 37.5, 180 } } do
		local m = put(vend, Furniture, "VendingDecor", spec[1], 0.0, spec[2] - (if spec[2] > 0 then 1.5 else -1.5), spec[3])
		for _, d in m:GetDescendants() do
			if d:IsA("SurfaceGui") or d:IsA("Script") or d:IsA("LocalScript") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored = true
			end
		end
	end
end
local ticket = lib:WaitForChild("TicketMachine")
for _, x in { -75, 75 } do
	put(ticket, Furniture, "TicketMachine", x, 0.0, 36.2, 0)
end

------------------------------------------------------------------------------------------------ мусор, ящики, кровь, лужи
local rubbleColors = { Color3.fromRGB(88, 84, 78), Color3.fromRGB(70, 68, 64), Color3.fromRGB(104, 98, 90) }
-- зона без обломков вокруг маркеров спавна, выхода, босса, цели, ящиков и точек зомби (радиус по XZ, в студах)
local CLEAR_RADIUS = 8
local clearZones: { Vector3 } = {}
local markersFolder = ROOT:FindFirstChild("Markers")
if markersFolder then
	for _, m in markersFolder:GetChildren() do
		if m:IsA("BasePart") then
			table.insert(clearZones, V(m.Position.X, 0, m.Position.Z))
		end
	end
end
local function inClearZone(x: number, z: number): boolean
	for _, c in clearZones do
		if (c.X - x) ^ 2 + (c.Z - z) ^ 2 < CLEAR_RADIUS ^ 2 then
			return true
		end
	end
	return false
end
local function rubblePile(parent: Instance, x: number, y: number, z: number, count: number, spread: number)
	for _ = 1, count do
		local s = rng:NextNumber(0.5, 2.2)
		local sx, sy, sz = s * rng:NextNumber(0.8, 1.6), s * rng:NextNumber(0.5, 1), s * rng:NextNumber(0.8, 1.6)
		local px, pz = x + rng:NextNumber(-spread, spread), z + rng:NextNumber(-spread, spread)
		local color, orient = rubbleColors[rng:NextInteger(1, 3)], V(rng:NextInteger(-20, 20), rng:NextInteger(0, 360), rng:NextInteger(-20, 20))
		if not inClearZone(px, pz) then -- случайные числа тратим всегда: раскладка остальных куч не меняется
			box(parent, "Rubble", V(sx, sy, sz), px, y + s * 0.3, pz, color, Enum.Material.Slate, { Orientation = orient })
		end
	end
end
-- кучи у стен и у колонн
for i = 1, 26 do
	local z = ({ -36, 36, -16.5, 16.5 })[rng:NextInteger(1, 4)]
	rubblePile(Debris, rng:NextNumber(-148, 148), 0, z + rng:NextNumber(-0.8, 0.8), rng:NextInteger(4, 8), 2.2)
end
-- ящики и бочки
for _ = 1, 22 do
	local x, z = rng:NextNumber(-148, 148), ({ -36.4, 36.4, -16.8, 16.8 })[rng:NextInteger(1, 4)]
	if rng:NextNumber() > 0.5 then
		box(Debris, "Crate", V(2.4, 2.4, 2.4), x, 1.2, z, Color3.fromRGB(110, 86, 52), Enum.Material.Wood, { Orientation = V(0, rng:NextInteger(0, 90), 0) })
	else
		cylinder(Debris, "Barrel", 3, 2.2, x, 1.5, z, Color3.fromRGB(70, 74, 82), false)
	end
end
-- кровь и грязь на платформах: убрана по просьбе Руслана
for _ = 1, 0 do
	local d = rng:NextNumber(1.2, 4)
	local x, z = rng:NextNumber(-150, 150), ({ -33, -12, 12, 33 })[rng:NextInteger(1, 4)] + rng:NextNumber(-3, 3)
	box(Stains, "Blood", V(0.05, d, d * rng:NextNumber(0.6, 1.2)), x, 0.06, z, Color3.fromRGB(rng:NextInteger(70, 110), 6, 6), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, CanCollide = false, Orientation = V(0, 0, 90) })
end
-- лужи в руслах путей: убраны
for _ = 1, 0 do
	local d = rng:NextNumber(2, 5)
	box(Stains, "Puddle", V(0.04, d, d * rng:NextNumber(1, 2.4)), rng:NextNumber(-150, 150), -2.46, LINES[rng:NextInteger(1, 3)] + rng:NextNumber(-3, 3), Color3.fromRGB(40, 70, 90), Enum.Material.Glass, { Shape = Enum.PartType.Cylinder, CanCollide = false, Transparency = 0.35, Orientation = V(0, 0, 90) })
end

------------------------------------------------------------------------------------------------ лагеря выживших (свет огня, спальники, ящики)
local function camp(parent: Instance, x: number, y: number, z: number, yaw: number)
	local g = Instance.new("Model")
	g.Name = "Camp"
	g.Parent = parent
	local barrel = cylinder(g, "FireBarrel", 3, 2.2, x, y + 1.5, z, Color3.fromRGB(60, 40, 30), false)
	local fire = Instance.new("Fire")
	fire.Size = 6
	fire.Heat = 8
	fire.Parent = barrel
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 70)
	light.Brightness = 1.6
	light.Range = 26
	light.Parent = barrel
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0)
	for i, off in { V(-4.5, 0, 2), V(-4.5, 0, -2.4), V(4.5, 0, 2.5) } do
		local p = box(g, "Bedroll", V(5.2, 0.5, 2.1), 0, y + 0.3, 0, Color3.fromRGB(60 + i * 20, 70, 50), Enum.Material.Fabric, { CanCollide = false })
		p.CFrame = CFrame.new(x, OY + y + 0.3, z) * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.new(off)
	end
	for i, off in { V(3.5, 0, -3.4), V(5.4, 0, -3.8) } do
		local p = box(g, "CampCrate", V(2.4, 2.4, 2.4), 0, y + 1.2, 0, Color3.fromRGB(110, 86, 52), Enum.Material.Wood)
		p.CFrame = CFrame.new(x, OY + y + 1.2, z) * CFrame.Angles(0, math.rad(yaw + i * 14), 0) * CFrame.new(off)
	end
	local sign = panel(g, "НЕ ПОДХОДИТЬ!", 4.4, 1.2, x, y + 4.0, z, 0, Color3.fromRGB(150, 40, 30), Color3.new(1, 1, 1), 8)
	sign.CFrame = CFrame.new(x - 1, OY + y + 4.0, z - 3.2) * CFrame.Angles(0, math.rad(yaw), math.rad(8))
	box(g, "SignPost", V(0.2, 4, 0.2), x - 1, y + 2, z - 3.3, DARK, Enum.Material.Metal, { CanCollide = false })
end
camp(Camps, -125, 0, 33.5, 0)
camp(Camps, 120, 0, -33.5, 180)
camp(Camps, -20, 0, 12, 90)
camp(Camps, 70, -2.5, -24, 0) -- в русле: временный лагерь у вагона

------------------------------------------------------------------------------------------------ тоннели: крепи, коммуникации, сигналы, свалки
local function tunnelSection(x0: number, x1: number, zt: number)
	for x = x0 + 10, x1 - 10, 28 do
		-- крепь: две стойки и балка
		for _, s in { -1, 1 } do
			box(TunnelDecor, "BraceLeg", V(0.8, 10, 0.8), x, 2.5, zt + s * 6.3, Color3.fromRGB(80, 66, 52), Enum.Material.Wood, { CanCollide = false })
		end
		box(TunnelDecor, "BraceBeam", V(0.8, 0.8, 13.6), x, 7.4, zt, Color3.fromRGB(80, 66, 52), Enum.Material.Wood, { CanCollide = false })
	end
	-- кабели вдоль стен
	for _, s in { -1, 1 } do
		box(TunnelDecor, "WallCable", V(x1 - x0, 0.4, 0.4), (x0 + x1) / 2, 3.2, zt + s * 6.8, Color3.fromRGB(26, 26, 28), Enum.Material.SmoothPlastic, { CanCollide = false })
		box(TunnelDecor, "WallCable", V(x1 - x0, 0.4, 0.4), (x0 + x1) / 2, 4.1, zt + s * 6.8, Color3.fromRGB(92, 30, 26), Enum.Material.SmoothPlastic, { CanCollide = false })
	end
	cylinder(TunnelDecor, "CeilingPipe", x1 - x0, 0.9, (x0 + x1) / 2, 6.6, zt, Color3.fromRGB(88, 90, 94))
	-- мусор и ящики у стен, лужи
	for x = x0 + 30, x1 - 30, 70 do
		if rng:NextNumber() > 0.3 then
			local side = if rng:NextNumber() > 0.5 then 1 else -1
			rubblePile(TunnelDecor, x + rng:NextNumber(-15, 15), -2.5, zt + side * 5.8, rng:NextInteger(4, 9), 1.4)
		end
	end
	for x = x0 + 45, x1 - 40, 110000 do
		local d = rng:NextNumber(3, 6)
		box(TunnelDecor, "Puddle", V(0.04, d, d * 1.8), x, -2.46, zt + rng:NextNumber(-3, 3), Color3.fromRGB(40, 70, 90), Enum.Material.Glass, { Shape = Enum.PartType.Cylinder, CanCollide = false, Transparency = 0.35, Orientation = V(0, 0, 90) })
	end
	-- сигнальные огни у путей и указатели «выход»
	for x = x0 + 40, x1 - 40, 80 do
		box(TunnelDecor, "SignalPole", V(0.3, 4, 0.3), x, -0.5, zt + 6.2, DARK, Enum.Material.Metal, { CanCollide = false })
		lamp(TunnelDecor, x, 1.8, zt + 6.2, Color3.fromRGB(255, 60, 40), 0.8, 14)
	end
	for x = x0 + 60, x1 - 60, 120 do
		panel(TunnelDecor, "ВЫХОД " .. (if x < 0 then "→" else "←"), 3.6, 1, x, 4.8, zt + 6.7, 0, Color3.fromRGB(30, 110, 60), Color3.new(1, 1, 1), rng:NextInteger(-3, 3))
	end
end
for _, zt in LINES do
	tunnelSection(-STATION_HALF - TUNNEL, -STATION_HALF - 5, zt)
end
tunnelSection(STATION_HALF + 5, BX0, 0)
tunnelSection(STATION_HALF + 5, STATION_HALF + TUNNEL, -24)
tunnelSection(STATION_HALF + 5, STATION_HALF + TUNNEL, 24)
-- лагеря и брошенные вещи в тоннелях
for _, spec in { { -260, -24 }, { -420, 0 }, { 300, 24 }, { 200, -24 } } do
	local g = Instance.new("Model")
	g.Name = "TunnelCamp"
	g.Parent = Camps
	local x, z = spec[1], spec[2]
	local barrel = cylinder(g, "FireBarrel", 3, 2.2, x, -1.0, z - 5, Color3.fromRGB(60, 40, 30), false)
	local fire = Instance.new("Fire")
	fire.Size = 5
	fire.Parent = barrel
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(255, 150, 70)
	l.Brightness = 1.4
	l.Range = 24
	l.Parent = barrel
	for i = 1, 2 do
		box(g, "Bedroll", V(5, 0.5, 2), x + 4 + i * 1.5, -2.2, z - 5 + (i - 1.5) * 2.6, Color3.fromRGB(70, 80, 60), Enum.Material.Fabric, { CanCollide = false })
	end
	box(g, "Crate", V(2.4, 2.4, 2.4), x - 3, -1.3, z - 5.5, Color3.fromRGB(110, 86, 52), Enum.Material.Wood)
end
-- у обвалов: тела-заглушки (мешки) и свет
for _, zt in LINES do
	rubblePile(TunnelDecor, -STATION_HALF - TUNNEL + 8, -2.5, zt, 10, 4)
	lamp(TunnelDecor, -STATION_HALF - TUNNEL + 14, 3.5, zt, Color3.fromRGB(255, 60, 40), 1.4, 20)
end

------------------------------------------------------------------------------------------------ станция B и двор
local bc = (BX0 + BX1) / 2
panel(StationB, "СТАНЦИЯ «ЗАГОРНАЯ»", 20, 3.6, bc - 30, 9, 19.4, 0, Color3.fromRGB(20, 60, 40), Color3.fromRGB(235, 235, 235), 2)
panel(StationB, "СТАНЦИЯ «ЗАГОРНАЯ»", 20, 3.6, bc + 30, 9, -19.4, 1, Color3.fromRGB(20, 60, 40), Color3.fromRGB(235, 235, 235), -2)
for _, z in { -17.7, 17.7 } do
	box(StationB, "TileBand", V(160, 3.2, 0.3), bc, 1.6, z, Color3.fromRGB(150, 150, 146), Enum.Material.Marble, { CanCollide = false })
end
for _, z in { -9, 9 } do
	box(StationB, "CableTray", V(158, 0.5, 2), bc, 12, z, DARK, Enum.Material.Metal, { CanCollide = false })
	cylinder(StationB, "Pipe", 158, 0.9, bc, 11, z + 1.4, Color3.fromRGB(88, 90, 94))
end
for i = 0, 4 do
	put(bench, StationB, "Bench", BX0 + 25 + i * 28, 0.0, if i % 2 == 0 then 13 else -13, 0)
end
for x = BX0 + 20, BX1 - 20, 30 do
	rubblePile(StationB, x + rng:NextNumber(-8, 8), 0, ({ 16.5, -16.5 })[rng:NextInteger(1, 2)], rng:NextInteger(3, 6), 1.8)
end
camp(StationB, BX0 + 40, 0, 12.5, 0)
-- двор: бочки, ящики, остовы машин, столбы со светом, знак
for i = 1, 14 do
	local x, z = rng:NextNumber(662, 818), rng:NextNumber(42, 130)
	if math.abs(z - 90) > 17 and math.abs(x - 766) > 12 then
		if rng:NextNumber() > 0.5 then
			box(StationB, "Crate", V(2.6, 2.6, 2.6), x, 14.3, z, Color3.fromRGB(110, 86, 52), Enum.Material.Wood, { Orientation = V(0, rng:NextInteger(0, 90), 0) })
		else
			cylinder(StationB, "Barrel", 3, 2.2, x, 14.5, z, Color3.fromRGB(70, 74, 82), false)
		end
	end
end
for _, spec in { { 672, 60, 20 }, { 810, 120, -30 }, { 700, 125, 70 } } do
	local car = box(StationB, "WreckBody", V(4.4, 1.6, 9.5), spec[1], 14.1, spec[2], Color3.fromRGB(88, 70, 60), Enum.Material.Metal, { Orientation = V(0, spec[3], 0) })
	box(StationB, "WreckCabin", V(4, 1.2, 4.6), spec[1], 15.5, spec[2] + 0.5, Color3.fromRGB(60, 60, 64), Enum.Material.Metal, { Orientation = V(0, spec[3], 0) })
	car.Parent = StationB
end
for _, spec in { { 660, 45 }, { 820, 45 }, { 660, 130 }, { 820, 130 } } do
	box(StationB, "LampPost", V(0.5, 12, 0.5), spec[1], 19, spec[2], DARK, Enum.Material.Metal)
	lamp(StationB, spec[1], 25.5, spec[2], Color3.fromRGB(255, 210, 150), 1.4, 40)
end
panel(StationB, "ВЫХОД ЗА ГОРУ → ТОННЕЛЬ ДЛЯ АВТО", 18, 2.6, 740, 20, 135, 1, Color3.fromRGB(150, 110, 20), Color3.fromRGB(20, 20, 20))

------------------------------------------------------------------------------------------------ зал: плакаты, лавки, урны
local hallBench = bench
for x = 84, 128, 22 do
	put(hallBench, Furniture, "HallBench", x, 13.0, 108, 0)
end
panel(Walls, "ВЫХОД В ГОРОД →", 10, 2, 128, 28, 84, 0, Color3.fromRGB(30, 110, 60), Color3.new(1, 1, 1))
panel(Walls, "НЕ СТОЯТЬ У ТУРНИКЕТОВ", 12, 2, 106, 27, 110.2, 0, Color3.fromRGB(150, 40, 30), Color3.new(1, 1, 1), 2)
for _, spec in { { 80, 100 }, { 130, 60 }, { 90, 62 } } do
	cylinder(Furniture, "Bin", 2.2, 1.5, spec[1], 14.1, spec[2], Color3.fromRGB(46, 78, 52), false)
end
rubblePile(Debris, 100, 13.0, 104, 6, 2)
rubblePile(Debris, 120, 13.0, 66, 5, 2)

------------------------------------------------------------------------------------------------ пыль и ржавый свет
for _, x in { -120, -60, 0, 60, 120 } do
	local p = box(Fx, "DustEmitter", V(1, 1, 1), x, 10, 0, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, { Transparency = 1, CanCollide = false })
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Rate = 4
	e.Lifetime = NumberRange.new(10, 14)
	e.Speed = NumberRange.new(0.3, 0.8)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new(8)
	e.Transparency = NumberSequence.new(0.94)
	e.Color = ColorSequence.new(Color3.fromRGB(150, 150, 140))
	e.Parent = p
end

------------------------------------------------------------------------------------------------ плитка на полу (материала Tile в Roblox нет: Marble + швы + шахматные вставки)
local floors = folder("FloorTiles")
local seamColor = Color3.fromRGB(70, 72, 70)
local function seamPart(name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, color: Color3, mat: Enum.Material)
	box(floors, name, V(sx, sy, sz), x, y, z, color, mat, { CanCollide = false, CanQuery = false })
end
for _, p in ROOT.Platform:GetChildren() do
	if string.find(p.Name, "^Platform%d") and p:IsA("BasePart") then
		p.Material = Enum.Material.Marble
		p.Color = Color3.fromRGB(176, 178, 170)
	end
end
for _, pl in { { -38, -29 }, { -19, -5 }, { 5, 19 }, { 29, 38 } } do
	local zc, w = (pl[1] + pl[2]) / 2, pl[2] - pl[1]
	for x = -158, 158, 4 do
		seamPart("Seam", x, 0.03, zc, 0.12, 0.04, w, seamColor, Enum.Material.SmoothPlastic)
	end
	for z = pl[1] + 2, pl[2] - 1, 2 do
		seamPart("Seam", 0, 0.03, z, 316, 0.04, 0.12, seamColor, Enum.Material.SmoothPlastic)
	end
end
for _, pl in { { -19, -5 }, { 5, 19 } } do
	local zc = (pl[1] + pl[2]) / 2
	for i = -39, 39 do
		if i % 2 == 0 then
			seamPart("DarkTile", i * 4 + 2, 0.04, zc, 4, 0.05, 4, Color3.fromRGB(86, 96, 110), Enum.Material.Marble)
		end
	end
end

------------------------------------------------------------------------------------------------ плитка на поясе стен (A002): швы тонкими деталями
-- пояс TileBand (высота 3,2, внутренняя грань на |z| = 37,55 у главной станции и 17,55 у станции B); плитка 2 × 0,8 студа.
-- Случайные числа не тратим (раскладка остальных деталей не меняется); детали без коллизии и без запросов.
local wallTiles = folder("WallTiles")
local function wallSeams(x0: number, x1: number, zInner: number, inward: number)
	local zc = zInner + inward * 0.03 -- чуть впереди пояса, внутрь зала
	for x = x0, x1, 2 do
		box(wallTiles, "Seam", V(0.1, 3.2, 0.06), x, 1.6, zc, seamColor, Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	end
	for _, y in { 0.8, 1.6, 2.4 } do
		box(wallTiles, "Seam", V(x1 - x0, 0.08, 0.06), (x0 + x1) / 2, y, zc, seamColor, Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	end
end
wallSeams(-158, 158, 37.55, -1)
wallSeams(-158, 158, -37.55, 1)
wallSeams(BX0 + 2, BX1 - 2, 17.55, -1)
wallSeams(BX0 + 2, BX1 - 2, -17.55, 1)

local count = 0
for _, d in DECOR:GetDescendants() do
	if d:IsA("BasePart") then
		count += 1
	end
end
return "Decor parts=" .. count
