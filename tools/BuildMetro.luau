--!strict
-- Генератор сэмпл-локации «Метро» (Workspace.Metro). Запуск: Studio → Edit, execute_luau (или Command bar) с содержимым этого файла.
-- Планировка (локальные координаты, OY — высота «коробки» в небе над городом):
--   Главная станция: X −160…160, Z −38…38, три линии путей (z = −24, 0, 24), четыре платформы (две боковые и две островные),
--   билетный зал выше (лестница с северной платформы), служебная комната с автоматом, лестница на поверхность (люк-заглушка).
--   Тоннели: по 480 студов на запад (все три линии, обвал в конце) и на восток; средняя линия идёт на станцию B (x 640…800), двор
--   «за горой» — открытая площадка (ночь), дальше дорожный тоннель (x 800…1280) для езды на машине.
-- Маркеры (Workspace.Metro.Markers): Metro_Spawn, Metro_Exit, Metro_Boss, Metro_Vending, Metro_ZombieSpawn_n, Metro_Objective_n,
-- Metro_StationB_Spawn, Metro_StationB_Exit.
-- Все размеры — константы в начале; изменить и запустить заново (старая Workspace.Metro удаляется).

local OY = 600
local V = Vector3.new
local CONCRETE, DARK, SLATE = Color3.fromRGB(96, 98, 102), Color3.fromRGB(58, 60, 64), Color3.fromRGB(120, 120, 124)
local LINES = { -24, 0, 24 } -- оси путей
local STATION_HALF = 160 -- половина длины главной станции
local TUNNEL = 480 -- длина тоннелей
local ROOF_Y = 14

local old = workspace:FindFirstChild("Metro")
if old then
	old:Destroy()
