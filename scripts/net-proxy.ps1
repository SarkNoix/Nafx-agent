# ============================================================
#  本机 HTTP 调试代理（Nafx net_proxy 的后台进程）
#
#  只监听 127.0.0.1，给「自己的服务」做联调：
#   · 记录每个请求（方法、URL、命中规则、状态、耗时）
#   · 按规则改写请求头 / 换目标地址 / 改请求体
#   · 按规则直接返回模拟响应（不转发）
#   · 按规则拦截（403）
#   · HTTPS 只做 CONNECT 隧道，不拆 TLS —— 也改写不了加密内容
#
#  用法：
#    powershell -File net-proxy.ps1 -Port 8899 -RulesFile rules.json -LogFile proxy.log.jsonl
#  规则文件每次请求都重新读，改完规则不用重启。
#
#  处理函数在 net-proxy-lib.ps1，主进程和每个 runspace 都会加载它。
# ============================================================
param(
    [int]$Port = 8899,
    [string]$RulesFile,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$libPath = Join-Path $PSScriptRoot 'net-proxy-lib.ps1'
if (-not (Test-Path -LiteralPath $libPath)) { throw "缺少 $libPath" }

$global:ProxyLogFile = if ($LogFile) { $LogFile } else { Join-Path $PSScriptRoot 'proxy.log.jsonl' }
$global:ProxyRulesFile = $RulesFile

. $libPath

# ---- 启动 ----
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()

# 一个浏览器会同时开好几条连接，串行处理会卡死 —— 用 8 个 runspace 并发
$pool = [runspacefactory]::CreateRunspacePool(1, 8)
$pool.Open()
$handlers = @()

while ($true) {
    $client = $listener.AcceptTcpClient()
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript({
        param($c, $lib, $log, $rules)
        . $lib
        $global:ProxyLogFile = $log
        $global:ProxyRulesFile = $rules
        Handle-Client $c
    }).AddArgument($client).AddArgument($libPath).AddArgument($global:ProxyLogFile).AddArgument($global:ProxyRulesFile)
    $h = $ps.BeginInvoke()
    $handlers += @{ ps = $ps; h = $h }

    if ($handlers.Count -gt 20) {
        # 已完成的连接必须 EndInvoke + Dispose，否则 PowerShell 对象和管道会一直堆着
        $alive = @()
        foreach ($item in $handlers) {
            if ($item.h.IsCompleted) {
                try { [void]$item.ps.EndInvoke($item.h) } catch { }
                try { $item.ps.Dispose() } catch { }
            } else {
                $alive += $item
            }
        }
        $handlers = $alive
    }
}

