--!strict
-- Катсцены: генерал коротко говорит задачу, камера показывает, где это. Сервер собирает кадры, клиент играет (CutsceneController).
-- Кадр: { from, fromEnd, look, lookEnd, seconds, speaker, text }. Отключение на всю команду — атрибут CutscenesOff
-- (настройка хоста при создании лобби; в игре — клавиша K у хоста, событие CutsceneToggle).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local MissionService = require(script.Parent:WaitForChild("MissionService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local CutsceneService = {}

export type Shot = { from: Vector3, fromEnd: Vector3, look: Vector3, lookEnd: Vector3, seconds: number, speaker: string?, text: string }

local C = Config.Cutscene

local function marker(name: string): Vector3?
	local markers = workspace:FindFirstChild("Markers")
	local m = markers and markers:FindFirstChild(name)
	return if m and m:IsA("BasePart") then m.Position else nil
end

-- Проверка пути камеры: не влетает в модели и видит цель
local function worldParams(): (RaycastParams, OverlapParams)
	local skip: { Instance } = {}
	for _, name in { "Zombies", "Corpses", "Soldiers", "Convoy", "MissionObjects" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(skip, f)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(skip, p.Character)
		end
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = skip
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = skip
	return rp, op
end

local function insideSomething(p: Vector3, radius: number, op: OverlapParams): boolean
	for _, part in workspace:GetPartBoundsInRadius(p, radius, op) do
		if part.Transparency < 0.9 and part ~= workspace.Terrain then
			local l = part.CFrame:PointToObjectSpace(p):Abs()
			local h = part.Size / 2 + Vector3.one * radius
			if l.X <= h.X and l.Y <= h.Y and l.Z <= h.Z then
				return true
			end
		end
	end
	return false
end

type Check = { radius: number, tolerance: number, sky: boolean }

-- Штраф кадра; 0 — кадр чистый. Влёт в модель штрафуется сильнее, чем заслонённая цель
local function penalty(s: Shot, check: Check, rp: RaycastParams, op: OverlapParams): number
	local n = 0
	local STEPS = 4
	for i = 0, STEPS do
		local u = i / STEPS
		local p = s.from:Lerp(s.fromEnd, u)
		local l = s.look:Lerp(s.lookEnd, u)
		if insideSomething(p, check.radius, op) then
			n += 4
		end
		local d = l - p
		local len = d.Magnitude - check.tolerance
		if len > 0 and workspace:Raycast(p, d.Unit * len, rp) then
			n += 1
		end
		if check.sky and workspace:Raycast(p, Vector3.new(0, 200, 0), rp) then
			n += 2
		end
		if i < STEPS then
			local nextP = s.from:Lerp(s.fromEnd, (i + 1) / STEPS)
			if workspace:Raycast(p, nextP - p, rp) then
				n += 4
			end
		end
	end
	return n
end

local function bestShot(list: { Shot }, check: Check, rp: RaycastParams, op: OverlapParams): Shot
	local best, bestN = list[1], math.huge
	for _, s in list do
		local n = penalty(s, check, rp, op)
		if n == 0 then
			return s
		end
		if n < bestN then
			best, bestN = s, n
		end
	end
	return best
end

local function polar(angle: number, radius: number, height: number): Vector3
	return Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
end

-- Генерал крупно
local function generalShot(text: string, seconds: number): Shot
	local g = marker("General") or marker("PlayerSpawn") or Vector3.zero
	local head = g + Vector3.new(0, 3, 0)
	local list: { Shot } = {}
	for _, ring in { { 15, 6 }, { 11, 5 }, { 8, 4.5 } } do
		for i = 0, 7 do
			local a = math.rad(50 + i * 45)
			table.insert(list, { from = g + polar(a, ring[1], ring[2]), fromEnd = g + polar(a, ring[1] * 0.72, ring[2] * 0.75), look = head, lookEnd = head, seconds = seconds, speaker = C.Speaker, text = text })
		end
	end
	local rp, op = worldParams()
	return bestShot(list, { radius = 1.5, tolerance = 3, sky = false }, rp, op)
end

-- Облёт места: сверху, а если место под крышей или под землёй — низко и рядом
local function areaShot(at: Vector3, text: string, seconds: number, speaker: string?): Shot
	local rp, op = worldParams()
	local outdoors = workspace:Raycast(at + Vector3.new(0, 6, 0), Vector3.new(0, 150, 0), rp) == nil
	local rings = if outdoors then { { 120, 70 }, { 90, 90 }, { 60, 110 }, { 55, 60 } } else { { 30, 10 }, { 22, 8 }, { 16, 6 }, { 12, 5 } }
	local list: { Shot } = {}
	for _, ring in rings do
		for i = 0, 7 do
			local a = math.rad(45 + i * 45)
			local fromEnd = if outdoors then at + polar(a - math.rad(90), ring[1] * 0.55, ring[2] * 0.72) else at + polar(a - math.rad(40), ring[1] * 0.7, ring[2] * 0.85)
			table.insert(list, { from = at + polar(a, ring[1], ring[2]), fromEnd = fromEnd, look = at, lookEnd = at, seconds = seconds, speaker = speaker, text = text })
		end
	end
	return bestShot(list, { radius = if outdoors then 5 else 2, tolerance = if outdoors then 12 else 3, sky = outdoors }, rp, op)
end

-- Общий план: если задевает модели — поднимаем камеру
local function highShot(s: Shot): Shot
	local rp, op = worldParams()
	local check: Check = { radius = 5, tolerance = 60, sky = true }
	for _ = 1, 8 do
		if penalty(s, check, rp, op) == 0 then
			break
		end
		s.from += Vector3.new(0, 40, 0)
		s.fromEnd += Vector3.new(0, 40, 0)
	end
	return s
end

-- Кадры дня перед ночью night
function CutsceneService.dayShots(night: number, first: boolean): { Shot }
	local shots: { Shot } = {}
	if first then
		local spawn = marker("PlayerSpawn") or Vector3.zero
		table.insert(shots, highShot({ from = Vector3.new(420, 240, -420), fromEnd = Vector3.new(120, 200, -420), look = Vector3.zero, lookEnd = Vector3.new(0, 0, -60), seconds = C.StorySeconds, speaker = C.Speaker, text = C.Story[1] }))
		table.insert(shots, areaShot(marker("Metro_EntranceTop") or Vector3.zero, C.Story[2], C.StorySeconds, C.Speaker))
		table.insert(shots, areaShot(spawn, C.Story[3], C.StorySeconds, C.Speaker))
	end
	local def = Config.Missions[night]
	if not def then
		return shots
	end
	local say = C.Say[night] or C.ByType[def.type] or C.ByType.classic
	table.insert(shots, generalShot(string.format("Night %d. %s", night, say), C.GeneralSeconds))
	local at = MissionService.anchorPosition(def.anchor)
	if def.markerRoute then
		-- маршрут конвоя: первая и последняя точка
		local a = marker(def.markerRoute[1])
		local b = marker(def.markerRoute[#def.markerRoute])
		if a then
			table.insert(shots, areaShot(a, "The convoy goes through here", C.AreaSeconds))
		end
		if b then
			at = b
		end
	end
	table.insert(shots, areaShot(at, C.Where[def.type] or C.Where.classic, C.AreaSeconds))
	for _, id in WaveMath.bossTypes(Config.Waves, night) do
		local z = Config.Zombies[id]
		if z then
			table.insert(shots, areaShot(at, string.format("Boss tonight: %s", z.name), C.AreaSeconds))
		end
	end
	return shots
end

local function enabled(): boolean
	return ReplicatedStorage:GetAttribute("CutscenesOff") ~= true
end

-- Утро: всем (выключено настройкой — ничего)
function CutsceneService.playDay(night: number, first: boolean)
	if enabled() then
		Remotes.get("Cutscene"):FireAllClients(CutsceneService.dayShots(night, first))
	end
end

-- Разговор с генералом (E): задание ночи одному игроку
function CutsceneService.playFor(player: Player, night: number)
	Remotes.get("Cutscene"):FireClient(player, CutsceneService.dayShots(night, false))
end

-- Вышел босс: короткий кадр; на это время игроков не бьют, босс стоит
function CutsceneService.bossIntro(id: string, pos: Vector3, look: Vector3)
	if not enabled() then
		return
	end
	local z = Config.Zombies[id]
	local line = C.Boss[id]
	if not z then
		return
	end
	for _, p in Players:GetPlayers() do
		PlayerService.setInvulnerable(p, C.BossSeconds + 0.5)
	end
	local head = pos + Vector3.new(0, 4, 0)
	local list: { Shot } = {}
	for _, dist in { 22, 16, 12 } do
		for _, deg in { 0, 35, -35, 70, -70, 110, -110, 180 } do
			local dir = CFrame.Angles(0, math.rad(deg), 0):VectorToWorldSpace(look)
			table.insert(list, { from = pos + dir * dist + Vector3.new(0, 7, 0), fromEnd = pos + dir * dist * 0.6 + Vector3.new(0, 4, 0), look = head, lookEnd = head, seconds = C.BossSeconds, speaker = z.name, text = line or "" })
		end
	end
	local rp, op = worldParams()
	Remotes.get("Cutscene"):FireAllClients({ bestShot(list, { radius = 2.5, tolerance = 6, sky = false }, rp, op) })
end

function CutsceneService.init()
	Remotes.get("CutsceneToggle").OnServerEvent:Connect(function(player: Player)
		if not RateLimit.allow(player, "CutsceneToggle", 0.5) then
			return
		end
		local host = ReplicatedStorage:GetAttribute("HostUserId")
		if typeof(host) == "number" and host ~= player.UserId then
			Remotes.get("Notify"):FireClient(player, "Only the squad host can change this", 2)
			return
		end
		local off = not (ReplicatedStorage:GetAttribute("CutscenesOff") == true)
		ReplicatedStorage:SetAttribute("CutscenesOff", off)
		Remotes.get("Notify"):FireAllClients(if off then "Cutscenes are off" else "Cutscenes are on", 3)
	end)
end

return CutsceneService
