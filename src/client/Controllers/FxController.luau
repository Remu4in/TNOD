--!strict
-- «Сочность» стрельбы и ближнего боя (только косметика на клиенте):
-- выстрел (отдача ствола, вспышка, толчок камеры, гильзы), пули (светящаяся «пуля» с хвостом),
-- попадание (искры, кровь, вспышка зомби), взмах оружия ближнего боя, звуки — в WeaponSfx.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WeaponSfx = require(Shared:WaitForChild("WeaponSfx"))
local MeleeAnim = require(Shared:WaitForChild("MeleeAnim"))
local Rewind = require(Shared:WaitForChild("Rewind"))
local ViewModel = require(script.Parent:WaitForChild("ViewModelController"))

local FxController = {}

local player = Players.LocalPlayer

local function folder(): Folder
	local f = workspace:FindFirstChild("ClientFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "ClientFx"
		f.Parent = workspace
	end
	return f :: Folder
end

local function toolOf(char: Model?): Tool?
	return char and char:FindFirstChildOfClass("Tool")
end

local function handleOf(tool: Tool): BasePart?
	return tool:FindFirstChild("Handle") :: BasePart?
end

-- Дуло: самая передняя (-Z) точка мешей оружия в системе координат рукояти (считаем один раз на оружие)
local muzzleCache: { [Tool]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any -- слабые ключи: Tool выбрасываются и пересоздаются

local function muzzleOffset(tool: Tool): Vector3
	local cached = muzzleCache[tool]
	if cached then
		return cached
	end
	local handle = handleOf(tool)
	local result = Vector3.new(0, 0, -1)
	if handle then
		local minZ = math.huge
		local corners: { Vector3 } = {}
		for _, d in tool:GetChildren() do
			if d:IsA("MeshPart") then
				local half = d.Size / 2
				for _, sx in { -1, 1 } do
					for _, sy in { -1, 1 } do
						for _, sz in { -1, 1 } do
							local c = handle.CFrame:PointToObjectSpace(d.CFrame:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)))
							table.insert(corners, c)
							minZ = math.min(minZ, c.Z)
						end
					end
				end
			end
		end
		local sx, sy, n = 0, 0, 0
		for _, c in corners do
			if c.Z <= minZ + 0.2 then
				sx += c.X
				sy += c.Y
				n += 1
			end
		end
		if n > 0 then
			result = Vector3.new(sx / n, sy / n + 0.05, minZ - 0.05)
		end
	end
	muzzleCache[tool] = result
	return result
end

local function muzzleWorld(tool: Tool): Vector3?
	local vm = ViewModel.muzzleWorld(tool)
	if vm then
		return vm
	end
	local handle = handleOf(tool)
	return if handle then handle.CFrame:PointToWorldSpace(muzzleOffset(tool)) else nil
end

-- Частицы -------------------------------------------------------------

local activeBursts = 0
local MAX_BURSTS = 30

local function burst(pos: Vector3, color: Color3, count: number, speedMin: number, speedMax: number, size: number, life: number, glow: boolean)
	if activeBursts >= MAX_BURSTS then
		return
	end
	activeBursts += 1
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.Position = pos
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Lifetime = NumberRange.new(life * 0.6, life)
	e.Speed = NumberRange.new(speedMin, speedMax)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	e.Color = ColorSequence.new(color)
	e.LightEmission = if glow then 1 else 0
	e.Acceleration = Vector3.new(0, -40, 0)
	e.Drag = 2
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Parent = anchor
	anchor.Parent = folder()
	e:Emit(count)
	Debris:AddItem(anchor, life + 0.2)
	task.delay(life + 0.2, function()
		activeBursts -= 1
	end)
end

-- Кровь на полу и осколки ----------------------------------------------

local MAX_PUDDLES = 40
local puddles: { Part } = {}
local shardCount = 0

