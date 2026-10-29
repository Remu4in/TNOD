--!strict
-- Правила лобби без Roblox API: отряды (кто видит, кто входит, кто приглашает и запускает) и площадки запуска.
-- Игроки — числа (UserId), время — секунды любой монотонной шкалы. LobbyService хранит состояние и вызывает эти функции;
-- решение «друг ли игрок владельцу» приходит параметром (Player:IsFriendsWith асинхронный и живёт в сервисе).

local LobbyRules = {}

export type Mode = "Public" | "Friends" | "Invite"

export type Squad = {
	id: number,
	owner: number,
	mode: Mode,
	members: { number }, -- по порядку входа; members[1] — владелец, если он в отряде
	invited: { [number]: number }, -- userId → когда приглашение истекает
	locked: boolean, -- отряд уже стартует: изменения закрыты
}

export type Pad = {
	members: { number },
	startedAt: number?, -- когда встал первый игрок (начало отсчёта)
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

-- ===== Отряды =====

function LobbyRules.newSquad(id: number, owner: number, mode: Mode): Squad
	return { id = id, owner = owner, mode = mode, members = { owner }, invited = {}, locked = false }
end

function LobbyRules.isMember(squad: Squad, uid: number): boolean
	return indexOf(squad.members, uid) ~= nil
end

function LobbyRules.isInvited(squad: Squad, uid: number, now: number): boolean
	local untilT = squad.invited[uid]
	return untilT ~= nil and now < untilT
end

function LobbyRules.expireInvites(squad: Squad, now: number)
	for uid, untilT in squad.invited do
		if now >= untilT then
			squad.invited[uid] = nil
		end
	end
end

function LobbyRules.inviteCount(squad: Squad, now: number): number
	local n = 0
	for uid in squad.invited do
		if LobbyRules.isInvited(squad, uid, now) then
			n += 1
		end
	end
	return n
end

-- Виден ли отряд игроку в списке: Public — всем, Friends — друзьям владельца, Invite — только приглашённым; участникам — всегда
function LobbyRules.canSee(squad: Squad, uid: number, isFriendOfOwner: boolean, now: number): boolean
	if LobbyRules.isMember(squad, uid) or LobbyRules.isInvited(squad, uid, now) then
		return true
	end
	if squad.mode == "Public" then
		return true
	end
	return squad.mode == "Friends" and isFriendOfOwner
end

function LobbyRules.canJoin(squad: Squad, uid: number, isFriendOfOwner: boolean, now: number, maxSize: number): Result
	if squad.locked then
		return no("The squad is already starting")
	end
	if LobbyRules.isMember(squad, uid) then
		return no("You are already in this squad")
	end
	if #squad.members >= maxSize then
		return no("The squad is full")
	end
	if LobbyRules.isInvited(squad, uid, now) then
		return YES -- приглашённый входит в любой отряд
	end
	if squad.mode == "Public" then
		return YES
	end
	if squad.mode == "Friends" then
		return if isFriendOfOwner then YES else no("Friends only")
	end
	return no("Invite only")
end

function LobbyRules.join(squad: Squad, uid: number)
	if not LobbyRules.isMember(squad, uid) then
		table.insert(squad.members, uid)
	end
	squad.invited[uid] = nil
end

-- Выход из отряда. "disband" — отряд опустел и удаляется; "owner" — владелец сменился; "ok" — вышел рядовой участник
function LobbyRules.leave(squad: Squad, uid: number): string
	local i = indexOf(squad.members, uid)
	if not i then
		return "ok"
	end
	table.remove(squad.members, i)
	if #squad.members == 0 then
		return "disband"
	end
	if squad.owner == uid then
		squad.owner = squad.members[1]
		return "owner"
	end
	return "ok"
end

-- Пригласить может только владелец: не себя, не участника, не в полный и не в стартующий отряд, и не больше maxInvites сразу
function LobbyRules.canInvite(squad: Squad, by: number, target: number, now: number, maxSize: number, maxInvites: number): Result
	if squad.locked then
		return no("The squad is already starting")
	end
	if by ~= squad.owner or not LobbyRules.isMember(squad, by) then
		return no("Only the squad leader can invite")
	end
	if target == by then
		return no("You can't invite yourself")
	end
	if LobbyRules.isMember(squad, target) then
		return no("Already in the squad")
	end
	if #squad.members >= maxSize then
		return no("The squad is full")
	end
	if LobbyRules.inviteCount(squad, now) >= maxInvites and not LobbyRules.isInvited(squad, target, now) then
		return no("Too many pending invites")
	end
	return YES
end

function LobbyRules.invite(squad: Squad, target: number, now: number, ttl: number)
	squad.invited[target] = now + ttl
end

function LobbyRules.canSetMode(squad: Squad, by: number, mode: any): Result
	if squad.locked then
		return no("The squad is already starting")
	end
	if by ~= squad.owner then
		return no("Only the squad leader can do that")
	end
	if not LobbyRules.isMode(mode) then
		return no("Unknown mode")
	end
	return YES
end

function LobbyRules.canKick(squad: Squad, by: number, target: number): Result
	if squad.locked then
		return no("The squad is already starting")
	end
	if by ~= squad.owner then
		return no("Only the squad leader can do that")
	end
	if target == by or not LobbyRules.isMember(squad, target) then
		return no("Can't remove this player")
	end
	return YES
end

function LobbyRules.canStart(squad: Squad, by: number): Result
	if squad.locked then
		return no("The squad is already starting")
	end
	if by ~= squad.owner then
		return no("Only the squad leader can start")
	end
	if #squad.members < 1 then
		return no("The squad is empty")
	end
	return YES
end

-- ===== Площадки запуска =====

function LobbyRules.newPad(): Pad
	return { members = {}, startedAt = nil }
end

function LobbyRules.padHas(pad: Pad, uid: number): boolean
	return indexOf(pad.members, uid) ~= nil
end

-- Сколько секунд осталось до старта (nil — отсчёт не идёт)
function LobbyRules.padRemaining(pad: Pad, now: number, countdown: number): number?
	local t = pad.startedAt
	if not t then
		return nil
	end
	return math.max(0, countdown - (now - t))
end

function LobbyRules.padCanJoin(pad: Pad, uid: number, now: number, maxSize: number, countdown: number, lockSeconds: number): Result
	if LobbyRules.padHas(pad, uid) then
		return no("You are already on this pad")
	end
	if #pad.members >= maxSize then
		return no("This pad is full")
	end
	local left = LobbyRules.padRemaining(pad, now, countdown)
	if left ~= nil and left <= lockSeconds then
		return no("This pad is about to launch")
	end
	return YES
end

function LobbyRules.padJoin(pad: Pad, uid: number, now: number)
	if LobbyRules.padHas(pad, uid) then
		return
	end
	table.insert(pad.members, uid)
	if pad.startedAt == nil then
		pad.startedAt = now
	end
end

-- Сошёл с площадки; пустая площадка сбрасывает отсчёт
function LobbyRules.padLeave(pad: Pad, uid: number)
	local i = indexOf(pad.members, uid)
	if i then
		table.remove(pad.members, i)
	end
	if #pad.members == 0 then
		pad.startedAt = nil
	end
end

-- Отсчёт кончился и на площадке достаточно игроков
function LobbyRules.padReady(pad: Pad, now: number, countdown: number, minPlayers: number): boolean
	local left = LobbyRules.padRemaining(pad, now, countdown)
	return left ~= nil and left <= 0 and #pad.members >= math.max(1, minPlayers)
end

return LobbyRules
