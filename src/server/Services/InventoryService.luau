--!strict
-- Ограничения инвентаря: всего предметов (оружие, расходники, оборудование) и расходников одного вида. Field kit (донат) поднимает лимит расходников.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local InventoryService = {}

local function tools(player: Player): { Tool }
	local list: { Tool } = {}
	for _, c in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if c then
			for _, t in c:GetChildren() do
				if t:IsA("Tool") then
					table.insert(list, t)
				end
			end
		end
	end
	return list
end

function InventoryService.count(player: Player): number
	return #tools(player)
end

function InventoryService.isFull(player: Player): boolean
	return InventoryService.count(player) >= Config.Inventory.MaxItems
end

function InventoryService.itemCount(player: Player, itemId: string): number
	local n = 0
	for _, t in tools(player) do
		if t:GetAttribute("ItemId") == itemId then
			n += 1
		end
	end
	return n
end

function InventoryService.itemLimit(player: Player): number
	return if player:GetAttribute("Has_fieldkit") == true then Config.Inventory.FieldKitMax else Config.Inventory.ItemMax
end

-- Можно ли взять расходник; nil — можно, иначе текст для игрока
function InventoryService.itemDenied(player: Player, itemId: string): string?
	if InventoryService.isFull(player) then
		return string.format("Inventory full (%d items)", Config.Inventory.MaxItems)
	end
	if InventoryService.itemCount(player, itemId) >= InventoryService.itemLimit(player) then
		local def = Config.Items[itemId]
		return string.format("You can carry %d: %s", InventoryService.itemLimit(player), if def then def.name else itemId)
	end
	return nil
end

return InventoryService
