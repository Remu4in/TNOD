--!strict
-- Анимации холодного оружия (процедурные, без готовых анимаций Roblox): взмахи и осмотр (клавиша F, как в CS).
-- Всё считается в системе руки: X вправо, Y вверх, -Z вперёд от камеры. Tool.Grip = baseGrip * поза⁻¹, поэтому поза двигает
-- оружие вместе с кистью. Осмотр может ещё двигать части модели (у бабочки — рукояти вокруг шарнира).

local TweenService = game:GetService("TweenService")
local Config = require(script.Parent:WaitForChild("Config"))

local MeleeAnim = {}

export type Pose = { t: number, cf: CFrame }
-- grip — поза оружия; hand — поза кисти от первого лица (по умолчанию как у оружия): у ножа и керамбита оружие крутится само, а кисть остаётся на месте;
-- model — вращение всей модели в её системе (вокруг рукояти: флипы бабочки); parts: префикс имени детали → поворот в системе рукояти (вокруг шарнира)
export type InspectFrame = { grip: CFrame, hand: CFrame?, model: CFrame?, parts: { [string]: CFrame }? }

local CF, ANG = CFrame.new, CFrame.Angles
local rad = math.rad

-- Взмахи -----------------------------------------------------------------------------------------------------------
-- Поза двигает оружие вместе с кистью (в первом лице — и саму кисть, см. MeleeAnim.live), в третьем лице — всю руку.
-- Ключ с t = MeleeAnim.HIT[стиль] — момент попадания: поза в нём — «руки вытянуты, остриё в цели»; время ключей не менять
-- без изменения HIT (по нему сервер наносит урон).
MeleeAnim.STYLES = {
	-- колющий (ножи, бабочка): кисть к плечу, лезвие горизонтально вперёд — резкий выпад всей рукой с проходом и быстрый возврат
	stab = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.25, -0.2, 0.7) * ANG(0.35, 0.25, -0.1) },
		{ t = 0.5, cf = CF(-0.1, 0.05, -1.35) * ANG(-1.1, 0.3, 0) },
		{ t = 0.68, cf = CF(-0.1, 0, -1.1) * ANG(-1.05, 0.25, 0) },
		{ t = 1, cf = CFrame.identity },
	},
	-- рубящий по диагонали (мачете): замах за правое плечо, широкая дуга вниз-влево через перед и проход
	slash = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.6, 0.4, 0.4) * ANG(0.6, -0.5, -1.1) },
		{ t = 0.55, cf = CF(-0.55, -0.35, -1.0) * ANG(-1.5, 0.55, 1.0) },
		{ t = 0.75, cf = CF(-0.7, -0.5, -0.85) * ANG(-1.65, 0.7, 1.2) },
		{ t = 1, cf = CFrame.identity },
	},
	-- сверху вниз (лом): тяжёлый замах за голову и удар вниз с отскоком
	smash = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.38, cf = CF(0.15, 0.7, 0.45) * ANG(1.5, 0, -0.15) },
		{ t = 0.6, cf = CF(0, -0.6, -1.0) * ANG(-1.55, 0, 0.1) },
		{ t = 0.8, cf = CF(0, -0.4, -0.8) * ANG(-1.2, 0, 0.05) },
		{ t = 1, cf = CFrame.identity },
	},
	-- топор: замах над плечом и косой удар вниз с проходом
	chop = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.4, cf = CF(0.3, 0.75, 0.35) * ANG(1.35, -0.3, -0.4) },
		{ t = 0.62, cf = CF(-0.2, -0.6, -1.0) * ANG(-1.1, 0.35, 0.3) },
		{ t = 1, cf = CFrame.identity },
	},
	-- бита: боковой замах — бита ложится плашмя, уходит вправо-назад и широкой дугой слева направо через перед, корпус «вслед»
	side = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.75, 0.05, 0.55) * ANG(0, rad(-70), 0) * ANG(0, 0, rad(-85)) },
		{ t = 0.55, cf = CF(-0.55, 0, -0.75) * ANG(0, rad(115), 0) * ANG(0, 0, rad(-85)) },
		{ t = 0.78, cf = CF(-0.8, 0, -0.4) * ANG(0, rad(150), 0) * ANG(0, 0, rad(-80)) },
		{ t = 1, cf = CFrame.identity },
	},
	-- тяжёлый (кувалда, топор): поднять над головой, пауза, мощный удар вниз перед собой, отдача
	heavy = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.42, cf = CF(0, 0.95, 0.35) * ANG(rad(95), 0, 0) },
		{ t = 0.62, cf = CF(0, 1.0, 0.4) * ANG(rad(105), 0, 0) },
		{ t = 0.74, cf = CF(0, -0.7, -1.1) * ANG(rad(-90), 0, 0) },
		{ t = 0.86, cf = CF(0, -0.55, -0.95) * ANG(rad(-78), 0, 0) },
		{ t = 1, cf = CFrame.identity },
	},
	-- катана: быстрый длинный косой рез от плеча вниз-влево с проходом и коротким «стряхиванием»
	katana = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.25, cf = CF(0.6, 0.4, 0.3) * ANG(0.5, -1.0, -0.8) },
		{ t = 0.5, cf = CF(-0.75, -0.3, -0.95) * ANG(-0.5, 1.05, 0.8) },
		{ t = 0.7, cf = CF(-0.9, -0.4, -0.7) * ANG(-0.65, 1.25, 0.95) },
		{ t = 1, cf = CFrame.identity },
	},
	-- керамбит: короткий быстрый «коготь» наискось и обратный росчерк
	swipe = {
		{ t = 0, cf = CFrame.identity },
		{ t = 0.3, cf = CF(0.4, 0.15, 0.2) * ANG(0.45, -0.6, -1.0) },
		{ t = 0.55, cf = CF(-0.55, -0.15, -0.7) * ANG(-0.6, 0.85, 0.7) },
		{ t = 0.78, cf = CF(-0.35, 0, -0.4) * ANG(-0.3, 0.4, 0.2) },
		{ t = 1, cf = CFrame.identity },
	},
} :: { [string]: { Pose } }

