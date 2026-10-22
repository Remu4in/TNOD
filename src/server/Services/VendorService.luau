--!strict
-- НПС-продавцы в особых зданиях: появляются только днём и только в здании, открытом за монеты (вывеска, BuildingService).
-- Места — маркеры Workspace.Markers.Vendor_<id> (MapInfo.vendors). Покупку за монеты проверяет и выполняет сервер.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))
local ItemService = require(script.Parent:WaitForChild("ItemService"))
local BuildingService = require(script.Parent:WaitForChild("BuildingService"))
local EquipmentService = require(script.Parent:WaitForChild("EquipmentService"))

local VendorService = {}

type Vendor = { id: string, model: Model, root: BasePart, track: AnimationTrack?, shown: boolean, always: boolean? }

local vendors: { [string]: Vendor } = {}
local stash: Folder
local live: Folder
local TALK_RANGE = 18
local IDLE_ANIM = "rbxassetid://180435571" -- стандартная стойка R6

local function isDay(): boolean
	local phase = ReplicatedStorage:GetAttribute("Phase")
	return phase == "Day" or phase == "Intermission"
end

local function open(v: Vendor): boolean
	if v.always then
		return true
	end
	return isDay() and BuildingService.isUnlocked(v.id)
end

local function playIdle(v: Vendor)
	local hum = v.model:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
	local anim = Instance.new("Animation")
	anim.AnimationId = IDLE_ANIM
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = true
		track:Play()
		v.track = track
	end
end

local function build(id: string, position: Vector3, facing: Vector3, index: number): Vendor?
	local def = Config.Vendors[id]
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("NPC")
	local template = lib and lib:FindFirstChild(if index % 2 == 0 then "Survivor2" else "Survivor1")
	if not def or not template then
		warn("[VendorService] нет продавца или модели для " .. id)
		return nil
	end
	local model = template:Clone()
	model.Name = "Vendor_" .. id
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local flat = Vector3.new(facing.X, 0, facing.Z)
	model:PivotTo(CFrame.lookAt(position + Vector3.new(0, 3, 0), position + Vector3.new(0, 3, 0) + (if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, 1))))
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanQuery = d == root -- по продавцам не стреляем; кнопка висит на корне
		end
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(150, 30)
	gui.StudsOffset = Vector3.new(0, 3.6, 0)
	gui.MaxDistance = 50
	gui.Parent = root
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.fromRGB(255, 200, 80)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = def.name
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Торговать"
	prompt.ObjectText = def.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	local v: Vendor = { id = id, model = model, root = root, track = nil, shown = false }
	prompt.Triggered:Connect(function(player: Player)
		if not open(v) or not PlayerService.isUp(player) then
			return
		end
		Remotes.get("ShopOpen"):FireClient(player, { vendorId = id, title = def.name, greeting = def.greeting, items = def.items })
	end)
	model.Parent = stash
	return v
end

local function refresh()
	for _, v in vendors do
		if v.always then
			continue
		end
		local want = open(v)
		if want and not v.shown then
			v.model.Parent = live
			playIdle(v)
			v.shown = true
		elseif not want and v.shown then
			if v.track then
				v.track:Stop()
				v.track = nil
			end
			v.model.Parent = stash
			v.shown = false
		end
	end
end

