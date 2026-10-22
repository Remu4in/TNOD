--!strict
-- Чистые формулы волн: без сервисов Roblox, поэтому тестируются вне Studio.
-- Состав волны = обычные по долям и особые по таблице WaveMath.Plan + боссы (цикл WaveMath.BossCycle).
-- Количество — кривая от старта до потолка (zombieCount); монеты — общий бюджет команды (Config.Economy).

local WaveMath = {}

export type WaveTuning = {
	StartCounts: { number }, -- зомби на 1-й волне для 1, 2, 3… игроков; дальше + StartPerExtraPlayer на игрока
	StartPerExtraPlayer: number,
	CurveWaves: number, -- на этой волне достигается потолок
	CurveExp: number, -- форма кривой: >1 — рост медленно, потом быстрее
	JitterPct: number, -- случайное отклонение числа зомби по волне, ±%
	CapSolo: number,
	CapPerExtraPlayer: number,
	HpGrowthPerWave: number,
	DamageGrowthPerWave: number,
	SpeedGrowthPerWave: number,
	SpeedCeil: number,
	BossEvery: number,
	CountScale: number?, -- множитель числа зомби (на время тестов 0,1; в релизе не задаём)
}

-- Уровень угрозы команды (вооружённость): считается один раз в начале ночи (makeThreat)
export type ClassDef = { weight: number, bonusMin: number, bonusMax: number }
export type Tier = { min: number, hp: number, runners: number, early: number }
export type Threat = { classes: { string }, defs: { [string]: ClassDef }, tier: Tier, score: number, seed: number }

-- Состав: тип зомби → сколько. Типы боссов начинаются с «Boss».
export type Composition = { [string]: number }

-- План состава по волнам: shares — доли обычных зомби (нормируются), counts — особые в штуках (в команде растут вместе с общим
-- числом зомби), fractions — доля от всех зомби волны, only — все обычные одного типа. Волны дальше последней берут последнюю запись.
export type PlanRow = { shares: { [string]: number }, counts: { [string]: number }?, fractions: { [string]: number }?, only: string? }
WaveMath.Plan = {
	[1] = { shares = { Walker = 100 } },
	[2] = { shares = { Walker = 88, Runner = 12 } },
	[3] = { shares = { Walker = 80, Runner = 20 } },
	[4] = { shares = { Walker = 72, Runner = 28 } },
	[5] = { shares = { Walker = 66, Runner = 28 } },
	[6] = { shares = { Walker = 58, Runner = 25, Crawler = 8 }, counts = { Brute = 2 } },
	[7] = { shares = { Walker = 52, Runner = 25, Crawler = 10 }, counts = { Brute = 2, Chemist = 2 } },
	[8] = { shares = { Walker = 48, Runner = 26, Crawler = 10 }, counts = { Brute = 3, Chemist = 3 } },
	[9] = { shares = { Walker = 44, Runner = 28, Crawler = 12 }, counts = { Brute = 4, Chemist = 4 } },
	[10] = { shares = { BucketHead = 100 }, only = "BucketHead" },
	[11] = { shares = { Walker = 45, Crawler = 10, Dark = 35 }, counts = { Brute = 5, Chemist = 4, Military = 2 } },
	[12] = { shares = { Walker = 45, Crawler = 10, Dark = 35 }, counts = { Brute = 5, Chemist = 4, Military = 2 } },
	[13] = { shares = { Walker = 45, Crawler = 10, Dark = 35 }, counts = { Brute = 5, Chemist = 4, Military = 2 } },
	[14] = { shares = { Walker = 45, Crawler = 10, Dark = 35 }, counts = { Brute = 5, Chemist = 4, Military = 2 } },
	[15] = { shares = { Walker = 40, Crawler = 10, Dark = 40 }, counts = { Brute = 5, Chemist = 4, Military = 2 } },
	[16] = { shares = { Walker = 40, Runner = 30, Crawler = 12 }, counts = { Brute = 5, Chemist = 5, Military = 3 } },
	[17] = { shares = { Walker = 40, Runner = 30, Crawler = 12 }, counts = { Brute = 5, Chemist = 5, Military = 3 } },
	[18] = { shares = { Walker = 40, Runner = 30, Crawler = 12 }, counts = { Brute = 6, Chemist = 5, Military = 4 } },
	[19] = { shares = { Walker = 40, Runner = 30, Crawler = 12 }, counts = { Brute = 6, Chemist = 5, Military = 4 } },
	[20] = { shares = { Walker = 25, Runner = 10, Crawler = 5 }, counts = { Brute = 6, Chemist = 5 }, fractions = { Military = 0.5 } },
} :: { [number]: PlanRow }