end
local ROOT = Instance.new("Folder")
ROOT.Name = "Metro"
ROOT.Parent = workspace
local function folder(name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = ROOT
	return f
end
local Shell, Tunnels, Platform, Props, Lights, Markers, StationB = folder("Shell"), folder("Tunnels"), folder("Platform"), folder("Props"), folder("Lights"), folder("Markers"), folder("StationB")

local function part(parent: Instance, name: string, size: Vector3, x: number, y: number, z: number, color: Color3?, material: Enum.Material?, extra: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.new(x, OY + y, z)
	p.Color = color or CONCRETE
	p.Material = material or Enum.Material.Concrete
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in extra do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- Длинные детали режем на куски по CHUNK студов: навигационная сетка (PathfindingService) не строится на очень длинных деталях
local CHUNK = 100
local function longPart(parent: Instance, name: string, x0: number, x1: number, sizeY: number, sizeZ: number, y: number, z: number, color: Color3?, material: Enum.Material?)
	local x = x0
	while x < x1 - 0.01 do
		local len = math.min(CHUNK, x1 - x)
		part(parent, name, V(len, sizeY, sizeZ), x + len / 2, y, z, color, material)
		x += len
	end
end

local function track(parent: Instance, x0: number, x1: number, z: number, step: number)
	longPart(parent, "Rail", x0, x1, 0.35, 0.25, -2.15, z - 0.75, Color3.fromRGB(110, 90, 80), Enum.Material.Metal)
	longPart(parent, "Rail", x0, x1, 0.35, 0.25, -2.15, z + 0.75, Color3.fromRGB(110, 90, 80), Enum.Material.Metal)
	for x = x0 + 1, x1 - 1, step do
		part(parent, "Sleeper", V(0.7, 0.3, 4.6), x, -2.3, z, Color3.fromRGB(70, 50, 36), Enum.Material.Wood)
	end
end

local function lamp(x: number, y: number, z: number, color: Color3, brightness: number, range: number, on: boolean)
	local p = part(Lights, "Lamp", V(2, 0.4, 0.8), x, y, z, Color3.fromRGB(230, 235, 255), Enum.Material.Neon, { CanCollide = false })
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Enabled = on
	l.Parent = p
	if not on then
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(80, 80, 84)
	end
end

------------------------------------------------------------------------------------------------ главная станция
-- платформы (верх y = 0) и русла (верх пола −2,5)
local platforms = { { -38, -29 }, { -19, -5 }, { 5, 19 }, { 29, 38 } }
for i, pl in platforms do
	part(Platform, "Platform" .. i, V(STATION_HALF * 2, 2, pl[2] - pl[1]), 0, -1, (pl[1] + pl[2]) / 2, SLATE, Enum.Material.Slate)
	local edgeNear = pl[1]
	part(Platform, "EdgeStrip", V(STATION_HALF * 2 - 2, 0.15, 0.7), 0, 0.08, (i % 2 == 1) and pl[1] + 0.4 or pl[2] - 0.4, Color3.fromRGB(230, 190, 40), Enum.Material.SmoothPlastic)
end
for i, zt in LINES do
	part(Platform, "TrackBed" .. i, V(STATION_HALF * 2, 1, 10), 0, -3, zt, DARK, Enum.Material.Pebble)
	track(Platform, -STATION_HALF, STATION_HALF, zt, 4)
end

-- стены и потолок; торцевые стены с тремя проёмами тоннелей (14 шириной, до y = 6,5)
-- северная стена с проёмом лестницы (x 100…112), южная — с проёмом служебной комнаты (x −104…−96)
local W0, W1 = -STATION_HALF - 3, STATION_HALF + 3
part(Shell, "WallNorth", V(100 - W0, 17, 2), (W0 + 100) / 2, 6.5, 39, CONCRETE)
part(Shell, "WallNorth", V(W1 - 112, 17, 2), (112 + W1) / 2, 6.5, 39, CONCRETE)
part(Shell, "WallSouth", V(-104 - W0, 17, 2), (W0 - 104) / 2, 6.5, -39, CONCRETE)
part(Shell, "WallSouth", V(W1 + 96, 17, 2), (W1 - 96) / 2, 6.5, -39, CONCRETE)
part(Shell, "Roof", V(STATION_HALF * 2 + 6, 2, 80), 0, ROOF_Y, 0, DARK)
for _, side in { -1, 1 } do
	local x = side * (STATION_HALF + 1)
	local segs = { { -40, -31 }, { -17, -7 }, { 7, 17 }, { 31, 40 } }
	for _, s in segs do
		part(Shell, "EndWall", V(2, 17, s[2] - s[1]), x, 6.5, (s[1] + s[2]) / 2, CONCRETE)
	end
	for _, zt in LINES do
		part(Shell, "EndWallTop", V(2, 8.5, 14), x, 10.25, zt, CONCRETE)
	end
end

-- колонны, балки, скамейки
for x = -140, 140, 20 do
	for _, z in { -34, -12, 12, 34 } do
		part(Platform, "Pillar", V(1.6, 13, 1.6), x, 6.5, z, CONCRETE)
	end
	part(Shell, "CeilingBeam", V(1.4, 1.4, 78), x, 12.3, 0, Color3.fromRGB(78, 80, 84))
end
for _, z in { -36, -12, 12, 36 } do
	for x = -120, 120, 40 do
		part(Props, "BenchSeat", V(5, 0.4, 1.4), x + 6, 1.4, z + 1.8, Color3.fromRGB(96, 70, 48), Enum.Material.Wood)
		part(Props, "BenchLegL", V(0.4, 1.4, 1.2), x + 4, 0.7, z + 1.8, DARK, Enum.Material.Metal)
		part(Props, "BenchLegR", V(0.4, 1.4, 1.2), x + 8, 0.7, z + 1.8, DARK, Enum.Material.Metal)
	end
end
for _, z in { -37, 37 } do
	for _, x in { -100, 0, 100 } do
		part(Props, "Sign", V(12, 2.4, 0.3), x, 9, z, Color3.fromRGB(30, 80, 140), Enum.Material.SmoothPlastic, { CanCollide = false })
	end
end

-- застывший поезд на линии 3 (рядом с островной платформой): два вагона
for i, cx in { -70, -40 } do
	part(Props, "TrainCar" .. i, V(26, 8, 5.4), cx, 1.2, 24, Color3.fromRGB(70, 90, 110), Enum.Material.Metal)
	part(Props, "TrainRoof" .. i, V(26, 0.6, 5.0), cx, 5.5, 24, Color3.fromRGB(50, 56, 64), Enum.Material.Metal)
	for w = -10, 10, 5 do
		part(Props, "TrainWindow", V(3, 2, 5.6), cx + w, 2.2, 24, Color3.fromRGB(20, 30, 40), Enum.Material.Glass, { Transparency = 0.35, CanCollide = false })
	end
end
-- и на линии 1 один вагон-укрытие
part(Props, "TrainCar3", V(26, 8, 5.4), 60, 1.2, -24, Color3.fromRGB(110, 70, 60), Enum.Material.Metal)
part(Props, "TrainRoof3", V(26, 0.6, 5.0), 60, 5.5, -24, Color3.fromRGB(60, 50, 48), Enum.Material.Metal)

-- пандусы-переходы через русла на обоих концах (X = ±150): с каждой стороны каждой линии
local rlen = math.sqrt(5 ^ 2 + 2.5 ^ 2)
local rang = math.atan2(2.5, 5)
for _, x in { -150, 150 } do
	for _, zt in LINES do
		part(Platform, "Ramp", V(6, 0.5, rlen), x, -1.25, zt + 2.5, SLATE, Enum.Material.Slate, { CFrame = CFrame.new(x, OY - 1.25, zt + 2.5) * CFrame.Angles(rang, 0, 0) })
		part(Platform, "Ramp", V(6, 0.5, rlen), x, -1.25, zt - 2.5, SLATE, Enum.Material.Slate, { CFrame = CFrame.new(x, OY - 1.25, zt - 2.5) * CFrame.Angles(-rang, 0, 0) })
	end
end

-- лестница из станции в билетный зал (проём в северной стене x 100…112), 13 ступеней → y = 13
part(Shell, "StairLintel", V(12, 5, 2), 106, 11.5, 39, CONCRETE)
part(Shell, "DoorFloorStairs", V(12, 2, 2), 106, -1, 39, SLATE, Enum.Material.Slate)
for i = 0, 12 do
	part(Platform, "Step", V(12, 1.0, 1.15), 106, (i + 1) * 1.0 - 0.5, 40.6 + i * 1.15, Color3.fromRGB(118, 118, 122), Enum.Material.Slate)
end
-- зал: x 76…136, z 55…111 (внутренний), пол y = 13
part(Shell, "HallFloor", V(60, 1, 56), 106, 12.5, 83, SLATE, Enum.Material.Slate)
part(Shell, "HallFloorFront", V(60, 1, 8), 106, 12.5, 51, SLATE, Enum.Material.Slate, { CanCollide = false, Transparency = 1 })
part(Shell, "HallFloorCutL", V(24, 1, 8), 88, 12.5, 55, SLATE, Enum.Material.Slate)
part(Shell, "HallFloorCutR", V(24, 1, 8), 124, 12.5, 55, SLATE, Enum.Material.Slate)
part(Shell, "HallWallW", V(1.5, 18, 56), 76, 21.5, 83, CONCRETE)
part(Shell, "HallWallE", V(1.5, 18, 56), 136, 21.5, 83, CONCRETE)
part(Shell, "HallWallN", V(62, 18, 1.5), 106, 21.5, 111, CONCRETE)
part(Shell, "HallWallS_L", V(21, 18, 1.5), 86.5, 21.5, 55.5, CONCRETE)
part(Shell, "HallWallS_R", V(21, 18, 1.5), 125.5, 21.5, 55.5, CONCRETE)
part(Shell, "HallRoof", V(62, 1.5, 58), 106, 30.5, 83, DARK)
for i = 0, 3 do
	part(Props, "Turnstile", V(0.5, 3, 3), 92 + i * 9, 14.5, 70, Color3.fromRGB(150, 150, 154), Enum.Material.Metal)
	part(Props, "TurnstileBar", V(2.4, 0.3, 0.3), 92 + i * 9, 15.2, 70, Color3.fromRGB(200, 200, 204), Enum.Material.Metal)
end
part(Props, "TicketBooth", V(8, 5, 4), 92, 15, 100, Color3.fromRGB(100, 80, 60), Enum.Material.Wood)
part(Props, "Newsstand", V(6, 4, 3), 82, 14.5, 100, Color3.fromRGB(120, 60, 50), Enum.Material.Wood)
-- выход на поверхность: ступени вдоль восточной стены, площадка, люк в потолке
for i = 0, 9 do
	part(Props, "ExitStep", V(8, 0.8, 1.6), 128, 13.4 + i * 0.8, 106 - i * 1.6, Color3.fromRGB(118, 118, 122), Enum.Material.Slate)
end
part(Props, "ExitLanding", V(10, 1, 10), 128, 20.5, 85.5, Color3.fromRGB(110, 110, 114), Enum.Material.Slate)
part(Props, "ExitHatch", V(6, 0.5, 6), 128, 29.6, 85.5, Color3.fromRGB(60, 56, 50), Enum.Material.DiamondPlate, { CanCollide = false })

-- служебная комната (южная стена, проём x −104…−96): комната z −40…−84, x −120…−80
part(Shell, "ServiceDoorTop", V(8, 5, 2), -100, 11.5, -39, CONCRETE)
part(Shell, "DoorFloorService", V(8, 2, 2), -100, -1, -39, SLATE, Enum.Material.Slate)
part(Shell, "ServiceFloor", V(40, 1, 44), -100, -0.5, -62, DARK)
part(Shell, "ServiceWallW", V(1, 9, 44), -120.5, 4.5, -62, CONCRETE)
part(Shell, "ServiceWallE", V(1, 9, 44), -79.5, 4.5, -62, CONCRETE)
part(Shell, "ServiceWallS", V(42, 9, 1), -100, 4.5, -84.5, CONCRETE)
part(Shell, "ServiceRoof", V(42, 1, 46), -100, 9.5, -62, DARK)
for i = 1, 6 do
	part(Props, "ServiceCrate", V(2.6, 2.6, 2.6), -116 + i * 3, 1.3, -80, Color3.fromRGB(110, 86, 52), Enum.Material.Wood)
end
part(Props, "ServiceShelf", V(14, 6, 1.2), -90, 3, -83, Color3.fromRGB(70, 72, 76), Enum.Material.Metal)
part(Props, "ServiceDesk", V(5, 2.6, 2.4), -112, 1.3, -52, Color3.fromRGB(90, 70, 50), Enum.Material.Wood)

------------------------------------------------------------------------------------------------ тоннели
local function tube(parent: Instance, x0: number, x1: number, zt: number, floorMat: Enum.Material?)
	longPart(parent, "TunnelFloor", x0, x1, 1, 14, -3, zt, DARK, floorMat or Enum.Material.Pebble)
	longPart(parent, "TunnelWallN", x0, x1, 11, 1.2, 2.5, zt + 7.6, CONCRETE)
	longPart(parent, "TunnelWallS", x0, x1, 11, 1.2, 2.5, zt - 7.6, CONCRETE)
	longPart(parent, "TunnelRoof", x0, x1, 1.2, 16.4, 8.1, zt, DARK)
end
local function rubbleCap(parent: Instance, x: number, zt: number, dir: number)
	part(parent, "CollapseWall", V(2, 12, 16), x, 3, zt, DARK)
	for i = 1, 14 do
		part(parent, "Rubble", V(2 + (i * 7 % 5) * 0.8, 1.5 + (i * 3 % 4) * 0.7, 2 + (i * 5 % 4)), x - dir * (1 + (i % 4) * 1.6), -2 + (i * 3 % 4) * 0.5, zt - 6 + i * 0.85, Color3.fromRGB(88, 84, 78), Enum.Material.Slate, { Orientation = V(0, i * 37 % 90, i * 11 % 20) })
	end
end
for _, zt in LINES do
	-- запад: все три линии, обвал в конце
	tube(Tunnels, -STATION_HALF - TUNNEL, -STATION_HALF, zt)
	track(Tunnels, -STATION_HALF - TUNNEL, -STATION_HALF, zt, 6)
	rubbleCap(Tunnels, -STATION_HALF - TUNNEL - 1, zt, -1)
	-- восток: линии 1 и 3 заканчиваются обвалом, линия 2 идёт на станцию B
	if zt ~= 0 then
		tube(Tunnels, STATION_HALF, STATION_HALF + TUNNEL, zt)
		track(Tunnels, STATION_HALF, STATION_HALF + TUNNEL, zt, 6)
		rubbleCap(Tunnels, STATION_HALF + TUNNEL + 1, zt, 1)
	end
end
tube(Tunnels, STATION_HALF, STATION_HALF + TUNNEL, 0)
track(Tunnels, STATION_HALF, STATION_HALF + TUNNEL, 0, 6)

------------------------------------------------------------------------------------------------ станция B (за горой) и двор
local BX0, BX1 = STATION_HALF + TUNNEL, STATION_HALF + TUNNEL + 160 -- 640…800
local bc = (BX0 + BX1) / 2
part(StationB, "PlatformN", V(160, 2, 14), bc, -1, 12, SLATE, Enum.Material.Slate)
part(StationB, "PlatformS", V(160, 2, 14), bc, -1, -12, SLATE, Enum.Material.Slate)
part(StationB, "TrackBed", V(160, 1, 10), bc, -3, 0, DARK, Enum.Material.Pebble)
track(StationB, BX0, BX1, 0, 4)
part(StationB, "WallN", V(760 - (BX0 - 1), 17, 2), ((BX0 - 1) + 760) / 2, 6.5, 20, CONCRETE) -- проём лестницы во двор: x 760…772
part(StationB, "WallN", V((BX1 + 1) - 772, 17, 2), (772 + (BX1 + 1)) / 2, 6.5, 20, CONCRETE)
part(StationB, "WallS", V(162, 17, 2), bc, 6.5, -20, CONCRETE)
part(StationB, "Roof", V(162, 2, 42), bc, ROOF_Y, 0, DARK)
for x = BX0 + 20, BX1 - 20, 20 do
	part(StationB, "Pillar", V(1.6, 13, 1.6), x, 6.5, 12, CONCRETE)
	part(StationB, "Pillar", V(1.6, 13, 1.6), x, 6.5, -12, CONCRETE)
end
-- торцы B: западный (с тоннелем линии 2) и восточный (дорожный тоннель)
for _, x in { BX0 - 1, BX1 + 1 } do
	part(StationB, "EndWall", V(2, 17, 13), x, 6.5, 13.5, CONCRETE)
	part(StationB, "EndWall", V(2, 17, 13), x, 6.5, -13.5, CONCRETE)
	part(StationB, "EndWallTop", V(2, 8.5, 14), x, 10.25, 0, CONCRETE)
end
-- лестница с северной платформы во двор (проём x 760…772 в северной стене), двор на y = 13
part(StationB, "StairLintel", V(12, 5, 2), 766, 11.5, 20, CONCRETE)
part(StationB, "DoorFloor", V(12, 2, 2), 766, -1, 20, SLATE, Enum.Material.Slate)
for i = 0, 12 do
	part(StationB, "Step", V(12, 1.0, 1.15), 766, (i + 1) * 1.0 - 0.5, 21.6 + i * 1.15, Color3.fromRGB(118, 118, 122), Enum.Material.Slate)
end
-- двор: открытая площадка 180 × 120 на уровне 13 (небо над головой, ночь), ограда с трёх сторон
part(StationB, "YardGround", V(180, 1, 100), 740, 12.5, 86, Color3.fromRGB(70, 74, 70), Enum.Material.Concrete)
part(StationB, "YardFenceN", V(180, 6, 1.5), 740, 16.5, 136, DARK, Enum.Material.Metal)
part(StationB, "YardFenceW", V(1.5, 6, 100), 650.5, 16.5, 86, DARK, Enum.Material.Metal)
part(StationB, "YardFenceE", V(1.5, 6, 100), 829.5, 16.5, 86, DARK, Enum.Material.Metal)
part(StationB, "YardFenceS_L", V(110, 6, 1.5), 705, 16.5, 36.5, DARK, Enum.Material.Metal)
part(StationB, "YardFenceS_R", V(52, 6, 1.5), 803, 16.5, 36.5, DARK, Enum.Material.Metal)
-- «гора» в конце двора (декор-заглушка, высокая стена: дальше дороги нет)
part(StationB, "MountainWall", V(180, 60, 4), 740, 44, 138, Color3.fromRGB(80, 78, 74), Enum.Material.Slate)
for i = 1, 6 do
	part(StationB, "YardCrate", V(3, 3, 3), 690 + i * 14, 14.5, 90 + (i % 3) * 8, Color3.fromRGB(110, 86, 52), Enum.Material.Wood)
end
part(StationB, "YardTruck", V(7, 6, 18), 770, 16, 120, Color3.fromRGB(60, 70, 60), Enum.Material.Metal)

-- восточный торец станции B закрыт (дорожного тоннеля нет: по замыслу Руслана машина нужна в другом месте)
part(StationB, "EndWallSealed", V(2, 11, 14), BX1 + 1, 3, 0, CONCRETE)

------------------------------------------------------------------------------------------------ свет
for x = -150, 150, 25 do
	for i, z in { -33, -12, 12, 33 } do
		lamp(x, 12.3, z, Color3.fromRGB(190, 210, 255), 0.9, 22, ((x // 25) + i) % 3 ~= 0)
	end
end
lamp(106, 28.5, 83, Color3.fromRGB(190, 210, 255), 0.9, 26, true)
lamp(-100, 8.4, -62, Color3.fromRGB(255, 190, 120), 0.8, 18, true)
local function tunnelLights(x0: number, x1: number, zt: number)
	local k = 0
	for x = x0, x1, 40 do
		k += 1
		lamp(x, 7.2, zt, Color3.fromRGB(255, 70, 50), 0.7, 18, k % 3 == 1)
	end
end
for _, zt in LINES do
	tunnelLights(-STATION_HALF - TUNNEL + 20, -STATION_HALF - 40, zt)
end
tunnelLights(STATION_HALF + 40, BX0 - 20, 0)
tunnelLights(STATION_HALF + 40, STATION_HALF + TUNNEL - 20, -24)
tunnelLights(STATION_HALF + 40, STATION_HALF + TUNNEL - 20, 24)
for x = BX0 + 20, BX1 - 20, 30 do
	lamp(x, 12.3, 0, Color3.fromRGB(190, 210, 255), 0.9, 22, (x // 30) % 2 == 0)
end

------------------------------------------------------------------------------------------------ маркеры
local function marker(name: string, x: number, y: number, z: number, color: Color3, look: Vector3?)
	local p = part(Markers, name, V(4, 1, 4), x, y, z, color, Enum.Material.SmoothPlastic, { Transparency = 0.6, CanCollide = false, CanQuery = false, CanTouch = false })
	if look then
		p.CFrame = CFrame.lookAt(p.Position, p.Position + look)
	end
end
marker("Metro_Spawn", 106, 0.6, 33, Color3.fromRGB(80, 220, 120), V(0, 0, -1)) -- появление команды: северная платформа у лестницы
marker("Metro_Exit", 128, 21.5, 85.5, Color3.fromRGB(80, 160, 255)) -- верх лестницы зала: выход на поверхность
marker("Metro_Boss", -10, 0.6, 0, Color3.fromRGB(255, 70, 70)) -- островная платформа посередине
marker("Metro_Vending", -84, 0.6, -62, Color3.fromRGB(80, 200, 255), V(-1, 0, 0)) -- автомат в служебной комнате
local zi = 0
local spawnsList = {
	{ -632, -1.5, -24 }, { -632, -1.5, 0 }, { -632, -1.5, 24 }, { 632, -1.5, -24 }, { 632, -1.5, 24 },
	{ -400, -1.5, 0 }, { 400, -1.5, 0 }, { -250, -1.5, -24 }, { 250, -1.5, 24 }, { -70, 0.6, -34 }, { 70, 0.6, 34 },
	{ 700, -1.5, 0 }, { 740, 14, 100 },
}
for _, p in spawnsList do
	zi += 1
	-- в месте точка двора (13-я) называется _14 (номер 13 не используется) — как в игре
	marker("Metro_ZombieSpawn_" .. (if zi == 13 then 14 else zi), p[1], p[2], p[3], Color3.fromRGB(230, 120, 40))
end
for i, p in { { -600, -1.5, 0 }, { 600, -1.5, -24 }, { -100, 0.6, -50 } } do
	marker("Metro_Objective_" .. i, p[1], p[2], p[3], Color3.fromRGB(200, 80, 220)) -- гнёзда и цели зачистки
end
marker("Metro_StationB_Spawn", 700, 0.6, 12, Color3.fromRGB(80, 220, 120), V(1, 0, 0)) -- прибытие на станцию B
marker("Metro_StationB_Exit", 740, 14, 40, Color3.fromRGB(80, 160, 255)) -- двор (выход «за горой»)
-- ящики с патронами (AmmoCrateService ставит ящики по этим маркерам): двор у разбитого поезда и платформа линии 1 (позиции прочитаны из места 2026-10-25)
for _, a in { { "AmmoCrate_1", 740, 13.5, 112, V(0, 0, -1) }, { "AmmoCrate_2", 0, 0.5, -34, V(0, 0, 1) } } do
	local p = part(Markers, a[1], V(3.2, 1, 2.2), a[2], a[3], a[4], Color3.fromRGB(90, 200, 90), Enum.Material.Plastic, { Transparency = 0.6, CanCollide = false, CanQuery = false, CanTouch = false })
	p.CFrame = CFrame.lookAt(p.Position, p.Position + a[5])
end

local count = 0
for _, d in ROOT:GetDescendants() do
	if d:IsA("BasePart") then
		count += 1
	end
end
return "Metro built: parts=" .. count
