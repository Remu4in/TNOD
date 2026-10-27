--!strict
-- Атаки боссов 10 (Гаргантюа) и 15 (Повелитель тёмных). Вынесено из ZombieService, чтобы тот не рос: здесь только состояния атак и опасные зоны на земле,
-- а позы суставов, красные зоны, спавн зомби и прочее ZombieService передаёт через init(ctx).
--   slam     (Гаргантюа) — удар по земле: от точки удара к игроку ползёт линия растений, замедляет попавших (кувырок спасает)
--   crawlers (Гаргантюа) — снимает со спины ползуна и кидает в игрока: приземляется живым и атакует
--   charge   (Повелитель) — разбег: windup секунд набирает силу, перед ним на земле дорожка (в конце фиксируется), затем бежит по прямой и сбивает попавшего на пути
--   swing    (Повелитель) — чёрный взмах: горизонтальный замах и чёрная волна по прямой, гаснет у укрытия, кувырок спасает
-- Бросок знака (Гаргантюа) и прыжок с волной тьмы (Повелитель) живут в ZombieService: это доработанные бросок камня (rock.stun) и прыжок (jump.wave).
-- Каждой атаке — телеграф (поза, рисунок на земле), окно для уворота, урон/кулдаун в Config.Zombies[босс].attacks; урон считает только сервер.
-- Опасные зоны (растения, волна) живут в списке hazards и обновляются из единого цикла ИИ ZombieService (BossAI.update), своих циклов нет.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local BossAI = {}

export type Ctx = {
	container: () -> Instance, -- папка живых зомби (лучи по препятствиям её не видят)
	armPose: (z: any, deg: number, time: number) -> (),
	crouchPose: (z: any, amount: number, time: number) -> (),
	tweenJoint: (z: any, name: string, info: TweenInfo, c0: CFrame) -> (),
	setEyes: (z: any, alert: boolean) -> (),
	spawnAt: (typeId: string, pos: Vector3) -> any?, -- зомби по месту (вне очереди и лимита), nil — не вышло
	thrownAlive: () -> number, -- сколько брошенных ползунов живы
	damageMult: () -> number, -- множитель урона нынешней волны
	endAct: (z: any) -> (), -- закончить атаку босса (чистит зоны и вызывает cancel)
}
local ctx: Ctx

-- Опасные зоны на земле: step возвращает false, когда зона закончилась; cleanup убирает детали
type Hazard = { step: (now: number) -> boolean, cleanup: () -> () }
local hazards: { Hazard } = {}

local KINDS = { "slam", "crawlers", "charge", "swing" }
local rng = Random.new()

function BossAI.init(c: Ctx)
	ctx = c
end

-- Один раз за тик ИИ: растения и волны
function BossAI.update(now: number)
	for i = #hazards, 1, -1 do
		local h = hazards[i]
		if not h.step(now) then
			h.cleanup()
			table.remove(hazards, i)
		end
	end
end

-- Ночь кончилась / новый раунд: все зоны исчезают
function BossAI.clearAll()
	for _, h in hazards do
		h.cleanup()
	end
	table.clear(hazards)
end

function BossAI.isKind(kind: string): boolean
	return table.find(KINDS, kind) ~= nil
end

-- Первые разы атак после появления босса
function BossAI.firstTimes(def: Config.ZombieDef, now: number): { [string]: number }
	local out: { [string]: number } = {}
	local attacks = def.attacks :: any
	if attacks then
		for _, kind in KINDS do
			local d = attacks[kind]
			if d then
				out[kind] = now + d.first
			end
		end
	end
	return out
end

-- Какие атаки готовы: кулдаун прошёл, игрок в дальности (ползуны и разбег ещё требуют, чтобы босс видел игрока)
function BossAI.ready(z: any, now: number, dist: number, los: boolean): { string }
	local list: { string } = {}
	local attacks = z.def.attacks :: any
	if not attacks then
		return list
	end
	for _, kind in KINDS do
		local d = attacks[kind]
		if d and now >= (z.nextAtk[kind] or 0) and dist >= d.minRange and dist <= d.range then
			local ok = true
			if kind == "crawlers" then
				ok = los and ctx.thrownAlive() < d.maxAlive
			elseif kind == "charge" or kind == "swing" then
				ok = los
			end
			if ok then
				table.insert(list, kind)
			end
		end
	end
	return list
end

