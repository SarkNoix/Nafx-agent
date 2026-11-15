# ============================================================
#  Nafx · 联网工具（web_search / web_fetch）
#  纯 PowerShell + .NET，不依赖任何外部模块
#  - web_search: 抓 Bing 结果页并解析，返回标题/链接/摘要
#  - web_fetch : 抓网页，去掉脚本样式标签，转成干净文本
# ============================================================

$script:WebTimeout    = 40      # 抓网页的超时秒数（只读超时，不是整体耗时）
$script:WebSearchTimeout = 20   # 搜索页通常很小，单独给个短超时
$script:WebMaxResults = 8       # 默认返回几条搜索结果
$script:WebMaxChars   = 6000    # 抓回文本的默认上限
$script:WebUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Set-WebOptions {
    param([int]$TimeoutSeconds = 0, [int]$MaxChars = 0)
    if ($TimeoutSeconds -gt 0) { $script:WebTimeout = $TimeoutSeconds }
    if ($MaxChars -gt 0) { $script:WebMaxChars = $MaxChars }
}

function Initialize-Web {
    # 老系统默认可能还在 TLS 1.0，联网会直接失败
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor
                                                      [Net.SecurityProtocolType]::Tls11 -bor
                                                      [Net.SecurityProtocolType]::Tls
    } catch { }
    try {
        # 服务器常发 gzip / br，.NET 必须显式声明解压，否则拿到乱码
        [Net.ServicePointManager]::DefaultConnectionLimit = 8
    } catch { }
}

