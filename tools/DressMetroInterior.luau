--!strict
-- Оснащение метро, проход 2 (интерьер): вагоны, потолок зала, светильники, пол/плитка. Запуск: Studio → Edit (execute_luau)
-- ПОСЛЕ BuildMetro.luau и DressMetro.luau (DressMetro пересоздаёт Decor — этот файл надо запускать заново).
-- Идемпотентно: свои папки Decor.TrainWear / Decor.CeilingV2 / Decor.LampHousings пересоздаются, переcвет/перекраска идёт от исходных
-- значений в атрибутах OrigColor/OrigMaterial. Секции включаются в RUN (можно запускать по одной).
-- Решения (журнал осмотра docs/world/metro.spec.md §12, 2026-10-24): вагоны — грязные, ржавые; потолок — решётка балок, фаски, провисшие кабели.

local RUN = { trains = true, ceiling = true, lamps = true, floor = true, props = true, tunnels = true, hall = true }

local OY = 600
local V = Vector3.new
local ROOT = workspace:FindFirstChild("Metro")
assert(ROOT, "сначала tools/BuildMetro.luau")
local DECOR = ROOT:FindFirstChild("Decor")
assert(DECOR, "сначала tools/DressMetro.luau")
local Props = ROOT:WaitForChild("Props")

local DARK = Color3.fromRGB(48, 50, 54)
local RUST = Color3.fromRGB(92, 58, 44)

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

-- потемнение и «грязь»: цвет от исходного (OrigColor), чтобы повторный запуск не темнил дальше
local function grime(c: Color3, k: number, rustMix: number): Color3
	local h, s, v = c:ToHSV()
	local base = Color3.fromHSV(h, s * 0.55, v * k)
	return base:Lerp(Color3.fromRGB(78, 62, 50), rustMix)
end

local function restyle(p: BasePart, k: number, rustMix: number)
	if p:GetAttribute("OrigColor") == nil then
		p:SetAttribute("OrigColor", p.Color)
		p:SetAttribute("OrigMaterial", p.Material.Name)
	end
	local orig = p:GetAttribute("OrigColor") :: Color3
	local mat = Enum.Material[p:GetAttribute("OrigMaterial") :: string]
	if mat == Enum.Material.Neon then
		-- светящиеся «двери» и полосы вагона: тусклый корпус, не лампа
		p.Material = Enum.Material.SmoothPlastic
		p.Color = grime(orig, 0.35, 0.3)
	else
		p.Color = grime(orig, k, rustMix)
	end
end

------------------------------------------------------------------------------------------------ вагоны
if RUN.trains then
	local wear = fresh("TrainWear")
	local rng = Random.new(77)
	local rustColors = { Color3.fromRGB(92, 58, 44), Color3.fromRGB(72, 48, 38), Color3.fromRGB(56, 44, 38) }
	for _, car in Props:GetChildren() do
		if car.Name:find("^Train%d_[AB]$") or car.Name == "Train1_Full" then
			local parts = if car:IsA("BasePart") then { car } else car:GetDescendants()
			for _, d in parts do
				if d:IsA("Decal") or d:IsA("Texture") then
					if d.Parent and not d.Parent:IsA("MeshPart") then
						d:Destroy() -- мемные наклейки из исходного ассета
					end
				elseif d:IsA("BasePart") then
					restyle(d, 0.5, 0.22)
				end
			end
			-- ржавые потёки на бортах (по ориентации вагона)
			local cf, size
			if car:IsA("Model") then
				cf, size = car:GetBoundingBox()
			else
				cf, size = (car :: BasePart).CFrame, (car :: BasePart).Size
			end
			local long = if size.X > size.Z then "X" else "Z"
			local len = if long == "X" then size.X else size.Z
			local wid = if long == "X" then size.Z else size.X
			for i = 1, 14 do
				local along = rng:NextNumber(-len / 2 + 2, len / 2 - 2)
				local side = if rng:NextNumber() > 0.5 then 1 else -1
				local w, h = rng:NextNumber(0.8, 3.2), rng:NextNumber(0.8, 3)
				local y = rng:NextNumber(-size.Y / 2 + 2.2, size.Y / 2 - 3)
				local local3 = if long == "X" then V(along, y, side * (wid / 2 + 0.03)) else V(side * (wid / 2 + 0.03), y, along)
				local rot = if long == "X" then CFrame.new() else CFrame.Angles(0, math.rad(90), 0)
				box(wear, "Rust", V(w, h, 0.06), cf * CFrame.new(local3) * rot, rustColors[rng:NextInteger(1, 3)], Enum.Material.CorrodedMetal, { Transparency = rng:NextNumber(0.05, 0.3) })
			end
		end
	end