-- Лужа или брызги на поверхности под точкой попадания; старые исчезают, когда их больше MAX_PUDDLES
local function bloodSplat(pos: Vector3, size: number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { folder() }
	for _, name in { "Zombies", "Corpses", "Soldiers" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(ignore, f)
		end
	end
	if player.Character then
		table.insert(ignore, player.Character)
	end
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(pos + Vector3.new(0, 1.5, 0), Vector3.new((math.random() - 0.5) * 3, -14, (math.random() - 0.5) * 3), params)
	if not hit or hit.Normal.Y < 0.5 or not hit.Instance.Anchored then
		return
	end
	if #puddles >= MAX_PUDDLES then
		local old = table.remove(puddles, 1)
		if old then
			old:Destroy()
		end
	end
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.04, size, size * (0.7 + math.random() * 0.5))
	p.Color = Color3.fromRGB(70 + math.random(0, 25), 4, 4)
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = CFrame.lookAt(hit.Position + hit.Normal * 0.03, hit.Position + hit.Normal) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, math.rad(math.random(0, 359)))
	p.Parent = folder()
	table.insert(puddles, p)
	task.delay(30, function()
		if p.Parent then
			TweenService:Create(p, TweenInfo.new(6), { Transparency = 1 }):Play()
			Debris:AddItem(p, 6.5)
		end
	end)
end

-- Осколки: мелкие обломки разлетаются от точки попадания и пропадают
local function shards(pos: Vector3, normalUp: Vector3?, count: number, color: Color3)
	for _ = 1, count do
		if shardCount >= 36 then
			return
		end
		shardCount += 1
		local c = Instance.new("Part")
		c.Size = Vector3.new(0.08 + math.random() * 0.12, 0.05 + math.random() * 0.08, 0.1 + math.random() * 0.15)
		c.Color = color
		c.Material = Enum.Material.Concrete
		c.CanQuery = false
		c.CanTouch = false
		c.CFrame = CFrame.new(pos) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		local dir = Vector3.new(math.random() - 0.5, math.random() * 0.8 + 0.2, math.random() - 0.5).Unit
		c.AssemblyLinearVelocity = dir * (8 + math.random() * 12) + (normalUp or Vector3.zero) * 6
		c.AssemblyAngularVelocity = Vector3.new(math.random(-20, 20), math.random(-20, 20), math.random(-20, 20))
		c.Parent = folder()
		Debris:AddItem(c, 1.6)
		task.delay(1.6, function()
			shardCount -= 1
		end)
	end
end

-- Выстрел --------------------------------------------------------------

-- живых PointLight вспышек: при 6 стрелках с автоматами не больше Config.Visual.Muzzle.MaxLights, остальные вспышки — только неон
local flashLights = 0

local function muzzleFlash(tool: Tool, size: number)
	local pos = muzzleWorld(tool)
	local handle = handleOf(tool)
	if not pos or not handle then
		return
	end
	local m = Config.Visual.Muzzle
	local s = size * m.SizeMul
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 205, 100)
	flash.Size = Vector3.one * s * 0.5
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.CFrame = CFrame.new(pos)
	if flashLights < m.MaxLights then
		flashLights += 1
		local light = Instance.new("PointLight")
		light.Range = m.RangeBase + size * m.RangePerSize
		light.Brightness = m.Brightness
		light.Color = m.Color
		light.Shadows = false
		light.Parent = flash
		TweenService:Create(light, TweenInfo.new(0.08), { Brightness = 0 }):Play()
		task.delay(0.09, function()
			flashLights -= 1
		end)
	end
	flash.Parent = folder()
	TweenService:Create(flash, TweenInfo.new(0.07), { Size = Vector3.one * s * 1.3, Transparency = 1 }):Play()
	Debris:AddItem(flash, 0.09)
	burst(pos, Color3.fromRGB(255, 200, 100), 4, 8, 20, 0.16, 0.18, true)
end

local shellCount = 0

local function ejectShell(tool: Tool)
	local handle = handleOf(tool)
	local handleCf = ViewModel.handleCFrame(tool) or (handle and handle.CFrame)
	if not handle or not handleCf or shellCount >= 24 then
		return
	end
	shellCount += 1
	local shell = Instance.new("Part")
	shell.Size = Vector3.new(0.06, 0.06, 0.2)
	shell.Color = Color3.fromRGB(205, 165, 60)
	shell.Material = Enum.Material.Metal
	shell.CanQuery = false
	shell.CanTouch = false
	local cf = handleCf * CFrame.new(0.1, 0.25, -0.2)
	shell.CFrame = cf * CFrame.Angles(math.random() * 3, math.random() * 3, 0)
	shell.AssemblyLinearVelocity = cf.RightVector * (7 + math.random() * 5) + cf.UpVector * (6 + math.random() * 4) + cf.LookVector * (math.random() * 3)
	shell.AssemblyAngularVelocity = Vector3.new(math.random(-30, 30), math.random(-30, 30), math.random(-30, 30))
	shell.Parent = folder()
	Debris:AddItem(shell, 1.3)
	task.delay(1.3, function()
		shellCount -= 1
	end)
