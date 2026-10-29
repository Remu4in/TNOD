--!strict
-- Звуки метро: пока игрок на станции (выше Config.Metro.SoundMinY — станция лежит на y ≈ 600), тихо звучат зацикленные фон тоннеля, гул, капли, скрип металла,
-- далёкий поезд и гудение ламп (Config.Metro.Sounds). Выйдет наверх — плавно стихают. Общая громкость — SoundGroup «NotdAmbience» (SfxController), если он есть.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local MetroAmbienceController = {}

function MetroAmbienceController.start()
	local player = Players.LocalPlayer
	local sounds: { { sound: Sound, volume: number } } = {}
	local folder = Instance.new("Folder")
	folder.Name = "MetroAmbience"
	folder.Parent = SoundService
	for _, def in Config.Metro.Sounds do
		local s = Instance.new("Sound")
		s.Name = def.name
		s.SoundId = def.id
		s.Looped = true
		s.Volume = 0
		s.Parent = folder
		table.insert(sounds, { sound = s, volume = def.volume })
	end
	local active = false
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.5 then
			return
		end
		acc = 0
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local inside = root ~= nil and root.Position.Y > Config.Metro.SoundMinY
		if inside == active then
			return
		end
		active = inside
		local group = SoundService:FindFirstChild("NotdAmbience")
		for _, e in sounds do
			if inside then
				if group and group:IsA("SoundGroup") then
					e.sound.SoundGroup = group
				end
				if not e.sound.IsPlaying then
					e.sound:Play()
				end
			end
			local tween = TweenService:Create(e.sound, TweenInfo.new(if inside then 2 else 1.5), { Volume = if inside then e.volume else 0 })
			tween:Play()
			if not inside then
				tween.Completed:Once(function()
					if not active then
						e.sound:Pause()
					end
				end)
			end
		end
	end)
end

return MetroAmbienceController
