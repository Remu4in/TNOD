--!strict
-- Миссии ночи (сюжет: docs/story.md). Ночь = миссия из Config.Missions[ночь]: точка миссии (шатёр района), задача и «поток» зомби,
-- который идёт со всех сторон на расстоянии 100–150 студов от этой точки (ZombieService.setAnchor), пока задача не выполнена.
--   scout   — разведка: обойти N контрольных точек вокруг шатра; зомби идут потоком без конца
--   defend  — защита шатра: продержаться SECONDS секунд рядом с ним; поток без конца
--   clear   — зачистка: убить всю волну (конечная очередь), зомби — вокруг точки миссии
--   classic — как раньше (убить всю волну); сюда же пока сведены ещё не сделанные типы (конвой, установка шатра, босс-события)
-- Статус для клиентов — атрибуты ReplicatedStorage: MissionTitle, MissionText, MissionKind.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))

local MissionService = {}

type Point = { pos: Vector3, part: BasePart, done: boolean }
type State = {
	def: Config.MissionDef,
	night: number,
	anchor: Vector3,
	points: { Point },
	secondsLeft: number,
	infinite: boolean,
	comp: WaveMath.Composition,
	hpMult: number,
	lastText: string,
}

local current: State? = nil
local objects: Folder? = nil
local rng = Random.new()

local GROUND_FOLDERS = { "Roads", "Ground", "Grass" }

local function isGround(inst: Instance): boolean
	for _, name in GROUND_FOLDERS do
		local f = workspace:FindFirstChild(name)
		if f and inst:IsDescendantOf(f) then
			return true
		end
	end
	return false
end

-- Точка на земле под (x, z): только дороги, земля и трава (не крыши зданий)
local function groundAt(x: number, z: number): Vector3?
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0))
	if hit and hit.Normal.Y > 0.9 and isGround(hit.Instance) then
		local up = workspace:Raycast(hit.Position + Vector3.new(0, 2, 0), Vector3.new(0, 40, 0))
		if not up then
			return hit.Position
		end
	end
	return nil
end

-- Шатры района (по удалению от базы): точки миссий. Если шатров нет — вокруг стартовой точки игроков.
local function tentPositions(): { Vector3 }
	local list: { Vector3 } = {}
	local base = workspace:FindFirstChild("Base")
	if base then
		for _, c in base:GetChildren() do
			if c.Name == "Tent" and c:IsA("Model") then
				table.insert(list, c:GetPivot().Position)
			end
		end
	end
	local origin = Vector3.zero
	local markers = workspace:FindFirstChild("Markers")
	local ps = markers and markers:FindFirstChild("PlayerSpawn") :: BasePart?
	if ps then
		origin = ps.Position
	end
	table.sort(list, function(a, b)
		return (a - origin).Magnitude < (b - origin).Magnitude
	end)
	if #list == 0 then
		table.insert(list, origin)
	end
	return list
end

