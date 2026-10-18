-- Запекание R6-зомби из ассета в ServerStorage.Assets.Zombies (в Studio — ServerStorage.Tools.BakeZombie, только Edit).
-- Что делает: ищет в ассете модели с R6-Humanoid, чистит (все скрипты, Remote/Bindable, Sound, ParticleEmitter, значения-настройки,
-- Animation), записывает id анимаций атрибутами Anim_<роль>, при нестандартных суставах приводит к стандартному R6 (NormalizeR6).
-- Использование: BakeZombie.run(sourceId, { names... }) — имена по порядку найденных моделей; nil в списке — пропустить модель.
local IS = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")
local Normalize = require(ServerStorage.Tools.NormalizeR6)

local ROLE = { Animation1 = "idle", IdleArms = "idleArms", WalkAnim = "walk", RunAnim = "run", Attack = "attack", Arms = "arms" }
local DROP = { Script = true, LocalScript = true, ModuleScript = true, RemoteEvent = true, RemoteFunction = true, BindableEvent = true, BindableFunction = true,
	Sound = true, ParticleEmitter = true, Animation = true, StringValue = true, NumberValue = true, BoolValue = true, ObjectValue = true,
	Vector3Value = true, BrickColorValue = true, BinaryStringValue = true, Configuration = true }

local B = {}

-- модели с R6-Humanoid, не вложенные в другую такую же модель
local function findRigs(root: Instance): { Model }
	local list = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Humanoid") and d.RigType == Enum.HumanoidRigType.R6 and d.Parent and d.Parent:IsA("Model") and d.Parent:FindFirstChild("Torso") then
			table.insert(list, d.Parent)
		end
	end
	return list
end
B.findRigs = findRigs

local function standardJoints(model: Model): boolean
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 and (d.Part1.Name == "Torso" or d.Part1.Name == "Head" or d.Part1.Name == "Left Arm" or d.Part1.Name == "Right Arm" or d.Part1.Name == "Left Leg" or d.Part1.Name == "Right Leg") then
			n += 1
		end
	end
	return n == 6
end

function B.bake(sourceId: number, model: Model, name: string): string
	local anims = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Animation") and ROLE[d.Name] and not anims[ROLE[d.Name]] then
			anims[ROLE[d.Name]] = string.match(d.AnimationId, "%d+$")
		end
	end
	local c = model:Clone()
	for _, d in c:GetDescendants() do
		if DROP[d.ClassName] then
			d:Destroy()
		end
	end
	local needFix = not standardJoints(c)
	if needFix then
		Normalize.normalize(c)
	end
	c.Name = name
	c:SetAttribute("SourceId", tostring(sourceId))
	c:SetAttribute("Stripped", true)
	c:SetAttribute("RigType", "R6")
	c:SetAttribute("Normalized", needFix)
	for role, id in anims do
		c:SetAttribute("Anim_" .. role, id)
	end
	local h = c:FindFirstChildOfClass("Humanoid") :: Humanoid
	if not h:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = h
	end
	local lib = ServerStorage.Assets
	local zf = lib:FindFirstChild("Zombies") or Instance.new("Folder", lib)
	zf.Name = "Zombies"
	local old = zf:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	c.Parent = zf
	local keys = {}
	for r, id in anims do
		table.insert(keys, r .. "=" .. id)
	end
	table.sort(keys)
	local size = c:GetExtentsSize()
	return string.format("%s src=%d fix=%s h=%.1f w=%.1f anims: %s", name, sourceId, tostring(needFix), size.Y, size.X, table.concat(keys, " "))
end

function B.run(sourceId: number, names: { string? }): { string }
	local out = {}
	local asset = IS:LoadAsset(sourceId)
	local rigs = findRigs(asset)
	table.insert(out, sourceId .. ": моделей R6 " .. #rigs)
	for i, m in rigs do
		local nm = names[i]
		if nm then
			local ok, res = pcall(B.bake, sourceId, m, nm)
			table.insert(out, "  #" .. i .. " [" .. m.Name .. "] " .. (if ok then res else "ОШИБКА " .. tostring(res)))
		else
			table.insert(out, "  #" .. i .. " [" .. m.Name .. "] пропущена")
		end
	end
	asset:Destroy()
	return out
end

return B
