# Inventory — Фазы 0–2 (окружение, ворота дисков, инвентаризация)

Справочник на требование. Всегда `-LiteralPath`, кодировка логов UTF-8.

## Окружение (Фаза 0)

```powershell
Get-CimInstance Win32_OperatingSystem | Select Caption, BuildNumber          # версия ОС → ветвление
$env:USERPROFILE; whoami                                                     # кириллический профиль
Get-Volume | Where-Object DriveLetter | Select DriveLetter,FileSystemLabel,DriveType,@{n='SizeGB';e={[math]::Round($_.Size/1GB)}},@{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}
$env:TEMP                                                                     # никогда не хардкодить
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
```

## Ворота дисков (Фаза 1)

```powershell
Get-Disk | Get-PhysicalDisk | Select DeviceId,FriendlyName,BusType,@{n='SizeGB';e={[math]::Round($_.Size/1GB)}}  # BusType=USB → съёмный
```

Правила: Removable/Network не трогаем без явного «да»; корзины — только по выбранным дискам; дельты — по выбранным.

## Карта папок и топ файлов

```powershell
# Топ-50 папок по размеру для заданного корня (долго — запускать в фоне)
$root='D:\'
Get-ChildItem -LiteralPath $root -Directory -Force | ForEach-Object {
  $s = (Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  [pscustomobject]@{ Path=$_.FullName; GB=[math]::Round($s/1GB,2) }
} | Sort-Object GB -Descending | Select-Object -First 50 | Out-File -FilePath "$work\dirs_top.txt" -Encoding UTF8

# Топ крупных файлов
Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 50 Length,FullName | Out-File -FilePath "$work\files_top.txt" -Encoding UTF8
```

Обязательные корни для карты: целевые диски, `C:\ProgramData`, `$env:LOCALAPPDATA`, `$env:APPDATA`, корень профиля (со скрытыми).

## Установленные программы (реестр — главный источник)

```powershell
$paths = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $paths -ErrorAction SilentlyContinue |
  Select DisplayName,DisplayVersion,InstallLocation,UninstallString,ProductCode,InstallDate,EstimatedSize |
  Sort DisplayName | Out-File "$work\installed.txt" -Encoding UTF8
```

- HKCU обязателен (per-user Squirrel), WOW6432Node обязателен (32-бит).
- Вывод — **`installed.csv`** (колонки Name/Ver/Hive/Loc/LocExists/Uninst/Code/Date/SizeMB) — делает `scripts/inventory-quick.ps1` (вместе с установщиками, корзинами, кэшами).
- **«Мёртвая запись» = кандидат, а не факт**: `InstallLocation`/`UninstallString` → несуществующий путь. Осторожно: легитимные MSI (VC++ 2012/2013/v14, .NET Runtime) часто держат `InstallLocation` = `C:\ProgramData\Package Cache\{guid}`, который отсутствует при вычищенном кэше установщика — это НЕ сирота. Второй критерий сироты: папка отсутствует И нет живого компонента/антиинсталлера по `UninstallString` И приложения нет в задачах/службах. Решение всегда за пользователем.
- Win11 — дополнительно `winget list`; UWP — `Get-AppxPackage`.
- **Детекция неиспользуемых** (Фаза 10) дополнительно смотрит UserAssist/Prefetch/MuiCache — см. `final-options.md`.

## Установщики (Desktop / Downloads / Documents)

```powershell
@("$env:USERPROFILE\Desktop","$env:USERPROFILE\Downloads","$env:USERPROFILE\Documents") |
  ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Include *.exe,*.msi,*.zip,*.iso,*.rar -ErrorAction SilentlyContinue } |
  Select @{n='GB';e={[math]::Round($_.Length/1GB,2)}},LastWriteTime,FullName | Sort GB -Descending
```

Правило: никогда авто-удалять; только по списку с размером и датой; дубликат инсталлятора можно сократить до одной копии.

**Внимательные точки вне пользовательских папок** (риск, не авто, уточнять у пользователя):
- `C:\Program Files\Microsoft Office\Updates\Download` — кэш обновлений Office C2R (реально ~0,9 ГБ); удаление заставит Office скачать обновления заново, данных не теряет;
- `C:\Windows\Installer\Razer Central` — кэш установщиков Razer (~0,3 ГБ); осторожно (файлы нужны для ремонта Razer, но пересоздаются при переустановке).

## Дубликаты (только кандидаты!)

```powershell
# Группировка по (Length, Name), фильтр >50 МБ, хеш — только кандидатов (не хешируем полмиллиона файлов)
Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
  Where-Object Length -gt 50MB |
  Group-Object Length,Name | Where-Object Count -gt 1 |
  ForEach-Object { $_.Group | Select Length,FullName } | Out-File "$work\dupes.txt" -Encoding UTF8
```

- Файл всегда писать (при пустом результате — маркер `(пусто)`).
- **Системные пути** (WinSxS / `Windows\assembly` (NGEN) / DriverStore / lxss / Edge vs WebView2) — by-design «дубли», выносить в `dupes_system.txt`, не пугать пользователя.
- Итог — **кандидаты**: подтверждение реальности только хешем (SHA-256) по парам из дублей.

## Корзины (по выбранным дискам)

Считать только реальные данные: файлы **`$R*`** в `X:\$Recycle.Bin` (метаданные `$I*` — не считаем). Делает `scripts/inventory-quick.ps1`. Перед очисткой показать размер; очистка — `Clear-RecycleBin -DriveLetter X -Force` для выбранных дисков.

## Прочее для инвентаря

- **Тени (только для внимания)**: `vssadmin list shadowstorage` требует админ — замер в elevated-проходе Фазы 4, а не в Фазу 2 пользовательской сессии; на практике 10%+ диска возможны при лимите UNBOUNDED (в прогоне C: было 16 ГБ).
- **Кэши npm**: проверять ОБА места — `%LOCALAPPDATA%\npm-cache` (актуальный) и `%APPDATA%\npm-cache` (остаток старых версий npm, бывает сотни МБ).
- **Сканы-карты**: `scripts/scan.ps1` — один проход по дереву; корни брать без пересечений (профиль один раз, а не C:\Users + AppData отдельно), рабочая папка исключена.