end

------------------------------------------------------------------------------------------------ потолок зала (R1)
if RUN.ceiling then
	local f = fresh("CeilingV2")
	local rng = Random.new(91)
	local CONC = Color3.fromRGB(64, 65, 68)
	-- фаски в углах потолка вдоль длинных стен: убирают «коробку»
	for _, z in { -36.3, 36.3 } do
		box(f, "Cove", V(316, 2.4, 2.4), CFrame.new(0, OY + 12.0, z) * CFrame.Angles(math.rad(45), 0, 0), CONC, Enum.Material.Concrete)
	end
	-- продольные балки над путями: вместе с поперечными образуют сетку кессонов
	for _, z in { -24, 0, 24 } do
		box(f, "Girder", V(316, 0.9, 1.2), CFrame.new(0, OY + 12.45, z), Color3.fromRGB(70, 70, 74), Enum.Material.Concrete)
	end
	-- нижние полки поперечных балок (ржавый двутавр) и подвеска
	for x = -140, 140, 20 do
		box(f, "BeamFlange", V(3, 0.25, 78), CFrame.new(x, OY + 11.55, 0), Color3.fromRGB(78, 56, 46), Enum.Material.Metal)
	end
	-- потёки и сырость на нижней грани перекрытия
	for _ = 1, 36 do
		local x, z = rng:NextNumber(-150, 150), rng:NextNumber(-36, 36)
		box(f, "Stain", V(rng:NextNumber(5, 14), 0.05, rng:NextNumber(4, 12)), CFrame.new(x, OY + 12.96, z), Color3.fromRGB(34, 33, 30), Enum.Material.Concrete, { Transparency = rng:NextNumber(0.3, 0.6) })
	end
	-- провисшие кабели вместо чёрных палок
	local old = DECOR:FindFirstChild("Utilities")
	if old then
		for _, c in old:GetChildren() do
			if c.Name == "HangingCable" then
				c:Destroy()
			end
		end
	end
	local function cable(x0: number, x1: number, z: number, sag: number, color: Color3)
		local n = 6
		local prev = V(x0, OY + 11.8, z)
		for i = 1, n do
			local t = i / n
			local nxt = V(x0 + (x1 - x0) * t, OY + 11.8 - 4 * sag * t * (1 - t), z)
			local mid = (prev + nxt) / 2
			local len = (nxt - prev).Magnitude
			box(f, "Cable", V(0.22, 0.22, len), CFrame.lookAt(mid, nxt), color, Enum.Material.SmoothPlastic)
			prev = nxt
		end
	end
	for _, z in { -30, -12, 12, 30 } do
		for _ = 1, 9 do
			local x0 = -140 + 20 * rng:NextInteger(0, 13)
			local span = 20 * rng:NextInteger(1, 2)
			local col = if rng:NextNumber() > 0.8 then Color3.fromRGB(64, 26, 24) else Color3.fromRGB(24, 24, 26)
			cable(x0, math.min(x0 + span, 150), z + rng:NextNumber(-0.8, 0.8), rng:NextNumber(0.8, 1.8), col)
		end
		-- оборванный конец, свисает вниз
		local dx = rng:NextNumber(-140, 140)
		box(f, "CableEnd", V(0.2, 3.5, 0.2), CFrame.new(dx, OY + 10, z + 0.6), Color3.fromRGB(24, 24, 26), Enum.Material.SmoothPlastic)
	end
end

