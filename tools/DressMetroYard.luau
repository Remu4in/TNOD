--!strict
-- Оснащение метро, проход 3 (P3): двор R5 и станция B + хвосты. Запуск: Studio → Edit (execute_luau)
-- ПОСЛЕ BuildMetro.luau, DressMetro.luau (и DressMetroInterior.luau — порядок с ним не важен, папки разные).
-- Идемпотентно: свои папки Decor.YardV2 / Decor.StationBV2 пересоздаются; перекраска идёт от OrigColor/OrigMaterial.
-- Секции включаются в RUN (можно запускать по одной). Все добавки без коллизии, кроме контейнеров, мешков и бочек (они стоят вне проходов
-- и вне 8 студов вокруг маркеров; полоса лестницы x 756…778, z < 64 свободна).
-- Правила: docs/world/style_bible.md (без надписей, ржавый серо-ржавый, ночь), docs/world/metro.spec.md R4/R5.

local RUN = { yard = true, stationb = true, tails = true }

local OY = 600
local V = Vector3.new
local ROOT = workspace:FindFirstChild("Metro")
assert(ROOT, "сначала tools/BuildMetro.luau")
local DECOR = ROOT:FindFirstChild("Decor")
assert(DECOR, "сначала tools/DressMetro.luau")
local Props = ROOT:WaitForChild("Props")

local DARK = Color3.fromRGB(48, 50, 54)
local RUST = Color3.fromRGB(92, 58, 44)
local CONC = Color3.fromRGB(70, 70, 72)

local function fresh(name: string): Folder
	local f = DECOR:FindFirstChild(name)
	if f then
		f:Destroy()
	end
	local n = Instance.new("Folder")
	n.Name = name
	n.Parent = DECOR
	return n
end

