-- «Печь оружия» (копия для репозитория; в Studio — ServerStorage.Tools.WeaponBaker, только Edit-режим).
-- Паки Rubie's Weapon Collection (см. docs/asset_plan.md §4): LoadAsset → выбор оружия → отбрасывание патронов и обвесов →
-- нормализация позы (дуло/остриё в -Z, верх +Y, начало координат — хват) → чистая модель без скриптов в
-- ServerStorage.Assets.Weapons.<Класс>.<Имя>. В игре эти модели только клонируются (WeaponService.buildTool).
-- Пример: require(game.ServerStorage.Tools.WeaponBaker).bakePack(16855904941, "Pistols")
-- Порядок: сначала проверка Vetter (asset-vetting), потом запекание. Все LuaSourceContainer/Remote/Sound/частицы не копируются:
-- берём только MeshPart (цвет, материал, SurfaceAppearance).
local IS = game:GetService("InsertService")
local SS = game:GetService("ServerStorage")
local WB = {}

-- Что не берём в модель (патроны, обвесы, чехлы); для гранатомётов часть правил отключается
local SKIP = {
	Addons = true, ["Shell Mount"] = true, ["Unfolded Stock"] = true, Laser = true, ["Cylinder Laser"] = true,
	["Match Kit"] = true, Bipod = true, Scope = true, Sheathe = true, Shells = true, Camera = true, ["Drum Mag"] = true,
}
local SKIP_LAUNCHER = { Addons = true, Shells = true, Camera = true, ["Drum Mag"] = true }

-- Класс → способ нормализации и доля длины от тыла до точки хвата
local KINDS = {
	Pistols = { kind = "pistol", gripZ = 0.17, gripY = 0.32 },
	Revolvers = { kind = "pistol", gripZ = 0.17, gripY = 0.32 },
	SMG = { kind = "gun", gripZ = 0.34, gripY = 0.40 },
	Carbines = { kind = "gun", gripZ = 0.30, gripY = 0.40 },
	Shotguns = { kind = "gun", gripZ = 0.28, gripY = 0.42 },
	Rifles = { kind = "gun", gripZ = 0.30, gripY = 0.40 },
	Launchers = { kind = "gun", gripZ = 0.40, gripY = 0.45 },
	Melee = { kind = "melee" },
}

local function isAmmo(n)
	return n:find("%dmm") ~= nil or n:find("ACP") ~= nil or n:find(" AE$") ~= nil or n:find("LR$") ~= nil
		or n:find("Gauge") ~= nil or n:find("Subsonic") ~= nil or n:find("Magnum") ~= nil or n:find("Special$") ~= nil
		or n:find("HE$") ~= nil
end

local function skipSet(cls)
	return if cls == "Launchers" then SKIP_LAUNCHER else SKIP
end

local function skipModel(n, cls) -- вложенная модель: обвес или патрон
	return skipSet(cls)[n] == true or isAmmo(n)
end

local function safeName(n)
	return (n:gsub("[^%w]+", ""))
end

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

-- Оружие = модель, у которой есть собственные BasePart (папки и «коллекции» раскрываем)
local function findWeapons(root, cls, acc)
	for _, c in root:GetChildren() do
		if c:IsA("Model") and not skipSet(cls)[c.Name] then
			local hasPart = false
			for _, k in c:GetChildren() do
				if k:IsA("BasePart") then
					hasPart = true
					break
				end
			end
			if hasPart then
				table.insert(acc, c)
			else
				findWeapons(c, cls, acc)
			end
		elseif c:IsA("Folder") then
			findWeapons(c, cls, acc)
		end
	end
	return acc
end

