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

-- Подкат и кувырок ------------------------------------------------------------------------------------
-- Движение делаем у себя (LinearVelocity на корне), сервер проверяет энергию/паузу и даёт неуязвимость кувырку.
-- Подкат: корпус опускается (HipHeight, голова и верх торса не сталкиваются) — можно пролезть под баррикадой
-- с выбитыми нижними досками. Кувырок: камера делает сальто вперёд.
local P = Config.Player
local dodging = false
local lastDodge = 0
local flipStart = 0
local flipDuration = 0

local function aliveHumanoid(): (Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hum and root and hum.Health > 0 then
		return hum, root
	end
	return nil, nil
end

-- Куда рвануть: куда идёт игрок, а если стоит — куда смотрит камера
local function dodgeDirection(hum: Humanoid): Vector3
	if hum.MoveDirection.Magnitude > 0.1 then
		return hum.MoveDirection.Unit
	end
	local look = (workspace.CurrentCamera :: Camera).CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
end

local function burst(root: BasePart, dir: Vector3, speed: number, seconds: number, hum: Humanoid)
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(1e5, 0, 1e5) -- по вертикали свободно: гравитация и спуски работают
	lv.VectorVelocity = dir * speed
	lv.Parent = root
	local started = os.clock()
	while true do
		local t = (os.clock() - started) / seconds
		if t >= 1 or hum.Health <= 0 or not root.Parent then
			break
		end
		local v = speed * (1 - 0.55 * t) -- к концу рывок затухает
		lv.VectorVelocity = dir * v
		RunService.Heartbeat:Wait()
	end
	lv:Destroy()
	attachment:Destroy()
end

local function doSlide()
	local hum, root = aliveHumanoid()
	if not hum or not root then
		dodging = false
		return
	end
	local char = hum.Parent :: Model
	local head = char:FindFirstChild("Head") :: BasePart?
	local upper = char:FindFirstChild("UpperTorso") :: BasePart?
	local hip, jumpHeight, jumpPower = hum.HipHeight, hum.JumpHeight, hum.JumpPower
	hum.HipHeight = 0.2
	hum.JumpHeight = 0
	hum.JumpPower = 0
	if head then
		head.CanCollide = false
	end
	if upper then
		upper.CanCollide = false
	end
	burst(root, dodgeDirection(hum), P.SlideSpeed, P.SlideSeconds, hum)
	hum.HipHeight = hip
	hum.JumpHeight = jumpHeight
	hum.JumpPower = jumpPower
	if head then
		head.CanCollide = true
	end
	if upper then
		upper.CanCollide = true
	end
	dodging = false
end

local function doRoll()
	local hum, root = aliveHumanoid()
	if not hum or not root then
		dodging = false
		return
	end
	flipStart = os.clock()
	flipDuration = P.RollSeconds
	burst(root, dodgeDirection(hum), P.RollSpeed, P.RollSeconds, hum)
	dodging = false
end

local function tryDodge()
	local hum = aliveHumanoid()
	if dodging or not hum or player:GetAttribute("Downed") == true then
		return
	end
	if os.clock() - lastDodge < P.DodgeCooldown then
		return
	end
	local energy = (player:GetAttribute("Energy") :: number?) or 0
	local slide = player:GetAttribute("Sprinting") == true
	if energy < (if slide then P.SlideEnergy else P.RollEnergy) then
		return
	end
	dodging = true
	lastDodge = os.clock()
	Remotes.get("Dodge"):FireServer(if slide then "slide" else "roll")
	task.spawn(if slide then doSlide else doRoll)
end

-- Публичный вызов (кнопка на телефоне, тесты): подкат в спринте, иначе кувырок
MovementController.dodge = tryDodge

function MovementController.start()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	ContextActionService:BindAction("NotdDodge", function(_, state)
		if state == Enum.UserInputState.Begin then
			tryDodge()
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.C, Enum.KeyCode.ButtonB)
	ContextActionService:SetTitle("NotdDodge", "Кувырок")

	-- сальто камеры при кувырке (после обновления стандартной камеры)
	RunService:BindToRenderStep("NotdRollCam", Enum.RenderPriority.Camera.Value + 3, function()
		local camera = workspace.CurrentCamera
		local t = if flipDuration > 0 then (os.clock() - flipStart) / flipDuration else 1
		if camera and t >= 0 and t < 1 then
			local eased = t * t * (3 - 2 * t)
			camera.CFrame = camera.CFrame * CFrame.Angles(-math.pi * 2 * eased, 0, 0)
		end
	end)

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
