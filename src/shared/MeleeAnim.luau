--!strict
-- Анимации холодного оружия (процедурные, без готовых анимаций Roblox): взмахи и осмотр (клавиша F, как в CS).
-- Всё считается в системе руки: X вправо, Y вверх, -Z вперёд от камеры. Tool.Grip = baseGrip * поза⁻¹, поэтому поза двигает
-- оружие вместе с кистью. Осмотр может ещё двигать части модели (у бабочки — рукояти вокруг шарнира).

local TweenService = game:GetService("TweenService")
local Config = require(script.Parent:WaitForChild("Config"))

local MeleeAnim = {}

export type Pose = { t: number, cf: CFrame }
export type InspectFrame = { grip: CFrame, parts: { [string]: CFrame }? } -- parts: префикс имени детали → поворот в системе рукояти (вокруг pivot)

local CF, ANG = CFrame.new, CFrame.Angles
local rad = math.rad

-- Взмахи -----------------------------------------------------------------------------------------------------------
MeleeAnim.STYLES = {
	-- колющий: назад — резкий выпад — возврат
	stab = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0, 0.05, 0.45) * ANG(0.15, 0, 0) },
		{ t = 0.5, cf = CF(0, -0.05, -0.95) * ANG(-0.1, 0, 0) },
		{ t = 1, cf = CFrame.identity },
	},
	-- рубящий по диагонали: замах за плечо — широкая дуга вниз-влево — возврат
	slash = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.3, 0.15, 0.3) * ANG(0.6, -0.55, -0.35) },
		{ t = 0.55, cf = CF(-0.4, -0.2, -0.75) * ANG(-0.85, 0.85, 0.3) },
		{ t = 1, cf = CFrame.identity },
	},
	-- сверху вниз: тяжёлый замах и удар
	smash = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.38, cf = CF(0.1, 0.55, 0.25) * ANG(1.15, 0, 0) },
		{ t = 0.6, cf = CF(0, -0.45, -0.75) * ANG(-1.05, 0, 0) },
		{ t = 1, cf = CFrame.identity },
	},
	-- топор: замах над плечом и косой удар вниз с проходом
	chop = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.4, cf = CF(0.25, 0.65, 0.3) * ANG(1.25, -0.25, -0.35) },
		{ t = 0.62, cf = CF(-0.2, -0.5, -0.9) * ANG(-0.95, 0.35, 0.25) },
		{ t = 1, cf = CFrame.identity },
	},
	-- бита: боковой замах — бита ложится плашмя, уходит вправо-назад и широкой дугой слева направо через перед
	side = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.5, 0.05, 0.4) * ANG(0, rad(-45), 0) * ANG(0, 0, rad(-85)) },
		{ t = 0.55, cf = CF(-0.4, 0, -0.55) * ANG(0, rad(100), 0) * ANG(0, 0, rad(-85)) },
		{ t = 0.75, cf = CF(-0.55, 0, -0.3) * ANG(0, rad(130), 0) * ANG(0, 0, rad(-80)) },
		{ t = 1, cf = CFrame.identity },
	},
	-- тяжёлый (топор, кувалда): поднять над головой, пауза, мощный удар вниз перед собой и отдача
	heavy = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.42, cf = CF(0, 0.8, 0.25) * ANG(rad(80), 0, 0) },
		{ t = 0.62, cf = CF(0, 0.85, 0.3) * ANG(rad(88), 0, 0) },
		{ t = 0.74, cf = CF(0, -0.55, -1.0) * ANG(rad(-75), 0, 0) },
		{ t = 0.84, cf = CF(0, -0.45, -0.9) * ANG(rad(-70), 0, 0) },
		{ t = 1, cf = CFrame.identity },
	},
	-- катана: быстрый длинный косой рез слева направо вниз с проходом
	katana = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.25, cf = CF(0.5, 0.3, 0.25) * ANG(0.45, -0.95, -0.65) },
		{ t = 0.5, cf = CF(-0.65, -0.2, -0.85) * ANG(-0.35, 0.95, 0.65) },
		{ t = 0.7, cf = CF(-0.75, -0.25, -0.65) * ANG(-0.45, 1.1, 0.75) },
		{ t = 1, cf = CFrame.identity },
	},
	-- керамбит: короткий быстрый «коготь» наискось
	swipe = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.3, 0.1, 0.15) * ANG(0.35, -0.5, -0.8) },
		{ t = 0.55, cf = CF(-0.45, -0.1, -0.6) * ANG(-0.45, 0.7, 0.55) },
		{ t = 1, cf = CFrame.identity },
	},
} :: { [string]: { Pose } }