end

-- Светящаяся «пуля» с хвостом летит от дула к точке попадания
function FxController.tracer(shooter: Player, origin: Vector3, hit: Vector3)
	local tool = toolOf(shooter.Character)
	local start = (tool and muzzleWorld(tool)) or origin
	local delta = hit - start
	local dist = delta.Magnitude
	if dist < 1 then
		return
	end
	local dir = delta.Unit
	local tr = Config.Visual.Tracer
	local len = math.min(tr.Length, dist)
	local streak = Instance.new("Part")
	streak.Material = Enum.Material.Neon
	streak.Color = if shooter == player then tr.OwnColor else tr.OtherColor
	streak.CastShadow = false
	streak.Size = Vector3.new(tr.Width, tr.Width, len)
	streak.Anchored = true
	streak.CanCollide = false
	streak.CanQuery = false
	streak.CanTouch = false
	streak.CFrame = CFrame.lookAt(start + dir * (len / 2), start + dir * len)
	streak.Parent = folder()
	local time = math.clamp(dist / 520, 0.04, 0.3)
	local endCenter = start + dir * (dist - len / 2)
	TweenService:Create(streak, TweenInfo.new(time, Enum.EasingStyle.Linear), {
		CFrame = CFrame.lookAt(endCenter, endCenter + dir),
		Transparency = 0.8,
	}):Play()
	Debris:AddItem(streak, time + 0.03)
end

-- Попадание в мир: искры и «пинг»
function FxController.impact(pos: Vector3)
	burst(pos, Color3.fromRGB(255, 215, 130), 5, 10, 24, 0.18, 0.22, true)
	shards(pos, nil, 3, Color3.fromRGB(120, 118, 112))
	WeaponSfx.ping(pos)
end

-- Попадание по зомби: кровь и белая вспышка модели
local function flashZombie(pos: Vector3)
	local zf = workspace:FindFirstChild("Zombies")
	if not zf then
		return
	end
	local best: Model? = nil
	local bestDist = 6
	for _, m in zf:GetChildren() do
		if m:IsA("Model") and m.PrimaryPart then
			local d = (m.PrimaryPart.Position - pos).Magnitude
			if d < bestDist and not m:FindFirstChild("HitFlash") then
				best, bestDist = m, d
			end
		end
	end
	if best then
		local h = Instance.new("Highlight")
		h.Name = "HitFlash"
		h.FillColor = Color3.new(1, 1, 1)
		h.FillTransparency = 0.25
		h.OutlineTransparency = 1
		h.Parent = best
		TweenService:Create(h, TweenInfo.new(0.12), { FillTransparency = 1 }):Play()
		Debris:AddItem(h, 0.14)
	end
end

-- Отдача: толчок камеры и ствола -----------------------------------------

local recoil = { pitch = 0, yaw = 0, roll = 0 } -- радианы, затухают сами
local kick = { back = 0, rot = 0 }

local function kickCamera(pitchDeg: number, yawDeg: number, rollDeg: number)
	recoil.pitch = math.min(math.rad(9), recoil.pitch + math.rad(pitchDeg))
	recoil.yaw += math.rad((math.random() * 2 - 1) * yawDeg)
	recoil.roll += math.rad((math.random() * 2 - 1) * rollDeg)
end

function FxController.onLocalShot(tool: Tool, weaponId: string)
	local fx = Config.WeaponFx[weaponId]
	if not fx then
		return
	end
	kick.back = math.min(kick.back + fx.kickBack, 0.8)
	kick.rot = math.min(kick.rot + math.rad(fx.kickRot), math.rad(22))
	ViewModel.kick(weaponId)
	-- подъём и увод прицела делает WeaponController по предсказуемой закономерности (Ballistics.recoilStep),
	-- здесь — только лёгкая «дрожь» кадра, не влияющая на прицел
	kickCamera(0, 0, 0.3)
	muzzleFlash(tool, fx.flash)
	if fx.shell then
		ejectShell(tool)
	end
end

