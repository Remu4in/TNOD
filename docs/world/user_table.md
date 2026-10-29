# Что нужно от Руслана — метро (на 2026-10-25, после P3: двор R5 и станция B)

Сначала P1. «Я сам» = могу сделать через Studio MCP, нужно только «да» на каждую запись в место (`studio_changes.md`). Присланные ID принимаю по шагу 7 скилла и `asset-vetting`.

| # | ID | Что | Приор. | Действие | Запрос / промпт | Габарит | Что прислать |
|---|---|---|---|---|---|---|---|
| 1 | — | **Сохранить место (Ctrl+S)**; посмотреть двор R5 и станцию B (W017–W020) | P1 | Посмотреть в Studio | — | — | «принято» / замечания |
| 2 | — | Навмеш проверен (W021): все 29 точек Success, двор и R3 достижимы — ничего делать не нужно | P1 | — | — | — | — |
| 3 | A041 | Гнёзда мутантов для `Metro_Objective_1…3` | P1 | Я сам: `generate_mesh` (по 1 тесту на гнездо) — скажите «да» | `organic mutant nest, pale fleshy growth with cocoons and web strands, on floor, abandoned post-apocalyptic subway, realistic, grimy, desaturated grey and rust tones, low-poly game asset, no blood, single object, game prop` | ≈ 6×3×6 | ничего |
| 4 | A039 | Заграждения во дворе вместо процедурных мешков (проверить ID `12651656400`) | P2 | Найти в Creator Store | `sandbag barricade` / `military sandbag wall low poly` | ≈ 8×3×2, ≤ 300 частей | ID `A039: …` |
| 5 | A056 | Контейнеры двора (сейчас коробки с рёбрами) | P2 | Найти в Creator Store | `rusty shipping container low poly` / `cargo container` | 20×8,3×8 | ID `A056: …` |
| 6 | A057 | Скалы за двором (сейчас серые блоки) | P2 | Найти в Creator Store | `rock cliff low poly` / `mountain rock wall` / `rocky cliff face` | ≈ 40×40×20, ≤ 200 частей | ID `A057: …` |
| 7 | A024 | `Train1_Full`: текстура меша растянута, я её убрал (однотонный ржавый). Заменить меш или оставить | P2 | Найти в Creator Store или «оставить» | `london underground train` / `subway train car damaged` | ≈ 106×14,6×10 (три вагона) | ID `A024: …` / «оставить» |
| 8 | A026 | Вагон изнутри | P2 | Найти в Creator Store | `subway train interior` / `metro carriage interior` | ширина ≤ 10, ≤ 3000 частей | ID `A026: …` |
| 9 | A019 | Аварийные красные светильники и трубки (корпуса уже есть) | P2 | Я сам: `generate_mesh` — «да» | `red emergency wall light, round, metal housing, abandoned post-apocalyptic subway, realistic, grimy, desaturated grey and rust tones, low-poly game asset` | ≈ 1×1×1 | ничего |
| 10 | A017 | Урна (`ServerStorage.AssetStaging.A017_Bin`) | P2 | «Да» на `Baker.bake` и замену цилиндров в `DressMetro` | — | 1,5×2,2×1,5 | «да» |
| 11 | A034, A044 | Граффити и плакаты без текста | P2 | «Да, генерируй» (`generate_texture`) или PNG | A034: `abstract graffiti tag shapes without letters, spray paint, faded, flat front view`; A044: `old faded propaganda-style poster illustration without any text, torn edges` | декаль ≈ 4×3 | «да» / PNG |
| 12 | A036–A038, A042 | Мусор, лагерь, брошенные вещи, генератор | P2–P3 | Я сам (`generate_mesh`), по одному | промпты — `asset_manifest.md` | см. манифест | ничего |
| 13 | A047–A051 | Звуки метро и двора | P2–P3 | Найти в Creator Store | `subway ambience` / `tunnel wind` / `dripping water` / `night wind outdoor` | зацикленные, тихие | ID `A047: …` |
| 14 | — | Ночь в игре очень тёмная (двор почти чёрный, фонари видны точками). Решение по яркости ночи (`Lighting`) — на стороне игры, не метро | P2 | Решить: оставить или поднять `Ambient`/`Brightness` ночью | — | — | «оставить» / «поднять» |

Пришлите ID списком `A0xx: 123…`.

Выполнено и убрано: турникеты A012 (перекрашены в тёмные, W017); `AmmoCrate_1/2` и `Metro_ZombieSpawn_14` перенесены в `BuildMetro.luau`; W013 (расширение `floor`) — откат не запрошен, остаётся.
Отклонено/не берём: лавки через `generate_procedural_model` (скрипты внутри), плитка через `generate_material` (A002 — швы деталями).
