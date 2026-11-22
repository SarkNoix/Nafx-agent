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
    $pktSize = 512; try { if ($Action.pktSize -gt 0) { $pktSize = [int]$Action.pktSize } } catch { }
    if ($pktSize -lt 64) { $pktSize = 64 }
    if ($pktSize -gt 512) { $pktSize = 512 }

    # 可选：抓包期间顺手发一条请求，专门制造「自己的流量」，不用另开窗口
    # 注意：子进程传进来的可能是 PSCustomObject，不是 Hashtable，不能用 ContainsKey
    $triggerUrl = ([string]$Action.url).Trim()
    $triggerMethod = 'GET'
    if (([string]$Action.method).Trim()) { $triggerMethod = ([string]$Action.method).Trim().ToUpperInvariant() }
    $triggerHeaders = @{}
    $hdrRaw = ([string]$Action.headers).Trim()
    if ($hdrRaw) {
        foreach ($pair in ($hdrRaw -split ';')) {
            if ($pair -match '^([^:]+):\s*(.*)$') { $triggerHeaders[$matches[1].Trim()] = $matches[2].Trim() }
        }
    }

    # 抓某个程序：用它的 TCP/UDP 端口做过滤（pktmon 本身不支持按 PID 过滤）
    $procSpec = ([string]$Action.program).Trim()
    $pidWant = 0
    try { if ([string]$Action.pid -and [int]$Action.pid -gt 0) { $pidWant = [int]$Action.pid } } catch { }
    $procs = @()
    if ($pidWant -gt 0) {
        $procs = @(Get-Process -Id $pidWant -ErrorAction SilentlyContinue)
    } elseif ($procSpec) {
        $nm = $procSpec -replace '(?i)\.exe$', ''
        if ($nm -match '^\d+$') {
            $procs = @(Get-Process -Id ([int]$nm) -ErrorAction SilentlyContinue)
        } else {
            $procs = @(Get-Process -Name $nm -ErrorAction SilentlyContinue)
        }
        if ($procs.Count -eq 0 -and (Test-Path -LiteralPath $procSpec)) {
            $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $procSpec })
        }
    }
    $procPorts = @()
    if ($procs.Count -gt 0) {
        $pids = @($procs | ForEach-Object { [int]$_.Id })
        $procPorts += @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
                        Where-Object { $pids -contains [int]$_.OwningProcess } |
                        ForEach-Object { [int]$_.LocalPort })
        $procPorts += @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                        Where-Object { $pids -contains [int]$_.OwningProcess } |
                        ForEach-Object { [int]$_.LocalPort })
        $procPorts = @($procPorts | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    }
    $procLabel = ''
    if ($procSpec -or $pidWant -gt 0) {
        if ($procs.Count -eq 0) {
            return "没找到程序「$procSpec」。给进程名（如 chrome.exe）或 PID；先确认它开着。"
        }
        $names = @($procs | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
        $procLabel = ($names -join ',') + '（PID ' + (($procs | ForEach-Object { $_.Id }) -join ',') + '）'
        if ($procPorts.Count -eq 0) {
            return "程序 $procLabel 现在没有 TCP/UDP 连接或监听，抓不到它的包。先让它发一次请求/产生流量，再抓；也可以直接用 net_capture(port=端口)。"
        }
    }

    # 没 url 也没端口/IP/程序：抓到的只会是一屏背景流量，直接提示怎么用，别浪费上下文
    if (-not $triggerUrl -and $port -le 0 -and -not $ip -and -not $procLabel) {
        return "没给抓包范围，这次没抓。抓某个程序：net_capture(program=`"进程名或PID`")；抓自己的请求：net_capture(url=`"http://127.0.0.1:9100/api/secure`")；只抓端口：net_capture(port=9100)。"
    }

    # url 里自带端口：没显式给 port 时用它做过滤，避免抓到一屏无关流量
    if ($triggerUrl -and $port -le 0) {
        try {
            $u = [Uri]$triggerUrl
            if ($u.Port -gt 0) { $port = [int]$u.Port }
            if (-not $ip -and $u.Host) { $ip = [string]$u.Host }
        } catch { }
    }

    $stamp = Get-NetStamp
    $etl = Resolve-NetOutPath $Action.file ('cap_' + $stamp + '.etl')
    if ($etl -match '\.pcapng$') { $etl = [IO.Path]::ChangeExtension($etl, '.etl') }

    # 一个过滤器里把 port/ip/proto 一起给，pktmon 才会按「与」匹配；分多条 add 是「或」
    & $pkt filter remove 2>&1 | Out-Null
    if ($procLabel) {
        # 同一个程序的多个端口用多条 filter（这里是「或」），只覆盖它自己的端口
        foreach ($pp in ($procPorts | Select-Object -First 16)) {
            $pf = @('filter', 'add', '-p', [string]$pp)
            if ($proto -in @('tcp','udp','icmp')) { $pf += @('-t', $proto) }
            & $pkt @pf 2>&1 | Out-Null
        }
    } else {
        $fargs = @('filter', 'add')
        if ($port -gt 0) { $fargs += @('-p', [string]$port) }
        if ($ip) { $fargs += @('-i', $ip) }
        if ($proto -in @('tcp','udp','icmp')) { $fargs += @('-t', $proto) }
        if ($fargs.Count -gt 2) { & $pkt @fargs 2>&1 | Out-Null }
    }

    $startOut = & $pkt start --capture --pkt-size $pktSize --file-name $etl 2>&1
    if ($LASTEXITCODE -ne 0) {
        & $pkt filter remove 2>&1 | Out-Null
        throw ("抓包启动失败（多半要管理员权限，或者已经有一个抓包在跑）：" + (($startOut | Out-String).Trim()))
    }

    $triggerStatus = ''
    $swCap = [Diagnostics.Stopwatch]::StartNew()
    if ($triggerUrl) {
        Start-Sleep -Milliseconds 400
        try {
            $wr = Invoke-WebRequest -Uri $triggerUrl -Method $triggerMethod -Headers $triggerHeaders -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $triggerStatus = [string][int]$wr.StatusCode
        } catch {
            if ($_.Exception.Response) { $triggerStatus = [string][int]$_.Exception.Response.StatusCode }
            else { $triggerStatus = '失败:' + $_.Exception.Message }
        }
    }
    $remain = $seconds - [Math]::Floor($swCap.Elapsed.TotalSeconds)
    if ($remain -gt 0) { Start-Sleep -Seconds ([int]$remain) }
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
    if ($procLabel) {
        [void]$sb.AppendLine("抓包对象：程序 $procLabel，端口 " + (($procPorts | Select-Object -First 16) -join ',') + "（按这些端口过滤）")
    }
    if ($triggerUrl) {
        [void]$sb.AppendLine("抓包期间发了：$triggerMethod $triggerUrl → $triggerStatus（这条请求/响应就在包里）")
    }
    if ($ipCount -eq 0) {
        if ($triggerUrl) {
            [void]$sb.AppendLine('请求发出去了但没抓到包：检查 port 是否写成了这条请求的端口；或者当前不是管理员。')
        } elseif ($procLabel) {
            [void]$sb.AppendLine('程序这 ' + $seconds + ' 秒没发包。抓包只「看」流量，先让它动起来（发请求/刷新）再抓，或把 seconds 调大。')
        } else {
            [void]$sb.AppendLine('一个包都没抓到。抓包只「看」流量，不会自己产生流量；要抓自己的请求，加上 url="http://127.0.0.1:端口/路径" 一起抓。')
        }
        [void]$sb.AppendLine('也可以先用 net_ports 确认服务在跑，再用 net_proxy 在 HTTP 层看请求。')
    } else {
        [void]$sb.AppendLine('出现最多的流：')
        $top = $flows.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6
        foreach ($x in $top) { [void]$sb.AppendLine(('  {0,-58} ×{1}' -f $x.Key, $x.Value)) }
    }
    if (Test-Path -LiteralPath $pcap) {
        [void]$sb.AppendLine("pcapng：$pcap（可直接拖进 Wireshark）")
        # 抓到自己请求/指定程序时，顺手把请求首行和响应体贴出来：模型不用再调 net_packets 就能看到差什么
        $reqs = @()
        if ($triggerUrl -or $procLabel) {
            try {
                $pk = @(Read-NetPcapngPackets $pcap)
                $resps = @()
                foreach ($one in $pk) {
                    $dd = Get-NetPacketDecoded $one
                    if (-not $dd) { continue }
                    if ($dd.isHttpReq) { $reqs += $dd }
                    elseif ($dd.isHttpResp) { $resps += $dd }
                }
                if ($reqs.Count -gt 0) {
                    [void]$sb.AppendLine("包里的请求：#" + $reqs[0].index + " " + $reqs[0].firstLine)
                }
                if ($resps.Count -gt 0) {
                    $st = ([string]$resps[0].firstLine).Trim()
                    if ($st) { [void]$sb.AppendLine('响应状态：' + $st) }
                    $body = ''
                    $rp = $resps[0].payload -replace "`r`n", "`n"
                    if ($rp -match "`n`n") { $body = ($rp -split "`n`n", 2)[1] }
                    if ($body) {
                        $b = $body.Trim()
                        if ($b.Length -gt 300) { $b = $b.Substring(0, 300) + '...' }
                        [void]$sb.AppendLine('第一个响应体：' + $b)
                    }
                    if ($reqs.Count -gt 0) {
                        [void]$sb.AppendLine('改这条请求：net_rewrite(file="' + (Split-Path -Leaf $pcap) + '", index=' + $reqs[0].index + ', setHeaders="X-Token: 值")')
                    }
                }
            } catch { }
        }
    }
    if ($ipCount -gt 0) {
        $leaf = Split-Path -Leaf $pcap
        if (($triggerUrl -or $procLabel) -and $reqs.Count -gt 0) {
            # 抓到自己请求时，细节已经在上面给过了，不再提示多余的步骤
        } else {
            [void]$sb.AppendLine('看具体包：net_packets(file="' + $leaf + '")；看第 N 个加 index=N，改请求再发用 net_rewrite(index=N)。')
        }
    }
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
    # ⚠ 哈希表自带 Count 属性，会拿到键的数量；对象才读 count 参数
    $count = 1
    $countVal = if ($Action -is [hashtable]) { $Action['count'] } else { $Action.count }
    try { if ([int]$countVal -gt 1) { $count = [int]$countVal } } catch { }
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
# 5) net_packets：看抓包文件里的具体数据包（按序号 / 端口 / 协议 / 内容）
#    6) net_rewrite：把某个包里的 HTTP 请求改写后按 TCP 重发
# ------------------------------------------------------------

