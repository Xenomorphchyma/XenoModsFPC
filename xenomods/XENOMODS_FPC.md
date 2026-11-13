# XenoModsFPC

Набор модов XenoMods на Free Pascal-порте Space Rangers HD
(`pakompom/SpaceRangersHD_FPC`) и хост плагинов для модов других авторов.
Ветка `xenomodsfpc` этого форка; оригинальные XenoMods и XenoNativeLoader
не изменяются.

## Архитектура

XenoNativeLoader находит машинный код Delphi-сборки `Rangers.exe` по
сигнатурам и патчит его в памяти. FPC-порт — другая программа (другие
раскладка объектов и VMT, LLVM, 64-битные и не-Windows цели), поэтому DLL
для лоадера здесь работать не могут. Вместо этого:

- **Хост плагинов** `source/mods/xeno/XenoPluginHost.pas` — замена
  XenoNativeLoader для FPC. Он загружает `Mods\...\Native\*.XenoPlugin.dll`
  (`.so`) включённых модов и отдаёт им C-API
  (`xenomods/sdk/xeno_fpc_plugin_api.h`): события в точках кода игры, поля
  объектов по имени, скриптовые функции для `ImportedFunction`, INI, лог,
  UI и музыку. EXE не нужно менять под каждый мод. Для авторов модов —
  `xenomods/sdk/README_RU.md`.
- **Точки расширения** в коде игры — вызовы `XenoRaise*` под
  `{$IFDEF XENO_MODS}` в aItem, aKling, aGalaxy, fHangar, GR_Music, GR_Sound,
  fLoad, fPanelRuins и GR_Main.
- **Карта полей** генерируется из исходников:
  `python xenomods/gen_fieldmap.py` (`--check` проверяет актуальность; это
  делает и `package.ps1`). Модуль `XenoFieldMapData` собирается в режиме
  ObjFPC: в Delphi-режиме `@Запись.ПроцедурноеПоле` читает процедуру вместо
  адреса поля.
- **Встроенные Xeno-моды** (`source/mods/xeno/Xeno*.pas`) подписываются на
  те же события, что и внешние плагины (`XenoSubscribe`). Они работают и на
  Android без отдельной сборки `.so` и одновременно проверяют API.
- Мод активен, только когда его папка выбрана в `Mods\ModCFG.txt`.
  Перезапуск после смены набора модов не нужен.

Сборка: символ `XENO_MODS` в `source/mods/NativeMods.inc` (по умолчанию
включён; `DISABLE_XENO_MODS` выключает всё).

## Состояние модов

| Мод | Тип | FPC | Где |
| --- | --- | --- | --- |
| XenoBG, XenoCoalitionBG, XenoStationsBG, XenoPlanets | ресурсы (.pkg) | без изменений | — |
| XenoRangers, XenoRangersOriginalBalance | ресурсы, скрипты | без изменений | — |
| XenoZeroSignalQuest | текстовый квест | без изменений | — |
| XenoCoalitionSupplyLines | скрипт + DLL настроек | встроен | `XenoCoalitionSupplyLines.pas` |
| XenoDomRangers | скрипт + DLL (камуфляж NPC) | встроен | `XenoDomRangers.pas`, событие `Kling.Camouflage` |
| XenoEquipmentInflation | скрипт + DLL (цены TItem) | встроен | `XenoEquipmentInflation.pas`, события `Item.*` |
| XenoHangarPaging | DLL + UI в CFG | встроен | `XenoHangarPaging.pas`, события `Hangar.*` |
| XenoMusicFlow | DLL (смена музыки) | встроен | `XenoMusicFlow.pas`, события `Music.*`, `Sound.VolumeRamp`, `Frame` |
| XenoBigGalaxy: GalaxyGenerator | DLL (55 секторов) | встроен | `XenoBigGalaxy.pas`, события `Galaxy.*` |
| XenoBigGalaxy: NextDay | DLL | режим Compatible — штатное поведение, кода не нужно; Dominator* не перенесены | — |
| XenoScriptHotReload | инструмент автора | не перенесён | — |
| XenoSystemZoom | DLL (масштаб карты системы) | не в релизе | — |
| XenoPBEngineFix | DLL (имя кэша PBEngine) | не нужен | движок роботов в порте не подключается |
| XenoStable (лоадер) | исправления D3D9/окна/фокуса | не нужен | порт работает на SDL2/OKGF |
| XenoStable: AchievementsWithMods | | не нужен | достижения в порте локальные и от модов не зависят |

