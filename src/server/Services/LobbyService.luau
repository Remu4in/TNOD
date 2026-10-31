--!strict
-- Лобби и команды. Одно место, два режима: публичный сервер — лобби, резервный сервер того же места — матч (идёт обычный раунд).
-- Лобби: зоны сбора команды (первый вошедший — хост, зона закрывается, пока он настраивает: число игроков и доступ; затем зона
-- открыта для подходящих игроков, старт — кнопкой хоста или отсчётом, когда зона заполнена), ворота «Play solo», табло «Top survivors»,
-- торговцы и автоматы (окна-заглушки «Coming soon»), военные НПС (LobbyNpcService). Всех из зоны сервер телепортирует на новый
-- резервный сервер (TeleportData — состав группы).
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
local LobbyNpcService = require(script.Parent:WaitForChild("LobbyNpcService"))
local LobbyBuilder = require(script.Parent.Parent:WaitForChild("Locations"):WaitForChild("Lobby"))

local L = Config.Lobby

local LobbyService = {}

type Zone = LobbyRules.Zone

export type Handlers = {
	-- Studio: «телепорт» — этот же сервер становится матчем для группы
	onStudioStart: ({ Player }, { [string]: any }) -> (),
}

local mode: string = "match" -- "lobby" | "match"
local studio = RunService:IsStudio()
local handlers: Handlers? = nil
local info: LobbyBuilder.LobbyInfo? = nil

local zones: { Zone } = {}
local zoneOfUid: { [number]: number } = {}
local launching: { [Player]: boolean } = {}
local friendCache: { [string]: boolean } = {}
local nameCache: { [number]: string } = {}
local dirty = true
local lastHint: { [Player]: number } = {}
local savedLighting: { [string]: any }? = nil
local bannerShown: { [number]: string } = {}
local lastBoardLeader = 0

-- Studio: ждём, пока кто-то снова запустит матч после возврата в лобби
local studioStartPending = false
-- кто нажал «Back to lobby» на экране итогов
local wantBack: { [Player]: boolean } = {}

local COLORS = {
	free = Color3.fromRGB(70, 210, 110),
	setup = Color3.fromRGB(235, 80, 70),
	open = Color3.fromRGB(255, 190, 60),
	launching = Color3.fromRGB(235, 240, 255),
}

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
	local lc = L.Lighting
	Lighting.ClockTime = lc.ClockTime
	Lighting.Brightness = lc.Brightness
	Lighting.Ambient = lc.Ambient
	Lighting.OutdoorAmbient = lc.OutdoorAmbient
	Lighting.ExposureCompensation = lc.Exposure
	Lighting.FogEnd = lc.FogEnd
	Lighting.FogColor = lc.FogColor
	-- вечернее небо: ночное небо матча убираем в ServerStorage.Skies
	local skies = ServerStorage:FindFirstChild("Skies")
	if skies then
		for _, s in Lighting:GetChildren() do
			if s:IsA("Sky") and s.Name == "NightSky" then
				s.Parent = skies
			end
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
	local skies = ServerStorage:FindFirstChild("Skies")
	local night = skies and skies:FindFirstChild("NightSky")
	if night and not Lighting:FindFirstChild("NightSky") then
		night.Parent = Lighting
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

-- ===== Зоны =====

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

local function rootOf(player: Player): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function zonePlayers(zone: Zone): { Player }
	local list: { Player } = {}
	for _, uid in zone.members do
		local p = playerOfUid(uid)
		if p then
			table.insert(list, p)
		end
	end
	return list
end

-- Стоит ли игрок внутри зоны (круг по радиусу; по высоте — на плите, не на крыше вышки)
local function insideZone(root: Vector3, view: LobbyBuilder.ZoneView, extra: number): boolean
	local dx, dz = root.X - view.center.X, root.Z - view.center.Z
	local dy = root.Y - view.center.Y
	return dx * dx + dz * dz <= (view.radius + extra) ^ 2 and dy > -4 and dy < 10
end

-- Вывести игрока из зоны на юг, к тропинке (закрытая зона, удаление, роспуск)
local function eject(player: Player, view: LobbyBuilder.ZoneView)
	local root = rootOf(player)
	if not root then
		return
	end
	local out = view.center + Vector3.new(0, 3, view.radius + 4.5)
	root.CFrame = CFrame.new(out) * root.CFrame.Rotation
	root.AssemblyLinearVelocity = Vector3.zero
