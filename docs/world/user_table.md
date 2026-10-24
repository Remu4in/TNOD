# Что нужно от Руслана — метро (на 2026-10-24)

Сначала P1. «Я сам» = могу сделать через Studio MCP, нужно только «да» на каждую запись в место (`studio_changes.md`).

| # | ID | Что | Приор. | Действие | Запрос / промпт | Что прислать |
|---|---|---|---|---|---|---|
| 1 | A041 | Гнёзда мутантов для `Metro_Objective_1…3` | P1 | Я сам: `generate_mesh` (по 1 тесту на гнездо) — скажите «да» | `organic mutant nest, pale fleshy growth with cocoons and web strands, on floor, abandoned post-apocalyptic subway, realistic, grimy, desaturated grey and rust tones, low-poly game asset, no blood, single object, game prop` (≈ 6×3×6) | ничего; посмотрите снимок и решите |
| 2 | A001, A003 | Плитка пола, грязный бетон | P1 | Решить: оставляем `Marble` + швы-детали (как A002 на стенах) или пробуем ComfyUI локально | A003: `seamless tileable grimy concrete wall, water stains, soot, cracks, flat orthographic, even lighting, desaturated grey` | «оставить» / установленный ComfyUI |
| 3 | A019 | Светильники (аварийный красный, в сетке, трубка) | P1 | Я сам: `generate_mesh` — «да»; либо оставить Neon-бруски | см. `asset_manifest.md` §П A019 | ничего |
| 4 | A017 | Урна (меш готов: `Workspace.WF_Test.A017_Bin`) | P2 | «Да» на `Baker.bake` в `ServerStorage.Assets.Metro` и замену цилиндров в `DressMetro` | — | «да» / «нет» |
| 5 | A026 | Вагон изнутри (лут, бой в вагоне) | P2 | Найти в маркете (≤ 3000 частей, ширина ≤ 10) или взять геометрию из `Train with Zombie` (12 скриптов — чистка) | `subway train interior` / `train car interior` / `metro carriage interior` | ID списком `A026: 123…` |
| 6 | A039 | Заграждения (металл, мешки, паллеты) | P2 | Проверить ID `12651656400` (мешки) через `asset-vetting` и найти ещё | `barricade metal` / `wooden pallet barricade` | ID |
| 7 | A034, A044 | Граффити без текста, плакаты без текста | P2 | Решить, нужны ли (сейчас пустые щиты); если да — картинки: Roblox `generate_texture` (я сам) или свои файлы | A034: `abstract graffiti tag shapes without letters, spray paint, faded, flat front view`; A044: `old faded propaganda-style poster illustration without any text, torn edges` | «да, генерируй» / PNG в `art/incoming/` |
| 8 | A042, A036, A037, A038 | Генератор/канистра, мусор, лагерь, брошенные вещи | P2–P3 | Я сам (`generate_mesh`) по промптам манифеста — по одному, с вашим «да» | промпты — `asset_manifest.md` §П A036–A038, A042 | ничего |
| 9 | A027 | Рельсы (кандидат `572434010`, `Vetter`: clean) | P3 | «Да» на приём: перенос из `AssetStaging` в библиотеку | — | «да» / «нет» |
| 10 | A031 | Низкий локомотив ≤ 10 студов | P3 | Найти в маркете (прежний отклонён — высота 17) или генерировать | `diesel locomotive` / `locomotive` | ID |
| 11 | A047–A051 | Звуки: гул, ветер тоннеля, капли, скрип, далёкий поезд, лампы | P2–P3 | Найти звуки (в маркете) | `subway ambience` / `tunnel wind` / `dripping water` / `metal creak` / `distant train rumble` / `flickering light buzz` | ID звуков |
| 12 | — | `BuildMetro.luau` не знает про `AmmoCrate_1/2` и `Metro_ZombieSpawn_14` (в месте есть) | P1 | «Да» перенести маркеры в сборщик (позиции читаю из места) | — | «да» |

Отклонено/не берём: лавки через `generate_procedural_model` (скрипты внутри), плитка через `generate_material` (A002 — швы деталями).
