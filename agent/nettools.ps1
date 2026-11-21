# ============================================================
#  网络工具：抓包 / 代理拦截改写 / 发包 / 本地 HTTP 调试 / 端口
#
#  设计原则：
#   · 全部是「本机自己调试自己的服务」用的，绝不做别人的中间人；
#   · 代理只监听 127.0.0.1；HTTPS 只做 CONNECT 隧道，不解密；
#   · 抓包用系统自带 pktmon（需要管理员），产物落 workspace\net；
#   · 每个工具都返回人话总结 + 文件路径，让模型能看懂再决定下一步。
#
#  由 tools.ps1 dot-source 进来，函数名统一 Invoke-Net*。
# ============================================================

function Get-NetDir {
    $root = $script:AiRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = 'E:\Nafx\workspace' }
    $dir = Join-Path $root 'net'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-NetStamp { Get-Date -Format 'yyyyMMdd_HHmmss' }

function Resolve-NetOutPath($rel, $defaultName) {
    $dir = Get-NetDir
    if ([string]::IsNullOrWhiteSpace($rel)) { return (Join-Path $dir $defaultName) }
    $rel = ([string]$rel).Trim()
    if ([IO.Path]::IsPathRooted($rel)) {
        # 只允许落在 workspace\net 里，别把抓包文件写到系统目录
        $full = [IO.Path]::GetFullPath($rel)
        if (-not $full.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
            throw "抓包文件只能放在 $dir 里。给相对路径就行，比如 capture.pcapng"
        }
        return $full
    }
    return (Join-Path $dir $rel)
}

function Format-NetSize($n) {
    if ($n -lt 1024) { return "$n B" }
    if ($n -lt 1048576) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return ('{0:N1} MB' -f ($n / 1MB))
}

function Get-NetPreview($text, $max) {
    if ($null -eq $text) { return '' }
    $t = [string]$text
    if ($t.Length -le $max) { return $t }
    return $t.Substring(0, $max) + "…（还有 $($t.Length - $max) 字符，已截断）"
}

function ConvertTo-NetHex($bytes) {
    if (-not $bytes) { return '' }
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
}

