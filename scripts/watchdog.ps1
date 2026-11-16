# ============================================================
#  面板看门狗
#
#  问题：面板（monitor.ps1）偶尔会退出，用户看到的就是"面板突然没了"。
#  用户得手动重开，中间那段时间什么都看不到。
#
#  这个脚本每 10 秒检查一次 8090 端口。
#    - 端口在监听 → 什么都不做
#    - 端口没了   → 拉起来
#    - 连续拉起失败 3 次 → 记日志并放弃（别死循环刷进程）
#
#  只做这一件事，故意写得很简单 —— 看门狗自己挂掉比面板挂掉更糟。
#
#  用法（不带参数就守护 8090）：
#    powershell -File scripts\watchdog.ps1
#    powershell -File scripts\watchdog.ps1 -Port 8090 -IntervalSec 10
# ============================================================

param(
    [int]$Port = 8090,
    [int]$IntervalSec = 10
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path $PSScriptRoot -Parent
$Mon  = Join-Path $Root 'monitor.ps1'
$LogDir = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir 'watchdog.log'

function WLog {
    param([string]$Text)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Text)
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Test-Panel {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $t = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $t.AsyncWaitHandle.WaitOne(1500)
        if ($ok -and $c.Connected) { $c.Close(); return $true }
        $c.Close()
    } catch { }
    return $false
}

WLog ("看门狗启动，守护端口 $Port，每 $IntervalSec 秒检查一次")

$failStreak = 0

while ($true) {
    if (Test-Panel) {
        $failStreak = 0
        Start-Sleep -Seconds $IntervalSec
        continue
    }

    # 端口不通：确认不是已有进程在启动中
    Start-Sleep -Seconds 2
    if (Test-Panel) {
        Start-Sleep -Seconds $IntervalSec
        continue
    }

    WLog '面板没有响应，尝试拉起'
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $Mon) `
            -WindowStyle Hidden
    } catch {
        WLog ('拉起失败：' + $_.Exception.Message)
    }

    # 给面板 40 秒启动
    $started = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Panel) { $started = $true; break }
    }

    if ($started) {
        WLog '面板已恢复'
        $failStreak = 0
    } else {
        $failStreak++
        WLog ('拉起后仍不通（第 ' + $failStreak + ' 次）')
        if ($failStreak -ge 3) {
            WLog '连续 3 次拉不起来，看门狗退出。请手动检查。'
            break
        }
        Start-Sleep -Seconds 15
    }
}
