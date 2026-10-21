--!strict
-- Перки команды (с боссов): общие для всей команды, действуют до конца раунда (игры). Состояние — атрибут ReplicatedStorage.Perks
-- вида "Vigor=2,Mag=1", поэтому и сервер, и клиент считают эффекты одинаково, без лишних событий.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(script.Parent:WaitForChild("Config"))

local Perks = {}

export type Def = { id: string, name: string, desc: string, kind: string, per: number, max: number, color: Color3 }

function Perks.parse(text: string?): { [string]: number }
	local stacks: { [string]: number } = {}
	if typeof(text) ~= "string" then
		return stacks
	end
	for id, n in string.gmatch(text, "(%w+)=(%d+)") do
		stacks[id] = tonumber(n) :: number
	end
	return stacks
end

function Perks.encode(stacks: { [string]: number }): string
	local ids: { string } = {}
	for id, n in stacks do
		if n > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, id .. "=" .. stacks[id])
	end
	return table.concat(parts, ",")
end

function Perks.stacks(): { [string]: number }
	return Perks.parse(ReplicatedStorage:GetAttribute("Perks") :: string?)
end

-- Суммарный бонус всех перков вида kind (например "speed" → 0,10 при двух стаках по 5%)
function Perks.total(kind: string, stacks: { [string]: number }?): number
	local have = stacks or Perks.stacks()
	local sum = 0
	for _, def in Config.Perks :: { Def } do
		if def.kind == kind then
			sum += def.per * (have[def.id] or 0)
		end
	end
	return sum
end

function Perks.mult(kind: string): number
	return 1 + Perks.total(kind)
end

function Perks.walkSpeed(): number
	return Config.Player.WalkSpeed * Perks.mult("speed")
end

function Perks.sprintSpeed(): number
	return Config.Player.SprintSpeed * Perks.mult("speed")
end

function Perks.byId(id: string): Def?
	for _, def in Config.Perks :: { Def } do
		if def.id == id then
			return def
		end
	end
	return nil
end

return Perks
