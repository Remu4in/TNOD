--!strict
-- Россыпь костей на полу (метро и пещера): отдельные кости из ассета C_BonesAssortment (бедро, плечо, рёбра, позвонки…), черепа и кости C_Bone_A кладутся
-- по одной, каждая — на свой пол (луч вниз) с учётом её поворота. Модели целиком не двигаем: у них pivot смещён от габарита, и кости «висели» над полом
-- или уходили в него. Библиотека: ServerStorage.Assets.Metro.New (файл места).

local ServerStorage = game:GetService("ServerStorage")

local BoneKit = {}

local PIECE_SCALE = 2.6
local SKULL_SCALE = 2

local function library(): Instance?
	local assets = ServerStorage:FindFirstChild("Assets")
	local metro = assets and assets:FindFirstChild("Metro")
	return metro and metro:FindFirstChild("New")
end

-- Полувысота повёрнутой детали над своим центром
local function halfHeight(cf: CFrame, size: Vector3): number
	return 0.5 * (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z)
end

-- Собрать шаблоны кусочков: { part, ... } из ассортимента, отдельный череп и кость A
local function templates(): ({ MeshPart }, MeshPart?, MeshPart?)
	local lib = library()
	local pieces: { MeshPart } = {}
	local skull: MeshPart? = nil
	local boneA: MeshPart? = nil
	if not lib then
		return pieces, skull, boneA
	end
	local assort = lib:FindFirstChild("C_BonesAssortment_14047690299")
	if assort then
		for _, d in assort:GetDescendants() do
			if d:IsA("MeshPart") and d.Transparency < 1 then
				table.insert(pieces, d)
			end
		end
	end
	local sk = lib:FindFirstChild("C_Skull_5528640463")
	skull = sk and sk:FindFirstChildWhichIsA("MeshPart", true)
	local ba = lib:FindFirstChild("C_Bone_A_11573236999")
	boneA = ba and ba:FindFirstChildWhichIsA("MeshPart", true)
	return pieces, skull, boneA
end

-- Россыпь вокруг точки center (x, z берутся из неё): count костей в радиусе spread; floorY(x, z) → y пола (nil — пропустить кость).
-- Возвращает Model в parent (или nil, если библиотеки нет).
function BoneKit.cluster(parent: Instance, name: string, center: Vector3, seed: number, count: number, spread: number, floorY: (number, number) -> number?): Model?
	local pieces, skull, boneA = templates()
	if #pieces == 0 then
		return nil
	end
	local rng = Random.new(seed)
	local model = Instance.new("Model")
	model.Name = name
	local function put(src: MeshPart, scale: number, x: number, z: number, yaw: number)
		local y = floorY(x, z)
		if not y then
			return
		end
		local p = src:Clone()
		p:ClearAllChildren()
		p.Size = src.Size * scale
		local rot = CFrame.Angles(0, yaw, 0) * src.CFrame.Rotation
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CFrame = CFrame.new(x, y + halfHeight(rot, p.Size) - 0.05, z) * rot
		p.Parent = model
	end
	for _ = 1, count do
		local ang = rng:NextNumber(0, math.pi * 2)
		local r = spread * math.sqrt(rng:NextNumber())
		local src = pieces[rng:NextInteger(1, #pieces)]
		put(src, PIECE_SCALE * rng:NextNumber(0.8, 1.25), center.X + math.cos(ang) * r, center.Z + math.sin(ang) * r, rng:NextNumber(0, math.pi * 2))
	end
	if skull then
		for _ = 1, rng:NextInteger(1, 2) do
			local ang = rng:NextNumber(0, math.pi * 2)
			local r = spread * 0.8 * math.sqrt(rng:NextNumber())
			put(skull, SKULL_SCALE * rng:NextNumber(0.9, 1.2), center.X + math.cos(ang) * r, center.Z + math.sin(ang) * r, rng:NextNumber(0, math.pi * 2))
		end
	end
	if boneA then
		for _ = 1, rng:NextInteger(2, 4) do
			local ang = rng:NextNumber(0, math.pi * 2)
			local r = spread * math.sqrt(rng:NextNumber())
			put(boneA, 3 * rng:NextNumber(0.8, 1.3), center.X + math.cos(ang) * r, center.Z + math.sin(ang) * r, rng:NextNumber(0, math.pi * 2))
		end
	end
	model.Parent = parent
	return model
end

return BoneKit
