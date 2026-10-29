--!strict
-- Все числа баланса и настройки игры в одном месте.
-- Меняем здесь, а не в коде систем. Правки баланса — через агента balance-analyst.

local Ballistics = require(script.Parent:WaitForChild("Ballistics"))

export type WeaponDef = {
	id: string,
	name: string,
	price: number, -- 0 = стартовое
	damage: number,
	pellets: number, -- >1 — дробовик
	spreadDeg: number,
	fireRate: number, -- выстрелов в секунду
	automatic: boolean,
	magSize: number,
	reserve: number, -- -1 = бесконечно
	reloadTime: number,
	range: number, -- дальность выстрела; у ближнего боя — длина удара
	color: Color3,
	-- ближний бой (fireRate — взмахов в секунду, патроны не нужны)
	melee: boolean?,
	arcDeg: number?, -- ширина сектора удара
	maxTargets: number?, -- сколько зомби задевает один взмах
	knockback: number?, -- отбрасывание зомби
}

-- Одна деталь внешнего вида оружия: меш в системе координат рукояти Handle (дуло — в сторону -Z)
export type VisualPart = {
	mesh: string,
	texture: string?,
	size: Vector3,
	offset: CFrame,
}

-- Настройка звука оружия: тон/громкость поверх общих официальных звуков
export type WeaponSound = {
	fireVolume: number,
	firePitch: number,
	fireTrim: number?, -- обрезать выстрел до N секунд (для скорострельных)
	reloadVolume: number,
	reloadPitch: number,
}

-- Отдача и эффекты выстрела (клиент)
export type WeaponFxDef = {
	kickBack: number, -- откат ствола назад, студов
	kickRot: number, -- подброс ствола, градусов
	camPitch: number, -- толчок камеры вверх, градусов
	camYaw: number, -- случайный толчок в сторону, градусов
	flash: number, -- размер вспышки у дула
	shell: boolean, -- вылетает ли гильза
}

export type MeleeFxDef = {
	style: string, -- "stab" | "slash" | "smash"
	time: number,
	shake: number,
}

-- Атаки боссов (ZombieService.startBossSpecial). Прыжок: босс приседает на windup секунд, под игроком красная зона (следует за ним, в последние 0,7 с застывает),
-- затем прыгает за flight секунд; урон в radius студов. Бросок: босс отрывает кусок земли (windup), бросает в игрока по дуге (flight), на месте падения красный круг
-- (к центру прозрачнее); урон в radius. cooldown — пауза до следующего такого же; range/minRange — дальность до игрока; first — через сколько секунд после появления можно впервые.
export type BossJump = {
	windup: number, flight: number, cooldown: number, range: number, minRange: number, radius: number, damage: number, first: number,
	wave: { extra: number, noSprint: number }?, -- после приземления: волна тьмы на extra студов шире radius, без урона, noSprint секунд нельзя бегать (Повелитель тёмных)
}
export type BossRock = {
	windup: number, flight: number, cooldown: number, range: number, minRange: number, radius: number, damage: number, first: number,
	stun: number?, -- бросок знака (Гаргантюа): попавшего оглушает на столько секунд (нельзя двигаться и стрелять)
}
-- Новые атаки боссов (Services/BossAI), у каждой: windup — телеграф (поза, рисунок на земле), cooldown, first — когда можно впервые, range/minRange — дальность до игрока.
-- slam (Гаргантюа): удар по земле, от точки удара к игроку со скоростью speed ползёт линия растений длиной length и шириной width, живут life секунд;
--   попавший (кувырок спасает) замедлен в slowMult раз на slowSeconds. crawlers (Гаргантюа): снимает со спины ползуна и кидает в игрока (flight секунд полёта),
--   приземлившийся ползун живой и атакует; не больше maxAlive брошенных живых. charge (Повелитель тёмных): windup секунд набирает силу, на земле дорожка;
--   за lockBefore секунд до старта направление фиксируется; бежит прямо на speed студов/с distance студов (стоп у препятствия), урон damage задетому на пути
--   (шириной width), после — recover секунд стоит. swing: горизонтальный замах, чёрная волна шириной width летит speed студов/с на length студов
--   и гаснет у любого укрытия; урон damage (кувырок спасает).
export type BossSlam = { windup: number, cooldown: number, first: number, range: number, minRange: number, length: number, width: number, speed: number, life: number, slowMult: number, slowSeconds: number }
export type BossCrawlers = { windup: number, flight: number, cooldown: number, first: number, range: number, minRange: number, maxAlive: number }
export type BossCharge = { windup: number, lockBefore: number, speed: number, distance: number, width: number, damage: number, recover: number, cooldown: number, first: number, range: number, minRange: number }
export type BossSwing = { windup: number, cooldown: number, first: number, range: number, minRange: number, speed: number, length: number, width: number, damage: number }
-- Финальный босс (BossAI): sea — море тьмы: waves волн шириной width и высотой height с паузой gap, идут speed студов/с на length студов, низкие — прыжком;
-- comets — count комет (каждая за hover+0,4+fall ≈ 3–4 с, падает в точку, где игрок стоял), радиус radius, высота зависания height; clones — count теней с 1/hpDivisor
-- здоровья, поднимаются rise с, прозрачность alpha; beam — луч duration с преследует игрока (скорость chaseSpeed, радиус radius, урон damage раз в tick);
-- slash — обычный порез (вертикальный, горизонтальный или по диагонали) размером size, летит speed студов/с на length студов.
export type BossSea = { windup: number, cooldown: number, first: number, range: number, minRange: number, waves: number, gap: number, speed: number, length: number, width: number, height: number, damage: number }
export type BossComets = { windup: number, cooldown: number, first: number, range: number, minRange: number, count: number, interval: number, hover: number, fall: number, radius: number, damage: number, height: number }
export type BossClones = { windup: number, cooldown: number, first: number, range: number, minRange: number, count: number, hpDivisor: number, rise: number, alpha: number }
export type BossBeam = { windup: number, cooldown: number, first: number, range: number, minRange: number, duration: number, chaseSpeed: number, radius: number, damage: number, tick: number }
export type BossSlash = { windup: number, cooldown: number, first: number, range: number, minRange: number, speed: number, length: number, size: number, damage: number }
export type BossAttacks = {
	slam: BossSlam?, crawlers: BossCrawlers?, charge: BossCharge?, swing: BossSwing?,
	sea: BossSea?, comets: BossComets?, clones: BossClones?, beam: BossBeam?, slash: BossSlash?,
}
export type ZombieDef = {
	id: string,
	name: string,
	hp: number,
	speed: number,
	damage: number,
	attackCooldown: number, -- пауза между ударами по игроку (после удара)
	windup: number, -- замах: столько секунд зомби замирает с поднятыми руками, прежде чем ударить (можно уйти или перекатиться)
	breakCooldown: number, -- пауза между ударами по баррикаде
	reward: number, -- монеты убийце
	points: number, -- очки убийце (и в общий командный счёт)
	scale: number,
	color: Color3,
	planksPerHit: number,
	flask: { range: number, minRange: number, cooldown: number, damage: number, tick: number, radius: number }?, -- химик: бросает колбу с ядом
	teleport: { cooldown: number, distance: number }?, -- тёмный: появляется рядом с игроком (не ближе distance)
	jump: BossJump?, -- босс: мощный прыжок на ближайшего игрока
	rock: BossRock?, -- босс: бросок куска земли по дуге
	attacks: BossAttacks?, -- босс: атаки Services/BossAI (удар по земле, ползун, разбег, чёрный взмах; у финального — море, кометы, тени, луч, порез)
	phase2: { hpFraction: number }?, -- вторая фаза: при HP ≤ доли босс не бьёт обычно, только способности, и неуязвим к огнестрелу (нужно холодное оружие)
}

local Config = {}

Config.Round = {
	IntermissionTime = 15,
	FirstDayTime = 120, -- день можно завершить раньше голосованием (клавиша V): когда готовы все игроки
	DayTime = 120,
	NightMinTime = 420, -- длина ночи: 7 минут на 1-й волне, +NightPerWave секунд за каждую следующую, не больше NightMaxTime
	NightPerWave = 10,
	NightMaxTime = 600, -- ночь заканчивается, когда мутантов не осталось или по таймеру (оставшиеся сгорят на рассвете)
	DayWarnSeconds = 15, -- за сколько секунд до ночи предупреждаем, что баррикады закроются
	GameOverTime = 8,
	ZombiesAlivePerPlayer = 40, -- одновременно живых мутантов на игрока; остальные ждут в очереди спавна
	ZombiesAliveMin = 40,
	SpawnsPerTick = 2,
	SpawnTick = 0.25,
	AiTick = 0.2, -- как часто зомби пересчитывают цель
}

-- Локации идут по порядку; смена каждые LocationNights ночей (= 2 босса при BossEvery = 5).
Config.Locations = {
	{ id = "Custom", name = "Своя карта" }, -- карту Руслан собрал в Studio; код её не строит (Locations/Custom читает маркеры)
}
Config.LocationNights = 10

-- Режим осмотра (2026-10-18): вместо раундов строится «Большой мир» (Locations/World), зомби нет, всё открыто,
-- на базе стоят телепорт-площадки к каждой локации. Выключить (false) — обычная игра на карте City.
Config.Explore = false -- true: режим осмотра без раундов
Config.TestStands = true -- стенды у спавна: тестовое оружие бесплатно, вызов волн мутантов (выключить перед релизом)
Config.TentMarkRadius = 250 -- метки на военные палатки каждое утро в этом радиусе, студов (1 стад ≈ 0,28 м)
Config.ExploreZombies = true -- в режиме осмотра ставить проверочных зомби (Зомби 3.0)

-- Машины (VehicleService / VehicleController): аркадная езда
Config.Vehicle = {
	maxSpeed = 105, -- студов/с вперёд (~75 км/ч в масштабе игры)
	reverseSpeed = 30,
	accel = 55,
	brake = 110,
	drag = 22, -- замедление без газа
	turn = 2.4, -- рад/с на малой скорости (на большой делится)
	length = 13, -- итоговая длина кузова в студах
	curbSlow = 0.5, -- множитель максимальной скорости на бордюре/тротуаре
	offroadSlow = 0.8, -- и на траве/земле
}

-- Типы машин (2026-10-19). Шаблон модели — ServerStorage.CarModels.<template> (VehicleBaker); перёд -Z.
-- Скорости — студов/с, turn — рад/с на малой скорости, density — плотность коробки-корпуса (тяжелее = сильнее толкает
-- игроков и зомби при столкновении), hp — прочность, ram — давка зомби (см. Config.VehicleRam). Config.Vehicle выше — запасная
-- настройка для шаблонов без типа. price — цена покупки (покупка машин в игре — отдельный этап, поле пока не читается).
-- turret — место стрелка и турель на крыше: модель из ServerStorage.Assets.Weapons.Turrets, length — длина в студах,
-- seat — смещение сиденья стрелка от точки крепления (после масштаба). Стрельба турели — следующий этап.
export type VehicleType = {
	id: string,
	name: string,
	maxSpeed: number,
	reverseSpeed: number,
	accel: number,
	brake: number,
	drag: number,
	turn: number,
	density: number,
	hp: number,
	ramMult: number, -- множитель урона от давки
	price: number,
	seats: number, -- мест в машине без стрелка (0 — не ездовая, декор): 1 водитель, 2 переднее пассажирское, 3–4 задние
	turret: { seat: Vector3, gunPivot: Vector3? }?, -- seat — смещение сиденья стрелка от люка; gunPivot — ось встроенного пулемёта (детали MG шаблона), в родных координатах шаблона
}
Config.VehicleTypes = {
	Car = { id = "Car", name = "Легковая", maxSpeed = 105, reverseSpeed = 30, accel = 55, brake = 110, drag = 22, turn = 2.4, density = 0.5, hp = 300, ramMult = 1, price = 0, seats = 4 },
	Jeep = { id = "Jeep", name = "Военный джип", maxSpeed = 92, reverseSpeed = 28, accel = 46, brake = 105, drag = 22, turn = 2.2, density = 0.9, hp = 700, ramMult = 1.4, price = 3000, seats = 0 },
	Van = { id = "Van", name = "Фургон", maxSpeed = 82, reverseSpeed = 26, accel = 38, brake = 95, drag = 22, turn = 1.9, density = 1.1, hp = 800, ramMult = 1.5, price = 2500, seats = 0 },
	Truck = { id = "Truck", name = "Грузовик", maxSpeed = 72, reverseSpeed = 22, accel = 28, brake = 85, drag = 20, turn = 1.6, density = 1.6, hp = 1100, ramMult = 2, price = 4500, seats = 0 },
	Bus = { id = "Bus", name = "Автобус", maxSpeed = 62, reverseSpeed = 20, accel = 22, brake = 75, drag = 20, turn = 1.3, density = 2.0, hp = 1400, ramMult = 2.4, price = 5500, seats = 0 },
	GunJeep = {
		id = "GunJeep", name = "Джип с турелью", maxSpeed = 92, reverseSpeed = 28, accel = 46, brake = 105, drag = 22, turn = 2.2, density = 0.9, hp = 900, ramMult = 1.4, price = 10000, seats = 4,
		-- пулемёт уже есть в модели машины (детали «MG»): отдельную турель не ставим, а оживляем встроенный; параметры — Config.TurretGun
		turret = { seat = Vector3.new(0, -2.2, 0.8), gunPivot = Vector3.new(-0.9, 3.55, -1.6) },
	},
} :: { [string]: VehicleType }

-- Шаблон → тип машины и длина (для всех типов): ключ — имя для VehicleService.spawn; template — имя в CarModels, если отличается.
Config.VehicleModels = {
	Prius = { type = "Car", length = 13 },
	Sedan = { type = "Car", length = 13.5 },
	Coupe = { type = "Car", length = 13 },
	Humvee = { type = "Jeep", length = 17 },
	HumveeMedic = { type = "Jeep", length = 17 },
	MilitaryCar = { type = "Jeep", length = 16 }, -- перёд в шаблоне повёрнут при запекании (yaw π)
	Ambulance = { type = "Van", length = 18 },
	Truck = { type = "Truck", length = 26 },
	Bus = { type = "Bus", length = 30 },
	GunJeep = { type = "GunJeep", length = 17, template = "Humvee" },
} :: { [string]: { type: string, length: number, template: string? } }

-- Давка зомби и поломка. Урон зомби = (base + perSpeed × (скорость − minSpeed)) × ramMult типа, не чаще раза в cooldown на зомби.
-- Боссы (id начинается с «Boss») не страдают: машина получает bossHit урона и урон от резкого торможения (crash*).
Config.VehicleRam = {
	minSpeed = 26, -- ниже этой скорости (студов/с) давки нет
	base = 55,
	perSpeed = 2.2,
	cooldown = 0.6, -- пауза между ударами по одному и тому же зомби
	margin = 1.2, -- запас вокруг коробки-корпуса
	push = 70, -- отбрасывание выживших зомби, студов/с
	selfPerHit = 2, -- урон машине за каждого сбитого
	bossHit = 45,
	crashDecel = 55, -- потеря скорости за один тик (0,1 с), с которой считается авария
	crashDamage = 2.2, -- урона за каждый студ/с сверх порога
	smokeFrac = 0.35, -- доля прочности, ниже которой машина дымит
	limpFrac = 0.3, -- ниже этой доли прочности — максимальная скорость падает до limpSpeed
	limpSpeed = 0.7,
	wreckRemoveAfter = 120, -- секунд до исчезновения остова (0 — не убирать)
}

