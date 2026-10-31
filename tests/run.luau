--!strict
-- Юнит-тесты чистой логики (без Roblox): luau tests/run.luau
-- Код выхода 1 при падениях.

local WaveMath = require("../src/shared/WaveMath")
local Ballistics = require("../src/shared/Ballistics")
local RateLimit = require("../src/shared/RateLimit")
local Rewind = require("../src/shared/Rewind")
local LobbyRules = require("../src/shared/LobbyRules")

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
	MissionPersonalTotal = 3413,
	MissionTeamTotal = 13050,
	MissionGrowth = 0.18,
	MissionRewardWaves = 15,
	KillCapMin = 200,
	KillCapMax = 300,
	KillCapWaves = 15,
	KillPoolShare = 0.35,
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
		error(string.format("%s (expected %s, got %s)", msg, tostring(b), tostring(a)), 2)
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

test("wave 1 without weapons: 20 / 30 / 35 / 40", function()
	local want = { 20, 30, 35, 40 }
	for p = 1, 4 do
		eq(WaveMath.zombieCount(Tuning, 1, p), want[p], "players " .. p)
	end
	eq(WaveMath.zombieCount(Tuning, 1, 5), 44, "5 players")
end)

test("the curve doesn't decrease, starts at the start and ends at the cap", function()
	for p = 1, 6 do
		local prev = 0
		for w = 1, 30 do
			local n = WaveMath.curveCount(Tuning, w, p)
			check(n >= prev - 1e-9, string.format("players %d, wave %d", p, w))
			prev = n
		end
	end
	eq(WaveMath.curveCount(Tuning, 20, 1), 250, "solo, 20th")
	eq(math.floor(WaveMath.curveCount(Tuning, 20, 4) + 0.5), 500, "four players, 20th")
end)

test("zombie count: within ±10% of the curve (no weapons), not above the cap", function()
	for seed = 1, 30 do
		for w = 2, 25 do
			for _, p in { 1, 2, 4 } do
				local n = WaveMath.zombieCount(Tuning, w, p, threatOf({ {} }, seed))
				local curve = WaveMath.curveCount(Tuning, w, p)
				check(n >= math.floor(curve * 0.9), string.format("seed %d w %d p %d: %d < 90%% of %.1f", seed, w, p, n, curve))
				check(n <= math.min(math.ceil(curve * 1.1), 250 * (1 + (p - 1) / 3)) + 1, string.format("seed %d w %d p %d: %d", seed, w, p, n))
			end
		end
	end
end)

test("cap: solo 250, four players 500, with any weapon", function()
	local full = { "SMG", "Shotgun", "Rifle", "MG" }
	for w = 1, 40 do
		check(WaveMath.zombieCount(Tuning, w, 1, threatOf({ full })) <= 250, "solo, wave " .. w)
		check(WaveMath.zombieCount(Tuning, w, 4, threatOf({ full, full, full, full })) <= 500, "four players, wave " .. w)
	end
	eq(WaveMath.zombieCount(Tuning, 25, 1, threatOf({ full })), 250, "solo, late wave")
end)

test("the roll is reproducible", function()
	eq(WaveMath.zombieCount(Tuning, 6, 2, threatOf({ {} }, 7)), WaveMath.zombieCount(Tuning, 6, 2, threatOf({ {} }, 7)), "repeat")
end)

test("more players — more zombies", function()
	check(WaveMath.zombieCount(Tuning, 3, 4) > WaveMath.zombieCount(Tuning, 3, 1), "4 players against 1")
end)

test("0 players counts as 1", function()
	eq(WaveMath.zombieCount(Tuning, 2, 0), WaveMath.zombieCount(Tuning, 2, 1), "0 players")
end)

test("weapon bonus: SMG/shotgun 5–10, rifle/machine gun 10–20 (solo, wave 1)", function()
	for seed = 1, 30 do
		for class, def in ClassDefs do
			local n = WaveMath.zombieCount(Tuning, 1, 1, threatOf({ { class } }, seed)) - 20
			check(n >= def.bonusMin and n <= def.bonusMax, string.format("%s seed %d: +%d", class, seed, n))
		end
	end
end)

