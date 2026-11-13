--!strict
-- Риги рук для Animation Editor: по одному на каждый нож из кейса (Config.Donate.Cases → case_knife).
-- Запуск: Studio (Edit) → execute_luau / Command Bar с текстом этого файла. Строит Workspace.KnifeRigs/Rig_<id>.
-- Система координат рига = камера игрока: Cam — глаз (смотрит в −Z), рука и нож стоят как в игре (ViewModelController, стойка ножа).
-- Суставы — Motor6D: Cam → Forearm (Shoulder) → Hand (Wrist) → пальцы (…1, …2) и Knife (Grip); у бабочки Knife → BiteHandle / Blade
-- (шарнир у основания клинка). Анимацию публикуем из Animation Editor, ID отдаём в Config.KnifeAnims (подключение — ViewModelController).
-- Числа стойки продублированы из ViewModelController (MELEE_HAND, PALM, KNIFE_ELBOW, пальцы) — при их правке обновить и здесь.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Config = require(ReplicatedStorage.Shared.Config) :: any

local ORIGIN = CFrame.new(0, 400, 0) -- где стоит первый риг (высоко над картой, чтобы ничего не мешало)
local STEP = Vector3.new(8, 0, 0) -- расстояние между ригами
local MELEE_HAND = Vector3.new(0.6, -0.7, -1.3)
local PALM = CFrame.new(0.17, -0.02, 0.02)
local KNIFE_ELBOW = Vector3.new(1.0, -1.0, 0.5)
local FINGER_Y = { 0.15, 0.05, -0.05, -0.15 }
local FINGER_LEN = { { 0.17, 0.15 }, { 0.18, 0.16 }, { 0.17, 0.15 }, { 0.14, 0.12 } }
local FINGER_NAMES = { "Index", "Middle", "Ring", "Pinky" }
local SKIN = Color3.fromRGB(234, 184, 146)
local SLEEVE = Color3.fromRGB(62, 74, 52)

local function knives(): { string }
	for _, case in Config.Donate.Cases do
		if case.id == "case_knife" then
			local ids = {}
			for _, e in case.pool do
				table.insert(ids, e.id)
			end
			return ids
		end
	end
	return {}
end

