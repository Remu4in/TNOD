--!strict
-- Лобби: блокпост у края заражённого города, ночь, прожекторы с вышек. Строится кодом (низкополигонально), без ассетов.
-- Не карта раунда: MapBuilder не используется (он сносит Workspace.Map, а в Studio лобби и матч живут на одном сервере).
-- Что внутри: четыре площадки-«грузовика» (отсчёт и счётчик над каждой), стол отряда, ворота «Play solo», стена рейтинга.
-- Сервис получает от build() подписи и зоны площадок и сам обновляет тексты.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local BuildKit = require(script.Parent:WaitForChild("BuildKit"))

local Lobby = {}

export type PadInfo = {
	index: number,
	center: Vector3, -- центр плиты (на уровне пола)
	halfX: number,
	halfZ: number,
	plate: Part,
	count: TextLabel, -- «2/6»
	status: TextLabel, -- «Launching in 12» / «Step on the pad»
}

export type LobbyInfo = {
	root: Model,
	spawn: Vector3,
	pads: { PadInfo },
	boardRows: { TextLabel }, -- строки таблицы лидеров сверху вниз
	boardTitle: TextLabel,
	squadPrompt: ProximityPrompt,
	soloPrompt: ProximityPrompt,
}

local GROUND = Color3.fromRGB(58, 60, 55)
local CONCRETE = Color3.fromRGB(110, 112, 108)
local KHAKI = Color3.fromRGB(88, 96, 70)
local DARK = Color3.fromRGB(34, 36, 40)
local WARM = Color3.fromRGB(255, 200, 130)

