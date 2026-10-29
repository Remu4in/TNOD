--!strict
-- Ночь 19 — «бойня на военной базе» (Config.Missions[19].baseBattle, Config.BaseBattle). Мутанты прорвали базу: на ней обломки и мусор, треть солдат лежит убитыми
-- (SoldierService.setDead), а у стартовой точки игроков держат оборону 10 живых солдат: отстреливают зомби и могут погибнуть (ZombieService.registerTarget,
-- как сопровождающие конвоя). Поток зомби со стороны базы, баррикады на базе на эту ночь убраны — это делает MissionService.begin.
-- Защитники уходят в конце ночи (finish); обломки и убитые остаются до сброса раунда (reset).

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local SoldierService = require(script.Parent:WaitForChild("SoldierService"))
local DebrisKit = require(script.Parent:WaitForChild("DebrisKit"))

local BaseBattleService = {}

type Defender = { model: Model, hum: Humanoid, root: BasePart, hp: number, alive: boolean, post: Vector3, nextShot: number }

local defenders: { Defender } = {}
local folder: Folder? = nil
local debris: { Folder } = {}
local rng = Random.new()

local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "BaseDefenders"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

-- Обломки по всей базе: кучи в случайных местах Config.BaseZone на земле (крыши и стены пропускаются), несколько с остовами машин
local function buildDebris()
	local B = Config.BaseBattle
	local Z = Config.BaseZone
	local wrecks = B.Debris.Wrecks
	local seeded = Random.new(1900)
	local built = 0
	local tries = 0
	while built < B.Debris.Clusters and tries < B.Debris.Clusters * 12 do
		tries += 1
		local x = seeded:NextNumber(Z.minX + 12, Z.maxX - 12)
		local z = seeded:NextNumber(Z.minZ + 12, Z.maxZ - 12)
		local y = DebrisKit.groundY(x, z)
		if y then
			built += 1
			local f = DebrisKit.build("BaseDebris_" .. built, Vector3.new(x, y, z), 1900 + built, {
				Radius = B.Debris.Radius, Chunks = B.Debris.Chunks, Crates = B.Debris.Crates, Planks = B.Debris.Planks, Barrels = B.Debris.Barrels,
				Tires = B.Debris.Tires, Cloth = B.Debris.Cloth, wreck = built <= wrecks,
			}, true)
			table.insert(debris, f)
		end
	end
end

local function post(spawn: Vector3, i: number, count: number): Vector3
	local a = (i - 0.5) / count * math.pi * 2
	local r = Config.BaseBattle.PostRadius * (0.6 + 0.4 * ((i % 2)))
	local p = spawn + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
	local y = DebrisKit.groundY(p.X, p.Z)
	return Vector3.new(p.X, y or spawn.Y, p.Z)
end

local function buildDefender(i: number, at: Vector3): Defender?
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("NPC")
	local template = lib and lib:FindFirstChild("Soldier")
	if not template then
		return nil
	end
	local model = template:Clone() :: Model
	model.Name = "BaseDefender" .. i
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then
		model:Destroy()
		return nil
	end
	model:PivotTo(CFrame.new(at + Vector3.new(0, 3, 0)))
	SoldierService.attachLooseParts(model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CollisionGroup = "Default"
		end
	end
	local B = Config.BaseBattle
	local hp = rng:NextInteger(B.DefenderHp[1], B.DefenderHp[2])
	hum.MaxHealth = hp
	hum.Health = hp
	hum.WalkSpeed = 12
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	model.Parent = container()
	root:SetNetworkOwner(nil)
	local d: Defender = { model = model, hum = hum, root = root, hp = hp, alive = true, post = at, nextShot = 0 }
	ZombieService.registerTarget(model, root, function(amount: number)
		if not d.alive then
			return
		end
		d.hp -= amount
		hum.Health = math.max(0, d.hp)
		if d.hp <= 0 then
			d.alive = false
			ZombieService.unregisterTarget(model)
			hum.Health = 0
			Debris:AddItem(model, 6)
		end
	end)
	return d
end

local function tracer(from: Vector3, to: Vector3)
	local len = (to - from).Magnitude
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 220, 120)
	p.Size = Vector3.new(0.12, 0.12, len)
	p.CFrame = CFrame.lookAt(from + (to - from) / 2, to)
	p.Parent = container()
	Debris:AddItem(p, 0.06)
end

-- Начало ночи 19: убитые солдаты, обломки (один раз за раунд), защитники на стартовой точке игроков
function BaseBattleService.start(spawnPos: Vector3)
	BaseBattleService.finish()
	SoldierService.setDead(Config.BaseBattle.DeadFraction)
	if #debris == 0 then
		buildDebris()
	end
	local n = Config.BaseBattle.Defenders
	for i = 1, n do
		local d = buildDefender(i, post(spawnPos, i, n))
		if d then
			table.insert(defenders, d)
		end
	end
end

-- Раз в тик миссии (0,25 с): защитники стреляют по ближайшему зомби и возвращаются на свои места
function BaseBattleService.update(now: number)
	local B = Config.BaseBattle
	for _, d in defenders do
		if d.alive and d.model.Parent then
			local pos = d.root.Position
			local best: { model: Model, root: BasePart }? = nil
			local bestDist = B.DefenderRange
			for _, z in ZombieService.queryNear(pos, B.DefenderRange) do
				local dist = (z.root.Position - pos).Magnitude
				if dist < bestDist then
					best, bestDist = z, dist
				end
			end
			if best then
				-- поворот к цели и выстрел
				d.root.CFrame = CFrame.lookAt(pos, Vector3.new(best.root.Position.X, pos.Y, best.root.Position.Z))
				if now >= d.nextShot then
					d.nextShot = now + B.DefenderInterval
					local from = pos + Vector3.new(0, 1.2, 0)
					local to = best.root.Position + Vector3.new(0, 1, 0)
					tracer(from, to)
					local snd = d.root:FindFirstChild("ShotSound") :: Sound?
					if not snd then
						local created = Instance.new("Sound")
						created.Name = "ShotSound"
						created.SoundId = "rbxassetid://168436671"
						created.Volume = 0.1
						created.RollOffMaxDistance = 90
						created.Parent = d.root
						snd = created
					end
					if snd then
						snd:Play()
					end
					ZombieService.damage(best.model, B.DefenderDps * B.DefenderInterval, nil, { dir = to - from, push = 2, stagger = 0.1 })
				end
			end
			if (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(d.post.X, 0, d.post.Z)).Magnitude > 5 then
				d.hum:MoveTo(d.post)
			end
		end
	end
end

-- Сколько защитников ещё живы (для текста миссии)
function BaseBattleService.alive(): number
	local n = 0
	for _, d in defenders do
		if d.alive then
			n += 1
		end
	end
	return n
end

-- Конец ночи: защитники уходят (обломки и убитые солдаты остаются до сброса раунда)
function BaseBattleService.finish()
	for _, d in defenders do
		if d.alive then
			ZombieService.unregisterTarget(d.model)
		end
		d.model:Destroy()
	end
	table.clear(defenders)
end

-- Сброс раунда: всё возвращается — обломки убраны, солдаты встали на места
function BaseBattleService.reset()
	BaseBattleService.finish()
	for _, f in debris do
		f:Destroy()
	end
	table.clear(debris)
	SoldierService.reviveDead()
end

return BaseBattleService
