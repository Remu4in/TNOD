--!strict
-- Свет, туман, цветокоррекция и свечение по фазам — пресеты Config.Visual.Presets. Lighting целиком ставит клиент:
-- сервер пишет атрибут ReplicatedStorage.Look (day | night | boss | lobby) и меняет небо, а мы плавно (TweenService) переходим к пресету.
-- Под картой (ниже Config.Metro.InsideMaxY) берём пресет metro, в пещере (x > Cave.minX и z > Cave.minZ) — cave.
-- Значения клиента локальные: сервер свойства Lighting больше не трогает, поэтому они не перетираются репликацией.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local LookController = {}

local V = Config.Visual
local metroLevel = 0 -- 0 — наверху, 1 — станция, 2 — пещера
local current = ""
local tweens: { Tween } = {}
local changed = Instance.new("BindableEvent")

-- эффект нужного класса в Lighting: берём существующий (настроенный в месте) или создаём
local function effect(className: string, name: string?): Instance
	if name then
		local found = Lighting:FindFirstChild(name)
		if found and found.ClassName == className then
			return found
		end
	else
		local found = Lighting:FindFirstChildOfClass(className :: any)
		if found then
			return found
		end
	end
	local e = Instance.new(className :: any)
	if name then
		e.Name = name
	end
	e.Parent = Lighting
	return e
end

-- какой пресет нужен сейчас
local function wanted(): string
	if metroLevel == 2 then
		return "cave"
	elseif metroLevel == 1 then
		return "metro"
	end
	local look = ReplicatedStorage:GetAttribute("Look")
	if type(look) == "string" and (V.Presets :: any)[look] then
		return look
	end
	return if ReplicatedStorage:GetAttribute("Mode") == "lobby" then "lobby" else "day"
end

local function apply(name: string, seconds: number)
	local preset = (V.Presets :: any)[name]
	if not preset then
		return
	end
	current = name
	for _, t in tweens do
		t:Cancel()
	end
	table.clear(tweens)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local function go(inst: Instance, props: { [string]: any }?)
		if not props then
			return
		end
		if seconds <= 0 then
			for k, v in props do
				(inst :: any)[k] = v
			end
			return
		end
		local t = TweenService:Create(inst, info, props)
		t:Play()
		table.insert(tweens, t)
	end
	local light = preset.lighting
	if light and light.ClockTime == 24 then
		-- ночь задана как 24: переход из дня идёт вперёд, через закат (к 0 твин крутил бы время назад, через утро).
		-- Если уже ночь (часы после полуночи), целимся в 0, иначе твин прокрутил бы почти сутки.
		local copy = table.clone(light)
		if seconds <= 0 or Lighting.ClockTime < 12 then
			copy.ClockTime = 0
		end
		light = copy
	end
	go(Lighting, light)
	go(effect("Atmosphere"), preset.atmosphere)
	go(effect("BloomEffect"), preset.bloom)
	go(effect("SunRaysEffect"), preset.sunRays)
	go(effect("ColorCorrectionEffect", "LookGrade"), preset.grade)
	changed:Fire(name)
end

local function refresh(seconds: number)
	local name = wanted()
	if name ~= current then
		apply(name, seconds)
	end
end

-- крупная луна и звёзды у любого неба, которое сервер положит в Lighting
local function tuneSky(s: Instance)
	if s:IsA("Sky") then
		s.MoonAngularSize = V.MoonSize
		s.StarCount = V.StarCount
		s.CelestialBodiesShown = true -- у NightSky и RedNight в месте луна была выключена
	end
end

-- 0 — наверху, 1 — станция метро, 2 — пещера
function LookController.metroLevel(): number
	return metroLevel
end

-- имя текущего пресета (day, night, boss, lobby, metro, cave)
function LookController.current(): string
	return current
end

-- ночь наверху (для прожекторов и фар): пресет night или boss
function LookController.isNight(): boolean
	local look = ReplicatedStorage:GetAttribute("Look")
	return look == "night" or look == "boss"
end

LookController.Changed = changed.Event

function LookController.start()
	local player = Players.LocalPlayer
	for _, s in Lighting:GetChildren() do
		tuneSky(s)
	end
	Lighting.ChildAdded:Connect(tuneSky)
	apply(wanted(), 0) -- первый кадр — сразу нужный вид, без перехода от дневных значений места
	ReplicatedStorage:GetAttributeChangedSignal("Look"):Connect(function()
		refresh(V.TweenTime)
	end)
	ReplicatedStorage:GetAttributeChangedSignal("Mode"):Connect(function()
		refresh(V.TweenTime)
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local level = 0
		if root and root.Position.Y < Config.Metro.InsideMaxY then
			local c = Config.Metro.Cave
			level = if root.Position.X > c.minX and root.Position.Z > c.minZ then 2 else 1
		end
		if level ~= metroLevel then
			metroLevel = level
			refresh(V.MetroTweenTime)
		end
	end)
end

return LookController
