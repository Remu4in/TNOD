--!strict
-- Свет в метро: пока игрок под картой (ниже Config.Metro.InsideMaxY) клиент приглушает Lighting — на станции полумрак, в пещере почти полная темнота —
-- и включает фонарик: SpotLight на невидимой детали у камеры (виден только самому игроку). Вышел наверх — прежние значения Lighting возвращаются.
-- Значения Lighting ставит сервер (RoundService, день/ночь); пока мы внизу, держим тёмные значения каждый кадр.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local MetroLightController = {}

local KEYS = { "Brightness", "Ambient", "OutdoorAmbient", "ExposureCompensation", "EnvironmentDiffuseScale", "EnvironmentSpecularScale" }

function MetroLightController.start()
	local player = Players.LocalPlayer
	local saved: { [string]: any }? = nil
	local level = 0 -- 0 — снаружи, 1 — станция, 2 — пещера
	local lamp: Part? = nil
	local acc = 0

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

	local function setLevel(newLevel: number)
		if newLevel == level then
			return
		end
		if level == 0 and newLevel > 0 then
			local snap: { [string]: any } = {}
			for _, k in KEYS do
				snap[k] = (Lighting :: any)[k]
			end
			saved = snap
		elseif newLevel == 0 and saved then
			for k, v in saved do
				(Lighting :: any)[k] = v
			end
			saved = nil
			if lamp then
				lamp:Destroy()
				lamp = nil
			end
		end
		level = newLevel
	end

	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local newLevel = 0
			if root and root.Position.Y < Config.Metro.InsideMaxY then
				local c = Config.Metro.Cave
				newLevel = if root.Position.X > c.minX and root.Position.Z > c.minZ then 2 else 1
			end
			setLevel(newLevel)
		end
		if level == 0 then
			return
		end
		local look = if level == 2 then Config.Metro.Dark.cave else Config.Metro.Dark.station
		for k, v in look do
			(Lighting :: any)[k] = v
		end
		local cam = workspace.CurrentCamera
		if cam then
			ensureLamp().CFrame = cam.CFrame
		end
	end)
end

return MetroLightController