# ------------------------------------------------------------
# 1) net_http：发 HTTP 请求（允许本机 / 内网，专门用来调自己的服务）
# ------------------------------------------------------------
function Invoke-NetHttp($Action) {
    $url = ([string]$Action.url).Trim()
    if ([string]::IsNullOrWhiteSpace($url)) { throw '要给 url，比如 http://127.0.0.1:8090/' }
    if ($url -notmatch '^https?://') { $url = 'http://' + $url }

    $method = ([string]$Action.method).Trim().ToUpperInvariant()
    if (-not $method) { $method = 'GET' }
    if ($method -notin @('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS')) {
        throw "method 只能是 GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS，收到：$method"
    }

    $timeout = 0
    try { $timeout = [int]$Action.timeout } catch { }
    if ($timeout -le 0) { $timeout = 15 }
    if ($timeout -gt 60) { $timeout = 60 }

    # 链接到 169.254（云元数据）这种不是「自己的服务」，挡掉
    $h = $url -replace '^https?://', ''
    if ($h -match '^\[([^\]]+)\]') { $h = $matches[1] } else { $h = ($h -replace '[/?#].*$', '') -replace ':\d+$', '' }
    if ($h -match '^169\.254\.') { throw '不允许访问 169.254.*（云主机元数据地址），这不是你自己的服务。' }

    $body = [string]$Action.body
    $ct = [string]$Action.contentType
    if (-not $ct -and $body) { $ct = 'application/json; charset=utf-8' }

    $headers = @{}
    if ($Action.headers) {
        $hh = $Action.headers
        if ($hh -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($hh)) { $hh = $hh | ConvertFrom-Json } else { $hh = $null }
        }
        if ($hh) { foreach ($p in $hh.PSObject.Properties) { $headers[[string]$p.Name] = [string]$p.Value } }
    }

    $insecure = [bool]$Action.insecure
    $maxBody = 4000
    try { if ($Action.maxBody -gt 0) { $maxBody = [int]$Action.maxBody } } catch { }
    if ($maxBody -gt 20000) { $maxBody = 20000 }

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $proxyUrl = ([string]$Action.proxy).Trim()
    if ($proxyUrl) {
        $handler.Proxy = New-Object System.Net.WebProxy($proxyUrl)
        $handler.UseProxy = $true
    }
    if ($insecure) {
        # 只用于本机自签证书调试
        $handler.ServerCertificateCustomValidationCallback = { param($m,$c,$ch,$e) return $true }
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($method), $url)
    foreach ($k in $headers.Keys) {
        [void]$req.Headers.TryAddWithoutValidation($k, $headers[$k])
    }
    if ($body) {
        $content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, $(if ($ct) { $ct } else { 'application/json' }))
        $req.Content = $content
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    } catch {
        throw ("请求没发出去：" + $_.Exception.Message + "。检查地址、端口、服务是否在跑。")
    } finally {
        $sw.Stop()
    }

    $status = [int]$resp.StatusCode
    $reason = [string]$resp.ReasonPhrase
    $bytes = $null
    $text = ''
    try {
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($bytes -and $bytes.Length -le 200000) {
            $text = [Text.Encoding]::UTF8.GetString($bytes)
        } elseif ($bytes) {
            $text = '[响应体 ' + (Format-NetSize $bytes.Length) + '，太大不展开，已存文件]'
        }
    } catch { }

    $hdrs = @()
    foreach ($p in $resp.Headers) { $hdrs += ($p.Key + ': ' + (($p.Value) -join ', ')) }
    foreach ($p in $resp.Content.Headers) { $hdrs += ($p.Key + ': ' + (($p.Value) -join ', ')) }

    $save = ([string]$Action.save).Trim()
    $savedPath = ''
    if ($save -and $bytes) {
        $savedPath = Resolve-NetOutPath $save ('resp_' + (Get-NetStamp) + '.bin')
        [IO.File]::WriteAllBytes($savedPath, $bytes)
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$method $url → $status $reason  （$([int]$sw.ElapsedMilliseconds) ms，$([Text.Encoding]::UTF8.GetByteCount($text)) B）")
    if ($hdrs.Count -gt 0) {
        [void]$sb.AppendLine('响应头：')
        foreach ($x in ($hdrs | Select-Object -First 10)) { [void]$sb.AppendLine('  ' + $x) }
    }
    if ($text) {
        [void]$sb.AppendLine('正文：')
        [void]$sb.AppendLine((Get-NetPreview $text $maxBody))
    }
    if ($savedPath) { [void]$sb.AppendLine("已保存响应体：$savedPath") }
    return $sb.ToString().Trim()
}

