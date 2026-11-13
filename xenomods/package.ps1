#requires -Version 5.1
<#
.SYNOPSIS
Packs XenoModsFPC: this fork's Windows build plus the XenoMods mod folders.
.DESCRIPTION
The archive unpacks into the game folder:
  XenoModsFPC\Rangers.exe and its DLLs  - the FPC game with the Xeno natives built in;
  Mods\XenoMods\...                     - the same mod folders as the Delphi release.
The original Rangers.exe and its okgf.dll stay untouched. Rangers.exe in the
subfolder finds the game data in its parent folder by itself.
Plugin DLLs, XenoNativeLoader and mods without an FPC port are left out;
Native\*.ini stay because the built-in ports read them.
.EXAMPLE
python tools/build.py --release --target=win32
powershell -File xenomods/package.ps1 -Version 1.0.0 -XenoModsZip XenoMods-1.1.0.zip
#>
param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$XenoModsZip,
    [ValidateSet('win32', 'win64')] [string]$Target = 'win32',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root '.local\xenomodsfpc' }
$cpu = if ($Target -eq 'win32') { 'win32-i386' } else { 'win64-x86_64' }
$bin = Join-Path $root ".local\$cpu\release\bin"
if (-not (Test-Path (Join-Path $bin 'Rangers.exe'))) {
    throw "Build first: python tools/build.py --release --target=$Target"
}
# The plugin host's field map must match the sources the EXE was built from.
& python (Join-Path $PSScriptRoot 'gen_fieldmap.py') --check
if ($LASTEXITCODE -ne 0) { throw 'XenoFieldMap is out of date: run python xenomods/gen_fieldmap.py and rebuild.' }
# Mods whose native part has no FPC port or is not needed there.
$excludedMods = @('XenoPBEngineFix', 'XenoScriptHotReload', 'XenoSystemZoom')

$stage = Join-Path $OutputDirectory "stage-$Version"
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$gameFolder = Join-Path $stage 'XenoModsFPC'
New-Item -ItemType Directory -Force $gameFolder | Out-Null
# Rangers.exe, the DLLs it imports and the license notices, chosen like the
# port's own releases. xvidcore.dll comes from the game folder at runtime.
if (-not $env:LLVM_MINGW) {
    $toolchain = Get-ChildItem (Join-Path $root '.local\windows-tools') -Directory -Recurse -Filter 'llvm-mingw-*-ucrt-*' |
        Select-Object -First 1
    if ($toolchain) { $env:LLVM_MINGW = $toolchain.FullName }
}
& python (Join-Path $PSScriptRoot 'release_files.py') $gameFolder $Target
if ($LASTEXITCODE -ne 0) { throw 'Collecting the release files failed.' }
$commit = (& git -C $root rev-parse HEAD).Trim()
$dirty = if (& git -C $root status --porcelain) { ' (uncommitted changes)' } else { '' }
Set-Content -Path (Join-Path $gameFolder 'build.txt') -Encoding ASCII -Value @(
    "XenoModsFPC $Version ($Target)", "Commit: $commit$dirty", "Built: $((Get-Item (Join-Path $bin 'Rangers.exe')).LastWriteTimeUtc.ToString('u'))"
)

$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $XenoModsZip))
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if ($name -eq 'LICENSE') {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $gameFolder 'licenses\XenoMods.txt'), $true)
            continue
        }
        if (-not $name.StartsWith('Mods/XenoMods/') -or $name.EndsWith('/')) { continue }
        $mod = $name.Split('/')[2]
        if ($mod -in $excludedMods) { continue }
        if ($name.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $destination = Join-Path $stage ($name -replace '/', '\')
        New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
    }
}
finally {
    $zip.Dispose()
}

$readme = @"
XenoModsFPC $Version
https://github.com/Xenomorphchyma/XenoModsFPC

Моды XenoMods для Free Pascal-версии Space Rangers HD: A War Apart
(https://github.com/pakompom/SpaceRangersHD_FPC). Нативные части модов
встроены в Rangers.exe из этого архива, XenoNativeLoader не нужен.

Нужно: установленная Space Rangers HD: A War Apart (Steam или GOG).

Установка
1. Распакуйте архив в папку с игрой, где лежит Rangers.exe.
   Появятся папка XenoModsFPC и моды в Mods\XenoMods.
   Оригинальный Rangers.exe и его файлы не заменяются.
2. Запускайте XenoModsFPC\Rangers.exe (удобно сделать ярлык).
   Обычный Rangers.exe и Steam по-прежнему запускают обычную игру.
3. В меню модов включите нужные моды из категории XenoMods и начните
   новую игру. Перезапуск после включения модов не нужен.
   Для XenoCoalitionSupplyLines включите также UtilityFunctionsPack.

Удаление: удалите папки XenoModsFPC и Mods\XenoMods.

Важно
- Сохранения и настройки лежат в Документы\SpaceRangersHD, как у обычной
  игры. Перед первым запуском сделайте копию сохранений. Отдельная папка:
  XenoModsFPC\Rangers.exe --user-dir="D:\Путь\к\папке".
- Планетарные бои в FPC-версии пока засчитываются победой автоматически.
- Лог: rangers-fpc.log в папке сохранений. Приложите его к сообщению об ошибке.
- Настройки модов: Mods\XenoMods\<мод>\Native\*.XenoPlugin.ini.
  После изменения перезапустите игру.

Лицензии: XenoModsFPC\LICENSE, NOTICE.md и папка licenses.
"@
[IO.File]::WriteAllText((Join-Path $stage 'XenoModsFPC\README_RU.txt'), $readme, (New-Object Text.UTF8Encoding $true))

$archive = Join-Path $OutputDirectory "XenoModsFPC-$Version-$Target.zip"
if (Test-Path $archive) { Remove-Item -LiteralPath $archive -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive)
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path "$archive.sha256" -Value "$hash  $(Split-Path $archive -Leaf)" -Encoding ASCII
Write-Host "Created $archive"

# Plugin SDK for mod authors: header, documentation and the example plugin.
$sdkRoot = Join-Path $OutputDirectory "sdk-$Version"
$sdkStage = Join-Path $sdkRoot 'XenoModsFPC-SDK'
if (Test-Path $sdkRoot) { Remove-Item -LiteralPath $sdkRoot -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $sdkStage 'example') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'sdk\xeno_fpc_plugin_api.h'), (Join-Path $PSScriptRoot 'sdk\README_RU.md'), (Join-Path $PSScriptRoot 'sdk\LICENSE') $sdkStage
Copy-Item (Join-Path $PSScriptRoot 'sdk\example\XenoFpcExample.cpp') (Join-Path $sdkStage 'example')
# Names of every hookable routine of this build (written by gen_hooks.py).
$hookList = Join-Path $root ".local\$cpu\release\xenohooks\XenoHooks.txt"
if (-not (Test-Path $hookList)) { throw "No hook list: build with hooks first (XENO_HOOKS must not be 0)." }
Copy-Item $hookList $sdkStage
$sdkArchive = Join-Path $OutputDirectory "XenoModsFPC-SDK-$Version.zip"
if (Test-Path $sdkArchive) { Remove-Item -LiteralPath $sdkArchive -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($sdkRoot, $sdkArchive)
Write-Host "Created $sdkArchive"
