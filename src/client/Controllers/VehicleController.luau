--!strict
-- Езда на машине (клиент водителя): пока игрок сидит на «DriverSeat», читаем газ/руль с VehicleSeat и задаём корпусу
-- скорость и поворот. Сервер сеть для сидящего отдаёт клиенту, поэтому управление отзывчивое.
-- Для тестов: атрибуты DbgThrottle / DbgSteer на сиденье подменяют ввод.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))

local VehicleController = {}

-- Настройка езды берётся по типу машины (атрибут VehicleType, Config.VehicleTypes); нет типа — запасная Config.Vehicle
local function tuneOf(model: Instance): { maxSpeed: number, reverseSpeed: number, accel: number, brake: number, drag: number, turn: number }
	local typeId = model:GetAttribute("VehicleType")
	local t = if typeof(typeId) == "string" then Config.VehicleTypes[typeId] else nil
	return t or Config.Vehicle
end

local function approach(v: number, target: number, step: number): number
	if v < target then
		return math.min(v + step, target)
	end
	return math.max(v - step, target)
end

-- Панель мест вместо панели оружия: 1 водитель, 2 переднее пассажирское, 3–4 задние, 0 турель (если есть).
-- Клик/касание или клавиша с номером места пересаживает на свободное место (сервер проверяет).
-- Геймпад: крестовина влево/вправо — на предыдущее/следующее свободное место (кнопки оружия и движения не заняты).
local SEAT_LABELS: { [number]: string } = { [1] = "Driver", [2] = "Passenger", [3] = "Rear left", [4] = "Rear right", [0] = "Turret" }
local SEAT_ORDER = { 1, 2, 3, 4, 0 }
local SEAT_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Zero] = 0,
}
local SEAT_STEP: { [Enum.KeyCode]: number } = { [Enum.KeyCode.DPadRight] = 1, [Enum.KeyCode.DPadLeft] = -1 }

