# Параметры
param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [switch]$Remove
)

# Поиск битых ярлыков (.lnk/.url) в 4 стандартных местах.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File shortcuts.ps1 -OutDir "<рабочая папка>"
# Без -Remove — только отчёт; с -Remove — удаляет битые (с тест-патом и логом). Живые никогда не трогаются.

$ErrorActionPreference = 'SilentlyContinue'
$sh = New-Object -ComObject WScript.Shell

$places = @(
    "$env:USERPROFILE\Desktop",
    "$env:ProgramData\Microsoft\Windows\Desktop",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
)

$broken = @(); $alive = 0
foreach ($p in $places) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    Get-ChildItem -LiteralPath $p -Recurse -File -Include *.lnk,*.url |
        ForEach-Object {
            try {
                $target = $sh.CreateShortcut($_.FullName).TargetPath
                if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target)) {
                    $broken += [pscustomobject]@{ Link = $_.FullName; Target = $target }
                } else { $alive++ }
            } catch { $broken += [pscustomobject]@{ Link = $_.FullName; Target = '(ошибка чтения)' } }
        }
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$report = Join-Path $OutDir 'broken_shortcuts.txt'
$broken | Sort-Object Link | Format-Table -AutoSize | Out-File -FilePath $report -Encoding UTF8

if ($Remove) {
    $log = Join-Path $OutDir 'broken_shortcuts_log.txt'
    foreach ($b in $broken) {
        try {
            Remove-Item -LiteralPath $b.Link -Force -Recurse
            Add-Content -Path $log -Value "removed: $($b.Link)" -Encoding UTF8
        } catch { Add-Content -Path $log -Value "LOCKED: $($b.Link)" -Encoding UTF8 }
    }
}

Write-Output "broken=$($broken.Count) alive=$alive report=$report"
