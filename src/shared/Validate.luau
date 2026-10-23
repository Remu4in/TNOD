--!strict
-- Общие проверки данных от клиента (клиент недоверенный).

local Validate = {}

-- Вектор без NaN и ±inf по всем трём осям, модуль каждой оси меньше limit (по умолчанию 1e6).
function Validate.finiteVector(v: Vector3, limit: number?): boolean
	local lim = limit or 1e6
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < lim and math.abs(v.Y) < lim and math.abs(v.Z) < lim
end

return Validate