test("a class counts once, no matter how many guns", function()
	eq(WaveMath.zombieCount(Tuning, 1, 1, threatOf({ { "SMG", "SMG", "SMG" } }, 5)), WaveMath.zombieCount(Tuning, 1, 1, threatOf({ { "SMG" } }, 5)), "three SMGs = one")
end)

test("threat level: no weapons 1st, rifle 3rd, everything 4th", function()
	eq(threatOf({ {} }).tier.hp, 1.0, "no weapons")
	eq(threatOf({ { "SMG" } }).tier.hp, 1.1, "SMGs")
	eq(threatOf({ { "Rifle" } }).tier.hp, 1.2, "rifle")
	eq(threatOf({ { "SMG", "Shotgun", "Rifle", "MG" } }).tier.hp, 1.35, "everything")
	eq(threatOf({ { "Rifle" }, {} }).tier.hp, 1.1, "one of two: average 7.5")
end)

test("HP and speed: grow by wave, speed not above the cap", function()
	check(WaveMath.hpMultiplier(Tuning, 5, threatOf({ { "Rifle" } })) > WaveMath.hpMultiplier(Tuning, 5), "weapons raise HP")
	for w = 1, 40 do
		check(WaveMath.speedOf(Tuning, 14, w) <= 18, "walker on wave " .. w)
		check(WaveMath.speedOf(Tuning, 14, w) >= 14, "not slower than base")
	end
	eq(WaveMath.speedOf(Tuning, 19, 30), 19, "a runner faster than the cap doesn't slow down")
end)

test("HP multiplier: wave 1 = 1, grows", function()
	eq(WaveMath.hpMultiplier(Tuning, 1), 1, "wave 1")
	check(WaveMath.hpMultiplier(Tuning, 10) > WaveMath.hpMultiplier(Tuning, 9), "growth")
end)

test("bosses only on every 5th wave", function()
	for w = 1, 20 do
		local isBoss = w % 5 == 0
		eq(WaveMath.isBossWave(Tuning, w), isBoss, "wave " .. w)
		eq(WaveMath.bossCount(Tuning, w) > 0, isBoss, "number of bosses on wave " .. w)
	end
end)

test("the composition adds up to the zombie count", function()
	for w = 1, 40 do
		for p = 1, 6 do
			local threat = threatOf({ { "SMG", "Rifle" } }, w * 3 + p)
			local c = WaveMath.composition(Tuning, w, p, threat)
			eq(WaveMath.total(c), WaveMath.zombieCount(Tuning, w, p, threat), string.format("wave %d, players %d", w, p))
			for id, n in c do
				check(n > 0, "non-positive number " .. id)
			end
		end
	end
end)

test("wave 10: all regulars are armored, bosses Gargantua and Dark Lord", function()
	local c = WaveMath.composition(Tuning, 10, 3)
	eq(c.Walker, nil, "no walkers")
	eq(c.Runner, nil, "no runners")
	eq(c.Military, nil, "no soldiers")
	check((c.BucketHead or 0) > 0, "armored present")
	eq(c.BossGarg, 1, "Gargantua")
	eq(c.BossStrong, 1, "Dark Lord")
end)

test("soldiers from the 11th: 2–4 of them, none before the 11th", function()
	for w = 1, 10 do
		eq(WaveMath.composition(Tuning, w, 2).Military, nil, "wave " .. w)
	end
	for w = 11, 19 do
		local n = WaveMath.composition(Tuning, w, 1).Military or 0
		check(n >= 2 and n <= 4, "wave " .. w .. ": " .. n)
	end
end)

test("wave 20: soldiers are the main group", function()
	local c = WaveMath.composition(Tuning, 20, 2)
	check((c.Military or 0) >= WaveMath.total(c) * 0.4, "few soldiers")
end)

