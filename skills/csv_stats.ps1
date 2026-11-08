# 表格统计：行数列数、每列的求和/平均/最大最小、不同值个数
# 用法: csv_stats.ps1 -Path data.csv

param([string]$Path = '')

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
    Write-Output "要指定表格：-Path data.csv"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

try {
    $rows = @(Get-Content -LiteralPath $Path -Encoding UTF8)
} catch {
    Write-Output ("读不了：" + $_.Exception.Message)
    exit 1
}

# 去掉空行
$rows = @($rows | Where-Object { $_.Trim() -ne '' })
if ($rows.Count -lt 2) {
    Write-Output "表格里没有数据行（只有表头或空文件）"
    exit 1
}

$header = @($rows[0] -split ',' | ForEach-Object { $_.Trim().Trim('"') })
$data = @($rows | Select-Object -Skip 1)

Write-Output ("表格：" + $(if ($__origName) { $__origName } else { Split-Path $Path -Leaf }))
Write-Output ("  " + $header.Count + " 列 × " + $data.Count + " 行数据")
Write-Output ""

# 逐列分析
for ($c = 0; $c -lt $header.Count; $c++) {
    $col = $header[$c]
    $vals = @()
    $numVals = @()
    foreach ($r in $data) {
        if (-not $r.Trim()) { continue }
        $cells = @($r -split ',')
        if ($c -ge $cells.Count) { continue }
        $v = $cells[$c].Trim().Trim('"')
        if ($v -eq '') { continue }
        $vals += $v
        $n = 0.0
        if ([double]::TryParse($v, [ref]$n)) { $numVals += $n }
    }

    if ($vals.Count -eq 0) {
        Write-Output ("[$col]  全是空值")
        continue
    }

    $uniq = @($vals | Sort-Object -Unique).Count
    $isNum = ($numVals.Count -ge ($vals.Count * 0.8))

    if ($isNum -and $numVals.Count -gt 0) {
        $st = $numVals | Measure-Object -Sum -Average -Maximum -Minimum
        Write-Output ("[$col]  数值型  有效 $($numVals.Count) 个，不同值 $uniq 个")
        Write-Output ("    总和 {0:N2}   平均 {1:N2}   最大 {2:N2}   最小 {3:N2}" -f $st.Sum, $st.Average, $st.Maximum, $st.Minimum)
    } else {
        # 字符串列：显示最常见的几个
        $top = @($vals | Group-Object | Sort-Object Count -Descending | Select-Object -First 3)
        $topStr = ($top | ForEach-Object { $_.Name + "(" + $_.Count + ")" }) -join '、'
        Write-Output ("[$col]  文本型  有效 $($vals.Count) 个，不同值 $uniq 个")
        Write-Output ("    最多：$topStr")
    }
}
