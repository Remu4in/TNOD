--!strict
-- Оборудование: колючая и электро-проволока, турель. Покупается у НПС-продавцов (VendorService), приходит предметом в руки;
-- клик ставит его на землю в точке прицела (PlaceEquipment). Урон мутантам и все проверки — только на сервере.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Validate = require(Shared:WaitForChild("Validate"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local EquipmentService = {}

type Placed = {
	kind: string,
	model: Model,
	owner: Player,
	center: Vector3,
	hits: number,
	ammo: number,
	nextAt: number,
	lastHit: { [Model]: number },
	muzzleOffset: Vector3,
}

local placed: { Placed } = {}
local folder: Folder? = nil
local rng = Random.new()

local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "Equipment"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

local function countOf(player: Player, kind: string): number
	local n = 0
	for _, p in placed do
		if p.owner == player and p.kind == kind then
			n += 1
		end
	end
	for _, c in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if c then
			for _, t in c:GetChildren() do
				if t:IsA("Tool") and t:GetAttribute("EquipKind") == kind then
					n += 1
				end
			end
		end
	end
	return n
end

-- Выдать предмет-оборудование; false — достигнут лимит
function EquipmentService.give(player: Player, kind: string): boolean
	local def = (Config.Equipment :: any)[kind]
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not def or not backpack or countOf(player, kind) >= def.max then
		return false
	end
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("EquipKind", kind)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1.4, 0.9, 1.4)
	handle.Massless = true
	handle.CanCollide = false
	handle.Material = Enum.Material.Metal
	handle.Color = if kind == "Turret" then Color3.fromRGB(80, 90, 60) elseif kind == "ElectricWire" then Color3.fromRGB(60, 140, 255) else Color3.fromRGB(70, 70, 75)
	handle.Parent = tool
	tool.Parent = backpack
	return true
end

-- Деталь-«отрезок» от точки a до точки b (мировые координаты) толщиной t
local function segment(parent: Instance, a: Vector3, b: Vector3, t: number, color: Color3, material: Enum.Material, name: string): Part
	local len = (b - a).Magnitude
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.new(t, t, math.max(len, 0.02))
	p.CFrame = CFrame.lookAt((a + b) / 2, b)
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function postPart(parent: Instance, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material, name: string): Part
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
	p.Parent = parent
	return p
end

-- Модель проволоки (визуал; хитбокс и размеры — Config.Equipment, те же): cf — основание в центре, длина вдоль X, глубина вдоль Z.
-- Колючая: спираль «егоза» из коротких отрезков (витки по дуге) на трёх деревянных кольях, по спирали — шипы.
-- Электро: три провода с провисанием на металлических столбах, изоляторы на столбах, слабые искры (ParticleEmitter) и мягкий свет.
-- Деталей: колючая ≈ 100, электро ≈ 45; пресеты — константы ниже.
local BARBED_LOOPS, BARBED_SEGMENTS = 11, 7
local function wireModel(kind: string, cf: CFrame, size: Vector3): Model
	local m = Instance.new("Model")
	m.Name = kind
	local electric = kind == "ElectricWire"
	local base = Instance.new("Part")
	base.Name = "Hitbox"
	base.Size = size
	base.CFrame = cf * CFrame.new(0, size.Y / 2, 0)
	base.Transparency = 1
	base.CanCollide = false
	base.CanQuery = false
	base.Anchored = true
	base.Parent = m
	m.PrimaryPart = base
	local L = size.X
	local function world(x: number, y: number, z: number): Vector3
		return cf:PointToWorldSpace(Vector3.new(x, y, z))
	end
	if not electric then
		local steel = Color3.fromRGB(110, 112, 116)
		local rust = Color3.fromRGB(92, 58, 44)
		-- колья
		local postH = size.Y + 0.7
		for _, x in { -L / 2, 0, L / 2 } do
			local lean = if x == 0 then 0.04 else 0
			postPart(m, cf * CFrame.new(x, postH / 2, 0) * CFrame.Angles(lean, 0, 0), Vector3.new(0.38, postH, 0.38), Color3.fromRGB(70, 52, 38), Enum.Material.Wood, "Post")
			postPart(m, cf * CFrame.new(x, postH, 0) * CFrame.Angles(0.15, 0.5, 0), Vector3.new(0.3, 0.25, 0.3), Color3.fromRGB(58, 44, 32), Enum.Material.Wood, "PostTop")
		end
		-- спираль: витки по дуге из коротких отрезков, чуть неровная
		local rng = Random.new(math.floor(cf.Position.X * 31 + cf.Position.Z * 17))
		local total = BARBED_LOOPS * BARBED_SEGMENTS
		local radius = size.Y * 0.5
		local yc = radius + 0.08
		local prev: Vector3? = nil
		for k = 0, total do
			local t = k / total
			local ang = math.pi * 2 * BARBED_LOOPS * t
			local r = radius * (0.92 + rng:NextNumber() * 0.16)
			local pos = world(-L / 2 + 0.25 + (L - 0.5) * t, yc + math.sin(ang) * r, math.cos(ang) * r * 1.3)
			if prev then
				segment(m, prev, pos, 0.09, if k % 5 == 0 then rust else steel, Enum.Material.Metal, "Coil")
				if k % 4 == 0 then
					-- шип: короткая палочка наружу от оси спирали
					local out = (pos - world(-L / 2 + 0.25 + (L - 0.5) * t, yc, 0))
					if out.Magnitude > 0.01 then
						segment(m, pos, pos + out.Unit * 0.32, 0.05, steel, Enum.Material.Metal, "Barb")
					end
				end
			end
			prev = pos
		end
		-- две прямые жилы между кольями (опора для спирали)
		for _, y in { 0.12, size.Y + 0.1 } do
			segment(m, world(-L / 2, y, 0), world(L / 2, y, 0), 0.07, steel, Enum.Material.Metal, "Strand")
		end
		return m
	end
	-- электро: тонкие металлические столбы, изоляторы, три провода с провисанием
	local pole = Color3.fromRGB(70, 74, 80)
	local glow = Color3.fromRGB(120, 190, 255)
	local postH = 2.4
	local ys = { 0.7, 1.4, 2.1 }
	for _, x in { -L / 2, 0, L / 2 } do
		postPart(m, cf * CFrame.new(x, postH / 2, 0), Vector3.new(0.26, postH, 0.26), pole, Enum.Material.Metal, "Pole")
		postPart(m, cf * CFrame.new(x, 0.1, 0), Vector3.new(0.9, 0.2, 0.9), Color3.fromRGB(58, 60, 64), Enum.Material.Concrete, "PoleBase")
		for _, y in ys do
			-- изолятор: короткий светлый цилиндр на выносной ножке
			postPart(m, cf * CFrame.new(x, y, 0.2) * CFrame.Angles(0, math.rad(90), 0), Vector3.new(0.32, 0.2, 0.2), Color3.fromRGB(200, 210, 205), Enum.Material.SmoothPlastic, "Insulator").Shape = Enum.PartType.Cylinder
		end
	end
	local sparkPart: Part? = nil
	for yi, y in ys do
		local steps = 8
		local prev: Vector3? = nil
		for k = 0, steps do
			local t = k / steps
			local sag = math.sin(t * math.pi) * 0.14 -- провисание между столбами
			local pos = world(-L / 2 + L * t, y - sag, 0.22)
			if prev then
				local s = segment(m, prev, pos, 0.07, glow, Enum.Material.Neon, "Wire")
				s.Transparency = 0.25
			end
			prev = pos
		end
		if yi == 2 then
			-- искры: слабые, из середины среднего провода
			local sp = postPart(m, cf * CFrame.new(0, y - 0.1, 0.3), Vector3.new(L * 0.5, 0.2, 0.2), glow, Enum.Material.SmoothPlastic, "Sparks")
			sp.Transparency = 1
			sparkPart = sp
		end
	end
	if sparkPart then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Sparks"
		emitter.Color = ColorSequence.new(Color3.fromRGB(190, 225, 255))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.22), NumberSequenceKeypoint.new(1, 0) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.15, 0.35)
		emitter.Speed = NumberRange.new(2, 5)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rate = 6 -- слабые, редкие искры
		emitter.Acceleration = Vector3.new(0, -8, 0)
		emitter.Shape = Enum.ParticleEmitterShape.Box
		emitter.Parent = sparkPart
	end
	local light = Instance.new("PointLight")
	light.Color = glow
	light.Range = 9
	light.Brightness = 0.9
	light.Parent = base
	return m
