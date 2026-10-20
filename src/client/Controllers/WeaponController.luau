--!strict
-- Стрельба на клиенте: прицел по камере, запрос на сервер, автоматический огонь при удержании.
-- Урон считает сервер; здесь только ввод и мгновенный визуальный отклик.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local WeaponSfx = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponSfx"))
local FxController = require(script.Parent:WaitForChild("FxController"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Ballistics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Ballistics"))

local WeaponController = {}

local player = Players.LocalPlayer
local firing = false
local lastShot = 0

-- Прицеливание и отдача
local aimHeld = false -- кнопка прицеливания зажата
local burst = 0 -- номер последнего выстрела в очереди (0 — первый)
local burstStartPitch: number? = nil -- наклон камеры в начале очереди: к нему частично возвращаемся после неё
local recoverTarget: number? = nil

local function equipped(): Tool?
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("WeaponId") then
		return tool
	end
	return nil
end

local function cameraPitch(): number
	local look = workspace.CurrentCamera.CFrame.LookVector
	return math.asin(math.clamp(look.Y, -1, 1))
end

-- Состояние для разброса: движение, прыжок, прицел, номер выстрела (nextShot — для следующего выстрела)
local function ballisticState(aim: Ballistics.Aim, rate: number, nextShot: boolean): Ballistics.State
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local vel = if root then root.AssemblyLinearVelocity else Vector3.zero
	local idle = os.clock() - lastShot > aim.resetTime + 1 / rate
	return {
		ads = player:GetAttribute("ADS") == true,
		speed = Vector3.new(vel.X, 0, vel.Z).Magnitude,
		airborne = hum ~= nil and hum.FloorMaterial == Enum.Material.Air,
		burst = if idle then 0 elseif nextShot then burst + 1 else burst,
	}
end

-- Отдача: поднять прицел и увести в сторону по закономерности очереди. Меняем сам взгляд камеры (не просто «тряску»):
-- игрок может компенсировать отдачу мышью, а следующий выстрел идёт туда, куда смотрит прицел.
local function applyRecoil(aim: Ballistics.Aim)
	local camera = workspace.CurrentCamera
	local pitchDeg, yawDeg = Ballistics.recoilStep(aim, burst)
	if player:GetAttribute("ADS") == true then
		pitchDeg *= 0.8
		yawDeg *= 0.6
	end
	local cf = camera.CFrame
	camera.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, math.rad(yawDeg), 0) * cf.Rotation * CFrame.Angles(math.rad(pitchDeg), 0, 0)
end

local function aimPoint(): Vector3
	local camera = workspace.CurrentCamera
	-- вид от 1 лица: всегда стреляем в центр экрана (прицел)
	local pos = camera.ViewportSize / 2
	local ray = camera:ViewportPointToRay(pos.X, pos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	return if result then result.Position else ray.Origin + ray.Direction * 500
end

local lastSwing = 0

-- Ближний бой: звук и анимация взмаха сразу, урон считает сервер по направлению взгляда
local function tryMelee(tool: Tool)
	local rate = (tool:GetAttribute("FireRate") :: number?) or 2
	local now = os.clock()
	if now - lastSwing < 1 / rate then
		return
	end
	lastSwing = now
	WeaponSfx.swing(nil)
	FxController.onLocalSwing(tool, tostring(tool:GetAttribute("WeaponId")))
	-- стандартный скрипт Animate персонажа проигрывает взмах, когда в инструменте появляется StringValue "toolanim"
	local anim = Instance.new("StringValue")
	anim.Name = "toolanim"
	anim.Value = "Slash"
	anim.Parent = tool
	Debris:AddItem(anim, 0.5)
	local camera = workspace.CurrentCamera
	Remotes.get("Melee"):FireServer(camera.CFrame.LookVector)
end

local function tryShoot()
	local tool = equipped()
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not tool or not head or player:GetAttribute("Downed") then
		return
	end
	if tool:GetAttribute("Melee") == true then
		tryMelee(tool)
		return
	end
	local rate = (tool:GetAttribute("FireRate") :: number?) or 4
	local now = os.clock()
	if now - lastShot < 1 / rate then
		return
	end
	if ((tool:GetAttribute("Mag") :: number?) or 0) <= 0 then
		WeaponSfx.click()
		Remotes.get("Reload"):FireServer()
		return
	end
	local weaponId = tool:GetAttribute("WeaponId")
	local aim = if typeof(weaponId) == "string" then Config.WeaponAim[weaponId] else nil
	-- номер выстрела в очереди (после паузы очередь начинается заново)
	local idle = not aim or now - lastShot > aim.resetTime + 1 / rate
	if idle then
		burst = 0
		burstStartPitch = cameraPitch()
		recoverTarget = nil
	else
		burst += 1
	end
	lastShot = now
	if typeof(weaponId) == "string" then
		WeaponSfx.fire(weaponId, nil)
		FxController.onLocalShot(tool, weaponId)
	end
	local origin = head.Position
	local dir = (aimPoint() - origin).Unit
	Remotes.get("Fire"):FireServer(origin, dir, player:GetAttribute("ADS") == true)
	-- отдача применяется после выстрела: пуля ушла туда, куда смотрел прицел в момент нажатия
	if aim then
		applyRecoil(aim)
	end
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
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			aimHeld = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			firing = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			aimHeld = false
		end
	end)

	-- каждый кадр: включён ли прицел, текущий разброс для прицела-перекрестия, возврат взгляда после очереди
	RunService:BindToRenderStep("NotdAim", Enum.RenderPriority.Camera.Value + 4, function(dt: number)
		local camera = workspace.CurrentCamera
		local tool = equipped()
		local weaponId = if tool then tool:GetAttribute("WeaponId") else nil
		local aim = if typeof(weaponId) == "string" then Config.WeaponAim[weaponId] else nil
		local firearm = tool ~= nil and tool:GetAttribute("Melee") ~= true and aim ~= nil
		-- целиться нельзя на бегу, лёжа/упавшим и без огнестрела
		local ads = aimHeld and firearm and player:GetAttribute("Sprinting") ~= true and player:GetAttribute("Downed") ~= true
		if player:GetAttribute("ADS") ~= (ads == true) then
			player:SetAttribute("ADS", ads == true)
		end
		local fov = if ads and aim then aim.adsFov else 0
		if player:GetAttribute("AdsFov") ~= fov then
			player:SetAttribute("AdsFov", fov)
		end
		UserInputService.MouseDeltaSensitivity = if ads and aim then math.clamp(aim.adsFov / 70, 0.3, 1) else 1

		local spread = 0
		if firearm and aim and typeof(weaponId) == "string" then
			local def = Config.Weapons[weaponId]
			local rate = ((tool :: Tool):GetAttribute("FireRate") :: number?) or 4
			spread = Ballistics.spreadDeg(def.spreadDeg, aim, ballisticState(aim, rate, true), Config.Player.WalkSpeed)
		end
		if math.abs(((player:GetAttribute("AimSpread") :: number?) or 0) - spread) > 0.02 then
			player:SetAttribute("AimSpread", spread)
		end

		-- после очереди прицел частично возвращается вниз: к 40% набранного подъёма
		if aim and burstStartPitch and os.clock() - lastShot > aim.resetTime * 0.7 then
			local now = cameraPitch()
			if not recoverTarget then
				recoverTarget = burstStartPitch + math.max(now - burstStartPitch, 0) * 0.4
			end
			local target = recoverTarget :: number
			if now > target + 1e-3 then
				local step = (now - target) * math.min(1, dt * 6)
				camera.CFrame = camera.CFrame * CFrame.Angles(-step, 0, 0)
			else
				burstStartPitch = nil
				recoverTarget = nil
			end
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
			FxController.cancelInspect(true) -- R прерывает осмотр оружия (F снова запускает)
			Remotes.get("Reload"):FireServer()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
	ContextActionService:SetTitle("Reload", "R")

	-- F — осмотр холодного оружия (нож, катана, керамбит, бабочка); Pass: та же клавиша «Разобрать» у баррикады продолжает работать
	ContextActionService:BindAction("InspectWeapon", function(_, state)
		if state == Enum.UserInputState.Begin then
			FxController.inspect()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.F)

	-- G — выбросить оружие из рук (подобрать можно на E)
	ContextActionService:BindAction("DropWeapon", function(_, state)
		if state == Enum.UserInputState.Begin and equipped() then
			Remotes.get("DropWeapon"):FireServer()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.G)

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
