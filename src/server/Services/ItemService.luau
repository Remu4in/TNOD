--!strict
-- Расходники: аптечка, энергетик и граната. Выдаются продавцами; применяет и проверяет сервер.
-- Граната лежит стопкой в одной ячейке (атрибут Count); бросок — по направлению взгляда, которое присылает клиент (GrenadeController).

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local StaminaService = require(script.Parent:WaitForChild("StaminaService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local ZombieService = require(script.Parent:WaitForChild("ZombieService"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local ItemService = {}

local function notify(player: Player, text: string)
	Remotes.get("Notify"):FireClient(player, text, 1.5)
end

local function use(tool: Tool)
	if tool:GetAttribute("Used") then
		return
	end
	local char = tool.Parent
	if not char or not char:IsA("Model") then
		return
	end
	local player = Players:GetPlayerFromCharacter(char)
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not player or not humanoid or humanoid.Health <= 0 or player:GetAttribute("Downed") then
		return
	end
	local itemId = tool:GetAttribute("ItemId")
	local def = if typeof(itemId) == "string" then Config.Items[itemId] else nil
	if not def then
		return
	end
	if def.heal then
		if humanoid.Health >= humanoid.MaxHealth then
			notify(player, "Health is full")
			return
		end
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + def.heal)
	end
	if def.energy then
		if ((player:GetAttribute("Energy") :: number?) or Config.Player.EnergyMax) >= Config.Player.EnergyMax - 1 then
			notify(player, "Energy is full")
			return
		end
		StaminaService.addEnergy(player, def.energy)
	end
	if def.infiniteWaves then
		StaminaService.grantInfinite(player, def.infiniteWaves)
		notify(player, "Infinite energy — until the end of the next night", 3)
	end
	tool:SetAttribute("Used", true)
	tool:Destroy()
end

local function buildTool(itemId: string, def: Config.ItemDef): Tool
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("ItemId", itemId)
	if def.stack then
		tool:SetAttribute("Count", 1)
		tool.Name = string.format("%s ×1", def.name)
	end
	if not def.grenade then -- граната бросается по команде клиента (направление взгляда), а не по Activated
		tool.Activated:Connect(function()
			use(tool)
		end)
	end
	-- готовая модель из Assets.Items (деталь с именем предмета); нет её — простая заготовка ниже
	local assets = ServerStorage:FindFirstChild("Assets")
	local items = assets and assets:FindFirstChild("Items")
	local template = items and items:FindFirstChild(itemId)
	if template and template:IsA("BasePart") then
		local model = template:Clone()
		model.Name = "Handle"
		model.Parent = tool
		return tool
	end
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Color = def.color
	handle.Material = Enum.Material.SmoothPlastic
	handle.CanCollide = false
	handle.Massless = true
	if def.heal then
		-- аптечка: белая коробка с красным крестом
		handle.Size = Vector3.new(1.1, 0.8, 0.5)
		handle.Parent = tool
		for _, size in { Vector3.new(0.6, 0.12, 0.18), Vector3.new(0.18, 0.12, 0.6) } do
			local cross = Instance.new("Part")
			cross.Name = "Cross"
			cross.Size = size
			cross.Color = Color3.fromRGB(215, 40, 40)
			cross.Material = Enum.Material.SmoothPlastic
			cross.CanCollide = false
			cross.Massless = true
			cross.CFrame = handle.CFrame * CFrame.new(0, 0.44, 0)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = handle
			weld.Part1 = cross
			weld.Parent = cross
			cross.Parent = tool
		end
	else
		-- энергетик: банка
		handle.Shape = Enum.PartType.Cylinder
		handle.Size = Vector3.new(0.9, 0.5, 0.5)
		handle.Material = Enum.Material.Metal
		handle.Parent = tool
	end
	return tool
end

-- Выдать предмет игроку (в рюкзак); false — лимит (игрок получает сообщение)
function ItemService.give(player: Player, itemId: string): boolean
	local def = Config.Items[itemId]
	if not def then
		return false
	end
	local denied = InventoryService.itemDenied(player, itemId)
	if denied then
		notify(player, denied)
		return false
	end
	-- стопка: добавляем к уже имеющейся
	if def.stack then
		local t = InventoryService.itemTool(player, itemId)
		if t then
			local n = ((t:GetAttribute("Count") :: number?) or 1) + 1
			t:SetAttribute("Count", n)
			t.Name = string.format("%s ×%d", def.name, n)
			return true
		end
	end
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if backpack then
		buildTool(itemId, def).Parent = backpack
		return true
	end
	return false
end

-- Лечение тиммейта: подсказка на каждом персонаже, клиент показывает её только с аптечкой в руках (SquadController); проверяет сервер
local function setupHealPrompt(target: Player, char: Model)
	local root = char:WaitForChild("HumanoidRootPart", 5)
	if not root then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HealPrompt"
	prompt.ActionText = "Heal"
	prompt.ObjectText = target.DisplayName
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(helper: Player)
		local hChar = helper.Character
		local tool = hChar and hChar:FindFirstChildOfClass("Tool")
		local hum = char:FindFirstChildOfClass("Humanoid")
		local helperHum = hChar and hChar:FindFirstChildOfClass("Humanoid")
		local def = Config.Items.Medkit
		if helper == target or not tool or tool:GetAttribute("ItemId") ~= "Medkit" or tool:GetAttribute("Used") then
			return
		end
		if not hum or hum.Health <= 0 or target:GetAttribute("Downed") or not helperHum or helperHum.Health <= 0 or helper:GetAttribute("Downed") then
			return
		end
		if hum.Health >= hum.MaxHealth then
			notify(helper, target.DisplayName .. ": health is full")
			return
		end
		tool:SetAttribute("Used", true)
		tool:Destroy()
		hum.Health = math.min(hum.MaxHealth, hum.Health + (def.heal or 0))
		notify(helper, "Healed " .. target.DisplayName)
		notify(target, helper.DisplayName .. " healed you")
	end)
