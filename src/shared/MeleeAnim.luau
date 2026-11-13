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
export type InspectFrame = { grip: CFrame, hand: CFrame?, model: CFrame?, parts: { [string]: CFrame }?, open: number? }

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
-- Ножи (2026-11-11, как в CS2): быстрые серии — рез справа, обратный рез слева, укол. Стилет — короткие уколы с двух сторон.
MeleeAnim.STYLES.knifeR = {
	{ t = 0, cf = CFrame.identity },
	{ t = 0.22, cf = CF(0.45, 0.25, 0.25) * ANG(0.3, -0.5, -0.9) }, -- замах к правому плечу
	{ t = 0.5, cf = CF(-0.35, -0.1, -1.0) * ANG(-1.2, 0.6, 0.8) }, -- лезвие проходит через цель справа налево
	{ t = 0.7, cf = CF(-0.6, -0.3, -0.7) * ANG(-1.3, 0.8, 1.0) }, -- проход
	{ t = 1, cf = CFrame.identity },
}
MeleeAnim.STYLES.knifeL = mirrored(MeleeAnim.STYLES.knifeR)
MeleeAnim.STYLES.knifeStab = {
	{ t = 0, cf = CFrame.identity },
	{ t = 0.25, cf = CF(0.15, -0.1, 0.45) * ANG(0.25, 0.15, 0) }, -- кисть к себе
	{ t = 0.5, cf = CF(-0.05, 0.05, -1.4) * ANG(-1.25, 0.2, 0) }, -- выпад
	{ t = 0.65, cf = CF(-0.05, 0, -1.2) * ANG(-1.15, 0.15, 0) },
	{ t = 1, cf = CFrame.identity },
}
MeleeAnim.STYLES.jab = {
	{ t = 0, cf = CFrame.identity },
	{ t = 0.2, cf = CF(0.12, -0.05, 0.3) * ANG(0.15, 0.1, 0) },
	{ t = 0.45, cf = CF(0.05, 0.05, -1.5) * ANG(-1.35, 0.1, 0) },
	{ t = 0.6, cf = CF(0.05, 0, -1.3) * ANG(-1.3, 0.1, 0) },
	{ t = 1, cf = CFrame.identity },
}
MeleeAnim.STYLES.jabL = mirrored(MeleeAnim.STYLES.jab)
MeleeAnim.STYLES.swipeL = mirrored(MeleeAnim.STYLES.swipe)
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
-- раскрытие пальцев кисти ножа сейчас (0 — кулак, 1 — раскрыта); ставит FxController из InspectFrame.open
MeleeAnim.open = 0

-- Доля времени взмаха, в которую удар попадает по цели (сервер применяет урон в этот момент)
MeleeAnim.HIT = { stab = 0.5, slash = 0.55, smash = 0.6, chop = 0.62, side = 0.55, heavy = 0.74, katana = 0.5, swipe = 0.55 } :: { [string]: number }
MeleeAnim.HIT.katanaL, MeleeAnim.HIT.katanaUp, MeleeAnim.HIT.sideL = 0.5, 0.5, 0.55
MeleeAnim.CAM.katanaL, MeleeAnim.CAM.katanaUp, MeleeAnim.CAM.sideL = { 0.6, -2.6, -2.8 }, { 2.2, 0.8, 1.2 }, { 0.6, -3.0, -2.6 }
MeleeAnim.HIT.knifeR, MeleeAnim.HIT.knifeL, MeleeAnim.HIT.knifeStab, MeleeAnim.HIT.jab, MeleeAnim.HIT.jabL, MeleeAnim.HIT.swipeL = 0.5, 0.5, 0.5, 0.45, 0.45, 0.55
MeleeAnim.CAM.knifeR, MeleeAnim.CAM.knifeL, MeleeAnim.CAM.knifeStab = { 0.4, 1.2, 1.4 }, { 0.4, -1.2, -1.4 }, { 0.8, 0.3, 0.5 }
MeleeAnim.CAM.jab, MeleeAnim.CAM.jabL, MeleeAnim.CAM.swipeL = { 0.6, 0.2, 0.4 }, { 0.6, -0.2, -0.4 }, { 0.4, -1.4, -1.6 }

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

-- Доля пути от a к b в «степени» k (CFrame.identity:Lerp — поворот и сдвиг по дуге)
local function part(a: CFrame, b: CFrame, k: number): CFrame
	return a * CFrame.identity:Lerp(a:Inverse() * b, k)
