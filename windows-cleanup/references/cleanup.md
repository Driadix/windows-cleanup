# Cleanup — Фазы 4–5 (мусор/кэши + удаление программ)

Справочник на требование. Всё удаление — **группами** через единые функции с `-LiteralPath -Recurse -Force`; после каждого — `Test-Path` → `removed / LOCKED / already gone`.

## Точки мусора и кэша (Фаза 4)

Каждая проверяется на существование перед удалением. Порядок: **user-проход** (всё в AppData/HKCU/корзины) → **elevated-проход** (системные, UAC-батч) → DISM.

| Точка | Путь/команда | Уровень |
|---|---|---|
| TEMP пользователя | `$env:TEMP` (может быть перенаправлен!) | user |
| System Temp | `C:\Windows\Temp` | elevated |
| npm | `npm cache clean --force` | user |
| bun | `bun pm cache rm` | user |
| pip / uv / go / NuGet | `pip cache purge` · `uv cache clean` · `go clean -cache` · NuGet HTTP-cache (`%LOCALAPPDATA%\NuGet\v3-cache`) | user |
| Puppeteer | `~\\.cache\puppeteer` | user |
| PlatformIO | `~\\.platformio\dist`, `~\\.platformio\.cache` | user |
| Браузеры | `User Data\Default\Cache`, `GPUCache`, `Code Cache`, `Service Worker`, `ShaderCache` (Brave/Yandex/Edge) — профиль не трогать | user |
| CrashDumps / D3DSCache / DXCache | `%LOCALAPPDATA%\CrashDumps`, `D3DSCache`, `NVIDIA\DXCache`, `Steam\htmlcache` | user |
| Squirrel-старые | папки `app-x.y.z` и `*-updater` (оставить актуальную версию!) | user |
| Кэши приложений | Discord/Figma/GitHubDesktop `.nupkg`, Steam htmlcache, Razer, vscode-cpptools `ipch`, thumbcache | user |
| System Update | `C:\Windows\SoftwareDistribution\Download` + `DeliveryOptimization` (после `Stop-Service wuauserv,DoSvc`) | elevated |
| Остатки драйверов | `C:\Windows\Dbz*`, `C:\AMD\RyzenMasterExtraction` (takeown при необходимости) | elevated |
| WinSxS | `dism /Online /Cleanup-Image /StartComponentCleanup` (только это, не руками; `/ResetBase` — см. final-options) | elevated |

`thumbcache_*.db` — пересоздаётся сам, но Explorer должен быть закрыт. `Packages` (UWP-data), `Installer` (MSI-кэш), `WinSxS`, `pagefile.sys` — **не руками**.

**Внимательные точки (вне таблицы, риск):**
- `C:\Program Files\Microsoft Office\Updates\Download` — кэш обновлений Office C2R (~0,9 ГБ); удаление = повторная загрузка обновлений, данных не теряет. Как отдельную строку в отчёт (🟡).
- `C:\Windows\Installer\Razer Central` — установочный кэш Razer (~0,3 ГБ); осторожно, пересоздаётся при переустановке.

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
**Правило:** папку не удалять, пока не сверен реестр и не подтверждено, что она не делит каталог с соседями (например `D:\Soft`). После удаления программы возможны битые ярлыки в Старт-меню — отдельно прогнать `scripts/shortcuts.ps1` (дешёвый ре-скан).

## LOCKED-процедура

1. ретрай удаления;
2. `Stop-Process` держателя (или `Stop-Service`), ретрай;
3. остановка SearchIndexer часто не помогает;
4. финал — удаление при перезагрузке: `scripts/pending-delete.ps1` (PendingFileRenameOperations, fill elevated).

## UAC-практика

- Не просим права заранее; перед промптом говорим «сейчас появится окно UAC — подтверди».
- `Start-Process -Verb RunAs -PassThru -Wait`; exit-код — источник истины; лог читаем из файла.
- Всё elevated — в 1–2 прохода за сессию (цель ≤2, потолок 3). Отменённый UAC → пометить, спросить один раз в конце; повторный промпт только по просьбе.