------------------------------------------------------------------------------------------------ светильники зала: корпус и каркас
if RUN.lamps then
	local f = fresh("LampHousings")
	local lights = ROOT:FindFirstChild("Lights")
	if lights then
		for _, l in lights:GetChildren() do
			if l.Name == "Lamp" and l:IsA("BasePart") and math.abs(l.Position.Y - (OY + 12.3)) < 0.5 then
				local on = l.Material == Enum.Material.Neon
				local cf = CFrame.new(l.Position)
				box(f, "Housing", V(3.2, 0.3, 1.8), cf * CFrame.new(0, 0.4, 0), Color3.fromRGB(46, 47, 50), Enum.Material.Metal)
				for _, s in { -0.85, 0.85 } do
					box(f, "Rail", V(3.2, 0.14, 0.14), cf * CFrame.new(0, -0.15, s), Color3.fromRGB(58, 52, 48), Enum.Material.Metal)
				end
				for _, s in { -1.55, 1.55 } do
					box(f, "Cap", V(0.14, 0.5, 1.8), cf * CFrame.new(s, 0.1, 0), Color3.fromRGB(58, 52, 48), Enum.Material.Metal)
				end
				if on then
					l.Color = Color3.fromRGB(205, 220, 245)
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------ пол и плитка: мрамор → керамическая плитка
if RUN.floor then
	local TILE = Enum.Material.CeramicTiles
	local walls = DECOR:FindFirstChild("Walls")
	if walls then
		for _, d in walls:GetChildren() do
			if d:IsA("BasePart") and (d.Name == "TileBand" or d.Name == "PillarBase") then
				if d:GetAttribute("OrigColor") == nil then
					d:SetAttribute("OrigColor", d.Color)
				end
				d.Material = TILE
				d.Color = grime(d:GetAttribute("OrigColor") :: Color3, 0.72, 0.1)
			end
		end
	end
	local plats = ROOT:FindFirstChild("Platform")
	if plats then
		for _, d in plats:GetChildren() do
			if d:IsA("BasePart") and d.Name:find("^Platform%d") and d.Material == Enum.Material.Marble then
				if d:GetAttribute("OrigColor") == nil then
					d:SetAttribute("OrigColor", d.Color)
				end
				d.Material = TILE
				d.Color = grime(d:GetAttribute("OrigColor") :: Color3, 0.75, 0.1)
			end
		end
	end
	-- полы билетного и служебного залов (Shell) и платформы станции B
	for _, folderName in { "Shell", "StationB" } do
		local fld = ROOT:FindFirstChild(folderName)
		if fld then
			for _, d in fld:GetChildren() do
				if d:IsA("BasePart") and d.Material == Enum.Material.Marble then
					if d:GetAttribute("OrigColor") == nil then
						d:SetAttribute("OrigColor", d.Color)
					end
					d.Material = TILE
					d.Color = grime(d:GetAttribute("OrigColor") :: Color3, 0.75, 0.1)
				end
			end
		end
	end
	local floorTiles = DECOR:FindFirstChild("FloorTiles")
	if floorTiles then
		for _, d in floorTiles:GetChildren() do
			if d:IsA("BasePart") and d.Material == Enum.Material.Marble then
				d.Material = TILE
			end
		end
	end
end

------------------------------------------------------------------------------------------------ автоматы и турникеты: без надписей и брендов, грязнее
-- билетные автоматы (надпись «Tickets» и логотип) и торговые автоматы (реклама реальных брендов): Decal удаляем (SB §7: надписей нет)
if RUN.props then
	local function dirty(m: Instance, stripDecals: boolean)
		for _, d in m:GetDescendants() do
			if stripDecals and (d:IsA("Decal") or d:IsA("Texture") or d:IsA("SurfaceGui")) then
				d:Destroy()
			elseif d:IsA("BasePart") then
				restyle(d, 0.5, 0.2)
			end
		end
	end
	for _, n in { "TicketMachine_1", "TicketMachine_2" } do
		local m = Props:FindFirstChild(n)
		if m then
			dirty(m, true)
		end
	end
	local ts = Props:FindFirstChild("Turnstiles_Hall")
	if ts then
		dirty(ts, false)
	end
	local furniture = DECOR:FindFirstChild("Furniture")
	if furniture then
		for _, m in furniture:GetChildren() do
			if m.Name == "TicketMachine" or m.Name == "VendingDecor" then
				dirty(m, true)
			end
		end
	end
end

------------------------------------------------------------------------------------------------ общее для P2: провисший кабель и «свободные» места
local function sagCable(parent: Instance, a: Vector3, b: Vector3, sag: number, color: Color3)
	local n = 6
	local prev = a
	for i = 1, n do
		local t = i / n
		local nxt = a:Lerp(b, t) - V(0, 4 * sag * t * (1 - t), 0)
		box(parent, "Cable", V(0.22, 0.22, (nxt - prev).Magnitude), CFrame.lookAt((prev + nxt) / 2, nxt), color, Enum.Material.SmoothPlastic)
		prev = nxt
	end
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
local LINES_P2 = { -24, 0, 24 }
local STATION_HALF, TUNNEL = 160, 480

