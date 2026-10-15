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
	FirstDayTime = 15,
	DayTime = 25,
	GameOverTime = 8,
	MaxZombiesAlive = 60,
	SpawnsPerTick = 2,
	SpawnTick = 0.25,
	AiTick = 0.2, -- как часто зомби пересчитывают цель
}

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
