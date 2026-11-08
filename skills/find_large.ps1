# 列出目录里最大的 N 个文件
# 用法: find_large.ps1 -Path . -Top 10

param(
    [string]$Path = '.',
    [int]$Top = 10
)

if ($Top -lt 1) { $Top = 10 }

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Output "这里没有文件：$Path"
    exit 0
}

$sorted = @($files | Sort-Object Length -Descending | Select-Object -First $Top)
$sumMb = ($files | Measure-Object Length -Sum).Sum / 1MB

Write-Output ("最大的 $($sorted.Count) 个文件（目录共 $($files.Count) 个，合计 {0:N1} MB）：" -f $sumMb)
$i = 0
foreach ($f in $sorted) {
    $i++
    $rel = $f.FullName
    try { $rel = $f.FullName.Substring((Resolve-Path -LiteralPath $Path).Path.Length).TrimStart('\') } catch { }
    $sz = if ($f.Length -ge 1MB) { "{0:N1} MB" -f ($f.Length/1MB) }
          elseif ($f.Length -ge 1KB) { "{0:N1} KB" -f ($f.Length/1KB) }
          else { "{0} B" -f $f.Length }
    Write-Output ("{0,3}. {1,-10} {2}" -f $i, $sz, $rel)
}
