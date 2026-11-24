# Nafx 自检：看服务、目录、模型是否正常
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-AppPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    return [IO.Path]::GetFullPath((Join-Path $Root $p))
}

$model = Resolve-AppPath $Cfg.model
$ws = Resolve-AppPath $Cfg.workspace
$modelUrl = "http://$($Cfg.host):$($Cfg.port)/health"
$panelUrl = "http://$($Cfg.host):$($Cfg.monitorPort)/"

# 和 launcher.ps1 用同一套 llama 目录规则：cpu 用 llama\，gpu 用 llama-gpu\。
$llamaMode = if ($Cfg.llamaMode) { [string]$Cfg.llamaMode } else { 'cpu' }
$llamaDir  = if ($llamaMode -eq 'gpu') {
    if ($Cfg.llamaGpuDir) { [string]$Cfg.llamaGpuDir } else { 'llama-gpu' }
} else {
    if ($Cfg.llamaCpuDir) { [string]$Cfg.llamaCpuDir } else { 'llama' }
}
$llamaServer = Join-Path $Root ($llamaDir.Trim('\') + '\llama-server.exe')
$modelMode = if ($Cfg.modelMode) { [string]$Cfg.modelMode } else { 'local' }

function Test-Url([string]$u) {
    try { return ((Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) }
    catch { return $false }
}

$rows = @()
if ($modelMode -eq 'api') {
    $rows += [pscustomobject]@{ 项目 = '模型文件'; 状态 = '不需要'; 说明 = '接口模式，用远端模型' }
} else {
    $rows += [pscustomobject]@{ 项目 = '模型文件'; 状态 = $(if (Test-Path $model) { '正常' } else { '缺失' }); 说明 = $model }
}
$rows += [pscustomobject]@{ 项目 = '推理服务'; 状态 = $(if ($modelMode -eq 'api') { '不需要' } elseif (Test-Url $modelUrl) { '在线' } else { '未启动' }); 说明 = $(if ($modelMode -eq 'api') { [string]$Cfg.apiBase } else { "端口 $($Cfg.port)" }) }
$rows += [pscustomobject]@{ 项目 = '监视面板'; 状态 = $(if (Test-Url $panelUrl) { '在线' } else { '未启动' }); 说明 = "端口 $($Cfg.monitorPort)" }
$rows += [pscustomobject]@{ 项目 = '工作目录'; 状态 = $(if (Test-Path $ws) { '正常' } else { '缺失' }); 说明 = $ws }
if ($modelMode -eq 'api') {
    $rows += [pscustomobject]@{ 项目 = 'llama 程序'; 状态 = '不需要'; 说明 = '接口模式，不走本地 llama' }
} else {
    $rows += [pscustomobject]@{ 项目 = 'llama 程序'; 状态 = $(if (Test-Path $llamaServer) { '正常' } else { '缺失' }); 说明 = ($llamaDir.Trim('\') + '\llama-server.exe') }
}

Write-Host ''
Write-Host '  Nafx 自检' -ForegroundColor Cyan
Write-Host '  ────────────────────────────────────────────' -ForegroundColor DarkGray
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$pids = Get-Process llama-server -ErrorAction SilentlyContinue
if ($pids) {
    foreach ($p in $pids) {
        Write-Host ("  llama-server 运行中，PID $($p.Id)，内存 " + [math]::Round($p.WorkingSet64 / 1MB) + ' MB') -ForegroundColor DarkGray
    }
}

$bad = @($rows | Where-Object { $_.状态 -in @('缺失', '未启动') })
if ($bad.Count -gt 0) {
    Write-Host ''
    Write-Host '  有项目不正常。可以双击 Nafx.bat 重新拉起服务。' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host '  一切正常，去浏览器打开面板就能用。' -ForegroundColor Green
}
Write-Host ''
