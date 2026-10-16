--!strict
-- Диспетчер локаций: собирает карту по id из Config.Locations. Сами локации — в ServerScriptService.Server.Locations.

local Types = require(script.Parent.Parent:WaitForChild("Types"))
local Locations = script.Parent.Parent:WaitForChild("Locations")

local MapBuilder = {}

-- Есть ли уже построенная локация с таким id
function MapBuilder.has(id: string): boolean
	return Locations:FindFirstChild(id) ~= nil
end

function MapBuilder.build(id: string): Types.MapInfo
	local old = workspace:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
	local location = require(Locations:WaitForChild(id)) :: { build: () -> Types.MapInfo }
	return location.build()
end

return MapBuilder
