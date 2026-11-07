--!strict
-- Генерал Нурсултан на базе: выдаёт задание на ближайшую ночь и объясняет, что делать. Подойти и нажать E («Поговорить»);
-- утром (начало дня) всем приходит напоминание. Тексты — по типу миссии (Config.Missions[ночь], Config.Briefs).
-- Модель — ServerStorage.Assets.NPC.General (ассет 9306326178, проверен: скриптов нет), место — маркер Workspace.Markers.General
-- (если маркера нет, ставим рядом со стартовой точкой игроков).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local MissionService = require(script.Parent:WaitForChild("MissionService"))

local GeneralService = {}

local NAME = "General Nursultan"
local IDLE_ANIM = "rbxassetid://180435571" -- стойка R6

local function missionFor(night: number): Config.MissionDef
	return Config.Missions[night] or { type = "classic", title = string.format("Night %d", night), anchor = 1 }
end

-- Текст брифинга: заголовок и строки
function GeneralService.brief(night: number): (string, { string })
	local def = missionFor(night)
	local lines: { string } = {}
	if night == 1 then
		table.insert(lines, "Soldiers, welcome to the base. The city has been overrun by mutants: by day they burn in the sun, at night they come out. We are taking the city back district by district.")
		table.insert(lines, "By day, stock up at the shop and open buildings with shared coins. At night the shop is closed: we move out on the mission.")
	end
	local template = Config.Briefs[def.type] or Config.Briefs.classic
	for _, line in template do
		local text = string.gsub(line, "{(%w+)}", function(key: string): string
			if key == "points" then
				return tostring(def.points or 3)
			elseif key == "radius" then
				local r = def.radius or Config.ScoutRadius
				return string.format("%d–%d", r[1], r[2])
			elseif key == "kills" then
				return tostring(def.kills or 15)
			elseif key == "seconds" then
				return tostring(def.seconds or 150)
			elseif key == "hold" then
				return tostring(Config.Convoy.InstallHold)
			elseif key == "follow" then
				return tostring(Config.Convoy.FollowRadius)
			end
			return key
		end)
		table.insert(lines, text)
	end
	if def.install and def.type == "escort" then
		table.insert(lines, string.format("When the truck stops, set up the tent on the golden marker: hold E for %d seconds.", Config.Convoy.InstallHold))
	end
	if def.hint and def.hint ~= "" then
		table.insert(lines, "Objective: " .. def.hint .. ".")
	end
	return string.format("Night %d: %s", night, def.title), lines
end

local function nextNight(): number
	return ((ReplicatedStorage:GetAttribute("Wave") :: number?) or 0) + 1
end

local function send(player: Player)
	-- короткая сцена: реплика и камера над местом; катсцены выключены — текстом
	if ReplicatedStorage:GetAttribute("CutscenesOff") ~= true then
		require(script.Parent:WaitForChild("CutsceneService")).playFor(player, nextNight())
		return
	end
	local title, lines = GeneralService.brief(nextNight())
	Remotes.get("Briefing"):FireClient(player, NAME, title, lines)
end

-- Подстановка {points}/{kills}/{seconds}/{follow}/{name} в короткие тексты Config.DayBrief
local function fill(template: string, def: Config.MissionDef, extra: { [string]: string }?): string
	local out = string.gsub(template, "{(%w+)}", function(key: string): string
		if extra and extra[key] then
			return extra[key]
		elseif key == "points" then
			return tostring(def.points or 3)
		elseif key == "kills" then
			return tostring(def.kills or 15)
		elseif key == "seconds" then
			return tostring(def.seconds or 150)
		elseif key == "follow" then
			return tostring(Config.Convoy.FollowRadius)
		end
		return key
	end)
	return out
end