-- Детали модели без патронов и обвесов; group: Body / Mag / Slide
local function collect(model, cls)
	local list, dropped = {}, 0
	local function rec(inst, group)
		for _, c in inst:GetChildren() do
			if c:IsA("BasePart") then
				table.insert(list, { part = c, group = group })
			elseif c:IsA("Model") or c:IsA("Folder") then
				if skipModel(c.Name, cls) then
					dropped += 1
				else
					local g = group
					if c.Name == "Mag" then
						g = "Mag"
					elseif c.Name == "Slide" then
						g = "Slide"
					end
					rec(c, g)
				end
			end
		end
	end
	rec(model, "Body")
	return list, dropped
end

local function corners(cf, size)
	local s = size / 2
	local out = {}
	for ix = -1, 1, 2 do
		for iy = -1, 1, 2 do
			for iz = -1, 1, 2 do
				table.insert(out, cf:PointToWorldSpace(Vector3.new(s.X * ix, s.Y * iy, s.Z * iz)))
			end
		end
	end
	return out
end

local function bounds(items, cfOf)
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, it in items do
		for _, w in corners(cfOf(it), it.part.Size) do
			mn = Vector3.new(math.min(mn.X, w.X), math.min(mn.Y, w.Y), math.min(mn.Z, w.Z))
			mx = Vector3.new(math.max(mx.X, w.X), math.max(mx.Y, w.Y), math.max(mx.Z, w.Z))
		end
	end
	return mn, mx
end

local function centerOf(it)
	return it.part.Position
end

-- Конец клинка/бойка у холодного оружия: центр масс по объёму смещён к «рабочему» концу; при равенстве — где шире
local function businessEndSign(items, mn, mx)
	-- В паке всё холодное оружие стоит остриём вверх (+Y). Прежняя эвристика (масса/ширина) на ножах, мече и бите ошибалась:
	-- остриё смотрело в руку. Поэтому по умолчанию +Y; старая логика ниже оставлена как запасная (отключена).
	if true then
		return 1, "+Y по умолчанию"
	end
	local c = (mn + mx) / 2
	local len = mx.Y - mn.Y
	local sv, sy = 0, 0
	for _, it in items do
		local s = it.part.Size
		local v = s.X * s.Y * s.Z
		sv += v
		sy += v * (it.part.Position.Y - c.Y)
	end
	local com = if sv > 0 then sy / sv else 0
	if math.abs(com) > 0.04 * len then
		return if com > 0 then 1 else -1, "масса"
	end
	local wTop, wBot = 0, 0
	for _, it in items do
		local y = it.part.Position.Y - c.Y
		local s = it.part.Size
		local w = math.max(s.X, s.Z)
		if y > 0.25 * len / 2 then
			wTop = math.max(wTop, w)
		elseif y < -0.25 * len / 2 then
			wBot = math.max(wBot, w)
		end
	end
	if wTop == wBot then
		return 1, "по умолчанию"
	end
	return if wTop > wBot then 1 else -1, "ширина"
end