local function part(name: string, size: Vector3, color: Color3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CFrame = cf
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Parent = parent
	return p
end

-- Motor6D с шарниром в точке joint (мировые координаты): поворот Part1 в редакторе идёт вокруг неё
local function motor(name: string, p0: BasePart, p1: BasePart, joint: CFrame)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = p0
	m.Part1 = p1
	m.C0 = p0.CFrame:ToObjectSpace(joint)
	m.C1 = p1.CFrame:ToObjectSpace(joint)
	m.Parent = p0
end

local function libraryModel(ref: string): Model?
	local node: Instance? = ServerStorage:FindFirstChild("Assets")
	for _, name in string.split("Weapons/" .. ref, "/") do
		node = if node then node:FindFirstChild(name) else nil
	end
	return if node and node:IsA("Model") then node else nil
end

local function buildRig(id: string, at: CFrame, folder: Folder): Model?
	local def = Config.WeaponModels[id]
	local lib = def and libraryModel(def.ref)
	if not lib then
		warn("[KnifeRigs] no model for " .. id)
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "Rig_" .. id
	local cam = part("Cam", Vector3.new(0.2, 0.2, 0.2), Color3.new(1, 0, 0), at, model)
	cam.Anchored = true
	cam.Transparency = 0.5
	model.PrimaryPart = cam

	-- кисть и нож в стойке (как ViewModelController: handFrame = камера · MELEE_HAND, оружие = handFrame · Grip⁻¹)
	local hold = Config.MeleeHold[id] or Config.MeleeHold.default
	local grip = CFrame.lookAt(Vector3.zero, hold.dir.Unit, hold.up):Inverse()
	local handFrame = at * CFrame.new(MELEE_HAND)
	local handCf = handFrame * CFrame.new(0, 0, 0.1) * CFrame.Angles(math.rad(-12), 0, 0)
	local knifeCf = handFrame * grip:Inverse()

	local elbowPos = at:PointToWorldSpace(at:PointToObjectSpace(handCf.Position) + KNIFE_ELBOW)
	local len = (handCf.Position - elbowPos).Magnitude
	local forearm = part("Forearm", Vector3.new(0.32, 0.32, len), SLEEVE, CFrame.lookAt((elbowPos + handCf.Position) / 2, handCf.Position), model)
	local hand = part("Hand", Vector3.new(0.13, 0.36, 0.3), SKIN, handCf * PALM, model)
	motor("Shoulder", cam, forearm, CFrame.lookAt(elbowPos, handCf.Position))
	motor("Wrist", forearm, hand, handCf)

	-- пальцы в кулаке (как placeFingers при open = 0)
	for i = 1, 4 do
		local l1, l2 = FINGER_LEN[i][1], FINGER_LEN[i][2]
		local k = 0.92 + 0.04 * i
		local j0 = handCf * CFrame.new(0.13, FINGER_Y[i], -0.14) * CFrame.Angles(0, math.rad(5 + 75 * k), 0)
		local a = part(FINGER_NAMES[i] .. "1", Vector3.new(0.09, 0.085, l1), SKIN, j0 * CFrame.new(0, 0, -l1 / 2), model)
		local j1 = j0 * CFrame.new(0, 0, -l1) * CFrame.Angles(0, math.rad(5 + 100 * k), 0)
		local b = part(FINGER_NAMES[i] .. "2", Vector3.new(0.085, 0.08, l2), SKIN, j1 * CFrame.new(0, 0, -l2 / 2), model)
		motor(FINGER_NAMES[i] .. "1", hand, a, j0)
		motor(FINGER_NAMES[i] .. "2", a, b, j1)
	end
	local t0 = handCf * CFrame.new(0.12, 0.2, 0.06) * CFrame.Angles(math.rad(-10), math.rad(70), 0)
	local th1 = part("Thumb1", Vector3.new(0.1, 0.095, 0.17), SKIN, t0 * CFrame.new(0, 0, -0.085), model)
	local t1 = t0 * CFrame.new(0, 0, -0.17) * CFrame.Angles(0, math.rad(50), 0)
	local th2 = part("Thumb2", Vector3.new(0.09, 0.085, 0.13), SKIN, t1 * CFrame.new(0, 0, -0.065), model)
	motor("Thumb1", hand, th1, t0)
	motor("Thumb2", th1, th2, t1)

	-- нож: невидимая рукоять Knife (как Handle инструмента) и детали модели на сварках; подвижные части бабочки — на Motor6D
	local knife = part("Knife", Vector3.new(0.2, 0.2, 0.2), Color3.new(0, 0, 0), knifeCf, model)
	knife.Transparency = 1
	motor("Grip", hand, knife, handCf)
	local natural = lib:GetAttribute("Length")
	local scale = if typeof(natural) == "number" and natural > 0 then def.length / natural else 1
	local shift = CFrame.new(def.grip or Vector3.zero) * (def.rot or CFrame.identity)
	local movable: { { p: BasePart, rel: CFrame } } = {}
	local hingeZ, hingeN = 0, 0
	for _, src in lib:GetChildren() do
		if src:IsA("MeshPart") then
			local p = src:Clone()
			p.Size = src.Size * scale
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Massless = true
			local rel = shift * (src.CFrame.Rotation + src.Position * scale)
			p.CFrame = knifeCf * rel
			p.Parent = model
			if id == "Balisong" and (string.sub(p.Name, 1, 10) == "BiteHandle" or string.sub(p.Name, 1, 5) == "Blade") then
				table.insert(movable, { p = p, rel = rel })
				if string.sub(p.Name, 1, 5) ~= "Blade" then
					hingeZ += rel.Position.Z - math.max(p.Size.X, p.Size.Y, p.Size.Z) / 2
					hingeN += 1
				end
			else
				local w = Instance.new("Weld")
				w.Part0 = knife
				w.Part1 = p
				w.C0 = rel
				w.Parent = p
			end
		end
	end
	local hinge = knifeCf * CFrame.new(0, 0, if hingeN > 0 then hingeZ / hingeN else 0)
	for _, m in movable do
		motor(string.match(m.p.Name, "^%a+") or m.p.Name, knife, m.p, hinge)
	end

	local ac = Instance.new("AnimationController")
	Instance.new("Animator").Parent = ac
	ac.Parent = model
	model.Parent = folder
	return model
end

local old = workspace:FindFirstChild("KnifeRigs")
if old then
	old:Destroy()
end
local folder = Instance.new("Folder")
folder.Name = "KnifeRigs"
folder.Parent = workspace
local built = {}
for i, id in knives() do
	if buildRig(id, ORIGIN + STEP * (i - 1), folder) then
		table.insert(built, id)
	end
	task.wait()
end
return "built: " .. table.concat(built, ", ")