-- Вспомогательное ----------------------------------------------------------------------------------------------------

local function flatDir(from: Vector3, to: Vector3): Vector3
	local v = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	return if v.Magnitude > 0.05 then v.Unit else Vector3.new(0, 0, -1)
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Параметры лучей по препятствиям: без зомби, игроков и их машин-зон; обломки, растения и зоны CanQuery = false
local function obstacleParams(): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	local ex: { Instance } = { ctx.container() }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(ex, pl.Character)
		end
	end
	p.FilterDescendantsInstances = ex
	return p
end

local function groundPoint(pos: Vector3): Vector3
	local hit = workspace:Raycast(pos + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), obstacleParams())
	return if hit then hit.Position else Vector3.new(pos.X, pos.Y - 3, pos.Z)
end

-- Свободная длина вперёд от точки: ближайшее препятствие на трёх высотах (колени, грудь, голова) — ближе него и останавливаемся
local function clearLength(origin: Vector3, dir: Vector3, length: number): number
	local params = obstacleParams()
	local best = length
	for _, h in { 1.2, 3, 5 } do
		local hit = workspace:Raycast(origin + Vector3.new(0, h, 0), dir * length, params)
		if hit and hit.Distance < best then
			best = hit.Distance
		end
	end
	return best
end

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Parent = workspace
	return p
end

-- Дорожка-телеграф на земле: от origin по dir, length × width
local function placeStrip(strip: Part, origin: Vector3, dir: Vector3, length: number)
	local g = groundPoint(origin)
	strip.Size = Vector3.new(strip.Size.X, 0.12, length)
	strip.CFrame = CFrame.lookAt(Vector3.new(origin.X, g.Y + 0.2, origin.Z) + dir * length / 2, Vector3.new(origin.X, g.Y + 0.2, origin.Z) + dir * length * 1.5)
end

local function makeStrip(width: number): Part
	return part("BossStrip", Vector3.new(width, 0.12, 1), CFrame.new(), Color3.fromRGB(255, 50, 30), Enum.Material.Neon, 0.6)
end

-- Развернуть босса лицом по dir (он стоит на месте на время замаха)
local function face(z: any, dir: Vector3)
	local pos = z.root.Position
	z.root.CFrame = CFrame.lookAt(pos, pos + dir)
end

local function newAct(z: any, kind: string, now: number, windup: number, player: Player, data: any): any
	local act = { kind = kind, phase = "wind", endAt = now + windup, target = player, aim = z.root.Position, zone = {}, rock = nil, locked = false, data = data }
	z.bossAct = act
	return act
end

-- Удар по земле: линия растений ------------------------------------------------------------------------------------

local function makePlant(pos: Vector3): { Part }
	local h = 2.4 + rng:NextNumber() * 1.2
	local yaw = rng:NextNumber() * math.pi * 2
	local base = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
	local parts: { Part } = {}
	table.insert(parts, part("PlantStem", Vector3.new(0.5, h, 0.5), base * CFrame.new(0, h / 2, 0) * CFrame.Angles((rng:NextNumber() - 0.5) * 0.3, 0, 0), Color3.fromRGB(58, 102, 46), Enum.Material.Grass, 0))
	for k = -1, 1, 2 do
		table.insert(parts, part("PlantLeaf", Vector3.new(1.8, 0.12, 0.7), base * CFrame.new(k * 0.9, h * 0.5, 0) * CFrame.Angles(0, 0, math.rad(k * 28)), Color3.fromRGB(80, 142, 58), Enum.Material.Grass, 0))
	end
	local bulb = part("PlantBulb", Vector3.new(0.9, 0.9, 0.9), base * CFrame.new(0, h, 0), Color3.fromRGB(118, 44, 92), Enum.Material.SmoothPlastic, 0)
	bulb.Shape = Enum.PartType.Ball
	table.insert(parts, bulb)
	return parts
end

