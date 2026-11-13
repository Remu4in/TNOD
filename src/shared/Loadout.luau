--!strict
-- Стартовый набор (план релиза 2026-11-11): игрок выбирает в лобби оружие и холодное из своего (кейсы и покупки за робуксы — навсегда).
-- Без Roblox API: has(perk) — есть ли у игрока право (атрибут Has_<perk>). Тесты — tests/run.luau.

local Config = require(script.Parent:WaitForChild("Config"))
local CaseRules = require(script.Parent:WaitForChild("CaseRules"))

local Loadout = {}

Loadout.DefaultMelee = "Knife"

-- Всё, что можно получить навсегда: оружие из кейсов (ножи из кейса ножей, Karambit и Balisong — и прямой покупкой)
local function allPaid(): { string }
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, case in Config.Donate.Cases do
		for _, e in case.pool do
			if Config.Weapons[e.id] and not seen[e.id] then
				seen[e.id] = true
				table.insert(list, e.id)
			end
		end
	end
	return list
end

-- Всё, что можно получить навсегда (для окна набора: чего нет — показывается закрытым)
function Loadout.all(): { string }
	return allPaid()
end

-- Своё огнестрельное (без пистолета: он есть у всех)
function Loadout.guns(has: (string) -> boolean): { string }
	local out: { string } = {}
	for _, id in allPaid() do
		if not Config.Weapons[id].melee and has(CaseRules.perkFor(id)) then
			table.insert(out, id)
		end
	end
	return out
end

-- Своё холодное: обычный нож есть у всех
function Loadout.melee(has: (string) -> boolean): { string }
	local out: { string } = { Loadout.DefaultMelee }
	for _, id in allPaid() do
		if Config.Weapons[id].melee and has(CaseRules.perkFor(id)) then
			table.insert(out, id)
		end
	end
	return out
end

-- Можно ли поставить в набор: gun — "" (без оружия) или своё огнестрельное; melee — нож или своё холодное
function Loadout.validGun(id: any, has: (string) -> boolean): boolean
	return id == "" or (typeof(id) == "string" and table.find(Loadout.guns(has), id) ~= nil)
end

function Loadout.validMelee(id: any, has: (string) -> boolean): boolean
	return typeof(id) == "string" and table.find(Loadout.melee(has), id) ~= nil
end

-- Что выдать в начале раунда: (оружие или nil, холодное). Чужое или истёкшее не выдаём.
function Loadout.pick(gun: any, melee: any, has: (string) -> boolean): (string?, string)
	local g = if gun ~= "" and Loadout.validGun(gun, has) then gun :: string else nil
	local m = if Loadout.validMelee(melee, has) then melee :: string else Loadout.DefaultMelee
	return g, m
end

return Loadout
