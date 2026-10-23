# Промпт для Sonnet: пакеты B, E, G из ревью 2026-10-23

Вставить в новую сессию целиком (всё ниже линии).

---

Ты — разработчик «Ночи мертвецов» (Roblox, Luau `--!strict`). Отвечай по-русски. Сначала прочитай `CLAUDE.md`, затем `docs/qa/opus_review_2026-10-23.md`: в нём по номерам описаны все находки (файл:строка, сценарий, способ исправления). Твоя задача — исправить пакеты **B, E и G**, строго в этом порядке. **Один пакет — один коммит.** После каждого пакета покажи короткий итог и сразу переходи к следующему. Не пушь.

## Общие правила
- Меняй только файлы, перечисленные у пакета. Если для исправления нужен другой файл — остановись и спроси Руслана.
- Номера строк в отчёте указаны на коммит `edf6ddf`, они могли сдвинуться. Ищи код по содержимому.
- Стиль — как в окружающем коде: русские комментарии в том же объёме, `task.*`, `GetService`, без новых зависимостей.
- Параллельно с тобой может работать другая сессия: Opus в пакете D (`DataService`). `DataService.luau`, `RatingService.luau`, `ZombieService.luau`, `MissionService.luau`, `RoundService.luau`, `SoldierService.luau` **не трогай**.
- **Синхронизация со Studio** (Rojo нет). Studio один на все сессии.
  1. `list_roblox_studios` → `studio_id`.
  2. Перед правкой скрипта в Studio сравни `#Source` в Studio с размером файла в HEAD (`git show HEAD:<файл> | tr -d '\r' | wc -c`). Не совпадает — **не перезаписывай**, спроси Руслана: в Studio могли остаться несохранённые правки.
  3. Правь через `multi_edit` (те же замены, что в файле) или записывай `Source` целиком. **`replace_all` в `multi_edit` ненадёжен** — делай отдельную замену на каждое вхождение.
  4. После правки снова сравни `#Source` с размером файла на диске (без `\r`): должно совпасть байт в байт.
  5. Новый модуль в `src/shared/` — это `ModuleScript` в `ReplicatedStorage.Shared` (см. таблицу в `CLAUDE.md`).
- **Плейтест:** перед `start_stop_play` проверь `get_studio_state`. Если игра уже запущена — это может быть другая сессия: подожди и проверь снова, не останавливай чужой плейтест. После проверки обязательно останови игру (`start_stop_play(false)`).
- Консоль: сообщения `ContentId … failed`, `Failed to load sound`, `asset … access permission` и `DataStore … API access` были и до тебя — их не чини. Любая **новая** ошибка или `warn` из наших скриптов — исправить до коммита.
- Решения записывай в конец `docs/decisions.md` (раздел с датой и пакетом: что сделано, что проверено, что нет).
- Подпись коммита — последняя строка: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Пакет B — входы от клиента
Файлы: `src/shared/Remotes.luau`, новый `src/shared/Validate.luau`, `src/server/Services/WeaponService.luau`, `VehicleService.luau`, `EquipmentService.luau`, `PlayerService.luau`.

1. **Общая проверка векторов.** Создай `src/shared/Validate.luau` с `Validate.finiteVector(v: Vector3, limit: number?): boolean` (NaN и ±inf по всем трём осям, модуль каждой оси < `limit`, по умолчанию 1e6). В `WeaponService` замени локальный `isFiniteVector` на него.
2. **№6 `TurretAim`** (`VehicleService`, `onTurretAim`): вместо `d.X ~= d.X` — `Validate.finiteVector(d)`. Проверка: вектор `Vector3.new(1, 0/0, 0)` отклоняется.
3. **№5 упавший в машине.** `PlayerService.isUp(player)` в подсказке посадки (`prompt.Triggered` в `VehicleService.spawn`), в `onSwitchSeat` и в `gunnerState`. В `PlayerService` в локальной функции `down` после `player:SetAttribute("Downed", true)`: если `h.SeatPart`, то `h.Sit = false`. `VehicleService` пока не требует `PlayerService` — добавь `require(script.Parent:WaitForChild("PlayerService"))` (цикла нет: `PlayerService` требует только `Perks`, `Config`, `ScoreService`).
4. **№14 дубли в `Remotes`.** Удали повтор `PerkOffer` и `PerkChoose` в `NAMES`. В `folder()` на сервере перед созданием проверяй уникальность имён (`assert` с понятным текстом).
5. **№24 выстрел из машины.** В `onFire` и `onMelee` (`WeaponService`) отклоняй, если у Humanoid игрока есть `SeatPart`. Пулемёт машины использует `TurretFire` — его не трогай.
6. **№23 подбор дропа** (`WeaponService`):
   - при подборе патронов к уже имеющемуся оружию — `st.reserve = math.min(st.reserve + …, reserveCap(def))`;
   - в `onPickup` сначала прочитай атрибуты дропа и уничтожь его (или пометь атрибутом `Taken` и проверяй его в начале), только потом выдавай оружие — чтобы уступка в `buildTool` не дала двойной подбор;
   - в `spawnDrop` после `model.Parent = dropsFolder()` — `handle:SetNetworkOwner(nil)` (в `pcall`: деталь может оказаться закреплённой).
   - в `giveWithAmmo` вместо `def.magSize` используй `magCap(def)` (иначе пропадает бонус перка «магазин»).
7. **№25 оборудование** (`EquipmentService.onPlace`): `Validate.finiteVector(pos, 1e5)` вместо ручной проверки; после рейкаста — отклонять, если `math.abs(hit.Position.Y - root.Position.Y) > 8` (турель на крыше).

