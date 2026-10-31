--!strict
-- Правила лобби без Roblox API: зоны сбора команды (кто может войти, кто хост, передача хоста, заполнение, отсчёт).
-- Игроки — числа (UserId), время — секунды любой монотонной шкалы. LobbyService хранит состояние и вызывает эти функции;
-- решение «друг ли игрок хосту» приходит параметром (Player:IsFriendsWith асинхронный и живёт в сервисе).
--
-- Жизнь зоны:  free ──(вошёл первый: он хост)──▶ setup ──(хост нажал «Open squad»)──▶ open ──(полна: отсчёт / «Start now»)──▶ launching
--              ▲                                  │ «Cancel» / хост ушёл                │ хост ушёл: хостом станет следующий
--              └──────────────────────────────────┴─────────────────────────────────────┘ зона опустела: снова free

local LobbyRules = {}

export type Mode = "Public" | "Friends" | "Invite"
export type ZoneState = "free" | "setup" | "open" | "launching"

export type Zone = {
	host: number?, -- UserId хоста; nil, пока зона свободна
	members: { number }, -- по порядку входа; members[1] — самый давний (следующий хост)
	state: ZoneState,
	size: number, -- сколько игроков хост хочет собрать (1…maxSize)
	mode: Mode,
	invited: { [number]: number }, -- userId → когда приглашение истекает
	kicked: { [number]: boolean }, -- удалённые хостом: не пустим снова, пока зона не освободится
	fullAt: number?, -- когда зона заполнилась (начало отсчёта)
	setupAt: number?, -- когда хост встал (для тайм-аута настройки)
}

export type Result = { ok: boolean, reason: string? }

local MODES: { [string]: boolean } = { Public = true, Friends = true, Invite = true }

local function indexOf(list: { number }, uid: number): number?
	for i, v in list do
		if v == uid then
			return i
		end
	end
	return nil
end

local function no(reason: string): Result
	return { ok = false, reason = reason }
end

local YES: Result = { ok = true, reason = nil }

function LobbyRules.isMode(v: any): boolean
	return typeof(v) == "string" and MODES[v] == true
end

