# Манифест ассетов — «Ночь мертвецов» / Метро

> Получен из `examples/metro_assets_needed.md` по шаблону `skills/world-forge/templates/asset_manifest.md` (2026-10-23).
> Статусы — по журналу `examples/assets_ledger_example.md` на 2026-10-22; **сверено со Studio 2026-10-24** (только чтение: `Workspace.Metro`, `ServerStorage.Assets.Metro`, `AssetStaging`) — изменения и находки в разделе «Сверка со Studio» внизу.
> Источник выбран по дереву из `SKILL.md`, шаг 3; где пользователь явно хотел маркет, а дерево даёт `procedural`, — оставлен маркет и указана процедурная заглушка.
> Промпты и запросы — из `style_bible.md` §9. Требования ко всем ассетам маркета: без скриптов (или простые — вычистим), ≤ 5 000 частей, стиль «заброшенное метро / постапокалипсис», низкий полигонаж.

## Легенда
Источник: `procedural | gen-material | gen-mesh | gen-image-3d | market | buy`. Статус: `todo → wip → candidate → quarantine → vetted → placed → done`; также `stub` (стоит процедурная заглушка), `rejected`. Приоритет: P1 / P2 / P3.
Ledger: `L:10-22` = раздел «2026-10-22 — ассеты метро» журнала, `L:10-22в` = «вторая партия», `L:реквизит` = строка «Реквизит» журнала.

## 0. Каркас (уже построен процедурно)
| ID | Предмет | Зона / роль | Кол-во | Источник | Статус | Приор. | Запрос / промпт | Asset ID / файл | Лицензия | Ledger | Примечание |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A052 | Оболочка: стены, полы, потолки, балки, колонны | R1–R5, тоннели | — | procedural | placed | P1 | — | `BuildMetro.luau` | проект | — | детали ≤ 100 студов |
| A053 | Пути: рельсы, шпалы, русла, пандусы | R1, R4, тоннели | — | procedural | placed | P1 | — | `BuildMetro.luau` | проект | — | замена — A027 |
| A054 | Лестницы, проёмы с полом, маркеры | все | — | procedural | placed | P1 | — | `BuildMetro.luau` | проект | — | маркеры — spec §7 |

## 1. Пол, стены, потолок
| ID | Предмет | Зона / роль | Кол-во | Источник | Статус | Приор. | Запрос / промпт | Asset ID / файл | Лицензия | Ledger | Примечание |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A001 | Плитка пола (светлая, тёмная, с рисунком) | платформы R1/R4, R2, R3 | 2–3 вида | gen-material | stub | P1 | → §П A001 | — | — | — | сейчас `Marble` + швы-детали (`Decor.FloorTiles`, 527 деталей); `Enum.Material.Tile` нет, но есть `CeramicTiles` (D-018) — сравнить |
| A002 | Плитка стен (белая, цветная) | пояс стен и колонн | 2 вида | procedural | placed | P1 | швы поясом: `DressMetro` (A002) | `MaterialService.AssistantMaterials."Material: WF_A002_WallTileWhite"` (4 варианта, тест) | Roblox, AI | — | сейчас `Marble`-пояс 3,2. Тест `generate_material` 2026-10-24: мозаика неровных плит вместо кабанчиковой плитки, чистые швы, повтор каждые 10 студов — **как есть не годится** (снимки `docs/tests/2026-10-24_A002/`); варианты `…1–3` не осмотрены |
| A003 | Грязный бетон | стены тоннелей, потолок | 1–2 | gen-material | stub | P1 | → §П A003 | — | — | — | сейчас `Concrete` |
| A004 | Своды/арки над платформой | R1 | 3–5 сегментов | procedural | todo | P2 | запасной маркет: `metro station arch` / `subway vault arch` | — | — | — | в маркете не нашли; клинья/цилиндры или `generate_procedural_model` |
| A005 | Секции тоннеля (прямой, поворот, развилка) | тоннели | 3–6 | market | vetted | P2 | `tunnel segment` / `subway tunnel tube` | `15383663333` (пак, 15 секций, лучший), `13825043850`, `18310180132` (candidate) | бесплатные, лицензия не проверена | L:10-22, L:10-22в | `Assets.Metro.TunnelPack`, `TunnelRussian`; сейчас процедурные тоннели; решение о замене — после осмотра |
| A006 | Кольца обделки / крепи тоннеля | тоннели | 2–3 | procedural | stub | P2 | запасной маркет: `tunnel lining rings` / `tunnel ribs support` | — | — | — | сейчас деревянные крепи шаг 28 |
| A007 | Трубы под потолком | R1, R4, тоннели | 1 пак | procedural | placed | P3 | запасной маркет: `industrial pipes pack` | — | — | — | цилиндры `DressMetro` |
| A008 | Кабельные лотки и провода | R1, R4, тоннели | 1–2 | procedural | placed | P3 | — | — | — | — | лотки + 160 свисающих кабелей |
| A009 | Вентиляция, решётки | торцы R1 | 1–2 | procedural | stub | P3 | решётка-декаль → §П A009 | — | — | — | короба-заглушки |

