--!strict
-- Зомби: очередь спавна, пул моделей, единый цикл ИИ для всех (без скрипта в каждом зомби),
-- урон по зомби только через ZombieService.damage на сервере.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local BarricadeService = require(script.Parent:WaitForChild("BarricadeService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local BossAI = require(script.Parent:WaitForChild("BossAI"))

local ZombieService = {}

type State = "ToWindow" | "Breaking" | "Entering" | "Hunt"

type Zombie = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	head: BasePart,
	def: Config.ZombieDef,
	hp: number,
	maxHp: number,
	speed: number, -- скорость этой волны (def.speed с ростом по волнам, WaveMath.speedOf)
	state: State,
	window: Types.Window?,
	lastAttack: number,
	lastPos: Vector3,
	stuckTime: number,
	alive: boolean,
	gen: number, -- номер «жизни» из пула: отсеивает устаревшие результаты поиска пути
	waypoints: { PathWaypoint }?,
	wpIdx: number,
	pathGoal: Vector3,
	pathAt: number,
	pathBusy: boolean,
	pathFailed: boolean, -- последний расчёт пути не нашёл маршрут (цель за баррикадой)
	staggerUntil: number, -- до этого момента зомби «вздрогнул» от попадания и стоит
	windupUntil: number, -- 0 — не замахивается; иначе момент удара (замах: стоит, руки подняты, глаза светлеют)
	windupTarget: Player?,
	welds: { [string]: JointInstance }, -- детали тела на Weld (меши) или Motor6D (риг): сервер двигает C0 при замахе, ударе и реакции на попадание
	rest: { [string]: CFrame }, -- их положение в покое
	slowUntil: number, -- до этого момента зомби хромает (попали в ногу)
	vaultResetAt: number, -- не раньше этого момента зомби снова может перелезать забор
	vaultLockUntil: number, -- до этого момента зомби в прыжке через забор и не думает
	headKill: boolean, -- убит выстрелом в голову (бонус очков и монет в RoundService)
	pivots: { [string]: Vector3 }, -- точки вращения частей тела (шея, плечи, бёдра) в системе корня
	hipPivot: Vector3, -- ось, вокруг которой корпус откидывается от попадания
	armRaise: number, -- угол поднятых рук при замахе, градусов
	armStrike: number, -- угол руки в ударе
	eyes: { BasePart },
	rig: boolean, -- настоящий риг R15 (Humanoid + Animator), а не меши на сварке
	tracks: { [string]: AnimationTrack },
	animIds: { [string]: string },
	nextSpecial: number, -- когда снова можно бросить колбу / телепортироваться
	throwing: boolean, -- замах — бросок колбы, а не удар -- анимации рига: idle, walk
	animName: string, -- какая анимация сейчас играет
	animSpeed: number, -- скорость шага, при которой анимация ходьбы идёт 1:1
	poseGen: number, -- растёт при сбросе позы (resetAttack, release): отложенные возвраты поз прошлой жизни не срабатывают
	jointTweens: { [string]: Tween }, -- активный твин каждого сустава (замах, удар, реакция на попадание)
	vaultTween: Tween?, -- активный твин корня при перелезании забора
	bossAct: BossAct?, -- идущая атака босса (прыжок или бросок): босс стоит и не думает, ИИ ведёт stepBossAct
	nextJump: number, -- когда босс снова может прыгнуть
	nextRock: number, -- когда босс снова может бросить обломок
	phase2: boolean, -- финальный босс во второй фазе: только способности, неуязвим к огнестрелу (принимает лишь удары Impact.melee)
	nextAtk: { [string]: number }, -- когда можно снова каждую атаку из def.attacks (BossAI): slam, crawlers, charge, swing
}

-- Атака босса. kind: "jump" (прыжок на игрока) | "rock" (бросок обломка). Фазы: jump — "charge" (3 с, на земле под игроком красная зона) → "air" → посадка;
-- rock — "rip" (отрывает кусок земли) → бросок (зона падения красным кругом, пока летит) → готово. zone — части красной зоны на земле.
type BossAct = {
	kind: string,
	phase: string,
	endAt: number, -- конец фазы
	target: Player,
	aim: Vector3, -- где зона (центр на земле)
	zone: { Part },
	rock: Part?,
	locked: boolean, -- зона больше не следует за игроком
	data: any?, -- состояние атак BossAI (линия растений, ползун на спине, дорожка разбега)
}

local map: Types.MapInfo
local active: { [Model]: Zombie } = {}
local pool: { [string]: { Zombie } } = {}
local queue: { string } = {}
local hpMultiplier = 1
local waveNumber = 1
local damageMultiplier = 1
local hazardGen = 0 -- растёт на clearAll и рассвете: колбы и лужи прошлой ночи перестают бить
local streamMode = false -- бесконечный поток миссии: очередь не пустеет, потерявшихся переносим без ожидания конца волны
local storage: Folder
local container: Folder
local onKilled: ((player: Player?, zombie: Zombie) -> ())? = nil

local COLLISION_GROUP = "Zombies"

-- Поиск пути: не больше PATH_BUDGET новых расчётов за такт ИИ, маршрут обновляется раз в PATH_REFRESH секунд
local PATH_BUDGET = 8
local PATH_REFRESH = 1.5
local PATH_GOAL_DRIFT = 8
local pathBudget = 0

-- Лучи по миру без зомби (перелезание, колба): фильтр задаётся в init, когда создана папка зомби
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
-- Лучи без зомби и без персонажа цели (прямая видимость, телепорт тёмного): по одному на персонажа, слабые ключи
local targetParams: { [Instance]: RaycastParams } = setmetatable({}, { __mode = "k" }) :: any

local function paramsExcluding(char: Instance): RaycastParams
	local params = targetParams[char]
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { container, char }
		targetParams[char] = params
	end
	return params
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

-- Шаблоны мешей частей тела (AssetService грузит меш по сети: один раз, с ожиданием, как у оружия)
local meshTemplates: { [string]: MeshPart } = {}
local meshState: { [string]: string } = {} -- "loading" | "ok" | "failed"

local function loadMesh(meshId: string): MeshPart?
	if not meshState[meshId] then
		meshState[meshId] = "loading"
		local ok, result = pcall(function()
			-- коллизия «коробкой»: попадания по частям тела дёшевы и предсказуемы (CollisionFidelity у готовой части менять нельзя)
			return AssetService:CreateMeshPartAsync(Content.fromUri(meshId), { CollisionFidelity = Enum.CollisionFidelity.Box })
		end)
		if ok then
			meshTemplates[meshId] = result
			meshState[meshId] = "ok"
		else
			warn("[ZombieService] не удалось загрузить меш " .. meshId .. ": " .. tostring(result))
			meshState[meshId] = "failed"
		end
	end
	while meshState[meshId] == "loading" do
		task.wait(0.05)
	end
	return meshTemplates[meshId]
end

-- Humanoid, коллизии и группа столкновений: общая часть для модели из мешей и запасной модели из блоков
local function finishModel(model: Model, def: Config.ZombieDef, root: BasePart, hipHeight: number): Model
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = hipHeight
	humanoid.WalkSpeed = def.speed
	humanoid.JumpHeight = 3 -- (прыжок у блочных зомби не срабатывает, перелезание заборов — в think)
	humanoid.RigType = Enum.HumanoidRigType.R15 -- высота по HipHeight, без суставов ног
	humanoid.MaxHealth = 1e6 -- HP зомби считаем сами
	humanoid.Health = 1e6
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.Parent = model

	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = COLLISION_GROUP
		end
	end
	return model
end

-- Все части тела на Weld (а не WeldConstraint): сервер двигает C0 при замахе, ударе и реакции на попадание, и это
-- видно всем. Имя сварки — "W_" .. имя части (Head, Torso, LeftArm, RightArm, LeftLeg, RightLeg)
local function weldBody(root: BasePart, p: BasePart)
	local w = Instance.new("Weld")
	w.Name = "W_" .. p.Name
	w.Part0 = root
	w.Part1 = p
	w.C0 = root.CFrame:ToObjectSpace(p.CFrame)
	w.Parent = root
end

-- Модель из сгенерированных мешей (Config.ZombieVisuals): корень-невидимка (хитбокс и физика) + части тела
-- Меш из шаблона: размер, текстура и (если заданы) цвет с материалом. BaseColor — цвет «в покое» для подсветки замаха.
local function makePiece(template: MeshPart, name: string, vp: { mesh: string, texture: string, size: Vector3, pos: Vector3, color: Color3?, material: string? }): MeshPart
	local p = template:Clone()
	p.Name = name
	p.Size = vp.size
	p.TextureID = vp.texture
	p.Color = vp.color or Color3.new(1, 1, 1)
	p:SetAttribute("BaseColor", p.Color)
	if vp.material then
		p.Material = (Enum.Material :: any)[vp.material]
	end
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Anchored = false
	p.CFrame = CFrame.new(vp.pos)
	return p
end

local function buildMeshModel(def: Config.ZombieDef, vis: Config.ZombieVisual, templates: { [string]: MeshPart }): Model
	local s = def.scale
	local model = Instance.new("Model")
	model.Name = "Zombie_" .. def.id
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1) * s
	root.Transparency = 1
	root.CanCollide = true
	root.CFrame = CFrame.new()
	root.Parent = model
	-- Видимые меши в рейкастах не участвуют: их коробки перекрывают друг друга (у громилы голова внутри коробки торса,
	-- и выстрелы в голову засчитывались в корпус). Попадания принимают отдельные невидимые хитбоксы "Hit<Часть>"
	-- по каждой части тела; они сварены с мешем и двигаются вместе с ним при замахе и реакции на попадание.
	for _, vp in vis.parts do
		local p = makePiece(templates[vp.mesh], vp.part, vp)
		p.Parent = model
		weldBody(root, p)
		-- остальные меши части (предплечье, кисть, голень, стопа, таз) держатся за основной
		for _, ex in vp.extra or {} do
			local e = makePiece(templates[ex.mesh], vp.part .. "Extra", ex)
			e.Parent = model
			weld(p, e)
		end

		local hit = Instance.new("Part")
		hit.Name = "Hit" .. vp.part
		hit.Size = vp.hitSize
		hit.Transparency = 1
		hit.CanCollide = false
		hit.CanTouch = false
		hit.Massless = true
		hit.CFrame = CFrame.new(vp.hitPos)
		hit.Parent = model
		weld(p, hit)
	end
	root.CanQuery = false -- попадания принимают хитбоксы частей, а не корень
	-- таз на высоте vis.pelvis над стопами; центр корня = низ корня + половина высоты
	return finishModel(model, def, root, vis.pelvis - 1 * s)
end

