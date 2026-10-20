--!strict
-- Юнит-тесты чистой логики (без Roblox): luau tests/run.luau
-- Код выхода 1 при падениях.

local WaveMath = require("../src/shared/WaveMath")

local Tuning = {
	BaseCountPerPlayer = 20,
	GrowthMin = 10,
	GrowthMax = 20,
	PlayerCountFactor = 0.5,
	CapSolo = 250,
	CapPerExtraPlayer = 1 / 3,
	HpGrowthPerWave = 0.15,
	SpeedGrowthPerWave = 0.01,
	SpeedCeil = 18,
	RunnersFromWave = 2,
	RunnerShareMax = 0.4,
	RunnerShareGrowth = 0.08,
	BossEvery = 5,
}

-- Заглушка Random: детерминированный генератор
local FakeRng = {}
FakeRng.__index = FakeRng
function FakeRng.new(seed: number)
	return setmetatable({ s = seed }, FakeRng)
end
function FakeRng.NextInteger(self: any, a: number, b: number): number
	self.s = (self.s * 1103515245 + 12345) % 2147483648
	return a + self.s % (b - a + 1)
end

local total, failed = 0, 0
local function test(name: string, fn: () -> ())
	total += 1
	local ok, err = pcall(fn)
	if ok then
		print("PASS  " .. name)
	else
		failed += 1
		print("FAIL  " .. name .. "\n        - " .. tostring(err))
	end
end
local function eq(a: any, b: any, msg: string)
	if a ~= b then
		error(string.format("%s (ожидали %s, получили %s)", msg, tostring(b), tostring(a)), 2)
	end
end
local function check(c: boolean, msg: string)
	if not c then
		error(msg, 2)
	end
end

local ClassDefs = {
	SMG = { weight = 7, bonusMin = 5, bonusMax = 10 },
	Shotgun = { weight = 7, bonusMin = 5, bonusMax = 10 },
	Rifle = { weight = 15, bonusMin = 10, bonusMax = 20 },
	MG = { weight = 15, bonusMin = 10, bonusMax = 20 },
}
local Tiers = {
	{ min = 0, hp = 1.0, runners = 0, early = 0 },
	{ min = 7, hp = 1.1, runners = 0.05, early = 0 },
	{ min = 15, hp = 1.2, runners = 0.1, early = 1 },
	{ min = 29, hp = 1.35, runners = 0.15, early = 1 },
}
local function threatOf(loadouts: { { string } }, seed: number?)
	return WaveMath.makeThreat(ClassDefs, Tiers, loadouts, seed or 1)
end

test("1-я волна без оружия: 20 на игрока", function()
	for p = 1, 4 do
		eq(WaveMath.zombieCount(Tuning, 1, p), 20 * p, "игроков " .. p)
	end
end)

test("число зомби не убывает с волной", function()
	local prev = 0
	for w = 1, 30 do
		local n = WaveMath.zombieCount(Tuning, w, 1, threatOf({ {} }))
		check(n >= prev, "волна " .. w .. " меньше предыдущей")
		prev = n
	end
end)

test("потолок: соло 250, вчетвером 500, с любым оружием", function()
	local full = { "SMG", "Shotgun", "Rifle", "MG" }
	eq(WaveMath.zombieCount(Tuning, 20, 1, threatOf({ full })), 250, "соло")
	eq(WaveMath.zombieCount(Tuning, 20, 4, threatOf({ full, full, full, full })), 500, "вчетвером")
	for w = 1, 40 do
		check(WaveMath.zombieCount(Tuning, w, 1, threatOf({ full })) <= 250, "соло, волна " .. w)
	end
end)

test("рост по волнам: 10–20 соло, бросок воспроизводим", function()
	for seed = 1, 20 do
		local prev = WaveMath.zombieCount(Tuning, 1, 1, threatOf({ {} }, seed))
		for w = 2, 8 do
			local n = WaveMath.zombieCount(Tuning, w, 1, threatOf({ {} }, seed))
			check(n - prev >= 10 and n - prev <= 20, string.format("seed %d, волна %d: +%d", seed, w, n - prev))
			prev = n
		end
	end
	eq(WaveMath.zombieCount(Tuning, 6, 2, threatOf({ {} }, 7)), WaveMath.zombieCount(Tuning, 6, 2, threatOf({ {} }, 7)), "повтор")
end)