function Convert-HtmlToText {
    param([string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    $t = $Html
    # 去掉整块的脚本、样式、注释（标签可能带属性，如 <style data-for="result" type="text/css">）
    $t = [regex]::Replace($t, '(?is)<script\b[^>]*>.*?</script\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<style\b[^>]*>.*?</style\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<noscript\b[^>]*>.*?</noscript\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<svg\b[^>]*>.*?</svg\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<head\b[^>]*>.*?</head\s*>', ' ')
    $t = [regex]::Replace($t, '(?s)<!--.*?-->', ' ')
    # 表单控件和模板里的内容不是正文：百度就把整页 CSS 塞在 <textarea> 里，
    # 不先整块删掉，等下面把标签去掉，这些 CSS 就会当作正文露出来
    $t = [regex]::Replace($t, '(?is)<textarea\b[^>]*>.*?</textarea\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<template\b[^>]*>.*?</template\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<select\b[^>]*>.*?</select\s*>', ' ')
    $t = [regex]::Replace($t, '(?is)<title\b[^>]*>.*?</title\s*>', ' ')
    # 块级元素转换成换行，保住段落结构
    $t = [regex]::Replace($t, '(?i)</?(p|div|br|li|tr|h[1-6]|section|article|header|footer|table|ul|ol|blockquote)\b[^>]*>', "`n")
    $t = [regex]::Replace($t, '(?i)</?(td|th)\b[^>]*>', ' ')
    # 兜底：有的页面 <style>/<script> 不闭合，上面成对的规则会漏掉。
    # 必须放在「去标签」之前：这一步要靠 <style 这个尖括号定位，标签一去就再也找不到了
    $t = [regex]::Replace($t, '(?is)<(style|script)\b.*', ' ')
    # 其余标签全部去掉
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    # 先折叠行内空白，再解码实体：
    # 反过来的话 &nbsp; 会被解码成不换行空格，夹在词之间变成 "Qwen3 : Think" 这种怪空格
    $t = $t -replace '[ \t\u00A0]+', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace "`r", ''
    $lines = foreach ($ln in ($t -split "`n")) {
        $s = ($ln -replace '\u00A0', ' ').Trim()
        if ($s -ne '') { $s }
    }
    return ($lines -join "`n")
}

function Invoke-WebRaw {
    param([string]$Url, [int]$TimeoutSeconds = 0)
    Initialize-Web
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:WebTimeout }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.UserAgent = $script:WebUA
    $req.Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    $req.Timeout = $TimeoutSeconds * 1000
    $req.ReadWriteTimeout = $TimeoutSeconds * 1000
    $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor
                                  [Net.DecompressionMethods]::Deflate -bor
                                  [Net.DecompressionMethods]::Brotli
    $req.AllowAutoRedirect = $true
    $req.MaximumAutomaticRedirections = 5
    # 补上浏览器会带的头。知乎、百科、微软博客这类站点只看到裸请求就直接 403，
    # 缺 Accept-Language / Referer 是最常见的被拦原因。
    $req.Headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8'
    $req.Headers['Cache-Control'] = 'no-cache'
    $req.Headers['Upgrade-Insecure-Requests'] = '1'
    try {
        $u = [Uri]$Url
        $req.Headers['Referer'] = "$($u.Scheme)://$($u.Host)/"
    } catch { }
    $resp = $req.GetResponse()
    try {
        $stream = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        # 分块读：大页面用 CopyTo 会撞上 ReadWriteTimeout，分块能边读边续命
        $buf = New-Object byte[] 81920
        $total = 0
        $cap = 8MB
        while ($total -lt $cap) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $total += $n
        }
        $bytes = $ms.ToArray()
        $ms.Dispose()
        $charset = ''
        try { $charset = $resp.CharacterSet } catch { }
        $enc = $null
        # 页面里的 <meta charset> 优先于响应头：
        # 不少服务器（如 learn.microsoft.com）响应头只给 HTTP 默认的 ISO-8859-1，
        # 页面实际却是 UTF-8；听响应头就会得到 "ææ¡£" 这种乱码。
        $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(4096, $bytes.Length))
        $mMeta = [regex]::Match($head, '(?i)<meta[^>]+charset\s*=\s*["'']?([\w\-]+)')
        if ($mMeta.Success) {
            try { $enc = [Text.Encoding]::GetEncoding($mMeta.Groups[1].Value.ToLower()) } catch { }
        }
        if ($null -eq $enc -and $charset) {
            # 响应头的 ISO-8859-1 / US-ASCII 基本等于"没声明"，不可信
            if ($charset -notmatch '(?i)iso-8859|us-ascii|windows-1252') {
                try { $enc = [Text.Encoding]::GetEncoding($charset.Trim('"')) } catch { }
            }
        }
        if ($null -ne $enc) {
            $text = $enc.GetString($bytes)
        } else {
            # 什么线索都没有：先按严格 UTF-8 解，解不动再退回系统 ANSI（中文为 GBK）
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            try { $text = $strict.GetString($bytes) }
            catch { $text = [Text.Encoding]::GetEncoding(0).GetString($bytes) }
        }
        return [pscustomobject]@{ Text = $text; FinalUrl = $resp.ResponseUri.AbsoluteUri; Status = [int]$resp.StatusCode }
    } finally {
        $resp.Close()
    }
}