Отличия от DLL-версий:

- **XenoDomRangers.** Delphi-плагин писал байт `ChameleonLogic` (поле есть
  только у TPlayer) прямо в объект рейнджера по смещению. Здесь логика серии
  хранится в таблице сессий; поля камуфляжа TShip пишутся как раньше и
  попадают в сейв. Мост SolHook не нужен.
- **XenoEquipmentInflation.** Таблица предметов — хэш по адресу. Вместо
  NewInstance/FreeInstance — `TItem.Create`/`Destroy`, затем конец
  `LoadFromBuffer`/`LoadFromBlock` и запись Cost в `SaveToBuffer`.
- **XenoHangarPaging.** Страница заполняется до штатной случайной раскладки,
  которая тогда пропускается (её случайные вызовы сохраняются, чтобы не
  сдвигать RNG). Стрелки — колбэки кнопок из CFG мода, а не перехват WndProc.
- **XenoMusicFlow.** Таймер Win32 заменён событием `Frame`; остаток трека
  оценивается тем же методом по позиции чтения файла.
- **XenoBigGalaxy.** `Constellations.Generator.*` читаются из Lang.dat мода,
  `[RuntimeBases]` — из `Native\XenoGalaxyGenerator.XenoPlugin.ini`. Мост
  SolEngine и тестовая геометрия HexGrid не перенесены.
- Настройки читаются из тех же `Native\*.XenoPlugin.ini`
  (`[Plugin] Enabled=0` отключает мод). Сообщения пишутся в
  `rangers-fpc.log` с подсистемой `xeno`.

## Тесты

`Rangers.exe --xeno-selftest[=ходы]` (`XenoSelfTest.pas`). После главного
меню он проверяет:

- чистую логику модов (случаи из прежних `native_tests.cpp`);
- хост: карту полей, внешний плагин, скриптовый мост;
- генерацию новой игры с выбранными модами и ходы;
- скриптовые библиотеки модов;
- камуфляж DomRangers на настоящем доминаторе;
- ангар с 14 кораблями на настоящем экране;
- живую музыку;
- сохранение и загрузку с инфляцией.

Тест идёт в фоне: окно скрыто и не забирает фокус, звук уходит в пустое
устройство SDL (музыка при этом играет внутри игры, её проверки работают),
окна ошибок не показываются — ошибка пишется в `rangers-fpc.log`, код выхода
ненулевой. `--xeno-visible` показывает окно, диалоги и включает звук.

Отчёт — `<папка пользователя>\xeno_selftest.txt`, код выхода 0 или 1.
Последний прогон: 90 из 90 (тестовая папка `RuntimeTests\FPC_XenoMods`,
включая пример плагина `XenoTests\XenoFpcExample`).

## Установка и упаковка

`xenomods/package.ps1 -Version X -XenoModsZip <XenoMods-*.zip>` собирает:

- `XenoModsFPC-X-win32.zip` для игроков: папка `XenoModsFPC\` (Rangers.exe
  и его DLL) и `Mods\XenoMods\...` без DLL плагинов. Архив распаковывается в
  папку игры; оригинальный Rangers.exe и его okgf.dll не трогаются. EXE в
  подпапке сам находит данные игры уровнем выше (`XenoSelectGameDirectory`),
  `--user-dir=` задаёт отдельную папку сохранений и настроек.
- `XenoModsFPC-SDK-X.zip` для авторов модов: заголовок API, инструкция и
  пример плагина.

Android: код переносим (без Win32-API); APK из этой ветки собирается штатным
`tools/build.py --target=android` на Linux или macOS (WSL).
