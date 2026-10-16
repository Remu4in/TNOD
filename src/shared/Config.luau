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
	range: number,
	color: Color3,
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

export type ZombieDef = {
	id: string,
	name: string,
	hp: number,
	speed: number,
	damage: number,
	attackCooldown: number,
	reward: number,
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
	DownedWalkSpeed = 4,
	BleedOutTime = 30,
	ReviveHoldTime = 3,
	ReviveHealth = 50,
	StartCoins = 500,
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
}

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
}

local WeaponSounds: { [string]: WeaponSound } = {
	Pistol = { fireVolume = 0.8, firePitch = 1.0, fireTrim = 0.9, reloadVolume = 0.8, reloadPitch = 1.0 },
	SMG = { fireVolume = 0.55, firePitch = 1.35, fireTrim = 0.3, reloadVolume = 0.8, reloadPitch = 1.15 },
	Shotgun = { fireVolume = 1.0, firePitch = 0.65, fireTrim = 1.1, reloadVolume = 0.9, reloadPitch = 0.8 },
	Rifle = { fireVolume = 0.8, firePitch = 0.85, fireTrim = 0.5, reloadVolume = 0.9, reloadPitch = 0.9 },
}
Config.WeaponSounds = WeaponSounds

-- Порядок стен с оружием на карте
Config.WallBuys = { "SMG", "Shotgun", "Rifle", "SMG" }

local Zombies: { [string]: ZombieDef } = {
	Walker = {
		id = "Walker", name = "Ходок", hp = 60, speed = 8, damage = 15, attackCooldown = 1,
		reward = 50, scale = 1, color = Color3.fromRGB(95, 140, 80), planksPerHit = 1,
	},
	Runner = {
		id = "Runner", name = "Бегун", hp = 40, speed = 15, damage = 10, attackCooldown = 0.8,
		reward = 60, scale = 0.9, color = Color3.fromRGB(150, 160, 70), planksPerHit = 1,
	},
	Brute = {
		id = "Brute", name = "Громила", hp = 600, speed = 7, damage = 35, attackCooldown = 1.5,
		reward = 400, scale = 1.8, color = Color3.fromRGB(110, 50, 50), planksPerHit = 5,
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