end

local function hint(player: Player, text: string)
	local t = os.clock()
	if t - (lastHint[player] or 0) > L.ZoneEjectSeconds then
		lastHint[player] = t
		notify(player, text)
	end
end

local function removeFromZone(player: Player)
	local uid = uidOf(player)
	local idx = zoneOfUid[uid]
	if not idx then
		return
	end
	zoneOfUid[uid] = nil
	local zone = zones[idx]
	local res = LobbyRules.leave(zone, uid, L.ZoneMaxSize, now())
	if res == "host" then
		local boss = playerOfUid(zone.host :: number)
		if boss then
			notify(boss, "You are the squad host now", 3)
		end
	elseif res == "free" then
		bannerShown[idx] = nil
	end
	dirty = true
end

-- ===== Состояние для клиента =====

local function accessName(m: string): string
	return if m == "Friends" then "Friends only" elseif m == "Invite" then "Invite only" else "Public"
end

local function buildState(player: Player): { [string]: any }
	local state: { [string]: any } = { mode = mode, launching = launching[player] == true }
	local idx = zoneOfUid[uidOf(player)]
	if idx then
		local zone = zones[idx]
		local members = {}
		for _, m in zone.members do
			table.insert(members, { uid = m, name = nameOf(m) })
		end
		local t = now()
		local left = LobbyRules.countdownLeft(zone, t, L.ZoneCountdown)
		state.zone = {
			id = idx,
			role = if zone.host == uidOf(player) then "host" else "member",
			state = zone.state,
			host = if zone.host then nameOf(zone.host) else "",
			hostUid = zone.host,
			countdown = L.ZoneCountdown,
			members = members,
			size = zone.size,
			max = L.ZoneMaxSize,
			access = zone.mode,
			endsAt = if left then workspace:GetServerTimeNow() + left else nil,
		}
	end
	return state
end

local function broadcast()
	dirty = false
	for _, p in Players:GetPlayers() do
		Remotes.get("LobbyState"):FireClient(p, buildState(p))
	end
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

local function teleportData(kind: string, list: { Player }, leader: number?): { [string]: any }
	local ids = {}
	for _, p in list do
		table.insert(ids, p.UserId)
	end
	return { v = 1, from = "lobby", kind = kind, members = ids, leader = leader or ids[1], at = os.time() }
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

-- Запуск матча для группы (зона или соло). zoneIdx — зона, которую откроем снова, если запуск не удался
local function launch(list: { Player }, kind: string, leader: number?, zoneIdx: number?)
	local group: { Player } = {}
	for _, p in alive(list) do
		if not launching[p] then
			table.insert(group, p)
		end
	end
	if #group == 0 then
		if zoneIdx then
			LobbyRules.unlock(zones[zoneIdx], now())
		end
		return
	end
	for _, p in group do
		launching[p] = true
		notify(p, "Launching…", 3)
	end
	dirty = true
	local data = teleportData(kind, group, leader)
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
			-- не вышло: группа остаётся в лобби, зона снова открыта
			for _, p in alive(group) do
				launching[p] = nil
				notify(p, "Couldn't start the game. You're back in the lobby — try again", 5)
			end
			if zoneIdx then
				LobbyRules.unlock(zones[zoneIdx], now())
			end
		end
		dirty = true
	end)
end

local function launchZone(idx: number)
	local zone = zones[idx]
	local group = zonePlayers(zone)
	local leader = zone.host
	LobbyRules.lock(zone)
	launch(group, "zone", leader, idx)
end

-- ===== Команды клиента =====

local function startSolo(player: Player)
	if zoneOfUid[uidOf(player)] then
		notify(player, "Step out of the squad zone first")
		return
	end
	launch({ player }, "solo", nil, nil)
end

-- Игрок достаточно близко к точке (меню и ворота проверяются на сервере: подсказка может прийти и от изменённого клиента)
local function nearPoint(player: Player, pos: Vector3, distance: number): boolean
	local root = rootOf(player)
	return root ~= nil and (root.Position - pos).Magnitude <= distance
end

