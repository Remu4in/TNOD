--!strict
-- WorldForge Vetter — скан стороннего ассета на скрипты и признаки вредоносов (по vetting/asset-vetting_SKILL.md).
-- Только Edit-режим. Ничего не запускает и не меняет: только читает. Чистка — Baker.strip.
-- Примеры:
--   Vetter.line(Vetter.vet(game.ServerStorage.AssetStaging.Foo))
--   local r = Vetter.vetId(1234567890)   -- LoadAsset без парента; при «not authorized» → insert_asset + AssetStaging
local Vetter = {}

export type Finding = { path: string, class: string, reason: string }
export type Report = {
	name: string,
	parts: number,
	meshes: number,
	scripts: number,
	remotes: number,
	bigStrings: number,
	humanoids: number,
	animations: number,
	sounds: number,
	prompts: number,
	size: Vector3,
	findings: { Finding },
	verdict: string, -- "clean" | "scripts" | "suspicious"
}

-- Сигнатуры в Source (сравнение по lower-case)
local SIGS: { { string } } = {
	{ "require(число)", "require%s*%(%s*%d" },
	{ "loadstring", "loadstring" },
	{ "get/setfenv", "[gs]etfenv" },
	{ "HttpService", "httpservice" },
	{ "InsertService", "insertservice" },
	{ "MarketplaceService", "marketplaceservice" },
	{ "PromptPurchase", "promptpurchase" },
	{ "TeleportService", "teleportservice" },
	{ "DataStore", "datastore" },
	{ "GroupService", "groupservice" },
	{ ":Kick(", ":kick%(" },
	{ "string.char", "string%.char" },
	{ "string.reverse", "string%.reverse" },
	{ "utf8.char", "utf8%.char" },
	{ ":byte()", ":byte%(" },
	{ "hex-escape", "\\x%x%x\\x%x%x" },
	{ "dec-escape", "\\%d%d%d?\\%d%d%d?\\%d%d%d?" },
	{ "game[\"…\"]", "game%s*%[%s*[\"']" },
	{ "getfenv()[…]", "getfenv%s*%(%s*%)%s*%[" },
	{ "_G/shared", "[^%w_]_g[%.%[]" },
	{ "shared.", "[^%w_]shared[%.%[]" },
	{ "Instance.new(Script)", "instance%.new%s*%(%s*[\"']%a*script" },
	{ ".Source =", "%.source%s*=" },
	{ "debug.*", "debug%.%a" },
	{ "IsStudio", "isstudio" },
	{ "ScreenGui", "screengui" },
	{ "clipboard", "clipboard" },
	{ "JobId", "jobid" },
	{ "Prevent Lag", "prevent lag" },
	{ "payload/scrambled", "payload" },
	{ "scrambled", "scrambled" },
}

local BAD_NAMES: { [string]: boolean } = {
	runtime = true,
	screenbuilder = true,
	loader = true,
	core = true,
	bootstrap = true,
	require = true,
	hierarchy = true,
	layout = true,
	type = true,
	easyconfiguration = true,
}

-- Необычные родители скриптов (признак вредоносных семейств)
local ODD_PARENTS = { "JointInstance", "WeldConstraint", "Decal", "Texture", "BasePart", "Attachment", "Sound", "Configuration", "SurfaceAppearance" }

-- Невидимые символы UTF-8: NBSP, U+200B…U+200F, U+2060, BOM. Обычная кириллица — не находка.
local INVISIBLE = { "\194\160", "\226\128[\139-\143]", "\226\129\160", "\239\187\191" }

local function hasHiddenChars(s: string): boolean
	if s ~= string.gsub(s, "^%s+", "") or s ~= string.gsub(s, "%s+$", "") then
		return true
	end
	if string.find(s, "[%z\1-\31\127]") then -- управляющие
		return true
	end
	for _, pat in INVISIBLE do
		if string.find(s, pat) then
			return true
		end
	end
	return false
end

-- Корень + все потомки: ассет может быть одиночной деталью или самим скриптом (например MainModule)
local function selfAndDescendants(root: Instance): { Instance }
	local list = root:GetDescendants()
	table.insert(list, 1, root)
	return list
end

local function longestToken(src: string): number
	local best = 0
	for tok in string.gmatch(src, "[%w%+/=]+") do
		if #tok > best then
			best = #tok
		end
	end
	return best
