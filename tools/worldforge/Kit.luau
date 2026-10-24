--!strict
-- WorldForge Kit — примитивы процедурной сборки локации (обобщено из examples/BuildMetro.luau и DressMetro.luau).
-- Только Edit-режим Studio (execute_luau или Command bar). Координаты — локальные относительно origin (только сдвиг).
-- Пример:
--   local kit = Kit.new({ name = "Metro", origin = Vector3.new(0, 600, 0), seed = 42 })
--   local shell = kit.folder("Shell")
--   kit.longPart(shell, "Floor", "X", -160, 160, 2, 14, -1, 0)
--   kit.wallWithOpenings(shell, "WallN", "X", -163, 163, 39, 0, 17, 2, { { from = 100, to = 112, top = 9 } })
--   return kit.report()

local Kit = {}

export type Options = {
	name: string, -- имя корневой папки
	parent: Instance?, -- по умолчанию workspace
	origin: Vector3?, -- сдвиг всей локации
	chunk: number?, -- макс. длина детали (навмеш), по умолчанию 100
	seed: number?, -- seed случайности (фиксированный → воспроизводимая расстановка)
	color: Color3?, -- цвет по умолчанию
	material: Enum.Material?, -- материал по умолчанию
	keepExisting: boolean?, -- true: не удалять старый корень (дополнять)
}

export type Opening = { from: number, to: number, top: number, sill: number? }

-- Габариты Instance по осям мира (все BasePart внутри)
function Kit.aabb(m: Instance): (Vector3, Vector3)
	local V = Vector3.new
	local minV, maxV = V(math.huge, math.huge, math.huge), V(-math.huge, -math.huge, -math.huge)
	local list: { Instance } = if m:IsA("BasePart") then { m } else m:GetDescendants()
	for _, d in list do
		if d:IsA("BasePart") then
			local cf, s = d.CFrame, d.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local p = cf:PointToWorldSpace(V(sx * s.X, sy * s.Y, sz * s.Z))
						minV = V(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z))
						maxV = V(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z))
					end
				end
			end
		end
	end
	return minV, maxV
end