-- Нормализует одну модель оружия → { model, line } или nil, причина
function WB.bakeModel(src, cls, packId, outName)
	local cfg = KINDS[cls]
	if not cfg then
		return nil, "неизвестный класс " .. tostring(cls)
	end
	local items, dropped = collect(src, cls)
	if #items == 0 then
		return nil, "нет частей"
	end
	-- детали далеко от основного корпуса (Kolibri: магазин «в стороне») отбрасываем
	local sx, sy, sz = 0, 0, 0
	for _, it in items do
		local p = it.part.Position
		sx += p.X
		sy += p.Y
		sz += p.Z
	end
	local mean = Vector3.new(sx / #items, sy / #items, sz / #items)
	local far = {}
	local kept = {}
	for _, it in items do
		if (it.part.Position - mean).Magnitude > 9 then
			table.insert(far, it.part.Name)
		else
			table.insert(kept, it)
		end
	end
	items = kept
	local mn, mx = bounds(items, function(it)
		return it.part.CFrame
	end)
	local c = (mn + mx) / 2

	local R = CFrame.new()
	local notes = {}
	if cfg.kind == "melee" then
		local sign, why = businessEndSign(items, mn, mx)
		R = if sign > 0 then CFrame.Angles(-math.pi / 2, 0, 0) else CFrame.Angles(math.pi / 2, 0, 0)
		table.insert(notes, "остриё " .. (if sign > 0 then "+Y" else "-Y") .. " (" .. why .. ")")
	else
		-- ожидаем: тонкая ось X, длина по Z, тыл (+Z) там, где приклад/магазин пистолета, верх +Y
		local rearCue, upCue = 0, 0
		for _, it in items do
			local n = it.part.Name
			local inStock = n:find("Stock") ~= nil
			if inStock then
				rearCue += it.part.Position.Z - c.Z
			elseif cfg.kind == "pistol" and it.group == "Mag" then
				rearCue += (it.part.Position.Z - c.Z) * 2
			end
			if it.group == "Mag" then
				upCue += c.Y - it.part.Position.Y
			end
		end
		if rearCue < -0.15 then
			R = R * CFrame.Angles(0, math.pi, 0)
			table.insert(notes, "развёрнут на 180° по Y")
		end
		if math.abs(upCue) > 0.6 and upCue < 0 then -- пак везде «вверх +Y»; переворот только при явном признаке (магазин выше корпуса)
			table.insert(notes, "ВНИМАНИЕ: магазин выше центра — проверить, не вверх ногами")
		end
		local d = mx - mn
		if d.Z < d.Y * 0.9 or d.X > d.Z then
			table.insert(notes, "ВНИМАНИЕ: ориентация не по Z — проверить")
		end
	end

	local function tmpCF(it)
		return CFrame.new(c) * R * CFrame.new(-c) * it.part.CFrame
	end
	local mn2, mx2 = bounds(items, tmpCF)
	local d2 = mx2 - mn2
	local c2 = (mn2 + mx2) / 2

	-- точка хвата
	local g
	if cfg.kind == "melee" then
		local ratio = if d2.Z > 4.5 then 0.32 else 0.18
		g = Vector3.new(c2.X, c2.Y, mx2.Z - ratio * d2.Z)
	else
		g = Vector3.new(c2.X, mn2.Y + cfg.gripY * d2.Y, mx2.Z - cfg.gripZ * d2.Z)
	end

	local model = Instance.new("Model")
	model.Name = outName
	local counts = { Body = 0, Mag = 0, Slide = 0 }
	local barrelY: number? = nil
	for i, it in items do
		local clone = it.part:Clone()
		for _, k in clone:GetChildren() do
			if not k:IsA("SurfaceAppearance") then
				k:Destroy()
			end
		end
		clone.Name = string.format("%s_%02d", safeName(it.part.Name) ~= "" and safeName(it.part.Name) or "Part", i)
		clone.CFrame = CFrame.new(-g) * tmpCF(it)
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true
		clone:SetAttribute("Group", it.group)
		counts[it.group] += 1
		if it.part.Name == "Barrel" or it.part.Name == "Muzzle" then
			barrelY = clone.Position.Y
		end
		clone.Parent = model
	end
	local mn3, mx3 = bounds(
		(function()
			local t = {}
			for _, p in model:GetChildren() do
				table.insert(t, { part = p })
			end
			return t
		end)(),
		function(it)
			return it.part.CFrame
		end
	)
	local d3 = mx3 - mn3
	model.WorldPivot = CFrame.new()
	model:SetAttribute("Class", cls)
	model:SetAttribute("DisplayName", src.Name)
	model:SetAttribute("SourceId", packId)
	model:SetAttribute("Length", d3.Z)
	model:SetAttribute("Height", d3.Y)
	model:SetAttribute("Width", d3.X)
	model:SetAttribute("MuzzleZ", mn3.Z)
	model:SetAttribute("MuzzleY", barrelY or (mn3.Y + mx3.Y) / 2)
	model:SetAttribute("MinY", mn3.Y)
	model:SetAttribute("MaxY", mx3.Y)
	model:SetAttribute("RearZ", mx3.Z)
	model:SetAttribute("MagParts", counts.Mag)
	model:SetAttribute("SlideParts", counts.Slide)
	local line = string.format(
		"%s → %s: частей %d (маг %d, затвор %d), %.2f×%.2f×%.2f, тыл z=%+.2f дуло z=%+.2f, y=%+.2f..%+.2f; отброшено %d групп%s%s",
		src.Name, outName, #items, counts.Mag, counts.Slide, d3.X, d3.Y, d3.Z, mx3.Z, mn3.Z, mn3.Y, mx3.Y, dropped,
		if #far > 0 then ("; ушли далеко: " .. table.concat(far, ",")) else "",
		if #notes > 0 then ("; " .. table.concat(notes, ", ")) else ""
	)
	return model, line
end

-- id пака → все модели оружия в Assets.Weapons.<cls>; only — необязательный список имён
function WB.bakePack(id, cls, only)
	local ok, holder = pcall(function()
		return IS:LoadAsset(id)
	end)
	if not ok then
		return { "LoadAsset: " .. tostring(holder) }
	end
	local report = {}
	local dst = folder("Weapons/" .. cls)
	local used = {}
	for _, w in findWeapons(holder, cls, {}) do
		if not only or table.find(only, w.Name) then
			local name = safeName(w.Name)
			used[name] = (used[name] or 0) + 1
			if used[name] > 1 then
				name ..= "_" .. used[name]
			end
			local model, line = WB.bakeModel(w, cls, id, name)
			if model then
				local prev = dst:FindFirstChild(name)
				if prev then
					prev:Destroy()
				end
				model.Parent = dst
				-- повторная проверка: ничего исполняемого
				for _, d in model:GetDescendants() do
					if d:IsA("LuaSourceContainer") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("Sound") then
						d:Destroy()
					end
				end
				table.insert(report, line)
			else
				table.insert(report, w.Name .. ": ПРОПУЩЕН (" .. tostring(line) .. ")")
			end
		end
	end
	holder:Destroy()
	return report
end

-- Прицел (обвес): все детали пака, начало координат — центр основания, перёд (линза/наводка) — в -Z (как в паке; проверить в Play)
function WB.bakeSight(id, name)
	local ok, holder = pcall(function()
		return IS:LoadAsset(id)
	end)
	if not ok then
		return nil, "LoadAsset: " .. tostring(holder)
	end
	local items = {}
	for _, d in holder:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(items, { part = d })
		end
	end
	if #items == 0 then
		holder:Destroy()
		return nil, "нет частей"
	end
	local mn, mx = bounds(items, function(it)
		return it.part.CFrame
	end)
	local base = Vector3.new((mn.X + mx.X) / 2, mn.Y, (mn.Z + mx.Z) / 2)
	local model = Instance.new("Model")
	model.Name = name
	for i, it in items do
		local clone = it.part:Clone()
		for _, k in clone:GetChildren() do
			if not k:IsA("SurfaceAppearance") then
				k:Destroy()
			end
		end
		clone.Name = string.format("%s_%02d", safeName(it.part.Name), i)
		clone.CFrame = CFrame.new(-base) * it.part.CFrame
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true
		clone.Parent = model
	end
	local d = mx - mn
	model.WorldPivot = CFrame.new()
	model:SetAttribute("Class", "Sights")
	model:SetAttribute("SourceId", id)
	model:SetAttribute("Width", d.X)
	model:SetAttribute("Height", d.Y)
	model:SetAttribute("Length", d.Z)
	holder:Destroy()
	folder("Weapons/Sights")
	local dst = SS.Assets.Weapons.Sights
	local prev = dst:FindFirstChild(name)
	if prev then
		prev:Destroy()
	end
	model.Parent = dst
	return model, string.format("%s: частей %d, %.3f×%.3f×%.3f", name, #items, d.X, d.Y, d.Z)
end

return WB
