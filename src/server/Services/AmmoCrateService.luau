--!strict
-- Ящики с патронами по маркерам AmmoCrate_<n> (в Workspace.Markers и Workspace.Metro.Markers): бесплатно пополняют патроны всего оружия
-- игрока, один раз на игрока за ночь (в начале каждой фазы счётчик сбрасывается). Пример награды за обход укрытий (разбитый поезд в метро).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local AmmoCrateService = {}

local used: { [Player]: boolean } = {}

local function build(marker: BasePart)
	local crate = Instance.new("Part")
	crate.Name = "AmmoCrate"
	crate.Anchored = true
	crate.Size = Vector3.new(3.2, 2.2, 2.2)
	crate.Material = Enum.Material.Wood
	crate.Color = Color3.fromRGB(88, 96, 60)
	local ground = Vector3.new(marker.Position.X, marker.Position.Y - marker.Size.Y / 2, marker.Position.Z)
	crate.CFrame = CFrame.lookAt(ground + Vector3.new(0, crate.Size.Y / 2, 0), ground + Vector3.new(0, crate.Size.Y / 2, 0) + Vector3.new(marker.CFrame.LookVector.X, 0, marker.CFrame.LookVector.Z))
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 24)
	gui.StudsOffset = Vector3.new(0, 2.4, 0)
	gui.MaxDistance = 60
	gui.Parent = crate
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.4
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.fromRGB(255, 220, 90)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "ПАТРОНЫ"
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Взять патроны"
	prompt.ObjectText = "Ящик с патронами"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = crate
	prompt.Triggered:Connect(function(player: Player)
		if not PlayerService.isUp(player) then
			return
		end
		if used[player] then
			Remotes.get("Notify"):FireClient(player, "Вы уже брали патроны из ящика в эту фазу", 2)
			return
		end
		if WeaponService.refillAll(player) then
			used[player] = true
			Remotes.get("Notify"):FireClient(player, "Патроны пополнены", 2)
		else
			Remotes.get("Notify"):FireClient(player, "Патроны полные", 2)
		end
	end)
	crate.Parent = workspace
	marker.Transparency = 1
end

-- Припасы тоннеля в горе (MissionService, после выхода из метро): ящик без маркера; каждый игрок один раз за всё время пополняет патроны ОДНОГО оружия —
-- того, что держит в руках (по выбору игрока), общий счётчик на все ящики сбрасывается resetSupply
local supplyUsed: { [Player]: boolean } = {}

function AmmoCrateService.resetSupply()
	table.clear(supplyUsed)
end

function AmmoCrateService.supply(parent: Instance, position: Vector3, yaw: number): Part
	local crate = Instance.new("Part")
	crate.Name = "SupplyCrate"
	crate.Anchored = true
	crate.Size = Vector3.new(3.6, 2.4, 2.6)
	crate.Material = Enum.Material.Wood
	crate.Color = Color3.fromRGB(78, 92, 56)
	crate.CFrame = CFrame.new(position + Vector3.new(0, crate.Size.Y / 2, 0)) * CFrame.Angles(0, yaw, 0)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 24)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 90
	gui.Parent = crate
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.4
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.fromRGB(255, 220, 90)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "ПРИПАСЫ"
	label.Parent = gui
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Пополнить оружие в руках"
	prompt.ObjectText = "Припасы (одно оружие на игрока)"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = crate
	prompt.Triggered:Connect(function(player: Player)
		if not PlayerService.isUp(player) then
			return
		end
		if supplyUsed[player] then
			Remotes.get("Notify"):FireClient(player, "Вы уже пополнили своё оружие из припасов", 3)
			return
		end
		local ok, reason = WeaponService.canRefillHeld(player)
		if not ok then
			Remotes.get("Notify"):FireClient(player, reason or "Возьмите в руки оружие, которое хотите пополнить", 3)
			return
		end
		if WeaponService.refillHeld(player) then
			supplyUsed[player] = true
			Remotes.get("Notify"):FireClient(player, "Оружие в руках пополнено. Больше припасов вам не положено", 4)
		end
	end)
	crate.Parent = parent
	return crate
end

function AmmoCrateService.init()
	local folders: { Instance } = {}
	local markers = workspace:FindFirstChild("Markers")
	if markers then
		table.insert(folders, markers)
	end
	local metro = workspace:FindFirstChild("Metro")
	if metro and metro:FindFirstChild("Markers") then
		table.insert(folders, metro.Markers)
	end
	for _, f in folders do
		for _, m in f:GetChildren() do
			if m:IsA("BasePart") and string.sub(m.Name, 1, 10) == "AmmoCrate_" then
				build(m)
			end
		end
	end
	ReplicatedStorage:GetAttributeChangedSignal("Phase"):Connect(function()
		table.clear(used)
	end)
	Players.PlayerRemoving:Connect(function(p)
		used[p] = nil
		supplyUsed[p] = nil
	end)
end

return AmmoCrateService
