# 检查某个端口通不通（TCP 连接测试 + 本机监听/占用进程）
# 用法: port_check.ps1 -Port 8090 [-Host 127.0.0.1] [-TimeoutMs 2000]

param(
    [int]$Port = 0,
    [string]$HostName = '127.0.0.1',
    [int]$TimeoutMs = 2000
)

if ($Port -lt 1 -or $Port -gt 65535) {
    Write-Output '要指定端口：-Port 8090'
    exit 1
}
$TimeoutMs = [Math]::Max(200, [Math]::Min(10000, $TimeoutMs))

# 1) TCP 握手
$sw = [Diagnostics.Stopwatch]::StartNew()
$ok = $false
$err = ''
try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect($HostName, $Port, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) { $ok = $true }
    $c.Close()
} catch { $err = $_.Exception.Message }
$sw.Stop()

if ($ok) {
    Write-Output ("{0}:{1} 通（TCP 握手 {2} ms）" -f $HostName, $Port, $sw.ElapsedMilliseconds)
} else {
    $why = if ($err) { $err } else { "连接超时/被拒（$TimeoutMs ms）" }
    Write-Output ("{0}:{1} 不通 —— {2}" -f $HostName, $Port, $why)
}

# 2) 本机监听与占用
$listen = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($listen.Count -gt 0) {
    Write-Output '本机在监听：'
    foreach ($l in ($listen | Select-Object -First 5)) {
        $pname = ''
        try { $pname = (Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
        Write-Output ("  TCP {0}:{1}  PID {2} {3}" -f $l.LocalAddress, $l.LocalPort, $l.OwningProcess, $pname)
    }
} else {
    Write-Output '本机没有进程在 Listen 这个 TCP 端口。'
}
$udp = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
if ($udp.Count -gt 0) {
    Write-Output ("UDP 也有 {0} 个端点在用这个端口。" -f $udp.Count)
}

if (-not $ok) {
    Write-Output '下一步：换 Host 再试；确认服务是否启动（net_ports 看监听）；防火墙/端口映射。'
    exit 1
}
