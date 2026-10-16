--!strict
-- Расходники: аптечка и энергетик. Выдаются складами (позже — донатом); применяет и проверяет сервер.

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local StaminaService = require(script.Parent:WaitForChild("StaminaService"))

local ItemService = {}

local function notify(player: Player, text: string)
	Remotes.get("Notify"):FireClient(player, text, 1.5)
end

local function use(tool: Tool)
	if tool:GetAttribute("Used") then
		return
	end
	local char = tool.Parent
	if not char or not char:IsA("Model") then
		return
	end
	local player = Players:GetPlayerFromCharacter(char)
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not player or not humanoid or humanoid.Health <= 0 or player:GetAttribute("Downed") then
		return
	end
	local itemId = tool:GetAttribute("ItemId")
	local def = if typeof(itemId) == "string" then Config.Items[itemId] else nil
	if not def then
		return
	end
	if def.heal then
		if humanoid.Health >= humanoid.MaxHealth then
			notify(player, "Здоровье полное")
			return
		end
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + def.heal)
	end
	if def.energy then
		if ((player:GetAttribute("Energy") :: number?) or Config.Player.EnergyMax) >= Config.Player.EnergyMax - 1 then
			notify(player, "Энергия полная")
			return
		end
		StaminaService.addEnergy(player, def.energy)
	end
	tool:SetAttribute("Used", true)
	tool:Destroy()
end

local function buildTool(itemId: string, def: Config.ItemDef): Tool
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("ItemId", itemId)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Color = def.color
	handle.Material = Enum.Material.SmoothPlastic
	handle.CanCollide = false
	handle.Massless = true
	if def.heal then
		-- аптечка: белая коробка с красным крестом
		handle.Size = Vector3.new(1.1, 0.8, 0.5)
		handle.Parent = tool
		for _, size in { Vector3.new(0.6, 0.12, 0.18), Vector3.new(0.18, 0.12, 0.6) } do
			local cross = Instance.new("Part")
			cross.Name = "Cross"
			cross.Size = size
			cross.Color = Color3.fromRGB(215, 40, 40)
			cross.Material = Enum.Material.SmoothPlastic
			cross.CanCollide = false
			cross.Massless = true
			cross.CFrame = handle.CFrame * CFrame.new(0, 0.44, 0)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = handle
			weld.Part1 = cross
			weld.Parent = cross
			cross.Parent = tool
		end
	else
		-- энергетик: банка
		handle.Shape = Enum.PartType.Cylinder
		handle.Size = Vector3.new(0.9, 0.5, 0.5)
		handle.Material = Enum.Material.Metal
		handle.Parent = tool
	end
	tool.Activated:Connect(function()
		use(tool)
	end)
	return tool
end

-- Выдать предмет игроку (в рюкзак)
function ItemService.give(player: Player, itemId: string)
	local def = Config.Items[itemId]
	if not def then
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if backpack then
		buildTool(itemId, def).Parent = backpack
	end
end

return ItemService
