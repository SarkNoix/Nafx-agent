# 模拟实时订单数据流：每隔 2 秒往 data\orders.jsonl 追加一条
param(
    [int]$Times = 15,
    [int]$IntervalSeconds = 2
)

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$file = Join-Path $dataDir 'orders.jsonl'

$items = @('键盘', '鼠标', '显示器', '耳机', 'U盘', '摄像头', '路由器')
$id = 0
if (Test-Path $file) {
    $id = (Get-Content $file | Where-Object { $_.Trim() -ne '' }).Count
}

Write-Host "开始写入数据流 -> $file" -ForegroundColor Cyan
for ($i = 1; $i -le $Times; $i++) {
    $id++
    $rec = [ordered]@{
        id    = $id
        item  = $items[(Get-Random -Maximum $items.Count)]
        price = (Get-Random -Minimum 29 -Maximum 999)
        qty   = (Get-Random -Minimum 1 -Maximum 5)
        ts    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    ($rec | ConvertTo-Json -Compress) | Add-Content -Path $file -Encoding UTF8
    Write-Host ("  [{0}] #{1} {2} x{3}" -f $i, $rec.id, $rec.item, $rec.qty) -ForegroundColor DarkGray
    if ($i -lt $Times) { Start-Sleep -Seconds $IntervalSeconds }
}
Write-Host "数据流结束，共 $Times 条" -ForegroundColor Green
