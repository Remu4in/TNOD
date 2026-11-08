--!strict
-- Модели для иконок оружия в магазинах: копии из ServerStorage.Assets.Weapons в ReplicatedStorage.WeaponIcons (только меши, без скриптов).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local WeaponIconService = {}

local function library(ref: string): Model?
	local node: Instance? = ServerStorage:FindFirstChild("Assets")
	for _, name in string.split("Weapons/" .. ref, "/") do
		node = if node then node:FindFirstChild(name) else nil
	end
	return if node and node:IsA("Model") then node else nil
end

function WeaponIconService.init()
	if ReplicatedStorage:FindFirstChild("WeaponIcons") then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "WeaponIcons"
	for id, def in Config.WeaponModels do
		local src = def.ref ~= "" and library(def.ref) or nil
		if src then
			local model = Instance.new("Model")
			model.Name = id
			for _, part in src:GetChildren() do
				if part:IsA("MeshPart") and not string.find(part.Name, "^Speedloader") then
					local copy = part:Clone()
					copy.Anchored = true
					copy.CanCollide = false
					copy.CanQuery = false
					copy.CanTouch = false
					copy.Parent = model
				end
			end
			model.Parent = folder
		end
	end
	folder.Parent = ReplicatedStorage
end

return WeaponIconService