local function onBuy(player: Player, vendorId: unknown, itemId: unknown)
	if typeof(vendorId) ~= "string" or typeof(itemId) ~= "string" or not RateLimit.allow(player, "VendorBuy", 0.3) then
		return
	end
	local v = vendors[vendorId]
	local def = Config.Vendors[if string.sub(vendorId, 1, 8) == "Vending_" then "Vending" else vendorId]
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not v or not def or not root or not PlayerService.isUp(player) or not open(v) then
		return
	end
	if (root.Position - v.root.Position).Magnitude > TALK_RANGE then
		return
	end
	local item: Config.VendorItem? = nil
	for _, it in def.items do
		if it.id == itemId then
			item = it
		end
	end
	local notify = Remotes.get("Notify")
	if not item then
		return
	end
	-- условия до списания монет
	if item.kind == "weapon" then
		local def2 = Config.Weapons[item.id]
		if not def2 then
			return
		end
		for _, c in { player:FindFirstChildOfClass("Backpack"), player.Character } do
			if c then
				for _, t in c:GetChildren() do
					if t:IsA("Tool") and t:GetAttribute("WeaponId") == item.id and def2.melee then
						notify:FireClient(player, "Уже есть", 1.5)
						return
					end
				end
			end
		end
	end
	if item.kind == "ammo" then
		local can, why = WeaponService.canRefillHeld(player)
		if not can then
			notify:FireClient(player, why or "Нельзя", 2)
			return
		end
	end
	if not EconomyService.trySpend(player, item.price) then
		notify:FireClient(player, "Не хватает монет", 1.5)
		return
	end
	local ok = true
	if item.kind == "ammo" then
		ok = WeaponService.refillHeld(player)
	elseif item.kind == "item" then
		ItemService.give(player, item.id)
	elseif item.kind == "weapon" then
		WeaponService.give(player, item.id)
	elseif item.kind == "equip" then
		ok = EquipmentService.give(player, item.id)
	elseif item.kind == "life" then
		ReplicatedStorage:SetAttribute("TeamLives", ((ReplicatedStorage:GetAttribute("TeamLives") :: number?) or 0) + 1)
	else
		ok = false
	end
	if ok then
		notify:FireClient(player, "Куплено: " .. item.name, 1.5)
	else
		EconomyService.add(player, item.price) -- возврат монет
		notify:FireClient(player, "Нельзя: достигнут лимит", 2)
	end
end

-- Вендинговые автоматы по маркерам Workspace.Markers.Vending_<n>: модель из Assets.Props.Vending, лицом по LookVector маркера
local function buildVending(marker: BasePart)
	local lib = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("Props")
	local template = lib and lib:FindFirstChild("Vending")
	local def = Config.Vendors.Vending
	if not template or not def then
		warn("[VendorService] нет модели Assets.Props.Vending")
		return
	end
	local model = template:Clone() :: Model
	model.Name = marker.Name
	local look = Vector3.new(marker.CFrame.LookVector.X, 0, marker.CFrame.LookVector.Z)
	local ground = Vector3.new(marker.Position.X, marker.Position.Y - marker.Size.Y / 2, marker.Position.Z)
	model:PivotTo(CFrame.lookAt(ground, ground + (if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, 1))))
	local bbCf, bbSize = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + Vector3.new(0, ground.Y - (bbCf.Position.Y - bbSize.Y / 2), 0)) -- низ автомата на землю
	local biggest: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			if not biggest or d.Size.Magnitude > biggest.Size.Magnitude then
				biggest = d
			end
		elseif d:IsA("SurfaceGui") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy() -- внутренняя кнопка модели не нужна: торгуем через подсказку
		end
	end
	if not biggest then
		model:Destroy()
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Купить"
	prompt.ObjectText = def.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = biggest
	local v: Vendor = { id = marker.Name, model = model, root = biggest, track = nil, shown = true, always = true }
	prompt.Triggered:Connect(function(player: Player)
		if not PlayerService.isUp(player) then
			return
		end
		Remotes.get("ShopOpen"):FireClient(player, { vendorId = marker.Name, title = def.name, greeting = def.greeting, items = def.items })
	end)
	model.Parent = live
	vendors[marker.Name] = v
end

-- Автомат, установленный по ходу игры (с шатром)
function VendorService.addVending(marker: BasePart)
	buildVending(marker)
end

function VendorService.init(map: Types.MapInfo)
	stash = Instance.new("Folder")
	stash.Name = "VendorStash"
	stash.Parent = ServerStorage
	live = Instance.new("Folder")
	live.Name = "Vendors"
	live.Parent = workspace
	for i, m in map.vendors or {} do
		local v = build(m.id, m.position, m.facing, i)
		if v then
			vendors[m.id] = v
		end
	end
	local markers = workspace:FindFirstChild("Markers")
	if markers then
		for _, m in markers:GetChildren() do
			if m:IsA("BasePart") and string.sub(m.Name, 1, 8) == "Vending_" then
				buildVending(m)
			end
		end
	end
	Remotes.get("VendorBuy").OnServerEvent:Connect(onBuy)
	task.spawn(function()
		while true do
			refresh()
			task.wait(0.5)
		end
	end)
end

return VendorService