-- UserId из данных клиента: целое положительное число
function LobbyRules.isUserId(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and v > 0 and v < 2 ^ 52
end

-- Размер отряда из данных клиента: целое от 1 до maxSize
function LobbyRules.isZoneSize(v: any, maxSize: number): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and v >= 1 and v <= maxSize
end

-- ===== Зона сбора =====

function LobbyRules.newZone(maxSize: number): Zone
	return { host = nil, members = {}, state = "free", size = maxSize, mode = "Public", invited = {}, kicked = {}, fullAt = nil, setupAt = nil }
end

-- Зона снова свободна (настройки по умолчанию)
function LobbyRules.reset(zone: Zone, maxSize: number)
	zone.host = nil
	zone.members = {}
	zone.state = "free"
	zone.size = maxSize
	zone.mode = "Public"
	zone.invited = {}
	zone.kicked = {}
	zone.fullAt = nil
	zone.setupAt = nil
end

function LobbyRules.has(zone: Zone, uid: number): boolean
	return indexOf(zone.members, uid) ~= nil
end

function LobbyRules.isInvited(zone: Zone, uid: number, now: number): boolean
	local untilT = zone.invited[uid]
	return untilT ~= nil and now < untilT
end

function LobbyRules.expireInvites(zone: Zone, now: number)
	for uid, untilT in zone.invited do
		if now >= untilT then
			zone.invited[uid] = nil
		end
	end
end

local function inviteCount(zone: Zone, now: number): number
	local n = 0
	for uid in zone.invited do
		if LobbyRules.isInvited(zone, uid, now) then
			n += 1
		end
	end
	return n
end

-- Заполнена ли зона (только открытая)
function LobbyRules.isFull(zone: Zone): boolean
	return zone.state == "open" and #zone.members >= zone.size
end

-- Пересчёт начала отсчёта: идёт, только пока открытая зона полна
local function syncFull(zone: Zone, now: number)
	if LobbyRules.isFull(zone) then
		if zone.fullAt == nil then
			zone.fullAt = now
		end
	else
		zone.fullAt = nil
	end
end

-- Может ли игрок войти в зону (isFriendOfHost — друг ли он хосту)
function LobbyRules.canEnter(zone: Zone, uid: number, isFriendOfHost: boolean, now: number): Result
	if zone.state == "free" then
		return YES -- первый вошедший станет хостом
	end
	if LobbyRules.has(zone, uid) then
		return no("You are already in this zone")
	end
	if zone.state == "launching" then
		return no("This squad is already launching")
	end
	if zone.state == "setup" then
		return no("The host is still setting up")
	end
	if zone.kicked[uid] then
		return no("The host removed you from this squad")
	end
	if #zone.members >= zone.size then
		return no("This squad is full")
	end
	if LobbyRules.isInvited(zone, uid, now) then
		return YES -- приглашённый входит при любом доступе
	end
	if zone.mode == "Public" then
		return YES
	end
	if zone.mode == "Friends" then
		return if isFriendOfHost then YES else no("Friends only")
	end
	return no("Invite only")
end

-- Игрок вошёл (после canEnter). "host" — стал хостом свободной зоны; "member" — обычный участник
function LobbyRules.enter(zone: Zone, uid: number, now: number): string
	if zone.state == "free" then
		zone.host = uid
		zone.members = { uid }
		zone.state = "setup"
		zone.setupAt = now
		return "host"
	end
	if not LobbyRules.has(zone, uid) then
		table.insert(zone.members, uid)
	end
	zone.invited[uid] = nil
	syncFull(zone, now)
	return "member"
end

-- Игрок ушёл из зоны. "none" — его там не было; "free" — зона опустела и свободна; "host" — сменился хост; "ok" — ушёл рядовой участник
function LobbyRules.leave(zone: Zone, uid: number, maxSize: number, now: number): string
	local i = indexOf(zone.members, uid)
	if not i then
		return "none"
	end
	table.remove(zone.members, i)
	if #zone.members == 0 then
		LobbyRules.reset(zone, maxSize)
		return "free"
	end
	syncFull(zone, now)
	if zone.host == uid then
		zone.host = zone.members[1]
		return "host"
	end
	return "ok"
end

-- Хост меняет число мест и доступ (в настройке и в открытой зоне). Размер не меньше числа уже вошедших
function LobbyRules.configure(zone: Zone, by: number, size: any, mode: any, maxSize: number, now: number): Result
	if zone.host ~= by or (zone.state ~= "setup" and zone.state ~= "open") then
		return no("Only the host can change the settings")
	end
	if not LobbyRules.isZoneSize(size, maxSize) then
		return no("Squad size must be from 1 to " .. maxSize)
	end
	if not LobbyRules.isMode(mode) then
		return no("Unknown access mode")
	end
	if (size :: number) < #zone.members then
		return no("Too many players are already inside")
	end
	zone.size = size :: number
	zone.mode = mode :: Mode
	syncFull(zone, now)
	return YES
end

-- Хост подтвердил настройки: зона открывается
function LobbyRules.open(zone: Zone, by: number, now: number): Result
	if zone.host ~= by or zone.state ~= "setup" then
		return no("Only the host can open the squad")
	end
	zone.state = "open"
	syncFull(zone, now)
	return YES
end

-- «Start now»: только хост, зона не стартует уже
function LobbyRules.canStart(zone: Zone, by: number): Result
	if zone.host ~= by or (zone.state ~= "setup" and zone.state ~= "open") then
		return no("Only the host can start")
	end
	return YES
end

-- «Cancel»: хост распускает зону; вызывающий сам выведет игроков и вызовет reset
function LobbyRules.canCancel(zone: Zone, by: number): Result
	if zone.host ~= by or (zone.state ~= "setup" and zone.state ~= "open") then
		return no("Only the host can cancel")
	end
	return YES
end

-- Удалить участника (не хоста): он больше не войдёт, пока зона не освободится
function LobbyRules.kick(zone: Zone, by: number, target: number, now: number): Result
	if zone.host ~= by or (zone.state ~= "setup" and zone.state ~= "open") then
		return no("Only the host can remove players")
	end
	if target == by or not LobbyRules.has(zone, target) then
		return no("Can't remove this player")
	end
	local i = indexOf(zone.members, target) :: number
	table.remove(zone.members, i)
	zone.kicked[target] = true
	syncFull(zone, now)
	return YES
end

-- Пригласить: только хост, не себя, не участника, не больше maxInvites сразу
function LobbyRules.invite(zone: Zone, by: number, target: number, now: number, ttl: number, maxInvites: number): Result
	if zone.host ~= by or (zone.state ~= "setup" and zone.state ~= "open") then
		return no("Only the host can invite")
	end
	if target == by then
		return no("You can't invite yourself")
	end
	if LobbyRules.has(zone, target) then
		return no("Already in the squad")
	end
	if inviteCount(zone, now) >= maxInvites and not LobbyRules.isInvited(zone, target, now) then
		return no("Too many pending invites")
	end
	zone.invited[target] = now + ttl
	zone.kicked[target] = nil
	return YES
end

-- Сколько секунд до старта (nil — отсчёт не идёт)
function LobbyRules.countdownLeft(zone: Zone, now: number, countdown: number): number?
	local t = zone.fullAt
	if t == nil or zone.state ~= "open" then
		return nil
	end
	return math.max(0, countdown - (now - t))
end

function LobbyRules.ready(zone: Zone, now: number, countdown: number): boolean
	local left = LobbyRules.countdownLeft(zone, now, countdown)
	return left ~= nil and left <= 0
end

-- Зона началась запуском: изменения закрыты
function LobbyRules.lock(zone: Zone)
	zone.state = "launching"
	zone.fullAt = nil
end

-- Запуск не удался: зона снова открыта (если ещё есть кому)
function LobbyRules.unlock(zone: Zone, now: number)
	if zone.state == "launching" then
		zone.state = "open"
		syncFull(zone, now)
	end
end

-- Хост завис в настройке дольше timeout секунд
function LobbyRules.setupExpired(zone: Zone, now: number, timeout: number): boolean
	return zone.state == "setup" and zone.setupAt ~= nil and now - (zone.setupAt :: number) >= timeout
end

return LobbyRules
