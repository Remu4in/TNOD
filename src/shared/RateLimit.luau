--!strict
-- Ограничение частоты запросов от клиента (на ключ и игрока).

local RateLimit = {}

local last: { [Player]: { [string]: number } } = {}

-- true, если с прошлого разрешённого вызова прошло не меньше minInterval секунд
function RateLimit.allow(player: Player, key: string, minInterval: number): boolean
	local now = os.clock()
	local byKey = last[player]
	if not byKey then
		byKey = {}
		last[player] = byKey
	end
	local prev = byKey[key]
	if prev and now - prev < minInterval then
		return false
	end
	byKey[key] = now
	return true
end

function RateLimit.forget(player: Player)
	last[player] = nil
end

return RateLimit
