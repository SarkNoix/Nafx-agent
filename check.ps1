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

function Test-Url([string]$u) {
    try { return ((Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) }
    catch { return $false }
}

$rows = @()
$rows += [pscustomobject]@{ 项目 = '模型文件'; 状态 = $(if (Test-Path $model) { '正常' } else { '缺失' }); 说明 = $model }
$rows += [pscustomobject]@{ 项目 = '推理服务'; 状态 = $(if (Test-Url $modelUrl) { '在线' } else { '未启动' }); 说明 = "端口 $($Cfg.port)" }
$rows += [pscustomobject]@{ 项目 = '监视面板'; 状态 = $(if (Test-Url $panelUrl) { '在线' } else { '未启动' }); 说明 = "端口 $($Cfg.monitorPort)" }
$rows += [pscustomobject]@{ 项目 = '工作目录'; 状态 = $(if (Test-Path $ws) { '正常' } else { '缺失' }); 说明 = $ws }
$rows += [pscustomobject]@{ 项目 = 'llama 程序'; 状态 = $(if (Test-Path (Join-Path $Root 'llama\llama-server.exe')) { '正常' } else { '缺失' }); 说明 = 'llama\llama-server.exe' }

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
