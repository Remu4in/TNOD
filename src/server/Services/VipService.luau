--!strict
-- Вид VIP-игрока (Config.VipLook): золотая аура — всегда, в лобби и в матче (контур с подсветкой силуэта, искры, свечение); надпись VIP — только в лобби
-- (в матче над головами и так метки команды). VIP — атрибут игрока Has_vip (ставит DonateService по профилю); снят — аура и надпись убираются.
-- Всё создаёт сервер внутри персонажа, поэтому видно всем игрокам.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local VipService = {}

local L = Config.VipLook
local AURA = "VipAura"
local LABEL = "VipLabel"

local function isLobby(): boolean
	return ReplicatedStorage:GetAttribute("Mode") == "lobby"
end

local function clear(char: Model)
	for _, d in char:GetDescendants() do
		if d.Name == AURA or d.Name == LABEL then
			d:Destroy()
		end
	end
end

local function addAura(char: Model, root: BasePart)
	-- контур и лёгкая подсветка силуэта: видно в толпе и издалека (у себя от первого лица тело скрыто — контура не видно)
	local hl = Instance.new("Highlight")
	hl.Name = AURA
	hl.Adornee = char
	hl.FillColor = L.Color
	hl.FillTransparency = L.FillTransparency
	hl.OutlineColor = L.Color
	hl.OutlineTransparency = L.OutlineTransparency
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = char
	local att = Instance.new("Attachment")
	att.Name = AURA
	att.Parent = root
	-- искры с поверхности корпуса разлетаются медленно и гаснут за ~1 с: тонкий ореол вокруг тела
	local p = Instance.new("ParticleEmitter")
	p.Name = AURA
	p.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	p.Color = ColorSequence.new(L.Color)
	p.LightEmission = 1
	p.LightInfluence = 0
	p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0) })
	p.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.6) })
	p.Lifetime = NumberRange.new(L.AuraLifetime * 0.7, L.AuraLifetime)
	p.Rate = L.AuraRate
	p.Speed = NumberRange.new(L.AuraSpeed * 0.6, L.AuraSpeed)
	p.SpreadAngle = Vector2.new(180, 180)
	p.Acceleration = Vector3.new(0, 0.8, 0) -- чуть поднимаются
	p.Shape = Enum.ParticleEmitterShape.Box
	p.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	p.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	p.Parent = root -- излучает весь корпус (HumanoidRootPart 2×2×1)
	local light = Instance.new("PointLight")
	light.Name = AURA
	light.Color = L.Color
	light.Range = L.LightRange
	light.Brightness = L.LightBrightness
	light.Shadows = false
	light.Parent = att
end

local function addLabel(head: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Name = LABEL
	gui.Adornee = head
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(70, 26)
	gui.StudsOffsetWorldSpace = Vector3.new(0, L.LabelOffset, 0)
	gui.MaxDistance = L.LabelMaxDistance
	gui.Parent = head
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.fromRGB(30, 26, 14)
	t.BackgroundTransparency = 0.25
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = L.Color
	t.Text = L.Label
	t.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = t
	local stroke = Instance.new("UIStroke")
	stroke.Color = L.Color
	stroke.Thickness = 1.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = t
end

local function apply(player: Player)
	local char = player.Character
	if not char then
		return
	end
	clear(char)
	if player:GetAttribute("Has_vip") ~= true then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		addAura(char, root)
	end
	local head = char:FindFirstChild("Head") :: BasePart?
	if head and isLobby() then
		addLabel(head)
	end
end

local started = false
function VipService.init()
	if started then
		return
	end
	started = true
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(char)
			char:WaitForChild("HumanoidRootPart", 10)
			char:WaitForChild("Head", 10)
			apply(player)
		end)
		player:GetAttributeChangedSignal("Has_vip"):Connect(function()
			apply(player)
		end)
		if player.Character then
			task.spawn(apply, player)
		end
	end
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
	-- лобби ↔ матч на одном сервере (Studio): надпись только в лобби
	ReplicatedStorage:GetAttributeChangedSignal("Mode"):Connect(function()
		for _, p in Players:GetPlayers() do
			apply(p)
		end
	end)
end

return VipService
