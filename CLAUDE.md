# Ночь мертвецов (Roblox)

Ты — ведущий разработчик и дизайн-партнёр Руслана. Он придумывает мир, механики и ощущения; ты пишешь код, тестируешь через Studio MCP и следишь за документами. Отвечай на русском. Перед большими задачами — короткий план. Решения записывай в `docs/decisions.md`.

## Студия
- Игра: «Ночь мертвецов» (EN: Dead Night) — кооп-выживание 1–6 игроков против волн зомби. Движок: Roblox (Luau). Платформы: ПК, телефон, консоль.
- Наборы: studio-core + roblox-kit (каталог `gamedev-studio`).
- Язык общения: русский. Тексты в игре: EN (с 2026-10-30; сообщения в консоль — тоже EN; комментарии в коде и документы — RU). Локализация RU позже — через LocalizationTable.
- Команды:
  - запуск/плейтест: Studio MCP (`start_stop_play`, `get_console_output`, `screen_capture`, симуляция ввода); несколько игроков — Test → Clients and Servers;
  - юнит-тесты чистой логики: `luau tests/run.luau` (если установлен Luau CLI);
  - линтер/типы (по желанию): `selene src`, `luau-lsp analyze --definitions=<globalTypes.d.luau> src`.
- Документы: стандартные пути studio-core (`docs/game_design.md`, `docs/decisions.md`, `docs/roadmap.md`, `docs/qa/`, `docs/playtests/`, `docs/assets_ledger.md` …).

## Код: где что лежит (совместимо с Rojo, `default.project.json`)
| Файл в репозитории | Объект в Studio |
|---|---|
| `src/shared/*.luau` | `ReplicatedStorage.Shared.<Имя>` (ModuleScript), `Shared` — Folder |
| `src/server/init.server.luau` | `ServerScriptService.Server` (Script) |
| `src/server/Types.luau` | `ServerScriptService.Server.Types` (ModuleScript) |
| `src/server/Services/*.luau` | `ServerScriptService.Server.Services.<Имя>` (Folder → ModuleScript) |
| `src/server/Locations/*.luau` | `ServerScriptService.Server.Locations.<Имя>` (Folder → ModuleScript; `BuildKit` — общий набор, `Lobby` — лобби (строит `LobbyService`, не `MapBuilder`), остальные — локации по id из `Config.Locations`) |
| `src/client/init.client.luau` | `StarterPlayer.StarterPlayerScripts.Client` (LocalScript) |
| `src/client/Controllers/*.luau` | `…Client.Controllers.<Имя>` (Folder → ModuleScript) |

**Источник истины — файлы в `src/`.** Место в Studio почти пустое: карту строит `MapBuilder`.
**Исключение — готовые модели ассетов:** чистые копии лежат в `ServerStorage.Assets` (внутри файла места, не в репозитории); «печь» `tools/Baker.luau`; сырые и непроверенные — в `ServerStorage.AssetStaging`. Ассеты проверяем скиллом `asset-vetting` (`.claude/skills/asset-vetting`); `Workspace` в Edit-режиме держим пустым от чужих моделей. Трекер ассетов и этапов — `docs/asset_plan.md`. Режим осмотра: `Config.Explore` (локация `World`).

### Синхронизация с Studio (без Rojo)
1. `list_roblox_studios` → нужный `studio_id`.
2. Через `execute_luau` создай недостающие Folder/Script/ModuleScript/LocalScript по таблице выше и запиши `Source` из файлов (длинные файлы — по одному скрипту за вызов). Существующие — обнови `Source` целиком или через `multi_edit`.
3. Проверь: `search_game_tree` — структура совпадает с таблицей; лишних скриптов нет.
4. Если Руслан установит Rojo (`rojo serve` + плагин Rojo) — синхронизация через него, шаги 1–3 не нужны.
Правки, сделанные прямо в Studio, сразу переноси обратно в `src/`.

