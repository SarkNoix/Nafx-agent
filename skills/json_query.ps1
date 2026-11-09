# 查 JSON / JSONL 文件里的字段
# 用法: json_query.ps1 -Path data/users.json -Pattern "name"
#       json_query.ps1 -Path data/orders.jsonl -Pattern "user.name"
#       json_query.ps1 -Path data/users.json -Pattern ""     → 只看结构（前几条）

param(
    [string]$Path = '',
    [string]$Pattern = ''
)

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定文件：-Path data/users.json"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

$raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Output "文件是空的：$Path"
    exit 0
}

# 先当成整体 JSON 解析；不行再按行（JSONL）解析。
# 别靠首字符判断——JSONL 的第一行也是 { 开头，跟普通 JSON 一样。
$items = @()
$isJsonl = $false
try {
    $obj = $raw | ConvertFrom-Json
    if ($obj -is [array]) { $items = @($obj) } else { $items = @($obj) }
} catch {
    # 按行解析
    $okLines = 0
    foreach ($ln in ($raw -split "`r?`n")) {
        $s = $ln.Trim()
        if (-not $s) { continue }
        try { $items += ($s | ConvertFrom-Json); $okLines++ } catch { }
    }
    if ($okLines -eq 0) {
        Write-Output "不是合法的 JSON，也不是 JSONL（每行一个对象）"
        exit 1
    }
    $isJsonl = $true
}

if ($items.Count -eq 0) {
    Write-Output "没解析出任何记录（文件可能不是 JSON / JSONL）"
    exit 0
}

$kind = if ($isJsonl) { 'JSONL' } else { 'JSON' }
Write-Output ("$kind 文件，$($items.Count) 条记录")

# 没给字段：列出每条的字段名
if ([string]::IsNullOrWhiteSpace($Pattern)) {
    $keys = @{}
    foreach ($it in $items) {
        if ($it -is [pscustomobject]) {
            foreach ($p in $it.PSObject.Properties) { $keys[$p.Name] = $true }
        }
    }
    if ($keys.Count -eq 0) {
        Write-Output ""
        Write-Output "内容："
        $items | Select-Object -First 5 | ForEach-Object { Write-Output ("  " + $_) }
    } else {
        Write-Output ""
        Write-Output ("字段（" + $keys.Count + " 个）：" + (($keys.Keys | Sort-Object) -join '、'))
        Write-Output ""
        Write-Output "第一条长这样："
        $items[0] | ConvertTo-Json -Depth 4 | ForEach-Object { Write-Output ("  " + $_) }
    }
    exit 0
}

# 按字段路径取值（支持 a.b.c）
$values = @()
foreach ($it in $items) {
    $cur = $it
    $ok = $true
    foreach ($seg in ($Pattern -split '\.')) {
        if ($null -eq $cur) { $ok = $false; break }
        if ($cur -is [pscustomobject]) {
            $prop = $cur.PSObject.Properties[$seg]
            if ($null -eq $prop) { $ok = $false; break }
            $cur = $prop.Value
        } else {
            $ok = $false; break
        }
    }
    if ($ok -and $null -ne $cur) { $values += $cur }
}

if ($values.Count -eq 0) {
    Write-Output "没有一条记录含字段：$Pattern"
    exit 0
}

Write-Output ""
Write-Output ("字段 $Pattern 有值的有 $($values.Count) 条")
Write-Output ""

# 全是数字就顺手给个统计
$nums = @()
foreach ($v in $values) {
    $d = 0.0
    if ([double]::TryParse([string]$v, [ref]$d)) { $nums += $d }
}

if ($nums.Count -eq $values.Count -and $nums.Count -gt 0) {
    $sum = ($nums | Measure-Object -Sum).Sum
    $avg = [math]::Round($sum / $nums.Count, 2)
    $min = ($nums | Measure-Object -Minimum).Minimum
    $max = ($nums | Measure-Object -Maximum).Maximum
    Write-Output ("  合计 $sum")
    Write-Output ("  平均 $avg")
    Write-Output ("  最小 $min   最大 $max")
} else {
    # 不是纯数字：去重计数 + 前几个
    $uniq = @($values | Sort-Object -Unique)
    Write-Output ("  不同的值有 $($uniq.Count) 种")
    Write-Output ("  前几个：" + (($uniq | Select-Object -First 10) -join '、'))
}
