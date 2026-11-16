# 按文件类型（扩展名）把文件归到子目录（默认预览）
# 用法:
#   archive_by_type.ps1 -Path downloads              预览
#   archive_by_type.ps1 -Path downloads -Apply       真移动
#   archive_by_type.ps1 -Path downloads -Apply -GroupCustom "脚本=.ps1,.bat;配置=.json,.ini"
#                                 自定义分组（覆盖默认）
#
# 为什么要有这个：
#   之前只有 archive_by_date（按日期归），用户说「按类型归类」时
#   模型找不到对的技能，就只能硬用按日期的那个 —— 结果 14 个文件全进了
#   一个 2026-11/ 目录，看着像做了，其实归错了。

param(
    [string]$Path = '.',
    [switch]$Apply,
    [string]$GroupCustom = ''
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

# 默认分组：目录名 → 扩展名列表
$map = @{}
if ($GroupCustom) {
    foreach ($pair in ($GroupCustom -split ';')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $dirName = $kv[0].Trim()
        foreach ($e in ($kv[1] -split ',')) {
            $key = $e.Trim().ToLower()
            if (-not $key.StartsWith('.')) { $key = '.' + $key }
            if ($dirName) { $map[$key] = $dirName }
        }
    }
} else {
    $defaults = [ordered]@{
        '脚本' = @('.ps1', '.bat', '.cmd', '.sh', '.py', '.js', '.vbs')
        '配置' = @('.json', '.ini', '.cfg', '.conf', '.yaml', '.yml', '.xml', '.toml')
        '日志' = @('.log', '.txt.log')
        '数据' = @('.csv', '.tsv', '.jsonl', '.xlsx', '.xls', '.db', '.sqlite')
        '文档' = @('.txt', '.md', '.doc', '.docx', '.pdf', '.rtf')
        '压缩包' = @('.zip', '.7z', '.rar', '.tar', '.gz', '.bz2')
        '图片' = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.svg', '.webp', '.ico')
        '音视频' = @('.mp3', '.mp4', '.wav', '.avi', '.mkv', '.flac', '.mov')
        '表格' = @('.xlsx', '.xls', '.ods')
        '程序' = @('.exe', '.msi', '.dll', '.appx')
    }
    foreach ($k in $defaults.Keys) {
        foreach ($e in $defaults[$k]) { if (-not $map.ContainsKey($e)) { $map[$e] = $k } }
    }
}

$plan = @{}
$unknown = @()
foreach ($f in $files) {
    $ext = [IO.Path]::GetExtension($f.Name).ToLower()
    # 备份文件 a.txt.bak.20261116_041737 的 GetExtension 会给出奇怪的结果，
    # 扩展名长度超过 8 个字符的当"其他"处理
    $folder = $null
    if ($ext -and $ext.Length -le 9 -and $map.ContainsKey($ext)) {
        $folder = $map[$ext]
    } else {
        $folder = '其他'
    }
    if (-not $plan.ContainsKey($folder)) { $plan[$folder] = @() }
    $plan[$folder] += $f
}

Write-Output ($(if ($Apply) { "正在按类型归类" } else { "归类计划（预览，加 -Apply 才动）" }) + "：")
foreach ($k in ($plan.Keys | Sort-Object)) {
    Write-Output ("  " + $k + "/  ← " + $plan[$k].Count + " 个文件")
    if ($plan[$k].Count -le 6) {
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
