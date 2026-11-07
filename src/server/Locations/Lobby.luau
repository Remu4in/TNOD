--!strict
-- Лобби v2: военный блокпост у края города, тёплый вечер. Строится кодом из готовых моделей `ServerStorage.Assets`
-- (техника, мешки с песком, ящики, фонари, вышки, автоматы, НПС) и из проверенных ассетов `Assets.Lobby`
-- (баннеры, зоны сбора, прилавки, вывеска, стена, табло). Скриптов в моделях нет: тексты, цвета и меню ведёт LobbyService.
-- Не карта раунда: MapBuilder не используется (он сносит Workspace.Map, а в Studio лобби и матч живут на одном сервере).
--
-- Планировка (локальные координаты: x — на восток, z — на юг, игрок появляется на юге и смотрит на север):
--
--   z=-112 ┌──────── северный забор + вышки ────────┐
--          │  танк     APC      Humvee    грузовик   │  техника за баннерами
--   z=-54  │ [баннер] [баннер]  [баннер]  [баннер]   │
--   z=-32  │ ZONE 1   ZONE 2    ZONE 3    ZONE 4     │  зоны сбора команды (x = -66, -22, 22, 66)
--          │ магазин(З)   ·  аллея x=0  ·  SOLO(В)   │  стена и прилавки слева, ворота Solo справа
--   z=26   │ ════════ дорога + колонна у восточных ворот
--   z=38…84│        площадь, спавн (0,4,52) ↑        │  автоматы у площади
--   z=108  │        ТАБЛО «Top survivors» (лицом на север, за спиной у игрока)
--   z=126  └──────── южный забор + вышки ────────────┘

local ServerStorage = game:GetService("ServerStorage")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local Lobby = {}

export type BannerView = {
	setText: (title: string, status: string, detail: string, color: Color3, progress: number?) -> (),
}

export type ZoneView = {
	index: number,
	center: Vector3, -- центр зоны на уровне пола
	radius: number,
	ring: BasePart, -- светящееся кольцо ассета
	fill: BasePart, -- диск внутри кольца
	banner: BannerView,
	setColor: (color: Color3) -> (),
}

export type BoardEntry = { name: string, wave: number, rating: number, image: string? }

export type BoardView = {
	setRow: (rank: number, entry: BoardEntry?) -> (),
	setNote: (text: string) -> (),
	setSquad: (rank: number, names: string?, wave: number, rating: number) -> (),
	rig: Model?, -- «аватар первого места» ассета: сервер одевает его в лидера
}

export type NpcSpot = {
	kind: string, -- "guard" | "patrol" | "chat" | "trader"
	pos: Vector3,
	yaw: number, -- куда смотрит (градусы, 0 = на север)
	route: { Vector3 }?, -- патруль: точки по кругу туда-обратно
	partner: number?, -- chat: номер собеседника в списке точек
	trader: number?, -- trader: номер прилавка
	label: string?,
}

export type MenuPoint = { prompt: ProximityPrompt, kind: string, id: number }

export type LobbyInfo = {
	root: Model,
	spawn: Vector3,
	zones: { ZoneView },
	board: BoardView,
	soloPrompt: ProximityPrompt,
	menus: { MenuPoint }, -- прилавки (shop) и автоматы (vending)
	npcSpots: { NpcSpot },
	npcFolder: Folder,
}

-- Палитра: тёплый вечер, военный хаки
local COL = {
	grass = { Color3.fromRGB(86, 112, 60), Color3.fromRGB(78, 104, 56), Color3.fromRGB(96, 120, 64), Color3.fromRGB(104, 112, 62) },
	dirt = Color3.fromRGB(112, 94, 68),
	tileA = Color3.fromRGB(150, 146, 134),
	tileB = Color3.fromRGB(128, 124, 114),
	cobble = Color3.fromRGB(112, 106, 98),
	asphalt = Color3.fromRGB(54, 56, 60),
	line = Color3.fromRGB(226, 214, 150),
	concrete = Color3.fromRGB(120, 120, 116),
	dark = Color3.fromRGB(34, 36, 40),
	khaki = Color3.fromRGB(96, 104, 76),
	gold = Color3.fromRGB(255, 204, 92),
	warm = Color3.fromRGB(255, 200, 130),
}

local rng = Random.new(7)

function Lobby.zoneX(index: number, count: number): number
	return (index - (count + 1) / 2) * 44
end

-- Берёт модель из ServerStorage.Assets по пути "Папка.Имя"
local function template(path: string): Model?
	local cur: Instance? = ServerStorage:FindFirstChild("Assets")
	for seg in string.gmatch(path, "[^.]+") do
		cur = if cur then cur:FindFirstChild(seg) else nil
	end
	if cur and cur:IsA("Model") then
		return cur
	end
	warn("[Lobby] asset not found: " .. path)
	return nil
end

-- Мировой AABB модели по углам частей; низ-центр → точка опоры для расстановки
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