-- Запасная модель из блоков (если меши не загрузились)
local function buildBlockModel(def: Config.ZombieDef): Model
	local s = def.scale
	local model = Instance.new("Model")
	model.Name = "Zombie_" .. def.id

	local function mk(name: string, size: Vector3, offset: Vector3, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size * s
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.Massless = true
		p.CFrame = CFrame.new(offset * s)
		p.Parent = model
		return p
	end

	local root = mk("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0), def.color)
	root.Transparency = 1
	root.CanCollide = true
	root.Massless = false
	local torso = mk("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0), Color3.fromRGB(80, 70, 90))
	local head = mk("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0), def.color)
	local armL = mk("LeftArm", Vector3.new(0.8, 0.8, 2), Vector3.new(-1.3, 0.6, -0.9), def.color)
	local armR = mk("RightArm", Vector3.new(0.8, 0.8, 2), Vector3.new(1.3, 0.6, -0.9), def.color)
	local legL = mk("LeftLeg", Vector3.new(0.9, 2, 0.9), Vector3.new(-0.5, -2, 0), Color3.fromRGB(60, 55, 70))
	local legR = mk("RightLeg", Vector3.new(0.9, 2, 0.9), Vector3.new(0.5, -2, 0), Color3.fromRGB(60, 55, 70))
	for _, p in { torso, head, armL, armR, legL, legR } do
		weldBody(root, p)
	end
	-- светящиеся глаза
	for _, x in { -0.25, 0.25 } do
		local eye = mk("Eye", Vector3.new(0.2, 0.2, 0.1), Vector3.new(x, 1.75, -0.62), Color3.fromRGB(255, 60, 40))
		eye.Material = Enum.Material.Neon
		weld(root, eye)
	end
	return finishModel(model, def, root, 3 * s - 1 * s)
end

-- Украшения боссов (B_Buff, B_Garg) лежат внутри невидимых деталей тела (Torso.Model.…) и ничем не сварены: у B_Buff они падали на землю и
-- лежали там, а невидимое тело бегало отдельно; у B_Garg были заякорены и висели на месте. Привариваем каждую несваренную деталь
-- к ближайшей родительской детали (к конечности) в том виде, как они стоят в шаблоне; на физику, столкновения и пули они не влияют.
-- Если родительской детали нет (конус, ведро, нож лежат прямо в модели), берётся ближайшая сваренная часть тела (голова, рука).
local function weldLooseParts(model: Model)
	local welded: { [Instance]: boolean } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("WeldConstraint") then
			if d.Part0 then
				welded[d.Part0] = true
			end
			if d.Part1 then
				welded[d.Part1] = true
			end
		elseif d:IsA("JointInstance") then
			if d.Part0 then
				welded[d.Part0] = true
			end
			if d.Part1 then
				welded[d.Part1] = true
			end
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not welded[d] and d.Name ~= "HumanoidRootPart" then
			local parent: Instance? = d.Parent
			while parent and not parent:IsA("BasePart") do
				parent = parent.Parent
			end
			if not parent then
				-- украшение лежит прямо в модели (конус и ведро, нож Качка, Handle аксессуара): крепим к ближайшей сваренной части тела
				local bestDist = math.huge
				for part in welded do
					if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part ~= d and part:IsDescendantOf(model) then
						local dist = (part.Position - d.Position).Magnitude
						if dist < bestDist then
							parent, bestDist = part, dist
						end
					end
				end
			end
			if parent and parent:IsA("BasePart") then
				local w = Instance.new("WeldConstraint")
				w.Part0 = parent
				w.Part1 = d
				w.Parent = d
				d.Anchored = false
				d.Massless = true
				d.CanCollide = false
				d.CanQuery = false -- попадания принимают части тела (Head, Torso…), а не украшения
			end
		end
	end
end

-- Колени. У Качка нога составная: внутри R6-ноги лежат декоративные UpperLeg / LowerLeg / Foot (на сварках). Нижняя часть (голень, стопа и всё ниже колена)
-- получает сустав Motor6D «Knee<Side>» в ноге, чтобы присед (crouchPose) мог согнуть ногу в колене. Без составной ноги колен нет (присед — только бёдра и корпус).
-- ThighLen — длина бедра в студах: от неё зависит, насколько опускается корпус.
local function addKnees(model: Model)
	for _, side in { "Left", "Right" } do
		local leg = model:FindFirstChild(side .. " Leg") :: BasePart?
		if not leg then
			continue
		end
		local upper: BasePart? = nil
		local lower: BasePart? = nil
		for _, d in leg:GetDescendants() do
			if d:IsA("BasePart") then
				if d.Name:find("UpperLeg") then
					upper = d
				elseif d.Name:find("LowerLeg") then
					lower = d
				end
			end
		end
		model:SetAttribute("ThighLen", if upper then upper.Size.Y else leg.Size.Y)
		if not upper or not lower then
			continue
		end
		local kneeY = math.clamp((upper.Position.Y - upper.Size.Y / 2 + lower.Position.Y + lower.Size.Y / 2) / 2, lower.Position.Y, upper.Position.Y)
		local kneeCf = CFrame.new(lower.Position.X, kneeY, lower.Position.Z)
		local group: { BasePart } = {}
		for _, d in leg:GetDescendants() do
			if d:IsA("BasePart") and d ~= upper and d ~= lower and d.Position.Y < kneeY then
				table.insert(group, d)
			end
		end
		-- голень: вместо сварки с ногой — сустав в колене
		for _, c in lower:GetChildren() do
			if c:IsA("WeldConstraint") then
				c:Destroy()
			end
		end
		local knee = Instance.new("Motor6D")
		knee.Name = "Knee" .. side
		knee.Part0 = leg
		knee.Part1 = lower
		knee.C0 = leg.CFrame:ToObjectSpace(kneeCf)
		knee.C1 = lower.CFrame:ToObjectSpace(kneeCf)
		knee.Parent = leg
		-- стопа, шарниры и прочее ниже колена теперь держатся за голень (сохраняют положение)
		for _, d in group do
			for _, c in d:GetChildren() do
				if c:IsA("WeldConstraint") then
					c.Part0 = lower
				end
			end
		end
	end
end

-- Части тела рига R6, принимающие попадания (partKind): им CanQuery включаем принудительно
local RIG_HIT_PARTS: { [string]: boolean } = {
	Head = true, Torso = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
	UpperTorso = true, LowerTorso = true, LeftUpperArm = true, RightUpperArm = true, LeftLowerArm = true, RightLowerArm = true, LeftHand = true, RightHand = true,
	LeftUpperLeg = true, RightUpperLeg = true, LeftLowerLeg = true, RightLowerLeg = true, LeftFoot = true, RightFoot = true,
}

-- Риг R6 из библиотеки ServerStorage.Assets.Zombies (Config.ZombieRigs): случайная модель из пула типа, живой Humanoid, суставы Motor6D.
-- Попадания принимают сами части тела (Head, Torso, руки, ноги); корень-невидимка попаданий не принимает.
local function buildRigModel(def: Config.ZombieDef, rigDef: Config.ZombieRig): Model?
	local lib = ServerStorage:FindFirstChild("Assets")
	local folder = lib and lib:FindFirstChild("Zombies")
	if not folder then
		return nil
	end
	local candidates = {}
	for _, name in rigDef.pool do
		local m = folder:FindFirstChild(name)
		if m and m:IsA("Model") then
			table.insert(candidates, m)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local src = candidates[math.random(1, #candidates)]
	local model = src:Clone()
	model.Name = "Zombie_" .. def.id
	model:ScaleTo(if rigDef.absolute then rigDef.scale else rigDef.scale * def.scale)
	weldLooseParts(model)
	addKnees(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.WalkSpeed = def.speed
	humanoid.JumpHeight = 3
	humanoid.MaxHealth = 1e6 -- HP зомби считаем сами
	humanoid.Health = 1e6
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	root.Transparency = 1
	root.CanQuery = false -- иначе корень перехватывает пули, летящие в корпус
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = COLLISION_GROUP
			d.Anchored = false
			d.CanTouch = false
			if d.Parent == model and RIG_HIT_PARTS[d.Name] then
				d.CanQuery = true -- у B_Garg в шаблоне Head с CanQuery = false: пули шли сквозь голову и урон по голове не засчитывался
			end
			if d.Name == "Handle" then
				d.CanCollide = false -- аксессуары не мешают
			end
			d:SetAttribute("BaseColor", d.Color) -- цвет «в покое» для подсветки замаха
			d:SetAttribute("BaseTransparency", d.Transparency) -- прозрачность «в покое»: тени финального босса возвращаются к ней при повторном использовании модели
			if rigDef.tint and d.Name ~= "HumanoidRootPart" and d.Name ~= "Handle" then
				d.Color = rigDef.tint
				d:SetAttribute("BaseColor", rigDef.tint)
			end
		end
	end
	if rigDef.crawl then
		-- ползун: корпус наклонён вперёд почти до горизонтали и опущен к земле (поворот в системе корня, до чтения суставов)
		for _, d in model:GetDescendants() do
			if d:IsA("Motor6D") and d.Part0 == root and d.Part1 and d.Part1.Name == "Torso" then
				d.C0 = CFrame.new(0, -1.5 * model:GetScale(), 0) * CFrame.Angles(math.rad(-80), 0, 0) * d.C0
			end
		end
	end
	model:SetAttribute("Rig", true)
	model:SetAttribute("RigAsset", src.Name) -- по нему Config.ZombieRigHp уменьшает здоровье зомби в конусе и в ведре
	return model
end

local function buildModel(def: Config.ZombieDef): Model
	if Config.UseRigZombies then
		local rigDef = Config.ZombieRigs[def.id]
		if rigDef then
			local rigModel = buildRigModel(def, rigDef)
			if rigModel then
				return rigModel
			end
			warn("[ZombieService] нет моделей из пула в ServerStorage.Assets.Zombies — зомби " .. def.id .. " собран из мешей")
		end
	end
	local vis = Config.ZombieVisuals[def.id]
	if vis then
		local templates: { [string]: MeshPart } = {}
		local complete = true
		local function need(meshId: string)
			local t = loadMesh(meshId)
			if t then
				templates[meshId] = t
			else
				complete = false
			end
		end
		for _, vp in vis.parts do
			need(vp.mesh)
			for _, ex in vp.extra or {} do
				need(ex.mesh)
			end
		end
		if complete then
			return buildMeshModel(def, vis, templates)
		end
	end
	return buildBlockModel(def)
end

-- id анимаций модели: атрибуты Anim_<роль> (из ассета), иначе стандартные R6 (Config.ZombieAnimDefaults)
local function resolveAnimIds(model: Model, rigDef: Config.ZombieRig): { [string]: string }
	local function pick(role: string): string
		local own = model:GetAttribute("Anim_" .. role)
		return if type(own) == "string" and own ~= "" then own else Config.ZombieAnimDefaults[role]
	end
	return {
		idle = pick("idle"),
		walk = pick(if rigDef.useRun then "run" else "walk"),
	}
end

-- Анимации рига: проигрываются на сервере через Animator (видны всем). Анимация, к которой у плейса нет доступа
-- (длина так и остаётся 0), заменяется стандартной R6.
local function loadTracks(model: Model, ids: { [string]: string }): { [string]: AnimationTrack }
	local tracks: { [string]: AnimationTrack } = {}
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator
	local function make(name: string, id: string): AnimationTrack?
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. id
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if not ok then
			warn("[ZombieService] не загрузилась анимация " .. name .. " " .. id .. ": " .. tostring(track))
			return nil
		end
		track.Looped = true
		track.Priority = if name == "idle" then Enum.AnimationPriority.Idle else Enum.AnimationPriority.Movement
		return track
	end
	for name, id in ids do
		local track = make(name, id)
		if track then
			tracks[name] = track
			local default = Config.ZombieAnimDefaults[if name == "idle" then "idle" else "walk"]
			if id ~= default then
				task.delay(4, function()
					if track.Length == 0 and tracks[name] == track then
						warn("[ZombieService] анимация " .. id .. " недоступна, заменена стандартной")
						local wasPlaying = track.IsPlaying
						track:Stop(0)
						local fallback = make(name, default)
						if fallback then
							tracks[name] = fallback
							if wasPlaying then
								fallback:Play(0.2)
							end
						end
					end
				end)
			end
		end
	end
	return tracks
end

local function acquire(typeId: string): Zombie
	local list = pool[typeId]
	if list and #list > 0 then
		return table.remove(list) :: Zombie
	end
	local def = Config.Zombies[typeId]
	local model = buildModel(def)
	local isRig = model:GetAttribute("Rig") == true
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local welds: { [string]: JointInstance } = {}
	local rest: { [string]: CFrame } = {}
	if isRig then
		-- сустав каждой части находим по тому, какую деталь он держит (имена у ассетов разные: RootJoint / Root Hip)
		local limbs = { Torso = "Torso", Head = "Head", LeftArm = "Left Arm", RightArm = "Right Arm", LeftLeg = "Left Leg", RightLeg = "Right Leg" }
		if model:FindFirstChild("LowerTorso") then
			-- настоящий R15 (финальный босс): «корпус» — корневой сустав HumanoidRootPart → LowerTorso (наклон и присед несут всё тело), руки и ноги — плечи и бёдра
			limbs = { Torso = "LowerTorso", Head = "Head", LeftArm = "LeftUpperArm", RightArm = "RightUpperArm", LeftLeg = "LeftUpperLeg", RightLeg = "RightUpperLeg" }
		end
		for name, partName in limbs do
			local found: Motor6D? = nil
			for _, d in model:GetDescendants() do
				if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == partName and d.Part0 and (partName ~= "Torso" or d.Part0 == root) then
					found = d
					break
				end
			end
			local j = found :: Motor6D
			welds[name] = j
			rest[name] = j.C0
		end
	else
		for _, name in { "Torso", "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg" } do
			local w = root:FindFirstChild("W_" .. name) :: Weld
			welds[name] = w
			rest[name] = w.C0
		end
	end
	if isRig then
		for _, side in { "Left", "Right" } do
			local knee = model:FindFirstChild("Knee" .. side, true) or model:FindFirstChild(side .. "Knee", true) -- KneeLeft — составная нога Качка, LeftKnee — колено R15
			if knee and knee:IsA("Motor6D") then
				welds[side .. "Knee"] = knee
				rest[side .. "Knee"] = knee.C0
			end
		end
	end
	local eyes: { BasePart } = {}
	for _, d in model:GetChildren() do
		if d.Name == "Eye" and d:IsA("BasePart") then
			table.insert(eyes, d)
		end
	end
	-- точки вращения и углы замаха зависят от вида модели: у мешей руки висят вниз, у блоков — вытянуты вперёд
	local isMesh = not isRig and (model:FindFirstChild("Torso") :: Instance):IsA("MeshPart")
	local s = def.scale
	local pivots: { [string]: Vector3 } = {}
	local hipPivot = Vector3.new(0, -0.9 * s, 0)
	if isRig then
		for name, w in welds do
			pivots[name] = rest[name].Position
		end
		pivots.Torso += Vector3.new(0, -1, 0) -- корпус наклоняется от пояса (RootJoint стоит в центре торса)
		hipPivot = pivots.Torso
	elseif isMesh then
		for _, vp in (Config.ZombieVisuals[typeId] :: Config.ZombieVisual).parts do
			pivots[vp.part] = vp.pivot
		end
		hipPivot = Vector3.new(0, -0.3, 0)
	else
		pivots = {
			Head = Vector3.new(0, 1.0 * s, 0),
			LeftArm = Vector3.new(-1.3 * s, 0.6 * s, 0),
			RightArm = Vector3.new(1.3 * s, 0.6 * s, 0),
			LeftLeg = Vector3.new(-0.5 * s, -1 * s, 0),
			RightLeg = Vector3.new(0.5 * s, -1 * s, 0),
			Torso = Vector3.zero,
		}
	end
	return {
		model = model,
		humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid,
		root = model:FindFirstChild("HumanoidRootPart") :: BasePart,
		head = model:FindFirstChild("Head") :: BasePart,
		def = def,
		hp = 0,
		maxHp = 0,
		state = "ToWindow",
		window = nil,
		lastAttack = 0,
		lastPos = Vector3.zero,
		stuckTime = 0,
		alive = false,
		gen = 0,
		waypoints = nil,
		wpIdx = 1,
		pathGoal = Vector3.zero,
		pathAt = 0,
		pathBusy = false,
		pathFailed = false,
		staggerUntil = 0,
		windupUntil = 0,
		windupTarget = nil,
		welds = welds,
		rest = rest,
		pivots = pivots,
		hipPivot = hipPivot,
		armRaise = if isRig then 100 elseif isMesh then 140 else 75,
		armStrike = if isRig then 35 elseif isMesh then 50 else -25,
		rig = isRig,
		speed = def.speed,
		tracks = {}, -- анимации грузим при первом выходе в мир (Animator должен быть в Workspace)
		animName = "",
		animSpeed = if isRig then Config.ZombieRigs[def.id].animSpeed else 1,
		nextSpecial = 0,
		throwing = false,
		animIds = if isRig then resolveAnimIds(model, Config.ZombieRigs[def.id]) else {},
		slowUntil = 0,
		vaultResetAt = 0,
		vaultLockUntil = 0,
		headKill = false,
		eyes = eyes,
		poseGen = 0,
		jointTweens = {},
		vaultTween = nil,
		bossAct = nil,
		nextJump = 0,
		nextRock = 0,
		nextAtk = {},
		phase2 = false,
	}
end

local function requestPath(z: Zombie, goal: Vector3, now: number)
	z.pathBusy = true
	z.pathGoal = goal
	z.pathAt = now
	pathBudget -= 1
	local gen = z.gen
	local from = z.root.Position
	local scale = z.def.scale
	task.spawn(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = math.max(2, 1.5 * scale),
			AgentHeight = 5,
			AgentCanJump = false, -- зомби не прыгают через заборы переулков (высота 4,4 > их прыжок 3)
			WaypointSpacing = 8,
		})
		local ok = pcall(function()
			path:ComputeAsync(from, goal)
		end)
		if z.gen == gen then
			if ok and path.Status == Enum.PathStatus.Success then
				z.waypoints = path:GetWaypoints()
				z.wpIdx = 2
				z.pathFailed = false
			else
				z.waypoints = nil
				z.pathFailed = true
			end
			z.pathBusy = false
		end
	end)
end

-- Идём к цели по маршруту (обходя дома и машины); вблизи или без маршрута — напрямик.
local function goTo(z: Zombie, goal: Vector3, now: number)
	local pos = z.root.Position
	local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z).Magnitude
	if flat < 8 then
		z.waypoints = nil
		z.humanoid:MoveTo(goal)
		return
	end
	if not z.pathBusy and pathBudget > 0 and (z.waypoints == nil or now - z.pathAt > PATH_REFRESH or (goal - z.pathGoal).Magnitude > PATH_GOAL_DRIFT) then
		requestPath(z, goal, now)
	end
	local wps = z.waypoints
	if wps then
		local wp = wps[z.wpIdx]
		while wp and Vector3.new(wp.Position.X - pos.X, 0, wp.Position.Z - pos.Z).Magnitude < 3 do
			z.wpIdx += 1
			wp = wps[z.wpIdx]
		end
		if wp then
			if wp.Action == Enum.PathWaypointAction.Jump then
				z.humanoid.Jump = true
			end
			z.humanoid:MoveTo(wp.Position)
			return
		end
		z.waypoints = nil
	end
	z.humanoid:MoveTo(goal)
end

-- Атака: замах (стоит с поднятыми руками, глаза светлеют) → удар. За время замаха можно отойти за радиус удара
-- или перекатиться (кувырок неуязвим): тогда удар «в пустоту». Между ударами — длинная пауза attackCooldown.
local EYE_NORMAL = Color3.fromRGB(255, 60, 40)
local EYE_ALERT = Color3.fromRGB(255, 240, 160)

-- Один активный твин на сустав: новый отменяет прежний, сброс позы (cancelPose) — все
local function tweenJoint(z: Zombie, name: string, info: TweenInfo, c0: CFrame)
	local old = z.jointTweens[name]
	if old then
		old:Cancel()
	end
	local tween = TweenService:Create(z.welds[name], info, { C0 = c0 })
	z.jointTweens[name] = tween
	tween:Play()
end

-- Сброс позы (смерть, пул, новая жизнь): твины суставов и перелезания не доигрывают на следующем зомби из пула
local endBossAct: (Zombie) -> () -- задаётся ниже вместе с атаками босса

local function cancelPose(z: Zombie)
	endBossAct(z)
	z.poseGen += 1
	for _, tween in z.jointTweens do
		tween:Cancel()
	end
	table.clear(z.jointTweens)
	local vault = z.vaultTween
	if vault then
		z.vaultTween = nil
		vault:Cancel()
	end
	z.root.Anchored = false
end

-- deg: 0 — руки в покое; иначе поворот рук вокруг плеч на столько градусов (положительный — вперёд и вверх)
local function armPose(z: Zombie, deg: number, time: number)
	for _, name in { "LeftArm", "RightArm" } do
		local pivot = CFrame.new(z.pivots[name])
		local target = if deg == 0 then z.rest[name] else pivot * CFrame.Angles(math.rad(deg), 0, 0) * pivot:Inverse() * z.rest[name]
		tweenJoint(z, name, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), target)
	end
end

-- Присед рига: amount 0 — стоит, 1 — полный. Корпус опускается и наклоняется вперёд, бёдра идут вперёд, колени сгибаются назад (если у босса есть
-- колени, иначе только бёдра и корпус). Бёдра компенсируют наклон корпуса, иначе ноги уезжают назад вместе с ним.
local function crouchPose(z: Zombie, amount: number, time: number)
	if not z.rig then
		return
	end
	local info = TweenInfo.new(time, Enum.EasingStyle.Quad, if amount > 0 then Enum.EasingDirection.Out else Enum.EasingDirection.InOut)
	local knees = z.welds.LeftKnee ~= nil
	local thighNet = math.rad(if knees then 55 else 30) * amount -- на сколько бедро идёт вперёд от вертикали
	local lean = math.rad(25) * amount -- наклон корпуса вперёд
	local thigh = (z.model:GetAttribute("ThighLen") :: number?) or 3
	local drop = thigh * (1 - math.cos(thighNet)) * (if knees then 1 else 0.7) + 0.4 * amount
	local waist = CFrame.new(z.pivots.Torso)
	tweenJoint(z, "Torso", info, CFrame.new(0, -drop, 0) * waist * CFrame.fromAxisAngle(Vector3.new(-1, 0, 0), lean) * waist:Inverse() * z.rest.Torso)
	for _, side in { "Left", "Right" } do
		tweenJoint(z, side .. "Leg", info, z.rest[side .. "Leg"] * CFrame.Angles(thighNet + lean, 0, 0))
		if knees then
			tweenJoint(z, side .. "Knee", info, z.rest[side .. "Knee"] * CFrame.Angles(-thighNet * 1.2, 0, 0))
		end
	end
end

-- Знак замаха: у блочных зомби светлеют глаза, у модельных зомби — тело слегка краснеет (подсветка попавшего в замах)
local TINT_ALERT = Color3.fromRGB(255, 150, 130)
local function setEyes(z: Zombie, alert: boolean)
	if #z.eyes > 0 then
		for _, eye in z.eyes do
			eye.Color = if alert then EYE_ALERT else EYE_NORMAL
		end
	else
		for _, d in z.model:GetChildren() do
			if d:IsA("MeshPart") then
				d.Color = if alert then TINT_ALERT else (d:GetAttribute("BaseColor") or Color3.new(1, 1, 1))
			end
		end
	end
end

-- Колба химика: летит по дуге к месту, где стоял игрок; в точке падения — взрыв яда и лужа
local function flaskBurst(def: Config.ZombieDef, landing: Vector3)
	local fl = def.flask :: { range: number, minRange: number, cooldown: number, damage: number, tick: number, radius: number }
	local hit = workspace:Raycast(landing + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), worldParams)
	local ground = if hit then hit.Position else landing
	local puddle = Instance.new("Part")
	puddle.Name = "PoisonPuddle"
	puddle.Shape = Enum.PartType.Cylinder
	puddle.Size = Vector3.new(0.25, fl.radius * 2, fl.radius * 2)
	puddle.CFrame = CFrame.new(ground + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
	puddle.Anchored = true
	puddle.CanCollide = false
	puddle.CanQuery = false
	puddle.CanTouch = false
	puddle.Material = Enum.Material.Neon
	puddle.Color = Color3.fromRGB(110, 220, 70)
	puddle.Transparency = 0.45
	puddle.Parent = workspace
	local gen = hazardGen
	local function strike(amount: number)
		for _, p in PlayerService.upPlayers() do
			local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r and (r.Position - ground).Magnitude <= fl.radius then
				PlayerService.damage(p, amount)
			end
		end
	end
	strike(fl.damage * damageMultiplier)
	task.spawn(function()
		for _ = 1, 6 do
			task.wait(0.5)
			if hazardGen ~= gen then
				break -- рассвет или конец раунда: лужа высыхает сразу
			end
			strike(fl.tick)
		end
		puddle:Destroy()
	end)
end

local function launchFlask(z: Zombie, target: Player)
	local char = target.Character
	local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not r then
		return
	end
	local origin = z.head.Position + Vector3.new(0, 0.5, 0)
	local landing = r.Position
	local dist = (landing - origin).Magnitude
	local t = math.clamp(dist / 45, 0.5, 1.3)
	local gravity = Vector3.new(0, -workspace.Gravity, 0)
	local flask = Instance.new("Part")
	flask.Name = "Flask"
	flask.Shape = Enum.PartType.Ball
	flask.Size = Vector3.new(1.2, 1.2, 1.2)
	flask.Material = Enum.Material.Neon
	flask.Color = Color3.fromRGB(110, 220, 70)
	flask.CanCollide = false
	flask.CanQuery = false
	flask.CanTouch = false
	flask.Position = origin
	flask.Parent = workspace
	flask.AssemblyLinearVelocity = (landing - origin) / t - 0.5 * gravity * t
	local def = z.def
	local gen = hazardGen
	task.delay(t, function()
		flask:Destroy()
		if hazardGen == gen then
			flaskBurst(def, landing)
		end
	end)
end

local function resetAttack(z: Zombie)
	z.throwing = false
	z.nextSpecial = 0
	z.windupUntil = 0
	z.windupTarget = nil
	cancelPose(z)
	for name, w in z.welds do
		w.C0 = z.rest[name]
	end
	z.slowUntil = 0
	z.vaultResetAt = 0
	z.vaultLockUntil = 0
	z.headKill = false
	setEyes(z, false)
end

local function cancelWindup(z: Zombie)
	z.throwing = false
	z.windupUntil = 0
	z.windupTarget = nil
	armPose(z, 0, 0.2)
	setEyes(z, false)
end

-- Дружественные цели-НПС (конвой, солдаты): зомби атакуют их наравне с игроками. damage — функция урона цели.
type NpcTarget = { root: BasePart, damage: (amount: number) -> () }
local npcTargets: { [Model]: NpcTarget } = {}
local npcWindup: { [Zombie]: Model } = {}

function ZombieService.registerTarget(model: Model, root: BasePart, damage: (amount: number) -> ())
	npcTargets[model] = { root = root, damage = damage }
end

function ZombieService.unregisterTarget(model: Model)
	npcTargets[model] = nil
end

-- Цели на такт ИИ: живые игроки и цели-НПС собираются один раз за такт (collectTargets), а не для каждого зомби
local tickPlayers: { Player } = {}
local tickPlayerRoots: { BasePart } = {}
local tickNpcModels: { Model } = {}
local tickNpcRoots: { BasePart } = {}

local function collectTargets()
	table.clear(tickPlayers)
	table.clear(tickPlayerRoots)
	table.clear(tickNpcModels)
	table.clear(tickNpcRoots)
	for _, p in Players:GetPlayers() do
		if PlayerService.isUp(p) then
			local char = p.Character
			local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r then
				table.insert(tickPlayers, p)
				table.insert(tickPlayerRoots, r)
			end
		end
	end
	for model, t in npcTargets do
		if t.root.Parent then
			table.insert(tickNpcModels, model)
			table.insert(tickNpcRoots, t.root)
		end
	end
end

local function nearestNpc(pos: Vector3): (Model?, BasePart?, number)
	local best: Model? = nil
	local bestRoot: BasePart? = nil
	local bestDist = math.huge
	for i, root in tickNpcRoots do
		local model = tickNpcModels[i]
		if npcTargets[model] and root.Parent then
			local d = (root.Position - pos).Magnitude
			if d < bestDist then
				best, bestRoot, bestDist = model, root, d
			end
		end
	end
	return best, bestRoot, bestDist
end

local function startWindup(z: Zombie, player: Player?, now: number)
	npcWindup[z] = nil
	z.windupUntil = now + z.def.windup
	z.windupTarget = player
	armPose(z, z.armRaise, z.def.windup * 0.85)
	setEyes(z, true)
end

local function finishStrike(z: Zombie, now: number)
	local target = z.windupTarget
	local throwing = z.throwing
	z.throwing = false
	z.windupUntil = 0
	z.windupTarget = nil
	z.lastAttack = now + math.random() * 0.6 -- небольшой разброс, чтобы стая не била залпом в один такт
	local npcModel = npcWindup[z]
	npcWindup[z] = nil
	armPose(z, z.armStrike, 0.08)
	z.model:SetAttribute("SwingAt", os.clock()) -- клиент по этому звучит ударом (SfxController)
	local poseGen = z.poseGen
	task.delay(0.3, function()
		if z.alive and z.poseGen == poseGen then
			armPose(z, 0, 0.25)
		end
	end)
	setEyes(z, false)
	if npcModel then
		local t = npcTargets[npcModel]
		local reachNpc = (3.5 * z.def.scale + 1.5) * 1.25 + 3
		if t and t.root.Parent and (t.root.Position - z.root.Position).Magnitude <= reachNpc + t.root.Size.Magnitude * 0.25 then
			t.damage(z.def.damage * damageMultiplier)
		end
		return
	end
	if throwing then
		if target and PlayerService.isUp(target) then
			launchFlask(z, target)
		end
		return
	end
	-- удар достаёт, только если игрок всё ещё рядом (отошёл — промах) и не в кувырке (PlayerService.damage)
	if target and PlayerService.isUp(target) then
		local char = target.Character
		local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local reach = (3.5 * z.def.scale + 1.5) * 1.25
		if r and (r.Position - z.root.Position).Magnitude <= reach then
			PlayerService.damage(target, z.def.damage * damageMultiplier)
		end
	end
end

-- Реакция на попадание: часть тела, в которую попали, дёргается (корпус откидывается от выстрела, голова запрокидывается,
-- рука отлетает, нога подгибается). kind: "Head" | "Torso" | "Arm" | "Leg"; power — сила удара (0,5..2).
-- Вид части тела по имени: хитбоксы мешей называются Hit<Часть>; у рига R6 — Head/Torso/Left Arm…
local function kindByName(raw: string): string?
	local name = string.gsub(raw, "^Hit", "")
	if name == "Head" then
		return "Head"
	elseif string.find(name, "Arm") or string.find(name, "Hand$") then
		return "Arm"
	elseif string.find(name, "Leg") or string.find(name, "Foot") then
		return "Leg"
	elseif name == "Torso" or name == "UpperTorso" or name == "LowerTorso" or name == "HumanoidRootPart" then
		return "Torso"
	end
	return nil
end

local kindCache: { [BasePart]: string } = setmetatable({}, { __mode = "k" }) :: any

-- Аксессуары, шлемы, волосы и прочие детали, приваренные к телу (Weld, Motor6D, WeldConstraint, AccessoryWeld), считаются той частью тела,
-- к которой они приварены (идём по сварке до 4 шагов): иначе выстрел в волосы или шлем не засчитывался как выстрел в голову.
local function partKind(part: BasePart): string
	local cached = kindCache[part]
	if cached then
		return cached
	end
	local result = kindByName(part.Name)
	if not result then
		-- у части моделей (военные, химик) шлемы, жилеты и руки лежат во вложенных Model (Top, Helmet, Chest…): сварку ищем во всей модели зомби
		local model = part:FindFirstAncestorOfClass("Model")
		while model and model.Parent and model.Parent:IsA("Model") do
			model = model.Parent
		end
		if model then
			local joints: { { a: BasePart, b: BasePart } } = {}
			for _, d in model:GetDescendants() do
				if d:IsA("JointInstance") and d.Part0 and d.Part1 then
					table.insert(joints, { a = d.Part0, b = d.Part1 })
				elseif d:IsA("WeldConstraint") and d.Part0 and d.Part1 then
					table.insert(joints, { a = d.Part0, b = d.Part1 })
				end
			end
			local seen: { [BasePart]: boolean } = { [part] = true }
			local frontier: { BasePart } = { part }
			for _ = 1, 4 do
				local nextFrontier: { BasePart } = {}
				for _, p in frontier do
					for _, j in joints do
						local other = if j.a == p then j.b elseif j.b == p then j.a else nil
						if other and not seen[other] then
							seen[other] = true
							local kind = kindByName(other.Name)
							if kind and kind ~= "Torso" or (kind == "Torso" and other.Name ~= "HumanoidRootPart") then
								result = kind
								break
							end
							table.insert(nextFrontier, other)
						end
					end
					if result then
						break
					end
				end
				if result or #nextFrontier == 0 then
					break
				end
				frontier = nextFrontier
			end
		end
	end
	if not result then
		-- деталь лежит внутри части тела (Handle внутри Head) или не приварена вовсе (ведро, шапка): берём ближайшую часть тела модели
		local parent = part.Parent
		if parent and parent:IsA("BasePart") then
			result = kindByName(parent.Name)
		end
		if not result then
			local model = part:FindFirstAncestorOfClass("Model")
			while model and model.Parent and model.Parent:IsA("Model") do
				model = model.Parent
			end
			if model then
				local bestDist = math.huge
				for _, d in model:GetDescendants() do
					if d:IsA("BasePart") and d ~= part and d.Name ~= "HumanoidRootPart" then
						local kind = kindByName(d.Name)
						if kind then
							local local_ = d.CFrame:PointToObjectSpace(part.Position)
							local half = d.Size / 2
							local out = Vector3.new(math.max(math.abs(local_.X) - half.X, 0), math.max(math.abs(local_.Y) - half.Y, 0), math.max(math.abs(local_.Z) - half.Z, 0))
							if out.Magnitude < bestDist then
								bestDist = out.Magnitude
								result = kind
							end
						end
					end
				end
			end
		end
	end
	result = result or "Torso"
	kindCache[part] = result
	return result
end

local function jerk(z: Zombie, name: string, offset: CFrame, tIn: number, tOut: number)
	tweenJoint(z, name, TweenInfo.new(tIn, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), offset * z.rest[name])
	local poseGen = z.poseGen
	task.delay(tIn, function()
		if z.alive and z.poseGen == poseGen then
			tweenJoint(z, name, TweenInfo.new(tOut, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), z.rest[name])
		end
	end)
end

-- Откинуть верхнюю часть тела от выстрела вокруг бёдер (angleDeg), остальные части — по списку names
local function leanBody(z: Zombie, localDir: Vector3, angleDeg: number, names: { string })
	local axis = Vector3.yAxis:Cross(localDir)
	if axis.Magnitude < 0.01 then
		return
	end
	if z.rig then
		-- у рига голова и руки — дети верхней части корпуса: достаточно наклонить пояс, остальное следует за ним
		local waist = CFrame.new(z.pivots.Torso)
		jerk(z, "Torso", waist * CFrame.fromAxisAngle(axis.Unit, math.rad(angleDeg)) * waist:Inverse(), 0.05, 0.3)
		return
	end
	local pivot = CFrame.new(z.hipPivot)
	local lean = pivot * CFrame.fromAxisAngle(axis.Unit, math.rad(angleDeg)) * pivot:Inverse()
	for _, name in names do
		jerk(z, name, lean, 0.05, 0.3)
	end
end

local function flinch(z: Zombie, kind: string, hitName: string, flat: Vector3, power: number, now: number)
	-- у рига части называются LeftUpperArm, RightLowerLeg…: приводим к логическим именам LeftArm/RightLeg
	local partName = hitName
	if z.rig and (kind == "Arm" or kind == "Leg") then
		partName = (if string.find(hitName, "Left") then "Left" else "Right") .. kind
	end
	local localDir = if flat == Vector3.zero then Vector3.new(0, 0, 1) else z.root.CFrame:VectorToObjectSpace(flat)
	if kind == "Head" then
		local neck = CFrame.new(z.pivots.Head)
		jerk(z, "Head", neck * CFrame.Angles(math.rad(38) * power, math.rad((math.random() - 0.5) * 40), 0) * neck:Inverse(), 0.05, 0.28)
		leanBody(z, localDir, 10 * power, { "Torso", "LeftArm", "RightArm" })
	elseif kind == "Arm" then
		local sx = if partName == "LeftArm" then -1 else 1
		local shoulder = CFrame.new(z.pivots[partName])
		jerk(z, partName, shoulder * CFrame.Angles(math.rad(-55) * power, 0, math.rad(sx * 18)) * shoulder:Inverse(), 0.05, 0.3)
		leanBody(z, localDir, 6 * power, { "Torso" })
	elseif kind == "Leg" then
		local hip = CFrame.new(z.pivots[partName])
		jerk(z, partName, hip * CFrame.Angles(math.rad(50) * power, 0, 0) * hip:Inverse(), 0.06, 0.4)
		z.slowUntil = now + 1.6 -- подстреленная нога: хромает
		z.humanoid.WalkSpeed = z.speed * 0.5
		local pivot = CFrame.new(z.hipPivot)
		local names = if z.rig then { "Torso" } else { "Torso", "Head", "LeftArm", "RightArm" }
		for _, name in names do
			jerk(z, name, pivot * CFrame.Angles(math.rad(-9), 0, 0) * pivot:Inverse(), 0.07, 0.35)
		end
	else -- корпус: откидывается от выстрела
		leanBody(z, localDir, 16 * power, { "Torso", "Head", "LeftArm", "RightArm" })
	end
end

-- Полоска здоровья босса сверху экрана (клиент: BossBarController): атрибуты ReplicatedStorage BossName, BossHp, BossMaxHp (боссов несколько — сумма)
local function refreshBossBar()
	local hp, maxHp, name = 0, 0, ""
	local immune = false
	for _, a in active do
		if a.alive and WaveMath.isBossType(a.def.id) and a.model:GetAttribute("Clone") ~= true then -- тени финального босса в полоску не входят
			immune = immune or a.phase2
			hp += math.max(0, a.hp)
			maxHp += a.maxHp
			if name == "" then
				name = a.def.name
			end
		end
	end
	local rs = game:GetService("ReplicatedStorage")
	rs:SetAttribute("BossName", if maxHp > 0 then name else nil)
	rs:SetAttribute("BossHp", if maxHp > 0 then hp else nil)
	rs:SetAttribute("BossMaxHp", if maxHp > 0 then maxHp else nil)
	rs:SetAttribute("BossImmune", if immune then true else nil) -- вторая фаза: бить только холодным оружием
end

local function release(z: Zombie)
	z.alive = false
	active[z.model] = nil
	if WaveMath.isBossType(z.def.id) then
		refreshBossBar()
	end
	cancelPose(z)
	for _, track in z.tracks do
		track:Stop(0)
	end
	z.animName = ""
	z.model.Parent = storage
	local list = pool[z.def.id]
	if not list then
		list = {}
		pool[z.def.id] = list
	end
	table.insert(list, z)
end

-- Выбор точки появления: зомби идут на игроков со всех сторон, а не гуськом. Берём точки на расстоянии SPAWN_MIN..SPAWN_MAX от
-- ближайшего живого игрока, делим окружение выбранного игрока на 8 секторов и берём сектор, откуда зомби появлялись реже всего;
-- в самой точке — случайный сдвиг, чтобы не слипались (не ближе SPAWN_GAP к другому зомби).
local SPAWN_MIN, SPAWN_MAX, SPAWN_GAP, SECTORS = 60, 340, 3.5, 8
local sectorUse: { number } = {}
for i = 1, SECTORS do
	sectorUse[i] = 0
end
local spawnCount = 0

-- Точка миссии: зомби появляются кольцом 100–150 студов вокруг неё, сектора чередуются (поток со всех сторон)
local anchorPos: Vector3? = nil
local aliveCapOverride: number? = nil
local anchorUse: { number } = {}
for i = 1, SECTORS do
	anchorUse[i] = 0
end
local RING_MIN, RING_MAX = 100, 150

local function ringSpawnPosition(anchor: Vector3): Vector3?
	local roots: { Vector3 } = {}
	for _, p in PlayerService.upPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			table.insert(roots, r.Position)
		end
	end
	local order: { number } = {}
	for i = 1, SECTORS do
		order[i] = i
	end
	table.sort(order, function(a, b)
		if anchorUse[a] ~= anchorUse[b] then
			return anchorUse[a] < anchorUse[b]
		end
		return a < b
	end)
	for attempt = 1, 14 do
		-- берём наименее использованные сектора по очереди; сектор — 1/8 круга с небольшим случайным углом
		local sector = order[math.min(#order, 1 + math.floor((attempt - 1) / 3))]
		if attempt <= 3 then
			sector = order[1 + math.random(0, 1)]
		end
		local angle = ((sector - 1) + math.random()) / SECTORS * math.pi * 2
		local radius = RING_MIN + math.random() * (RING_MAX - RING_MIN)
		local x, z = anchor.X + math.cos(angle) * radius, anchor.Z + math.sin(angle) * radius
		local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0))
		if hit and hit.Normal.Y > 0.9 then
			local ok = false
			for _, name in { "Roads", "Ground", "Grass" } do
				local f = workspace:FindFirstChild(name)
				if f and hit.Instance:IsDescendantOf(f) then
					ok = true
					break
				end
			end
			if ok and not workspace:Raycast(hit.Position + Vector3.new(0, 2, 0), Vector3.new(0, 40, 0)) then
				local far = true
				for _, r in roots do
					if Vector3.new(r.X - x, 0, r.Z - z).Magnitude < 45 then
						far = false
						break
					end
				end
				if far then
					anchorUse[sector] += 1
					if anchorUse[sector] >= 6 then
						for i = 1, SECTORS do
							anchorUse[i] = math.floor(anchorUse[i] / 2)
						end
					end
					return hit.Position + Vector3.new(0, 3, 0)
				end
			end
		end
	end
	return nil
end

function ZombieService.setAnchor(pos: Vector3?)
	anchorPos = pos
	for i = 1, SECTORS do
		anchorUse[i] = 0
	end
end

-- Двигать точку потока, не сбрасывая счётчики секторов (конвой едет)
-- Свой потолок живых зомби на время миссии (конвой: меньше, иначе грузовик не доживёт); nil — обычный
function ZombieService.setAliveCap(cap: number?)
	aliveCapOverride = cap
end

function ZombieService.moveAnchor(pos: Vector3)
	anchorPos = pos
end

function ZombieService.queueSize(): number
	return #queue
end

-- Бесконечный поток миссии (MissionService): перенос потерявшихся работает и при непустой очереди
function ZombieService.setStreamMode(on: boolean)
	streamMode = on
end

-- Свои точки появления на время миссии (метро): список позиций вместо маркеров карты
local spawnOverride: { Vector3 }? = nil

function ZombieService.setSpawnPoints(points: { Vector3 }?)
	spawnOverride = points
end

local function pickSpawnPosition(): Vector3
	if spawnOverride and #spawnOverride > 0 then
		-- не ближе 35 студов к живым игрокам: из нескольких случайных точек берём самую далёкую
		local roots: { Vector3 } = {}
		for _, p in PlayerService.upPlayers() do
			local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r then
				table.insert(roots, r.Position)
			end
		end
		-- предпочитаем точки в 50–260 студах от ближайшего живого игрока (поток рядом, но не в лицо); иначе самую далёкую
		local good: { Vector3 } = {}
		local best, bestMin = spawnOverride[1], -1
		for _, candidate in spawnOverride do
			local minDist = math.huge
			for _, r in roots do
				minDist = math.min(minDist, (candidate - r).Magnitude)
			end
			if minDist >= 50 and minDist <= 260 then
				table.insert(good, candidate)
			end
			if minDist > bestMin then
				best, bestMin = candidate, minDist
			end
		end
		if #good > 0 then
			best = good[math.random(1, #good)]
		end
		return best + Vector3.new(math.random(-3, 3), 3, math.random(-3, 3))
	end
	if anchorPos then
		local ring = ringSpawnPosition(anchorPos)
		if ring then
			return ring
		end
	end
	local spawns = map.zombieSpawns
	local up = PlayerService.upPlayers()
	local roots: { Vector3 } = {}
	for _, p in up do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			table.insert(roots, r.Position)
		end
	end
	local base: Vector3
	if #roots == 0 then
		base = spawns[math.random(1, #spawns)]
	else
		local focus = roots[math.random(1, #roots)]
		local eligible: { { pos: Vector3, sector: number } } = {}
		local near: { { pos: Vector3, sector: number } } = {}
		for _, sp in spawns do
			local minDist = math.huge
			for _, r in roots do
				minDist = math.min(minDist, (Vector3.new(sp.X, 0, sp.Z) - Vector3.new(r.X, 0, r.Z)).Magnitude)
			end
			local d = sp - focus
			local sector = math.floor(((math.atan2(d.Z, d.X) + math.pi) / (2 * math.pi)) * SECTORS) % SECTORS + 1
			local entry = { pos = sp, sector = sector }
			if minDist >= SPAWN_MIN and minDist <= SPAWN_MAX then
				table.insert(eligible, entry)
			elseif minDist >= 40 then
				table.insert(near, entry)
			end
		end
		local pool = if #eligible > 0 then eligible else near
		if #pool == 0 then
			base = spawns[math.random(1, #spawns)]
		else
			local bestUse = math.huge
			for _, e in pool do
				bestUse = math.min(bestUse, sectorUse[e.sector])
			end
			local choices: { { pos: Vector3, sector: number } } = {}
			for _, e in pool do
				if sectorUse[e.sector] == bestUse then
					table.insert(choices, e)
				end
			end
			local pick = choices[math.random(1, #choices)]
			base = pick.pos
			sectorUse[pick.sector] += 1
		end
	end
	spawnCount += 1
	if spawnCount % 24 == 0 then
		for i = 1, SECTORS do
			sectorUse[i] = math.floor(sectorUse[i] / 2)
		end
	end
	-- сдвиг внутри точки без наложения на уже стоящих зомби
	local result = base
	for _ = 1, 8 do
		local angle, radius = math.random() * math.pi * 2, 2 + math.random() * 9
		local candidate = base + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local free = true
		for _, z in active do
			local d = z.root.Position - candidate
			if d.X * d.X + d.Z * d.Z < SPAWN_GAP * SPAWN_GAP then
				free = false
				break
			end
		end
		result = candidate
		if free then
			break
		end
	end
	return result
end

local function spawnOne(typeId: string, atPos: Vector3?): Zombie
	local z = acquire(typeId)
	z.model:SetAttribute("Thrown", nil) -- метка брошенного ползуна (BossAI) не переходит в следующую жизнь модели из пула
	if z.model:GetAttribute("Clone") then
		-- модель была тенью финального босса: возвращаем прозрачность и снимаем метку
		z.model:SetAttribute("Clone", nil)
		for _, d in z.model:GetDescendants() do
			if d:IsA("BasePart") then
				local base = d:GetAttribute("BaseTransparency")
				if typeof(base) == "number" then
					d.Transparency = base
				end
			end
		end
	end
	z.phase2 = false
	z.model:SetAttribute("Phase2", nil)
	local spawnPos = atPos or pickSpawnPosition()
	local rigMul = Config.ZombieRigHp[tostring(z.model:GetAttribute("RigAsset"))] or 1
	z.maxHp = math.floor(z.def.hp * hpMultiplier * rigMul + 0.5)
	z.hp = z.maxHp
	if WaveMath.isBossType(z.def.id) then
		local now0 = os.clock()
		z.nextJump = now0 + ((z.def.jump :: any) and (z.def.jump :: any).first or 0)
		z.nextRock = now0 + ((z.def.rock :: any) and (z.def.rock :: any).first or 0)
		z.nextAtk = BossAI.firstTimes(z.def, now0)
	end
	-- сразу охотимся на игрока; к баррикадам идём, только если они закрывают путь к нему (см. Hunt)
	z.state = "Hunt"
	z.window = nil
	z.staggerUntil = 0
	z.gen += 1
	z.waypoints = nil
	z.pathBusy = false
	z.pathFailed = false
	z.lastAttack = 0
	resetAttack(z)
	z.stuckTime = 0
	z.lastPos = spawnPos
	z.alive = true
	z.speed = if WaveMath.isBossType(z.def.id) then z.def.speed else WaveMath.speedOf(Config.Waves, z.def.speed, waveNumber)
	z.humanoid.WalkSpeed = z.speed
	z.model:SetAttribute("Hp", z.hp)
	z.model:SetAttribute("MaxHp", z.maxHp)
	z.model:PivotTo(CFrame.new(spawnPos))
	z.model.Parent = container
	z.root:SetNetworkOwner(nil) -- двигает только сервер
	if z.rig and next(z.tracks) == nil then
		z.tracks = loadTracks(z.model, z.animIds)
	end
	active[z.model] = z
	if WaveMath.isBossType(z.def.id) then
		refreshBossBar()
	end
	return z
end

local function nearestUpCharacter(pos: Vector3): (Player?, BasePart?, number)
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDist = math.huge
	for i, r in tickPlayerRoots do
		local d = (r.Position - pos).Magnitude
		if d < bestDist then
			best, bestRoot, bestDist = tickPlayers[i], r, d
		end
	end
	return best, bestRoot, bestDist
end

-- Анимация рига: по скорости корпуса — стоит (idle) или идёт (walk, темп по скорости). На замахе и в оцепенении — idle.
local function animate(z: Zombie)
	if not z.rig then
		return
	end
	local v = z.root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local want = if speed > 1.5 and z.windupUntil == 0 then "walk" else "idle"
	if want ~= z.animName then
		for name, track in z.tracks do
			if name == want then
				track:Play(0.2)
			else
				track:Stop(0.2)
			end
		end
		z.animName = want
	end
	local walk = z.tracks.walk
	if walk and want == "walk" then
		walk:AdjustSpeed(math.clamp(speed / z.animSpeed, 0.4, 2.4))
	end
end

-- Тёмный: перепрыгивает к игроку, но не ближе tp.distance
local function teleportNear(z: Zombie, targetRoot: BasePart, now: number)
	local tp = z.def.teleport :: { cooldown: number, distance: number }
	z.nextSpecial = now + tp.cooldown
	local angle = math.random() * math.pi * 2
	local spot = targetRoot.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (tp.distance + math.random() * 4)
	local hit = workspace:Raycast(spot + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), paramsExcluding(targetRoot.Parent :: Instance))
	if hit then
		z.model:PivotTo(CFrame.new(hit.Position + Vector3.new(0, 4, 0)))
		z.waypoints = nil
		z.pathFailed = false
	end
end

local function hasLineOfSight(z: Zombie, targetRoot: BasePart): boolean
	local from = z.head.Position
	return workspace:Raycast(from, targetRoot.Position - from, paramsExcluding(targetRoot.Parent :: Instance)) == nil
end

-- Атаки босса -----------------------------------------------------------------------------------------------------------

-- Красная зона на земле: три концентрических диска, чем ближе к центру, тем прозрачнее
local function makeZone(center: Vector3, radius: number): { Part }
	local parts: { Part } = {}
	for i, k in { { 1, 0.6 }, { 0.66, 0.76 }, { 0.33, 0.88 } } do
		local p = Instance.new("Part")
		p.Name = "BossZone"
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(0.2, radius * 2 * k[1], radius * 2 * k[1])
		p.CFrame = CFrame.new(center + Vector3.new(0, 0.15 + i * 0.03, 0)) * CFrame.Angles(0, 0, math.rad(90))
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 40, 30)
		p.Transparency = k[2]
		p.Parent = workspace
		table.insert(parts, p)
	end
	return parts
end

local function moveZone(zone: { Part }, center: Vector3)
	for i, p in zone do
		p.CFrame = CFrame.new(center + Vector3.new(0, 0.15 + i * 0.03, 0)) * CFrame.Angles(0, 0, math.rad(90))
	end
end

local function clearZone(zone: { Part })
	for _, p in zone do
		p:Destroy()
	end
	table.clear(zone)
end

-- Точка на земле под игроком
local function groundUnder(char: Model, pos: Vector3): Vector3
	local hit = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), paramsExcluding(char))
	return if hit then hit.Position else Vector3.new(pos.X, pos.Y - 3, pos.Z)
end

-- Кольцо удара: расширяется и исчезает
local function shockwave(center: Vector3, radius: number)
	local ring = Instance.new("Part")
	ring.Name = "BossShock"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, 2, 2)
	ring.CFrame = CFrame.new(center + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 120, 60)
	ring.Transparency = 0.2
	ring.Parent = workspace
	local tw = TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.4, radius * 2, radius * 2), Transparency = 1 })
	tw:Play()
	tw.Completed:Once(function()
		ring:Destroy()
	end)
end

local function damageInRadius(center: Vector3, radius: number, amount: number)
	for _, p in PlayerService.upPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and Vector3.new(r.Position.X - center.X, 0, r.Position.Z - center.Z).Magnitude <= radius and r.Position.Y - center.Y < 12 then
			PlayerService.damage(p, amount)
		end
	end
end

-- Оглушение игроков в радиусе (бросок знака Гаргантюа): кувырок спасает (PlayerService.stun не накладывается на неуязвимого)
local function stunInRadius(center: Vector3, radius: number, seconds: number)
	for _, p in PlayerService.upPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and Vector3.new(r.Position.X - center.X, 0, r.Position.Z - center.Z).Magnitude <= radius and r.Position.Y - center.Y < 12 then
			PlayerService.stun(p, seconds)
		end
	end
end

-- Волна тьмы Повелителя после приземления: тёмное кольцо расходится до outer студов, без урона; кто внутри — не может бегать noSprint секунд
local function darkWave(center: Vector3, outer: number, noSprint: number)
	local ring = Instance.new("Part")
	ring.Name = "BossDarkRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.5, 2, 2)
	ring.CFrame = CFrame.new(center + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.SmoothPlastic
	ring.Color = Color3.fromRGB(14, 8, 24)
	ring.Transparency = 0.2
	ring.Parent = workspace
	local tw = TweenService:Create(ring, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.5, outer * 2, outer * 2), Transparency = 1 })
	tw:Play()
	tw.Completed:Once(function()
		ring:Destroy()
	end)
	for _, p in PlayerService.upPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and Vector3.new(r.Position.X - center.X, 0, r.Position.Z - center.Z).Magnitude <= outer and r.Position.Y - center.Y < 12 then
			PlayerService.noSprint(p, noSprint)
		end
	end
end

-- Обломки при падении камня: несколько кусков разлетаются и падают
local function debrisBurst(center: Vector3, color: Color3)
	for _ = 1, 9 do
		local d = Instance.new("Part")
		d.Name = "BossDebris"
		d.Size = Vector3.new(0.6 + math.random() * 0.9, 0.6 + math.random() * 0.7, 0.6 + math.random() * 0.9)
		d.Material = Enum.Material.Slate
		d.Color = color
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.CFrame = CFrame.new(center + Vector3.new(0, 1, 0)) * CFrame.Angles(math.random() * 6, math.random() * 6, 0)
		d.Parent = workspace
		d.AssemblyLinearVelocity = Vector3.new((math.random() - 0.5) * 30, 18 + math.random() * 14, (math.random() - 0.5) * 30)
		Debris:AddItem(d, 2.5)
	end
end

endBossAct = function(z: Zombie)
	local act = z.bossAct
	if not act then
		return
	end
	z.bossAct = nil
	clearZone(act.zone)
	if act.rock then
		act.rock:Destroy()
	end
	if BossAI.isKind(act.kind) then
		BossAI.cancel(z, act)
	end
end

-- Атаки боссов вынесены в BossAI: передаём ему позы, спавн зомби и завершение атаки
BossAI.init({
	container = function(): Instance
		return container
	end,
	armPose = armPose,
	crouchPose = crouchPose,
	tweenJoint = tweenJoint,
	setEyes = setEyes,
	spawnAt = function(typeId: string, pos: Vector3): any?
		local ok, z = pcall(spawnOne, typeId, pos)
		return if ok then z else nil
	end,
	thrownAlive = function(): number
		local n = 0
		for _, z in active do
			if z.alive and z.model:GetAttribute("Thrown") == true then
				n += 1
			end
		end
		return n
	end,
	damageMult = function(): number
		return damageMultiplier
	end,
	clonesAlive = function(): number
		local n = 0
		for _, w in active do
			if w.alive and w.model:GetAttribute("Clone") == true then
				n += 1
			end
		end
		return n
	end,
	endAct = function(z: any)
		endBossAct(z)
	end,
})

-- Босс начинает атаку, если есть готовая и игрок в её дальности; true — атака началась (дальше ведёт stepBossAct)
local function startBossSpecial(z: Zombie, player: Player, targetRoot: BasePart, dist: number, now: number): boolean
	local jump = z.def.jump
	local rock = z.def.rock
	local ready: { string } = {}
	if jump and now >= z.nextJump and dist >= jump.minRange and dist <= jump.range then
		table.insert(ready, "jump")
	end
	if rock and now >= z.nextRock and dist >= rock.minRange and dist <= rock.range and hasLineOfSight(z, targetRoot) then
		table.insert(ready, "rock")
	end
	if z.def.attacks then
		for _, k in BossAI.ready(z, now, dist, hasLineOfSight(z, targetRoot)) do
			table.insert(ready, k)
		end
	end
	if #ready == 0 then
		return false
	end
	local kind = ready[math.random(1, #ready)]
	if BossAI.isKind(kind) then
		return BossAI.begin(z, kind, player, targetRoot, now)
	end
	local char = player.Character :: Model
	local aim = groundUnder(char, targetRoot.Position)
	z.humanoid:MoveTo(z.root.Position)
	setEyes(z, true)
	if kind == "jump" then
		local j = jump :: Config.BossJump
		z.bossAct = { kind = "jump", phase = "charge", endAt = now + j.windup, target = player, aim = aim, zone = makeZone(aim, j.radius), rock = nil, locked = false }
		-- присел: бёдра вперёд, колени согнуты, корпус опущен и наклонён; держится, пока не прыгнет
		crouchPose(z, 1, j.windup * 0.45)
		armPose(z, -30, j.windup * 0.5)
	else
		local r = rock :: Config.BossRock
		local rockPart = Instance.new("Part")
		rockPart.Name = "BossRock"
		if r.stun then
			-- дорожный знак (бросок Гаргантюа): жёлтый ромб, без надписей
			rockPart.Name = "BossSign"
			rockPart.Size = Vector3.new(5, 5, 0.4)
			rockPart.Material = Enum.Material.Metal
			rockPart.Color = Color3.fromRGB(226, 182, 44)
		else
			rockPart.Size = Vector3.new(5, 4, 5)
			rockPart.Material = Enum.Material.Slate
			rockPart.Color = Color3.fromRGB(96, 84, 72)
		end
		rockPart.Anchored = true
		rockPart.CanCollide = false
		rockPart.CanQuery = false
		rockPart.CanTouch = false
		local base = groundUnder(z.model, z.root.Position) + z.root.CFrame.LookVector * 3
		rockPart.CFrame = CFrame.new(base + Vector3.new(0, 1, 0)) * CFrame.Angles(0.4, 0.8, 0.2)
		rockPart.Parent = workspace
		debrisBurst(base, Color3.fromRGB(96, 84, 72))
		z.bossAct = { kind = "rock", phase = "rip", endAt = now + r.windup, target = player, aim = aim, zone = {}, rock = rockPart, locked = false }
		-- обломок поднимается над головой босса, руки вверх
		TweenService:Create(rockPart, TweenInfo.new(r.windup * 0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(z.head.Position + Vector3.new(0, 4.5, 0)) * CFrame.Angles(0.8, 1.6, 0.4),
		}):Play()
		armPose(z, 150, r.windup * 0.8)
	end
	return true
end

-- Ход идущей атаки (вызывается из think вместо обычного поведения)
local function stepBossAct(z: Zombie, now: number)
	local act = z.bossAct :: BossAct
	local gen = z.gen
	if BossAI.isKind(act.kind) then
		BossAI.step(z, act, now) -- новые атаки боссов (удар по земле, ползун, разбег, чёрный взмах) ведёт BossAI
		return
	end
	z.humanoid:MoveTo(z.root.Position)
	if act.kind == "jump" then
		local j = z.def.jump :: Config.BossJump
		if act.phase == "charge" then
			-- зона следует за игроком, в последние 0,7 с застывает (можно успеть выбежать)
			if not act.locked then
				local char = act.target.Character
				local r = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if r and PlayerService.isUp(act.target) then
					act.aim = groundUnder(char :: Model, r.Position)
					moveZone(act.zone, act.aim)
				end
				if now >= act.endAt - 0.7 then
					act.locked = true
				end
			end
			if now >= act.endAt then
				act.phase = "air"
				local from = z.root.CFrame
				local to = CFrame.new(act.aim + Vector3.new(0, z.root.Size.Y * 0.5 + 3, 0)) * from.Rotation
				local apex = CFrame.new((from.Position + to.Position) / 2 + Vector3.new(0, 24, 0)) * from.Rotation
				cancelWindup(z)
				crouchPose(z, 0, 0.12) -- распрямился и оттолкнулся
				armPose(z, 70, 0.25)
				z.root.Anchored = true
				local half = j.flight / 2
				local up = TweenService:Create(z.root, TweenInfo.new(half, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = apex })
				z.vaultTween = up
				up.Completed:Once(function(state: Enum.PlaybackState)
					if z.vaultTween ~= up or state ~= Enum.PlaybackState.Completed or z.gen ~= gen then
						return
					end
					local down = TweenService:Create(z.root, TweenInfo.new(half, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = to })
					z.vaultTween = down
					down.Completed:Once(function(downState: Enum.PlaybackState)
						if z.vaultTween ~= down or downState ~= Enum.PlaybackState.Completed or z.gen ~= gen or not z.alive then
							return
						end
						z.vaultTween = nil
						z.root.Anchored = false
						local center = act.aim
						clearZone(act.zone)
						shockwave(center, j.radius)
						damageInRadius(center, j.radius, j.damage * damageMultiplier)
						if j.wave then
							darkWave(center, j.radius + j.wave.extra, j.wave.noSprint) -- Повелитель тёмных: волна тьмы шире удара, без урона
						end
						z.model:SetAttribute("SwingAt", os.clock())
						z.bossAct = nil
						z.nextJump = os.clock() + j.cooldown
						z.lastAttack = os.clock()
						setEyes(z, false)
						-- приземление: короткий присед и подъём
						crouchPose(z, 0.7, 0.1)
						armPose(z, 0, 0.4)
						local pg = z.poseGen
						task.delay(0.3, function()
							if z.poseGen == pg and z.gen == gen and z.alive then
								crouchPose(z, 0, 0.4)
							end
						end)
					end)
					down:Play()
				end)
				up:Play()
			end
		end
		return
	end
	-- бросок обломка
	local r = z.def.rock :: Config.BossRock
	if act.phase == "rip" and now >= act.endAt then
		local char = act.target.Character
		local tr = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local aim = if tr and PlayerService.isUp(act.target) then groundUnder(char :: Model, tr.Position) else act.aim
		local rock = act.rock :: Part
		local from = rock.Position
		local flight = math.clamp((aim - from).Magnitude / 55, 0.9, r.flight)
		local zone = makeZone(aim, r.radius)
		local gravity = Vector3.new(0, -workspace.Gravity, 0)
		rock.Anchored = false
		rock.AssemblyLinearVelocity = (aim + Vector3.new(0, 1.5, 0) - from) / flight - 0.5 * gravity * flight
		rock.AssemblyAngularVelocity = Vector3.new(4, 6, 2)
		z.bossAct = nil -- босс свободен; обломок и зона живут сами
		z.nextRock = now + r.cooldown
		z.lastAttack = now
		z.model:SetAttribute("SwingAt", os.clock())
		armPose(z, 0, 0.3)
		setEyes(z, false)
		local hazard = hazardGen
		task.delay(flight, function()
			rock:Destroy()
			clearZone(zone)
			if hazardGen == hazard then
				shockwave(aim, r.radius)
				debrisBurst(aim, Color3.fromRGB(96, 84, 72))
				damageInRadius(aim, r.radius, r.damage * damageMultiplier)
				if r.stun then
					stunInRadius(aim, r.radius, r.stun) -- знак Гаргантюа оглушает
				end
			end
		end)
	end
end

local function think(z: Zombie, now: number, dt: number)
	local pos = z.root.Position
	local reach = 3.5 * z.def.scale + 1.5

	-- хромота после попадания в ногу проходит
	if z.slowUntil > 0 and now >= z.slowUntil then
		z.slowUntil = 0
		z.humanoid.WalkSpeed = z.speed
	end

	-- атака босса (прыжок, бросок): стоит и ждёт, попадания её не срывают
	if z.bossAct then
		stepBossAct(z, now)
		return
	end

	-- после попадания зомби на миг замирает (чувствуется удар); замах при этом срывается
	if now < z.staggerUntil then
		if z.windupUntil > 0 then
			cancelWindup(z)
		end
		z.humanoid:MoveTo(pos)
		return
	end

	-- замах: стоим на месте; в конце — удар
	if z.windupUntil > 0 then
		z.humanoid:MoveTo(pos)
		if now >= z.windupUntil then
			finishStrike(z, now)
		end
		return
	end

	-- перелезание забора: заборы переулков (4,4) выше обычного прыжка зомби (3), поэтому упёршись в забор, зомби
	-- через секунду делает усиленный прыжок. Игроку это даёт 1–2 с форы; стенки (5,6) и балки зомби не берут.
	-- Зомби собраны из блоков, Humanoid.Jump у них не срабатывает, а скорость корня гасит сам Humanoid. Поэтому
	-- перелезание — короткая дуга над забором: корень на 0,7 с закрепляется и летит по твину, потом отпускается.
	if now < z.vaultLockUntil then
		return
	end
	if z.stuckTime > 1 and now >= z.vaultResetAt then
		local look = z.root.CFrame.LookVector
		local hit = workspace:Raycast(pos + Vector3.new(0, 1, 0), look * 4, worldParams)
		if hit and string.sub(hit.Instance.Name, 1, 5) == "Fence" then
			local start = z.root.CFrame
			local base = Vector3.new(hit.Position.X, pos.Y, hit.Position.Z)
			local apex = CFrame.new(base + Vector3.new(0, 3.8, 0)) * start.Rotation
			local landing = CFrame.new(base + look * 3.4) * start.Rotation
			z.vaultLockUntil = now + 0.8
			z.vaultResetAt = now + 2.2 -- пауза до следующего перелезания
			z.stuckTime = 0
			z.root.Anchored = true
			-- твин хранится в z.vaultTween: смерть, пул или перенос отменяют его (cancelPose), отменённый дальше не идёт
			local up = TweenService:Create(z.root, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = apex })
			z.vaultTween = up
			up.Completed:Once(function(state: Enum.PlaybackState)
				if z.vaultTween ~= up or state ~= Enum.PlaybackState.Completed then
					return
				end
				local down = TweenService:Create(z.root, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = landing })
				z.vaultTween = down
				down.Completed:Once(function(downState: Enum.PlaybackState)
					if z.vaultTween ~= down or downState ~= Enum.PlaybackState.Completed then
						return
					end
					z.vaultTween = nil
					z.root.Anchored = false
				end)
				down:Play()
			end)
			up:Play()
			return
		end
	end
	-- застревание: долго почти не двигаемся — прыгаем
	if (pos - z.lastPos).Magnitude < 0.3 and z.state ~= "Breaking" then
		z.stuckTime += dt
		if z.stuckTime > 2 then
			z.humanoid.Jump = true
			z.stuckTime = 0
		end
	else
		z.stuckTime = 0
	end
	z.lastPos = pos

	if z.state == "ToWindow" then
		local w = z.window
		if not w then
			z.state = "Hunt"
			return
		end
		if (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(w.outside.X, 0, w.outside.Z)).Magnitude < 3 then
			z.state = if BarricadeService.isOpen(w) then "Entering" else "Breaking"
		else
			goTo(z, w.outside, now)
		end
	elseif z.state == "Breaking" then
		local w = z.window :: Types.Window
		if BarricadeService.isOpen(w) then
			z.state = "Entering"
			return
		end
		z.humanoid:MoveTo(w.outside)
		if now - z.lastAttack >= z.def.breakCooldown then
			z.lastAttack = now
			BarricadeService.damage(w, z.def.planksPerHit)
		end
	elseif z.state == "Entering" then
		local w = z.window :: Types.Window
		z.humanoid:MoveTo(w.inside)
		local flat = Vector3.new(pos.X, 0, pos.Z) - Vector3.new(w.inside.X, 0, w.inside.Z)
		if flat.Magnitude < 3 then
			z.state = "Hunt"
		end
	else -- Hunt
		local player, targetRoot, dist = nearestUpCharacter(pos)
		-- ближе игрока может оказаться конвой или солдат: идём бить его
		local npcModel, npcRoot, npcDist = nearestNpc(pos)
		if npcModel and npcRoot and (not player or npcDist < dist) then
			goTo(z, npcRoot.Position, now)
			local npcReach = reach + 2 + npcRoot.Size.Magnitude * 0.25
			if npcDist <= npcReach and now - z.lastAttack >= z.def.attackCooldown then
				startWindup(z, nil, now)
				npcWindup[z] = npcModel
			end
			return
		end
		if not player or not targetRoot then
			return
		end
		-- упёрся в баррикаду (почти не двигаемся, а рядом закрытый вход): ломаем её
		if z.stuckTime > 0.6 then
			local near = BarricadeService.closedEntranceNear(pos, 8)
			if near then
				z.window = near
				z.state = "ToWindow"
				z.waypoints = nil
				z.stuckTime = 0
				return
			end
		end
		-- пути к игроку нет (он за баррикадой): идём ломать вход, который его защищает, где бы зомби ни стоял
		if z.pathFailed and not z.pathBusy then
			local w = BarricadeService.guardingEntrance(targetRoot.Position, 45)
			if w then
				z.window = w
				z.state = "ToWindow"
				z.pathFailed = false
				z.waypoints = nil
				return
			end
		end
		if (z.def.jump or z.def.rock or z.def.attacks) and startBossSpecial(z, player, targetRoot, dist, now) then
			return
		end
		local tp = z.def.teleport
		if tp and now >= z.nextSpecial and dist > tp.distance + 10 then
			teleportNear(z, targetRoot, now)
			return
		end
		goTo(z, targetRoot.Position, now)
		local fl = z.def.flask
		if fl and now >= z.nextSpecial and dist <= fl.range and dist >= fl.minRange and hasLineOfSight(z, targetRoot) then
			z.nextSpecial = now + fl.cooldown
			z.throwing = true
			startWindup(z, player, now)
		elseif dist <= reach and now - z.lastAttack >= z.def.attackCooldown and not (z.def.attacks and (z.def.attacks :: any).slash) then
			-- (у финального босса обычного удара нет: его заменяет порез в BossAI)
			startWindup(z, player, now)
		end
	end
end

-- Тело убитого зомби: на миг замирает, затем отлетает от стрелка (клон модели, живёт пару секунд)
local MAX_CORPSES = 10
local corpses: { Model } = {}

-- Разные смерти: выстрел в голову — голова отлетает; тяжёлый удар (дробь, кувалда) — отрывает конечности и швыряет тело;
-- выстрел в ногу — оседает почти на месте; обычная — отлёт от стрелка
local function spawnCorpse(z: Zombie, dir: Vector3, kind: string, heavy: boolean)
	local folder = workspace:FindFirstChild("Corpses")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Corpses"
		folder.Parent = workspace
	end
	if #corpses >= MAX_CORPSES then
		local oldest = table.remove(corpses, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	local c = z.model:Clone()
	c.Name = "Corpse"
	local joints: { [BasePart]: Instance } = {}
	local hum = c:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:Destroy()
	end
	if z.rig then
		-- риг: суставы Motor6D заменяем шаровыми — тело разваливается как тряпичная кукла
		for _, m in c:GetDescendants() do
			if m:IsA("Motor6D") and m.Part0 and m.Part1 then
				local a0 = Instance.new("Attachment")
				a0.CFrame = m.C0
				a0.Parent = m.Part0
				local a1 = Instance.new("Attachment")
				a1.CFrame = m.C1
				a1.Parent = m.Part1
				local ball = Instance.new("BallSocketConstraint")
				ball.Attachment0 = a0
				ball.Attachment1 = a1
				ball.LimitsEnabled = true
				ball.UpperAngle = 55
				ball.TwistLimitsEnabled = true
				ball.TwistLowerAngle = -35
				ball.TwistUpperAngle = 35
				ball.Parent = m.Part0
				joints[m.Part1] = ball
				m:Destroy()
			end
		end
	end
	if not z.rig then
		-- блочная модель: части сидят на сварке/суставах — запоминаем, чтобы при тяжёлой смерти отрывать
		for _, j in c:GetDescendants() do
			if j:IsA("JointInstance") and j.Part0 and j.Part1 then
				for _, end_ in { j.Part0, j.Part1 } do
					if end_.Name ~= "HumanoidRootPart" and end_.Name ~= "Handle" and end_.Name ~= "Torso" then
						joints[end_] = j
					end
				end
			end
		end
	end
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local parts: { BasePart } = {}
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = z.rig and d.Name ~= "HumanoidRootPart" and d.Name ~= "Handle" -- у рига ударяются о землю все части (рэгдолл), у мешей — только корень
			d.CanQuery = false
			d.CanTouch = false
			d.CollisionGroup = "Default"
			table.insert(parts, d)
		end
	end
	if not root then
		c:Destroy()
		return
	end
	root.CanCollide = true
	root.Transparency = 1
	c.Parent = folder
	table.insert(corpses, c)
	-- «заморозка» на 0,07 с, потом бросок
	task.delay(0.07, function()
		if not c.Parent then
			return
		end
		for _, p in parts do
			p.Anchored = false
		end
		local mass = root.AssemblyMass
		local push = if kind == "Leg" then 0.35 elseif heavy then 1.9 else 1
		root:ApplyImpulse((dir * 34 * push + Vector3.new(0, (if heavy then 30 else 20) * (if kind == "Leg" then 0.4 else 1), 0)) * mass)
		root.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-4, 4), math.random(-8, 8)) * (if heavy then 2 else 1)
		-- что отрывается: голова (выстрел в голову) или 1–2 конечности (тяжёлый удар)
		for part, joint in joints do
			local n = part.Name
			local tear = (kind == "Head" and string.find(n, "Head") ~= nil)
				or (heavy and (string.find(n, "Arm") ~= nil or string.find(n, "Leg") ~= nil) and math.random() < 0.45)
			if tear then
				joint:Destroy()
				part.CanCollide = true
				local e = Instance.new("ParticleEmitter")
				e.Rate = 0
				e.Lifetime = NumberRange.new(0.3, 0.6)
				e.Speed = NumberRange.new(8, 20)
				e.SpreadAngle = Vector2.new(60, 60)
				e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0) })
				e.Color = ColorSequence.new(Color3.fromRGB(150, 8, 8))
				e.Acceleration = Vector3.new(0, -50, 0)
				e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				e.Parent = part
				e:Emit(14)
				part:ApplyImpulse((dir * 22 + Vector3.new((math.random() - 0.5) * 18, 26, (math.random() - 0.5) * 18)) * part.AssemblyMass)
				part.AssemblyAngularVelocity = Vector3.new(math.random(-20, 20), math.random(-20, 20), math.random(-20, 20))
			end
		end
	end)
	task.delay(2.4, function()
		for _, p in parts do
			if p.Parent then
				TweenService:Create(p, TweenInfo.new(0.8), { Transparency = 1 }):Play()
			end
		end
	end)
	Debris:AddItem(c, 3.4)
