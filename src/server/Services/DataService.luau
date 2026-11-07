--!strict
-- Сохранение статистики игрока: UpdateAsync, ретраи, сессионная блокировка, BindToClose.
-- В Studio без доступа к API (Game Settings → Security) работает без сохранения.
--
-- На игрока — сессия с одной очередью операций (захват блокировки, запись, финальная запись): в полёте не больше одного
-- UpdateAsync, повторные запросы во время записи сливаются в одну следующую, финальная запись (release) — последняя.
-- Если профиль занят другим сервером или не загрузился, играем без записи и раз в LOCK_RETRY с пытаемся захватить
-- блокировку снова; при успехе свежий профиль из хранилища складывается с прибавкой этой сессии (profile − base).

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local DataService = {}

export type Lock = { jobId: string, at: number, sid: string? }

export type Profile = {
	version: number,
	bestWave: number,
	kills: number,
	rounds: number,
	revives: number,
	rating: number, -- сумма рейтинговых очков за все раунды (RatingService)
	bestRoundRating: number,
	perks: { [string]: number }, -- донат: право → до какого времени (os.time)
	receipts: { string }, -- последние обработанные покупки (ProcessReceipt не выдаёт дважды)
	weekClaim: number, -- за какую неделю уже выдана награда топа
	lock: Lock?,
}

type Session = {
	player: Player,
	key: string,
	sid: string, -- id сессии в блокировке: отличает эту сессию от прошлой того же игрока на этом же сервере
	profile: Profile, -- живые значения (HUD, итоги раунда), без lock
	base: Profile, -- последнее известное состояние хранилища; прибавка сессии = profile − base
	pendingSnap: Profile?, -- снимок profile последней попытки захвата (если ответ потерялся, а запись прошла)
	canSave: boolean, -- блокировка наша, пишем
	busy: boolean, -- работает очередь (UpdateAsync в полёте)
	wantAcquire: boolean,
	wantSave: boolean,
	closing: boolean, -- запрошена финальная запись: после неё — ничего
	retryScheduled: boolean,
	retryCount: number, -- сколько раз уже повторяли захват (первые повторы частые: прошлый сервер вот-вот отпустит профиль)
}

local VERSION = 1
local LOCK_TTL = 15 * 60 -- блокировка старше 15 минут считается брошенной
local LOCK_RETRY = 15 -- повтор захвата занятого / не загрузившегося профиля, с
local LOCK_RETRY_FAST = 3 -- первые LOCK_FAST_TRIES повторов: после телепорта прошлый сервер освобождает профиль за секунды
local LOCK_FAST_TRIES = 6
local CLOSE_WAIT = 25 -- BindToClose ждёт сохранений не дольше, с (лимит Roblox — 30)
local STORE_NAME = if RunService:IsStudio() then "Test_Profiles_v1" else "Profiles_v1"

local COUNTERS = { "kills", "rounds", "revives", "rating" } -- копятся: при слиянии прибавляем то, что набрано в сессии
local RECORDS = { "bestWave", "bestRoundRating" } -- рекорды: при слиянии берём максимум

local store: DataStore? = nil
local sessions: { [Player]: Session } = {}
local inFlight = 0 -- сколько очередей сейчас работает (BindToClose ждёт нуля)

-- ===== Чистые функции (без Roblox API) =====

local function default(): Profile
	return { version = VERSION, bestWave = 0, kills = 0, rounds = 0, revives = 0, rating = 0, bestRoundRating = 0, perks = {}, receipts = {}, weekClaim = 0, lock = nil }
end

-- Приводим сохранённое к актуальной схеме (миграции по version)
local function sanitize(raw: any): Profile
	local p = default()
	if typeof(raw) ~= "table" then
		return p
	end
	for _, k in COUNTERS do
		local v = raw[k]
		if typeof(v) == "number" and v == v and v >= 0 then
			(p :: any)[k] = math.floor(v)
		end
	end
	for _, k in RECORDS do
		local v = raw[k]
		if typeof(v) == "number" and v == v and v >= 0 then
			(p :: any)[k] = math.floor(v)
		end
	end
	if typeof(raw.perks) == "table" then
		for k, v in raw.perks do
			if typeof(k) == "string" and typeof(v) == "number" then
				p.perks[k] = v
			end
		end
	end
	if typeof(raw.receipts) == "table" then
		for _, v in raw.receipts do
			if typeof(v) == "string" then
				table.insert(p.receipts, v)
			end
		end
	end
	if typeof(raw.weekClaim) == "number" then
		p.weekClaim = raw.weekClaim
	end
	local lock = raw.lock
	if typeof(lock) == "table" and typeof(lock.jobId) == "string" and typeof(lock.at) == "number" then
		p.lock = { jobId = lock.jobId, at = lock.at, sid = if typeof(lock.sid) == "string" then lock.sid else nil }
	end
	return p