## Архитектура
- Сервер: `MapBuilder` (серая карта) → `BarricadeService`, `PlayerService` (HP, падение/поднятие, реген, возрождение), `ZombieService` (очередь, пул, единый цикл ИИ), `WeaponService` (стрельба, покупка со стен), `EconomyService` (монеты: личные счета игроков), `BuildingService` (здания за монеты, закрытие магазина), `ItemService` (аптечка, энергетик), `DataService` (статистика, UpdateAsync + блокировка сессии), `RoundService` (Перерыв → День → Ночь → … → Конец).
- Сервер дополнительно: `StaminaService` (энергия и спринт), `ScoreService` (личные очки и командная копилка, leaderstats); локации — `Locations/*` (`MapBuilder` — диспетчер).
- Сервер дополнительно (миссии и мир): `MissionService` (миссия ночи и поток зомби), `GeneralService` (генерал на базе, выдаёт задание), `ConvoyService` (колонна в миссии escort; едет по дорогам, маршрут — `RoadRoute`), `SoldierService` (военные НПС на базе), `VehicleService` (машины и пулемёт), `VendorService` (НПС-продавцы в открытых зданиях), `ShopService` (точки магазина оружия: палатки и стенды), `EquipmentService` (проволока и турель), `AmmoCrateService` (ящики с патронами), `PerkService` (перки команды после боссов), `RatingService` (рейтинг и глобальный лидерборд).
- Лобби: одно место, два режима (`LobbyService.detectMode`): публичный сервер — лобби (`Locations/Lobby` строит блокпост из ассетов `ServerStorage.Assets` и `Assets.Lobby`; `LobbyService`: 4 зоны сбора команды — первый вошедший хост, зона закрыта, пока он настраивает размер 1–6 и доступ Public / Friends only / Invite only, затем открыта; старт кнопкой хоста или отсчётом, когда зона заполнена; ворота Play solo; табло «Top survivors» из `RatingService`; окна магазина и автоматов — заглушки «Coming soon»; телепорт на резервный сервер `ReserveServer`), `LobbyNpcService` ведёт 12 военных НПС лобби, резервный сервер — матч (обычный раунд; в конце экран итогов и возврат в лобби). Правила зон без Roblox API — `Shared/LobbyRules` (тесты). В Studio телепорт заменён заглушкой (`Config.Lobby.StudioSkipTeleport`), `Config.Lobby.ForceMode` — только Studio; в Studio по умолчанию стартует лобби.
- Клиент: `HUDController`, `WeaponController` (ввод, прицел, ближний бой), `EffectsController` (цифры урона, звуки), `ArmsController` (руки от 1 лица, анимации), `MovementController` (спринт, подкат, кувырок, камера кувырка), `FxController` (отдача, вспышки, трассеры).
- Клиент дополнительно: `LobbyController` (меню хоста зоны сбора, панель команды, приглашения, окна магазина и автомата, экран итогов с «Back to lobby»; игровые контроллеры в `init.client` стартуют только в режиме матча), `ViewModelController` (руки и оружие от первого лица), `VehicleController` (езда: ввод водителя), `ShopController` (меню покупки оружия, B), `VoteController` (голос за конец дня, V), `EquipController` (установка турели и проволоки из рук), `TurretController` (пулемёт машины: наведение, огонь), `PerkController` (выбор перка команды после босса), `ZombieMarkerController` (метки на последних зомби), `MissionController` (задача ночи на экране), `BriefingController` (окно задания от генерала), `SfxController` (голоса и звуки окружения).
- Состояние для клиентов — атрибуты (`ReplicatedStorage`: Mode (lobby | match), ReturnAt, Phase (в лобби — "Lobby"), Wave, PhaseEndsAt, ZombiesLeft, LastRoundWave, Location, TeamPoints, TeamTotal, TeamLives, DayVotes, DayVoteNeed, BuildingsOpen, Perks, MissionTitle, MissionText, MissionKind; `Player`: Coins, Score, Energy, Sprinting, Dodge, Downed, DownedUntil, RoundKills, Revives, Headshots, BestWave, Rating, RatingTotal, VotedDay, NearShop, ShopFree; `Tool`: WeaponId, Mag, Reserve, Melee, Automatic, FireRate, EquipKind, ItemId; машины: Vehicle, VehicleType, Hp, MaxHp, Wrecked, TurretMag, TurretReserve, TurretReloading, TurretReady; зомби: Hp, MaxHp, SwingAt). События — `Shared/Remotes`.
- Все числа баланса — `src/shared/Config.luau`; формулы волн — `src/shared/WaveMath.luau` (тестируется без Roblox).

## Правила кода
- `--!strict`, `task.*`, `GetService`; один цикл на систему, без скриптов внутри моделей.
- **Клиент недоверенный:** каждый `OnServerEvent` — проверка типов, частоты, состояния, дистанции; урон, монеты, покупки — только сервер (скилл `roblox-security`).
- Сторонние модели/плагины/модули — только через `skill-vetting`; модели Creator Store — без скриптов.
- Новый контент: запись в `Config` → логика в сервисе → тест (если логика чистая) → плейтест через MCP → `docs/game_design.md`.
- Любая ошибка в выводе консоли сервера или клиента — исправить до продолжения.
