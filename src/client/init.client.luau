--!strict
-- Точка входа клиента.
local Controllers = script:WaitForChild("Controllers")
require(Controllers:WaitForChild("HUDController")).start()
require(Controllers:WaitForChild("WeaponController")).start()
require(Controllers:WaitForChild("EffectsController")).start()
require(Controllers:WaitForChild("ArmsController")).start()
