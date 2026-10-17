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
local muzzleCache: { [Tool]: Vector3 } = {}

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

-- Выстрел --------------------------------------------------------------

local function muzzleFlash(tool: Tool, size: number)
	local pos = muzzleWorld(tool)
	local handle = handleOf(tool)
	if not pos or not handle then
		return
	end
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 205, 100)
	flash.Size = Vector3.one * size * 0.5
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CFrame = CFrame.new(pos)
	local light = Instance.new("PointLight")
	light.Range = 12 + size * 6
	light.Brightness = 4
	light.Color = Color3.fromRGB(255, 180, 90)
	light.Parent = flash
	flash.Parent = folder()
	TweenService:Create(flash, TweenInfo.new(0.07), { Size = Vector3.one * size * 1.3, Transparency = 1 }):Play()
	TweenService:Create(light, TweenInfo.new(0.07), { Brightness = 0 }):Play()
	Debris:AddItem(flash, 0.09)
	burst(pos, Color3.fromRGB(255, 200, 100), 4, 8, 20, 0.16, 0.18, true)
end

local shellCount = 0

local function ejectShell(tool: Tool)
	local handle = handleOf(tool)
	if not handle or shellCount >= 24 then
		return
	end
	shellCount += 1
	local shell = Instance.new("Part")
	shell.Size = Vector3.new(0.06, 0.06, 0.2)
	shell.Color = Color3.fromRGB(205, 165, 60)
	shell.Material = Enum.Material.Metal
	shell.CanQuery = false
	shell.CanTouch = false
	local cf = handle.CFrame * CFrame.new(0.1, 0.25, -0.2)
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
	local len = math.min(9, dist)
	local streak = Instance.new("Part")
	streak.Material = Enum.Material.Neon
	streak.Color = if shooter == player then Color3.fromRGB(255, 230, 150) else Color3.fromRGB(235, 235, 235)
	streak.Size = Vector3.new(0.1, 0.1, len)
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
	end
	flashZombie(pos)
	local tool = toolOf(player.Character)
	if tool and tool:GetAttribute("Melee") == true then
		local fx = Config.MeleeFx[tostring(tool:GetAttribute("WeaponId"))]
		local shake = if fx then fx.shake else 2
		kickCamera(shake, shake * 0.6, shake * 0.8)
	end
end

-- Взмах ближнего боя: рукоять двигается по ключевым позам (через Tool.Grip), камера подаётся вперёд
type Pose = { t: number, cf: CFrame }

local STYLES: { [string]: { Pose } } = {
	-- колющий: назад — резкий выпад — возврат
	stab = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CFrame.new(0, 0.05, 0.45) * CFrame.Angles(0.15, 0, 0) },
		{ t = 0.5, cf = CFrame.new(0, -0.05, -0.95) * CFrame.Angles(-0.1, 0, 0) },
		{ t = 1, cf = CFrame.identity },
	},
	-- рубящий по диагонали: замах за плечо — широкая дуга вниз-влево — возврат
	slash = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CFrame.new(0.3, 0.15, 0.3) * CFrame.Angles(0.6, -0.55, -0.35) },
		{ t = 0.55, cf = CFrame.new(-0.4, -0.2, -0.75) * CFrame.Angles(-0.85, 0.85, 0.3) },
		{ t = 1, cf = CFrame.identity },
	},
	-- сверху вниз: тяжёлый замах и удар
	smash = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.38, cf = CFrame.new(0.1, 0.55, 0.25) * CFrame.Angles(1.15, 0, 0) },
		{ t = 0.6, cf = CFrame.new(0, -0.45, -0.75) * CFrame.Angles(-1.05, 0, 0) },
		{ t = 1, cf = CFrame.identity },
	},
}

local swing: { tool: Tool, style: string, started: number, duration: number, baseGrip: CFrame }? = nil

local function poseAt(style: string, u: number): CFrame
	local keys = STYLES[style]
	for i = 2, #keys do
		local a, b = keys[i - 1], keys[i]
		if u <= b.t then
			local k = (u - a.t) / math.max(1e-4, b.t - a.t)
			k = TweenService:GetValue(k, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
			return a.cf:Lerp(b.cf, k)
		end
	end
	return CFrame.identity
end

function FxController.onLocalSwing(tool: Tool, weaponId: string)
	local fx = Config.MeleeFx[weaponId]
	if not fx or not STYLES[fx.style] then
		return
	end
	if swing then
		swing.tool.Grip = swing.baseGrip
	end
	swing = { tool = tool, style = fx.style, started = os.clock(), duration = fx.time, baseGrip = tool.Grip }
	-- короткий «подаёт плечом» вперёд
	kickCamera(-0.6, 0.6, 1.2)
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

local appliedKick: CFrame? = nil -- сдвиг камеры, наложенный в прошлом кадре

function FxController.start()
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

		-- взмах ближнего боя
		local s = swing
		if s then
			if not s.tool.Parent then
				swing = nil
			else
				local u = (os.clock() - s.started) / s.duration
				if u >= 1 then
					s.tool.Grip = s.baseGrip
					swing = nil
				else
					s.tool.Grip = s.baseGrip * poseAt(s.style, u):Inverse()
				end
			end
		end
	end)
end

return FxController
