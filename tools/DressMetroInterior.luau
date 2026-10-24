--!strict
-- Оснащение метро, проход 2 (интерьер): вагоны, потолок зала, светильники, пол/плитка. Запуск: Studio → Edit (execute_luau)
-- ПОСЛЕ BuildMetro.luau и DressMetro.luau (DressMetro пересоздаёт Decor — этот файл надо запускать заново).
-- Идемпотентно: свои папки Decor.TrainWear / Decor.CeilingV2 / Decor.LampHousings пересоздаются, переcвет/перекраска идёт от исходных
-- значений в атрибутах OrigColor/OrigMaterial. Секции включаются в RUN (можно запускать по одной).
-- Решения (журнал осмотра docs/world/metro.spec.md §12, 2026-10-24): вагоны — грязные, ржавые; потолок — решётка балок, фаски, провисшие кабели.

local RUN = { trains = true, ceiling = true, lamps = true, floor = true, props = true }

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
