--!strict
-- Процедурные обломки и мусор (без внешних ассетов, палитра docs/world/style_bible.md: бетон, тёмный металл, ржавчина, старое дерево, без крови и надписей).
-- Остов грузовика, шины, ящики, доски, бочки, лоскуты ткани, куски бетона и дерева, копоть на земле, дым и слабый огонь. Всё без столкновений и запросов лучей
-- (пути зомби и пули не страдают), одной Folder в Workspace. Используется на месте шатра при провале конвоя (MissionService) и на базе в ночь 19 (BaseBattleService).

local DebrisKit = {}

export type Options = {
	Radius: number,
	Chunks: number,
	Crates: number,
	Planks: number,
	Barrels: number,
	Tires: number,
	Cloth: number,
	wreck: boolean?, -- остов грузовика с дымом и огнём (по умолчанию да)
}

local COLORS = {
	concrete = Color3.fromRGB(96, 98, 102), dark = Color3.fromRGB(58, 60, 64), rust = Color3.fromRGB(92, 58, 44),
	wood = Color3.fromRGB(86, 66, 48), char = Color3.fromRGB(34, 32, 30), cloth = Color3.fromRGB(78, 82, 60), tire = Color3.fromRGB(28, 28, 30),
}
local GROUND_FOLDERS = { "Roads", "Ground", "Grass", "Base" }
local MAX_GROUND_Y = 3 -- выше — крыша или стена здания, а не земля

-- Высота земли под (x, z): только земля, дороги, трава и пол базы; нет земли (или это крыша) — nil
function DebrisKit.groundY(x: number, z: number): number?
	local include: { Instance } = {}
	for _, name in GROUND_FOLDERS do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(include, f)
		end
	end
	if #include == 0 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	local hit = workspace:Raycast(Vector3.new(x, 120, z), Vector3.new(0, -240, 0), params)
	if hit and hit.Normal.Y > 0.9 and hit.Position.Y <= MAX_GROUND_Y then
		return hit.Position.Y
	end
	return nil
end

