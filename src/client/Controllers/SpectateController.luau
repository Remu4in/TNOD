--!strict
-- Наблюдатель после смерти: пока игрок мёртв (до следующего дня), он свободно летает камерой. Только камера на клиенте, на игру это не влияет.
-- Мышь — обзор, WASD — полёт, E / Q — вверх / вниз, Shift — быстрее. Геймпад: стики, RB / LB — вверх / вниз. Телефон: тянуть по экрану — обзор.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local SpectateController = {}

local DELAY = 2.5 -- с после смерти: сначала видно падение тела
local SPEED, FAST = 45, 110
local LOOK_MOUSE = 0.0035
local LOOK_STICK = 2.4
local LOOK_TOUCH = 0.006
local STREAM_EVERY = 2 -- с: просим сервер загрузить карту вокруг камеры (стриминг)

function SpectateController.start()
	local player = Players.LocalPlayer
	local active = false
	local deadSince: number? = nil
	local yaw, pitch = 0, 0
	local stick = Vector2.zero
	local lookStick = Vector2.zero
	local touchLook = Vector2.zero
	local streamAcc = 0

	local gui = Instance.new("ScreenGui")
	gui.Name = "SpectateHUD"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 4
	gui.Parent = player:WaitForChild("PlayerGui")
	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -90)
	hint.Size = UDim2.fromOffset(620, 44)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextSize = 16
	hint.TextColor3 = Color3.new(1, 1, 1)
	hint.TextStrokeTransparency = 0.4
	hint.TextWrapped = true
	hint.Text = "YOU DIED — you'll be back at dawn\nSPECTATING: WASD fly · E / Q up / down · Shift faster"
	hint.Parent = gui

	local function setActive(on: boolean)
		if on == active then
			return
		end
		active = on
		gui.Enabled = on
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		if on then
			local x, y = cam.CFrame:ToOrientation()
			pitch, yaw = x, y
			cam.CameraType = Enum.CameraType.Scriptable
		else
			cam.CameraType = Enum.CameraType.Custom
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				cam.CameraSubject = hum
			end
		end
	end

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			stick = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			lookStick = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.UserInputType == Enum.UserInputType.Touch then
			touchLook += Vector2.new(input.Delta.X, input.Delta.Y)
		end
	end)

	RunService:BindToRenderStep("NotdSpectate", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local dead = not hum or hum.Health <= 0
		if dead then
			deadSince = deadSince or os.clock()
		else
			deadSince = nil
		end
		-- конец раунда: экран итогов, камеру и мышь не держим
		local phase = ReplicatedStorage:GetAttribute("Phase")
		setActive(deadSince ~= nil and os.clock() - (deadSince :: number) >= DELAY and (phase == "Night" or phase == "Day"))
		local cam = workspace.CurrentCamera
		if not active or not cam then
			return
		end
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		local mouse = UserInputService:GetMouseDelta()
		yaw -= mouse.X * LOOK_MOUSE + lookStick.X * LOOK_STICK * dt + touchLook.X * LOOK_TOUCH
		pitch -= mouse.Y * LOOK_MOUSE - lookStick.Y * LOOK_STICK * dt + touchLook.Y * LOOK_TOUCH
		touchLook = Vector2.zero
		pitch = math.clamp(pitch, math.rad(-85), math.rad(85))

		local function key(code: Enum.KeyCode): number
			return if UserInputService:IsKeyDown(code) then 1 else 0
		end
		local rot = CFrame.fromOrientation(pitch, yaw, 0)
		local right = key(Enum.KeyCode.D) - key(Enum.KeyCode.A) + (if math.abs(stick.X) > 0.15 then stick.X else 0)
		local forward = key(Enum.KeyCode.W) - key(Enum.KeyCode.S) + (if math.abs(stick.Y) > 0.15 then stick.Y else 0)
		local up = key(Enum.KeyCode.E) - key(Enum.KeyCode.Q) + key(Enum.KeyCode.ButtonR1) - key(Enum.KeyCode.ButtonL1)
		local move = rot.RightVector * right + rot.LookVector * forward + Vector3.yAxis * up
		local speed = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then FAST else SPEED
		cam.CFrame = CFrame.new(cam.CFrame.Position + (if move.Magnitude > 1 then move.Unit else move) * speed * dt) * rot

		streamAcc += dt
		if streamAcc >= STREAM_EVERY then
			streamAcc = 0
			local at = cam.CFrame.Position
			task.spawn(function()
				pcall(function()
					player:RequestStreamAroundAsync(at)
				end)
			end)
		end
	end)
end

return SpectateController