end

export type Impact = {
	dir: Vector3?, -- направление удара/выстрела (от стрелка к зомби)
	push: number?, -- отбрасывание, студов/с
	stagger: number?, -- на сколько секунд зомби замирает
	part: BasePart?, -- часть тела, в которую попали (для реакции: голова, корпус, рука, нога)
	heavy: boolean?, -- тяжёлый удар (дробь, кувалда, топор): смерть с оторванными конечностями
	power: number? , -- сила удара для анимации реакции (1 — обычная)
	melee: boolean?, -- удар холодным оружием (по боссу во второй фазе проходит только он)
}

-- Урон по зомби (только сервер). Возвращает: нанесён ли урон, убит ли.
function ZombieService.damage(model: Model, amount: number, attacker: Player?, impact: Impact?): (boolean, boolean)
	local z = active[model]
	if not z or not z.alive then
		return false, false
	end
	if z.phase2 and not (impact and impact.melee) then
		return false, false -- вторая фаза финального босса: огнестрел, турели, проволока и машины не берут
	end
	z.hp -= amount
	z.model:SetAttribute("Hp", math.max(0, z.hp))
	local ph = z.def.phase2
	if ph and not z.phase2 and z.hp > 0 and z.hp <= z.maxHp * ph.hpFraction and z.model:GetAttribute("Clone") ~= true then
		-- вторая фаза: рёв (руки к небу), с этого момента только способности и неуязвимость к огнестрелу
		z.phase2 = true
		z.model:SetAttribute("Phase2", true)
		refreshBossBar()
		setEyes(z, true)
		armPose(z, 175, 0.5)
		local pg = z.poseGen
		task.delay(1.6, function()
			if z.alive and z.poseGen == pg and not z.bossAct then
				armPose(z, 0, 0.5)
			end
		end)
		game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("Notify"):FireAllClients("Страж бункера вошёл во вторую фазу: огнестрел его не берёт — бейте холодным оружием!", 6)
	end
	if WaveMath.isBossType(z.def.id) then
		refreshBossBar()
	end
	-- горизонтальное направление удара: из импакта или от стрелка к зомби
	local flat = Vector3.zero
	if impact and impact.dir then
		flat = Vector3.new(impact.dir.X, 0, impact.dir.Z)
	elseif attacker and attacker.Character then
		local ar = attacker.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if ar then
			flat = Vector3.new(z.root.Position.X - ar.Position.X, 0, z.root.Position.Z - ar.Position.Z)
		end
	end
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zero
	local kind = if impact and impact.part then partKind(impact.part) else "Torso"
	if z.hp > 0 and impact then
		local now = os.clock()
		-- выстрел в голову останавливает дольше, в ногу — почти нет (зато хромает)
		local staggerScale = if kind == "Head" then 1.4 elseif kind == "Leg" then 0.5 else 1
		if impact.stagger then
			z.staggerUntil = math.max(z.staggerUntil, now + impact.stagger * staggerScale)
		end
		if impact.push and flat ~= Vector3.zero then
			z.root:ApplyImpulse(flat * impact.push * z.root.AssemblyMass)
		end
		if impact.part then
			flinch(z, kind, (string.gsub(impact.part.Name, "^Hit", "")), flat, impact.power or 1, now)
		end
	end
	if z.hp <= 0 then
		z.headKill = kind == "Head"
		spawnCorpse(z, flat, kind, impact ~= nil and impact.heavy == true)
		release(z)
		local isClone = z.model:GetAttribute("Clone") == true
		if z.def.attacks and (z.def.attacks :: any).clones and not isClone then
			-- настоящий босс убит: его тени рассыпаются
			local shadows: { Zombie } = {}
			for _, w in active do
				if w.alive and w.model:GetAttribute("Clone") == true then
					table.insert(shadows, w)
				end
			end
			for _, w in shadows do
				release(w)
			end
		end
		if onKilled and not isClone then -- за тень наград и очков нет
			(onKilled :: (Player?, Zombie) -> ())(attacker, z)
		end
		return true, true
	end
	return true, false
