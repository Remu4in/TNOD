--!strict
-- WorldForge Checks — автопроверки построенной локации (шаг 5). Только читает сцену.
-- Пример:
--   local r = Checks.run(workspace.Metro, {
--     partBudget = 15000, maxPartLength = 100,
--     requiredMarkers = { "Metro_Spawn", "Metro_Exit" },
--     propFolders = { "Decor/Furniture", "Decor/Debris" },
--     keepClear = { { name = "проход у лестницы", cframe = CFrame.new(106, 603, 30), size = Vector3.new(12, 5, 8) } },
--   })
--   return Checks.text(r)
-- Статус: run/text запускались в Studio 2026-10-24 (Edit, Workspace.Metro): Raycast и GetPartBoundsInBox в Edit работают.
-- reachability — не проверено.
local Checks = {}

export type Box = { name: string, cframe: CFrame, size: Vector3 }
export type Options = {
	partBudget: number?, -- лимит BasePart (предупреждение при превышении)
	maxPartLength: number?, -- макс. горизонтальный размер твёрдой детали (навмеш), по умолчанию 100
	requiredMarkers: { string }?, -- имена маркеров, которые должны быть в <root>/Markers
	propFolders: { string }?, -- пути папок с предметами (относительно root, через "/") для проверки «парит в воздухе»
	floatTolerance: number?, -- допуск зазора под предметом, по умолчанию 0.3
	keepClear: { Box }?, -- объёмы, где не должно быть твёрдых деталей (проходы, проёмы, спавны)
}
export type Result = { errors: { string }, warnings: { string }, stats: { [string]: number } }

local function resolve(root: Instance, path: string): Instance?
	local cur: Instance? = root
	for _, name in string.split(path, "/") do
		if not cur then
			return nil
		end
		cur = (cur :: Instance):FindFirstChild(name)
	end
	return cur
end

local function bounds(m: Instance): (Vector3, Vector3)
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local list: { Instance } = if m:IsA("BasePart") then { m } else m:GetDescendants()
	for _, d in list do
		if d:IsA("BasePart") then
			local cf, s = d.CFrame, d.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local w = cf:PointToWorldSpace(Vector3.new(s.X * sx, s.Y * sy, s.Z * sz))
						mn = mn:Min(w)
						mx = mx:Max(w)
					end
				end
			end
		end
	end
	return mn, mx
end