function MissionService.anchorPosition(index: number): Vector3
	local list = tentPositions()
	return list[math.clamp(index, 1, #list)]
end

local function setStatus(title: string, text: string, kind: string)
	ReplicatedStorage:SetAttribute("MissionTitle", title)
	ReplicatedStorage:SetAttribute("MissionText", text)
	ReplicatedStorage:SetAttribute("MissionKind", kind)
end

local function notify(text: string, seconds: number)
	Remotes.get("Notify"):FireAllClients(text, seconds)
end

local function makeBeacon(pos: Vector3, label: string): BasePart
	local part = Instance.new("Part")
	part.Name = "ScoutBeacon"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(80, 200, 255)
	part.Transparency = 0.35
	part.Size = Vector3.new(2, 30, 2)
	part.Position = pos + Vector3.new(0, 15, 0)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(200, 44)
	gui.StudsOffset = Vector3.new(0, 18, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 1500
	gui.Parent = part
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(120, 220, 255)
	text.TextStrokeTransparency = 0.3
	text.Text = label
	text.Parent = gui
	part.Parent = objects
	return part
end

local function upPositions(): { Vector3 }
	local list: { Vector3 } = {}
	for _, p in PlayerService.upPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			table.insert(list, r.Position)
		end
	end
	return list
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Команда выдвигается к точке миссии: ставим игроков на землю рядом с шатром
local function moveTeam(anchor: Vector3)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if char then
			local angle = rng:NextNumber() * math.pi * 2
			local radius = 8 + rng:NextNumber() * 8
			local x, z = anchor.X + math.cos(angle) * radius, anchor.Z + math.sin(angle) * radius
			local ground = groundAt(x, z) or anchor
			char:PivotTo(CFrame.new(ground + Vector3.new(0, 4, 0)))
		end
	end
end

-- Начало ночи: comp/hpMult — состав и здоровье волны (для подпитки бесконечного потока)
function MissionService.begin(night: number, comp: WaveMath.Composition, hpMult: number): (boolean, string)
	MissionService.finish()
	local def: Config.MissionDef = Config.Missions[night] or { type = "classic", title = string.format("Ночь %d", night), anchor = 1 }
	local anchor = MissionService.anchorPosition(def.anchor)
	objects = Instance.new("Folder")
	objects.Name = "MissionObjects"
	objects.Parent = workspace
	local kind = def.type
	if kind ~= "scout" and kind ~= "defend" and kind ~= "clear" then
		kind = "classic"
	end
	local state: State = {
		def = def, night = night, anchor = anchor, points = {}, secondsLeft = def.seconds or 0,
		infinite = kind == "scout" or kind == "defend", comp = comp, hpMult = hpMult, lastText = "",
	}
	current = state
	ZombieService.setAnchor(anchor)
	if Config.MissionMoveTeam then
		moveTeam(anchor)
	end
	if kind == "scout" then
		local count = def.points or 3
		local placed = 0
		local tries = 0
		while placed < count and tries < 80 do
			tries += 1
			local angle = (placed / count) * math.pi * 2 + (rng:NextNumber() - 0.5) * 0.8
			local radius = 55 + rng:NextNumber() * 45
			local ground = groundAt(anchor.X + math.cos(angle) * radius, anchor.Z + math.sin(angle) * radius)
			if ground then
				placed += 1
				table.insert(state.points, { pos = ground, part = makeBeacon(ground, string.format("Точка %d", placed)), done = false })
			end
		end
	end
	setStatus(def.title, def.hint or "", kind)
	notify(string.format("Ночь %d — %s", night, def.title), 4)
	return state.infinite, kind
end

local function topUp(state: State)
	if state.infinite and ZombieService.queueSize() < 8 then
		-- подпитка потока: обычные зомби волны (боссы приходят один раз, в начале ночи)
		local normal: WaveMath.Composition = {}
		for id, n in state.comp do
			if not WaveMath.isBossType(id) then
				normal[id] = n
			end
		end
		ZombieService.enqueue(WaveMath.spawnQueue(normal, rng), state.hpMult, state.night)
	end
end

-- Раз в 0,25 с: "done" — миссия выполнена, nil — идёт (classic/clear завершает RoundService по числу зомби)
function MissionService.update(dt: number): string?
	local state = current
	if not state then
		return nil
	end
	topUp(state)
	local kind = ReplicatedStorage:GetAttribute("MissionKind")
	local text = ""
	local result: string? = nil
	if kind == "scout" then
		local done = 0
		local ups = upPositions()
		for _, pt in state.points do
			if not pt.done then
				for _, pos in ups do
					if flatDist(pos, pt.pos) < 10 then
						pt.done = true
						pt.part:Destroy()
						notify("Точка обследована", 2)
						break
					end
				end
			end
			if pt.done then
				done += 1
			end
		end
		text = string.format("Обследовано точек: %d из %d", done, #state.points)
		if #state.points > 0 and done >= #state.points then
			result = "done"
		end
	elseif kind == "defend" then
		local near = false
		for _, pos in upPositions() do
			if flatDist(pos, state.anchor) < 80 then
				near = true
				break
			end
		end
		if near then
			state.secondsLeft = math.max(0, state.secondsLeft - dt)
			text = string.format("Держим шатёр: осталось %d с", math.ceil(state.secondsLeft))
		else
			text = string.format("Вернитесь к шатру! Осталось %d с", math.ceil(state.secondsLeft))
		end
		if state.secondsLeft <= 0 then
			result = "done"
		end
	elseif kind == "clear" or kind == "classic" then
		text = string.format("Осталось зомби: %d", (ReplicatedStorage:GetAttribute("ZombiesLeft") :: number?) or 0)
	end
	if text ~= state.lastText then
		state.lastText = text
		ReplicatedStorage:SetAttribute("MissionText", text)
	end
	return result
end

function MissionService.finish()
	if objects then
		objects:Destroy()
		objects = nil
	end
	if current then
		current = nil
	end
	ZombieService.setAnchor(nil)
	setStatus("", "", "")
end

-- Рассвет: команда возвращается к магазину
function MissionService.returnTeam(spawn: Vector3)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if char then
			char:PivotTo(CFrame.new(spawn + Vector3.new(math.random(-6, 6), 3, math.random(-4, 4))))
		end
	end
end

function MissionService.isInfinite(): boolean
	return current ~= nil and current.infinite
end

return MissionService