function Invoke-WebSearch {
    param([string]$Query, [int]$Count = 0)

    if ([string]::IsNullOrWhiteSpace($Query)) { throw 'query 不能为空，把要搜索的关键词填进去。' }
    if ($Count -le 0) { $Count = $script:WebMaxResults }
    if ($Count -gt 20) { $Count = 20 }

    # 这台机器是 Windows，遇到"命令/脚本"类查询时，必须让搜索引擎知道是 Windows。
    # 实测：搜 "whoami /privileges" 排第一的是「Linux whoami 命令教程」，
    # 因为同名命令 Linux 也叫 whoami，引擎默认偏 Linux。
    # 所以对命令行类查询，主动补上 "Windows" 这个语境词。
    $q2 = $Query.Trim()

    # ---- 1) 判断是不是 Windows 命令行/脚本类查询 ----
    # 典型特征：cmd 命令名、带 /参数 的开关、.ps1/.bat、PowerShell 语法
    $winCmdNames = '(?i)^(whoami|net|wmic|sc|reg|tasklist|taskkill|schtasks|systeminfo|ipconfig|netstat|' +
                   'nslookup|ping|tracert|route|arp|attrib|icacls|cacls|takeown|robocopy|xcopy|' +
                   'dir|type|find|findstr|echo|copy|move|ren|del|rd|md|cd|tree|where|fc|sort|more|' +
                   'forfiles|fsutil|bcdedit|diskpart|chkdsk|driverquery|getmac|powercfg|shutdown|' +
                   'certutil|bitsadmin|curl|wsl|powershell|pwsh|cmd)\b'
    # 带 /x 这种开关的，基本就是 Windows 命令（Linux 用 -x）
    $hasSlashSwitch = $q2 -match '\s/[a-zA-Z]'
    # 明确是 Linux 语境的，就别乱加 Windows
    $isLinuxQuery = $q2 -match '(?i)linux|ubuntu|debian|centos|bash|shell 脚本|grep|awk|sed|chmod|chown|apt-get|yum |systemctl|/etc/|/usr/|/var/'
    $isWinQuery = (-not $isLinuxQuery) -and (
        $q2 -match $winCmdNames -or
        $q2 -match '(?i)powershell|\.ps1|\.bat|\.cmd|cmd 命令|批处理|注册表|组策略|服务管理器'
    )

    # ---- 2) 按类型补语境 ----
    if ($isWinQuery) {
        # 已经是 Windows 语境的，不重复加
        if ($q2 -notmatch '(?i)\bwindows\b|\bwin10\b|\bwin11\b|powershell|cmd 命令|批处理') {
            if ($q2 -match '(?i)powershell|\.ps1' -or $q2 -match '^[A-Z][a-z]+-[A-Z]') {
                $q2 = "PowerShell Windows $q2"
            } elseif ($hasSlashSwitch -or $q2 -match $winCmdNames) {
                # cmd 命令：明确写 windows cmd，避免命中 Linux 同名命令
                $q2 = "$q2 windows cmd 命令"
            } else {
                $q2 = "Windows $q2"
            }
        }
    }
    elseif ($q2 -match '^[A-Z][a-z]+-[A-Z]' -and $q2 -notmatch '^(?i)powershell') {
        # PowerShell 的 Cmdlet（Get-Date 这种）：前面加 PowerShell 才不会被当成英语单词
        $q2 = "PowerShell $q2"
    }
    elseif ($q2 -match '^[\u4e00-\u9fa5]{1,6}$' -and $q2 -notmatch '是什么|什么|怎么|如何') {
        $q2 = "$q2 是什么"
    }

    $q = [Uri]::EscapeDataString($q2)
    $url = "https://www.bing.com/search?q=$q&setlang=zh-CN&count=$Count"

    try { $page = Invoke-WebRaw $url -TimeoutSeconds $script:WebSearchTimeout }
    catch {
        throw ("联网失败：" + $_.Exception.Message + "。可能是网络不通，或者搜索引擎暂时拒绝访问。")
    }

    $html = $page.Text
    $results = @()

    # Bing 的每条自然结果都在 <li class="b_algo"> 里
    $blocks = [regex]::Matches($html, '(?is)<li class="b_algo".*?</li>')
    if ($blocks.Count -eq 0) {
        return [pscustomobject]@{
            Query   = $Query
            Results = @()
            Note    = '没有解析到结果。可能是关键词太生僻，或搜索引擎返回了异常页面。'
        }
    }

    foreach ($b in $blocks) {
        if ($results.Count -ge $Count) { break }
        $block = $b.Value

        # 标题和链接：取第一个 h2 里的 a
        $title = ''
        $link = ''
        $mA = [regex]::Match($block, '(?is)<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>')
        if ($mA.Success) {
            $link = $mA.Groups[1].Value
            $title = Convert-HtmlToText $mA.Groups[2].Value
        } else {
            $mA2 = [regex]::Match($block, '(?is)<a[^>]*href="(http[^"]+)"[^>]*>(.*?)</a>')
            if ($mA2.Success) {
                $link = $mA2.Groups[1].Value
                $title = Convert-HtmlToText $mA2.Groups[2].Value
            }
        }
        if ([string]::IsNullOrWhiteSpace($title)) { continue }

        # 摘要：Bing 用 <p> 或 class 含 b_caption 的块
        $snippet = ''
        $mS = [regex]::Match($block, '(?is)<p[^>]*>(.*?)</p>')
        if ($mS.Success) { $snippet = Convert-HtmlToText $mS.Groups[1].Value }
        if ([string]::IsNullOrWhiteSpace($snippet)) {
            $mS2 = [regex]::Match($block, '(?is)class="[^"]*b_caption[^"]*"[^>]*>(.*?)</div>')
            if ($mS2.Success) { $snippet = Convert-HtmlToText $mS2.Groups[1].Value }
        }
        $snippet = ($snippet -replace '\s+', ' ').Trim()
        if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '…' }

        $results += [pscustomobject]@{
            Title   = $title.Trim()
            Url     = $link
            Snippet = $snippet
        }
    }

    return [pscustomobject]@{
        Query   = $Query
        Results = $results
        Note    = ''
    }
}

