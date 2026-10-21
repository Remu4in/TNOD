--!strict
-- Юнит-тесты чистой логики (без Roblox): luau tests/run.luau
-- Код выхода 1 при падениях.

local WaveMath = require("../src/shared/WaveMath")

local Tuning = {
	StartCounts = { 20, 30, 35, 40 },
	StartPerExtraPlayer = 4,
	CurveWaves = 20,
	CurveExp = 1.25,
	JitterPct = 10,
	CapSolo = 250,
	CapPerExtraPlayer = 1 / 3,
	HpGrowthPerWave = 0.12,
	DamageGrowthPerWave = 0.03,
	SpeedGrowthPerWave = 0.01,
	SpeedCeil = 18,
	BossEvery = 5,
}

local Economy = {
	WaveRewardBase = 350,
	WaveRewardPerWave = 25,
	KillPoolBase = 440,
	KillPoolPerWave = 33,
	KillBodyShare = 0.4,
	KillWeights = { Walker = 1, Runner = 1.2, Crawler = 0.8, Dark = 2, BucketHead = 2.5, Military = 3, Chemist = 3, Brute = 6 },
	BossKillWeight = 40,
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

test("1-я волна без оружия: 20 / 30 / 35 / 40", function()
	local want = { 20, 30, 35, 40 }
	for p = 1, 4 do
		eq(WaveMath.zombieCount(Tuning, 1, p), want[p], "игроков " .. p)
	end
	eq(WaveMath.zombieCount(Tuning, 1, 5), 44, "5 игроков")
end)

test("кривая не убывает, начинается со старта и кончается потолком", function()
	for p = 1, 6 do
		local prev = 0
		for w = 1, 30 do
			local n = WaveMath.curveCount(Tuning, w, p)
			check(n >= prev - 1e-9, string.format("игроков %d, волна %d", p, w))
			prev = n
		end
	end
	eq(WaveMath.curveCount(Tuning, 20, 1), 250, "соло, 20-я")
	eq(math.floor(WaveMath.curveCount(Tuning, 20, 4) + 0.5), 500, "вчетвером, 20-я")
end)

test("число зомби: в пределах ±10% от кривой (без оружия), не выше потолка", function()
	for seed = 1, 30 do
		for w = 2, 25 do
			for _, p in { 1, 2, 4 } do
				local n = WaveMath.zombieCount(Tuning, w, p, threatOf({ {} }, seed))
				local curve = WaveMath.curveCount(Tuning, w, p)
				check(n >= math.floor(curve * 0.9), string.format("seed %d w %d p %d: %d < 90%% от %.1f", seed, w, p, n, curve))
				check(n <= math.min(math.ceil(curve * 1.1), 250 * (1 + (p - 1) / 3)) + 1, string.format("seed %d w %d p %d: %d", seed, w, p, n))
			end
		end
	end
end)

test("потолок: соло 250, вчетвером 500, с любым оружием", function()
	local full = { "SMG", "Shotgun", "Rifle", "MG" }
	for w = 1, 40 do
		check(WaveMath.zombieCount(Tuning, w, 1, threatOf({ full })) <= 250, "соло, волна " .. w)
		check(WaveMath.zombieCount(Tuning, w, 4, threatOf({ full, full, full, full })) <= 500, "вчетвером, волна " .. w)
	end
	eq(WaveMath.zombieCount(Tuning, 25, 1, threatOf({ full })), 250, "соло, поздняя волна")
end)

test("бросок воспроизводим", function()
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
		local n = WaveMath.composition(Tuning, w, 1).Military or 0
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

test("состав по плану: 1-я — одни ходоки, 2-я — бегуны со 2-й", function()
	local c1 = WaveMath.composition(Tuning, 1, 1)
	eq(c1.Walker, 20, "1-я: только ходоки")
	check(WaveMath.composition(Tuning, 2, 1).Runner ~= nil, "бегуны на 2-й")
end)

test("особые в команде растут вместе с волной", function()
	check((WaveMath.composition(Tuning, 12, 4).Brute or 0) > (WaveMath.composition(Tuning, 12, 1).Brute or 0), "громил больше у команды")
end)

test("уровень угрозы 3+ приближает особых на волну", function()
	local threat = threatOf({ { "Rifle" } }, 3)
	check((WaveMath.composition(Tuning, 5, 1, threat).Brute or 0) == 0 or true, "волна 5 допускает")
	check((WaveMath.composition(Tuning, 5, 1, threat).Brute or 0) > 0, "громилы уже на 5-й при винтовке")
	eq(WaveMath.composition(Tuning, 5, 1).Brute, nil, "без оружия — нет")
end)

test("урон зомби +3% за волну", function()
	eq(WaveMath.damageMultiplier(Tuning, 1), 1, "волна 1")
	check(math.abs(WaveMath.damageMultiplier(Tuning, 11) - 1.3) < 1e-9, "волна 11 = 1,3")
end)

local function cumulative(upTo: number, headShare: number): number
	local sum = 0
	for w = 1, upTo do
		local comp = WaveMath.composition(Tuning, w, 1)
		local units = WaveMath.killUnits(Economy, w, comp)
		local pool = 0
		for id, n in comp do
			pool += units[id] * n * (headShare + (1 - headShare) * Economy.KillBodyShare)
		end
		sum += WaveMath.waveReward(Economy, w) + pool
	end
	return sum
end

test("экономика: сумма единиц за убийство равна пулу волны", function()
	for w = 1, 20 do
		local comp = WaveMath.composition(Tuning, w, 3)
		local units = WaveMath.killUnits(Economy, w, comp)
		local sum = 0
		for id, n in comp do
			sum += units[id] * n
		end
		check(math.abs(sum - WaveMath.killPool(Economy, w)) < 1e-6, "волна " .. w)
	end
end)

test("экономика: к 16-й без хедшотов ≈13,6 тыс., только хедшоты ≈20,5 тыс.", function()
	local low, high = cumulative(16, 0), cumulative(16, 1)
	check(low > 13000 and low < 14200, "минимум " .. low)
	check(high > 20000 and high < 21000, "максимум " .. high)
	check(cumulative(19, 0) > 14500 and cumulative(17, 0) < 16000, "все здания (14,5 тыс.) в минимуме — около 16–18-й")
end)

test("экономика: за волну не зависит от размера толпы", function()
	local a = WaveMath.killUnits(Economy, 10, WaveMath.composition(Tuning, 10, 1))
	local b = WaveMath.killUnits(Economy, 10, WaveMath.composition(Tuning, 10, 4))
	local sa, sb = 0, 0
	for id, n in WaveMath.composition(Tuning, 10, 1) do
		sa += a[id] * n
	end
	for id, n in WaveMath.composition(Tuning, 10, 4) do
		sb += b[id] * n
	end
	check(math.abs(sa - sb) < 1e-6, "пул одинаков для 1 и 4 игроков")
end)

print(string.format("\nИТОГО: %d тестов, упало %d", total, failed))
if failed > 0 then
	error("есть упавшие тесты", 0)
end
