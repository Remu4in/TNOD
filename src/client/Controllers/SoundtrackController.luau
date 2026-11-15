--!strict
-- Звуковое сопровождение (Config.Soundtrack): работает и в лобби, и в матче.
-- Музыка — одна дорожка по состоянию: катсцена > итоги > лобби > метро (тишина: там MetroAmbienceController) > босс > ночь > день.
-- Фон — зацикленные звуки дня, базы и ночи; ночью ещё случайные звуки вдалеке. Сигналы — наступила ночь, рассвет, босс, катсцена;
-- пока игрок упал — сердцебиение. Только отображение: состояние берём из атрибутов сервера (Phase, Mode, BossName, ReturnAt, Downed).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local SoundtrackController = {}

local C = Config.Soundtrack

-- Общая группа громкости звуков окружения (её же использует SfxController)
local function ambienceGroup(): SoundGroup
	local g = SoundService:FindFirstChild("NotdAmbience")
	if g and g:IsA("SoundGroup") then
		return g
	end
	local ng = Instance.new("SoundGroup")
	ng.Name = "NotdAmbience"
	ng.Volume = Config.AmbienceVolume
	ng.Parent = SoundService
	return ng
end

local folder: Folder
local function newSound(name: string, id: string, looped: boolean): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = id
	s.Looped = looped
	s.Volume = 0
	s.SoundGroup = ambienceGroup()
	s.Parent = folder
	return s
end

-- Плавно довести громкость; на нуле — пауза (чтобы не тратить каналы)
local tweens: { [Sound]: Tween } = {}
local function fadeTo(s: Sound, volume: number, seconds: number)
	local old = tweens[s]
	if old then
		old:Cancel()
	end
	if volume > 0 and not s.IsPlaying then
		if s.TimePosition > 0 then
			s:Resume()
		else
			s:Play()
		end
	end
	local t = TweenService:Create(s, TweenInfo.new(seconds), { Volume = volume })
	tweens[s] = t
	t:Play()
	if volume <= 0 then
		t.Completed:Once(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed and s.Volume <= 0 then
				s:Pause()
			end
		end)
	end
end

local function playOnce(id: string, volume: number, parent: Instance?, cut: number?)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.SoundGroup = ambienceGroup()
	if parent and parent:IsA("Attachment") then
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 40
		s.RollOffMaxDistance = 400
	end
	s.Parent = parent or folder
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	if cut then
		task.delay(cut, function()
			if s.Parent then
				fadeTo(s, 0, 2)
				task.delay(2.1, function()
					s:Destroy()
				end)
			end
		end)
	end
	task.delay(math.max(cut or 0, 15) + 3, function()
		if s.Parent and not s.Looped then
			s:Destroy()
		end
	end)
end

local function inBase(pos: Vector3): boolean
	local z = Config.BaseZone
	return workspace:FindFirstChild("Base") ~= nil -- база есть только на карте Custom (атрибут Location — имя карты, не id)
		and pos.X >= z.minX and pos.X <= z.maxX and pos.Z >= z.minZ and pos.Z <= z.maxZ and pos.Y <= z.maxY
end