function Get-NetLatestPcap {
    $dir = Get-NetDir
    $f = Get-ChildItem -LiteralPath $dir -Filter '*.pcapng' -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return $null }
    return $f.FullName
}

function Resolve-NetPcapFile($rel) {
    if ([string]::IsNullOrWhiteSpace($rel)) {
        $latest = Get-NetLatestPcap
        if (-not $latest) { throw 'workspace\net 里还没有 pcapng。先用 net_capture 抓一个。' }
        return $latest
    }
    $rel = ([string]$rel).Trim() -replace '/', '\'
    $cands = @()
    if ([IO.Path]::IsPathRooted($rel)) {
        $cands += $rel
    } else {
        # 模型常把路径写成 workspace\net\x.pcapng 或 net\x.pcapng，这里都认
        $cands += (Join-Path (Get-NetDir) $rel)
        $cands += (Join-Path $script:AiRoot $rel)
        $cands += (Join-Path (Get-NetDir) ([IO.Path]::GetFileName($rel)))
    }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    # 模型常瞎猜文件名（如 capture.pcapng）。找不到就退回最新的，别让它卡在报错上
    $latest = Get-NetLatestPcap
    if ($latest) { return $latest }
    throw ("找不到抓包文件：$rel。可以直接给文件名（如 " + [IO.Path]::GetFileName($rel) + '），不给 file 就用最新一个。')
}

