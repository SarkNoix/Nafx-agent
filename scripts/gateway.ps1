# ============================================================
#  Nafx 网关启动器（80 端口 · 负载均衡 · 监控）
#
#  对应脚本：scripts\gateway.js（Node 写的转发 + 限流 + 指标）
#
#  做的事：
#    1) 检查管理员权限（80 是系统端口，普通权限绑不上）
#    2) 检查 node 在不在、端口有没有被占用（占了就说清是谁占的）
#    3) 后台隐藏启动 gateway.js，等端口真的监听上再报成功
#    4) PID 写进 logs\gateway.pid，-Stop 用它来收
#
#  用法：
#    powershell -File scripts\gateway.ps1             # 后台启动（默认）
#    powershell -File scripts\gateway.ps1 -Status     # 看状态 + 指标
#    powershell -File scripts\gateway.ps1 -Stop       # 停掉
#    powershell -File scripts\gateway.ps1 -Foreground # 前台跑（调试看日志）
#    powershell -File scripts\gateway.ps1 -Port 8088  # 换端口
# ============================================================

param(
    [int]$Port = 80,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Foreground,
    [string]$Node = 'E:\Node\node.exe'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$GwJs = Join-Path $PSScriptRoot 'gateway.js'
$PidFile = Join-Path $Root 'logs\gateway.pid'
$OutLog = Join-Path $Root 'logs\gateway.out.log'
$ErrLog = Join-Path $Root 'logs\gateway.err.log'

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GwPid {
    if (-not (Test-Path $PidFile)) { return 0 }
    $p = 0
    try { $p = [int]((Get-Content $PidFile -Raw).Trim()) } catch { }
    if ($p -le 0) { return 0 }
    if (-not (Get-Process -Id $p -ErrorAction SilentlyContinue)) { return 0 }
    return $p
}

function Test-PortUp {
    param([int]$P, [int]$Ms = 300)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.BeginConnect('127.0.0.1', $P, $null, $null)
        $ok = $t.AsyncWaitHandle.WaitOne($Ms)
        return ($ok -and $c.Connected)
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Get-Stats {
    try {
        $r = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/__gateway/stats') -TimeoutSec 3
        return $r
    } catch { return $null }
}

# ---------------- -Status ----------------
if ($Status) {
    $pidGw = Get-GwPid
    "网关进程：" + $(if ($pidGw) { "运行中 pid=$pidGw" } else { '没在运行' })
    "端口 " + $Port + " 监听：" + (Test-PortUp -P $Port -Ms 500)
    $s = Get-Stats
    if ($s) {
        "运行时长：" + $s.gateway.uptimeSec + " 秒；空闲内存 " + $s.host.freeMB + "/" + $s.host.totalMB + " MB"
        foreach ($n in @('panel', 'model')) {
            $b = $s.backends.$n
            ("{0,-6} 目标 {1,-14} 存活 {2,-5} 在途 {3}/{4} 排队 {5} 均延迟 {6}ms 错误率 {7} 累计 {8} 请求" -f `
                $n, $b.target, $b.alive, $b.inflight, $b.limit, $b.queued,
                $(if ($null -ne $b.ewmaMs) { $b.ewmaMs } else { '-' }), $b.errRate, $b.totalReq)
        }
    } else {
        '（拿不到指标：网关没起，或者 /__gateway/stats 不通）'
    }
    return
}

# ---------------- -Stop ----------------
if ($Stop) {
    $pidGw = Get-GwPid
    if ($pidGw) {
        Stop-Process -Id $pidGw -Force -ErrorAction SilentlyContinue
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        "已停止 gateway（pid=$pidGw）"
    } else {
        # PID 文件丢了也尽量捞回来：找命令行里带 gateway.js 的 node
        $stray = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'gateway\.js' }
        if ($stray) {
            foreach ($p in $stray) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            "已停止残留的 gateway 进程：" + (($stray | ForEach-Object { $_.ProcessId }) -join ',')
        } else {
            '没有在运行的网关'
        }
    }
    return
}

# ---------------- 启动 ----------------

if (-not (Test-Path $Node)) { throw "找不到 node：$Node" }
if (-not (Test-Path $GwJs)) { throw "找不到 gateway.js：$GwJs" }

if ($Port -lt 1024 -and -not (Test-IsAdmin)) {
    throw "端口 $Port 是系统端口，需要管理员权限。请用「以管理员身份运行」打开 PowerShell 再执行。"
}

$existing = Get-GwPid
if ($existing) {
    "网关已经在跑（pid=$existing）。要重启先 -Stop。"
    return
}

if (Test-PortUp -P $Port -Ms 500) {
    $owner = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $name = if ($owner) { (Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue).ProcessName } else { '未知' }
    throw "端口 $Port 已被占用（$name）。先腾出来，或者用 -Port 换一个。"
}

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null

if ($Foreground) {
    "前台运行网关，Ctrl+C 结束（端口 $Port）"
    & $Node $GwJs --port $Port
    return
}

$proc = Start-Process -FilePath $Node -ArgumentList @($GwJs, '--port', "$Port") `
    -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII

$up = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ($proc.HasExited) { break }
    if (Test-PortUp -P $Port -Ms 200) { $up = $true; break }
}

if ($up) {
    "网关已启动：http://127.0.0.1:$Port  pid=$($proc.Id)"
    $st = Get-Stats
    if ($st) {
        if ($st.modelMode -eq 'api') {
            "  面板（/、/api/*）→ 8090 ；模型（/v1/*）→ $($st.backends.model.target)（$($st.modelLabel)）"
        } else {
            "  面板（/、/api/*）→ 8090 ；本地模型（/v1/*、/health）→ $($st.backends.model.target)"
        }
    }
    $statsUrl = 'http://127.0.0.1:' + $Port + '/__gateway/stats'
    "  指标：$statsUrl"
    "  日志：logs\gateway.jsonl（请求级）、logs\gateway-stats.json（每 10 秒汇总）"
} else {
    $err = ''
    if (Test-Path $ErrLog) { $err = (Get-Content $ErrLog -Tail 8) -join "`n" }
    throw "网关没起来（pid=$($proc.Id) 已退出或端口未监听）。错误输出：`n$err"
}