-- Зеркальная поза (удар с другой стороны): отражение относительно плоскости X = 0
local function mirror(cf: CFrame): CFrame
	local x, y, z, r11, r12, r13, r21, r22, r23, r31, r32, r33 = cf:GetComponents()
	return CFrame.new(-x, y, z, r11, -r12, -r13, -r21, r22, r23, -r31, r32, r33)
end

local function mirrored(keys: { Pose }): { Pose }
	local out: { Pose } = {}
	for _, k in keys do
		table.insert(out, { t = k.t, cf = mirror(k.cf) })
	end
	return out
end

-- Удары комбо (Config.MeleeCombo). Катана: 1 — справа (katana), 2 — слева (katanaL, зеркало), 3 — снизу вверх (katanaUp).
-- Бита: 1 — справа (side), 2 — слева (sideL, зеркало). Время ключа попадания у зеркальных такое же, как у исходных.
MeleeAnim.STYLES.katanaL = mirrored(MeleeAnim.STYLES.katana)
MeleeAnim.STYLES.sideL = mirrored(MeleeAnim.STYLES.side)
MeleeAnim.STYLES.katanaUp = {
	{ t = 0, cf = CFrame.identity },
	{ t = 0.25, cf = CF(0.45, -0.7, -0.2) * ANG(-2.3, -0.3, -0.4) }, -- клинок вниз-вперёд у правого бедра
	{ t = 0.5, cf = CF(-0.3, 0.4, -0.9) * ANG(-1.0, 0.5, 0.5) }, -- проходит вверх через цель
	{ t = 0.7, cf = CF(-0.4, 0.8, -0.5) * ANG(0.2, 0.6, 0.6) }, -- клинок над левым плечом
	{ t = 1, cf = CFrame.identity },
}