Config.Player = {
	MaxHealth = 100,
	RegenDelay = 5,
	RegenPerSecond = 0, -- здоровье само не восстанавливается: только аптечка (Items.Medkit) и поднятие командой
	-- Движение: зомби быстрее ходьбы (Ходок 14 > 13), но спринт за энергию их обгоняет
	WalkSpeed = 13,
	SprintSpeed = 21,
	BackwardSpeedFactor = 0.75, -- спиной вперёд идём медленнее
	DownedWalkSpeed = 4,
	-- Энергия: 5 с непрерывного спринта тратят всю, полностью восстанавливается за 15 с
	EnergyMax = 100,
	SprintSeconds = 5, -- было 10: спринт в 2 раза короче (запрос Руслана 2026-10-16)
	EnergyRegenSeconds = 15, -- было 30: восстановление в 2 раза быстрее (запрос Руслана 2026-10-18)
	EnergyRegenDelay = 1, -- пауза после спринта перед восстановлением
	SprintMinEnergy = 15, -- с меньшей энергией спринт не начать
	-- Подкат (спринт + Q): низкий скользящий рывок, проходит под баррикадой с выбитыми нижними досками.
	-- Кувырок (C): рывок с неуязвимостью в первые секунды — уклонение от замаха зомби.
	SlideEnergy = 10,
	SlideSeconds = 1.0,
	SlideSpeed = 34,
	RollEnergy = 12,
	RollSeconds = 0.5,
	RollSpeed = 26,
	RollInvulnSeconds = 0.4,
	DodgeCooldown = 1.0, -- общая пауза между подкатом и кувырком
	BleedOutTime = 30,
	ReviveHoldTime = 3,
	ReviveHealth = 50,
	StartCoins = 500,
}

-- Здания: открываются «скидыванием» монет (любой игрок вкладывает часть суммы через вывеску).
-- Бесплатное (cost = 0) открыто с начала раунда. Склады выдают набор один раз за игру при открытии.
-- bonus: "medkits" — аптечки и энергетики, "melee" — по одному холодному оружию на игрока,
-- "teamLife" — дополнительная жизнь команды; "wire" и "turret" — содержимое появится с этапом «Оборудование».
export type BuildingDef = {
	id: string,
	name: string,
	cost: number,
	bonus: string?,
	info: string, -- что внутри (для вывески и уведомления)
}

local Buildings: { BuildingDef } = {
	{ id = "Cafe", name = "Кафе", cost = 0, info = "Стартовое укрытие" },
	-- Открытие здания за монеты (вывеска) даёт доступ к НПС-продавцу внутри: он торгует только днём (Config.Vendors)
	{ id = "Pharmacy", name = "Медпункт", cost = 500, info = "Продавец: аптечки и энергетики" },
	{ id = "Armory", name = "Оружейная", cost = 1000, info = "Продавец: холодное оружие" },
	{ id = "Garage", name = "Гараж", cost = 2000, info = "Продавец: колючая и электро-проволока" },
	{ id = "GunShop", name = "Магазин турелей", cost = 3000, info = "Продавец: турели" },
	{ id = "Shelter", name = "Убежище", cost = 4000, bonus = "teamLife", info = "Дополнительная жизнь команды и продавец" },
	{ id = "Factory", name = "Завод", cost = 4000, info = "Внутри военный автомобиль с пулемётом на крыше" },
}
Config.Buildings = Buildings

-- Предметы-расходники (выдаются складами, потом — донатом)
export type ItemDef = {
	name: string,
	heal: number?, -- здоровье
	energy: number?, -- энергия спринта
	color: Color3,
}

local Items: { [string]: ItemDef } = {
	Medkit = { name = "Аптечка", heal = 60, color = Color3.fromRGB(235, 235, 235) },
	EnergyDrink = { name = "Энергетик", infiniteWaves = 1, color = Color3.fromRGB(60, 190, 255) },
}
Config.Items = Items

-- Очки: личные (таблица игроков) и в общий командный счёт (потом — на открытие зданий)
Config.Score = {
	Repair = 2, -- за доску, выбитую зомби
	Revive = 50, -- за поднятие товарища
}

Config.Economy = {
	CoinsPerHit = 0, -- монеты за попадания убраны: доход — награда за миссию и пул за убийства (WaveMath.missionReward / killPool / killCap)
	CoinsPerPlankRepair = 10,
	MaxRepairCoinsPerDay = 100, -- на всю команду
	-- Вариант C «миссии решают» (2026-10-25, docs/balance/economy_2026-10.md). Личные счета (на здания скидываются у вывески). Основной доход —
	-- награда за миссию ночи: личная часть каждому целиком + командная, поровну на всех (она оплачивает здания). Обе растут от ночи к ночи
	-- как 1 + MissionGrowth·(ночь − 1); суммы за MissionRewardWaves ночей — MissionPersonalTotal и MissionTeamTotal (цель на игрока к 15-й
	-- ночи ≈ 0,9 × (5250 на 3–4 ствола + 14 500 / игроков на здания); стартовые 500 — на патроны). Миссия провалена — доля MissionFailShare
	-- (0: награды нет). Лежащему на конец ночи — DownedRewardFactor от награды.
	-- Убийства: пул ночи на игрока = KillPoolShare от потолка KillCap (растёт от KillCapMin до KillCapMax за KillCapWaves ночей), пул растёт
	-- с числом игроков; в голову полная доля, в тело — KillBodyShare. Потолок монет за убийства на игрока за ночь — KillCap (200–300): сколько бы
	-- зомби ни пришло за время миссии, больше потолка убийства не платят (было 3000 за первую ночь на потоке зомби).
	-- Штраф: каждая потеря игрока (упал и не был поднят) отнимает LossPenalty от монет, заработанных за эту волну.
	MissionPersonalTotal = 3413,
	MissionTeamTotal = 13050,
	MissionGrowth = 0.18,
	MissionRewardWaves = 15,
	MissionFailShare = 0,
	KillCapMin = 200,
	KillCapMax = 300,
	KillCapWaves = 15,
	KillPoolShare = 0.35,
	KillBodyShare = 0.4,
	KillWeights = { Walker = 1, Runner = 1.2, Crawler = 0.8, Dark = 2, BucketHead = 2.5, Military = 3, Chemist = 3, Brute = 6 },
	BossKillWeight = 40,
	DownedRewardFactor = 0.5,
	LossPenalty = 0.2,
	HeadshotMultiplier = 2, -- урон по голове (было 1,5)
	LimbMultiplier = 0.75, -- урон по рукам и ногам: целиться в корпус и голову выгоднее
	HeadshotKillPointsBonus = 0.5, -- добавка к очкам за убийство выстрелом в голову (доля от очков типа)
	HeadshotKillCoinsBonus = 0.25, -- и к монетам
	RefillPriceFactor = 0.5,
}

Config.Barricade = {
	Planks = 10, -- было 5: баррикада прочнее в 2 раза; ломается снизу вверх — когда выбиты ~3 нижние доски, под ней можно проскользнуть
	RepairHoldTime = 0.6,
	DismantleHoldTime = 1.0, -- сколько держать «Разобрать», чтобы снять все доски самому
	AttackRange = 6,
}

local Weapons: { [string]: WeaponDef } = {
	Pistol = {
		id = "Pistol", name = "Пистолет", price = 0,
		damage = 20, pellets = 1, spreadDeg = 1, fireRate = 4, automatic = false,
		magSize = 12, reserve = -1, reloadTime = 1.2, range = 250,
		color = Color3.fromRGB(70, 70, 75),
	},
	SMG = {
		id = "SMG", name = "Пистолет-пулемёт", price = 500,
		damage = 14, pellets = 1, spreadDeg = 2.2, fireRate = 10, automatic = true,
		magSize = 30, reserve = 180, reloadTime = 1.6, range = 200,
		color = Color3.fromRGB(40, 60, 90),
	},
	Shotgun = {
		id = "Shotgun", name = "Дробовик", price = 750,
		damage = 12, pellets = 6, spreadDeg = 7, fireRate = 1.2, automatic = false,
		magSize = 6, reserve = 36, reloadTime = 2.2, range = 60,
		color = Color3.fromRGB(110, 70, 40),
	},
	Rifle = {
		id = "Rifle", name = "Винтовка", price = 1200,
		damage = 45, pellets = 1, spreadDeg = 0.5, fireRate = 3, automatic = true,
		magSize = 20, reserve = 120, reloadTime = 2.0, range = 400,
		color = Color3.fromRGB(60, 80, 50),
	},
	Revolver = {
		id = "Revolver", name = "Револьвер", price = 400,
		damage = 55, pellets = 1, spreadDeg = 0.8, fireRate = 1.6, automatic = false,
		magSize = 6, reserve = 42, reloadTime = 2.4, range = 300,
		color = Color3.fromRGB(90, 90, 95),
	},
	LMG = {
		id = "LMG", name = "Пулемёт", price = 1800,
		damage = 22, pellets = 1, spreadDeg = 2.8, fireRate = 11, automatic = true,
		magSize = 75, reserve = 300, reloadTime = 4.2, range = 250,
		color = Color3.fromRGB(50, 55, 60),
	},
	Sniper = {
		id = "Sniper", name = "Снайперская винтовка", price = 1500,
		damage = 150, pellets = 1, spreadDeg = 0.1, fireRate = 0.9, automatic = false,
		magSize = 5, reserve = 30, reloadTime = 3.0, range = 600,
		color = Color3.fromRGB(70, 60, 45),
	},
	-- Ближний бой: патронов нет, бьёт по сектору перед игроком
	Knife = {
		id = "Knife", name = "Нож", price = 0,
		damage = 25, pellets = 1, spreadDeg = 0, fireRate = 2.5, automatic = false,
		magSize = 0, reserve = -1, reloadTime = 0, range = 5.5,
		color = Color3.fromRGB(150, 150, 155),
		melee = true, arcDeg = 70, maxTargets = 1, knockback = 20,
	},
	Bat = {
		id = "Bat", name = "Бита", price = 300,
		damage = 45, pellets = 1, spreadDeg = 0, fireRate = 1.4, automatic = false,
		magSize = 0, reserve = -1, reloadTime = 0, range = 6.5,
		color = Color3.fromRGB(150, 110, 60),
		melee = true, arcDeg = 110, maxTargets = 3, knockback = 45,
	},
	Machete = {
		id = "Machete", name = "Мачете", price = 600,
		damage = 70, pellets = 1, spreadDeg = 0, fireRate = 1.8, automatic = false,
		magSize = 0, reserve = -1, reloadTime = 0, range = 6.5,
		color = Color3.fromRGB(130, 135, 140),
		melee = true, arcDeg = 100, maxTargets = 2, knockback = 30,
	},
}

-- Что выдаётся каждому в начале раунда (остальное покупается на стенах)
Config.StartWeapons = { "Pistol", "Knife" }

Config.Weapons = Weapons

-- Внешний вид. Пистолет — официальный Roblox Weapons Kit; SMG, дробовик и винтовка сгенерированы
-- в Studio (generate_mesh, 2026-10-16). Все ассеты записаны в docs/assets_ledger.md.
local Visuals: { [string]: { VisualPart } } = {
	Pistol = {
		{
			mesh = "rbxassetid://2492922600", texture = "rbxassetid://2492931263",
			size = Vector3.new(0.1925, 0.9165, 1.3615),
			offset = CFrame.new(-0.068, 0.074, -0.257) * CFrame.Angles(0, math.pi, 0),
		},
		{
			mesh = "rbxassetid://2492925447",
			size = Vector3.new(0.1062, 0.7854, 0.5009),
			offset = CFrame.new(-0.068, 0.002, 0.110) * CFrame.Angles(0, math.pi, 0),
		},
		{
			mesh = "rbxassetid://2492923497", texture = "rbxassetid://2492931686",
			size = Vector3.new(0.1557, 0.2798, 1.2122),
			offset = CFrame.new(-0.068, 0.432, -0.319) * CFrame.Angles(0, math.pi, 0),
		},
	},
	-- Новые модели (этап 1.5, generate_mesh, 2026-10-16): начало координат Handle — место хвата, ствол/клинок смотрит в -Z.
	-- Значения получены скриптом из сгенерированных моделей (масштаб k, хват, поворот); нож, мачете, бита — тоже.
	SMG = {
		{ mesh = "rbxassetid://86180393992531", texture = "rbxassetid://77745462030465", size = Vector3.new(0.2400, 0.9769, 2.0078),
			offset = CFrame.new(0.0000, 0.1200, -0.5040) },
	},
	Shotgun = {
		{ mesh = "rbxassetid://72409578915987", texture = "rbxassetid://134995232020072", size = Vector3.new(0.2200, 0.7644, 3.3747),
			offset = CFrame.new(0, 0.0550, -0.7150) },
	},
	Rifle = {
		{ mesh = "rbxassetid://109394360456042", texture = "rbxassetid://126271532108495", size = Vector3.new(0.1890, 1.2003, 0.5919),
			offset = CFrame.new(-0.0121, -0.2934, -0.4867) },
		{ mesh = "rbxassetid://115271859157501", texture = "rbxassetid://83729228976662", size = Vector3.new(0.3200, 1.1387, 2.9236),
			offset = CFrame.new(0, 0.2023, -0.2400) },
	},
	LMG = {
		{ mesh = "rbxassetid://94831980243151", texture = "rbxassetid://108981689744397", size = Vector3.new(0.2704, 0.7522, 0.4631),
			offset = CFrame.new(-0.0002, -0.0070, -0.0133) },
		{ mesh = "rbxassetid://115117388427607", texture = "rbxassetid://113148434788766", size = Vector3.new(1.2000, 1.7084, 2.8051),
			offset = CFrame.new(0, -0.0600, -0.3726) },
		{ mesh = "rbxassetid://116538760803965", texture = "rbxassetid://107363929925152", size = Vector3.new(0.1729, 0.4111, 1.7150),
			offset = CFrame.new(-0.0008, 0.5714, -1.6725) },
	},
	Sniper = {
		{ mesh = "rbxassetid://118201601639438", texture = "rbxassetid://115761728350604", size = Vector3.new(0.3333, 0.7161, 0.5944),
			offset = CFrame.new(-0.0054, -0.0061, -0.0051) },
		{ mesh = "rbxassetid://105579768282482", texture = "rbxassetid://103194693022178", size = Vector3.new(0.5000, 0.8137, 2.7741),
			offset = CFrame.new(0.0250, 0.0625, -0.4729) },
		{ mesh = "rbxassetid://135394950602850", texture = "rbxassetid://132150245465704", size = Vector3.new(0.1890, 0.2815, 1.9736),
			offset = CFrame.new(-0.0042, 0.4183, -1.7273) },
		{ mesh = "rbxassetid://80440239887468", texture = "rbxassetid://73752518295586", size = Vector3.new(0.4418, 0.5242, 1.1523),
			offset = CFrame.new(-0.0030, 0.6771, -0.5260) },
	},
	Revolver = {
		{ mesh = "rbxassetid://89695116920427", texture = "rbxassetid://114436493381492", size = Vector3.new(0.2349, 0.7267, 0.4427),
			offset = CFrame.new(0.0004, -0.0029, -0.0015) },
		{ mesh = "rbxassetid://133687885069902", texture = "rbxassetid://137133591885506", size = Vector3.new(0.2800, 0.7327, 0.6994),
			offset = CFrame.new(0, 0.2709, -0.3486) },
		{ mesh = "rbxassetid://79231535056305", texture = "rbxassetid://133850275004083", size = Vector3.new(0.1295, 0.2289, 0.5241),
			offset = CFrame.new(0, 0.5318, -0.8678) },
	},
	Knife = {
		{ mesh = "rbxassetid://83287424896071", texture = "rbxassetid://104557653597097", size = Vector3.new(1.4900, 0.5149, 0.2400),
			offset = CFrame.Angles(math.rad(80), 0, 0) * CFrame.new(0, 0, -0.4800) * CFrame.Angles(0, math.rad(90), 0) }, -- хват «обратный»: клинок смотрит вверх, а не вперёд
	},
	Machete = {
		{ mesh = "rbxassetid://73914981913805", texture = "rbxassetid://126655934720778", size = Vector3.new(1.3906, 1.7482, 0.1511),
			offset = CFrame.new(-0.0009, 0.0003, -1.4293, 0.0000, -0.0000, 1.0000, -0.8131, -0.5821, 0.0000, 0.5821, -0.8131, -0.0000) },
		{ mesh = "rbxassetid://107034107062962", texture = "rbxassetid://82015346137372", size = Vector3.new(1.1839, 1.1031, 0.4001),
			offset = CFrame.new(0.0000, 0.0062, 0.0012, 0.0000, -0.0000, 1.0000, -0.8131, -0.5821, 0.0000, 0.5821, -0.8131, -0.0000) },
		{ mesh = "rbxassetid://89913069161620", texture = "rbxassetid://97834968452305", size = Vector3.new(0.5965, 0.3496, 0.2869),
			offset = CFrame.new(-0.0002, 0.0250, -0.5027, 0.0000, -0.0000, 1.0000, -0.8131, -0.5821, 0.0000, 0.5821, -0.8131, -0.0000) },
	},
	Bat = {
		{ mesh = "rbxassetid://128014260046754", texture = "rbxassetid://80520276839389", size = Vector3.new(0.6385, 0.5600, 2.7633),
			offset = CFrame.new(0, 0, -1.1200) },
	},
}
Config.WeaponVisuals = Visuals

