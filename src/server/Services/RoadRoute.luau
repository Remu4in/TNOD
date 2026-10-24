--!strict
-- Маршруты по дорогам для конвоя (ConvoyService, MissionService). Дорога — это то, на что попадает луч сверху вниз и что лежит
-- в Workspace.Roads (ровная поверхность); крыши, машины, деревья и всё, что стоит над дорогой, клетку закрывают.
-- Карта режется на клетки CELL студов; клетка проходима, если дорога под ней и под четырьмя соседними (запас на ширину грузовика).
-- Поиск — A* по 8 соседям без срезания углов, клетки проверяются лениво (один луч на клетку за поиск).
-- Прямой линии через здания не бывает: нет пути — nil.

local Players = game:GetService("Players")

local RoadRoute = {}

local CELL = 6
local MARGIN = 1500 -- насколько поиск может выйти за прямоугольник «откуда–куда» (объезды по дорогам бывают длинными)
local MAX_NODES = 60000
local EXCLUDE_FOLDERS = { "Zombies", "Convoy", "MissionObjects", "Soldiers", "MilitaryVehicles" } -- движущееся и временное дорогу не закрывает

export type Grid = {
	snap: (pos: Vector3, maxDist: number) -> Vector3?,
	find: (from: Vector3, to: Vector3) -> { Vector3 }?,
}

local function cellKey(ix: number, iz: number): number
	return (ix + 32768) * 65536 + (iz + 32768)
end

local function cellCenter(ix: number, iz: number): (number, number)
	return (ix + 0.5) * CELL, (iz + 0.5) * CELL
end

local function cellOf(pos: Vector3): (number, number)
	return math.floor(pos.X / CELL), math.floor(pos.Z / CELL)
end

