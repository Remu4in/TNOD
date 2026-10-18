-- Проверка ассета перед запеканием (копия для репозитория; в Studio — ServerStorage.Tools.Vetter, только Edit).
-- LoadAsset без вставки в карту + сигнатуры вредоносов (оба семейства: Runtime/ScreenBuilder и Hierarchy/Layout/Prevent Lag)
-- и признаки обфускации. Для новых ID сначала insert_asset (иначе «User is not authorized»), см. .claude/skills/asset-vetting.
local IS = game:GetService("InsertService")
local Vetter = {}

local function scanSource(s, d)
	local f = {}
	local l = s:lower()
	for tok in s:gmatch("[A-Za-z0-9+/=]+") do
		if #tok >= 220 then
			f["base64?"] = true
			break
		end
	end
	if s:find("\\%d%d%d\\%d%d%d\\%d%d%d") or s:find("\\x%x%x\\x%x%x\\x%x%x") then f["escape-цепочка"] = true end
	if l:find("string%.char") or l:find("string%.reverse") or l:find("utf8%.char") then f["string.char"] = true end
	if l:find("loadstring") then f["loadstring"] = true end
	if l:find("[gs]etfenv") then f["getfenv"] = true end
	if l:find("httpservice") then f["HttpService"] = true end
	if l:find("insertservice") then f["InsertService"] = true end
	if l:find("teleportservice") then f["Teleport"] = true end
	if l:find(":kick%(") then f["Kick"] = true end
	if l:find("require%s*%(%s*%d") then f["require(число)"] = true end
	if l:find("marketplaceservice") and (l:find("jobid") or l:find("root%[")) then f["JobId+Marketplace"] = true end
	if l:find("prevent lag") or l:find("c:byte%(%)") then f["загрузчик(Prevent Lag/c:byte)"] = true end
	if l:find("isstudio") and (l:find("scrambled") or l:find("payload") or l:find("overlay window") or l:find("code sample")) then f["Studio-вредонос"] = true end
	if l:find("clipboard") or l:find("command bar") then f["clipboard/команда"] = true end
	if l:find("game%s*%[") then f["динамический доступ"] = true end
	local n = d.Name
	if n == "Runtime" or n == "ScreenBuilder" or n == "Hierarchy" or n == "Layout" or n == "Loader" or n == "Bootstrap" then f["имя:" .. n] = true end
	local p = d.Parent
	if p and (p:IsA("Weld") or p:IsA("Decal") or p:IsA("Attachment") or p:IsA("Sound") or p:IsA("Texture") or p:IsA("SpecialMesh")) then
		f["скрипт в " .. p.ClassName] = true
	end
	return f
end

-- возвращает { ok, reason?, parts, mesh, scripts, remotes, flags = {имя = число}, size = Vector3, name }
function Vetter.vet(id)
	local ok, res = pcall(function()
		return IS:LoadAsset(id)
	end)
	if not ok then
		return { ok = false, reason = tostring(res):sub(1, 60) }
	end
	local r = { ok = true, parts = 0, mesh = 0, scripts = 0, remotes = 0, flags = {}, hum = 0 }
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, d in res:GetDescendants() do
		if d:IsA("BasePart") then
			r.parts += 1
			if d:IsA("MeshPart") then
				r.mesh += 1
			end
			local cf, s = d.CFrame, d.Size / 2
			for ix = -1, 1, 2 do
				for iy = -1, 1, 2 do
					for iz = -1, 1, 2 do
						local w = cf:PointToWorldSpace(Vector3.new(s.X * ix, s.Y * iy, s.Z * iz))
						mn = Vector3.new(math.min(mn.X, w.X), math.min(mn.Y, w.Y), math.min(mn.Z, w.Z))
						mx = Vector3.new(math.max(mx.X, w.X), math.max(mx.Y, w.Y), math.max(mx.Z, w.Z))
					end
				end
			end
		elseif d:IsA("LuaSourceContainer") then
			r.scripts += 1
			local okS, s = pcall(function()
				return d.Source
			end)
			if okS then
				for k in scanSource(s, d) do
					r.flags[k] = (r.flags[k] or 0) + 1
				end
			else
				r.flags["Source нечитаем"] = 1
			end
		elseif d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			r.remotes += 1
		elseif d:IsA("Humanoid") then
			r.hum += 1
		elseif d:IsA("BinaryStringValue") or (d:IsA("StringValue") and #d.Value > 500) then
			r.flags["большие данные"] = (r.flags["большие данные"] or 0) + 1
		end
	end
	r.size = if r.parts > 0 then mx - mn else Vector3.zero
	local top = res:GetChildren()[1]
	r.name = top and top.Name or "-"
	res:Destroy()
	return r
end

function Vetter.line(id, r)
	if not r.ok then
		return id .. ": НЕ ЗАГРУЗИЛСЯ (" .. tostring(r.reason) .. ")"
	end
	local fl = {}
	for k, v in r.flags do
		table.insert(fl, k .. "×" .. v)
	end
	table.sort(fl)
	return string.format("%d [%s] ч=%d м=%d %.0f×%.0f×%.0f скр=%d rem=%d | %s", id, r.name:sub(1, 30), r.parts, r.mesh, r.size.X, r.size.Y, r.size.Z, r.scripts, r.remotes, #fl > 0 and table.concat(fl, "; ") or "чисто")
end

return Vetter
