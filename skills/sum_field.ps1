# 对 jsonl / csv 里的数值字段求和、平均、最大最小
# 用法: sum_field.ps1 -Path data/orders.jsonl -Field amount

param(
    [string]$Path = '',
    [string]$Field = 'amount'
)

# ---- 如果是 Excel 文件，先转成 csv 再处理 ----
$__xlsxTemp = ''
$__origName = ''
if ($Path -match '\.(xlsx|xlsm)$') {
    $__origName = Split-Path $Path -Leaf
    $__xlsxTemp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('nafx_c_' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.csv'))
    $__conv = Join-Path $PSScriptRoot 'xlsx_to_csv.ps1'
    if (-not (Test-Path $__conv)) { Write-Output "找不到 xlsx_to_csv.ps1，转不了 Excel"; exit 1 }
    $__out = & $__conv -Path $Path -Out $__xlsxTemp 2>&1
    if (-not (Test-Path $__xlsxTemp)) {
        Write-Output ("Excel 转 csv 失败：" + ($__out -join ' '))
        exit 1
    }
    $Path = $__xlsxTemp
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定文件：-Path data/orders.jsonl"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

$ext = [IO.Path]::GetExtension($Path).ToLower()
$values = New-Object System.Collections.ArrayList

try {
    if ($ext -eq '.csv') {
        $rows = @(Get-Content -LiteralPath $Path -Encoding UTF8)
        if ($rows.Count -lt 2) { Write-Output "CSV 里没有数据行"; exit 0 }
        $header = $rows[0] -split ','
        $colIdx = -1
        for ($i = 0; $i -lt $header.Count; $i++) {
            if ($header[$i].Trim().Trim('"') -eq $Field) { $colIdx = $i; break }
        }
        if ($colIdx -lt 0) {
            Write-Output ("CSV 里没有 '$Field' 这一列。现有列：" + (($header | ForEach-Object { $_.Trim() }) -join ', '))
            exit 1
        }
        foreach ($r in @($rows | Select-Object -Skip 1)) {
            if (-not $r.Trim()) { continue }
            $cells = $r -split ','
            if ($colIdx -lt $cells.Count) {
                $v = 0.0
                if ([double]::TryParse($cells[$colIdx].Trim().Trim('"'), [ref]$v)) { [void]$values.Add($v) }
            }
        }
    } else {
        # jsonl：一行一个对象
        foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
            if (-not $line.Trim()) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $raw = $o.$Field
                if ($null -ne $raw) {
                    $v = 0.0
                    if ([double]::TryParse([string]$raw, [ref]$v)) { [void]$values.Add($v) }
                }
            } catch { }
        }
    }
} catch {
    Write-Output ("读文件出错：" + $_.Exception.Message)
    exit 1
}

if ($values.Count -eq 0) {
    Write-Output "没有读到 '$Field' 的数值（检查字段名对不对）"
    exit 1
}

$stats = $values | Measure-Object -Sum -Average -Maximum -Minimum
Write-Output ("字段 {0} ，共 {1} 条：" -f $Field, $values.Count)
Write-Output ("  总和  {0:N2}" -f $stats.Sum)
Write-Output ("  平均  {0:N2}" -f $stats.Average)
Write-Output ("  最大  {0:N2}" -f $stats.Maximum)
Write-Output ("  最小  {0:N2}" -f $stats.Minimum)
