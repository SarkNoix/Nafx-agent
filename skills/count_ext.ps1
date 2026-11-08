# 统计目录里每种扩展名各有多少个文件
# 用法: count_ext.ps1 -Path test

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

# 没扩展名的单独归一类
$files |
    Group-Object -Property { if ($_.Extension) { $_.Extension.ToLower() } else { '(无扩展名)' } } |
    Sort-Object Count -Descending |
    ForEach-Object {
        Write-Output ("{0,-14} {1} 个" -f $_.Name, $_.Count)
    }

Write-Output ""
Write-Output ("共 {0} 个文件，{1} 种类型" -f $files.Count, (@($files | Group-Object { $_.Extension }).Count))