-- Хват: scale — общий масштаб модели в руках; foregrip — точка опоры левой руки в системе рукояти (до масштаба);
-- gripRot — поворот ладони левой руки (подбирается в плейтесте). Без foregrip оружие одноручное.
-- view — где рукоять относительно камеры (вправо, вверх, вперёд); tilt — наклон оружия; mag — точка магазина (перезарядка).
export type WeaponHold = {
	scale: number,
	foregrip: Vector3?,
	handRoll: number?,
	view: Vector3?,
	tilt: CFrame?,
	mag: Vector3?,
}
Config.WeaponHold = {
	Pistol = { scale = 1, foregrip = Vector3.new(-0.05, -0.3, -0.1), mag = Vector3.new(0, -0.45, 0.05), view = Vector3.new(0.4, -0.5, -1.1) },
	SMG = { scale = 0.75, foregrip = Vector3.new(0, 0.22, -0.85), mag = Vector3.new(0, -0.4, -0.35), view = Vector3.new(0.4, -0.5, -1.1) },
	Shotgun = { scale = 0.8, foregrip = Vector3.new(0, 0.15, -1.4), mag = Vector3.new(0, -0.2, -0.2), view = Vector3.new(0.4, -0.5, -1.1) },
	Rifle = { scale = 0.8, foregrip = Vector3.new(0, 0.1, -1.0), mag = Vector3.new(0, -0.5, -0.45), view = Vector3.new(0.4, -0.5, -1.1) },
	LMG = { scale = 0.7, foregrip = Vector3.new(0, -0.2, -0.8), mag = Vector3.new(0, -0.3, -0.35), view = Vector3.new(0.4, -0.5, -1.1) },
	Sniper = { scale = 0.8, foregrip = Vector3.new(0, -0.05, -1.0), mag = Vector3.new(0, -0.1, -0.3), view = Vector3.new(0.4, -0.5, -1.1) },
	Revolver = { scale = 0.9, foregrip = Vector3.new(-0.05, -0.3, -0.1), mag = Vector3.new(0, -0.2, -0.3), view = Vector3.new(0.4, -0.5, -1.1) },
	Knife = { scale = 1, view = Vector3.new(0.5, -0.5, -1.1), tilt = CFrame.Angles(math.rad(25), math.rad(10), math.rad(-10)) },
	Bat = { scale = 1, view = Vector3.new(0.5, -0.5, -1.1), tilt = CFrame.Angles(math.rad(45), math.rad(8), math.rad(-5)) },
	Machete = { scale = 1, view = Vector3.new(0.5, -0.5, -1.1), tilt = CFrame.Angles(math.rad(30), math.rad(8), math.rad(-8)) },
} :: { [string]: WeaponHold }

