---
name: asset-vetting
description: Проверка ассетов Creator Store перед использованием в «Ночи мертвецов» — скрипты, вредоносные сигнатуры, размер, число частей. Использовать при каждом новом ID ассета, который прислал Руслан, и перед вставкой любой модели в Studio.
---

# Проверка ассета (обязательна)

Ассеты из Creator Store могут содержать скрипты-вредоносы. 2026-10-18 в пяти ассетах Руслана нашли Studio-only вредонос (`Runtime` + `ScreenBuilder`, вложены в `Weld`/`Decal`/`Part`, при Play в Studio показывает окно с «командой» для копирования). Поэтому:

0. **Новые ID:** `LoadAsset` отвечает «User is not authorized» для ассетов, которых нет у аккаунта. Сначала `insert_asset` (Edit-режим, скрипты не запускаются), затем `require(ServerStorage.Tools.Vetter).vet(id)` / `.line(id, r)` (в репозитории логика описана ниже), потом немедленно перенести вставленную модель в `ServerStorage.AssetStaging`. Ассеты под автором «Roblox» с пробелами/невидимыми символами в имени — особенно подозрительны (12 из 13 заражены).
1. **Не вставлять модель в Workspace для проверки.** Грузить отдельно: `InsertService:LoadAsset(id)` в `execute_luau` (Edit). Скрипты при этом не запускаются; результат не парентить, в конце `Destroy()`.
   Если `LoadAsset` отвечает «User is not authorized» — вставить через `insert_asset`, сразу проверить и перенести в `ServerStorage.AssetStaging`.
2. **Считать:** части (`BasePart`), `MeshPart`, `LuaSourceContainer`, `Humanoid`, `Animation`, габариты (`GetBoundingBox`), имена скриптов.
3. **Сигнатуры в `Source` каждого скрипта (lower-case):** `require(число)`, `loadstring`, `getfenv/setfenv`, `HttpService`, `InsertService`, `MarketplaceService`, `TeleportService`, `:Kick(`, `string.char`, `\x..\x..`, `IsStudio` вместе со `scrambled`/`payload`/`overlay window`/`code sample`; скрипты с именами `Runtime`, `ScreenBuilder`; скрипты длиннее 20 000 знаков без видимой причины; нечитаемый `Source`.
3b. **Признаки обфускации и скрытых носителей (усиленная проверка, 2026-10-18):**
   - длинные строки-«данные» без пробелов (`[A-Za-z0-9+/=]{200,}`, base64), много `\ddd`/`\x..` подряд, `string.char`/`string.reverse`/`string.byte` в цикле, `utf8.char`;
   - доступ через строки: `game["…"]`, `getfenv()[…]`, `_G`/`shared`, склейка имён сервисов, `Instance.new("Script"…)` и запись в `.Source`, `debug.*`, `coroutine.wrap(loadstring…)`, `require` от числа или от модуля по строке;
   - `RemoteEvent`/`RemoteFunction` внутри ассета, `BindableEvent`, сетевые вызовы, `:Kick(`, `Teleport*`, `DataStore*`, `MarketplaceService`/`PromptPurchase`, `GroupService`, `HttpService`;
   - скрипты внутри `Weld`, `Decal`, `Part`, `Attachment`, `Sound` и прочих необычных родителях, скрипты в `Configuration`, цепочки вложенных скриптов, имена `Runtime`, `ScreenBuilder`, `Loader`, `Core`, `Bootstrap`, `Require`;
   - большие `StringValue`/`BinaryStringValue`, `Configuration` с данными;
   - `RunService:IsStudio()` как условие запуска (вредоносы стреляют только в Studio);
   - скрипты, при запуске которых что-то показывают пользователю (`ScreenGui`, «окно», «команда», «копировать», `clipboard`) — вредонос по умолчанию.
   - **Семейство №2 (в кафе `71270377535225`):** скрипты `Hierarchy`, `Layout`, `Type`, `EasyConfiguration` внутри `MeshPart`, комментарий «Prevent Lag», `IsStudio() → return` (молчит в Studio, работает в игре), `c:byte()`-кодирование, `root.MarketplaceService`, `root['JobId']`. Загрузчик чужого кода.
   Любое срабатывание → карантин, читаем скрипт вручную; сомневаемся — не используем.
3c. **Карантин:** ассет проверяется повторно перед выходом из `AssetStaging` в карту. В проект идёт только геометрия/анимации: **все** `LuaSourceContainer` и большие строковые значения вычищаются кодом, после чистки — повторное сканирование (должно быть 0). Playtest с ассетами в Workspace — только после этого.
4. **Решение:**
   - нет скриптов → можно брать;
   - скрипты обычные (двери, анимации) → брать только геометрию и анимации, **логику писать свою** в `src/`;
   - есть вредонос → никогда не запускать; геометрию можно использовать только после удаления **всех** `LuaSourceContainer` (и больших `StringValue`/`BinaryStringValue`); сообщить Руслану, предложить пожаловаться на ассет.
5. **Хранение:** непроверенные и «сырые» ассеты лежат в `ServerStorage.AssetStaging` (скрипты там не работают). В `Workspace` ассеты не оставлять.
6. **Запись:** каждый использованный ассет — в `docs/assets_ledger.md` (ID, автор, дата, что взято, что вычищено) и в `docs/asset_plan.md` (статус).

## Заготовка проверки (Edit, `execute_luau`)

```lua
local IS = game:GetService("InsertService")
local PAT = {{"require(число)","require%s*%(%s*%d"},{"loadstring","loadstring"},{"get/setfenv","[gs]etfenv"},{"HttpService","HttpService"},{"InsertService","InsertService"},{"Marketplace","MarketplaceService"},{"Teleport","TeleportService"},{"Kick",":Kick%("},{"string.char","string%.char"},{"hex","\\x%x%x\\x%x%x"}}
for _, id in ids do
  local ok, res = pcall(function() return IS:LoadAsset(id) end)
  -- перебрать res:GetDescendants(): BasePart / LuaSourceContainer (Source) / Humanoid / Animation
  -- помнить про IsStudio+scrambled/payload и имена Runtime/ScreenBuilder
  res:Destroy()
  task.wait(0.2)
end
```