local function readSettings(arg: unknown): (number?, string?)
	if typeof(arg) ~= "table" then
		return nil, nil
	end
	local t = arg :: { [string]: unknown }
	local size, access = t.size, t.access
	if typeof(size) ~= "number" or typeof(access) ~= "string" then
		return nil, nil
	end
	return size, access
end

local function onCmd(player: Player, cmd: unknown, arg: unknown)
	local pi = info
	if typeof(cmd) ~= "string" or mode ~= "lobby" or not pi then
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

	if cmd == "solo" then
		local host = pi.soloPrompt.Parent :: BasePart
		if nearPoint(player, host.Position, L.MenuDistance) then
			startSolo(player)
		end
		return
	elseif cmd == "buy" then
		if typeof(arg) == "string" then
			notify(player, "This item is coming soon")
		end
		return
	end

	-- остальные команды — только хост своей зоны, пока он стоит в ней
	local idx = zoneOfUid[uid]
	if not idx then
		return
	end
	local zone = zones[idx]
	local view = pi.zones[idx]
	local root = rootOf(player)
	if not root or not insideZone(root.Position, view, 4) then
		return
	end

	if cmd == "open" or cmd == "config" then
		local size, access = readSettings(arg)
		local res = LobbyRules.configure(zone, uid, size, access, L.ZoneMaxSize, t)
		if not res.ok then
			notify(player, res.reason or "Not allowed")
			return
		end
		if cmd == "open" then
			local opened = LobbyRules.open(zone, uid, t)
			if not opened.ok then
				notify(player, opened.reason or "Not allowed")
				return
			end
		end
		dirty = true
	elseif cmd == "start" then
		local res = LobbyRules.canStart(zone, uid)
		if not res.ok then
			notify(player, res.reason or "Can't start")
			return
		end
		launchZone(idx)
	elseif cmd == "cancel" then
		local res = LobbyRules.canCancel(zone, uid)
		if not res.ok then
			notify(player, res.reason or "Can't cancel")
			return
		end
		local members = zonePlayers(zone)
		for _, p in members do
			zoneOfUid[uidOf(p)] = nil
			eject(p, view)
			if p ~= player then
				notify(p, "The host closed the squad")
			end
		end
		LobbyRules.reset(zone, L.ZoneMaxSize)
		bannerShown[idx] = nil
		dirty = true
	elseif cmd == "kick" then
		if not LobbyRules.isUserId(arg) then
			return
		end
		local target = playerOfUid(arg :: number)
		local res = LobbyRules.kick(zone, uid, arg :: number, t)
		if not res.ok then
			notify(player, res.reason or "Can't remove")
			return
		end
		if target then
			zoneOfUid[uidOf(target)] = nil
			eject(target, view)
			notify(target, "You were removed from the squad")
		end
		dirty = true
	elseif cmd == "invite" then
		if not LobbyRules.isUserId(arg) or not RateLimit.allow(player, "LobbyInvite", L.InviteInterval) then
			return
		end
		local target = playerOfUid(arg :: number)
		if not target then
			notify(player, "That player is not in the lobby")
			return
		end
		LobbyRules.expireInvites(zone, t)
		local res = LobbyRules.invite(zone, uid, target.UserId, t, L.ZoneInviteTtl, L.ZoneInvitesMax)
		if not res.ok then
			notify(player, res.reason or "Can't invite")
			return
		end
		Remotes.get("LobbyInvite"):FireClient(target, idx, player.DisplayName, L.ZoneInviteTtl)
		notify(player, "Invite sent to " .. target.DisplayName)
		dirty = true
	end
end

-- ===== Зоны: присутствие, баннеры, отсчёт =====

