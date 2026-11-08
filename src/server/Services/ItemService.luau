--!strict
-- Расходники: аптечка и энергетик. Выдаются складами (позже — донатом); применяет и проверяет сервер.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local StaminaService = require(script.Parent:WaitForChild("StaminaService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))

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
			notify(player, "Health is full")
			return
		end
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + def.heal)
	end
	if def.energy then
		if ((player:GetAttribute("Energy") :: number?) or Config.Player.EnergyMax) >= Config.Player.EnergyMax - 1 then
			notify(player, "Energy is full")
			return
		end
		StaminaService.addEnergy(player, def.energy)
	end
	if def.infiniteWaves then
		StaminaService.grantInfinite(player, def.infiniteWaves)
		notify(player, "Infinite energy — until the end of the next night", 3)
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
	tool.Activated:Connect(function()
		use(tool)
	end)
	-- готовая модель из Assets.Items (деталь с именем предмета); нет её — простая заготовка ниже
	local assets = ServerStorage:FindFirstChild("Assets")
	local items = assets and assets:FindFirstChild("Items")
	local template = items and items:FindFirstChild(itemId)
	if template and template:IsA("BasePart") then
		local model = template:Clone()
		model.Name = "Handle"
		model.Parent = tool
		return tool
	end
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
	return tool
end

-- Выдать предмет игроку (в рюкзак); false — лимит (игрок получает сообщение)
function ItemService.give(player: Player, itemId: string): boolean
	local def = Config.Items[itemId]
	if not def then
		return false
	end
	local denied = InventoryService.itemDenied(player, itemId)
	if denied then
		notify(player, denied)
		return false
	end
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if backpack then
		buildTool(itemId, def).Parent = backpack
		return true
	end
	return false
end

-- Лечение тиммейта: подсказка на каждом персонаже, клиент показывает её только с аптечкой в руках (SquadController); проверяет сервер
local function setupHealPrompt(target: Player, char: Model)
	local root = char:WaitForChild("HumanoidRootPart", 5)
	if not root then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HealPrompt"
	prompt.ActionText = "Heal"
	prompt.ObjectText = target.DisplayName
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(helper: Player)
		local hChar = helper.Character
		local tool = hChar and hChar:FindFirstChildOfClass("Tool")
		local hum = char:FindFirstChildOfClass("Humanoid")
		local helperHum = hChar and hChar:FindFirstChildOfClass("Humanoid")
		local def = Config.Items.Medkit
		if helper == target or not tool or tool:GetAttribute("ItemId") ~= "Medkit" or tool:GetAttribute("Used") then
			return
		end
		if not hum or hum.Health <= 0 or target:GetAttribute("Downed") or not helperHum or helperHum.Health <= 0 or helper:GetAttribute("Downed") then
			return
		end
		if hum.Health >= hum.MaxHealth then
			notify(helper, target.DisplayName .. ": health is full")
			return
		end
		tool:SetAttribute("Used", true)
		tool:Destroy()
		hum.Health = math.min(hum.MaxHealth, hum.Health + (def.heal or 0))
		notify(helper, "Healed " .. target.DisplayName)
		notify(target, helper.DisplayName .. " healed you")
	end)
end

function ItemService.init()
	local function watch(p: Player)
		p.CharacterAdded:Connect(function(char: Model)
			setupHealPrompt(p, char)
		end)
		if p.Character then
			task.spawn(setupHealPrompt, p, p.Character)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return ItemService
