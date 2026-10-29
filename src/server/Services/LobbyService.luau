--!strict
-- Лобби и пати. Одно место, два режима: публичный сервер — лобби, резервный сервер того же места — матч (идёт обычный раунд).
-- Лобби: площадки-«грузовики» (до 6 игроков, отсчёт), свои отряды (Public / Friends only / Invite only, приглашения, Start),
-- «Play solo», витрина рейтинга. Всех, кто в группе, сервер сам телепортирует на новый резервный сервер (TeleportData — состав группы).
-- Клиент недоверенный: он шлёт только команды (LobbyCmd), состав группы и разрешения решает сервер (правила — Shared/LobbyRules).
-- Студия: телепорта нет, при Config.Lobby.StudioSkipTeleport этот же сервер переключается в матч и обратно (init.server → onStudioStart).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local Lighting = game:GetService("Lighting")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local LobbyRules = require(Shared:WaitForChild("LobbyRules"))
local DataService = require(script.Parent:WaitForChild("DataService"))
local RatingService = require(script.Parent:WaitForChild("RatingService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local LobbyBuilder = require(script.Parent.Parent:WaitForChild("Locations"):WaitForChild("Lobby"))

local L = Config.Lobby

local LobbyService = {}

type Squad = LobbyRules.Squad
type Pad = LobbyRules.Pad

export type Handlers = {
	-- Studio: «телепорт» — этот же сервер становится матчем для группы
	onStudioStart: ({ Player }, { [string]: any }) -> (),
}

local mode: string = "match" -- "lobby" | "match"
local studio = RunService:IsStudio()
local handlers: Handlers? = nil
local info: LobbyBuilder.LobbyInfo? = nil

local squads: { [number]: Squad } = {}
local squadOfUid: { [number]: number } = {}
local nextSquadId = 1
local pads: { Pad } = {}
local padOfUid: { [number]: number } = {}
local launching: { [Player]: boolean } = {}
local friendCache: { [string]: boolean } = {}
local nameCache: { [number]: string } = {}
local dirty = true
local lastHint: { [Player]: number } = {}
local savedLighting: { [string]: any }? = nil
local padShown: { [number]: string } = {}

-- Studio: ждём, пока кто-то снова запустит матч после возврата в лобби
local studioStartPending = false
-- кто нажал «Back to lobby» на экране итогов
local wantBack: { [Player]: boolean } = {}

local function notify(player: Player, text: string, seconds: number?)
	if player.Parent then
		Remotes.get("Notify"):FireClient(player, text, seconds or 3)
	end
end

local function now(): number
	return os.clock()
end

local function uidOf(player: Player): number
	return player.UserId
end

-- ===== Режим сервера =====

function LobbyService.detectMode(): string
	if not L.Enabled then
		return "match"
	end
	if studio then
		-- ForceMode работает только в Studio: на живом сервере его не слушаем
		if L.ForceMode == "lobby" or L.ForceMode == "match" then
			return L.ForceMode :: string
		end
		return "lobby"
	end
	-- резервный сервер, созданный ReserveServer (у VIP-серверов владелец ≠ 0: это обычное лобби для друзей)
	if game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
		return "match"
	end
	return "lobby"
end

function LobbyService.mode(): string
	return mode
end

local function setMode(m: string)
	mode = m
	ReplicatedStorage:SetAttribute("Mode", m)
end

-- ===== Свет лобби (в Studio лобби и матч делят Lighting: запоминаем и возвращаем) =====

local LIGHT_PROPS = { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "ExposureCompensation", "FogEnd", "FogColor" }

local function applyLobbyLighting()
	if not savedLighting then
		local snap: { [string]: any } = {}
		for _, k in LIGHT_PROPS do
			snap[k] = (Lighting :: any)[k]
		end
		savedLighting = snap
	end
	Lighting.ClockTime = 0
	Lighting.Brightness = 0.35
	Lighting.Ambient = Color3.fromRGB(70, 78, 110)
	Lighting.OutdoorAmbient = Color3.fromRGB(80, 92, 130)
	Lighting.ExposureCompensation = 0.25
	Lighting.FogEnd = 1200
	Lighting.FogColor = Color3.fromRGB(30, 36, 56)
	local skies = ServerStorage:FindFirstChild("Skies")
	if skies then
		for _, s in Lighting:GetChildren() do
			if s:IsA("Sky") and s.Name ~= "NightSky" then
				s.Parent = skies
			end
		end
		local night = skies:FindFirstChild("NightSky")
		if night and not Lighting:FindFirstChild("NightSky") then
			night.Parent = Lighting
		end
	end
end

local function restoreLighting()
	local snap = savedLighting
	if snap then
		for k, v in snap do
			(Lighting :: any)[k] = v
		end
		savedLighting = nil
	end
end

-- ===== Друзья =====

local function friendKey(a: number, b: number): string
	return if a < b then a .. ":" .. b else b .. ":" .. a
end

local function isFriends(a: number, b: number): boolean
	return friendCache[friendKey(a, b)] == true
end

local function probeFriends(player: Player)
	for _, other in Players:GetPlayers() do
		if other ~= player then
			task.spawn(function()
				local key = friendKey(player.UserId, other.UserId)
				if friendCache[key] ~= nil then
					return
				end
				local ok, res = pcall(function()
					return player:IsFriendsWith(other.UserId)
				end)
				friendCache[key] = ok and res == true
				dirty = true
			end)
		end
	end
end

-- ===== Отряды =====

local function playerOfUid(uid: number): Player?
	return Players:GetPlayerByUserId(uid)
end

local function nameOf(uid: number): string
	local p = playerOfUid(uid)
	if p then
		return p.DisplayName
	end
	return nameCache[uid] or tostring(uid)
end

local function squadOf(player: Player): Squad?
	local id = squadOfUid[uidOf(player)]
	return if id then squads[id] else nil
end

local function squadPlayers(squad: Squad): { Player }
	local list: { Player } = {}
	for _, uid in squad.members do
		local p = playerOfUid(uid)
		if p then
			table.insert(list, p)
		end
	end
	return list
end

local function removeFromPad(uid: number)
	local i = padOfUid[uid]
	if i then
		LobbyRules.padLeave(pads[i], uid)
		padOfUid[uid] = nil
		dirty = true
	end
end

local function leaveSquad(player: Player)
	local uid = uidOf(player)
	local id = squadOfUid[uid]
	local squad = if id then squads[id] else nil
	squadOfUid[uid] = nil
	if not squad then
		return
	end
	local res = LobbyRules.leave(squad, uid)
	if res == "disband" then
		squads[squad.id] = nil
	elseif res == "owner" then
		local boss = playerOfUid(squad.owner)
		if boss then
			notify(boss, "You are the squad leader now", 3)
		end
	end
	dirty = true
end

local function disband(squad: Squad)
	for _, uid in squad.members do
		squadOfUid[uid] = nil
	end
	squads[squad.id] = nil
	dirty = true
end

-- ===== Состояние для клиента =====

local function buildState(player: Player): { [string]: any }
	local t = now()
	local uid = uidOf(player)
	local mine = squadOf(player)
	local state: { [string]: any } = { mode = mode, launching = launching[player] == true }
	if mine then
		local members = {}
		for _, m in mine.members do
			table.insert(members, { uid = m, name = nameOf(m) })
		end
		state.squad = { id = mine.id, owner = mine.owner, mode = mine.mode, members = members, max = L.MaxSquad, locked = mine.locked }
	end
	local list = {}
	local invites = {}
	for id, sq in squads do
		local ownerFriend = isFriends(uid, sq.owner)
		if LobbyRules.isInvited(sq, uid, t) then
			table.insert(invites, { squadId = id, from = nameOf(sq.owner), left = math.ceil((sq.invited[uid] :: number) - t) })
		end
		if not mine and LobbyRules.canSee(sq, uid, ownerFriend, t) then
			table.insert(list, {
				id = id,
				owner = nameOf(sq.owner),
				mode = sq.mode,
				count = #sq.members,
				max = L.MaxSquad,
				joinable = LobbyRules.canJoin(sq, uid, ownerFriend, t, L.MaxSquad).ok,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	state.squads = list
	state.invites = invites
	state.onPad = padOfUid[uid]
	return state
end

local function broadcast()
	dirty = false
	for _, p in Players:GetPlayers() do
		Remotes.get("LobbyState"):FireClient(p, buildState(p))
	end
end

local function sendState(player: Player, open: boolean?)
	local s = buildState(player)
	if open then
		s.open = true
	end
	Remotes.get("LobbyState"):FireClient(player, s)
end

-- ===== Телепорт =====

local function alive(list: { Player }): { Player }
	local out: { Player } = {}
	for _, p in list do
		if p.Parent == Players then
			table.insert(out, p)
		end
	end
	return out
end

local function teleportData(kind: string, list: { Player }, squad: Squad?): { [string]: any }
	local ids = {}
	for _, p in list do
		table.insert(ids, p.UserId)
	end
	return { v = 1, from = "lobby", kind = kind, members = ids, leader = if squad then squad.owner else ids[1], at = os.time() }
end

local failedAt: { [Player]: string } = {}

-- Общий телепорт группы: резервный сервер (или лобби), 3 попытки с паузой. true — все ушли (или ушли те, кто ещё был)
local function teleportGroup(list: { Player }, placeId: number, reserveCode: string?, data: { [string]: any }): boolean
	local group = alive(list)
	for attempt = 1, L.TeleportAttempts do
		group = alive(group)
		if #group == 0 then
			return true
		end
		DataService.flush(group, L.FlushTimeout) -- данные сохраняем до ухода: следующий сервер возьмёт профиль без простоя
		local opts = Instance.new("TeleportOptions")
		if reserveCode then
			opts.ReservedServerAccessCode = reserveCode
		end
		opts:SetTeleportData(data)
		for _, p in group do
			failedAt[p] = nil
		end
		local ok, err = pcall(function()
			return TeleportService:TeleportAsync(placeId, group, opts)
		end)
		if not ok then
			warn("[LobbyService] TeleportAsync (attempt " .. attempt .. "): " .. tostring(err))
		else
			-- игроки ушли → успех; TeleportInitFailed → повторяем; тишина дольше 15 с тоже считаем сбоем
			local deadline = os.clock() + 15
			while os.clock() < deadline do
				local anyFailed = false
				for _, p in group do
					if failedAt[p] then
						anyFailed = true
					end
				end
				if anyFailed or #alive(group) == 0 then
					break
				end
				task.wait(0.25)
			end
			if #alive(group) == 0 then
				return true
			end
		end
		if attempt < L.TeleportAttempts then
			task.wait(L.TeleportRetryPause * attempt)
		end
	end
	return #alive(group) == 0
end

-- Запуск матча для группы (площадка, отряд, соло)
local function launch(list: { Player }, kind: string, squad: Squad?)
	local group: { Player } = {}
	for _, p in alive(list) do
		if not launching[p] then
			table.insert(group, p)
		end
	end
	if #group == 0 then
		return
	end
	for _, p in group do
		launching[p] = true
		removeFromPad(uidOf(p))
		notify(p, "Launching…", 3)
	end
	if squad then
		squad.locked = true
	end
	dirty = true
	local data = teleportData(kind, group, squad)
	task.spawn(function()
		local done = false
		if studio and L.StudioSkipTeleport then
			-- заглушка: этот же сервер превращается в матч
			for _, p in group do
				launching[p] = nil
			end
			local h = handlers
			if h then
				h.onStudioStart(group, data)
			end
			done = true
		else
			local okCode, code = pcall(function()
				return TeleportService:ReserveServer(game.PlaceId)
			end)
			local retries = 0
			while not okCode and retries < L.TeleportAttempts - 1 do
				retries += 1
				task.wait(L.TeleportRetryPause * retries)
				okCode, code = pcall(function()
					return TeleportService:ReserveServer(game.PlaceId)
				end)
			end
			if okCode then
				done = teleportGroup(group, game.PlaceId, code :: string, data)
			else
				warn("[LobbyService] ReserveServer: " .. tostring(code))
			end
		end
		if not done then
			-- не вышло: группа остаётся в лобби
			for _, p in alive(group) do
				launching[p] = nil
				notify(p, "Couldn't start the game. You're back in the lobby — try again", 5)
			end
			if squad then
				squad.locked = false
			end
		end
		dirty = true
	end)
end

-- ===== Команды клиента =====

local function startSolo(player: Player)
	if padOfUid[uidOf(player)] then
		notify(player, "Step off the truck first")
		return
	end
	if squadOf(player) then
		notify(player, "Leave your squad to play solo")
		return
	end
	launch({ player }, "solo", nil)
end

local function onCmd(player: Player, cmd: unknown, arg: unknown)
	if typeof(cmd) ~= "string" or mode ~= "lobby" then
		return
	end
	if not RateLimit.allow(player, "LobbyCmd", L.CmdInterval) then
		return
	end
	if launching[player] or not player.Parent then
		return
	end
	local uid = uidOf(player)
	local t = now()
	local mine = squadOf(player)

	if cmd == "create" then
		if mine or padOfUid[uid] or not LobbyRules.isMode(arg) then
			return
		end
		local count = 0
		for _ in squads do
			count += 1
		end
		if count >= L.SquadsMax then
			notify(player, "Too many squads right now")
			return
		end
		local sq = LobbyRules.newSquad(nextSquadId, uid, arg :: any)
		nextSquadId += 1
		squads[sq.id] = sq
		squadOfUid[uid] = sq.id
		dirty = true
	elseif cmd == "mode" then
		if not mine then
			return
		end
		local res = LobbyRules.canSetMode(mine, uid, arg)
		if res.ok then
			mine.mode = arg :: any
			dirty = true
		else
			notify(player, res.reason or "Not allowed")
		end
	elseif cmd == "join" or cmd == "accept" then
		if mine or padOfUid[uid] or typeof(arg) ~= "number" then
			return
		end
		local sq = squads[arg :: number]
		if not sq then
			notify(player, "That squad no longer exists")
			return
		end
		local res = LobbyRules.canJoin(sq, uid, isFriends(uid, sq.owner), t, L.MaxSquad)
		if not res.ok then
			notify(player, res.reason or "Can't join")
			return
		end
		LobbyRules.join(sq, uid)
		squadOfUid[uid] = sq.id
		local boss = playerOfUid(sq.owner)
		if boss and boss ~= player then
			notify(boss, player.DisplayName .. " joined the squad")
		end
		dirty = true
	elseif cmd == "decline" then
		if typeof(arg) ~= "number" then
			return
		end
		local sq = squads[arg :: number]
		if sq then
			sq.invited[uid] = nil
			dirty = true
		end
	elseif cmd == "leave" then
		if mine then
			leaveSquad(player)
		end
	elseif cmd == "invite" then
		if not mine or not LobbyRules.isUserId(arg) then
			return
		end
		if not RateLimit.allow(player, "LobbyInvite", L.InviteInterval) then
			return
		end
		local target = playerOfUid(arg :: number)
		if not target then
			notify(player, "That player is not in the lobby")
			return
		end
		if squadOf(target) then
			notify(player, target.DisplayName .. " is already in a squad")
			return
		end
		local res = LobbyRules.canInvite(mine, uid, target.UserId, t, L.MaxSquad, L.InvitesPerSquad)
		if not res.ok then
			notify(player, res.reason or "Can't invite")
			return
		end
		LobbyRules.expireInvites(mine, t)
		LobbyRules.invite(mine, target.UserId, t, L.InviteTtl)
		Remotes.get("LobbyInvite"):FireClient(target, mine.id, player.DisplayName, L.InviteTtl)
		notify(player, "Invite sent to " .. target.DisplayName)
		dirty = true
	elseif cmd == "kick" then
		if not mine or not LobbyRules.isUserId(arg) then
			return
		end
		local res = LobbyRules.canKick(mine, uid, arg :: number)
		if not res.ok then
			notify(player, res.reason or "Can't remove")
			return
		end
		local target = playerOfUid(arg :: number)
		if target then
			leaveSquad(target)
			notify(target, "You were removed from the squad")
		end
	elseif cmd == "start" then
		if not mine then
			return
		end
		local res = LobbyRules.canStart(mine, uid)
		if not res.ok then
			notify(player, res.reason or "Can't start")
			return
		end
		launch(squadPlayers(mine), "squad", mine)
	elseif cmd == "solo" then
		startSolo(player)
	end
end

-- ===== Площадки =====

local function onPad(root: Vector3, pad: LobbyBuilder.PadInfo): boolean
	return math.abs(root.X - pad.center.X) <= pad.halfX
		and math.abs(root.Z - pad.center.Z) <= pad.halfZ
		and root.Y - pad.center.Y > -3
		and root.Y - pad.center.Y < 9
end

local function hint(player: Player, text: string)
	local t = os.clock()
	if t - (lastHint[player] or 0) > 5 then
		lastHint[player] = t
		notify(player, text)
	end
end

local function padTick()
	local pi = info
	if not pi then
		return
	end
	local t = now()
	-- кто где стоит
	local standing: { [number]: number } = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 and not launching[p] then
			for i, pad in pi.pads do
				if onPad(root.Position, pad) then
					standing[p.UserId] = i
					break
				end
			end
		end
	end
	-- сошедшие
	for uid, i in padOfUid do
		if standing[uid] ~= i then
			removeFromPad(uid)
		end
	end
	-- вставшие
	for uid, i in standing do
		if padOfUid[uid] ~= i then
			local p = playerOfUid(uid)
			if p and squadOfUid[uid] then
				hint(p, "Leave your squad to use a truck")
			elseif p then
				local res = LobbyRules.padCanJoin(pads[i], uid, t, L.MaxSquad, L.PadCountdown, L.PadLockSeconds)
				if res.ok then
					LobbyRules.padJoin(pads[i], uid, t)
					padOfUid[uid] = i
					dirty = true
				else
					hint(p, res.reason or "Can't board")
				end
			end
		end
	end
	-- отсчёт, старт и подписи
	for i, pad in pads do
		local left = LobbyRules.padRemaining(pad, t, L.PadCountdown)
		local view = pi.pads[i]
		local countText = string.format("%d/%d", #pad.members, L.MaxSquad)
		local statusText: string
		if left == nil then
			statusText = "Step on the pad"
		elseif left <= L.PadLockSeconds then
			statusText = "Launching!"
		else
			statusText = string.format("Launching in %d", math.ceil(left))
		end
		local shown = countText .. "|" .. statusText
		if padShown[i] ~= shown then
			padShown[i] = shown
			view.count.Text = countText
			view.status.Text = statusText
			view.status.TextColor3 = if left ~= nil and left <= L.PadLockSeconds then Color3.fromRGB(255, 120, 90) else Color3.fromRGB(120, 230, 140)
			view.plate.Color = if #pad.members > 0 then Color3.fromRGB(240, 200, 60) else Color3.fromRGB(60, 200, 90)
		end
		if LobbyRules.padReady(pad, t, L.PadCountdown, L.PadMinPlayers) then
			local group: { Player } = {}
			for _, uid in table.clone(pad.members) do
				local p = playerOfUid(uid)
				if p then
					table.insert(group, p)
				end
			end
			launch(group, "pad", nil)
			-- launch снимает игроков с площадки; на случай пустой группы сбрасываем её
			for _, uid in table.clone(pad.members) do
				LobbyRules.padLeave(pad, uid)
				padOfUid[uid] = nil
			end
		end
	end
end

-- ===== Витрина =====

local function refreshBoard()
	local pi = info
	if not pi then
		return
	end
	local top = RatingService.top(L.BoardSize)
	for r, row in pi.boardRows do
		local e = top[r]
		if e then
			if not nameCache[e.userId] then
				local p = playerOfUid(e.userId)
				if p then
					nameCache[e.userId] = p.DisplayName
				else
					local ok, nm = pcall(function()
						return Players:GetNameFromUserIdAsync(e.userId)
					end)
					nameCache[e.userId] = if ok then nm else tostring(e.userId)
				end
			end
			row.Text = string.format("  %d.  %s  —  %d", r, nameCache[e.userId], e.rating)
		else
			row.Text = if r == 1 and #top == 0 then "  No records yet — be the first!" else ""
		end
	end
end

-- ===== Вход / выход из лобби =====

local function spawnInLobby(player: Player)
	if mode ~= "lobby" then
		return
	end
	PlayerService.spawn(player)
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
		if hum then
			hum.Died:Connect(function()
				task.wait(2)
				if mode == "lobby" and player.Parent then
					PlayerService.spawn(player)
				end
			end)
		end
	end)
	probeFriends(player)
	spawnInLobby(player)
	dirty = true
end

local commonConnected = false

-- Общее для обоих режимов: сбои телепорта и кнопка «Back to lobby»
local function connectCommon()
	if commonConnected then
		return
	end
	commonConnected = true
	TeleportService.TeleportInitFailed:Connect(function(player: Player, _result: Enum.TeleportResult, message: string)
		failedAt[player] = message
		warn("[LobbyService] TeleportInitFailed: " .. player.Name .. ": " .. tostring(message))
	end)
	Remotes.get("BackToLobby").OnServerEvent:Connect(function(player: Player)
		if ReplicatedStorage:GetAttribute("ReturnAt") == nil or not RateLimit.allow(player, "BackToLobby", 1) then
			return
		end
		wantBack[player] = true
		-- вне Studio уходит сразу один игрок; остальные ждут своей кнопки или таймера
		if not (studio and L.StudioSkipTeleport) and not launching[player] then
			launching[player] = true
			task.spawn(function()
				local ok = teleportGroup({ player }, game.PlaceId, nil, { v = 1, from = "match", kind = "return", at = os.time() })
				if not ok then
					launching[player] = nil
					notify(player, "Couldn't reach the lobby. Try again in a moment", 5)
				end
			end)
		end
	end)
end

-- Строим лобби и включаем его логику. handlers — вызывается только в Studio-заглушке.
function LobbyService.initLobby(h: Handlers)
	handlers = h
	setMode("lobby")
	ReplicatedStorage:SetAttribute("Phase", "Lobby")
	ReplicatedStorage:SetAttribute("Location", "Checkpoint 7")
	applyLobbyLighting()
	local built = LobbyBuilder.build()
	info = built
	for _ = 1, L.PadCount do
		table.insert(pads, LobbyRules.newPad())
	end
	PlayerService.setSpawn(built.spawn)

	built.squadPrompt.Triggered:Connect(function(player)
		if mode == "lobby" then
			sendState(player, true)
		end
	end)
	built.soloPrompt.Triggered:Connect(function(player)
		if mode == "lobby" and not launching[player] and RateLimit.allow(player, "LobbyCmd", L.CmdInterval) then
			startSolo(player)
		end
	end)
	Remotes.get("LobbyCmd").OnServerEvent:Connect(onCmd)

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(hookPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		leaveSquad(player)
		removeFromPad(uidOf(player))
		launching[player] = nil
		lastHint[player] = nil
		failedAt[player] = nil
		wantBack[player] = nil
		for key in friendCache do
			if string.find(key, tostring(player.UserId), 1, true) then
				friendCache[key] = nil
			end
		end
		dirty = true
	end)
	connectCommon()

	-- основной цикл: площадки 10 раз в секунду, состояние клиентам не чаще StateInterval
	task.spawn(function()
		local lastSend = 0
		while true do
			task.wait(0.1)
			if mode == "lobby" then
				local ok, err = pcall(padTick)
				if not ok then
					warn("[LobbyService] pad tick: " .. tostring(err))
				end
				-- приглашения протухают: клиент должен видеть актуальный список
				local t = os.clock()
				if dirty and t - lastSend >= L.StateInterval then
					lastSend = t
					broadcast()
				elseif t - lastSend >= 2 then
					lastSend = t
					broadcast() -- раз в 2 с: обновляем «осталось секунд» у приглашений
				end
			end
		end
	end)
	task.spawn(function()
		while true do
			if mode == "lobby" then
				local ok, err = pcall(refreshBoard)
				if not ok then
					warn("[LobbyService] board: " .. tostring(err))
				end
			end
			task.wait(L.BoardRefresh)
		end
	end)
	print("[LobbyService] lobby ready")
end

-- ===== Матч: возврат в лобби =====

-- Состав группы из TeleportData (без данных — Studio, старая ссылка: просто играем)
function LobbyService.initMatch()
	setMode("match")
	local function check(player: Player)
		local ok, data = pcall(function()
			return player:GetJoinData().TeleportData
		end)
		if ok and typeof(data) == "table" and (data :: any).v == 1 then
			print(string.format("[LobbyService] %s joined the match (%s)", player.Name, tostring((data :: any).kind)))
		elseif not studio then
			warn("[LobbyService] " .. player.Name .. " joined the match without TeleportData")
		end
	end
	Players.PlayerAdded:Connect(check)
	for _, p in Players:GetPlayers() do
		task.spawn(check, p)
	end
	connectCommon()
end

-- Studio-заглушка: этот же сервер снова становится лобби
local function studioShowLobby()
	setMode("lobby")
	ReplicatedStorage:SetAttribute("Phase", "Lobby")
	ReplicatedStorage:SetAttribute("Location", "Checkpoint 7")
	applyLobbyLighting()
	for _, sq in squads do
		sq.locked = false
	end
	for p in launching do
		launching[p] = nil
	end
	PlayerService.setSpawn((info :: LobbyBuilder.LobbyInfo).spawn)
	PlayerService.spawnAll()
	dirty = true
end

-- Лобби → матч внутри одного сервера (только Studio)
function LobbyService.studioToMatch()
	restoreLighting()
	setMode("match")
	ReplicatedStorage:SetAttribute("ReturnAt", nil)
	studioStartPending = false
end

-- Начало экрана итогов (RoundService, фаза GameOver): клиент показывает «Back to lobby» и отсчёт до ReturnAt
function LobbyService.beginResults()
	for p in wantBack do
		wantBack[p] = nil
	end
	ReplicatedStorage:SetAttribute("ReturnAt", workspace:GetServerTimeNow() + L.ReturnSeconds)
end

-- Конец раунда: ждём кнопки или таймера, потом всех в лобби. Вызывается из RoundService после «Round over»; возвращает управление,
-- когда нужно начинать новый раунд на этом же сервере (Studio после нового запуска; на живом — только если лобби недоступно).
function LobbyService.afterRound()
	local endsAt = (ReplicatedStorage:GetAttribute("ReturnAt") :: number?) or (workspace:GetServerTimeNow() + L.ReturnSeconds)
	local deadline = os.clock() + math.max(0, endsAt - workspace:GetServerTimeNow())
	local stub = studio and L.StudioSkipTeleport
	while os.clock() < deadline do
		local everyone = Players:GetPlayers()
		if #everyone == 0 then
			break
		end
		local all = true
		for _, p in everyone do
			if not wantBack[p] then
				all = false
			end
		end
		if all or (stub and next(wantBack) ~= nil) then
			break
		end
		task.wait(0.5)
	end
	ReplicatedStorage:SetAttribute("ReturnAt", nil)
	local rest = {}
	for _, p in Players:GetPlayers() do
		if not launching[p] then
			table.insert(rest, p)
		end
	end
	if stub then
		studioStartPending = true
		studioShowLobby()
		while studioStartPending do
			task.wait(0.5)
		end
		return
	end
	if #rest > 0 then
		for _, p in rest do
			launching[p] = true
		end
		local ok = teleportGroup(rest, game.PlaceId, nil, { v = 1, from = "match", kind = "return", at = os.time() })
		if not ok then
			for _, p in alive(rest) do
				launching[p] = nil
				notify(p, "Couldn't reach the lobby. A new round starts here", 5)
			end
			return -- лобби недоступно: начинаем новый раунд на этом сервере
		end
	end
	-- все ушли в лобби: сервер закроется сам, раунды больше не нужны
	while #Players:GetPlayers() > 0 do
		task.wait(2)
	end
	while true do
		task.wait(60)
	end
end

return LobbyService
