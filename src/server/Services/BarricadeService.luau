--!strict
-- Баррикады на входах: зомби ломают доски, игроки чинят и могут сами разобрать (ProximityPrompt).

local Types = require(script.Parent.Parent:WaitForChild("Types"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))

local BarricadeService = {}

local windows: { Types.Window } = {}
local intact: { [number]: number } = {} -- id входа → целых досок
local brokenByZombies: { [number]: number } = {} -- id входа → сколько досок выбили зомби (только за них платим при починке)
local rng = Random.new()
local dayMode = false -- днём доски убраны: можно свободно бегать туда-сюда

local function setPlank(plank: BasePart, alive: boolean)
	plank.Transparency = if alive then 0 else 1
	plank.CanCollide = alive
	plank.CanQuery = alive
end

local function refresh(w: Types.Window)
	local count = intact[w.id]
	for i, plank in w.planks do
		setPlank(plank, not dayMode and i <= count)
	end
	w.prompt.Enabled = not dayMode and count < #w.planks
	w.dismantle.Enabled = not dayMode and count > 0
	w.model:SetAttribute("Planks", if dayMode then 0 else count)
end

-- Привязать сервис к новой локации (вызывается и при смене локации).
function BarricadeService.setMap(map: Types.MapInfo)
	windows = map.windows
	table.clear(intact)
	table.clear(brokenByZombies)
	for _, w in windows do
		intact[w.id] = #w.planks
		brokenByZombies[w.id] = 0
		refresh(w)
		w.prompt.Triggered:Connect(function(player: Player)
			-- упавший игрок чинить не может
			if dayMode or player:GetAttribute("Downed") then
				return
			end
			if intact[w.id] < #w.planks then
				intact[w.id] += 1
				-- монеты — только за доски, выбитые зомби (иначе «разобрал-починил» превратится в ферму монет)
				if brokenByZombies[w.id] > 0 then
					brokenByZombies[w.id] -= 1
					EconomyService.addRepairReward(player)
				end
				refresh(w)
			end
		end)
		w.dismantle.Triggered:Connect(function(player: Player)
			-- выйти из укрытия по своей воле: разбираем все доски сразу (чинить можно обратно)
			if dayMode or player:GetAttribute("Downed") then
				return
			end
			if intact[w.id] > 0 then
				intact[w.id] = 0
				refresh(w)
			end
		end)
	end
end

function BarricadeService.init(map: Types.MapInfo)
	BarricadeService.setMap(map)
end

function BarricadeService.repairAll()
	for _, w in windows do
		intact[w.id] = #w.planks
		brokenByZombies[w.id] = 0
		refresh(w)
	end
end

-- Днём (open = true) баррикады пропадают; с началом ночи (open = false) встают целыми.
-- Кто остался снаружи — остаётся снаружи.
function BarricadeService.setOpen(open: boolean)
	dayMode = open
	if not open then
		for _, w in windows do
			intact[w.id] = #w.planks
			brokenByZombies[w.id] = 0
		end
	end
	for _, w in windows do
		refresh(w)
	end
end

function BarricadeService.isOpen(w: Types.Window): boolean
	return dayMode or intact[w.id] <= 0
end

function BarricadeService.damage(w: Types.Window, planks: number)
	if dayMode then
		return
	end
	local before = intact[w.id]
	intact[w.id] = math.max(0, before - planks)
	brokenByZombies[w.id] += before - intact[w.id]
	refresh(w)
end

-- Закрытый вход (есть целые доски), который защищает цель: ближайший к ней внутри maxDist.
-- Нужен зомби, которым закрыт путь к игроку: они идут ломать именно эту баррикаду.
function BarricadeService.guardingEntrance(targetPos: Vector3, maxDist: number): Types.Window?
	if dayMode then
		return nil
	end
	local best: Types.Window? = nil
	local bestDist = maxDist
	for _, w in windows do
		if intact[w.id] > 0 then
			local d = (w.inside - targetPos).Magnitude
			if d < bestDist then
				best, bestDist = w, d
			end
		end
	end
	return best
end

-- Случайный вход для нового зомби: чем ближе к точке спавна и чем больше вес входа, тем вероятнее.
-- Так волна делится между несколькими точками обороны, а центральный магазин атакуют редко.
function BarricadeService.pickEntrance(pos: Vector3): Types.Window?
	local weights: { number } = {}
	local total = 0
	for i, w in windows do
		local d = (w.outside - pos).Magnitude
		local score = w.weight / (1 + (d / 60) ^ 2)
		weights[i] = score
		total += score
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber(0, total)
	for i, w in windows do
		roll -= weights[i]
		if roll <= 0 then
			return w
		end
	end
	return windows[#windows]
end

return BarricadeService
