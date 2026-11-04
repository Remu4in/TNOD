--!nocheck
-- Страж релиза и согласованности Config. Запуск: Studio (Edit) → execute_luau, ничего не меняет в месте.
-- Печатает список проблем и возвращает их число (0 — можно выпускать). Проверяет:
--   релизные флаги (TestStands, Waves.CountScale, DebugStartNight, Explore, Convoy.TruckSpeed, MissionKillsFloor);
--   ShopList ↔ Weapons, WeaponAim ↔ Weapons, MeleeFx ↔ MeleeAnim, типы зомби в волнах ↔ Zombies, уникальность имён в Remotes.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MeleeAnim = require(Shared:WaitForChild("MeleeAnim"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))

local problems: { string } = {}
local function problem(text: string)
	table.insert(problems, text)
end

-- 1. Релизные флаги
if Config.TestStands then
	problem("Config.TestStands = true: тестовые стенды включены (в релизе должно быть false)")
end
local scale = Config.Waves.CountScale
if scale ~= nil and scale ~= 1 then
	problem("Config.Waves.CountScale = " .. tostring(scale) .. " (в релизе nil или 1)")
end
if Config.DebugStartNight ~= 1 then
	problem("Config.DebugStartNight = " .. tostring(Config.DebugStartNight) .. " (в релизе 1)")
end
if Config.Explore then
	problem("Config.Explore = true: режим осмотра включён (в релизе false)")
end
-- тестовые настройки прохождения всех ночей (decisions.md, 2026-10-24): конвой быстрее, нижняя граница убийств ниже
-- скорости конвоев — баланс v3 (2026-11): по умолчанию 11, у ночей до 13; выше — явно тестовое значение
if Config.Convoy.TruckSpeed > 13 then
	problem("Config.Convoy.TruckSpeed = " .. tostring(Config.Convoy.TruckSpeed) .. " (больше 13 студов/с — тестовое значение; релизное по умолчанию 11)")
end
for night, def in Config.Missions do
	if def.convoySpeed and def.convoySpeed > 13 then
		problem(string.format("Config.Missions[%d].convoySpeed = %s (больше 13 студов/с)", night, tostring(def.convoySpeed)))
	end
end
if (Config.MissionKillsFloor or 5) < 5 then
	problem("Config.MissionKillsFloor = " .. tostring(Config.MissionKillsFloor) .. " (тест; в релизе 5)")
end

-- Лобби: ForceMode и StudioSkipTeleport работают только в Studio (LobbyService проверяет RunService:IsStudio()), но в релизной сборке им делать нечего
local lobby = Config.Lobby
if not lobby.Enabled then
	problem("Config.Lobby.Enabled = false: лобби выключено (в релизе true — игроки сразу попадают в раунд)")
end
if lobby.ForceMode ~= nil then
	problem("Config.Lobby.ForceMode = " .. tostring(lobby.ForceMode) .. " (тест; в релизе nil; на живом сервере всё равно игнорируется)")
end
if lobby.ZoneMaxSize < 1 or lobby.ZoneMaxSize > 6 then
	problem("Config.Lobby.ZoneMaxSize = " .. tostring(lobby.ZoneMaxSize) .. " (игра рассчитана на 1–6 игроков)")
end
if lobby.TeleportAttempts < 1 or lobby.ZoneCountdown <= 0 then
	problem("Config.Lobby: TeleportAttempts < 1 или ZoneCountdown <= 0 (зона не сможет стартовать)")
end
if lobby.StudioSkipTeleport then
	print("[ReleaseCheck] Config.Lobby.StudioSkipTeleport = true: действует только в Studio (на живом сервере телепорт настоящий) — это нормально")
end

-- Баланс v3 (2026-11): здоровье зомби не растёт, монет за убийства нет, прогрессия — числом
if Config.Waves.HpGrowthPerWave ~= 0 then
	problem("Config.Waves.HpGrowthPerWave = " .. tostring(Config.Waves.HpGrowthPerWave) .. " (должно быть 0: здоровье зомби не растёт по волнам)")
