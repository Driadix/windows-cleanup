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
| Run/RunOnce | HKCU + HKLM + WOW6432Node `...\CurrentVersion\Run*` |
| Startup-папки | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` + `$env:ProgramData\...` |
| Задачи | `Get-ScheduledTask` + фильтр `TaskPath -notlike '\Microsoft\Windows\*'` + разворачивать `Actions` + `Get-ScheduledTaskInfo` |
| Службы Auto | `Get-CimInstance Win32_Service \| Where-Object StartMode -eq 'Auto'` |
| Winlogon | `Shell`, `Userinit` |
| StartupApproved | `...\Explorer\StartupApproved\Run` (состояние вкл/выкл) |

**Правило:** каждая запись → кросс-проверка `Test-Path` цели; живые остаются, битые удаляются. Сообщать пользователю найденное (например «битые Opera ×2, Omniroute → удалял»).

## Битые ярлыки (Фаза 8)

Скрипт `scripts/shortcuts.ps1` проходит 4 места: Desktop user+Public, Start Menu user+ProgramData; `.lnk` и `.url`. Битые = `TargetPath` не существует. Живые не трогать. Итог — сосчитать битые/целые в отчёт.
