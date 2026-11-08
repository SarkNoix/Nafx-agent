# 批量替换文件里的文字（默认只预览）
# 用法:
#   replace_text.ps1 -Path test -Find "old" -Replace "new"          预览
#   replace_text.ps1 -Path test -Find "old" -Replace "new" -Apply   真改

param(
    [string]$Path = '.',
    [string]$Find = '',
    [string]$Replace = '',
    [string]$Ext = '',
    [switch]$Apply
)

if ([string]::IsNullOrWhiteSpace($Find)) {
    Write-Output "要说清找什么：-Find 旧文字 -Replace 新文字"
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

$plan = @()
foreach ($f in $files) {
    $text = ''
    try { $text = [IO.File]::ReadAllText($f.FullName) } catch { continue }
    $cnt = ([regex]::Matches($text, [regex]::Escape($Find))).Count
    if ($cnt -gt 0) {
        $plan += [pscustomobject]@{ File = $f; Count = $cnt; Text = $text }
    }
}

if ($plan.Count -eq 0) {
    Write-Output ("没找到 '$Find'（搜了 " + $files.Count + " 个文件）")
    exit 0
}

$total = ($plan | Measure-Object Count -Sum).Sum
Write-Output ("'$Find' → '$Replace'：" + $plan.Count + " 个文件共 " + $total + " 处" +
              $(if ($Apply) { "（正在改）" } else { "（预览，加 -Apply 才改）" }))
foreach ($p in $plan) { Write-Output ("  " + $p.File.Name + "  " + $p.Count + " 处") }

if (-not $Apply) { exit 0 }

$ok = 0
foreach ($p in $plan) {
    try {
        $newText = $p.Text.Replace($Find, $Replace)
        [IO.File]::WriteAllText($p.File.FullName, $newText, (New-Object Text.UTF8Encoding($false)))
        $ok++
    } catch {
        Write-Output ("  失败：" + $p.File.Name + " — " + $_.Exception.Message)
    }
}
Write-Output ""
Write-Output ("改好 $ok 个文件")
