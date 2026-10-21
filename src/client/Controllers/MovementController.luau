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
local Perks = require(Shared:WaitForChild("Perks"))

local MovementController = {}

local player = Players.LocalPlayer
local BASE_FOV, SPRINT_FOV, SLIDE_FOV = 70, 78, 90
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
local flipBase: CFrame? = nil -- направление взгляда до кувырка: в конце камера возвращается ровно в него
local sliding = false

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
	sliding = true
	hum.HipHeight = 0.2
	hum.CameraOffset = Vector3.new(0, -1.2, 0)
	hum.JumpHeight = 0
	hum.JumpPower = 0
	if head then
		head.CanCollide = false
	end
	if upper then
		upper.CanCollide = false
	end
	burst(root, dodgeDirection(hum), P.SlideSpeed, P.SlideSeconds, hum)
	sliding = false
	hum.CameraOffset = Vector3.zero
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
	local camera = workspace.CurrentCamera
	flipBase = if camera then camera.CFrame.Rotation else nil
	burst(root, dodgeDirection(hum), P.RollSpeed, P.RollSeconds, hum)
	dodging = false
end

-- Отказ показываем в подсказке внизу экрана (HUDController слушает атрибут DodgeDenied), чтобы кнопка не «молчала»
local function deny(reason: string)
	player:SetAttribute("DodgeDenied", reason .. "|" .. tostring(os.clock()))
end

local function tryDodge(want: string?)
	local hum, root = aliveHumanoid()
	if dodging or not hum or not root or player:GetAttribute("Downed") == true then
		return
	end
	if os.clock() - lastDodge < P.DodgeCooldown then
		deny("Рано: пауза между подкатом и кувырком")
		return
	end
	local energy = (player:GetAttribute("Energy") :: number?) or 0
	-- подкат — только на бегу (атрибут Sprinting приходит с сервера с задержкой, поэтому смотрим и на скорость)
	local flatSpeed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	local running = player:GetAttribute("Sprinting") == true or flatSpeed > P.SprintSpeed - 3
	-- want: "slide" (Q) | "roll" (C) | nil (кнопка телефона и автотесты: на бегу подкат, иначе кувырок)
	local slide = if want == "slide" then true elseif want == "roll" then false else running
	if slide and not running then
		deny("Подкат — только на бегу")
		return
	end
	local need = if slide then P.SlideEnergy else P.RollEnergy
	if energy < need then
		deny(string.format("Не хватает энергии (нужно %d)", need))
		return
	end
	dodging = true
	lastDodge = os.clock()
	Remotes.get("Dodge"):FireServer(if slide then "slide" else "roll")
	task.spawn(if slide then doSlide else doRoll)
end

-- Публичный вызов (кнопка на телефоне, тесты): подкат в спринте, иначе кувырок
MovementController.dodge = function()
	tryDodge(nil)
end

function MovementController.start()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	-- Q — подкат (только на бегу), C — кувырок
	ContextActionService:BindAction("NotdDodge", function(_, state)
		if state == Enum.UserInputState.Begin then
			player:SetAttribute("DodgeKeyPresses", ((player:GetAttribute("DodgeKeyPresses") :: number?) or 0) + 1) -- диагностика: дошла ли клавиша
			tryDodge(nil)
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.ButtonB)
	ContextActionService:SetTitle("NotdDodge", "Кувырок")
	ContextActionService:BindAction("NotdSlide", function(_, state)
		if state == Enum.UserInputState.Begin then
			tryDodge("slide")
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Q)
	ContextActionService:BindAction("NotdRoll", function(_, state)
		if state == Enum.UserInputState.Begin then
			tryDodge("roll")
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.C)
	-- то же через атрибут игрока RequestDodge (кнопки интерфейса и автотесты: Studio не эмулирует клавиши в игре)
	player:GetAttributeChangedSignal("RequestDodge"):Connect(function()
		tryDodge(nil)
	end)

	-- Спиной вперёд идём медленнее (P.BackwardSpeedFactor): скорость пересчитывается каждый кадр от базовой (ходьба/спринт),
	-- подкат, кувырок, падение и сиденье в машине не трогаем. Сервер пишет базовую скорость сам — мы переписываем её только когда
	-- она равна базовой или нашему прошлому значению.
	local lastWritten = 0
	RunService.Heartbeat:Connect(function()
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local camera = workspace.CurrentCamera
		if not hum or not camera or hum.Health <= 0 or hum.SeatPart then
			return
		end
		if player:GetAttribute("Downed") == true or player:GetAttribute("Dodge") ~= nil then
			return
		end
		local base = if player:GetAttribute("Sprinting") == true then Perks.sprintSpeed() else Perks.walkSpeed()
		local factor = 1
		local move = hum.MoveDirection
		if move.Magnitude > 0.1 then
			local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
			if look.Magnitude > 0.01 then
				local dot = move.Unit:Dot(look.Unit)
				if dot < -0.3 then
					local t = math.clamp((-dot - 0.3) / 0.7, 0, 1)
					factor = 1 - (1 - P.BackwardSpeedFactor) * t
				end
			end
		end
		local want = base * factor
		local cur = hum.WalkSpeed
		if math.abs(cur - want) > 0.01 and (math.abs(cur - base) < 0.01 or math.abs(cur - lastWritten) < 0.01) then
			hum.WalkSpeed = want
			lastWritten = want
		end
	end)

	-- сальто камеры при кувырке. Стандартная камера берёт за основу CFrame прошлого кадра, поэтому прибавлять
	-- поворот к её кадру нельзя (наклон копился, камера уезжала вверх). На 0,5 с камеру целиком задаём сами:
	-- направление взгляда до кувырка + сальто, а в последнем кадре возвращаем ровно исходное направление.
	RunService:BindToRenderStep("NotdRollCam", Enum.RenderPriority.Camera.Value + 3, function()
		local camera = workspace.CurrentCamera
		local base = flipBase
		if not camera or not base then
			return
		end
		local t = if flipDuration > 0 then (os.clock() - flipStart) / flipDuration else 1
		local position = camera.CFrame.Position
		if t >= 0 and t < 1 then
			local eased = t * t * (3 - 2 * t)
			camera.CFrame = CFrame.new(position) * base * CFrame.Angles(-math.pi * 2 * eased, 0, 0)
		else
			camera.CFrame = CFrame.new(position) * base
			flipBase = nil
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
		local adsFov = (player:GetAttribute("AdsFov") :: number?) or 0
		local target = if adsFov > 0 then adsFov elseif sliding then SLIDE_FOV elseif player:GetAttribute("Sprinting") == true then SPRINT_FOV else BASE_FOV
		camera.FieldOfView += (target - camera.FieldOfView) * math.min(1, dt * 8)
	end)
end

return MovementController