end
for i, tier in Config.Threat.Tiers do
	if tier.hp ~= 1 then
		problem(string.format("Config.Threat.Tiers[%d].hp = %s (должно быть 1: уровень угрозы не меняет здоровье)", i, tostring(tier.hp)))
	end
end
if Config.Economy.CoinsPerHit ~= 0 or Config.Economy.CoinsPerPlankRepair ~= 0 then
	problem("Config.Economy.CoinsPerHit / CoinsPerPlankRepair не 0: монеты только за миссии, за попадания, убийства и ремонт монет нет")
end
for key in Config.Economy do
	if string.sub(key, 1, 4) == "Kill" or string.find(key, "KillCoins", 1, true) or key == "BossKillWeight" then
		problem("Config.Economy." .. key .. ": монеты за убийства отменены (убийства дают только очки)")
	end
end
-- число ночей с записью о длине и их суммарная длина (цель — 20 ночей за 40–50 минут вместе с днями)
if Config.Round.NightDefaultTime < 120 then
	problem("Config.Round.NightDefaultTime = " .. tostring(Config.Round.NightDefaultTime) .. " (меньше двух минут: миссии не успеют)")
end
if Config.Round.AliveHardCap > 150 then
	problem("Config.Round.AliveHardCap = " .. tostring(Config.Round.AliveHardCap) .. " (больше 150 одновременно живых — риск для производительности сервера)")
end

-- 2. Магазин и оружие
for i, item in Config.ShopList do
	if not Config.Weapons[item.id] then
		problem(string.format("ShopList[%d].id = %s: нет в Config.Weapons", i, tostring(item.id)))
	end
end
for id in Config.WeaponAim do
	if not Config.Weapons[id] then
		problem("WeaponAim[" .. id .. "]: нет в Config.Weapons")
	end
end

-- 3. Взмахи холодного оружия
for id, fx in Config.MeleeFx do
	if not MeleeAnim.STYLES[fx.style] then
		problem(string.format("MeleeFx[%s].style = %s: нет в MeleeAnim.STYLES", id, tostring(fx.style)))
	end
	if not MeleeAnim.HIT[fx.style] then
		problem(string.format("MeleeFx[%s].style = %s: нет в MeleeAnim.HIT", id, tostring(fx.style)))
	end
end

-- 4. Типы зомби из волн (состав берём у WaveMath.composition: волны 1–40, 1–6 игроков)
local missingZombie: { [string]: boolean } = {}
for wave = 1, 40 do
	for players = 1, 6 do
		for id in WaveMath.composition(Config.Waves, wave, players) do
			if not Config.Zombies[id] and not missingZombie[id] then
				missingZombie[id] = true
				problem(string.format("волна %d: тип зомби %s есть в составе, но нет в Config.Zombies", wave, id))
			end
		end
	end
end

-- 5. Имена в Remotes: NAMES — локальная переменная модуля, поэтому читаем исходник
local remotes = Shared:FindFirstChild("Remotes")
if remotes and remotes:IsA("ModuleScript") then
	local seen: { [string]: boolean } = {}
	for line in string.gmatch(remotes.Source, "[^\n]+") do
		local name = string.match(line, '^%s*"(%w+)",')
		if name then
			if seen[name] then
				problem("Remotes.NAMES: имя " .. name .. " объявлено дважды")
			end
			seen[name] = true
		end
	end
else
	print("[ReleaseCheck] Remotes: исходник недоступен, проверка уникальности имён пропущена")
end

if #problems == 0 then
	print("[ReleaseCheck] проблем нет")
else
	print(string.format("[ReleaseCheck] проблем: %d", #problems))
	for i, text in problems do
		print(string.format("  %d. %s", i, text))
	end
end
return #problems
