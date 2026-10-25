--!strict
-- Военные НПС на базе (модели лежат в Workspace.Soldiers, расставлены в Studio) живут круглосуточно и заняты делом:
--   patrol — ходят по своему участку базы и иногда останавливаются (иногда с жестом),
--   guard  — стоят на посту, оглядываются по сторонам,
--   chat   — стоят парами лицом друг к другу и жестикулируют (разговаривают).
-- Мутанты целятся только в игроков (ZombieService ищет цель среди Players), солдат не трогают.

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RateLimit = require(Shared:WaitForChild("RateLimit"))

local SoldierService = {}

-- Скорость ходьбы, под которую сделаны официальные анимации ходьбы (R6 и R15): при меньшей WalkSpeed анимация замедляется
-- пропорционально (так же делает стандартный скрипт Animate), иначе ноги «бегут» на месте, а солдат плывёт по земле.
local WALK_ANIM_SPEED = 14.5

local ANIMS = {
	R15 = {
		idle = "rbxassetid://507766666",
		idleAlt = "rbxassetid://507766388",
		walk = "rbxassetid://507777826",
		emotes = { "rbxassetid://507770239", "rbxassetid://507770453", "rbxassetid://507770677", "rbxassetid://507770818" }, -- wave, point, cheer, laugh
	},
	R6 = {
		idle = "rbxassetid://180435571",
		idleAlt = "rbxassetid://180435792",
		walk = "rbxassetid://180426354",
		emotes = { "rbxassetid://128777973", "rbxassetid://128853357", "rbxassetid://129423030", "rbxassetid://129423131" }, -- wave, point, cheer, laugh
	},
}

type Soldier = {
	model: Model,
	hum: Humanoid,
	root: BasePart,
	mode: string,
	home: Vector3,
	homeYaw: number,
	idle: AnimationTrack?,
	idleAlt: AnimationTrack?, -- второй вариант стойки: солдаты на посту не стоят одинаково
	walk: AnimationTrack?,
	emotes: { AnimationTrack },
	nextAt: number,
	state: string, -- "pause" | "walk"
	waypoints: { PathWaypoint },
	wpIndex: number,
	lastPos: Vector3,
	stuckSince: number,
	targetYaw: number,
	partner: Soldier?,
	useAlt: boolean, -- в стойке играет второй вариант
	pathBusy: boolean, -- путь считается в отдельном потоке: солдат стоит в паузе
	talkUntil: number, -- до этого времени солдат разговаривает: стоит и смотрит на собеседника
	talkTarget: BasePart?,
	lastLine: number, -- номер последней сказанной реплики (подряд не повторяется)
}

local soldiers: { Soldier } = {}
local rng = Random.new()
local PATROL_RADIUS = 26

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

local function groundPoint(pos: Vector3): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excl: { Instance } = {}
	local folder = workspace:FindFirstChild("Soldiers")
	if folder then
		table.insert(excl, folder)
	end
	params.FilterDescendantsInstances = excl
	local hit = workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), params)
	return if hit then hit.Position else nil
end

