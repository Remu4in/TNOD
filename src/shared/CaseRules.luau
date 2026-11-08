--!strict
-- Кейсы доната: что может выпасть и с каким шансом. Без Roblox API (тесты в tests/run.luau).
-- Уже полученное оружие из кейса исключается, шансы остальных пересчитываются: игрок видит настоящие шансы до оплаты.

local CaseRules = {}

export type Entry = { id: string, w: number }
export type Chance = { id: string, chance: number }

local NAMED_PERK: { [string]: string } = { Karambit = "karambit", Balisong = "balisong" }

-- Ключ права в профиле для оружия из кейса
function CaseRules.perkFor(weaponId: string): string
	return NAMED_PERK[weaponId] or ("gun_" .. weaponId)
end

-- Что ещё может выпасть (сумма шансов = 1); пусто — всё уже получено
function CaseRules.pool(entries: { Entry }, owns: (string) -> boolean): { Chance }
	local total = 0
	for _, e in entries do
		if not owns(e.id) then
			total += e.w
		end
	end
	local out: { Chance } = {}
	if total <= 0 then
		return out
	end
	for _, e in entries do
		if not owns(e.id) then
			table.insert(out, { id = e.id, chance = e.w / total })
		end
	end
	return out
end

-- Выбор по случайному числу r от 0 до 1
function CaseRules.roll(pool: { Chance }, r: number): string?
	local sum = 0
	for _, c in pool do
		sum += c.chance
		if r < sum then
			return c.id
		end
	end
	local last = pool[#pool]
	return if last then last.id else nil
end

return CaseRules
