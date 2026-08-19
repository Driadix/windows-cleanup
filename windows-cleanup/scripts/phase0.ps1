# phase0.ps1 — контекст и baseline учёта (Фаза 0).
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File phase0.ps1 -Work "D:\путь\рабочей папки"
# или без -Work (создаст Documents\PC-Cleanup\<дата>).
# Пишет: phase0_context.txt + baseline в ledger.csv (для честной дельты в Фазе 10).
param(
    [string]$Work = ''
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')

if (-not $Work) { $Work = New-WorkDir }
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$log = Join-Path $Work 'phase0_context.txt'
$ledger = Init-Ledger -Work $Work

$lines = @()
$lines += '=== ФАЗА 0. КОНТЕКСТ ==='
$lines += ('Время: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$os = Get-CimInstance Win32_OperatingSystem
$lines += ('ОС: ' + $os.Caption + ' | Build ' + $os.BuildNumber)
$lines += ('PS: ' + $PSVersionTable.PSVersion.ToString())
$lines += ('Пользователь: ' + $(whoami) + ' | Профиль: ' + $env:USERPROFILE)
$lines += ('TEMP: ' + $env:TEMP)
$lines += ('Elevated: ' + (Test-Elevated))
# Ранняя диагностика UAC-FAIL: неинтерактивная сессия + не-админ — UAC-подъём через Start-Process -Verb RunAs
# часто МОЛЧА не повышает (процесс остаётся Medium integrity, даже при подтверждённом UAC-промпте).
# Реальный кейс прогона 2026-08-19. Если флаги совпали — предупредим и запишем в observations.
$isInteractive = [Environment]::UserInteractive
if (-not (Test-Elevated) -and -not $isInteractive) {
    $lines += 'UAC-RISK: неинтерактивная сессия + не-админ — Start-Process -Verb RunAs может НЕ повысить права'
    $lines += '  (процесс останется Medium integrity). Если elevated-проход не сработает: перезапусти агента от'
    $lines += '  имени администратора или выполни elevated-команду вручную из админ-консоли (см. run-elevated.ps1).'
    # observe.ps1 использует exit в теле — dot-source его нельзя (exit убьёт и нас), запускаем дочерним процессом
    try {
        $obs = Join-Path $here 'observe.ps1'
        if (Test-Path -LiteralPath $obs) {
            Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','"' + $obs + '"','-Work','"' + $Work + '"','-Level','warn','-Phase','0','-Msg','UAC-RISK: неинтерактивная сессия, не-админ — возможен молчаливый отказ Start-Process -Verb RunAs (кейс 2026-08-19)') -Wait -WindowStyle Hidden
        }
    } catch {}
}
$lines += '--- Диски (Volumes) ---'
$vols = @(Get-Volume | Where-Object DriveLetter)
foreach ($v in $vols) {
    $freeGB = [math]::Round($v.SizeRemaining / 1GB, 2)
    $lines += ('{0}: label="{1}" type={2} размер={3}ГБ свободно={4}ГБ fs={5}' -f $v.DriveLetter, $v.FileSystemLabel, $v.DriveType, [math]::Round($v.Size / 1GB), $freeGB, $v.FileSystem)
}
$lines += '--- Физические диски ---'
try {
    Get-Disk | Get-PhysicalDisk | ForEach-Object {
        $lines += ('dev {0} "{1}" bus={2} {3}ГБ' -f $_.DeviceId, $_.FriendlyName, $_.BusType, [math]::Round($_.Size / 1GB))
    }
} catch { $lines += ('  (не удалось: ' + $_.Exception.Message + ')') }
$lines += ('Рабочая папка: ' + $Work)
$lines | Set-Content -Path $log -Encoding UTF8

# Baseline свободного места в ledger (категория 'baseline', объект '<том>')
foreach ($v in $vols) {
    $freeGB = [math]::Round($v.SizeRemaining / 1GB, 2)
    Write-Ledger -Path $ledger -Phase 'baseline' -Object ("volume " + $v.DriveLetter) -TargetPath ($v.DriveLetter + ':') -SizeBeforeMB ($v.SizeRemaining / 1MB) -Status 'baseline' -RemovedMB 0
}
$lines | ForEach-Object { Write-Output $_ }
Write-Output ("LEDGER: " + $ledger)
