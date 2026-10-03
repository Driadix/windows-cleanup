# Smoke tests for windows-cleanup helper scripts (offline, no desktop needed).
# Uses fixtures to exercise semantic behavior: .url web links, {::}-CLSID targets,
# empty-target shortcuts, decoy non-shortcut files, duplicate detection.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\smoke_test.ps1 [-SkillDir <dir>]
# Exit code 0 = all PASS, 1 = at least one FAIL.

param(
    [string]$SkillDir = ""
)

$ErrorActionPreference = 'Stop'
if (-not $SkillDir) { $SkillDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-cleanup' }
$scanScript = Join-Path $SkillDir 'scripts\scan.ps1'
$shcScript  = Join-Path $SkillDir 'scripts\shortcuts.ps1'
if (-not (Test-Path -LiteralPath $scanScript) -or -not (Test-Path -LiteralPath $shcScript)) {
    Write-Error "scripts not found under $SkillDir"; exit 1
}

$fail = 0
function Assert([bool]$cond, [string]$msg) {
    if ($cond) { Write-Output "PASS  $msg" }
    else       { Write-Output "FAIL  $msg"; $script:fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wc_smoke_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Write-Output "== smoke fixtures in $tmp =="

try {
    # ---------- scan.ps1 fixture ----------
    $tree = Join-Path $tmp 'tree'
    New-Item -ItemType Directory -Path "$tree\bigfold\inner", "$tree\emptyfold" -Force | Out-Null
    # Три одинаковых по (Length,Name) файла -> кандидаты в дубли (порог -MinDupBytes 1 КБ)
    'AAAA' * 300 | Set-Content -Path "$tree\bigfold\dupe.bin"  -Encoding UTF8   # ~1200 байт
    'AAAA' * 300 | Set-Content -Path "$tree\bigfold\inner\dupe.bin" -Encoding UTF8
    'BBBB' * 100 | Set-Content -Path "$tree\single.bin" -Encoding UTF8
    'not a shortcut' | Set-Content -Path "$tree\bigfold\decoy.exe" -Encoding UTF8

    $scanOut = Join-Path $tmp 'scanout'
    $r = & $scanScript -Root $tree -OutDir $scanOut -Top 5 -MinDupBytes 1024 2>&1
    # Скрипты не делают явный exit 0, поэтому $LASTEXITCODE ненадёжен (остаётся от предыдущего
    # дочернего процесса). Проверяем маркер успеха в выводе — это и есть контракт scan.ps1.
    Assert (($r -join "`n") -match 'OK: dirs_top=') 'scan: exit marker OK present in output'
    Assert (($r -join "`n") -notmatch 'Exception|error :') 'scan: no exception in output'
    foreach ($f in 'dirs_top.txt','files_top.txt','dupes.txt') {
        Assert (Test-Path -LiteralPath (Join-Path $scanOut $f)) "scan: report $f written"
    }
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut 'dirs_top.txt') -Raw) -match 'bigfold') "scan: dirs_top contains bigfold"
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut 'files_top.txt') -Raw) -match 'dupe\.bin') "scan: files_top contains dupe.bin"
    $dupeLines = @(Get-Content -LiteralPath (Join-Path $scanOut 'dupes.txt') | Where-Object { $_.Trim() })
    Assert ($dupeLines.Count -ge 2) "scan: dupes.txt lists dupe.bin candidates (got $($dupeLines.Count))"

    # ---------- shortcuts.ps1 fixture ----------
    $fdir = Join-Path $tmp 'links'
    New-Item -ItemType Directory -Path $fdir -Force | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $realExe = "$env:SystemRoot\System32\notepad.exe"

    # .lnk, цель не существует -> БИТАЯ
    $s = $sh.CreateShortcut((Join-Path $fdir 'broken.lnk')); $s.TargetPath = 'C:\No\Such\Path\gone.exe'; $s.Save()
    # .lnk, живая цель -> ЖИВАЯ
    $s = $sh.CreateShortcut((Join-Path $fdir 'alive.lnk')); $s.TargetPath = $realExe; $s.Save()
    # .lnk, пустая цель (как shell-объект «Этот компьютер») -> НЕ битая
    $s = $sh.CreateShortcut((Join-Path $fdir 'empty.lnk')); $s.Save()
    # .lnk, цель {::CLSID} -> НЕ битая
    $s = $sh.CreateShortcut((Join-Path $fdir 'clsid.lnk')); $s.TargetPath = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'; $s.Save()
    # .url с URL -> ЖИВАЯ
    "[InternetShortcut]`r`nURL=https://example.com`r`n" | Set-Content -Path (Join-Path $fdir 'web.url') -Encoding UTF8
    # .url без URL -> БИТАЯ
    "[InternetShortcut]`r`n" | Set-Content -Path (Join-Path $fdir 'broken.url') -Encoding UTF8
    # Сторонний exe в каталоге — не должен попасть в отчёт
    'decoy' | Set-Content -Path (Join-Path $fdir 'decoy.exe') -Encoding UTF8

    $shcOut = Join-Path $tmp 'shcout'
    $r2 = & $shcScript -OutDir $shcOut -Places @($fdir) 2>&1
    Assert (($r2 -join "`n") -match 'broken=\d+ alive=\d+') 'shortcuts: summary line present in output'
    $report = Join-Path $shcOut 'broken_shortcuts.txt'
    Assert (Test-Path -LiteralPath $report) 'shortcuts: report written'
    $txt = Get-Content -LiteralPath $report -Raw
    Assert ($txt -match 'broken\.lnk')  'shortcuts: broken.lnk (missing target) detected'
    Assert ($txt -match 'broken\.url')  'shortcuts: broken.url (no URL) detected'
    Assert ($txt -notmatch 'alive\.lnk') 'shortcuts: alive.lnk NOT flagged (existing target)'
    Assert ($txt -notmatch 'empty\.lnk') 'shortcuts: empty-target .lnk NOT flagged (shell object semantics)'
    Assert ($txt -notmatch 'clsid\.lnk') 'shortcuts: {::}-CLSID .lnk NOT flagged'
    Assert ($txt -notmatch 'web\.url')   'shortcuts: .url with URL=https:// NOT flagged'
    Assert ($txt -notmatch 'decoy\.exe') 'shortcuts: non-shortcut decoy.exe NOT in report'
    $brokenCount = @($txt -split "`r?`n" | Where-Object { $_ -match '\.(lnk|url)' }).Count
    Assert ($brokenCount -eq 2) "shortcuts: exactly 2 broken reported (got $brokenCount)"

    # ---------- scan: forward-slash root; маркер "(пусто)" для дублей; самоключение OutDir ----------
    $tree2 = Join-Path $tmp 'tree2'
    New-Item -ItemType Directory -Path "$tree2\only" -Force | Out-Null
    'X' * 100 | Set-Content -Path "$tree2\only\small.txt" -Encoding UTF8     # << порога 1024 КБ
    $scanOut2 = Join-Path $tmp 'scanout2'
    & $scanScript -Root ($tree2.Replace('\','/')) -OutDir $scanOut2 -MinDupBytes 1024 | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $scanOut2 'dupes.txt')) 'scan2: dupes.txt always created'
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut2 'dupes.txt') -Raw) -match '\(пусто') 'scan2: empty dupes -> "(пусто)" marker'
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut2 'dirs_top.txt') -Raw) -match 'only') 'scan2: forward-slash root normalized (dir "only" found)'

    $tree3 = Join-Path $tmp 'tree3'
    New-Item -ItemType Directory -Path "$tree3\inner" -Force | Out-Null
    'Y' * 2000 | Set-Content -Path "$tree3\inner\data.bin" -Encoding UTF8
    $scanOut3 = Join-Path $tree3 'scanout'
    & $scanScript -Root $tree3 -OutDir $scanOut3 -MinDupBytes 1024 | Out-Null   # 1-й проход пишет отчёты внутрь tree3
    & $scanScript -Root $tree3 -OutDir $scanOut3 -MinDupBytes 1024 | Out-Null   # 2-й проход (не должен считать свои отчёты)
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut3 'files_top.txt') -Raw) -notmatch 'scanout') 'scan3: self-reports (OutDir) excluded from files_top'
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut3 'dirs_top.txt') -Raw) -notmatch 'scanout') 'scan3: OutDir excluded from dirs_top'

    # ---------- cleanup-common: статусы удаления + лидгер ----------
    . (Join-Path $SkillDir 'scripts\cleanup-common.ps1')
    $croot = Join-Path $tmp 'common'
    New-Item -ItemType Directory -Path "$croot\sub" -Force | Out-Null
    'Z' * 5000 | Set-Content -Path "$croot\sub\file.bin" -Encoding UTF8
    $r1 = Remove-Target -Path "$croot\sub\file.bin"
    Assert ($r1.Status -eq 'removed' -and $r1.RemovedBytes -ge 5000) 'common: Remove-Target (file) -> removed'
    $r2 = Remove-Target -Path "$croot\missing\gone"
    Assert ($r2.Status -eq 'already gone') 'common: Remove-Target (missing) -> already gone'
    $r3 = Remove-Contents -Path $croot
    Assert ($r3.Status -eq 'done' -and $r3.RemovedBytes -ge 0) 'common: Remove-Contents -> done'
    # Регрессия прогона 2026-10-03: цель, где ВСЁ заблокировано, обязана дать LOCKED, а не 'done'
    # (иначе отчёт врёт «очищено» при 0 освобождённого — кейс Office C2R из user-сессии).
    $lockroot = Join-Path $tmp 'lockeddir'
    New-Item -ItemType Directory -Path $lockroot -Force | Out-Null
    $lockfile = Join-Path $lockroot 'held.bin'
    'H' * 3000 | Set-Content -Path $lockfile -Encoding UTF8
    $held = [IO.File]::Open($lockfile, 'Open', 'ReadWrite', 'None')   # держим файл занятым
    try {
        $r4 = Remove-Contents -Path $lockroot
        Assert ($r4.Status -eq 'LOCKED' -and $r4.RemovedBytes -eq 0) "common: all-locked contents -> LOCKED (got $($r4.Status))"
    } finally { $held.Dispose() }
    $r5 = Remove-Contents -Path $lockroot
    Assert ($r5.Status -eq 'done' -and $r5.RemovedBytes -ge 3000) 'common: contents removable again after unlock -> done'
    $empty = Join-Path $tmp 'emptydir'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    $r6 = Remove-Contents -Path $empty
    Assert ($r6.Status -eq 'already gone') 'common: empty dir contents -> already gone'
    $led = Join-Path $tmp 'ledger.csv'
    Init-Ledger -Work $tmp -Name 'ledger.csv' | Out-Null
    Write-Ledger -Path $led -Phase 'test' -Object 'объект' -TargetPath 'C:\x' -SizeBeforeMB 1 -SizeAfterMB 0 -Status 'removed' -RemovedMB 1
    $ledRows = @(Import-Csv -LiteralPath $led)
    $testRows = @($ledRows | Where-Object { $_.phase -eq 'test' })
    Assert ($testRows.Count -eq 1) 'common: Write-Ledger appended a row'
    Assert ($testRows[0].removed_mb -eq '1') 'common: Write-Ledger (removed_mb=1) correct'
    # Get-ExePath: двойные backslash'и в PathName + голое имя + кавычки.
    # Пути строим от $env:SystemDrive, а не литералом 'C:\...' — фикстуры парсера не должны
    # привязывать тест к машине (иначе валидатор переносимости законно на них ругается).
    $pf = $env:ProgramFiles   # содержит пробел — это и тестируем
    $exe1 = Get-ExePath ($pf.Replace('\','\\') + '\\AmneziaVPN\\amneziavpn-service.exe -x')
    Assert ($exe1 -eq (Join-Path $pf 'AmneziaVPN\amneziavpn-service.exe')) 'common: Get-ExePath collapses double backslashes'
    $exe2 = Get-ExePath 'powershell.exe -NoProfile -Command x'
    Assert ($exe2 -eq 'powershell.exe') 'common: Get-ExePath handles bare exe name'
    $exe3 = Get-ExePath ('"' + $pf + '\X\y.exe" --flag')
    Assert ($exe3 -eq ($pf + '\X\y.exe')) 'common: Get-ExePath handles quoted path'
    $exe4 = Get-ExePath ($pf + '\X\y.exe --flag')
    Assert ($exe4 -eq ($pf + '\X\y.exe')) 'common: Get-ExePath handles unquoted space path (with args)'
    $exe5 = Get-ExePath ($pf + '\AmneziaVPN\AmneziaVPN-service.exe')
    Assert ($exe5 -eq ($pf + '\AmneziaVPN\AmneziaVPN-service.exe')) 'common: Get-ExePath handles unquoted space path (no args)'
    # UNC (регресс: .Replace('\\','\') ломал \\srv -> \srv)
    $exe6 = Get-ExePath '\\srv\share\app.exe -x'
    Assert ($exe6 -eq '\\srv\share\app.exe') 'common: Get-ExePath preserves UNC in fixtures'

    # ---------- системный guard: BLOCKED + Test-ProtectedRoot ----------
    $blocked1 = Remove-Target -Path "$env:SystemRoot\System32\definitely-missing-xzy.bin"
    Assert ($blocked1.Status -eq 'BLOCKED') 'common: Remove-Target blocks System32 (BLOCKED, even if missing)'
    $blocked2 = Remove-Target -Path "$env:SystemRoot\WinSxS\some-guid"
    Assert ($blocked2.Status -eq 'BLOCKED') 'common: Remove-Target blocks WinSxS (BLOCKED)'
    Assert (-not (Test-ProtectedRoot (Join-Path $tmp 'common'))) 'common: Test-ProtectedRoot allows normal temp paths'
    Assert (-not (Test-ProtectedRoot "$env:SystemRoot\Temp")) 'common: Test-ProtectedRoot allows Windows\Temp'

    # ---------- регрессии фиксов прогона 2026-10-03 ----------
    # DeliveryOptimization под \ServiceProfiles\ — allow-list, иначе elevated-проход молча чистил 0 байт
    $doPath = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization'
    Assert (-not (Test-ProtectedRoot $doPath)) 'common: DeliveryOptimization allowed (was silently BLOCKED)'
    Assert (-not (Test-ProtectedRoot (Join-Path $doPath 'Cache'))) 'common: DeliveryOptimization\Cache allowed too'
    Assert (Test-ProtectedRoot "$env:SystemRoot\ServiceProfiles\LocalService") 'common: other ServiceProfiles still BLOCKED'
    Assert (Test-ProtectedRoot "$env:SystemRoot\System32\drivers") 'common: System32 subtree still BLOCKED'

    # Test-SharedRoot: общие каталоги не считаются локацией приложения (защита от обхода всего диска)
    Assert (Test-SharedRoot $env:ProgramFiles) 'common: ProgramFiles is a shared root'
    Assert (Test-SharedRoot "$env:SystemDrive\") 'common: drive root is a shared root'
    Assert (Test-SharedRoot 'C:') 'common: bare drive letter is a shared root'
    Assert (-not (Test-SharedRoot (Join-Path $env:ProgramFiles 'SomeApp'))) 'common: app dir under ProgramFiles is NOT shared'
    Assert (Test-SharedRoot '') 'common: empty path treated as shared (never an app dir)'

    # Get-FixedVolumes: DriveType — СТРОКА, фильтр `-ne 2` не работал и пропускал съёмные тома
    $removable = @(Get-Volume | Where-Object { $_.DriveLetter -and ($_.DriveType.ToString() -ne 'Fixed') })
    $fixed = @(Get-FixedVolumes)
    Assert ($fixed.Count -gt 0) 'common: Get-FixedVolumes returns at least one volume'
    $leaked = @($fixed | Where-Object { $_.DriveType.ToString() -ne 'Fixed' })
    Assert ($leaked.Count -eq 0) "common: Get-FixedVolumes excludes non-Fixed (leaked $($leaked.Count); removable present on machine: $($removable.Count))"

    # Get-ExePath: UNC должен сохраняться (старый .Replace('\\','\') ломал \\srv -> \srv)
    Assert ((Get-ExePath '\\srv\share\app.exe') -eq '\\srv\share\app.exe') 'common: Get-ExePath preserves UNC path'
    Assert ((Get-ExePath '\\\\srv\\share\\app.exe -x') -eq '\\srv\share\app.exe') 'common: Get-ExePath collapses WMI-doubled UNC'

    # ConvertTo-Bytes: суффикс из командной строки (регресс бага 0.2.2 ParameterArgumentTransformationError)
    Assert ((ConvertTo-Bytes -Size '1KB') -eq 1KB) 'common: ConvertTo-Bytes parses 1KB'
    Assert ((ConvertTo-Bytes -Size '1.5GB') -eq [long](1.5GB)) 'common: ConvertTo-Bytes parses 1.5GB'
    Assert ((ConvertTo-Bytes -Size 'abc') -eq 0) 'common: ConvertTo-Bytes returns 0 on garbage (scan.ps1 falls back to 50MB)'

    # scan.ps1: -Tag (суффикс имён), -ProgressFile (DONE ПОСЛЕ записи выходов), мета-кэш complete=true
    $tree4 = Join-Path $tmp 'tree4'
    New-Item -ItemType Directory -Path "$tree4\sub" -Force | Out-Null
    'Q' * 2000 | Set-Content -Path "$tree4\sub\q.bin" -Encoding UTF8
    $scanOut4 = Join-Path $tmp 'scanout4'
    $prog4 = Join-Path $scanOut4 'prog.txt'
    & $scanScript -Root $tree4 -OutDir $scanOut4 -Tag c -MinDupBytes '1KB' -ProgressFile $prog4 | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $scanOut4 'dirs_top_c.txt')) 'scan: -Tag suffixes report names (dirs_top_c.txt)'
    Assert (-not (Test-Path -LiteralPath (Join-Path $scanOut4 'dirs_top.txt'))) 'scan: -Tag does not write unsuffixed name'
    Assert (Test-Path -LiteralPath (Join-Path $scanOut4 'scan_meta_c.txt')) 'scan: -Tag meta cache written'
    $progTxt = @(Get-Content -LiteralPath $prog4)
    Assert ($progTxt[-1] -match '^DONE') 'scan: DONE is the last progress line'
    Assert ($progTxt[0] -match 'start') 'scan: progress starts with start marker'
    $meta4 = (Get-Content -LiteralPath (Join-Path $scanOut4 'scan_meta_c.txt') -Raw | ConvertFrom-Json)
    Assert ($meta4.complete -eq $true) 'scan: meta marks complete=true'
    Assert ([bool]$meta4.finished -and [bool]$meta4.host) 'scan: meta has finished+host fields'
    # DONE пишется последним => к моменту DONE выходные файлы уже существуют (гонка закрыта)
    Assert ((Test-Path -LiteralPath (Join-Path $scanOut4 'files_top_c.txt')) -and (Test-Path -LiteralPath (Join-Path $scanOut4 'dupes_c.txt'))) 'scan: outputs exist when DONE observed'
    # -MinDupBytes строкой с суффиксом (регресс: int-параметр падал)
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut4 'dupes_c.txt') -Raw) -match '\(пусто') 'scan: string -MinDupBytes 1KB accepted, no dupes'

    # ledger-report.ps1: отрицательная дельта должна печататься со знаком МИНУС
    # (раньше [math]::Abs показывал потерю места как освобождение)
    $ledW = Join-Path $tmp 'ledgerw'
    New-Item -ItemType Directory -Path $ledW -Force | Out-Null
    $vol = Get-Volume | Where-Object { $_.DriveLetter -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1
    $nowMB = [double]$vol.SizeRemaining / 1MB
    Init-Ledger -Work $ledW -Name 'ledger.csv' | Out-Null
    $ledPath = Join-Path $ledW 'ledger.csv'
    # baseline на 20 ГБ БОЛЬШЕ текущего свободного => дельта обязана быть отрицательной.
    # fmt-N = инвариантная культура (точка), как в Write-Ledger: в ru-RU запятая разорвала бы CSV.
    $baseMB = fmt-N ($nowMB + 20480) 4
    Add-Content -LiteralPath $ledPath -Value ('{0},baseline,volume {1},{1}:,{2},0,baseline,0' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $vol.DriveLetter, $baseMB) -Encoding UTF8
    & (Join-Path $SkillDir 'scripts\ledger-report.ps1') -Work $ledW | Out-Null
    $repTxt = Get-Content -LiteralPath (Join-Path $ledW 'ledger_report.txt') -Raw
    Assert ($repTxt -match 'изм\. свободного: -2[0-9]') 'ledger-report: negative delta keeps minus sign (space loss is visible)'
    Assert ($repTxt -notmatch 'ИТОГО освобождено \(по строкам ledger\):\s*МБ') 'ledger-report: total MB cell not blank on empty removals'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Output 'ALL SMOKE TESTS PASSED'; exit 0 }
else { Write-Output "$fail FAILED"; exit 1 }
