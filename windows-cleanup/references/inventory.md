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
- **Мёртвая запись** = InstallLocation/UninstallString → несуществующий путь → кандидат на удаление ключа.
- Win11 — дополнительно `winget list`; UWP — `Get-AppxPackage`.
- **Детекция неиспользуемых** (Фаза 10) дополнительно смотрит UserAssist/Prefetch/MuiCache — см. `final-options.md`.

## Установщики (Desktop / Downloads / Documents)

```powershell
@("$env:USERPROFILE\Desktop","$env:USERPROFILE\Downloads","$env:USERPROFILE\Documents") |
  ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Include *.exe,*.msi,*.zip,*.iso,*.rar -ErrorAction SilentlyContinue } |
  Select @{n='GB';e={[math]::Round($_.Length/1GB,2)}},LastWriteTime,FullName | Sort GB -Descending
```

Правило: никогда авто-удалять; только по списку с размером и датой; дубликат инсталлятора можно сократить до одной копии.

## Дубликаты (только кандидаты!)

```powershell
# Группировка по (Length, Name), фильтр >50 МБ, хеш — только кандидатов (не хешируем полмиллиона файлов)
Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
  Where-Object Length -gt 50MB |
  Group-Object Length,Name | Where-Object Count -gt 1 |
  ForEach-Object { $_.Group | Select Length,FullName } | Out-File "$work\dupes.txt" -Encoding UTF8
```

## Корзины (по выбранным дискам)

```powershell
Clear-RecycleBin -DriveLetter C -Force    # перед этим показать размер: Get-Volume или (New-Object -ComObject Shell.Application)
```