-- Куча обломков вокруг center. seed — сид (картина повторяется), strict — детали без земли под собой пропускать (иначе сажать на высоту center).
-- Возвращает Folder (уже в Workspace).
function DebrisKit.build(name: string, center: Vector3, seed: number, R: Options, strict: boolean?): Folder
	local rng = Random.new(seed)
	local folder = Instance.new("Folder")
	folder.Name = name
	local function ground(x: number, z: number): number?
		local y = DebrisKit.groundY(x, z)
		if y then
			return y
		end
		return if strict then nil else center.Y
	end
	local function part(partName: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = partName
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material
		if shape then
			p.Shape = shape
		end
		p.Parent = folder
		return p
	end
	-- случайная точка в круге (не ближе minR от центра), посаженная на землю; низ детали на земле; nil — земли нет (strict)
	local function spot(minR: number, maxR: number, height: number, tiltMax: number): CFrame?
		local a, r = rng:NextNumber() * math.pi * 2, minR + rng:NextNumber() * (maxR - minR)
		local x, z = center.X + math.cos(a) * r, center.Z + math.sin(a) * r
		local tilt = tiltMax * (rng:NextNumber() - 0.5) * 2
		local y = ground(x, z)
		if not y then
			return nil
		end
		return CFrame.new(x, y + height / 2 - 0.1, z) * CFrame.Angles(tilt, rng:NextNumber() * math.pi * 2, tilt * 0.6)
	end
	local cy = ground(center.X, center.Z)
	if not cy then
		folder.Parent = workspace
		return folder
	end
	-- копоть: тёмное пятно на земле
	local sootCf = CFrame.new(center.X, cy + 0.12, center.Z) * CFrame.Angles(0, 0, math.rad(90))
	local soot = part("Soot", Vector3.new(0.12, R.Radius * 1.6, R.Radius * 1.6), sootCf, COLORS.char, Enum.Material.Slate, Enum.PartType.Cylinder)
	soot.Transparency = 0.25
	local hullPos = center
	local hullCf = CFrame.new(center)
	if R.wreck ~= false then
		-- остов грузовика: корпус завален на бок, кузов, кабина, колёса (часть на остове, часть откатилась), оторванная дверь
		local hullX, hullZ = center.X + (rng:NextNumber() - 0.5) * 6, center.Z + (rng:NextNumber() - 0.5) * 6
		hullPos = Vector3.new(hullX, (ground(hullX, hullZ) or cy) + 2.6, hullZ)
		hullCf = CFrame.new(hullPos) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, math.rad(78))
		part("WreckHull", Vector3.new(5.5, 4, 13), hullCf, COLORS.dark, Enum.Material.Metal)
		part("WreckBed", Vector3.new(5.2, 0.5, 8), hullCf * CFrame.new(0, 2.2, 2), COLORS.rust, Enum.Material.CorrodedMetal)
		part("WreckCab", Vector3.new(5, 3.4, 4), hullCf * CFrame.new(0.4, 0.4, -5), COLORS.char, Enum.Material.Metal)
		local door = spot(4, R.Radius * 0.8, 3, 0.25)
		if door then
			part("WreckDoor", Vector3.new(0.3, 3, 3.6), door, COLORS.rust, Enum.Material.CorrodedMetal)
		end
	end
	for k = 1, R.Tires do
		local cf: CFrame?
		if R.wreck ~= false and k <= 3 then
			cf = hullCf * CFrame.new(if k % 2 == 0 then 3 else -3, -1.2, (k - 2) * 4) * CFrame.Angles(0, 0, math.rad(90))
		else
			local c = spot(4, R.Radius, 1.6, 0.3)
			cf = if c then c * CFrame.Angles(0, 0, math.rad(90)) else nil
		end
		if cf then
			part("Tire", Vector3.new(1.4, 3, 3), cf, COLORS.tire, Enum.Material.Rubber, Enum.PartType.Cylinder)
		end
	end
	-- ящики и россыпь досок
	for _ = 1, R.Crates do
		local sz = 2 + rng:NextNumber() * 1.5
		local cf = spot(3, R.Radius, sz * 0.9, 0.35)
		if cf then
			part("Crate", Vector3.new(sz, sz * 0.9, sz), cf, COLORS.wood, Enum.Material.Wood)
		end
	end
	for _ = 1, R.Planks do
		local cf = spot(2, R.Radius, 0.2, 0.2)
		if cf then
			part("Plank", Vector3.new(0.3, 0.2, 2.5 + rng:NextNumber() * 3), cf, COLORS.wood, Enum.Material.WoodPlanks)
		end
	end
	-- бочки: цилиндр Roblox лежит по оси X; стоящая бочка — повёрнута на 90° вокруг Z, лежащая (каждая вторая) — без поворота
	for k = 1, R.Barrels do
		local cf = spot(4, R.Radius * 0.9, if k % 2 == 1 then 3 else 2.2, 0.1)
		if cf then
			if k % 2 == 1 then
				cf = cf * CFrame.Angles(0, 0, math.rad(90))
			end
			part("Barrel", Vector3.new(3, 2.2, 2.2), cf, if k % 2 == 0 then COLORS.rust else COLORS.dark, Enum.Material.Metal, Enum.PartType.Cylinder)
		end
	end
	-- лоскуты ткани
	for _ = 1, R.Cloth do
		local cf = spot(1, R.Radius * 0.9, 0.1, 0.05)
		if cf then
			part("Cloth", Vector3.new(3 + rng:NextNumber() * 3, 0.1, 2 + rng:NextNumber() * 2.5), cf, COLORS.cloth, Enum.Material.Fabric)
		end
	end
	-- куски бетона и дерева
	for _ = 1, R.Chunks do
		local size = Vector3.new(0.8 + rng:NextNumber() * 2.6, 0.5 + rng:NextNumber() * 1.5, 0.8 + rng:NextNumber() * 2.6)
		local concrete = rng:NextNumber() < 0.6
		local cf = spot(0, R.Radius, size.Y, 0.5)
		if cf then
			part("Chunk", size, cf, if concrete then COLORS.concrete else COLORS.wood, if concrete then Enum.Material.Concrete else Enum.Material.Wood)
		end
	end
	-- дым и слабый огонь над остовом
	if R.wreck ~= false then
		local smokePart = part("RubbleSmoke", Vector3.new(4, 1, 4), CFrame.new(hullPos + Vector3.new(0, 2, 0)), COLORS.char, Enum.Material.SmoothPlastic)
		smokePart.Transparency = 1
		local smoke = Instance.new("Smoke")
		smoke.Color = Color3.fromRGB(70, 70, 70)
		smoke.Size = 8
		smoke.Opacity = 0.4
		smoke.RiseVelocity = 7
		smoke.Parent = smokePart
		local fire = Instance.new("Fire")
		fire.Size = 4
		fire.Heat = 3
		fire.Parent = smokePart
	end
	folder.Parent = workspace
	return folder
end

return DebrisKit
