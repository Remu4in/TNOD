--!strict
-- Сохранение статистики игрока: UpdateAsync, ретраи, сессионная блокировка, BindToClose.
-- В Studio без доступа к API (Game Settings → Security) работает без сохранения.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local DataService = {}

export type Profile = {
	version: number,
	bestWave: number,
	kills: number,
	rounds: number,
	revives: number,
	rating: number, -- сумма рейтинговых очков за все раунды (RatingService)
	bestRoundRating: number,
	lock: { jobId: string, at: number }?,
}

local VERSION = 1
local LOCK_TTL = 15 * 60 -- блокировка старше 15 минут считается брошенной
local STORE_NAME = if RunService:IsStudio() then "Test_Profiles_v1" else "Profiles_v1"

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
local canSave: { [Player]: boolean } = {}

local function default(): Profile
	return { version = VERSION, bestWave = 0, kills = 0, rounds = 0, revives = 0, rating = 0, bestRoundRating = 0, lock = nil }
end

-- Приводим сохранённое к актуальной схеме (миграции по version)
local function sanitize(raw: any): Profile
	local p = default()
	if typeof(raw) ~= "table" then
		return p
	end
	for _, key in { "bestWave", "kills", "rounds", "revives", "rating", "bestRoundRating" } do
		local v = raw[key]
		if typeof(v) == "number" and v == v and v >= 0 then
			(p :: any)[key] = math.floor(v)
		end
	end
	if typeof(raw.lock) == "table" and typeof(raw.lock.jobId) == "string" and typeof(raw.lock.at) == "number" then
		p.lock = { jobId = raw.lock.jobId, at = raw.lock.at }
	end
	return p
end

local function key(player: Player): string
	return "Player_" .. player.UserId
end

-- В Studio без доступа к API не ждём ретраев (иначе вход растянется на 30 с)
local ATTEMPTS = if RunService:IsStudio() then 1 else 4

local function withRetry<T>(fn: () -> T): (boolean, T?)
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(string.format("[DataService] попытка %d: %s", attempt, tostring(result)))
		if attempt < ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end
	return false, nil
end

local function load(player: Player)
	if not store then
		profiles[player] = default()
		canSave[player] = false
		return
	end
	local ds = store :: DataStore
	local jobId = game.JobId
	local lockedByOther = false
	local ok, result = withRetry(function()
		return ds:UpdateAsync(key(player), function(old: any)
			local p = sanitize(old)
			local lock = p.lock
			if lock and lock.jobId ~= jobId and os.time() - lock.at < LOCK_TTL then
				lockedByOther = true
				return nil -- не меняем: профиль открыт на другом сервере
			end
			lockedByOther = false
			p.lock = { jobId = jobId, at = os.time() }
			return p
		end)
	end)
	if not ok then
		warn("[DataService] не удалось загрузить профиль, играем без сохранения: " .. player.Name)
		profiles[player] = default()
		canSave[player] = false
		return
	end
	if lockedByOther then
		-- скорее всего, быстрый перезаход: старый сервер ещё сохраняет. Играем без записи, чтобы не затереть.
		profiles[player] = sanitize(result)
		canSave[player] = false
		return
	end
	profiles[player] = sanitize(result)
	canSave[player] = true
end

local function save(player: Player, release: boolean)
	local p = profiles[player]
	if not p or not canSave[player] or not store then
		return
	end
	local ds = store :: DataStore
	local jobId = game.JobId
	withRetry(function()
		return ds:UpdateAsync(key(player), function(old: any)
			local cur = sanitize(old)
			if cur.lock and cur.lock.jobId ~= jobId then
				return nil -- блокировку перехватил другой сервер — не пишем
			end
			local out: Profile = {
				version = VERSION,
				bestWave = math.max(cur.bestWave, p.bestWave),
				kills = p.kills,
				rounds = p.rounds,
				revives = p.revives,
				rating = math.max(cur.rating, p.rating),
				bestRoundRating = math.max(cur.bestRoundRating, p.bestRoundRating),
				lock = if release then nil else { jobId = jobId, at = os.time() },
			}
			return out
		end)
	end)
end

function DataService.get(player: Player): Profile?
	return profiles[player]
end

-- Итоги раунда в профиль + обновление атрибутов для HUD/лидерборда
function DataService.recordRound(player: Player, wave: number, kills: number, revives: number)
	local p = profiles[player]
	if not p then
		return
	end
	p.bestWave = math.max(p.bestWave, wave)
	p.kills += kills
	p.rounds += 1
	p.revives += revives
	player:SetAttribute("BestWave", p.bestWave)
	task.spawn(save, player, false)
end

-- Рейтинг раунда в профиль; возвращает новую сумму (nil — профиля нет)
function DataService.addRating(player: Player, gained: number): number?
	local p = profiles[player]
	if not p then
		return nil
	end
	p.rating += math.floor(gained)
	p.bestRoundRating = math.max(p.bestRoundRating, math.floor(gained))
	player:SetAttribute("RatingTotal", p.rating)
	task.spawn(save, player, false)
	return p.rating
end

function DataService.init()
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = if ok then ds else nil

	local function onJoin(player: Player)
		load(player)
		local p = profiles[player]
		if p and player.Parent then
			player:SetAttribute("BestWave", p.bestWave)
			player:SetAttribute("RatingTotal", p.rating)
		end
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, pl in Players:GetPlayers() do
		task.spawn(onJoin, pl)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player, true)
		profiles[player] = nil
		canSave[player] = nil
	end)
	game:BindToClose(function()
		for _, pl in Players:GetPlayers() do
			task.spawn(save, pl, true)
		end
		task.wait(3)
	end)

	-- автосохранение
	task.spawn(function()
		while true do
			task.wait(120)
			for _, pl in Players:GetPlayers() do
				task.spawn(save, pl, false)
			end
		end
	end)
end

return DataService