end

-- Копия без блокировки
local function clone(p: Profile): Profile
	local out = default()
	for _, k in COUNTERS do
		(out :: any)[k] = (p :: any)[k]
	end
	for _, k in RECORDS do
		(out :: any)[k] = (p :: any)[k]
	end
	out.perks = table.clone(p.perks)
	out.receipts = table.clone(p.receipts)
	out.weekClaim = p.weekClaim
	return out
end

-- Донат при слиянии не теряется: срок — больший, покупки — объединение (последние 100)
local function mergeDonate(out: Profile, other: Profile)
	for k, v in other.perks do
		out.perks[k] = math.max(out.perks[k] or 0, v)
	end
	for _, id in other.receipts do
		if not table.find(out.receipts, id) then
			table.insert(out.receipts, id)
		end
	end
	while #out.receipts > 100 do
		table.remove(out.receipts, 1)
	end
	out.weekClaim = math.max(out.weekClaim, other.weekClaim)
end

-- Профиль держит другая живая сессия (другой сервер или прошлая сессия игрока на этом же сервере)
local function lockedByOther(lock: Lock?, jobId: string, sid: string, now: number): boolean
	if not lock or lock.sid == sid then
		return false
	end
	if lock.jobId == jobId and lock.sid == nil then
		return false -- старый формат без sid, этот же сервер
	end
	return now - lock.at < LOCK_TTL
end

-- Свежий профиль из хранилища + прибавка сессии (live − base); счётчики прибавляем, рекорды — максимум.
-- Отрицательная прибавка (base новее live) не отнимает.
local function mergeSession(fresh: Profile, live: Profile, base: Profile): Profile
	local out = clone(fresh)
	for _, k in COUNTERS do
		(out :: any)[k] = (fresh :: any)[k] + math.max(0, (live :: any)[k] - (base :: any)[k])
	end
	for _, k in RECORDS do
		(out :: any)[k] = math.max((fresh :: any)[k], (live :: any)[k])
	end
	mergeDonate(out, live)
	return out
end

-- Что пишем при обычном сохранении, когда блокировка наша: счётчики — живые, рекорды и rating не опускаем
local function saveValue(cur: Profile, live: Profile): Profile
	local out = clone(live)
	for _, k in RECORDS do
		(out :: any)[k] = math.max((cur :: any)[k], (live :: any)[k])
	end
	out.rating = math.max(cur.rating, live.rating)
	mergeDonate(out, cur)
	return out
end

-- ===== Работа с хранилищем =====

-- В Studio без доступа к API не ждём ретраев (иначе вход растянется на 30 с)
local ATTEMPTS = if RunService:IsStudio() then 1 else 4

local function withRetry<T>(fn: () -> T): (boolean, T?)
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(string.format("[DataService] attempt %d: %s", attempt, tostring(result)))
		if attempt < ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end
	return false, nil
end

local function lockFor(s: Session): Lock
	return { jobId = game.JobId, at = os.time(), sid = s.sid }
end

-- Атрибуты для HUD/лидерборда
local function publish(s: Session)
	if s.player.Parent then
		s.player:SetAttribute("BestWave", s.profile.bestWave)
		s.player:SetAttribute("RatingTotal", s.profile.rating)
		local h = loadedHandler
		if h then
			task.spawn(h, s.player)
		end
	end
end

local loadedHandler: ((Player) -> ())? = nil -- профиль загружен (донат: атрибуты прав)

local kick: (s: Session) -> ()

local function scheduleRetry(s: Session)
	if s.retryScheduled or s.closing or not store then
		return
	end
	s.retryScheduled = true
	local delay = if s.retryCount < LOCK_FAST_TRIES then LOCK_RETRY_FAST else LOCK_RETRY
	s.retryCount += 1
	task.delay(delay, function()
		s.retryScheduled = false
		if s.closing or s.canSave or sessions[s.player] ~= s then
			return
		end
		s.wantAcquire = true
		kick(s)
	end)
end

