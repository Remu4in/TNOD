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

-- Генерал крупно
local function generalShot(text: string, seconds: number): Shot
	local g = marker("General") or marker("PlayerSpawn") or Vector3.zero
	local head = g + Vector3.new(0, 3, 0)
	return { from = g + Vector3.new(10, 6, 12), fromEnd = g + Vector3.new(7, 4.5, 9), look = head, lookEnd = head, seconds = seconds, speaker = C.Speaker, text = text }
end

-- Облёт места сверху
local function areaShot(at: Vector3, text: string, seconds: number, speaker: string?): Shot
	return { from = at + Vector3.new(85, 70, 85), fromEnd = at + Vector3.new(45, 50, -45), look = at, lookEnd = at, seconds = seconds, speaker = speaker, text = text }
end

-- Кадры дня перед ночью night
function CutsceneService.dayShots(night: number, first: boolean): { Shot }
	local shots: { Shot } = {}
	if first then
		local spawn = marker("PlayerSpawn") or Vector3.zero
		table.insert(shots, { from = Vector3.new(420, 240, -420), fromEnd = Vector3.new(120, 200, -420), look = Vector3.zero, lookEnd = Vector3.new(0, 0, -60), seconds = C.StorySeconds, speaker = C.Speaker, text = C.Story[1] })
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
	local front = pos + look * 22 + Vector3.new(0, 7, 0)
	Remotes.get("Cutscene"):FireAllClients({
		{ from = front, fromEnd = pos + look * 13 + Vector3.new(0, 4, 0), look = head, lookEnd = head, seconds = C.BossSeconds, speaker = z.name, text = line or "" },
	})
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
