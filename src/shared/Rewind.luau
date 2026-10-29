--!strict
-- Анимация с реверсом, как осмотр оружия в CS2: прогресс u (0…1) идёт вперёд, а при прерывании не скачет и не докручивается,
-- а плавно едет назад по тем же кадрам (быстрее, reverseSpeed раз) до нейтрального положения. Новое нажатие во время возврата
-- разворачивает анимацию вперёд из текущей позы. Чистая логика, без Roblox (тесты: tests/run.luau).

local Rewind = {}

export type State = {
	time: number, -- длительность одного прохода вперёд, с
	reverseSpeed: number, -- во сколько раз возврат быстрее прохода
	u: number,
	dir: number, -- 1 — вперёд, -1 — возврат
	held: boolean, -- кнопка ещё нажата: по окончании прохода идёт заново
	restart: boolean, -- после возврата сразу запустить заново
	active: boolean,
}

function Rewind.new(time: number, reverseSpeed: number): State
	return { time = math.max(time, 0.05), reverseSpeed = math.max(reverseSpeed, 1), u = 0, dir = 1, held = false, restart = false, active = false }
end

function Rewind.start(s: State, time: number?)
	if time then
		s.time = math.max(time, 0.05)
	end
	s.u, s.dir, s.held, s.restart, s.active = 0, 1, true, false, true
end

-- Нажатие: не идёт — запуск; идёт вперёд — возврат и повтор с начала; возвращается — разворот вперёд из текущей позы
function Rewind.press(s: State)
	s.held = true
	if not s.active then
		Rewind.start(s)
	elseif s.dir > 0 then
		s.dir, s.restart = -1, true
	else
		s.dir, s.restart = 1, false
	end
end

function Rewind.release(s: State)
	s.held = false
end

-- Прерывание (R, смена режима): плавно назад, без повтора
function Rewind.cancel(s: State)
	if s.active then
		s.dir, s.restart, s.held = -1, false, false
	end
end

function Rewind.stop(s: State)
	s.active, s.u, s.dir, s.held, s.restart = false, 0, 1, false, false
end

-- Шаг по времени; возвращает u (nil — анимация закончилась)
function Rewind.step(s: State, dt: number): number?
	if not s.active then
		return nil
	end
	if s.dir > 0 then
		s.u += dt / s.time
		if s.u >= 1 then
			if s.held then
				s.u -= 1
			else
				Rewind.stop(s)
				return nil
			end
		end
	else
		s.u -= dt / s.time * s.reverseSpeed
		if s.u <= 0 then
			if s.restart then
				s.u, s.dir, s.restart = 0, 1, false
			else
				Rewind.stop(s)
				return nil
			end
		end
	end
	return s.u
end

return Rewind