## 2. Станция и платформа
| ID | Предмет | Зона / роль | Кол-во | Источник | Статус | Приор. | Запрос / промпт | Asset ID / файл | Лицензия | Ledger | Примечание |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A010 | Основа станции / детали (арки, колонны, трубы) | R1 | 1–2 | market | vetted | P2 | `subway station` / `metro platform` | `16276755276` (1121 часть, 7 скриптов вычищено); `13473210807` платформа; `9677855066` трамв. остановка | бесплатные, не проверена | L:10-22, L:10-22в | `Assets.Metro.StationAsset` — решение после осмотра пользователем; `2772959533`/`2772870107` rejected (5 584/5 863 частей) — брать детали |
| A011 | Билетные автоматы | R1 у северной стены | 1–2 | market | placed | P2 | `metro ticket machine` | `1957743767` | бесплатный, не проверена | L:10-22в | `Assets.Metro.TicketMachine`, x = ±75 |
| A012 | Турникеты | R2 | 1–2 вида | market | placed | P2 | `subway turnstile` | `77325124` (NYC, 6 скриптов вычищено) | бесплатный, не проверена | L:10-22в | **стоят** в `Props.Turnstiles_Hall` (6 шт., сверка 2026-10-24); библиотека `Assets.Metro.TurnstilesNYC`; `9518499699` — **quarantine** (скрипты в Weld) |
| A013 | Лавки | R1, R2, R4 | 2 вида | market | placed | P3 | `subway bench` / `platform bench` | `15080186657` | бесплатный, не проверена | L:10-22в | второй вид — todo |
| A014 | Эскалаторы | R1 → R2 | 1–2 | market | vetted | P3 | `subway escalator` / `escalator broken` | `16239094234` (17 скриптов + 2 Remote вычищены), `3743977597` | бесплатные, не проверена | L:10-22в | сейчас лестница; нужна ли замена — решить |
| A015 | Колонны с плиткой | R1 | 1–2 | procedural | stub | P2 | материал из A002 | — | — | — | сейчас база `Marble` 2,6 |
| A016 | Карта линий на стене | R1 | 1–2 | market | vetted | P3 | `subway train map` / `metro route map` | `9635331128` | бесплатный, не проверена | L:10-22 | `Assets.Metro.MetroSign`; проверить: нет ли текста (SB §7) |
| A017 | Урны | R1, R2 | 1–2 | gen-mesh | candidate | P2 | → §П A017 | `ServerStorage.AssetStaging.A017_Bin` (тест W005, `rbxassetid://121493486437423`) | Roblox, AI | — | сгенерирован 2026-10-24, габарит точный, годится; ждёт `Baker.bake` и замены цилиндров в DressMetro; прежде: сейчас цилиндры; запасной маркет: `trash can subway` / `public bin` |
| A018 | Знаки-иконки (выход, номер линии, платформа) | R1, тоннели | 3–5 | gen-material | stub | P2 | → §П A018 | `8565656963` (vetted, частично) | — | L:10-22в | **только иконки**: у `8565656963` надписи Masuk/Keluar — не подходит по SB §7 без замены текстуры |
| A019 | Светильники: аварийный красный, в сетке, люминесцентная трубка | R1, тоннели | 3 вида | gen-mesh | stub | P1 | → §П A019 | — | — | — | сейчас Neon-бруски; запасной маркет: `industrial caged lamp` / `fluorescent tube light` |
| A020 | Часы на платформе | R1 | 1 | gen-mesh | todo | P3 | → §П A020 | — | — | — | без цифр-надписей? — циферблат допустим |
| A021 | Служебные двери, металлические, роллет | R1, R3 | 3–4 | procedural | todo | P2 | запасной маркет: `fire door` / `metal security door` / `roller shutter` | — | — | — | простые формы |
| A022 | Решётки у выхода | R2 | 1–2 | procedural | todo | P3 | запасной маркет: `metal gate grate` / `rolling grille` | — | — | — | — |
| A023 | Люки, лестницы в тоннеле | тоннели, R2 | 2–3 | procedural | stub | P3 | запасной маркет: `ladder wall` / `manhole hatch` | — | — | — | люк-заглушка в R2 |

