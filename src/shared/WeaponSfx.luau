--!strict
-- Звуки оружия на клиенте (официальные звуки Roblox, тон/громкость — из Config.WeaponSounds).
-- position = nil — звук «в голове» (свои выстрелы), иначе объёмный звук в точке мира.

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Config = require(script.Parent:WaitForChild("Config"))

local WeaponSfx = {}

local lastClick = 0

local function emit(id: string, volume: number, pitch: number, position: Vector3?, trim: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	sound.PlaybackSpeed = pitch
	local holder: Instance
	if position then
		local att = Instance.new("Attachment")
		att.WorldPosition = position
		att.Parent = workspace.Terrain
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = 12
		sound.RollOffMaxDistance = 220
		holder = att
	else
		holder = SoundService
	end
	sound.Parent = holder
	sound:Play()
	if trim then
		-- скорострельное оружие: обрезаем хвост выстрела, чтобы очередь не сливалась в кашу
		task.delay(trim, function()
			if sound.Parent then
				TweenService:Create(sound, TweenInfo.new(0.08), { Volume = 0 }):Play()
			end
		end)
		Debris:AddItem(holder == SoundService and sound or holder, trim + 0.12)
	else
		Debris:AddItem(holder == SoundService and sound or holder, 3)
	end
end

function WeaponSfx.fire(weaponId: string, position: Vector3?)
	local s = Config.WeaponSounds[weaponId]
	if s then
		-- лёгкий случайный разброс тона: очередь не звучит как один и тот же клип
		emit(Config.Sounds.fire, s.fireVolume, s.firePitch * (0.94 + math.random() * 0.12), position, s.fireTrim)
	end
end

function WeaponSfx.reload(weaponId: string, position: Vector3?)
	local s = Config.WeaponSounds[weaponId]
	if s then
		emit(Config.Sounds.reload, s.reloadVolume, s.reloadPitch, position, nil)
	end
end

-- Взмах оружием ближнего боя (position = nil — свой взмах)
function WeaponSfx.swing(position: Vector3?)
	emit(Config.Sounds.swing, 0.6, 1.0, position, 0.5)
end

-- Попадание по зомби: выше тон при хедшоте, тише при обычном
function WeaponSfx.hit(headshot: boolean, killed: boolean)
	emit(Config.Sounds.hit, if killed then 0.7 else 0.45, if headshot then 1.5 else 0.85, nil, 0.3)
end

-- «Пинг» пули о поверхность в точке попадания
function WeaponSfx.ping(position: Vector3)
	emit(Config.Sounds.hit, 0.22, 1.9 + math.random() * 0.3, position, 0.25)
end

-- Сухой щелчок при пустом магазине (не чаще раза в 0,35 с)
function WeaponSfx.click()
	local now = os.clock()
	if now - lastClick < 0.35 then
		return
	end
	lastClick = now
	emit(Config.Sounds.click, 0.5, 2.2, nil, 0.2)
end

-- Предзагрузка звуков и мешей/текстур оружия, чтобы при первой покупке ствол не появлялся с задержкой
function WeaponSfx.preload()
	-- временные объекты нужного типа: строки без типа ContentProvider считает картинками и ругается в консоль
	local list: { Instance } = {}
	for _, id in Config.Sounds do
		local s = Instance.new("Sound")
		s.SoundId = id
		table.insert(list, s)
	end
	for _, parts in Config.WeaponVisuals do
		for _, vp in parts do
			local m = Instance.new("SpecialMesh")
			m.MeshId = vp.mesh
			m.TextureId = vp.texture or ""
			table.insert(list, m)
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
		for _, obj in list do
			obj:Destroy()
		end
	end)
end

return WeaponSfx
