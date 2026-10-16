--!strict
-- Открываемые здания: игроки «скидываются» монетами через вывеску; открытое здание отпирает входы и даёт бонус.
-- Магазин в центре на ночь закрывается для всех: кто остался внутри — выталкивается на улицу.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local BarricadeService = require(script.Parent:WaitForChild("BarricadeService"))
local ItemService = require(script.Parent:WaitForChild("ItemService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local BuildingService = {}

local defs: { [string]: Config.BuildingDef } = {}
for _, d in Config.Buildings do
	defs[d.id] = d
end

local map: Types.MapInfo? = nil
local infos: { [string]: Types.BuildingInfo } = {}
local funded: { [string]: number } = {}
local unlocked: { [string]: boolean } = {}
local stock: { [string]: { [string]: number } } = {} -- здание → предмет ("medkit"/"energy") → сколько осталось
local claimed: { [string]: { [Player]: boolean } } = {} -- склад холодного оружия: кто уже взял

local function notify(player: Player?, text: string, seconds: number)
	local r = Remotes.get("Notify")
	if player then
		r:FireClient(player, text, seconds)
	else
		r:FireAllClients(text, seconds)
	end
end

-- Сколько монет вкладывает один «заход» (10% цены, не меньше 100)
local function stepOf(def: Config.BuildingDef): number
	return math.max(100, math.ceil(def.cost / 10 / 50) * 50)
end

local function updateSign(id: string)
	local info, def = infos[id], defs[id]
	if not info or not def then
		return
	end
	local open = unlocked[id] == true
	if info.signLabel then
		info.signLabel.Text = if open
			then def.name .. "\nоткрыто"
			else string.format("%s\n● %d / %d", def.name, funded[id] or 0, def.cost)
	end
	if info.signPrompt then
		info.signPrompt.Enabled = not open
		info.signPrompt.ObjectText = def.name
		info.signPrompt.ActionText = string.format("Вложить %d ●", stepOf(def))
	end
end

local function updateSpots(id: string)
	local info = infos[id]
	if not info then
		return
	end
	local open = unlocked[id] == true
	for _, spot in info.spots do
		local enabled = open
		if spot.kind == "medkit" or spot.kind == "energy" then
			local left = if stock[id] then (stock[id][spot.kind] or 0) else 0
			enabled = open and left > 0
			spot.prompt.ObjectText = string.format("%s: %d", if spot.kind == "medkit" then "Аптечки" else "Энергетики", left)
		end
		spot.prompt.Enabled = enabled
	end
end

local function applyBonus(id: string)
	local def = defs[id]
	if not def or not def.bonus then
		return
	end
	if def.bonus == "medkits" then
		-- запас на склад: по 1 на двоих игроков (1–2 игрока → 1+1, 3–4 → 2+2, 5–6 → 3+3)
		local n = math.max(1, math.ceil(#Players:GetPlayers() / 2))
		stock[id] = { medkit = n, energy = n }
	elseif def.bonus == "melee" then
		claimed[id] = {}
	elseif def.bonus == "teamLife" then
		ReplicatedStorage:SetAttribute("TeamLives", ((ReplicatedStorage:GetAttribute("TeamLives") :: number?) or 0) + 1)
	end
end

local function unlock(id: string)
	local def = defs[id]
	unlocked[id] = true
	BarricadeService.setPointLocked(id, false)
	applyBonus(id)
	updateSign(id)
	updateSpots(id)
	if def then
		notify(nil, string.format("Открыто: %s — %s", def.name, def.info), 5)
	end
end

local function contribute(player: Player, id: string)
	local def = defs[id]
	if not def or unlocked[id] or not RateLimit.allow(player, "Contribute", 0.25) then
		return
	end
	local remaining = def.cost - (funded[id] or 0)
	local amount = math.min(stepOf(def), remaining, EconomyService.get(player))
	if amount <= 0 or not EconomyService.trySpend(player, amount) then
		notify(player, "Не хватает монет", 1.5)
		return
	end
	funded[id] = (funded[id] or 0) + amount
	if funded[id] >= def.cost then
		unlock(id)
	else
		updateSign(id)
	end
end

local function onSpot(player: Player, id: string, spot: Types.Spot)
	if not unlocked[id] or player:GetAttribute("Downed") or not RateLimit.allow(player, "BuildingSpot", 0.3) then
		return
	end
	if spot.kind == "medkit" or spot.kind == "energy" then
		local s = stock[id]
		if not s or (s[spot.kind] or 0) <= 0 then
			notify(player, "Закончились", 1.5)
			return
		end
		s[spot.kind] -= 1
		ItemService.give(player, if spot.kind == "medkit" then "Medkit" else "EnergyDrink")
		updateSpots(id)
	elseif string.sub(spot.kind, 1, 6) == "melee:" then
		local weaponId = string.sub(spot.kind, 7)
		local who = claimed[id]
		if not who or not Config.Weapons[weaponId] then
			return
		end
		if who[player] then
			notify(player, "Со склада можно взять только одно оружие", 2)
			return
		end
		who[player] = true
		WeaponService.give(player, weaponId)
		notify(player, "Получено: " .. Config.Weapons[weaponId].name, 2)
	end
end

-- Новый раунд (и новая локация): всё закрыто, кроме бесплатных зданий
function BuildingService.reset()
	ReplicatedStorage:SetAttribute("TeamLives", 0)
	table.clear(funded)
	table.clear(stock)
	table.clear(claimed)
	for id in infos do
		local def = defs[id]
		funded[id] = 0
		unlocked[id] = def == nil or def.cost <= 0
		BarricadeService.setPointLocked(id, not unlocked[id])
		updateSign(id)
		updateSpots(id)
	end
end

-- Привязать сервис к новой локации; вызывать после BarricadeService.setMap
function BuildingService.setMap(newMap: Types.MapInfo)
	map = newMap
	table.clear(infos)
	for _, info in newMap.buildings do
		infos[info.id] = info
		local id = info.id
		if info.signPrompt then
			info.signPrompt.Triggered:Connect(function(player: Player)
				contribute(player, id)
			end)
		end
		for _, spot in info.spots do
			spot.prompt.Triggered:Connect(function(player: Player)
				onSpot(player, id, spot)
			end)
		end
	end
	BuildingService.reset()
end

function BuildingService.isUnlocked(id: string): boolean
	return unlocked[id] == true
end

-- Магазин ночью ------------------------------------------------------------

-- Игроков, оставшихся в магазине, выставляем наружу с ближайшей стороны
local function expelFromShop()
	local m = map
	if not m then
		return
	end
	local shop = m.shop
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if char and root then
			local rel = root.Position - shop.center
			if math.abs(rel.X) < shop.halfX + 1 and math.abs(rel.Z) < shop.halfZ + 1 and root.Position.Y < 14 then
				local dx = shop.halfX - math.abs(rel.X)
				local dz = shop.halfZ - math.abs(rel.Z)
				local sx = if rel.X >= 0 then 1 else -1
				local sz = if rel.Z >= 0 then 1 else -1
				local target = if dx < dz
					then Vector3.new(shop.center.X + sx * (shop.halfX + 8), 3, root.Position.Z)
					else Vector3.new(root.Position.X, 3, shop.center.Z + sz * (shop.halfZ + 8))
				char:PivotTo(CFrame.new(target))
				notify(player, "Магазин закрыт на ночь", 3)
			end
		end
	end
end

function BuildingService.closeShop()
	BarricadeService.setPointLocked("shop", true)
	expelFromShop()
end

function BuildingService.openShop()
	BarricadeService.setPointLocked("shop", false)
end

return BuildingService
