--!strict
-- Общие источники света для машин: фары. Сервер ставит их выключенными и помечает тегом NightLight —
-- клиент (NightLightsController) включает ночью. Один SpotLight на машину (без теней) и две неоновые «линзы» для свечения.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local LightKit = {}

local TAG = "NightLight"

-- forward — направление «вперёд» машины в мире; фары ставим на передний край габарита модели, на трети высоты
function LightKit.headlights(model: Model, anchor: BasePart, forward: Vector3)
	if model:FindFirstChild("NightHeadlight", true) then
		return
	end
	local h = Config.Visual.Headlights
	local fwd = Vector3.new(forward.X, 0, forward.Z)
	if fwd.Magnitude < 0.01 then
		return
	end
	fwd = fwd.Unit
	local cf, size = model:GetBoundingBox()
	local reach = math.abs(fwd:Dot(cf.RightVector)) * size.X / 2 + math.abs(fwd:Dot(cf.UpVector)) * size.Y / 2 + math.abs(fwd:Dot(cf.LookVector)) * size.Z / 2
	local side = math.abs(fwd:Cross(Vector3.yAxis):Dot(cf.RightVector)) * size.X / 2 + math.abs(fwd:Cross(Vector3.yAxis):Dot(cf.LookVector)) * size.Z / 2
	local front = cf.Position + fwd * (reach - 0.05) + Vector3.new(0, -size.Y / 2 + size.Y * 0.33, 0)
	local right = fwd:Cross(Vector3.yAxis).Unit
	local face = CFrame.lookAt(front, front + fwd)

	-- носитель света — невидимая приваренная деталь (SpotLight на Attachment в проверке 2026-11-04 дорогу не освещал)
	local holder = Instance.new("Part")
	holder.Name = "NightHeadlight"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.CFrame = face * CFrame.Angles(math.rad(-8), 0, 0) -- чуть вниз, на дорогу
	holder.Anchored = false
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Massless = true
	holder.CastShadow = false
	local hw = Instance.new("WeldConstraint")
	hw.Part0 = anchor
	hw.Part1 = holder
	hw.Parent = holder
	holder.Parent = model
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Front
	spot.Range = h.Range
	spot.Angle = h.Angle
	spot.Brightness = h.Brightness
	spot.Color = h.Color
	spot.Shadows = false
	spot.Enabled = false
	spot.Parent = holder
	CollectionService:AddTag(spot, TAG)

	for _, k in { -1, 1 } do
		local lens = Instance.new("Part")
		lens.Name = "NightHeadlightLens"
		lens.Size = h.LensSize
		lens.CFrame = face + right * k * math.max(side * 0.65, 0.8)
		lens.Color = h.Color
		lens.Material = Enum.Material.Neon
		lens.Transparency = 1
		lens.Anchored = false
		lens.CanCollide = false
		lens.CanQuery = false
		lens.CanTouch = false
		lens.Massless = true
		lens.CastShadow = false
		local w = Instance.new("WeldConstraint")
		w.Part0 = anchor
		w.Part1 = lens
		w.Parent = lens
		lens.Parent = model
		CollectionService:AddTag(lens, TAG)
	end
end

return LightKit