function Invoke-WebFetch {
    param([string]$Url, [int]$MaxChars = 0)

    if ([string]::IsNullOrWhiteSpace($Url)) { throw 'url 不能为空。' }
    $Url = $Url.Trim()
    if ($Url -notmatch '^https?://') {
        if ($Url -match '^[\w\.-]+\.[a-z]{2,}(/|$)') { $Url = 'https://' + $Url }
        else { throw "这不是一个网址：$Url。要以 http:// 或 https:// 开头。" }
    }
    if ($MaxChars -le 0) { $MaxChars = $script:WebMaxChars }

    try { $page = Invoke-WebRaw $Url }
    catch {
        $msg = $_.Exception.Message
        # 403/401 很常见：知乎、百度百科这类站点直接挡程序访问。
        # 别让它傻乎乎地反复试同一批站点，明确告诉它换来源。
        if ($msg -match '\((403|401|999)\)') {
            $host0 = try { ([Uri]$Url).Host } catch { $Url }
            throw ("$host0 拒绝程序访问（403）。这类站点（知乎、百度百科、部分博客）基本抓不到，" +
                   "换一条别的来源，或者只用搜索结果里的摘要作答。不要把同一个站点再试一次。")
        }
        if ($msg -match '\((404)\)') { throw "这个网址不存在（404）：$Url。换一条搜索结果里的链接。" }
        throw ("抓取失败：" + $msg + "。网址可能不存在、需要登录，或者网络不通。")
    }

    $raw = $page.Text
    $isHtml = ($raw -match '(?i)<html|<body|<div|<p>')
    if ($isHtml) { $text = Convert-HtmlToText $raw } else { $text = $raw.Trim() }

    # 取页面标题，方便模型知道抓的是什么
    $pageTitle = ''
    $mT = [regex]::Match($raw, '(?is)<title[^>]*>(.*?)</title>')
    if ($mT.Success) { $pageTitle = (Convert-HtmlToText $mT.Groups[1].Value).Trim() }

    $total = $text.Length
    $truncated = $false
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars)
        $truncated = $true
    }

    return [pscustomobject]@{
        Url       = $page.FinalUrl
        Title     = $pageTitle
        Text      = $text
        TotalLen  = $total
        Truncated = $truncated
    }
}

