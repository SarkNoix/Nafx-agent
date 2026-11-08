# 抓网页正文（去掉标签，只留文字）
# 用法: web_fetch_text.ps1 -Url "https://example.com" [-Out page.txt] [-Max 5000]

param(
    [string]$Url = '',
    [string]$Out = '',
    [int]$Max = 8000
)

if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-Output "要指定网址：-Url https://..."
    exit 1
}
if ($Url -notmatch '^https?://') {
    $Url = 'https://' + $Url
}

try {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 `
              -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -ErrorAction Stop
    $html = $resp.Content
    $status = $resp.StatusCode
} catch {
    Write-Output ("抓不到：" + $_.Exception.Message)
    exit 1
}

if ($html -is [byte[]]) { $html = [Text.Encoding]::UTF8.GetString($html) }

$rawLen = $html.Length

# 1) 去掉 script / style / 注释 / head
$text = $html
$text = [regex]::Replace($text, '(?is)<script.*?</script>', '')
$text = [regex]::Replace($text, '(?is)<style.*?</style>', '')
$text = [regex]::Replace($text, '(?is)<noscript.*?</noscript>', '')
$text = [regex]::Replace($text, '(?is)<!--.*?-->', '')
$text = [regex]::Replace($text, '(?is)<head.*?</head>', '')

# 2) 标题单独拿出来
$title = ''
$m = [regex]::Match($html, '(?is)<title[^>]*>(.*?)</title>')
if ($m.Success) { $title = [regex]::Replace($m.Groups[1].Value, '\s+', ' ').Trim() }

# 3) 块级标签转换成换行，其余标签删掉
$text = [regex]::Replace($text, '(?i)</?(p|div|br|li|tr|h[1-6]|section|article|header|footer|table|ul|ol)[^>]*>', "`n")
$text = [regex]::Replace($text, '(?s)<[^>]+>', '')

# 4) 实体
$text = $text.Replace('&nbsp;', ' ').Replace('&lt;', '<').Replace('&gt;', '>')
$text = $text.Replace('&amp;', '&').Replace('&quot;', '"').Replace('&#39;', "'")

# 5) 收拾空白：每行 trim，去掉连续空行
$lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$clean = ($lines -join "`n")

Write-Output ("网址 " + $Url)
Write-Output ("状态 " + $status + "，原始 HTML " + $rawLen + " 字符")
if ($title) { Write-Output ("标题 " + $title) }
Write-Output ("正文 " + $clean.Length + " 字符，共 " + $lines.Count + " 行")
Write-Output ""

if ($clean.Length -eq 0) {
    Write-Output "（没抓到正文，可能是纯 JS 渲染的页面）"
    exit 0
}

if ($Out) {
    try {
        [IO.File]::WriteAllText($Out, $clean, (New-Object Text.UTF8Encoding($false)))
        Write-Output ("已存到 " + $Out)
        exit 0
    } catch {
        Write-Output ("存不进去：" + $_.Exception.Message)
    }
}

# 直接输出，超长截断
if ($clean.Length -gt $Max) {
    Write-Output $clean.Substring(0, $Max)
    Write-Output ""
    Write-Output ("…（后面还有 " + ($clean.Length - $Max) + " 字符，加 -Out 文件名 可以全存下来）")
} else {
    Write-Output $clean
}
