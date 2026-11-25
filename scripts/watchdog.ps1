# ============================================================
#  面板看门狗
#
#  问题：面板（monitor.ps1）偶尔会退出，用户看到的就是"面板突然没了"。
#  用户得手动重开，中间那段时间什么都看不到。
#
#  这个脚本做两件事：
#    1) 每 10 秒检查一次 8090 端口
#         - 端口在监听 → 什么都不做
#         - 端口没了   → 拉起来
#         - 连续拉起失败 3 次 → 记日志并放弃（别死循环刷进程）
#    2) 每 60 秒看一眼内存（8GB 机器上这个比面板挂掉更常见）
#         - llama-server 常驻内存 >= 5600 MB → 连续 2 次超阈值、且没有任务在跑，就只重启 llama-server
#           （5120 context + f16 时 llama 正常就吃 4600-4900 MB，所以阈值不能低于 5000，会误杀）
#         - 可用内存 < 400 MB 但 llama 没超标 → 只记一条日志（这句大概率是浏览器吃掉的，重启模型没用）
#         - 重启后 15 分钟内不再重启（冷却，避免来回折腾）
#       MemCheckSec = 0 可以关掉内存部分，只留原来的面板守护。
#
#  只做这两件事，故意写得很简单 —— 看门狗自己挂掉比面板挂掉更糟。
#
#  用法（不带参数就守护 8090，并开启内存监控）：
#    powershell -File scripts\watchdog.ps1
#    powershell -File scripts\watchdog.ps1 -Port 8090 -IntervalSec 10
#    powershell -File scripts\watchdog.ps1 -MemCheckSec 0      # 只看面板，不看内存
# ============================================================

param(
    [int]$Port = 8090,
    [int]$IntervalSec = 10,
    [int]$MemCheckSec = 60,
    [int]$LlamaMaxMB = 5600,
    [int]$FreeMinMB = 400,
    [int]$MemCooldownSec = 900,
    # 自动化（jobs.json）：每 SchedSec 秒 tick 一次；-NoSchedule 可以只守护面板
    [int]$SchedSec = 60,
    [switch]$NoSchedule
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

# --- 模型端口（重启后要等 /health，从 config.json 读）---
$ModelHost = '127.0.0.1'
$ModelPort = 8080
try {
    $cfgW = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfgW.host) { $ModelHost = [string]$cfgW.host }
    if ($cfgW.port) { $ModelPort = [int]$cfgW.port }
} catch { }

function Get-MemState {
    $m = [pscustomobject]@{ FreeMB = 0; LlamaMB = 0; LlamaCount = 0 }
    try {
        $m.FreeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
    } catch { }
    $procs = @(Get-Process llama-server -ErrorAction SilentlyContinue)
    $m.LlamaCount = $procs.Count
    if ($procs.Count -gt 0) {
        $m.LlamaMB = [math]::Round((($procs | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
    }
    return $m
}

# 有任务在跑就别重启模型，不然任务会半路死
function Test-Busy {
    $sf = Join-Path $Root 'agent\state.json'
    if (-not (Test-Path $sf)) { return $false }
    try {
        $s = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        $ph = [string]$s.phase
        if ($ph -like '正在*' -or $ph -like '第 *') { return $true }
        $st = [string]$s.status
        if ($st -eq 'running' -or $st -eq 'queued' -or $st -eq 'busy') { return $true }
    } catch { }
    return $false
}

# 只重启模型服务：kill llama-server → launcher -NoBrowser 拉起 → 等 /health
# 面板和配置都不动，也不会再多开一个浏览器窗口
function Restart-Llama {
    WLog '内存超阈值，重启 llama-server'
    Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill() } catch { }
    }
    Start-Sleep -Seconds 3
    $launcher = Join-Path $Root 'launcher.ps1'
    if (-not (Test-Path $launcher)) {
        WLog '找不到 launcher.ps1，放弃重启'
        return $false
    }
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $launcher, '-NoBrowser') `
            -WindowStyle Hidden
    } catch {
        WLog ('重启失败：' + $_.Exception.Message)
        return $false
    }
    $healthUrl = 'http://' + $ModelHost + ':' + $ModelPort + '/health'
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        try {
            if ((Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) {
                WLog 'llama-server 已恢复'
                return $true
            }
        } catch { }
    }
    WLog 'llama-server 重启后 120 秒仍未就绪'
    return $false
}

WLog ("看门狗启动，守护端口 $Port，每 $IntervalSec 秒检查一次")

# 自动化调度：不新开常驻进程，直接在守护循环里 tick。
# 加载失败不影响面板守护（调度是加分项，不是命脉）。
$SchedOn = $false
if (-not $NoSchedule) {
    $schedPath = Join-Path $Root 'scripts\scheduler.ps1'
    if (Test-Path $schedPath) {
        try {
            . $schedPath
            $SchedOn = $true
            WLog ('自动化调度器已挂上（每 ' + $SchedSec + ' 秒 tick）')
        } catch {
            WLog ('调度器加载失败：' + $_.Exception.Message)
        }
    }
}

$failStreak = 0
$lastMemCheck = Get-Date
$lastMemRestart = [datetime]::MinValue
$lastLowFreeLog = [datetime]::MinValue
$lastSched = [datetime]::MinValue
$memStreak = 0

while ($true) {

    # --- 自动化 tick：到点的 / 探针失败的 job 走面板队列或直跑 agent ---
    if ($SchedOn -and ((Get-Date) - $lastSched).TotalSeconds -ge $SchedSec) {
        $lastSched = Get-Date
        try { Invoke-SchedulerTick | Out-Null } catch { WLog ('调度 tick 出错：' + $_.Exception.Message) }
    }

    # --- 内存闸门：每 MemCheckSec 秒看一次，连续 2 次超阈值才动手 ---
    # 只有 llama 自己变大才重启它：重启只是把 llama 拉回 4.6-4.9 GB 的基线。
    # 如果可用内存低、但 llama 没超标，重启没用（省下的内存会被浏览器/system 吃掉），只记日志。
    if ($MemCheckSec -gt 0 -and ((Get-Date) - $lastMemCheck).TotalSeconds -ge $MemCheckSec) {
        $lastMemCheck = Get-Date
        $m = Get-MemState
        $overByLlama = ($m.LlamaMB -ge $LlamaMaxMB)
        $lowFreeButNormalLlama = ($m.FreeMB -lt $FreeMinMB -and $m.LlamaMB -lt 5000)
        if ($overByLlama) {
            $memStreak++
            WLog ('内存告警（llama 占用 ' + $m.LlamaMB + ' MB，超过 ' + $LlamaMaxMB + '，可用 ' + $m.FreeMB + ' MB），第 ' + $memStreak + ' 次')
            if ($memStreak -ge 2 -and $m.LlamaCount -gt 0) {
                if (((Get-Date) - $lastMemRestart).TotalSeconds -lt $MemCooldownSec) {
                    WLog '冷却期内，先不重启'
                } elseif (Test-Busy) {
                    WLog '有任务在跑，跳过本次重启'
                } else {
                    if (Restart-Llama) { $lastMemRestart = Get-Date }
                    $memStreak = 0
                }
            }
        } else {
            if ($lowFreeButNormalLlama -and ((Get-Date) - $lastLowFreeLog).TotalSeconds -ge 600) {
                $lastLowFreeLog = Get-Date
                WLog ('可用内存只有 ' + $m.FreeMB + ' MB，但 llama 占用正常（' + $m.LlamaMB + ' MB），不重启；建议关掉多余浏览器窗口')
            }
            $memStreak = 0
        }
    }

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