-- Модели оружия из библиотеки (2026-10-19, паки Rubie's Weapon Collection, запечены tools/WeaponBaker.luau):
-- ServerStorage.Assets.Weapons.<ref>. Модель уже нормализована: начало координат — хват, дуло/остриё в -Z, верх +Y.
-- length — итоговая длина модели в студах (масштаб = length / атрибут модели Length); grip — сдвиг модели относительно рукояти
-- (студы, после масштаба), rot — доворот (подбирается в плейтесте). Нет записи или модели в библиотеке — старый вид из WeaponVisuals.
-- WeaponHold.scale относится только к старым мешам (WeaponVisuals) и здесь не участвует.
export type WeaponModelDef = { ref: string, length: number, grip: Vector3?, rot: CFrame? }
Config.WeaponModels = {
	Pistol = { ref = "Pistols/Glock19", length = 1.4 },
	Revolver = { ref = "Revolvers/ColtPython", length = 1.7 },
	SMG = { ref = "SMG/MP5", length = 2.2 },
	Shotgun = { ref = "Shotguns/Mossberg500", length = 3.3 },
	Rifle = { ref = "Rifles/AK12", length = 3.2 },
	-- Sniper: сгенерированная модель была размытой (текстура низкого разрешения), пока вместо неё карабин Mini14: оптику даёт маска прицела
	-- (Config.ScopedWeapons). LMG: подходящей модели в паках нет — остаётся сгенерированная из WeaponVisuals
	Sniper = { ref = "Carbines/Mini14", length = 4.2 },
	Knife = { ref = "Melee/CombatKnife", length = 2.1 },
	Bat = { ref = "Melee/BaseballBat", length = 3.0 },
	Machete = { ref = "Melee/StandardMachete", length = 2.5 },
} :: { [string]: WeaponModelDef }

-- Где правая кисть держит оружие (студы, система рукояти, уже с масштабом модели). У пистолетов, револьверов и Kriss Vector начало
-- координат модели не в рукояти (как у винтовок), поэтому кисть берётся отсюда; нет записи — ViewModelController.DEFAULT_HAND.
Config.WeaponHands = {
	Pistol = Vector3.new(0, -0.12, -0.16),
	M1911 = Vector3.new(0, -0.02, -0.06),
	FiveSeven = Vector3.new(0, -0.05, -0.06),
	Revolver = Vector3.new(0, -0.02, 0.04),
	Model29 = Vector3.new(0, -0.02, 0.08),
	Vector = Vector3.new(0, -0.1, -0.55),
} :: { [string]: Vector3 }

-- ЧЕРНОВИК ассортимента (не подключён к игре; числа предложены 2026-10-19 и утверждаются Русланом / balance-analyst).
-- Работающий баланс — Config.Weapons выше. class — папка библиотеки; slot — место в магазине (1–12) в порядке роста цены;
-- tier: "start" | "wall" (стены/вендинг за монеты) | "donate" (за донат, как косметика/ускорение) | "late" (поздняя игра, база).
export type WeaponDraft = {
	id: string, name: string, ref: string, tier: string, slot: number?,
	price: number, damage: number, pellets: number?, fireRate: number, magSize: number?, reserve: number?, reloadTime: number?,
	note: string?,
}
Config.WeaponDraft = {
	-- Пистолеты
	{ id = "Pistol", name = "Glock 19", ref = "Pistols/Glock19", tier = "start", price = 0, damage = 20, fireRate = 4, magSize = 12, reserve = -1, reloadTime = 1.2, note = "как сейчас" },
	{ id = "M1911", name = "M1911", ref = "Pistols/M1911A1", tier = "wall", slot = 1, price = 250, damage = 28, fireRate = 3.2, magSize = 8, reserve = 56, reloadTime = 1.4 },
	{ id = "FiveSeven", name = "Five-seveN", ref = "Pistols/FiveSeveN", tier = "wall", slot = 2, price = 350, damage = 17, fireRate = 5.5, magSize = 20, reserve = 120, reloadTime = 1.5 },
	{ id = "DesertEagle", name = "Desert Eagle", ref = "Pistols/DesertEagle", tier = "wall", slot = 6, price = 900, damage = 62, fireRate = 2.0, magSize = 8, reserve = 48, reloadTime = 2.0, note = "мощнее револьвера, мало патронов" },
	-- Револьверы
	{ id = "Revolver", name = "Colt Python", ref = "Revolvers/ColtPython", tier = "wall", slot = 3, price = 400, damage = 55, fireRate = 1.6, magSize = 6, reserve = 42, reloadTime = 2.4, note = "как сейчас" },
	{ id = "Model29", name = "S&W Model 29", ref = "Revolvers/SWModel29", tier = "donate", price = 0, damage = 70, fireRate = 1.3, magSize = 6, reserve = 36, reloadTime = 2.6, note = "магнум .44, косметика-бонус" },
	-- ПП
	{ id = "SMG", name = "MP5", ref = "SMG/MP5", tier = "wall", slot = 4, price = 500, damage = 14, fireRate = 10, magSize = 30, reserve = 180, reloadTime = 1.6, note = "как сейчас" },
	{ id = "Uzi", name = "Uzi", ref = "SMG/Uzi", tier = "wall", slot = 3, price = 450, damage = 12, fireRate = 12, magSize = 32, reserve = 192, reloadTime = 1.7 },
	{ id = "Thompson", name = "Thompson M1A1", ref = "SMG/M1A1Thompson", tier = "wall", slot = 5, price = 800, damage = 18, fireRate = 9, magSize = 50, reserve = 200, reloadTime = 2.4, note = "барабан" },
	{ id = "Vector", name = "Kriss Vector", ref = "SMG/KrissVector", tier = "late", price = 1700, damage = 13, fireRate = 15, magSize = 25, reserve = 200, reloadTime = 1.6 },
	-- Дробовики
	{ id = "Shotgun", name = "Mossberg 500", ref = "Shotguns/Mossberg500", tier = "wall", slot = 5, price = 750, damage = 12, pellets = 6, fireRate = 1.2, magSize = 6, reserve = 36, reloadTime = 2.2, note = "как сейчас" },
	{ id = "Sawnoff", name = "Обрез", ref = "Shotguns/SawnOffShotgun", tier = "wall", slot = 2, price = 350, damage = 14, pellets = 7, fireRate = 0.9, magSize = 2, reserve = 24, reloadTime = 1.8, note = "дёшево, 2 выстрела, дальность 40" },
	{ id = "SPAS12", name = "SPAS-12", ref = "Shotguns/SPAS12", tier = "wall", slot = 8, price = 1400, damage = 11, pellets = 7, fireRate = 2.0, magSize = 8, reserve = 48, reloadTime = 2.8, note = "полуавто" },
	{ id = "AA12", name = "AA-12", ref = "Shotguns/AA12", tier = "late", price = 2800, damage = 10, pellets = 7, fireRate = 5.0, magSize = 20, reserve = 120, reloadTime = 3.4, note = "автоматический" },
	-- Винтовки / карабины
	{ id = "Rifle", name = "AK-12", ref = "Rifles/AK12", tier = "wall", slot = 7, price = 1200, damage = 45, fireRate = 3, magSize = 20, reserve = 120, reloadTime = 2.0, note = "как сейчас" },
	{ id = "M4A1", name = "M4A1", ref = "Carbines/M4A1", tier = "wall", slot = 6, price = 1000, damage = 36, fireRate = 4.2, magSize = 30, reserve = 180, reloadTime = 2.0 },
	{ id = "SCAR", name = "SCAR-L", ref = "Rifles/SCARL", tier = "late", price = 2200, damage = 52, fireRate = 3.4, magSize = 25, reserve = 150, reloadTime = 2.2 },
	{ id = "SKS", name = "СКС", ref = "Carbines/SKS", tier = "wall", slot = 9, price = 1300, damage = 80, fireRate = 1.8, magSize = 10, reserve = 60, reloadTime = 2.6, note = "полуавто, заменит снайперку, пока нет модели снайперки" },
	-- Тяжёлое (моделей в паках нет — старые сгенерированные)
	{ id = "LMG", name = "Пулемёт", ref = "", tier = "late", price = 1800, damage = 22, fireRate = 11, magSize = 75, reserve = 300, reloadTime = 4.2, note = "как сейчас; модель из WeaponVisuals" },
	{ id = "Sniper", name = "Снайперская винтовка", ref = "", tier = "late", price = 1500, damage = 150, fireRate = 0.9, magSize = 5, reserve = 30, reloadTime = 3.0, note = "как сейчас; модель из WeaponVisuals" },
	-- Гранатомёты (после этапа «Оборудование»; взрывы и урон по площади — новая механика)
	{ id = "M79", name = "M79", ref = "Launchers/M79", tier = "late", price = 5000, damage = 180, fireRate = 0.5, magSize = 1, reserve = 8, reloadTime = 2.5, note = "радиус 8, не бьёт по своим" },
	-- Ближний бой
	{ id = "Knife", name = "Боевой нож", ref = "Melee/CombatKnife", tier = "start", price = 0, damage = 25, fireRate = 2.5, note = "как сейчас" },
	{ id = "Bat", name = "Бита", ref = "Melee/BaseballBat", tier = "wall", slot = 1, price = 300, damage = 45, fireRate = 1.4, note = "как сейчас" },
	{ id = "Crowbar", name = "Монтировка", ref = "Melee/Crowbar", tier = "wall", price = 450, damage = 55, fireRate = 1.6 },
	{ id = "Machete", name = "Мачете", ref = "Melee/StandardMachete", tier = "wall", slot = 2, price = 600, damage = 70, fireRate = 1.8, note = "как сейчас" },
	{ id = "FireAxe", name = "Пожарный топор", ref = "Melee/FireAxe", tier = "wall", price = 900, damage = 95, fireRate = 1.1 },
	{ id = "Katana", name = "Катана", ref = "Melee/Katana", tier = "late", price = 1800, damage = 110, fireRate = 2.0 },
	{ id = "Sledge", name = "Кувалда", ref = "Melee/Sledgehammer", tier = "late", price = 1500, damage = 160, fireRate = 0.7, note = "сильное отбрасывание" },
	{ id = "Karambit", name = "Керамбит", ref = "Melee/Karambit", tier = "donate", price = 0, damage = 30, fireRate = 3.0, note = "косметика, чуть быстрее ножа" },
	{ id = "Balisong", name = "Бабочка", ref = "Melee/Balisong", tier = "donate", price = 0, damage = 25, fireRate = 2.5, note = "косметика" },
} :: { WeaponDraft }

-- Обвесы (только описание и модели; логика обвесов — следующий этап). ref — ServerStorage.Assets.Weapons.Sights.<имя>
-- Модель стоит основанием на рельсе: начало координат — центр основания, перёд — в -Z. aimY — высота линии прицеливания над рельсой.
Config.WeaponSights = {
	{ id = "RedDot", name = "Красная точка", ref = "Sights/RedDot", price = 300, zoom = 1.0, note = "по умолчанию на ПП" },
	{ id = "EOTech", name = "Голографический EOTech", ref = "Sights/EOTech", price = 600, zoom = 1.0 },
	{ id = "Holo", name = "Голографический простой", ref = "Sights/Holo", price = 450, zoom = 1.0 },
	-- 4× и 8× (оптика для снайперки) — моделей нет, искать (ACOG и снайперский прицел из списка Руслана не берём)
} :: { { id: string, name: string, ref: string, price: number, zoom: number, note: string? } }

-- Анимации персонажа (R15): официальные из Roblox Weapons Kit
Config.Animations = {
	aim = "rbxassetid://3972164452", -- RifleAim: оружие в руках, прицеливание
	reload = "rbxassetid://3972131105", -- RifleReload: перезарядка
}

-- Звуки: официальные Roblox (из Weapons Kit). Для разных стволов меняем тон и громкость.
Config.Sounds = {
	fire = "rbxassetid://3806566911",
	reload = "rbxassetid://3821789416",
	hit = "rbxassetid://1489924400",
	click = "rbxassetid://3909012115", -- сухой щелчок при пустом магазине
	swing = "rbxasset://sounds/swordslash.wav", -- взмах ближнего боя (встроенный звук Roblox)
}

local WeaponSounds: { [string]: WeaponSound } = {
	Pistol = { fireVolume = 0.8, firePitch = 1.0, fireTrim = 0.9, reloadVolume = 0.8, reloadPitch = 1.0 },
	SMG = { fireVolume = 0.55, firePitch = 1.35, fireTrim = 0.3, reloadVolume = 0.8, reloadPitch = 1.15 },
	Shotgun = { fireVolume = 1.0, firePitch = 0.65, fireTrim = 1.1, reloadVolume = 0.9, reloadPitch = 0.8 },
	Rifle = { fireVolume = 0.8, firePitch = 0.85, fireTrim = 0.5, reloadVolume = 0.9, reloadPitch = 0.9 },
	Revolver = { fireVolume = 0.9, firePitch = 0.8, fireTrim = 0.9, reloadVolume = 0.8, reloadPitch = 0.95 },
	LMG = { fireVolume = 0.7, firePitch = 0.95, fireTrim = 0.35, reloadVolume = 0.9, reloadPitch = 0.75 },
	Sniper = { fireVolume = 1.0, firePitch = 0.55, fireTrim = 1.4, reloadVolume = 0.9, reloadPitch = 0.7 },
}
Config.WeaponSounds = WeaponSounds

-- «Сочность» выстрела (клиентский FxController): отдача ствола (вдоль -Z рукояти, град.), толчок камеры, вспышка, гильзы
local WeaponFx: { [string]: WeaponFxDef } = {
	Pistol = { kickBack = 0.22, kickRot = 7, camPitch = 1.4, camYaw = 0.4, flash = 0.55, shell = true },
	SMG = { kickBack = 0.12, kickRot = 4, camPitch = 0.7, camYaw = 0.5, flash = 0.5, shell = true },
	Shotgun = { kickBack = 0.5, kickRot = 14, camPitch = 3.2, camYaw = 0.8, flash = 1.0, shell = true },
	Rifle = { kickBack = 0.2, kickRot = 6, camPitch = 1.3, camYaw = 0.6, flash = 0.7, shell = true },
	Revolver = { kickBack = 0.35, kickRot = 12, camPitch = 2.6, camYaw = 0.5, flash = 0.8, shell = false },
	LMG = { kickBack = 0.14, kickRot = 4, camPitch = 0.8, camYaw = 0.7, flash = 0.7, shell = true },
	Sniper = { kickBack = 0.55, kickRot = 14, camPitch = 4.0, camYaw = 0.3, flash = 1.0, shell = true },
}
Config.WeaponFx = WeaponFx

-- Прицеливание, отдача, разброс и реакция зомби на попадание (см. Shared/Ballistics). Значения — стартовые, под плейтест.
-- Отдача: pitch — градусов вверх за выстрел, yaw — размах зигзага; к 12-му выстрелу очереди растёт на recoilGrow.
local WeaponAim: { [string]: Ballistics.Aim } = {
	Pistol = { adsFov = 45, adsSpreadMul = 0.3, recoilPitch = 1.0, recoilYaw = 0.15, recoilGrow = 0, resetTime = 0.45, bloom = 0.15, bloomMax = 0.9, push = 5, stagger = 0.14 },
	SMG = { adsFov = 42, adsSpreadMul = 0.35, recoilPitch = 0.55, recoilYaw = 0.22, recoilGrow = 0.6, resetTime = 0.25, bloom = 0.12, bloomMax = 1.6, push = 3, stagger = 0.05 },
	Shotgun = { adsFov = 48, adsSpreadMul = 0.55, recoilPitch = 4.5, recoilYaw = 0.3, recoilGrow = 0, resetTime = 0.6, bloom = 0, bloomMax = 0, push = 18, stagger = 0.35 },
	Rifle = { adsFov = 35, adsSpreadMul = 0.25, recoilPitch = 0.8, recoilYaw = 0.25, recoilGrow = 0.5, resetTime = 0.3, bloom = 0.1, bloomMax = 1.2, push = 6, stagger = 0.15 },
	Revolver = { adsFov = 42, adsSpreadMul = 0.25, recoilPitch = 3.2, recoilYaw = 0.2, recoilGrow = 0, resetTime = 0.6, bloom = 0, bloomMax = 0, push = 12, stagger = 0.25 },
	LMG = { adsFov = 40, adsSpreadMul = 0.4, recoilPitch = 0.6, recoilYaw = 0.4, recoilGrow = 0.8, resetTime = 0.3, bloom = 0.15, bloomMax = 2.4, push = 4, stagger = 0.04 },
	Sniper = { adsFov = 12, adsSpreadMul = 0.05, recoilPitch = 5, recoilYaw = 0.1, recoilGrow = 0, resetTime = 0.8, bloom = 0, bloomMax = 0, push = 22, stagger = 0.45 },
}
Config.WeaponAim = WeaponAim

-- Оружие с оптическим прицелом: при прицеливании ствол и руки скрываются, на экране маска прицела с перекрестием (ViewModelController)
Config.ScopedWeapons = { Sniper = true } :: { [string]: boolean }

-- Взмах ближнего боя: стиль анимации, длительность (сек.) и сила тряски камеры при попадании
local MeleeFx: { [string]: MeleeFxDef } = {
	Knife = { style = "stab", time = 0.26, shake = 1.6 },
	Bat = { style = "smash", time = 0.42, shake = 3.2 },
	Machete = { style = "slash", time = 0.34, shake = 2.4 },
}
Config.MeleeFx = MeleeFx

-- Тестовый ассортимент (2026-10-19): оружие из Config.WeaponDraft, которого ещё нет в Config.Weapons, достраивается по образцу
-- базового ствола своего класса (разброс, дальность, отдача, звук, анимации — как у базы; цифры боя — из черновика).
-- Нужно для меню покупки (ShopController): в режиме осмотра всё бесплатно. Гранатомёты не добавляются (нет взрывов).
-- Баланс этих записей — черновой; боевые числа утверждает Руслан. Базы: пистолеты → Pistol, револьверы → Revolver, ПП → SMG,
-- дробовики → Shotgun, винтовки и карабины → Rifle, холодное — Knife/Bat/Machete по размеру.
local DRAFT_LENGTH = { Pistols = 1.4, Revolvers = 1.7, SMG = 2.2, Shotguns = 3.3, Rifles = 3.2, Carbines = 3.2 }
local DRAFT_BASE = { Pistols = "Pistol", Revolvers = "Revolver", SMG = "SMG", Shotguns = "Shotgun", Rifles = "Rifle", Carbines = "Rifle" }
local MELEE_LENGTH: { [string]: number } = { Crowbar = 2.8, FireAxe = 3.2, Sledge = 3.4, Katana = 3.8, Karambit = 1.4, Balisong = 1.7 } -- длина модели в руках, студов
local MELEE_BASE: { [string]: string } = { Karambit = "Knife", Balisong = "Knife", Crowbar = "Bat", Sledge = "Bat", FireAxe = "Machete", Katana = "Machete" }
local SHOP_CATEGORIES = { "Пистолеты", "ПП", "Дробовики", "Винтовки", "Тяжёлое", "Ближний бой" }
local CATEGORY_OF = { Pistols = 1, Revolvers = 1, SMG = 2, Shotguns = 3, Rifles = 4, Carbines = 4, Melee = 6 }
export type ShopItem = { id: string, category: number }
local shopList: { ShopItem } = {}
for _, d in Config.WeaponDraft do
	local class = string.match(d.ref, "^(%w+)/") or ""
	if class ~= "Launchers" then
		local baseId = if class == "Melee" then (MELEE_BASE[d.id] or "Bat") else DRAFT_BASE[class]
		if not Weapons[d.id] and baseId and Weapons[baseId] then
			local base = Weapons[baseId]
			local def = table.clone(base)
			def.id, def.name, def.price = d.id, d.name, d.price
			def.damage, def.pellets, def.fireRate = d.damage, d.pellets or base.pellets, d.fireRate
			if not base.melee then
				def.magSize, def.reserve, def.reloadTime = d.magSize or base.magSize, d.reserve or base.reserve, d.reloadTime or base.reloadTime
			end
			if d.id == "SKS" then
				def.automatic = false
			end
			if d.id == "Sledge" then
				def.knockback = 80
			end
			Weapons[d.id] = def
			WeaponAim[d.id] = WeaponAim[baseId]
			WeaponFx[d.id] = WeaponFx[baseId]
			WeaponSounds[d.id] = WeaponSounds[baseId]
			MeleeFx[d.id] = MeleeFx[baseId]
			Config.WeaponModels[d.id] = {
				ref = d.ref,
				length = if class == "Melee" then (MELEE_LENGTH[d.id] or 2.5) else DRAFT_LENGTH[class],
			}
		end
		if Weapons[d.id] then
			table.insert(shopList, { id = d.id, category = CATEGORY_OF[class] or (if class == "" then 5 else 4) })
		end
	end
end
Config.ShopCategories = SHOP_CATEGORIES

-- Класс оружия для прогрессии (Config.ThreatClasses): по папке модели; пулемёт и снайперка без модели — по id
local THREAT_BY_CLASS = { SMG = "SMG", Shotguns = "Shotgun", Rifles = "Rifle", Carbines = "Rifle" }
local WeaponThreat: { [string]: string } = {}
for _, d in Config.WeaponDraft do
	local class = string.match(d.ref, "^(%w+)/") or ""
	local kind = THREAT_BY_CLASS[class]
	if d.id == "LMG" then
		kind = "MG"
	elseif d.id == "Sniper" then
		kind = "Rifle"
	end
	if kind then
		WeaponThreat[d.id] = kind
	end
end
Config.WeaponThreat = WeaponThreat

-- Холодное оружие: свой стиль взмаха (MeleeAnim.STYLES), время и тряска камеры; керамбит держится за кольцо (оно в центре кисти)
local function meleeFx(id: string, style: string, time: number, shake: number)
	MeleeFx[id] = { style = style, time = time, shake = shake }
end
meleeFx("Katana", "katana", 0.3, 2.2)
meleeFx("Bat", "side", 0.5, 3.4)
meleeFx("FireAxe", "heavy", 0.85, 5.0)
meleeFx("Karambit", "swipe", 0.2, 1.2)
meleeFx("Balisong", "stab", 0.24, 1.4)
meleeFx("Crowbar", "smash", 0.38, 2.6)
meleeFx("Sledge", "heavy", 0.95, 6.0)
-- Доставание оружия (ViewModelController): стиль по классу оружия. time — вся анимация, с; rise — доля времени, за которую оружие приходит
-- из начального положения (variants: pos — смещение от стойки вправо/вверх/назад в студах, rot — наклон, градусы; вариант выбирается случайно);
-- turn/turnAt — осмотр: поворот (градусы) в промежутке turnAt долей времени; action — затвор (slide: затвор пистолета, charge: рукоятка/затвор
-- сбоку, pump: помпа дробовика) в промежутке actionAt, actionDist — ход затвора в студах. Холодное оружие (melee) — короткое доставание снизу.
export type DrawVariant = { pos: Vector3, rot: Vector3 }
export type DrawAnimDef = {
	time: number,
	rise: number,
	variants: { DrawVariant },
	turn: Vector3?,
	turnAt: { number }?,
	action: string?,
	actionAt: { number }?,
	actionDist: number?,
}
Config.DrawAnim = {
	melee = { time = 0.4, rise = 1, variants = { { pos = Vector3.new(0, -1, 0.35), rot = Vector3.new(-38, 0, 12) } } },
	-- пистолеты: поднимаются снизу, небольшой осмотр (поворот ствола к себе), передёргивание затвора левой рукой сверху
	pistol = {
		time = 1.25, rise = 0.3, variants = { { pos = Vector3.new(0.05, -0.85, 0.3), rot = Vector3.new(-40, 0, 8) } },
		turn = Vector3.new(-6, -38, 30), turnAt = { 0.3, 0.64 }, action = "slide", actionAt = { 0.64, 0.95 }, actionDist = 0.35,
	},
	-- ПП: небольшой поворот при выходе и передёргивание затвора сбоку (рукоятка взведения)
	smg = {
		time = 1.1, rise = 0.4, variants = { { pos = Vector3.new(0.25, -0.7, 0.4), rot = Vector3.new(-30, 22, -14) } },
		turn = Vector3.new(0, -28, -22), turnAt = { 0.25, 0.56 }, action = "charge", actionAt = { 0.58, 0.94 }, actionDist = 0.4,
	},
	-- винтовки: снизу или из-за спины (случайно)
	rifle = {
		time = 0.85, rise = 0.7,
		variants = {
			{ pos = Vector3.new(0.05, -1, 0.4), rot = Vector3.new(-42, 0, 10) },
			{ pos = Vector3.new(0.85, -0.2, 0.9), rot = Vector3.new(-12, 58, -34) },
		},
	},
	-- дробовики: из-за спины, в конце передёргивание помпой
	shotgun = {
		time = 1.3, rise = 0.5, variants = { { pos = Vector3.new(0.9, -0.15, 0.95), rot = Vector3.new(-14, 62, -36) } },
		action = "pump", actionAt = { 0.62, 0.95 }, actionDist = 0.45,
	},
	-- пулемёт: двумя руками справа из-за спины, тяжёлый, поэтому дольше
	lmg = { time = 1.4, rise = 0.7, variants = { { pos = Vector3.new(1.1, -0.3, 1.0), rot = Vector3.new(-18, 70, -40) } } },
} :: { [string]: DrawAnimDef }

-- Осмотр оружия (клавиша F), отдельно от доставания: короткий цикл, повторяется, пока держат F. При прерывании (R, повторное F, прицел)
-- анимация едет назад по тем же кадрам в reverseSpeed раз быстрее (Rewind), а не прокручивается до конца и не прыгает.
-- gun — огнестрел: time — один проход, с; pos — смещение оружия (вправо/вверх/назад, студы), rot — поворот (тангаж, рыскание, крен, градусы),
-- sway — качание рысканием/креном (градусы) и подъём (студы) в середине прохода; in/out — доли прохода на подъём и опускание.
-- Холодное оружие осматривается по MeleeAnim.INSPECT (флипы ножей), здесь для него только скорость возврата.
Config.Inspect = {
	reverseSpeed = 4,
	gun = { time = 1.3, pos = Vector3.new(-0.12, 0.08, 0.22), rot = Vector3.new(8, -42, 38), sway = Vector3.new(10, 14, 0.04), inRatio = 0.25, outRatio = 0.25 },
}

-- Стиль доставания по оружию: холодное — melee, пулемёт — lmg, снайперка — rifle, остальное — по папке модели (пистолеты и револьверы — pistol)
local DRAW_BY_CLASS = { Pistols = "pistol", Revolvers = "pistol", SMG = "smg", Shotguns = "shotgun", Rifles = "rifle", Carbines = "rifle" }
local WeaponDraw: { [string]: string } = {}
for id, def in Weapons do
	local model = Config.WeaponModels[id]
	local class = if model then (string.match(model.ref, "^(%w+)/") or "") else ""
	WeaponDraw[id] = if def.melee then "melee" elseif id == "LMG" then "lmg" else (DRAW_BY_CLASS[class] or "rifle")
end
Config.WeaponDraw = WeaponDraw

-- Комбо на ЛКМ: серия ударов разными позами (MeleeAnim.STYLES), если следующий удар начат не позже window секунд после начала предыдущего
-- (window больше интервала 1/fireRate оружия); после последнего удара серия идёт заново. time — длительность взмаха; удар по зомби сервер
-- применяет в долю MeleeAnim.HIT[style] от неё. Урон и темп (fireRate) не меняются. Катана: справа, слева, снизу. Бита: справа, слева.
export type ComboStep = { style: string, time: number }
Config.MeleeCombo = {
	Katana = { window = 0.9, steps = { { style = "katana", time = 0.3 }, { style = "katanaL", time = 0.3 }, { style = "katanaUp", time = 0.34 } } },
	Bat = { window = 1.3, steps = { { style = "side", time = 0.5 }, { style = "sideL", time = 0.5 } } },
} :: { [string]: { window: number, steps: { ComboStep } } }

if Config.WeaponModels.Karambit then
	Config.WeaponModels.Karambit.grip = Vector3.new(0, -0.47, 0.78) * (MELEE_LENGTH.Karambit / 1.13) + Vector3.new(0, 0.1, -0.5) -- кольцо у кисти, но лезвие выдвинуто вперёд, чтобы не пряталось за кулаком
end

-- Хват холодного оружия в руке: dir — куда смотрит остриё в системе кисти (X вправо, Y вверх, −Z вперёд), up — ориентация лезвия.
-- Tool.Grip считается из этого при сборке инструмента (WeaponService.buildTool).
export type MeleeHold = { dir: Vector3, up: Vector3 }
Config.MeleeHold = {
	-- остриём вверх: нож, бабочка, мачете, бита, топор (по просьбе Руслана); остальные — чуть вперёд
	default = { dir = Vector3.new(-0.12, 0.96, -0.25), up = Vector3.new(0, 0, 1) },
	Katana = { dir = Vector3.new(-0.2, 0.8, -0.55), up = Vector3.new(0, 0, 1) },
	Karambit = { dir = Vector3.new(-0.15, 0.75, -0.6), up = Vector3.new(0, 0, 1) },
} :: { [string]: MeleeHold }
Config.ShopList = shopList

-- Порядок стен с оружием в магазине (8 мест, см. BuildKit.shop)
Config.WallBuys = { "Bat", "Machete", "Revolver", "SMG", "Shotgun", "Rifle", "LMG", "Sniper" }

local Zombies: { [string]: ZombieDef } = {
	Walker = {
		id = "Walker", name = "Ходок", hp = 30, speed = 14, damage = 15, attackCooldown = 2.2, windup = 0.55, breakCooldown = 1,
		reward = 50, points = 10, scale = 1, color = Color3.fromRGB(95, 140, 80), planksPerHit = 1,
	},
	Runner = {
		id = "Runner", name = "Бегун", hp = 20, speed = 19, damage = 10, attackCooldown = 1.8, windup = 0.4, breakCooldown = 0.8,
		reward = 60, points = 15, scale = 0.9, color = Color3.fromRGB(150, 160, 70), planksPerHit = 1,
	},
	Brute = {
		id = "Brute", name = "Громила", hp = 300, speed = 12, damage = 35, attackCooldown = 3, windup = 0.9, breakCooldown = 1.5,
		reward = 400, points = 100, scale = 1.8, color = Color3.fromRGB(110, 50, 50), planksPerHit = 5,
	},
	-- Особые зомби (2026-10-19). Числа черновые: расписание по волнам и баланс — следующий шаг.
	Military = {
		id = "Military", name = "Заражённый военный", hp = 90, speed = 13, damage = 22, attackCooldown = 2.2, windup = 0.5, breakCooldown = 1,
		reward = 150, points = 40, scale = 1.05, color = Color3.fromRGB(80, 100, 70), planksPerHit = 2,
	},
	Chemist = {
		id = "Chemist", name = "Химик", hp = 45, speed = 12, damage = 10, attackCooldown = 2.4, windup = 0.5, breakCooldown = 1,
		reward = 120, points = 35, scale = 1, color = Color3.fromRGB(120, 200, 90), planksPerHit = 1,
		flask = { range = 40, minRange = 10, cooldown = 5, damage = 20, tick = 4, radius = 7 },
	},
	Dark = {
		id = "Dark", name = "Тёмный", hp = 75, speed = 17, damage = 20, attackCooldown = 2, windup = 0.4, breakCooldown = 0.8,
		reward = 140, points = 40, scale = 1, color = Color3.fromRGB(25, 25, 30), planksPerHit = 1,
		teleport = { cooldown = 7, distance = 18 },
	},
	BucketHead = {
		id = "BucketHead", name = "Бронированный", hp = 150, speed = 12, damage = 18, attackCooldown = 2.4, windup = 0.6, breakCooldown = 1.2,
		reward = 130, points = 40, scale = 1.15, color = Color3.fromRGB(120, 120, 120), planksPerHit = 2,
	},
	Crawler = {
		id = "Crawler", name = "Ползун", hp = 25, speed = 11, damage = 8, attackCooldown = 1.6, windup = 0.35, breakCooldown = 0.8,
		reward = 40, points = 12, scale = 0.6, color = Color3.fromRGB(110, 120, 90), planksPerHit = 1,
	},
	BossBuff = {
		id = "BossBuff", name = "Качок", hp = 2667, speed = 11, damage = 50, attackCooldown = 3, windup = 0.9, breakCooldown = 1.5,
		reward = 2000, points = 500, scale = 2.0, color = Color3.fromRGB(110, 60, 60), planksPerHit = 6,
			jump = { windup = 3, flight = 0.9, cooldown = 13, range = 70, minRange = 8, radius = 13, damage = 60, first = 6 },
			rock = { windup = 1.6, flight = 1.3, cooldown = 9, range = 75, minRange = 14, radius = 8, damage = 40, first = 4 },
	},
	BossGarg = {
		id = "BossGarg", name = "Гаргантюа", hp = 5000, speed = 9, damage = 80, attackCooldown = 3.5, windup = 1.1, breakCooldown = 1.8,
		reward = 4000, points = 800, scale = 2.5, color = Color3.fromRGB(70, 100, 60), planksPerHit = 8,
			-- (2026-10-28) вместо прыжка и броска камня: удар по земле, ползун со спины, бросок знака (rock со stun), обычный удар
			rock = { windup = 1.5, flight = 1.4, cooldown = 9, range = 75, minRange = 14, radius = 6, damage = 30, first = 4, stun = 2 },
			attacks = {
				slam = { windup = 1.3, cooldown = 10, first = 5, range = 40, minRange = 4, length = 42, width = 4, speed = 32, life = 4.5, slowMult = 0.4, slowSeconds = 3 },
				crawlers = { windup = 1.5, flight = 1.0, cooldown = 14, first = 8, range = 60, minRange = 12, maxAlive = 6 },
			},
	},
	BossStrong = {
		id = "BossStrong", name = "Повелитель тёмных", hp = 3000, speed = 13, damage = 60, attackCooldown = 2.8, windup = 0.8, breakCooldown = 1.4,
		reward = 3000, points = 650, scale = 1.7, color = Color3.fromRGB(40, 30, 50), planksPerHit = 6,
			-- (2026-10-28) разбег, чёрный взмах, прыжок с волной тьмы (jump.wave), обычный удар дубинкой
			jump = { windup = 3, flight = 0.8, cooldown = 11, range = 70, minRange = 8, radius = 13, damage = 70, first = 6, wave = { extra = 10, noSprint = 3 } },
			attacks = {
				charge = { windup = 2, lockBefore = 0.7, speed = 48, distance = 70, width = 5, damage = 70, recover = 1.4, cooldown = 14, first = 9, range = 80, minRange = 15 },
				swing = { windup = 0.9, cooldown = 9, first = 5, range = 60, minRange = 5, speed = 60, length = 55, width = 9, damage = 45 },
			},
	},
	-- Финальный босс (ночь 20, решение Руслана 2026-10-29: новая модель, ассет 5794917487, свой набор механик). Фаза 1: порез + способности; фаза 2 (HP ≤ 50%):
	-- только способности и неуязвимость к огнестрелу. Тени (clones) повторяют способности, кроме раздвоения, и в 20 раз слабее.
	BossFinal = {
		id = "BossFinal", name = "Страж бункера", hp = 6000, speed = 13, damage = 70, attackCooldown = 2.6, windup = 0.8, breakCooldown = 1.4,
		reward = 5000, points = 1000, scale = 1.9, color = Color3.fromRGB(30, 24, 36), planksPerHit = 7,
			phase2 = { hpFraction = 0.5 },
			attacks = {
				sea = { windup = 1.3, cooldown = 15, first = 6, range = 90, minRange = 0, waves = 3, gap = 1, speed = 38, length = 80, width = 70, height = 3, damage = 40 },
				comets = { windup = 1.6, cooldown = 26, first = 14, range = 140, minRange = 0, count = 20, interval = 0.35, hover = 2.1, fall = 0.8, radius = 6, damage = 45, height = 45 },
				clones = { windup = 1.8, cooldown = 45, first = 16, range = 140, minRange = 0, count = 3, hpDivisor = 20, rise = 1.4, alpha = 0.6 },
				beam = { windup = 1, cooldown = 20, first = 10, range = 110, minRange = 6, duration = 5, chaseSpeed = 17, radius = 3.5, damage = 14, tick = 0.25 },
				slash = { windup = 0.55, cooldown = 2.2, first = 1, range = 16, minRange = 0, speed = 55, length = 32, size = 9, damage = 35 },
			},
	},
}

Config.Zombies = Zombies
-- Здоровье зомби уменьшено (2026-10-27, по просьбе Руслана): у всех вдвое, у босса 5-й ночи (Качок) в 1,5 раза; потом добавим количество, а не жирность.
-- Множитель здоровья по модели в пуле BucketHead (поверх hp): «с конусом» итого в 4 раза слабее прежнего (150 × 0,5 = 75), «с ведром» — в 3 раза (150 × 0,667 = 100).
Config.ZombieRigHp = { Z_Cone = 0.5, Z_Bucket = 0.667 } :: { [string]: number }

-- Внешний вид зомби (2026-10-17, v2): готовые модели R15 из Creator Store, собранные из мешей тела (см. assets_ledger).
-- Позиции — в системе корня (начало — таз, лицо смотрит в -Z). height — рост, pelvis — высота таза над стопами.
-- Каждая «часть» (Head, Torso, LeftArm, RightArm, LeftLeg, RightLeg) — основной меш на сварке W_<Часть> (поворачивается
-- при замахе и реакции на попадание) + extra — остальные меши R15 (предплечье, кисть, голень, стопа, таз), приваренные к основному.
-- pivot — точка вращения (шея, плечо, бедро); hitSize/hitPos — невидимый хитбокс части (в системе корня).
-- id мешей и текстур записаны без префикса rbxassetid:// (его добавляет нормализация ниже); color/material — если отличаются от стандартных.
export type ZombieVisualExtra = { mesh: string, texture: string, size: Vector3, pos: Vector3, color: Color3?, material: string? }
export type ZombieVisualPart = {
	part: string, mesh: string, texture: string, size: Vector3, pos: Vector3, pivot: Vector3,
	hitSize: Vector3, hitPos: Vector3, color: Color3?, material: string?, extra: { ZombieVisualExtra }?,
}
export type ZombieVisual = { height: number, pelvis: number, parts: { ZombieVisualPart } }
local V = Vector3.new
local ZombieVisuals: { [string]: ZombieVisual } = {
	Walker = { height = 5.80, pelvis = 3.41, parts = {
		{ part = "Head", mesh = "3182202971", texture = "3182205395", size = V(0.61, 1.03, 0.79), pos = V(0.00, 1.87, -0.02), pivot = V(0.00, 1.35, -0.02), hitSize = V(0.58, 0.98, 0.75), hitPos = V(0.00, 1.87, -0.02) },
		{ part = "Torso", mesh = "3182202967", texture = "3182206678", size = V(1.22, 1.95, 1.26), pos = V(0.01, 0.67, -0.02), pivot = V(0.00, 0.00, 0.00), hitSize = V(1.04, 2.27, 1.01), hitPos = V(0.01, 0.42, -0.02), extra = { { mesh = "3182202986", texture = "3182206678", size = V(1.14, 0.70, 1.05), pos = V(0.00, -0.36, 0.08) } } },
		{ part = "LeftArm", mesh = "3182202958", texture = "3182205732", size = V(0.56, 1.17, 0.47), pos = V(-0.66, 0.85, 0.20), pivot = V(-0.66, 1.43, 0.20), hitSize = V(0.65, 2.17, 0.61), hitPos = V(-0.77, 0.15, 0.08), extra = { { mesh = "3182202957", texture = "3182205732", size = V(0.41, 0.89, 0.45), pos = V(-0.92, -0.05, 0.14) }, { mesh = "3182202965", texture = "3182205732", size = V(0.33, 0.74, 0.46), pos = V(-0.98, -0.75, -0.05) } } },
		{ part = "RightArm", mesh = "3182202959", texture = "3182206211", size = V(0.52, 1.21, 0.46), pos = V(0.71, 0.61, 0.20), pivot = V(0.71, 1.21, 0.20), hitSize = V(0.64, 2.20, 0.61), hitPos = V(0.82, -0.08, 0.08), extra = { { mesh = "3182202960", texture = "3182206211", size = V(0.46, 0.98, 0.49), pos = V(0.95, -0.28, 0.14) }, { mesh = "3182202962", texture = "3182206211", size = V(0.35, 0.80, 0.48), pos = V(1.02, -0.98, -0.04) } } },
		{ part = "LeftLeg", mesh = "3182202972", texture = "3182205952", size = V(0.73, 1.41, 0.73), pos = V(-0.42, -1.07, 0.04), pivot = V(-0.42, -0.36, 0.04), hitSize = V(0.62, 2.59, 0.87), hitPos = V(-0.42, -1.89, -0.11), extra = { { mesh = "3182202970", texture = "3182205952", size = V(0.47, 1.66, 0.53), pos = V(-0.51, -2.27, 0.08) }, { mesh = "3182202969", texture = "3182205952", size = V(0.54, 0.49, 0.84), pos = V(-0.49, -3.17, -0.20) } } },
		{ part = "RightLeg", mesh = "3182202980", texture = "3182206464", size = V(0.73, 1.42, 0.73), pos = V(0.42, -1.07, 0.04), pivot = V(0.42, -0.36, 0.04), hitSize = V(0.62, 2.58, 0.85), hitPos = V(0.42, -1.88, -0.10), extra = { { mesh = "3182202979", texture = "3182206464", size = V(0.48, 1.65, 0.39), pos = V(0.46, -2.36, -0.01) }, { mesh = "3182202982", texture = "3182206464", size = V(0.49, 0.35, 0.83), pos = V(0.45, -3.22, -0.18) } } },
	} },
	Runner = { height = 5.20, pelvis = 3.06, parts = {
		{ part = "Head", mesh = "3182202971", texture = "2830889216", size = V(0.55, 0.93, 0.71), pos = V(0.00, 1.68, -0.02), pivot = V(0.00, 1.21, -0.02), hitSize = V(0.52, 0.88, 0.67), hitPos = V(0.00, 1.68, -0.02) },
		{ part = "Torso", mesh = "3182202967", texture = "2830889216", size = V(1.10, 1.75, 1.13), pos = V(0.01, 0.60, -0.02), pivot = V(0.00, 0.00, 0.00), hitSize = V(0.93, 2.06, 0.90), hitPos = V(0.01, 0.39, -0.02), extra = { { mesh = "3182202986", texture = "3182206678", size = V(1.03, 0.63, 0.94), pos = V(0.00, -0.33, 0.08) } } },
		{ part = "LeftArm", mesh = "3182202958", texture = "2830889216", size = V(0.50, 1.05, 0.43), pos = V(-0.59, 0.76, 0.18), pivot = V(-0.59, 1.29, 0.18), hitSize = V(0.59, 1.95, 0.54), hitPos = V(-0.69, 0.14, 0.07), extra = { { mesh = "3182202957", texture = "3182205732", size = V(0.37, 0.79, 0.40), pos = V(-0.82, -0.05, 0.13) }, { mesh = "3182202965", texture = "3182205732", size = V(0.30, 0.67, 0.42), pos = V(-0.88, -0.68, -0.04) } } },
		{ part = "RightArm", mesh = "3182202959", texture = "2830889216", size = V(0.47, 1.09, 0.42), pos = V(0.64, 0.54, 0.18), pivot = V(0.64, 1.09, 0.18), hitSize = V(0.57, 1.98, 0.54), hitPos = V(0.74, -0.08, 0.07), extra = { { mesh = "3182202960", texture = "3182206211", size = V(0.41, 0.88, 0.44), pos = V(0.85, -0.25, 0.13) }, { mesh = "3182202962", texture = "3182206211", size = V(0.31, 0.71, 0.43), pos = V(0.92, -0.88, -0.04) } } },
		{ part = "LeftLeg", mesh = "3182202972", texture = "2830889216", size = V(0.65, 1.26, 0.66), pos = V(-0.38, -0.95, 0.03), pivot = V(-0.38, -0.32, 0.03), hitSize = V(0.56, 2.33, 0.78), hitPos = V(-0.38, -1.69, -0.10), extra = { { mesh = "3182202970", texture = "3182205952", size = V(0.42, 1.49, 0.48), pos = V(-0.46, -2.03, 0.07) }, { mesh = "3182202969", texture = "3182205952", size = V(0.49, 0.44, 0.75), pos = V(-0.44, -2.84, -0.18) } } },
		{ part = "RightLeg", mesh = "3182202980", texture = "2830889216", size = V(0.65, 1.27, 0.66), pos = V(0.38, -0.95, 0.03), pivot = V(0.38, -0.32, 0.03), hitSize = V(0.56, 2.32, 0.77), hitPos = V(0.38, -1.68, -0.09), extra = { { mesh = "3182202979", texture = "3182206464", size = V(0.43, 1.48, 0.35), pos = V(0.41, -2.12, -0.01) }, { mesh = "3182202982", texture = "3182206464", size = V(0.44, 0.31, 0.75), pos = V(0.41, -2.89, -0.17) } } },
	} },
}
-- Громила — тот же Ходок, но крупнее и с красноватым оттенком (id ассетов ещё без префикса, как у остальных)
local function scaledZombie(src: ZombieVisual, k: number, tint: Color3): ZombieVisual
	local function part(p: ZombieVisualPart): ZombieVisualPart
		local out = table.clone(p)
		out.size, out.pos, out.pivot, out.hitSize, out.hitPos = p.size * k, p.pos * k, p.pivot * k, p.hitSize * k, p.hitPos * k
		out.color = tint
		if p.extra then
			local extras = {}
			for _, e in p.extra do
				local ex = table.clone(e)
				ex.size, ex.pos, ex.color = e.size * k, e.pos * k, tint
				table.insert(extras, ex)
			end
			out.extra = extras
		end
		return out
	end
	local parts = {}
	for _, p in src.parts do
		table.insert(parts, part(p))
	end
	return { height = src.height * k, pelvis = src.pelvis * k, parts = parts }
end
ZombieVisuals.Brute = scaledZombie(ZombieVisuals.Walker, 8.6 / 5.8, Color3.fromRGB(215, 160, 150))

-- id → полный адрес ассета

local function assetUri(id: string): string
	return if id == "" then "" else "rbxassetid://" .. id
end
for _, vis in ZombieVisuals do
	for _, vp in vis.parts do
		vp.mesh, vp.texture = assetUri(vp.mesh), assetUri(vp.texture)
		for _, ex in vp.extra or {} do
			ex.mesh, ex.texture = assetUri(ex.mesh), assetUri(ex.texture)
		end
	end
end
Config.ZombieVisuals = ZombieVisuals

-- «Зомби 3.0» (2026-10-19): готовые R6-модели Руслана из ServerStorage.Assets.Zombies (Humanoid, Motor6D, Animator).
-- Тип зомби → пул моделей; при создании берётся случайная из пула. Нет пула/моделей — старая сборка из мешей (ZombieVisuals).
-- pool — имена моделей библиотеки; scale — множитель роста (R6 ≈ 5 студов); animSpeed — скорость шага, при которой анимация идёт 1:1;
-- useRun — вместо ходьбы играть анимацию бега модели; tint — перекраска (необязательно).
-- Анимации читаются из атрибутов модели Anim_idle / Anim_walk / Anim_run / Anim_attack (записал Baker из Animation-объектов ассета),
-- чего нет — берётся ZombieAnimDefaults (стандартные R6 Roblox).
-- absolute — scale задаёт итоговый размер модели (без множителя def.scale); crawl — корпус прижат к земле (ползун)
export type ZombieRig = { pool: { string }, scale: number, animSpeed: number, useRun: boolean?, tint: Color3?, absolute: boolean?, crawl: boolean?, noAlertTint: boolean? }
Config.UseRigZombies = true
Config.ZombieAnimDefaults = { idle = "180435571", walk = "180426354", run = "180426354" }
Config.ZombieRigs = {
	Walker = {
		pool = { "Z_Walker1", "Z_Pack1", "Z_Pack2", "Z_Pack3", "Z_Pack4", "Z_Pack5", "Z_Pack6", "Z_Pack7", "Z_Pack8", "Z_P4_1", "Z_P4_2", "Z_P4_3", "Z_P4_4" },
		scale = 1.1, animSpeed = 13,
	},
	Runner = {
		pool = { "Z_Drooling", "Z_Runner1", "Z_Zombie1" },
		scale = 1.05, animSpeed = 15, useRun = true,
	},
	Brute = { -- большой «обычный»
		pool = { "Z_Pack2", "Z_Pack1" },
		scale = 0.8, animSpeed = 10,
	},
	Military = { pool = { "Z_Mil1", "Z_Mil2", "Z_Mil3", "Z_Mil4", "Z_Mil5" }, scale = 1.0, absolute = true, animSpeed = 13 },
	Chemist = { pool = { "Z_Chem1", "Z_Chem2", "Z_Chem3" }, scale = 1.0, absolute = true, animSpeed = 12 },
	Dark = { pool = { "Z_Pack1", "Z_Pack3", "Z_Pack4", "Z_Pack5", "Z_Pack6", "Z_Pack7" }, scale = 1.05, absolute = true, animSpeed = 15, useRun = true, tint = Color3.fromRGB(22, 22, 28) },
	BucketHead = { pool = { "Z_Bucket", "Z_Cone" }, scale = 1.1, absolute = true, animSpeed = 12 },
	Crawler = { pool = { "Z_Pack1", "Z_Pack3", "Z_Pack4", "Z_Pack5", "Z_Pack6", "Z_Pack7", "Z_Pack8" }, scale = 0.85, absolute = true, animSpeed = 9, crawl = true },
	BossBuff = { pool = { "B_Buff" }, scale = 0.6, absolute = true, animSpeed = 8 },
	BossGarg = { pool = { "B_Garg" }, scale = 1.8, absolute = true, animSpeed = 6 },
	BossStrong = { pool = { "B_Strong" }, scale = 0.95, absolute = true, animSpeed = 10 },
	BossFinal = { pool = { "B_Final" }, scale = 2.4, absolute = true, animSpeed = 14, useRun = true, noAlertTint = true }, -- R15, ассет 5794917487 («Boss-Dark Zombie»), скрипты вычищены
} :: { [string]: ZombieRig }

-- Машины: сгенерированные меши (Studio generate_mesh, 2026-10-17), модель стоит основанием на земле, перёд — в -Z.
export type MeshProp = { id: string, mesh: string, texture: string, size: Vector3 }
Config.CarVisuals = {
	{ id = "sedan", mesh = "rbxassetid://129272857890305", texture = "rbxassetid://84409657774031", size = Vector3.new(5.950, 5.200, 11.020) },
	{ id = "taxi", mesh = "rbxassetid://92599135640985", texture = "rbxassetid://85508270173744", size = Vector3.new(5.420, 5.200, 10.730) },
	{ id = "pickup", mesh = "rbxassetid://98886210970866", texture = "rbxassetid://138402185501088", size = Vector3.new(10.560, 10.400, 19.700) }, -- ×2 по просьбе Руслана
} :: { MeshProp }

-- Целые легковые машины из Creator Store (модели без скриптов лежат в ServerStorage.CarModels, а не в src).
-- Шаблон: корень Root (невидимая коробка-коллизия) + визуальные части без коллизии; перёд — в -Z, основание на земле.
-- length — итоговая длина в студах (модель масштабируется целиком).
Config.CarModels = {
	{ id = "Prius", length = 13 },
	{ id = "Sedan", length = 13.5 },
	{ id = "Coupe", length = 13 },
} :: { { id: string, length: number } }

-- Реквизит помещений и улиц: сгенерированные меши (Studio generate_mesh, 2026-10-17). Основание на земле, перёд — в -Z.
-- Размер подогнан по высоте (в студах), пропорции — как у меша.
Config.Props = {
	barrel = { id = "barrel", mesh = "rbxassetid://140582108961361", texture = "rbxassetid://77852703394003", size = Vector3.new(2.398, 3.600, 2.395) },
	bunk = { id = "bunk", mesh = "rbxassetid://70482340500678", texture = "rbxassetid://78936043302699", size = Vector3.new(7.272, 6.300, 3.646) },
	cafe_counter = { id = "cafe_counter", mesh = "rbxassetid://85528278208501", texture = "rbxassetid://97455988190072", size = Vector3.new(5.171, 4.600, 3.475) },
	cafe_table = { id = "cafe_table", mesh = "rbxassetid://124712917529755", texture = "rbxassetid://112352464903247", size = Vector3.new(6.162, 4.400, 3.434) },
	crates = { id = "crates", mesh = "rbxassetid://132407778378387", texture = "rbxassetid://111787660296897", size = Vector3.new(4.079, 5.000, 2.946) },
	dumpster = { id = "dumpster", mesh = "rbxassetid://91666621374441", texture = "rbxassetid://103951974913486", size = Vector3.new(3.029, 5.000, 3.457) },
	lamp = { id = "lamp", mesh = "rbxassetid://70651189363768", texture = "rbxassetid://126128509168015", size = Vector3.new(7.630, 17.000, 2.267) },
	medcabinet = { id = "medcabinet", mesh = "rbxassetid://71492390288705", texture = "rbxassetid://137435795271440", size = Vector3.new(3.646, 7.000, 2.244) },
	pharm_counter = { id = "pharm_counter", mesh = "rbxassetid://77059312536642", texture = "rbxassetid://112153749413645", size = Vector3.new(7.830, 3.600, 4.892) },
	shelf = { id = "shelf", mesh = "rbxassetid://82671446985249", texture = "rbxassetid://92562520345154", size = Vector3.new(4.377, 7.000, 2.694) },
	weapon_rack = { id = "weapon_rack", mesh = "rbxassetid://74726149311071", texture = "rbxassetid://89623108733746", size = Vector3.new(5.728, 5.500, 3.274) },
	workbench = { id = "workbench", mesh = "rbxassetid://88300467054470", texture = "rbxassetid://70826351294526", size = Vector3.new(7.453, 3.400, 4.289) },
} :: { [string]: MeshProp }

-- Прогрессия волн (WaveMath). Количество: кривая от StartCounts до потолка на CurveWaves-й волне (±JitterPct%), плюс добавка за оружие команды
-- (ThreatClasses, один раз за класс); потолок: CapSolo, для команды × (1 + CapPerExtraPlayer·(игроков − 1)) — 250 соло, 500 вчетвером.
-- Состав по волнам — WaveMath.Plan.
-- Качество: HP растёт каждую волну и ещё зависит от «уровня угрозы» (Config.Threat.Tiers — вооружённость команды), скорость чуть растёт, но не выше SpeedCeil (спринт игрока — 21).
Config.Waves = {
	StartCounts = { 20, 30, 35, 40 }, -- на 1-й волне для 1, 2, 3, 4 игроков; дальше + StartPerExtraPlayer
	StartPerExtraPlayer = 4,
	CurveWaves = 20, -- на этой волне число зомби достигает потолка
	CurveExp = 1.25,
	JitterPct = 10,
	CapSolo = 250,
	CapPerExtraPlayer = 1 / 3,
	HpGrowthPerWave = 0.12,
	DamageGrowthPerWave = 0.03,
	SpeedGrowthPerWave = 0.01,
	SpeedCeil = 18,
	BossEvery = 5,
	CountScale = 0.1, -- ТЕСТЫ: числа зомби на 90% меньше, чтобы быстрее проходить ночи; в релизе удалить или поставить 1
}

-- Класс оружия для прогрессии: у каждого — вес (для уровня угрозы) и добавка зомби к волне (диапазон, случайно один раз на волну).
-- Считаются любые оружия в инвентаре игроков на момент начала ночи; пистолеты и холодное — нет.
Config.ThreatClasses = {
	SMG = { weight = 7, bonusMin = 5, bonusMax = 10 },
	Shotgun = { weight = 7, bonusMin = 5, bonusMax = 10 },
	Rifle = { weight = 15, bonusMin = 10, bonusMax = 20 },
	MG = { weight = 15, bonusMin = 10, bonusMax = 20 },
}
-- Уровни угрозы по среднему весу оружия на игрока: min — нижняя граница; hp — множитель здоровья; runners — добавка к доле бегунов (доля всей волны, за счёт обычных; только на волнах, где бегуны есть по плану WaveMath.Plan);
-- early — на сколько волн раньше приходят особые зомби.
Config.Threat = {
	Tiers = {
		{ min = 0, hp = 1.0, runners = 0, early = 0 },
		{ min = 7, hp = 1.1, runners = 0.05, early = 0 },
		{ min = 15, hp = 1.2, runners = 0.1, early = 1 },
		{ min = 29, hp = 1.35, runners = 0.15, early = 1 },
	},
}

-- Перки команды (Shared/Perks, PerkService): после каждого босса каждый игрок выбирает 1 из 3 случайных своих перков, выбранные действуют на всю
-- команду до конца раунда. kind: health (+HP), stamina (+доля времени спринта), mag (+доля магазина), speed (+доля скорости ходьбы и бега),
-- power (+доля урона), reload (−доля времени перезарядки), ammo (+доля запаса патронов), revive (−доля времени подъёма), coins (+доля монет).
-- per — прирост за один стак, max — сколько раз можно взять.
Config.Perks = {
	{ id = "Vigor", name = "Закалка", desc = "+50 к здоровью", kind = "health", per = 50, max = 3, color = Color3.fromRGB(230, 90, 90) },
	{ id = "Endurance", name = "Выносливость", desc = "+10 к энергии спринта", kind = "stamina", per = 0.10, max = 5, color = Color3.fromRGB(90, 190, 255) },
	{ id = "Mag", name = "Расширенный магазин", desc = "+30% к магазину оружия", kind = "mag", per = 0.30, max = 2, color = Color3.fromRGB(240, 200, 80) },
	{ id = "Swift", name = "Лёгкая поступь", desc = "+5% к скорости", kind = "speed", per = 0.05, max = 3, color = Color3.fromRGB(120, 230, 150) },
	{ id = "Power", name = "Убойная сила", desc = "+10% к урону", kind = "power", per = 0.10, max = 3, color = Color3.fromRGB(255, 140, 60) },
	{ id = "Reload", name = "Быстрые руки", desc = "Перезарядка на 15% быстрее", kind = "reload", per = 0.15, max = 3, color = Color3.fromRGB(200, 160, 255) },
	{ id = "Ammo", name = "Запас патронов", desc = "+25% к запасу патронов", kind = "ammo", per = 0.25, max = 3, color = Color3.fromRGB(220, 200, 140) },
	{ id = "Medic", name = "Полевой медик", desc = "Поднимаете на 30% быстрее", kind = "revive", per = 0.30, max = 2, color = Color3.fromRGB(240, 240, 240) },
	{ id = "Greed", name = "Мародёр", desc = "+10% монет", kind = "coins", per = 0.10, max = 3, color = Color3.fromRGB(255, 215, 0) },
}

-- Перки команды (Shared/Perks, PerkService): после каждого босса каждый игрок выбирает 1 из 3 случайных своих перков, выбранные действуют на всю
-- команду до конца раунда. kind: health (+HP), stamina (+доля времени спринта), mag (+доля магазина), speed (+доля скорости ходьбы и бега),
-- power (+доля урона), reload (−доля времени перезарядки), ammo (+доля запаса патронов), revive (−доля времени подъёма), coins (+доля монет).
-- per — прирост за один стак, max — сколько раз можно взять.
Config.Perks = {
	{ id = "Vigor", name = "Закалка", desc = "+50 к здоровью", kind = "health", per = 50, max = 3, color = Color3.fromRGB(230, 90, 90) },
	{ id = "Endurance", name = "Выносливость", desc = "+10 к энергии спринта", kind = "stamina", per = 0.10, max = 5, color = Color3.fromRGB(90, 190, 255) },
	{ id = "Mag", name = "Расширенный магазин", desc = "+30% к магазину оружия", kind = "mag", per = 0.30, max = 2, color = Color3.fromRGB(240, 200, 80) },
	{ id = "Swift", name = "Лёгкая поступь", desc = "+5% к скорости", kind = "speed", per = 0.05, max = 3, color = Color3.fromRGB(120, 230, 150) },
	{ id = "Power", name = "Убойная сила", desc = "+10% к урону", kind = "power", per = 0.10, max = 3, color = Color3.fromRGB(255, 140, 60) },
	{ id = "Reload", name = "Быстрые руки", desc = "Перезарядка на 15% быстрее", kind = "reload", per = 0.15, max = 3, color = Color3.fromRGB(200, 160, 255) },
	{ id = "Ammo", name = "Запас патронов", desc = "+25% к запасу патронов", kind = "ammo", per = 0.25, max = 3, color = Color3.fromRGB(220, 200, 140) },
	{ id = "Medic", name = "Полевой медик", desc = "Поднимаете на 30% быстрее", kind = "revive", per = 0.30, max = 2, color = Color3.fromRGB(240, 240, 240) },
	{ id = "Greed", name = "Мародёр", desc = "+10% монет", kind = "coins", per = 0.10, max = 3, color = Color3.fromRGB(255, 215, 0) },
}

-- Миссии ночей (сюжет: docs/story.md, MissionService). anchor — номер шатра/точки района по удалению от базы (1 — ближайший);
-- radius = { от, до } — расстояние контрольных точек от места шатра в студах (по умолчанию Config.ScoutRadius = 50–100);
-- type: scout (points контрольных точек), defend (seconds секунд у шатра), clear, classic — убить всю волну; planned — тип, который ещё не сделан
-- (сейчас играется как classic). Не указано — classic.
-- convoySpeed — скорость грузовика этой миссии (студов/с), вместо Config.Convoy.TruckSpeed; clearSandbags — на эту ночь убрать мешки с песком у точки появления игроков (Config.Convoy.Sandbag*)
export type MissionDef = { type: string, title: string, anchor: number, points: number?, radius: { number }?, seconds: number?, hint: string?, planned: string?, kills: number?, install: boolean?, brief: string?, convoySpeed: number?, clearSandbags: boolean?, baseBattle: boolean?, day: boolean?, bosses: { string }?, nests: number?, boss: string? }
-- Конвой (ConvoyService): грузовик и два военных-сопровождающих; зомби атакуют их наравне с игроками
Config.Convoy = {
	TruckHp = 1000,
	TruckSpeed = 9.5, -- студов в секунду. ТЕСТ (2026-10-24): все конвои за ~3 минуты (самый длинный маршрут, ночь 12, ~1614 студов → ~170 с); в релизе вернуть к ~3,5 или короче маршруты
	SoldierHp = 150, -- было 300: сопровождающие были слишком сильными (2026-10-26)
	SoldierDps = 15, -- урон по зомби в секунду каждого солдата (было 50)
	SoldierShotInterval = 0.5,
	SoldierRange = 40,
	AliveCap = 14, -- живых зомби одновременно на миссии конвоя (грузовик 1000 HP не выдержит 40)
	InstallHold = 6, -- сколько секунд держать «Установить шатёр»
	Model = "APC", -- машина конвоя из ServerStorage.Assets.Vehicles (бронетранспортёр Stryker); запасная — TransportTruck
	Solid = false, -- true: машина твёрдая (толкает игроков, но на стыках дороги скорость неровная)
	FollowGain = 6, -- 1/с: как сильно машина подтягивается к расчётной точке маршрута (скорость = курс × скорость + ошибка × FollowGain)
	TurnGain = 8, -- 1/с: как быстро машина доворачивает к расчётной позе
	MaxLag = 12, -- студов: дальше машина от расчётной точки (застряла) — возвращаем на маршрут
	MaxTilt = 12, -- градусов: наклон кузова от вертикали (крен или тангаж) больше — машину ставят на колёса по курсу (не даём перевернуться на уклонах и рёбрах)
	EngineVolume = 0.04, -- громкость мотора грузовика (было 0,12: слишком громко)
	Accel = 2.5, -- студов/с² — разгон
	Brake = 4, -- студов/с² — торможение
	FollowRadius = 60, -- грузовик едет, только когда рядом (в этом радиусе, студов) есть живой игрок; иначе стоит и ждёт
	StartOffset = 14, -- студов: грузовик ночью-конвоя выезжает из начальной зоны — от точки появления игроков в сторону ближайшей дороги
	SandbagFolder = "Base", -- где лежат мешки с песком (модели Fort), перекрывающие выезд из начальной зоны
	SandbagName = "Fort",
}
Config.ScoutRadius = { 50, 100 } -- радиус контрольных точек от места шатра по умолчанию (у миссии можно задать свой: radius)
-- Разговор с солдатами базы (SoldierService, клавиша E на солдате): случайная реплика над головой, подряд одна и та же не повторяется.
-- bubbleTime — сколько секунд виден пузырь (и стоит солдат), soldierCooldown — пауза солдата между разговорами, playerInterval — минимум секунд между запросами игрока
Config.SoldierTalk = {
	bubbleTime = 4.5,
	soldierCooldown = 1.5,
	playerInterval = 1,
	distance = 9,
	lines = {
		"Боец, а ты точно не зомби? Покажи документы. Лучше зубы покажи.",
		"Генерал Нурсултан сказал держать позицию. Я держу. Уже третий час. Ногу не чувствую.",
		"Устав гласит: не стой там, где сложно бегать.",
		"Мутанты ночью, мы днём. Всё по графику, как в профсоюзе.",
		"Хочешь совет? Целься в голову. Если голова есть.",
		"Сухпаёк закончился. Остались только лавровый лист и надежда.",
		"Я не боюсь зомби. Я боюсь, что генерал заставит чистить картошку.",
		"Говорят, где-то есть тихая ночь. Не верю.",
		"Береги патроны, боец. Мы их не печатаем.",
		"Я бы сходил в увольнение, но город сейчас занят.",
		"Если встретишь босса, беги. Если не встретишь, всё равно беги.",
		"Старшина учил: один выстрел — один зомби. Старшина не видел толпу.",
		"На базе безопасно. По крайней мере, до рассвета, потом тоже безопасно.",
		"Тут недавно один зомби попросил прикурить. Мы ему отказали из принципа.",
		"Не забывай перезаряжаться. Это тебе не кино, там магазины бесконечные.",
		"Нурсултан сегодня в хорошем настроении. Расстрелял только одну ведомость.",
		"Знаешь, почему мы не спим? Потому что ночью приходят мутанты. И ещё кофе.",
		"Мой дедушка воевал, отец воевал. А я тут с зомби. Эволюция.",
		"Каску надел? Нет? Ну, значит, будешь героем. Посмертно.",
		"Лучшая защита — это забор. Лучше забора только двойной забор.",
		"Видишь тот шатёр? Раньше он был палаткой, теперь это стратегический объект.",
		"Я тут записался в добровольцы. Не знал, что нас никто не спрашивал.",
		"Зомби медленные? Расскажи это тому, что ночью меня догнал.",
		"Не геройствуй. Герои у нас долго не служат, зато красиво.",
		"Дежурство, боец, это когда ты стоишь и стараешься не заснуть. Вот этим я и занят.",
		"Главное в армии — уметь вовремя сказать «так точно» и вовремя убежать.",
		"Разведка доложила: впереди очень много зомби. Разведка не вернулась.",
		"Вчера нашёл в кармане конфету. Это был лучший день в моей жизни.",
		"Бить прикладом — не по уставу. Но зомби об уставе не знают.",
		"Рация молчит уже сутки. Или все спят, или нас забыли.",
		"Сержант сказал, что я похож на героя. Потом добавил: «издалека».",
		"Береги базу, боец. Тут тепло, сухо и почти не едят.",
		"Если упадёшь, не волнуйся: товарищ поднимет. Если успеет.",
		"Мне бы отпуск на море. Хотя бы на лужу после дождя.",
	},
}

-- Тексты генерала Нурсултана по типам миссий ({points}, {radius}, {kills}, {seconds}, {hold} подставляются из Config.Missions и Config.Convoy)
Config.Briefs = {
	scout = {
		"Нужна разведка. Вокруг места будущего шатра отмечены контрольные точки — {points} синих кругов света в {radius} шагах от него.",
		"Обойдите их все. Мутанты пойдут со всех сторон без остановки: не стойте на месте и держитесь вместе.",
	},
	build = {
		"Здесь встанет наш шатёр. Сначала зачистите зону: убейте {kills} мутантов.",
		"Затем встаньте на золотую метку и удерживайте E {hold} секунд — шатёр установится. Он даст нам магазин, автомат и плацдарм в районе.",
	},
	escort = {
		"Конвой с припасами. Грузовик выедет от точки сбора, объедет контрольные точки района и остановится на дороге у места шатра.",
		"Едет он только пока рядом с ним (в {follow} шагах) есть кто-то из вас: ушли далеко — колонна встанет и будет ждать.",
		"С ним идут двое моих бойцов: по 150 здоровья, стреляют несильно — основная работа на вас. Мутанты нападают и на них, и на грузовик (1000 прочности) — прикрывайте.",
		"Потеряем грузовик — задание провалено.",
	},
	defend = {
		"Мутанты идут на шатёр. Держите оборону {seconds} секунд рядом с ним — не уходите далеко, отсчёт идёт, только пока вы рядом.",
	},
	clear = {
		"Зачистите зону: уничтожьте всех мутантов этой ночи. Берегите патроны, поднимайте упавших.",
	},
	metro = {
		"Под городом заброшенная станция метро — там гнёзда мутантов. Вход у лестницы, вот на этой отметке на карте.",
		"Спуститесь по лестнице: внизу вас перенесёт на станцию. Зачистите её: убейте {kills} мутантов. Они лезут из тоннелей со всех сторон — держитесь платформ и укрытий.",
		"Когда зачистим, вернётесь на базу.",
	},
	bossfight = {
		"Финал, боец. Это не ночь: босс выходит днём, обычных мутантов не будет — только он.",
		"Держитесь вместе, не стойте на месте: у него хватает приёмов, а кувырок спасает от большинства. Победим его — и город наш.",
	},
	classic = {
		"Уничтожьте всех мутантов этой ночи. Магазин на ночь закрыт — берегите патроны, поднимайте упавших.",
	},
} :: { [string]: { string } }
-- Оповещение днём о ближайшей ночи (GeneralService.announceDay → атрибуты NextBrief*, клиент DayBriefController): панель, строки в чате и напоминание.
-- {points} {kills} {seconds} {follow} подставляются из Config.Missions и Config.Convoy (как в Config.Briefs)
Config.DayBrief = {
	ShowSeconds = 9, -- сколько панель висит в начале дня
	RemindBefore = 30, -- за сколько секунд до ночи напоминаем
	RemindSeconds = 6, -- сколько держится напоминание
	Task = {
		scout = "Разведка: обойти {points} контрольные точки вокруг места шатра",
		build = "Зачистить зону ({kills} убийств) и поставить шатёр: удерживать E на золотой метке",
		escort = "Конвой: довезти грузовик с припасами до места шатра",
		defend = "Оборона шатра: продержаться {seconds} секунд рядом с ним",
		clear = "Зачистка: убить всех мутантов ночи",
		metro = "Метро: спуститься по лестнице и зачистить станцию ({kills} убийств)",
		classic = "Убить всех мутантов ночи",
		bossfight = "Финал: босс-файт — убить финального босса",
	},
	Tip = {
		scout = "Мутанты идут со всех сторон без остановки — держитесь вместе.",
		build = "Пока шатёр не стоит, магазина в районе нет — защищайте золотую метку.",
		escort = "Конвой стартует от места появления игроков (спавна) и едет, только пока рядом кто-то из вас (в {follow} шагах). Соберитесь у спавна заранее и прикрывайте грузовик!",
		defend = "Отсчёт идёт, только пока вы рядом с шатром.",
		clear = "Магазин на ночь закрыт — купите всё днём.",
		metro = "Внизу тесно и темно: держитесь платформ и укрытий, берите побольше патронов.",
		classic = "Магазин на ночь закрыт — купите всё днём и поднимайте упавших.",
		bossfight = "Бой днём и без обычных зомби: только босс. Запаситесь патронами и аптечками, держитесь вместе.",
	},
	Boss = "Ночью придёт босс: {name}.",
	Here = "на базе",
} :: { ShowSeconds: number, RemindBefore: number, RemindSeconds: number, Task: { [string]: string }, Tip: { [string]: string }, Boss: string, Here: string }
Config.AmbienceVolume = 0.7 -- общая громкость звуков окружения (зомби, машины); по слуху держим тихо
Config.DebugStartNight = 1 -- для проверок: с какой ночи начинается раунд (в релизе всегда 1)
Config.MissionMoveTeam = false -- true: в начале ночи команду переносит к точке миссии (по решению Руслана 2026-10-24 — выключено: идут сами)
-- Минимум убийств игроков на любой ночи для засчёта миссии: линейно от Solo (1 игрок) до Full (FullPlayers игроков, по числу в начале ночи);
-- с Config.Waves.CountScale масштабируется как убийства метро (не меньше 5)
Config.MissionMinKills = { Solo = 15, Full = 30, FullPlayers = 6 }
Config.MissionKillsFloor = 3 -- ТЕСТ: нижняя граница убийств после масштаба CountScale (минимум убийств, зачистка шатра, метро); в релизе удалить (было 5)
Config.MissionReturnTeam = false -- true: с рассветом команду переносит к магазину (по решению Руслана 2026-10-26 — выключено: не телепортировать на рассвете)
-- Военная база (Workspace.Base: стены x −159…107, ворота у z = 300, дальняя стена z ≈ 580): с началом ночи всех, кто внутри, выталкивает к точке сбора
-- игроков (BuildingService.expelFromBase, по образцу магазина). locationId — локация, для которой верны границы; maxY — выше (вышки, вертолёты) не считаем
Config.BaseZone = { locationId = "Custom", minX = -161, maxX = 109, minZ = 300, maxZ = 580, maxY = 60 }
-- Метки миссий (MissionService.makeBeacon): светящийся полупрозрачный круг на земле + метка в HUD с расстоянием (столбы убраны по просьбе Руслана 2026-10-26).
-- ScoutPointRadius — радиус круга контрольной точки = радиус засчитывания; PlaceBeacon — круг места миссии (подпись зависит от типа миссии)
Config.ScoutPointRadius = 10
Config.ScoutPointColor = Color3.fromRGB(80, 200, 255)
-- Обломки на месте шатра при провале конвоя (MissionService.buildRubble): число деталей по видам и радиус разброса, студы
Config.Rubble = { Radius = 14, Chunks = 34, Crates = 6, Planks = 12, Barrels = 4, Tires = 5, Cloth = 6 }
-- Надписи над метками миссий (BillboardGui): мелкие и полупрозрачные, чтобы не закрывали обзор (по просьбе Руслана 2026-10-28 — в 10 раз меньше по площади,
-- было 200×44 и 240×40 пикселей, дальность 2000 и 1500 студов); дальше MaxDistance надпись не рисуется
Config.MissionLabel = { Width = 70, Height = 13, MaxDistance = 450, TextTransparency = 0.5, StrokeTransparency = 0.85 }
Config.PlaceBeacon = { Radius = 16, Color = Color3.fromRGB(255, 200, 60) }
-- Ночь 19, «бойня на базе» (BaseBattleService, MissionService.begin): Total зомби одним потоком (одновременно не больше AliveCap) со стороны базы (точки
-- SpawnPoints внутри Config.BaseZone), баррикады на базе на эту ночь убраны; треть солдат базы лежит убитыми (DeadFraction); у точки появления игроков
-- Defenders живых солдат (HP из DefenderHp, урон DefenderDps, шаг DefenderInterval, дальность DefenderRange) — зомби их атакуют и могут убить;
-- по базе Debris.Clusters куч мусора (Wrecks из них — с остовами машин).
Config.BaseBattle = {
	Total = 200, AliveCap = 45, SpawnPoints = 14, DeadFraction = 1 / 3,
	Defenders = 10, DefenderHp = { 200, 250 }, DefenderDps = 30, DefenderInterval = 0.4, DefenderRange = 55, PostRadius = 14,
	Debris = { Clusters = 16, Radius = 11, Chunks = 16, Crates = 3, Planks = 6, Barrels = 2, Tires = 2, Cloth = 3, Wrecks = 3 },
}
-- Финал акта 1 (RoundService.day(finale), MissionService.beginFinale): после убийства финального босса начинается день 20 с миссией «зайти в бункер»
-- (Workspace.Bunker.BunkerEntrance); когда все живые игроки в Radius студов от входа — всем окно поздравления, через EndSeconds раунд заканчивается
Config.Finale = {
	Radius = 22, EndSeconds = 25,
	Title = "Акт 1 пройден!",
	Lines = {
		"Вы дошли до бункера и победили Стража. Первый акт закончен: город держится, база цела, а за бронёй бункера — новые вопросы.",
		"Второй акт — в разработке. Спасибо, что играли: ждите продолжения!",
	},
}
-- Метро (ночь 18, MissionService): внизу нужно сжечь гнёзда мутантов (маркеры Workspace.Metro.Markers.Metro_Objective_1…n, удержание E NestHold секунд),
-- затем выходит босс станции (Missions[18].boss, у маркера Metro_Boss), после его смерти и набранных убийств миссия выполнена. Звуки — тихие зацикленные
-- (id проверены 2026-10-29: загружаются, длины 1,3–77 с); играют на клиенте, пока игрок ниже InsideMaxY (станция и пещера лежат под картой, пол y ≈ -400)
-- Выход из метро (решение Руслана 2026-10-29): 5 груд костей по станции (удержание E BoneHold с) → костяной ключ → костяная дверь у маркера Metro_Exit
-- (открывается, когда есть ключ, сожжены гнёзда и убит босс) → вся команда оказывается в тоннеле в горе («The Hub Map (For Apeirophobia)», Hub.spawn) — миссия
-- выполнена. Груды стоят в точках BoneSpots (x, z, y старта луча вниз до пола; мировые координаты метро), пол ищется лучом по Workspace.Metro и Terrain.
-- Пещера за станцией B (Terrain, 2026-10-29): кишка → большой зал → верхний уровень с костяной дверью (маркер Metro_Exit). Первый, кто входит в зал
-- (Metro_CaveRoom, CaveRadius), запускает «последний рубеж»: зомби идут из пещерных маркеров, нужно CaveKills убийств, только потом открывается дверь.
-- Освещение: в метро клиент приглушает Lighting (Dark.station) и в пещере темнее (Dark.cave, x > Cave.minX и z > Cave.minZ), включается фонарик у камеры.
-- Hub.halfWidth — по x от Hub.spawn «зона тоннеля»: оттуда команду на рассвете возвращает на базу.
Config.Metro = {
	NestHold = 6,
	Bones = 5,
	BoneHold = 2,
	BoneSpots = {
		{ -130, 50, -390 }, { 130, -55, -390 }, { -100, -62, -393 }, { 100, 90, -390 }, { 892, 140, -385 },
	},
	Hub = { spawn = Vector3.new(-800, 4, -87), halfWidth = 230 },
	InsideMaxY = -200,
	CaveKills = 20,
	CaveRadius = 60,
	Cave = { minX = 640, minZ = 22 },
	Dark = {
		station = { Brightness = 0, Ambient = Color3.fromRGB(34, 36, 48), OutdoorAmbient = Color3.fromRGB(34, 36, 48), ExposureCompensation = -0.35, EnvironmentDiffuseScale = 0, EnvironmentSpecularScale = 0 },
		cave = { Brightness = 0, Ambient = Color3.fromRGB(7, 7, 11), OutdoorAmbient = Color3.fromRGB(7, 7, 11), ExposureCompensation = -0.6, EnvironmentDiffuseScale = 0, EnvironmentSpecularScale = 0 },
	},
	Flashlight = { Range = 70, Angle = 75, Brightness = 3.2, Color = Color3.fromRGB(255, 244, 220) },
	Sounds = {
		{ name = "tunnel ambience", id = "rbxassetid://9118773471", volume = 0.18 },
		{ name = "underground hum", id = "rbxassetid://9112795571", volume = 0.14 },
		{ name = "water drip", id = "rbxassetid://9112903083", volume = 0.12 },
		{ name = "metal creak", id = "rbxassetid://9116552386", volume = 0.1 },
		{ name = "train rumble", id = "rbxassetid://6761165534", volume = 0.1 },
		{ name = "light buzz", id = "rbxassetid://9112823813", volume = 0.08 },
	},
}
Config.Missions = {
	[1] = { type = "scout", title = "Разведка района", anchor = 1, points = 3, hint = "Обойдите контрольные точки вокруг шатра" },
	[2] = { type = "build", title = "Зачистка зоны и установка шатра", anchor = 1, kills = 15, hint = "Зачистите зону и установите шатёр на отмеченном месте" },
	-- Первый конвой: выезжает из начальной зоны (мешки с песком на эту ночь убираются), едет не быстро (6,5 студа/с — маршрут ~600 студов за ~90 с, решение Руслана 2026-10-26; было 3,5;
	-- Config.Convoy.TruckSpeed = 9,5 — тестовая, на неё ночи 8, 12, 17 не меняем) и только пока рядом игрок
	[3] = { type = "escort", title = "Сопровождение конвоя с припасами", anchor = 1, points = 3, convoySpeed = 6.5, clearSandbags = true, hint = "Не дайте уничтожить грузовик: он объедет контрольные точки и встанет у шатра" },
	[4] = { type = "scout", title = "Разведка ближайших зданий", anchor = 1, points = 4, radius = { 100, 200 }, hint = "Обойдите контрольные точки" },
	[5] = { type = "classic", title = "Защита шатра от босса", anchor = 1, planned = "defend-boss", hint = "Убейте босса и волну" },
	[6] = { type = "scout", title = "Разведка второго района", anchor = 2, points = 3, hint = "Обойдите контрольные точки вокруг шатра" },
	[7] = { type = "build", title = "Зачистка и установка шатра", anchor = 2, kills = 20, hint = "Зачистите зону и установите шатёр на отмеченном месте" },
	[8] = { type = "escort", title = "Сопровождение конвоя", anchor = 2, points = 3, hint = "Не дайте уничтожить грузовик" },
	[9] = { type = "scout", title = "Разведка территории третьего шатра", anchor = 3, points = 4 },
	[10] = { type = "classic", title = "Босс: зомби против растений", anchor = 2, planned = "boss", hint = "Убейте босса и волну" },
	[11] = { type = "scout", title = "Изучение локаций вокруг шатров", anchor = 2, points = 5 },
	[12] = { type = "escort", title = "Конвой до третьего шатра", anchor = 3, points = 3, install = true, hint = "Доведите грузовик и установите шатёр у места" },
	[13] = { type = "defend", title = "Аномалии и нападения на магазины", anchor = 1, seconds = 150, planned = "anomaly" },
	[14] = { type = "defend", title = "Нападение на все шатры", anchor = 2, seconds = 200, planned = "multi-defend" },
	[15] = { type = "classic", title = "Босс нападает на основную базу", anchor = 1, planned = "boss", hint = "Убейте босса и волну" },
	[16] = { type = "scout", title = "Разведка территории", anchor = 4, points = 4, planned = "daytime" },
	[17] = { type = "escort", title = "Установка шатра и конвой", anchor = 4, points = 3, install = true, hint = "Доведите грузовик и установите шатёр у места" },
	[18] = { type = "metro", title = "Катакомбы: зачистка метро", anchor = 6, kills = 40, nests = 3, boss = "BossBuff", hint = "Спуститесь по лестнице у входа в метро, сожгите гнёзда (E) и убейте босса станции" },
	[19] = { type = "clear", title = "Военная база: зачистка и захват", anchor = 5, baseBattle = true, hint = "Отбейте базу: мутанты идут со стороны базы, солдаты у точки сбора помогают" },
	-- Финал (каркас, 2026-10-28): босс-файт ДНЁМ без обычных зомби — свет и небо дневные (day), выходит только босс из bosses (по очереди; кто финальный босс — решает Руслан,
	-- пока Повелитель тёмных); победа — убит последний босс (RoundService: атрибут Victory и сообщение; титры и награда — после решения Руслана)
	[20] = { type = "bossfight", title = "Финал: босс-файт", anchor = 5, day = true, bosses = { "BossFinal" }, hint = "Днём, без зомби: убейте финального босса" },
} :: { [number]: MissionDef }

-- Рейтинговые очки (не монеты): копятся за раунд, идут в профиль и в глобальный лидерборд (RatingService)
Config.Rating = {
	Kill = 5,
	HeadshotKill = 5, -- добавка за убийство выстрелом в голову
	BossKill = 100,
	BuildingOpened = 50, -- тому, кто внёс последний взнос
	NightSurvived = 30, -- × номер волны, каждому, кто дожил до конца ночи
	ClearBonus = 20, -- × номер волны × (1 − доля ночи, которая ушла на зачистку): быстрая зачистка
}

-- НПС-продавцы в зданиях (VendorService): появляются только днём в открытом за монеты здании.
-- kind: "item" — расходник (ItemService), "weapon" — оружие из Config.Weapons, "equip" — оборудование (EquipmentService), "life" — жизнь команды.
export type VendorItem = { id: string, name: string, desc: string, price: number, kind: string, robux: number? } -- robux: цена за донат (позже), пока не используется
export type VendorDef = { name: string, greeting: string, items: { VendorItem } }
local function weaponItems(ids: { string }): { VendorItem }
	local list: { VendorItem } = {}
	for _, id in ids do
		local d = Weapons[id]
		if d then
			table.insert(list, { id = id, name = d.name, desc = string.format("Урон %d · %.1f уд/с", d.damage, d.fireRate), price = d.price, kind = "weapon" })
		end
	end
	return list
end
Config.Vendors = {
	-- Вендинговые автоматы (маркеры Vending_<n>: кафе, военная база, палатки): работают днём и ночью, не зависят от зданий.
	-- kind "ammo" — патроны к оружию в руках. Монеты общие, как везде; донатные цены (robux) добавим вместе с магазином за робуксы.
	Vending = {
		name = "Автомат", greeting = "Работает от резервного питания. Сдачи нет.",
		items = {
			{ id = "Medkit", name = "Аптечка", desc = "+60 здоровья", price = 150, kind = "item", robux = 25 },
			{ id = "EnergyDrink", name = "Энергетик", desc = "бесконечная энергия на 1 волну", price = 100, kind = "item", robux = 20 },
			{ id = "Ammo", name = "Патроны", desc = "полный запас к оружию в руках", price = 150, kind = "ammo", robux = 15 },
		},
	},
	Pharmacy = {
		name = "Аптекарь", greeting = "Мутанты боятся солнца — а мы боимся ночи. Берите, пока светло.",
		items = {
			{ id = "Medkit", name = "Аптечка", desc = "+60 здоровья", price = 150, kind = "item" },
			{ id = "EnergyDrink", name = "Энергетик", desc = "бесконечная энергия спринта на 1 волну", price = 100, kind = "item" },
		},
	},
	Armory = {
		name = "Оружейник", greeting = "Холодное оружие не кончается, как патроны.",
		items = weaponItems({ "Bat", "Crowbar", "Machete", "FireAxe", "Sledge", "Katana" }),
	},
	Garage = {
		name = "Механик", greeting = "Проволока держит их у стены. Ставь с умом.",
		items = {
			{ id = "BarbedWire", name = "Колючая проволока", desc = "Ранит и держит мутантов, пока не порвётся", price = 250, kind = "equip" },
			{ id = "ElectricWire", name = "Электро-проволока", desc = "Бьёт током и оглушает; до рассвета", price = 600, kind = "equip" },
		},
	},
	GunShop = {
		name = "Торговец турелями", greeting = "Пулемёт сам не устанет. Пока есть патроны.",
		items = {
			{ id = "Turret", name = "Турель", desc = "50 урона раз в 2–4 с, 300 выстрелов", price = 1500, kind = "equip" },
		},
	},
	Shelter = {
		name = "Смотритель", greeting = "Каждая жизнь на счету.",
		items = {
			{ id = "TeamLife", name = "Жизнь команды", desc = "Если все упадут, команда поднимется", price = 2500, kind = "life" },
		},
	},
} :: { [string]: VendorDef }

-- Встроенный пулемёт машины с турелью (VehicleService): сидящий на месте 0 наводит его камерой и стреляет зажатой кнопкой мыши
Config.TurretGun = {
	damage = 30, -- по зомби; голова ×HeadshotMultiplier
	rate = 10, -- выстрелов в секунду
	spreadDeg = 1.3,
	range = 350,
	mag = 100, -- в магазине
	reserve = 150, -- запас (всего 250)
	reload = 3.5,
	yawRate = 4.5, -- рад/с поворот ствола
	minPitch = -8, -- градусов
	maxPitch = 60,
	recoil = 0.35, -- откат ствола, студов (в родном масштабе)
}

-- Оборудование (EquipmentService): покупается у продавцов, ставится кликом на землю
Config.Equipment = {
	BarbedWire = { name = "Колючая проволока", damage = 8, tick = 0.5, hits = 60, max = 6, size = Vector3.new(10, 1.4, 2.5), reach = 22 },
	ElectricWire = { name = "Электро-проволока", damage = 25, tick = 2, stun = 2.5, max = 4, size = Vector3.new(10, 0.6, 2.5), reach = 22 },
	Turret = { name = "Турель", damage = 50, minCooldown = 2, maxCooldown = 4, range = 90, ammo = 300, max = 2, length = 3.4, reach = 22 },
}

return Config
