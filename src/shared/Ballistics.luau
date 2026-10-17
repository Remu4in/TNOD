--!strict
-- Баллистика: чистые функции без Roblox, одинаковые на клиенте и сервере.
-- Стрельба предсказуема: отдача идёт по закономерности (индекс выстрела в очереди), разброс — по фиксированной
-- «розетке», а не случайно. Первый выстрел одиночного оружия всегда точно в прицел.

export type Aim = {
	adsFov: number, -- поле зрения при прицеливании
	adsSpreadMul: number, -- множитель разброса в прицеле
	recoilPitch: number, -- градусов вверх за выстрел (в начале очереди)
	recoilYaw: number, -- размах горизонтального «зигзага», градусов
	recoilGrow: number, -- на сколько отдача растёт к 12-му выстрелу очереди (0 = не растёт)
	resetTime: number, -- пауза без стрельбы, после которой очередь начинается заново
	bloom: number, -- прибавка к разбросу за каждый выстрел очереди, градусов
	bloomMax: number,
	push: number, -- отбрасывание зомби попаданием, студов/с
	stagger: number, -- на сколько секунд зомби замирает от попадания
}

export type State = {
	ads: boolean,
	speed: number, -- горизонтальная скорость, студов/с
	airborne: boolean,
	burst: number, -- номер выстрела в текущей очереди (0 — первый)
}

local Ballistics = {}

local GOLDEN = 2.399963 -- золотой угол, радианы

-- Отдача i-го выстрела очереди: (вверх, в сторону), градусов. Зигзаг по синусу — повторяется из очереди в очередь.
function Ballistics.recoilStep(aim: Aim, index: number): (number, number)
	local t = math.min(index / 12, 1)
	local pitch = aim.recoilPitch * (1 + aim.recoilGrow * t)
	local yaw = aim.recoilYaw * math.sin(index * 1.7) * (0.4 + t)
	return pitch, yaw
end

-- Текущий разброс (половина угла конуса, градусов): база × движение × прицел + «раздутие» очереди
function Ballistics.spreadDeg(baseSpread: number, aim: Aim, state: State, walkSpeed: number): number
	local speedFactor = 1 + math.min(state.speed / math.max(walkSpeed, 1), 1.7) * 0.9 -- шаг ≈ ×1,9, спринт ≈ ×2,5
	local air = if state.airborne then 2.5 else 1
	local bloom = math.min(aim.bloom * state.burst, aim.bloomMax)
	local ads = if state.ads then aim.adsSpreadMul else 1
	return (baseSpread * speedFactor * air + bloom) * ads
end

-- Смещение пули в единичном круге для пули pelletIndex (с 1) выстрела shotIndex (с 0): (x, y) ∈ круг радиуса ≤ 1.
-- Одиночные выстрелы: первый — в центр, дальше — спираль с фиксированным повтором. Дробь — всегда одна розетка.
function Ballistics.pelletOffset(pelletIndex: number, shotIndex: number, pellets: number): (number, number)
	if pellets <= 1 then
		if shotIndex == 0 then
			return 0, 0
		end
		local angle = shotIndex * GOLDEN
		local radius = math.sqrt(((shotIndex - 1) % 10 + 1) / 10) * 0.85
		return math.cos(angle) * radius, math.sin(angle) * radius
	end
	if pelletIndex == 1 then
		return 0, 0
	end
	local angle = (pelletIndex - 2) * (2 * math.pi / (pellets - 1)) + 0.4
	local radius = if pelletIndex % 2 == 0 then 0.9 else 0.5
	return math.cos(angle) * radius, math.sin(angle) * radius
end

return Ballistics
