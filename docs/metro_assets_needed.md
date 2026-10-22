# Метро: список ассетов для поиска в Creator Store

Что искать (английские запросы), зачем нужно, сколько штук и что уже есть. Статус: **есть** — уже проверено и лежит в `ServerStorage.Assets.Metro`; **нужно** — ещё не найдено; **кандидат** — найдено, не вставлено/не проверено.
Любой найденный ID присылайте списком: я вставлю, проверю на скрипты (скрипты вычищаем), уберу карантинные и поставлю.
Правила выбора: без скриптов (или с простыми — вычистим), не тяжелее ~5 000 частей, стиль «заброшенное метро / постапокалипсис», низкий полигонаж.

## 1. Пол, стены, потолок (главное для вида)
| Запрос | Для чего | Кол-во | Статус |
|---|---|---|---|
| `subway tile texture` / `metro floor tile` (SurfaceAppearance или MaterialVariant) | плиточный пол платформ, зала, служебной комнаты | 2–3 вида (светлая, тёмная, с рисунком) | нужно |
| `subway wall tile` / `white ceramic wall tile` (текстура или MaterialVariant) | плитка на стенах и колоннах | 2 вида (белая, цветная) | нужно |
| `concrete wall dirty` / `grime concrete texture` | стены тоннелей, потолок | 1–2 | нужно |
| `metro station arch` / `subway vault arch` | своды над платформой | 3–5 сегментов | нужно (не нашли) |
| `tunnel segment` / `subway tunnel tube` | тоннели вместо моих блочных | 3–6 сегментов (прямой, поворот, развилка) | кандидаты: `15383663333` (пак, 15 секций), `13825043850`, `18310180132` |
| `tunnel ribs support` / `tunnel lining rings` | кольца обделки тоннеля | 2–3 | нужно |
| `subway ceiling pipes` / `industrial pipes pack` | трубы под потолком | 1 пак | нужно |
| `cable tray` / `cable bundle` / `hanging wires` | кабельные лотки и провода | 1–2 | нужно |
| `ceiling ventilation duct` / `air vent grille` | вентиляция | 1–2 | нужно |

## 2. Станция и платформа
| Запрос | Для чего | Кол-во | Статус |
|---|---|---|---|
| `subway station` / `metro platform` | основа станции, детали | 1–2 (лёгкие) | кандидаты: `16276755276` (1121 часть, скрипты вычищены), `13473210807` (платформа), `9677855066` (трамвайная остановка); `2772959533`/`2772870107` слишком тяжёлые |
| `subway turnstile` | турникеты | 1–2 вида | есть: `77325124` (NYC), `9518499699` в карантине (скрипты в Weld) |
| `metro ticket machine` | билетные автоматы | 1–2 | есть: `1957743767` |
| `subway escalator` / `escalator broken` | эскалаторы к залу | 1–2 | кандидаты: `16239094234`, `3743977597` (геометрия без скриптов) |
| `subway bench` / `platform bench` | лавки | 2 вида | есть: `15080186657` |
| `metro pillar` / `column concrete tile` | колонны с плиткой | 1–2 | нужно |
| `subway train map` / `metro route map` (без текста или с картинкой) | карта линий на стене | 1–2 | кандидат: `9635331128` |
| `subway sign` / `exit sign` / `platform number sign` | знаки (по решению — без надписей на русском, только иконки) | 3–5 | частично: `8565656963` |
| `trash can subway` / `public bin` | урны | 1–2 | нужно |
| `emergency light red` / `industrial caged lamp` / `fluorescent tube light` | аварийный и потолочный свет | 3 вида | нужно |
| `subway clock` / `station clock` | часы на платформе | 1 | нужно |
| `fire door` / `metal security door` / `roller shutter` | служебные двери, решётки | 3–4 | нужно |
| `metal gate grate` / `rolling grille` | решётки у выхода | 1–2 | нужно |
| `ladder wall` / `manhole hatch` | люки, лестницы в тоннеле | 2–3 | нужно |

