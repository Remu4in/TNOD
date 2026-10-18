-- Приведение R6-модели к стандартному ригу Roblox (в Studio — ServerStorage.Tools.NormalizeR6, только Edit).
-- Нужен для старых R6 без HumanoidRootPart и с жёсткими Snap/Weld вместо Motor6D: стандартные анимации R6
-- (idle 180435571, walk 180426354) крутят именно Motor6D со стандартными C0/C1 (поворот осей важен).
-- Конечности ставятся в стандартную позу; аксессуары (Weld к Head/Torso) не трогаем.
local N = {}

local function rot(a, b, c, d, e, f, g, h, i) -- матрица поворота без смещения
	return CFrame.new(0, 0, 0, a, b, c, d, e, f, g, h, i)
end
local R_ROOT = rot(-1, 0, 0, 0, 0, 1, 0, 1, 0)
local R_RIGHT = rot(0, 0, 1, 0, 1, 0, -1, 0, 0)
local R_LEFT = rot(0, 0, -1, 0, 1, 0, 1, 0, 0)

-- имя, родитель, ребёнок, C0, C1
local SPEC = {
	{ "Neck", "Torso", "Head", CFrame.new(0, 1, 0) * R_ROOT, CFrame.new(0, -0.5, 0) * R_ROOT },
	{ "Right Shoulder", "Torso", "Right Arm", CFrame.new(1, 0.5, 0) * R_RIGHT, CFrame.new(-0.5, 0.5, 0) * R_RIGHT },
	{ "Left Shoulder", "Torso", "Left Arm", CFrame.new(-1, 0.5, 0) * R_LEFT, CFrame.new(0.5, 0.5, 0) * R_LEFT },
	{ "Right Hip", "Torso", "Right Leg", CFrame.new(1, -1, 0) * R_RIGHT, CFrame.new(0.5, 1, 0) * R_RIGHT },
	{ "Left Hip", "Torso", "Left Leg", CFrame.new(-1, -1, 0) * R_LEFT, CFrame.new(-0.5, 1, 0) * R_LEFT },
}

function N.normalize(model: Model)
	local torso = model:FindFirstChild("Torso") :: BasePart
	local names = { Torso = true, Head = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true, HumanoidRootPart = true }
	-- убрать все жёсткие/старые соединения между основными частями
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") and d.Part0 and d.Part1 and names[d.Part0.Name] and names[d.Part1.Name] then
			d:Destroy()
		end
	end
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Transparency = 1
		hrp.CanCollide = false
		hrp.CFrame = torso.CFrame
		hrp.Parent = model
	end
	local root = hrp :: BasePart
	local rj = Instance.new("Motor6D")
	rj.Name = "RootJoint"
	rj.Part0, rj.Part1 = root, torso
	rj.C0, rj.C1 = R_ROOT, R_ROOT
	rj.Parent = root
	for _, s in SPEC do
		local child = model:FindFirstChild(s[3]) :: BasePart
		if child then
			torso.CFrame = torso.CFrame -- родитель остаётся на месте
			child.CFrame = torso.CFrame * s[4] * s[5]:Inverse()
			local m = Instance.new("Motor6D")
			m.Name = s[1]
			m.Part0, m.Part1 = torso, child
			m.C0, m.C1 = s[4], s[5]
			m.Parent = torso
		end
	end
	root.CFrame = torso.CFrame
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
		end
	end
end

return N
