--!strict
-- Ночные огни базы и машин (только у клиента, сеть не нагружают):
--  • прожекторы на дозорных вышках Workspace.Base.WatchTower — SpotLight и видимый луч (Beam), медленно качаются по сторонам;
--  • мигающие красные огни на крыше каждой вышки и над воротами Workspace.Base.BaseGate;
--  • фары машин и колонны: сервер ставит их выключенными с тегом NightLight, здесь они загораются ночью.
-- Всё создаётся по существующим моделям карты и горит, только пока LookController.isNight(). Тени выключены у всех источников.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local LookController = require(script.Parent:WaitForChild("LookController"))

local NightLightsController = {}

local V = Config.Visual
local TAG = "NightLight"

type Searchlight = { part: BasePart, base: CFrame, phase: number }
type Beacon = { part: BasePart, light: PointLight, phase: number }

local searchlights: { Searchlight } = {}
local beacons: { Beacon } = {}
local folder: Folder? = nil
local built = false

local function newPart(name: string, size: Vector3, cf: CFrame, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- крыша вышки: самая высокая широкая деталь (у ассета — Union 12.8 × 1 × 12.8)
local function roofOf(tower: Instance): BasePart?
	local best: BasePart? = nil
	for _, d in tower:GetDescendants() do
		if d:IsA("BasePart") and d.Size.X >= 6 and d.Size.Z >= 6 then
			if not best or d.Position.Y > best.Position.Y then
				best = d
			end
		end
	end
	return best
end

local function addBeacon(at: Vector3, phase: number, parent: Instance)
	local b = V.Beacons
	local part = newPart("Beacon", Vector3.one * b.Size, CFrame.new(at), b.Color, 0)
	part.Shape = Enum.PartType.Ball
	local light = Instance.new("PointLight")
	light.Color = b.Color
	light.Range = b.Range
	light.Brightness = b.Brightness
	light.Shadows = false
	light.Parent = part
	part.Parent = parent
	table.insert(beacons, { part = part, light = light, phase = phase })
end

local function addSearchlight(at: Vector3, outward: Vector3, phase: number, parent: Instance)
	local s = V.Searchlights
	local flat = Vector3.new(outward.X, 0, outward.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	local base = CFrame.lookAt(at, at + flat.Unit)
	-- корпус прожектора: светящийся диск смотрит вперёд (−Z), от него идут свет и луч
	local part = newPart("Searchlight", Vector3.new(1.4, 1.4, 0.3), base, s.Color, 0)
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Front
	spot.Color = s.Color
	spot.Range = s.Range
	spot.Angle = s.Angle
	spot.Brightness = s.Brightness
	spot.Shadows = false
	spot.Parent = part
	local a0 = Instance.new("Attachment")
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0, -s.BeamLength)
	a1.Parent = part
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = s.BeamWidth0
	beam.Width1 = s.BeamWidth1
	beam.Color = ColorSequence.new(s.Color)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, s.BeamTransparency),
		NumberSequenceKeypoint.new(0.6, (1 + s.BeamTransparency) / 2),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = part
	part.Parent = parent
	table.insert(searchlights, { part = part, base = base, phase = phase })
end

local function build()
	if built then
		return
	end
	local base = workspace:FindFirstChild("Base")
	if not base then
		return
	end
	built = true
	local f = Instance.new("Folder")
	f.Name = "NightLights"
	folder = f
	local roofs: { BasePart } = {}
	for _, tower in base:GetChildren() do
		if tower.Name == "WatchTower" then
			local roof = roofOf(tower)
			if roof then
				table.insert(roofs, roof)
			end
		end
	end
	if #roofs > 0 then
		local center = Vector3.zero
		for _, r in roofs do
			center += r.Position
		end
		center /= #roofs
		for i, roof in roofs do
			local out = roof.Position - center
			out = Vector3.new(out.X, 0, out.Z)
			out = if out.Magnitude > 0.1 then out.Unit else Vector3.new(0, 0, -1)
			local half = math.min(roof.Size.X, roof.Size.Z) / 2
			-- прожектор — под краем крыши на внешней стороне, мигалка — над центром крыши
			addSearchlight(roof.Position + out * (half - 0.6) - Vector3.new(0, 2.2, 0), out, i * 1.7, f)
			addBeacon(roof.Position + Vector3.new(0, roof.Size.Y / 2 + V.Beacons.Size / 2, 0), i * 0.37, f)
		end
	end
	local gate = base:FindFirstChild("BaseGate")
	if gate and gate:IsA("Model") then
		local cf, size = gate:GetBoundingBox()
		-- две мигалки над краями ворот по длинной стороне
		local long = if size.X > size.Z then Vector3.new(size.X / 2 - 1, 0, 0) else Vector3.new(0, 0, size.Z / 2 - 1)
		local top = Vector3.new(0, size.Y / 2 + V.Beacons.Size / 2, 0)
		addBeacon(cf:PointToWorldSpace(top + long), 0, f)
		addBeacon(cf:PointToWorldSpace(top - long), 0.5, f)
	end
	f.Parent = workspace.CurrentCamera -- локально у клиента, не мешает лучам и поиску по Workspace
end

local function setHeadlight(inst: Instance, on: boolean)
	if inst:IsA("Light") then
		inst.Enabled = on
	elseif inst:IsA("BasePart") then
		inst.Transparency = if on then 0 else 1
	end
end

function NightLightsController.start()
	local night = false
	local function setNight(on: boolean)
		night = on
		if on then
			build()
		end
		if folder then
			folder.Parent = if on then workspace.CurrentCamera else nil
		end
		for _, inst in CollectionService:GetTagged(TAG) do
			setHeadlight(inst, on)
		end
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst: Instance)
		setHeadlight(inst, night)
	end)
	setNight(LookController.isNight())
	ReplicatedStorage:GetAttributeChangedSignal("Look"):Connect(function()
		local on = LookController.isNight()
		if on ~= night then
			setNight(on)
		end
	end)

	local s = V.Searchlights
	local b = V.Beacons
	RunService.Heartbeat:Connect(function()
		if not night or LookController.metroLevel() > 0 then
			return
		end
		local t = os.clock()
		for _, sl in searchlights do
			local yaw = math.rad(s.SwayDeg) * math.sin((t / s.SwayPeriod + sl.phase) * math.pi * 2)
			sl.part.CFrame = sl.base * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-s.Pitch), 0, 0)
		end
		for _, bc in beacons do
			local on = ((t / b.Period + bc.phase) % 1) < b.OnFraction
			bc.part.Transparency = if on then 0 else 0.75
			bc.light.Enabled = on
		end
	end)
end

return NightLightsController