# 读 pcapng 里的包（SHB/IDB/EPB 三种块就够用）
function Read-NetPcapngPackets($file) {
    $bytes = [IO.File]::ReadAllBytes($file)
    $o = 0
    $pkts = @()
    $link = 1
    while (($o + 12) -le $bytes.Length) {
        $type = [BitConverter]::ToUInt32($bytes, $o)
        $len  = [BitConverter]::ToUInt32($bytes, $o + 4)
        if ($len -lt 12 -or ($o + $len) -gt $bytes.Length) { break }
        if ($type -eq 1) {
            $link = [BitConverter]::ToUInt16($bytes, $o + 8)
        } elseif ($type -eq 6) {
            $tsHigh = [BitConverter]::ToUInt32($bytes, $o + 12)
            $tsLow  = [BitConverter]::ToUInt32($bytes, $o + 16)
            $capLen = [BitConverter]::ToUInt32($bytes, $o + 20)
            if ($capLen -gt 0 -and $capLen -lt 262144 -and ($o + 28 + $capLen) -le $bytes.Length) {
                $data = New-Object byte[] ([int]$capLen)
                [Array]::Copy($bytes, ($o + 28), $data, 0, [int]$capLen)
                $pkts += [pscustomobject]@{
                    index = ($pkts.Count + 1)
                    time  = (([double]$tsHigh * 4294967296.0 + [double]$tsLow) / 1000000.0)
                    data  = $data
                    link  = $link
                }
            }
        }
        $o += [int]$len
    }
    return $pkts
}

