# 发一个 HTTP 请求，把状态码/响应头/正文前几行打出来（模型可直接读）
# 用法: http_probe.ps1 -Url "http://127.0.0.1:8090/" [-Method GET] [-Body "..."] [-Headers "A: 1;B: 2"] [-Proxy "http://127.0.0.1:8899"] [-Insecure] [-Timeout 15] [-Max 4000]

param(
    [string]$Url = '',
    [string]$Method = 'GET',
    [string]$Body = '',
    [string]$Headers = '',
    [string]$Proxy = '',
    [switch]$Insecure,
    [int]$Timeout = 15,
    [int]$Max = 4000
)

if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-Output '要指定地址：-Url http://...'
    exit 1
}
if ($Url -notmatch '^https?://') { $Url = 'http://' + $Url }

try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {}

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
if ($Proxy) {
    $handler.Proxy = New-Object System.Net.WebProxy($Proxy)
    $handler.UseProxy = $true
}
if ($Insecure) {
    $handler.ServerCertificateCustomValidationCallback = { param($m, $c, $ch, $e) return $true }
}
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(1, [Math]::Min(120, $Timeout)))

$req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]$Method, $Url)
if ($Headers) {
    foreach ($pair in ($Headers -split ';')) {
        if ($pair -match '^([^:]+):\s*(.*)$') {
            [void]$req.Headers.TryAddWithoutValidation($matches[1].Trim(), $matches[2].Trim())
        }
    }
}
if ($Body) {
    $req.Content = New-Object System.Net.Http.StringContent($Body, [Text.Encoding]::UTF8, 'application/json')
}

$sw = [Diagnostics.Stopwatch]::StartNew()
try { $resp = $client.SendAsync($req).GetAwaiter().GetResult() }
catch {
    Write-Output ("请求失败：" + $_.Exception.Message)
    Write-Output '排查：地址端口通不通（port_check）；要不要 -Proxy；https 证书问题加 -Insecure'
    exit 1
}
$sw.Stop()

$bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
$text = [Text.Encoding]::UTF8.GetString($bytes)

Write-Output ("{0} {1} → {2} {3}（{4} ms，{5} B）" -f $Method, $Url, [int]$resp.StatusCode, $resp.ReasonPhrase, $sw.ElapsedMilliseconds, $bytes.Length)
Write-Output '响应头：'
$i = 0
foreach ($h in $resp.Headers) {
    if ($i -ge 10) { break }
    Write-Output ("  {0}: {1}" -f $h.Key, (($h.Value) -join ', '))
    $i++
}
foreach ($h in $resp.Content.Headers) {
    if ($i -ge 10) { break }
    Write-Output ("  {0}: {1}" -f $h.Key, (($h.Value) -join ', '))
    $i++
}
if ($bytes.Length -gt 0) {
    $preview = $text
    if ($preview.Length -gt $Max) { $preview = $preview.Substring(0, $Max) + "`n…（还有 " + ($preview.Length - $Max) + ' 字符，已截断）' }
    Write-Output '正文：'
    Write-Output $preview
} else {
    Write-Output '（无正文）'
}
$client.Dispose()
