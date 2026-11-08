# 找出目录里内容重复的文件（按哈希判断，不看文件名）
# 用法: find_duplicates.ps1 -Path test

param([string]$Path = '.')

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Output "这里没有文件：$Path"
    exit 0
}

try {
    $groups = @($files | Get-FileHash -Algorithm MD5 -ErrorAction SilentlyContinue |
                Group-Object -Property Hash |
                Where-Object { $_.Count -gt 1 })
} catch {
    Write-Output ("算哈希时出错：" + $_.Exception.Message)
    exit 1
}

if ($groups.Count -eq 0) {
    Write-Output "没有发现重复文件（检查了 $($files.Count) 个）"
    exit 0
}

$totalWasted = 0
$idx = 0
foreach ($g in $groups) {
    $idx++
    $names = @($g.Group | ForEach-Object { Split-Path $_.Path -Leaf })
    $size = 0
    try { $size = (Get-Item -LiteralPath $g.Group[0].Path).Length } catch { }
    $wasted = $size * ($g.Count - 1)
    $totalWasted += $wasted
    Write-Output ("重复组 $idx （{0} 个，每个 {1:N1} KB，可以省 {2:N1} KB）：" -f $g.Count, ($size/1KB), ($wasted/1KB))
    foreach ($n in $names) { Write-Output ("  " + $n) }
}

Write-Output ""
Write-Output ("一共 $($groups.Count) 组重复，可省 {0:N1} KB" -f ($totalWasted/1KB))
