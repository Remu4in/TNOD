--!strict
-- WorldForge Baker — «печь» ассетов (обобщено из examples/Baker.luau): чистка → замеры → чистая модель в библиотеке.
-- Только Edit-режим. Порядок: Vetter.vet (решение по asset_intake) → Baker.bake → запись в assets_ledger.
-- Пример:
--   Baker.bake("Metro", "Bench", game.ServerStorage.AssetStaging.Bench, { sourceId = 15080186657 })
--   Baker.bake("Metro", "Train", 16482420276, { flatGround = true })
local IS = game:GetService("InsertService")
local SS = game:GetService("ServerStorage")
local Baker = {}

export type StripOptions = { keepSounds: boolean?, keepPrompts: boolean?, keepSeats: boolean? }
export type BakeOptions = {
	sourceId: number?, -- id для записи, если source — Instance
	flatGround: boolean?, -- техника, горы: «земля» = низ модели
	pick: ((Instance) -> Instance?)?, -- выбрать нужную модель из загруженного контейнера
	library: Instance?, -- корень библиотеки, по умолчанию ServerStorage.Assets
	strip: StripOptions?,
	targetSize: Vector3?, -- калибровка масштаба: подогнать наибольший габарит к targetSize (по наибольшей оси)
}
export type StripCount = { scripts: number, remotes: number, strings: number, sounds: number, prompts: number, seats: number }

local function folder(root: Instance, path: string): Instance
	local cur = root
	for _, name in string.split(path, "/") do
		local nxt = cur:FindFirstChild(name)
		if not nxt then
			local f = Instance.new("Folder")
			f.Name = name
			f.Parent = cur
			nxt = f
		end
		cur = nxt :: Instance
	end
	return cur
end

local function defaultLibrary(): Instance
	local lib = SS:FindFirstChild("Assets")
	if not lib then
		local f = Instance.new("Folder")
		f.Name = "Assets"
		f.Parent = SS
		lib = f
	end
	return lib :: Instance
end

