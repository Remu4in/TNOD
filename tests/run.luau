--!strict
-- Юнит-тесты чистой логики (без Roblox): luau tests/run.luau
-- Код выхода 1 при падениях.

local WaveMath = require("../src/shared/WaveMath")

local Tuning = {
	BaseCount = 6,
	CountPerWave = 3,
	PlayerCountFactor = 0.5,
	HpGrowthPerWave = 0.15,
	RunnersFromWave = 3,
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

test("число зомби растёт с волной", function()
	local prev = 0
	for w = 1, 30 do
		local n = WaveMath.zombieCount(Tuning, w, 1)
		check(n > prev, "волна " .. w .. " не больше предыдущей")
		prev = n
	end
end)

test("первая волна соло = BaseCount", function()
	eq(WaveMath.zombieCount(Tuning, 1, 1), 6, "волна 1")
end)

test("больше игроков — больше зомби", function()
	check(WaveMath.zombieCount(Tuning, 3, 4) > WaveMath.zombieCount(Tuning, 3, 1), "4 игрока против 1")
end)

test("0 игроков считается как 1", function()
	eq(WaveMath.zombieCount(Tuning, 2, 0), WaveMath.zombieCount(Tuning, 2, 1), "0 игроков")
end)

test("множитель HP: волна 1 = 1, растёт", function()
	eq(WaveMath.hpMultiplier(Tuning, 1), 1, "волна 1")
	check(WaveMath.hpMultiplier(Tuning, 10) > WaveMath.hpMultiplier(Tuning, 9), "рост")
end)

test("бегунов нет до RunnersFromWave, доля не выше максимума", function()
	eq(WaveMath.runnerShare(Tuning, 2), 0, "волна 2")
	check(WaveMath.runnerShare(Tuning, 3) > 0, "волна 3")
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
			local c = WaveMath.composition(Tuning, w, p)
			eq(WaveMath.total(c), WaveMath.zombieCount(Tuning, w, p), string.format("волна %d, игроков %d", w, p))
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