-- Доля времени взмаха, в которую удар попадает по цели (сервер применяет урон в этот момент)
MeleeAnim.HIT = { stab = 0.5, slash = 0.55, smash = 0.6, chop = 0.62, side = 0.55, heavy = 0.74, katana = 0.5, swipe = 0.55 } :: { [string]: number }

function MeleeAnim.poseAt(style: string, u: number): CFrame
	local keys = MeleeAnim.STYLES[style]
	if not keys then
		return CFrame.identity
	end
	for i = 2, #keys do
		local a, b = keys[i - 1], keys[i]
		if u <= b.t then
			local k = (u - a.t) / math.max(1e-4, b.t - a.t)
			k = TweenService:GetValue(k, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
			return a.cf:Lerp(b.cf, k)
		end
	end
	return CFrame.identity
end

-- Осмотр -----------------------------------------------------------------------------------------------------------
local function ease(k: number): number
	k = math.clamp(k, 0, 1)
	return k * k * (3 - 2 * k)
end

-- 0 → 1 → 0 за время u
local function bell(u: number): number
	return math.sin(math.pi * math.clamp(u, 0, 1))
end

-- Нож: остриём вверх, чуть присесть, подбросить с закруткой вокруг собственной оси (как бутылку) и поймать
local function knife(u: number): InspectFrame
	local hold = Config.MeleeHold.Knife or Config.MeleeHold.default
	local axis = hold.dir.Unit -- ось ножа в системе кисти
	local dip = math.sin(math.pi * math.clamp(u / 0.16, 0, 1)) -- замах перед броском
	local k = math.clamp((u - 0.16) / 0.64, 0, 1)
	local toss = math.sin(math.pi * k) -- подброс и возврат
	local spin = ease(k) * math.pi * 6 -- три оборота вокруг оси лезвия
	return { grip = CF(0.02, 1.1 * toss - 0.18 * dip, 0.05 * toss) * CFrame.fromAxisAngle(axis, spin) }
end

-- Катана: поднять, повернуть плоскостью к камере, повести остриём и вернуть
local function katana(u: number): InspectFrame
	local lift = bell(u)
	local roll = ease(u / 0.35) - ease((u - 0.65) / 0.35)
	local tip = ease((u - 0.3) / 0.25) - ease((u - 0.65) / 0.25)
	return { grip = CF(-0.15 * lift, 0.35 * lift, 0.15 * lift) * ANG(rad(25) * tip, rad(-35) * roll, rad(95) * roll) }
end

-- Керамбит: два быстрых оборота на пальце (вокруг кольца) и остановка
local function karambit(u: number): InspectFrame
	local lift = bell(u * 1.1)
	local spin = ease((u - 0.1) / 0.7) * math.pi * 4
	local twist = ease((u - 0.2) / 0.3) - ease((u - 0.8) / 0.2)
	return { grip = CF(0.05 * lift, 0.3 * lift, -0.1 * lift) * ANG(spin, 0, 0) * ANG(0, rad(35) * twist, rad(-20) * twist) }
end

-- Бабочка: раскрыть-сложить рукояти вокруг шарнира (две половинки в разные стороны), провернуть и закрыть
local function butterfly(u: number): InspectFrame
	local lift = bell(u * 1.05)
	local fan = ease((u - 0.1) / 0.3) - ease((u - 0.45) / 0.3) -- 0 → 1 → 0: рукояти расходятся
	local flip = ease((u - 0.5) / 0.4) * math.pi * 2
	return {
		grip = CF(0.05 * lift, 0.35 * lift, -0.1 * lift) * ANG(flip, 0, rad(-20) * lift),
		parts = { BiteHandle = ANG(rad(170) * fan, 0, 0), Handle = ANG(rad(-170) * fan, 0, 0) },
	}
end

-- Осмотр по оружию: длительность (с) и функция времени. Ключ — id оружия из Config.Weapons.
MeleeAnim.INSPECT = {
	Knife = { time = 2.2, frame = knife },
	Katana = { time = 2.6, frame = katana },
	Karambit = { time = 1.5, frame = karambit },
	Balisong = { time = 1.8, frame = butterfly },
} :: { [string]: { time: number, frame: (number) -> InspectFrame } }

return MeleeAnim