# ============================================================
#  Windows 官方文档直查
#
#  为什么需要这个：
#    这台机器是 Windows，但搜索引擎对 "whoami /privileges" 这类查询
#    默认返回「Linux whoami 命令教程」——同名命令在 Linux 也有，
#    Bing 偏偏先给 Linux 的，加了 "windows cmd" 反而变成微软下载页。
#    与其跟搜索引擎斗，不如直接查微软官方文档：
#      cmd 命令   learn.microsoft.com/*/windows-server/administration/windows-commands/<名字>
#      PowerShell learn.microsoft.com/*/powershell/module/<模块>/<名字>
#    标题和内容都是权威的，还分中英文两版。
# ============================================================
function Get-WinDocCandidates {
    param([string]$Name)
    $raw = $Name.Trim().ToLower()
    $raw = $raw -replace '^[\s/\\-]+', ''
    $raw = $raw -replace '\s+/.*$', ''      # 去掉 /privileges 这类参数
    $raw = $raw -replace '\.exe$', ''

    $cmdBase   = 'https://learn.microsoft.com/zh-cn/windows-server/administration/windows-commands/'
    $cmdBaseEn = 'https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/'
    $psBase    = 'https://learn.microsoft.com/zh-cn/powershell/module/'
    $psBaseEn  = 'https://learn.microsoft.com/en-us/powershell/module/'

    # net 系列在文档里叫 net-user / net-share 这种带横线的名字
    $n = $raw -replace '\s+', '-'
    if ($raw -match '^net\s') { $n = $raw -replace '\s+', '-' }

    $list = @()
    $list += @{ Url = "$cmdBase$n"; Kind = 'cmd 命令'; Name = $n }
    if ($n -match '^[a-z]+-[a-z]' -and $n -notmatch '^net-') {
        foreach ($mod in @('microsoft.powershell.utility', 'microsoft.powershell.management', 'microsoft.powershell.core')) {
            $list += @{ Url = "$psBase$mod/$n"; Kind = 'PowerShell 命令'; Name = $n }
        }
    }
    # 兜底：英文站
    $list += @{ Url = "$cmdBaseEn$n"; Kind = 'cmd 命令（英文）'; Name = $n }
    if ($n -match '^[a-z]+-[a-z]' -and $n -notmatch '^net-') {
        foreach ($mod in @('microsoft.powershell.utility', 'microsoft.powershell.management')) {
            $list += @{ Url = "$psBaseEn$mod/$n"; Kind = 'PowerShell 命令（英文）'; Name = $n }
        }
    }
    return $list
}

function Invoke-WinDoc {
    param([string]$Name, [int]$MaxChars = 0)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'name 不能为空，把命令名填进去，比如 whoami' }
    if ($MaxChars -le 0) { $MaxChars = 4000 }

    $cands = Get-WinDocCandidates -Name $Name
    if ($cands.Count -eq 0) { throw "看不懂要查什么命令：$Name" }

    $tried = @()
    foreach ($c in $cands) {
        $tried += $c.Url
        try {
            $page = Invoke-WebFetch -Url $c.Url -MaxChars ($MaxChars * 3)
            if ($page -and $page.Title -and $page.Title -notmatch '(?i)^404|not found|找不到|页面不存在') {
                $body = $page.Text
                # 文档页顶部是导航噪音（跳至主要内容 / 浏览器提示 / 目录 / 退出编辑器模式），
                # 从"语法"或"描述"这一行开始才是真正有用的内容。
                $cut = [regex]::Match($body, '(?m)^\s*(语法|描述|示例|备注|Syntax|Description|Examples|Remarks|Applies to|适用范围)\s*$')
                if ($cut.Success -and $cut.Index -gt 0) { $body = $body.Substring($cut.Index) }
                # 再把页脚和版权区砍掉
                $endPat = [regex]::Match($body, '(?m)^\s*(其他资源|相关信息|Additional resources|Related content|反馈|Feedback)\s*$')
                if ($endPat.Success -and $endPat.Index -gt 0) { $body = $body.Substring(0, $endPat.Index) }
                $body = ($body -replace "(?m)^\s*$", ' ').Trim()
                if ($body.Length -gt $MaxChars) { $body = $body.Substring(0, $MaxChars) + '…' }
                return [pscustomobject]@{
                    Ok    = $true
                    Kind  = $c.Kind
                    Name  = $c.Name
                    Title = $page.Title
                    Url   = $(if ($page.Url) { $page.Url } else { $c.Url })
                    Text  = $body
                }
            }
        } catch { }
    }
    return [pscustomobject]@{
        Ok    = $false
        Kind  = ''
        Name  = $Name
        Title = ''
        Url   = ''
        Text  = "官方文档里没找到「$Name」。试过的地址：`n" + ($tried -join "`n") +
                "`n可能是这个命令名不对，或者它不是 Windows 自带的。可以改用 web_search 搜一下，但记得关键词里带 Windows。"
    }
}