function Lobby.build(): LobbyInfo
	local O = Config.Lobby.Origin
	local N = Config.Lobby.ZoneCount
	local old = workspace:FindFirstChild("Lobby")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Model")
	root.Name = "Lobby"
	local floorF = Instance.new("Folder")
	floorF.Name = "Floor"
	floorF.Parent = root
	local propsF = Instance.new("Folder")
	propsF.Name = "Props"
	propsF.Parent = root
	local npcF = Instance.new("Folder")
	npcF.Name = "Npcs"
	npcF.Parent = root

	local function at(x: number, y: number, z: number): Vector3
		return O + Vector3.new(x, y, z)
	end

	local function box(name: string, size: Vector3, center: Vector3, color: Color3, material: Enum.Material?, parent: Instance?, yawDeg: number?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = CFrame.new(center) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = parent or propsF
		return p
	end

	-- пол: плита со своей верхней отметкой top (над y=0 пола-травы)
	local function slab(name: string, x0: number, z0: number, x1: number, z1: number, top: number, color: Color3, material: Enum.Material): Part
		local thick = 0.4
		return box(name, Vector3.new(x1 - x0, thick, z1 - z0), at((x0 + x1) / 2, top - thick / 2, (z0 + z1) / 2), color, material, floorF)
	end

	-- плитка в шахматном порядке с лёгкой разноцветностью (не повторяется однообразно)
	local function tiles(name: string, x0: number, z0: number, x1: number, z1: number, step: number, top: number, matA: Enum.Material, colA: Color3, matB: Enum.Material, colB: Color3)
		local nx = math.max(1, math.round((x1 - x0) / step))
		local nz = math.max(1, math.round((z1 - z0) / step))
		local sx, sz = (x1 - x0) / nx, (z1 - z0) / nz
		for i = 1, nx do
			for j = 1, nz do
				local even = (i + j) % 2 == 0
				local c = if even then colA else colB
				local jitter = rng:NextNumber(-6, 6) / 255
				c = Color3.new(math.clamp(c.R + jitter, 0, 1), math.clamp(c.G + jitter, 0, 1), math.clamp(c.B + jitter, 0, 1))
				box(name, Vector3.new(sx, 0.4, sz), at(x0 + (i - 0.5) * sx, top - 0.2, z0 + (j - 0.5) * sz), c, if even then matA else matB, floorF)
			end
		end
	end

	-- расстановка модели: низ-центр в (x, y, z), поворот yawDeg вокруг вертикали
	local function put(path: string, x: number, z: number, yawDeg: number, opts: { y: number?, scale: number?, name: string?, parent: Instance? }?): Model?
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
		m.Parent = (opts and opts.parent) or propsF
		local pv = m:GetPivot()
		m.WorldPivot = bottomCenter(m) * pv.Rotation
		if opts and opts.scale and opts.scale ~= 1 then
			m:ScaleTo(opts.scale)
		end
		local y = (opts and opts.y) or 0.2
		m:PivotTo(CFrame.new(at(x, y, z)) * CFrame.Angles(0, math.rad(yawDeg), 0))
		return m
	end

	local function light(parent: Instance, range: number, brightness: number, color: Color3)
		local l = Instance.new("PointLight")
		l.Range = range
		l.Brightness = brightness
		l.Color = color
		l.Parent = parent
	end

	local function sign(name: string, text: string, size: Vector3, center: Vector3, yawDeg: number, textColor: Color3, ppsFactor: number?): Part
		local board = box(name, size, center, COL.dark, Enum.Material.Metal, propsF, yawDeg)
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = ppsFactor or 40
		gui.Parent = board
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.TextScaled = true
		t.Font = Enum.Font.GothamBlack
		t.TextColor3 = textColor
		t.Text = text
		t.Parent = gui
		return board
	end

	-- ===== Пол =====
	local FX0, FX1, FZ0, FZ1 = -146, 146, -122, 134
	box("Grass", Vector3.new(FX1 - FX0, 1, FZ1 - FZ0), at(0, -0.5, (FZ0 + FZ1) / 2), COL.grass[1], Enum.Material.Grass, floorF)
	-- пятна травы и земли: края лобби не однотонные
	for _ = 1, 70 do
		local x, z = rng:NextNumber(FX0 + 6, FX1 - 6), rng:NextNumber(FZ0 + 6, FZ1 - 6)
		local w, d = rng:NextNumber(10, 34), rng:NextNumber(10, 30)
		local dirt = rng:NextNumber() < 0.22
		local patch = box("Patch", Vector3.new(w, 0.1, d), at(x, 0.02 + rng:NextNumber(0, 0.04), z), if dirt then COL.dirt else COL.grass[rng:NextInteger(2, #COL.grass)], if dirt then Enum.Material.Ground else (if rng:NextNumber() < 0.4 then Enum.Material.LeafyGrass else Enum.Material.Grass), floorF, rng:NextNumber(0, 90))
		patch.CanCollide = false
	end
	-- дорога вдоль лобби (запад — восток) с разметкой
	slab("Road", FX0, 19, FX1, 33, 0.12, COL.asphalt, Enum.Material.Asphalt)
	for x = FX0 + 6, FX1 - 6, 10 do
		box("RoadLine", Vector3.new(5, 0.06, 0.5), at(x, 0.15, 26), COL.line, Enum.Material.SmoothPlastic, floorF)
	end
	slab("RoadCurbN", FX0, 18.2, FX1, 19, 0.3, COL.concrete, Enum.Material.Concrete)
	slab("RoadCurbS", FX0, 33, FX1, 33.8, 0.3, COL.concrete, Enum.Material.Concrete)
	-- площадь у спавна
	tiles("PlazaTile", -36, 38, 36, 86, 6, 0.2, Enum.Material.Pavement, COL.tileA, Enum.Material.Cobblestone, COL.tileB)
	slab("PlazaEdgeN", -36, 37.4, 36, 38, 0.3, COL.concrete, Enum.Material.Concrete)
	-- аллея через дорогу к зонам (x=0) и тропинки к каждой зоне
	tiles("AvenueTile", -5, -62, 5, 19, 5, 0.18, Enum.Material.Pavement, COL.tileA, Enum.Material.Pavement, COL.tileB)
	slab("AvenueLink", -5, 33, 5, 38, 0.18, COL.cobble, Enum.Material.Cobblestone)
	-- зоны: плита с плиткой, тропинка от дороги
	for i = 1, N do
		local zx = Lobby.zoneX(i, N)
		tiles("ZoneTile", zx - 16, -48, zx + 16, -16, 6.4, 0.2, Enum.Material.Concrete, COL.tileA, Enum.Material.Slate, COL.tileB)
		slab("ZonePath", zx - 3, -16, zx + 3, 19, 0.1, COL.cobble, Enum.Material.Cobblestone)
	end
	-- магазин (запад): плитка перед прилавками; Solo (восток): плитка и тропа
	tiles("ShopTile", -128, -26, -100, 14, 6.4, 0.2, Enum.Material.Concrete, COL.tileA, Enum.Material.Concrete, COL.tileB)
	slab("ShopPath", -100, 8, -90, 14, 0.1, COL.cobble, Enum.Material.Cobblestone)
	tiles("ShopTileSouth", 56, 94, 86, 126, 6.4, 0.2, Enum.Material.Concrete, COL.tileA, Enum.Material.Concrete, COL.tileB)
	tiles("ShopTileEast", 116, -24, 142, 14, 6.4, 0.2, Enum.Material.Concrete, COL.tileA, Enum.Material.Slate, COL.tileB)
	tiles("SoloTile", 88, -18, 116, 8, 6.4, 0.2, Enum.Material.Concrete, COL.tileA, Enum.Material.Slate, COL.tileB)
	slab("SoloPath", 98, 8, 106, 19, 0.1, COL.cobble, Enum.Material.Cobblestone)
	-- площадка под табло и грунт под колонну
	tiles("BoardTile", -34, 94, 34, 118, 6, 0.4, Enum.Material.Concrete, COL.tileB, Enum.Material.Concrete, COL.tileA)
	slab("ConvoyGround", 58, 38, 132, 82, 0.1, COL.dirt, Enum.Material.Ground)
	slab("BackGround", -120, -110, 120, -62, 0.06, COL.dirt, Enum.Material.Ground)

	-- ===== Периметр: забор, мешки у ворот, вышки =====
	local function fenceLine(x0: number, z0: number, x1: number, z1: number, yaw: number, gapA: number?, gapB: number?)
		local len = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
		local n = math.floor(len / 18.3)
		for k = 0, n - 1 do
			local t = (k + 0.5) / n
			local cx, cz = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
			local along = if yaw == 0 then cx else cz
			if not (gapA and gapB and along > gapA and along < gapB) then
				put("Base.FenceSection", cx, cz, yaw, { y = 0.1 })
			end
		end
	end
	fenceLine(-144, -118, 144, -118, 0)
	fenceLine(-144, 130, 144, 130, 0)
	fenceLine(-144, -118, -144, 130, 90)
	fenceLine(144, -118, 144, 130, 90, 14, 38) -- восточные ворота: проём у дороги
	for _, tower in { { -134, -108 }, { 134, -108 }, { -134, 122 }, { 134, 122 } } do
		put("Base.WatchTower", tower[1], tower[2], if tower[1] < 0 then 90 else -90, { y = 0.1 })
	end
	-- ворота: мешки по бокам проёма и колонна в проезде
	for _, z in { 8, 46 } do
		put("Base.Fort", 136, z, 0, { y = 0.1 })
	end
	put("Base.Fort", 120, 12, 90, { y = 0.1 })
	put("Base.Fort", 120, 40, 90, { y = 0.1 })

	-- ===== Зоны сбора =====
	local zones: { ZoneView } = {}
	local zoneZ = -32
	for i = 1, N do
		local zx = Lobby.zoneX(i, N)
		local zm = put("Lobby.Zone", zx, zoneZ, 0, { y = 0.2, name = "Zone" .. i })
		local ring: BasePart? = nil
		if zm then
			ring = zm:FindFirstChildWhichIsA("MeshPart")
		end
		if not ring then
			ring = box("ZoneRing", Vector3.new(18.4, 0.4, 18.4), at(zx, 0.4, zoneZ), COL.gold, Enum.Material.Neon, propsF)
		end
		local ringPart = ring :: BasePart
		ringPart.CanCollide = false
		local fill = Instance.new("Part")
		fill.Name = "ZoneFill"
		fill.Shape = Enum.PartType.Cylinder
		fill.Anchored = true
		fill.CanCollide = false
		fill.CanQuery = false
		fill.Size = Vector3.new(0.1, 17.4, 17.4)
		fill.CFrame = CFrame.new(at(zx, 0.28, zoneZ)) * CFrame.Angles(0, 0, math.rad(90))
		fill.Material = Enum.Material.Neon
		fill.Transparency = 0.72
		fill.Color = Color3.fromRGB(70, 210, 110)
		fill.Parent = propsF
		light(fill, 22, 1.1, fill.Color)

		-- баннер за зоной, лицом на юг
		local bm = put("Lobby.Banner", zx, -54, 180, { y = 0.2, name = "Banner" .. i, scale = 1.05 })
		local labels: { title: TextLabel?, status: TextLabel?, detail: TextLabel?, bar: Frame?, barBg: Frame?, stroke: UIStroke? } = {}
		if bm then
			local screen = bm:FindFirstChild("Screen") :: BasePart?
			if screen then
				local gui = Instance.new("SurfaceGui")
				gui.Face = Enum.NormalId.Back
				gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
				gui.CanvasSize = Vector2.new(1230, 700)
				gui.LightInfluence = 0
				gui.Brightness = 1.4
				gui.Parent = screen
				local bg = Instance.new("Frame")
				bg.Size = UDim2.fromScale(1, 1)
				bg.BackgroundColor3 = Color3.fromRGB(14, 18, 16)
				bg.BorderSizePixel = 0
				bg.Parent = gui
				local stroke = Instance.new("UIStroke")
				stroke.Thickness = 10
				stroke.Color = COL.gold
				stroke.Parent = bg
				local grad = Instance.new("UIGradient")
				grad.Color = ColorSequence.new(Color3.fromRGB(34, 40, 34), Color3.fromRGB(10, 12, 12))
				grad.Rotation = 90
				grad.Parent = bg
				local function lbl(y: number, h: number, font: Enum.Font, color: Color3): TextLabel
					local t = Instance.new("TextLabel")
					t.Position = UDim2.fromScale(0.04, y)
					t.Size = UDim2.fromScale(0.92, h)
					t.BackgroundTransparency = 1
					t.TextScaled = true
					t.Font = font
					t.TextColor3 = color
					t.TextStrokeTransparency = 0.6
					t.Parent = bg
					return t
				end
				labels.title = lbl(0.06, 0.15, Enum.Font.GothamBold, Color3.fromRGB(200, 206, 196))
				labels.status = lbl(0.24, 0.34, Enum.Font.GothamBlack, COL.gold)
				labels.detail = lbl(0.62, 0.16, Enum.Font.GothamBold, Color3.fromRGB(220, 224, 214))
				local barBg = Instance.new("Frame")
				barBg.Position = UDim2.fromScale(0.04, 0.84)
				barBg.Size = UDim2.fromScale(0.92, 0.08)
				barBg.BackgroundColor3 = Color3.fromRGB(40, 46, 40)
				barBg.BorderSizePixel = 0
				barBg.Parent = bg
				local c1 = Instance.new("UICorner")
				c1.CornerRadius = UDim.new(0, 12)
				c1.Parent = barBg
				local bar = Instance.new("Frame")
				bar.Size = UDim2.fromScale(0, 1)
				bar.BackgroundColor3 = COL.gold
				bar.BorderSizePixel = 0
				bar.Parent = barBg
				local c2 = Instance.new("UICorner")
				c2.CornerRadius = UDim.new(0, 12)
				c2.Parent = bar
				labels.bar, labels.barBg = bar, barBg
				labels.stroke = stroke
			end
		end
		local banner: BannerView = {
			setText = function(title: string, status: string, detail: string, color: Color3, progress: number?)
				if labels.title then
					labels.title.Text = title
				end
				if labels.status then
					labels.status.Text = status
					labels.status.TextColor3 = color
				end
				if labels.detail then
					labels.detail.Text = detail
				end
				local bar, barBg = labels.bar, labels.barBg
				if bar and barBg then
					barBg.Visible = progress ~= nil
					bar.Size = UDim2.fromScale(math.clamp(progress or 0, 0, 1), 1)
					bar.BackgroundColor3 = color
				end
				local st = labels.stroke
				if st then
					st.Color = color
				end
			end,
		}
		banner.setText("SQUAD " .. i, "OPEN", "Step in to host", Color3.fromRGB(110, 230, 140), nil)

		-- фонари и мешки вокруг плиты
		put("Props.RoadLight", zx - 17, -14, 0, { y = 0.2, scale = 0.5 })
		put("Props.RoadLight", zx + 17, -14, 180, { y = 0.2, scale = 0.5 })
		local view: ZoneView = {
			index = i,
			center = at(zx, 0.2, zoneZ),
			radius = Config.Lobby.ZoneRadius,
			ring = ringPart,
			fill = fill,
			banner = banner,
			setColor = function(color: Color3)
				ringPart.Color = color
				fill.Color = color
				for _, l in fill:GetChildren() do
					if l:IsA("PointLight") then
						l.Color = color
					end
				end
			end,
		}
		view.setColor(Color3.fromRGB(70, 210, 110))
		table.insert(zones, view)
	end
	-- мешки между зонами, по краям и позади
	for _, x in { -92, -44, 44, 92 } do
		put("Base.Fort", x, -32, 0, { y = 0.2 })
	end
	for _, x in { -92, -44, 44, 92 } do
		put("Base.Fort", x, -60, 0, { y = 0.1 })
	end

	-- техника за баннерами и ящики стопками
	put("Vehicles.MilitaryTank", -78, -90, -20, { y = 0.1 })
	put("Vehicles.APC", -24, -92, 8, { y = 0.1 })
	put("Vehicles.HumveeArmored", 28, -88, -12, { y = 0.1 })
	put("Vehicles.TransportTruck", 76, -92, 90, { y = 0.1 })
	for _, c in { { -52, -84, 15 }, { 4, -84, -10 }, { 52, -82, 30 }, { 96, -78, 0 } } do
		put("Props.MilitaryCrates", c[1], c[2], c[3], { y = 0.1 })
	end
	put("Base.Crates", -100, -80, 25, { y = 0.1 })
	put("Base.Crates", 106, -96, -35, { y = 0.1 })
	-- колонна у восточных ворот
	put("Vehicles.TransportTruck", 74, 54, 90, { y = 0.12 })
	put("Vehicles.APC", 114, 56, 90, { y = 0.12 })
	put("Vehicles.HumveeArmored", 90, 72, 70, { y = 0.12 })
	put("Vehicles.MilitaryTank", -100, 104, 30, { y = 0.1 })
	put("Props.MilitaryCrates", 64, 74, 20, { y = 0.12 })
	put("Base.Crates", 130, 70, 15, { y = 0.12 })
	-- техника у магазина
	put("Vehicles.HumveeArmored", -104, 56, 70, { y = 0.1 })
	put("Vehicles.HumveeArmored", -122, 70, 100, { y = 0.1 })
	put("Props.MilitaryCrates", -86, 66, -25, { y = 0.1 })

	-- ===== Фонари вдоль дорог и аллеи =====
	for _, p in { { -120, 17 }, { -80, 17 }, { -40, 17 }, { 40, 17 }, { 80, 17 }, { 120, 17 } } do
		put("Props.RoadLight", p[1], p[2], 0, { y = 0.2, scale = 0.5 })
	end
	for _, p in { { -120, 35 }, { -70, 35 }, { 70, 35 }, { 120, 35 } } do
		put("Props.RoadLight", p[1], p[2], 180, { y = 0.2, scale = 0.5 })
	end
	for _, z in { 46, 66, 82 } do
		put("Props.RoadLight", -36, z, 0, { y = 0.2, scale = 0.5 })
		put("Props.RoadLight", 36, z, 180, { y = 0.2, scale = 0.5 })
	end
	for _, z in { -10, -40 } do
		put("Props.RoadLight", -7, z, -90, { y = 0.2, scale = 0.5 })
		put("Props.RoadLight", 7, z, 90, { y = 0.2, scale = 0.5 })
	end
	-- скамейки у площади и военные припасы вместо бочек: скамьи лицом к центру
	for _, p in { { -30, 46, -90 }, { 30, 46, 90 }, { -30, 76, -90 }, { 30, 76, 90 } } do
		put("Metro.Bench", p[1], p[2], p[3], { y = 0.2 })
	end
	for _, c in { { -34, 63, 10 }, { 34, 63, -10 }, { -34, 90, 30 }, { 34, 90, -30 } } do
		put("Props.MilitaryCrates", c[1], c[2], c[3], { y = 0.2, scale = 0.8 })
	end

	local menus: { MenuPoint } = {}
	local npcSpots: { NpcSpot } = {}

	local function addPrompt(parent: Instance, action: string, object: string, distance: number): ProximityPrompt
		local pr = Instance.new("ProximityPrompt")
		pr.ActionText = action
		pr.ObjectText = object
		pr.HoldDuration = 0
		pr.MaxActivationDistance = distance
		pr.RequiresLineOfSight = false
		pr.Parent = parent
		return pr
	end

	-- ===== Магазины: три точки, в каждой стена с вывеской, 2 прилавка, ящики, по торговцу у прилавка =====
	-- Локальная схема (магазин «смотрит» на +x при поворотe 0): стена lx=-10, торговцы lx=-5.6, прилавки lx=0 (lz=±7), покупатели с +x.
	local traderCount = 0
	local function shopAt(cx: number, cz: number, rot: number)
		local r = math.rad(rot)
		local function w(lx: number, lz: number): (number, number)
			return cx + lx * math.cos(r) + lz * math.sin(r), cz - lx * math.sin(r) + lz * math.cos(r)
		end
		local wx, wz = w(-10, 0)
		put("Lobby.Wall", wx, wz, rot, { y = 0.2, name = "ShopWall", scale = 0.7 })
		local sx, sz = w(-10 + 2.2, 0)
		put("Lobby.ShopSign", sx, sz, rot - 90, { y = 7, name = "ShopSign", scale = 1.2 })
		for _, lz in { -7, 7 } do
			traderCount += 1
			local stx, stz = w(0, lz)
			put("Lobby.Stall", stx, stz, rot - 90, { y = 0.2, name = "Stall" .. traderCount })
			local tx, tz = w(-5.6, lz)
			table.insert(npcSpots, { kind = "trader", pos = at(tx, 0, tz), yaw = 90 - rot, trader = traderCount, label = "Trader" })
		end
		local c1x, c1z = w(-6, -15.5)
		local c2x, c2z = w(-6, 15.5)
		put("Props.MilitaryCrates", c1x, c1z, 20 + rot, { y = 0.2, scale = 0.8 })
		put("Props.MilitaryCrates", c2x, c2z, -15 + rot, { y = 0.2, scale = 0.8 })
	end
	shopAt(-113, -6, 0) -- запад: прежнее место
	shopAt(70, 110, 180) -- юг: у табло «Top survivors»
	shopAt(124, -5, 180) -- восток: у ворот Solo

	-- ===== Автоматы с донатными предметами: у площади, лицом к спавну =====
	for k, side in { -1, 1 } do
		local m = put("Props.Vending", side * 31, 56, if side < 0 then -90 else 90, { y = 0.2, name = "Vending" .. k })
		if m then
			local big: BasePart? = nil
			local bs = 0
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") and d.Size.Magnitude > bs then
					big, bs = d, d.Size.Magnitude
				end
			end
			if big then
				local pr = addPrompt(big, "Browse", "Vending machine", 9)
				table.insert(menus, { prompt = pr, kind = "vending", id = k })
			end
		end
	end

	-- ===== Solo: ворота на востоке =====
	local soloPos = at(102, 0.2, -5)
	put("Base.Fort", 90, -5, 0, { y = 0.2 })
	put("Base.Fort", 114, -5, 0, { y = 0.2 })
	put("Props.RoadLight", 96, 8, 0, { y = 0.2, scale = 0.5 })
	put("Props.RoadLight", 108, 8, 180, { y = 0.2, scale = 0.5 })
	put("Vehicles.HumveeArmored", 102, -26, 180, { y = 0.2 })
	local soloCrate = put("Props.MilitaryCrates", 102, -5, 0, { y = 0.2, scale = 1.1, name = "SoloCrate" })
	sign("SoloSign", "SOLO MISSION", Vector3.new(16, 4, 0.6), at(102, 12, 4), 180, COL.gold, 50)
	box("SoloPostL", Vector3.new(0.8, 11, 0.8), at(94.5, 5.5, 4), COL.dark, Enum.Material.Metal)
	box("SoloPostR", Vector3.new(0.8, 11, 0.8), at(109.5, 5.5, 4), COL.dark, Enum.Material.Metal)
	local soloHost: BasePart = Instance.new("Part")
	soloHost.Name = "SoloPromptHost"
	soloHost.Anchored = true
	soloHost.CanCollide = false
	soloHost.CanQuery = false
	soloHost.Transparency = 1
	soloHost.Size = Vector3.new(3, 3, 3)
	soloHost.Position = soloPos + Vector3.new(0, 2.5, 4)
	soloHost.Parent = propsF
	local soloPrompt = addPrompt(soloHost, "Play solo", "Solo mission", 11)
	if soloCrate then
		light(soloHost, 24, 1.1, COL.warm)
	end

	-- ===== Табло «Top survivors» — на юге, лицом на север, за спиной у игрока на спавне =====
	local boardView: BoardView
	do
		local bm = put("Lobby.Board", 0, 108, 0, { y = 0.4, name = "Board", scale = 2.2 })
		local rows: { { frame: Frame, rank: TextLabel, avatar: ImageLabel, name: TextLabel, wave: TextLabel, rating: TextLabel, stroke: UIStroke } } = {}
		local note: TextLabel? = nil
		local rig: Model? = nil
		if bm then
			rig = bm:FindFirstChild("Rig", true) :: Model?
			if rig then
				for _, d in rig:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored = d.Name == "HumanoidRootPart"
						d.CanCollide = false
					end
				end
			end
			local sb = bm:FindFirstChild("ScoreBlock", true) :: BasePart?
			if sb then
				sb.Transparency = 0
				sb.Color = Color3.fromRGB(12, 16, 14)
				sb.Material = Enum.Material.SmoothPlastic
				local gui = Instance.new("SurfaceGui")
				gui.Name = "BoardGui"
				gui.Face = Enum.NormalId.Front
				gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
				gui.CanvasSize = Vector2.new(1550, 900)
				gui.LightInfluence = 0
				gui.Brightness = 1.3
				gui.Parent = sb
				local bg = Instance.new("Frame")
				bg.Size = UDim2.fromScale(1, 1)
				bg.BackgroundColor3 = Color3.fromRGB(16, 20, 18)
				bg.BorderSizePixel = 0
				bg.Parent = gui
				local grad = Instance.new("UIGradient")
				grad.Color = ColorSequence.new(Color3.fromRGB(34, 42, 36), Color3.fromRGB(10, 12, 12))
				grad.Rotation = 90
				grad.Parent = bg
				local title = Instance.new("TextLabel")
				title.Position = UDim2.fromOffset(40, 8)
				title.Size = UDim2.new(1, -80, 0, 80)
				title.BackgroundTransparency = 1
				title.Font = Enum.Font.GothamBlack
				title.TextScaled = true
				title.TextColor3 = COL.gold
				title.Text = "TOP SURVIVORS"
				title.Parent = bg
				local function header(text: string, x: number, w: number, align: Enum.TextXAlignment)
					local h = Instance.new("TextLabel")
					h.Position = UDim2.fromOffset(x, 92)
					h.Size = UDim2.fromOffset(w, 32)
					h.BackgroundTransparency = 1
					h.Font = Enum.Font.GothamBold
					h.TextSize = 32
					h.TextColor3 = Color3.fromRGB(150, 158, 148)
					h.TextXAlignment = align
					h.Text = text
					h.Parent = bg
				end
				header("#", 40, 90, Enum.TextXAlignment.Center)
				header("SURVIVOR", 230, 500, Enum.TextXAlignment.Left)
				header("BEST NIGHT", 880, 250, Enum.TextXAlignment.Center)
				header("RATING", 1180, 300, Enum.TextXAlignment.Right)
				for r = 1, Config.Lobby.BoardSize do
					local y = 128 + (r - 1) * 68
					local rowF = Instance.new("Frame")
					rowF.Position = UDim2.fromOffset(30, y)
					rowF.Size = UDim2.fromOffset(1490, 62)
					rowF.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
					rowF.BackgroundTransparency = if r % 2 == 0 then 0.94 else 0.97
					rowF.BorderSizePixel = 0
					rowF.Parent = bg
					local rc = Instance.new("UICorner")
					rc.CornerRadius = UDim.new(0, 12)
					rc.Parent = rowF
					local rs = Instance.new("UIStroke")
					rs.Thickness = 3
					rs.Transparency = 1
					rs.Color = COL.gold
					rs.Parent = rowF
					local function cell(x: number, w: number, size: number, font: Enum.Font, align: Enum.TextXAlignment): TextLabel
						local t = Instance.new("TextLabel")
						t.Position = UDim2.fromOffset(x, 0)
						t.Size = UDim2.fromOffset(w, 62)
						t.BackgroundTransparency = 1
						t.Font = font
						t.TextSize = size
						t.TextColor3 = Color3.fromRGB(232, 236, 228)
						t.TextXAlignment = align
						t.TextTruncate = Enum.TextTruncate.AtEnd
						t.Text = ""
						t.Parent = rowF
						return t
					end
					local rank = cell(10, 90, 40, Enum.Font.GothamBlack, Enum.TextXAlignment.Center)
					rank.Text = tostring(r)
					local avatar = Instance.new("ImageLabel")
					avatar.Position = UDim2.fromOffset(120, 4)
					avatar.Size = UDim2.fromOffset(54, 54)
					avatar.BackgroundColor3 = Color3.fromRGB(40, 46, 42)
					avatar.BorderSizePixel = 0
					avatar.Image = ""
					avatar.Visible = false
					avatar.Parent = rowF
					local ac = Instance.new("UICorner")
					ac.CornerRadius = UDim.new(1, 0)
					ac.Parent = avatar
					local nameL = cell(200, 640, 38, Enum.Font.GothamBold, Enum.TextXAlignment.Left)
					local waveL = cell(850, 250, 38, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
					local ratingL = cell(1150, 320, 42, Enum.Font.GothamBlack, Enum.TextXAlignment.Right)
					table.insert(rows, { frame = rowF, rank = rank, avatar = avatar, name = nameL, wave = waveL, rating = ratingL, stroke = rs })
				end
				local n = Instance.new("TextLabel")
				n.Position = UDim2.fromOffset(40, 846)
				n.Size = UDim2.new(1, -80, 0, 40)
				n.BackgroundTransparency = 1
				n.Font = Enum.Font.Gotham
				n.TextSize = 26
				n.TextColor3 = Color3.fromRGB(140, 148, 138)
				n.Text = ""
				n.Parent = bg
				note = n
			end
			-- подсветка табло
			local lamp = bm:FindFirstChild("LightSource", true) :: BasePart?
			if lamp then
				lamp.Color = COL.warm
			end
		end
		-- фонари и мешки у табло
		put("Props.RoadLight", -34, 100, 0, { y = 0.4, scale = 0.6 })
		put("Props.RoadLight", 34, 100, 180, { y = 0.4, scale = 0.6 })
		put("Base.Fort", -52, 112, 90, { y = 0.2 })
		put("Base.Fort", 52, 112, 90, { y = 0.2 })
		local palette = { Color3.fromRGB(255, 208, 70), Color3.fromRGB(205, 210, 220), Color3.fromRGB(214, 140, 80) }
		-- табло лучших команд: рядом с Top survivors, лицом на север
		local squadRows: { TextLabel } = {}
		do
			local part = Instance.new("Part")
			part.Name = "SquadBoard"
			part.Anchored = true
			part.CanCollide = true
			part.Material = Enum.Material.SmoothPlastic
			part.Color = Color3.fromRGB(12, 16, 14)
			part.Size = Vector3.new(24, 12, 1)
			part.CFrame = CFrame.new(O + Vector3.new(-42, 7, 108)) -- лицевая сторона (Front) смотрит на -Z, к спавну
			part.Parent = root
			local gui = Instance.new("SurfaceGui")
			gui.Name = "SquadBoardGui"
			gui.Face = Enum.NormalId.Front
			gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
			gui.CanvasSize = Vector2.new(900, 450)
			gui.LightInfluence = 0
			gui.Brightness = 1.3
			gui.Parent = part
			local head = Instance.new("TextLabel")
			head.Size = UDim2.new(1, 0, 0, 80)
			head.BackgroundTransparency = 1
			head.Font = Enum.Font.Oswald
			head.TextSize = 58
			head.TextColor3 = Color3.fromRGB(255, 208, 70)
			head.Text = "TOP SQUADS"
			head.Parent = gui
			for r = 1, Config.Lobby.SquadBoardSize do
				local row = Instance.new("TextLabel")
				row.Position = UDim2.fromOffset(24, 80 + (r - 1) * 72)
				row.Size = UDim2.new(1, -48, 0, 66)
				row.BackgroundTransparency = 1
				row.Font = Enum.Font.GothamBold
				row.TextSize = 28
				row.TextWrapped = true
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.TextColor3 = palette[r] or Color3.fromRGB(232, 236, 228)
				row.Text = ""
				row.Parent = gui
				squadRows[r] = row
			end
		end
		boardView = {
			rig = rig,
			setSquad = function(rank: number, names: string?, wave: number, rating: number)
				local row = squadRows[rank]
				if row then
					row.Text = if names then string.format("%d. %s  ·  Night %d  ·  %d", rank, names, wave, rating) else ""
				end
			end,
			setRow = function(rank: number, entry: BoardEntry?)
				local row = rows[rank]
				if not row then
					return
				end
				local medal = palette[rank]
				row.stroke.Transparency = if entry and medal then 0.15 else 1
				if medal then
					row.stroke.Color = medal
					row.rank.TextColor3 = medal
					row.name.TextColor3 = if entry then medal else Color3.fromRGB(232, 236, 228)
				end
				if entry then
					row.name.Text = entry.name
					row.wave.Text = "Night " .. entry.wave
					row.rating.Text = string.format("%d", entry.rating)
					row.avatar.Visible = entry.image ~= nil
					row.avatar.Image = entry.image or ""
				else
					row.name.Text = ""
					row.wave.Text = ""
					row.rating.Text = ""
					row.avatar.Visible = false
				end
			end,
			setNote = function(text: string)
				if note then
					note.Text = text
				end
			end,
		}
	end

	-- ===== Название у входа =====
	sign("TitleSign", "DEAD NIGHT — CHECKPOINT 7", Vector3.new(60, 8, 1), at(0, 20, -108), 180, COL.gold, 30)
	box("TitlePostL", Vector3.new(1.4, 20, 1.4), at(-26, 10, -108), COL.dark, Enum.Material.Metal)
	box("TitlePostR", Vector3.new(1.4, 20, 1.4), at(26, 10, -108), COL.dark, Enum.Material.Metal)

	-- ===== Военные НПС: точки (ведёт LobbyNpcService) =====
	-- часовые у ворот и на площади
	table.insert(npcSpots, { kind = "guard", pos = at(132, 0, 22), yaw = 180, label = "Gate guard" })
	table.insert(npcSpots, { kind = "guard", pos = at(132, 0, 30), yaw = 0, label = "Gate guard" })
	table.insert(npcSpots, { kind = "guard", pos = at(-26, 0, 70), yaw = 0, label = "Guard" })
	table.insert(npcSpots, { kind = "guard", pos = at(26, 0, 70), yaw = 0, label = "Guard" })
	-- пара, разговаривающая у аллеи
	local chatA = #npcSpots + 1
	table.insert(npcSpots, { kind = "chat", pos = at(10, 0, -64), yaw = 90, partner = chatA + 1, label = "Soldier" })
	table.insert(npcSpots, { kind = "chat", pos = at(14, 0, -64), yaw = -90, partner = chatA, label = "Soldier" })
	-- патрули: дорога, аллея, площадь
	table.insert(npcSpots, { kind = "patrol", pos = at(-70, 0, 26), yaw = 90, route = { at(-70, 0, 26), at(70, 0, 26) }, label = "Patrol" })
	table.insert(npcSpots, { kind = "patrol", pos = at(0, 0, 10), yaw = 0, route = { at(0, 0, 10), at(0, 0, -62) }, label = "Patrol" })
	table.insert(npcSpots, { kind = "patrol", pos = at(-26, 0, 84), yaw = 0, route = { at(-26, 0, 84), at(26, 0, 84), at(26, 0, 44), at(-26, 0, 44) }, label = "Patrol" })

	root.Parent = workspace
	return {
		root = root,
		spawn = Config.Lobby.Spawn + O,
		zones = zones,
		board = boardView,
		soloPrompt = soloPrompt,
		menus = menus,
		npcSpots = npcSpots,
		npcFolder = npcF,
	}
end

return Lobby
