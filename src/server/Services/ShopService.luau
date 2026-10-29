--!strict
-- Точки магазина оружия: военные палатки (платно, только днём) и тестовые стенды (бесплатно, под флагом Config.TestStands).
-- Меню покупки открывается кнопкой у палатки; WeaponService спрашивает отсюда, стоит ли игрок у магазина.
-- Каждое утро игрокам приходят метки на палатки в радиусе Config.TentMarkRadius (студов) от них.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))

local ShopService = {}

export type Point = { name: string, center: Vector3, radius: number, free: boolean, tent: boolean }

local points: { Point } = {}
local folder: Folder? = nil

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isDay(): boolean
	local phase = ReplicatedStorage:GetAttribute("Phase")
	return phase == "Day" or phase == "Intermission"
end

-- Ближайшая точка магазина, в радиусе которой стоит игрок
function ShopService.pointFor(player: Player): Point?
	local root = rootOf(player)
	if not root then
		return nil
	end
	local best: Point? = nil
	local bestDist = math.huge
	for _, p in points do
		local d = (Vector3.new(p.center.X, root.Position.Y, p.center.Z) - root.Position).Magnitude
		local dy = math.abs(p.center.Y - root.Position.Y)
		if d <= p.radius and dy <= 30 and d < bestDist then
			best = p
			bestDist = d
		end
	end
	return best
end

-- Добавить точку. withPrompt: поставить кнопку «Открыть магазин» (E) в центре (у тестового стенда кнопка своя)
-- Убрать магазин по центру (шатёр сняли на новый раунд)
function ShopService.removePointAt(center: Vector3)
	for i = #points, 1, -1 do
		if (points[i].center - center).Magnitude < 1 then
			table.remove(points, i)
		end
	end
	if folder then
		for _, part in folder:GetChildren() do
			if part:IsA("BasePart") and (part.Position - (center + Vector3.new(0, 2, 0))).Magnitude < 1 then
				part:Destroy()
			end
		end
	end
end

function ShopService.addPoint(name: string, center: Vector3, radius: number, free: boolean, tent: boolean, withPrompt: boolean)
	local point: Point = { name = name, center = center, radius = radius, free = free, tent = tent }
	table.insert(points, point)
	if not withPrompt then
		return
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ShopPoints"
		folder.Parent = workspace
	end
	local part = Instance.new("Part")
	part.Name = "ShopPrompt"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(2, 2, 2)
	part.Position = center + Vector3.new(0, 2, 0)
	part.Parent = folder
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open the shop"
	prompt.ObjectText = name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = math.min(radius, 24)
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player: Player)
		if not free and not isDay() then
			Remotes.get("Notify"):FireClient(player, "The shop is closed at night — this is a shelter", 2)
			return
		end
		Remotes.get("ShopOpen"):FireClient(player)
	end)
end

local function sendMarkers(player: Player)
	local list: { { pos: Vector3, name: string } } = {}
	local root = rootOf(player)
	if root and isDay() then
		for _, p in points do
			if p.tent and (p.center - root.Position).Magnitude <= Config.TentMarkRadius then
				table.insert(list, { pos = p.center, name = p.name })
			end
		end
	end
	Remotes.get("TentMarkers"):FireClient(player, list)
end

function ShopService.init(map: Types.MapInfo)
	for _, s in map.shops or {} do
		ShopService.addPoint(s.name, s.center, s.radius, false, true, true)
	end
	-- атрибуты игрока: рядом ли магазин (для клавиши B) и бесплатный ли он
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				local p = ShopService.pointFor(player)
				local near = p ~= nil and (p.free or isDay())
				if player:GetAttribute("NearShop") ~= near then
					player:SetAttribute("NearShop", near)
				end
				local free = p ~= nil and p.free
				if player:GetAttribute("ShopFree") ~= free then
					player:SetAttribute("ShopFree", free)
				end
			end
			task.wait(0.4)
		end
	end)
	-- утро: метки на палатки поблизости; ночью метки снимаются
	ReplicatedStorage:GetAttributeChangedSignal("Phase"):Connect(function()
		for _, player in Players:GetPlayers() do
			sendMarkers(player)
		end
	end)
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(1)
			sendMarkers(player)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
end

return ShopService
