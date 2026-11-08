# 订单数据流分析（由智能体调用）
param([string]$File = 'data/orders.jsonl')

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$path = Join-Path $root $File
if (-not (Test-Path $path)) { Write-Output "找不到数据文件：$File"; exit 1 }

$rows = Get-Content $path -Encoding UTF8 | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_ | ConvertFrom-Json }
if (-not $rows) { Write-Output '数据为空'; exit 0 }

$count = ($rows | Measure-Object).Count
$sum   = ($rows | ForEach-Object { $_.price * $_.qty } | Measure-Object -Sum).Sum
$top   = ($rows | Sort-Object price -Descending | Select-Object -First 1)

Write-Output "订单数: $count"
Write-Output "总金额: $sum"
Write-Output "最高单价: $($top.item) $($top.price) 元"
Write-Output "最近一条: $($rows[-1].item) x$($rows[-1].qty)"