# ------------------------------------------------------------
# 2) net_capture：pktmon 抓包（端口 / IP / 协议过滤）
# ------------------------------------------------------------
function Invoke-NetCapture($Action) {
    $pkt = Join-Path $env:SystemRoot 'System32\PktMon.exe'
    if (-not (Test-Path -LiteralPath $pkt)) { throw '系统里没有 PktMon.exe（Windows 10 1809 以下不支持）。' }

    $seconds = 5
    try { if ($Action.seconds -gt 0) { $seconds = [int]$Action.seconds } } catch { }
    if ($seconds -gt 30) { $seconds = 30 }

    $port = 0; try { $port = [int]$Action.port } catch { }
    $ip = ([string]$Action.ip).Trim()
    $proto = ([string]$Action.proto).Trim().ToLowerInvariant()
    $pktSize = 128; try { if ($Action.pktSize -gt 0) { $pktSize = [int]$Action.pktSize } } catch { }
    if ($pktSize -lt 64) { $pktSize = 64 }
    if ($pktSize -gt 512) { $pktSize = 512 }

    $stamp = Get-NetStamp
    $etl = Resolve-NetOutPath $Action.file ('cap_' + $stamp + '.etl')
    if ($etl -match '\.pcapng$') { $etl = [IO.Path]::ChangeExtension($etl, '.etl') }

    # 先清掉上次的过滤器，否则会层层叠加
    & $pkt filter remove 2>&1 | Out-Null
    if ($port -gt 0) { & $pkt filter add -p $port 2>&1 | Out-Null }
    if ($ip) { & $pkt filter add -i $ip 2>&1 | Out-Null }
    if ($proto -in @('tcp','udp','icmp')) { & $pkt filter add -t $proto 2>&1 | Out-Null }

    $startOut = & $pkt start --capture --pkt-size $pktSize --file-name $etl 2>&1
    if ($LASTEXITCODE -ne 0) {
        & $pkt filter remove 2>&1 | Out-Null
        throw ("抓包启动失败（多半要管理员权限，或者已经有一个抓包在跑）：" + (($startOut | Out-String).Trim()))
    }

    Start-Sleep -Seconds $seconds
    $stopOut = & $pkt stop 2>&1
    & $pkt filter remove 2>&1 | Out-Null

    if (-not (Test-Path -LiteralPath $etl)) { throw '抓包结束但没生成日志文件。可能没抓到任何包。' }

    $txt = [IO.Path]::ChangeExtension($etl, '.txt')
    $pcap = [IO.Path]::ChangeExtension($etl, '.pcapng')
    & $pkt etl2txt $etl --out $txt --brief 2>&1 | Out-Null
    & $pkt etl2pcap $etl --out $pcap 2>&1 | Out-Null

    # 解析 brief 文本：统计 IP 包和流
    $flows = @{}
    $ipCount = 0
    $httpCount = 0
    $lines = @()
    try { $lines = Get-Content -LiteralPath $txt -Encoding UTF8 } catch { }
    foreach ($ln in $lines) {
        if ($ln -match 'ip:\s+(\S+)\s+>\s+(\S+):\s+(\w+)') {
            $ipCount++
            $key = "$($matches[1]) → $($matches[2]) $($matches[3])"
            if ($flows.ContainsKey($key)) { $flows[$key]++ } else { $flows[$key] = 1 }
        }
        if ($ln -match '类型 HTTP') { $httpCount++ }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("抓包完成：$seconds 秒，抓到 $ipCount 个 IP 包（HTTP 事件 $httpCount 条）。")
    if ($ipCount -eq 0) {
        [void]$sb.AppendLine('一个包都没抓到。常见原因：这段时间没有流量、过滤器太窄（端口/IP 写错了），或者当前不是管理员。')
        [void]$sb.AppendLine('可以先去掉 port/ip 过滤再抓一次，或者用 net_proxy 在 HTTP 层看请求。')
    } else {
        [void]$sb.AppendLine('出现最多的流：')
        $top = $flows.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8
        foreach ($x in $top) { [void]$sb.AppendLine(('  {0,-58} ×{1}' -f $x.Key, $x.Value)) }
    }
    if (Test-Path -LiteralPath $pcap) { [void]$sb.AppendLine("pcapng：$pcap（可直接拖进 Wireshark）") }
    [void]$sb.AppendLine("文本明细：$txt")
    return $sb.ToString().Trim()
}

# ------------------------------------------------------------
# 3) net_send：直接发 TCP / UDP 数据包（文本或十六进制）
# ------------------------------------------------------------
function Invoke-NetSend($Action) {
    $hostName = ([string]$Action.host).Trim()
    if (-not $hostName) { $hostName = '127.0.0.1' }
    $port = 0; try { $port = [int]$Action.port } catch { }
    if ($port -le 0 -or $port -gt 65535) { throw '要给 port（1-65535）' }

    $proto = ([string]$Action.proto).Trim().ToLowerInvariant()
    if ($proto -notin @('tcp','udp')) { $proto = 'tcp' }

    $data = [string]$Action.data
    $isHex = [bool]$Action.hex
    if ($isHex) {
        $clean = ($data -replace '[^0-9A-Fa-f]', '')
        if ($clean.Length % 2 -ne 0) { throw '十六进制要成对，比如 48 65 6C 6C 6F' }
        $bytes = New-Object byte[] ($clean.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16) }
    } else {
        if (-not $data) { throw '要给 data（要发的内容），或者 hex=true 发十六进制' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($data)
    }

    $waitMs = 1500; try { if ($Action.waitMs -gt 0) { $waitMs = [int]$Action.waitMs } } catch { }
    if ($waitMs -gt 10000) { $waitMs = 10000 }
    # ⚠ 不能写 $Action.count —— 哈希表自带 Count 属性，会拿到键的数量
    $count = 1
    try { if ($Action.ContainsKey('count') -and [int]$Action['count'] -gt 1) { $count = [int]$Action['count'] } } catch { }
    if ($count -gt 20) { $count = 20 }
    $interval = 0; try { $interval = [int]$Action.intervalMs } catch { }
    if ($interval -lt 0) { $interval = 0 }

    $recvAll = New-Object System.Text.StringBuilder
    $recvBytes = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ($proto -eq 'udp') {
        $udp = New-Object System.Net.Sockets.UdpClient
        try {
            $udp.Client.ReceiveTimeout = $waitMs
            $udp.Connect($hostName, $port)
            for ($i = 0; $i -lt $count; $i++) {
                [void]$udp.Send($bytes, $bytes.Length)
                if ($interval -gt 0 -and $i -lt ($count - 1)) { Start-Sleep -Milliseconds $interval }
            }
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            try {
                $r = $udp.Receive($ep)
            } catch {
                $r = $null
            }
            if ($r) { $recvBytes = $r.Length; [void]$recvAll.Append([Text.Encoding]::UTF8.GetString($r)) }
        } finally { $udp.Close() }
    } else {
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $tcp.BeginConnect($hostName, $port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { throw "连不上 $hostName`:$port（5 秒超时）。服务在跑吗？端口对吗？" }
            $tcp.EndConnect($iar)
            $ns = $tcp.GetStream()
            $ns.ReadTimeout = $waitMs
            for ($i = 0; $i -lt $count; $i++) {
                $ns.Write($bytes, 0, $bytes.Length)
                $ns.Flush()
                if ($interval -gt 0 -and $i -lt ($count - 1)) { Start-Sleep -Milliseconds $interval }
            }
            # 读回复：读到没数据或超时为止
            $buf = New-Object byte[] 4096
            $deadline = [DateTime]::Now.AddMilliseconds($waitMs)
            while ([DateTime]::Now -lt $deadline) {
                try { $n = $ns.Read($buf, 0, $buf.Length) } catch { break }
                if ($n -le 0) { break }
                $recvBytes += $n
                [void]$recvAll.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n))
                if ($recvBytes -ge 65536) { break }
            }
        } catch [System.Management.Automation.MethodInvocationException] {
            throw ("连接失败：" + $_.Exception.InnerException.Message)
        } finally { $tcp.Close() }
    }
    $sw.Stop()

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(("{0} {1}:{2} 发了 {3} 字节 ×{4}，收到 {5} 字节，耗时 {6} ms" -f $proto.ToUpperInvariant(), $hostName, $port, $bytes.Length, $count, $recvBytes, [int]$sw.ElapsedMilliseconds))
    if ($isHex) { [void]$sb.AppendLine('发送(hex)：' + (ConvertTo-NetHex $bytes)) }
    else { [void]$sb.AppendLine('发送：' + (Get-NetPreview $data 300)) }
    if ($recvBytes -gt 0) {
        [void]$sb.AppendLine('收到(文本)：' + (Get-NetPreview ($recvAll.ToString()) 600))
    } else {
        [void]$sb.AppendLine('没收到回复（服务不回、协议不是请求-响应型，或者 waitMs 太短）。')
    }
    return $sb.ToString().Trim()
}

