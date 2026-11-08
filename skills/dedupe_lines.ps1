# 文件里的重复行去重（默认预览）
# 用法:
#   dedupe_lines.ps1 -Path data.txt            预览
#   dedupe_lines.ps1 -Path data.txt -Apply     真写回

param(
    [string]$Path = '',
    [switch]$Apply
)

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定文件：-Path data.txt"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

try {
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
} catch {
    Write-Output ("读不了：" + $_.Exception.Message)
    exit 1
}

$seen = @{}
$kept = @()
$dupCount = 0
$dupSamples = @()
foreach ($line in $lines) {
    $key = $line.Trim()
    if ($key -eq '') { $kept += $line; continue }
    if ($seen.ContainsKey($key)) {
        $dupCount++
        if ($dupSamples.Count -lt 5 -and $dupSamples -notcontains $key) { $dupSamples += $key }
    } else {
        $seen[$key] = $true
        $kept += $line
    }
}

Write-Output ("原 $($lines.Count) 行，去重后 $($kept.Count) 行，去掉 $dupCount 行重复")
if ($dupSamples.Count -gt 0) {
    Write-Output "重复行示例："
    foreach ($d in $dupSamples) {
        $t = $d
        if ($t.Length -gt 70) { $t = $t.Substring(0,70) + "…" }
        Write-Output ("  " + $t)
    }
}

if ($dupCount -eq 0) { exit 0 }

$outPath = if ($Apply) { (Get-Item -LiteralPath $Path).FullName } else { [IO.Path]::Combine((Split-Path -Parent $Path), ([IO.Path]::GetFileNameWithoutExtension($Path) + '_deduped' + [IO.Path]::GetExtension($Path))) }

try {
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines($outPath, $kept, $enc)
    Write-Output ""
    Write-Output $(if ($Apply) { "已写回 $Path" } else { "去重结果在：$outPath  （加 -Apply 才写回原文件）" })
} catch {
    Write-Output ("写不进去：" + $_.Exception.Message)
}