Проверка в Studio: синхронизация, плейтест, ночь 1 стартует; выстрел из оружия и подбор выброшенного (G, затем E) работают. Через `execute_luau` на сервере нельзя вызвать живой модуль (у команды своя копия `require`), поэтому NaN проверь, вызвав `Validate.finiteVector` напрямую в `execute_luau` (Edit): `(1,0/0,0)` → false, `(1,0,0)` → true, `(math.huge,0,0)` → false.

## Пакет E — клиент
Файлы: `src/client/Controllers/PerkController.luau`, `WeaponController.luau`, `SfxController.luau`, `FxController.luau`. `TurretController` и `EquipController` (№19, управление на телефоне) **не трогай** — там ждём решения Руслана по кнопкам.

1. **№15 окно перков.** В Heartbeat-обработчике: если `overlay.Visible and endsAt > 0 and os.clock() >= endsAt + 1.5` — вызвать `close()` (сервер сам выбирает перк через 30 + 1 с). После выбора (`choose`) не перетирать «Ждём остальных игроков…»: например, обнулять `endsAt` в `choose` и закрывать по `task.delay`, как сейчас. Клавиши 1–3 должны освобождаться в любом исходе (`close()` уже вызывает `UnbindAction`).
2. **№21 `Activated` копятся.** В `hookTool` подключать `tool.Activated` один раз на Tool: таблица `hooked` со слабыми ключами (`setmetatable({}, { __mode = "k" })`) или атрибут на Tool.
3. **№22 таблицы без очистки.** `nextVoice` и `swingSeen` в `SfxController`, `muzzleCache` в `FxController` — слабые ключи (`__mode = "k"`).

Проверка в Studio: плейтест, взять и сменить оружие 3–4 раза, выстрелить — ошибок в консоли клиента нет. Окно перков проверить не получится (нужен босс) — так и напиши в итоге.

## Пакет G — документация и тесты (только №28 и №29)
Файлы: `CLAUDE.md`, `src/shared/Config.luau` (только удаление мёртвых ключей), `src/shared/Remotes.luau` (комментарий), `tests/run.luau`, новый `tools/ReleaseCheck.luau`. №20 и №27 не трогай — они ждут решения или плейтеста Opus.

1. **`CLAUDE.md`, раздел «Архитектура».** Добавь недостающие сервисы (AmmoCrate, Convoy, Equipment, General, Mission, Perk, Rating, Shop, Soldier, Vehicle, Vendor) и контроллеры (ViewModel, Vehicle, Shop, Vote, Equip, Turret, Perk, ZombieMarker, Mission, Briefing, Sfx) — по одной короткой фразе, что делает каждый (бери из комментария в начале файла). Исправь: трассеры — в `FxController`, а не в `EffectsController`. Дополни список атрибутов фактическими (сверь `Grep` по `SetAttribute(` в `src/server`). Остальные разделы `CLAUDE.md` не переписывай.
2. **Мёртвые ключи Config.** Перед удалением подтверди `Grep` по `src/` и `tools/`, что ключ нигде не читается: `ExploreAutoZombies`, `ExploreZombieTypes`. `WeaponSights` **не удаляй** (следующий этап по решению 2026-10-19). Поле `runners` в `Config.Threat.Tiers` не трогай — это вопрос к Руслану (реализовать или удалить); напиши его в итоге.
3. **`Remotes.luau`:** исправь комментарий `ShopOpen` — сервер шлёт `()` (палатка) или таблицу продавца `{ vendorId, title, greeting, items }`.
4. **`tests/run.luau`:** исправь пустую проверку `… == 0 or true` (найди по тексту «волна 5 допускает»): либо реальное условие, либо удалить. Добавь чистые тесты для `src/shared/Ballistics.luau` и `src/shared/RateLimit.luau` (кейсы — раздел 7 отчёта, пункты 2 и 4; игрока для `RateLimit` подменить таблицей). Ручные копии Config в тестах пока оставь: `Config` требует `script`, и в Luau CLI его не загрузить.
5. **`tools/ReleaseCheck.luau`** — страж релиза и согласованности Config. Запускается в Studio (Edit, `execute_luau`), читает `ReplicatedStorage.Shared.Config`, печатает список проблем и возвращает их число. Проверки (раздел 7, пункт 1): `TestStands`, `Waves.CountScale` (nil или 1), `DebugStartNight == 1`, `Explore == false`; у каждого `ShopList[i].id` есть `Weapons[id]`; у каждого ключа `WeaponAim` есть `Weapons`; у каждого `MeleeFx[id].style` есть `MeleeAnim.STYLES[style]` и `MeleeAnim.HIT[style]`; у каждого типа зомби из `Config.Waves` есть `Config.Zombies[id]`; имена в `Remotes` уникальны (прочитай `NAMES`, если он доступен, иначе пропусти с пометкой). **Сейчас он должен находить `CountScale = 0.1` и `TestStands = true` — это ожидаемо**, Config не меняй. Прогони его в Studio и приложи вывод к итогу.
6. Тесты: если `luau` есть в PATH — запусти `luau tests/run.luau`, все тесты должны пройти. Если нет — **не устанавливай** ничего сам, напиши Руслану, что тесты не прогнаны и нужен Luau CLI.

## Итог после каждого пакета
3–6 строк: хеш коммита, что исправлено (по номерам находок), что проверено в Studio, что не проверено, вопросы к Руслану.