-- Удаляет всё, что может исполнять код или нести данные; возвращает счётчики
function Baker.strip(root: Instance, opts: StripOptions?): StripCount
	local o: StripOptions = opts or {}
	local n: StripCount = { scripts = 0, remotes = 0, strings = 0, sounds = 0, prompts = 0, seats = 0 }
	for _, d in root:GetDescendants() do
		if d.Parent == nil then
			continue -- уже удалён вместе с родителем
		end
		if d:IsA("LuaSourceContainer") then
			n.scripts += 1
			d:Destroy()
		elseif d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction") then
			n.remotes += 1
			d:Destroy()
		elseif d:IsA("BinaryStringValue") or (d:IsA("StringValue") and #d.Value > 200) then
			n.strings += 1
			d:Destroy()
		elseif d:IsA("Sound") and not o.keepSounds then
			n.sounds += 1
			d:Destroy()
		elseif (d:IsA("ClickDetector") or d:IsA("ProximityPrompt")) and not o.keepPrompts then
			n.prompts += 1
			d:Destroy()
		elseif (d:IsA("Seat") or d:IsA("VehicleSeat")) and not o.keepSeats then
			-- сиденье — это деталь: заменяем на обычный Part той же формы, чтобы не терять геометрию
			local p = Instance.new("Part")
			p.Name = d.Name
			p.Size = (d :: BasePart).Size
			p.CFrame = (d :: BasePart).CFrame
			p.Color = (d :: BasePart).Color
			p.Material = (d :: BasePart).Material
			p.Transparency = (d :: BasePart).Transparency
			p.Parent = d.Parent
			n.seats += 1
			d:Destroy()
		end
	end
	return n
end

-- Число оставшихся опасных объектов (должно быть 0)
function Baker.scan(root: Instance): number
	local bad = 0
	for _, d in root:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction") or d:IsA("BinaryStringValue") or (d:IsA("StringValue") and #d.Value > 200) then
			bad += 1
		end
	end
	return bad
end

-- Габариты по осям мира и «уровень земли» GroundY (логика из образца: верх плиты-основания у низа модели,
-- иначе низ самой нижней крупной твёрдой части). Ставит WorldPivot в центр основания и атрибуты SizeX/Y/Z, GroundY.
function Baker.measure(model: Model, flatGround: boolean?): (Vector3?, number)
	local V = Vector3.new
	local mn, mx = V(math.huge, math.huge, math.huge), V(-math.huge, -math.huge, -math.huge)
	local items: { { number } } = {}
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local cf, s = p.CFrame, p.Size / 2
			local a, b = V(math.huge, math.huge, math.huge), V(-math.huge, -math.huge, -math.huge)
			for _, ix in { -1, 1 } do
				for _, iy in { -1, 1 } do
					for _, iz in { -1, 1 } do
						local w = cf:PointToWorldSpace(V(s.X * ix, s.Y * iy, s.Z * iz))
						a = a:Min(w)
						b = b:Max(w)
					end
				end
			end
			mn = mn:Min(a)
			mx = mx:Max(b)
			if p.CanCollide and p.Transparency < 0.9 then
				table.insert(items, { a.Y, b.Y, (b.X - a.X) * (b.Z - a.Z) })
			end
		end
	end
	if mn.X == math.huge then
		return nil, 0
	end
	local ground = 0
	if not flatGround then
		local lowest = math.huge
		for _, it in items do
			if it[3] >= 16 then
				lowest = math.min(lowest, it[1])
			end
		end
		if lowest ~= math.huge then
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
	end
	local size = mx - mn
	model.WorldPivot = CFrame.new((mn.X + mx.X) / 2, mn.Y, (mn.Z + mx.Z) / 2)
	model:SetAttribute("SizeX", size.X)
	model:SetAttribute("SizeY", size.Y)
	model:SetAttribute("SizeZ", size.Z)
	model:SetAttribute("GroundY", ground)
	return size, ground
end

-- Калибровка масштаба: наибольший габарит → наибольшая ось targetSize. Model:ScaleTo масштабирует от pivot.
function Baker.calibrate(model: Model, targetSize: Vector3): number
	local size = model:GetExtentsSize()
	local cur = math.max(size.X, size.Y, size.Z)
	local want = math.max(targetSize.X, targetSize.Y, targetSize.Z)
	if cur <= 0 then
		return 1
	end
	local k = want / cur
	model:ScaleTo(model:GetScale() * k)
	return k
end

-- source: число (id ассета) или Instance (копия из AssetStaging; клонируется). path — подпапка библиотеки, "A/B".
function Baker.bake(path: string, name: string, source: number | Instance, opts: BakeOptions?): (boolean, string)
	local o: BakeOptions = opts or {}
	local holder: Instance
	if typeof(source) == "Instance" then
		holder = (source :: Instance):Clone()
	else
		local ok, res = pcall(function(): Instance
			return IS:LoadAsset(source :: number)
		end)
		if not ok then
			return false, "LoadAsset: " .. tostring(res) .. " (вставить через insert_asset в AssetStaging и передать Instance)"
		end
		holder = res :: Instance
	end
	local model: Model? = nil
	if o.pick then
		local picked = o.pick(holder)
		if picked then
			if picked:IsA("Model") then
				model = picked
			else
				local m = Instance.new("Model")
				picked.Parent = m
				model = m
			end
			(model :: Model).Parent = nil
		end
	elseif holder:IsA("Model") and typeof(source) == "Instance" then
		model = holder
	else
		local kids = holder:GetChildren()
		if #kids == 1 and kids[1]:IsA("Model") then
			model = kids[1] :: Model
			(model :: Model).Parent = nil
		else
			local m = Instance.new("Model")
			if typeof(source) == "Instance" then
				holder.Parent = m
			else
				for _, c in kids do
					c.Parent = m
				end
			end
			model = m
		end
	end
	if not model then
		holder:Destroy()
		return false, "pick вернул nil"
	end
	local m = model :: Model
	m.Name = name
	local n = Baker.strip(m, o.strip)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
		end
	end
	if o.targetSize then
		Baker.measure(m, true)
		Baker.calibrate(m, o.targetSize)
	end
	local size, ground = Baker.measure(m, o.flatGround)
	if not size then
		m:Destroy()
		return false, "нет частей"
	end
	m:SetAttribute("SourceId", if typeof(source) == "number" then source else (o.sourceId or 0))
	m:SetAttribute("Stripped", n.scripts)
	local bad = Baker.scan(m)
	if bad > 0 then
		m:Destroy()
		return false, "после чистки осталось " .. bad
	end
	local dst = folder(o.library or defaultLibrary(), path)
	local prev = dst:FindFirstChild(name)
	if prev then
		prev:Destroy()
	end
	m.Parent = dst
	if holder ~= m and holder.Parent == nil then
		holder:Destroy()
	end
	local parts = 0
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	local s = size :: Vector3
	return true, string.format("%s/%s: %.0f×%.0f×%.0f (земля +%.1f), частей %d, вычищено: скриптов %d, remote %d, строк %d, звуков %d, prompt %d, сидений %d; повторный скан 0", path, name, s.X, s.Y, s.Z, ground, parts, n.scripts, n.remotes, n.strings, n.sounds, n.prompts, n.seats)
end

export type RestyleRules = {
	darken: number?, -- 0..1: насколько затемнить цвета деталей
	desaturate: number?, -- 0..1
	materialMap: { [Enum.Material]: Enum.Material }?, -- замена материалов (например Plastic → Concrete)
	tint: Color3?, -- общий оттенок (смешивание 20%)
	dropTextures: boolean?, -- убрать Decal/Texture (например, надписи)
}

-- Воркфлоу D: привести ассет к стилю. Цвет детали с TextureID/SurfaceAppearance может не влиять на вид — не проверено.
function Baker.restyle(root: Instance, rules: RestyleRules): number
	local changed = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local c = d.Color
			if rules.desaturate then
				local h, s, v = c:ToHSV()
				c = Color3.fromHSV(h, s * (1 - rules.desaturate), v)
			end
			if rules.tint then
				c = c:Lerp(rules.tint, 0.2)
			end
			if rules.darken then
				c = c:Lerp(Color3.new(0, 0, 0), rules.darken)
			end
			d.Color = c
			if rules.materialMap and rules.materialMap[d.Material] then
				d.Material = rules.materialMap[d.Material]
			end
			changed += 1
		elseif rules.dropTextures and (d:IsA("Decal") or d:IsA("Texture")) then
			d:Destroy()
			changed += 1
		end
	end
	return changed
end

return Baker
