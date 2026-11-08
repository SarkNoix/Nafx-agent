# 从日志里提取出错的行
# 用法: log_errors.ps1 -Path app.log -Keyword "error,错误,exception,fail"

param(
    [string]$Path = '',
    [string]$Keyword = 'error,错误,exception,fail,失败,cannot,无法'
)

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定日志文件：-Path app.log"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

$patterns = @($Keyword -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

try {
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
} catch {
    Write-Output ("读不了：" + $_.Exception.Message)
    exit 1
}

$hits = @()
$n = 0
foreach ($line in $lines) {
    $n++
    foreach ($p in $patterns) {
        if ($line.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $hits += [pscustomobject]@{ No = $n; Text = $line }
            break
        }
    }
}

Write-Output ("日志 $($lines.Count) 行，命中 $($hits.Count) 行（关键词：" + ($patterns -join '/') + "）")

if ($hits.Count -eq 0) { exit 0 }

Write-Output ""
foreach ($h in ($hits | Select-Object -First 40)) {
    $t = $h.Text.Trim()
    if ($t.Length -gt 110) { $t = $t.Substring(0,110) + "…" }
    Write-Output ("[$($h.No)] " + $t)
}
if ($hits.Count -gt 40) {
    Write-Output ""
    Write-Output ("…还有 " + ($hits.Count - 40) + " 行没显示")
}
