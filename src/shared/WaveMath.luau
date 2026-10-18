--!strict
-- Чистые формулы волн: без сервисов Roblox, поэтому тестируются вне Studio.
-- Состав волны = Walker/Runner (по долям) + особые по расписанию (WaveMath.Schedule) + боссы (цикл WaveMath.BossCycle).

local WaveMath = {}

export type WaveTuning = {
	BaseCount: number,
	CountPerWave: number,
	PlayerCountFactor: number,
	HpGrowthPerWave: number,
	RunnersFromWave: number,
	RunnerShareMax: number,
	RunnerShareGrowth: number,
	BossEvery: number,
}

-- Состав: тип зомби → сколько. Типы боссов начинаются с «Boss».
export type Composition = { [string]: number }

-- Правило появления особого зомби. kind = "count": штук = min(cap, floor(value + grow·(волна − from)));
-- kind = "share": доля обычных зомби волны = min(cap, value + grow·(волна − from)).
export type Rule = { id: string, kind: string, from: number, to: number?, value: number, grow: number?, cap: number? }

-- Расписание (2026-10-19). Числа черновые — баланс после плейтеста.
WaveMath.Schedule = {
	{ id = "Crawler", kind = "share", from = 6, value = 0.06, grow = 0.01, cap = 0.15 }, -- ползуны подмешиваются с 6-й
	{ id = "Brute", kind = "count", from = 6, value = 1, grow = 0.25, cap = 6 }, -- Громилы с 6-й
	{ id = "Chemist", kind = "count", from = 7, value = 1, grow = 0.34, cap = 5 }, -- химики с 7-й
	{ id = "Military", kind = "count", from = 11, to = 19, value = 2, grow = 0.25, cap = 4 }, -- военные с 11-й: 2–4 штуки
	{ id = "Military", kind = "share", from = 20, value = 0.5 }, -- 20-я: заражение базы, военные — основная группа
} :: { Rule }

-- Волны, где ВСЕ обычные зомби — один тип (10-я: бронированные, PvZ)
WaveMath.AllSame = { [10] = "BucketHead" } :: { [number]: string }

-- Замена типа на диапазоне волн: «тёмные» вместо быстрых на 11–15 (тёмные собаки заменят их, когда будет риг собаки)
WaveMath.Replace = {
	{ from = 11, to = 15, old = "Runner", new = "Dark" },
} :: { { from: number, to: number, old: string, new: string } }

-- Боссы по порядку: 5-я — Качок, 10-я — Гаргантюа (PvZ), 15-я — Повелитель тёмных, дальше по кругу
WaveMath.BossCycle = { "BossBuff", "BossGarg", "BossStrong" } :: { string }

function WaveMath.zombieCount(t: WaveTuning, wave: number, players: number): number
	local p = math.max(1, players)
	local base = t.BaseCount + t.CountPerWave * (wave - 1)
	return math.floor(base * (1 + t.PlayerCountFactor * (p - 1)) + 0.5)
end

function WaveMath.hpMultiplier(t: WaveTuning, wave: number): number
	return 1 + t.HpGrowthPerWave * (wave - 1)
end

function WaveMath.runnerShare(t: WaveTuning, wave: number): number
	if wave < t.RunnersFromWave then
		return 0
	end
	return math.min(t.RunnerShareMax, t.RunnerShareGrowth * (wave - t.RunnersFromWave + 1))
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

local function ruleActive(rule: Rule, wave: number): boolean
	return wave >= rule.from and (rule.to == nil or wave <= rule.to)
end

local function ruleValue(rule: Rule, wave: number): number
	local v = rule.value + (rule.grow or 0) * (wave - rule.from)
	if rule.cap then
		v = math.min(v, rule.cap)
	end
	return v
end

function WaveMath.composition(t: WaveTuning, wave: number, players: number): Composition
	local total = WaveMath.zombieCount(t, wave, players)
	local comp: Composition = {}
	local bosses = WaveMath.bossTypes(t, wave)
	for _, b in bosses do
		comp[b] = (comp[b] or 0) + 1
	end
	local rest = math.max(0, total - #bosses)

	-- 10-я и подобные: все обычные — один тип
	local same = WaveMath.AllSame[wave]
	if same then
		comp[same] = (comp[same] or 0) + rest
		return comp
	end

	-- особые по расписанию (не больше, чем осталось мест)
	local free = rest
	for _, rule in WaveMath.Schedule do
		if ruleActive(rule, wave) and free > 0 then
			local n = if rule.kind == "count" then math.floor(ruleValue(rule, wave)) else math.floor(rest * ruleValue(rule, wave) + 0.5)
			n = math.min(n, free)
			if n > 0 then
				comp[rule.id] = (comp[rule.id] or 0) + n
				free -= n
			end
		end
	end

	-- остальное — ходоки и бегуны
	local runners = math.floor(free * WaveMath.runnerShare(t, wave) + 0.5)
	if free - runners > 0 then
		comp.Walker = free - runners
	end
	if runners > 0 then
		comp.Runner = runners
	end

	for _, r in WaveMath.Replace do
		if wave >= r.from and wave <= r.to and comp[r.old] then
			comp[r.new] = (comp[r.new] or 0) + comp[r.old]
			comp[r.old] = nil
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

return WaveMath
