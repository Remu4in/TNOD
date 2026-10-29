--!strict
-- Пулемёт машины (место стрелка 0): ствол наводится по камере. Огонь — та же кнопка, что у оружия: зажатая левая кнопка мыши,
-- ButtonR2 на геймпаде, экранная кнопка «Огонь» на телефоне. Перезарядка — R, ButtonX или экранная кнопка «R».
-- Действия ContextActionService привязаны, только пока игрок за пулемётом (высокий приоритет: R и ButtonX не уходят оружию).
-- Патроны и урон считает сервер (VehicleService); здесь только ввод и подсказка с патронами.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local TurretController = {}

function TurretController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "TurretHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(1, 1)
	label.Position = UDim2.new(1, -24, 1, -90)
	label.Size = UDim2.fromOffset(300, 64)
	label.BackgroundColor3 = Color3.fromRGB(22, 24, 29)
	label.BackgroundTransparency = 0.2
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(255, 200, 80)
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label

	local firing = false
	local current: Model? = nil

	-- я за пулемётом? (сижу на месте 0 машины, у которой есть пулемёт)
	local function gunnerModel(): Model?
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		local model = seat and seat.Parent
		if seat and model and model:GetAttribute("Vehicle") == true and seat:GetAttribute("SeatIndex") == 0 and model:GetAttribute("TurretReady") == true then
			return model :: Model
		end
		return nil
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.UserInputType == Enum.UserInputType.MouseButton1 and current then
			firing = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			firing = false
		end
	end)

	-- геймпад и телефон: кнопки появляются, только пока игрок за пулемётом
	local bound = false
	local function setBound(on: boolean)
		if on == bound then
			return
		end
		bound = on
		-- экранная кнопка перезарядки оружия за пулемётом не работает (оружие убрано): прячем её, чтобы не путать с «R» пулемёта
		local weaponReload = ContextActionService:GetButton("Reload")
		if weaponReload then
			weaponReload.Visible = not on
		end
		if on then
			ContextActionService:BindActionAtPriority("TurretFire", function(_, state)
				if state == Enum.UserInputState.Begin then
					firing = true
				elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
					firing = false
				end
				return Enum.ContextActionResult.Sink
			end, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonR2)
			ContextActionService:SetTitle("TurretFire", "Fire")
			ContextActionService:BindActionAtPriority("TurretReload", function(_, state)
				if state == Enum.UserInputState.Begin then
					Remotes.get("TurretReload"):FireServer()
				end
				return Enum.ContextActionResult.Sink
			end, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
			ContextActionService:SetTitle("TurretReload", "R")
		else
			ContextActionService:UnbindAction("TurretFire")
			ContextActionService:UnbindAction("TurretReload")
		end
	end

	-- подсказка под тем устройством, с которого игрок сейчас играет
	local function controlsHint(): string
		local last = UserInputService:GetLastInputType()
		if last == Enum.UserInputType.Touch then
			return "on-screen «Fire» and «R» buttons"
		elseif string.find(last.Name, "Gamepad") then
			return "R2 — fire, X — reload"
		end
		return "LMB — fire, R — reload"
	end

	local lastAim, lastFire = 0, 0
	RunService.Heartbeat:Connect(function()
		current = gunnerModel()
		gui.Enabled = current ~= nil
		setBound(current ~= nil)
		if not current then
			firing = false
			return
		end
		local mag = current:GetAttribute("TurretMag")
		local reserve = current:GetAttribute("TurretReserve")
		if current:GetAttribute("TurretReloading") == true then
			label.Text = "RELOADING…"
		else
			label.Text = string.format("MACHINE GUN  %s / %s\n%s", tostring(mag), tostring(reserve), controlsHint())
		end
		local cam = workspace.CurrentCamera
		local now = os.clock()
		if cam and now - lastAim >= 0.05 then
			lastAim = now
			Remotes.get("TurretAim"):FireServer(cam.CFrame.LookVector)
		end
		if firing and now - lastFire >= 1 / Config.TurretGun.rate then
			lastFire = now
			Remotes.get("TurretFire"):FireServer()
		end
	end)
end

return TurretController