end

-- Живые зомби в радиусе от точки (для ближнего боя и ловушек): модель и корневая часть
function ZombieService.queryNear(pos: Vector3, radius: number): { { model: Model, root: BasePart } }
	local result: { { model: Model, root: BasePart } } = {}
	for model, z in active do
		if z.alive and (z.root.Position - pos).Magnitude <= radius then
			table.insert(result, { model = model, root = z.root })
		end
	end
	return result
end

-- Рассвет: мутанты не переносят солнце — загораются и гибнут за несколько секунд (без награды); очередь спавна сбрасывается
function ZombieService.sunrise()
	table.clear(queue)
	hazardGen += 1
	BossAI.clearAll()
	for model, z in active do
		if z.alive then
			local gen = z.gen
			local delay = 0.5 + math.random() * 3.5
			local fire = Instance.new("Fire")
			fire.Size = 9
			fire.Heat = 8
			fire.Parent = z.root
			Debris:AddItem(fire, delay + 0.4)
			task.delay(delay, function()
				if z.alive and z.gen == gen and active[model] == z then
					ZombieService.damage(model, z.hp + 1, nil, nil)
				end
			end)
		end
	end
end

-- Тип живого зомби по модели (машины: боссов не давим); nil — модель не активна или зомби мёртв
function ZombieService.defOf(model: Model): Config.ZombieDef?
	local z = active[model]
	return if z and z.alive then z.def else nil