-- Новая сетка: кэш клеток живёт, пока жива сетка (дороги не меняются, а препятствия на момент планирования нам и нужны)
function RoadRoute.grid(): Grid
	local roads = workspace:FindFirstChild("Roads")
	local exclude: { Instance } = {}
	for _, name in EXCLUDE_FOLDERS do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude

	local roadCache: { [number]: boolean } = {}
	local heightCache: { [number]: number } = {}
	local walkCache: { [number]: boolean } = {}

	local function isRoad(ix: number, iz: number): boolean
		local k = cellKey(ix, iz)
		local cached = roadCache[k]
		if cached ~= nil then
			return cached
		end
		local result = false
		if roads then
			local x, z = cellCenter(ix, iz)
			local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0), params)
			if hit and hit.Normal.Y > 0.85 and hit.Instance:IsDescendantOf(roads) then
				result = true
				heightCache[k] = hit.Position.Y
			end
		end
		roadCache[k] = result
		return result
	end

	local function walkable(ix: number, iz: number): boolean
		local k = cellKey(ix, iz)
		local cached = walkCache[k]
		if cached ~= nil then
			return cached
		end
		local ok = isRoad(ix, iz) and isRoad(ix + 1, iz) and isRoad(ix - 1, iz) and isRoad(ix, iz + 1) and isRoad(ix, iz - 1)
		walkCache[k] = ok
		return ok
	end

	local function point(ix: number, iz: number): Vector3
		local x, z = cellCenter(ix, iz)
		return Vector3.new(x, heightCache[cellKey(ix, iz)] or 0, z)
	end

	local grid = {} :: Grid

	-- Ближайшая проходимая клетка в пределах maxDist студов (кольцами вокруг pos)
	function grid.snap(pos: Vector3, maxDist: number): Vector3?
		local cx, cz = cellOf(pos)
		local rings = math.ceil(maxDist / CELL)
		for r = 0, rings do
			local best: Vector3? = nil
			local bestD = math.huge
			for dx = -r, r do
				for dz = -r, r do
					if math.max(math.abs(dx), math.abs(dz)) == r and walkable(cx + dx, cz + dz) then
						local p = point(cx + dx, cz + dz)
						local d = Vector3.new(p.X - pos.X, 0, p.Z - pos.Z).Magnitude
						if d < bestD and d <= maxDist then
							best, bestD = p, d
						end
					end
				end
			end
			if best then
				return best
			end
		end
		return nil
	end

	-- A*: путь между клетками, ближайшими к from и to (в пределах 40 студов); nil — пути нет
	function grid.find(from: Vector3, to: Vector3): { Vector3 }?
		local a, b = grid.snap(from, 40), grid.snap(to, 40)
		if not a or not b then
			return nil
		end
		local ax, az = cellOf(a)
		local bx, bz = cellOf(b)
		local minX, maxX = math.min(ax, bx) - MARGIN // CELL, math.max(ax, bx) + MARGIN // CELL
		local minZ, maxZ = math.min(az, bz) - MARGIN // CELL, math.max(az, bz) + MARGIN // CELL

		-- двоичная куча по f
		local heap: { number } = {} -- ключи клеток
		local fScore: { [number]: number } = {}
		local gScore: { [number]: number } = {}
		local cameFrom: { [number]: number } = {}
		local closed: { [number]: boolean } = {}
		local cx: { [number]: number } = {}
		local cz: { [number]: number } = {}

		local function push(k: number)
			table.insert(heap, k)
			local i = #heap
			while i > 1 do
				local parent = i // 2
				if fScore[heap[parent]] <= fScore[heap[i]] then
					break
				end
				heap[parent], heap[i] = heap[i], heap[parent]
				i = parent
			end
		end
		local function pop(): number
			local top = heap[1]
			local last = table.remove(heap) :: number
			if #heap > 0 then
				heap[1] = last
				local i = 1
				while true do
					local l, r, s = i * 2, i * 2 + 1, i
					if l <= #heap and fScore[heap[l]] < fScore[heap[s]] then
						s = l
					end
					if r <= #heap and fScore[heap[r]] < fScore[heap[s]] then
						s = r
					end
					if s == i then
						break
					end
					heap[s], heap[i] = heap[i], heap[s]
					i = s
				end
			end
			return top
		end
		local function h(ix: number, iz: number): number
			local dx, dz = math.abs(ix - bx), math.abs(iz - bz)
			return (math.max(dx, dz) + 0.4142 * math.min(dx, dz)) * CELL
		end

		local startKey, goalKey = cellKey(ax, az), cellKey(bx, bz)
		gScore[startKey] = 0
		fScore[startKey] = h(ax, az)
		cx[startKey], cz[startKey] = ax, az
		push(startKey)
		local nodes = 0
		while #heap > 0 and nodes < MAX_NODES do
			local k = pop()
			if closed[k] then
				continue
			end
			closed[k] = true
			nodes += 1
			if k == goalKey then
				-- восстановление пути с выбрасыванием точек на прямых отрезках
				local cells: { number } = { k }
				local cur = k
				while cameFrom[cur] do
					cur = cameFrom[cur]
					table.insert(cells, 1, cur)
				end
				local result: { Vector3 } = {}
				local lastDx: number?, lastDz: number? = nil, nil
				for i, key in cells do
					local x, z = cx[key], cz[key]
					local nextKey = cells[i + 1]
					local dx, dz = 0, 0
					if nextKey then
						dx, dz = cx[nextKey] - x, cz[nextKey] - z
					end
					if i == 1 or not nextKey or dx ~= lastDx or dz ~= lastDz then
						table.insert(result, point(x, z))
					end
					lastDx, lastDz = dx, dz
				end
				return result
			end
			local x, z = cx[k], cz[k]
			for dx = -1, 1 do
				for dz = -1, 1 do
					if dx ~= 0 or dz ~= 0 then
						local nx, nz = x + dx, z + dz
						if nx >= minX and nx <= maxX and nz >= minZ and nz <= maxZ and walkable(nx, nz) then
							-- по диагонали — только если оба боковых соседа проходимы (углы не срезаем)
							if dx == 0 or dz == 0 or (walkable(x + dx, z) and walkable(x, z + dz)) then
								local nk = cellKey(nx, nz)
								if not closed[nk] then
									local g = gScore[k] + (if dx ~= 0 and dz ~= 0 then 1.4142 else 1) * CELL
									local old = gScore[nk]
									if not old or g < old then
										gScore[nk] = g
										fScore[nk] = g + h(nx, nz)
										cameFrom[nk] = k
										cx[nk], cz[nk] = nx, nz
										push(nk)
									end
								end
							end
						end
					end
				end
			end
		end
		return nil
	end

	return grid
end

return RoadRoute
