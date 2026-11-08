--!strict
-- Донатный магазин на военной базе (баланс v4): как магазины лобби v2 — стена, вывеска, два прилавка, два ящика с припасами и двое военных у прилавков.
-- Ассеты те же, что у лобби (ServerStorage.Assets.Lobby: Wall, ShopSign, Stall; Props.MilitaryCrates; NPC.Lobby: LobbySoldier_*), все без скриптов.
-- Прилавок открывает робуксовый магазин (StoreController).
-- Место — Config.BaseShop (на базе между «Military Carport Garage Building House» и APC). Магазин стоит в месте статично (Workspace.BaseDonateShop,
-- построен один раз через BaseShopService.build() в Edit); при запуске сервис только вешает подсказки на прилавки (а если модели в месте нет — строит её).
-- Магазин открыт днём и ночью: это донат, не оружие.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local BaseShopService = {}

local built: Model? = nil

local function template(path: string): Model?
	local cur: Instance? = ServerStorage:FindFirstChild("Assets")
	for seg in string.gmatch(path, "[^.]+") do
		cur = if cur then cur:FindFirstChild(seg) else nil
	end
	if cur and cur:IsA("Model") then
		return cur
	end
	warn("[BaseShopService] asset not found: " .. path)
	return nil
end

-- низ-центр модели (мировой AABB по углам частей)
local function bottomCenter(model: Model): CFrame
	local mnX, mnY, mnZ = math.huge, math.huge, math.huge
	local mxX, mxZ = -math.huge, -math.huge
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local h = p.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local w = (p.CFrame * CFrame.new(h.X * sx, h.Y * sy, h.Z * sz)).Position
						mnX, mnY, mnZ = math.min(mnX, w.X), math.min(mnY, w.Y), math.min(mnZ, w.Z)
						mxX, mxZ = math.max(mxX, w.X), math.max(mxZ, w.Z)
					end
				end
			end
		end
	end
	if mnX == math.huge then
		return model:GetPivot()
	end
	return CFrame.new((mnX + mxX) / 2, mnY, (mnZ + mxZ) / 2)
end

local function groundY(x: number, z: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { built :: Instance }
	local hit = workspace:Raycast(Vector3.new(x, 80, z), Vector3.new(0, -160, 0), params)
	return if hit then hit.Position.Y else 0
end

-- Расстановка: низ-центр модели в (x, земля, z), поворот yawDeg вокруг вертикали (как put в Locations/Lobby)
local function put(parent: Instance, path: string, x: number, z: number, yawDeg: number, opts: { scale: number?, name: string?, lift: number? }?): Model?
	local src = template(path)
	if not src then
		return nil
	end
	local m = src:Clone()
	for _, d in m:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	m.Name = (opts and opts.name) or src.Name
	m.Parent = parent
	m.WorldPivot = bottomCenter(m) * m:GetPivot().Rotation
	if opts and opts.scale and opts.scale ~= 1 then
		m:ScaleTo(opts.scale)
	end
	m:PivotTo(CFrame.new(x, groundY(x, z) + ((opts and opts.lift) or 0.2), z) * CFrame.Angles(0, math.rad(yawDeg), 0))
	return m
end

local function openDonate(player: Player)
	if not PlayerService.isUp(player) then
		return
	end
	Remotes.get("StoreOpen"):FireClient(player)
end

-- Построить магазин по Config.BaseShop (заменяет старый Workspace.BaseDonateShop); без подсказок — их вешает init
function BaseShopService.build(): Model
	local old = workspace:FindFirstChild("BaseDonateShop")
	if old then
		old:Destroy()
	end
	local cfg = Config.BaseShop
	local root = Instance.new("Model")
	root.Name = "BaseDonateShop"
	root.Parent = workspace
	built = root
	local cx, cz, rot = cfg.Center.X, cfg.Center.Z, cfg.Rot
	local r = math.rad(rot)
	-- локальная схема как в лобби: стена lx = −10, торговцы lx = −5,6, прилавки lx = 0 (lz = ±7), покупатели со стороны +lx
	local function w(lx: number, lz: number): (number, number)
		return cx + lx * math.cos(r) + lz * math.sin(r), cz - lx * math.sin(r) + lz * math.cos(r)
	end
	local wx, wz = w(-10, 0)
	put(root, "Lobby.Wall", wx, wz, rot, { name = "ShopWall", scale = 0.7 })
	local sx, sz = w(-10 + 2.2, 0)
	put(root, "Lobby.ShopSign", sx, sz, rot - 90, { name = "ShopSign", scale = 1.2, lift = 7 })
	-- покупатели стоят в сторону +lx: смотрим туда
	local fx, fz = w(1, 0)
	local facing = Vector3.new(fx - cx, 0, fz - cz).Unit
	for i, lz in { -7, 7 } do
		local stx, stz = w(0, lz)
		put(root, "Lobby.Stall", stx, stz, rot - 90, { name = "Stall" .. i })
		-- военный-торговец за прилавком, лицом к покупателям
		local npc = template("NPC.Lobby.LobbySoldier_" .. (if i == 1 then 1 else 2))
		if npc then
			local m = npc:Clone()
			for _, d in m:GetDescendants() do
				if d:IsA("LuaSourceContainer") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					d.Anchored = true
				end
			end
			m.Name = "Trader" .. i
			m.Parent = root
			local tx, tz = w(-5.6, lz)
			local bc = bottomCenter(m)
			local offset = m:GetPivot().Position - bc.Position
			local ground = Vector3.new(tx, groundY(tx, tz) + 0.2, tz)
			m:PivotTo(CFrame.lookAt(ground + offset, ground + offset + facing))
		end
	end
	local c1x, c1z = w(-6, -15.5)
	local c2x, c2z = w(-6, 15.5)
	put(root, "Props.MilitaryCrates", c1x, c1z, 20 + rot, { scale = 0.8 })
	put(root, "Props.MilitaryCrates", c2x, c2z, -15 + rot, { scale = 0.8 })
	return root
end

-- Запуск: магазин уже стоит в месте — вешаем подсказки на прилавки (Stall1, Stall2); нет модели — строим
function BaseShopService.init()
	local shop = workspace:FindFirstChild("BaseDonateShop")
	if not shop or not shop:IsA("Model") then
		shop = BaseShopService.build()
	end
	built = shop :: Model
	for _, stall in (shop :: Model):GetChildren() do
		if stall:IsA("Model") and string.sub(stall.Name, 1, 5) == "Stall" then
			local biggest: BasePart? = nil
			for _, d in stall:GetDescendants() do
				if d:IsA("BasePart") and (not biggest or d.Size.Magnitude > biggest.Size.Magnitude) then
					biggest = d
				end
			end
			if biggest and not biggest:FindFirstChildOfClass("ProximityPrompt") then
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Donate shop"
				prompt.ObjectText = "Trader"
				prompt.HoldDuration = 0
				prompt.MaxActivationDistance = 12
				prompt.RequiresLineOfSight = false
				prompt.Parent = biggest
				prompt.Triggered:Connect(openDonate)
			end
		end
	end
end

return BaseShopService