function Get-NetU16($b, $o) { return ((([int]$b[$o]) -shl 8) -bor ([int]$b[$o + 1])) }

function ConvertTo-NetIpText([byte[]]$b, $off) {
    if ($b.Length -lt ($off + 4)) { return '' }
    return ("{0}.{1}.{2}.{3}" -f [int]$b[$off], [int]$b[$off + 1], [int]$b[$off + 2], [int]$b[$off + 3])
}

function Get-NetPacketDecoded($pkt) {
    $d = $pkt.data
    if ($d.Length -lt 20) { return $null }
    $start = 0
    # pktmon 的 pcapng 有时标 Ethernet 但实际是裸 IP，这里两边都兼容
    if ($d[0] -ne 0x45 -and $d[0] -ne 0x60) {
        if ($d.Length -ge 14) {
            $start = 14
            $et = (Get-NetU16 $d 12)
            if ($et -eq 0x8100 -and $d.Length -ge 18) { $start = 18 }
        }
    }
    if ($start + 20 -gt $d.Length) { return $null }
    $ver = ([int]$d[$start]) -shr 4
    if ($ver -ne 4 -and $ver -ne 6) { return $null }
    $ihl = (([int]$d[$start]) -band 0x0F) * 4
    if ($ihl -lt 20 -or ($start + $ihl) -gt $d.Length) { return $null }
    $protoNum = [int]$d[$start + 9]
    $proto = switch ($protoNum) { 6 { 'TCP' } 17 { 'UDP' } 1 { 'ICMP' } default { "IP($protoNum)" } }
    $srcIp = ConvertTo-NetIpText $d ($start + 12)
    $dstIp = ConvertTo-NetIpText $d ($start + 16)
    $ipLen = (Get-NetU16 $d ($start + 2))
    if ($ipLen -le 0) { $ipLen = $d.Length - $start }

    $sport = 0; $dport = 0; $flags = ''; $payload = ''; $payloadLen = 0; $payloadBytes = $null
    $l4 = $start + $ihl
    if ($proto -eq 'TCP' -and ($l4 + 20) -le $d.Length) {
        $sport = (Get-NetU16 $d $l4)
        $dport = (Get-NetU16 $d ($l4 + 2))
        $off = (([int]$d[$l4 + 12]) -shr 4) * 4
        $f = [int]$d[$l4 + 13]
        $flags = (@(
            $(if ($f -band 0x02) { 'SYN' }),
            $(if ($f -band 0x10) { 'ACK' }),
            $(if ($f -band 0x08) { 'PSH' }),
            $(if ($f -band 0x01) { 'FIN' }),
            $(if ($f -band 0x04) { 'RST' })
        ) | Where-Object { $_ }) -join ','
        $ps = $l4 + $off
        if ($ps -lt $d.Length) {
            $payloadBytes = New-Object byte[] ($d.Length - $ps)
            [Array]::Copy($d, $ps, $payloadBytes, 0, $payloadBytes.Length)
        }
    } elseif ($proto -eq 'UDP' -and ($l4 + 8) -le $d.Length) {
        $sport = (Get-NetU16 $d $l4)
        $dport = (Get-NetU16 $d ($l4 + 2))
        $ps = $l4 + 8
        if ($ps -lt $d.Length) {
            $payloadBytes = New-Object byte[] ($d.Length - $ps)
            [Array]::Copy($d, $ps, $payloadBytes, 0, $payloadBytes.Length)
        }
    }

    $isHttpReq = $false
    $isHttpResp = $false
    $firstLine = ''
    if ($payloadBytes -and $payloadBytes.Length -gt 0) {
        $payloadLen = $payloadBytes.Length
        $payload = [Text.Encoding]::UTF8.GetString($payloadBytes)
        $firstLine = ($payload -split "`r?`n")[0]
        if ($firstLine -match '^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)\s+\S+\s+HTTP/1\.[01]') { $isHttpReq = $true }
        if ($firstLine -match '^HTTP/1\.[01]\s+\d{3}') { $isHttpResp = $true }
    }

    return [pscustomobject]@{
        index = $pkt.index; time = $pkt.time
        proto = $proto; srcIp = $srcIp; dstIp = $dstIp
        sport = $sport; dport = $dport; flags = $flags
        ipLen = $ipLen; payloadLen = $payloadLen
        payload = $payload; payloadBytes = $payloadBytes
        firstLine = $firstLine; isHttpReq = $isHttpReq; isHttpResp = $isHttpResp
    }
}