function FxController.onRemoteShot(shooter: Player, weaponId: string)
	local fx = Config.WeaponFx[weaponId]
	local tool = toolOf(shooter.Character)
	if fx and tool then
		muzzleFlash(tool, fx.flash)
		if fx.shell then
			ejectShell(tool)
		end
	end
end

-- Попадание, о котором сообщил сервер (только стрелку): кровь, вспышка, для ближнего боя — тряска
function FxController.onHit(pos: Vector3, damage: number, killed: boolean, headshot: boolean)
	-- выстрел в голову — заметно больше крови и жёлтая вспышка
	local count = if headshot then (if killed then 34 else 20) elseif killed then 26 else 12
	burst(pos, Color3.fromRGB(165, 12, 12), count, 8, if killed or headshot then 34 else 22, 0.34, 0.55, false)
	if headshot then
		burst(pos, Color3.fromRGB(255, 220, 90), 8, 10, 26, 0.18, 0.3, false)
		-- приземлённо: плотный красный выброс и крупные капли, без экранных надписей (обзор не закрываем)
		burst(pos, Color3.fromRGB(120, 6, 6), if killed then 22 else 12, 14, 38, 0.5, 0.45, false)
	end
	flashZombie(pos)
	bloodSplat(pos, if killed then 3.2 + math.random() * 1.5 else 0.8 + math.random() * 0.8)
	if killed then
		for _ = 1, 3 do
			bloodSplat(pos + Vector3.new((math.random() - 0.5) * 4, 0, (math.random() - 0.5) * 4), 0.5 + math.random() * 0.7)
		end
	end
	local tool = toolOf(player.Character)
	if tool and tool:GetAttribute("Melee") == true then
		local fx = Config.MeleeFx[tostring(tool:GetAttribute("WeaponId"))]
		local shake = if fx then fx.shake else 2
		kickCamera(shake, shake * 0.6, shake * 0.8)
	end
end

-- Взмах ближнего боя: рукоять двигается по ключевым позам (через Tool.Grip), камера подаётся вперёд
-- Позы взмахов и осмотра — в Shared/MeleeAnim
local swing: { tool: Tool, style: string, started: number, duration: number, baseGrip: CFrame }? = nil
-- Взмахи других игроков (по событию MeleeFx): у них двигается только рука — Tool.Grip чужого оружия мы не трогаем
local remoteSwings: { [Model]: { style: string, started: number, duration: number } } = {}

local function poseAt(style: string, u: number): CFrame
	return MeleeAnim.poseAt(style, u)
end