-- Что будет следующей ночью: атрибуты ReplicatedStorage для клиента (DayBriefController показывает их панелью и строкой в чате).
-- NextBriefPos — точка миссии (для строки «где»: расстояние и сторона света считает клиент от игрока); у миссий на базе её нет
function GeneralService.publishBrief(night: number)
	local def = missionFor(night)
	local kind = def.type
	local DB = Config.DayBrief
	local task = fill(DB.Task[kind] or DB.Task.classic, def)
	local tip = fill(DB.Tip[kind] or DB.Tip.classic, def)
	local bosses = WaveMath.bossTypes(Config.Waves, night)
	if #bosses > 0 then
		local names: { string } = {}
		for _, id in bosses do
			table.insert(names, Config.Zombies[id].name)
		end
		tip = fill(DB.Boss, def, { name = table.concat(names, ", ") }) .. " " .. tip
	end
	local pos: Vector3? = nil
	if kind ~= "classic" and kind ~= "clear" then
		pos = MissionService.anchorPosition(def.anchor)
	end
	ReplicatedStorage:SetAttribute("NextBriefNight", night)
	ReplicatedStorage:SetAttribute("NextBriefTitle", def.title)
	ReplicatedStorage:SetAttribute("NextBriefTask", task)
	ReplicatedStorage:SetAttribute("NextBriefTip", tip)
	ReplicatedStorage:SetAttribute("NextBriefPos", pos)
end

-- Утро: напоминание всем игрокам
function GeneralService.announceDay()
	local night = nextNight()
	local def = missionFor(night)
	GeneralService.publishBrief(night)
	Remotes.get("Notify"):FireAllClients(string.format("Night %d: %s. Talk to %s (E) to see the orders again.", night, def.title, NAME), 5)
end

local function build()
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("NPC")
	local template = lib and lib:FindFirstChild("General")
	if not template then
		warn("[GeneralService] no ServerStorage.Assets.NPC.General")
		return
	end
	local markers = workspace:FindFirstChild("Markers")
	local marker = markers and markers:FindFirstChild("General") :: BasePart?
	local spawn = markers and markers:FindFirstChild("PlayerSpawn") :: BasePart?
	local position: Vector3
	local look: Vector3
	if marker then
		position = Vector3.new(marker.Position.X, marker.Position.Y - marker.Size.Y / 2, marker.Position.Z)
		look = marker.CFrame.LookVector
	else
		local base = if spawn then spawn.Position else Vector3.zero
		position = base + Vector3.new(14, 0, 8)
		look = if spawn then (base - position) * Vector3.new(1, 0, 1) else Vector3.new(0, 0, 1)
	end
	local model = template:Clone() :: Model
	model.Name = "General"
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local hum = model:FindFirstChildOfClass("Humanoid")
	local look2 = Vector3.new(look.X, 0, look.Z)
	look2 = if look2.Magnitude > 0.01 then look2.Unit else Vector3.new(0, 0, 1)
	-- на землю: низ модели на ground. Маркер уже стоит на земле (position — его низ). Без маркера луч идёт вниз от точки на 3 студа выше
	-- и только по земле, дорогам и базе: раньше он начинался на 20 студов выше и садил генерала на крышу ворот базы
	local gy = position.Y
	if not marker then
		local include: { Instance } = {}
		for _, name in { "Ground", "Roads", "Grass", "Base" } do
			local f = workspace:FindFirstChild(name)
			if f then
				table.insert(include, f)
			end
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = include
		local ground = workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -30, 0), params)
		if ground then
			gy = ground.Position.Y
		end
	end
	model:PivotTo(CFrame.lookAt(Vector3.new(position.X, gy + 3.2, position.Z), Vector3.new(position.X, gy + 3.2, position.Z) + look2))
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanQuery = d == root
		end
	end
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
		local anim = Instance.new("Animation")
		anim.AnimationId = IDLE_ANIM
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if ok and track then
			track.Looped = true
			track:Play()
		end
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 30)
	gui.StudsOffset = Vector3.new(0, 3.8, 0)
	gui.MaxDistance = 60
	gui.Parent = root
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.fromRGB(255, 200, 80)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = NAME
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Talk"
	prompt.ObjectText = NAME
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(player: Player)
		if RateLimit.allow(player, "General", 1) then
			send(player)
		end
	end)
	model.Parent = workspace
end

function GeneralService.init()
	build()
end

return GeneralService