end

function ZombieService.isZombiePart(part: BasePart): (Model?, boolean)
	-- модель зомби — ближайший предок из активных: деталь может лежать во вложенной Model (Top, Helmet, Chest у военных)
	local model: Model? = part:FindFirstAncestorOfClass("Model")
	while model and not active[model] do
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model") or nil
	end
	if model and active[model] then
		-- голова = сама голова, хитбокс меша и всё, что на ней надето (волосы, шапки, очки — аксессуары считаются частью головы)
		return model, partKind(part) == "Head"
	end
	return nil, false
end

-- Вид части тела для множителей урона: "Head" | "Torso" | "Arm" | "Leg"
function ZombieService.partKind(part: BasePart): string
	return partKind(part)
end

-- hpMult не указан — множители текущей ночи не меняются (добавка зомби без сброса силы волны)
function ZombieService.enqueue(types: { string }, hpMult: number?, wave: number?, front: boolean?)
	if hpMult then
		hpMultiplier = hpMult
		waveNumber = wave or 1
		damageMultiplier = WaveMath.damageMultiplier(Config.Waves, waveNumber)
	end
	for i, t in types do
		if front then
			table.insert(queue, i, t) -- вне очереди (тестовый стенд босса: поток миссии не пустеет и до конца очереди не дойти)
		else
			table.insert(queue, t)
		end
	end
