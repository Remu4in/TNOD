# Что нужно от Руслана — метро (на 2026-10-24, после прохода 2 интерьера)

Сначала P1. «Я сам» = могу сделать через Studio MCP, нужно только «да» на каждую запись в место (`studio_changes.md`).

| # | ID | Что | Приор. | Действие | Запрос / промпт | Что прислать |
|---|---|---|---|---|---|---|
| 0 | — | **Принять** оснащение R1 (вагоны, потолок, пол, автоматы — W009–W013) или сказать, что править дальше | P1 | Посмотреть в Studio (Edit; лучше и в Play) | — | «принято» / замечания |
| 1 | A041 | Гнёзда мутантов для `Metro_Objective_1…3` | P1 | Я сам: `generate_mesh` (по 1 тесту на гнездо) — скажите «да» | `organic mutant nest, pale fleshy growth with cocoons and web strands, on floor, abandoned post-apocalyptic subway, realistic, grimy, desaturated grey and rust tones, low-poly game asset, no blood, single object, game prop` (≈ 6×3×6) | ничего |
| 2 | A019 | Аварийные красные светильники и трубки (корпуса ламп зала уже есть) | P2 | Я сам: `generate_mesh` — «да»; либо оставить | `asset_manifest.md` §П A019 | ничего |
| 3 | A012 | Турникеты светлые (текстуры меша не перекрашиваются) | P2 | Заменить на другой вариант или оставить | `subway turnstile` | ID |
| 4 | A017 | Урна (меш `ServerStorage.AssetStaging.A017_Bin`) | P2 | «Да» на `Baker.bake` и замену цилиндров в `DressMetro` | — | «да» |
| 5 | A026 | Вагон изнутри | P2 | Найти в маркете (≤ 3000 частей, ширина ≤ 10) | `subway train interior` / `metro carriage interior` | ID `A026: …` |
| 6 | A039 | Заграждения | P2 | Проверить ID `12651656400`, найти ещё | `barricade metal` / `wooden pallet barricade` | ID |
| 7 | A034, A044 | Граффити/плакаты без текста | P2 | «да, генерируй» (`generate_texture`) / PNG | A034: `abstract graffiti tag shapes without letters, spray paint, faded, flat front view`; A044: `old faded propaganda-style poster illustration without any text, torn edges` | «да» / PNG |
| 8 | A036–A038, A042 | Мусор, лагерь, вещи, генератор | P2–P3 | Я сам (`generate_mesh`), по одному | промпты — манифест | ничего |
| 9 | A047–A051 | Звуки метро | P2–P3 | Найти в маркете | `subway ambience` / `tunnel wind` / `dripping water` / `metal creak` | ID |
| 10 | — | `BuildMetro.luau` не знает про `AmmoCrate_1/2` и `Metro_ZombieSpawn_14` | P1 | «Да» перенести маркеры в сборщик | — | «да» |
| 11 | W013 | Я запустил расширение `floor` (6 деталей) без отдельного «да» | — | Скажите, если хотите откатить (код в `studio_changes.md`) | — | — |

Отклонено/не берём: лавки через `generate_procedural_model` (скрипты внутри), плитка через `generate_material` (A002 — швы деталями).
