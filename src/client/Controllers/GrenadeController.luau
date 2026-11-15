--!strict
-- Граната в руках: нажатие (ЛКМ / касание) — бросок туда, куда смотрит камера. Клиент присылает только направление;
-- есть ли граната, пауза между бросками, полёт и урон — на сервере (ItemService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local GrenadeController = {}

local function hook(tool: Instance)
	if not tool:IsA("Tool") or tool:GetAttribute("ItemId") ~= "Grenade" or tool:GetAttribute("GrenadeHooked") then
		return
	end
	tool:SetAttribute("GrenadeHooked", true)
	tool.Activated:Connect(function()
		local cam = workspace.CurrentCamera
		if cam then
			Remotes.get("ThrowGrenade"):FireServer(cam.CFrame.LookVector)
		end
	end)
end

function GrenadeController.start()
	local player = Players.LocalPlayer
	local function watch(container: Instance)
		for _, t in container:GetChildren() do
			hook(t)
		end
		container.ChildAdded:Connect(hook)
	end
	local backpack = player:WaitForChild("Backpack")
	watch(backpack)
	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then
			watch(c)
		end
	end)
	local function onChar(char: Model)
		watch(char)
	end
	if player.Character then
		onChar(player.Character)
	end
	player.CharacterAdded:Connect(onChar)
end

return GrenadeController
