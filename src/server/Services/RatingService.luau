--!strict
-- Рейтинговые очки (не монеты и не «очки» команды): убийства, попадания в голову, открытые здания, выживание и скорость зачистки.
-- Копятся за раунд (атрибут Rating, строка «Рейтинг» в таблице игроков), в конце раунда идут в профиль (DataService) и в глобальный
-- лидерборд — OrderedDataStore с суммой рейтинга. Окно лидерборда и подбор тимейтов — позже; RatingService.top() уже отдаёт список.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WaveMath = require(Shared:WaitForChild("WaveMath"))
local DataService = require(script.Parent:WaitForChild("DataService"))

local RatingService = {}

local board: OrderedDataStore? = nil
local waves: OrderedDataStore? = nil -- лучшая ночь игрока (для табло в лобби)
local BOARD_NAME = if RunService:IsStudio() then "Test_RatingBoard_v1" else "RatingBoard_v1"
local WAVES_NAME = if RunService:IsStudio() then "Test_BestWaveBoard_v1" else "BestWaveBoard_v1"
local PREFIX = if RunService:IsStudio() then "Test_" else ""

-- Неделя: номер с понедельника 5 января 1970 (UTC)
function RatingService.currentWeek(): number
	return math.floor((os.time() - 345600) / 604800)
end

local function ordered(name: string): OrderedDataStore?
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(PREFIX .. name)
	end)
	return if ok then store else nil
end

-- Команда в ключе: id участников в base36 по возрастанию (ключ OrderedDataStore — до 50 символов)
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function toBase36(n: number): string
	local out = ""
	repeat
		local d = n % 36
		out = string.sub(DIGITS, d + 1, d + 1) .. out
		n = n // 36
	until n == 0
	return out
end

local function teamKey(players: { Player }): string
	local ids: { number } = {}
	for _, p in players do
		table.insert(ids, p.UserId)
	end
	table.sort(ids)
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, toBase36(id))
	end
	return table.concat(parts, "_")
end

local function teamIds(key: string): { number }
	local ids: { number } = {}
	for part in string.gmatch(key, "[^_]+") do
		local n = tonumber(part, 36)
		if n then
			table.insert(ids, n)
		end
	end
	return ids
end

local function raiseTo(store: OrderedDataStore?, key: string, value: number)
	if not store then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			(store :: OrderedDataStore):UpdateAsync(key, function(old: any)
				if typeof(old) == "number" and old >= value then
					return nil
				end
				return value
			end)
		end)
		if not ok then
			warn("[RatingService] board: " .. tostring(err))
		end
	end)
end