local function startPlants(origin: Vector3, dir: Vector3, d: Config.BossSlam)
	local STEP = 3.2
	local total = math.max(1, math.floor(d.length / STEP))
	local started = os.clock()
	local planted = 0
	local plants: { { parts: { Part }, pos: Vector3, dieAt: number } } = {}
	local slowedAt: { [Player]: number } = {}
	local hazard: Hazard
	hazard = {
		step = function(now: number): boolean
			-- линия «ползёт»: новое растение, как только фронт прошёл очередные STEP студов
			while planted < total and (planted + 1) * STEP <= (now - started) * d.speed do
				planted += 1
				local p = groundPoint(origin + dir * (planted * STEP))
				table.insert(plants, { parts = makePlant(p), pos = p, dieAt = now + d.life })
			end
			for i = #plants, 1, -1 do
				if now >= plants[i].dieAt then
					for _, pt in plants[i].parts do
						pt:Destroy()
					end
					table.remove(plants, i)
				end
			end
			for _, player in PlayerService.upPlayers() do
				local root = rootOf(player)
				if root and now - (slowedAt[player] or 0) > 0.4 then
					for _, pl in plants do
						local flat = Vector3.new(root.Position.X - pl.pos.X, 0, root.Position.Z - pl.pos.Z).Magnitude
						if flat <= d.width / 2 + 1.5 and math.abs(root.Position.Y - pl.pos.Y) < 6 then
							slowedAt[player] = now
							PlayerService.slow(player, d.slowMult, d.slowSeconds) -- кувырок (неуязвимость) не даёт замедлить
							break
						end
					end
				end
			end
			return planted < total or #plants > 0
		end,
		cleanup = function()
			for _, pl in plants do
				for _, pt in pl.parts do
					pt:Destroy()
				end
			end
			table.clear(plants)
		end,
	}
	table.insert(hazards, hazard)
end

local function beginSlam(z: any, player: Player, targetRoot: BasePart, now: number): boolean
	local d = (z.def.attacks :: any).slam :: Config.BossSlam
	local dir = flatDir(z.root.Position, targetRoot.Position)
	local act = newAct(z, "slam", now, d.windup, player, { dir = dir, strip = makeStrip(d.width), lockAt = now + d.windup - 0.4 })
	z.humanoid:MoveTo(z.root.Position)
	ctx.setEyes(z, true)
	ctx.armPose(z, 160, d.windup * 0.8) -- оружие над головой
	ctx.crouchPose(z, 0.25, d.windup * 0.6)
	act.zone = {}
	return true
end

local function stepSlam(z: any, act: any, now: number)
	local d = (z.def.attacks :: any).slam :: Config.BossSlam
	local data = act.data
	z.humanoid:MoveTo(z.root.Position)
	if act.phase == "wind" then
		if now < data.lockAt then
			local r = rootOf(act.target)
			if r and PlayerService.isUp(act.target) then
				data.dir = flatDir(z.root.Position, r.Position)
			end
		end
		face(z, data.dir)
		local origin = z.root.Position + data.dir * (4 + z.def.scale)
		placeStrip(data.strip, origin, data.dir, d.length)
		if now >= data.lockAt then
			data.strip.Transparency = 0.3 -- направление зафиксировано
		end
		if now >= act.endAt then
			act.phase = "recover"
			act.endAt = now + 0.7
			data.strip:Destroy()
			ctx.armPose(z, -15, 0.12) -- удар в землю
			ctx.crouchPose(z, 0.5, 0.12)
			z.model:SetAttribute("SwingAt", os.clock())
			startPlants(z.root.Position + data.dir * (4 + z.def.scale), data.dir, d)
			z.nextAtk.slam = now + d.cooldown
			z.lastAttack = now
		end
	elseif now >= act.endAt then
		ctx.armPose(z, 0, 0.4)
		ctx.crouchPose(z, 0, 0.4)
		ctx.setEyes(z, false)
		ctx.endAct(z)
	end
end

-- Бросок ползуна ---------------------------------------------------------------------------------------------------

local function backCf(z: any): CFrame
	return z.root.CFrame * CFrame.new(0, 1.2 + z.root.Size.Y * 0.2, z.root.Size.Z * 0.9) * CFrame.Angles(math.rad(-80), 0, 0)
end

local function beginCrawlers(z: any, player: Player, targetRoot: BasePart, now: number): boolean
	local d = (z.def.attacks :: any).crawlers :: Config.BossCrawlers
	local c = ctx.spawnAt("Crawler", backCf(z).Position)
	if not c then
		return false
	end
	-- ползун на спине: стоит неподвижно и «не думает», пока босс не бросит
	c.vaultLockUntil = math.huge
	c.root.Anchored = true
	c.model:SetAttribute("Thrown", true)
	newAct(z, "crawlers", now, d.windup, player, { crawler = c, thrown = false, armed = false })
	z.humanoid:MoveTo(z.root.Position)
	ctx.setEyes(z, true)
	ctx.armPose(z, -70, d.windup * 0.45) -- тянется за спину
	return true
