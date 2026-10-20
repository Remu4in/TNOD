--!strict
-- «Своя карта»: карту Руслана собирает вручную в Studio (Workspace), код её не строит и не меняет. Здесь только считываем точки:
-- Workspace.Markers (необязательно) — Part'ы-маркеры, если их нет, берутся запасные значения.
--   PlayerSpawn            — где появляются игроки
--   ZombieSpawn, ZombieSpawn2 … — где появляются зомби (любые Part'ы с именем, начинающимся на ZombieSpawn)
--   VehicleSpawn_<Шаблон>  — где ставить ездовую машину; <Шаблон> из Config.VehicleModels (Coupe, Prius, GunJeep …)
-- Здания, окна/баррикады и магазины пока не подключены (нужны маркеры — см. обсуждение в чате).

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Types = require(script.Parent.Parent:WaitForChild("Types"))
local BuildKit = require(script.Parent:WaitForChild("BuildKit"))

local Custom = {}

-- Земля рядом с точкой: бросаем луч вниз по кольцам вокруг центра и берём первое место, где под лучом дорога/трава/пол
-- (а не крыша здания). Нужна только для запасного места появления.
local function groundNear(center: Vector3): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local buildings = workspace:FindFirstChild("Buildings")
	local base = workspace:FindFirstChild("Base")
	local vehicles = workspace:GetChildren()
	local excl: { Instance } = {}
	for _, c in { buildings, base, workspace:FindFirstChild("Mountains") } do
		if c then
			table.insert(excl, c)
		end
	end
	for _, c in vehicles do
		if c.Name == "Vehicles" or c.Name == "CarModels" then
			table.insert(excl, c)
		end
	end
	params.FilterDescendantsInstances = excl
	for radius = 0, 80, 8 do
		for step = 0, 7 do
			local a = step / 8 * math.pi * 2
			local p = center + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
			local hit = workspace:Raycast(Vector3.new(p.X, 300, p.Z), Vector3.new(0, -400, 0), params)
			if hit and hit.Position.Y < 6 then
				-- свободно ли место над землёй (нет зданий/стен): проверяем коробку 4×8×4
				local blocked = workspace:GetPartBoundsInBox(CFrame.new(hit.Position + Vector3.new(0, 5, 0)), Vector3.new(4, 8, 4))
				local solid = false
				for _, part in blocked do
					if part.CanCollide and part ~= hit.Instance then
						solid = true
						break
					end
				end
				if not solid then
					return hit.Position
				end
			end
			if radius == 0 then
				break
			end
		end
	end
	return nil
end

local function marker(name: string): BasePart?
	local folder = workspace:FindFirstChild("Markers")
	local m = folder and folder:FindFirstChild(name)
	if m and m:IsA("BasePart") then
		m.Transparency = 1
		return m
	end
	return nil
end

function Custom.build(): Types.MapInfo
	local spawnMarker = marker("PlayerSpawn")
	local playerSpawn: Vector3
	if spawnMarker then
		playerSpawn = spawnMarker.Position + Vector3.new(0, 3, 0)
	else
		-- запасное место: возле первого Cafe (стартовое укрытие), иначе центр карты
		local cafe = workspace:FindFirstChild("Buildings") and workspace.Buildings:FindFirstChild("Cafe")
		local center = if cafe and cafe:IsA("Model") then cafe:GetPivot().Position else Vector3.new(0, 0, 0)
		local ground = groundNear(center)
		playerSpawn = (ground or Vector3.new(center.X, 0, center.Z)) + Vector3.new(0, 4, 0)
		warn("[Custom] нет Workspace.Markers.PlayerSpawn — игроки появятся у " .. tostring(playerSpawn))
	end

	local zombieSpawns: { Vector3 } = {}
	local carSpawns: { CFrame } = {}
	local carNames: { string } = {}
	local markers = workspace:FindFirstChild("Markers")
	if markers then
		for _, m in markers:GetChildren() do
			if m:IsA("BasePart") then
				m.Transparency = 1 -- в игре маркеры не видны
				if string.sub(m.Name, 1, 11) == "ZombieSpawn" then
					table.insert(zombieSpawns, m.Position + Vector3.new(0, 3, 0))
				elseif string.sub(m.Name, 1, 13) == "VehicleSpawn_" then
					table.insert(carSpawns, CFrame.new(m.Position.X, m.Position.Y - m.Size.Y / 2, m.Position.Z) * m.CFrame.Rotation)
					table.insert(carNames, string.sub(m.Name, 14))
				end
			end
		end
	end
	if #zombieSpawns == 0 then
		table.insert(zombieSpawns, playerSpawn + Vector3.new(0, 0, -50))
	end

	-- военные палатки: модели с именем Tent в Base/Decor/Buildings (+ маркеры TentShop*): магазин оружия днём
	local shops: { { name: string, center: Vector3, radius: number } } = {}
	local function addTent(inst: Instance)
		local center: Vector3, size: Vector3
		if inst:IsA("Model") then
			local cf, s = inst:GetBoundingBox()
			center, size = Vector3.new(cf.Position.X, cf.Position.Y - s.Y / 2, cf.Position.Z), s
		elseif inst:IsA("BasePart") then
			center, size = Vector3.new(inst.Position.X, inst.Position.Y - inst.Size.Y / 2, inst.Position.Z), inst.Size
		else
			return
		end
		table.insert(shops, { name = "Военная палатка", center = center, radius = math.max(size.X, size.Z) / 2 + 18 })
	end
	for _, folderName in { "Base", "Decor", "Buildings" } do
		local f = workspace:FindFirstChild(folderName)
		if f then
			for _, c in f:GetChildren() do
				if c.Name == "Tent" then
					addTent(c)
				end
			end
		end
	end
	if markers then
		for _, m in markers:GetChildren() do
			if string.sub(m.Name, 1, 8) == "TentShop" then
				addTent(m)
			end
		end
	end

	-- входы, вывески, продавцы и ночные заграждения по маркерам ---------------------------------------------------------
	--   Barricade_<n>    — вход в укрытие (кафе, палатка): ночью баррикада из досок, ломается снизу вверх
	--   Door_<id>_<n>    — вход в здание Config.Buildings: закрыт стальным щитом, пока не открыто за монеты и всегда закрыт ночью
	--   Sign_<id>        — вывеска здания (вложить монеты); Vendor_<id> — место НПС-продавца
	--   Barrier_<имя>    — заграждение (ворота базы): ночью решётка, днём проход открыт
	-- У маркеров вход: LookVector — наружу (куда выйдет игрок), Size.X — ширина проёма; позиция — на земле у проёма.
	BuildKit.reset()
	local windows: { Types.Window } = {}
	local buildings: { Types.BuildingInfo } = {}
	local vendors: { { id: string, position: Vector3, facing: Vector3 } } = {}
	local barriers: { BasePart } = {}
	local entrancesFolder = workspace:FindFirstChild("Entrances")
	if entrancesFolder then
		entrancesFolder:Destroy()
	end
	local entrances = Instance.new("Folder")
	entrances.Name = "Entrances"
	entrances.Parent = workspace

	local infoById: { [string]: Types.BuildingInfo } = {}
	for _, def in Config.Buildings do
		if def.cost > 0 then
			infoById[def.id] = { id = def.id, name = def.name, windows = {}, spots = {} }
		end
	end

	local function axisNormal(look: Vector3): Vector3
		if math.abs(look.Z) >= math.abs(look.X) then
			return Vector3.new(0, 0, if look.Z >= 0 then 1 else -1)
		end
		return Vector3.new(if look.X >= 0 then 1 else -1, 0, 0)
	end
	local nextWindow = 1
	local function addWindow(m: BasePart, point: string, weight: number): Types.Window
		local ground = Vector3.new(m.Position.X, m.Position.Y - m.Size.Y / 2, m.Position.Z)
		local w = BuildKit.entrance(entrances, nextWindow, point, weight, ground, axisNormal(m.CFrame.LookVector), m.Size.X, m.Size.Y)
		nextWindow += 1
		table.insert(windows, w)
		return w
	end

	if markers then
		for _, m in markers:GetChildren() do
			if m:IsA("BasePart") then
				local name = m.Name
				if string.sub(name, 1, 10) == "Barricade_" then
					addWindow(m, "shelter", 1)
				elseif string.sub(name, 1, 5) == "Door_" then
					local id = string.match(name, "^Door_([%w]+)")
					local info = id and infoById[id]
					if info then
						table.insert(info.windows, addWindow(m, id, 0.5))
						info.exit = Vector3.new(m.Position.X, m.Position.Y, m.Position.Z) + axisNormal(m.CFrame.LookVector) * 10
					else
						warn("[Custom] нет здания для маркера " .. name)
					end
				elseif string.sub(name, 1, 5) == "Sign_" then
					local info = infoById[string.sub(name, 6)]
					if info then
						local def
						for _, d in Config.Buildings do
							if d.id == info.id then
								def = d
							end
						end
						local prompt, label = BuildKit.sign(entrances, info.name, Vector3.new(m.Position.X, m.Position.Y - m.Size.Y / 2, m.Position.Z), m.CFrame.LookVector)
						info.signPrompt, info.signLabel = prompt, label
					end
				elseif string.sub(name, 1, 7) == "Vendor_" then
					table.insert(vendors, { id = string.sub(name, 8), position = Vector3.new(m.Position.X, m.Position.Y - m.Size.Y / 2, m.Position.Z), facing = m.CFrame.LookVector })
				elseif string.sub(name, 1, 8) == "Barrier_" then
					table.insert(barriers, m)
				end
				-- маркеры видимы только в Studio
				if string.sub(name, 1, 8) ~= "Barrier_" then
					m.Transparency = 1
				end
			end
		end
	end
	-- объём здания по модели в Workspace.Buildings (первая с именем id): для выставления игроков ночью
	local buildingsFolder = workspace:FindFirstChild("Buildings")
	for id, info in infoById do
		local model = buildingsFolder and buildingsFolder:FindFirstChild(id)
		if model and model:IsA("Model") then
			local cf, size = model:GetBoundingBox()
			info.zone = { center = cf.Position, size = size }
		end
		if #info.windows > 0 or info.signPrompt then
			table.insert(buildings, info)
		end
	end

	-- пустая корневая модель: карту хранит Workspace, код её не владеет (Destroy не вызывается)
	local root = Instance.new("Model")
	root.Name = "CustomMapInfo"
	return {
		id = "Custom",
		name = "Своя карта",
		root = root,
		windows = windows,
		buildings = buildings,
		vendors = vendors,
		barriers = barriers,
		shop = { center = playerSpawn, halfX = 0, halfZ = 0 },
		zombieSpawns = zombieSpawns,
		playerSpawn = playerSpawn,
		nightSpawn = playerSpawn,
		wallBuys = {},
		carSpawns = carSpawns,
		shops = shops,
		carNames = carNames,
	}
end

return Custom