end

local function turretModel(cf: CFrame): (Model?, Vector3)
	local node: Instance? = ServerStorage
	for _, n in { "Assets", "Weapons", "Turrets", "Maxim1910N" } do
		node = if node then node:FindFirstChild(n) else nil
	end
	if not node or not node:IsA("Model") then
		return nil, Vector3.zero
	end
	local m = node:Clone()
	m.Name = "Turret"
	local natural = node:GetAttribute("Length")
	local k = if typeof(natural) == "number" and natural > 0 then Config.Equipment.Turret.length / natural else 1
	m:ScaleTo(k)
	m:PivotTo(cf)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
		end
	end
	local muzzleZ = ((node:GetAttribute("MuzzleZ") :: number?) or -2) * k
	local muzzleY = ((node:GetAttribute("MuzzleY") :: number?) or 1.5) * k
	return m, Vector3.new(0, muzzleY, muzzleZ)
end

local function onPlace(player: Player, position: unknown)
	if typeof(position) ~= "Vector3" or not RateLimit.allow(player, "Place", 0.3) or not PlayerService.isUp(player) then
		return
	end
	local pos = position :: Vector3
	if not Validate.finiteVector(pos, 1e5) then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local tool = char and char:FindFirstChildOfClass("Tool")
	local kind = tool and tool:GetAttribute("EquipKind")
	if not root or not tool or typeof(kind) ~= "string" then
		return
	end
	local def = (Config.Equipment :: any)[kind]
	if not def or (Vector3.new(pos.X, root.Position.Y, pos.Z) - root.Position).Magnitude > def.reach + 8 then
		return
	end
	local owned = 0
	for _, p in placed do
		if p.owner == player and p.kind == kind then
			owned += 1
		end
	end
	if owned >= def.max then
		Remotes.get("Notify"):FireClient(player, "Лимит: " .. def.name .. " " .. def.max, 2)
		return
	end
	-- точка на земле под указанным местом
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { container() }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	local zf = workspace:FindFirstChild("Zombies")
	if zf then
		table.insert(exclude, zf)
	end
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -14, 0), params)
	if not hit or math.abs(hit.Position.Y - root.Position.Y) > 8 then -- не на крышу над собой
		return
	end
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local cf = CFrame.lookAt(hit.Position, hit.Position + look)
	local model: Model
	local muzzle = Vector3.zero
	if kind == "Turret" then
		local m, off = turretModel(cf)
		if not m then
			return
		end
		model, muzzle = m, off
	else
		model = wireModel(kind, cf, def.size)
	end
	model.Parent = container()
	tool:Destroy()
	table.insert(placed, {
		kind = kind, model = model, owner = player, center = hit.Position, hits = def.hits or 0,
		ammo = def.ammo or 0, nextAt = 0, lastHit = {}, muzzleOffset = muzzle,
	})
