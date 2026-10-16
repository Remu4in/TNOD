--!strict
-- Визуальный отклик: трассеры выстрелов, вспышки попаданий, цифры урона, полоски HP зомби.
-- Только косметика на клиенте, лимит одновременных эффектов.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local WeaponSfx = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponSfx"))

local EffectsController = {}

local player = Players.LocalPlayer
local MAX_NUMBERS = 25
local numbersAlive = 0

local fxFolder = Instance.new("Folder")
fxFolder.Name = "ClientFx"
fxFolder.Parent = workspace

local function tracer(from: Vector3, to: Vector3, mine: boolean)
	local len = (to - from).Magnitude
	if len < 0.5 then
		return
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = if mine then Color3.fromRGB(255, 230, 150) else Color3.fromRGB(200, 200, 200)
	p.Size = Vector3.new(0.08, 0.08, len)
	p.CFrame = CFrame.lookAt((from + to) / 2, to)
	p.Parent = fxFolder
	TweenService:Create(p, TweenInfo.new(0.08), { Transparency = 1 }):Play()
	Debris:AddItem(p, 0.1)
end

local function damageNumber(pos: Vector3, amount: number, killed: boolean, headshot: boolean)
	if numbersAlive >= MAX_NUMBERS then
		return
	end
	numbersAlive += 1
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.1
	anchor.Position = pos
	anchor.Parent = fxFolder
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(80, 40)
	bb.AlwaysOnTop = true
	bb.Parent = anchor
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextStrokeTransparency = 0.3
	t.Text = tostring(amount)
	t.TextColor3 = if killed then Color3.fromRGB(255, 80, 60) elseif headshot then Color3.fromRGB(255, 220, 60) else Color3.new(1, 1, 1)
	t.Parent = bb
	TweenService:Create(anchor, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = pos + Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(t, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.65, function()
		anchor:Destroy()
		numbersAlive -= 1
	end)
end

local function hitFlash(pos: Vector3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 120, 80)
	p.Size = Vector3.one * 0.6
	p.Position = pos
	p.Parent = fxFolder
	TweenService:Create(p, TweenInfo.new(0.12), { Size = Vector3.one * 1.4, Transparency = 1 }):Play()
	Debris:AddItem(p, 0.15)
end

local function headPosition(who: Player): Vector3?
	local char = who.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	return if head then head.Position else nil
end

function EffectsController.start()
	WeaponSfx.preload()
	Remotes.get("ShotFx").OnClientEvent:Connect(function(shooter: Player, origin: Vector3, hits: { Vector3 }, weaponId: string)
		for _, h in hits do
			tracer(origin, h, shooter == player)
		end
		-- свой выстрел уже прозвучал сразу при нажатии (WeaponController), чужие — объёмно из точки выстрела
		if shooter ~= player then
			WeaponSfx.fire(weaponId, origin)
		end
	end)
	Remotes.get("ReloadFx").OnClientEvent:Connect(function(who: Player, weaponId: string)
		if who == player then
			WeaponSfx.reload(weaponId, nil)
		else
			WeaponSfx.reload(weaponId, headPosition(who))
		end
	end)
	Remotes.get("HitFeedback").OnClientEvent:Connect(function(pos: Vector3?, dmg: number, killed: boolean, headshot: boolean)
		if pos then
			hitFlash(pos)
			damageNumber(pos, dmg, killed, headshot)
			WeaponSfx.hit(headshot, killed)
		end
	end)
end

return EffectsController
