--!strict
-- Баррикады на окнах: зомби ломают доски, игроки чинят через ProximityPrompt.

local Types = require(script.Parent.Parent:WaitForChild("Types"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))

local BarricadeService = {}

local windows: { Types.Window } = {}
local intact: { [number]: number } = {} -- id окна → целых досок

local function setPlank(plank: BasePart, alive: boolean)
	plank.Transparency = if alive then 0 else 1
	plank.CanCollide = alive
	plank.CanQuery = alive
end

local function refresh(w: Types.Window)
	local count = intact[w.id]
	for i, plank in w.planks do
		setPlank(plank, i <= count)
	end
	w.prompt.Enabled = count < #w.planks
	w.model:SetAttribute("Planks", count)
end

function BarricadeService.init(map: Types.MapInfo)
	windows = map.windows
	for _, w in windows do
		intact[w.id] = #w.planks
		refresh(w)
		w.prompt.Triggered:Connect(function(player: Player)
			-- упавший игрок чинить не может
			if player:GetAttribute("Downed") then
				return
			end
			if intact[w.id] < #w.planks then
				intact[w.id] += 1
				refresh(w)
				EconomyService.addRepairReward(player)
			end
		end)
	end
end

function BarricadeService.repairAll()
	for _, w in windows do
		intact[w.id] = #w.planks
		refresh(w)
	end
end

function BarricadeService.isOpen(w: Types.Window): boolean
	return intact[w.id] <= 0
end

function BarricadeService.damage(w: Types.Window, planks: number)
	intact[w.id] = math.max(0, intact[w.id] - planks)
	refresh(w)
end

function BarricadeService.nearestWindow(pos: Vector3): Types.Window?
	local best: Types.Window? = nil
	local bestDist = math.huge
	for _, w in windows do
		local d = (w.outside - pos).Magnitude
		if d < bestDist then
			best, bestDist = w, d
		end
	end
	return best
end

return BarricadeService
