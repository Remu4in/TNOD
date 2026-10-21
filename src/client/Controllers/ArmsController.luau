--!strict
-- Руки от 1 лица и анимации оружия: показываем свои руки, держим ствол в стойке прицеливания,
-- на перезарядке проигрываем официальную анимацию Roblox (Weapons Kit), растянутую на время перезарядки.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Perks = require(Shared:WaitForChild("Perks"))
local ViewModel = require(script.Parent:WaitForChild("ViewModelController"))

local ArmsController = {}

local player = Players.LocalPlayer

local ARM_PARTS = { "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperArm", "LeftLowerArm", "LeftHand" }
local AIM_MIN_ANGLE, AIM_MAX_ANGLE = -80, 80 -- диапазон наклона, который покрывает RifleAim (2 секунды)

local trackOwner: Animator? = nil
local aimTrack: AnimationTrack? = nil
local reloadTrack: AnimationTrack? = nil

local function currentAnimator(): Animator?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum and hum:FindFirstChildOfClass("Animator")
end

local function loadTrack(animator: Animator, id: string, priority: Enum.AnimationPriority, looped: boolean): AnimationTrack
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track.Priority = priority
	track.Looped = looped
	return track
end

-- Треки привязаны к Animator конкретного персонажа: после возрождения грузим заново.
local function ensureTracks(): Animator?
	local animator = currentAnimator()
	if animator and animator ~= trackOwner then
		trackOwner = animator
		aimTrack = loadTrack(animator, Config.Animations.aim, Enum.AnimationPriority.Action, true)
		reloadTrack = loadTrack(animator, Config.Animations.reload, Enum.AnimationPriority.Action2, false)
	end
	return animator
end

local function heldWeapon(): Tool?
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	-- стойка «ствол в руках» только для огнестрела; нож и бита держатся стандартной позой Roblox
	if tool and tool:GetAttribute("WeaponId") and tool:GetAttribute("Melee") ~= true then
		return tool
	end
	return nil
end

function ArmsController.start()
	-- руки видны от 1 лица (камера по умолчанию их прячет), а поза оружия следует за взглядом
	RunService:BindToRenderStep("NotdArms", Enum.RenderPriority.Camera.Value + 1, function()
		local char = player.Character
		if not char then
			return
		end
		-- пока работает viewmodel (руки и оружие в кадре), настоящие руки и Tool себе прячем
		local vm = ViewModel.active()
		for _, name in ARM_PARTS do
			local part = char:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				part.LocalTransparencyModifier = if vm then 1 else 0
			end
		end
		local held = char:FindFirstChildOfClass("Tool")
		if held then
			for _, d in held:GetChildren() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = if vm then 1 else 0
				end
			end
		end
		-- RifleAim — не обычная анимация, а «шкала наклона» (как в Weapons Kit): время кадра = угол взгляда
		-- от -80° (0 с) до +80° (2 с). Крутим её не по времени, а по высоте камеры, иначе руки ходят вверх-вниз.
		local aim = aimTrack
		local camera = workspace.CurrentCamera
		if aim and aim.IsPlaying and camera then
			local pitchDeg = math.deg(math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1)))
			local t = 2 * ((pitchDeg - AIM_MIN_ANGLE) / (AIM_MAX_ANGLE - AIM_MIN_ANGLE))
			aim:AdjustSpeed(0.001)
			aim.TimePosition = math.clamp(t, 0.001, 1.97)
		end
	end)

	-- стойка с оружием, пока оно в руках
	task.spawn(function()
		while true do
			task.wait(0.15)
			if ensureTracks() then
				local aim = aimTrack
				if aim then
					local holding = heldWeapon() ~= nil and not player:GetAttribute("Downed")
					if holding and not aim.IsPlaying then
						aim:Play(0.15)
					elseif not holding and aim.IsPlaying then
						aim:Stop(0.15)
					end
				end
			end
		end
	end)

	-- перезарядка: официальная анимация на время перезарядки данного оружия
	Remotes.get("ReloadFx").OnClientEvent:Connect(function(who: Player, weaponId: string)
		if who ~= player or not ensureTracks() then
			return
		end
		local track = reloadTrack
		local def = Config.Weapons[weaponId]
		if not track or not def then
			return
		end
		local reloadSeconds = def.reloadTime * (1 - math.min(0.7, Perks.total("reload")))
		ViewModel.reload(reloadSeconds)
		track:Play(0.1)
		local length = track.Length
		if length > 0 then
			track:AdjustSpeed(length / reloadSeconds)
		end
	end)
end

return ArmsController
