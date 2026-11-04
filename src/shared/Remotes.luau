--!strict
-- Сетевые события. Сервер создаёт, клиент ждёт.
-- Состояние раунда передаётся атрибутами (ReplicatedStorage и Player), события — только для действий.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMES = {
	"Fire", -- клиент → сервер: (origin: Vector3, direction: Vector3, ads: boolean) — ads: целится ли игрок (влияет на разброс)
	"Reload", -- клиент → сервер: ()
	"Melee", -- клиент → сервер: (direction: Vector3) — взмах оружием ближнего боя
	"Sprint", -- клиент → сервер: (on: boolean) — хочу спринтовать (энергию считает сервер)
	"Dodge", -- клиент → сервер: (kind: "slide" | "roll") — подкат или кувырок (энергию, паузу и неуязвимость считает сервер)
	"MeleeFx", -- сервер → всем: (attacker: Player, weaponId: string, comboIndex: number) — звук и анимация взмаха, номер удара серии
	"HitFeedback", -- сервер → стрелку: (position: Vector3, damage: number, killed: boolean, headshot: boolean)
	"ShotFx", -- сервер → всем: (shooter: Player, origin: Vector3, hits: {Vector3}, weaponId: string)
	"ReloadFx", -- сервер → всем: (player: Player, weaponId: string) — звук перезарядки
	"BuyWeapon", -- клиент → сервер: (weaponId: string) — купить/взять оружие из меню (в режиме осмотра бесплатно)
	"ShopOpen", -- сервер → клиенту: () — меню оружия (палатка) или { vendorId, title, greeting, items } — меню НПС-продавца
	"DropWeapon", -- клиент → сервер: () — выбросить оружие из рук (G); подбор — ProximityPrompt (E) на выброшенном оружии
	"SwitchSeat", -- клиент → сервер: (index: number) — пересесть в машине на место index (1 водитель, 2–4 пассажиры, 0 турель)
	"TentMarkers", -- сервер → клиенту: ({ { pos: Vector3, name: string } }) — метки на военные палатки поблизости (пусто — снять)
	"VoteDay", -- клиент → сервер: () — поставить/снять голос «завершить день» (все проголосовали — наступает ночь)
	"VendorBuy", -- клиент → сервер: (vendorId: string, itemId: string) — купить у НПС-продавца (цену и условия проверяет сервер)
	"PlaceEquipment", -- клиент → сервер: (position: Vector3, yaw: number?) — поставить оборудование из рук (турель, проволока) в точку на земле; yaw — поворот вокруг вертикали, радианы
	"TurretAim", -- клиент → сервер: (direction: Vector3) — куда стрелок наводит пулемёт машины (направление камеры)
	"TurretFire", -- клиент → сервер: () — очередь пулемёта (пока зажата кнопка; темп и патроны считает сервер)
	"TurretReload", -- клиент → сервер: () — перезарядка пулемёта машины
	"PerkOffer", -- сервер → игроку: (offerId: number, options: { { id, name, desc, stacks, max } }, seconds: number) — выбрать перк команды
	"PerkChoose", -- клиент → сервер: (offerId: number, index: number) — выбранный перк из предложенных (1–3)
	"GiveUp", -- клиент → сервер: () — упавший сдаётся (сразу погибает, не дожидаясь, пока истечёт кровью)
	"Briefing", -- сервер → игроку: (имя: string, заголовок: string, строки: { string }) — окно задания от генерала
	"TestPickWave", -- сервер → клиенту (только Studio, тестовый стенд): (maxNight: number) — открыть окно выбора ночи
	"TestSetWave", -- клиент → сервер (только Studio, тестовый стенд): (night: number) — следующей будет эта ночь (сервер проверяет тип, диапазон, частоту, дистанцию)
	"LobbyCmd", -- клиент → сервер (лобби): (cmd: string, arg: any) — open/config/start/cancel/kick/invite/solo/buy (хост зоны и покупки; сервер проверяет всё)
	"LobbyState", -- сервер → клиенту (лобби): снимок { mode, zone = { id, role, state, host, members, size, max, access, endsAt } } — что показать в меню зоны
	"LobbyInvite", -- сервер → клиенту (лобби): (zoneIndex: number, fromName: string, seconds: number) — хост зоны пригласил игрока
	"LobbyMenu", -- сервер → клиенту (лобби): (kind: "shop" | "vending", payload: { title: string, items: { { id, name, desc, price } } }) — окно торговца или автомата
	"BackToLobby", -- клиент → сервер (матч): () — вернуться в лобби (после конца раунда или по кнопке)
	"Ping", -- клиент → сервер: (position: Vector3) — поставить метку; сервер → всем: (player: Player, position: Vector3)
	"MinimapData", -- клиент → сервер: () — запрос плана карты (один раз); сервер → клиенту: ({ x, z, ширина, глубина, вид, … })
	"Notify", -- сервер → клиенту/всем: (text: string, seconds: number)
}

local Remotes = {}

local function folder(): Folder
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes")
		if not f then
			local nf = Instance.new("Folder")
			nf.Name = "Remotes"
			local seen: { [string]: boolean } = {}
			for _, name in NAMES do
				assert(not seen[name], "Remotes: event name declared twice: " .. name)
				seen[name] = true
				local ev = Instance.new("RemoteEvent")
				ev.Name = name
				ev.Parent = nf
			end
			nf.Parent = ReplicatedStorage
			f = nf
		end
		return f :: Folder
	end
	return ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Remotes.get(name: string): RemoteEvent
	return folder():WaitForChild(name) :: RemoteEvent
end

return Remotes
