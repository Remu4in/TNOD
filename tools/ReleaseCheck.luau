--!nocheck
-- Страж релиза и согласованности Config. Запуск: Studio (Edit) → execute_luau, ничего не меняет в месте.
-- Печатает список проблем и возвращает их число (0 — можно выпускать). Проверяет:
--   релизные флаги (TestStands, Waves.CountScale, DebugStartNight, Explore);
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
