--!strict
-- Стрельба на клиенте: прицел по камере, запрос на сервер, автоматический огонь при удержании.
-- Урон считает сервер; здесь только ввод и мгновенный визуальный отклик.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local WeaponController = {}

local player = Players.LocalPlayer
local firing = false
local lastShot = 0

local function equipped(): Tool?
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("WeaponId") then
		return tool
	end
	return nil
end

local function aimPoint(): Vector3
	local camera = workspace.CurrentCamera
	local pos = UserInputService:GetMouseLocation()
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		pos = camera.ViewportSize / 2 -- на телефоне стреляем в центр экрана
	end
	local ray = camera:ViewportPointToRay(pos.X, pos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	return if result then result.Position else ray.Origin + ray.Direction * 500
end

local function tryShoot()
	local tool = equipped()
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not tool or not head or player:GetAttribute("Downed") then
		return
	end
	local rate = (tool:GetAttribute("FireRate") :: number?) or 4
	local now = os.clock()
	if now - lastShot < 1 / rate then
		return
	end
	if ((tool:GetAttribute("Mag") :: number?) or 0) <= 0 then
		Remotes.get("Reload"):FireServer()
		return
	end
	lastShot = now
	local origin = head.Position
	local dir = (aimPoint() - origin).Unit
	Remotes.get("Fire"):FireServer(origin, dir)
end

function WeaponController.start()
	-- нажатие/удержание: мышь, тач (через Tool.Activated) и геймпад
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			firing = true
			tryShoot()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			firing = false
		end
	end)

	local function hookTool(tool: Instance)
		if tool:IsA("Tool") and tool:GetAttribute("WeaponId") then
			tool.Activated:Connect(function()
				if UserInputService.TouchEnabled then
					tryShoot()
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

	ContextActionService:BindAction("Reload", function(_, state)
		if state == Enum.UserInputState.Begin then
			Remotes.get("Reload"):FireServer()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
	ContextActionService:SetTitle("Reload", "R")

	-- автоматический огонь при удержании
	task.spawn(function()
		while true do
			task.wait()
			if firing then
				local tool = equipped()
				if tool and tool:GetAttribute("Automatic") then
					tryShoot()
				end
			end
		end
	end)
end

return WeaponController
