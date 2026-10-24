--!strict
-- Оборудование в руках (турель, проволока): та же кнопка, что огонь оружия (левая кнопка мыши, ButtonR2 на геймпаде,
-- касание экрана на телефоне через Tool.Activated), ставит его на землю в точке прицела в центре экрана. Всё остальное решает сервер.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))

local EquipController = {}

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

function EquipController.start()
	local player = Players.LocalPlayer
	local lastPlace = 0

	local function place()
		local char = player.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		if not char or not tool or tool:GetAttribute("EquipKind") == nil then
			return
		end
		-- на сенсорном ноутбуке одно нажатие даёт и клик, и Activated: ставим один раз
		local now = os.clock()
		if now - lastPlace < 0.3 then
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		lastPlace = now
		local size = cam.ViewportSize
		local ray = cam:ViewportPointToRay(size.X / 2, size.Y / 2)
		params.FilterDescendantsInstances = { char :: Instance }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 60, params)
		if hit then
			Remotes.get("PlaceEquipment"):FireServer(hit.Position)
		end
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			place()
		end
	end)

	-- телефон: касание экрана активирует Tool (как выстрел оружия в WeaponController); подключаемся к Tool один раз
	local hooked: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function hookTool(tool: Instance)
		if tool:IsA("Tool") and tool:GetAttribute("EquipKind") ~= nil and not hooked[tool] then
			hooked[tool] = true
			tool.Activated:Connect(function()
				if UserInputService.TouchEnabled then
					place()
				end
			end)
		end
	end
	player.CharacterAdded:Connect(function(char)
		char.ChildAdded:Connect(hookTool)
	end)
	if player.Character then
		player.Character.ChildAdded:Connect(hookTool)
	end
end

return EquipController
