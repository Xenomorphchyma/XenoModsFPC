# XenoModsFPC Plugin SDK (API 1)

XenoModsFPC — сборка FPC-версии Space Rangers HD со встроенным хостом
плагинов. Он загружает нативные части модов так же, как XenoNativeLoader
делает это для обычной (Delphi) игры, но без патчей машинного кода:

| XenoNativeLoader (Delphi) | XenoModsFPC |
| --- | --- |
| `XenoPlugin_Query` / `XenoPlugin_Initialize` | `XenoFpcPlugin_Query` / `XenoFpcPlugin_Initialize` (+ необязательный `XenoFpcPlugin_Shutdown`) |
| сигнатуры, трамплины, `VirtualProtect` | события: `host->subscribe("Item.Created", ...)` |
| смещения полей (`ship + 0x461`) | `host->fieldInfo("TShip", "ChameleonActive", &info)` |
| экспорт DLL для `ImportedFunction` | `host->registerScriptFunction(...)` |
| `host->configGetInt` и т. п. | то же, строки UTF-8 |
| `XenoNative.log` | `rangers-fpc.log`, подсистема `xeno` |

Заголовок: `xeno_fpc_plugin_api.h`. Пример: `example/XenoFpcExample.cpp`.

## Где лежит плагин

Как и у лоадера:

```text
Mods\<Категория>\<Мод>\
  ModuleInfo.txt
  Native\
    <Мод>.XenoPlugin.dll        (Windows; .XenoPlugin.so на Linux/Android)
    <Мод>.XenoPlugin.ini        (необязательно; [Plugin] Enabled=0 отключает)
```

Плагин загружается, только когда мод включён в менеджере модов, и
выгружается, когда его выключают. Перезапуск игры не нужен. DLL без
`XenoFpcPlugin_Initialize` (например, плагин только для XenoNativeLoader)
пропускается с предупреждением в логе, игра не падает.

**Одна DLL для обеих версий игры.** Если экспортировать и `XenoPlugin_*`, и
`XenoFpcPlugin_*`, одна и та же DLL работает и с XenoNativeLoader, и с
XenoModsFPC. Общую логику мода оставьте общей, разными будут только
«точки входа»: сигнатуры для Delphi-версии и события для FPC.

## Как перенести мод с XenoNativeLoader

1. Отделите логику мода от слоя хуков (как `price_math.cpp`,
   `generator_plan.cpp` у XenoMods). Она переносится без изменений.
2. Каждый хук замените событием. Если в коде игры нужного места нет,
   напишите автору XenoModsFPC: точку добавят в API для всех, а не под
   конкретный мод.
3. Каждое смещение поля запросите через `fieldInfo` один раз в
   `Initialize` и кешируйте. Унаследованные поля находятся и по классу
   потомка (`TRanger` → поля `TShip`). Таблица генерируется из исходников
   при сборке EXE, поэтому плагин не ломается при обновлении игры.
4. Скриптовые функции регистрируйте с той же сигнатурой, что в блоке
   `ScriptLibs` CFG мода. Имя библиотеки — имя файла из `Path` без `.dll`.
   CFG и скрипты мода менять не нужно.
5. Объекты из скриптов (`dword`) — указатели на объекты игры. Перед
   использованием проверяйте `isLiveObject` и `isInstanceOf`.

## События API 1

| Событие | Когда | Что можно изменить |
| --- | --- | --- |
| `Frame` | каждый проход главного цикла | — |
| `Galaxy.Created` | создание `TGalaxy` (новая игра и загрузка) | `sectorCount` |
| `Galaxy.PlanStar` | выбор сектора звезды при генерации | `sector` |
| `Galaxy.LayoutDone` | после каждой попытки раскладки секторов | `done` |
| `Galaxy.ContourNoEar` | обрезка скрытого сектора зашла в тупик | `removeVertex` |
| `Galaxy.StationSpawning` | этап 8 нового дня | `run` |
| `Item.Created`, `Item.Destroyed`, `Item.Loaded` | жизненный цикл `TItem` (могут прийти из потока хода) | — |
| `Item.SaveCost` | `TItem.SaveToBuffer` пишет цену | `cost` |
| `Kling.Camouflage` | доминатор проверяет камуфляж не игрока | `handled`, `effective` |
| `Hangar.Opened`, `Hangar.Closed` | экран ангара | — |
| `Hangar.Refresh` | заполнение мест 1..8 (каждый кадр) | `handled` |
| `Hangar.Key` | клавиша в ангаре | `handled` |
| `Music.PlayCategory` | смена музыки места | `skip` |
| `Music.StopImmediately`, `Music.PlaceFade` | остановка и затухание музыки | `keep` |
| `Sound.VolumeRamp` | плавное изменение громкости (поток звука) | `step` |

Подписчики вызываются по порядку: сначала встроенные моды XenoModsFPC, потом
плагины в порядке модов. Исключение в обработчике записывается в лог и не
роняет игру.

## Сборка

Windows, 32-битная игра (как Steam-версия):

```bash
i686-w64-mingw32-clang++ -std=c++17 -O2 -shared -static -o MyMod.XenoPlugin.dll MyMod.cpp
```

Подойдёт и MSVC (`cl /LD`, x86): все функции API — `cdecl`. Для 64-битной
сборки игры нужна x86_64-DLL, для Linux/Android — `.so` под нужную
архитектуру (`-fPIC -shared`, Android NDK для arm64).

## Проверка

`Rangers.exe --xeno-selftest` после загрузки главного меню прогоняет тесты
встроенных модов и хоста, генерирует новую игру с выбранными модами,
выполняет ходы, сохранение и загрузку и выходит с кодом 0 или 1. Отчёт —
`xeno_selftest.txt` в папке пользователя. Если включён мод с примером
плагина, проверяются и его загрузка и скриптовая функция.