function SoundtrackController.start()
	local player = Players.LocalPlayer
	local f = Instance.new("Folder")
	f.Name = "Soundtrack"
	f.Parent = SoundService
	folder = f

	-- Музыка: по звуку на каждую дорожку, создаём по требованию
	local tracks: { [string]: Sound } = {}
	local current: string? = nil
	local function trackFor(state: string): (string, number)
		local def = C.Music[state]
		local id = def.ids[1]
		if state == "night" then
			local wave = ReplicatedStorage:GetAttribute("Wave")
			local n = if typeof(wave) == "number" and wave >= 1 then wave else 1
			id = def.ids[(n - 1) % #def.ids + 1]
		end
		return id, def.volume
	end
	local function setMusic(state: string?)
		local key: string? = nil
		local volume = 0
		if state then
			local id
			id, volume = trackFor(state)
			key = id
			if not tracks[id] then
				tracks[id] = newSound("Music", id, true)
			end
		end
		if key == current then
			return
		end
		for id, s in tracks do
			if id ~= key then
				fadeTo(s, 0, C.Fade)
			end
		end
		if key then
			local s = tracks[key]
			s.TimePosition = 0
			fadeTo(s, volume, C.Fade)
		end
		current = key
	end

	-- Фоновые звуки
	local beds: { [string]: { { sound: Sound, volume: number } } } = {}
	for name, list in C.Beds do
		local out = {}
		for _, def in list do
			table.insert(out, { sound = newSound("Bed_" .. name, def.id, true), volume = def.volume })
		end
		beds[name] = out
	end
	local bedOn: { [string]: boolean } = {}
	local function setBed(name: string, on: boolean)
		if (bedOn[name] or false) == on then
			return
		end
		bedOn[name] = on
		for _, e in beds[name] do
			fadeTo(e.sound, if on then e.volume else 0, C.Fade)
		end
	end

	-- Сердцебиение, пока упал
	local heart = newSound("Downed", C.Downed.id, true)
	local heartOn = false

	-- Точка для дальних звуков ночи
	local farAtt = Instance.new("Attachment")
	farAtt.Name = "SoundtrackFar"
	farAtt.Parent = workspace.Terrain

	local lastPhase = ReplicatedStorage:GetAttribute("Phase")
	local lastBoss = ReplicatedStorage:GetAttribute("BossName")
	local inCutscene = false
	local nextNight = os.clock() + math.random(C.NightOneShotEvery[1], C.NightOneShotEvery[2])
	local nextRadio = os.clock() + math.random(C.BaseOneShot.every[1], C.BaseOneShot.every[2])

	local function stinger(name: string)
		local def = C.Stingers[name]
		playOnce(def.id, def.volume)
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			local mode = ReplicatedStorage:GetAttribute("Mode")
			local phase = ReplicatedStorage:GetAttribute("Phase")
			local boss = ReplicatedStorage:GetAttribute("BossName")
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local inMetro = root ~= nil and root.Position.Y < Config.Metro.InsideMaxY
			local cutscene = player:GetAttribute("InCutscene") == true
			local results = phase == "GameOver" or (mode ~= "lobby" and ReplicatedStorage:GetAttribute("ReturnAt") ~= nil)
			local lobby = mode == "lobby" or phase == "Lobby"
			local night = phase == "Night"
			local day = phase == "Day" or phase == "Intermission"

			-- сигналы
			if cutscene and not inCutscene then
				stinger("cutscene")
			end
			inCutscene = cutscene
			if phase ~= lastPhase then
				if phase == "Night" then
					stinger("night")
				elseif phase == "Day" and lastPhase == "Night" then
					stinger("dawn")
				end
				lastPhase = phase
			end
			if typeof(boss) == "string" and boss ~= lastBoss and not lobby then
				stinger("boss")
			end
			lastBoss = boss

			-- музыка
			local music: string? = nil
			if cutscene then
				music = "cutscene"
			elseif results then
				music = "results"
			elseif lobby then
				music = "lobby"
			elseif inMetro then
				music = nil
			elseif typeof(boss) == "string" then
				music = "boss"
			elseif night then
				music = "night"
			elseif day then
				music = "day"
			end
			setMusic(music)

			-- фон
			local outside = not lobby and not results and not inMetro
			local atBase = outside and root ~= nil and inBase(root.Position)
			setBed("day", outside and day and not atBase)
			setBed("base", atBase and not night)
			setBed("night", outside and night)

			-- случайные звуки ночи — из точки вдалеке, чтобы был слышен источник
			local now = os.clock()
			if outside and night and root and not cutscene then
				if now >= nextNight then
					nextNight = now + math.random(C.NightOneShotEvery[1], C.NightOneShotEvery[2])
					local a = math.random() * math.pi * 2
					local d = 60 + math.random() * 80
					farAtt.WorldPosition = root.Position + Vector3.new(math.cos(a) * d, 4, math.sin(a) * d)
					local def = C.NightOneShots[math.random(1, #C.NightOneShots)]
					playOnce(def.id, def.volume, farAtt, def.cut)
				end
			else
				nextNight = math.max(nextNight, now + C.NightOneShotEvery[1])
			end
			if atBase and not night and now >= nextRadio then
				nextRadio = now + math.random(C.BaseOneShot.every[1], C.BaseOneShot.every[2])
				playOnce(C.BaseOneShot.id, C.BaseOneShot.volume)
			end

			-- сердцебиение
			local downed = not lobby and player:GetAttribute("Downed") == true
			if downed ~= heartOn then
				heartOn = downed
				fadeTo(heart, if downed then C.Downed.volume else 0, if downed then 0.5 else 1)
			end
		end
	end)
end

return SoundtrackController
