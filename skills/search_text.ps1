# 在文件或目录里搜关键词，返回命中的文件和行
# 用法: search_text.ps1 -Pattern "错误" -Path . -Ext .txt,.log

param(
    [string]$Pattern = '',
    [string]$Path = '.',
    [string]$Ext = '',
    [switch]$IgnoreCase
)

if ([string]::IsNullOrWhiteSpace($Pattern)) {
    Write-Output "要指定要找什么：-Pattern 关键词"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "路径不存在：$Path"
    exit 1
}

$item = Get-Item -LiteralPath $Path
if (-not $item.PSIsContainer) {
    $files = @($item)
} else {
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue)
    if ($Ext) {
        $want = @($Ext -split ',' | ForEach-Object { $_.Trim().TrimStart('.').ToLower() })
        $files = @($files | Where-Object { $want -contains $_.Extension.TrimStart('.').ToLower() })
    }
}

if ($files.Count -eq 0) {
    Write-Output "没有要搜的文件"
    exit 0
}

$opt = if ($IgnoreCase) { 'IgnoreCase' } else { 'None' }
$hits = 0
$hitFiles = 0

foreach ($f in $files) {
    $found = @()
    try {
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop)
    } catch { continue }
    $n = 0
    foreach ($line in $lines) {
        $n++
        if ($line.IndexOf($Pattern, [StringComparison]::$opt) -ge 0) {
            $found += [pscustomobject]@{ No = $n; Text = $line }
        }
    }
    if ($found.Count -gt 0) {
        $hitFiles++
        $hits += $found.Count
        Write-Output ($f.Name + "  （" + $found.Count + " 处）")
        foreach ($h in ($found | Select-Object -First 5)) {
            $t = $h.Text
            if ($t.Length -gt 90) { $t = $t.Substring(0,90) + "…" }
            Write-Output ("  第 $($h.No) 行: " + $t.Trim())
        }
        if ($found.Count -gt 5) { Write-Output ("  …还有 " + ($found.Count - 5) + " 处") }
    }
}

Write-Output ""
if ($hits -eq 0) {
    Write-Output ("没搜到 '$Pattern'（搜了 " + $files.Count + " 个文件）")
} else {
    Write-Output ("'$Pattern' 出现在 $hitFiles 个文件里，共 $hits 处")
}
