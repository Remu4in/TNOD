--!strict
-- Военные НПС лобби: часовые стоят и оглядываются, патрульные ходят по маршрутам туда-обратно, пары разговаривают,
-- торговцы стоят за прилавками (подсказка «Browse» открывает окно магазина). Один цикл ИИ на всех, скриптов в моделях нет.
-- Модели — `ServerStorage.Assets.NPC.Lobby` (копии солдат с карты, без скриптов); точки и маршруты даёт Locations/Lobby.
-- Мутанты в лобби не появляются, солдатам ничего не грозит: они не умирают и не имеют физических забот (пол ровный, маршруты свободны).

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))
local LobbyBuilder = require(script.Parent.Parent:WaitForChild("Locations"):WaitForChild("Lobby"))
local SoldierService = require(script.Parent:WaitForChild("SoldierService"))

local LobbyNpcService = {}

-- те же стандартные анимации, что у SoldierService
local ANIMS = {
	R15 = { idle = "rbxassetid://507766666", idleAlt = "rbxassetid://507766388", walk = "rbxassetid://507777826", emotes = { "rbxassetid://507770239", "rbxassetid://507770453", "rbxassetid://507770677" } },
	R6 = { idle = "rbxassetid://180435571", idleAlt = "rbxassetid://180435792", walk = "rbxassetid://180426354", emotes = { "rbxassetid://128777973", "rbxassetid://128853357", "rbxassetid://129423030" } },
}
local WALK_ANIM_SPEED = 14.5

type Npc = {
	model: Model,
	hum: Humanoid,
	root: BasePart,
	spot: LobbyBuilder.NpcSpot,
	idle: AnimationTrack?,
	idleAlt: AnimationTrack?,
	walk: AnimationTrack?,
	emotes: { AnimationTrack },
	useAlt: boolean,
	nextAt: number,
	state: string, -- "pause" | "walk"
	routeIndex: number,
	routeDir: number,
	targetYaw: number,
	lastPos: Vector3,
	stuckSince: number,
	talkUntil: number,
	talkTarget: BasePart?,
	lastLine: number,
}

local npcs: { Npc } = {}
local rng = Random.new()
local running = false

local function loadTrack(animator: Animator, id: string, looped: boolean): AnimationTrack?
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = looped
		return track
	end
	return nil
end

local function faceYaw(n: Npc, yaw: number, dt: number, rate: number?)
	local _, current, _ = n.root.CFrame:ToOrientation()
	local diff = (yaw - current + math.pi) % (2 * math.pi) - math.pi
	local maxStep = dt * (rate or 1.6)
	local step = math.clamp(diff, -maxStep, maxStep)
	n.root.CFrame = CFrame.new(n.root.Position) * CFrame.Angles(0, current + step, 0)
end

local function setMoving(n: Npc, moving: boolean)
	local walk = n.walk
	if moving then
		if walk and not walk.IsPlaying then
			walk:Play(0.3)
		end
		if walk then
			walk:AdjustSpeed(math.max(0.3, n.hum.WalkSpeed / WALK_ANIM_SPEED))
		end
		for _, t in { n.idle, n.idleAlt } do
			if t and t.IsPlaying then
				t:Stop(0.3)
			end
		end
	else
		local stance = if n.useAlt and n.idleAlt then n.idleAlt else n.idle
		if stance and not stance.IsPlaying then
			stance:Play(0.3)
		end
		if walk and walk.IsPlaying then
			walk:Stop(0.3)
		end
	end
end