end

-- Взрыв гранаты: урон зомби в радиусе (к краю — 40 % от центра), без вреда игрокам; огонь и звук — встроенный Explosion без силы
local function explode(grenade: BasePart, thrower: Player, g: { damage: number, radius: number })
	local pos = grenade.Position
	local fx = Instance.new("Explosion")
	fx.Position = pos
	fx.BlastPressure = 0
	fx.BlastRadius = g.radius
	fx.DestroyJointRadiusPercent = 0 -- игроков и постройки не рвёт
	fx.ExplosionType = Enum.ExplosionType.NoCraters
	fx.Parent = workspace
	local sound = grenade:FindFirstChildOfClass("Sound")
	if sound then
		sound.Volume = 1.2
		sound.RollOffMaxDistance = 300
		sound:Play()
	end
	grenade.Transparency = 1
	for _, z in ZombieService.queryNear(pos, g.radius) do
		local dist = (z.root.Position - pos).Magnitude
		local k = 1 - 0.6 * math.clamp(dist / g.radius, 0, 1)
		local dir = Vector3.new(z.root.Position.X - pos.X, 0, z.root.Position.Z - pos.Z)
		ZombieService.damage(z.model, g.damage * k, thrower, {
			dir = if dir.Magnitude > 0.01 then dir.Unit else nil,
			push = 40 * k,
			stagger = 0.6,
			heavy = true,
			power = 1.5,
		})
	end
	task.delay(1.5, function()
		grenade:Destroy()
	end)
end

local lastThrow: { [Player]: number } = {}
local function onThrow(player: Player, direction: unknown)
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.5 or direction.Magnitude > 1.5 or direction ~= direction then
		return
	end
	if not RateLimit.allow(player, "ThrowGrenade", 0.2) or not PlayerService.isUp(player) then
		return
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not head or not tool or tool:GetAttribute("ItemId") ~= "Grenade" then
		return
	end
	local def = Config.Items.Grenade
	local g = def.grenade
	if not g then
		return
	end
	local now = os.clock()
	if now - (lastThrow[player] or 0) < g.cooldown then
		return
	end
	lastThrow[player] = now
	local count = ((tool:GetAttribute("Count") :: number?) or 1) - 1
	-- граната в полёт: копия модели из рук, физика на сервере
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local grenade: BasePart
	if handle then
		grenade = handle:Clone()
	else
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(0.8, 0.8, 0.8)
		p.Color = def.color
		grenade = p
	end
	grenade.Name = "ThrownGrenade"
	for _, d in grenade:GetChildren() do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		end
	end
	local dir = direction.Unit
	grenade.Anchored = false
	grenade.CanCollide = true
	grenade.CanQuery = false
	grenade.Massless = false
	grenade.Transparency = 0
	grenade.CFrame = CFrame.new(head.Position + dir * 2)
	grenade.CustomPhysicalProperties = PhysicalProperties.new(2, 0.6, 0.3)
	grenade.Parent = workspace
	grenade:SetNetworkOwner(nil)
	grenade.AssemblyLinearVelocity = (dir + Vector3.new(0, g.lift, 0)) * g.speed
	grenade.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))
	task.delay(g.fuse, function()
		if grenade.Parent then
			explode(grenade, player, g)
		end
	end)
	if count <= 0 then
		tool:Destroy()
	else
		tool:SetAttribute("Count", count)
		tool.Name = string.format("%s ×%d", def.name, count)
	end
end

function ItemService.init()
	Remotes.get("ThrowGrenade").OnServerEvent:Connect(onThrow)
	Players.PlayerRemoving:Connect(function(p)
		lastThrow[p] = nil
	end)
	local function watch(p: Player)
		p.CharacterAdded:Connect(function(char: Model)
			setupHealPrompt(p, char)
		end)
		if p.Character then
			task.spawn(setupHealPrompt, p, p.Character)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return ItemService