## 3. Поезда и рельсы
| ID | Предмет | Зона / роль | Кол-во | Источник | Статус | Приор. | Запрос / промпт | Asset ID / файл | Лицензия | Ledger | Примечание |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A024 | Вагоны на путях | R1 линии 1 и 3 | 3–5 | market | placed | P1 | `subway train` / `metro car` | `16482420276` (вагон), пак `8614691569` (Train106 и др.), `13463688473` (vetted, запас) | бесплатные, не проверена | L:10-22 | `SubwayCar`, `TrainPicks` |
| A025 | Разбитый состав | R5 (двор) | 1–2 | market | placed | P2 | `destroyed subway train` / `derailed train` | `9146311662` | бесплатный, не проверена | L:10-22 | укрытие во дворе |
| A026 | Вагон изнутри (лут, бой в вагоне) | R1 | 1–2 | market | todo | P2 | → §П A026 | — | — | — | `5107539489` (Train with Zombie): 12 скриптов, можно взять геометрию после чистки |
| A027 | Рельсы (прямой, поворот, стрелка) | все пути | 1 пак | market | candidate | P3 | `rusty rail track` / `railway track straight` | `572434010` (в AssetStaging; `Vetter` 2026-10-24: clean, 6 частей, 42×1×130), пак `8107652914` (не проверен) | — | L:10-22в | сейчас процедурные (A053) — по дереву достаточно; замена — только если лучше выглядит |
| A028 | Стрелки | тоннели | 1–2 | procedural | todo | P3 | запасной маркет: `railroad switch` / `track junction` | — | — | — | — |
| A029 | Двери вагонов (открытые/выбитые) | вагоны | 1–2 | gen-mesh | todo | P3 | → §П A029 | — | — | — | — |
| A030 | Дрезина | тоннели | 1–2 | market | placed | P2 | `handcar` / `rail trolley` | `12557087918` | бесплатный, не проверена | L:10-22в | стоит `Props.Handcar_Tunnel` (сверка 2026-10-24); езду пишем свою; `4542526738` — **quarantine** (скрипт в Sound) |
| A031 | Низкий локомотив (≤ 10 студов) | тоннель | 1 | market | todo | P3 | `diesel locomotive` / `locomotive` | — | — | L:10-22в | `8091742227` rejected (высота 17); запасной — gen-mesh; в библиотеке есть `Assets.Metro.Locomotive` (62 потомка) — происхождение и ID не записаны, **выяснить** |
| A032 | Упоры в тупиках | тоннели | 1–2 | procedural | todo | P3 | запасной маркет: `rail bumper` / `buffer stop` | — | — | — | — |
| A033 | Система поездов | — | — | market | rejected | — | — | `4560327510` | — | L:10-22в | 16 скриптов; логику поездов пишем свою |

