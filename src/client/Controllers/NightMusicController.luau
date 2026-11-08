--!strict
-- Фон ночи: нагнетающая дорожка, пока идёт фаза Night и игрок не в метро (там свои звуки). Дорожка меняется от ночи к ночи (Config.NightMusic).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local NightMusicController = {}

function NightMusicController.start()
	local C = Config.NightMusic
	local player = Players.LocalPlayer
	local sound = Instance.new("Sound")
	sound.Name = "NightMusic"
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	local active = false
	local fade: Tween? = nil

	local function setActive(on: boolean)
		if on == active then
			return
		end
		active = on
		if on then
			local wave = ReplicatedStorage:GetAttribute("Wave")
			local n = if typeof(wave) == "number" then wave else 1
			sound.SoundId = C.Tracks[(n - 1) % #C.Tracks + 1]
			local group = SoundService:FindFirstChild("NotdAmbience")
			if group and group:IsA("SoundGroup") then
				sound.SoundGroup = group
			end
			sound.TimePosition = 0
			sound:Play()
		end
		if fade then
			fade:Cancel()
		end
		local t = TweenService:Create(sound, TweenInfo.new(if on then C.FadeIn else C.FadeOut), { Volume = if on then C.Volume else 0 })
		fade = t
		t:Play()
		if not on then
			t.Completed:Once(function(state: Enum.PlaybackState)
				if state == Enum.PlaybackState.Completed and not active then
					sound:Stop()
				end
			end)
		end
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local inMetro = root ~= nil and root.Position.Y < Config.Metro.InsideMaxY
			setActive(ReplicatedStorage:GetAttribute("Phase") == "Night" and not inMetro)
		end
	end)
end

return NightMusicController