------------------------------------------------------------------------------------------------ тоннели (A006): обделка, пятна, кабели, мусор, аварийный свет
-- ничего из добавленного не мешает проходу: без коллизии, мусор — по краям (4…6,2 студа от оси), вокруг маркеров 7 студов свободно
if RUN.tunnels then
	local f = fresh("TunnelsV2")
	local rng = Random.new(133)
	local CONC = Color3.fromRGB(70, 70, 72)
	local function tunnel(x0: number, x1: number, zt: number)
		local len = x1 - x0
		for _, s in { -1, 1 } do
			box(f, "Cove", V(len, 2.2, 2.2), CFrame.new((x0 + x1) / 2, OY + 7.5, zt + s * 7.0) * CFrame.Angles(math.rad(45), 0, 0), CONC, Enum.Material.Concrete)
		end
		for x = x0 + 7, x1 - 7, 14 do
			for _, s in { -1, 1 } do
				box(f, "RingRib", V(0.9, 10, 0.7), CFrame.new(x, OY + 2.5, zt + s * 6.65), CONC, Enum.Material.Concrete)
			end
			box(f, "RingRib", V(0.9, 0.6, 13.4), CFrame.new(x, OY + 7.2, zt), CONC, Enum.Material.Concrete)
		end
		for x = x0 + 20, x1 - 20, 35 do
			local s = if rng:NextNumber() > 0.5 then 1 else -1
			box(f, "Stain", V(0.05, rng:NextNumber(3, 6), rng:NextNumber(4, 9)), CFrame.new(x + rng:NextNumber(-8, 8), OY + rng:NextNumber(2, 4), zt + s * 6.95) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(30, 30, 28), Enum.Material.Concrete, { Transparency = rng:NextNumber(0.3, 0.55) })
		end
		for x = x0 + 14, x1 - 42, 28 do
			if rng:NextNumber() > 0.5 then
				local dz = rng:NextNumber(-3, 3)
				local col = if rng:NextNumber() > 0.75 then Color3.fromRGB(64, 26, 24) else Color3.fromRGB(24, 24, 26)
				sagCable(f, V(x, OY + 7.2, zt + dz), V(x + 28, OY + 7.2, zt + dz), rng:NextNumber(1, 2), col)
			end
		end
		for x = x0 + 25, x1 - 25, 32 do
			if rng:NextNumber() > 0.35 then
				local s = if rng:NextNumber() > 0.5 then 1 else -1
				local px, pz = x + rng:NextNumber(-6, 6), zt + s * rng:NextNumber(4.2, 6.2)
				if freeSpot(px, pz, 7) then
					local kind = rng:NextInteger(1, 4)
					local yaw = CFrame.Angles(0, math.rad(rng:NextInteger(0, 180)), 0)
					if kind == 1 then
						for i = 1, 3 do
							box(f, "GarbageBag", V(1.6, 1.1, 1.4), CFrame.new(px + i * 1.1 - 2, OY - 1.95, pz + (i % 2) * 0.8) * yaw, Color3.fromRGB(26, 26, 28), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
						end
					elseif kind == 2 then
						box(f, "Plank", V(4.5, 0.25, 0.6), CFrame.new(px, OY - 2.2, pz) * yaw, Color3.fromRGB(70, 54, 40), Enum.Material.Wood)
						box(f, "Plank", V(3.6, 0.25, 0.6), CFrame.new(px + 0.5, OY - 2.0, pz + 0.7) * yaw * CFrame.Angles(0, math.rad(40), math.rad(8)), Color3.fromRGB(60, 48, 36), Enum.Material.Wood)
					elseif kind == 3 then
						box(f, "TippedBarrel", V(2.2, 1.6, 1.6), CFrame.new(px, OY - 1.7, pz) * yaw, Color3.fromRGB(88, 54, 40), Enum.Material.CorrodedMetal, { Shape = Enum.PartType.Cylinder })
					else
						box(f, "FloorPipe", V(6, 0.7, 0.7), CFrame.new(px, OY - 2.15, pz) * yaw, Color3.fromRGB(80, 82, 84), Enum.Material.CorrodedMetal, { Shape = Enum.PartType.Cylinder })
					end
				end
			end
		end
	end
	for _, zt in LINES_P2 do
		tunnel(-STATION_HALF - TUNNEL + 3, -STATION_HALF - 3, zt)
	end
	tunnel(STATION_HALF + 3, STATION_HALF + TUNNEL - 3, -24)
	tunnel(STATION_HALF + 3, STATION_HALF + TUNNEL - 3, 24)
	tunnel(STATION_HALF + 3, STATION_HALF + TUNNEL - 3, 0)
	-- аварийные лампы тоннелей: корпус-каркас, красный корпус лампы
	local lights = ROOT:FindFirstChild("Lights")
	if lights then
		for _, l in lights:GetChildren() do
			if l.Name == "Lamp" and l:IsA("BasePart") and math.abs(l.Position.Y - (OY + 7.2)) < 0.5 then
				box(f, "Housing", V(2.6, 0.3, 1.4), CFrame.new(l.Position) * CFrame.new(0, 0.4, 0), Color3.fromRGB(46, 47, 50), Enum.Material.Metal)
				for _, s in { -0.6, 0.6 } do
					box(f, "Rail", V(2.6, 0.14, 0.14), CFrame.new(l.Position) * CFrame.new(0, -0.15, s), Color3.fromRGB(58, 52, 48), Enum.Material.Metal)
				end
				if l.Material == Enum.Material.Neon then
					l.Color = Color3.fromRGB(255, 90, 70)
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------ билетный зал R2: плитка стен, колонны, балки, свет, мусор, знак выхода
if RUN.hall then
	local f = fresh("HallV2")
	local rng = Random.new(144)
	local TILE = Enum.Material.CeramicTiles
	local TILE_COLOR = Color3.fromRGB(104, 104, 100)
	local function band(cx: number, cz: number, sx: number, sz: number)
		box(f, "TileBand", V(sx, 3.2, sz), CFrame.new(cx, OY + 14.6, cz), TILE_COLOR, TILE)
		box(f, "TileTrim", V(if sx < 1 then 0.4 else sx, 0.4, if sz < 1 then 0.4 else sz), CFrame.new(cx, OY + 16.4, cz), RUST, Enum.Material.Metal)
	end
	band(76.9, 83, 0.3, 56)
	band(135.1, 83, 0.3, 56)
	band(106, 110.1, 58.5, 0.3)
	band(86.9, 56.4, 20.2, 0.3)
	band(125.1, 56.4, 20.25, 0.3)
	-- колонны (с коллизией) и перекрытие над ними
	for _, p in { { 88, 62 }, { 124, 62 }, { 88, 96 } } do
		box(f, "Pillar", V(1.6, 16.7, 1.6), CFrame.new(p[1], OY + 21.35, p[2]), Color3.fromRGB(96, 98, 102), Enum.Material.Concrete, { CanCollide = true, CanQuery = true })
		box(f, "PillarBase", V(2.6, 2.4, 2.6), CFrame.new(p[1], OY + 14.2, p[2]), TILE_COLOR, TILE, { CanCollide = true, CanQuery = true })
		box(f, "PillarTrim", V(2.2, 0.4, 2.2), CFrame.new(p[1], OY + 15.6, p[2]), RUST, Enum.Material.Metal)
	end
	for _, x in { 86, 106, 126 } do
		box(f, "Beam", V(1.4, 1.4, 57), CFrame.new(x, OY + 29.05, 83), Color3.fromRGB(78, 80, 84), Enum.Material.Concrete)
		box(f, "BeamFlange", V(3, 0.25, 57), CFrame.new(x, OY + 28.3, 83), Color3.fromRGB(78, 56, 46), Enum.Material.Metal)
	end
	box(f, "Girder", V(59, 0.9, 1.2), CFrame.new(106, OY + 29.3, 83), Color3.fromRGB(70, 70, 74), Enum.Material.Concrete)
	for _, z in { 55.75, 110.25 } do
		box(f, "Cove", V(58.5, 2.2, 2.2), CFrame.new(106, OY + 29.75, z) * CFrame.Angles(math.rad(45), 0, 0), Color3.fromRGB(64, 65, 68), Enum.Material.Concrete)
	end
	for _, x in { 76.75, 135.25 } do
		box(f, "Cove", V(2.2, 2.2, 54.5), CFrame.new(x, OY + 29.75, 83) * CFrame.Angles(0, 0, math.rad(45)), Color3.fromRGB(64, 65, 68), Enum.Material.Concrete)
	end
	for _, z in { 62, 104 } do
		box(f, "Pipe", V(58, 0.9, 0.9), CFrame.new(106, OY + 27.6, z), Color3.fromRGB(88, 90, 94), Enum.Material.Metal, { Shape = Enum.PartType.Cylinder })
	end
	for _ = 1, 6 do
		local x0 = 80 + rng:NextInteger(0, 2) * 20
		local z = rng:NextNumber(60, 106)
		sagCable(f, V(x0, OY + 28.0, z), V(x0 + 20, OY + 28.0, z), rng:NextNumber(0.8, 1.6), Color3.fromRGB(24, 24, 26))
	end
	-- свет: 4 новые лампы в корпусах (две горят), как в зале станции
	for _, p in { { 90, 70, true }, { 122, 70, false }, { 90, 98, false }, { 122, 98, true } } do
		local cf = CFrame.new(p[1], OY + 28.6, p[2])
		box(f, "Housing", V(3.2, 0.3, 1.8), cf * CFrame.new(0, 0.4, 0), Color3.fromRGB(46, 47, 50), Enum.Material.Metal)
		for _, s in { -0.85, 0.85 } do
			box(f, "Rail", V(3.2, 0.14, 0.14), cf * CFrame.new(0, -0.15, s), Color3.fromRGB(58, 52, 48), Enum.Material.Metal)
		end
		local lamp = box(f, "Lamp", V(2, 0.4, 0.8), cf, if p[3] then Color3.fromRGB(205, 220, 245) else Color3.fromRGB(80, 80, 84), if p[3] then Enum.Material.Neon else Enum.Material.SmoothPlastic)
		if p[3] then
			local l = Instance.new("PointLight")
			l.Color = Color3.fromRGB(190, 210, 255)
			l.Brightness = 0.9
			l.Range = 26
			l.Parent = lamp
		end
	end
	-- мусор и ящики у стен
	for _, p in { { 79, 60 }, { 79, 75 }, { 80, 92 }, { 84, 108 }, { 120, 108 }, { 133, 60 }, { 133, 72 }, { 98, 108 } } do
		if freeSpot(p[1], p[2], 8) then
			local yaw = CFrame.Angles(0, math.rad(rng:NextInteger(0, 180)), 0)
			if rng:NextNumber() > 0.5 then
				box(f, "Crate", V(2.6, 2.6, 2.6), CFrame.new(p[1], OY + 14.3, p[2]) * yaw, Color3.fromRGB(80, 64, 46), Enum.Material.Wood, { CanCollide = true, CanQuery = true })
				box(f, "Crate", V(2.4, 2.4, 2.4), CFrame.new(p[1] + 0.3, OY + 16.8, p[2]) * CFrame.Angles(0, math.rad(rng:NextInteger(0, 40)), math.rad(rng:NextInteger(-6, 6))), Color3.fromRGB(70, 56, 40), Enum.Material.Wood)
			else
				for i = 1, 3 do
					box(f, "GarbageBag", V(1.6, 1.1, 1.4), CFrame.new(p[1] + i * 1.1 - 2, OY + 13.55, p[2] + (i % 2) * 0.8) * yaw, Color3.fromRGB(26, 26, 28), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
				end
			end
		end
	end
	-- знак выхода на восточной стене: зелёная плита, белая стрелка вверх (без текста) и красная аварийная лампа
	box(f, "ExitPlate", V(0.2, 2.6, 6), CFrame.new(135.0, OY + 22, 98), Color3.fromRGB(22, 84, 50), Enum.Material.SmoothPlastic)
	box(f, "ArrowShaft", V(0.15, 1.5, 0.4), CFrame.new(134.85, OY + 21.6, 98), Color3.fromRGB(215, 215, 205), Enum.Material.SmoothPlastic)
	for _, s in { -1, 1 } do
		box(f, "ArrowHead", V(0.15, 0.4, 1.0), CFrame.new(134.85, OY + 22.5, 98 + s * 0.3) * CFrame.Angles(math.rad(s * 45), 0, 0), Color3.fromRGB(215, 215, 205), Enum.Material.SmoothPlastic)
	end
	local red = box(f, "EmergencyLamp", V(0.6, 0.6, 0.6), CFrame.new(134.6, OY + 24.8, 98), Color3.fromRGB(255, 90, 70), Enum.Material.Neon, { Shape = Enum.PartType.Ball })
	local rl = Instance.new("PointLight")
	rl.Color = Color3.fromRGB(255, 70, 50)
	rl.Brightness = 0.8
	rl.Range = 18
	rl.Parent = red
end