end

-- Очередь спавна пустеет (живые остаются): ночь 19 заменяет состав волны на свой поток
function ZombieService.clearQueue()
	table.clear(queue)
end

function ZombieService.remaining(): number
	local n = #queue
	for _ in active do
		n += 1
	end
	return n
end

function ZombieService.clearAll()
	table.clear(queue)
	hazardGen += 1
	BossAI.clearAll()
	local list = {}
	for _, z in active do
		table.insert(list, z)
	end
	for _, z in list do
		release(z)
	end
end

-- Привязать сервис к новой локации (точки спавна); вызывается и при смене локации.
function ZombieService.setMap(mapInfo: Types.MapInfo)
	map = mapInfo
end

function ZombieService.init(mapInfo: Types.MapInfo, killedCallback: (Player?, any) -> ())
	map = mapInfo
	onKilled = killedCallback
	storage = Instance.new("Folder")
	storage.Name = "ZombiePool"
	storage.Parent = game:GetService("ServerStorage")
	container = Instance.new("Folder")
	container.Name = "Zombies"
	container.Parent = workspace
	worldParams.FilterDescendantsInstances = { container }

	PhysicsService:RegisterCollisionGroup(COLLISION_GROUP)
	-- зомби не толкаются друг с другом (толпа не застревает в окнах)
	PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, COLLISION_GROUP, false)

	-- меши частей тела грузим заранее, чтобы первый зомби не появлялся с задержкой
	task.spawn(function()
		for _, vis in Config.ZombieVisuals do
			for _, vp in vis.parts do
				loadMesh(vp.mesh)
				for _, ex in vp.extra or {} do
					loadMesh(ex.mesh)
				end
			end
		end
	end)

	-- спавн очередью: не больше N за тик и не больше лимита на карте
	task.spawn(function()
		while true do
			task.wait(Config.Round.SpawnTick)
			local alive = 0
			for _ in active do
				alive += 1
			end
			-- одновременно живых: 40 на игрока, остальные ждут в очереди
			local aliveCap = aliveCapOverride or math.max(Config.Round.ZombiesAliveMin, Config.Round.ZombiesAlivePerPlayer * #Players:GetPlayers())
			local testScale = Config.Waves.CountScale
			if testScale and testScale < 1 then
				aliveCap = math.max(4, math.floor(aliveCap * testScale + 0.5)) -- тестовое уменьшение числа зомби касается и бесконечного потока
			end
			local n = 0
			-- босс выходит вне лимита живых (иначе он ждал бы, пока погибнут все обычные)
			while #queue > 0 and n < Config.Round.SpawnsPerTick and (alive < aliveCap or WaveMath.isBossType(queue[1])) do
				local typeId = table.remove(queue, 1) :: string
				-- сломанный тип (например, риг без нужного сустава) пропускаем, а не роняем весь цикл спавна
				local ok, err = pcall(spawnOne, typeId)
				if not ok then
					warn(string.format("[ZombieService] не удалось создать зомби %s: %s", typeId, tostring(err)))
				end
				n += 1
				alive += 1
			end
		end
	end)

	-- потерявшиеся зомби: когда их осталось немного, а кто-то 25 с не приближается к игрокам (застрял, не нашёл путь) — переносим
	-- на новую точку появления и сбрасываем путь. В бесконечном потоке миссии очередь не пустеет — там проверяем всех живых всегда.
	-- Запись прогресса привязана к поколению зомби (gen): зомби из пула не наследует таймер прошлой жизни.
	task.spawn(function()
		local progress: { [Zombie]: { best: number, at: number, gen: number } } = {}
		local function relocateLost()
			local count = 0
			for _ in active do
				count += 1
			end
			for z in progress do
				if not z.alive or active[z.model] ~= z then
					progress[z] = nil
				end
			end
			if count > 0 and (streamMode or (#queue == 0 and count <= 12)) then
				local now = os.clock()
				local roots: { Vector3 } = {}
				for _, p in PlayerService.upPlayers() do
					local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if r then
						table.insert(roots, r.Position)
					end
				end
				if #roots > 0 then
					-- цели-НПС (грузовик и солдаты конвоя) тоже считаются: зомби у грузовика не потерялся
					for _, t in npcTargets do
						if t.root.Parent then
							table.insert(roots, t.root.Position)
						end
					end
					for _, z in active do
						if z.alive and z.state ~= "Breaking" then
							local dist = math.huge
							for _, r in roots do
								dist = math.min(dist, (z.root.Position - r).Magnitude)
							end
							local pr = progress[z]
							if not pr or pr.gen ~= z.gen or dist < pr.best - 4 then
								progress[z] = { best = dist, at = now, gen = z.gen }
							elseif now - pr.at > 25 and dist > 30 then
								local pos = pickSpawnPosition()
								if z.vaultTween then
									-- перелезал забор: твин больше не тянет корень обратно к забору
									cancelPose(z)
									z.vaultLockUntil = 0
								end
								z.model:PivotTo(CFrame.new(pos))
								z.gen += 1
								z.waypoints = nil
								z.pathBusy = false
								z.pathFailed = false
								z.stuckTime = 0
								z.lastPos = pos
								progress[z] = { best = math.huge, at = now, gen = z.gen }
							end
						end
					end
				end
			else
				table.clear(progress)
			end
		end
		while true do
			task.wait(3)
			local ok, err = pcall(relocateLost)
			if not ok then
				warn("[ZombieService] перенос потерявшихся: " .. tostring(err))
			end
		end
	end)

	-- единый цикл ИИ. Ошибка в одном зомби не должна останавливать всех: такого зомби убираем из мира насовсем
	-- (не в пул — он может быть сломан) и пишем предупреждение.
	local function stepZombie(z: Zombie, now: number, dt: number)
		think(z, now, dt)
		animate(z)
	end
	-- Бюджет поиска путей раздаётся по кругу: такт начинается с зомби, следующего за последним получившим путь,
	-- иначе при полном числе зомби пути получали бы всегда одни и те же (первые в обходе хэш-таблицы active).
	local order: { Zombie } = {}
	local startAt = 1
	task.spawn(function()
		while true do
			local dt = task.wait(Config.Round.AiTick)
			local now = os.clock()
			pathBudget = PATH_BUDGET
			collectTargets()
			local okBoss, errBoss = pcall(BossAI.update, now)
			if not okBoss then
				warn("[ZombieService] атаки боссов: " .. tostring(errBoss))
			end
			table.clear(order)
			for _, z in active do
				table.insert(order, z)
			end
			local n = #order
			if startAt > n then
				startAt = 1
			end
			local nextStart = startAt
			local spent = false
			for k = 0, n - 1 do
				local i = (startAt + k - 1) % n + 1
				local z = order[i]
				if z.alive and active[z.model] == z then
					local ok, err = pcall(stepZombie, z, now, dt)
					if not ok then
						warn(string.format("[ZombieService] ошибка ИИ у %s, зомби убран: %s", z.def.id, tostring(err)))
						z.alive = false
						active[z.model] = nil
						z.model:Destroy()
					end
					if not spent and pathBudget <= 0 then
						spent = true
						nextStart = i % n + 1
					end
				end
			end
			startAt = nextStart
		end
	end)

end

return ZombieService