end

-- Поза по ключам: сплайн Катмулла — Рома в пространстве CFrame (кубическая кривая Безье через соседние ключи). Кривая проходит через
-- каждый ключ без остановки (раньше каждый отрезок шёл с разгоном и торможением — нож «дёргался» в каждой позе). Разгон и торможение
-- остаются только в начале и в конце взмаха.
function MeleeAnim.poseAt(style: string, u: number): CFrame
	local keys = MeleeAnim.STYLES[style]
	if not keys then
		return CFrame.identity
	end
	u = math.clamp(u, 0, 1)
	local n = #keys
	for i = 2, n do
		local a, b = keys[i - 1], keys[i]
		if u <= b.t then
			local k = math.clamp((u - a.t) / math.max(1e-4, b.t - a.t), 0, 1)
			if i == 2 then
				k = TweenService:GetValue(k, Enum.EasingStyle.Sine, Enum.EasingDirection.In) * 0.5 + k * 0.5
			elseif i == n then
				k = TweenService:GetValue(k, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
			end
			local p0 = if i > 2 then keys[i - 2].cf else a.cf
			local p3 = if i < n then keys[i + 1].cf else b.cf
			local c1 = a.cf * CFrame.identity:Lerp(p0:Inverse() * b.cf, 1 / 6)
			local c2 = b.cf * CFrame.identity:Lerp(p3:Inverse() * a.cf, 1 / 6)
			local q0, q1, q2 = part(a.cf, c1, k), part(c1, c2, k), part(c2, b.cf, k)
			return part(part(q0, q1, k), part(q1, q2, k), k)
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

-- Нож, осмотр по ритму CS2 (CT Knife): кисть поднимается к центру, клинок вертикально лицом к камере — пауза; поворот на ребро и наклон
-- влево с показом второй стороны — пауза; обратно вертикально лицом — пауза; возврат. Между фазами нож «дышит», не замирая.
local function knifeShow(u: number, _hinge: Vector3?): InspectFrame
	local function seg(a: number, b: number): number
		return silk((u - a) / (b - a))
	end
	local up = seg(0, 0.12) - seg(0.9, 1) -- кисть поднята
	local face = rad(80) * (seg(0.03, 0.14) - seg(0.86, 0.97)) -- плоскость клинка к камере
	local flip = rad(-160) * (seg(0.32, 0.46) - seg(0.66, 0.78)) -- поворот на другую сторону
	local tiltL = rad(32) * (seg(0.34, 0.48) - seg(0.66, 0.8)) -- наклон острия влево
	local breathe = 0.035 * math.sin(u * math.pi * 6) * up
	local pos = CF(-0.18 * up, 0.28 * up + breathe * 0.4, 0.08 * up)
	local hold = Config.MeleeHold.Knife or Config.MeleeHold.default
	local axis = hold.dir.Unit
	return {
		grip = pos * ANG(rad(10) * up + breathe, 0, tiltL) * CFrame.fromAxisAngle(axis, face + flip),
		hand = pos * ANG(0, 0, tiltL * 0.6),
	}
end

-- Осмотр по ключевым позам (ножи из кейса, по видео CS2). Ключ: { t, x, y, z, pitch, tilt, roll } — доля времени; сдвиг кисти (студы:
-- вправо, вверх, назад); наклон вперёд, наклон острия влево (90 — клинок горизонтально влево, 180 — остриём вниз, обратный хват) и
-- поворот клинка вокруг своей оси (градусы). Между ключами — плавный переход с остановкой (позы держатся), поверх — лёгкое «дыхание».
type ShowKey = { number }
local function keyed(keys: { ShowKey }): (number, Vector3?) -> InspectFrame
	return function(u: number, _hinge: Vector3?): InspectFrame
		u = math.clamp(u, 0, 1)
		local a, b = keys[1], keys[#keys]
		for i = 2, #keys do
			if u <= keys[i][1] then
				a, b = keys[i - 1], keys[i]
				break
			end
		end
		local k = silk((u - a[1]) / math.max(1e-4, b[1] - a[1]))
		local function f(i: number): number
			return a[i] + (b[i] - a[i]) * k
		end
		local env = math.clamp(math.min(u / 0.12, (1 - u) / 0.1), 0, 1)
		local br = 0.03 * math.sin(u * math.pi * 6) * env
		local axis = Config.MeleeHold.default.dir.Unit
		local x, y, z, tilt = f(2), f(3), f(4), rad(f(6))
		return {
			grip = CF(x, y + br * 0.4, z) * ANG(rad(f(5)) + br, 0, tilt) * CFrame.fromAxisAngle(axis, rad(f(7))),
			hand = CF(x, y, z) * ANG(0, 0, tilt * 0.5),
		}
	end
end

-- Осмотр «кистью» (v3): поворачивается вся кисть вместе с ножом, как в CS2 (раньше крутился только нож в неподвижном кулаке).
-- Ключ: { t, x, y, z, rx, ry, rz, spin, open } — доля времени; сдвиг кисти (вправо, вверх, назад); поворот кисти в осях камеры
-- (rx — наклон вперёд/назад, ry — поворот вокруг вертикали, rz — наклон влево, 90 — клинок горизонтально влево), градусы;
-- spin — поворот ножа в пальцах (вокруг оси клинка или spinAxis через точку pivot в системе кисти, градусы); open — раскрытие пальцев 0…1.
local function wristKeys(keys: { ShowKey }, spinAxis: Vector3?, pivot: Vector3?): (number, Vector3?) -> InspectFrame
	local axis = spinAxis or Config.MeleeHold.default.dir.Unit
	local pv = CF(pivot or Vector3.zero)
	return function(u: number, _hinge: Vector3?): InspectFrame
		u = math.clamp(u, 0, 1)
		local a, b = keys[1], keys[#keys]
		for i = 2, #keys do
			if u <= keys[i][1] then
				a, b = keys[i - 1], keys[i]
				break
			end
		end
		local k = silk((u - a[1]) / math.max(1e-4, b[1] - a[1]))
		local function f(i: number): number
			return a[i] + (b[i] - a[i]) * k
		end
		local env = math.clamp(math.min(u / 0.12, (1 - u) / 0.1), 0, 1)
		local br = 0.025 * math.sin(u * math.pi * 6) * env
		local hand = CF(f(2), f(3) + br * 0.3, f(4)) * ANG(rad(f(5)) + br, rad(f(6)), rad(f(7)))
		return { grip = hand * pv * CFrame.fromAxisAngle(axis, rad(f(8))) * pv:Inverse(), hand = hand, open = f(9) }
	end
end

-- Huntsman (Tanto) и M9: клинок вертикально лицом — пауза, наклон влево с другой стороной — пауза, снова лицом, возврат
local showVertical = keyed({
	{ 0, 0, 0, 0, 0, 0, 0 },
	{ 0.12, -0.18, 0.28, 0.08, 10, 0, 80 },
	{ 0.32, -0.17, 0.3, 0.08, 8, 0, 75 },
	{ 0.46, -0.2, 0.3, 0.08, 10, 32, -80 },
	{ 0.64, -0.2, 0.31, 0.08, 8, 30, -75 },
	{ 0.78, -0.18, 0.28, 0.08, 10, 0, 80 },
	{ 0.88, -0.17, 0.28, 0.08, 8, 0, 78 },
	{ 1, 0, 0, 0, 0, 0, 0 },
})
-- Survival (KA-BAR), по видео: кисть вытягивается к центру экрана, клинок вертикально плашмя к камере — долгая пауза;
-- кисть кладёт клинок горизонтально остриём влево — пауза; снова вертикально и в стойку
local showSurvival = wristKeys({
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	{ 0.1, -0.42, 0.32, 0.15, 8, -10, 8, 75, 0 },
	{ 0.4, -0.4, 0.34, 0.15, 6, -12, 6, 72, 0 },
	{ 0.52, -0.5, 0.18, 0, 0, -10, 85, 85, 0 },
	{ 0.76, -0.5, 0.2, 0, 3, -8, 82, 82, 0 },
	{ 0.88, -0.4, 0.32, 0.15, 8, -10, 8, 75, 0 },
	{ 1, 0, 0, 0, 0, 0, 0, 0, 0 },
})
-- Bowie, по видео: нож подбрасывается в обратный хват (пальцы раскрываются), кисть ладонью вверх — клинок лежит вдоль предплечья
-- остриём вправо — пауза; кисть поворачивается, клинок свисает остриём вниз — пауза; обратно вдоль руки, подброс в прямой хват
local showBowie = wristKeys({
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	{ 0.06, -0.1, 0.15, 0.05, -20, 0, 30, 60, 0.8 },
	{ 0.14, -0.4, 0.4, 0.1, 0, 0, -100, 180, 0.1 },
	{ 0.38, -0.4, 0.42, 0.1, 3, 0, -96, 180, 0 },
	{ 0.5, -0.45, 0.78, 0.1, 0, 20, -175, 290, 0 },
	{ 0.7, -0.45, 0.8, 0.1, 3, 18, -172, 290, 0 },
	{ 0.8, -0.4, 0.4, 0.1, 0, 0, -100, 180, 0 },
	{ 0.9, -0.1, 0.15, 0.05, -20, 0, 30, 300, 0.8 },
	{ 1, 0, 0, 0, 0, 0, 0, 360, 0 },
})
-- M9, по видео: клинок вертикально лицом — пауза; кисть поворачивается, клинок наклоняется влево и показывает обратную сторону с пилой
-- на обухе — пауза; обратно лицом
local showM9 = keyed({
	{ 0, 0, 0, 0, 0, 0, 0 },
	{ 0.12, -0.16, 0.27, 0.06, 8, 0, 82 },
	{ 0.34, -0.15, 0.29, 0.06, 6, -6, 78 },
	{ 0.48, -0.26, 0.31, 0.14, 16, 42, -95 },
	{ 0.7, -0.27, 0.32, 0.14, 13, 38, -90 },
	{ 0.84, -0.16, 0.27, 0.06, 8, 0, 82 },
	{ 1, 0, 0, 0, 0, 0, 0 },
})
-- Kukri: изогнутый клинок поднят остриём влево-вверх плашмя к камере, покачивание, возврат
local showKukri = keyed({
	{ 0, 0, 0, 0, 0, 0, 0 },
	{ 0.14, -0.15, 0.3, 0.05, 15, 25, 70 },
	{ 0.4, -0.12, 0.33, 0.05, 10, 32, 60 },
	{ 0.62, -0.16, 0.3, 0.05, 15, 20, 82 },
	{ 0.85, -0.15, 0.3, 0.05, 12, 26, 72 },
	{ 1, 0, 0, 0, 0, 0, 0 },
})
-- Stiletto: вертикально, наклон вправо, другая сторона, горизонтально влево — пауза, вертикально, наклон и возврат
local showStiletto = keyed({
	{ 0, 0, 0, 0, 0, 0, 0 },
	{ 0.1, -0.15, 0.25, 0.05, 0, 0, 80 },
	{ 0.22, -0.12, 0.26, 0.05, 0, -35, 80 },
	{ 0.34, -0.15, 0.26, 0.05, 0, 0, 260 },
	{ 0.46, -0.18, 0.2, 0.05, 0, 88, 270 },
	{ 0.6, -0.18, 0.21, 0.05, 2, 86, 265 },
	{ 0.72, -0.15, 0.25, 0.05, 0, 0, 440 },
	{ 0.85, -0.12, 0.25, 0.05, 0, -30, 440 },
	{ 1, 0, 0, 0, 0, 0, 360 },
})

-- Karambit, по видео: пальцы раскрываются, нож делает оборот на кольце (ось кольца — к камере, поворот против часовой: клинок уходит
-- вправо, вверх и назад вниз); кулак поднят к центру экрана тыльной стороной к камере, клинок свисает из-под кулака влево — пауза
-- с покачиванием; ещё оборот в ту же сторону и в стойку
local KARAMBIT_RING = Vector3.new(0.1, 0.5, -0.3) -- кольцо в системе кисти: вокруг него крутится нож
local karambitWrist = wristKeys({
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	{ 0.08, -0.3, 0.3, -0.2, 0, 45, 0, 0, 0.3 },
	{ 0.16, -0.5, 0.45, -0.35, 0, 75, 10, -40, 0.55 },
	{ 0.46, -0.5, 0.47, -0.35, 0, 75, 10, -720, 0.55 },
	{ 0.52, -0.5, 0.45, -0.35, 0, 75, 10, -720, 0 },
	{ 0.66, -0.48, 0.47, -0.35, 5, 95, 20, -720, 0 },
	{ 0.8, -0.5, 0.45, -0.35, 0, 75, 10, -720, 0 },
	{ 0.84, -0.5, 0.45, -0.35, 0, 75, 10, -720, 0.55 },
	{ 0.96, -0.15, 0.15, -0.1, 0, 20, 0, -1080, 0.6 },
	{ 1, 0, 0, 0, 0, 0, 0, -1080, 0 },
}, Vector3.zAxis, KARAMBIT_RING)
-- пока пальцы раскрыты, нож опускается так, чтобы кольцо сидело на указательном пальце (в хвате кольцо выше кулака)
local function karambitShow(u: number, h: Vector3?): InspectFrame
	local f = karambitWrist(u, h)
	local hand = f.hand :: CFrame
	local drop = math.clamp((f.open or 0) / 0.55, 0, 1)
	f.grip = hand * CF(0, -0.35 * drop, 0) * hand:Inverse() * f.grip
	return f
end
-- Butterfly, по видео (с нуля): кисть поворачивается ладонью вверх, нож поперёк руки; флип — вторая рукоять и клинок делают оборот,
-- нож раскрыт «буквой V» (рукояти разведены) клинком вверх-вправо — пауза с покачиванием; закрывающий флип и возврат.
-- Углы рукояти и клинка к концу кратны 2π: модель возвращается в исходный вид.
local butterflyWrist = wristKeys({
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	{ 0.12, -0.45, 0.45, 0.05, -15, 30, -55, 0, 0.5 },
	{ 0.3, -0.45, 0.45, 0.05, -15, 30, -55, 0, 0.3 },
	{ 0.45, -0.47, 0.48, 0.05, -12, 26, -50, 0, 0.2 },
	{ 0.8, -0.45, 0.46, 0.05, -15, 30, -55, 0, 0.5 },
	{ 1, 0, 0, 0, 0, 0, 0, 0, 0 },
})
local function butterflyShow(u: number, h: Vector3?): InspectFrame
	local function seg(a: number, b: number): number
		return silk((u - a) / (b - a))
	end
	local f = butterflyWrist(u, h)
	local handle2 = -math.pi * seg(0.14, 0.3) - 1.3 * seg(0.32, 0.42) + 1.3 * seg(0.8, 0.88) - math.pi * seg(0.86, 0.97)
	local blade = -math.pi * seg(0.17, 0.32) + settle(u, 0.32, 0.1) - math.pi * seg(0.86, 0.97)
	f.parts = { BiteHandle = ANG(handle2, 0, 0), Blade = ANG(blade, 0, 0) }
	return f
end
-- Осмотр по оружию: длительность (с) и функция времени. Ключ — id оружия из Config.Weapons.
MeleeAnim.INSPECT = {
	Knife = { time = 4.4, frame = knifeShow },
	Katana = { time = 2.6, frame = katana },
	Karambit = { time = 3.8, frame = karambitShow },
	Balisong = { time = 4.4, frame = butterflyShow },
} :: { [string]: { time: number, frame: (number, Vector3?) -> InspectFrame } }
-- ножи из кейса — по видео CS2 (Huntsman = Tanto, Survival = KA-BAR)
MeleeAnim.INSPECT.Tanto = { time = 4.4, frame = showVertical }
MeleeAnim.INSPECT.M9Bayonet = { time = 4.6, frame = showM9 }
MeleeAnim.INSPECT.KABAR = { time = 5.2, frame = showSurvival }
MeleeAnim.INSPECT.BowieKnife = { time = 5.0, frame = showBowie }
MeleeAnim.INSPECT.Kukri = { time = 3.2, frame = showKukri }
MeleeAnim.INSPECT.Stiletto = { time = 4.0, frame = showStiletto }

-- Доставание ножа (клавиша 3): кисть выходит из правого нижнего угла, клинок наклонён остриём вперёд и встаёт в стойку с небольшим
-- перелётом и докатом (по ритму CS2). hand — сдвиг кисти вместе с ножом, spin — поворот ножа в кисти.
export type DrawFrame = { hand: CFrame, spin: CFrame, open: number? }
-- parts (необязательно) — повороты подвижных частей модели при доставании (бабочка раскрывается), как InspectFrame.parts
local function knifeDraw(u: number): DrawFrame
	local rise = silk(u / 0.55)
	local over = math.sin(math.pi * math.clamp((u - 0.35) / 0.45, 0, 1)) -- перелёт вверх и назад в стойку
	local tip = 1 - silk(u / 0.6) -- остриё наклонено вперёд, потом встаёт
	local hand = CF(0.5 * (1 - rise), -1.1 * (1 - rise) + 0.06 * over, 0.4 * (1 - rise)) * ANG(-0.5 * (1 - rise) + 0.1 * over, 0, -0.35 * (1 - rise))
	return { hand = hand, spin = ANG(rad(-75) * tip + rad(8) * over + settle(u, 0.8, 0.05), 0, 0) }
end

-- Доставание из правого нижнего угла с перелётом; from — откуда выходит кисть, spin(u, over) — что делает нож в кисти
local function rising(from: CFrame, spin: (number, number) -> CFrame): (number) -> DrawFrame
	return function(u: number): DrawFrame
		local rise = silk(u / 0.55)
		local over = math.sin(math.pi * math.clamp((u - 0.35) / 0.45, 0, 1))
		local hand = CFrame.identity:Lerp(from, 1 - rise) * CF(0, 0.06 * over, 0) * ANG(0.1 * over, 0, 0)
		return { hand = hand, spin = spin(u, over) }
	end
end
local BELOW = CF(0.5, -1.1, 0.4) * ANG(-0.5, 0, -0.35) -- снизу справа
local SIDE = CF(1.0, -0.4, 0.3) * ANG(0, 0, -0.6) -- справа сбоку (Bowie)
-- клинок вверх: поднимается почти вертикально с небольшим наклоном назад (M9, Survival, Huntsman)
local function upright(u: number, over: number): CFrame
	return ANG(rad(25) * (1 - silk(u / 0.6)) + rad(6) * over + settle(u, 0.8, 0.04), 0, 0)
end
-- остриём вперёд, затем встаёт (как CT Knife)
local function tipUp(u: number, over: number): CFrame
	return ANG(rad(-75) * (1 - silk(u / 0.6)) + rad(8) * over + settle(u, 0.8, 0.05), 0, 0)
end

MeleeAnim.DRAW = {
	Knife = { time = 0.8, frame = knifeDraw },
	M9Bayonet = { time = 0.8, frame = rising(BELOW, upright) },
	KABAR = { time = 0.8, frame = rising(BELOW, upright) },
	Tanto = { time = 0.8, frame = rising(BELOW, upright) },
	BowieKnife = { time = 0.8, frame = rising(SIDE, tipUp) },
	-- Kukri: переворот в кисти на выходе
	Kukri = { time = 0.9, frame = rising(BELOW, function(u: number, _o: number): CFrame
		return ANG(-2 * math.pi * silk(u / 0.7) + settle(u, 0.7, 0.06), 0, 0)
	end) },
	-- Karambit, по видео: выходит справа, пальцы раскрываются — один оборот на кольце вперёд и в стойку
	Karambit = { time = 0.8, frame = function(u: number): DrawFrame
		local f = rising(SIDE, function(v: number, _o: number): CFrame
			local ring = CF(KARAMBIT_RING)
			return ring * ANG(0, 0, 2 * math.pi * silk((v - 0.1) / 0.5) - settle(v, 0.6, 0.12)) * ring:Inverse()
		end)(u)
		f.open = 0.7 * (silk((u - 0.06) / 0.08) - silk((u - 0.5) / 0.12))
		return f
	end },
	-- Stiletto: выходит сложенным, на середине лезвие выбрасывается щелчком
	Stiletto = { time = 0.9, frame = rising(BELOW, function(u: number, _o: number): CFrame
		return ANG(rad(-170) * (1 - silk((u - 0.45) / 0.12)) + settle(u, 0.57, 0.08), 0, 0)
	end) },
	-- Butterfly, по видео: выходит снизу сложенным, вторая рукоять делает оборот, клинок раскрывается вперёд (части — parts)
	Balisong = { time = 1.0, frame = rising(BELOW, function(u: number, over: number): CFrame
		return ANG(rad(-40) * (1 - silk(u / 0.6)) + rad(6) * over, 0, 0)
	end), parts = function(u: number): { [string]: CFrame }
		local function seg(a: number, b: number): number
			return silk((u - a) / (b - a))
		end
		return {
			BiteHandle = ANG(-2 * math.pi * seg(0.12, 0.6) + settle(u, 0.6, 0.12), 0, 0),
			Blade = ANG(-math.pi + math.pi * seg(0.2, 0.62) + settle(u, 0.62, 0.15), 0, 0),
		}
	end },
} :: { [string]: { time: number, frame: (number) -> DrawFrame, parts: ((number) -> { [string]: CFrame })? } }

return MeleeAnim
