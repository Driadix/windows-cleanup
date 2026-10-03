# Cleanup — Фазы 4–5 (мусор/кэши + удаление программ)

Справочник на требование. Всё удаление — **группами** через единые функции с `-LiteralPath -Recurse -Force`; после каждого — `Test-Path` → `removed / LOCKED / already gone`.

## Точки мусора и кэша (Фаза 4)

Каждая проверяется на существование перед удалением. Порядок: **user-проход** (всё в AppData/HKCU/корзины) → **elevated-проход** (системные, UAC-батч) → DISM.

| Точка | Путь/команда | Уровень |
|---|---|---|
| TEMP пользователя | `$env:TEMP` (может быть перенаправлен!) | user |
| System Temp | `$env:SystemRoot\Temp` | elevated |
| System Temp (Win11 24H2+) | `$env:SystemRoot\SystemTemp` — только при `Test-Path` (на Win10 отсутствует) | elevated |
| npm | `npm cache clean --force` | user |
| bun | `bun pm cache rm` | user |
| pip / uv / go / NuGet | `pip cache purge` · `uv cache clean` · `go clean -cache` (`$env:LOCALAPPDATA\go-build`) · NuGet HTTP-cache (`$env:LOCALAPPDATA\NuGet\v3-cache`) | user |
| Puppeteer | `~\.cache\puppeteer` | user |
| PlatformIO | `~\.platformio\dist`, `~\.platformio\.cache` | user |
| Браузеры | `User Data\{Default,Profile *}\{Cache,Code Cache,GPUCache,ShaderCache,Service Worker}` — Chrome/Edge/Brave/Yandex/Opera/Opera GX/Vivaldi; Firefox: `Profiles\*\cache2` + `startupCache`. Профиль (закладки/пароли) не трогать | user |
| GPU-шейдерные кэши | `$env:LOCALAPPDATA\NVIDIA\DXCache`, `...\NVIDIA\GLCache`, `...\AMD\DxCache`, `...\AMD\GLCache`, `$env:LOCALAPPDATA\D3DSCache` — пересоздаются сами | user |
| CrashDumps / WER (user) | `$env:LOCALAPPDATA\CrashDumps`, `$env:LOCALAPPDATA\Microsoft\Windows\WER\{ReportQueue,ReportArchive,Temp}` | user |
| Steam | `$env:LOCALAPPDATA\Steam\htmlcache`, `...\Steam\shadercache` | user |
| Discord / VS Code | `$env:APPDATA\discord\Cache` + `Code Cache`; `$env:APPDATA\Code\{Cache,CachedData,CachedExtensionVSIXs,logs}` | user |
| INetCache / thumbcache | `$env:LOCALAPPDATA\Microsoft\Windows\INetCache`; `...\Explorer\thumbcache_*.db` + `iconcache_*.db` (нужен закрытый Explorer) | user |
| Squirrel-старые | папки `app-x.y.z` и `*-updater` (оставить актуальную версию!) | user |
| System Update | `$env:SystemRoot\SoftwareDistribution\Download` + `\DataStore` (БД/история обновлений — сбрасывает историю, данных не теряет; отдельная строка в отчёте) + `$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization` (после `Stop-Service wuauserv,DoSvc,BITS`; по завершении прохода — вернуть службы!) | elevated |
| Дампы/логи системы | `$env:SystemRoot\MEMORY.DMP`, `$env:SystemRoot\Minidump\*.dmp`, `$env:SystemRoot\LiveKernelReports`, `$env:SystemRoot\Logs\CBS`, `$env:ProgramData\Microsoft\Windows\WER` | elevated |
| Кэш шрифтов | `$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache` (после `Stop-Service FontCache`) | elevated |
| Остатки обновлений ОС | `$env:SystemDrive\$WINDOWS.~BT`, `\$GetCurrent`, `\$WinREAgent`, `\$SysReset`, `\Windows.old` (**Windows.old — отдельное согласие: убирает откат на прежнюю версию ОС**, флаг `-WindowsOld` у `elevated-cleanup.ps1`) | elevated |
| Остатки драйверов | `$env:SystemRoot\Dbz*`, `$env:SystemDrive\AMD\RyzenMasterExtraction` (takeown при необходимости) | elevated |
| WinSxS | `dism /Online /Cleanup-Image /StartComponentCleanup` (только это, не руками; `/ResetBase` — см. final-options) | elevated |

