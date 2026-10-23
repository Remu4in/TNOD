--!strict
-- Звуки окружения (тихо, чтобы не уставали уши): голоса и удары зомби, их смерть, моторы машин, сигнал выполненной миссии.
-- Все звуки идут через SoundGroup "NotdAmbience" (общая громкость — Config.AmbienceVolume), у каждого своя дальность затухания.
-- Голоса зомби — только у ближайших MAX_VOICES, чтобы не было каши; запускает клиент (по одному звуку на зомби, переиспользуются).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local SfxController = {}

local ID = {
	growl = { "rbxassetid://131060194", "rbxassetid://131060145" }, -- «преследует» (3–5 с)
	walk = { "rbxassetid://131060210", "rbxassetid://131060226" },
	attack = { "rbxassetid://131138828", "rbxassetid://131138835", "rbxassetid://131138832" },
	dying = { "rbxassetid://131138845", "rbxassetid://131138854" },
	engine = "rbxassetid://520998094", -- мотор на холостых (зацикленный)
	mission = "rbxassetid://4612373756", -- миссия выполнена
	unlock = "rbxassetid://2846734837", -- шатёр установлен / открыто
}
local MAX_VOICES = 6
local VOICE_RANGE = 70

local group: SoundGroup

local function newSound(parent: Instance, id: string, volume: number, maxDistance: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 8
	s.RollOffMaxDistance = maxDistance
	s.SoundGroup = group
	s.Parent = parent
	return s
end

local function pick(list: { string }): string
	return list[math.random(1, #list)]
end

local function playAt(parent: Instance, id: string, volume: number, maxDistance: number, pitch: number?)
	local s = newSound(parent, id, volume, maxDistance)
	s.PlaybackSpeed = pitch or (0.92 + math.random() * 0.16)
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	task.delay(8, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

function SfxController.start()
	group = Instance.new("SoundGroup")
	group.Name = "NotdAmbience"
	group.Volume = Config.AmbienceVolume
	group.Parent = SoundService
	local camera = workspace.CurrentCamera

	-- Зомби: удар (по счётчику SwingAt), голос по очереди у ближайших
	-- слабые ключи: модели зомби из пула приходят новыми экземплярами, старые не должны копиться
	local nextVoice: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
	local swingSeen: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.4 then
			return
		end
		acc = 0
		camera = workspace.CurrentCamera
		local folder = workspace:FindFirstChild("Zombies")
		if not folder or not camera then
			return
		end
		local now = os.clock()
		local near: { { model: Model, root: BasePart, dist: number } } = {}
		for _, m in folder:GetChildren() do
			if m:IsA("Model") then
				local root = m:FindFirstChild("HumanoidRootPart") :: BasePart? or m.PrimaryPart
				if root then
					local dist = (root.Position - camera.CFrame.Position).Magnitude
					if dist < VOICE_RANGE then
						table.insert(near, { model = m, root = root, dist = dist })
					end
					-- удар зомби: сервер пишет время замаха в атрибут
					local swing = m:GetAttribute("SwingAt")
					if typeof(swing) == "number" and swing ~= swingSeen[m] then
						swingSeen[m] = swing
						if dist < 45 then
							playAt(root, pick(ID.attack), 0.18, 50)
						end
					end
				end
			end
		end
		table.sort(near, function(a, b)
			return a.dist < b.dist
		end)
		for i = 1, math.min(MAX_VOICES, #near) do
			local z = near[i]
			if (nextVoice[z.model] or 0) <= now then
				nextVoice[z.model] = now + 5 + math.random() * 8
				playAt(z.root, pick(if math.random() < 0.3 then ID.walk else ID.growl), 0.14, VOICE_RANGE)
			end
		end
	end)

	-- Смерть зомби: при появлении тела в Corpses
	local function watchCorpses(folder: Instance)
		folder.ChildAdded:Connect(function(c)
			task.defer(function()
				local root = c:FindFirstChild("HumanoidRootPart") :: BasePart? or (c :: any).PrimaryPart
				if root and camera and (root.Position - camera.CFrame.Position).Magnitude < 80 then
					playAt(root, pick(ID.dying), 0.2, 60)
				end
			end)
		end)
	end
	local corpses = workspace:FindFirstChild("Corpses")
	if corpses then
		watchCorpses(corpses)
	else
		workspace.ChildAdded:Connect(function(c)
			if c.Name == "Corpses" then
				watchCorpses(c)
			end
		end)
	end

	-- Моторы машин (кроме грузовика конвоя — у него свой звук на сервере): тихий цикл с высотой тона по скорости
	local engines: { [Model]: Sound } = {}
	task.spawn(function()
		while true do
			task.wait(0.5)
			local cam = workspace.CurrentCamera
			if cam then
				local seen: { [Model]: boolean } = {}
				local vehicles = workspace:FindFirstChild("Vehicles")
				for _, inst in if vehicles then vehicles:GetChildren() else {} do
					if inst:IsA("Model") and inst:GetAttribute("Vehicle") == true then
						local root = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
						if root and (root.Position - cam.CFrame.Position).Magnitude < 110 then
							local occupied = false
							for _, d in inst:GetDescendants() do
								if (d:IsA("Seat") or d:IsA("VehicleSeat")) and d.Occupant then
									occupied = true
									break
								end
							end
							if occupied then
								seen[inst] = true
								local s = engines[inst]
								if not s then
									s = newSound(root, ID.engine, 0.1, 90)
									s.Looped = true
									s:Play()
									engines[inst] = s
								end
								local speed = root.AssemblyLinearVelocity.Magnitude
								s.PlaybackSpeed = 0.75 + math.min(speed / 90, 1) * 0.9
								s.Volume = 0.08 + math.min(speed / 100, 1) * 0.08
							end
						end
					end
				end
				for model, s in engines do
					if not seen[model] then
						s:Destroy()
						engines[model] = nil
					end
				end
			end
		end
	end)

	-- Миссия выполнена / шатёр установлен: короткий сигнал по уведомлению сервера
	local Remotes = require(Shared:WaitForChild("Remotes"))
	Remotes.get("Notify").OnClientEvent:Connect(function(text: string)
		if typeof(text) ~= "string" then
			return
		end
		local cam = workspace.CurrentCamera
		local ui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not ui then
			return
		end
		local id: string? = nil
		if string.find(text, "пройдена") then
			id = ID.mission
		elseif string.find(text, "Шатёр установлен") or string.find(text, "припасы доставлены") then
			id = ID.unlock
		end
		if id and cam then
			local s = Instance.new("Sound")
			s.SoundId = id
			s.Volume = 0.25
			s.SoundGroup = group
			s.Parent = ui
			s.Ended:Once(function()
				s:Destroy()
			end)
			s:Play()
			task.delay(6, function()
				if s.Parent then
					s:Destroy()
				end
			end)
		end
	end)
end

return SfxController