# ------------------------------------------------------------
# 4) net_proxy：本机 HTTP 代理，拦截 / 改写 / 模拟响应
# ------------------------------------------------------------
function Get-NetProxyPaths {
    $dir = Get-NetDir
    $pdir = Join-Path $dir 'proxy'
    if (-not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force -Path $pdir | Out-Null }
    return @{
        dir    = $pdir
        pid    = (Join-Path $pdir 'proxy.pid')
        log    = (Join-Path $pdir 'proxy.log.jsonl')
        rules  = (Join-Path $pdir 'rules.json')
        script = (Join-Path $script:ToolDir '..\scripts\net-proxy.ps1')
    }
}

function Test-NetProxyRunning($pidFile) {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $pidText = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $pidText) { return $null }
    $proc = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
    if ($proc) { return $proc }
    return $null
}

function Invoke-NetProxy($Action) {
    $p = Get-NetProxyPaths
    $act = ([string]$Action.action).Trim().ToLowerInvariant()
    if (-not $act) { $act = 'status' }

    if ($act -eq 'start') {
        $running = Test-NetProxyRunning $p.pid
        if ($running) { return "代理已经在跑（PID $($running.Id)）。要换规则用 action=rules；要停用 action=stop。" }

        $port = 8899; try { if ($Action.port -gt 0) { $port = [int]$Action.port } } catch { }

        # 规则：直接给 JSON，或者给文件路径
        $rulesIn = $Action.rules
        if ($rulesIn) {
            if ($rulesIn -is [string] -and (Test-Path -LiteralPath $rulesIn)) {
                Copy-Item -LiteralPath $rulesIn -Destination $p.rules -Force
            } elseif ($rulesIn -is [string]) {
                [IO.File]::WriteAllText($p.rules, $rulesIn, [Text.Encoding]::UTF8)
            } else {
                [IO.File]::WriteAllText($p.rules, ($rulesIn | ConvertTo-Json -Depth 12), [Text.Encoding]::UTF8)
            }
            # 校验一下是合法 JSON
            try { $null = Get-Content -LiteralPath $p.rules -Raw | ConvertFrom-Json } catch { throw "rules 不是合法 JSON：$($_.Exception.Message)" }
        }

        if (-not (Test-Path -LiteralPath $p.script)) { throw "代理脚本不见了：$($p.script)" }

        $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $p.script + '"'),
            '-Port', $port, '-RulesFile', ('"' + $p.rules + '"'), '-LogFile', ('"' + $p.log + '"')
        )
        $proc.Id | Set-Content -LiteralPath $p.pid -Encoding ASCII

        # 等端口起来
        $ok = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $c.Connect('127.0.0.1', $port)
                $c.Close(); $ok = $true; break
            } catch { }
        }
        if (-not $ok) {
            try { Stop-Process -Id $proc.Id -Force } catch { }
            throw '代理进程起来了但端口没监听成功，可能端口被占用。换个 port 试试。'
        }
        $ruleCount = 0
        if (Test-Path -LiteralPath $p.rules) {
            try { $ruleCount = @((Get-Content -LiteralPath $p.rules -Raw | ConvertFrom-Json).rules).Count } catch { }
        }
        return ("代理已启动：http://127.0.0.1:$port  （PID $($proc.Id)，规则 $ruleCount 条）`n" +
                "把客户端（浏览器 / curl / 自己的程序）的 HTTP 代理设为 127.0.0.1:$port；" +
                "用 net_http 时加 proxy='http://127.0.0.1:$port' 也能走它。`n" +
                "请求日志：" + $p.log)
    }

    if ($act -eq 'stop') {
        $running = Test-NetProxyRunning $p.pid
        if (-not $running) {
            Remove-Item -LiteralPath $p.pid -Force -ErrorAction SilentlyContinue
            return '代理没在跑。'
        }
        try { Stop-Process -Id $running.Id -Force } catch { throw "停不掉 PID $($running.Id)：$($_.Exception.Message)" }
        Remove-Item -LiteralPath $p.pid -Force -ErrorAction SilentlyContinue
        return "代理已停止（PID $($running.Id)）。日志还在：" + $p.log
    }

    if ($act -eq 'status') {
        $running = Test-NetProxyRunning $p.pid
        $lines = 0
        if (Test-Path -LiteralPath $p.log) { $lines = (Get-Content -LiteralPath $p.log -ErrorAction SilentlyContinue).Count }
        $rules = '无'
        if (Test-Path -LiteralPath $p.rules) {
            try { $rules = @((Get-Content -LiteralPath $p.rules -Raw | ConvertFrom-Json).rules).Count.ToString() + ' 条' } catch { }
        }
        if ($running) { return "代理在跑：PID $($running.Id)，规则 $rules，日志 $lines 条。" }
        return "代理没在跑。规则文件：$($p.rules)，日志 $lines 条。"
    }

    if ($act -eq 'rules') {
        $rulesIn = $Action.rules
        if (-not $rulesIn) {
            if (Test-Path -LiteralPath $p.rules) { return (Get-Content -LiteralPath $p.rules -Raw) }
            return '还没设规则。'
        }
        if ($rulesIn -is [string]) {
            if (Test-Path -LiteralPath $rulesIn) {
                Copy-Item -LiteralPath $rulesIn -Destination $p.rules -Force
            } else {
                [IO.File]::WriteAllText($p.rules, $rulesIn, [Text.Encoding]::UTF8)
            }
        } else {
            [IO.File]::WriteAllText($p.rules, ($rulesIn | ConvertTo-Json -Depth 12), [Text.Encoding]::UTF8)
        }
        try { $n = @((Get-Content -LiteralPath $p.rules -Raw | ConvertFrom-Json).rules).Count } catch { throw "规则不是合法 JSON：$($_.Exception.Message)" }
        return "规则已更新：$n 条（代理每次请求都会重新读这个文件，不用重启）。"
    }

    if ($act -eq 'log') {
        if (-not (Test-Path -LiteralPath $p.log)) { return '还没有请求日志。' }
        $limit = 10; try { if ($Action.limit -gt 0) { $limit = [int]$Action.limit } } catch { }
        if ($limit -gt 50) { $limit = 50 }
        $tail = Get-Content -LiteralPath $p.log -Tail $limit -Encoding UTF8
        if ($Action.clear) {
            [IO.File]::WriteAllText($p.log, '', [Text.Encoding]::UTF8)
        }
        return ("最近 $($tail.Count) 条请求：`n" + ($tail -join "`n"))
    }

    if ($act -eq 'clear') { 
        if (Test-Path -LiteralPath $p.log) { [IO.File]::WriteAllText($p.log, '', [Text.Encoding]::UTF8) }
        return '日志已清空。'
    }

    throw "action 只能是 start / stop / status / rules / log / clear，收到：$act"
}

