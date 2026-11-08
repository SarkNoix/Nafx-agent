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

function Stop-Panel {
    $panelId = Get-PanelPid
    if ($panelId -gt 0) {
        $p = Get-Process -Id $panelId -ErrorAction SilentlyContinue
        if ($p) { try { $p.Kill() } catch { } }
    } else {
        # 没有 pid 文件时退回命令行匹配（排除自己）
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*-File*monitor.ps1*' -and $_.ProcessId -ne $PID } |
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