function Kit.new(opts: Options)
	local V = Vector3.new
	local O = opts.origin or Vector3.zero
	local CHUNK = opts.chunk or 100
	local DEF_COLOR = opts.color or Color3.fromRGB(96, 98, 102)
	local DEF_MAT = opts.material or Enum.Material.Concrete
	local parentOf = opts.parent or workspace

	local root = parentOf:FindFirstChild(opts.name)
	if root and not opts.keepExisting then
		root:Destroy()
		root = nil
	end
	if not root then
		local f = Instance.new("Folder")
		f.Name = opts.name
		f.Parent = parentOf
		root = f
	end
	local ROOT = root :: Instance

	local self = {}
	self.root = ROOT
	self.origin = O
	self.rng = Random.new(opts.seed or 42)

	function self.folder(name: string, parent: Instance?): Instance
		local p = parent or ROOT
		local f = p:FindFirstChild(name)
		if not f then
			local nf = Instance.new("Folder")
			nf.Name = name
			nf.Parent = p
			f = nf
		end
		return f :: Instance
	end

	-- Деталь с центром в (x, y, z) локально; extra — любые свойства (CanCollide, Transparency, Shape, Orientation…)
	function self.part(parent: Instance, name: string, size: Vector3, x: number, y: number, z: number, color: Color3?, material: Enum.Material?, extra: { [string]: any }?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = CFrame.new(O.X + x, O.Y + y, O.Z + z)
		p.Color = color or DEF_COLOR
		p.Material = material or DEF_MAT
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

	-- Длинная деталь вдоль оси X или Z от a0 до a1, порезанная на куски по CHUNK
	-- (навмеш Roblox не строится на очень больших деталях). c — координата по другой горизонтальной оси.
	function self.longPart(parent: Instance, name: string, axis: string, a0: number, a1: number, sizeY: number, sizeCross: number, y: number, c: number, color: Color3?, material: Enum.Material?, extra: { [string]: any }?)
		local a = a0
		while a < a1 - 0.01 do
			local len = math.min(CHUNK, a1 - a)
			if axis == "X" then
				self.part(parent, name, V(len, sizeY, sizeCross), a + len / 2, y, c, color, material, extra)
			else
				self.part(parent, name, V(sizeCross, sizeY, len), c, y, a + len / 2, color, material, extra)
			end
			a += len
		end
	end

	-- Пол-прямоугольник любого размера, порезанный сеткой CHUNK×CHUNK. Верх пола = topY.
	function self.floor(parent: Instance, name: string, x0: number, x1: number, z0: number, z1: number, topY: number, thickness: number, color: Color3?, material: Enum.Material?)
		local x = x0
		while x < x1 - 0.01 do
			local lx = math.min(CHUNK, x1 - x)
			local z = z0
			while z < z1 - 0.01 do
				local lz = math.min(CHUNK, z1 - z)
				self.part(parent, name, V(lx, thickness, lz), x + lx / 2, topY - thickness / 2, z + lz / 2, color, material)
				z += lz
			end
			x += lx
		end
	end

	-- Стена вдоль оси (X или Z) от a0 до a1 с явными проёмами. Низ стены y0, высота h, толщина t, c — координата по другой оси.
	-- Каждый проём: from..to по оси стены, top — верх проёма (локальный Y), sill — толщина порога-пола под проёмом
	-- (по умолчанию 2: под проёмом всегда нужен пол, иначе навмеш рвётся).
	function self.wallWithOpenings(parent: Instance, name: string, axis: string, a0: number, a1: number, c: number, y0: number, h: number, t: number, openings: { Opening }, color: Color3?, material: Enum.Material?)
		table.sort(openings, function(p: Opening, q: Opening)
			return p.from < q.from
		end)
		local function seg(s0: number, s1: number, b: number, top: number, nm: string)
			if s1 - s0 < 0.01 or top - b < 0.01 then
				return
			end
			local len, hh = s1 - s0, top - b
			if axis == "X" then
				self.part(parent, nm, V(len, hh, t), (s0 + s1) / 2, b + hh / 2, c, color, material)
			else
				self.part(parent, nm, V(t, hh, len), c, b + hh / 2, (s0 + s1) / 2, color, material)
			end
		end
		local cur = a0
		for _, o in openings do
			seg(cur, o.from, y0, y0 + h, name)
			seg(o.from, o.to, o.top, y0 + h, name .. "Lintel")
			local sill = o.sill or 2
			if sill > 0 then
				seg(o.from, o.to, y0 - sill, y0, name .. "DoorFloor")
			end
			cur = o.to
		end
		seg(cur, a1, y0, y0 + h, name)
	end

	-- Цилиндр (трубы, бочки, урны). axis: "X" (по умолчанию), "Y" (стоит вертикально), "Z"
	function self.cylinder(parent: Instance, name: string, length: number, diameter: number, x: number, y: number, z: number, color: Color3?, axis: string?, material: Enum.Material?): Part
		local p = self.part(parent, name, V(length, diameter, diameter), x, y, z, color, material or Enum.Material.Metal, { Shape = Enum.PartType.Cylinder })
		local pos = CFrame.new(O.X + x, O.Y + y, O.Z + z)
		if axis == "Y" then
			p.CFrame = pos * CFrame.Angles(0, 0, math.rad(90))
		elseif axis == "Z" then
			p.CFrame = pos * CFrame.Angles(0, math.rad(90), 0)
		end
		return p
	end

	-- Точечный свет-«лампа». on=false — погашенная (для атмосферы)
	function self.lamp(parent: Instance, x: number, y: number, z: number, color: Color3, brightness: number, range: number, on: boolean?, size: Vector3?): Part
		local lit = on ~= false
		local p = self.part(parent, "Lamp", size or V(2, 0.4, 0.8), x, y, z, if lit then Color3.fromRGB(230, 235, 255) else Color3.fromRGB(80, 80, 84), if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic, { CanCollide = false })
		local l = Instance.new("PointLight")
		l.Color = color
		l.Brightness = brightness
		l.Range = range
		l.Enabled = lit
		l.Parent = p
		return p
	end

	-- Поставить клон готовой модели: центр (x, z), низ на bottomY (локально), поворот вокруг Y
	function self.put(src: Instance, parent: Instance, name: string, x: number, bottomY: number, z: number, yawDeg: number?): Instance
		local c = src:Clone()
		c.Name = name
		c.Parent = parent
		local a, b = Kit.aabb(c)
		local center = (a + b) / 2
		local rot = CFrame.new(center) * CFrame.Angles(0, math.rad(yawDeg or 0), 0) * CFrame.new(-center)
		if c:IsA("Model") then
			c:PivotTo(rot * c:GetPivot())
		elseif c:IsA("BasePart") then
			c.CFrame = rot * c.CFrame
		end
		a, b = Kit.aabb(c)
		center = (a + b) / 2
		local target = V(O.X + x, O.Y + bottomY + (b.Y - a.Y) / 2, O.Z + z)
		if c:IsA("Model") then
			c:PivotTo(c:GetPivot() + (target - center))
		elseif c:IsA("BasePart") then
			c.CFrame += target - center
		end
		return c
	end

	-- Маркер геймплея (полупрозрачная плитка, без коллизий); look — направление взгляда
	function self.marker(name: string, x: number, y: number, z: number, color: Color3, look: Vector3?): Part
		local p = self.part(self.folder("Markers"), name, V(4, 1, 4), x, y, z, color, Enum.Material.SmoothPlastic, { Transparency = 0.6, CanCollide = false, CanQuery = false, CanTouch = false })
		if look then
			p.CFrame = CFrame.lookAt(p.Position, p.Position + look)
		end
		return p
	end

	-- Итог для вывода execute_luau
	function self.report(): string
		local parts, meshes = 0, 0
		for _, d in ROOT:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
				if d:IsA("MeshPart") then
					meshes += 1
				end
			end
		end
		return string.format("%s built: parts=%d meshes=%d", ROOT.Name, parts, meshes)
	end

	return self
end

return Kit