function Lobby.build(): LobbyInfo
	local O = Config.Lobby.Origin
	local old = workspace:FindFirstChild("Lobby")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Model")
	root.Name = "Lobby"
	root.Parent = workspace

	-- локальные координаты (x вправо, z к игроку, y вверх) → мировые
	local function at(x: number, y: number, z: number): Vector3
		return O + Vector3.new(x, y, z)
	end
	local function box(name: string, size: Vector3, center: Vector3, color: Color3, material: Enum.Material?, parent: Instance?): Part
		return BuildKit.part({ Name = name, Size = size, Position = center, Color = color, Material = material or Enum.Material.SmoothPlastic }, parent or root)
	end
	local function glow(parent: Instance, range: number, brightness: number, color: Color3)
		local l = Instance.new("PointLight")
		l.Range = range
		l.Brightness = brightness
		l.Color = color
		l.Parent = parent
	end
	local function label(parent: Instance, text: string, size: number, color: Color3?): TextLabel
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.TextScaled = true
		t.Font = Enum.Font.GothamBold
		t.TextColor3 = color or Color3.new(1, 1, 1)
		t.TextStrokeTransparency = 0.5
		t.Text = text
		t.Parent = parent
		return t
	end

	-- земля и ограда
	box("Ground", Vector3.new(240, 2, 200), at(0, -1, 0), GROUND, Enum.Material.Concrete)
	box("Road", Vector3.new(240, 0.2, 18), at(0, 0.1, 62), DARK, Enum.Material.Asphalt)
	local W, D = 240, 200
	for _, f in { { 0, -D / 2, W, 2 }, { 0, D / 2, W, 2 }, { -W / 2, 0, 2, D }, { W / 2, 0, 2, D } } do
		box("Barrier", Vector3.new(f[3], 7, f[4]), at(f[1], 3.5, f[2]), CONCRETE, Enum.Material.Concrete)
	end
	-- вышки с прожекторами по углам
	for _, c in { { -W / 2 + 8, -D / 2 + 8 }, { W / 2 - 8, -D / 2 + 8 }, { -W / 2 + 8, D / 2 - 8 }, { W / 2 - 8, D / 2 - 8 } } do
		for dx = -1, 1, 2 do
			for dz = -1, 1, 2 do
				box("TowerLeg", Vector3.new(1, 22, 1), at(c[1] + dx * 3, 11, c[2] + dz * 3), DARK, Enum.Material.Metal)
			end
		end
		box("TowerDeck", Vector3.new(9, 1, 9), at(c[1], 22, c[2]), KHAKI, Enum.Material.Metal)
		box("TowerRoof", Vector3.new(10, 0.8, 10), at(c[1], 27, c[2]), DARK, Enum.Material.Metal)
		local lamp = box("Searchlight", Vector3.new(2, 2, 2), at(c[1], 24, c[2]), WARM, Enum.Material.Neon)
		lamp.CanCollide = false
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Bottom
		spot.Angle = 90
		spot.Range = 120
		spot.Brightness = 3
		spot.Color = Color3.fromRGB(255, 235, 200)
		spot.Parent = lamp
	end

	-- фонари и костры-бочки
	for _, p in { { -80, 20 }, { 80, 20 }, { -40, 45 }, { 40, 45 }, { 0, 12 }, { -100, -40 }, { 100, -40 }, { 0, -40 } } do
		box("LampPole", Vector3.new(0.8, 14, 0.8), at(p[1], 7, p[2]), DARK, Enum.Material.Metal)
		local head = box("LampHead", Vector3.new(2.4, 0.6, 2.4), at(p[1], 14.3, p[2]), WARM, Enum.Material.Neon)
		head.CanCollide = false
		glow(head, 40, 1.3, Color3.fromRGB(255, 215, 160))
	end
	for _, p in { { -22, 38 }, { 22, 38 } } do
		local barrel = BuildKit.part({ Name = "FireBarrel", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4, 3, 3), CFrame = CFrame.new(at(p[1], 2, p[2])) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(120, 60, 40), Material = Enum.Material.Metal }, root)
		local fire = Instance.new("Fire")
		fire.Heat = 8
		fire.Size = 6
		fire.Parent = barrel
		glow(barrel, 32, 1.6, Color3.fromRGB(255, 150, 70))
	end

	-- мешки с песком у въезда и знаки
	for i = -3, 3 do
		box("Sandbags", Vector3.new(5, 2.4, 2.2), at(i * 5.5, 1.2, 74), Color3.fromRGB(150, 134, 100), Enum.Material.Fabric)
	end
	local title = box("TitleSign", Vector3.new(60, 10, 1), at(0, 16, -96), DARK, Enum.Material.Metal)
	local titleGui = Instance.new("SurfaceGui")
	titleGui.Face = Enum.NormalId.Back
	titleGui.Parent = title
	label(titleGui, "DEAD NIGHT — CHECKPOINT 7", 1, Color3.fromRGB(255, 220, 120))

	-- площадки-грузовики
	local pads: { PadInfo } = {}
	local n = Config.Lobby.PadCount
	local spacing = 34
	for i = 1, n do
		local x = (i - (n + 1) / 2) * spacing
		local z = -20
		-- грузовик: кабина, платформа, колёса, тент
		box("TruckBed", Vector3.new(11, 1, 18), at(x, 3, z - 4), KHAKI, Enum.Material.Metal)
		box("TruckCab", Vector3.new(11, 6, 6), at(x, 5.5, z - 15), KHAKI, Enum.Material.Metal)
		box("TruckWindow", Vector3.new(9, 2.4, 0.4), at(x, 6.6, z - 12), Color3.fromRGB(40, 60, 80), Enum.Material.Glass)
		box("TruckCover", Vector3.new(10, 6, 13), at(x, 7, z - 1), Color3.fromRGB(78, 88, 62), Enum.Material.Fabric)
		for _, wz in { -14, -2, 4 } do
			for wx = -1, 1, 2 do
				BuildKit.part({ Name = "Wheel", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 4, 4), CFrame = CFrame.new(at(x + wx * 5.8, 2, z + wz - 4)) * CFrame.Angles(0, 0, math.rad(90)), Color = DARK, Material = Enum.Material.Rubber }, root)
			end
		end
		-- плита, на которую встают (пол: y=0.2)
		local plate = box("Pad" .. i, Vector3.new(16, 0.4, 14), at(x, 0.2, z + 14), Color3.fromRGB(60, 200, 90), Enum.Material.Neon)
		plate.Transparency = 0.35
		plate.CanCollide = false
		for _, ex in { -8, 8 } do
			box("PadEdge", Vector3.new(0.5, 0.6, 14), at(x + ex, 0.3, z + 14), Color3.fromRGB(240, 230, 120), Enum.Material.Neon).CanCollide = false
		end
		-- табличка над грузовиком
		local sign = box("PadSign", Vector3.new(14, 7, 0.6), at(x, 13, z + 6), DARK, Enum.Material.Metal)
		sign.CanCollide = false
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Back
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 50
		gui.Parent = sign
		local head = Instance.new("TextLabel")
		head.Size = UDim2.fromScale(1, 0.2)
		head.BackgroundTransparency = 1
		head.TextScaled = true
		head.Font = Enum.Font.GothamBold
		head.TextColor3 = Color3.fromRGB(190, 200, 190)
		head.Text = "TRUCK " .. i
		head.Parent = gui
		local count = Instance.new("TextLabel")
		count.Position = UDim2.fromScale(0, 0.2)
		count.Size = UDim2.fromScale(1, 0.5)
		count.BackgroundTransparency = 1
		count.TextScaled = true
		count.Font = Enum.Font.GothamBlack
		count.TextColor3 = Color3.fromRGB(255, 255, 255)
		count.Text = string.format("0/%d", Config.Lobby.MaxSquad)
		count.Parent = gui
		local status = Instance.new("TextLabel")
		status.Position = UDim2.fromScale(0, 0.72)
		status.Size = UDim2.fromScale(1, 0.26)
		status.BackgroundTransparency = 1
		status.TextScaled = true
		status.Font = Enum.Font.GothamBold
		status.TextColor3 = Color3.fromRGB(120, 230, 140)
		status.Text = "Step on the pad"
		status.Parent = gui
		box("PadSignPost", Vector3.new(0.8, 12, 0.8), at(x - 6, 6, z + 6), DARK, Enum.Material.Metal)
		box("PadSignPost", Vector3.new(0.8, 12, 0.8), at(x + 6, 6, z + 6), DARK, Enum.Material.Metal)
		table.insert(pads, { index = i, center = at(x, 0, z + 14), halfX = 8, halfZ = 7, plate = plate, count = count, status = status })
	end

	-- стол отряда (слева) и ворота соло (справа)
	local function station(name: string, x: number, color: Color3, action: string, object: string, sign: string): ProximityPrompt
		local table_ = box(name, Vector3.new(10, 3.4, 5), at(x, 1.7, 30), color, Enum.Material.Metal)
		box(name .. "Tent", Vector3.new(14, 0.6, 9), at(x, 9, 30), KHAKI, Enum.Material.Fabric)
		for dx = -1, 1, 2 do
			box(name .. "Pole", Vector3.new(0.7, 9, 0.7), at(x + dx * 6.5, 4.5, 30 + 4), DARK, Enum.Material.Metal)
			box(name .. "Pole", Vector3.new(0.7, 9, 0.7), at(x + dx * 6.5, 4.5, 30 - 4), DARK, Enum.Material.Metal)
		end
		local board = box(name .. "Sign", Vector3.new(10, 2.6, 0.4), at(x, 6.6, 34), DARK, Enum.Material.Metal)
		board.CanCollide = false
		local sg = Instance.new("SurfaceGui")
		sg.Face = Enum.NormalId.Back
		sg.Parent = board
		label(sg, sign, 1, Color3.fromRGB(255, 220, 120))
		glow(table_, 26, 1.2, WARM)
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = action
		prompt.ObjectText = object
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = table_
		return prompt
	end
	local squadPrompt = station("SquadTable", -58, Color3.fromRGB(70, 90, 110), "Open squad menu", "Squad table", "SQUAD")
	local soloPrompt = station("SoloGate", 58, Color3.fromRGB(110, 70, 60), "Play solo", "Solo mission", "PLAY SOLO")

	-- стена рейтинга (на севере, лицом к площадке)
	local wall = box("BoardWall", Vector3.new(66, 34, 2), at(0, 17, -86), DARK, Enum.Material.Metal)
	local bg = Instance.new("SurfaceGui")
	bg.Face = Enum.NormalId.Back
	bg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	bg.PixelsPerStud = 40
	bg.Parent = wall
	local boardTitle = Instance.new("TextLabel")
	boardTitle.Size = UDim2.fromScale(1, 0.12)
	boardTitle.BackgroundTransparency = 1
	boardTitle.TextScaled = true
	boardTitle.Font = Enum.Font.GothamBlack
	boardTitle.TextColor3 = Color3.fromRGB(255, 220, 120)
	boardTitle.Text = "TOP SURVIVORS"
	boardTitle.Parent = bg
	local rows: { TextLabel } = {}
	local count = Config.Lobby.BoardSize
	for r = 1, count do
		local row = Instance.new("TextLabel")
		row.Position = UDim2.fromScale(0.04, 0.14 + (r - 1) * (0.84 / count))
		row.Size = UDim2.fromScale(0.92, 0.84 / count - 0.005)
		row.BackgroundTransparency = if r % 2 == 0 then 0.9 else 1
		row.BackgroundColor3 = Color3.new(1, 1, 1)
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextScaled = true
		row.Font = Enum.Font.GothamBold
		row.TextColor3 = Color3.fromRGB(230, 235, 230)
		row.Text = ""
		row.Parent = bg
		table.insert(rows, row)
	end
	box("BoardLegL", Vector3.new(2, 8, 2), at(-30, 4, -86), DARK, Enum.Material.Metal)
	box("BoardLegR", Vector3.new(2, 8, 2), at(30, 4, -86), DARK, Enum.Material.Metal)

	-- спавн: перед столами, лицом к площадкам
	local spawn = Config.Lobby.Spawn + O
	local spawnPad = BuildKit.part({ Name = "SpawnZone", Size = Vector3.new(30, 0.3, 14), Position = at(0, 0.15, 48), Color = Color3.fromRGB(80, 84, 78), Material = Enum.Material.Concrete, CanCollide = false }, root)
	spawnPad.CanQuery = false

	return {
		root = root,
		spawn = spawn,
		pads = pads,
		boardRows = rows,
		boardTitle = boardTitle,
		squadPrompt = squadPrompt,
		soloPrompt = soloPrompt,
	}
end

return Lobby
