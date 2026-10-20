-- «Печь машин» (копия для репозитория; в Studio — ServerStorage.Tools.VehicleBaker, только Edit-режим).
-- Берёт готовую вычищенную модель из ServerStorage.Assets.Vehicles (её запёк Baker из ангара техники 15366989586) и делает из неё
-- шаблон для VehicleService в ServerStorage.CarModels: Root (невидимая коробка-корпус, PrimaryPart) + визуальные детали,
-- перёд в -Z, основание на земле (Y = 0), без сидений, сварок, света, частиц и звуков.
-- Пример: require(game.ServerStorage.Tools.VehicleBaker).bake("HumveeArmored", "Humvee", { mount = "Tower" })
-- Атрибуты шаблона (в нативном масштабе, система координат Root; VehicleService домножает на масштаб):
--   NativeLength / NativeWidth / NativeHeight — габариты Root; DriverOffset — место водителя (если нашли DriveSeat);
--   MountOffset — точка крепления турели на крыше (если нашли деталь opts.mount, иначе центр крыши);
--   Wheels — число колёс (детали FL/FR/RL/RR или с «wheel» в имени помечены атрибутом Wheel).
local SS = game:GetService("ServerStorage")
local VB = {}

local REMOVE_CLASSES = {
	"Seat", "VehicleSeat", "ProximityPrompt", "ParticleEmitter", "Fire", "Smoke", "Sparkles", "Sound", "PointLight", "SpotLight",
	"SurfaceLight", "Weld", "WeldConstraint", "Motor6D", "ManualWeld", "Animation", "ClickDetector", "Highlight", "Beam", "Trail",
}
local REMOVE_NAMES = { ["Regen Button"] = true }

local function bounds(parts)
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in parts do
		local s = p.Size / 2
		for ix = -1, 1, 2 do
			for iy = -1, 1, 2 do
				for iz = -1, 1, 2 do
					local w = p.CFrame:PointToWorldSpace(Vector3.new(s.X * ix, s.Y * iy, s.Z * iz))
					mn = Vector3.new(math.min(mn.X, w.X), math.min(mn.Y, w.Y), math.min(mn.Z, w.Z))
					mx = Vector3.new(math.max(mx.X, w.X), math.max(mx.Y, w.Y), math.max(mx.Z, w.Z))
				end
			end
		end
	end
	return mn, mx
end

