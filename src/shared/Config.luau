--!strict
-- Все числа баланса и настройки игры в одном месте.
-- Меняем здесь, а не в коде систем. Правки баланса — через агента balance-analyst.

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

export type ZombieDef = {
	id: string,
	name: string,
	hp: number,
	speed: number,
	damage: number,
	attackCooldown: number,
	reward: number, -- монеты убийце
	points: number, -- очки убийце (и в общий командный счёт)
	scale: number,
	color: Color3,
	planksPerHit: number,
}

local Config = {}

Config.Round = {
	IntermissionTime = 15,
	FirstDayTime = 60, -- время на закупку и расход по точкам обороны
	DayTime = 60,
	DayWarnSeconds = 10, -- за сколько секунд до ночи предупреждаем, что баррикады закроются
	GameOverTime = 8,
	MaxZombiesAlive = 60,
	SpawnsPerTick = 2,
	SpawnTick = 0.25,
	AiTick = 0.2, -- как часто зомби пересчитывают цель
}

-- Локации идут по порядку; смена каждые LocationNights ночей (= 2 босса при BossEvery = 5).
Config.Locations = {
	{ id = "City", name = "Городской квартал" },
	{ id = "Police", name = "Полицейский участок" },
}
Config.LocationNights = 10

Config.Player = {
	MaxHealth = 100,
	RegenDelay = 5,
	RegenPerSecond = 8,
	-- Движение: зомби быстрее ходьбы (Ходок 14 > 13), но спринт за энергию их обгоняет
	WalkSpeed = 13,
	SprintSpeed = 21,
	DownedWalkSpeed = 4,
	-- Энергия: 5 с непрерывного спринта тратят всю, полностью восстанавливается за 30 с
	EnergyMax = 100,
	SprintSeconds = 5, -- было 10: спринт в 2 раза короче (запрос Руслана 2026-10-16)
	EnergyRegenSeconds = 30,
	EnergyRegenDelay = 1, -- пауза после спринта перед восстановлением
	SprintMinEnergy = 15, -- с меньшей энергией спринт не начать
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
	{ id = "Pharmacy", name = "Медпункт", cost = 500, bonus = "medkits", info = "Аптечки и энергетики" },
	{ id = "ColdStore", name = "Склад холодного оружия", cost = 1000, bonus = "melee", info = "Холодное оружие бесплатно" },
	{ id = "Garage", name = "Склад проволоки", cost = 2000, bonus = "wire", info = "Колючая и электро-проволока (скоро)" },
	{ id = "Armory", name = "Оружейная", cost = 3000, bonus = "turret", info = "Турель (скоро)" },
	{ id = "Shelter", name = "Убежище", cost = 4000, bonus = "teamLife", info = "Дополнительная жизнь команды" },
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
	EnergyDrink = { name = "Энергетик", energy = 70, color = Color3.fromRGB(60, 190, 255) },
}
Config.Items = Items

-- Очки: личные (таблица игроков) и в общий командный счёт (потом — на открытие зданий)
Config.Score = {
	Repair = 2, -- за доску, выбитую зомби
	Revive = 50, -- за поднятие товарища
}

Config.Economy = {
	CoinsPerHit = 10,
	CoinsPerPlankRepair = 10,
	MaxRepairCoinsPerDay = 200,
	HeadshotMultiplier = 1.5,
	RefillPriceFactor = 0.5,
}

