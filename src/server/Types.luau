--!strict
-- Общие типы серверных сервисов.

export type Window = {
	id: number,
	model: Model,
	planks: { BasePart },
	outside: Vector3, -- точка снаружи, куда идут зомби
	inside: Vector3, -- точка внутри за входом
	shutter: BasePart, -- стальной щит поверх проёма, пока здание закрыто
	prompt: ProximityPrompt, -- «Починить» (E)
	dismantle: ProximityPrompt, -- «Разобрать» (F): игрок сам снимает баррикаду, чтобы выйти
	point: string, -- к какой точке обороны относится вход ("shop" — центральный магазин)
	weight: number, -- шанс, что зомби выберут этот вход
}

-- Место внутри здания, где игрок что-то берёт (kind: "medkit", "energy", "melee:Bat" …)
export type Spot = {
	kind: string,
	prompt: ProximityPrompt,
	label: TextLabel?,
}

-- Открываемое здание: его входы, вывеска для «скидывания» монет и места с бонусами
export type BuildingInfo = {
	id: string, -- совпадает с Window.point и Config.Buildings[i].id
	name: string,
	windows: { Window },
	signPrompt: ProximityPrompt?, -- нет у бесплатных зданий
	signLabel: TextLabel?,
	spots: { Spot },
}

export type MapInfo = {
	id: string,
	name: string,
	root: Model,
	windows: { Window },
	buildings: { BuildingInfo },
	shop: { center: Vector3, halfX: number, halfZ: number }, -- магазин в центре: ночью закрыт
	zombieSpawns: { Vector3 },
	playerSpawn: Vector3, -- днём: в магазине
	nightSpawn: Vector3, -- ночью (возрождение командой): в стартовом укрытии
	wallBuys: { { weaponId: string, prompt: ProximityPrompt } },
	carSpawns: { CFrame }?, -- режим осмотра: где ставить машины (VehicleService)
}

return nil
