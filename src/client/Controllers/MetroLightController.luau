--!strict
-- Фонарик в метро: пока игрок под картой (LookController.metroLevel() > 0), на невидимой детали у камеры горит SpotLight (виден только самому игроку).
-- Свет станции и пещеры (полумрак, туман, цветокоррекция) ставит LookController по пресетам Config.Visual.Presets.metro / .cave.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local LookController = require(script.Parent:WaitForChild("LookController"))

local MetroLightController = {}

function MetroLightController.start()
	local lamp: Part? = nil

	local function ensureLamp(): Part
		if lamp and lamp.Parent then
			return lamp
		end
		local part = Instance.new("Part")
		part.Name = "MetroFlashlight"
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		local f = Config.Metro.Flashlight
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Front
		spot.Range = f.Range
		spot.Angle = f.Angle
		spot.Brightness = f.Brightness
		spot.Color = f.Color
		spot.Shadows = false
		spot.Parent = part
		local glow = Instance.new("PointLight")
		glow.Range = 12
		glow.Brightness = 0.5
		glow.Color = f.Color
		glow.Shadows = false
		glow.Parent = part
		part.Parent = workspace.CurrentCamera
		lamp = part
		return part
	end

	RunService.Heartbeat:Connect(function()
		if LookController.metroLevel() == 0 then
			if lamp then
				lamp:Destroy()
				lamp = nil
			end
			return
		end
		local cam = workspace.CurrentCamera
		if cam then
			ensureLamp().CFrame = cam.CFrame
		end
	end)
end

return MetroLightController
