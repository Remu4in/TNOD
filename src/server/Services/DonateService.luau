--!strict
-- Донат: товары Config.Donate.Items (Developer Products), покупка, сроки и эффекты. Права лежат в профиле (DataService.perks: ключ → до какого времени),
-- игроку ставятся атрибуты Has_<ключ>: их читают сервисы и клиент (менять атрибуты игрока может только сервер).
-- Товар без productId в Studio выдаётся сразу (для проверки), в игре показывает «Coming soon».
-- Топ недели: при входе проверяем итоги прошлой недели (топ-3 игрока и лучшая команда) — VIP на Config.Donate.WeeklyRewardDays дней, один раз за неделю.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local DataService = require(script.Parent:WaitForChild("DataService"))
local RatingService = require(script.Parent:WaitForChild("RatingService"))

local DonateService = {}

local FOREVER = 2 ^ 40
local byId: { [string]: any } = {}
local byProduct: { [number]: any } = {}
for _, item in Config.Donate.Items do
	byId[item.id] = item
	if item.productId and item.productId > 0 then
		byProduct[item.productId] = item
	end
end

local applyHandler: ((Player) -> ())? = nil -- эффекты в матче (RoundService ставит обработчик: монеты, здания, ножи, турель)
local checkedWeek: { [Player]: boolean } = {}

local function notify(player: Player, text: string, seconds: number?)
	Remotes.get("Notify"):FireClient(player, text, seconds or 4)
end

-- Атрибуты Has_<ключ> по профилю; срок истёк — атрибут снимается
local function publish(player: Player)
	local perks = DataService.perks(player)
	local now = os.time()
	for _, item in Config.Donate.Items do
		local active = perks ~= nil and (perks[item.perk] or 0) > now
		if active then
			player:SetAttribute("Has_" .. item.perk, true)
		elseif player:GetAttribute("Has_" .. item.perk) ~= nil then
			player:SetAttribute("Has_" .. item.perk, nil)
		end
	end
	local h = applyHandler
	if h then
		h(player)
	end
end

function DonateService.has(player: Player, perk: string): boolean
	return player:GetAttribute("Has_" .. perk) == true
end

-- Выдать право: срок прибавляется к оставшемуся; days = nil — навсегда
local function grant(player: Player, perk: string, days: number?)
	local perks = DataService.perks(player)
	if not perks then
		return false
	end
	local now = os.time()
	perks[perk] = if days then math.max(perks[perk] or 0, now) + days * 86400 else FOREVER
	DataService.touch(player)
	publish(player)
	return true
end

local function onReceipt(info: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	local item = byProduct[info.ProductId]
	if not player or not item or not DataService.canSave(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if DataService.hasReceipt(player, info.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- уже выдано, ответ потерялся
	end
	if not grant(player, item.perk, item.days) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	DataService.addReceipt(player, info.PurchaseId)
	DataService.flush({ player }, 8)
	notify(player, "Thank you! Purchased: " .. item.name, 5)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Запрос на покупку (из окна магазина, в лобби и в матче)
function DonateService.buy(player: Player, id: unknown)
	if typeof(id) ~= "string" or not RateLimit.allow(player, "DonateBuy", 1) then
		return
	end
	local item = byId[id]
	if not item then
		return
	end
	if not item.days and DonateService.has(player, item.perk) then
		notify(player, "Already owned: " .. item.name)
		return
	end
	if item.productId and item.productId > 0 then
		MarketplaceService:PromptProductPurchase(player, item.productId)
	elseif RunService:IsStudio() then
		grant(player, item.perk, item.days)
		notify(player, "Studio test: granted " .. item.name)
	else
		notify(player, "This item is coming soon")
	end
end

-- Итоги прошлой недели: топ-3 игрока и лучшая команда получают VIP на несколько дней (один раз)
local function checkWeekly(player: Player)
	if checkedWeek[player] or not DataService.canSave(player) then
		return
	end
	checkedWeek[player] = true
	local week = RatingService.currentWeek()
	if DataService.weekClaim(player) >= week then
		return
	end
	if RatingService.isWeekWinner(week - 1, player.UserId) then
		DataService.setWeekClaim(player, week)
		grant(player, "vip", Config.Donate.WeeklyRewardDays)
		notify(player, string.format("Top of last week! VIP for %d days — enjoy", Config.Donate.WeeklyRewardDays), 8)
	end
end

function DonateService.setApplyHandler(handler: (Player) -> ())
	applyHandler = handler
end

function DonateService.init()
	MarketplaceService.ProcessReceipt = onReceipt
	Remotes.get("DonateBuy").OnServerEvent:Connect(DonateService.buy)
	DataService.setLoadedHandler(function(player: Player)
		publish(player)
		task.spawn(checkWeekly, player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		checkedWeek[player] = nil
	end)
	for _, p in Players:GetPlayers() do
		publish(p)
	end
	-- срок мог истечь во время игры
	task.spawn(function()
		while true do
			task.wait(60)
			for _, p in Players:GetPlayers() do
				publish(p)
			end
		end
	end)
end

return DonateService