end

local function releaseCrawler(data: any)
	local c = data and data.crawler
	if c and not data.thrown then
		data.thrown = true
		c.vaultLockUntil = 0
		c.root.Anchored = false
	end
end

local function stepCrawlers(z: any, act: any, now: number)
	local d = (z.def.attacks :: any).crawlers :: Config.BossCrawlers
	local data = act.data
	local c = data.crawler
	z.humanoid:MoveTo(z.root.Position)
	if act.phase == "wind" then
		if not c.alive or not c.model.Parent then
			ctx.armPose(z, 0, 0.3)
			ctx.setEyes(z, false)
			ctx.endAct(z)
			return
		end
		c.model:PivotTo(backCf(z))
		local r = rootOf(act.target)
		if r and PlayerService.isUp(act.target) then
			face(z, flatDir(z.root.Position, r.Position))
		end
		if not data.armed and now >= act.endAt - 0.4 then
			data.armed = true
			ctx.armPose(z, 150, 0.35) -- замах над головой
		end
		if now >= act.endAt then
			-- бросок в то место, где игрок стоит сейчас
			local aim = z.root.Position + z.root.CFrame.LookVector * 20
			local tr = rootOf(act.target)
			if tr and PlayerService.isUp(act.target) then
				aim = groundPoint(tr.Position)
			end
			data.thrown = true
			local gen = c.gen
			local from = c.root.CFrame
			local to = CFrame.new(aim + Vector3.new(0, c.root.Size.Y * 0.5 + 1.5, 0)) * from.Rotation
			local apex = CFrame.new((from.Position + to.Position) / 2 + Vector3.new(0, 14, 0)) * from.Rotation
			local half = d.flight / 2
			local up = TweenService:Create(c.root, TweenInfo.new(half, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = apex })
			c.vaultTween = up
			up.Completed:Once(function(state: Enum.PlaybackState)
				if c.vaultTween ~= up or state ~= Enum.PlaybackState.Completed or c.gen ~= gen then
					return
				end
				local down = TweenService:Create(c.root, TweenInfo.new(half, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = to })
				c.vaultTween = down
				down.Completed:Once(function(downState: Enum.PlaybackState)
					if c.vaultTween ~= down or downState ~= Enum.PlaybackState.Completed or c.gen ~= gen then
						return
					end
					c.vaultTween = nil
					c.vaultLockUntil = 0 -- приземлился живым: дальше думает как обычный зомби
					c.root.Anchored = false
				end)
				down:Play()
			end)
			up:Play()
			ctx.armPose(z, 0, 0.35)
			z.model:SetAttribute("SwingAt", os.clock())
			z.nextAtk.crawlers = now + d.cooldown
			z.lastAttack = now
			act.phase = "recover"
			act.endAt = now + 0.5
		end
	elseif now >= act.endAt then
		ctx.setEyes(z, false)
		ctx.endAct(z)
	end
end

-- Разбег --------------------------------------------------------------------------------------------------------------

local function beginCharge(z: any, player: Player, targetRoot: BasePart, now: number): boolean
	local d = (z.def.attacks :: any).charge :: Config.BossCharge
	local dir = flatDir(z.root.Position, targetRoot.Position)
	newAct(z, "charge", now, d.windup, player, { dir = dir, strip = makeStrip(d.width), lockAt = now + d.windup - d.lockBefore, hit = {}, endPoint = Vector3.zero, startPos = Vector3.zero, runUntil = 0 })
	z.humanoid:MoveTo(z.root.Position)
	ctx.setEyes(z, true)
	ctx.crouchPose(z, 0.7, d.windup * 0.7) -- набирает силу: присел, руки назад
	ctx.armPose(z, -50, d.windup * 0.7)
	return true
end

local function endCharge(z: any, act: any, now: number)
	local d = (z.def.attacks :: any).charge :: Config.BossCharge
	z.humanoid.WalkSpeed = z.speed
	z.humanoid:MoveTo(z.root.Position)
	ctx.armPose(z, 0, 0.4)
	z.nextAtk.charge = now + d.cooldown
	z.lastAttack = now
	act.phase = "recover"
	act.endAt = now + d.recover
end

