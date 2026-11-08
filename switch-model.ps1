# 换模型：列出可用模型，选一个写进配置并重启服务
# 支持 models 目录里的，也支持手动输入任意路径的 .gguf

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $Root 'config.json'
if (-not (Test-Path $cfgPath)) { Write-Host '找不到 config.json' -ForegroundColor Red; exit 1 }
$Cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$modelDir = Join-Path $Root 'models'
if (-not (Test-Path $modelDir)) { New-Item -ItemType Directory -Force -Path $modelDir | Out-Null }

# 可用内存（GB）
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$freeGB = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 0 }
$totalGB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 0 }

Write-Host ''
Write-Host '  换模型' -ForegroundColor Cyan
Write-Host '  ────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ("  内存：可用 {0} GB / 总共 {1} GB" -f $freeGB, $totalGB) -ForegroundColor DarkGray
Write-Host ''

$files = @(Get-ChildItem $modelDir -Filter *.gguf -ErrorAction SilentlyContinue | Sort-Object Length)
if ($files.Count -eq 0) {
    Write-Host '  models 目录里还没有模型文件。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  去这里下个 .gguf（推荐 Qwen3-4B-Instruct-2507-Q4_K_M）：' -ForegroundColor DarkGray
    Write-Host '    https://huggingface.co/bartowski/Qwen3-4B-Instruct-2507-GGUF' -ForegroundColor DarkGray
    Write-Host '  下好放进 models 目录，再运行本脚本。' -ForegroundColor DarkGray
    Write-Host ''
}

$curPath = ''
if ($Cfg.model) {
    try { $curPath = [IO.Path]::GetFullPath((Join-Path $Root ([string]$Cfg.model))) } catch { }
}

$i = 0
foreach ($f in $files) {
    $i++
    $mark = ''
    try { if ((Resolve-Path $f.FullName).Path -eq $curPath) { $mark = '  ← 当前' } } catch { }
    $sizeGB = $f.Length / 1GB
    $warn = ''
    if ($freeGB -gt 0 -and $sizeGB -gt ($freeGB * 0.85)) { $warn = '  ⚠ 可能放不下' }
    Write-Host ("  [{0}] {1,-42} {2,5:N1} GB{3}{4}" -f $i, $f.Name, $sizeGB, $mark, $warn) -ForegroundColor $(if ($warn) { 'Yellow' } else { 'White' })
}

Write-Host ''
Write-Host '  [0] 手动输入模型路径（放在别处的 .gguf）' -ForegroundColor DarkGray
Write-Host ''
Write-Host ('  线程数：' + $(if ($Cfg.threads -and [int]$Cfg.threads -gt 0) { [string]$Cfg.threads } else { '自动（按 CPU 核心数）' })) -ForegroundColor DarkGray
Write-Host ('  上下文：' + $Cfg.context + ' token') -ForegroundColor DarkGray
Write-Host ''

$pick = Read-Host '  输入序号切换（直接回车取消）'
if ([string]::IsNullOrWhiteSpace($pick)) { return }

$chosen = $null
$chosenRel = ''

if ($pick.Trim() -eq '0') {
    $manual = Read-Host '  把 .gguf 的完整路径粘进来'
    if ([string]::IsNullOrWhiteSpace($manual)) { return }
    $manual = $manual.Trim().Trim('"').Trim("'")
    if (-not (Test-Path -LiteralPath $manual)) {
        Write-Host ('  这个路径不存在：' + $manual) -ForegroundColor Red
        return
    }
    $chosen = Get-Item -LiteralPath $manual
    # 在 models 目录里就用相对路径，否则用绝对路径
    if ($chosen.FullName.StartsWith($modelDir, [StringComparison]::OrdinalIgnoreCase)) {
        $chosenRel = 'models\' + $chosen.Name
    } else {
        $chosenRel = $chosen.FullName
    }
} else {
    $n = 0
    if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $files.Count) {
        Write-Host '  序号不对' -ForegroundColor Red
        return
    }
    $chosen = $files[$n - 1]
    $chosenRel = 'models\' + $chosen.Name
}

# 大模型自动降上下文，免得内存爆掉
$sizeGB = [math]::Round($chosen.Length / 1GB, 1)
$newCtx = [int]$Cfg.context
$hint = ''
if ($freeGB -gt 0) {
    if ($sizeGB -gt ($freeGB * 0.85)) {
        $newCtx = [Math]::Max(2048, [int]($Cfg.context / 2))
        $hint = "模型较大，上下文自动降到 $newCtx（原来 $($Cfg.context)）"
    }
}

$Cfg.model = $chosenRel
$Cfg.modelLabel = $chosen.BaseName
if ($newCtx -ne [int]$Cfg.context) { $Cfg.context = $newCtx }
[IO.File]::WriteAllText($cfgPath, ($Cfg | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('  已选择：' + $chosen.Name + '  (' + $sizeGB + ' GB)') -ForegroundColor Green
if ($hint) { Write-Host ('  ' + $hint) -ForegroundColor Yellow }
Write-Host '  正在重启服务…' -ForegroundColor Yellow

# 停旧服务
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# 起新服务
Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'launcher.ps1'), '-NoBrowser' `
    -WindowStyle Hidden | Out-Null

$url = 'http://' + $Cfg.host + ':' + $Cfg.port + '/health'
$ok = $false
Write-Host '  等模型加载' -NoNewline
for ($k = 0; $k -lt 180; $k++) {
    Start-Sleep -Seconds 1
    if ($k % 5 -eq 0) { Write-Host '.' -NoNewline }
    try { if ((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $ok = $true; break } } catch { }
}
Write-Host ''

# 面板也重启一下，让它读新配置
$port = if ($Cfg.monitorPort) { [int]$Cfg.monitorPort } else { 8090 }
try {
    Invoke-WebRequest ('http://' + $Cfg.host + ':' + $port + '/api/restart') -Method POST -UseBasicParsing -TimeoutSec 3 | Out-Null
} catch { }

Write-Host ''
if ($ok) {
    Write-Host '  服务已就绪。' -ForegroundColor Green
    Write-Host ('  面板：http://' + $Cfg.host + ':' + $port) -ForegroundColor DarkGray
} else {
    Write-Host '  服务没起来。看看 logs\server.err.log，或者模型文件和内存是不是有问题。' -ForegroundColor Red
}
Write-Host ''
