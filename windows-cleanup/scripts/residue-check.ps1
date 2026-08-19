# residue-check.ps1 — чек-лист остатков ПОСЛЕ антинсталла (read-only, ничего не удаляет).
# Проверяет по каждому приложению: процессы, службы, задачи, Run-ключи, Start-меню, папки, реестр-Uninstall.
# Использование:
#   residue-check.ps1 -Work "рабочая папка" -AppName "Driver Booster 13","Revo Uninstaller"
#   или  -Loc "D:\Soft\App","C:\Program Files\App"
# Выход: -Work\residue_check.txt (секция FOUND/clean по каждому приложению).
param(
    [Parameter(Mandatory=$true)][string]$Work,
    [string[]]$AppName = @(),
    [string[]]$Loc = @()
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$out = Join-Path $Work 'residue_check.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

$parents = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$runKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)

function Log([string]$m) { Add-Content -Path $out -Value $m -Encoding UTF8 }

function Test-InDirs([string]$Value, [string[]]$Dirs) {
    foreach ($x in $Dirs) { if ($Value -and ($Value -like ($x + '*'))) { return $true } }
    return $false
}
function Test-TaskHits($Actions, [string[]]$Dirs) {
    foreach ($a in $Actions) {
        $exe = [string]$a.Execute
        if (Test-InDirs -Value $exe -Dirs $Dirs) { return $true }
    }
    return $false
}

function Check-App([string]$Label, [string[]]$Dirs, [string]$Name) {
    Log ''
    Log ('===== ' + $Label + ' =====')
    $found = 0
    $d = @($Dirs | Where-Object { $_ })
    # процессы
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if (Test-InDirs -Value ([string]$p.Path) -Dirs $d) { Log ('ПРОЦЕСС: ' + $p.ProcessName + ' (pid ' + $p.Id + ')'); $found++ }
    }
    # службы
    foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        if (Test-InDirs -Value ([string]$s.PathName) -Dirs $d) { Log ('СЛУЖБА: ' + $s.Name + ' [' + $s.State + '] ' + $s.PathName); $found++ }
    }
    # задачи
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if (Test-TaskHits -Actions $t.Actions -Dirs $d) { Log ('ЗАДАЧА: ' + $t.TaskPath + $t.TaskName + ' [' + $t.State + ']'); $found++ }
    }
    # Run-ключи
    foreach ($rk in $runKeys) {
        $rp = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        if (-not $rp) { continue }
        foreach ($pr in $rp.PSObject.Properties) {
            if ($pr.Name -match '^PS') { continue }
            $val = [string]$pr.Value
            if ((Test-InDirs -Value $val -Dirs $d) -or ($val -like ('*' + $Label.Split(' ')[0] + '*'))) {
                Log ('RUN ' + $rk + ' :: ' + $pr.Name); $found++
            }
        }
    }
    # ярлыки Start Menu
    $sh = New-Object -ComObject WScript.Shell
    foreach ($sm in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")) {
        if (-not (Test-Path -LiteralPath $sm)) { continue }
        foreach ($lnk in (Get-ChildItem -LiteralPath $sm -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            $tgt = ''
            try { $tgt = $sh.CreateShortcut($lnk.FullName).TargetPath } catch { }
            if (Test-InDirs -Value $tgt -Dirs $d) { Log ('ЯРЛЫК: ' + $lnk.FullName); $found++ }
        }
    }
    # папки (каталог + AppData-производные)
    foreach ($x in $d) {
        if (Test-Path -LiteralPath $x) { Log ('ПАПКА: ' + $x + ' — СУЩЕСТВУЕТ'); $found++ }
        else { Log ('папка ок: ' + $x + ' — отсутствует') }
        $leaf = Split-Path -Leaf $x
        foreach ($app in @("$env:APPDATA\$leaf", "$env:LOCALAPPDATA\$leaf", "$env:ProgramData\$leaf")) {
            if (Test-Path -LiteralPath $app) { Log ('ПАПКА(AppData): ' + $app); $found++ }
        }
    }
    # реестр Uninstall
    foreach ($parent in $parents) {
        foreach ($p in (Get-ItemProperty $parent -ErrorAction SilentlyContinue)) {
            if (-not $p.DisplayName) { continue }
            if ($p.DisplayName -eq $Name -or $p.DisplayName -like ('*' + $Label + '*')) {
                Log ('РЕЕСТР Uninstall: ' + (($p.PSPath -split '\\')[-1]) + ' => ' + $p.DisplayName); $found++
            }
        }
    }
    if ($found -eq 0) { Log ('чисто: остатков по "' + $Label + '" нет') }
    return $found
}

$total = 0
foreach ($n in $AppName) {
    $dirs = @(); $reg = $null
    foreach ($parent in $parents) {
        $hit = Get-ItemProperty $parent -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n } | Select-Object -First 1
        if ($hit) { $reg = $hit; if ($hit.InstallLocation) { $dirs += ([string]$hit.InstallLocation).TrimEnd('\') }; break }
    }
    if (-not $dirs -and $reg -and $reg.UninstallString) {
        $m = [regex]::Match([string]$reg.UninstallString, '^"([^"]+)"')
        if ($m.Success) { $dirs += [IO.Path]::GetDirectoryName($m.Groups[1].Value) }
    }
    $total += Check-App -Label $n -Dirs $dirs -Name $n
}
foreach ($l in $Loc) {
    $total += Check-App -Label (Split-Path -Leaf $l) -Dirs @($l) -Name ''
}

Write-Output ("residue-check: всего остатков = " + $total + "  =>  отчёт: " + $out)
