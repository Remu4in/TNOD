--!strict
-- Езда на машине (клиент водителя): пока игрок сидит на «DriverSeat», читаем газ/руль с VehicleSeat и задаём корпусу
-- скорость и поворот. Сервер сеть для сидящего отдаёт клиенту, поэтому управление отзывчивое.
-- Для тестов: атрибуты DbgThrottle / DbgSteer на сиденье подменяют ввод.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local VehicleController = {}

local T = Config.Vehicle

local function approach(v: number, target: number, step: number): number
	if v < target then
		return math.min(v + step, target)
	end
	return math.max(v - step, target)
end

function VehicleController.start()
	local player = Players.LocalPlayer
	RunService.Heartbeat:Connect(function(dt: number)
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		if not seat or not seat:IsA("VehicleSeat") or seat.Name ~= "DriverSeat" then
			return
		end
		local model = seat.Parent
		local root = model and (model :: Model).PrimaryPart
		if not root then
			return
		end
		local v = root.AssemblyLinearVelocity
		local fwd = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		if fwd.Magnitude < 1e-3 then
			return
		end
		fwd = fwd.Unit
		local speed = (v * Vector3.new(1, 0, 1)):Dot(fwd)
		local throttle = (seat:GetAttribute("DbgThrottle") :: number?) or seat.ThrottleFloat
		local steer = (seat:GetAttribute("DbgSteer") :: number?) or seat.SteerFloat
		local target = 0
		local rate = T.drag
		if throttle > 0.05 then
			target = T.maxSpeed * throttle
			rate = if speed < -1 then T.brake else T.accel
		elseif throttle < -0.05 then
			target = -T.reverseSpeed
			rate = if speed > 1 then T.brake else T.accel
		end
		speed = approach(speed, target, rate * dt)
		local planar = fwd * speed
		root.AssemblyLinearVelocity = Vector3.new(planar.X, v.Y, planar.Z)
		-- руль: чем быстрее, тем тяжелее; на месте не поворачивает
		local steerRate = T.turn * math.clamp(speed / 22, -1, 1) / (1 + math.abs(speed) / 90)
		root.AssemblyAngularVelocity = Vector3.new(0, -steer * steerRate, 0)
		if root.CFrame.UpVector.Y < 0.96 then -- после удара завалился: ставим на колёса, курс сохраняем
			local pos = root.Position
			root.CFrame = CFrame.lookAt(pos, pos + fwd)
		end
	end)
end

return VehicleController