function Invoke-NetPackets($Action) {
    $file = Resolve-NetPcapFile $Action.file
    $all = @(Read-NetPcapngPackets $file)
    if ($all.Count -eq 0) { return "文件里没解析出包：$file（可能不是 pcapng，或抓的时候 0 包）" }
    $first = [double]$all[0].time

    $idx = 0
    $idxRaw = [string]$Action.index
    if ($idxRaw.Trim()) { try { $idx = [int]$idxRaw } catch { } }

    # 单个包：给详情
    if ($idx -gt 0) {
        if ($idx -gt $all.Count) { throw "包里只有 $($all.Count) 个，没有 #$idx" }
        $dec = Get-NetPacketDecoded $all[$idx - 1]
        if (-not $dec) { throw "包 #$idx 不是 IPv4/IPv6，解析不了。" }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("包 #$idx 详情（$([IO.Path]::GetFileName($file))）")
        [void]$sb.AppendLine(("时间：+{0:N3}s" -f ([double]$dec.time - $first)))
        [void]$sb.AppendLine(("链路：{0}  {1}:{2} → {3}:{4}" -f $dec.proto, $dec.srcIp, $dec.sport, $dec.dstIp, $dec.dport))
        [void]$sb.AppendLine(("长度：IP {0} B，载荷 {1} B" -f $dec.ipLen, $dec.payloadLen))
        if ($dec.flags) { [void]$sb.AppendLine("TCP 标志：$($dec.flags)") }
        if ($dec.payloadLen -eq 0) {
            [void]$sb.AppendLine('（没有载荷，纯握手/确认包）')
        } else {
            $kind = if ($dec.isHttpReq) { 'HTTP 请求' } elseif ($dec.isHttpResp) { 'HTTP 响应' } else { '载荷' }
            [void]$sb.AppendLine("载荷（$kind）：")
            [void]$sb.AppendLine((Get-NetPreview $dec.payload 2000))
            if ($dec.isHttpReq) {
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine('要改这个请求并重发：net_rewrite(index=' + $idx + ', setHeaders="X-Token: abc")；只改 body 用 bodyReplace="旧=>新"。')
            }
        }
        return $sb.ToString().Trim()
    }

    # 列表：过滤条件
    $port = 0
    $portRaw = [string]$Action.port
    if ($portRaw.Trim()) { try { $port = [int]$portRaw } catch { } }
    $protoWanted = ([string]$Action.proto).Trim().ToLowerInvariant()
    $contains = ([string]$Action.contains).Trim()
    $limit = 12
    $limitRaw = [string]$Action.limit
    if ($limitRaw.Trim()) { try { $limit = [int]$limitRaw } catch { } }
    $limit = [Math]::Max(1, [Math]::Min(40, $limit))

    $shown = 0; $matched = 0
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("抓包文件：$file（共 $($all.Count) 个包）")
    foreach ($p in $all) {
        $dec = Get-NetPacketDecoded $p
        if (-not $dec) { continue }
        if ($port -gt 0 -and $dec.sport -ne $port -and $dec.dport -ne $port) { continue }
        if ($protoWanted) {
            if ($protoWanted -eq 'http') { if (-not ($dec.isHttpReq -or $dec.isHttpResp)) { continue } }
            elseif ($protoWanted -eq 'tcp' -and $dec.proto -ne 'TCP') { continue }
            elseif ($protoWanted -eq 'udp' -and $dec.proto -ne 'UDP') { continue }
            elseif ($protoWanted -notin @('tcp', 'udp', 'http') -and $dec.proto.ToLowerInvariant() -ne $protoWanted) { continue }
        }
        if ($contains -and $dec.payload -notlike "*$contains*") { continue }
        $matched++
        if ($shown -ge $limit) { continue }
        $shown++
        $tag = ''
        if ($dec.isHttpReq) { $tag = ' ' + $dec.firstLine } elseif ($dec.isHttpResp) { $tag = ' ' + $dec.firstLine }
        [void]$sb.AppendLine(('  #{0}  +{1:N3}s  {2} {3}:{4} → {5}:{6}  {7}B{8}' -f `
            $dec.index, ([double]$dec.time - $first), $dec.proto, $dec.srcIp, $dec.sport, $dec.dstIp, $dec.dport, $dec.ipLen, $tag))
    }
    if ($matched -eq 0) {
        [void]$sb.AppendLine('没有符合条件的包。去掉 port/proto/contains 过滤再看一次。')
    } else {
        [void]$sb.AppendLine("共 $matched 个匹配，显示了 $shown 个。")
        [void]$sb.AppendLine('看某个包的完整内容：net_packets(index=N)；改它：net_rewrite(index=N, setHeaders="X-Token: abc")。')
    }
    return $sb.ToString().Trim()
}

function Invoke-NetRewrite($Action) {
    $file = Resolve-NetPcapFile $Action.file
    $all = @(Read-NetPcapngPackets $file)
    $idx = 0; try { $idx = [int]$Action.index } catch { }
    if ($idx -lt 1 -or $idx -gt $all.Count) { throw "index 要给对：这个文件有 $($all.Count) 个包，比如 index=$([Math]::Min(1, $all.Count))" }
    $dec = Get-NetPacketDecoded $all[$idx - 1]
    if (-not $dec) { throw "包 #$idx 解析不了。" }
    if (-not $dec.isHttpReq) {
        throw ("包 #$idx 不是 HTTP 请求（当前是 $($dec.proto) $($dec.sport)→$($dec.dport)，首行：$($dec.firstLine)）。" +
               ' 只能改 HTTP 请求；要看包用 net_packets(index=' + $idx + ')。')
    }

    # ---- 拆请求 ----
    $raw = $dec.payload -replace "`r`n", "`n"
    $parts = $raw -split "`n`n", 2
    $headLines = $parts[0] -split "`n"
    $body = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $reqLine = $headLines[0]
    $m = [regex]::Match($reqLine, '^(\S+)\s+(\S+)\s+(HTTP/1\.[01])$')
    if (-not $m.Success) { throw "请求行看不懂：$reqLine" }
    $method = $m.Groups[1].Value
    $target = $m.Groups[2].Value
    $version = $m.Groups[3].Value

    $hdr = @()
    for ($i = 1; $i -lt $headLines.Count; $i++) {
        if ($headLines[$i] -match '^([^:]+):\s*(.*)$') {
            $hdr += [pscustomobject]@{ Name = $matches[1].Trim(); Value = $matches[2].Trim() }
        }
    }

    $changes = @()
    if ($Action.method) { $method = ([string]$Action.method).ToUpperInvariant(); $changes += "方法→$method" }
    if ($Action.replaceUrl) { $target = [string]$Action.replaceUrl; $changes += "URL→$target" }

    $setPairs = @()
    if ($Action.setHeaders) {
        if ($Action.setHeaders -is [string]) {
            foreach ($pair in ($Action.setHeaders -split ';')) {
                if ($pair -match '^([^:]+):\s*(.*)$') { $setPairs += [pscustomobject]@{ Name = $matches[1].Trim(); Value = $matches[2].Trim() } }
            }
        } else {
            foreach ($pp in $Action.setHeaders.PSObject.Properties) { $setPairs += [pscustomobject]@{ Name = $pp.Name; Value = [string]$pp.Value } }
        }
    }
    foreach ($sp in $setPairs) {
        $found = $false
        for ($i = 0; $i -lt $hdr.Count; $i++) {
            if ($hdr[$i].Name -ieq $sp.Name) { $hdr[$i].Value = $sp.Value; $found = $true }
        }
        if (-not $found) { $hdr += $sp }
        $changes += "设置头 $($sp.Name): $($sp.Value)"
    }

    if ($Action.removeHeaders) {
        $names = @(([string]$Action.removeHeaders) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $hdr = @($hdr | Where-Object { $n = $_.Name; -not ($names | Where-Object { $n -ieq $_ }) })
        foreach ($n in $names) { $changes += "删头 $n" }
    }

    if ($null -ne $Action.body) { $body = [string]$Action.body; $changes += '整体替换 body' }
    if ($Action.bodyReplace) {
        foreach ($pair in (([string]$Action.bodyReplace) -split ';;')) {
            if ($pair -match '^(.*?)=>(.*)$') {
                $old = $matches[1]; $new = $matches[2]
                if ($body.Contains($old)) { $body = $body.Replace($old, $new); $changes += "body: $old → $new" }
            }
        }
    }

    # 目标与 Host
    $destHost = $dec.dstIp
    $destPort = $dec.dport
    if ($Action.host) { $destHost = [string]$Action.host; $changes += "目标→$destHost" }
    if ($Action.port -and [int]$Action.port -gt 0) { $destPort = [int]$Action.port; $changes += "端口→$destPort" }

    $hostVal = "$destHost"
    if ($destPort -ne 80) { $hostVal = "$destHost`:$destPort" }
    $hasHost = $false
    for ($i = 0; $i -lt $hdr.Count; $i++) {
        if ($hdr[$i].Name -ieq 'Host') { $hdr[$i].Value = $hostVal; $hasHost = $true }
    }
    if (-not $hasHost) { $hdr = @([pscustomobject]@{ Name = 'Host'; Value = $hostVal }) + $hdr }

    # Content-Length 跟 body 对齐（chunked 不碰）
    $hasCL = $false; $hasTE = $false
    foreach ($h in $hdr) { if ($h.Name -ieq 'Content-Length') { $hasCL = $true }; if ($h.Name -ieq 'Transfer-Encoding') { $hasTE = $true } }
    if (-not $hasTE) {
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
        if ($bodyBytes.Length -gt 0 -or $hasCL) {
            $newHdr = @()
            foreach ($h in $hdr) {
                if ($h.Name -ieq 'Content-Length') { $newHdr += [pscustomobject]@{ Name = $h.Name; Value = [string]$bodyBytes.Length } }
                else { $newHdr += $h }
            }
            if (-not $hasCL) { $newHdr += [pscustomobject]@{ Name = 'Content-Length'; Value = [string]$bodyBytes.Length } }
            $hdr = $newHdr
        }
    }

    # ---- 拼回请求 ----
    $outLines = @("$method $target $version")
    foreach ($h in $hdr) { $outLines += ("{0}: {1}" -f $h.Name, $h.Value) }
    $outText = ($outLines -join "`r`n") + "`r`n`r`n" + $body
    $sendBytes = [Text.Encoding]::UTF8.GetBytes($outText)

    # ---- 按 TCP 重发 ----
    $waitMs = 2000; try { if ($Action.waitMs) { $waitMs = [Math]::Max(200, [Math]::Min(10000, [int]$Action.waitMs)) } } catch { }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $recvText = ''
    $recvLen = 0
    $err = ''
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($destHost, $destPort, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)) { throw "连不上 $destHost`:$destPort" }
        $stream = $tcp.GetStream()
        $stream.Write($sendBytes, 0, $sendBytes.Length)
        $stream.Flush()
        $buf = New-Object byte[] 4096
        $sbRecv = New-Object System.Text.StringBuilder
        $deadline = [DateTime]::UtcNow.AddMilliseconds($waitMs)
        while ([DateTime]::UtcNow -lt $deadline -and $recvLen -lt 65536) {
            $remain = [int](($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remain -le 0) { break }
            if ($stream.DataAvailable) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                [void]$sbRecv.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n))
                $recvLen += $n
            } else { Start-Sleep -Milliseconds 40 }
        }
        $recvText = $sbRecv.ToString()
        $tcp.Close()
    } catch { $err = $_.Exception.Message }
    $sw.Stop()

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("改包重放：$([IO.Path]::GetFileName($file)) 的 #$idx → $destHost`:$destPort")
    if ($changes.Count -gt 0) { [void]$sb.AppendLine('改动：' + ($changes -join '；')) } else { [void]$sb.AppendLine('改动：无（原样重放）') }
    if ($err) {
        [void]$sb.AppendLine("发送失败：$err")
    } else {
        $status = ''
        if ($recvText -match '^HTTP/1\.[01]\s+(\d{3})\s*([^\r\n]*)') { $status = "$($matches[1]) $($matches[2])" }
        $statusText = if ($status) { $status } else { '没解析到状态行' }
        [void]$sb.AppendLine(("发了 {0} B，收到 {1} B（{2}，{3} ms）" -f $sendBytes.Length, $recvLen, $statusText, [int]$sw.ElapsedMilliseconds))
    }
    [void]$sb.AppendLine('')
    if ($recvText) {
        [void]$sb.AppendLine('响应（前 300 字）：')
        [void]$sb.AppendLine((Get-NetPreview $recvText 300))
    }
    if ($err) { [void]$sb.AppendLine('排查：目标端口通不通（net_ports）；host/port 参数对不对；服务是不是只收 HTTP/1.0。') }

    if ($Action.save) {
        $out = Resolve-NetOutPath $Action.save ("rewrite_$(Get-NetStamp).txt")
        [IO.File]::WriteAllText($out, $outText, (New-Object Text.UTF8Encoding($false)))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("改写后的请求已存：$out")
    }
    return $sb.ToString().Trim()
}

# ------------------------------------------------------------
# 7) net_ports：本机监听端口与连接（带进程名）
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