-- Захват блокировки (первая загрузка и повторы)
local function acquire(s: Session)
	local ds = store :: DataStore
	local taken = false
	local seen: Profile? = nil -- значение в хранилище, когда профиль занят
	local written: Profile? = nil
	local snap: Profile? = nil -- с каким снимком profile записано written
	local ok = withRetry(function()
		return ds:UpdateAsync(s.key, function(old: any)
			local fresh = sanitize(old)
			local now = os.time()
			if fresh.lock and fresh.lock.sid == s.sid then
				-- прошлая попытка уже записалась (ответ потерялся): прибавка в fresh уже есть, второй раз не добавляем
				taken, seen = true, nil
				snap = s.pendingSnap or s.base
				local out = clone(fresh)
				out.lock = lockFor(s)
				written = out
				return out
			end
			if lockedByOther(fresh.lock, game.JobId, s.sid, now) then
				taken, seen, written = false, clone(fresh), nil
				return nil -- не меняем: профиль открыт в другой сессии
			end
			taken, seen = true, nil
			local live = clone(s.profile)
			s.pendingSnap = live
			snap = live
			local out = mergeSession(fresh, live, s.base)
			out.lock = lockFor(s)
			written = out
			return out
		end)
	end)
	if not ok then
		if RunService:IsStudio() then
			warn("[DataService] profile not loaded, playing without saving: " .. s.player.Name)
		else
			warn("[DataService] profile not loaded, retry in " .. LOCK_RETRY .. " s: " .. s.player.Name)
			scheduleRetry(s)
		end
		return
	end
	if taken and written and snap then
		-- то, что набрано, пока шёл UpdateAsync (profile − snap), остаётся сверху записанного
		s.profile = mergeSession(written, s.profile, snap)
		s.base = clone(written)
		s.pendingSnap = nil
		s.canSave = true
		s.retryCount = 0
		publish(s)
	elseif seen then
		-- занято (быстрый перезаход или краш сервера): показываем сохранённое + прибавку сессии, не пишем
		s.profile = mergeSession(seen, s.profile, s.base)
		s.base = seen
		publish(s)
		scheduleRetry(s)
	end
end

local function write(s: Session, release: boolean)
	local ds = store :: DataStore
	local written: Profile? = nil
	local lost = false
	local ok = withRetry(function()
		return ds:UpdateAsync(s.key, function(old: any)
			local cur = sanitize(old)
			if not (cur.lock and cur.lock.sid == s.sid) then
				lost, written = true, nil
				return nil -- блокировка не наша (перехвачена после TTL) — не пишем
			end
			lost = false
			local out = saveValue(cur, s.profile)
			out.lock = if release then nil else lockFor(s)
			written = out
			return out
		end)
	end)
	if not ok then
		return -- следующий запрос записи (автосохранение, конец раунда) попробует снова
	end
	if written then
		s.base = clone(written)
	elseif lost then
		warn("[DataService] profile lock taken by another server, writing after re-acquiring: " .. s.player.Name)
		s.canSave = false
		scheduleRetry(s)
	end
end

-- Одна операция очереди; false — очередь закончена
local function step(s: Session): boolean
	if s.closing then
		-- финальная запись покрывает и отложенную обычную; после неё сессия закрыта
		s.wantSave, s.wantAcquire = false, false
		if s.canSave then
			write(s, true)
		end
		s.canSave = false
		return false
	elseif s.wantAcquire then
		s.wantAcquire = false
		if not s.canSave then
			acquire(s)
		end
	elseif s.wantSave then
		s.wantSave = false
		if s.canSave then
			write(s, false)
		end
	else
		return false
	end
	return true
end

-- Запускает очередь, если она стоит; если работает — новые флаги подхватит текущий проход
kick = function(s: Session)
	if s.busy or not store then
		return
	end
	s.busy = true
	inFlight += 1
	while true do
		local ok, more = pcall(step, s)
		if not ok then
			warn("[DataService] queue error: " .. tostring(more))
			if s.closing then
				break
			end
		elseif not more then
			break
		end
	end
	s.busy = false
	inFlight -= 1
	if s.closing and sessions[s.player] == s then
		sessions[s.player] = nil
	end
end

local function requestSave(player: Player)
	local s = sessions[player]
	if not s or s.closing then
		return
	end
	s.wantSave = true
	task.spawn(kick, s)
end

-- Финальная запись со снятием блокировки; повторные вызовы (PlayerRemoving + BindToClose) ничего не делают
local function release(player: Player)
	local s = sessions[player]
	if not s or s.closing then
		return
	end
	s.closing = true
	if store then
		task.spawn(kick, s) -- если очередь работает, текущий проход сам сделает финальную запись
	else
		sessions[player] = nil
	end
end