local LAST_PLAN = 20

local function planAt(wave: number): PlanRow
	return WaveMath.Plan[math.clamp(wave, 1, LAST_PLAN)]
end

-- Боссы по порядку: 5-я — Качок, 10-я — Гаргантюа (PvZ), 15-я — Повелитель тёмных, дальше по кругу
WaveMath.BossCycle = { "BossBuff", "BossGarg", "BossStrong" } :: { string }

-- Детерминированный «бросок» по семени: одно и то же число для всех клиентов и тестов (чистая арифметика, без Random)
function WaveMath.roll(seed: number, key: number, a: number, b: number): number
	local x = (math.floor(seed) * 7919 + key * 104729 + 12345) % 2147483647
	x = (x * 48271) % 2147483647
	x = (x * 48271) % 2147483647
	return a + x % (b - a + 1)
end

local NEUTRAL_TIER: Tier = { min = 0, hp = 1, runners = 0, early = 0 }

-- classesCfg — Config.ThreatClasses, tiers — Config.Threat.Tiers (по возрастанию min), loadouts — для каждого игрока список классов его оружия
function WaveMath.makeThreat(classesCfg: { [string]: ClassDef }, tiers: { Tier }, loadouts: { { string } }, seed: number): Threat
	local team: { [string]: boolean } = {}
	local sum = 0
	for _, loadout in loadouts do
		local mine: { [string]: boolean } = {}
		for _, class in loadout do
			local def = classesCfg[class]
			if def and not mine[class] then
				mine[class] = true
				sum += def.weight
				team[class] = true
			end
		end
	end
	local classes: { string } = {}
	for class in team do
		table.insert(classes, class)
	end
	table.sort(classes)
	local score = sum / math.max(1, #loadouts)
	local tier = tiers[1] or NEUTRAL_TIER
	for _, candidate in tiers do
		if score >= candidate.min then
			tier = candidate
		end
	end
	return { classes = classes, defs = classesCfg, tier = tier, score = score, seed = seed }
end

local function playerFactor(players: number): number
	return 1 + 0.5 * (math.max(1, players) - 1)
end

local function startCount(t: WaveTuning, players: number): number
	local p = math.max(1, players)
	local list = t.StartCounts
	if p <= #list then
		return list[p]
	end
	return list[#list] + (p - #list) * t.StartPerExtraPlayer
end

local function capFor(t: WaveTuning, players: number): number
	return t.CapSolo * (1 + t.CapPerExtraPlayer * (math.max(1, players) - 1))
end

-- Целевое число зомби по кривой (без отклонения и добавок): старт → потолок за CurveWaves волн
function WaveMath.curveCount(t: WaveTuning, wave: number, players: number): number
	local start, cap = startCount(t, players), capFor(t, players)
	local k = math.clamp((wave - 1) / (t.CurveWaves - 1), 0, 1) ^ t.CurveExp
	return (start + (cap - start) * k) * (t.CountScale or 1)
end

-- Сколько зомби в волне: кривая ±отклонение + добавка за классы оружия команды (в пределах потолка)
function WaveMath.zombieCount(t: WaveTuning, wave: number, players: number, threat: Threat?): number
	local seed = if threat then threat.seed else 0
	local total = WaveMath.curveCount(t, wave, players)
	if wave > 1 then
		total *= 1 + WaveMath.roll(seed, wave, -t.JitterPct, t.JitterPct) / 100
	end
	if threat then
		local pf = playerFactor(players)
		for i, class in threat.classes do
			local def = threat.defs[class]
			total += WaveMath.roll(seed, wave * 100 + i, def.bonusMin, def.bonusMax) * pf
		end
	end
	local scale = t.CountScale or 1
	return math.max(if scale < 1 then 3 else 1, math.floor(math.min(total, capFor(t, players) * scale) + 0.5))
end

function WaveMath.hpMultiplier(t: WaveTuning, wave: number, threat: Threat?): number
	return (1 + t.HpGrowthPerWave * (wave - 1)) * (if threat then threat.tier.hp else 1)
end

-- Урон зомби растёт с волной
function WaveMath.damageMultiplier(t: WaveTuning, wave: number): number
	return 1 + t.DamageGrowthPerWave * (wave - 1)
end

-- Множитель скорости обычных зомби по волне; итоговая скорость ограничена SpeedCeil (спринт игрока быстрее)
function WaveMath.speedMultiplier(t: WaveTuning, wave: number): number
	return 1 + t.SpeedGrowthPerWave * (wave - 1)
end

function WaveMath.speedOf(t: WaveTuning, base: number, wave: number): number
	return math.max(base, math.min(base * WaveMath.speedMultiplier(t, wave), t.SpeedCeil))
end

function WaveMath.isBossWave(t: WaveTuning, wave: number): boolean
	return wave > 0 and wave % t.BossEvery == 0
end

function WaveMath.bossCount(t: WaveTuning, wave: number): number
	if not WaveMath.isBossWave(t, wave) then
		return 0
	end
	return 1 + math.floor(wave / 10)
end

-- Типы боссов волны: i-й босс — следующий в цикле после босса предыдущей 5-й волны
function WaveMath.bossTypes(t: WaveTuning, wave: number): { string }
	local list: { string } = {}
	local n = WaveMath.bossCount(t, wave)
	local first = math.floor(wave / t.BossEvery) -- номер босс-волны: 1, 2, 3…
	for i = 1, n do
		table.insert(list, WaveMath.BossCycle[(first + i - 2) % #WaveMath.BossCycle + 1])
	end
	return list
end

-- Распределяем n штук по долям (метод наибольших остатков, сумма точная)
local function split(n: number, shares: { [string]: number }): { [string]: number }
	local ids: { string } = {}
	local sum = 0
	for id, v in shares do
		table.insert(ids, id)
		sum += v
	end
	table.sort(ids)
	local out: { [string]: number } = {}
	local rem: { { id: string, frac: number } } = {}
	local used = 0
	for _, id in ids do
		local exact = n * shares[id] / sum
		local whole = math.floor(exact)
		out[id] = whole
		used += whole
		table.insert(rem, { id = id, frac = exact - whole })
	end
	table.sort(rem, function(a, b)
		if a.frac ~= b.frac then
			return a.frac > b.frac
		end
		return a.id < b.id
	end)
	local i = 1
	while used < n and #rem > 0 do
		out[rem[i].id] += 1
		used += 1
		i = i % #rem + 1
	end
	return out
end

function WaveMath.composition(t: WaveTuning, wave: number, players: number, threat: Threat?): Composition
	local total = WaveMath.zombieCount(t, wave, players, threat)
	local tier = if threat then threat.tier else NEUTRAL_TIER
	local comp: Composition = {}
	local bosses = WaveMath.bossTypes(t, wave)
	for _, b in bosses do
		comp[b] = (comp[b] or 0) + 1
	end
	local rest = math.max(0, total - #bosses)
	local row = planAt(wave)
	if row.only then
		comp[row.only] = (comp[row.only] or 0) + rest
		return comp
	end
	-- особые приходят на волну раньше при высоком уровне угрозы (кроме волн «только один тип»)
	local specialRow = planAt(wave + tier.early)
	if specialRow.only then
		specialRow = row
	end
	local free = rest
	-- доли от всей волны (военные на 20-й)
	for id, fraction in specialRow.fractions or {} do
		local n = math.min(free, math.floor(rest * fraction + 0.5))
		if n > 0 then
			comp[id] = (comp[id] or 0) + n
			free -= n
		end
	end
	-- штуки растут вместе с размером волны: во сколько раз она больше, чем у одиночки без оружия
	local scale = math.max(1, total / math.max(1, WaveMath.curveCount(t, wave, 1)))
	local counts: { [string]: number } = specialRow.counts or {}
	local ids: { string } = {}
	for id in counts do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local n = math.min(free, math.floor(counts[id] * scale + 0.5))
		if n > 0 then
			comp[id] = (comp[id] or 0) + n
			free -= n
		end
	end
	if free > 0 then
		for id, n in split(free, row.shares) do
			if n > 0 then
				comp[id] = (comp[id] or 0) + n
			end
		end
	end
	return comp
end

function WaveMath.isBossType(id: string): boolean
	return string.sub(id, 1, 4) == "Boss"
end

function WaveMath.total(comp: Composition): number
	local n = 0
	for _, c in comp do
		n += c
	end
	return n
end

-- Список типов для очереди спавна: обычные перемешаны, боссы в конце волны.
function WaveMath.spawnQueue(comp: Composition, rng: Random): { string }
	local ids: { string } = {}
	for id in comp do
		table.insert(ids, id)
	end
	table.sort(ids) -- порядок не зависит от обхода таблицы: тесты и повторы воспроизводимы
	local queue: { string } = {}
	local bossQueue: { string } = {}
	for _, id in ids do
		for _ = 1, comp[id] do
			table.insert(if WaveMath.isBossType(id) then bossQueue else queue, id)
		end
	end
	for i = #queue, 2, -1 do
		local j = rng:NextInteger(1, i)
		queue[i], queue[j] = queue[j], queue[i]
	end
	for _, id in bossQueue do
		table.insert(queue, id)
	end
	return queue
end

-- Экономика команды ------------------------------------------------------------------------------------
-- Касса общая. За волну: награда за прохождение (waveReward) + пул за убийства (killPool): убийство в голову платит полную долю,
-- в тело — KillBodyShare от неё. Доля зависит от веса типа и не от размера толпы, поэтому доход за волну не растёт с числом зомби.
export type EconomyTuning = {
	WaveRewardBase: number,
	WaveRewardPerWave: number,
	KillPoolBase: number,
	KillPoolPerWave: number,
	KillBodyShare: number,
	KillWeights: { [string]: number },
	BossKillWeight: number,
}

function WaveMath.waveReward(e: EconomyTuning, wave: number): number
	return e.WaveRewardBase + e.WaveRewardPerWave * wave
end

function WaveMath.killPool(e: EconomyTuning, wave: number): number
	return e.KillPoolBase + e.KillPoolPerWave * wave
end

-- Монеты за убийство в голову по типам (в тело — умножить на KillBodyShare); сумма по всей волне = killPool
function WaveMath.killUnits(e: EconomyTuning, wave: number, comp: Composition): { [string]: number }
	local function weight(id: string): number
		return e.KillWeights[id] or (if WaveMath.isBossType(id) then e.BossKillWeight else 1)
	end
	local sum = 0
	for id, n in comp do
		sum += weight(id) * n
	end
	local units: { [string]: number } = {}
	if sum <= 0 then
		return units
	end
	local pool = WaveMath.killPool(e, wave)
	for id in comp do
		units[id] = pool * weight(id) / sum
	end
	return units
end

return WaveMath