## 4. Декор, «жизнь» и разруха
| ID | Предмет | Зона / роль | Кол-во | Источник | Статус | Приор. | Запрос / промпт | Asset ID / файл | Лицензия | Ledger | Примечание |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A034 | Граффити (картинки, без текста) | стены R1, тоннели | 6–10 | gen-material | todo | P2 | → §П A034 | — | — | — | декали |
| A035 | Обломки, кучи, обвал потолка | R1, тоннели, R4 | 4–6 | procedural | placed | P2 | обвал → §П A035 | — | — | — | кучи из кусков `Slate`; упавшая плита — gen-mesh по желанию |
| A036 | Мусор: пакеты, бумаги | R1, тоннели | 3–5 | gen-mesh | todo | P2 | → §П A036 | — | — | — | — |
| A037 | Лагерь выживших: спальник, палатка, бочка-костёр | R1, тоннели, R4 | 3–4 | gen-mesh | stub | P2 | → §П A037 | — | — | — | сейчас бочка + бруски-спальники |
| A038 | Брошенные вещи: тележка, чемодан, рюкзак, сумка | R1 | 4–6 | gen-mesh | todo | P3 | → §П A038 | — | — | — | — |
| A039 | Заграждения: металл, мешки, паллеты | R1, тоннели | 3–4 | market | todo | P2 | `barricade metal` / `wooden pallet barricade` | `12651656400` (мешки, в проекте) | не проверена | — | сверка 2026-10-24: в `Workspace.Metro` мешков нет (есть в `Workspace.Buildings.Shelter`, `Workspace.Base.Fort` — другие локации); в примере журнала записи нет — **добавить в ledger** |
| A040 | Лут: ящики с патронами, военные ящики, аптечка | R1, R3 | 3–5 | gen-mesh | placed | P2 | — | ящики `132407778378387` и др. | проект | L:реквизит | в метро: маркеры `AmmoCrate_1/2` (двор станции B) и процедурные `Props.ServiceCrate`; ставит ли игра меш-ящики на маркеры — не проверено; аптечка — todo |
| A041 | Гнёзда мутантов (цели `Metro_Objective_*`) | T-W2, T-E1, R3 | 2–3 | gen-mesh | todo | **P1** | → §П A041 | — | — | — | запасной — gen-image-3d; без крови (SB §1) |
| A042 | Генератор, канистра, электрощит (объекты цели) | R3, тоннели | 2–3 | gen-mesh | todo | P2 | → §П A042 | — | — | — | — |
| A043 | Останки, мешки для тел (не R15) | тоннели | 3–5 | gen-mesh | todo | P3 | → §П A043 | — | — | — | без крови |
| A044 | Плакаты (картинки) | стены, колонны R1 | 6–10 | gen-material | stub | P2 | → §П A044 | — | — | — | сейчас пустые цветные щиты |
| A045 | Кровь (декали) | — | 4–6 | gen-material | rejected | — | — | — | — | — | убрано решением пользователя |
| A046 | Фонарик / налобный фонарь | предмет игрока | 1–2 | — | rejected | — | — | — | — | — | не относится к локации — вынести в манифест предметов |

## 5. Звуки (тихие, зацикленные)
| ID | Предмет | Зона / роль | Кол-во | Источник | Статус | Приор. | Запрос / промпт | Asset ID / файл | Лицензия | Ledger | Примечание |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A047 | Фон: гул, ветер тоннеля | R1, тоннели | 1–2 | market | todo | P2 | `subway ambience` / `tunnel wind` / `underground hum` | — | — | — | только звук, проверка ID |
| A048 | Капли воды | тоннели | 1 | market | todo | P3 | `dripping water` / `water leak` | — | — | — | — |
| A049 | Скрип металла, далёкий поезд | тоннели | 1–2 | market | todo | P3 | `metal creak` / `distant train rumble` | — | — | — | — |
| A050 | Голоса зомби | везде | — | market | placed | P2 | — | общие (Chasing/Attacking/Dying) | — | — | есть в проекте |
| A051 | Гудение ламп | R1 | 1 | market | todo | P3 | `flickering light buzz` | — | — | — | — |

## Промпты и запросы (по ID)
Суффикс (SB §9): `abandoned post-apocalyptic subway, realistic, grimy, desaturated grey and rust tones, low-poly game asset`.
Negative (SB §9): `cartoon, toy, bright saturated colors, clean new, sci-fi, neon, text, letters, logo, watermark, blood`.

### A001 — плитка пола
- Материал: `seamless tileable subway floor tiles, square 30 cm light grey ceramic, dirty grout, worn and chipped, flat top-down orthographic, even lighting, desaturated grey`
- Вариант тёмный: то же с `dark blue-grey ceramic`. Вариант с рисунком: `checkerboard light and dark grey`.
- Требования: тайл 4×4 студа ≈ 4–9 плиток; проверка 2×2 на швы.

### A002 — плитка стен
- `seamless tileable white ceramic subway wall tiles, small rectangular brick pattern, dirty grout, stains, some cracked tiles, flat orthographic, even lighting, desaturated`
- Цветная: `pale green ceramic` (полоса линии).

### A003 — грязный бетон
- `seamless tileable grimy concrete wall, water stains, soot, cracks, flat orthographic, even lighting, desaturated grey`

### A009 — решётка вентиляции (декаль)
- `rusty metal ventilation grille, square, flat front view, isolated on white background, ` + суффикс