end

local function aabbSize(root: Instance): Vector3
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, d in selfAndDescendants(root) do
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
	if mn.X == math.huge then
		return Vector3.zero
	end
	return mx - mn
end

function Vetter.vet(root: Instance): Report
	local r: Report = {
		name = root.Name,
		parts = 0,
		meshes = 0,
		scripts = 0,
		remotes = 0,
		bigStrings = 0,
		humanoids = 0,
		animations = 0,
		sounds = 0,
		prompts = 0,
		size = aabbSize(root),
		findings = {},
		verdict = "clean",
	}
	local function add(d: Instance, reason: string)
		table.insert(r.findings, { path = d:GetFullName(), class = d.ClassName, reason = reason })
	end
	if hasHiddenChars(root.Name) then
		add(root, "имя с пробелами по краям или скрытыми символами")
	end
	for _, d in selfAndDescendants(root) do
		if d:IsA("BasePart") then
			r.parts += 1
			if d:IsA("MeshPart") then
				r.meshes += 1
			end
		elseif d:IsA("LuaSourceContainer") then
			r.scripts += 1
			local lname = string.lower(d.Name)
			if BAD_NAMES[lname] then
				add(d, "подозрительное имя скрипта")
			end
			local parent = d.Parent
			if parent then
				for _, cls in ODD_PARENTS do
					if parent:IsA(cls) then
						add(d, "скрипт внутри " .. parent.ClassName)
						break
					end
				end
				if parent:IsA("LuaSourceContainer") then
					add(d, "скрипт внутри скрипта")
				end
			end
			local ok, src = pcall(function(): string
				return (d :: any).Source
			end)
			if not ok or type(src) ~= "string" then
				add(d, "Source не читается")
			else
				local low = string.lower(src)
				for _, sig in SIGS do
					if string.find(low, sig[2]) then
						add(d, "сигнатура: " .. sig[1])
					end
				end
				if #src > 20000 then
					add(d, "очень длинный скрипт: " .. #src)
				end
				if longestToken(src) >= 200 then
					add(d, "длинная строка-данные без пробелов (base64?)")
				end
			end
		elseif d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction") then
			r.remotes += 1
			add(d, "Remote/Bindable внутри ассета")
		elseif d:IsA("BinaryStringValue") then
			r.bigStrings += 1
			add(d, "BinaryStringValue")
		elseif d:IsA("StringValue") and #d.Value > 200 then
			r.bigStrings += 1
			add(d, "большой StringValue: " .. #d.Value)
		elseif d:IsA("Humanoid") then
			r.humanoids += 1
		elseif d:IsA("Animation") then
			r.animations += 1
		elseif d:IsA("Sound") then
			r.sounds += 1
		elseif d:IsA("ClickDetector") or d:IsA("ProximityPrompt") then
			r.prompts += 1
		end
	end
	if #r.findings > 0 then
		r.verdict = "suspicious"
	elseif r.scripts > 0 then
		r.verdict = "scripts"
	end
	return r
end

-- LoadAsset без парента → vet → Destroy. Возвращает отчёт или ошибку (например «User is not authorized»).
function Vetter.vetId(id: number): (Report?, string?)
	local IS = game:GetService("InsertService")
	local ok, res = pcall(function(): Instance
		return IS:LoadAsset(id)
	end)
	if not ok then
		return nil, tostring(res)
	end
	local holder = res :: Instance
	local r = Vetter.vet(holder)
	r.name = tostring(id) .. " " .. r.name
	holder:Destroy()
	return r, nil
end

-- Однострочный итог + находки (для вывода execute_luau и записи в ledger)
function Vetter.line(r: Report): string
	local s = string.format("%s: %s | частей %d (мешей %d), %.0f×%.0f×%.0f | скриптов %d, remote %d, строк %d, humanoid %d, анимаций %d, звуков %d, prompt/click %d", r.name, r.verdict, r.parts, r.meshes, r.size.X, r.size.Y, r.size.Z, r.scripts, r.remotes, r.bigStrings, r.humanoids, r.animations, r.sounds, r.prompts)
	for i, f in r.findings do
		if i > 20 then
			s ..= string.format("\n  … ещё %d", #r.findings - 20)
			break
		end
		s ..= string.format("\n  [%s] %s — %s", f.class, f.path, f.reason)
	end
	return s
end

return Vetter