Config.Barricade = {
	Planks = 5,
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
		damage = 14, pellets = 1, spreadDeg = 3, fireRate = 10, automatic = true,
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
		damage = 22, pellets = 1, spreadDeg = 4, fireRate = 11, automatic = true,
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
	SMG = {
		{
			mesh = "rbxassetid://128177867774908", texture = "rbxassetid://110408941174746",
			size = Vector3.new(0.218, 0.9, 1.725), offset = CFrame.new(0, 0.22, -0.4),
		},
	},
	Shotgun = {
		{
			mesh = "rbxassetid://114620737768018", texture = "rbxassetid://94497357292282",
			size = Vector3.new(0.189, 0.72, 1.889), offset = CFrame.new(0, 0.14, -0.7),
		},
	},
	Rifle = {
		{
			mesh = "rbxassetid://100306694258708", texture = "rbxassetid://91475282685455",
			size = Vector3.new(0.257, 0.935, 2.071), offset = CFrame.new(0, 0.2, -0.75),
		},
	},
	-- Сгенерированы в Studio (generate_mesh, 2026-10-16, этап 1). Нож и мачете пришли «стоя» — повёрнуты в offset
	Revolver = {
		{
			mesh = "rbxassetid://94099447863607", texture = "rbxassetid://110820817042114",
			size = Vector3.new(0.322, 1.12, 1.316), offset = CFrame.new(0, 0.4, -0.35),
		},
	},
	LMG = {
		{
			mesh = "rbxassetid://91186817484981", texture = "rbxassetid://70401107133536",
			size = Vector3.new(0.32, 1.27, 2.7), offset = CFrame.new(0, 0.25, -1.05),
		},
	},
	Sniper = {
		{
			mesh = "rbxassetid://74974681462741", texture = "rbxassetid://113329805495926",
			size = Vector3.new(0.46, 1.17, 3.13), offset = CFrame.new(0, 0.3, -1.35),
		},
	},
	Bat = {
		{
			mesh = "rbxassetid://98332557332517", texture = "rbxassetid://126428980485328",
			size = Vector3.new(0.35, 0.346, 2.721), offset = CFrame.new(0, 0, -1.0),
		},
	},
	Knife = {
		{
			mesh = "rbxassetid://72884341636124", texture = "rbxassetid://118523366975863",
			size = Vector3.new(1.12, 1.165, 1.064),
			offset = CFrame.new(0, 0.05, -0.55) * CFrame.Angles(0, math.rad(-33.5), 0) * CFrame.Angles(math.rad(90), 0, 0),
		},
	},
	Machete = {
		{
			mesh = "rbxassetid://112017706644243", texture = "rbxassetid://90489625632426",
			size = Vector3.new(1.7, 1.86, 1.125),
			offset = CFrame.new(0, 0.05, -0.9) * CFrame.Angles(0, math.rad(33), 0) * CFrame.Angles(math.rad(-90), 0, 0),
		},
	},
}
Config.WeaponVisuals = Visuals

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

-- Взмах ближнего боя: стиль анимации, длительность (сек.) и сила тряски камеры при попадании
local MeleeFx: { [string]: MeleeFxDef } = {
	Knife = { style = "stab", time = 0.26, shake = 1.6 },
	Bat = { style = "smash", time = 0.42, shake = 3.2 },
	Machete = { style = "slash", time = 0.34, shake = 2.4 },
}
Config.MeleeFx = MeleeFx

-- Порядок стен с оружием в магазине (8 мест, см. BuildKit.shop)
Config.WallBuys = { "Bat", "Machete", "Revolver", "SMG", "Shotgun", "Rifle", "LMG", "Sniper" }

local Zombies: { [string]: ZombieDef } = {
	Walker = {
		id = "Walker", name = "Ходок", hp = 60, speed = 14, damage = 15, attackCooldown = 1,
		reward = 50, points = 10, scale = 1, color = Color3.fromRGB(95, 140, 80), planksPerHit = 1,
	},
	Runner = {
		id = "Runner", name = "Бегун", hp = 40, speed = 19, damage = 10, attackCooldown = 0.8,
		reward = 60, points = 15, scale = 0.9, color = Color3.fromRGB(150, 160, 70), planksPerHit = 1,
	},
	Brute = {
		id = "Brute", name = "Громила", hp = 600, speed = 12, damage = 35, attackCooldown = 1.5,
		reward = 400, points = 100, scale = 1.8, color = Color3.fromRGB(110, 50, 50), planksPerHit = 5,
	},
}

Config.Zombies = Zombies

Config.Waves = {
	BaseCount = 6,
	CountPerWave = 3,
	PlayerCountFactor = 0.5,
	HpGrowthPerWave = 0.15,
	RunnersFromWave = 3,
	RunnerShareMax = 0.4,
	RunnerShareGrowth = 0.08,
	BossEvery = 5,
}

return Config
