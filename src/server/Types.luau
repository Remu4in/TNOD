--!strict
-- Общие типы серверных сервисов.

export type Window = {
	id: number,
	model: Model,
	planks: { BasePart },
	outside: Vector3, -- точка снаружи, куда идут зомби
	inside: Vector3, -- точка внутри дома за окном
	prompt: ProximityPrompt,
}

export type MapInfo = {
	root: Model,
	windows: { Window },
	zombieSpawns: { Vector3 },
	playerSpawn: Vector3,
	wallBuys: { { weaponId: string, prompt: ProximityPrompt } },
}

return nil
