# 按修改日期把文件归档到 年-月 子目录（默认预览）
# 用法:
#   archive_by_date.ps1 -Path downloads              预览
#   archive_by_date.ps1 -Path downloads -Apply       真移动

param(
    [string]$Path = '.',
    [switch]$Apply
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}

$root = Get-Item -LiteralPath $Path
if (-not $root.PSIsContainer) {
    Write-Output "这不是目录：$Path"
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $root.FullName -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Output "这里没有文件"
    exit 0
}

$plan = @{}
foreach ($f in $files) {
    $folder = $f.LastWriteTime.ToString('yyyy-MM')
    if (-not $plan.ContainsKey($folder)) { $plan[$folder] = @() }
    $plan[$folder] += $f
}

Write-Output ($(if ($Apply) { "正在归档" } else { "归档计划（预览，加 -Apply 才动）" }) + "：")
foreach ($k in ($plan.Keys | Sort-Object)) {
    Write-Output ("  " + $k + "/  ← " + $plan[$k].Count + " 个文件")
    if ($plan[$k].Count -le 3) {
        foreach ($f in $plan[$k]) { Write-Output ("      " + $f.Name) }
    }
}
Write-Output ""
Write-Output ("共 " + $files.Count + " 个文件，分到 " + $plan.Count + " 个目录")

if (-not $Apply) { exit 0 }

$moved = 0
$failed = 0
foreach ($k in $plan.Keys) {
    $destDir = Join-Path $root.FullName $k
    try {
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
    } catch {
        Write-Output ("  建目录失败：" + $k + " — " + $_.Exception.Message)
        $failed += $plan[$k].Count
        continue
    }
    foreach ($f in $plan[$k]) {
        $dest = Join-Path $destDir $f.Name
        if (Test-Path -LiteralPath $dest) {
            Write-Output ("  跳过（已存在）：" + $f.Name)
            $failed++
            continue
        }
        try {
            Move-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop
            $moved++
        } catch {
            Write-Output ("  失败：" + $f.Name + " — " + $_.Exception.Message)
            $failed++
        }
    }
}
Write-Output ""
Write-Output ("移动了 $moved 个" + $(if ($failed -gt 0) { "，$failed 个没动" } else { "" }))
