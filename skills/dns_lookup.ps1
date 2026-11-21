# 查域名解析（A/AAAA/CNAME），排查「域名解析到哪、解析失败」
# 用法: dns_lookup.ps1 -Name example.com [-Server 8.8.8.8]

param(
    [string]$Name = '',
    [string]$Server = ''
)

if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Output '要指定域名：-Name example.com'
    exit 1
}

try {
    if ($Server) {
        $recs = Resolve-DnsName -Name $Name -Server $Server -ErrorAction Stop
    } else {
        $recs = Resolve-DnsName -Name $Name -ErrorAction Stop
    }
} catch {
    Write-Output ("解析失败：" + $_.Exception.Message)
    Write-Output '下一步：换 -Server 8.8.8.8 再试；确认域名拼写；本机 DNS/代理设置。'
    exit 1
}

$ipv4 = @($recs | Where-Object { $_.Type -eq 'A' })
$ipv6 = @($recs | Where-Object { $_.Type -eq 'AAAA' })
$cname = @($recs | Where-Object { $_.Type -eq 'CNAME' })

Write-Output ("{0} 解析结果（{1} 条）：" -f $Name, @($recs).Count)
foreach ($r in $cname) { Write-Output ("  CNAME → {0}" -f $r.NameHost) }
foreach ($r in $ipv4)  { Write-Output ("  A     → {0}" -f $r.IPAddress) }
foreach ($r in $ipv6)  { Write-Output ("  AAAA  → {0}" -f $r.IPAddress) }
if ($ipv4.Count -eq 0 -and $ipv6.Count -eq 0 -and $cname.Count -eq 0) {
    foreach ($r in ($recs | Select-Object -First 8)) {
        $v = [string]$r.IPAddress
        if (-not $v) { $v = [string]$r.NameHost }
        Write-Output ("  {0}  {1}" -f $r.Type, $v)
    }
}
