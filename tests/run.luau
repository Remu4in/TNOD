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
	for w = 1, 25 do
		for p = 1, 6 do
			local c = WaveMath.composition(Tuning, w, p)
			eq(c.Walker + c.Runner + c.Brute, WaveMath.zombieCount(Tuning, w, p), string.format("волна %d, игроков %d", w, p))
			check(c.Walker >= 0 and c.Runner >= 0, "неотрицательные")
		end
	end
end)

test("очередь спавна: те же типы, боссы в конце", function()
	local c = WaveMath.composition(Tuning, 10, 3)
	local q = WaveMath.spawnQueue(c, FakeRng.new(42) :: any)
	eq(#q, c.Walker + c.Runner + c.Brute, "длина очереди")
	local counts = { Walker = 0, Runner = 0, Brute = 0 }
	for _, t in q do
		counts[t] += 1
	end
	eq(counts.Walker, c.Walker, "ходоки")
	eq(counts.Runner, c.Runner, "бегуны")
	eq(counts.Brute, c.Brute, "громилы")
	for i = #q - c.Brute + 1, #q do
		eq(q[i], "Brute", "босс в конце, позиция " .. i)
	end
end)

print(string.format("\nИТОГО: %d тестов, упало %d", total, failed))
if failed > 0 then
	error("есть упавшие тесты", 0)
end
