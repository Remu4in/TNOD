-- «Печь ассетов» (копия для репозитория; в Studio лежит как ServerStorage.Tools.Baker, только Edit-режим).
-- LoadAsset / клон из карантина → вычистка скриптов и опасных носителей → замеры по осям мира и уровень земли →
-- чистая модель в ServerStorage.Assets.<папка>.<имя>.
-- Пример: require(game.ServerStorage.Tools.Baker).bake("Buildings", "Cafe", 71270377535225)
-- Порядок: сначала проверка скиллом asset-vetting (ServerStorage.Tools.Vetter), потом запекание.
-- В игре из ServerStorage.Assets только клонируем (World.place): по сети ничего не грузится.
local IS = game:GetService("InsertService")
local SS = game:GetService("ServerStorage")
local Baker = {}

local function folder(path)
	local cur = SS:FindFirstChild("Assets") or Instance.new("Folder")
	cur.Name = "Assets"
	cur.Parent = SS
	for _, name in string.split(path, "/") do
		local nxt = cur:FindFirstChild(name) or Instance.new("Folder")
		nxt.Name = name
		nxt.Parent = cur
		cur = nxt
	end
	return cur
end

-- удаляет всё, что может исполнять код или нести данные; возвращает счётчики
function Baker.strip(root)
	local n = { scripts = 0, remotes = 0, strings = 0, sounds = 0 }
	for _, d in root:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			n.scripts += 1
			d:Destroy()
		elseif d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction") then
			n.remotes += 1
			d:Destroy()
		elseif d:IsA("BinaryStringValue") or (d:IsA("StringValue") and #d.Value > 200) then
			n.strings += 1
			d:Destroy()
		elseif d:IsA("Sound") then
			n.sounds += 1
			d:Destroy()
		end
	end
	return n
end

function Baker.scan(root)
	local bad = 0
	for _, d in root:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BinaryStringValue") then
			bad += 1
		end
	end
	return bad
end

-- Габариты по осям мира и «уровень земли» (GroundY): верх плиты-основания, если она у низа модели, иначе низ самой нижней
-- твёрдой части. Так здания не парят, если у модели снизу лишний «хвост» (фундамент, опоры). Для техники и гор земля = 0.
function Baker.measure(model, flatGround)
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local items = {}
	local function aabb(p)
		local cf, s = p.CFrame, p.Size / 2
		local a, b = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for ix = -1, 1, 2 do
			for iy = -1, 1, 2 do
				for iz = -1, 1, 2 do
					local w = cf:PointToWorldSpace(Vector3.new(s.X * ix, s.Y * iy, s.Z * iz))
					a = Vector3.new(math.min(a.X, w.X), math.min(a.Y, w.Y), math.min(a.Z, w.Z))
					b = Vector3.new(math.max(b.X, w.X), math.max(b.Y, w.Y), math.max(b.Z, w.Z))
				end
			end
		end
		return a, b
	end
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local a, b = aabb(p)
			mn = Vector3.new(math.min(mn.X, a.X), math.min(mn.Y, a.Y), math.min(mn.Z, a.Z))
			mx = Vector3.new(math.max(mx.X, b.X), math.max(mx.Y, b.Y), math.max(mx.Z, b.Z))
			if p.CanCollide and p.Transparency < 0.9 then
				table.insert(items, { a.Y, b.Y, (b.X - a.X) * (b.Z - a.Z) })
			end
		end
	end
	if mn.X == math.huge then
		return nil
	end
	local lowest = math.huge
	for _, it in items do
		if it[3] >= 16 then
			lowest = math.min(lowest, it[1])
		end
	end
	local ground = 0
	if not flatGround and lowest ~= math.huge then
		ground = lowest - mn.Y
		local bestTop = math.huge
		for _, it in items do
			if it[1] <= lowest + 0.6 and (it[2] - it[1]) <= 3 and it[3] >= 150 then
				bestTop = math.min(bestTop, it[2])
			end
		end
		if bestTop < math.huge then
			ground = bestTop - mn.Y
		end
		ground = math.max(0, ground)
	end
	local size = mx - mn
	-- точка вращения — центр основания, оси мира; габариты и земля — в атрибутах (World.place берёт их)
	model.WorldPivot = CFrame.new((mn.X + mx.X) / 2, mn.Y, (mn.Z + mx.Z) / 2)
	model:SetAttribute("SizeX", size.X)
	model:SetAttribute("SizeY", size.Y)
	model:SetAttribute("SizeZ", size.Z)
	model:SetAttribute("GroundY", ground)
	return size, ground
end

-- source: число (id ассета) или Instance (копия из карантина). Если source — Instance, клонируется.
-- opts.sourceId — id для записи, если source — Instance.
function Baker.bake(path, name, source, opts)
	opts = opts or {}
	local holder
	if typeof(source) == "Instance" then
		holder = source:Clone()
	else
		local ok, res = pcall(function()
			return IS:LoadAsset(source)
		end)
		if not ok then
			return false, "LoadAsset: " .. tostring(res)
		end
		holder = res
	end
	local model
	if typeof(source) == "Instance" then
		if holder:IsA("Model") then
			model = holder
		else
			model = Instance.new("Model")
			holder.Parent = model
		end
	else
		local kids = holder:GetChildren()
		if opts.pick then
			model = opts.pick(holder)
			if model then
				model.Parent = nil
			end
		elseif #kids == 1 and kids[1]:IsA("Model") then
			model = kids[1]
			model.Parent = nil
		else
			model = Instance.new("Model")
			for _, c in kids do
				c.Parent = model
			end
		end
	end
	if not model then
		return false, "pick вернул nil"
	end
	model.Name = name
	local n = Baker.strip(model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
		end
	end
	local size, ground = Baker.measure(model, opts.flatGround or path == "Vehicles" or path == "Mountains")
	if not size then
		return false, "нет частей"
	end
	model:SetAttribute("SourceId", typeof(source) == "number" and source or (opts.sourceId or 0))
	model:SetAttribute("Stripped", n.scripts)
	local bad = Baker.scan(model)
	if bad > 0 then
		model:Destroy()
		return false, "после чистки осталось " .. bad
	end
	local dst = folder(path)
	local prev = dst:FindFirstChild(name)
	if prev then
		prev:Destroy()
	end
	model.Parent = dst
	if holder ~= model then
		holder:Destroy()
	end
	local parts = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	return true, string.format("%s/%s: %.0f×%.0f×%.0f (земля +%.1f), частей %d, вычищено скриптов %d, remote %d, строк %d, звуков %d", path, name, size.X, size.Y, size.Z, ground, parts, n.scripts, n.remotes, n.strings, n.sounds)
end

return Baker