`thumbcache_*.db` — пересоздаётся сам, но Explorer должен быть закрыт. `Packages` (UWP-data целиком), `Installer` (MSI-кэш целиком), `WinSxS`, `pagefile.sys`, `ProgramData\Package Cache` — **не руками** (Package Cache ломает ремонт/удаление приложений; из него допустимо только показывать размер как информацию). `%LOCALAPPDATA%\Packages\*\TempState` — per-app temp UWP, безопасен точечно. Win11: кэши Copilot/Recall/Windows Backup под `Packages\Microsoft.Copilot_*` — только при `Test-Path`.

**Внимательные точки (вне таблицы, риск):**
- `$env:ProgramFiles\Microsoft Office\Updates\Download` — кэш обновлений Office C2R (~0,9 ГБ); удаление = повторная загрузка обновлений, данных не теряет. Как отдельную строку в отчёт (🟡). Рядом: `$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache` (сотни МБ).
- `$env:SystemRoot\Installer\<вендор>` (напр. Razer Central) — установочный кэш (~0,3 ГБ); осторожно, нужен для ремонта, пересоздаётся при переустановке.

## Таблица удаления по типам софта (Фаза 5)

| Тип | Команда | Примеры/флаг |
|---|---|---|
| MSI | `msiexec /x {GUID} /qn /norestart` | 240–300 с таймаут |
| Inno Setup | `unins000.exe /SILENT` | EaseUS, PyCharm, Nova |
| NSIS | `Uninstall.exe /S` | vesktop, Legcord |
| Squirrel | `Update.exe --uninstall -s` | Figma, GitHubDesktop, Wand; Sidekick: `--silent` |
| InstallShield | `Support\Uninstall.exe` | редко |
| UWP | `Remove-AppxPackage` | Store-приложения |
| Portable | папка + ярлыки + реестр | me3, NetCracker |
| Steam-хвост | удалить `appmanifest_<id>.acf` + `steamapps\common\<игра>` без манифеста | манифеста нет → только папка |
| WSL | `wsl --unregister <дистро>` (без админа!) + vhdx | Ubuntu, Ubuntu-22.04 |
| LocalDB | `sqllocaldb stop/delete MSSQLLocalDB` | — |
| Служба-сирота | `Stop-Service` + `sc.exe delete` + папку | EaseUS UPDATE SERVICE |
| Драйвер | `pnputil /delete-driver oemXX.inf /uninstall` | только осторожно, см. final-options |

Общее: остановить процессы и службы ДО удаления; незапускаемые приложения — сначала `Stop-Process`; тихий инсталлятор с «MISSING» при уже удалённой папке — не ошибка, чистим реестр. **Перед каждым антинсталлером предупреждать пользователя**, что может открыться окно деинсталлятора (не все Inno уважают `/VERYSILENT`, некоторые ждут ручного щелчка) — это нормальное поведение программы, а не скилла. **Не верить exit-коду**: после удаления обязательно `scripts/residue-check.ps1` (процессы → службы → задачи → Run → ярлыки → папки → реестр). Таймауты: MSI 240–300 с, elevated-батч 30–50 мин.

## Чек-лист остатков ПОСЛЕ удаления

Процессы → службы → задачи → Run-ключи → ярлыки → папки (PF/PF(x86)/AppData/ProgramData/свои каталоги) → реестр (HKLM+WOW6432+HKCU Uninstall + ключи приложения).
**Правило:** папку не удалять, пока не сверен реестр и не подтверждено, что она не делит каталог с соседями (например общий каталог `D:\Soft` — `residue-check.ps1` сам помечает его «ОБЩИЙ КАТАЛОГ» и не считает остатком). После удаления программы возможны битые ярлыки в Старт-меню — отдельно прогнать `scripts/shortcuts.ps1` (дешёвый ре-скан).

## LOCKED-процедура

1. ретрай удаления;
2. `Stop-Process` держателя (или `Stop-Service`), ретрай;
3. остановка SearchIndexer часто не помогает;
4. финал — удаление при перезагрузке: `scripts/pending-delete.ps1` (PendingFileRenameOperations, fill elevated).

## UAC-практика

- Не просим права заранее; перед промптом говорим «сейчас появится окно UAC — подтверди».
- `Start-Process -Verb RunAs -PassThru -Wait`; exit-код — источник истины; лог читаем из файла.
- Всё elevated — в 1–2 прохода за сессию (цель ≤2, потолок 3). Отменённый UAC → пометить, спросить один раз в конце; повторный промпт только по просьбе.
