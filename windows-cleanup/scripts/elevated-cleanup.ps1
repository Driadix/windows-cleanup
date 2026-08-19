# elevated-cleanup.ps1 — системный ELEVATED-проход (запускать через run-elevated.ps1 или Start-Process -Verb RunAs).
# Чистит: Windows\Temp, SoftwareDistribution (Download+DataStore), DeliveryOptimization,
#          $WINDOWS.~BT / $GetCurrent / $WinREAgent, ретраит -Extra (LOCKED из user-прохода), DISM (флаг -Dism).
# Требует администратора. Логи/лидгер пишет в -Work.
# Использование (elevated):
#   run-elevated.ps1 -Script "...\elevated-cleanup.ps1" -Args @('-Work','D:\путь','-Dism','-Extra','C:\file.dat')
param(
    [Parameter(Mandatory=$true)][string]$Work,
    [switch]$Dism,
    [string[]]$Extra = @()
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$log = Join-Path $Work 'elevated_cleanup.log'
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
# Первая строка лога — фактический уровень прав ПРОЦЕССА (в сессиях агентов UAC-подъём может молча не
# сработать: процесс остаётся Medium integrity даже после подтверждения — реальный кейс 2026-08-19).
# run-elevated.ps1 читает эту строку после -Wait и, если False, честно сообщает, что elevated-проход
# НЕ выполнялся, и советует перезапустить агента от админа (см. run-elevated.ps1).
Add-Content -Path $log -Value ("elevated: " + (Test-Elevated)) -Encoding UTF8
$ledger = Init-Ledger -Work $Work
$script:totalMB = 0.0

function Write-LogAndLedger($Object, $Path, $Status, $BeforeMB, $AfterMB, $RemovedMB) {
    $line = "{0}`t{1}`t{2} МБ`tбыло {3} МБ`tосталось {4} МБ" -f $Object, $Status, [math]::Round($RemovedMB,1), [math]::Round($BeforeMB,1), [math]::Round($AfterMB,1)
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Ledger -Path $ledger -Phase 'elevated' -Object $Object -TargetPath $Path -SizeBeforeMB ([math]::Round($BeforeMB,1)) -SizeAfterMB ([math]::Round($AfterMB,1)) -Status $Status -RemovedMB ([math]::Round($RemovedMB,1))
    $script:totalMB += $RemovedMB
}

foreach ($svc in @('wuauserv','DoSvc','BITS')) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}

# --- содержимое папок ---
foreach ($t in @(
    @{ O='Windows\Temp'; P='C:\Windows\Temp' },
    @{ O='SoftwareDistribution\Download'; P='C:\Windows\SoftwareDistribution\Download' },
    @{ O='SoftwareDistribution\DataStore'; P='C:\Windows\SoftwareDistribution\DataStore' },
    @{ O='DeliveryOptimization (NetworkSvc)'; P='C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization' }
)) {
    $beforeMB = (Get-SizeBytes -Path $t.P) / 1MB
    $r = Remove-Contents -Path $t.P
    $afterMB = $r.RemainsBytes / 1MB
    $remMB = ($beforeMB - $afterMB)
    if ($remMB -lt 0.001) { $remMB = 0 }
    Write-LogAndLedger $t.O $t.P $r.Status $beforeMB $afterMB $remMB
}

# --- системные остатки (папки целиком) ---
foreach ($p in @('C:\$WINDOWS.~BT','C:\$GetCurrent','C:\$WinREAgent')) {
    $beforeMB = (Get-SizeBytes -Path $p) / 1MB
    $r = Remove-Target -Path $p
    Write-LogAndLedger $p $p $r.Status $beforeMB ($r.RemainsBytes/1MB) ($r.RemovedBytes/1MB)
}

# --- ретрай LOCKED из user-прохода (-Extra) ---
foreach ($p in $Extra) {
    $beforeMB = (Get-SizeBytes -Path $p) / 1MB
    $r = Remove-Target -Path $p
    Write-LogAndLedger ('EXTRA ' + $p) $p $r.Status $beforeMB ($r.RemainsBytes/1MB) ($r.RemovedBytes/1MB)
}

# --- DISM ---
if ($Dism) {
    Add-Content -Path $log -Value ("DISM /StartComponentCleanup started " + (Get-Date -Format 'HH:mm:ss')) -Encoding UTF8
    $dismOut = Join-Path $Work 'dism_startcomponentcleanup.txt'
    dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart 2>$null | Out-File -FilePath $dismOut -Encoding UTF8
    Add-Content -Path $log -Value ("DISM done exit=" + $LASTEXITCODE) -Encoding UTF8
}

Add-Content -Path $log -Value ("ИТОГО elevated: {0} МБ" -f [math]::Round($script:totalMB,1)) -Encoding UTF8
Write-Output ("DONE totalMB=" + [math]::Round($script:totalMB,1) + " log=$log")
