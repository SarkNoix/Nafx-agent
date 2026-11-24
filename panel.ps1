param([ValidateSet('start', 'stop', 'restart', 'status')][string]$Action = 'status')

# 管理 Nafx 面板进程（用 PID 文件，避免命令行匹配误杀）
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg     = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Url     = "http://$($Cfg.host):$($Cfg.monitorPort)/"
$PidFile = Join-Path $Root 'agent\panel.pid'

function Get-PanelPid {
    if (-not (Test-Path $PidFile)) { return 0 }
    $txt = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue)
    $n = 0
    if ([int]::TryParse(($txt -replace '\s', ''), [ref]$n)) { return $n }
    return 0
}

function Test-Up {
    try { return ((Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) } catch { return $false }
}

function Test-IsPanelProcess($proc) {
    if (-not $proc) { return $false }
    if ($proc.ProcessName -notin @('powershell', 'pwsh')) { return $false }
    $info = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
    return [bool]($info -and $info.CommandLine -and $info.CommandLine -like '*monitor.ps1*')
}

function Stop-Panel {
    $panelId = Get-PanelPid
    $stopped = $false
    $psProcs = @()
    foreach ($name in @('powershell.exe', 'pwsh.exe')) {
        $psProcs += Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue
    }
    # 先停看门狗。否则杀掉面板 10 秒后它又会被拉起来，用户以为“停止服务”没生效。
    $psProcs | Where-Object { $_.CommandLine -and $_.CommandLine -like '*watchdog.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    if ($panelId -gt 0) {
        $p = Get-Process -Id $panelId -ErrorAction SilentlyContinue
        # 只杀命令行确实是 monitor.ps1 的进程；pid 文件过期时不能误杀同号进程。
        if (Test-IsPanelProcess $p) { try { $p.Kill(); $stopped = $true } catch { } }
    }
    if (-not $stopped) {
        # pid 缺失或过期时退回命令行匹配，兼容 powershell.exe 和 pwsh.exe。
        $psProcs | Where-Object { $_.CommandLine -and $_.CommandLine -like '*monitor.ps1*' -and $_.ProcessId -ne $PID } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

switch ($Action) {
    'status' {
        if (Test-Up) { Write-Host "面板运行中：$Url" -ForegroundColor Green }
        else { Write-Host '面板没有运行' -ForegroundColor Yellow }
    }
    'stop' {
        Stop-Panel
        if (Test-Up) { Write-Host '停止失败（可能是别的实例占着端口）' -ForegroundColor Red }
        else { Write-Host '面板已停止' -ForegroundColor Green }
    }
    'start' {
        if (Test-Up) { Write-Host "面板已在运行：$Url" -ForegroundColor Green; break }
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'monitor.ps1') `
            -WindowStyle Hidden | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Up) { break }
        }
        if (Test-Up) { Write-Host "面板已启动：$Url" -ForegroundColor Green }
        else { Write-Host '面板启动失败' -ForegroundColor Red; exit 1 }
    }
    'restart' {
        Stop-Panel
        & $PSCommandPath -Action start
    }
}
