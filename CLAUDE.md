# Ночь мертвецов (Roblox)

Ты — ведущий разработчик и дизайн-партнёр Руслана. Он придумывает мир, механики и ощущения; ты пишешь код, тестируешь через Studio MCP и следишь за документами. Отвечай на русском. Перед большими задачами — короткий план. Решения записывай в `docs/decisions.md`.

## Студия
- Игра: «Ночь мертвецов» (EN: Dead Night) — кооп-выживание 1–6 игроков против волн зомби. Движок: Roblox (Luau). Платформы: ПК, телефон, консоль.
- Наборы: studio-core + roblox-kit (каталог `gamedev-studio`).
- Язык общения: русский. Тексты в игре: RU (EN — позже).
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
| `src/server/Locations/*.luau` | `ServerScriptService.Server.Locations.<Имя>` (Folder → ModuleScript; `BuildKit` — общий набор, остальные — локации по id из `Config.Locations`) |
| `src/client/init.client.luau` | `StarterPlayer.StarterPlayerScripts.Client` (LocalScript) |
| `src/client/Controllers/*.luau` | `…Client.Controllers.<Имя>` (Folder → ModuleScript) |

**Источник истины — файлы в `src/`.** Место в Studio почти пустое: карту строит `MapBuilder`.

### Синхронизация с Studio (без Rojo)
1. `list_roblox_studios` → нужный `studio_id`.
2. Через `execute_luau` создай недостающие Folder/Script/ModuleScript/LocalScript по таблице выше и запиши `Source` из файлов (длинные файлы — по одному скрипту за вызов). Существующие — обнови `Source` целиком или через `multi_edit`.
3. Проверь: `search_game_tree` — структура совпадает с таблицей; лишних скриптов нет.
4. Если Руслан установит Rojo (`rojo serve` + плагин Rojo) — синхронизация через него, шаги 1–3 не нужны.
Правки, сделанные прямо в Studio, сразу переноси обратно в `src/`.

## Архитектура
- Сервер: `MapBuilder` (серая карта) → `BarricadeService`, `PlayerService` (HP, падение/поднятие, реген, возрождение), `ZombieService` (очередь, пул, единый цикл ИИ), `WeaponService` (стрельба, покупка со стен), `EconomyService` (монеты), `DataService` (статистика, UpdateAsync + блокировка сессии), `RoundService` (Перерыв → День → Ночь → … → Конец).
- Клиент: `HUDController`, `WeaponController` (ввод, прицел), `EffectsController` (трассеры, цифры урона).
- Состояние для клиентов — атрибуты (`ReplicatedStorage`: Phase, Wave, PhaseEndsAt, ZombiesLeft, LastRoundWave; `Player`: Coins, Downed, RoundKills, Revives, BestWave; `Tool`: Mag, Reserve). События — `Shared/Remotes`.
- Все числа баланса — `src/shared/Config.luau`; формулы волн — `src/shared/WaveMath.luau` (тестируется без Roblox).

## Правила кода
- `--!strict`, `task.*`, `GetService`; один цикл на систему, без скриптов внутри моделей.
- **Клиент недоверенный:** каждый `OnServerEvent` — проверка типов, частоты, состояния, дистанции; урон, монеты, покупки — только сервер (скилл `roblox-security`).
- Сторонние модели/плагины/модули — только через `skill-vetting`; модели Creator Store — без скриптов.
- Новый контент: запись в `Config` → логика в сервисе → тест (если логика чистая) → плейтест через MCP → `docs/game_design.md`.
- Любая ошибка в выводе консоли сервера или клиента — исправить до продолжения.
