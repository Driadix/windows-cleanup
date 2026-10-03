# Deep — Фазы 6–8 (профиль, автозапуски, битые ярлыки)

Справочник на требование. Всё — только «место и мусор», **без проверок безопасности** (см. ADR 0003).

## Профиль и данные (Фаза 6)

Карты размеров: `AppData\Local`, `Roaming`, `LocalLow`, `ProgramData`, корень `$env:USERPROFILE` (включая скрытые `.codex/.bun/.gradle/.nuget/.cache/.dotnet`), `Documents\My Games`, `Saved Games`, `Recent`.

**Не трогать никогда:** `.ssh`, `.aws`, `.azure`, `Cert:\`, Credential Manager, `Favorites`, `Links`, исходники и рабочие каталоги пользователя.

**Кросс-референс «сирота»:** папка профиля ↔ установлено ли приложение (реестр Uninstall + `Test-Path` инсталл-директории) → папки без владельца = кандидаты. Типовые сироты: `AzureFunctionsTools` (от VS), старая `Package Cache`, `Sidekick.WebView2`, `app-*` Squirrel, `VintagestoryData` (сейвы), `CreamInstaller`, `~nsu*.tmp` (NSIS-остатки).

**Сейвы** (LocalLow по студиям, My Games, Saved Games) — категория «спорное» 🔴: отдельный вопрос с риском потери, никогда в общий список мусора.

## Автозапуски всех видов (Фаза 7)

| Источник | Команда/путь |
|---|---|
| Run/RunOnce | HKCU + HKLM + WOW6432Node `...\CurrentVersion\Run` **и `RunOnce`** (все 6 веток) |
| Startup-папки | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` + `$env:ProgramData\...StartUp` |
| Задачи | `Get-ScheduledTask` + фильтр `TaskPath -notlike '\Microsoft\Windows\*'` + разворачивать `Actions` |
| Службы Auto | `Get-CimInstance Win32_Service \| Where-Object StartMode -eq 'Auto'` |
| Winlogon | `Shell`, `Userinit`, `AppSetup`, `VmApplet` (`Shell`/`Userinit` могут содержать несколько путей через запятую — проверять каждый) |
| StartupApproved | `...\Explorer\StartupApproved\{Run,Run32,StartupFolder}` (HKCU+HKLM): 12 байт, первый `0x02`=ВЫКЛ / `0x03`=ВКЛ, байты 4–11 = FILETIME изменения (**нулевой FILETIME печатать датой нельзя** — выйдет 1601-01-01). Сирота = состояние есть, а значения Run/файла Startup уже нет |

**Правило:** показать пользователю **весь список** (не только битые) с предложением на каждую запись: удалить программу целиком / отключить автозапуск (`sc.exe config <svc> start= disabled` · `Disable-ScheduledTask` · снять Run-значение) / оставить. Отчёт строит `scripts/autostart.ps1`. Статусы: голые имена exe (резолвятся через %PATH%) — не битые; PathName служб может содержать двойные `\\` — схлопывать runs 2+ до одного, **но ведущий run оставлять двойным** (UNC `\\srv\share\app.exe`; простое `.Replace('\\','\')` превращало его в `\srv\...` и давало ложный BROKEN); пути с пробелами без аргументов — проверять целиком; shell-/`::{}`-таргеты — валидны.

## Битые ярлыки (Фаза 8)

Скрипт `scripts/shortcuts.ps1` проходит места через **shell-folders** (`[Environment]::GetFolderPath('Desktop'/'CommonDesktopDirectory'/'Programs'/'CommonPrograms')`) + Quick Launch — склейка `$env:USERPROFILE\Desktop` пропускала рабочий стол при OneDrive KFM (Desktop/Documents перенесены в `%USERPROFILE%\OneDrive\...`). `.lnk` и `.url`. Битые = `TargetPath` не существует (цель предварительно раскрывается через `ExpandEnvironmentVariables` — `%windir%\...` иначе давал ложный «битый»). Живые не трогать. Итог — сосчитать битые/целые в отчёт. С `-Remove`: после `Remove-Item` обязательный `Test-Path` — при `SilentlyContinue` catch не срабатывает и заблокированный ярлык записывался бы как `removed`.
