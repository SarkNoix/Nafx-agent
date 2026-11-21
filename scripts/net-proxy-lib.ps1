# 代理处理函数（被 net-proxy.ps1 dot-source，也在每个 runspace 里加载）
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

function Write-ProxyLog($obj) {
    try {
        $line = ($obj | ConvertTo-Json -Compress -Depth 6) + "`n"
        $enc = New-Object Text.UTF8Encoding($false)
        for ($i = 0; $i -lt 3; $i++) {
            try {
                [IO.File]::AppendAllText($global:ProxyLogFile, $line, $enc)
                return
            } catch { Start-Sleep -Milliseconds 40 }
        }
    } catch { }
}

function Read-Rules {
    $empty = @()
    if (-not $global:ProxyRulesFile -or -not (Test-Path -LiteralPath $global:ProxyRulesFile)) { return $empty }
    try {
        $raw = Get-Content -LiteralPath $global:ProxyRulesFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $j = $raw | ConvertFrom-Json
        if ($j -is [array]) { return @($j) }
        if ($j.rules) { return @($j.rules) }
        return $empty
    } catch { return $empty }
}

function Test-RuleMatch($rule, $method, $url, $body) {
    if ($rule.method) {
        $ms = @($rule.method)
        $okM = $false
        foreach ($m in $ms) { if ([string]$m -eq '*' -or ([string]$m).ToUpperInvariant() -eq $method.ToUpperInvariant()) { $okM = $true; break } }
        if (-not $okM) { return $false }
    }
    if ($rule.url) {
        if ($url.IndexOf([string]$rule.url, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    if ($rule.urlRegex) {
        if ($url -notmatch [string]$rule.urlRegex) { return $false }
    }
    if ($rule.bodyContains) {
        if (-not $body -or $body.IndexOf([string]$rule.bodyContains, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Read-HttpHead($stream) {
    # 不用 StreamReader：它会把 body 也缓冲走。
    $buf = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    $last4 = ''
    while ($true) {
        $n = $stream.Read($one, 0, 1)
        if ($n -le 0) { break }
        $buf.Add($one[0])
        $last4 += [char]$one[0]
        if ($last4.Length -gt 4) { $last4 = $last4.Substring($last4.Length - 4) }
        if ($last4 -eq "`r`n`r`n") { break }
        if ($buf.Count -gt 65536) { break }
    }
    $text = [Text.Encoding]::ASCII.GetString($buf.ToArray())
    return $text
}

function Read-Exact($stream, $count) {
    $out = New-Object byte[] $count
    $read = 0
    while ($read -lt $count) {
        $n = $stream.Read($out, $read, $count - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    if ($read -lt $count) {
        $part = New-Object byte[] $read
        [Array]::Copy($out, $part, $read)
        return $part
    }
    return $out
}

function Read-Chunked($stream) {
    $ms = New-Object System.IO.MemoryStream
    while ($true) {
        $line = ''
        while ($true) {
            $b = $stream.ReadByte()
            if ($b -lt 0) { return $ms.ToArray() }
            $ch = [char]$b
            if ($ch -eq "`n") { break }
            if ($ch -ne "`r") { $line += $ch }
        }
        $size = [Convert]::ToInt32(($line -split ';')[0].Trim(), 16)
        if ($size -eq 0) {
            # 吃掉结尾的空行
            try { $null = $stream.ReadByte(); $null = $stream.ReadByte() } catch { }
            break
        }
        $data = Read-Exact $stream $size
        $ms.Write($data, 0, $data.Length)
        try { $null = $stream.ReadByte(); $null = $stream.ReadByte() } catch { }
        if ($ms.Length -gt 8MB) { break }
    }
    return $ms.ToArray()
}

function Send-Simple($client, $status, $reason, $bodyText, $extraHeaders) {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$bodyText)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $status $reason`r`n")
    [void]$sb.Append("Content-Type: text/plain; charset=utf-8`r`n")
    if ($extraHeaders) {
        foreach ($k in $extraHeaders.Keys) { [void]$sb.Append(($k + ': ' + $extraHeaders[$k] + "`r`n")) }
    }
    [void]$sb.Append("Content-Length: $($bytes.Length)`r`n")
    [void]$sb.Append("Connection: close`r`n`r`n")
    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $client.Write($head, 0, $head.Length)
    if ($bytes.Length -gt 0) { $client.Write($bytes, 0, $bytes.Length) }
    $client.Flush()
}

function Handle-Client($client) {
    $stream = $null
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $head = Read-HttpHead $stream
        if ([string]::IsNullOrWhiteSpace($head)) { return }
        $lines = $head -split "`r`n"
        $reqLine = $lines[0]
        if ($reqLine -notmatch '^(\S+)\s+(\S+)\s+HTTP/(\d\.\d)') { return }
        $method = $matches[1].ToUpperInvariant()
        $target = $matches[2]

        $headers = @{}
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($ln -match '^([^:]+):\s*(.*)$') { $headers[$matches[1].Trim()] = $matches[2].Trim() }
        }

        # ---- HTTPS：只打隧道，不解密 ----
        if ($method -eq 'CONNECT') {
            Write-ProxyLog @{ t = (Get-Date).ToString('s'); method = 'CONNECT'; url = $target; rule = ''; status = 'tunnel'; ms = 0; note = 'HTTPS 隧道，未解密' }
            $hostPart = ($target -split ':')[0]
            $portPart = 443
            if ($target -match ':(\d+)$') { $portPart = [int]$matches[1] }
            try {
                $up = New-Object System.Net.Sockets.TcpClient
                $up.Connect($hostPart, $portPart)
                Send-Simple $stream 200 'Connection Established' '' @{}
                $upStream = $up.GetStream()
                $t1 = $stream.CopyToAsync($upStream)
                $t2 = $upStream.CopyToAsync($stream)
                [void][System.Threading.Tasks.Task]::WaitAny(@($t1, $t2), 120000)
                $up.Close()
            } catch {
                try { Send-Simple $stream 502 'Bad Gateway' ("隧道失败: " + $_.Exception.Message) @{} } catch { }
            }
            return
        }

        # 目标 URL：绝对形式或 Host + path
        $hostHdr = [string]$headers['Host']
        $url = $target
        if ($url -notmatch '^http://') {
            if (-not $hostHdr) { Send-Simple $stream 400 'Bad Request' '缺少 Host 头' @{}; return }
            $url = 'http://' + $hostHdr + $target
        }

        # 读 body
        $bodyText = ''
        $bodyBytes = $null
        if ($headers['Transfer-Encoding'] -match '(?i)chunked') {
            $bodyBytes = Read-Chunked $stream
            $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
        } elseif ($headers['Content-Length']) {
            $len = [int]$headers['Content-Length']
            if ($len -gt 0) {
                if ($len -gt 4MB) { Send-Simple $stream 413 'Payload Too Large' '请求体太大（>4MB），代理不接' @{}; return }
                $bodyBytes = Read-Exact $stream $len
                $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
            }
        }

        # ---- 规则 ----
        $rule = $null
        $ruleName = ''
        foreach ($r in (Read-Rules)) {
            if (Test-RuleMatch $r $method $url $bodyText) { $rule = $r; $ruleName = [string]$r.name; break }
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()

        if ($rule -and [string]$rule.action -eq 'mock') {
            $delay = 0
            try { if ($rule.delayMs -gt 0) { $delay = [int]$rule.delayMs } } catch { }
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($delay, 10000)) }
            $st = 200
            try { if ($rule.status -gt 0) { $st = [int]$rule.status } } catch { }
            $mockHeaders = @{}
            if ($rule.headers) { foreach ($p in $rule.headers.PSObject.Properties) { $mockHeaders[[string]$p.Name] = [string]$p.Value } }
            $mockBody = [string]$rule.body
            Send-Simple $stream $st 'Mock' $mockBody $mockHeaders
            $sw.Stop()
            Write-ProxyLog @{ t = (Get-Date).ToString('s'); method = $method; url = $url; rule = $ruleName; status = $st; ms = [int]$sw.ElapsedMilliseconds; reqLen = $(if ($bodyBytes) { $bodyBytes.Length } else { 0 }); respLen = $mockBody.Length; mock = $true }
            return
        }

        if ($rule -and [string]$rule.action -eq 'block') {
            $st = 403
            try { if ($rule.status -gt 0) { $st = [int]$rule.status } } catch { }
            Send-Simple $stream $st 'Blocked' ("被规则拦截：" + $ruleName) @{}
            $sw.Stop()
            Write-ProxyLog @{ t = (Get-Date).ToString('s'); method = $method; url = $url; rule = $ruleName; status = $st; ms = [int]$sw.ElapsedMilliseconds; blocked = $true }
            return
        }

        # ---- 转发 ----
        $fwdUrl = $url
        $fwdHeaders = @{}
        foreach ($k in $headers.Keys) {
            $lk = $k.ToLowerInvariant()
            if ($lk -in @('host','connection','proxy-connection','keep-alive','transfer-encoding','content-length','upgrade')) { continue }
            $fwdHeaders[$k] = $headers[$k]
        }
        if ($rule) {
            if ($rule.replaceUrl) { $fwdUrl = [string]$rule.replaceUrl }
            if ($rule.setHeaders) { foreach ($p in $rule.setHeaders.PSObject.Properties) { $fwdHeaders[[string]$p.Name] = [string]$p.Value } }
            if ($rule.removeHeaders) { foreach ($h in @($rule.removeHeaders)) { foreach ($k in @($fwdHeaders.Keys)) { if ($k -ieq [string]$h) { $fwdHeaders.Remove($k) } } } }
            if ($rule.bodyReplace) {
                $pat = [string]$rule.bodyReplace.pattern
                $rep = [string]$rule.bodyReplace.replacement
                if ($pat -and $bodyText) { $bodyText = [regex]::Replace($bodyText, $pat, $rep) }
            }
        }

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $http = New-Object System.Net.Http.HttpClient($handler)
        $http.Timeout = [TimeSpan]::FromSeconds(30)
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($method), $fwdUrl)
        foreach ($k in $fwdHeaders.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, $fwdHeaders[$k]) }
        if ($bodyBytes -and $bodyBytes.Length -gt 0) {
            $content = New-Object System.Net.Http.ByteArrayContent($bodyBytes)
            $ct = [string]$headers['Content-Type']
            if ($ct) { $content.Headers.TryAddWithoutValidation('Content-Type', $ct) | Out-Null }
            $req.Content = $content
        }

        try {
            $resp = $http.SendAsync($req).GetAwaiter().GetResult()
        } catch {
            $sw.Stop()
            Send-Simple $stream 502 'Bad Gateway' ("转发失败: " + $_.Exception.Message) @{}
            Write-ProxyLog @{ t = (Get-Date).ToString('s'); method = $method; url = $url; rule = $ruleName; status = 502; ms = [int]$sw.ElapsedMilliseconds; error = $_.Exception.Message }
            return
        }

        $respBytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($rule -and $rule.respBodyReplace -and $respBytes) {
            $txt = [Text.Encoding]::UTF8.GetString($respBytes)
            $pat = [string]$rule.respBodyReplace.pattern
            $rep = [string]$rule.respBodyReplace.replacement
            if ($pat) { $txt = [regex]::Replace($txt, $pat, $rep); $respBytes = [Text.Encoding]::UTF8.GetBytes($txt) }
        }

        $status = [int]$resp.StatusCode
        $reason = [string]$resp.ReasonPhrase
        if (-not $reason) { $reason = 'OK' }
        $headSb = New-Object System.Text.StringBuilder
        [void]$headSb.Append("HTTP/1.1 $status $reason`r`n")
        foreach ($p in $resp.Headers) {
            $k = $p.Key
            if ($k -in @('Transfer-Encoding','Connection','Content-Length')) { continue }
            [void]$headSb.Append(($k + ': ' + (($p.Value) -join ', ') + "`r`n"))
        }
        foreach ($p in $resp.Content.Headers) {
            $k = $p.Key
            if ($k -in @('Transfer-Encoding','Connection','Content-Length')) { continue }
            [void]$headSb.Append(($k + ': ' + (($p.Value) -join ', ') + "`r`n"))
        }
        [void]$headSb.Append("Content-Length: $($respBytes.Length)`r`n")
        [void]$headSb.Append("Connection: close`r`n`r`n")
        $headBytes = [Text.Encoding]::ASCII.GetBytes($headSb.ToString())
        $stream.Write($headBytes, 0, $headBytes.Length)
        if ($respBytes.Length -gt 0) { $stream.Write($respBytes, 0, $respBytes.Length) }
        $stream.Flush()
        $sw.Stop()

        Write-ProxyLog @{ t = (Get-Date).ToString('s'); method = $method; url = $url; rule = $ruleName; status = $status; ms = [int]$sw.ElapsedMilliseconds; reqLen = $(if ($bodyBytes) { $bodyBytes.Length } else { 0 }); respLen = $respBytes.Length }
    } catch {
        try { if ($stream) { Send-Simple $stream 500 'Proxy Error' ($_.Exception.Message) @{} } } catch { }
    } finally {
        try { $client.Close() } catch { }
    }
}