-- Лучшие команды: { ids, wave, rating }; значение в хранилище = ночь × 1 000 000 + рейтинг команды
function RatingService.topTeams(count: number): { { ids: { number }, wave: number, rating: number } }
	local list: { { ids: { number }, wave: number, rating: number } } = {}
	local store = ordered("TeamBoard_v1")
	if not store then
		return list
	end
	local ok, pages = pcall(function()
		return (store :: OrderedDataStore):GetSortedAsync(false, math.clamp(count, 1, 100))
	end)
	if ok and pages then
		for _, entry in (pages :: DataStorePages):GetCurrentPage() do
			local v = entry.value :: number
			table.insert(list, { ids = teamIds(entry.key), wave = v // 1000000, rating = v % 1000000 })
		end
	end
	return list
end

-- Победитель недели: топ-3 игрока или участник лучшей команды
function RatingService.isWeekWinner(week: number, userId: number): boolean
	local function page(name: string, n: number): { any }
		local store = ordered(name .. week)
		if not store then
			return {}
		end
		local ok, pages = pcall(function()
			return (store :: OrderedDataStore):GetSortedAsync(false, n)
		end)
		return if ok and pages then (pages :: DataStorePages):GetCurrentPage() else {}
	end
	for _, e in page("RatingWeek_", 3) do
		if tonumber(e.key) == userId then
			return true
		end
	end
	for _, e in page("TeamWeek_", 1) do
		if table.find(teamIds(e.key), userId) then
			return true
		end
	end
	return false
end

local function refresh(player: Player)
	local folder = player:FindFirstChild("leaderstats")
	local stat = folder and folder:FindFirstChild("Rating") :: IntValue?
	if stat then
		stat.Value = (player:GetAttribute("Rating") :: number?) or 0
	end
end

local function setup(player: Player)
	player:SetAttribute("Rating", 0)
	task.defer(function()
		local folder = player:WaitForChild("leaderstats", 10)
		if folder and not folder:FindFirstChild("Rating") then
			local v = Instance.new("IntValue")
			v.Name = "Rating"
			v.Parent = folder
		end
		refresh(player)
	end)
end

function RatingService.init()
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(BOARD_NAME)
	end)
	board = if ok then store else nil
	local okW, storeW = pcall(function()
		return DataStoreService:GetOrderedDataStore(WAVES_NAME)
	end)
	waves = if okW then storeW else nil
	for _, p in Players:GetPlayers() do
		setup(p)
	end
	Players.PlayerAdded:Connect(setup)
end

function RatingService.add(player: Player, amount: number)
	if amount <= 0 or not player.Parent then
		return
	end
	player:SetAttribute("Rating", ((player:GetAttribute("Rating") :: number?) or 0) + math.floor(amount + 0.5))
	refresh(player)
end

-- Убийство: базовые очки, выстрел в голову, босс
function RatingService.onKill(player: Player, zombie: any)
	local R = Config.Rating
	local points = R.Kill
	if zombie.headKill == true then
		points += R.HeadshotKill
	end
	if WaveMath.isBossType(zombie.def.id) then
		points += R.BossKill
	end
	RatingService.add(player, points)
end

function RatingService.onBuildingOpened(player: Player)
	RatingService.add(player, Config.Rating.BuildingOpened)
end

-- Конец ночи: выжившим — за номер волны; если мутантов не осталось — бонус за скорость (доля ночи, которую сэкономили)
function RatingService.onNightEnd(wave: number, cleared: boolean, timeUsedFraction: number)
	local R = Config.Rating
	for _, p in Players:GetPlayers() do
		if p:GetAttribute("Downed") ~= true then
			RatingService.add(p, R.NightSurvived * wave)
			if cleared then
				RatingService.add(p, R.ClearBonus * wave * (1 - math.clamp(timeUsedFraction, 0, 1)))
			end
		end
	end
end

function RatingService.resetRound(players: { Player })
	for _, p in players do
		p:SetAttribute("Rating", 0)
		refresh(p)
	end
end

-- Итог раунда: в профиль и в глобальный лидерборд
function RatingService.finishRound(players: { Player }, reached: number)
	-- команда: лучшая ночь и рейтинг за раунд (и за всё время, и за неделю)
	if #players >= 2 and reached > 0 then
		local sum = 0
		for _, p in players do
			sum += (p:GetAttribute("Rating") :: number?) or 0
		end
		local value = reached * 1000000 + math.min(999999, math.floor(sum))
		local key = teamKey(players)
		raiseTo(ordered("TeamBoard_v1"), key, value)
		raiseTo(ordered("TeamWeek_" .. RatingService.currentWeek()), key, value)
	end
	for _, p in players do
		local gained = (p:GetAttribute("Rating") :: number?) or 0
		if gained > 0 and DataService.canSave(p) then
			-- рейтинг недели копится
			local weekly = ordered("RatingWeek_" .. RatingService.currentWeek())
			local add = math.floor(gained)
			if weekly then
				task.spawn(function()
					pcall(function()
						(weekly :: OrderedDataStore):UpdateAsync(tostring(p.UserId), function(old: any)
							return (if typeof(old) == "number" then old else 0) + add
						end)
					end)
				end)
			end
		end
		local total = DataService.addRating(p, gained)
		local store = board
		-- в лидерборд пишем только из настоящего профиля (не по умолчанию после сбоя загрузки и не занятого другим сервером)
		-- и только вверх: устаревшая сумма не должна откатить запись игрока
		if store and total and gained > 0 and DataService.canSave(p) then
			local value = math.floor(total)
			task.spawn(function()
				local ok, err = pcall(function()
					(store :: OrderedDataStore):UpdateAsync(tostring(p.UserId), function(old: any)
						if typeof(old) == "number" and old >= value then
							return nil -- запись не меньше нашей: не трогаем
						end
						return value
					end)
				end)
				if not ok then
					warn("[RatingService] leaderboard: " .. tostring(err))
				end
			end)
			-- лучшая ночь: только вверх, как и рейтинг
			local best = math.floor((p:GetAttribute("BestWave") :: number?) or 0)
			local wstore = waves
			if wstore and best > 0 then
				task.spawn(function()
					local okW, errW = pcall(function()
						(wstore :: OrderedDataStore):UpdateAsync(tostring(p.UserId), function(old: any)
							if typeof(old) == "number" and old >= best then
								return nil
							end
							return best
						end)
					end)
					if not okW then
						warn("[RatingService] best wave: " .. tostring(errW))
					end
				end)
			end
		end
	end
end

-- Верх лидерборда: { { userId, rating, bestWave } } по убыванию (табло в лобби); bestWave — 0, если записи нет
function RatingService.top(count: number): { { userId: number, rating: number, bestWave: number } }
	local list: { { userId: number, rating: number, bestWave: number } } = {}
	local store = board
	if not store then
		return list
	end
	local ok, pages = pcall(function()
		return (store :: OrderedDataStore):GetSortedAsync(false, math.clamp(count, 1, 100))
	end)
	if ok and pages then
		for _, entry in (pages :: DataStorePages):GetCurrentPage() do
			local best = 0
			local wstore = waves
			if wstore then
				local okW, v = pcall(function()
					return (wstore :: OrderedDataStore):GetAsync(entry.key)
				end)
				if okW and typeof(v) == "number" then
					best = v
				end
			end
			table.insert(list, { userId = tonumber(entry.key) or 0, rating = entry.value :: number, bestWave = best })
		end
	end
	return list
end

return RatingService
