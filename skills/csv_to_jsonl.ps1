# CSV 转 jsonl（一行一个 JSON 对象）
# 用法: csv_to_jsonl.ps1 -Path data.csv -Out data.jsonl

param(
    [string]$Path = '',
    [string]$Out = ''
)

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定 CSV：-Path data.csv"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}
if (-not $Out) {
    $Out = [IO.Path]::Combine((Split-Path -Parent $Path), ([IO.Path]::GetFileNameWithoutExtension($Path) + '.jsonl'))
}

$rows = @(Get-Content -LiteralPath $Path -Encoding UTF8)
if ($rows.Count -lt 2) {
    Write-Output "CSV 里没有数据行"
    exit 0
}

$header = @($rows[0] -split ',' | ForEach-Object { $_.Trim().Trim('"') })
$outLines = @()
$bad = 0

foreach ($r in @($rows | Select-Object -Skip 1)) {
    if (-not $r.Trim()) { continue }
    $cells = @($r -split ',')
    if ($cells.Count -ne $header.Count) { $bad++; continue }
    $obj = [ordered]@{}
    for ($i = 0; $i -lt $header.Count; $i++) {
        $v = $cells[$i].Trim().Trim('"')
        # 看起来是数字就当数字
        $num = 0.0
        if ($v -ne '' -and [double]::TryParse($v, [ref]$num)) {
            $obj[$header[$i]] = $num
        } else {
            $obj[$header[$i]] = $v
        }
    }
    $outLines += ($obj | ConvertTo-Json -Compress)
}

try {
    [IO.File]::WriteAllLines($Out, $outLines, (New-Object Text.UTF8Encoding($false)))
} catch {
    Write-Output ("写不进去：" + $_.Exception.Message)
    exit 1
}

Write-Output ("转好了：$Out")
Write-Output ("  " + $outLines.Count + " 条记录，字段 " + ($header -join ', '))
if ($bad -gt 0) { Write-Output ("  有 $bad 行列数与表头对不上，跳过了") }
