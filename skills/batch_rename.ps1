# 批量改名：加前缀 / 加后缀 / 替换名字里的一段
# 用法:
#   batch_rename.ps1 -Path test -AddPrefix bak_        预览
#   batch_rename.ps1 -Path test -AddPrefix bak_ -Apply  真改
#   batch_rename.ps1 -Path test -Replace "old=new"
#
# 默认只预览，加了 -Apply 才动手。这是故意的。

param(
    [string]$Path = '.',
    [string]$AddPrefix = '',
    [string]$AddSuffix = '',
    [string]$Replace = '',
    [switch]$Apply
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}
if (-not $AddPrefix -and -not $AddSuffix -and -not $Replace) {
    Write-Output "要告诉我怎么改：-AddPrefix 前缀 / -AddSuffix 后缀 / -Replace 旧=新"
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Output "这里没有文件：$Path"
    exit 0
}

# 解析替换规则
$from = ''
$to = ''
if ($Replace) {
    $parts = $Replace -split '=', 2
    if ($parts.Count -ne 2) { Write-Output "-Replace 要写成 旧=新，比如 abc=xyz"; exit 1 }
    $from = $parts[0]
    $to = $parts[1]
}

$plan = @()
foreach ($f in $files) {
    $base = $f.BaseName
    $ext = $f.Extension
    if ($from) { $base = $base.Replace($from, $to) }
    $newName = $AddPrefix + $base + $AddSuffix + $ext
    if ($newName -ne $f.Name) {
        $plan += [pscustomobject]@{ Old = $f.Name; New = $newName; Full = $f.FullName; Dir = $f.DirectoryName }
    }
}

if ($plan.Count -eq 0) {
    Write-Output "没有需要改的文件"
    exit 0
}

Write-Output ("要改 $($plan.Count) 个文件：" + $(if ($Apply) { "（正在执行）" } else { "（只是预览，加 -Apply 才会真改）" }))
foreach ($p in $plan) { Write-Output ("  " + $p.Old + "  →  " + $p.New) }

if (-not $Apply) { exit 0 }

$ok = 0
$fail = 0
foreach ($p in $plan) {
    $dest = Join-Path $p.Dir $p.New
    if (Test-Path -LiteralPath $dest) {
        Write-Output ("  跳过（目标已存在）：" + $p.New)
        $fail++
        continue
    }
    try {
        Rename-Item -LiteralPath $p.Full -NewName $p.New -ErrorAction Stop
        $ok++
    } catch {
        Write-Output ("  失败：" + $p.Old + " — " + $_.Exception.Message)
        $fail++
    }
}
Write-Output ""
Write-Output ("改好 $ok 个" + $(if ($fail -gt 0) { "，$fail 个没改成" } else { "" }))