local function bannerFor(i: number, zone: Zone, view: LobbyBuilder.ZoneView, t: number)
	local title = "SQUAD " .. i
	local status, detail, color, progress
	local fill: Color3
	if zone.state == "free" then
		status, detail, color, progress = "OPEN", "Step in to host", COLORS.free, nil
		fill = COLORS.free
	elseif zone.state == "setup" then
		status = nameOf(zone.host :: number) .. " is setting up…"
		detail, color, progress = "Zone closed for now", COLORS.setup, nil
		fill = COLORS.setup
	elseif zone.state == "launching" then
		status, detail, color, progress = "LAUNCHING", "Hold on tight", COLORS.launching, 1
		fill = COLORS.launching
	else
		local left = LobbyRules.countdownLeft(zone, t, L.ZoneCountdown)
		local access = accessName(zone.mode)
		detail = string.format("%s's squad %d/%d · %s", nameOf(zone.host :: number), #zone.members, zone.size, access)
		if left then
			status = string.format("STARTING IN %d", math.ceil(left))
			progress = 1 - left / L.ZoneCountdown
		elseif #zone.members >= zone.size then
			status, progress = "FULL", nil
		else
			status, progress = "JOIN", nil
		end
		color, fill = COLORS.open, COLORS.open
	end
	local key = status .. "|" .. detail .. "|" .. tostring(progress and math.floor(progress * 20))
	if bannerShown[i] ~= key then
		bannerShown[i] = key
		view.banner.setText(title, status, detail, color, progress)
		view.setColor(fill)
	end
end

local function zoneTick()
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
		if root and hum and hum.Health > 0 and (not launching[p] or zoneOfUid[p.UserId]) then
			for i, view in pi.zones do
				if insideZone(root.Position, view, 0) then
					standing[p.UserId] = i
					break
				end
			end
		end
	end
	-- ушедшие из зоны (до запуска): теряют место; хост уходит — хостом станет следующий
	for uid, i in table.clone(zoneOfUid) do
		if standing[uid] ~= i and zones[i].state ~= "launching" then
			local p = playerOfUid(uid)
			if p then
				removeFromZone(p)
			else
				zoneOfUid[uid] = nil
				LobbyRules.leave(zones[i], uid, L.ZoneMaxSize, t)
				dirty = true
			end
		end
	end
	-- вошедшие: сервер решает, а не стена
	for uid, i in standing do
		if zoneOfUid[uid] ~= i then
			local p = playerOfUid(uid)
			if p then
				local zone = zones[i]
				LobbyRules.expireInvites(zone, t)
				local friend = if zone.host then isFriends(uid, zone.host) else false
				local res = LobbyRules.canEnter(zone, uid, friend, t)
				if res.ok then
					-- стоял в другой зоне — место там освобождается (его уже снял блок выше, если вышел)
					local kind = LobbyRules.enter(zone, uid, t)
					zoneOfUid[uid] = i
					bannerShown[i] = nil
					dirty = true
					if kind == "host" then
						notify(p, "You are the host. Set up your squad", 4)
					else
						notify(p, nameOf(zone.host :: number) .. "'s squad", 3)
					end
				else
					hint(p, res.reason or "Can't enter")
					if zones[i].state ~= "free" then
						eject(p, pi.zones[i])
					end
				end
			end
		end
	end
	-- хост завис в настройке — зона освобождается
	for i, zone in zones do
		if LobbyRules.setupExpired(zone, t, L.ZoneSetupTimeout) then
			local view = pi.zones[i]
			for _, p in zonePlayers(zone) do
				zoneOfUid[uidOf(p)] = nil
				eject(p, view)
				notify(p, "Squad setup timed out")
			end
			LobbyRules.reset(zone, L.ZoneMaxSize)
			bannerShown[i] = nil
			dirty = true
		end
	end
	-- отсчёт, старт, баннеры
	for i, zone in zones do
		if zone.state == "open" and LobbyRules.ready(zone, t, L.ZoneCountdown) then
			launchZone(i)
		end
		bannerFor(i, zone, pi.zones[i], t)
	end
end

-- ===== Табло «Top survivors» =====

local thumbCache: { [number]: string } = {}

local SAMPLE_ROWS = {
	{ name = "Sgt. Kowalski", wave = 17, rating = 9420 },
	{ name = "Doc Mercer", wave = 15, rating = 8710 },
	{ name = "Private Vega", wave = 14, rating = 7985 },
	{ name = "Lt. Okafor", wave = 12, rating = 6120 },
	{ name = "Ranger Holt", wave = 11, rating = 5440 },
	{ name = "Cpl. Dubois", wave = 10, rating = 4875 },
	{ name = "Medic Tanaka", wave = 9, rating = 3990 },
	{ name = "Scout Rivera", wave = 8, rating = 3105 },
	{ name = "Pvt. Novak", wave = 6, rating = 2260 },
	{ name = "Rookie Smith", wave = 4, rating = 1180 },
}

local function thumbOf(uid: number): string?
	if thumbCache[uid] then
		return thumbCache[uid]
	end
	local ok, img = pcall(function()
		return (Players:GetUserThumbnailAsync(uid, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100))
	end)
	if ok and typeof(img) == "string" then
		thumbCache[uid] = img
		return img
	end
	return nil
end

local function refreshBoard()
	local pi = info
	if not pi then
		return
	end
	local top = RatingService.top(L.BoardSize)
	local board = pi.board
	local sample = false
	if #top == 0 and studio then
		sample = true
	end
	for r = 1, L.BoardSize do
		if sample then
			local s = SAMPLE_ROWS[r]
			board.setRow(r, if s then { name = s.name, wave = s.wave, rating = s.rating, image = nil } else nil)
		else
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
				board.setRow(r, { name = nameCache[e.userId], wave = e.bestWave, rating = e.rating, image = thumbOf(e.userId) })
			else
				board.setRow(r, nil)
			end
		end
	end
	if sample then
		board.setNote("Sample data — shown in Studio only")
	elseif #top == 0 then
		board.setNote("No records yet — be the first survivor!")
	else
		board.setNote("Global top by total rating · refreshed every " .. math.floor(L.BoardRefresh / 60) .. " min")
	end
	-- «аватар первого места» ассета надевает наряд лидера
	local leader = if top[1] then top[1].userId else 0
	local rig = board.rig
	if rig and leader ~= lastBoardLeader and leader > 0 then
		lastBoardLeader = leader
		local hum = rig:FindFirstChildOfClass("Humanoid")
		if hum then
			task.spawn(function()
				local ok, desc = pcall(function()
					return Players:GetHumanoidDescriptionFromUserId(leader)
				end)
				if ok and desc then
					pcall(function()
						hum:ApplyDescription(desc)
					end)
				end
			end)
		end
	end
end

-- ===== Меню торговцев и автоматов =====

local function openMenu(player: Player, kind: string, title: string, pos: Vector3)
	if mode ~= "lobby" or launching[player] or not RateLimit.allow(player, "LobbyMenu", 0.5) then
		return
	end
	if not nearPoint(player, pos, L.MenuDistance) then
		return
	end
	local items = if kind == "shop" then L.Shop else L.Vending
	Remotes.get("LobbyMenu"):FireClient(player, kind, { title = title, items = items })
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
	for _ = 1, L.ZoneCount do
		table.insert(zones, LobbyRules.newZone(L.ZoneMaxSize))
	end
	PlayerService.setSpawn(built.spawn)

	built.soloPrompt.Triggered:Connect(function(player)
		if mode == "lobby" and not launching[player] and RateLimit.allow(player, "LobbyCmd", L.CmdInterval) then
			local host = built.soloPrompt.Parent :: BasePart
			if nearPoint(player, host.Position, L.MenuDistance) then
				startSolo(player)
			end
		end
	end)
	for _, m in built.menus do
		local host = m.prompt.Parent :: BasePart
		m.prompt.Triggered:Connect(function(player)
			openMenu(player, m.kind, if m.kind == "vending" then "Supply machine" else "Trader", host.Position)
		end)
	end
	LobbyNpcService.start(built.npcSpots, built.npcFolder, function(player: Player, traderIndex: number)
		-- игрок должен стоять у прилавка: позицию берём из точки торговца
		for _, spot in built.npcSpots do
			if spot.trader == traderIndex then
				openMenu(player, "shop", "Trader " .. traderIndex, spot.pos)
				return
			end
		end
	end)
	Remotes.get("LobbyCmd").OnServerEvent:Connect(onCmd)

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(hookPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		removeFromZone(player)
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

	-- основной цикл: зоны 10 раз в секунду, состояние клиентам не чаще StateInterval
	task.spawn(function()
		local lastSend = 0
		while true do
			task.wait(0.1)
			if mode == "lobby" then
				local ok, err = pcall(zoneTick)
				if not ok then
					warn("[LobbyService] zone tick: " .. tostring(err))
				end
				local t = os.clock()
				if dirty and t - lastSend >= L.StateInterval then
					lastSend = t
					broadcast()
				elseif t - lastSend >= 2 then
					lastSend = t
					broadcast() -- раз в 2 с: на случай потерянного снимка
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
	for i = 1, #zones do
		LobbyRules.reset(zones[i], L.ZoneMaxSize)
		bannerShown[i] = nil
	end
	table.clear(zoneOfUid)
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
