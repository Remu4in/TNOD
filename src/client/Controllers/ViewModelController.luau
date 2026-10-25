--!strict
-- Руки и оружие от первого лица (viewmodel): вместо рук персонажа в кадре — предплечья и кисти (рукав и кожа), оружие в руках.
-- Огнестрел и холодное оружие (у холодного кисть и оружие идут по позе взмаха или осмотра: FxController / MeleeAnim).
-- Движения (всё считается кодом): достать оружие, покачивание при ходьбе, «запаздывание» за мышью, отдача при выстреле,
-- прицеливание (оружие к центру), бег (оружие опущено), перезарядка по этапам (магазин вынимается и вставляется левой рукой).
-- Реальные руки и Tool у персонажа скрываются только для самого игрока (LocalTransparencyModifier), другие видят их как обычно.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MeleeAnim = require(Shared:WaitForChild("MeleeAnim"))

local ViewModel = {}

local player = Players.LocalPlayer

local SLEEVE = Color3.fromRGB(62, 74, 52) -- рукав: оливковый
local SKIN_FALLBACK = Color3.fromRGB(226, 182, 148)
local HIP = Vector3.new(0.55, -0.55, -1.6) -- где рукоять оружия относительно камеры от бедра
local MELEE_HAND = Vector3.new(0.6, -0.7, -1.3) -- где кисть с холодным оружием относительно камеры
local DEFAULT_HAND = Vector3.new(0.02, -0.17, 0.12) -- где правая кисть на оружии (система рукояти), если нет записи в Config.WeaponHands
-- куда левая рука берётся при действии затвором (система рукояти, от центра двигаемых деталей): затвор пистолета — сверху слева,
-- рукоятка взведения — слева-сверху сбоку, помпа — снизу
local ACTION_HAND = { slide = Vector3.new(-0.1, 0.12, 0.05), charge = Vector3.new(-0.12, 0.1, 0), pump = Vector3.new(0, -0.06, 0) }
local PISTOL_LEFT = Vector3.new(-0.24, -0.11, 0) -- левая рука у пистолета: смещение от правой кисти
local RELOAD_DROP = 0.55 -- на сколько магазин уходит вниз при перезарядке (студы): больше — рука и магазин вылетали за нижний край кадра
local RELOAD_OUT = Vector3.new(-0.25, -0.85, 0.1) -- где левая рука с вынутым магазином (относительно места магазина)
local SCOPE_FOV = 30 -- маска прицела появляется, когда поле зрения сузилось до этого (камера уже «приблизила» картинку)

type GunPart = { part: BasePart, rel: CFrame, isMag: boolean, weld: Weld, action: boolean }

type Rig = {
	tool: Tool,
	weaponId: string,
	model: Model,
	parts: { GunPart },
	rForearm: Part,
	rHand: Part,
	lForearm: Part,
	lHand: Part,
	draw: Config.DrawAnimDef, -- анимация доставания этого оружия (Config.DrawAnim)
	drawVariant: Config.DrawVariant,
	actionKind: string?, -- "slide" | "charge" | "pump": чем действуем при доставании (если подходящие детали есть)
	actionAnchor: Vector3, -- центр двигаемых деталей (система рукояти)
	hand: Vector3, -- где правая кисть держит оружие (система рукояти)
	sightX: number, -- боковое смещение прицельных приспособлений (система рукояти): в прицеливании оружие сдвигается на него к центру
	leftHold: Vector3, -- где левая рука держит оружие (система рукояти)
	magPos: Vector3, -- где магазин (система рукояти)
	muzzle: Vector3, -- дуло (система рукояти)
	aimY: number, -- высота линии прицеливания над рукоятью
	pistol: boolean,
	melee: boolean, -- холодное оружие: одна рука держит рукоять, положение берём из Tool.Grip (его двигают взмахи и осмотр, FxController)
	drawStart: number,
}

local rig: Rig? = nil
local container: Model? = nil
local scopeGui: ScreenGui? = nil

-- пружины (положение и поворот оружия относительно «стойки»)
local pos, posVel = Vector3.zero, Vector3.zero
local rot, rotVel = Vector3.zero, Vector3.zero
local bobPhase = 0
local reload: { started: number, duration: number }? = nil
local lastMouse = Vector2.zero

