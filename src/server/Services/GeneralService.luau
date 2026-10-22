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

local GeneralService = {}

local NAME = "Генерал Нурсултан"
local IDLE_ANIM = "rbxassetid://180435571" -- стойка R6

local function missionFor(night: number): Config.MissionDef
	return Config.Missions[night] or { type = "classic", title = string.format("Ночь %d", night), anchor = 1 }
end

-- Текст брифинга: заголовок и строки
function GeneralService.brief(night: number): (string, { string })
	local def = missionFor(night)
	local lines: { string } = {}
	if night == 1 then
		table.insert(lines, "Бойцы, добро пожаловать на базу. Город захвачен мутантами, днём они сгорают на солнце — ночью выходят. Мы забираем город район за районом.")
		table.insert(lines, "Днём закупайтесь в магазине и открывайте здания за общие монеты. Ночью магазин закрыт: выдвигаемся на задание.")
	end
	local template = Config.Briefs[def.type] or Config.Briefs.classic
	for _, line in template do
		local text = string.gsub(line, "{(%w+)}", function(key: string): string
			if key == "points" then
				return tostring(def.points or 3)
			elseif key == "kills" then
				return tostring(def.kills or 15)
			elseif key == "seconds" then
				return tostring(def.seconds or 150)
			elseif key == "hold" then
				return tostring(Config.Convoy.InstallHold)
			end
			return key
		end)
		table.insert(lines, text)
	end
	if def.install and def.type == "escort" then
		table.insert(lines, string.format("Когда грузовик встанет, установите шатёр на золотой метке: удерживайте E %d секунд.", Config.Convoy.InstallHold))
	end
	if def.hint and def.hint ~= "" then
		table.insert(lines, "Задача: " .. def.hint .. ".")
	end
	return string.format("Ночь %d: %s", night, def.title), lines
end

local function nextNight(): number
	return ((ReplicatedStorage:GetAttribute("Wave") :: number?) or 0) + 1
end

local function send(player: Player)
	local title, lines = GeneralService.brief(nextNight())
	Remotes.get("Briefing"):FireClient(player, NAME, title, lines)
end

-- Утро: напоминание всем игрокам
function GeneralService.announceDay()
	local night = nextNight()
	local def = missionFor(night)
	Remotes.get("Notify"):FireAllClients(string.format("%s ждёт на базе. Ночь %d: %s. Подойдите и нажмите E, чтобы выслушать задание.", NAME, night, def.title), 7)
end

local function build()
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("NPC")
	local template = lib and lib:FindFirstChild("General")
	if not template then
		warn("[GeneralService] нет ServerStorage.Assets.NPC.General")
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
	-- на землю: низ модели на ground
	local ground = workspace:Raycast(position + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0))
	local gy = if ground then ground.Position.Y else position.Y
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
	prompt.ActionText = "Поговорить"
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
