--!strict
-- Точка входа клиента.
-- Сервер в атрибуте Mode говорит, лобби это или матч: игровые контроллеры запускаются, только когда начался матч.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Controllers = script:WaitForChild("Controllers")
require(Controllers:WaitForChild("LookController")).start() -- свет и цветокоррекция по фазам (и в лобби, и в матче)
require(Controllers:WaitForChild("CursorController")).start() -- убирает значок мыши из центра экрана (и в лобби, и в матче)
require(Controllers:WaitForChild("LobbyController")).start() -- лобби и экран итогов
require(Controllers:WaitForChild("StoreController")).start() -- донатный магазин: и в лобби, и в матче

local started = false
local function startGame()
	if started then
		return
	end
	started = true
	require(Controllers:WaitForChild("HUDController")).start()
	require(Controllers:WaitForChild("WeaponController")).start()
	require(Controllers:WaitForChild("EffectsController")).start()
	require(Controllers:WaitForChild("ViewModelController")).start()
	require(Controllers:WaitForChild("ArmsController")).start()
	require(Controllers:WaitForChild("MovementController")).start()
	require(Controllers:WaitForChild("FxController")).start()
	require(Controllers:WaitForChild("VehicleController")).start()
	require(Controllers:WaitForChild("ShopController")).start()
	require(Controllers:WaitForChild("VoteController")).start()
	require(Controllers:WaitForChild("InfoController")).start()
	require(Controllers:WaitForChild("EmoteController")).start()
	require(Controllers:WaitForChild("EquipController")).start()
	require(Controllers:WaitForChild("TurretController")).start()
	require(Controllers:WaitForChild("PerkController")).start()
	require(Controllers:WaitForChild("ZombieMarkerController")).start()
	require(Controllers:WaitForChild("MissionController")).start()
	require(Controllers:WaitForChild("BriefingController")).start()
	require(Controllers:WaitForChild("DayBriefController")).start()
	require(Controllers:WaitForChild("StatusController")).start()
	require(Controllers:WaitForChild("MetroAmbienceController")).start()
	require(Controllers:WaitForChild("NightMusicController")).start()
	require(Controllers:WaitForChild("MetroLightController")).start()
	require(Controllers:WaitForChild("NightLightsController")).start()
	require(Controllers:WaitForChild("SfxController")).start()
	require(Controllers:WaitForChild("TestStandController")).start()
	require(Controllers:WaitForChild("BossBarController")).start()
	require(Controllers:WaitForChild("SquadController")).start()
	require(Controllers:WaitForChild("SpectateController")).start()
	require(Controllers:WaitForChild("CutsceneController")).start()
end

-- режим выставляется сервером в первые секунды; нет атрибута (старый сервер, режим осмотра) — играем как раньше
if ReplicatedStorage:GetAttribute("Mode") == nil then
	local waited = 0
	while ReplicatedStorage:GetAttribute("Mode") == nil and waited < 10 do
		waited += task.wait(0.1)
	end
end
if ReplicatedStorage:GetAttribute("Mode") ~= "lobby" then
	startGame()
end
ReplicatedStorage:GetAttributeChangedSignal("Mode"):Connect(function()
	if ReplicatedStorage:GetAttribute("Mode") ~= "lobby" then
		startGame()
	end
end)