function Format-WinDocResult {
    param($Result)
    if ($null -eq $Result) { return '错误：没查到结果' }
    if (-not $Result.Ok) { return $Result.Text }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("[$($Result.Kind)] $($Result.Name)　官方文档：$($Result.Title)")
    [void]$sb.AppendLine("来源：$($Result.Url)")
    [void]$sb.AppendLine('--- 正文 ---')
    [void]$sb.Append($Result.Text)
    return $sb.ToString().Trim()
}

# 把结构化结果转成给模型看的纯文本
function Format-SearchResult {    param($Result)
    if ($null -eq $Result) { return '错误：搜索没有返回结果' }
    if ($Result.Results.Count -eq 0) {
        return "搜索「$($Result.Query)」没有找到结果。$($Result.Note)"
    }
    # 结果要压紧。
    # 实测「2026年 诺贝尔文学奖 得主」搜回 6 条 = 1124 字符 ——
    # 光这一条 tool 消息就占了历史一多半（2205 tok），直接把上下文顶爆，
    # 后面只能把工具从 9 个砍到 5 个，任务就废了。
    # 这里压三处：摘要截 80 字、链接截 70 字（百度百科那种 %E5%B9%B4 编码串太长）。
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("搜索「$($Result.Query)」共 $($Result.Results.Count) 条：")
    $i = 0
    foreach ($r in $Result.Results) {
        $i++
        $title = [string]$r.Title
        if ($title.Length -gt 50) { $title = $title.Substring(0,50) + '…' }
        $url = [string]$r.Url
        if ($url.Length -gt 70) { $url = $url.Substring(0,70) + '…' }
        [void]$sb.AppendLine("$i. $title")
        [void]$sb.AppendLine("   $url")
        if ($r.Snippet) {
            $sn = ([string]$r.Snippet) -replace '\s+', ' '
            if ($sn.Length -gt 80) { $sn = $sn.Substring(0,80) + '…' }
            [void]$sb.Append("   摘要：$sn`n")
        }
    }
    [void]$sb.AppendLine('要点：')
    [void]$sb.AppendLine('- 摘要能回答就直接答，不必再抓网页')
    [void]$sb.AppendLine('- 摘要不够才用 web_fetch 打开一条；同一条别重复打开')
    [void]$sb.AppendLine('- 同一问题别重复搜，换说法结果也差不多')
    return $sb.ToString().Trim()
}

function Format-FetchResult {
    param($Result)
    if ($null -eq $Result) { return '错误：抓取没有返回结果' }
    $sb = New-Object System.Text.StringBuilder
    if ($Result.Title) { [void]$sb.AppendLine("页面标题：$($Result.Title)") }
    [void]$sb.AppendLine("网址：$($Result.Url)")
    [void]$sb.AppendLine('--- 正文 ---')
    [void]$sb.Append($Result.Text)
    if ($Result.Truncated) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("...[已截断，全文 $($Result.TotalLen) 字符]")
    }
    return $sb.ToString().Trim()
}
