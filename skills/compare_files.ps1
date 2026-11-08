# 比较两个文件是否相同
# 用法: compare_files.ps1 -Path a.txt -With b.txt

param(
    [string]$Path = '',
    [string]$With = ''
)

if (-not $Path -or -not $With) {
    Write-Output "要指定两个文件：-Path a.txt -With b.txt"
    exit 1
}
foreach ($f in @($Path, $With)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Output "文件不存在：$f"; exit 1 }
}

$a = Get-Item -LiteralPath $Path
$b = Get-Item -LiteralPath $With

Write-Output ("A: " + $a.Name + "  (" + $a.Length + " 字节)")
Write-Output ("B: " + $b.Name + "  (" + $b.Length + " 字节)")
Write-Output ""

if ($a.Length -ne $b.Length) {
    Write-Output "不一样（大小就不同）"
    exit 0
}

$ha = (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash
$hb = (Get-FileHash -LiteralPath $With -Algorithm MD5).Hash

if ($ha -eq $hb) {
    Write-Output "内容完全相同"
} else {
    Write-Output "大小一样，但内容不同"
    Write-Output ("  hash A: " + $ha.Substring(0,16))
    Write-Output ("  hash B: " + $hb.Substring(0,16))
}