local function playEmote(n: Npc)
	if #n.emotes > 0 then
		n.emotes[rng:NextInteger(1, #n.emotes)]:Play(0.2)
	end
end

local function flat(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function step(n: Npc, now: number, dt: number)
	if now < n.talkUntil then
		setMoving(n, false)
		local t = n.talkTarget
		if t and t.Parent then
			local to = t.Position - n.root.Position
			faceYaw(n, math.atan2(-to.X, -to.Z), dt, 6)
		end
		return
	end
	local kind = n.spot.kind
	if kind == "patrol" and n.spot.route then
		local route = n.spot.route
		if n.state == "pause" then
			setMoving(n, false)
			if now >= n.nextAt then
				-- следующая точка: туда-обратно по маршруту
				local nextIndex = n.routeIndex + n.routeDir
				if nextIndex > #route or nextIndex < 1 then
					n.routeDir = -n.routeDir
					nextIndex = n.routeIndex + n.routeDir
				end
				n.routeIndex = nextIndex
				n.state = "walk"
				n.lastPos = n.root.Position
				n.stuckSince = now
			end
		else
			local target = route[n.routeIndex]
			setMoving(n, true)
			n.hum:MoveTo(target)
			if flat(target, n.root.Position) < 3 then
				n.state = "pause"
				n.nextAt = now + rng:NextNumber(3, 7)
				if rng:NextNumber() < 0.35 then
					playEmote(n)
				end
			elseif (n.root.Position - n.lastPos).Magnitude > 1.5 then
				n.lastPos = n.root.Position
				n.stuckSince = now
			elseif now - n.stuckSince > 5 then
				n.state = "pause" -- застрял: пауза и та же точка ещё раз
				n.nextAt = now + 1
				n.routeIndex -= n.routeDir
			end
		end
	elseif kind == "chat" then
		setMoving(n, false)
		local partnerIndex = n.spot.partner
		local partner = if partnerIndex then npcs[partnerIndex] else nil
		if partner then
			local to = partner.root.Position - n.root.Position
			faceYaw(n, math.atan2(-to.X, -to.Z), dt)
		end
		if now >= n.nextAt then
			n.nextAt = now + rng:NextNumber(4, 9)
			if rng:NextNumber() < 0.6 then
				playEmote(n)
			end
		end
	else
		-- часовой / торговец: стоит на месте, чуть поворачивает голову к сторонам
		setMoving(n, false)
		if now >= n.nextAt then
			local spread = if kind == "trader" then 0.35 else 1.2
			n.targetYaw = math.rad(-n.spot.yaw) + rng:NextNumber(-spread, spread)
			n.nextAt = now + rng:NextNumber(3, 7)
			if rng:NextNumber() < 0.12 then
				playEmote(n)
			end
		end
		faceYaw(n, n.targetYaw, dt)
	end
end

local function showBubble(n: Npc, text: string)
	local head = n.model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local old = head:FindFirstChild("TalkBubble")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "TalkBubble"
	gui.Size = UDim2.fromOffset(260, 64)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 60
	gui.AlwaysOnTop = true
	gui.Adornee = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(20, 22, 18)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.fromRGB(240, 235, 215)
	label.Font = Enum.Font.GothamMedium
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = text
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
	pad.Parent = label
	gui.Parent = head
	task.delay(Config.SoldierTalk.bubbleTime, function()
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

local function talk(n: Npc, player: Player)
	local cfg = Config.SoldierTalk
	local now = os.clock()
	local char = player.Character
	local pRoot = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local ph = char and char:FindFirstChildOfClass("Humanoid")
	if not pRoot or not ph or ph.Health <= 0 then
		return
	end
	if (pRoot.Position - n.root.Position).Magnitude > cfg.distance + 4 then
		return
	end
	if now < n.talkUntil + cfg.soldierCooldown or not RateLimit.allow(player, "LobbyNpcTalk", cfg.playerInterval) then
		return
	end
	local count = #cfg.lines
	local pick = rng:NextInteger(1, count)
	if count > 1 and pick == n.lastLine then
		pick = pick % count + 1
	end
	n.lastLine = pick
	n.talkUntil = now + cfg.bubbleTime
	n.talkTarget = pRoot
	n.hum:MoveTo(n.root.Position)
	n.state = "pause"
	showBubble(n, cfg.lines[pick])
	if rng:NextNumber() < 0.5 then
		playEmote(n)
	end
end

-- Строит НПС по точкам; onTrader(игрок, номер прилавка) вызывается, когда игрок нажал «Browse» у торговца
function LobbyNpcService.start(spots: { LobbyBuilder.NpcSpot }, folder: Folder, onTrader: (Player, number) -> ())
	LobbyNpcService.stop()
	local assets = ServerStorage:FindFirstChild("Assets")
	local pool = assets and assets:FindFirstChild("NPC") and (assets :: Instance).NPC:FindFirstChild("Lobby")
	if not pool then
		warn("[LobbyNpcService] ServerStorage.Assets.NPC.Lobby is missing: no soldiers in the lobby")
		return
	end
	local templates: { Model } = {}
	for _, m in pool:GetChildren() do
		if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") and m:FindFirstChild("HumanoidRootPart") then
			table.insert(templates, m)
		end
	end
	if #templates == 0 then
		return
	end
	-- хорошая выборка: идём по списку с перетасовкой, чтобы соседи не совпадали
	local order = table.clone(templates)
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	for index, spot in spots do
		local src = order[(index - 1) % #order + 1]
		local model = src:Clone()
		model.Name = spot.label or "Soldier"
		for _, d in model:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
		model.Parent = folder
		hum.BreakJointsOnDeath = false
		hum.RequiresNeck = false
		hum.MaxHealth = math.huge
		hum.Health = math.huge
		hum.WalkSpeed = Config.Lobby.NpcWalkSpeed
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		SoldierService.removeLegacyJoints(model)
		SoldierService.attachLooseParts(model)
		local rigIsR15 = hum.RigType == Enum.HumanoidRigType.R15
		local lift = if rigIsR15 then hum.HipHeight + root.Size.Y / 2 else 3
		model:PivotTo(CFrame.new(spot.pos + Vector3.new(0, lift + 0.1, 0)) * CFrame.Angles(0, math.rad(-spot.yaw), 0))
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = false
			end
		end
		root:SetNetworkOwner(nil)
		local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
		local set = if rigIsR15 then ANIMS.R15 else ANIMS.R6
		local emotes: { AnimationTrack } = {}
		for _, id in set.emotes do
			local t = loadTrack(animator, id, false)
			if t then
				table.insert(emotes, t)
			end
		end
		local n: Npc = {
			model = model, hum = hum, root = root, spot = spot,
			idle = loadTrack(animator, set.idle, true), idleAlt = loadTrack(animator, set.idleAlt, true), walk = loadTrack(animator, set.walk, true),
			emotes = emotes, useAlt = rng:NextNumber() < 0.5,
			nextAt = os.clock() + rng:NextNumber(0, 4), state = "pause", routeIndex = 1, routeDir = 1,
			targetYaw = math.rad(-spot.yaw), lastPos = root.Position, stuckSince = os.clock(), talkUntil = 0, talkTarget = nil, lastLine = 0,
		}
		local stance = if n.useAlt and n.idleAlt then n.idleAlt else n.idle
		if stance then
			stance:Play()
			stance.TimePosition = rng:NextNumber(0, 1)
		end
		-- подсказка: торговец открывает магазин, остальные разговаривают
		local prompt = Instance.new("ProximityPrompt")
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = false
		if spot.kind == "trader" and spot.trader then
			local traderIndex = spot.trader
			prompt.ActionText = "Browse shop"
			prompt.ObjectText = "Trader"
			prompt.MaxActivationDistance = Config.Lobby.MenuDistance * 0.5
			prompt.Triggered:Connect(function(player: Player)
				onTrader(player, traderIndex)
			end)
		else
			prompt.ActionText = "Talk"
			prompt.ObjectText = "Soldier"
			prompt.MaxActivationDistance = Config.SoldierTalk.distance
			prompt.Triggered:Connect(function(player: Player)
				talk(n, player)
			end)
		end
		prompt.Parent = root
		table.insert(npcs, n)
	end
	running = true
	task.spawn(function()
		local last = os.clock()
		while running do
			task.wait(0.1)
			local now = os.clock()
			local dt = now - last
			last = now
			for _, n in npcs do
				if n.model.Parent then
					local ok, err = pcall(step, n, now, dt)
					if not ok then
						warn("[LobbyNpcService] step: " .. tostring(err))
					end
				end
			end
		end
	end)
	print("[LobbyNpcService] soldiers: " .. #npcs)
end

function LobbyNpcService.stop()
	running = false
	for _, n in npcs do
		if n.model.Parent then
			n.model:Destroy()
		end
	end
	table.clear(npcs)
end

return LobbyNpcService
