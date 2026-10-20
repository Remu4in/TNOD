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
	-- витки проволоки
	for i = 1, 3 do
		local coil = Instance.new("Part")
		coil.Size = Vector3.new(size.X, 0.18, 0.18)
		coil.Material = if electric then Enum.Material.Neon else Enum.Material.Metal
		coil.Color = if electric then Color3.fromRGB(90, 170, 255) else Color3.fromRGB(95, 95, 100)
		coil.CFrame = cf * CFrame.new(0, 0.3 + i * (size.Y / 4), (i - 2) * 0.7) * CFrame.Angles(math.rad(i * 25), 0, 0)
		coil.Anchored = true
		coil.CanCollide = false
		coil.CanQuery = false
		coil.Parent = m
	end
	for _, x in { -size.X / 2, size.X / 2 } do
		local post = Instance.new("Part")
		post.Size = Vector3.new(0.4, size.Y + 0.8, 0.4)
		post.Color = Color3.fromRGB(60, 45, 35)
		post.Material = Enum.Material.Wood
		post.CFrame = cf * CFrame.new(x, (size.Y + 0.8) / 2, 0)
		post.Anchored = true
		post.CanCollide = false
		post.CanQuery = false
		post.Parent = m
	end
	if electric then
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(90, 170, 255)
		light.Range = 10
		light.Brightness = 1.5
		light.Parent = base
	end
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
	if pos.X ~= pos.X or pos.Z ~= pos.Z or math.abs(pos.X) > 1e5 or math.abs(pos.Z) > 1e5 or math.abs(pos.Y) > 1e4 then
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
	if not hit then
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
