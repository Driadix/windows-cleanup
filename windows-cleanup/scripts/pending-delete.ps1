# Параметры
param(
    [Parameter(Mandatory=$true, ValueFromRemainingArguments=$true)][string[]]$Paths
)

# Удаление заблокированных файлов/папок ПРИ ПЕРЕЗАГРУЗКЕ через PendingFileRenameOperations.
# Использование (elevated): powershell.exe -NoProfile -ExecutionPolicy Bypass -File pending-delete.ps1 "<путь к папке>" "<путь к файлу>"
# Требует прав администратора (через Start-Process -Verb RunAs -Wait из скилла).
# Запускать ТОЛЬКО как финал LOCKED-процедуры (ретрай → Stop-Process → это).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')   # Test-Elevated / Test-ProtectedRoot

$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

# Проверка прав (BuiltInRole-enum: локаленезависимо, строка 'Administrators' на не-en сборках врёт)
if (-not (Test-Elevated)) { Write-Error 'Требуются права администратора'; exit 1 }

# PendingFileRenameOperations: пары "путь\??\..." + "" (пусто = удалить). REG_MULTI_SZ (7).
$existing = (Get-ItemProperty -Path $key -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
$list = [System.Collections.Generic.List[string]]::new()
# REG_MULTI_SZ с ОДНИМ элементом PowerShell разворачивает в [string], а List[string].AddRange
# свяжется с IEnumerable<char> и упадёт — приводим к [string[]] явно.
if ($existing) { $list.AddRange([string[]]@($existing)) }
$toAdd = [System.Collections.Generic.List[string]]::new()
function Add-Pending([string]$FullPath) {
    $toAdd.Add("\??\" + $FullPath)
    $toAdd.Add('')   # пустая вторая часть = удаление
}
foreach ($p in $Paths) {
    if (Test-ProtectedRoot $p) { Write-Output "BLOCKED (системный корень): $p"; continue }
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) { Write-Output "already gone: $p"; continue }
    if ($item.PSIsContainer) {
        # MoveFileEx удаляет каталог ТОЛЬКО если он пуст — очередь непустой папки молча ничего не
        # сделает при перезагрузке (реальный дефект: documented usage передавал непустые папки).
        # Раскрываем в глубину: сначала все файлы, потом подкаталоги от самых глубоких к корню.
        $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue)
        $dirs  = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                   Sort-Object { $_.FullName.Length } -Descending)
        foreach ($f in $files) { Add-Pending $f.FullName }
        foreach ($d in $dirs)  { Add-Pending $d.FullName }
        Add-Pending $item.FullName
        Write-Output ("queued dir: {0} (файлов {1}, подкаталогов {2})" -f $item.FullName, $files.Count, $dirs.Count)
    } else {
        Add-Pending $item.FullName
        Write-Output ("queued file: " + $item.FullName)
    }
}

# Защита от переполнения: значение читается smss при загрузке, практически потолок ~32 КБ.
# Разросшаяся/битая очередь может не примениться или сломать удаление при загрузке — поэтому
# при превышении консервативного лимита НЕ пишем вообще, а сообщаем (PATH-лимита у нас нет,
# но разумно не рисковать очередью ради пары файлов).
$curLen = 0L
foreach ($s in $list) { $curLen += [int]$s.Length + 1 }
$addLen = 0L
foreach ($s in $toAdd) { $addLen += [int]$s.Length + 1 }
$maxLen = 30000
if (($curLen + $addLen) -gt $maxLen) {
    Write-Error ("Очередь PendingFileRenameOperations почти полна: ~" + ($curLen + $addLen) + " символов при потолке ~" + $maxLen + ". НЕ записываю — заблокированные файлы удали вручную или после перезагрузки.")
    exit 2
}
$list.AddRange($toAdd)
Set-ItemProperty -Path $key -Name PendingFileRenameOperations -Value $list.ToArray() -Type MultiString
Write-Output "OK: запланировано удаление при перезагрузке: $($list.Count/2) объектов"