local function smooth(k: number): number
	k = math.clamp(k, 0, 1)
	return k * k * (3 - 2 * k)
end

local function segment(u: number, a: number, b: number): number
	return smooth((u - a) / (b - a))
end

local function springStep(cur: Vector3, vel: Vector3, target: Vector3, dt: number, k: number, c: number): (Vector3, Vector3)
	vel += ((target - cur) * k - vel * c) * dt
	return cur + vel * dt, vel
end

local function makePart(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function skinColor(): Color3
	local char = player.Character
	local bc = char and char:FindFirstChildOfClass("BodyColors")
	return if bc then bc.RightArmColor3 else SKIN_FALLBACK
end

-- Оптический прицел: тёмная маска с круглым окном и перекрестием на весь экран (создаётся один раз, включается по требованию)
local function setScope(on: boolean)
	if not on then
		if scopeGui then
			scopeGui.Enabled = false
		end
		return
	end
	if not scopeGui or not scopeGui.Parent then
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = "NotdScope"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = -10 -- под HUD: патроны и прицел остаются видны
		gui.Enabled = false
		-- квадрат по меньшей стороне экрана; чёрная обводка огромной толщины закрывает всё снаружи круга
		local lens = Instance.new("Frame")
		lens.Name = "Lens"
		lens.AnchorPoint = Vector2.new(0.5, 0.5)
		lens.Position = UDim2.fromScale(0.5, 0.5)
		lens.Size = UDim2.fromScale(0.92, 0.92)
		lens.BackgroundTransparency = 1
		lens.Parent = gui
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = 1
		ratio.AspectType = Enum.AspectType.FitWithinMaxSize
		ratio.Parent = lens
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = lens
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = 3000
		stroke.Parent = lens
		-- перекрестие: тонкие линии с просветом в центре и точка
		local function line(size: UDim2, anchor: Vector2)
			local f = Instance.new("Frame")
			f.AnchorPoint = anchor
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.Size = size
			f.BackgroundColor3 = Color3.new(0, 0, 0)
			f.BorderSizePixel = 0
			f.Parent = lens
		end
		line(UDim2.new(0.46, 0, 0, 2), Vector2.new(1.08, 0.5))
		line(UDim2.new(0.46, 0, 0, 2), Vector2.new(-0.08, 0.5))
		line(UDim2.new(0, 2, 0.46, 0), Vector2.new(0.5, 1.08))
		line(UDim2.new(0, 2, 0.46, 0), Vector2.new(0.5, -0.08))
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		dot.Size = UDim2.fromOffset(4, 4)
		dot.BackgroundColor3 = Color3.fromRGB(220, 40, 40)
		dot.BorderSizePixel = 0
		dot.Parent = lens
		gui.Parent = playerGui
		scopeGui = gui
	end
	(scopeGui :: ScreenGui).Enabled = true
end

local function destroyRig()
	setScope(false)
	if rig then
		rig.model:Destroy()
		rig = nil
	end
	reload = nil
end

-- Собираем копию деталей оружия из Tool: положение каждой детали относительно рукояти берём из её Weld (C0)
local function buildRig(tool: Tool, weaponId: string, melee: boolean): Rig?
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local camera = workspace.CurrentCamera
	if not handle or not camera then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "ViewModel"
	model.Parent = camera
	local parts: { GunPart } = {}
	local minZ, maxZ, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	local magSum, magN = Vector3.zero, 0
	local sightSum, sightN = 0, 0
	for _, d in tool:GetChildren() do
		if d:IsA("BasePart") and d ~= handle then
			local weld = d:FindFirstChildOfClass("Weld")
			if weld and weld.Part0 == handle then
				local clone = d:Clone()
				for _, c in clone:GetChildren() do
					if not c:IsA("SurfaceAppearance") then
						c:Destroy()
					end
				end
				clone.Anchored = true
				clone.CanCollide = false
				clone.CanQuery = false
				clone.CanTouch = false
				clone.CastShadow = false
				clone.Massless = true
				clone.Parent = model
				local rel = weld.C0
				local isMag = d:GetAttribute("Group") == "Mag"
				table.insert(parts, { part = clone, rel = rel, isMag = isMag, weld = weld, action = false })
				-- габариты по углам детали
				local half = d.Size / 2
				for _, sx in { -1, 1 } do
					for _, sy in { -1, 1 } do
						for _, sz in { -1, 1 } do
							local c = rel:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
							minZ, maxZ = math.min(minZ, c.Z), math.max(maxZ, c.Z)
							minY, maxY = math.min(minY, c.Y), math.max(maxY, c.Y)
						end
					end
				end
				if isMag then
					magSum += rel.Position
					magN += 1
				end
				if string.find(string.lower(d.Name), "sight", 1, true) then
					sightSum += rel.Position.X
					sightN += 1
				end
			end
		end
	end
	if #parts == 0 then
		model:Destroy()
		return nil
	end
	local length = maxZ - minZ
	local pistol = length < 2.0
	local skin = skinColor()
	local hand = Config.WeaponHands[weaponId] or DEFAULT_HAND
	-- доставание: стиль по классу оружия; детали затвора (Slide / ChargingHandle или Bolt / Pump) двигаются при передёргивании
	local draw = Config.DrawAnim[Config.WeaponDraw[weaponId] or (if melee then "melee" else "rifle")]
	local actionKind = draw.action
	local actionSum, actionN = Vector3.zero, 0
	if actionKind then
		local function matches(name: string, tag: string): boolean
			local l = string.lower(name)
			return if actionKind == "pump" then (string.match(l, "^pump") ~= nil and not string.find(l, "line", 1, true)) else string.find(l, tag, 1, true) ~= nil
		end
		local tag = if actionKind == "slide" then "slide" else "charginghandle"
		local found = false
		for _, gp in parts do
			if matches(gp.part.Name, tag) then
				found = true
			end
		end
		if actionKind == "charge" and not found then
			tag = "bolt" -- у части оружия рукоятки нет: тянем затвор
		end
		for _, gp in parts do
			if matches(gp.part.Name, tag) then
				gp.action = true
				actionSum += gp.rel.Position
				actionN += 1
			end
		end
		if actionN == 0 then
			actionKind = nil
		end
	end
	local rig_: Rig = {
		tool = tool, weaponId = weaponId, model = model, parts = parts,
		rForearm = makePart("RForearm", Vector3.new(0.4, 0.4, 3), SLEEVE, model),
		rHand = makePart("RHand", Vector3.new(0.38, 0.34, 0.55), skin, model),
		lForearm = makePart("LForearm", Vector3.new(0.4, 0.4, 3), SLEEVE, model),
		lHand = makePart("LHand", Vector3.new(0.38, 0.34, 0.55), skin, model),
		hand = hand,
		draw = draw,
		drawVariant = draw.variants[math.random(1, #draw.variants)],
		actionKind = actionKind,
		actionAnchor = if actionN > 0 then actionSum / actionN else Vector3.zero,
		sightX = if sightN > 0 then sightSum / sightN else 0,
		leftHold = if pistol then hand + PISTOL_LEFT else Vector3.new(-0.02, minY + 0.12, minZ + length * 0.32),
		magPos = if magN > 0 then magSum / magN else Vector3.new(0, -0.7, -0.1),
		muzzle = Vector3.new(0, (minY + maxY) / 2 + 0.05, minZ - 0.05),
		aimY = maxY,
		pistol = pistol,
		melee = melee,
		drawStart = os.clock(),
	}
	return rig_
end

-- Что сейчас в руках: оружие с WeaponId (огнестрел или холодное) и от первого лица
local function heldWeapon(): (Tool?, string?, boolean)
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return nil, nil, false
	end
	local id = tool:GetAttribute("WeaponId")
	if typeof(id) ~= "string" or not Config.Weapons[id] then
		return nil, nil, false
	end
	return tool, id, Config.Weapons[id].melee == true or tool:GetAttribute("Melee") == true
end

local function firstPerson(): boolean
	local camera = workspace.CurrentCamera
	return camera ~= nil and (camera.Focus.Position - camera.CFrame.Position).Magnitude < 1.6
end

function ViewModel.active(): boolean
	return rig ~= nil
end

-- Идёт ли сейчас перезарядка (колёсико мыши в это время оружие не меняет)
function ViewModel.isReloading(): boolean
	return reload ~= nil
end

-- F у огнестрела: повторить доставание (осмотр, передёргивание затвора) — как осмотр ножа; R прерывает (cancelDraw) и начинает перезарядку
function ViewModel.replayDraw()
	local r = rig
	if r and not r.melee and not reload then
		r.drawStart = os.clock()
		r.drawVariant = r.draw.variants[math.random(1, #r.draw.variants)]
	end
end

function ViewModel.cancelDraw()
	local r = rig
	if r and not r.melee then
		r.drawStart = os.clock() - r.draw.time * 2
	end
end

-- Дуло в мире (для вспышки, гильз, трассеров): из deck-а viewmodel, а не из скрытого оружия в руках персонажа
function ViewModel.handleCFrame(tool: Tool): CFrame?
	local r = rig
	if r and r.tool == tool and r.parts[1] then
		-- рукоять — начало системы координат: восстанавливаем её CFrame из первой детали
		return r.parts[1].part.CFrame * r.parts[1].rel:Inverse()
	end
	return nil
end

function ViewModel.muzzleWorld(tool: Tool): Vector3?
	local cf = ViewModel.handleCFrame(tool)
	return if cf then cf:PointToWorldSpace(ViewModel.rigMuzzle()) else nil
end

function ViewModel.rigMuzzle(): Vector3
	return if rig then rig.muzzle else Vector3.zero
end

-- Выстрел: толчок оружия назад и вверх
function ViewModel.kick(weaponId: string)
	local fx = Config.WeaponFx[weaponId]
	if not fx or not rig then
		return
	end
	posVel += Vector3.new((math.random() - 0.5) * 0.6, fx.kickBack * 7, fx.kickBack * 22)
	rotVel += Vector3.new(math.rad(fx.kickRot) * 9, (math.random() - 0.5) * 0.8, (math.random() - 0.5) * 1.2)
end

-- Перезарядка на duration секунд (длительность задаёт сервер: Config.Weapons[...].reloadTime)
function ViewModel.reload(duration: number)
	if rig then
		reload = { started = os.clock(), duration = math.max(duration, 0.6) }
	end
end

-- Анимация перезарядки: смещение оружия, положение левой руки и сдвиг магазина (система рукояти), прозрачность магазина
local function reloadPose(r: Rig, u: number): (CFrame, Vector3, Vector3, number)
	local tilt = segment(u, 0, 0.18) - segment(u, 0.82, 1)
	-- оружие чуть наклоняется и опускается, но остаётся в кадре вместе с правой рукой
	local weaponCf = CFrame.new(-0.1 * tilt, -0.1 * tilt, 0.08 * tilt) * CFrame.Angles(math.rad(-12) * tilt, math.rad(6) * tilt, math.rad(-22) * tilt)
	-- левая рука: к магазину → вниз с ним → за новым → вверх → к цевью
	local toMag = segment(u, 0.05, 0.2)
	local pull = segment(u, 0.2, 0.4)
	local away = segment(u, 0.4, 0.5)
	local fresh = segment(u, 0.55, 0.72)
	local seat = segment(u, 0.72, 0.86)
	local back = segment(u, 0.86, 1)
	local magHome = r.magPos
	local hand = r.leftHold:Lerp(magHome, toMag)
	local magOffset = Vector3.zero
	local magAlpha = 0
	if u < 0.5 then
		magOffset = Vector3.new(0, -RELOAD_DROP * pull, 0)
		hand = hand + Vector3.new(0, -RELOAD_DROP * pull, 0)
		magAlpha = 1 - away -- магазин исчезает, когда рука его бросила
		hand = hand + (RELOAD_OUT - Vector3.new(0, -RELOAD_DROP, 0)) * away
	elseif u < 0.86 then
		local outHand = magHome + RELOAD_OUT
		hand = outHand:Lerp(magHome + Vector3.new(0, -RELOAD_DROP, 0), fresh):Lerp(magHome, seat)
		magOffset = Vector3.new(0, -RELOAD_DROP * (1 - seat), 0)
		magAlpha = fresh -- новый магазин появляется у руки
	else
		hand = magHome:Lerp(r.leftHold, back)
		magAlpha = 1
	end
	return weaponCf, hand, magOffset, magAlpha
end

-- Руки: предплечье тянется от «локтя» (внизу у края кадра) к кисти
local function placeArm(forearm: Part, hand: Part, elbow: CFrame, handCf: CFrame)
	local from = elbow.Position
	local to = handCf.Position
	local dist = (to - from).Magnitude
	forearm.Size = Vector3.new(0.4, 0.4, math.max(dist, 0.3))
	forearm.CFrame = CFrame.lookAt((from + to) / 2, to)
	hand.CFrame = handCf
end

local function update(dt: number)
	local camera = workspace.CurrentCamera
	local tool, id, isMelee = heldWeapon()
	if not camera or not tool or not id or not firstPerson() or player:GetAttribute("Downed") == true then
		if rig then
			destroyRig()
		end
		return
	end
	if not rig or rig.tool ~= tool then
		destroyRig()
		rig = buildRig(tool, id, isMelee)
		pos, posVel, rot, rotVel = Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero
		if not rig then
			return
		end
	end
	local r = rig :: Rig
	local now = os.clock()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local speed = if root then Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude else 0
	local ads = player:GetAttribute("ADS") == true
	local sprint = player:GetAttribute("Sprinting") == true
	-- снайперский прицел: когда картинка приблизилась, ствол и руки не нужны — виден только прицел
	local scoped = ads and Config.ScopedWeapons[id] == true and camera.FieldOfView < SCOPE_FOV
	setScope(scoped)

	-- «запаздывание» оружия за поворотом камеры
	local md = UserInputService:GetMouseDelta()
	local swayX = math.clamp(-md.X * 0.0016, -0.1, 0.1)
	local swayY = math.clamp(md.Y * 0.0016, -0.1, 0.1)
	-- покачивание шага
	bobPhase += dt * speed * 0.5
	local moveK = math.clamp(speed / 16, 0, 1) * (if ads then 0.25 else 1)
	local bob = Vector3.new(math.sin(bobPhase) * 0.04 * moveK, -math.abs(math.cos(bobPhase)) * 0.035 * moveK, 0)

	-- базовая стойка: от бедра, в прицеле — по центру; на бегу ниже и набок; при доставании — снизу
	local stance = HIP
	local stanceRot = Vector3.zero
	if ads then
		stance = Vector3.new(-r.sightX, -r.aimY - 0.1, -1.0) -- прицельные приспособления на оси камеры (у винтовок они смещены от оси модели)
	elseif sprint then
		stance = HIP + Vector3.new(-0.18, -0.32, 0.12)
		stanceRot = Vector3.new(math.rad(-22), math.rad(14), math.rad(-12))
	end
	-- доставание: из начального положения (снизу или из-за спины) в стойку, осмотр, передёргивание (Config.DrawAnim)
	local da = r.draw
	local du = (now - r.drawStart) / da.time
	local away = 1 - smooth(du / da.rise)
	local variant = r.drawVariant
	stance += variant.pos * away
	stanceRot += Vector3.new(math.rad(variant.rot.X), math.rad(variant.rot.Y), math.rad(variant.rot.Z)) * away
	if da.turn and da.turnAt then
		local turnK = math.sin(math.pi * math.clamp((du - da.turnAt[1]) / (da.turnAt[2] - da.turnAt[1]), 0, 1))
		stanceRot += Vector3.new(math.rad(da.turn.X), math.rad(da.turn.Y), math.rad(da.turn.Z)) * turnK
	end
	-- ход затвора (0…1) и захват его левой рукой (0…1)
	local pull, grab = 0, 0
	local kind = r.actionKind
	if kind and da.actionAt and du >= da.actionAt[1] and du < 1 then
		local w = math.clamp((du - da.actionAt[1]) / (da.actionAt[2] - da.actionAt[1]), 0, 1)
		if kind == "pump" then
			pull = smooth(w / 0.4) - smooth((w - 0.5) / 0.4)
		else
			-- затвор тянем плавно, отпускаем резко (пружина)
			pull = if w < 0.5 then smooth(w / 0.5) elseif w < 0.62 then 1 else 1 - smooth((w - 0.62) / 0.1)
		end
		grab = smooth(w / 0.15) - smooth((w - 0.85) / 0.15)
	end
	local stiffness = if ads then 260 else 150
	pos, posVel = springStep(pos, posVel, Vector3.new(swayX, swayY, 0) + bob, dt, stiffness, 20)
	rot, rotVel = springStep(rot, rotVel, Vector3.new(swayY * 0.8, swayX * 1.4, swayX * 1.2) + stanceRot, dt, stiffness, 20)

	local rl = reload
	local reloadCf, leftTarget, magOffset, magAlpha = CFrame.identity, r.leftHold, Vector3.zero, 0
	local magHidden = false
	if rl then
		local u = (now - rl.started) / rl.duration
		if u >= 1 then
			reload = nil
		else
			reloadCf, leftTarget, magOffset, magAlpha = reloadPose(r, u)
			magHidden = true
		end
	end

	if kind and grab > 0 and not rl then
		-- левая рука идёт к затвору и тянет его вместе с деталями
		local target = r.actionAnchor + ACTION_HAND[kind] + Vector3.new(0, 0, (r.draw.actionDist or 0.3) * pull)
		leftTarget = leftTarget:Lerp(target, grab)
	end

	local weaponCf = camera.CFrame * CFrame.new(stance + pos) * CFrame.Angles(rot.X, rot.Y, rot.Z) * reloadCf
	-- холодное оружие: «кисть» — это рамка, в которой Tool.Grip задаёт положение рукояти (хват, взмах, осмотр двигают Grip)
	local handFrame = weaponCf
	if r.melee then
		handFrame = camera.CFrame * CFrame.new((if sprint then Vector3.new(0.5, -0.9, -1.1) else MELEE_HAND) + pos) * CFrame.Angles(rot.X, rot.Y, rot.Z)
		weaponCf = handFrame * tool.Grip:Inverse()
	end
	for _, gp in r.parts do
		if gp.isMag and magHidden then
			-- магазин: вынутый уезжает вниз и исчезает, новый приезжает снизу
			gp.part.CFrame = weaponCf * CFrame.new(magOffset) * gp.rel
			gp.part.Transparency = if magAlpha > 0.5 then 0 else 1
		else
			-- у холодного оружия части двигает осмотр (рукояти бабочки вокруг шарнира): смещение берём из сварки каждый кадр
			if gp.action and pull > 0 then
				gp.part.CFrame = weaponCf * CFrame.new(0, 0, (r.draw.actionDist or 0.3) * pull) * gp.rel
			else
				gp.part.CFrame = weaponCf * (if r.melee then gp.weld.C0 else gp.rel)
			end
			gp.part.Transparency = 0
		end
	end

	if scoped then
		for _, gp in r.parts do
			gp.part.Transparency = 1
		end
		for _, p in { r.rForearm, r.rHand, r.lForearm, r.lHand } do
			p.Transparency = 1
		end
		return
	end
	r.rForearm.Transparency = 0
	r.rHand.Transparency = 0

	-- кисти: правая на рукояти, левая на цевье (или магазине во время перезарядки)
	local tiltDown = CFrame.Angles(math.rad(-18), 0, 0)
	local rightHandCf = weaponCf * CFrame.new(r.hand) * tiltDown
	local leftHandCf = weaponCf * CFrame.new(leftTarget) * CFrame.Angles(math.rad(-10), math.rad(r.pistol and 18 or 0), math.rad(8))
	if r.melee then
		-- кисть в рамке хвата и идёт за взмахом (MeleeAnim.live), иначе оружие «выезжало» бы из неподвижного кулака; левая рука убрана
		rightHandCf = handFrame * MeleeAnim.live * CFrame.new(0, 0, 0.1) * CFrame.Angles(math.rad(-12), 0, 0)
		r.lForearm.Transparency = 1
		r.lHand.Transparency = 1
		placeArm(r.rForearm, r.rHand, camera.CFrame * CFrame.new(1.3, -3.0, 1.4), rightHandCf)
		return
	end
	r.lForearm.Transparency = 0
	r.lHand.Transparency = 0
	placeArm(r.rForearm, r.rHand, camera.CFrame * CFrame.new(1.5, -3.0, 1.2), rightHandCf)
	placeArm(r.lForearm, r.lHand, camera.CFrame * CFrame.new(-1.5, -3.0, 1.2), leftHandCf)
end

function ViewModel.start()
	RunService:BindToRenderStep("NotdViewModel", Enum.RenderPriority.Camera.Value + 6, update)
	player.CharacterAdded:Connect(destroyRig)
end

return ViewModel