local function startSeatPanel(player: Player)
	local gui = Instance.new("ScreenGui")
	gui.Name = "SeatPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 12
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	local row = Instance.new("Frame")
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -14)
	row.Size = UDim2.fromOffset(0, 64)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.BackgroundTransparency = 1
	row.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = row

	local padHint = Instance.new("TextLabel")
	padHint.AnchorPoint = Vector2.new(0.5, 1)
	padHint.Position = UDim2.new(0.5, 0, 1, -84)
	padHint.Size = UDim2.fromOffset(240, 22)
	padHint.BackgroundTransparency = 1
	padHint.Font = Enum.Font.GothamBold
	padHint.TextSize = 14
	padHint.TextColor3 = Color3.new(1, 1, 1)
	padHint.TextStrokeTransparency = 0.5
	padHint.Text = "◀ ▶ — change seat"
	padHint.Visible = false
	padHint.Parent = gui

	local buttons: { [number]: TextButton } = {}
	local seatTaken: { [number]: boolean } = {} -- занятые места (кроме своего), обновляется каждый кадр
	local mySeat: number? = nil
	for _, index in SEAT_ORDER do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(86, 64)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextWrapped = true
		b.LayoutOrder = if index == 0 then 5 else index
		b.Text = index .. "\n" .. SEAT_LABELS[index]
		b.Visible = false
		b.Parent = row
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = b
		b.Activated:Connect(function()
			Remotes.get("SwitchSeat"):FireServer(index)
		end)
		buttons[index] = b
	end

	local active = false
	local function setActive(on: boolean)
		if on == active then
			return
		end
		active = on
		gui.Enabled = on
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, not on)
		end)
		if on then
			ContextActionService:BindActionAtPriority("SeatKeys", function(_, state, input)
				if state == Enum.UserInputState.Begin then
					local index = SEAT_KEYS[input.KeyCode]
					local stepDir = SEAT_STEP[input.KeyCode]
					if stepDir and mySeat ~= nil then
						-- крестовина: ближайшее свободное место по кругу в порядке панели
						local pos = table.find(SEAT_ORDER, mySeat) or 1
						for k = 1, #SEAT_ORDER - 1 do
							local cand = SEAT_ORDER[(pos - 1 + stepDir * k) % #SEAT_ORDER + 1]
							if buttons[cand].Visible and not seatTaken[cand] then
								index = cand
								break
							end
						end
					end
					if index ~= nil and index ~= mySeat and buttons[index] and buttons[index].Visible then
						Remotes.get("SwitchSeat"):FireServer(index)
					end
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Zero,
				Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight)
		else
			ContextActionService:UnbindAction("SeatKeys")
		end
	end

	RunService.Heartbeat:Connect(function()
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		local model = seat and seat.Parent
		if not seat or not model or model:GetAttribute("Vehicle") ~= true or seat:GetAttribute("SeatIndex") == nil then
			setActive(false)
			return
		end
		setActive(true)
		padHint.Visible = UserInputService.GamepadEnabled
		local mine = seat:GetAttribute("SeatIndex")
		mySeat = if typeof(mine) == "number" then mine else nil
		local present: { [number]: Seat | VehicleSeat } = {}
		for _, d in model:GetChildren() do
			local idx = d:GetAttribute("SeatIndex")
			if typeof(idx) == "number" and (d:IsA("Seat") or d:IsA("VehicleSeat")) then
				present[idx] = d
			end
		end
		for index, b in buttons do
			local s = present[index]
			b.Visible = s ~= nil
			seatTaken[index] = s ~= nil and s.Occupant ~= nil and index ~= mine
			if s then
				local taken = s.Occupant ~= nil
				b.BackgroundColor3 = if index == mine then Color3.fromRGB(255, 170, 40) elseif taken then Color3.fromRGB(120, 45, 45) else Color3.fromRGB(40, 44, 52)
				b.TextColor3 = if index == mine then Color3.new(0, 0, 0) else Color3.new(1, 1, 1)
				b.BackgroundTransparency = if taken and index ~= mine then 0.35 else 0.1
			end
		end
	end)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local stepParams = RaycastParams.new()
stepParams.FilterType = Enum.RaycastFilterType.Exclude
stepParams.RespectCanCollide = true

-- Заезд на низкую ступеньку: лучи вниз у переднего края корпуса (посередине и по углам), плоский верх чуть выше дна — приподнимаем машину
local function climbStep(root: BasePart, model: Instance, character: Instance, dir: Vector3, speed: number, dt: number)
	local maxStep = Config.Vehicle.stepUp
	local bottom = root.Position.Y - root.Size.Y / 2
	local front = root.Position + dir * (root.Size.Z / 2 + math.max(0.8, math.abs(speed) * dt * 3))
	local side = root.CFrame.RightVector * (root.Size.X * 0.42)
	stepParams.FilterDescendantsInstances = { model, character }
	local step = 0
	for _, offset in { Vector3.zero, side, -side } do
		local from = Vector3.new(front.X + offset.X, bottom + maxStep + 0.1, front.Z + offset.Z)
		local hit = workspace:Raycast(from, Vector3.new(0, -(maxStep + 0.3), 0), stepParams)
		if hit and hit.Instance ~= workspace.Terrain and hit.Instance.Anchored and hit.Instance.CollisionGroup ~= "Curb" and hit.Normal.Y > 0.99 then
			step = math.max(step, hit.Position.Y - bottom)
		end
	end
	if step > 0.03 and step <= maxStep then
		root.CFrame += Vector3.new(0, step + 0.02, 0)
	end
end

function VehicleController.start()
	local player = Players.LocalPlayer
	startSeatPanel(player)
	-- Обзор: от первого лица кузов и пулемёт закрывают дорогу, а руки торчат из-под руля. На местах 1–4 камера идёт от третьего лица за машиной
	-- (колесо мыши меняет дальность); место стрелка (0) наводит ствол само. На выходе возвращаются прежние режим и зум.
	local savedCam: { mode: Enum.CameraMode, minZoom: number, maxZoom: number }? = nil
	RunService.Heartbeat:Connect(function()
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		local model = seat and seat.Parent
		local index = seat and seat:GetAttribute("SeatIndex")
		local inCar = model ~= nil and model:GetAttribute("Vehicle") == true and typeof(index) == "number" and index >= 1
		if inCar and not savedCam then
			savedCam = { mode = player.CameraMode, minZoom = player.CameraMinZoomDistance, maxZoom = player.CameraMaxZoomDistance }
			local root = (model :: Model).PrimaryPart
			local length = if root then root.Size.Z else 17
			player.CameraMode = Enum.CameraMode.Classic
			player.CameraMinZoomDistance = length * 1.5 -- сначала фиксируем дальность, затем разрешаем колесо
			player.CameraMaxZoomDistance = length * 1.5
			task.delay(0.15, function()
				if savedCam then
					player.CameraMinZoomDistance = length * 0.9
					player.CameraMaxZoomDistance = length * 3
				end
			end)
		elseif not inCar and savedCam then
			local s = savedCam
			savedCam = nil
			player.CameraMinZoomDistance = s.minZoom
			player.CameraMaxZoomDistance = s.maxZoom
			player.CameraMode = s.mode
		end
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		if not seat or not seat:IsA("VehicleSeat") or seat.Name ~= "DriverSeat" then
			return
		end
		local model = seat.Parent
		local root = model and (model :: Model).PrimaryPart
		if not root or not model or model:GetAttribute("Wrecked") == true then
			return
		end
		local T = tuneOf(model)
		-- сильно побитая машина едет медленнее (Config.VehicleRam.limpFrac / limpSpeed)
		local hp, maxHp = model:GetAttribute("Hp"), model:GetAttribute("MaxHp")
		local speedMul = 1
		if typeof(hp) == "number" and typeof(maxHp) == "number" and maxHp > 0 and hp / maxHp < Config.VehicleRam.limpFrac then
			speedMul = Config.VehicleRam.limpSpeed
		end
		-- что под машиной: на бордюре/тротуаре едем медленнее, по траве чуть медленнее
		groundParams.FilterDescendantsInstances = { model, character }
		local below = workspace:Raycast(root.Position, Vector3.new(0, -(root.Size.Y / 2 + 6), 0), groundParams)
		if below then
			if below.Instance.CollisionGroup == "Curb" then
				speedMul *= Config.Vehicle.curbSlow
			elseif below.Material == Enum.Material.Grass or below.Material == Enum.Material.Ground or below.Material == Enum.Material.Mud then
				speedMul *= Config.Vehicle.offroadSlow
			end
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
			target = math.min(T.maxSpeed, Config.Vehicle.speedCap) * speedMul * throttle
			rate = if speed < -1 then T.brake else T.accel
		elseif throttle < -0.05 then
			target = -math.min(T.reverseSpeed, Config.Vehicle.speedCap)
			rate = if speed > 1 then T.brake else T.accel
		end
		speed = approach(speed, target, rate * dt)
		local planar = fwd * speed
		root.AssemblyLinearVelocity = Vector3.new(planar.X, v.Y, planar.Z)
		if math.abs(throttle) > 0.05 then
			climbStep(root, model, character :: Model, if throttle > 0 then fwd else -fwd, speed, dt)
		end
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
