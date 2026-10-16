--!strict
-- Общие типы серверных сервисов.

export type Window = {
	id: number,
	model: Model,
	planks: { BasePart },
	outside: Vector3, -- точка снаружи, куда идут зомби
	inside: Vector3, -- точка внутри за входом
	prompt: ProximityPrompt, -- «Починить» (E)
	dismantle: ProximityPrompt, -- «Разобрать» (F): игрок сам снимает баррикаду, чтобы выйти
	point: string, -- к какой точке обороны относится вход ("shop" — центральный магазин)
	weight: number, -- шанс, что зомби выберут этот вход
}

export type MapInfo = {
	id: string,
	name: string,
	root: Model,
	windows: { Window },
	zombieSpawns: { Vector3 },
	playerSpawn: Vector3,
	wallBuys: { { weaponId: string, prompt: ProximityPrompt } },
}

return nil
