# 在表格里查某个人/某个值的某一项
# 用法:
#   csv_query.ps1 -Path data.csv -Find "张三" -Field "amount"
#   csv_query.ps1 -Path data.csv -Find "张三"              不指定字段就整行列出

param(
    [string]$Path = '',
    [string]$Find = '',
    [string]$Field = ''
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
    Write-Output "要指定表格：-Path data.csv"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($Find)) {
    Write-Output "要说清找谁/找什么：-Find 张三"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

try {
    $rows = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
} catch {
    Write-Output ("读不了：" + $_.Exception.Message)
    exit 1
}

if ($rows.Count -lt 2) {
    Write-Output "表格里没有数据行"
    exit 1
}

$header = @($rows[0] -split ',' | ForEach-Object { $_.Trim().Trim('"') })
$data = @($rows | Select-Object -Skip 1)

# 找到要取的那一列
$fieldIdx = -1
if ($Field) {
    for ($i = 0; $i -lt $header.Count; $i++) {
        if ($header[$i] -eq $Field) { $fieldIdx = $i; break }
    }
    if ($fieldIdx -lt 0) {
        for ($i = 0; $i -lt $header.Count; $i++) {
            if ($header[$i] -like "*$Field*" -or $Field -like "*$($header[$i])*") { $fieldIdx = $i; break }
        }
    }
    if ($fieldIdx -lt 0) {
        Write-Output ("表格里没有 '$Field' 这一列。现有列：" + ($header -join ', '))
        exit 1
    }
}

$matches = @()
foreach ($r in $data) {
    $cells = @($r -split ',')
    for ($i = 0; $i -lt $cells.Count; $i++) {
        $v = $cells[$i].Trim().Trim('"')
        if ($v -eq $Find -or $v -like "*$Find*") {
            $obj = [ordered]@{}
            for ($k = 0; $k -lt $header.Count -and $k -lt $cells.Count; $k++) {
                $obj[$header[$k]] = $cells[$k].Trim().Trim('"')
            }
            $matches += [pscustomobject]$obj
            break
        }
    }
}

if ($matches.Count -eq 0) {
    Write-Output ("表格里没找到包含 '$Find' 的行（共 " + $data.Count + " 行）")
    exit 0
}

if ($matches.Count -gt 1) {
    Write-Output ("找到 " + $matches.Count + " 行匹配 '$Find'：")
}

if ($fieldIdx -ge 0) {
    $col = $header[$fieldIdx]
    Write-Output ("$Find 的 $col ：")
    foreach ($m in $matches) {
        Write-Output ("  " + $m.$col)
    }
} else {
    foreach ($m in $matches) {
        Write-Output "--"
        foreach ($p in $m.PSObject.Properties) {
            Write-Output ("  " + $p.Name + ": " + $p.Value)
        }
    }
}
