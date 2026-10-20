--!strict
-- Оборудование в руках (турель, проволока): клик ставит его на землю в точке прицела. Всё остальное решает сервер.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))

local EquipController = {}

function EquipController.start()
	local player = Players.LocalPlayer
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local char = player.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		if not tool or tool:GetAttribute("EquipKind") == nil then
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local size = cam.ViewportSize
		local ray = cam:ViewportPointToRay(size.X / 2, size.Y / 2)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char :: Instance }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 60, params)
		if hit then
			Remotes.get("PlaceEquipment"):FireServer(hit.Position)
		end
	end)
end

return EquipController