## 3. Поезда и рельсы
| Запрос | Для чего | Кол-во | Статус |
|---|---|---|---|
| `subway train` / `metro car` | вагоны на путях | 3–5 | есть: `16482420276` (вагон), пак `8614691569` (Train106 и др.), `13463688473` |
| `destroyed subway train` / `derailed train` | разбитые составы, укрытия | 1–2 | есть: `9146311662` |
| `subway train interior` / `train car interior` | вагон внутри (лут, бой внутри вагона) | 1–2 | нужно |
| `train door` / `sliding train door` | двери вагонов (открытые/выбитые) | 1–2 | нужно |
| `rusty rail track` / `railway track straight/curve` | рельсы вместо моих блочных | 1 пак (прямой, поворот, стрелка) | кандидат: `572434010`; пак `8107652914` |
| `railroad switch` / `track junction` | стрелки | 1–2 | нужно |
| `handcar` / `rail trolley` | дрезина по рельсам | 1–2 | есть: `12557087918` (чистая); `4542526738` в карантине (скрипт в Sound) |
| `locomotive` / `diesel locomotive` | локомотив в тоннеле (низкий, влезает в 10 студов) | 1 | паровоз `8091742227` есть, но слишком высокий (17) |
| `train system` | система поездов | — | `4560327510` не берём (скрипты) |
| `rail bumper` / `buffer stop` | упоры в тупиках | 1–2 | нужно |

## 4. Декор, «жизнь» и разруха
| Запрос | Для чего | Кол-во | Статус |
|---|---|---|---|
| `subway graffiti decal` / `graffiti pack` | граффити на стенах (картинки, не текст) | 6–10 | нужно |
| `blood decal` / `bloodstain pack` | следы (если вернёмся к крови) | 4–6 | сейчас убрано по решению |
| `abandoned subway debris` / `rubble pile` / `collapsed ceiling` | обломки, обвалы | 4–6 | нужно |
| `trash pile` / `garbage bags` / `scattered papers` | мусор | 3–5 | нужно |
| `survivor camp` / `sleeping bag` / `tent small` / `campfire barrel` | лагеря выживших | 3–4 | нужно (сейчас простые детали) |
| `shopping cart` / `suitcase` / `backpack` / `duffel bag` | брошенные вещи | 4–6 | нужно |
| `barricade metal` / `sandbag` / `wooden pallet barricade` | заграждения | 3–4 | частично: `12651656400` (мешки) в проекте |
| `ammo box` / `military crate` / `medkit` | лут в метро | 3–5 | есть военные ящики в проекте |
| `generator` / `fuel canister` / `electric panel` | оборудование, объекты цели | 2–3 | нужно |
| `zombie nest` / `flesh growth` / `spider web` / `cocoon` | гнёзда мутантов (цели зачистки `Metro_Objective_*`) | 2–3 | нужно |
| `skeleton remains` / `body bag` / `corpse` (мёртвые, не R15-модель) | мертвецы на путях | 3–5 | нужно |
| `poster pack` / `old posters` (картинки) | плакаты на стенах | 6–10 | нужно |
| `flashlight` / `headlamp` | предмет игрока (позже) | 1–2 | нужно |

## 5. Звуки (тихие, зацикленные)
| Запрос | Для чего | Статус |
|---|---|---|
| `subway ambience` / `tunnel wind` / `underground hum` | фон станции и тоннелей | нужно |
| `dripping water` / `water leak` | капли | нужно |
| `metal creak` / `distant train rumble` | скрип, далёкий поезд | нужно |
| `zombie groan` / `zombie moan` (проверенные ID) | голоса в метро | есть общие (Chasing/Attacking/Dying) |
| `flickering light buzz` | гудение светильников | нужно |

## 6. Что уже сделано (процедурно, можно заменить)
Рельсы, шпалы, стены и потолок тоннелей, платформы, колонны, балки, лавки-заглушки, турникеты зала, билетные автоматы, кабели, крепи, лагеря — всё собирается `tools/BuildMetro.luau` и `tools/DressMetro.luau` и заменяется найденными ассетами по мере поступления.