local function stepCharge(z: any, act: any, now: number)
	local d = (z.def.attacks :: any).charge :: Config.BossCharge
	local data = act.data
	if act.phase == "wind" then
		z.humanoid:MoveTo(z.root.Position)
		if now < data.lockAt then
			local r = rootOf(act.target)
			if r and PlayerService.isUp(act.target) then
				data.dir = flatDir(z.root.Position, r.Position)
			end
		else
			data.strip.Transparency = 0.25 -- направление зафиксировано: пора уходить с дорожки
		end
		face(z, data.dir)
		placeStrip(data.strip, z.root.Position + data.dir * 2, data.dir, d.distance)
		if now >= act.endAt then
			local start = z.root.Position
			local length = math.max(8, clearLength(Vector3.new(start.X, groundPoint(start).Y, start.Z), data.dir, d.distance + 3) - 4)
			length = math.min(length, d.distance)
			data.startPos = start
			data.endPoint = start + data.dir * length
			data.runUntil = now + length / d.speed + 1.5
			data.strip:Destroy()
			ctx.crouchPose(z, 0, 0.15)
			ctx.armPose(z, -25, 0.2)
			z.humanoid.WalkSpeed = d.speed
			act.phase = "run"
			z.model:SetAttribute("SwingAt", os.clock())
		end
	elseif act.phase == "run" then
		z.humanoid:MoveTo(data.endPoint)
		local pos = z.root.Position
		local a = Vector3.new(data.startPos.X, 0, data.startPos.Z)
		local b = Vector3.new(pos.X, 0, pos.Z)
		local ab = b - a
		for _, player in PlayerService.upPlayers() do
			local r = rootOf(player)
			if r and not data.hit[player] then
				local p = Vector3.new(r.Position.X, 0, r.Position.Z)
				local t = if ab.Magnitude > 0.01 then math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1) else 0
				local closest = a + ab * t
				if (p - closest).Magnitude <= d.width / 2 + 1.5 and math.abs(r.Position.Y - pos.Y) < 8 then
					data.hit[player] = true
					PlayerService.damage(player, d.damage * ctx.damageMult()) -- кувырок (неуязвимость) отменяет урон внутри damage
				end
			end
		end
		local left = Vector3.new(data.endPoint.X - pos.X, 0, data.endPoint.Z - pos.Z).Magnitude
		if left < 3 or now >= data.runUntil then
			endCharge(z, act, now)
		end
	elseif now >= act.endAt then
		ctx.setEyes(z, false)
		ctx.endAct(z)
	else
		z.humanoid:MoveTo(z.root.Position)
	end
end

-- Чёрный взмах ---------------------------------------------------------------------------------------------------------

local function twist(z: any, deg: number, time: number)
	local waist = CFrame.new(z.pivots.Torso)
	ctx.tweenJoint(z, "Torso", TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), waist * CFrame.Angles(0, math.rad(deg), 0) * waist:Inverse() * z.rest.Torso)
end

local function launchWave(z: any, dir: Vector3, d: Config.BossSwing)
	local from = z.root.Position + dir * (2 + z.def.scale)
	local g = groundPoint(from)
	local origin = Vector3.new(from.X, g.Y + 3, from.Z)
	local length = math.max(4, clearLength(Vector3.new(origin.X, g.Y, origin.Z), dir, d.length + 2) - 1)
	length = math.min(length, d.length)
	local wave = part("BossDarkWave", Vector3.new(0.5, d.width, d.width), CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(12, 8, 20), Enum.Material.SmoothPlastic, 0.15)
	wave.Shape = Enum.PartType.Cylinder
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(150, 90, 255)
	light.Range = 14
	light.Brightness = 1.2
	light.Parent = wave
	local trail = Instance.new("ParticleEmitter")
	trail.Color = ColorSequence.new(Color3.fromRGB(20, 12, 30))
	trail.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 0) })
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime = NumberRange.new(0.4, 0.7)
	trail.Speed = NumberRange.new(0, 2)
	trail.Rate = 40
	trail.Parent = wave
	local flightTime = length / d.speed
	local target = CFrame.new(origin + dir * length) * CFrame.Angles(0, 0, math.rad(90))
	TweenService:Create(wave, TweenInfo.new(flightTime, Enum.EasingStyle.Linear), { CFrame = target }):Play()
	local started = os.clock()
	local hit: { [Player]: boolean } = {}
	local fading = false
	local prev = origin
	table.insert(hazards, {
		step = function(now: number): boolean
			if not wave.Parent then
				return false
			end
			if not fading then
				-- ИИ тикает раз в 0,2 с, а волна пролетает до 12 студов за тик: проверяем отрезок от прошлой позиции до нынешней, а не одну точку
				local cur = wave.Position
				local a = Vector3.new(prev.X, 0, prev.Z)
				local ab = Vector3.new(cur.X, 0, cur.Z) - a
				for _, player in PlayerService.upPlayers() do
					local r = rootOf(player)
					if r and not hit[player] then
						local p = Vector3.new(r.Position.X, 0, r.Position.Z)
						local t = if ab.Magnitude > 0.01 then math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1) else 0
						local flat = (p - (a + ab * t)).Magnitude
						if flat <= d.width / 2 + 0.8 and math.abs(r.Position.Y - cur.Y) <= 4.5 then
							hit[player] = true
							PlayerService.damage(player, d.damage * ctx.damageMult()) -- кувырок отменяет урон; укрытие — волна гаснет у него (length)
						end
					end
				end
				prev = cur
				if now - started >= flightTime then
					fading = true
					TweenService:Create(wave, TweenInfo.new(0.3), { Transparency = 1 }):Play()
					started = now
				end
				return true
			end
			return now - started < 0.35
		end,
		cleanup = function()
			wave:Destroy()
		end,
	})