### A017 — урна
- Меш: `old metal subway trash bin, dented, peeling dark green paint, ` + суффикс + `, single object, game prop`
- Габарит ≈ 1,5 × 2,2 × 1,5 студа.

### A018 — знаки-иконки
- `subway wayfinding pictogram sign, exit arrow icon, white symbol on dark blue plate, worn and scratched, flat front view, no text` (варианты: стрелка, бегущий человек, лестница, кружок цвета линии)

### A019 — светильники
- `industrial caged ceiling lamp, rusty metal cage, ` + суффикс + `, single object, game prop` (≈ 1 × 1,5 × 1)
- `fluorescent tube ceiling light fixture, dusty, one tube broken, ` + суффикс (≈ 4 × 0,5 × 1)
- `red emergency wall light, round, metal housing, ` + суффикс

### A020 — часы
- `old station wall clock, round, cracked glass, dirty metal frame, ` + суффикс

### A026 — вагон изнутри (маркет)
- `subway train interior` / `train car interior` / `metro carriage interior`; ≤ 3 000 частей, ширина ≤ 10 студов.

### A029 — двери вагона
- `subway train sliding door panel, dented, broken window, ` + суффикс + `, single object, game prop`

### A034 — граффити
- `abstract graffiti tag shapes without letters, spray paint, faded, on transparent background, flat front view` (6–10 вариантов, разные цвета палитры)

### A035 — упавшая плита (опционально)
- `broken concrete ceiling slab with exposed rebar, ` + суффикс

### A036 — мусор
- `pile of black garbage bags, ` + суффикс; `scattered old newspapers on floor, flat, ` + суффикс

### A037 — лагерь
- `old sleeping bag rolled out, dirty, ` + суффикс; `small worn camping tent, ` + суффикс; `rusty oil barrel fire pit, ` + суффикс (огонь — эффектом движка)

### A038 — брошенные вещи
- `abandoned shopping cart, rusty`, `old suitcase`, `worn backpack`, `duffel bag` + суффикс

### A041 — гнездо мутантов (P1)
- Меш: `organic mutant nest, pale fleshy growth with cocoons and web strands, on floor, ` + суффикс + `, no blood, single object, game prop` (≈ 6 × 3 × 6)
- Картинка для картинка→3D (запасной): то же + `single object centered, plain light grey background, three-quarter view, full object visible, soft even lighting`

### A042 — объекты цели
- `portable diesel generator, rusty`, `red metal fuel canister`, `electrical wall panel with open door and wires` + суффикс

### A043 — останки
- `skeleton remains lying on ground in torn clothes`, `black body bag on floor` + суффикс (без крови)

### A044 — плакаты
- `old faded propaganda-style poster illustration without any text, torn edges, ` + палитра SB; 6–10 вариантов

## Сводка
| Источник | todo | stub | candidate/vetted | placed/done | rejected |
|---|---|---|---|---|---|
| procedural | 5 | 4 | — | 6 | — |
| gen-material | 1 | 5 | — | — | 1 |
| gen-mesh | 7 | 3 | — | 1 | — |
| market | 7 | — | 5 | 7 | 1 |
| без источника | — | — | — | — | 1 |
| **Итого: 54 строки** | 20 | 12 | 5 | 14 | 3 |

## Сверка со Studio (2026-10-24, только чтение)
Место `NightOfTheDeath` (placeId 98810057984988), Edit. Инструменты: `search_game_tree`, `inspect_instance`, `screen_capture`.
- **`Workspace.Metro`**: 6 023 потомка; папки `Shell`, `Tunnels`, `Platform`, `Props`, `Lights`, `Markers`, `StationB`, `Decor`. **Скриптов нет** (`LuaSourceContainer` = 0).
  - `Decor`: `FloorTiles` 527 деталей, `TunnelDecor` 605, `Debris` 188, `Utilities` 176, `Walls` 126, `Furniture` 60 (лавки ×23 + `HallBench` ×3, `TicketMachine` ×2, `VendingDecor` ×3), `StationB` 52, `Camps` 8 (`Camp` ×4, `TunnelCamp` ×4), `Fx` 5, `Stains` — пусто.
  - `Props`: `Turnstiles_Hall` (6), `TicketMachine_1/2`, `Train3_A/B`, `Train1_Full` (MeshPart), `BrokenTrainYard`, `Bench_1/2`, `Handcar_Tunnel`, процедурные лавки (`BenchSeat`/`BenchLeg*`), `Newsstand`, `TicketBooth`, `ServiceCrate`, `ServiceDesk`, `ServiceShelf`, `Exit*`.
  - `Markers` (25): `Metro_Spawn`, `Metro_Exit`, `Metro_Boss`, `Metro_Vending`, `Metro_Objective_1…3`, `Metro_StationB_Spawn/_Exit`, `AmmoCrate_1/2`, `Metro_ZombieSpawn_1…12` и **`_14`** — номера 13 нет: позиция №13 из `examples/BuildMetro.luau` (740, 14, 100) в месте называется `_14`. Сборщик в игре новее образца (есть `AmmoCrate_*`). В `Checks.requiredMarkers` указывать имена по факту.
  - Координаты мировые = локальные spec + (0, 600, 0): `Metro_Spawn` (106, 600,6, 33).