-- Толчок камеры в момент попадания (градусы: наклон, рыскание, крен — как у FxController.kickCamera): у каждого стиля свой
MeleeAnim.CAM = {
	stab = { 0.8, 0.4, 0.8 }, slash = { 0.9, 2.2, 2.2 }, smash = { 2.6, 0.4, 0.8 }, chop = { 2.4, 1.2, 1.6 }, side = { 0.6, 3.0, 2.6 },
	heavy = { 4.2, 0.6, 1.2 }, katana = { 0.6, 2.6, 2.8 }, swipe = { 0.4, 1.4, 1.6 },
} :: { [string]: { number } }

-- Текущая поза оружия (взмах или осмотр, система кисти): FxController обновляет каждый кадр, ViewModelController двигает по ней кисть
MeleeAnim.live = CFrame.identity

-- Доля времени взмаха, в которую удар попадает по цели (сервер применяет урон в этот момент)
MeleeAnim.HIT = { stab = 0.5, slash = 0.55, smash = 0.6, chop = 0.62, side = 0.55, heavy = 0.74, katana = 0.5, swipe = 0.55 } :: { [string]: number }
MeleeAnim.HIT.katanaL, MeleeAnim.HIT.katanaUp, MeleeAnim.HIT.sideL = 0.5, 0.5, 0.55
MeleeAnim.CAM.katanaL, MeleeAnim.CAM.katanaUp, MeleeAnim.CAM.sideL = { 0.6, -2.6, -2.8 }, { 2.2, 0.8, 1.2 }, { 0.6, -3.0, -2.6 }

-- Комбо: стиль и длительность удара с номером index (серия — Config.MeleeCombo; нет серии — единственный взмах Config.MeleeFx)
function MeleeAnim.stepAt(weaponId: string, index: number): (string, number)
	local combo = Config.MeleeCombo[weaponId]
	local step = if combo then combo.steps[index] else nil
	if step then
		return step.style, step.time
	end
	local fx = Config.MeleeFx[weaponId]
	return if fx then fx.style else "stab", if fx then fx.time else 0.3
end

-- Какой по счёту удар серии: prev — номер предыдущего удара этого игрока этим оружием (0 — нет), since — секунд с начала предыдущего.
-- Серия продолжается, если следующий удар в окне Config.MeleeCombo[..].window; после последнего удара — заново с первого.
function MeleeAnim.nextIndex(weaponId: string, prev: number, since: number): number
	local combo = Config.MeleeCombo[weaponId]
	if combo and prev >= 1 and prev < #combo.steps and since <= combo.window then
		return prev + 1
	end
	return 1
end

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

-- Нож (как в CS2): поднять, повернуть к камере правую грань клинка, затем левую и в конце небольшой росчерк остриём (острие описывает круг,
-- клинок делает оборот вокруг своей оси). Кисть только приподнимается: вращается нож, а не рука.
local function knife(u: number, _hinge: Vector3?): InspectFrame
	local hold = Config.MeleeHold.Knife or Config.MeleeHold.default
	local axis = hold.dir.Unit -- ось ножа в системе кисти
	local function seg(a: number, b: number): number
		return ease((u - a) / (b - a))
	end
	local lift = seg(0, 0.12) - seg(0.9, 1)
	-- поворот вокруг оси клинка: 0 → правая грань (+75°) → левая (−75°) → 0
	local roll = rad(75) * seg(0.12, 0.34) - rad(150) * seg(0.4, 0.62) + rad(75) * seg(0.84, 0.96)
	-- росчерк: острие кружит (полтора оборота малого круга) и клинок делает один оборот вокруг оси
	local k = seg(0.62, 0.84)
	local env = math.sin(math.pi * k)
	local phase = 2 * math.pi * 1.5 * k
	local tilt = ANG(0.5 * env * math.sin(phase), 0, 0.5 * env * math.cos(phase))
	local spin = 2 * math.pi * k
	return {
		grip = CF(0.02 * lift, 0.12 * lift, 0.05 * lift) * tilt * CFrame.fromAxisAngle(axis, roll + spin),
		hand = CF(0.02 * lift, 0.04 * lift, 0),
	}
end

-- Катана: поднять, повернуть плоскостью к камере, повести остриём и вернуть
local function katana(u: number): InspectFrame
	local lift = bell(u)
	local roll = ease(u / 0.35) - ease((u - 0.65) / 0.35)
	local tip = ease((u - 0.3) / 0.25) - ease((u - 0.65) / 0.25)
	return { grip = CF(-0.15 * lift, 0.35 * lift, 0.15 * lift) * ANG(rad(25) * tip, rad(-35) * roll, rad(95) * roll) }