-- Рука при взмахе (вид от 3 лица и чужие игроки): правое плечо (R15 — RightUpperArm.RightShoulder, R6 — Torso."Right Shoulder")
-- поворачивается по позе: наклон оружия вперёд = рука вперёд, рыскание = рука в сторону. Исходный C0 запоминаем один раз.
local shoulderBase: { [Motor6D]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function shoulderOf(char: Model): Motor6D?
	local upper = char:FindFirstChild("RightUpperArm")
	local m = if upper then upper:FindFirstChild("RightShoulder") else nil
	if not m then
		local torso = char:FindFirstChild("Torso")
		m = if torso then torso:FindFirstChild("Right Shoulder") else nil
	end
	return if m and m:IsA("Motor6D") then m else nil
end

-- pose = nil — вернуть руку на место
local function setArmPose(char: Model, pose: CFrame?)
	local m = shoulderOf(char)
	if not m then
		return
	end
	local base = shoulderBase[m]
	if not base then
		if not pose then
			return
		end
		base = m.C0
		shoulderBase[m] = base
	end
	if pose then
		local rx, ry, rz = pose:ToEulerAnglesXYZ()
		m.C0 = (base :: CFrame) * CFrame.Angles(-rx * 0.9, ry * 0.8, rz * 0.4)
	else
		m.C0 = base :: CFrame
	end
end

-- Серия ударов у себя: номер считаем тем же правилом, что и сервер (MeleeAnim.nextIndex, окно Config.MeleeCombo), от своего времени нажатия
local localCombo: { index: number, at: number, weaponId: string }? = nil

function FxController.onLocalSwing(tool: Tool, weaponId: string)
	if not Config.MeleeFx[weaponId] then
		return
	end
	local now = os.clock()
	local last = localCombo
	local prev, since = 0, math.huge
	if last and last.weaponId == weaponId then
		prev, since = last.index, now - last.at
	end
	local index = MeleeAnim.nextIndex(weaponId, prev, since)
	localCombo = { index = index, at = now, weaponId = weaponId }
	local style, duration = MeleeAnim.stepAt(weaponId, index)
	if not MeleeAnim.STYLES[style] then
		return
	end
	FxController.cancelInspect()
	if swing then
		swing.tool.Grip = swing.baseGrip
	end
	swing = { tool = tool, style = style, started = now, duration = duration, baseGrip = tool.Grip }
	-- короткий «подаёт плечом» вперёд, а в момент попадания — толчок своего стиля (по MeleeAnim.HIT, как у сервера)
	kickCamera(-0.6, 0.6, 1.2)
	local cam = MeleeAnim.CAM[style]
	if cam then
		task.delay(duration * (MeleeAnim.HIT[style] or 0.5), function()
			kickCamera(cam[1], cam[2], cam[3])
		end)
	end
end

-- Чужой взмах: сервер сообщил, что attacker замахнулся оружием weaponId (удар серии с номером index) — двигаем ему руку по стилю
function FxController.onRemoteSwing(attacker: Player, weaponId: string, index: number?)
	local char = attacker.Character
	if not char or not Config.MeleeFx[weaponId] then
		return
	end
	local style, duration = MeleeAnim.stepAt(weaponId, if typeof(index) == "number" then index else 1)
	if not MeleeAnim.STYLES[style] then
		return
	end
	remoteSwings[char] = { style = style, started = os.clock(), duration = duration }
end

-- Осмотр холодного оружия (клавиша F): оружие двигается по MeleeAnim.INSPECT, части модели — вокруг шарниров
type InspectPart = { weld: Weld, base: CFrame, pivot: Vector3, key: string }
local inspecting: { tool: Tool, rw: Rewind.State, frame: (number, Vector3?) -> MeleeAnim.InspectFrame, baseGrip: CFrame, parts: { InspectPart }, hinge: Vector3?, fadeAt: number?, fadeU: number, restart: boolean }? = nil
local collectParts: (Tool, { [string]: CFrame }?) -> ({ InspectPart }, Vector3?)
local drawParts: { tool: Tool, parts: { InspectPart } }? = nil -- части, которые двигает доставание (MeleeAnim.DRAW[..].parts)
local INSPECT_FADE = 0.18 -- прерванный осмотр холодного за столько секунд плавно уходит в стойку (как в CS2), а не прокручивается назад

-- smooth = true (R): осмотр плавно едет назад до нейтральной позы и заканчивается (Rewind); false (смена оружия, удар): сразу в руку
function FxController.cancelInspect(smooth: boolean?)
	local i = inspecting
	if i then
		if smooth and i.tool.Parent and i.rw.active then
			-- плавно в стойку из текущей позы (без прокрутки назад: обороты керамбита и бабочки задом наперёд выглядели сломанными)
			if not i.fadeAt then
				i.fadeAt, i.fadeU = os.clock(), i.rw.u
			end
			i.restart = false
			return
		end
		if i.tool.Parent then
			i.tool.Grip = i.baseGrip
		end
		for _, p in i.parts do
			if p.weld.Parent then
				p.weld.C0 = p.base
			end
		end
		inspecting = nil
	end
end

-- Отпустили F: осмотр доигрывает текущий проход и не повторяется
function FxController.inspectRelease()
	local i = inspecting
	if i then
		Rewind.release(i.rw)
	end
end

-- F: запуск осмотра; при повторных нажатиях — реверс и заново (во время возврата — разворот вперёд из текущей позы)
function FxController.inspect()
	if not Config.Inspect.melee then
		return -- осмотр холодного оружия выключен (Config.Inspect.melee)
	end
	local tool = toolOf(player.Character)
	if not tool or tool:GetAttribute("Melee") ~= true or swing then
		return
	end
	if ViewModel.isDrawing() then
		return -- оружие ещё достаётся: осмотр отдельно от доставания
	end
	local id = tostring(tool:GetAttribute("WeaponId"))
	local def = MeleeAnim.INSPECT[id]
	if not def then
		return
	end
	local cur = inspecting
	if cur and cur.tool == tool then
		-- повторное F: плавно в стойку и заново с начала
		if not cur.fadeAt then
			cur.fadeAt, cur.fadeU = os.clock(), cur.rw.u
		end
		cur.restart = true
		return
	end
	FxController.cancelInspect(false)
	local parts, hinge = collectParts(tool, def.frame(0.5, nil).parts)
	local rw = Rewind.new(def.time, Config.Inspect.reverseSpeed)
	Rewind.press(rw)
	inspecting = { tool = tool, rw = rw, frame = def.frame, baseGrip = tool.Grip, parts = parts, hinge = hinge, fadeAt = nil, fadeU = 0, restart = false }
end

-- Подвижные части модели (рукояти и клинок бабочки) по префиксам имён keys: сварки к рукояти и общий шарнир
function collectParts(tool: Tool, keys: { [string]: CFrame }?): ({ InspectPart }, Vector3?)
	local handle = handleOf(tool)
	local parts: { InspectPart } = {}
	local hinge: Vector3? = nil
	if keys and handle then
		-- шарнир один на все части (рукояти и клинок): ось по X модели, на переднем (−Z) конце рукоятей
		local hingeZ, hingeN = 0, 0
		local found: { { weld: Weld, key: string } } = {}
		for _, d in tool:GetChildren() do
			if d:IsA("BasePart") and d ~= handle then
				local weld = d:FindFirstChildOfClass("Weld")
				if weld and weld.Part0 == handle then
					for key in keys do
						if string.sub(d.Name, 1, #key) == key then
							table.insert(found, { weld = weld, key = key })
							if key ~= "Blade" then
								hingeZ += weld.C0.Position.Z - math.max(d.Size.X, d.Size.Y, d.Size.Z) / 2
								hingeN += 1
							end
						end
					end
				end
			end
		end
		if hingeN > 0 then
			hinge = Vector3.new(0, 0, hingeZ / hingeN)
			for _, f in found do
				table.insert(parts, { weld = f.weld, base = f.weld.C0, pivot = hinge :: Vector3, key = f.key })
			end
		end
	end
	return parts, hinge
end

-- Покадровое применение отдачи и взмаха -----------------------------------

local weaponWelds: { { weld: Weld, base: CFrame } } = {}
local weldTool: Tool? = nil

local function refreshWelds(tool: Tool?)
	if tool == weldTool then
		return
	end
	-- вернуть прежнему оружию родные смещения
	for _, w in weaponWelds do
		if w.weld.Parent then
			w.weld.C0 = w.base
		end
	end
	table.clear(weaponWelds)
	weldTool = tool
	if tool and tool:GetAttribute("Melee") ~= true then
		for _, d in tool:GetDescendants() do
			if d:IsA("Weld") then
				table.insert(weaponWelds, { weld = d, base = d.C0 })
			end
		end
	end
end

local scrubBase: { [Tool]: CFrame } = setmetatable({}, { __mode = "k" }) :: any -- исходный Grip для стоп-кадра осмотра (PoseScrub, Studio)
local appliedKick: CFrame? = nil -- сдвиг камеры, наложенный в прошлом кадре

-- Упавший игрок (атрибут Downed) лежит лицом вниз и ползёт: к позе корневого сустава (R15 — LowerTorso.Root, R6 — HumanoidRootPart.RootJoint)
-- после анимации (Stepped) добавляем наклон вперёд у пояса и опускаем тело к земле; на ходу оно покачивается из стороны в сторону, а анимация
-- ходьбы двигает руки и ноги как при ползании. Transform пишет каждый клиент для всех персонажей — поэтому видят все. Работает и с Motor6D,
-- и с AnimationConstraint новых аватаров (у него C0 только для чтения, а Attachment0 двигает сам Roblox).
local crawlPhase: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any

local function rootJointOf(char: Model): (Motor6D | AnimationConstraint)?
	local lower = char:FindFirstChild("LowerTorso")
	local m = if lower then lower:FindFirstChild("Root") else nil
	if not m then
		local hrp = char:FindFirstChild("HumanoidRootPart")
		m = if hrp then hrp:FindFirstChild("RootJoint") else nil
	end
	if m and (m:IsA("Motor6D") or m:IsA("AnimationConstraint")) then
		return m :: any
	end
	return nil
end

local function stepDownedPoses(_time: number, dt: number)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local joint = if char and p:GetAttribute("Downed") == true then rootJointOf(char) else nil
		if joint then
			local hrp = (char :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?
			local v = if hrp then hrp.AssemblyLinearVelocity else Vector3.zero
			local speed = Vector3.new(v.X, 0, v.Z).Magnitude
			local phase = (crawlPhase[joint] or 0) + dt * speed * 1.4
			crawlPhase[joint] = phase
			local sway = if speed > 0.5 then math.sin(phase) * 0.14 else 0
			local lie = CFrame.new(0, -1.5, 0) * CFrame.Angles(math.rad(-82), sway * 0.6, sway)
			;(joint :: any).Transform = lie * (joint :: any).Transform
		end
	end
end

function FxController.start()
	RunService.Stepped:Connect(stepDownedPoses)
	-- Стандартная камера берёт за основу текущий CFrame, поэтому наш сдвиг нужно снять до её обновления,
	-- иначе он копится кадр за кадром и камера уезжает вверх.
	RunService:BindToRenderStep("NotdFxPre", Enum.RenderPriority.First.Value, function()
		local camera = workspace.CurrentCamera
		local applied = appliedKick
		if camera and applied then
			camera.CFrame = camera.CFrame * applied:Inverse()
			appliedKick = nil
		end
	end)

	RunService:BindToRenderStep("NotdFx", Enum.RenderPriority.Camera.Value + 2, function(dt: number)
		local camera = workspace.CurrentCamera
		-- камера: толчок и возврат
		local decay = math.exp(-11 * dt)
		recoil.pitch *= decay
		recoil.yaw *= decay
		recoil.roll *= decay
		if camera and (math.abs(recoil.pitch) + math.abs(recoil.yaw) + math.abs(recoil.roll)) > 1e-4 then
			local kickCF = CFrame.Angles(recoil.pitch, recoil.yaw, recoil.roll)
			camera.CFrame = camera.CFrame * kickCF
			appliedKick = kickCF
		end

		-- ствол: откат назад и поворот, затем пружинит обратно
		local tool = toolOf(player.Character)
		refreshWelds(tool)
		local kdecay = math.exp(-15 * dt)
		kick.back *= kdecay
		kick.rot *= kdecay
		local offset = if kick.back > 1e-3 or kick.rot > 1e-3
			then CFrame.new(0, kick.back * 0.2, kick.back) * CFrame.Angles(kick.rot, 0, 0)
			else CFrame.identity
		for _, w in weaponWelds do
			if w.weld.Parent then
				w.weld.C0 = w.base * offset
			end
		end

		-- осмотр ближнего оружия (вперёд, повтор, пока держат F, и реверс при прерывании — Rewind)
		local live = CFrame.identity
		local liveOpen = 0 -- раскрытие пальцев кисти ножа (0 — кулак, 1 — ладонь раскрыта), см. MeleeAnim.open
		local ins = inspecting
		if ins then
			local active = toolOf(player.Character)
			local u: number? = nil
			local w = 1 -- вес позы осмотра (затухает при прерывании)
			if active == ins.tool and not swing then
				if ins.fadeAt then
					local k = math.clamp((os.clock() - ins.fadeAt) / INSPECT_FADE, 0, 1)
					if k >= 1 then
						ins.fadeAt = nil
						if ins.restart then
							ins.restart = false
							Rewind.start(ins.rw)
							u = 0
						end
					else
						u, w = ins.fadeU, 1 - k * k * (3 - 2 * k)
					end
				else
					u = Rewind.step(ins.rw, dt)
				end
			end
			if not u then
				FxController.cancelInspect(false)
			else
				local frame = ins.frame(u, ins.hinge)
				local function wt(cf: CFrame?): CFrame?
					return if cf and w < 1 then CFrame.identity:Lerp(cf, w) else cf
				end
				local grip, hand, model = wt(frame.grip) :: CFrame, wt(frame.hand), wt(frame.model)
				live = hand or grip
				liveOpen = (frame.open or 0) * w
				-- вращение всей модели (frame.model) — в системе модели: Grip = model⁻¹ · базовый · поза⁻¹
				ins.tool.Grip = (if model then model:Inverse() else CFrame.identity) * ins.baseGrip * grip:Inverse()
				for _, part in ins.parts do
					local rot = wt(frame.parts and frame.parts[part.key])
					if rot and part.weld.Parent then
						part.weld.C0 = CFrame.new(part.pivot) * rot * CFrame.new(-part.pivot) * part.base
					end
				end
			end
		end

		-- доставание: подвижные части модели (бабочка раскрывается при выходе)
		if not ins then
			local tool = toolOf(player.Character)
			local d = if tool then MeleeAnim.DRAW[tostring(tool:GetAttribute("WeaponId"))] else nil
			local du = ViewModel.drawProgress()
			if tool and d and d.parts and du then
				if not drawParts or drawParts.tool ~= tool then
					drawParts = { tool = tool, parts = (collectParts(tool, d.parts(0.5))) }
				end
				local rots = d.parts(du)
				for _, part in (drawParts :: any).parts do
					local rot = rots[part.key]
					if rot and part.weld.Parent then
						part.weld.C0 = CFrame.new(part.pivot) * rot * CFrame.new(-part.pivot) * part.base
					end
				end
			elseif drawParts then
				for _, part in drawParts.parts do
					if part.weld.Parent then
						part.weld.C0 = part.base
					end
				end
				drawParts = nil
			end
		end

		-- взмах ближнего боя
		local s = swing
		if s then
			if not s.tool.Parent then
				swing = nil
			else
				local u = (os.clock() - s.started) / s.duration
				local char = player.Character
				if u >= 1 then
					s.tool.Grip = s.baseGrip
					if char then
						setArmPose(char, nil)
					end
					swing = nil
				else
					local pose = poseAt(s.style, u)
					if ViewModel.active() then
						-- от первого лица видны только оружие и кисть: оба идут по позе (кисть — в ViewModelController через MeleeAnim.live)
						s.tool.Grip = s.baseGrip * pose:Inverse()
						live = pose
						if char then
							setArmPose(char, nil)
						end
					else
						-- от третьего лица двигается рука целиком, оружие в ней неподвижно
						s.tool.Grip = s.baseGrip
						if char then
							setArmPose(char, pose)
						end
					end
				end
			end
		end
		-- стоп-кадр осмотра (только Studio): атрибут PoseScrub = "inspect:<0…1>"
		local scrub = if RunService:IsStudio() then player:GetAttribute("PoseScrub") else nil
		-- ручная поза кисти для подбора ключей (только Studio): "raw:x,y,z,rx,ry,rz,spin,open[,ось]" — как ключ MeleeAnim.wristKeys,
		-- ось 1 — оборот вокруг X (керамбит на кольце), иначе — вокруг клинка
		if typeof(scrub) == "string" and string.sub(scrub, 1, 4) == "raw:" and not swing then
			local tool = toolOf(player.Character)
			local v = {}
			for num in string.gmatch(string.sub(scrub, 5), "[^,]+") do
				table.insert(v, tonumber(num) or 0)
			end
			if tool and #v >= 8 then
				scrubBase[tool] = scrubBase[tool] or tool.Grip
				local axis = if v[9] == 1 then Vector3.xAxis else Config.MeleeHold.default.dir.Unit
				local hand = CFrame.new(v[1], v[2], v[3]) * CFrame.Angles(math.rad(v[4]), math.rad(v[5]), math.rad(v[6]))
				live = hand
				liveOpen = v[8]
				tool.Grip = scrubBase[tool] * (hand * CFrame.fromAxisAngle(axis, math.rad(v[7]))):Inverse()
			end
		end
		if typeof(scrub) == "string" and string.sub(scrub, 1, 8) == "inspect:" and not swing then
			local tool = toolOf(player.Character)
			local def = if tool then MeleeAnim.INSPECT[tostring(tool:GetAttribute("WeaponId"))] else nil
			if tool and def then
				scrubBase[tool] = scrubBase[tool] or tool.Grip
				local frame = def.frame(math.clamp(tonumber(string.sub(scrub, 9)) or 0, 0, 1), nil)
				live = frame.hand or frame.grip
				liveOpen = frame.open or 0
				tool.Grip = (if frame.model then frame.model:Inverse() else CFrame.identity) * scrubBase[tool] * frame.grip:Inverse()
			end
		end
		MeleeAnim.live = live
		MeleeAnim.open = liveOpen

		-- взмахи других игроков
		for char, rs in remoteSwings do
			local u = (os.clock() - rs.started) / rs.duration
			if u >= 1 or not char.Parent then
				setArmPose(char, nil)
				remoteSwings[char] = nil
			else
				setArmPose(char, poseAt(rs.style, u))
			end
		end
	end)
end

return FxController