function DataService.get(player: Player): Profile?
	local s = sessions[player]
	return if s and not s.closing then s.profile else nil
end

-- Записать профили игроков и дождаться конца записи (перед телепортом: новый сервер получит свежие данные, а блокировку
-- снимет PlayerRemoving уже на уходе). Не ждёт дольше timeout секунд; без блокировки (профиль занят) просто не пишет.
function DataService.flush(players: { Player }, timeout: number)
	local deadline = os.clock() + timeout
	for _, p in players do
		requestSave(p)
	end
	for _, p in players do
		local s = sessions[p]
		while s and (s.busy or s.wantSave or s.wantAcquire) and os.clock() < deadline do
			task.wait(0.1)
		end
	end
end

function DataService.setLoadedHandler(handler: (Player) -> ())
	loadedHandler = handler
end

-- Донат: права игрока (таблица живая: менять и звать touch), покупки и награда недели
function DataService.perks(player: Player): { [string]: number }?
	local s = sessions[player]
	return if s and not s.closing then s.profile.perks else nil
end

function DataService.touch(player: Player)
	requestSave(player)
end

function DataService.hasReceipt(player: Player, id: string): boolean
	local s = sessions[player]
	return s ~= nil and table.find(s.profile.receipts, id) ~= nil
end

function DataService.addReceipt(player: Player, id: string)
	local s = sessions[player]
	if s then
		table.insert(s.profile.receipts, id)
		requestSave(player)
	end
end

function DataService.weekClaim(player: Player): number
	local s = sessions[player]
	return if s then s.profile.weekClaim else 0
end

function DataService.setWeekClaim(player: Player, week: number)
	local s = sessions[player]
	if s then
		s.profile.weekClaim = week
		requestSave(player)
	end
end

-- Профиль загружен и записывается (блокировка наша; не по умолчанию после сбоя и не занят другим сервером)
function DataService.canSave(player: Player): boolean
	local s = sessions[player]
	return s ~= nil and s.canSave and not s.closing
end

-- Итоги раунда в профиль + обновление атрибутов для HUD/лидерборда
function DataService.recordRound(player: Player, wave: number, kills: number, revives: number)
	local s = sessions[player]
	if not s or s.closing then
		return
	end
	local p = s.profile
	p.bestWave = math.max(p.bestWave, wave)
	p.kills += kills
	p.rounds += 1
	p.revives += revives
	player:SetAttribute("BestWave", p.bestWave)
	requestSave(player)
end

-- Рейтинг раунда в профиль; возвращает новую сумму (nil — профиля нет)
function DataService.addRating(player: Player, gained: number): number?
	local s = sessions[player]
	if not s or s.closing then
		return nil
	end
	local p = s.profile
	p.rating += math.floor(gained)
	p.bestRoundRating = math.max(p.bestRoundRating, math.floor(gained))
	player:SetAttribute("RatingTotal", p.rating)
	requestSave(player)
	return p.rating
end

function DataService.init()
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = if ok then ds else nil

	local function onJoin(player: Player)
		if sessions[player] or not player.Parent then
			return
		end
		local s: Session = {
			player = player,
			key = "Player_" .. player.UserId,
			sid = HttpService:GenerateGUID(false),
			profile = default(),
			base = default(),
			pendingSnap = nil,
			canSave = false,
			busy = false,
			wantAcquire = true,
			wantSave = false,
			closing = false,
			retryScheduled = false,
			retryCount = 0,
		}
		sessions[player] = s
		kick(s) -- загрузка; если игрок вышел во время неё, очередь сама сделает финальную запись и снимет блокировку
		if not player.Parent then
			release(player) -- на случай, если PlayerRemoving прошёл раньше, чем появилась сессия
			return
		end
		publish(s)
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, pl in Players:GetPlayers() do
		task.spawn(onJoin, pl)
	end
	Players.PlayerRemoving:Connect(release)
	game:BindToClose(function()
		for _, pl in Players:GetPlayers() do
			release(pl)
		end
		-- ждём фактического конца очередей (и тех, что запустил PlayerRemoving), но не дольше CLOSE_WAIT
		local deadline = os.clock() + CLOSE_WAIT
		while inFlight > 0 and os.clock() < deadline do
			task.wait(0.2)
		end
		if inFlight > 0 then
			warn("[DataService] shutdown: saves did not finish in time: " .. inFlight)
		end
	end)

	-- автосохранение
	task.spawn(function()
		while true do
			task.wait(120)
			for _, pl in Players:GetPlayers() do
				requestSave(pl)
			end
		end
	end)
end

return DataService
