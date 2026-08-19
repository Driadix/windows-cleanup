# inventory-quick.ps1 — быстрая часть Фазы 2: программы (CSV), установщики, корзины, кэши.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File inventory-quick.ps1 -Work "рабочая папка" [-Disks 'C'] [-Disks 'C','D']
#   -Disks: буквы выбранных в Фазе 1 дисков (например 'C'). Кэши на других томах (например %TEMP% на D:)
#           помечаются в cache_sizes.txt как «вне выбранных дисков» — по умолчанию в очистку не идут (U2).
# Выход (в -Work): installed.csv (с Hive и LocExists/LocKind), installers.txt, recyclebin.txt, cache_sizes.txt.
#   Корзины считаем ТОЛЬКО по файлам $R* (их сумма = реальные данные; $I-метаданные не считаем).
#   Кэши браузеров — по профилям (Default, Profile *), не хардкодим "Default".
param([Parameter(Mandatory=$true)][string]$Work, [string[]]$Disks = @())
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }

# ---------- 1. Установленные программы -> CSV ----------
$rows = @()
$hives = @{
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'            = 'HKLM'
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' = 'HKLM32'
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'            = 'HKCU'
}
foreach ($h in $hives.Keys) {
    foreach ($p in (Get-ItemProperty $h -ErrorAction SilentlyContinue)) {
        $name = $p.DisplayName
        if (-not $name) { continue }   # шелуха без имени
        $dir = $null
        if ($p.InstallLocation) {
            $dir = ([string]$p.InstallLocation).TrimEnd('\')
            # InstallLocation бывает URL/протокольной ссылкой (@url:http://..., http://..., ms-internal:...),
            # а не локальным путём. Test-Path на URL всегда False, но это НЕ «пропавший софт» / сирота
            # (LocKind='missing' сбил бы Фазу 6) — считаем «локации нет», как если бы поле пустое.
            if ($dir -match '^@' -or $dir -match '^[a-zA-Z][a-zA-Z0-9+.-]*://' -or $dir -match '^ms-[a-zA-Z0-9.]+:') { $dir = '' }
        }
        elseif ($p.UninstallString) {
            $m = [regex]::Match([string]$p.UninstallString, '^"([^"]+)"')
            if ($m.Success) { $dir = [IO.Path]::GetDirectoryName($m.Groups[1].Value) }
        }
        $locExists = (-not $dir) -or (Test-Path -LiteralPath $dir)
        # LocKind: 'ok' / 'missing' / 'packagecache' / 'none' — чтобы Фаза 6 не считала
        # Installation-кеши (C:\ProgramData\Package Cache\{GUID}) ложными «сиротами» (см. U6).
        $locKind = 'none'
        if ($dir) {
            if ($dir -match '\\Package Cache\\') { $locKind = 'packagecache' }
            elseif (Test-Path -LiteralPath $dir) { $locKind = 'ok' }
            else { $locKind = 'missing' }
        }
        $rows += [pscustomobject]@{
            Name = $name; Ver = $p.DisplayVersion; Hive = $hives[$h]; Loc = $dir; LocExists = $locExists; LocKind = $locKind
            Uninst = $p.UninstallString; Code = $p.ProductCode; Date = $p.InstallDate
            # EstimatedSize в реестре — в КИЛОБАЙТАХ, а колонка называется SizeMB (реальный кейс: LoL
            # показывал 39 492 190 «МБ» = 39 ТБ, тогда как это 37,7 ГБ). Делим на 1024, чтобы имя не врало.
            SizeMB = if ($p.EstimatedSize) { [math]::Max(0, [long]([math]::Round([double]$p.EstimatedSize / 1024))) } else { $null }
        }
    }
}
$rows | Sort-Object Name | Export-Csv -Path (Join-Path $Work 'installed.csv') -NoTypeInformation -Encoding UTF8

# ---------- 2. Установщики в пользовательских папках ----------
$ins = @()
foreach ($d in @(($env:USERPROFILE + '\Desktop'), ($env:USERPROFILE + '\Downloads'), ($env:USERPROFILE + '\Documents'))) {
    if (Test-Path -LiteralPath $d) {
        Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.exe','.msi','.zip','.iso','.rar','.7z' } |
            ForEach-Object { $ins += [pscustomobject]@{ GB=[math]::Round($_.Length/1GB,2); Last=$_.LastWriteTime.ToString('yyyy-MM-dd'); Path=$_.FullName } }
    }
}
if ($ins.Count) {
    $ins | Sort-Object GB -Descending | ForEach-Object { "{0}`t{1}`t{2}" -f (fmt-N $_.GB 2), $_.Last, $_.Path } |
        Set-Content -Path (Join-Path $Work 'installers.txt') -Encoding UTF8
} else {
    # Set-Content с пустым пайплайном НЕ перезаписывает файл — останется устаревший список
    # (реальный кейс тестового прогона: бывшие установщики продолжали «жить» в installers.txt).
    '(пусто — установщиков нет)' | Set-Content -Path (Join-Path $Work 'installers.txt') -Encoding UTF8
}

# ---------- 3. Корзины по дискам (только $R*) ----------
# DriveType у Get-Volume — enum; явно исключаем съёмные(2)/сетевые(4)/CD(5)
$rbLines = @()
foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -ne 2 -and $_.DriveType -ne 4 -and $_.DriveType -ne 5 })) {
    $root = '{0}:\$Recycle.Bin' -f $v.DriveLetter
    if (Test-Path -LiteralPath $root) {
        $sum = (Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '$R*' } | Measure-Object Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        $rbLines += ('{0}: {1} ГБ' -f $v.DriveLetter, [math]::Round([long]$sum/1GB,2))
    } else { $rbLines += ('{0}: нет корзины/нет доступа' -f $v.DriveLetter) }
}
if (-not $rbLines) { $rbLines = '(пусто — томов NTFS с буквами нет)' }
$rbLines | Set-Content -Path (Join-Path $Work 'recyclebin.txt') -Encoding UTF8