end

local function beginSwing(z: any, player: Player, targetRoot: BasePart, now: number): boolean
	local d = (z.def.attacks :: any).swing :: Config.BossSwing
	local dir = flatDir(z.root.Position, targetRoot.Position)
	newAct(z, "swing", now, d.windup, player, { dir = dir, lockAt = now + d.windup - 0.3, struck = false })
	z.humanoid:MoveTo(z.root.Position)
	ctx.setEyes(z, true)
	twist(z, 70, d.windup * 0.8) -- корпус закручивается назад
	ctx.armPose(z, 85, d.windup * 0.7)
	return true
end

local function stepSwing(z: any, act: any, now: number)
	local d = (z.def.attacks :: any).swing :: Config.BossSwing
	local data = act.data
	z.humanoid:MoveTo(z.root.Position)
	if act.phase == "wind" then
		if now < data.lockAt then
			local r = rootOf(act.target)
			if r and PlayerService.isUp(act.target) then
				data.dir = flatDir(z.root.Position, r.Position)
			end
		end
		face(z, data.dir)
		if now >= act.endAt then
			twist(z, -70, 0.14) -- взмах
			launchWave(z, data.dir, d)
			z.model:SetAttribute("SwingAt", os.clock())
			z.nextAtk.swing = now + d.cooldown
			z.lastAttack = now
			act.phase = "recover"
			act.endAt = now + 0.6
		end
	elseif now >= act.endAt then
		twist(z, 0, 0.3)
		ctx.armPose(z, 0, 0.3)
		ctx.setEyes(z, false)
		ctx.endAct(z)
	end
end

-- Вход ---------------------------------------------------------------------------------------------------------------------

-- Начать атаку kind; false — не вышло (босс остаётся свободным)
function BossAI.begin(z: any, kind: string, player: Player, targetRoot: BasePart, now: number): boolean
	if kind == "slam" then
		return beginSlam(z, player, targetRoot, now)
	elseif kind == "crawlers" then
		return beginCrawlers(z, player, targetRoot, now)
	elseif kind == "charge" then
		return beginCharge(z, player, targetRoot, now)
	elseif kind == "swing" then
		return beginSwing(z, player, targetRoot, now)
	end
	return false
end

function BossAI.step(z: any, act: any, now: number)
	local kind = act.kind
	if kind == "slam" then
		stepSlam(z, act, now)
	elseif kind == "crawlers" then
		stepCrawlers(z, act, now)
	elseif kind == "charge" then
		stepCharge(z, act, now)
	elseif kind == "swing" then
		stepSwing(z, act, now)
	end
end

-- Атака прервана (смерть босса, пул, новая ночь): убираем рисунки на земле, отпускаем ползуна, возвращаем скорость
function BossAI.cancel(z: any, act: any)
	local data = act.data
	if not data then
		return
	end
	local strip = data.strip :: Part?
	if strip then
		strip:Destroy()
	end
	releaseCrawler(data)
	if act.kind == "charge" then
		z.humanoid.WalkSpeed = z.speed
	end
end

return BossAI
