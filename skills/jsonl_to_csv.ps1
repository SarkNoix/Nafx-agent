# jsonl 转 CSV
# 用法: jsonl_to_csv.ps1 -Path data.jsonl -Out data.csv

param(
    [string]$Path = '',
    [string]$Out = ''
)

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定 jsonl：-Path data.jsonl"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}
if (-not $Out) {
    $Out = [IO.Path]::Combine((Split-Path -Parent $Path), ([IO.Path]::GetFileNameWithoutExtension($Path) + '.csv'))
}

$objs = @()
foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
    if (-not $line.Trim()) { continue }
    try { $objs += ($line | ConvertFrom-Json) } catch { }
}

if ($objs.Count -eq 0) {
    Write-Output "没读到有效的 JSON 行"
    exit 0
}

# 按出现顺序收集字段
$cols = @()
foreach ($o in $objs) {
    foreach ($p in $o.PSObject.Properties.Name) {
        if ($cols -notcontains $p) { $cols += $p }
    }
}

$outLines = @()
$outLines += ($cols | ForEach-Object { if ($_ -match '[,"\n]') { '"' + $_.Replace('"','""') + '"' } else { $_ } }) -join ','

foreach ($o in $objs) {
    $cells = @()
    foreach ($c in $cols) {
        $v = $o.$c
        if ($null -eq $v) { $cells += ''; continue }
        $s = [string]$v
        if ($s -match '[,"\n]') { $s = '"' + $s.Replace('"','""') + '"' }
        $cells += $s
    }
    $outLines += ($cells -join ',')
}

try {
    [IO.File]::WriteAllLines($Out, $outLines, (New-Object Text.UTF8Encoding($false)))
} catch {
    Write-Output ("写不进去：" + $_.Exception.Message)
    exit 1
}

Write-Output ("转好了：$Out")
Write-Output ("  " + $objs.Count + " 条记录，字段 " + ($cols -join ', '))