end

local function remove(p: Placed)
	p.model:Destroy()
	local i = table.find(placed, p)
	if i then
		table.remove(placed, i)
	end
end

local function insideWire(p: Placed, z: { model: Model, root: BasePart }, size: Vector3): boolean
	local hitbox = p.model.PrimaryPart
	if not hitbox then
		return false
	end
	local rel = hitbox.CFrame:PointToObjectSpace(z.root.Position)
	return math.abs(rel.X) <= size.X / 2 + 1 and math.abs(rel.Z) <= size.Z / 2 + 1.6 and math.abs(rel.Y) <= 6
end

local function stepTurret(p: Placed, now: number)
	local def = Config.Equipment.Turret
	if now < p.nextAt then
		return
	end
	local pivot = p.model:GetPivot()
	local muzzle = pivot:PointToWorldSpace(p.muzzleOffset)
	local best: { model: Model, root: BasePart }? = nil
	local bestDist = math.huge
	for _, z in ZombieService.queryNear(p.center, def.range) do
		local d = (z.root.Position - p.center).Magnitude
		if d < bestDist then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { p.model }
			local r = workspace:Raycast(muzzle, z.root.Position + Vector3.new(0, 1, 0) - muzzle, params)
			if not r or r.Instance:IsDescendantOf(z.model) then
				best, bestDist = z, d
			end
		end
	end
	if not best then
		p.nextAt = now + 0.3
		return
	end
	local target = best.root.Position
	p.model:PivotTo(CFrame.lookAt(pivot.Position, Vector3.new(target.X, pivot.Position.Y, target.Z)))
	local dir = target - muzzle
	ZombieService.damage(best.model, def.damage, p.owner, { dir = dir, push = 6, stagger = 0.2 })
	-- трассер
	local tracer = Instance.new("Part")
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 220, 120)
	tracer.Size = Vector3.new(0.15, 0.15, dir.Magnitude)
	tracer.CFrame = CFrame.lookAt(muzzle + dir / 2, muzzle + dir)
	tracer.Parent = container()
	Debris:AddItem(tracer, 0.08)
	p.ammo -= 1
	p.nextAt = now + rng:NextNumber(def.minCooldown, def.maxCooldown)
	if p.ammo <= 0 then
		p.nextAt = math.huge
		task.delay(1, function()
			remove(p)
		end)
	end
end

local function step(now: number)
	for i = #placed, 1, -1 do
		local p = placed[i]
		if not p.model.Parent then
			table.remove(placed, i)
		elseif p.kind == "Turret" then
			stepTurret(p, now)
		else
			local def = (Config.Equipment :: any)[p.kind]
			for _, z in ZombieService.queryNear(p.center, def.size.X) do
				local last = p.lastHit[z.model]
				if (not last or now - last >= def.tick) and insideWire(p, z, def.size) then
					p.lastHit[z.model] = now
					local impact = if p.kind == "ElectricWire" then { stagger = def.stun, push = 0 } else { stagger = 0.35, push = 0 }
					ZombieService.damage(z.model, def.damage, p.owner, impact)
					if p.kind == "BarbedWire" then
						p.hits -= 1
						if p.hits <= 0 then
							remove(p)
							break
						end
					end
				end
			end
		end
	end
end

-- Новый раунд: всё оборудование убирается
function EquipmentService.clearAll()
	for i = #placed, 1, -1 do
		placed[i].model:Destroy()
		table.remove(placed, i)
	end
end

-- Рассвет: электро-проволока обесточена и пропадает
function EquipmentService.onDay()
	for i = #placed, 1, -1 do
		if placed[i].kind == "ElectricWire" then
			placed[i].model:Destroy()
			table.remove(placed, i)
		end
	end
end

function EquipmentService.init()
	Remotes.get("PlaceEquipment").OnServerEvent:Connect(onPlace)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			step(os.clock())
		end
	end)
end

return EquipmentService