local function playEmote(s: Soldier)
	if #s.emotes == 0 then
		return
	end
	local track = s.emotes[rng:NextInteger(1, #s.emotes)]
	if track.Length > 0 or true then
		track:Play(0.2)
	end
end

local function faceYaw(s: Soldier, yaw: number, dt: number, rate: number?)
	local _, current, _ = s.root.CFrame:ToOrientation()
	local diff = (yaw - current + math.pi) % (2 * math.pi) - math.pi
	local maxStep = dt * (rate or 1.6)
	local step = math.clamp(diff, -maxStep, maxStep)
	s.root.CFrame = CFrame.new(s.root.Position) * CFrame.Angles(0, current + step, 0)
end

-- Поиск пути (до 8 ComputeAsync) уходит в task.spawn, чтобы не держать Heartbeat; пока он идёт, солдат в паузе.
local function computePatrol(s: Soldier)
	for _ = 1, 8 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(8, PATROL_RADIUS)
		local p = groundPoint(s.home + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
		if p and math.abs(p.Y - s.home.Y) < 4 then
			local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = false })
			local ok = pcall(function()
				path:ComputeAsync(s.root.Position, p)
			end)
			if not s.model.Parent then
				return
			end
			if ok and path.Status == Enum.PathStatus.Success then
				s.waypoints = path:GetWaypoints()
				s.wpIndex = 2
				s.state = "walk"
				s.stuckSince = os.clock()
				s.lastPos = s.root.Position
				return
			end
		end
	end
	s.state = "pause"
	s.nextAt = os.clock() + 2
end

local function newPatrolTarget(s: Soldier)
	if s.pathBusy then
		return
	end
	s.pathBusy = true
	task.spawn(function()
		computePatrol(s)
		s.pathBusy = false
	end)
end

local function setMoving(s: Soldier, moving: boolean)
	local walk = s.walk
	if moving then
		if walk and not walk.IsPlaying then
			walk:Play(0.3)
		end
		if walk then
			walk:AdjustSpeed(math.max(0.3, s.hum.WalkSpeed / WALK_ANIM_SPEED))
		end
		for _, t in { s.idle, s.idleAlt } do
			if t and t.IsPlaying then
				t:Stop(0.3)
			end
		end
	else
		local stance = if s.useAlt and s.idleAlt then s.idleAlt else s.idle
		if stance and not stance.IsPlaying then
			stance:Play(0.3)
		end
		if walk and walk.IsPlaying then
			walk:Stop(0.3)
		end
	end
end

local function step(s: Soldier, now: number, dt: number)
	if now < s.talkUntil then
		-- разговор: стоит и поворачивается к собеседнику
		setMoving(s, false)
		local t = s.talkTarget
		if t and t.Parent then
			local to = t.Position - s.root.Position
			faceYaw(s, math.atan2(-to.X, -to.Z), dt, 6)
		end
		return
	elseif s.talkUntil > 0 then
		s.talkUntil = 0
		s.talkTarget = nil
		s.state = "pause"
		s.nextAt = now + 1
	end
	if s.mode == "patrol" then
		if s.state == "pause" then
			setMoving(s, false)
			if now >= s.nextAt then
				newPatrolTarget(s)
			end
		else
			local wp = s.waypoints[s.wpIndex]
			if not wp then
				s.state = "pause"
				s.nextAt = now + rng:NextNumber(3, 8)
				if rng:NextNumber() < 0.35 then
					playEmote(s)
				end
				return
			end
			setMoving(s, true)
			s.hum:MoveTo(wp.Position)
			if (Vector3.new(wp.Position.X, 0, wp.Position.Z) - Vector3.new(s.root.Position.X, 0, s.root.Position.Z)).Magnitude < 3 then
				s.wpIndex += 1
			end
			-- застрял: пауза и новая цель
			if (s.root.Position - s.lastPos).Magnitude > 1.5 then
				s.lastPos = s.root.Position
				s.stuckSince = now
			elseif now - s.stuckSince > 4 then
				s.state = "pause"
				s.nextAt = now + 1
			end
		end
	elseif s.mode == "guard" then
		setMoving(s, false)
		if now >= s.nextAt then
			s.targetYaw = s.homeYaw + rng:NextNumber(-1.2, 1.2)
			s.nextAt = now + rng:NextNumber(3, 7)
			if rng:NextNumber() < 0.15 then
				playEmote(s)
			end
		end
		faceYaw(s, s.targetYaw, dt)
	elseif s.mode == "chat" then
		setMoving(s, false)
		local p = s.partner
		if p then
			local to = p.root.Position - s.root.Position
			faceYaw(s, math.atan2(-to.X, -to.Z), dt)
		end
		if now >= s.nextAt then
			s.nextAt = now + rng:NextNumber(4, 9)
			if rng:NextNumber() < 0.6 then
				playEmote(s)
			end
		end
	end
end

-- Снаряжение (оружие, жилеты, шлемы) в моделях лежит отдельными деталями без суставов: пока они якорные, всё на месте,
-- а без якоря падает на землю. Перед снятием якорей приваривает каждую «лишнюю» деталь к ближайшей детали тела.
local function attachLooseParts(model: Model)
	local connected: { [BasePart]: boolean } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("ManualWeld") then
			local a = (d :: any).Part0
			local b = (d :: any).Part1
			if typeof(a) == "Instance" and a:IsA("BasePart") then
				connected[a] = true
			end
			if typeof(b) == "Instance" and b:IsA("BasePart") then
				connected[b] = true
			end
		end
	end
	local body: { BasePart } = {}
	for part in connected do
		table.insert(body, part)
	end
	if #body == 0 then
		return
	end
	local attached = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not connected[d] then
			local best: BasePart? = nil
			local bd = math.huge
			for _, b in body do
				local dist = (b.Position - d.Position).Magnitude
				if dist < bd then
					best, bd = b, dist
				end
			end
			if best then
				local w = Instance.new("WeldConstraint")
				w.Part0 = best
				w.Part1 = d
				w.Parent = d
				d.Massless = true
				d.CanCollide = false
				attached += 1
			end
		end
	end
	if attached > 0 then
		model:SetAttribute("AttachedGear", attached)
	end
end

-- «Белые» солдаты (R6 в защитных костюмах) пришли с устаревшими суставами Snap между торсом и ногами/головой: они жёстко держат
-- конечности поверх Motor6D, и анимация ходьбы не двигает ноги. Убираем такой сустав, если ту же пару деталей уже соединяет Motor6D.
local function removeLegacyJoints(model: Model)
	local motors: { [BasePart]: { [BasePart]: boolean } } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 then
			motors[d.Part0] = motors[d.Part0] or {}
			motors[d.Part0][d.Part1] = true
			motors[d.Part1] = motors[d.Part1] or {}
			motors[d.Part1][d.Part0] = true
		end
	end
	local removed = 0
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") and not d:IsA("Motor6D") then
			local a, b = d.Part0, d.Part1
			if a and b and motors[a] and motors[a][b] then
				d:Destroy()
				removed += 1
			end
		end
	end
	if removed > 0 then
		model:SetAttribute("LegacyJointsRemoved", removed)
	end
end

-- Пузырь с репликой над головой солдата (виден всем поблизости)
local function showBubble(s: Soldier, text: string)
	local head = s.model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local old = head:FindFirstChild("TalkBubble")
	if old then
		old:Destroy()
	end
	local cfg = Config.SoldierTalk
	local gui = Instance.new("BillboardGui")
	gui.Name = "TalkBubble"
	gui.Size = UDim2.fromOffset(260, 64)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 70
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
	task.delay(cfg.bubbleTime, function()
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

-- E на солдате: он останавливается, поворачивается к игроку и говорит случайную реплику (подряд не повторяется)
local function talk(s: Soldier, player: Player)
	local cfg = Config.SoldierTalk
	local now = os.clock()
	local char = player.Character
	local pRoot = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hp = char and char:FindFirstChildOfClass("Humanoid")
	if not pRoot or not hp or hp.Health <= 0 or player:GetAttribute("Downed") == true then
		return
	end
	if (pRoot.Position - s.root.Position).Magnitude > cfg.distance + 4 then
		return
	end
	if now < s.talkUntil + cfg.soldierCooldown then
		return
	end
	if not RateLimit.allow(player, "SoldierTalk", cfg.playerInterval) then
		return
	end
	local count = #cfg.lines
	local pick = math.random(1, count)
	if count > 1 and pick == s.lastLine then
		pick = pick % count + 1
	end
	s.lastLine = pick
	s.talkUntil = now + cfg.bubbleTime
	s.talkTarget = pRoot
	s.hum:MoveTo(s.root.Position)
	s.waypoints = {}
	s.state = "pause"
	showBubble(s, cfg.lines[pick])
	if rng:NextNumber() < 0.5 then
		playEmote(s)
	end
end

local function addTalkPrompt(s: Soldier)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Поговорить"
	prompt.ObjectText = "Солдат"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.SoldierTalk.distance
	prompt.RequiresLineOfSight = false
	prompt.Parent = s.root
	prompt.Triggered:Connect(function(player: Player)
		talk(s, player)
	end)
end

function SoldierService.init()
	local folder = workspace:FindFirstChild("Soldiers")
	if not folder then
		return
	end
	local list: { Soldier } = {}
	for i, model in folder:GetChildren() do
		local hum = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if model:IsA("Model") and hum and root then
			-- солдаты не умирают; больше не якорные: ходят и стоят на ногах физически
			hum.BreakJointsOnDeath = false
			hum.RequiresNeck = false
			hum.MaxHealth = math.huge
			hum.Health = math.huge
			hum.WalkSpeed = 7
			removeLegacyJoints(model)
			attachLooseParts(model) -- пока модель якорная и всё на своих местах
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = false
				end
			end
			root:SetNetworkOwner(nil)
			local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
			local set = if hum.RigType == Enum.HumanoidRigType.R15 then ANIMS.R15 else ANIMS.R6
			local emotes: { AnimationTrack } = {}
			for _, id in set.emotes do
				local t = loadTrack(animator, id, false)
				if t then
					table.insert(emotes, t)
				end
			end
			local _, yaw, _ = root.CFrame:ToOrientation()
			local s: Soldier = {
				model = model, hum = hum, root = root,
				mode = if i % 5 <= 1 then "patrol" elseif i % 5 <= 3 then "guard" else "chat",
				home = root.Position, homeYaw = yaw,
				idle = loadTrack(animator, set.idle, true), walk = loadTrack(animator, set.walk, true), emotes = emotes,
				nextAt = os.clock() + rng:NextNumber(0, 4), state = "pause", waypoints = {}, wpIndex = 1,
				lastPos = root.Position, stuckSince = os.clock(), targetYaw = yaw, partner = nil, pathBusy = false,
				talkUntil = 0, talkTarget = nil, lastLine = 0,
				idleAlt = loadTrack(animator, set.idleAlt, true), useAlt = rng:NextNumber() < 0.5,
			}
			local startIdle = if s.useAlt and s.idleAlt then s.idleAlt else s.idle
			if startIdle then
				startIdle:Play()
				startIdle.TimePosition = rng:NextNumber(0, 1)
			end
			addTalkPrompt(s)
			table.insert(list, s)
		end
	end
	-- пары для разговора: каждый «болтун» берёт ближайшего другого болтуна
	for _, a in list do
		if a.mode == "chat" then
			local best: Soldier? = nil
			local bd = math.huge
			for _, b in list do
				if b ~= a and b.mode == "chat" then
					local d = (a.root.Position - b.root.Position).Magnitude
					if d < bd then
						best, bd = b, d
					end
				end
			end
			a.partner = best
			if bd > 25 then
				a.mode = "guard" -- напарник далеко: становится часовым
			end
		end
	end
	soldiers = list

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.1 then
			return
		end
		-- обнуляем до прохода: шаг не должен накладываться на следующий кадр
		local elapsed = acc
		acc = 0
		local now = os.clock()
		for _, s in soldiers do
			if s.model.Parent then
				step(s, now, elapsed)
			end
		end
	end)
	print("[SoldierService] солдат: " .. #soldiers)
end

SoldierService.attachLooseParts = attachLooseParts

return SoldierService