test("больше игроков — больше зомби", function()
	check(WaveMath.zombieCount(Tuning, 3, 4) > WaveMath.zombieCount(Tuning, 3, 1), "4 игрока против 1")
end)

test("0 игроков считается как 1", function()
	eq(WaveMath.zombieCount(Tuning, 2, 0), WaveMath.zombieCount(Tuning, 2, 1), "0 игроков")
end)

test("добавка за оружие: ПП/дробовик 5–10, винтовка/пулемёт 10–20 (соло, волна 1)", function()
	for seed = 1, 30 do
		for class, def in ClassDefs do
			local n = WaveMath.zombieCount(Tuning, 1, 1, threatOf({ { class } }, seed)) - 20
			check(n >= def.bonusMin and n <= def.bonusMax, string.format("%s seed %d: +%d", class, seed, n))
		end
	end
end)

test("класс считается один раз, сколько бы стволов ни было", function()
	eq(WaveMath.zombieCount(Tuning, 1, 1, threatOf({ { "SMG", "SMG", "SMG" } }, 5)), WaveMath.zombieCount(Tuning, 1, 1, threatOf({ { "SMG" } }, 5)), "три ПП = один")
end)

test("уровень угрозы: без оружия 1-й, с винтовкой 3-й, у всех всё — 4-й", function()
	eq(threatOf({ {} }).tier.hp, 1.0, "нет оружия")
	eq(threatOf({ { "SMG" } }).tier.hp, 1.1, "ПП")
	eq(threatOf({ { "Rifle" } }).tier.hp, 1.2, "винтовка")
	eq(threatOf({ { "SMG", "Shotgun", "Rifle", "MG" } }).tier.hp, 1.35, "всё")
	eq(threatOf({ { "Rifle" }, {} }).tier.hp, 1.1, "у одного из двух: среднее 7,5")
end)

test("HP и скорость: рост по волне, скорость не выше потолка", function()
	check(WaveMath.hpMultiplier(Tuning, 5, threatOf({ { "Rifle" } })) > WaveMath.hpMultiplier(Tuning, 5), "оружие повышает HP")
	for w = 1, 40 do
		check(WaveMath.speedOf(Tuning, 14, w) <= 18, "ходок на волне " .. w)
		check(WaveMath.speedOf(Tuning, 14, w) >= 14, "не медленнее базы")
	end
	eq(WaveMath.speedOf(Tuning, 19, 30), 19, "бегун быстрее потолка не замедляется")
end)

test("множитель HP: волна 1 = 1, растёт", function()
	eq(WaveMath.hpMultiplier(Tuning, 1), 1, "волна 1")
	check(WaveMath.hpMultiplier(Tuning, 10) > WaveMath.hpMultiplier(Tuning, 9), "рост")
end)

test("бегунов нет до RunnersFromWave, доля не выше максимума", function()
	eq(WaveMath.runnerShare(Tuning, 1), 0, "волна 1")
	check(WaveMath.runnerShare(Tuning, 2) > 0, "волна 2")
	for w = 1, 50 do
		check(WaveMath.runnerShare(Tuning, w) <= Tuning.RunnerShareMax + 1e-9, "максимум на волне " .. w)
	end
end)

test("боссы только на каждой 5-й волне", function()
	for w = 1, 20 do
		local isBoss = w % 5 == 0
		eq(WaveMath.isBossWave(Tuning, w), isBoss, "волна " .. w)
		eq(WaveMath.bossCount(Tuning, w) > 0, isBoss, "число боссов на волне " .. w)
	end
end)