local function box(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, extra: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
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

local SOLID = { CanCollide = true, CanQuery = true }

local function grime(c: Color3, k: number, rustMix: number): Color3
	local h, s, v = c:ToHSV()
	return Color3.fromHSV(h, s * 0.55, v * k):Lerp(Color3.fromRGB(78, 62, 50), rustMix)
end

local function sagCable(parent: Instance, a: Vector3, b: Vector3, sag: number, color: Color3)
	local n = 6
	local prev = a
	for i = 1, n do
		local t = i / n
		local nxt = a:Lerp(b, t) - V(0, 4 * sag * t * (1 - t), 0)
		box(parent, "Cable", V(0.2, 0.2, (nxt - prev).Magnitude), CFrame.lookAt((prev + nxt) / 2, nxt), color, Enum.Material.SmoothPlastic)
		prev = nxt
	end
end

local function pointLight(p: BasePart, color: Color3, brightness: number, range: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Parent = p
end

local markerPos: { Vector3 } = {}
do
	local mk = ROOT:FindFirstChild("Markers")
	if mk then
		for _, m in mk:GetChildren() do
			if m:IsA("BasePart") then
				table.insert(markerPos, m.Position)
			end
		end
	end
end
local function freeSpot(x: number, z: number, r: number): boolean
	for _, p in markerPos do
		if (p.X - x) ^ 2 + (p.Z - z) ^ 2 < r * r then
			return false
		end
	end
	return true
end

------------------------------------------------------------------------------------------------ двор R5 (x 650…830, z 36…136, земля y 13)
if RUN.yard then
	local f = fresh("YardV2")
	local rng = Random.new(155)
	local GY = 13 -- верх земли (локально)
	local placed: { { number } } = {}
	-- место для крупного предмета: в границах двора, вне поезда, вне полосы лестницы, вне 8 студов от маркеров, не рядом с уже поставленным
	local function okSpot(x: number, z: number, r: number): boolean
		if x < 656 + r or x > 824 - r or z < 42 + r or z > 130 - r then
			return false
		end
		if x > 676 and x < 794 and z > 70 and z < 110 then
			return false -- разбитый состав (BrokenTrainYard, коридор вокруг него)
		end
		if x > 750 - r and x < 784 + r and z < 66 then
			return false -- полоса от лестницы
		end
		if not freeSpot(x, z, 8 + r) then
			return false
		end
		for _, q in placed do
			if (q[1] - x) ^ 2 + (q[2] - z) ^ 2 < (q[3] + r) ^ 2 then
				return false
			end
		end
		return true
	end
	local function claim(x: number, z: number, r: number)
		table.insert(placed, { x, z, r })
	end

	-- земля: пятна грязи, трещины, лужи
	for _ = 1, 70 do
		local d = rng:NextNumber(3, 9)
		box(f, "Dirt", V(0.06, d, d * rng:NextNumber(0.6, 1)), CFrame.new(rng:NextNumber(658, 822), OY + GY + 0.04, rng:NextNumber(40, 132)) * CFrame.Angles(0, rng:NextNumber(0, 3), 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(44, 40, 36), Enum.Material.Ground, { Shape = Enum.PartType.Cylinder, Transparency = rng:NextNumber(0.35, 0.6) })
	end
	for _ = 1, 34 do
		box(f, "Crack", V(rng:NextNumber(5, 14), 0.06, 0.18), CFrame.new(rng:NextNumber(660, 820), OY + GY + 0.06, rng:NextNumber(42, 130)) * CFrame.Angles(0, rng:NextNumber(0, 3.1), 0), Color3.fromRGB(22, 22, 24), Enum.Material.Concrete)
	end
	for _ = 1, 9 do
		local d = rng:NextNumber(3, 7)
		box(f, "Puddle", V(0.05, d, d * rng:NextNumber(0.6, 0.9)), CFrame.new(rng:NextNumber(662, 818), OY + GY + 0.07, rng:NextNumber(46, 130)) * CFrame.Angles(0, rng:NextNumber(0, 3), 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(20, 22, 24), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Reflectance = 0.04, Transparency = 0.15 })
	end
	-- облупленная разметка парковки у восточной ограды
	for z = 48, 128, 10 do
		box(f, "BayLine", V(8, 0.05, 0.35), CFrame.new(816, OY + GY + 0.05, z), Color3.fromRGB(150, 140, 100), Enum.Material.SmoothPlastic, { Transparency = 0.35 })
	end

	-- ограда: столбы, верхний рельс, колючая проволока (поверх существующих щитов YardFence*, высота 13,5…19,5)
	local function fence(x0: number, z0: number, x1: number, z1: number)
		local len = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
		local n = math.max(1, math.floor(len / 10))
		local prev = V(x0, OY + GY + 8.4, z0)
		for i = 0, n do
			local t = i / n
			local x, z = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
			box(f, "FencePost", V(0.6, 9, 0.6), CFrame.new(x, OY + GY + 4.5, z), DARK, Enum.Material.Metal)
			local top = V(x, OY + GY + 8.4, z)
			if i > 0 then
				box(f, "FenceRail", V(0.25, 0.25, (top - prev).Magnitude), CFrame.lookAt((prev + top) / 2, top), RUST, Enum.Material.Metal)
				sagCable(f, prev + V(0, 0.5, 0), top + V(0, 0.5, 0), 0.35, Color3.fromRGB(34, 34, 36))
			end
			prev = top
		end
	end
	fence(650.5, 36.5, 650.5, 136)
	fence(829.5, 36.5, 829.5, 136)
	fence(650.5, 136, 829.5, 136)
	fence(650.5, 36.5, 760, 36.5)
	fence(777, 36.5, 829.5, 36.5)

	-- «гора» за двором: слои скал снаружи ограды (не мешают проходу) и боковые срезы; тёмные, без коллизии
	local ROCK = { Color3.fromRGB(58, 57, 55), Color3.fromRGB(66, 63, 58), Color3.fromRGB(50, 50, 52) }
	for i = 0, 17 do
		local x = 636 + i * 11.5
		local h = rng:NextNumber(46, 96)
		local w = rng:NextNumber(14, 24)
		box(f, "Cliff", V(w, h, rng:NextNumber(12, 22)), CFrame.new(x, OY + 14 + h / 2 - 6, 148 + rng:NextNumber(0, 12)) * CFrame.Angles(0, math.rad(rng:NextNumber(-10, 10)), math.rad(rng:NextNumber(-5, 5))), ROCK[rng:NextInteger(1, 3)], Enum.Material.Slate)
	end
	for _, side in { { 640, -1 }, { 842, 1 } } do
		for z = 40, 140, 16 do
			local h = rng:NextNumber(28, 60)
			box(f, "CliffSide", V(rng:NextNumber(10, 16), h, 18), CFrame.new(side[1] + side[2] * rng:NextNumber(0, 6), OY + 14 + h / 2 - 6, z) * CFrame.Angles(0, math.rad(rng:NextNumber(-8, 8)), math.rad(rng:NextNumber(-4, 4))), ROCK[rng:NextInteger(1, 3)], Enum.Material.Slate)
		end
	end
	-- осыпь у подножия существующей стены (внутри двора, у северной ограды, 5 студов)
	for x = 662, 818, 7 do
		if rng:NextNumber() > 0.3 then
			local s = rng:NextNumber(1.6, 3.4)
			box(f, "Scree", V(s, s * 0.7, s), CFrame.new(x + rng:NextNumber(-2, 2), OY + GY + s * 0.3, rng:NextNumber(131, 134.4)) * CFrame.Angles(rng:NextNumber(0, 1), rng:NextNumber(0, 3), rng:NextNumber(0, 1)), ROCK[rng:NextInteger(1, 3)], Enum.Material.Slate)
		end
	end

	-- лестница: перила по краям, фонарь над выходом
	local steps = 13
	for _, x in { 760.4, 771.6 } do
		local a = V(x, OY + 1.0 + 3.4, 21.6)
		local b = V(x, OY + steps + 3.4, 21.6 + (steps - 1) * 1.15)
		box(f, "HandRail", V(0.25, 0.25, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), RUST, Enum.Material.Metal)
		for i = 0, steps - 1, 3 do
			local z = 21.6 + i * 1.15
			box(f, "RailPost", V(0.25, 3.4, 0.25), CFrame.new(x, OY + (i + 1) + 1.7, z), DARK, Enum.Material.Metal)
		end
	end
	do
		box(f, "ExitLampPost", V(0.5, 9, 0.5), CFrame.new(777.5, OY + GY + 4.5, 40), DARK, Enum.Material.Metal)
		box(f, "ExitLampArm", V(5, 0.35, 0.35), CFrame.new(775, OY + GY + 8.8, 40), DARK, Enum.Material.Metal)
		local head = box(f, "ExitLamp", V(1.6, 0.4, 1.0), CFrame.new(772.5, OY + GY + 8.5, 40), Color3.fromRGB(255, 205, 140), Enum.Material.Neon)
		pointLight(head, Color3.fromRGB(255, 200, 140), 2.2, 44)
	end

	-- укрытия: контейнеры, мешки, паллеты, шины, бочки-костры
	local CONT = { Color3.fromRGB(104, 52, 40), Color3.fromRGB(46, 62, 78), Color3.fromRGB(70, 82, 60), Color3.fromRGB(96, 78, 44) }
	local function container(x: number, z: number, yaw: number)
		local col = grime(CONT[rng:NextInteger(1, #CONT)], 0.8, 0.25)
		local cf = CFrame.new(x, OY + GY + 4.15, z) * CFrame.Angles(0, math.rad(yaw), 0)
		box(f, "Container", V(20, 8.3, 8), cf, col, Enum.Material.CorrodedMetal, SOLID)
		for i = -4, 4 do
			box(f, "ContainerRib", V(0.5, 8.1, 8.2), cf * CFrame.new(i * 2.2, 0, 0), col:Lerp(Color3.new(0, 0, 0), 0.25), Enum.Material.Metal)
		end
		claim(x, z, 12)
	end
	local function sandbags(x: number, z: number, yaw: number, len: number)
		local cf0 = CFrame.new(x, OY + GY, z) * CFrame.Angles(0, math.rad(yaw), 0)
		for row = 0, 2 do
			local cnt = math.floor(len / 2.2) - row
			for i = 0, cnt - 1 do
				local off = (i - (cnt - 1) / 2) * 2.2 + (row % 2) * 0.6
				box(f, "Sandbag", V(2.2, 0.9, 1.3), cf0 * CFrame.new(off, 0.45 + row * 0.85, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(-6, 6)), 0), Color3.fromRGB(104 + rng:NextInteger(-8, 8), 94, 70), Enum.Material.Fabric, SOLID)
			end
		end
		claim(x, z, len / 2 + 1)
	end
	local function pallets(x: number, z: number)
		local cf0 = CFrame.new(x, OY + GY, z) * CFrame.Angles(0, math.rad(rng:NextInteger(0, 90)), 0)
		for i = 0, rng:NextInteger(1, 3) do
			box(f, "Pallet", V(3.4, 0.4, 3.4), cf0 * CFrame.new(rng:NextNumber(-0.4, 0.4), 0.2 + i * 0.45, rng:NextNumber(-0.4, 0.4)) * CFrame.Angles(0, math.rad(rng:NextNumber(-15, 15)), 0), Color3.fromRGB(86, 66, 46), Enum.Material.Wood)
		end
		claim(x, z, 3)
	end
	local function tires(x: number, z: number)
		for i = 0, rng:NextInteger(2, 4) do
			box(f, "Tire", V(0.8, 2.4, 2.4), CFrame.new(x + rng:NextNumber(-1.2, 1.2), OY + GY + 0.4 + (i % 2) * 0.7, z + rng:NextNumber(-1.2, 1.2)) * CFrame.Angles(0, rng:NextNumber(0, 3), 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(22, 22, 24), Enum.Material.Rubber, { Shape = Enum.PartType.Cylinder })
		end
		claim(x, z, 3)
	end
	local function fireBarrel(x: number, z: number)
		box(f, "FireBarrel", V(3.2, 2.4, 2.4), CFrame.new(x, OY + GY + 1.6, z) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(86, 50, 38), Enum.Material.CorrodedMetal, { Shape = Enum.PartType.Cylinder, CanCollide = true, CanQuery = true })
		local glow = box(f, "FireGlow", V(1.2, 0.4, 1.2), CFrame.new(x, OY + GY + 3.1, z), Color3.fromRGB(255, 150, 70), Enum.Material.Neon)
		local fire = Instance.new("Fire")
		fire.Size = 4
		fire.Heat = 6
		fire.Parent = glow
		pointLight(glow, Color3.fromRGB(255, 150, 70), 2.4, 34)
		claim(x, z, 3)
	end

	-- расстановка по правилам (seed 155): контейнеры вдоль восточной и западной ограды, укрытия у лестницы и у поезда
	for _, c in { { 836 - 20, 56, 90 }, { 672, 118, 0 }, { 806, 124, 20 }, { 666, 52, 90 } } do
		local x, z = c[1], c[2]
		if okSpot(x, z, 12) then
			container(x, z, c[3])
		end
	end
	for _, s in { { 744, 56, 0, 10 }, { 790, 62, 90, 9 }, { 716, 62, 20, 9 }, { 700, 100, 90, 8 }, { 786, 120, 0, 10 } } do
		if okSpot(s[1], s[2], s[4] / 2 + 1) then
			sandbags(s[1], s[2], s[3], s[4])
		end
	end
	local tries = 0
	local cnt = { pallets = 0, tires = 0, fire = 0 }
	while tries < 200 and (cnt.pallets < 5 or cnt.tires < 4 or cnt.fire < 3) do
		tries += 1
		local x, z = rng:NextNumber(660, 820), rng:NextNumber(46, 128)
		if okSpot(x, z, 4) then
			if cnt.fire < 3 and tries % 7 == 0 then
				fireBarrel(x, z)
				cnt.fire += 1
			elseif cnt.pallets < 5 and tries % 3 == 0 then
				pallets(x, z)
				cnt.pallets += 1
			elseif cnt.tires < 4 then
				tires(x, z)
				cnt.tires += 1
			end
		end
	end
	-- мусор по двору: мешки и доски (без коллизии)
	for _ = 1, 22 do
		local x, z = rng:NextNumber(660, 820), rng:NextNumber(44, 132)
		if freeSpot(x, z, 8) and not (x > 676 and x < 794 and z > 70 and z < 110) then
			if rng:NextNumber() > 0.5 then
				for i = 1, 3 do
					box(f, "GarbageBag", V(1.6, 1.1, 1.4), CFrame.new(x + i * 1.1 - 2, OY + GY + 0.55, z + (i % 2) * 0.8), Color3.fromRGB(26, 26, 28), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
				end
			else
				box(f, "Plank", V(4.5, 0.25, 0.6), CFrame.new(x, OY + GY + 0.15, z) * CFrame.Angles(0, rng:NextNumber(0, 3), 0), Color3.fromRGB(70, 54, 40), Enum.Material.Wood)
			end
		end
	end
	-- холодные «ночные» фонари на высоких столбах по углам (поверх существующих тёплых), чтобы двор читался ночью
	for _, p in { { 700, 50 }, { 780, 50 }, { 700, 128 }, { 790, 128 } } do
		box(f, "FloodPost", V(0.6, 14, 0.6), CFrame.new(p[1], OY + GY + 7, p[2]), DARK, Enum.Material.Metal)
		local head = box(f, "FloodLamp", V(2.2, 0.5, 1.2), CFrame.new(p[1], OY + GY + 14.3, p[2]), Color3.fromRGB(205, 220, 245), Enum.Material.Neon)
		pointLight(head, Color3.fromRGB(190, 210, 255), 2.6, 62)
	end
end

------------------------------------------------------------------------------------------------ станция B (x 640…800, потолок 13, стены z ±20, платформы z 5…19)
if RUN.stationb then
	local f = fresh("StationBV2")
	local rng = Random.new(166)
	local X0, X1 = 640, 800
	local len = X1 - X0
	local cx = (X0 + X1) / 2
	-- фаски потолок/стена, продольные балки на колоннах, поперечные рёбра
	for _, s in { -1, 1 } do
		box(f, "Cove", V(len - 4, 2.2, 2.2), CFrame.new(cx, OY + 11.9, s * 17.9) * CFrame.Angles(math.rad(45), 0, 0), CONC, Enum.Material.Concrete)
		box(f, "Beam", V(len - 4, 1.2, 1.4), CFrame.new(cx, OY + 12.4, s * 12), Color3.fromRGB(78, 80, 84), Enum.Material.Concrete)
		box(f, "BeamFlange", V(len - 4, 0.25, 3), CFrame.new(cx, OY + 11.75, s * 12), Color3.fromRGB(78, 56, 46), Enum.Material.Metal)
	end
	for x = X0 + 10, X1 - 10, 20 do
		box(f, "Rib", V(1, 0.7, 38), CFrame.new(x, OY + 12.65, 0), Color3.fromRGB(70, 70, 74), Enum.Material.Concrete)
	end
	for _ = 1, 10 do
		local x0 = X0 + rng:NextInteger(0, 6) * 20 + 10
		sagCable(f, V(x0, OY + 12.3, rng:NextNumber(-15, 15)), V(x0 + 20, OY + 12.3, rng:NextNumber(-15, 15)), rng:NextNumber(0.8, 1.6), Color3.fromRGB(24, 24, 26))
	end
	-- пятна сырости на стенах
	for x = X0 + 12, X1 - 12, 24 do
		local s = if rng:NextNumber() > 0.5 then 1 else -1
		box(f, "Stain", V(rng:NextNumber(4, 9), rng:NextNumber(3, 7), 0.05), CFrame.new(x + rng:NextNumber(-6, 6), OY + rng:NextNumber(7, 10), s * 18.9), Color3.fromRGB(30, 30, 28), Enum.Material.Concrete, { Transparency = rng:NextNumber(0.3, 0.55) })
	end
	-- корпуса ламп станции и красные аварийные на стенах
	local lights = ROOT:FindFirstChild("Lights")
	if lights then
		for _, l in lights:GetChildren() do
			if l.Name == "Lamp" and l:IsA("BasePart") and math.abs(l.Position.Y - (OY + 12.3)) < 0.5 and l.Position.X > X0 and l.Position.X < X1 then
				box(f, "Housing", V(3.2, 0.3, 1.8), CFrame.new(l.Position) * CFrame.new(0, 0.4, 0), Color3.fromRGB(46, 47, 50), Enum.Material.Metal)
				for _, s in { -0.85, 0.85 } do
					box(f, "Rail", V(3.2, 0.14, 0.14), CFrame.new(l.Position) * CFrame.new(0, -0.15, s), Color3.fromRGB(58, 52, 48), Enum.Material.Metal)
				end
				if l.Material == Enum.Material.Neon then
					l.Color = Color3.fromRGB(205, 220, 245)
				end
			end
		end
	end
	for _, p in { { 690, 19.2 }, { 740, -19.2 }, { 784, 19.2 } } do
		local red = box(f, "EmergencyLamp", V(0.6, 0.6, 0.6), CFrame.new(p[1], OY + 9.5, p[2]), Color3.fromRGB(255, 90, 70), Enum.Material.Neon, { Shape = Enum.PartType.Ball })
		pointLight(red, Color3.fromRGB(255, 70, 50), 0.8, 18)
	end
	-- завал и мусор на платформах (вне 8 студов вокруг маркеров, не у лестницы x 756…778)
	for x = X0 + 16, X1 - 16, 22 do
		local s = if rng:NextNumber() > 0.5 then 1 else -1
		local px, pz = x + rng:NextNumber(-5, 5), s * rng:NextNumber(14, 17.5)
		if freeSpot(px, pz, 9) and not (px > 750 and px < 782 and pz > 0) then
			local yaw = CFrame.Angles(0, math.rad(rng:NextInteger(0, 180)), 0)
			if rng:NextNumber() > 0.5 then
				for i = 1, 3 do
					box(f, "GarbageBag", V(1.6, 1.1, 1.4), CFrame.new(px + i * 1.1 - 2, OY + 1 + 0.55, pz + (i % 2) * 0.8) * yaw, Color3.fromRGB(26, 26, 28), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
				end
			else
				box(f, "Crate", V(2.6, 2.6, 2.6), CFrame.new(px, OY + 2.3, pz) * yaw, Color3.fromRGB(80, 64, 46), Enum.Material.Wood, SOLID)
				box(f, "Crate", V(2.2, 2.2, 2.2), CFrame.new(px + 0.4, OY + 4.7, pz) * CFrame.Angles(0, math.rad(rng:NextInteger(0, 40)), 0), Color3.fromRGB(70, 56, 40), Enum.Material.Wood)
			end
		end
	end
	-- иконка вместо надписи: зелёный знак выхода со стрелкой над лестницей (северная стена, x 766)
	box(f, "ExitPlate", V(6, 2.6, 0.2), CFrame.new(766, OY + 10.2, 19.0), Color3.fromRGB(22, 84, 50), Enum.Material.SmoothPlastic)
	box(f, "ArrowShaft", V(0.4, 1.5, 0.15), CFrame.new(766, OY + 9.9, 18.85), Color3.fromRGB(215, 215, 205), Enum.Material.SmoothPlastic)
	for _, s in { -1, 1 } do
		box(f, "ArrowHead", V(1.0, 0.4, 0.15), CFrame.new(766 + s * 0.3, OY + 10.8, 18.85) * CFrame.Angles(0, 0, math.rad(s * 45)), Color3.fromRGB(215, 215, 205), Enum.Material.SmoothPlastic)
	end
end

------------------------------------------------------------------------------------------------ хвосты: турникеты и Train1_Full (текстура меша растянута)
if RUN.tails then
	-- сброс текстур мешей с запоминанием; цвет — от исходного
	local function dull(root: Instance, k: number, rustMix: number, material: Enum.Material?)
		for _, d in root:GetDescendants() do
			if d:IsA("SpecialMesh") and d.TextureId ~= "" then
				d:SetAttribute("OrigTextureId", d.TextureId)
				d.TextureId = ""
			end
			if d:IsA("BasePart") then
				if d:GetAttribute("OrigColor") == nil then
					d:SetAttribute("OrigColor", d.Color)
					d:SetAttribute("OrigMaterial", d.Material.Name)
				end
				local orig = d:GetAttribute("OrigColor") :: Color3
				local _, _, v = orig:ToHSV()
				if v > 0.32 then
					d.Color = grime(orig, k, rustMix)
				end
				if material and (d.Material == Enum.Material.Plastic or d.Material == Enum.Material.SmoothPlastic) then
					d.Material = material
				end
			end
		end
	end
	local tt = Props:FindFirstChild("Turnstiles_Hall")
	if tt then
		dull(tt, 0.42, 0.22, Enum.Material.Metal)
	end
	local tr = Props:FindFirstChild("Train1_Full")
	if tr and tr:IsA("MeshPart") then
		if tr:GetAttribute("OrigTextureId") == nil then
			tr:SetAttribute("OrigTextureId", tr.TextureID)
		end
		tr.TextureID = ""
		if tr:GetAttribute("OrigColor") == nil then
			tr:SetAttribute("OrigColor", tr.Color)
			tr:SetAttribute("OrigMaterial", tr.Material.Name)
		end
		tr.Color = Color3.fromRGB(86, 62, 50)
		tr.Material = Enum.Material.CorrodedMetal
	end
end

local n = 0
for _, d in DECOR:GetDescendants() do
	if d:IsA("BasePart") then
		n += 1
	end
end
return "DressMetroYard: Decor parts=" .. n
