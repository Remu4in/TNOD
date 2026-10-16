--!strict
-- Спринт: Shift / L3 (ПК, геймпад) и кнопка «Бег» на телефоне (переключатель).
-- Энергию и скорость считает сервер; здесь — ввод и лёгкий эффект поля зрения при беге.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local MovementController = {}

local player = Players.LocalPlayer
local BASE_FOV, SPRINT_FOV = 70, 78
local wanted = false

local function setWanted(on: boolean)
	if wanted ~= on then
		wanted = on
		Remotes.get("Sprint"):FireServer(on)
	end
end

function MovementController.start()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	ContextActionService:BindAction("NotdSprint", function(_, state)
		if touchOnly then
			-- на телефоне кнопка работает как переключатель
			if state == Enum.UserInputState.Begin then
				setWanted(not wanted)
			end
		elseif state == Enum.UserInputState.Begin then
			setWanted(true)
		else
			setWanted(false)
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle("NotdSprint", "Бег")

	-- энергия кончилась: сервер уже остановил спринт, сбрасываем своё «хочу бежать»
	player:GetAttributeChangedSignal("Energy"):Connect(function()
		local energy = (player:GetAttribute("Energy") :: number?) or Config.Player.EnergyMax
		if wanted and energy <= 0 then
			wanted = false
		end
	end)

	-- при спринте поле зрения чуть шире
	RunService.RenderStepped:Connect(function(dt: number)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local target = if player:GetAttribute("Sprinting") == true then SPRINT_FOV else BASE_FOV
		camera.FieldOfView += (target - camera.FieldOfView) * math.min(1, dt * 8)
	end)
end

return MovementController