# ------------------------------------------------------------
# 5) net_ports：本机监听端口与连接（带进程名）
# ------------------------------------------------------------
function Invoke-NetPorts($Action) {
    $port = 0; try { $port = [int]$Action.port } catch { }
    $limit = 20; try { if ($Action.limit -gt 0) { $limit = [int]$Action.limit } } catch { }
    if ($limit -gt 60) { $limit = 60 }

    $procs = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { if (-not $procs.ContainsKey($p.Id)) { $procs[$p.Id] = $p.ProcessName } }

    $list = @()
    foreach ($c in (Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        $state = [string]$c.State
        $lp = [int]$c.LocalPort
        if ($port -gt 0 -and $lp -ne $port -and [int]$c.RemotePort -ne $port) { continue }
        if ($state -ne 'Listen' -and $port -le 0) { continue }   # 不指定端口时只列监听
        $pn = ''
        if ($c.OwningProcess -and $procs.ContainsKey([int]$c.OwningProcess)) { $pn = $procs[[int]$c.OwningProcess] }
        $list += [pscustomobject]@{
            proto = 'TCP'; local = ("{0}:{1}" -f $c.LocalAddress, $c.LocalPort); remote = ("{0}:{1}" -f $c.RemoteAddress, $c.RemotePort)
            state = $state; pid = [int]$c.OwningProcess; name = $pn
        }
    }
    foreach ($u in (Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
        $lp = [int]$u.LocalPort
        if ($port -gt 0 -and $lp -ne $port) { continue }
        $pn = ''
        if ($u.OwningProcess -and $procs.ContainsKey([int]$u.OwningProcess)) { $pn = $procs[[int]$u.OwningProcess] }
        $list += [pscustomobject]@{
            proto = 'UDP'; local = ("{0}:{1}" -f $u.LocalAddress, $u.LocalPort); remote = ''
            state = 'Listen'; pid = [int]$u.OwningProcess; name = $pn
        }
    }

    $sb = New-Object System.Text.StringBuilder
    if ($port -gt 0) {
        $hit = @($list)
        [void]$sb.AppendLine("端口 $port 相关：$($hit.Count) 条")
    } else {
        [void]$sb.AppendLine("本机监听端口 $($list.Count) 个：")
    }
    foreach ($x in ($list | Sort-Object -Property @{Expression='proto'}, @{Expression={[int]($_.local -split ':')[-1]}} | Select-Object -First $limit)) {
        if ($x.proto -eq 'TCP') {
            [void]$sb.AppendLine(('  {0,-4} {1,-26} {2,-12} pid {3,-6} {4}' -f $x.proto, $x.local, $x.state, $x.pid, $x.name))
        } else {
            [void]$sb.AppendLine(('  {0,-4} {1,-26} {2,-12} pid {3,-6} {4}' -f $x.proto, $x.local, 'UDP', $x.pid, $x.name))
        }
    }
    if ($list.Count -gt $limit) { [void]$sb.AppendLine("…还有 $($list.Count - $limit) 条，用 port 参数缩小范围。") }
    return $sb.ToString().Trim()
}