- **`ServerStorage.Assets.Metro`** (17): `BrokenTrain`, `SubwayCar`, `TrainPicks` (5 MeshPart), `TunnelPack` (15), `TunnelRussian`, `StationAsset` (13), `PlatformETC`, `TramStop`, `MetroSign`, `SignBoard`, `TurnstilesNYC` (6), `TicketMachine`, `Bench`, `EscalatorKoncar`, `EscalatorLuxiar`, `Handcar`, `Locomotive`. **Скриптов нет.** Атрибутов с ID источника у моделей нет — ID только в ledger.
- **`ServerStorage.AssetStaging`**: 216 объектов верхнего уровня, 154 947 потомков (карантин/черновики всей игры, не только метро). На верхнем уровне — **`ModuleScript` `MainModule`** (имя типичное для загрузчиков по ID) и модель **`Rake script`**: в ServerStorage скрипты не выполняются, но в локацию их не переносить; проверить `Vetter` (после установки) и решить с пользователем. Метро-кандидаты: `Railway Track` (A027), `Train with Zombie` и `Train with Zombie (из Workspace)` (A026), `Subway Tunnels V1`, `Tunnel-Tube`, `Potato's Subway Side/Island Platform`, `Sinus Turnstile`, `JNR C62 steam locomotive`, `Train System` (A033 rejected).
- **`ServerStorage.Tools`**: `Baker`, `Vetter`, `NormalizeR6`, `BakeZombie`, `WeaponBaker`, `VehicleBaker` — модули игры (не WorldForge). `ServerStorage.WorldForge` — **нет**.
- Изменения статусов: A012 vetted → **placed**, A030 vetted → **placed**, A039 placed → **todo** (в метро нет); подтверждены placed: A011, A013, A024, A025; vetted (в библиотеке, не стоят): A005, A010, A014, A016, A018; stub: A001, A037.

## Проход 2 интерьера (2026-10-24, `tools/DressMetroInterior.luau`)
| ID | Что сделано | Статус | Дальше |
|---|---|---|---|
| A055 (новый) | Оснащение R1: фаски в углах потолка, 3 продольные балки, ржавые полки поперечных, пятна сырости — `Decor.CeilingV2` (A004 частично: настоящих сводов нет, формы — фаски/балки) | placed (procedural) | своды/арки — P2, решить после осмотра |
| A019 | Корпус-каркас над 57 лампами зала (`Decor.LampHousings`), включённые лампы менее белые; **нового меша нет** | stub → частично (procedural) | аварийная красная и люминесцентная трубка — по-прежнему `gen-mesh`, P2 |
| A008 | Провисшие кабели (параболы из 6 сегментов) вместо чёрных палок | placed | — |
| A024 | Вагоны `Train3_A/B`, `Train1_Full`: темнее/ржавее, мемные Decal удалены, `Decor.TrainWear` | placed, restyled | `Train1_Full`: текстура меша растянута — заменить меш (`TrainPicks`) или оставить; салон (A026) — todo |
| A001 | Мрамор → `CeramicTiles` (матовая плитка, без «молний») по всему залу, R2, R3, станции B | placed (тест принят на платформе 2) | оценить в Play |
| A011/A012 | Билетные и торговые автоматы: Decal с брендами/«Tickets» удалены, перекрашены; турникеты перекрашены (остались светлыми из-за текстур) | placed, restyled | турникеты — решить: заменить A012 |
| A015 | База колонн → `CeramicTiles` | placed | — |
