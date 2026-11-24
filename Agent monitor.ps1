# ============================================================
#  Nafx · Agent monitor
#
#  一个只读的实时监控窗口：面板、llama、模型、tools 的日志和状态。
#  由 Nafx.bat 启动；也可以单独运行：
#    powershell -ExecutionPolicy Bypass -File "Agent monitor.ps1"
#  按 Q 退出；按 Ctrl+C 也可以。
# ============================================================

param(
    [switch]$Once
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
try { $Host.UI.RawUI.WindowTitle = 'Agent monitor' } catch { }

$CfgPath = Join-Path $Root 'config.json'
$Cfg = $null
try { $Cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Cfg = $null }
if (-not $Cfg) { $Cfg = [pscustomobject]@{} }

function Get-CfgString([string]$Name, [string]$Default) {
    $v = [string]$Cfg.$Name
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

$HostName   = Get-CfgString 'host' '127.0.0.1'
$ProbeHost  = if ($HostName -in @('0.0.0.0', '::', '[::]')) { '127.0.0.1' } else { $HostName }
$ModelPort  = [int](Get-CfgString 'port' '8080')
$PanelPort  = [int](Get-CfgString 'monitorPort' '8090')
$ModelUrl   = 'http://' + $ProbeHost + ':' + $ModelPort
$PanelUrl   = 'http://' + $ProbeHost + ':' + $PanelPort
$ModelMode  = (Get-CfgString 'modelMode' 'local').ToLower()
$LlamaMode  = (Get-CfgString 'llamaMode' 'cpu').ToLower()
$LlamaDir   = if ($LlamaMode -eq 'gpu') { Get-CfgString 'llamaGpuDir' 'llama-gpu' } else { Get-CfgString 'llamaCpuDir' 'llama' }
$ModelLabel = Get-CfgString 'modelLabel' (Get-CfgString 'model' 'model')

$PanelLog   = Join-Path $Root 'logs\panel\panel.log'
$ReqLog     = Join-Path $Root 'logs\panel\requests.log'
$LlamaErr   = Join-Path $Root 'logs\server.err.log'
$LlamaOut   = Join-Path $Root 'logs\server.out.log'
$WarmupLog  = Join-Path $Root 'logs\warmup.log'
$WatchLog   = Join-Path $Root 'logs\watchdog.log'
$RunLogDir  = Join-Path $Root 'agent\logs'
$HistoryLog = Join-Path $RunLogDir 'history.jsonl'
$StateFile  = Join-Path $Root 'agent\state.json'
$ToolsFile  = Join-Path $Root 'agent\tools-schema.json'
$FlowsFile  = Join-Path $Root 'agent\flows.json'

function Test-Url([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Get-Json([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200 -and $r.Content) { return ($r.Content | ConvertFrom-Json) }
    } catch { }
    return $null
}

function Get-LogLines([string]$Path, [int]$Count) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        return @(Get-Content -LiteralPath $Path -Tail $Count -Encoding UTF8 -ErrorAction Stop |
                 Where-Object { $_.Trim() })
    } catch { return @() }
}

function Get-Clip([string]$Text, [int]$Width) {
    if ($null -eq $Text) { return '' }
    $s = ([string]$Text).Replace("`r", ' ').Replace("`n", ' ').TrimEnd()
    if ($s.Length -gt $Width) { return $s.Substring(0, [Math]::Max(1, $Width - 1)) + '…' }
    return $s
}

function Get-LatestRun {
    $runs = @(Get-ChildItem -LiteralPath $RunLogDir -Filter 'run_*.txt' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($runs.Count -gt 0) { return $runs[0].FullName }
    return ''
}

function Get-LatestTaskLine {
    $state = $null
    try { if (Test-Path -LiteralPath $StateFile) { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    if ($state -and ([string]$state.status -in @('running', 'queued', 'busy') -or [string]$state.phase -like '正在*')) {
        $step = if ($state.step) { [string]$state.step } else { '?' }
        $task = if ($state.task) { [string]$state.task } else { '' }
        return ('运行中 · ' + $task + ' · 第 ' + $step + ' 步')
    }
    try {
        if (Test-Path -LiteralPath $HistoryLog) {
            $line = Get-Content -LiteralPath $HistoryLog -Tail 1 -Encoding UTF8
            if ($line) {
                $h = $line | ConvertFrom-Json
                $steps = if ($h.steps) { @($h.steps).Count } else { 0 }
                return ('最近 · ' + [string]$h.ts + ' ' + [string]$h.status + ' · ' +
                        [string]$h.task + ' · ' + [string]$h.elapsed + 's · ' + $steps + ' 步')
            }
        }
    } catch { }
    return '暂无任务记录'
}

function Get-ToolCount {
    try {
        if (Test-Path -LiteralPath $ToolsFile) {
            $tj = Get-Content $ToolsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return @($tj).Count
        }
    } catch { }
    return 0
}

function Get-FlowCount {
    try {
        if (Test-Path -LiteralPath $FlowsFile) {
            $fj = Get-Content $FlowsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($fj -and $fj.flows) { return @($fj.flows).Count }
        }
    } catch { }
    return 0
}

function Get-PanelPid {
    try {
        $p = Join-Path $Root 'agent\panel.pid'
        if (Test-Path -LiteralPath $p) {
            $n = 0
            if ([int]::TryParse((Get-Content -LiteralPath $p -Raw).Trim(), [ref]$n)) { return $n }
        }
    } catch { }
    return 0
}

function Write-Section([string]$Name, [string]$Path, [string[]]$Lines, [ConsoleColor]$Color, [int]$Width) {
    $leaf = if ($Path) { Split-Path -Leaf $Path } else { '—' }
    Write-Host ('  [' + $Name + '] ' + $leaf) -ForegroundColor $Color
    if (-not $Lines -or @($Lines).Count -eq 0) {
        Write-Host '    （暂无日志）' -ForegroundColor DarkGray
        return
    }
    foreach ($line in @($Lines)) {
        $text = Get-Clip $line $Width
        $lineColor = 'Gray'
        if ($text -match '(?i)ERROR|FAIL|ERROR|错误|失败|异常') { $lineColor = 'Red' }
        elseif ($text -match '(?i)WARN|WARNING|警告|慢请求') { $lineColor = 'Yellow' }
        Write-Host ('    ' + $text) -ForegroundColor $lineColor
    }
}

function Show-Frame {
    $width = 100
    $height = 30
    try {
        $width = [Math]::Max(70, [Console]::WindowWidth - 1)
        $height = [Math]::Max(24, [Console]::WindowHeight)
    } catch { }
    $logWidth = [Math]::Max(50, $width - 6)
    $linesPer = 3
    if ($height -ge 38) { $linesPer = 4 }
    if ($height -ge 46) { $linesPer = 5 }

    $panelSys = Get-Json ($PanelUrl + '/api/system')
    $panelUp = ($null -ne $panelSys) -or (Test-Url ($PanelUrl + '/'))
    $panelPid = Get-PanelPid
    $modelUp = if ($ModelMode -eq 'api') { $true } else { Test-Url ($ModelUrl + '/health') }
    $llama = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    $llamaMb = 0
    if ($llama.Count -gt 0) {
        $llamaMb = [int][Math]::Round((($llama | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
    }
    $toolCount = Get-ToolCount
    $flowCount = Get-FlowCount
    $taskLine = Get-LatestTaskLine
    $latestRun = Get-LatestRun
    $ctxValue = if ($panelSys -and $null -ne $panelSys.context) { [string]$panelSys.context } else { Get-CfgString 'context' '—' }
    $slotsValue = if ($panelSys -and $null -ne $panelSys.slotsReady) { [string]$panelSys.slotsReady } else { '—' }
    $promptValue = if ($panelSys -and $null -ne $panelSys.promptTokens) { [string]$panelSys.promptTokens } else { '—' }
    $toolTokenValue = if ($panelSys -and $null -ne $panelSys.toolTokens) { [string]$panelSys.toolTokens } else { '—' }
    $timeText = (Get-Date).ToString('HH:mm:ss')

    try { Clear-Host } catch { }

    Write-Host ('  Nafx · Agent monitor' + (' ' * 6) + $timeText) -ForegroundColor Cyan
    Write-Host ('  项目   ' + (Get-Clip $Root ($width - 9))) -ForegroundColor DarkGray
    Write-Host ('  面板   ' + $(if ($panelUp) { '● 在线' } else { '○ 未启动' }) +
                '   ' + $PanelUrl + '   PID ' + $(if ($panelPid -gt 0) { $panelPid } else { '—' })) `
               -ForegroundColor $(if ($panelUp) { 'Green' } else { 'Red' })
    if ($ModelMode -eq 'api') {
        Write-Host ('  Llama   接口模式，不走本地 llama   ' + (Get-CfgString 'apiBase' '')) -ForegroundColor Yellow
    } elseif ($llama.Count -gt 0) {
        Write-Host ('  Llama   ● 运行   PID ' + (($llama | Select-Object -First 1).Id) +
                    '   ' + $llamaMb + ' MB   ' + $LlamaMode + '\llama-server.exe') -ForegroundColor Green
    } else {
        Write-Host ('  Llama   ○ 未运行   ' + $LlamaDir + '\llama-server.exe') -ForegroundColor Red
    }
    Write-Host ('  模型    ' + $ModelLabel + '   ' + $ModelMode + '   ' + $ModelUrl + '   ' +
                $(if ($modelUp) { '● ok' } else { '○ 未就绪' })) `
               -ForegroundColor $(if ($modelUp) { 'Green' } else { 'Red' })
    Write-Host ('  运行    ctx ' + $ctxValue + ' · slots ' + $slotsValue +
                ' · prompt ' + $promptValue + ' tok · tools ' + $toolTokenValue + ' tok') -ForegroundColor DarkGray
    Write-Host ('  工具    ' + $toolCount + ' 个 / ' + $flowCount + ' 个流程   ' + (Get-Clip $taskLine $logWidth)) `
               -ForegroundColor Gray
    Write-Host ('  ' + ('─' * $width)) -ForegroundColor DarkGray

    $panelLines = @(Get-LogLines $PanelLog $linesPer)
    $llamaPath = if ((Test-Path $LlamaErr) -and ((Get-Item $LlamaErr).Length -gt 0)) { $LlamaErr } else { $LlamaOut }
    $llamaLines = @(Get-LogLines $llamaPath $linesPer)
    $modelLines = @(Get-LogLines $WarmupLog ([Math]::Max(2, $linesPer - 1)))
    $toolPath = if ($latestRun) { $latestRun } else { $HistoryLog }
    $toolLines = @(Get-LogLines $toolPath ([Math]::Max(3, $linesPer + 1)))

    Write-Section '面板' $PanelLog $panelLines Cyan $logWidth
    Write-Section 'Llama' $llamaPath $llamaLines Magenta $logWidth
    Write-Section '模型' $WarmupLog $modelLines Blue $logWidth
    Write-Section 'Tools' $toolPath $toolLines Yellow $logWidth
    Write-Host ('  每 2 秒刷新 · Q 退出 · 只读监控（不改配置、不启停服务）') -ForegroundColor DarkGray
}

if ($Once) {
    Show-Frame
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\NafxAgentMonitor')
$locked = $false
$oldCursor = $true
try {
    if (-not $mutex.WaitOne(0)) { exit 0 }
    $locked = $true
    try { $oldCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
    $running = $true
    while ($running) {
        Show-Frame
        $until = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $until) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') { $running = $false; break }
                }
            } catch { }
            Start-Sleep -Milliseconds 120
        }
    }
} catch {
    Write-Host ''
    Write-Host ('  Agent monitor 出错：' + $_.Exception.Message) -ForegroundColor Red
    if (-not $Once) { Write-Host '  按 Enter 关闭' -ForegroundColor DarkGray; [void](Read-Host) }
} finally {
    try { [Console]::CursorVisible = $oldCursor } catch { }
    if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
