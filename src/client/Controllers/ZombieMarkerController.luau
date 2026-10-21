--!strict
-- Метки на последних зомби: когда в ночь осталось не больше MARK_AT мутантов, их видно сквозь стены (красный контур и стрелка с
-- расстоянием), чтобы команда могла найти тех, кто застрял или потерялся. Только отображение: счёт зомби считает сервер (ZombiesLeft).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ZombieMarkerController = {}

local MARK_AT = 10
local MARK_COLOR = Color3.fromRGB(255, 70, 50)

local function addMarker(model: Model)
	if model:FindFirstChild("FindMarker") then
		return
	end
	local hl = Instance.new("Highlight")
	hl.Name = "FindMarker"
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 1
	hl.OutlineColor = MARK_COLOR
	hl.OutlineTransparency = 0.1
	hl.Adornee = model
	hl.Parent = model
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart? or model.PrimaryPart
	if not root then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "FindMarkerArrow"
	gui.Adornee = root
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(64, 44)
	gui.StudsOffset = Vector3.new(0, 5.5, 0)
	gui.MaxDistance = 2000
	gui.LightInfluence = 0
	gui.Parent = model
	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.Size = UDim2.new(1, 0, 0.5, 0)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.GothamBold
	arrow.TextScaled = true
	arrow.TextColor3 = MARK_COLOR
	arrow.TextStrokeTransparency = 0.3
	arrow.Text = "▼"
	arrow.Parent = gui
	local dist = Instance.new("TextLabel")
	dist.Name = "Dist"
	dist.Position = UDim2.fromScale(0, 0.5)
	dist.Size = UDim2.new(1, 0, 0.5, 0)
	dist.BackgroundTransparency = 1
	dist.Font = Enum.Font.GothamBold
	dist.TextScaled = true
	dist.TextColor3 = Color3.new(1, 1, 1)
	dist.TextStrokeTransparency = 0.3
	dist.Parent = gui
end

local function clearMarkers(model: Instance)
	local hl = model:FindFirstChild("FindMarker")
	if hl then
		hl:Destroy()
	end
	local gui = model:FindFirstChild("FindMarkerArrow")
	if gui then
		gui:Destroy()
	end
end

function ZombieMarkerController.start()
	local player = Players.LocalPlayer
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.3 then
			return
		end
		acc = 0
		local folder = workspace:FindFirstChild("Zombies")
		if not folder then
			return
		end
		local left = (ReplicatedStorage:GetAttribute("ZombiesLeft") :: number?) or 99
		local show = ReplicatedStorage:GetAttribute("Phase") == "Night" and left > 0 and left <= MARK_AT
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		for _, m in folder:GetChildren() do
			if m:IsA("Model") then
				if show then
					addMarker(m)
					local gui = m:FindFirstChild("FindMarkerArrow")
					local label = gui and gui:FindFirstChild("Dist") :: TextLabel?
					local zr = m:FindFirstChild("HumanoidRootPart") :: BasePart? or m.PrimaryPart
					if label and root and zr then
						label.Text = string.format("%d м", math.floor((zr.Position - root.Position).Magnitude + 0.5))
					end
				else
					clearMarkers(m)
				end
			end
		end
	end)
end

return ZombieMarkerController
