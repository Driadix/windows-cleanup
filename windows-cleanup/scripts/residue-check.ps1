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
    # Префиксное сравнение ПО ГРАНИЦЕ '\' и без wildcard-семантики:
    #   было `-like ($x + '*')` → 'C:\App' совпадал с 'C:\App2\x.exe' (ложный «остаток»),
    #   а '[' / ']' в имени папки трактовались как wildcards (молча теряли совпадения).
    if (-not $Value) { return $false }
    $v = $Value.Replace('/','\').TrimEnd('\')
    foreach ($x in $Dirs) {
        if (-not $x) { continue }
        $xn = $x.Replace('/','\').TrimEnd('\')
        if ($v.Equals($xn, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($v.StartsWith($xn + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Test-NameHits([string]$Value, [string[]]$Terms) {
    # Совпадение по имени приложения — ПО ГРАНИЦЕ СЛОВА.
    # Ни -like (скобки/звёздки в имени ломают шаблон), ни IndexOf (подстрока 'Soft' совпадала с
    # каждым 'Microsoft'/'Software' — реальный кейс прогона 2026-10-03: 146 ложных «остатков»).
    if (-not $Value) { return $false }
    foreach ($t in $Terms) {
        if (-not $t) { continue }
        # \b ставим только у word-границы термина: '.NET' начинается с '.', перед ним границы нет,
        # и жёсткий '\b\.NET' никогда бы не совпал.
        $esc = [regex]::Escape($t)
        $pre = if ($t.Substring(0,1) -match '\w') { '\b' } else { '' }
        $post = if ($t.Substring($t.Length-1,1) -match '\w') { '\b' } else { '' }
        if ([regex]::IsMatch($Value, ($pre + $esc + $post), 'IgnoreCase')) { return $true }
    }
    return $false
}
function Test-SharedCatalog([string]$Dir) {
    # «Свой каталог» пользователя (D:\Soft, D:\Games, ...), в котором соседние приложения живут
    # рядом: удаление такой папки снесло бы чужие программы. Признак — InstallLocation ДРУГОГО
    # установленного приложения начинается с этого пути (данные уже загружены, I/O не требуется).
    if (-not $Dir) { return $false }
    $dn = $Dir.Replace('/','\').TrimEnd('\')
    $prefix = $dn + '\'
    foreach ($p in $sysUninst) {
        $loc = ([string]$p.InstallLocation).Replace('/','\').TrimEnd('\')
        if ($loc -and $loc.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ОДНОКРАТНО на прогон: раньше Check-App переопрашивал Get-Process / Win32_Service /
# Get-ScheduledTask / 3 ветки Uninstall / всё Start Menu на КАЖДОМ приложении
# (O(apps × полный опрос системы)).
$sysProcs  = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path })
$sysSvcs   = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName })
$sysTasks  = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
$sysUninst = New-Object 'System.Collections.Generic.List[object]'
foreach ($parent in $parents) {
    foreach ($p in (Get-ItemProperty $parent -ErrorAction SilentlyContinue)) {
        if ($p.DisplayName) { $sysUninst.Add($p) }
    }
}
$runValues = @{}
foreach ($rk in $runKeys) {
    $rp = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
    if (-not $rp) { continue }
    $vals = @{}
    foreach ($pr in $rp.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { $vals[$pr.Name] = [string]$pr.Value } }
    $runValues[$rk] = $vals
}
# Ярлыки Start Menu — один COM-обход на прогон (раньше обход + CreateShortcut на каждое приложение,
# причём COM-объект создавался заново и не освобождался).
$smPlaces = @(
    [Environment]::GetFolderPath('Programs'),
    [Environment]::GetFolderPath('CommonPrograms'),
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
) | Where-Object { $_ } | Select-Object -Unique
$smLinks = New-Object 'System.Collections.Generic.List[object]'
$sh = $null
try {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($sm in $smPlaces) {
        if (-not (Test-Path -LiteralPath $sm)) { continue }
        foreach ($lnk in (Get-ChildItem -LiteralPath $sm -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
            $sc = $null; $tgt = ''
            try { $sc = $sh.CreateShortcut($lnk.FullName); $tgt = $sc.TargetPath } catch { }
            finally { if ($sc) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sc) } }
            if ($tgt) { $smLinks.Add([pscustomobject]@{ Link = $lnk.FullName; Target = $tgt }) }
        }
    }
} finally { if ($sh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) } }

function Check-App([string]$Label, [string[]]$Dirs, [string]$Name) {
    Log ''
    Log ('===== ' + $Label + ' =====')
    $found = 0
    # Общие каталоги (Program Files, D:\Soft, корень тома) НЕЛЬЗЯ считать остатком приложения:
    # рядом живут соседние программы — правило cleanup.md про общий каталог.
    $d      = @($Dirs | Where-Object { $_ -and -not (Test-SharedRoot $_) -and -not (Test-SharedCatalog $_) })
    $shared = @($Dirs | Where-Object { $_ -and ((Test-SharedRoot $_) -or (Test-SharedCatalog $_)) })
    foreach ($s in $shared) {
        Log ('ОБЩИЙ КАТАЛОГ: ' + $s + ' — как остаток не проверяется (в нём живут другие приложения)')
    }
    # Имена для именного поиска: полное имя, а не первое слово (Label.Split(' ')[0] помечал любой
    # Run-ключ со словом 'Driver' при приложении 'Driver Booster').
    $terms = @()
    foreach ($src in @($Name, $Label)) { if ($src -and $src.Trim().Length -ge 3) { $terms += $src.Trim() } }
    $terms = @($terms | Select-Object -Unique)

    # процессы
    foreach ($p in $sysProcs) {
        if (Test-InDirs -Value ([string]$p.Path) -Dirs $d) { Log ('ПРОЦЕСС: ' + $p.ProcessName + ' (pid ' + $p.Id + ')'); $found++ }
    }
    # службы
    foreach ($s in $sysSvcs) {
        if ((Test-InDirs -Value ([string]$s.PathName) -Dirs $d) -or (Test-NameHits -Value ([string]$s.Name) -Terms $terms)) {
            Log ('СЛУЖБА: ' + $s.Name + ' [' + $s.State + '] ' + $s.PathName); $found++
        }
    }
    # задачи
    foreach ($t in $sysTasks) {
        $hit = $false
        foreach ($a in $t.Actions) {
            if (Test-InDirs -Value ([string]$a.Execute) -Dirs $d) { $hit = $true; break }
        }
        if (-not $hit -and (Test-NameHits -Value ([string]$t.TaskName) -Terms $terms)) { $hit = $true }
        if ($hit) { Log ('ЗАДАЧА: ' + $t.TaskPath + $t.TaskName + ' [' + $t.State + ']'); $found++ }
    }
    # Run-ключи
    foreach ($rk in $runKeys) {
        if (-not $runValues.ContainsKey($rk)) { continue }
        foreach ($kv in $runValues[$rk].GetEnumerator()) {
            $val = [string]$kv.Value
            if ((Test-InDirs -Value (Get-ExePath $val) -Dirs $d) -or (Test-NameHits -Value $val -Terms $terms)) {
                Log ('RUN ' + $rk + ' :: ' + $kv.Key + ' = ' + $val); $found++
            }
        }
    }
    # ярлыки Start Menu
    foreach ($l in $smLinks) {
        if (Test-InDirs -Value $l.Target -Dirs $d) { Log ('ЯРЛЫК: ' + $l.Link); $found++ }
    }
    # папки: каталог приложения
    foreach ($x in $d) {
        if (Test-Path -LiteralPath $x) { Log ('ПАПКА: ' + $x + ' — СУЩЕСТВУЕТ'); $found++ }
        else { Log ('папка ок: ' + $x + ' — отсутствует') }
    }
    # папки в AppData/ProgramData — по ИМЕНИ приложения, а не по leaf каталога установки.
    # Прежний код брал Split-Path -Leaf от InstallLocation: для общего 'D:\Soft' получался
    # fabricated-кандидат '%APPDATA%\Soft', принадлежащий соседним приложениям (ложный остаток).
    $leafTerms = @()
    foreach ($t in $terms) {
        $leafTerms += $t
        $san = ($t -replace '[^A-Za-z0-9._-]', '')
        if ($san) { $leafTerms += $san }
    }
    foreach ($leaf in ($leafTerms | Select-Object -Unique)) {
        if (-not $leaf -or $leaf.Length -lt 3) { continue }
        foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData)) {
            if (-not $base) { continue }
            $app = Join-Path $base $leaf
            if (Test-Path -LiteralPath $app) { Log ('ПАПКА(AppData): ' + $app); $found++ }
        }
    }
    # реестр Uninstall: совпадение ПО СЛОВУ (regex \b), а не -like '*Soft*' — подстрока 'Soft'
    # совпадала с каждым DisplayName, содержащим 'Microsoft'/'Software' (реальный кейс прогона
    # 2026-10-03: -Loc 'D:\Soft' выдал 146 «остатков» из одних только записей .NET/VC++).
    foreach ($p in $sysUninst) {
        if (($Name -and $p.DisplayName -eq $Name) -or (Test-NameHits -Value ([string]$p.DisplayName) -Terms $terms)) {
            Log ('РЕЕСТР Uninstall: ' + (($p.PSPath -split '\\')[-1]) + ' => ' + $p.DisplayName); $found++
        }
    }
    if ($found -eq 0) {
        if ($d) { Log ('чисто: остатков по "' + $Label + '" нет') }
        else {
            # Без каталога приложения прежний код всё равно печатал «чисто» — ложное подтверждение
            # удаления: пути вообще не проверялись.
            Log ('НЕ ПОДТВЕРЖДЕНО «чисто»: каталог приложения не определён — проверены только именные совпадения. Проверь вручную.')
        }
    }
    return $found
}

$total = 0
foreach ($n in $AppName) {
    $dirs = @(); $reg = $null
    foreach ($hit in $sysUninst) {
        if ($hit.DisplayName -eq $n) { $reg = $hit; break }
    }
    if ($reg) {
        if ($reg.InstallLocation) { $dirs += ([string]$reg.InstallLocation).TrimEnd('\') }
        if (-not $dirs -and $reg.UninstallString) {
            $m = [regex]::Match([string]$reg.UninstallString, '^"([^"]+)"')
            if ($m.Success) { $dirs += [IO.Path]::GetDirectoryName($m.Groups[1].Value) }
        }
    } else {
        Log ''
        Log ('===== ' + $n + ' =====')
        Log ('WARN: записи Uninstall для "' + $n + '" не найдено — каталог неизвестен, проверка только по имени.')
    }
    $total += Check-App -Label $n -Dirs $dirs -Name $n
}
foreach ($l in $Loc) {
    $total += Check-App -Label (Split-Path -Leaf $l) -Dirs @($l) -Name ''
}

Write-Output ("residue-check: всего остатков = " + $total + "  =>  отчёт: " + $out)
