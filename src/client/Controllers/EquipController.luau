--!strict
-- Оборудование в руках (турель, проволока): та же кнопка, что огонь оружия (левая кнопка мыши, ButtonR2 на геймпаде,
-- касание экрана на телефоне через Tool.Activated), ставит его на землю в точке прицела в центре экрана. Всё остальное решает сервер.
-- Превью: пока оборудование в руках, на месте установки показан полупрозрачный макет (зелёный — можно, красный — нельзя: далеко, нет земли,
-- на крыше над головой). Поворот по взгляду игрока; R — довернуть на 45° (Shift+R — в обратную сторону). Колёсико мыши не берём: оно у камеры.
-- Клиент присылает точку и угол (yaw), сервер перепроверяет всё сам (EquipmentService.onPlace).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local EquipController = {}

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local GREEN = Color3.fromRGB(80, 230, 110)
local RED = Color3.fromRGB(240, 70, 60)
local TURN = math.rad(45) -- шаг поворота по R

function EquipController.start()
	local player = Players.LocalPlayer
	local lastPlace = 0
	local turn = 0 -- поворот от взгляда, радианы (R)

	-- макет установки: одна полупрозрачная деталь по габаритам предмета (Config.Equipment), создаётся при первом показе
	local preview = Instance.new("Part")
	preview.Name = "EquipPreview"
	preview.Anchored = true
	preview.CanCollide = false
	preview.CanQuery = false
	preview.CanTouch = false
	preview.CastShadow = false
	preview.Material = Enum.Material.ForceField
	preview.Transparency = 0.45
	local previewKind = ""
	local hint = Instance.new("ScreenGui")
	hint.Name = "EquipHint"
	hint.ResetOnSpawn = false
	hint.Enabled = false
	local hintLabel = Instance.new("TextLabel")
	hintLabel.AnchorPoint = Vector2.new(0.5, 1)
	hintLabel.Position = UDim2.new(0.5, 0, 1, -120)
	hintLabel.Size = UDim2.fromOffset(360, 24)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Font = Enum.Font.GothamMedium
	hintLabel.TextSize = 15
	hintLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	hintLabel.TextStrokeTransparency = 0.5
	hintLabel.Text = "ЛКМ — поставить · R — повернуть"
	hintLabel.Parent = hint
	hint.Parent = player:WaitForChild("PlayerGui")

	local function heldTool(): Tool?
		local char = player.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		if tool and tool:GetAttribute("EquipKind") ~= nil then
			return tool
		end
		return nil
	end

	-- куда целимся: точка на земле, угол, годится ли место (те же условия, что у сервера, чуть строже по дальности)
	local function aim(tool: Tool): (Vector3?, number, boolean)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local cam = workspace.CurrentCamera
		local kind = tool:GetAttribute("EquipKind")
		local def = if typeof(kind) == "string" then (Config.Equipment :: any)[kind] else nil
		if not char or not root or not cam or not def then
			return nil, 0, false
		end
		local size = cam.ViewportSize
		local ray = cam:ViewportPointToRay(size.X / 2, size.Y / 2)
		params.FilterDescendantsInstances = { char :: Instance, preview }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 60, params)
		local look = cam.CFrame.LookVector
		local yaw = math.atan2(-look.X, -look.Z) + turn
		if not hit then
			return nil, yaw, false
		end
		local flat = (Vector3.new(hit.Position.X, root.Position.Y, hit.Position.Z) - root.Position).Magnitude
		local ok = flat <= def.reach and math.abs(hit.Position.Y - root.Position.Y) <= 8 and hit.Normal.Y > 0.5
		return hit.Position, yaw, ok
	end

	local function refreshPreview()
		local tool = heldTool()
		if not tool then
			preview.Parent = nil
			hint.Enabled = false
			return
		end
		local kind = tool:GetAttribute("EquipKind") :: string
		local def = (Config.Equipment :: any)[kind]
		if previewKind ~= kind then
			previewKind = kind
			preview.Size = if kind == "Turret" then Vector3.new(2.2, 1.8, def.length) else def.size
		end
		local pos, yaw, ok = aim(tool)
		if not pos then
			preview.Parent = nil
			hint.Enabled = true
			return
		end
		preview.Color = if ok then GREEN else RED
		preview.CFrame = CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, preview.Size.Y / 2, 0)
		preview.Parent = workspace
		hint.Enabled = true
		hintLabel.TextColor3 = if ok then Color3.fromRGB(235, 235, 235) else Color3.fromRGB(255, 130, 120)
		hintLabel.Text = if ok then "ЛКМ — поставить · R — повернуть" else "Здесь поставить нельзя (далеко или нет земли) · R — повернуть"
	end
	RunService.Heartbeat:Connect(refreshPreview) -- не RenderStepped: макету достаточно кадра запаздывания

	local function place()
		local char = player.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		if not char or not tool or tool:GetAttribute("EquipKind") == nil then
			return
		end
		-- на сенсорном ноутбуке одно нажатие даёт и клик, и Activated: ставим один раз
		local now = os.clock()
		if now - lastPlace < 0.3 then
			return
		end
		lastPlace = now
		local pos, yaw, ok = aim(tool)
		if pos and ok then
			Remotes.get("PlaceEquipment"):FireServer(pos, yaw)
		end
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			place()
		end
	end)
	-- R: довернуть макет. WeaponController забирает R под перезарядку (Sink), поэтому берём её с высоким приоритетом и только пока в руках оборудование
	ContextActionService:BindActionAtPriority("EquipTurn", function(_, state)
		if not heldTool() then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			local back = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			turn = (turn + (if back then -TURN else TURN)) % (math.pi * 2)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.R)

	-- телефон: касание экрана активирует Tool (как выстрел оружия в WeaponController); подключаемся к Tool один раз
	local hooked: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function hookTool(tool: Instance)
		if tool:IsA("Tool") and tool:GetAttribute("EquipKind") ~= nil and not hooked[tool] then
			hooked[tool] = true
			tool.Activated:Connect(function()
				if UserInputService.TouchEnabled then
					place()
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
end

return EquipController