function Checks.run(root: Instance, opts: Options?): Result
	local o: Options = opts or {}
	local r: Result = { errors = {}, warnings = {}, stats = {} }
	local maxLen = o.maxPartLength or 100

	-- 1. Скрипты и носители данных внутри локации (ассеты должны быть вычищены)
	local parts, scripts, longOnes = 0, 0, 0
	local longNames: { string } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			scripts += 1
			if scripts <= 10 then
				table.insert(r.errors, "скрипт в локации: " .. d:GetFullName())
			end
		elseif d:IsA("BasePart") then
			parts += 1
			if d.CanCollide and math.max(d.Size.X, d.Size.Z) > maxLen + 0.01 then
				longOnes += 1
				if #longNames < 10 then
					table.insert(longNames, string.format("%s (%.0f×%.0f)", d:GetFullName(), d.Size.X, d.Size.Z))
				end
			end
		end
	end
	r.stats.parts = parts
	r.stats.scripts = scripts
	r.stats.longParts = longOnes
	if longOnes > 0 then
		table.insert(r.warnings, string.format("%d твёрдых деталей длиннее %d студов (навмеш может не построиться): %s", longOnes, maxLen, table.concat(longNames, "; ")))
	end
	if o.partBudget and parts > o.partBudget then
		table.insert(r.warnings, string.format("частей %d > бюджета %d", parts, o.partBudget))
	end

	-- 2. Маркеры
	if o.requiredMarkers then
		local markers = root:FindFirstChild("Markers")
		for _, name in o.requiredMarkers do
			if not (markers and markers:FindFirstChild(name)) then
				table.insert(r.errors, "нет маркера " .. name)
			end
		end
	end

	-- 3. «Парящие» предметы: опора ищется тонким объёмом под всем основанием (ножки, колёса, соседние детали
	-- составного предмета); только если опоры нет — луч вниз из центра, чтобы сообщить зазор.
	-- Один луч из центра давал ложные «парит» для лавки из отдельных деталей и дрезины на рельсах (2026-10-24).
	local tol = o.floatTolerance or 0.3
	local floating = 0
	local markersFolder = root:FindFirstChild("Markers")
	if o.propFolders then
		for _, path in o.propFolders do
			local f = resolve(root, path)
			if not f then
				table.insert(r.warnings, "нет папки " .. path)
				continue
			end
			for _, item in (f :: Instance):GetChildren() do
				if not (item:IsA("BasePart") or item:IsA("Model")) then
					continue
				end
				local mn, mx = bounds(item)
				if mn.X == math.huge then
					continue
				end
				local slab = OverlapParams.new()
				slab.FilterType = Enum.RaycastFilterType.Exclude
				slab.FilterDescendantsInstances = if markersFolder then { item, markersFolder } else { item }
				local slabCf = CFrame.new((mn.X + mx.X) / 2, mn.Y - tol / 2 + 0.05, (mn.Z + mx.Z) / 2)
				local slabSize = Vector3.new(math.max((mx.X - mn.X) * 0.9, 0.2), tol + 0.1, math.max((mx.Z - mn.Z) * 0.9, 0.2))
				if #workspace:GetPartBoundsInBox(slabCf, slabSize, slab) > 0 then
					continue
				end
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { item }
				local origin = Vector3.new((mn.X + mx.X) / 2, mn.Y + 0.05, (mn.Z + mx.Z) / 2)
				local hit = workspace:Raycast(origin, Vector3.new(0, -50, 0), params)
				local gap = if hit then origin.Y - 0.05 - hit.Position.Y else math.huge
				if gap > tol then
					floating += 1
					if floating <= 10 then
						table.insert(r.warnings, string.format("парит: %s (зазор %s)", item:GetFullName(), if gap == math.huge then "> 50" else string.format("%.2f", gap)))
					end
				end
			end
		end
	end
	r.stats.floating = floating

	-- 4. Свободные объёмы (проходы): твёрдые детали внутри — ошибка
	if o.keepClear then
		local params = OverlapParams.new()
		local markers = root:FindFirstChild("Markers")
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = if markers then { markers } else {}
		for _, box in o.keepClear do
			local hits = workspace:GetPartBoundsInBox(box.cframe, box.size, params)
			local solid: { string } = {}
			for _, p in hits do
				if p.CanCollide and p:IsDescendantOf(root) then
					table.insert(solid, p.Name)
				end
			end
			if #solid > 0 then
				table.insert(r.errors, string.format("проход «%s» перекрыт: %s", box.name, table.concat(solid, ", ", 1, math.min(#solid, 8))))
			end
		end
	end
	return r
end

-- Достижимость: путь от from до каждого to. Навмеш строится движком; в Edit-режиме может быть недоступен —
-- запускать в Play (Run) через execute_luau, если в Edit статус NoPath везде. Не проверено (D-013).
-- После пересоздания геометрии навмеш «залипает»: пересадить деталь (Parent = nil → обратно) и повторить.
function Checks.reachability(from: Vector3, targets: { [string]: Vector3 }, agent: { [string]: any }?): { [string]: string }
	local PFS = game:GetService("PathfindingService")
	local out: { [string]: string } = {}
	for name, pos in targets do
		local path = PFS:CreatePath(agent or { AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
		local ok, err = pcall(function()
			path:ComputeAsync(from, pos)
		end)
		out[name] = if ok then path.Status.Name else ("ошибка: " .. tostring(err))
	end
	return out
end

function Checks.text(r: Result): string
	local s = string.format("Ошибок %d, предупреждений %d | частей %d, скриптов %d, длинных деталей %d, парящих %d", #r.errors, #r.warnings, r.stats.parts or 0, r.stats.scripts or 0, r.stats.longParts or 0, r.stats.floating or 0)
	for _, e in r.errors do
		s ..= "\n  ОШИБКА: " .. e
	end
	for _, w in r.warnings do
		s ..= "\n  внимание: " .. w
	end
	return s
end

return Checks
