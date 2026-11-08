# 找出并清理空文件夹（默认只列出来）
# 用法:
#   clean_empty_dirs.ps1 -Path .           只列出
#   clean_empty_dirs.ps1 -Path . -Apply    真删

param(
    [string]$Path = '.',
    [switch]$Apply
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}

$root = Get-Item -LiteralPath $Path
if (-not $root.PSIsContainer) {
    Write-Output "这不是目录：$Path"
    exit 1
}

# 反复扫，删掉一层后可能又有新的空目录
$allEmpty = @()
$round = 0
while ($round -lt 10) {
    $round++
    $dirs = @(Get-ChildItem -LiteralPath $root.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue |
              Sort-Object { $_.FullName.Length } -Descending)

    $found = @()
    foreach ($d in $dirs) {
        $children = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) { $found += $d }
    }
    if ($found.Count -eq 0) { break }

    foreach ($d in $found) {
        $rel = $d.FullName
        try { $rel = $d.FullName.Substring($root.FullName.Length).TrimStart('\') } catch { }
        $allEmpty += $rel
        if ($Apply) {
            try { Remove-Item -LiteralPath $d.FullName -Force -Recurse -ErrorAction Stop }
            catch { Write-Output ("  删不掉：" + $rel + " — " + $_.Exception.Message) }
        }
    }
    if (-not $Apply) { break }
}

if ($allEmpty.Count -eq 0) {
    Write-Output "没有空文件夹"
    exit 0
}

Write-Output ($(if ($Apply) { "已清理" } else { "发现" }) + " " + $allEmpty.Count + " 个空文件夹" +
              $(if ($Apply) { "" } else { "（加 -Apply 才真删）" }))
foreach ($e in $allEmpty) { Write-Output ("  " + $e) }