end

-- Плавное нарастание без рывков: скорость и ускорение на концах равны нулю
local function silk(k: number): number
	k = math.clamp(k, 0, 1)
	return k * k * k * (k * (k * 6 - 15) + 10)
end

-- Затухающий докат после остановки в момент t0: оружие «садится» в руку
local function settle(u: number, t0: number, amount: number): number
	local d = u - t0
	if d <= 0 then
		return 0
	end
	return amount * silk(d / 0.02) * (1 - silk((u - 0.96) / 0.04)) * math.exp(-d * 16) * math.sin(d * 48)
end

-- Керамбит: подъём кисти, замах назад, два оборота на пальце с разгоном и докатом, показ обеих граней клинка, обратный оборот и возврат.
-- Вращается оружие вокруг кольца, кисть только подыгрывает.
local function karambit(u: number): InspectFrame
	local function seg(a: number, b: number): number
		return silk((u - a) / (b - a))
	end
	local lift = seg(0, 0.14) - seg(0.86, 1)
	local windup = -0.45 * (seg(0.06, 0.16) - seg(0.16, 0.26))
	local spin = 4 * math.pi * seg(0.16, 0.5) + settle(u, 0.5, 0.22) - 2 * math.pi * seg(0.72, 0.92) + settle(u, 0.92, -0.16)
	local show = rad(48) * seg(0.5, 0.58) - rad(92) * seg(0.58, 0.66) + rad(44) * seg(0.66, 0.73)
	local pos = CF(0.05 * lift, 0.3 * lift, -0.1 * lift)
	local wrist = 0.16 * math.sin(spin * 0.5) * math.clamp(lift, 0, 1)
	return {
		grip = pos * ANG(spin + windup, 0, 0) * ANG(0, show, rad(-14) * lift),
		hand = pos * ANG(wrist, 0, rad(4) * wrist),
	}
end

-- Бабочка по образцу CS2: движения перекрываются, поэтому нож не замирает между фазами.
-- Три тела вокруг шарнира у основания клинка: рукоять Handle (в кисти), вторая рукоять BiteHandle и клинок Blade.
-- К концу все углы кратны 2π: нож в исходном положении, кисть не крутится, а подыгрывает флипам.
local function butterfly(u: number, _hinge: Vector3?): InspectFrame
	local function seg(a: number, b: number): number
		return silk((u - a) / (b - a))
	end
	local present = seg(0, 0.1) - seg(0.92, 1)
	local handle2 = -math.pi * seg(0.09, 0.27) - math.pi * seg(0.56, 0.74) + settle(u, 0.74, 0.1)
	local blade = -math.pi * seg(0.2, 0.38) + settle(u, 0.38, 0.12) - math.pi * seg(0.84, 0.97) + settle(u, 0.97, 0.08)
	local spin = -2 * math.pi * seg(0.33, 0.6) - 2 * math.pi * seg(0.68, 0.9)
	local wrist = 0.14 * math.sin(spin * 0.5) * present
	return {
		grip = CF(0.04 * present, 0.18 * present, -0.1 * present) * ANG(wrist * 0.5, rad(80) * present, 0),
		hand = CF(0.04 * present, 0.08 * present, 0) * ANG(wrist, 0, 0),
		model = ANG(spin, 0, 0),
		parts = { BiteHandle = ANG(handle2, 0, 0), Blade = ANG(blade, 0, 0) },
	}
end

-- Осмотр по оружию: длительность (с) и функция времени. Ключ — id оружия из Config.Weapons.
MeleeAnim.INSPECT = {
	Knife = { time = 3.0, frame = knife },
	Katana = { time = 2.6, frame = katana },
	Karambit = { time = 3.4, frame = karambit },
	Balisong = { time = 4.2, frame = butterfly },
} :: { [string]: { time: number, frame: (number, Vector3?) -> InspectFrame } }

return MeleeAnim
