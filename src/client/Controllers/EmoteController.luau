--!strict
-- Эмоции: быстрые клавиши (Z — помахать, X — ура, T — танец) и камера от третьего лица на время эмоции. Эмоция запускается через BindableFunction PlayEmote
-- стандартного скрипта Animate (Humanoid:PlayEmote здесь не годится: он знает только эмоции из HumanoidDescription, у наших персонажей их нет).
-- Игра идёт от первого лица (StarterPlayer.CameraMode = LockFirstPerson, зум 0,5): в нём эмоцию игрок не видит. Пока проигрывается эмоция (любая стандартная
-- эмоция Animate), камера переключается в Classic и отодвигается; когда эмоция кончилась или игрок пошёл,
-- возвращаются прежние режим и зум. Эмоцию определяем по анимации: её Animation лежит в папке Animate-эмоций (wave, point, dance, dance2, dance3, laugh, cheer).
-- Сервер не участвует: анимацию персонажа игрока воспроизводит клиент и она реплицируется как обычно (Humanoid:PlayEmote).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local EmoteController = {}

local EMOTES: { [string]: boolean } = { wave = true, point = true, dance = true, dance2 = true, dance3 = true, laugh = true, cheer = true }
local QUICK: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Z] = "wave",
	[Enum.KeyCode.X] = "cheer",
	[Enum.KeyCode.T] = "dance",
}
local THIRD_DISTANCE = 11 -- студов от персонажа в третьем лице

function EmoteController.start()
	local player = Players.LocalPlayer
	local saved: { mode: Enum.CameraMode, minZoom: number, maxZoom: number }? = nil
	local playing = 0 -- сколько эмоций сейчас идёт (обычно одна)

	local function enterThird()
		if not saved then
			saved = { mode = player.CameraMode, minZoom = player.CameraMinZoomDistance, maxZoom = player.CameraMaxZoomDistance }
		end
		player.CameraMode = Enum.CameraMode.Classic
		player.CameraMaxZoomDistance = math.max(THIRD_DISTANCE, 12)
		player.CameraMinZoomDistance = THIRD_DISTANCE
	end
	local function leaveThird()
		local s = saved
		if s then
			saved = nil
			player.CameraMinZoomDistance = s.minZoom
			player.CameraMaxZoomDistance = s.maxZoom
			player.CameraMode = s.mode
		end
	end

	local function watch(char: Model)
		local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
		if not hum then
			return
		end
		local animator = hum:WaitForChild("Animator", 10) :: Animator?
		if not animator then
			return
		end
		animator.AnimationPlayed:Connect(function(track: AnimationTrack)
			local anim = track.Animation
			local folder = anim and anim.Parent
			if folder and EMOTES[folder.Name] then
				playing += 1
				enterThird()
				track.Stopped:Once(function()
					playing = math.max(0, playing - 1)
					if playing == 0 then
						leaveThird()
					end
				end)
			end
		end)
		hum.Died:Once(function()
			playing = 0
			leaveThird()
		end)
	end
	if player.Character then
		task.spawn(watch, player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		playing = 0
		leaveThird()
		watch(char)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		local name = QUICK[input.KeyCode]
		if not name then
			return
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local animate = char and char:FindFirstChild("Animate")
		local play = animate and animate:FindFirstChild("PlayEmote")
		if hum and hum.Health > 0 and not hum.SeatPart and player:GetAttribute("Downed") ~= true and play and play:IsA("BindableFunction") then
			task.spawn(function()
				pcall(function()
					play:Invoke(name)
				end)
			end)
		end
	end)
end

return EmoteController