# ---------- 4. Кэши (браузерные по профилям + пакетные) ----------
$cTargets = @()
foreach ($br in @(
    @{ N='Brave'; UserData="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" },
    @{ N='Yandex'; UserData="$env:LOCALAPPDATA\Yandex\YandexBrowser\User Data" },
    @{ N='Edge'; UserData="$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
    @{ N='Opera'; UserData="$env:LOCALAPPDATA\Programs\Opera\User Data" }
)) {
    if (-not (Test-Path -LiteralPath $br.UserData)) { continue }
    $profiles = @(Get-ChildItem -LiteralPath $br.UserData -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like 'Default*' -or $_.Name -like 'Profile*' } | Select-Object -ExpandProperty FullName)
    foreach ($pf in $profiles) {
        foreach ($sub in @('Cache','Code Cache','GPUCache','ShaderCache','Service Worker')) {
            $cTargets += [pscustomobject]@{ N = ("{0} {1}\{2}" -f $br.N, [IO.Path]::GetFileName($pf), $sub); Path = (Join-Path $pf $sub) }
        }
    }
}
$cTargets += @(
    [pscustomobject]@{ N='%TEMP%'; Path=$env:TEMP },
    [pscustomobject]@{ N='npm cache (local)'; Path="$env:LOCALAPPDATA\npm-cache" },
    [pscustomobject]@{ N='npm cache (roaming, старый)'; Path="$env:APPDATA\npm-cache" },
    [pscustomobject]@{ N='uv cache'; Path="$env:LOCALAPPDATA\uv\cache" },
    [pscustomobject]@{ N='pip cache'; Path="$env:LOCALAPPDATA\pip\Cache" },
    [pscustomobject]@{ N='NuGet v3-cache'; Path="$env:LOCALAPPDATA\NuGet\v3-cache" },
    [pscustomobject]@{ N='electron Cache'; Path="$env:LOCALAPPDATA\electron\Cache" },
    [pscustomobject]@{ N='VS Code CachedExtensionVSIXs'; Path="$env:APPDATA\Code\CachedExtensionVSIXs" }
)
$selDisks = @($Disks | ForEach-Object { ($_.TrimEnd(':')).ToUpperInvariant() })
$cLines = foreach ($t in $cTargets) {
    $sz = Get-SizeBytes -Path $t.Path
    if (-not (Test-Path -LiteralPath $t.Path)) { "{0}`t(нет)`t{1}" -f '-', $t.Path; continue }
    $vol = ([IO.Path]::GetPathRoot($t.Path)).TrimEnd('\')
    $onSel = (-not $selDisks) -or ($selDisks -contains (($vol.TrimEnd(':')).ToUpperInvariant()))
    $flag = if ($onSel) { '' } else { '  [том ' + $vol + ' — вне выбранных дисков]' }
    "{0}`t{1} ГБ`t{2}{3}" -f $t.N, (fmt-N ($sz/1GB) 3), $t.Path, $flag
}
$cLines | Set-Content -Path (Join-Path $Work 'cache_sizes.txt') -Encoding UTF8

Write-Output ("installed.csv rows=" + $rows.Count)
Write-Output ("recyclebin: " + ($rbLines -join '; '))
