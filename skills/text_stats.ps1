# 统计文本的行数、字数、字符数
# 用法: text_stats.ps1 -Path data/orders.jsonl
#       text_stats.ps1 -Path data          （目录则统计所有文本文件）

param([string]$Path = '.')

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "路径不存在：$Path"
    exit 1
}

function Get-TextStats {
    param([string]$file)
    $text = ''
    try { $text = [IO.File]::ReadAllText($file) } catch { return $null }
    $lines = 0
    if ($text.Length -gt 0) {
        $lines = ($text -split "`r?`n").Count
        # 最后一行是空的就不算
        if ($text -match "`r?`n$") { $lines-- }
    }
    $chars = $text.Length
    # 去掉空白后的字符数
    $noSpace = ($text -replace '\s', '').Length
    return [pscustomobject]@{ Lines = $lines; Chars = $chars; NoSpace = $noSpace }
}

$item = Get-Item -LiteralPath $Path

if (-not $item.PSIsContainer) {
    $st = Get-TextStats -file $item.FullName
    if (-not $st) { Write-Output "读不了这个文件：$Path"; exit 1 }
    Write-Output ("文件 " + $item.Name)
    Write-Output ("  行数      " + $st.Lines)
    Write-Output ("  字符数    " + $st.Chars)
    Write-Output ("  非空白    " + $st.NoSpace)
    exit 0
}

# 目录：统计所有文本类文件
$exts = @('.txt', '.md', '.json', '.jsonl', '.csv', '.log', '.ps1', '.bat', '.js', '.py', '.xml', '.html', '.ini', '.cfg', '.yml', '.yaml')
$files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $exts -contains $_.Extension.ToLower() })

if ($files.Count -eq 0) {
    Write-Output "这里没有文本文件：$Path"
    exit 0
}

$tLines = 0
$tChars = 0
$tNoSpace = 0
$rows = @()
foreach ($f in $files) {
    $st = Get-TextStats -file $f.FullName
    if (-not $st) { continue }
    $tLines += $st.Lines
    $tChars += $st.Chars
    $tNoSpace += $st.NoSpace
    $rel = $f.FullName
    try { $rel = $f.FullName.Substring((Resolve-Path -LiteralPath $Path).Path.Length).TrimStart('\') } catch { }
    $rows += [pscustomobject]@{ Name = $rel; Lines = $st.Lines; Chars = $st.Chars }
}

$rows | Sort-Object Lines -Descending | ForEach-Object {
    Write-Output ("{0,-30} {1,5} 行  {2,7} 字符" -f $_.Name, $_.Lines, $_.Chars)
}
Write-Output ""
Write-Output ("合计 {0} 个文件：{1} 行，{2} 字符（非空白 {3}）" -f $files.Count, $tLines, $tChars, $tNoSpace)
