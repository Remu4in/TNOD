--!strict
-- Перки команды после боссов. Каждый игрок получает свои 3 случайных перка и выбирает один (у каждого — своё предложение),
-- выбранные перки действуют на всю команду до конца раунда. Не выбрал за OFFER_SECONDS — перк выбирается случайно из предложенных.
-- Состояние — атрибут ReplicatedStorage.Perks (см. Shared/Perks). Донатные способы получения перков — позже.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Perks = require(Shared:WaitForChild("Perks"))

local PerkService = {}

local OFFER_SECONDS = 30

type Offer = { id: number, options: { string }, chosen: boolean }
local offers: { [Player]: Offer } = {}
local nextOfferId = 0
local rng = Random.new()

local function publish(stacks: { [string]: number })
	ReplicatedStorage:SetAttribute("Perks", Perks.encode(stacks))
end

-- Максимум здоровья по перкам: вызывать при смене перков и при появлении персонажа
function PerkService.applyHealth(player: Player, heal: boolean)
	local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not h then
		return
	end
	local want = Config.Player.MaxHealth + Perks.total("health")
	local added = want - h.MaxHealth
	h.MaxHealth = want
	if heal and added > 0 and h.Health > 0 then
		h.Health = math.min(want, h.Health + added)
	end
	if player:GetAttribute("Downed") ~= true and not h.SeatPart then
		h.WalkSpeed = if player:GetAttribute("Sprinting") == true then Perks.sprintSpeed() else Perks.walkSpeed()
	end
end

local function applyAll()
	for _, p in Players:GetPlayers() do
		PerkService.applyHealth(p, true)
	end
end

local function addStack(id: string)
	local def = Perks.byId(id)
	if not def then
		return
	end
	local stacks = Perks.stacks()
	if (stacks[id] or 0) >= def.max then
		return
	end
	stacks[id] = (stacks[id] or 0) + 1
	publish(stacks)
	applyAll()
end

local function finish(player: Player, offer: Offer, id: string)
	if offer.chosen then
		return
	end
	offer.chosen = true
	addStack(id)
	local def = Perks.byId(id)
	if def then
		Remotes.get("Notify"):FireAllClients(string.format("%s выбрал перк: %s (%s)", player.DisplayName, def.name, def.desc), 4)
	end
end

local function randomOptions(count: number): { string }
	local stacks = Perks.stacks()
	local pool: { string } = {}
	for _, def in Config.Perks do
		if (stacks[def.id] or 0) < def.max then
			table.insert(pool, def.id)
		end
	end
	local picked: { string } = {}
	while #picked < count and #pool > 0 do
		table.insert(picked, table.remove(pool, rng:NextInteger(1, #pool)) :: string)
	end
	return picked
end

-- Предложить перки всем игрокам (после босса)
function PerkService.openOffers()
	for _, player in Players:GetPlayers() do
		local options = randomOptions(3)
		if #options > 0 then
			nextOfferId += 1
			local offer: Offer = { id = nextOfferId, options = options, chosen = false }
			offers[player] = offer
			local payload: { { id: string, name: string, desc: string, stacks: number, max: number } } = {}
			local stacks = Perks.stacks()
			for _, id in options do
				local def = Perks.byId(id) :: Perks.Def
				table.insert(payload, { id = id, name = def.name, desc = def.desc, stacks = stacks[id] or 0, max = def.max })
			end
			Remotes.get("PerkOffer"):FireClient(player, offer.id, payload, OFFER_SECONDS)
			task.delay(OFFER_SECONDS + 1, function()
				if offers[player] == offer and not offer.chosen then
					finish(player, offer, options[rng:NextInteger(1, #options)])
				end
			end)
		end
	end
end

function PerkService.reset()
	table.clear(offers)
	publish({})
	applyAll()
end

-- Выбор игрока (из события PerkChoose; клиент присылает только номер предложения и номер карточки)
function PerkService.choose(player: Player, offerId: unknown, index: unknown): boolean
	if typeof(offerId) ~= "number" or typeof(index) ~= "number" then
		return false
	end
	local offer = offers[player]
	if not offer or offer.id ~= offerId or offer.chosen then
		return false
	end
	local id = offer.options[math.floor(index)]
	if not id then
		return false
	end
	finish(player, offer, id)
	return true
end

function PerkService.init()
	publish({})
	Remotes.get("PerkChoose").OnServerEvent:Connect(function(player: Player, offerId: unknown, index: unknown)
		if RateLimit.allow(player, "PerkChoose", 0.3) then
			PerkService.choose(player, offerId, index)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		offers[player] = nil
	end)
end

return PerkService