-- opts: yaw (радианы, поворот вокруг основания, чтобы перёд смотрел в -Z), mount (имя детали-основания турели),
-- hullCap (доля длины, выше которой коробка-корпус не поднимается; по умолчанию 0.5)
function VB.bake(srcName, name, opts)
	opts = opts or {}
	local lib = SS:FindFirstChild("Assets") and SS.Assets:FindFirstChild("Vehicles")
	local src = lib and lib:FindFirstChild(srcName)
	if not src then
		return false, "нет Assets.Vehicles." .. srcName
	end
	local model = src:Clone()
	model.Name = name
	-- чистка
	local removed = 0
	local driver, mountPart
	for _, d in model:GetDescendants() do
		if d.Name == "DriveSeat" and d:IsA("BasePart") then
			driver = d.Position
		end
		if opts.mount and d.Name == opts.mount and d:IsA("BasePart") then
			mountPart = d
		end
	end
	local driverPos = driver
	local mountPos, mountTop
	if mountPart then
		mountPos = mountPart.Position
		mountTop = mountPart.Position + Vector3.new(0, mountPart.Size.Y / 2, 0) -- верх детали-основания (мир, до поворота)
	end
	local toDestroy = {}
	for _, d in model:GetDescendants() do
		local kill = REMOVE_NAMES[d.Name] == true
		for _, c in REMOVE_CLASSES do
			if d:IsA(c) then
				kill = true
			end
		end
		if d:IsA("Constraint") or d:IsA("LuaSourceContainer") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			kill = true
		end
		if kill then
			table.insert(toDestroy, d)
		end
	end
	for _, d in toDestroy do
		if d.Parent then
			d:Destroy()
			removed += 1
		end
	end

	-- поворот вокруг центра основания (WorldPivot модели), потом на ноль координат
	local pivot = src.WorldPivot
	local rot = CFrame.Angles(0, opts.yaw or 0, 0)
	local function xf(p: Vector3): Vector3
		return rot:PointToWorldSpace(pivot:PointToObjectSpace(p))
	end
	model:PivotTo(rot)
	if driverPos then
		driverPos = xf(driverPos)
	end
	if mountPos then
		mountPos = xf(mountPos)
		mountTop = xf(mountTop)
	end

	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	if #parts == 0 then
		model:Destroy()
		return false, "нет частей"
	end
	local mn, mx = bounds(parts)
	-- основание на землю, центр по X/Z в нуле
	local shift = Vector3.new(-(mn.X + mx.X) / 2, -mn.Y, -(mn.Z + mx.Z) / 2)
	for _, p in parts do
		p.CFrame = p.CFrame + shift
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = true
		p.CanTouch = false
		p.Massless = true
		local ln = p.Name:lower()
		if p.Name == "FL" or p.Name == "FR" or p.Name == "RL" or p.Name == "RR" or ln:find("wheel") or ln:find("tire") then
			p:SetAttribute("Wheel", true)
		end
	end
	if driverPos then
		driverPos += shift
	end
	if mountPos then
		mountPos += shift
		mountTop += shift
	end
	local size = mx - mn
	local hullH = math.min(size.Y, (opts.hullCap or 0.5) * size.Z)
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(size.X, hullH, size.Z)
	root.CFrame = CFrame.new(0, hullH / 2, 0)
	root.Transparency = 1
	root.CanCollide = true
	root.Anchored = false
	root.Parent = model
	model.PrimaryPart = root
	local wheels = 0
	for _, p in parts do
		if p:GetAttribute("Wheel") then
			wheels += 1
		end
	end
	model:SetAttribute("NativeLength", size.Z)
	model:SetAttribute("NativeWidth", size.X)
	model:SetAttribute("NativeHeight", hullH)
	model:SetAttribute("FullHeight", size.Y)
	model:SetAttribute("Wheels", wheels)
	model:SetAttribute("SourceModel", srcName)
	model:SetAttribute("SourceId", src:GetAttribute("SourceId") or 0)
	local c0 = root.Position
	if driverPos then
		model:SetAttribute("DriverOffset", driverPos - c0)
	end
	if mountPos then
		model:SetAttribute("MountOffset", Vector3.new(mountPos.X, mountTop.Y, mountPos.Z) - c0)
	else
		model:SetAttribute("MountOffset", Vector3.new(0, size.Y, 0.1 * size.Z) - c0)
	end
	-- итоговая проверка: ничего исполняемого
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			model:Destroy()
			return false, "после чистки остался исполняемый объект"
		end
	end
	local dst = SS:FindFirstChild("CarModels") or Instance.new("Folder")
	dst.Name = "CarModels"
	dst.Parent = SS
	local prev = dst:FindFirstChild(name)
	if prev then
		prev:Destroy()
	end
	model.Parent = dst
	return true,
		string.format(
			"%s ← %s: %.1f×%.1f(коробка %.1f)×%.1f, частей %d, колёс %d, убрано %d%s%s",
			name, srcName, size.X, size.Y, hullH, size.Z, #parts, wheels, removed,
			if driverPos then ", место водителя найдено" else "", if mountPart then (", турель на " .. opts.mount) else ""
		)
end

-- Турель/орудие для крыши: поворот вокруг основания, центр основания в нуле, ствол в -Z (yaw подбирается по модели)
function VB.bakeTurret(srcPath, name, yaw)
	local node = SS.Assets
	for _, n in string.split(srcPath, "/") do
		node = node:FindFirstChild(n)
		if not node then
			return false, "нет " .. srcPath
		end
	end
	local model = node:Clone()
	model.Name = name
	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Seat") or d:IsA("VehicleSeat") or d:IsA("ProximityPrompt") or d:IsA("ParticleEmitter") or d:IsA("Sound") or d:IsA("Constraint") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local pivot = node.WorldPivot
	local rot = CFrame.Angles(0, yaw or 0, 0)
	for _, p in parts do
		p.CFrame = rot * pivot:ToObjectSpace(p.CFrame) -- система основания → поворот
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
	end
	local mn, mx = bounds(parts)
	local size = mx - mn
	model.WorldPivot = CFrame.new()
	model:SetAttribute("Length", size.Z)
	model:SetAttribute("Width", size.X)
	model:SetAttribute("Height", size.Y)
	model:SetAttribute("MuzzleZ", mn.Z)
	model:SetAttribute("MuzzleY", (mn.Y + mx.Y) / 2)
	local folder = SS.Assets.Weapons:FindFirstChild("Turrets") or Instance.new("Folder")
	folder.Name = "Turrets"
	folder.Parent = SS.Assets.Weapons
	local prev = folder:FindFirstChild(name)
	if prev then
		prev:Destroy()
	end
	model.Parent = folder
	return true, string.format("%s: %.1f×%.1f×%.1f, ствол z=%.1f", name, size.X, size.Y, size.Z, mn.Z)
end

return VB