test("состав в сумме равен числу зомби", function()
	for w = 1, 40 do
		for p = 1, 6 do
			local threat = threatOf({ { "SMG", "Rifle" } }, w * 3 + p)
			local c = WaveMath.composition(Tuning, w, p, threat)
			eq(WaveMath.total(c), WaveMath.zombieCount(Tuning, w, p, threat), string.format("волна %d, игроков %d", w, p))
			for id, n in c do
				check(n > 0, "неположительное число " .. id)
			end
		end
	end
end)

test("10-я волна: все обычные — бронированные, боссы Гаргантюа и Повелитель тёмных", function()
	local c = WaveMath.composition(Tuning, 10, 3)
	eq(c.Walker, nil, "нет ходоков")
	eq(c.Runner, nil, "нет бегунов")
	eq(c.Military, nil, "нет военных")
	check((c.BucketHead or 0) > 0, "есть бронированные")
	eq(c.BossGarg, 1, "Гаргантюа")
	eq(c.BossStrong, 1, "Повелитель тёмных")
end)

test("военные с 11-й: 2–4 штуки, до 11-й нет", function()
	for w = 1, 10 do
		eq(WaveMath.composition(Tuning, w, 2).Military, nil, "волна " .. w)
	end
	for w = 11, 19 do
		local n = WaveMath.composition(Tuning, w, 2).Military or 0
		check(n >= 2 and n <= 4, "волна " .. w .. ": " .. n)
	end
end)

test("20-я волна: военные — основная группа", function()
	local c = WaveMath.composition(Tuning, 20, 2)
	check((c.Military or 0) >= WaveMath.total(c) * 0.4, "военных мало")
end)

test("тёмные вместо бегунов на 11–15", function()
	for w = 11, 15 do
		local c = WaveMath.composition(Tuning, w, 2)
		eq(c.Runner, nil, "бегунов нет на волне " .. w)
		check((c.Dark or 0) > 0, "тёмные на волне " .. w)
	end
	check(WaveMath.composition(Tuning, 16, 2).Dark == nil, "после 15-й тёмных нет")
	check(WaveMath.composition(Tuning, 10, 2).Dark == nil, "до 11-й тёмных нет")
end)

test("боссы по кругу: 5 — Качок, 10 — Гаргантюа, 15 — Повелитель тёмных", function()
	eq(WaveMath.bossTypes(Tuning, 5)[1], "BossBuff", "5")
	eq(WaveMath.bossTypes(Tuning, 10)[1], "BossGarg", "10")
	eq(WaveMath.bossTypes(Tuning, 15)[1], "BossStrong", "15")
	eq(#WaveMath.bossTypes(Tuning, 7), 0, "7 — без босса")
end)

test("особые зомби появляются по расписанию", function()
	eq(WaveMath.composition(Tuning, 5, 1).Chemist, nil, "химик до 7-й")
	check((WaveMath.composition(Tuning, 9, 1).Chemist or 0) > 0, "химик на 9-й")
	check((WaveMath.composition(Tuning, 8, 1).Crawler or 0) > 0, "ползуны на 8-й")
end)

test("очередь спавна: те же типы, боссы в конце", function()
	local c = WaveMath.composition(Tuning, 15, 3)
	local q = WaveMath.spawnQueue(c, FakeRng.new(42) :: any)
	eq(#q, WaveMath.total(c), "длина очереди")
	local counts: { [string]: number } = {}
	for _, t in q do
		counts[t] = (counts[t] or 0) + 1
	end
	for id, n in c do
		eq(counts[id], n, "тип " .. id)
	end
	local bosses = 0
	for id, n in c do
		if WaveMath.isBossType(id) then
			bosses += n
		end
	end
	for i = #q - bosses + 1, #q do
		check(WaveMath.isBossType(q[i]), "босс в конце, позиция " .. i)
	end
	for i = 1, #q - bosses do
		check(not WaveMath.isBossType(q[i]), "обычный в начале, позиция " .. i)
	end
end)

print(string.format("\nИТОГО: %d тестов, упало %d", total, failed))
if failed > 0 then
	error("есть упавшие тесты", 0)
end