test("dark ones instead of runners on 11–15", function()
	for w = 11, 15 do
		local c = WaveMath.composition(Tuning, w, 2)
		eq(c.Runner, nil, "no runners on wave " .. w)
		check((c.Dark or 0) > 0, "dark ones on wave " .. w)
	end
	check(WaveMath.composition(Tuning, 16, 2).Dark == nil, "no dark ones after the 15th")
	check(WaveMath.composition(Tuning, 10, 2).Dark == nil, "no dark ones before the 11th")
end)

test("bosses in rotation: 5 — Jock, 10 — Gargantua, 15 — Dark Lord", function()
	eq(WaveMath.bossTypes(Tuning, 5)[1], "BossBuff", "5")
	eq(WaveMath.bossTypes(Tuning, 10)[1], "BossGarg", "10")
	eq(WaveMath.bossTypes(Tuning, 15)[1], "BossStrong", "15")
	eq(#WaveMath.bossTypes(Tuning, 7), 0, "7 — no boss")
end)

test("special zombies appear on schedule", function()
	eq(WaveMath.composition(Tuning, 5, 1).Chemist, nil, "chemist before the 7th")
	check((WaveMath.composition(Tuning, 9, 1).Chemist or 0) > 0, "chemist on the 9th")
	check((WaveMath.composition(Tuning, 8, 1).Crawler or 0) > 0, "crawlers on the 8th")
end)

test("spawn queue: same types, bosses at the end", function()
	local c = WaveMath.composition(Tuning, 15, 3)
	local q = WaveMath.spawnQueue(c, FakeRng.new(42) :: any)
	eq(#q, WaveMath.total(c), "queue length")
	local counts: { [string]: number } = {}
	for _, t in q do
		counts[t] = (counts[t] or 0) + 1
	end
	for id, n in c do
		eq(counts[id], n, "type " .. id)
	end
	local bosses = 0
	for id, n in c do
		if WaveMath.isBossType(id) then
			bosses += n
		end
	end
	for i = #q - bosses + 1, #q do
		check(WaveMath.isBossType(q[i]), "boss at the end, position " .. i)
	end
	for i = 1, #q - bosses do
		check(not WaveMath.isBossType(q[i]), "regular at the start, position " .. i)
	end
end)

test("composition per plan: 1st — walkers only, 2nd — runners from the 2nd", function()
	local c1 = WaveMath.composition(Tuning, 1, 1)
	eq(c1.Walker, 20, "1st: walkers only")
	check(WaveMath.composition(Tuning, 2, 1).Runner ~= nil, "runners on the 2nd")
end)

test("specials in the party grow with the wave", function()
	check((WaveMath.composition(Tuning, 12, 4).Brute or 0) > (WaveMath.composition(Tuning, 12, 1).Brute or 0), "more brutes with a bigger party")
end)

test("threat level 3+ brings specials a wave earlier", function()
	local threat = threatOf({ { "Rifle" } }, 3)
	check((WaveMath.composition(Tuning, 5, 1, threat).Brute or 0) > 0, "brutes already on the 5th with a rifle")
	eq(WaveMath.composition(Tuning, 5, 1).Brute, nil, "without weapons — no")
end)

test("threat level adds runners, only where they're in the plan", function()
	local threat = threatOf({ { "Rifle" } }, 3) -- 3-й уровень: runners = 0,1
	local plain = WaveMath.composition(Tuning, 4, 1)
	local armed = WaveMath.composition(Tuning, 4, 1, threat)
	local plainShare = (plain.Runner or 0) / WaveMath.total(plain)
	local armedShare = (armed.Runner or 0) / WaveMath.total(armed)
	check(armedShare > plainShare + 0.03, string.format("runner share grew (%.2f → %.2f)", plainShare, armedShare))
	eq(WaveMath.total(armed), WaveMath.zombieCount(Tuning, 4, 1, threat), "the composition sum doesn't change")
	eq(WaveMath.composition(Tuning, 1, 1, threat).Runner, nil, "wave 1 — no runners, with a weapon")
	eq(WaveMath.composition(Tuning, 12, 1, threat).Runner, nil, "11–15: no runners in the plan — and we don't add any")
end)

test("zombie damage +3% per wave", function()
	eq(WaveMath.damageMultiplier(Tuning, 1), 1, "wave 1")
	check(math.abs(WaveMath.damageMultiplier(Tuning, 11) - 1.3) < 1e-9, "wave 11 = 1.3")
end)

test("economy: mission rewards for nights 1–15 equal the set totals and grow", function()
	local personal, team, prev = 0, 0, 0
	for w = 1, 15 do
		local p, t = WaveMath.missionReward(Economy, w)
		personal += p
		team += t
		check(p > prev, "growth on night " .. w)
		prev = p
	end
	check(math.abs(personal - Economy.MissionPersonalTotal) < 1e-6, "personal part " .. personal)
	check(math.abs(team - Economy.MissionTeamTotal) < 1e-6, "team part " .. team)
end)

test("economy: player income by night 15 ≈ 0.9 basket with 1, 2, 4 and 6 players", function()
	local killPoolFull = 0
	for w = 1, 15 do
		killPoolFull += WaveMath.killPool(Economy, w, 1)
	end
	for _, n in { 1, 2, 4, 6 } do
		local income = Economy.MissionPersonalTotal + killPoolFull + Economy.MissionTeamTotal / n
		local target = 0.9 * (5250 + 14500 / n)
		check(math.abs(income - target) < target * 0.01, n .. " players: " .. income .. " vs " .. target)
	end
end)

test("economy: kill coin cap per night 200–300 and growing", function()
	eq(WaveMath.killCap(Economy, 1), 200, "night 1")
	eq(WaveMath.killCap(Economy, 15), 300, "night 15")
	eq(WaveMath.killCap(Economy, 40), 300, "the cap doesn't grow further")
	check(WaveMath.killCap(Economy, 8) > WaveMath.killCap(Economy, 3), "growth")
end)

test("economy: the sum of kill units equals the wave pool", function()
	for w = 1, 20 do
		for _, players in { 1, 3 } do
			local comp = WaveMath.composition(Tuning, w, players)
			local units = WaveMath.killUnits(Economy, w, comp, players)
			local sum = 0
			for id, n in comp do
				sum += units[id] * n
			end
			check(math.abs(sum - WaveMath.killPool(Economy, w, players)) < 1e-6, "wave " .. w)
		end
	end
end)

test("economy: the kill pool doesn't depend on crowd size and grows with player count", function()
	local function total(players: number, crowdPlayers: number): number
		local comp = WaveMath.composition(Tuning, 10, crowdPlayers)
		local units = WaveMath.killUnits(Economy, 10, comp, players)
		local sum = 0
		for id, n in comp do
			sum += units[id] * n
		end
		return sum
	end
	check(math.abs(total(2, 1) - total(2, 4)) < 1e-6, "the pool is equal for the same party with crowds of different sizes")
	check(math.abs(total(4, 4) - 4 * total(1, 1)) < 1e-6, "the pool is proportional to the player count")
end)

-- Ballistics ---------------------------------------------------------------------------------------------------------

local Aim: Ballistics.Aim = {
	adsFov = 55, adsSpreadMul = 0.4, recoilPitch = 1.2, recoilYaw = 0.5, recoilGrow = 0.5,
	resetTime = 0.4, bloom = 0.1, bloomMax = 1.5, push = 0, stagger = 0,
}
local function stateOf(over: { ads: boolean?, speed: number?, airborne: boolean?, burst: number? }?): Ballistics.State
	local o = over or {}
	return { ads = o.ads or false, speed = o.speed or 0, airborne = o.airborne or false, burst = o.burst or 0 }
end

test("ballistics: the first single shot hits dead center", function()
	local x, y = Ballistics.pelletOffset(1, 0, 1)
	eq(x, 0, "x")
	eq(y, 0, "y")
end)

test("ballistics: single shots 1..50 within a circle of radius 0.85", function()
	for i = 1, 50 do
		local x, y = Ballistics.pelletOffset(1, i, 1)
		check(math.sqrt(x * x + y * y) <= 0.85 + 1e-9, "shot " .. i)
	end
end)

test("ballistics: for pellets the first pellet is in the center, the rest in the unit circle", function()
	local x, y = Ballistics.pelletOffset(1, 0, 8)
	eq(x, 0, "x")
	eq(y, 0, "y")
	for i = 2, 8 do
		local px, py = Ballistics.pelletOffset(i, 0, 8)
		check(math.sqrt(px * px + py * py) <= 1, "pellet " .. i)
	end
end)

test("ballistics: two pellets — no division by 0", function()
	local x, y = Ballistics.pelletOffset(2, 0, 2)
	check(x == x and y == y and math.abs(x) < math.huge and math.abs(y) < math.huge, "finite offset")
end)

test("ballistics: the offset is reproducible", function()
	local x1, y1 = Ballistics.pelletOffset(3, 7, 1)
	local x2, y2 = Ballistics.pelletOffset(3, 7, 1)
	eq(x1, x2, "x")
	eq(y1, y2, "y")
end)

test("spread: standing = base; aiming multiplies by adsSpreadMul; in the air ×2.5", function()
	local base = 2
	check(math.abs(Ballistics.spreadDeg(base, Aim, stateOf(), 14) - base) < 1e-9, "standing")
	check(math.abs(Ballistics.spreadDeg(base, Aim, stateOf({ ads = true }), 14) - base * Aim.adsSpreadMul) < 1e-9, "ADS")
	check(math.abs(Ballistics.spreadDeg(base, Aim, stateOf({ airborne = true }), 14) - base * 2.5) < 1e-9, "in the air")
end)

test("spread: speed increases it, walkSpeed = 0 without division by 0", function()
	check(Ballistics.spreadDeg(2, Aim, stateOf({ speed = 14 }), 14) > Ballistics.spreadDeg(2, Aim, stateOf(), 14), "a step is wider than standing")
	local v = Ballistics.spreadDeg(2, Aim, stateOf({ speed = 14 }), 0)
	check(v == v and v < math.huge, "walkSpeed = 0")
end)

test("spread: burst bloom not above bloomMax", function()
	local base = 2
	local capped = Ballistics.spreadDeg(base, Aim, stateOf({ burst = 1000 }), 14)
	check(math.abs(capped - (base + Aim.bloomMax)) < 1e-9, "bloom cap")
	check(Ballistics.spreadDeg(base, Aim, stateOf({ burst = 3 }), 14) < capped, "below the cap")
end)

test("recoil: no yaw drift at the start of a burst, the zigzag is reproducible", function()
	local pitch, yaw = Ballistics.recoilStep(Aim, 0)
	eq(yaw, 0, "yaw drift on shot 0")
	check(math.abs(pitch - Aim.recoilPitch) < 1e-9, "initial climb = recoilPitch")
	for i = 0, 20 do
		local p1, y1 = Ballistics.recoilStep(Aim, i)
		local p2, y2 = Ballistics.recoilStep(Aim, i)
		check(p1 == p2 and y1 == y2, "repeat " .. i)
	end
	local p12 = Ballistics.recoilStep(Aim, 12)
	check(math.abs(p12 - Aim.recoilPitch * (1 + Aim.recoilGrow)) < 1e-9, "growth up to the 12th shot")
end)

-- RateLimit (игрок подменён таблицей) -------------------------------------------------------------------------------

test("RateLimit: the first call passes, a repeat within the interval doesn't", function()
	local p: any = {}
	check(RateLimit.allow(p, "A", 1000), "first")
	check(not RateLimit.allow(p, "A", 1000), "repeat within the interval")
	RateLimit.forget(p)
end)

test("RateLimit: keys and players are independent", function()
	local p1: any, p2: any = {}, {}
	check(RateLimit.allow(p1, "A", 1000), "p1 A")
	check(RateLimit.allow(p1, "B", 1000), "p1 B")
	check(RateLimit.allow(p2, "A", 1000), "p2 A")
	check(not RateLimit.allow(p1, "A", 1000), "p1 A repeat")
	RateLimit.forget(p1)
	RateLimit.forget(p2)
end)

test("RateLimit: after forget it's allowed again, a zero interval doesn't block", function()
	local p: any = {}
	check(RateLimit.allow(p, "A", 1000), "first")
	RateLimit.forget(p)
	check(RateLimit.allow(p, "A", 1000), "after forget")
	check(RateLimit.allow(p, "Z", 0), "interval 0, first")
	check(RateLimit.allow(p, "Z", 0), "interval 0, second")
	RateLimit.forget(p)
end)

test("Rewind: forward pass, return on a repeat press and restart", function()
	local s = Rewind.new(1, 4)
	Rewind.press(s)
	local u = Rewind.step(s, 0.5)
	check(u ~= nil and math.abs((u :: number) - 0.5) < 1e-6, "halfway forward")
	Rewind.press(s) -- второе нажатие: возврат с последующим повтором
	u = Rewind.step(s, 0.1)
	check(u ~= nil and (u :: number) < 0.5 and (u :: number) > 0, "going back, no jump")
	u = Rewind.step(s, 0.2) -- до нуля, дальше разворот вперёд
	check(s.active and s.dir == 1, "after returning it plays again")
	Rewind.release(s)
	local guard = 0
	while Rewind.step(s, 0.1) ~= nil and guard < 100 do
		guard += 1
	end
	check(not s.active, "finished playing and ended")
end)

test("Rewind: cancel goes back and ends, a press during the return turns it around", function()
	local s = Rewind.new(2, 4)
	Rewind.press(s)
	Rewind.release(s)
	Rewind.step(s, 1)
	Rewind.cancel(s)
	local u = Rewind.step(s, 0.1)
	check(u ~= nil and (u :: number) < 0.5, "return")
	Rewind.press(s)
	check(s.dir == 1 and s.active, "turn forward from the current pose")
	Rewind.cancel(s)
	check(Rewind.step(s, 10) == nil and not s.active, "the return ended")
end)

test("Rewind: while held, the pass repeats", function()
	local s = Rewind.new(1, 4)
	Rewind.press(s)
	Rewind.step(s, 0.9)
	local u = Rewind.step(s, 0.3)
	check(s.active and u ~= nil and (u :: number) < 0.5, "second lap")
end)

-- ===== Лобби: зоны сбора =====

test("LobbyRules: первый вошедший — хост, зона закрывается", function()
	local z = LobbyRules.newZone(6)
	check(LobbyRules.canEnter(z, 100, false, 0).ok, "free zone lets the first in")
	check(LobbyRules.enter(z, 100, 0) == "host" and z.host == 100 and z.state == "setup", "first becomes host")
	local res = LobbyRules.canEnter(z, 200, true, 1)
	check(not res.ok and res.reason == "The host is still setting up", "closed while the host sets up")
	check(not LobbyRules.canEnter(z, 100, false, 1).ok, "host cannot enter twice")
end)

test("LobbyRules: настройка — только хост, пределы значений", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	check(not LobbyRules.configure(z, 101, 4, "Public", 6, 0).ok, "non-host cannot configure")
	check(not LobbyRules.configure(z, 100, 0, "Public", 6, 0).ok, "size 0 refused")
	check(not LobbyRules.configure(z, 100, 7, "Public", 6, 0).ok, "size 7 refused")
	check(not LobbyRules.configure(z, 100, 2.5, "Public", 6, 0).ok, "fractional size refused")
	check(not LobbyRules.configure(z, 100, "4", "Public", 6, 0).ok, "string size refused")
	check(not LobbyRules.configure(z, 100, 4, "Secret", 6, 0).ok, "unknown mode refused")
	check(not LobbyRules.configure(z, 100, 0 / 0, "Public", 6, 0).ok, "NaN size refused")
	check(LobbyRules.configure(z, 100, 4, "Friends", 6, 0).ok and z.size == 4 and z.mode == "Friends", "valid settings applied")
end)

test("LobbyRules: открытие и правила входа по доступу", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	check(not LobbyRules.open(z, 101, 0).ok, "non-host cannot open")
	LobbyRules.configure(z, 100, 3, "Friends", 6, 0)
	check(LobbyRules.open(z, 100, 0).ok and z.state == "open", "host opens")
	check(not LobbyRules.canEnter(z, 200, false, 1).ok, "stranger refused (Friends only)")
	check(LobbyRules.canEnter(z, 201, true, 1).ok, "friend of the host enters")
	LobbyRules.enter(z, 201, 1)
	check(LobbyRules.enter(z, 201, 1) == "member" and #z.members == 2, "no duplicates")
	LobbyRules.configure(z, 100, 3, "Invite", 6, 1)
	check(not LobbyRules.canEnter(z, 202, true, 2).ok, "Invite only refuses even a friend")
	check(LobbyRules.invite(z, 100, 202, 2, 60, 12).ok, "host invites")
	check(LobbyRules.canEnter(z, 202, false, 10).ok, "invited stranger enters")
	check(not LobbyRules.canEnter(z, 202, false, 63).ok, "invite expired")
	LobbyRules.configure(z, 100, 3, "Public", 6, 1)
	check(LobbyRules.canEnter(z, 203, false, 3).ok, "Public admits anyone with room")
	LobbyRules.enter(z, 203, 3)
	check(not LobbyRules.canEnter(z, 204, true, 4).ok, "full zone refuses")
end)

test("LobbyRules: размер нельзя сделать меньше числа игроков внутри", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	LobbyRules.open(z, 100, 0)
	LobbyRules.enter(z, 101, 1)
	LobbyRules.enter(z, 102, 1)
	check(not LobbyRules.configure(z, 100, 2, "Public", 6, 1).ok, "cannot shrink below members")
	check(LobbyRules.configure(z, 100, 3, "Public", 6, 1).ok, "can shrink to exactly members")
end)

test("LobbyRules: хост ушёл — хост следующий; пустая зона свободна", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	LobbyRules.configure(z, 100, 4, "Friends", 6, 0)
	LobbyRules.open(z, 100, 0)
	LobbyRules.enter(z, 101, 1)
	LobbyRules.enter(z, 102, 1)
	check(LobbyRules.leave(z, 999, 6, 2) == "none", "stranger leaving does nothing")
	check(LobbyRules.leave(z, 100, 6, 2) == "host" and z.host == 101, "next member becomes host")
	check(z.mode == "Friends" and z.size == 4 and z.state == "open", "settings are kept")
	check(LobbyRules.leave(z, 102, 6, 3) == "ok" and z.host == 101, "member left, host stays")
	check(LobbyRules.leave(z, 101, 6, 4) == "free" and z.state == "free" and z.host == nil, "empty zone is free")
	check(z.size == 6 and z.mode == "Public" and next(z.kicked) == nil, "defaults restored")
	check(LobbyRules.canEnter(z, 300, false, 5).ok, "free again")
end)

test("LobbyRules: хост ушёл во время настройки — зона свободна", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	check(LobbyRules.leave(z, 100, 6, 1) == "free" and z.state == "free", "setup abandoned")
end)

test("LobbyRules: заполнение запускает отсчёт, уход сбрасывает", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	LobbyRules.configure(z, 100, 3, "Public", 6, 0)
	check(LobbyRules.countdownLeft(z, 0, 12) == nil, "no countdown during setup")
	LobbyRules.open(z, 100, 0)
	LobbyRules.enter(z, 101, 10)
	check(LobbyRules.countdownLeft(z, 10, 12) == nil, "not full yet")
	LobbyRules.enter(z, 102, 20)
	check(z.fullAt == 20, "countdown starts when full")
	check(LobbyRules.countdownLeft(z, 25, 12) == 7, "7 s left")
	check(not LobbyRules.ready(z, 31, 12) and LobbyRules.ready(z, 32, 12), "ready after 12 s")
	LobbyRules.leave(z, 102, 6, 26)
	check(z.fullAt == nil and LobbyRules.countdownLeft(z, 27, 12) == nil, "someone left: countdown reset")
	LobbyRules.enter(z, 103, 40)
	check(z.fullAt == 40, "refill restarts the countdown")
end)

test("LobbyRules: удаление игрока хостом", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	LobbyRules.open(z, 100, 0)
	LobbyRules.enter(z, 101, 1)
	check(not LobbyRules.kick(z, 101, 100, 2).ok, "member cannot kick the host")
	check(not LobbyRules.kick(z, 100, 100, 2).ok, "host cannot kick self")
	check(not LobbyRules.kick(z, 100, 555, 2).ok, "cannot kick a stranger")
	check(LobbyRules.kick(z, 100, 101, 2).ok and not LobbyRules.has(z, 101), "host kicks")
	check(not LobbyRules.canEnter(z, 101, true, 3).ok, "kicked player stays out")
	check(LobbyRules.invite(z, 100, 101, 3, 60, 12).ok and LobbyRules.canEnter(z, 101, true, 4).ok, "a new invite lifts the ban")
end)

test("LobbyRules: приглашения — только хост, лимиты", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	check(not LobbyRules.invite(z, 101, 300, 0, 60, 12).ok, "non-host cannot invite")
	check(not LobbyRules.invite(z, 100, 100, 0, 60, 12).ok, "cannot invite self")
	check(LobbyRules.invite(z, 100, 300, 0, 60, 1).ok, "first invite")
	check(not LobbyRules.invite(z, 100, 301, 0, 60, 1).ok, "invite cap")
	check(LobbyRules.invite(z, 100, 300, 0, 60, 1).ok, "re-invite of the same player is fine")
	LobbyRules.expireInvites(z, 100)
	check(next(z.invited) == nil, "expired invites cleaned")
end)

test("LobbyRules: старт, отмена, запуск закрывает зону", function()
	local z = LobbyRules.newZone(6)
	LobbyRules.enter(z, 100, 0)
	check(LobbyRules.canStart(z, 100).ok and not LobbyRules.canStart(z, 101).ok, "only the host starts")
	check(LobbyRules.canCancel(z, 100).ok and not LobbyRules.canCancel(z, 101).ok, "only the host cancels")
	LobbyRules.open(z, 100, 0)
	LobbyRules.lock(z)
	check(z.state == "launching" and not LobbyRules.canStart(z, 100).ok and not LobbyRules.canCancel(z, 100).ok, "launching zone is closed")
	check(not LobbyRules.canEnter(z, 5, true, 1).ok, "nobody enters a launching zone")
	LobbyRules.unlock(z, 5)
	check(z.state == "open", "failed launch reopens the zone")
end)

test("LobbyRules: тайм-аут настройки", function()
	local z = LobbyRules.newZone(6)
	check(not LobbyRules.setupExpired(z, 1000, 120), "free zone never expires")
	LobbyRules.enter(z, 100, 10)
	check(not LobbyRules.setupExpired(z, 100, 120) and LobbyRules.setupExpired(z, 130, 120), "expires after the timeout")
	LobbyRules.open(z, 100, 130)
	check(not LobbyRules.setupExpired(z, 9999, 120), "open zone does not expire")
end)

test("LobbyRules: данные клиента", function()
	check(LobbyRules.isUserId(12345) and not LobbyRules.isUserId(-1) and not LobbyRules.isUserId(1.5), "userId")
	check(not LobbyRules.isUserId(0 / 0) and not LobbyRules.isUserId("5") and not LobbyRules.isUserId(math.huge), "bad userId")
	check(LobbyRules.isMode("Public") and not LobbyRules.isMode("public") and not LobbyRules.isMode(5), "mode")
	check(LobbyRules.isZoneSize(1, 6) and LobbyRules.isZoneSize(6, 6) and not LobbyRules.isZoneSize(7, 6) and not LobbyRules.isZoneSize(nil, 6), "zone size")
end)

print(string.format("\nTOTAL: %d tests, %d failed", total, failed))
if failed > 0 then
	error("some tests failed", 0)
end
