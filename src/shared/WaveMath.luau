--!strict
-- Чистые формулы волн: без сервисов Roblox, поэтому тестируются вне Studio.

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

export type Composition = { Walker: number, Runner: number, Brute: number }

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

function WaveMath.composition(t: WaveTuning, wave: number, players: number): Composition
	local total = WaveMath.zombieCount(t, wave, players)
	local brutes = WaveMath.bossCount(t, wave)
	local rest = math.max(0, total - brutes)
	local runners = math.floor(rest * WaveMath.runnerShare(t, wave) + 0.5)
	return { Walker = rest - runners, Runner = runners, Brute = brutes }
end

-- Список типов для очереди спавна: перемешанный, боссы в конце волны.
function WaveMath.spawnQueue(comp: Composition, rng: Random): { string }
	local queue: { string } = {}
	for _ = 1, comp.Walker do
		table.insert(queue, "Walker")
	end
	for _ = 1, comp.Runner do
		table.insert(queue, "Runner")
	end
	for i = #queue, 2, -1 do
		local j = rng:NextInteger(1, i)
		queue[i], queue[j] = queue[j], queue[i]
	end
	for _ = 1, comp.Brute do
		table.insert(queue, "Brute")
	end
	return queue
end

return WaveMath
