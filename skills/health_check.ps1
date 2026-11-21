# ============================================================
#  本机体检（system health check）
#
#  只查自己这台机器，不碰任何外部目标。
#  查的是「我的电脑现在什么状态」：
#    网络：谁在监听、谁在连外面、防火墙开没开
#    启动：开机自启了什么
#    账号：有哪些用户、是不是管理员
#    补丁：系统版本、最近装的更新
#    权限：敏感目录谁都能写吗
#    磁盘：还剩多少
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File health-check.ps1
#    powershell -ExecutionPolicy Bypass -File health-check.ps1 -Section net
#
#  参数 -Section 可选：net / boot / account / patch / perm / disk / all（默认 all）
# ============================================================

param(
    [ValidateSet('all','net','boot','account','patch','perm','disk')]
    [string]$Section = 'all',
    [int]$TopN = 15,          # listening / 连接 各显示前多少条
    [switch]$Json,            # 只输出 JSON，给别的程序读
    [switch]$Full            # 完整输出（默认精简，只报问题和关键数字）
)

$ErrorActionPreference = 'SilentlyContinue'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$out = [ordered]@{}

function Add-Item {
    param($Bucket, $Key, $Value)
    if (-not $Bucket.Contains($Key)) { $Bucket[$Key] = @() }
    $Bucket[$Key] += $Value
}

# ------------------------------------------------------------
#  1. 网络：监听端口 / 活动连接 / 防火墙
# ------------------------------------------------------------
function Get-NetSection {
    $r = [ordered]@{}

    # ---- 谁在监听（本机开了什么服务）----
    # Get-NetTCPConnection 在 PS 5.1 上要 Win8+，19044 没问题。
    # 拿不到就退回 netstat，别让整段挂掉。
    $listen = @()
    try {
        $listen = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object {
            $procName = ''
            try { $procName = (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName } catch { }
            [pscustomobject]@{
                addr    = [string]$_.LocalAddress
                port    = [int]$_.LocalPort
                pid     = [int]$_.OwningProcess
                process = $procName
                # 只听本地回环 = 外部连不进来，安全；只听 0.0.0.0 = 局域网能连
                scope   = if ([string]$_.LocalAddress -in @('127.0.0.1','::1')) { 'local' } else { 'any' }
            }
        })
    } catch {
        $listen = @(& netstat -ano 2>$null | Select-String 'LISTENING' | ForEach-Object {
            $parts = ($_.Line -split '\s+') | Where-Object { $_ }
            if ($parts.Count -ge 5) {
                $ep = [string]$parts[1]
                $port = 0; [void][int]::TryParse(($ep -split ':')[-1], [ref]$port)
                [pscustomobject]@{
                    addr = ($ep -split ':')[0]; port = $port
                    pid = [int]$parts[-1]; process = ''
                    scope = if ($ep -match '^(127\.0\.0\.1|\[::1\])') { 'local' } else { 'any' }
                }
            }
        })
    }

    $r.listenTotal = @($listen).Count
    # Windows 自己就监听的端口，列出来但不该当风险报。
    # 135/139/445 = SMB+RPC，3389 = 远程桌面，这些默认开着是正常的，
    # 真正要留意的是「陌生的进程占了对外端口」。
    $sysPorts = @(135,139,445,5040,5357,7680,49664,49665,49666,49667,49668,49669,49670)
    $r.systemPorts = $sysPorts
    # 对外开放里，排除系统端口和动态高位端口（49152+ 都是 RPC 随机端口）
    $r.openNotable = @($listen | Where-Object {
        $_.scope -eq 'any' -and $sysPorts -notcontains $_.port -and $_.port -lt 49152
    })
    $r.listenOpen  = @($listen | Where-Object { $_.scope -eq 'any' }).Count
    # 只挑「对外开放」的排前面 —— 这些才是需要留意的
    $r.listening = @($listen |
        Sort-Object @{ Expression = { if ($_.scope -eq 'any') { 0 } else { 1 } } }, @{ Expression = 'port' } |
        Select-Object -First $TopN)

    # ---- 谁在连外面（活动连接）----
    $conn = @()
    try {
        $conn = @(Get-NetTCPConnection -State Established -ErrorAction Stop |
            Where-Object { [string]$_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0','::') } |
            ForEach-Object {
                $procName = ''
                try { $procName = (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName } catch { }
                [pscustomobject]@{
                    remote  = ([string]$_.RemoteAddress) + ':' + $_.RemotePort
                    pid     = [int]$_.OwningProcess
                    process = $procName
                }
            })
    } catch { }
    $r.connTotal = @($conn).Count
    $r.connections = @($conn | Sort-Object process | Select-Object -First $TopN)

    # ---- 防火墙 ----
    # 三套配置（域/专用/公用）任一关着都算有问题
    $fw = @()
    try {
        $fw = @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.Name; enabled = [bool]$_.Enabled }
        })
    } catch { }
    $r.firewall = $fw
    $r.firewallOff = @($fw | Where-Object { -not $_.enabled } | ForEach-Object { $_.name })

    return $r
}

# ------------------------------------------------------------
#  2. 启动项：开机自启了什么
# ------------------------------------------------------------
function Get-BootSection {
    $r = [ordered]@{}
    $items = @()

    # ---- 注册表 Run 键 ----
    # 四个位置都要看：HKLM/HKCU × 32位/64位。
    # WOW64 那两处在 64 位系统上容易漏，可疑软件常躲在这里。
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path $k)) { continue }
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($name in $p.PSObject.Properties.Name) {
            if ($name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)') { continue }
            # 注册表路径太长，缩成 HKCU\Run / HKLM\Run 这种好读的形式。
            $short = $k
            if ($k -like 'HKCU:*') { $short = 'HKCU' + $k.Substring(4) }
            elseif ($k -like 'HKLM:*') { $short = 'HKLM' + $k.Substring(4) }
            $short = $short.Replace('\SOFTWARE\Microsoft\Windows\CurrentVersion', '')
            $items += [pscustomobject]@{
                source = 'registry'
                where  = $short
                name   = [string]$name
                cmd    = [string]$p.$name
            }
        }
    }

    # ---- 启动文件夹 ----
    foreach ($sf in @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )) {
        if (-not $sf -or -not (Test-Path $sf)) { continue }
        foreach ($f in @(Get-ChildItem $sf -File -ErrorAction SilentlyContinue)) {
            $items += [pscustomobject]@{
                source = 'startup-folder'; where = $sf; name = $f.Name; cmd = $f.FullName
            }
        }
    }

    $r.total = @($items).Count
    $r.items = @($items | Select-Object -First $TopN)
    return $r
}

# ------------------------------------------------------------
#  3. 账号：本机用户 + 管理员组
# ------------------------------------------------------------
function Get-AccountSection {
    $r = [ordered]@{}

    $users = @()
    try {
        $users = @(Get-LocalUser -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                name      = [string]$_.Name
                enabled   = [bool]$_.Enabled
                lastLogon = if ($_.LastLogon) { $_.LastLogon.ToString('yyyy-MM-dd HH:mm', $Inv) } else { '从未' }
                # 有密码 = 能登录；空白密码的账号是明确风险
                password  = if ($_.PasswordRequired) { '有' } else { '无（风险）' }
            }
        })
    } catch {
        # 老系统没 Get-LocalUser，退回 net user
        $users = @(& net user 2>$null | Select-Object -Skip 4 | ForEach-Object {
            foreach ($n in ($_ -split '\s+')) {
                if ($n.Trim()) { [pscustomobject]@{ name = $n.Trim(); enabled = $true; lastLogon = '?'; password = '?' } }
            }
        })
    }
    $r.users = $users

    # 管理员组成员 —— 这个是重点，多一个成员就是多一个能改系统的人
    $admins = @()
    try {
        $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                name   = [string]$_.Name
                source = [string]$_.PrincipalSource    # Local / MicrosoftAccount / AzureAD
                type   = [string]$_.ObjectClass
            }
        })
    } catch { }
    $r.administrators = $admins
    $r.adminCount = @($admins).Count

    # 当前是不是提权运行
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        $r.isElevated = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $r.currentUser = [string]$id.Name
    } catch { }

    return $r
}

# ------------------------------------------------------------
#  4. 补丁：系统版本 + 最近更新 + 杀毒状态
# ------------------------------------------------------------
function Get-PatchSection {
    $r = [ordered]@{}

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $r.os = [string]$os.Caption
        $r.version = [string]$os.Version
        $r.build = [string]$os.BuildNumber
        $r.installedOn = $(if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd', $Inv) } else { '' })
        $r.lastBoot = $(if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm', $Inv) } else { '' })
    } catch { }

    # 最近的更新。Win32_QuickFixEngineering 只有装了补丁的条目，
    # 拿不到「一直没装」的情况，但能看出多久没更新过。
    $hf = @()
    try {
        $hf = @(Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop |
            Where-Object { $_.InstalledOn } |
            Sort-Object InstalledOn -Descending |
            Select-Object -First 8 | ForEach-Object {
                [pscustomobject]@{
                    id = [string]$_.HotFixID
                    on = try { ([datetime]$_.InstalledOn).ToString('yyyy-MM-dd', $Inv) } catch { [string]$_.InstalledOn }
                }
            })
    } catch { }
    $r.recentUpdates = $hf
    if ($hf.Count -gt 0) { $r.lastUpdate = $hf[0].on } else { $r.lastUpdate = '' }

    # Defender 状态
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $r.defender = [ordered]@{
            realtime      = [bool]$mp.RealTimeProtectionEnabled
            antivirus     = [bool]$mp.AntivirusEnabled
            signaturesOld = 0
            signatureDate = ''
        }
        if ($mp.AntivirusSignatureLastUpdated) {
            $r.defender.signatureDate = $mp.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd', $Inv)
            $r.defender.signaturesOld = [int]((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays
        }
    } catch {
        $r.defender = [ordered]@{ note = '读不到 Defender 状态（可能被第三方杀软接管，或不是管理员）' }
    }

    return $r
}

# ------------------------------------------------------------
#  5. 敏感目录权限：谁能写
# ------------------------------------------------------------
function Get-PermSection {
    $r = [ordered]@{}
    # 挑几个「别人能写 = 有风险」的目录
    $targets = @(
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32'),
        $env:ProgramFiles,
        $env:ProgramData
    ) | Where-Object { $_ -and (Test-Path $_) }

    $rows = @()
    foreach ($t in $targets) {
        $acl = $null
        try { $acl = Get-Acl -Path $t -ErrorAction Stop } catch { continue }
        # 只看「Everyone / Users / Authenticated Users」这些宽泛主体有没有写权限
        $wideWrite = @($acl.Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and
            ([string]$_.IdentityReference) -match 'Everyone|BUILTIN\\Users|Authenticated Users|INTERACTIVE' -and
            ([string]$_.FileSystemRights) -match 'Write|Modify|FullControl'
        })
        $rows += [pscustomobject]@{
            path       = $t
            wideWrite  = $wideWrite.Count
            who        = (@($wideWrite | ForEach-Object { [string]$_.IdentityReference } | Select-Object -Unique) -join ', ')
        }
    }
    $r.dirs = $rows
    $r.riskyCount = @($rows | Where-Object { $_.wideWrite -gt 0 }).Count
    return $r
}

# ------------------------------------------------------------
#  6. 磁盘
# ------------------------------------------------------------
function Get-DiskSection {
    $r = [ordered]@{}
    $rows = @()
    try {
        $rows = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
            $total = [double]$_.Size / 1GB
            $free  = [double]$_.FreeSpace / 1GB
            [pscustomobject]@{
                drive    = [string]$_.DeviceID
                totalGB  = [math]::Round($total, 1)
                freeGB   = [math]::Round($free, 1)
                usedPct  = if ($total -gt 0) { [math]::Round(($total - $free) / $total * 100) } else { 0 }
            }
        })
    } catch { }
    $r.drives = $rows
    # 低于 10% 剩余就点名
    $r.lowSpace = @($rows | Where-Object { $_.usedPct -ge 90 } | ForEach-Object { $_.drive })
    return $r
}

# ------------------------------------------------------------
#  跑
# ------------------------------------------------------------
$want = $(if ($Section -eq 'all') { @('net','boot','account','patch','perm','disk') } else { @($Section) })

foreach ($s in $want) {
    switch ($s) {
        'net'     { $out.net     = Get-NetSection }
        'boot'    { $out.boot    = Get-BootSection }
        'account' { $out.account = Get-AccountSection }
        'patch'   { $out.patch   = Get-PatchSection }
        'perm'    { $out.perm    = Get-PermSection }
        'disk'    { $out.disk    = Get-DiskSection }
    }
}
$out.generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv)

# ---- 输出 ----
# ---- 精简模式：只报「需要处理的」，别把几十行原始数据塞给模型 ----
#
# 为什么要有这个：完整输出约 1500 字符，全部进模型历史会撑爆上下文，
# 实测 4096 上下文下直接 400 Bad Request、任务卡死。
# 精简模式只留：该处理的问题 + 几个核心数字，约 400 字符。
if (-not $Full -and -not $Json) {
    $lines2 = @()
    $lines2 += '本机体检 ' + $out.generatedAt

    if ($out.net) {
        $off = @($out.net.firewallOff)
        if ($off.Count -gt 0) { $lines2 += ('⚠ 防火墙关着：' + ($off -join '、')) } else { $lines2 += '✓ 防火墙三套全开' }
        $nb = @($out.net.openNotable)
        if ($nb.Count -gt 0) {
            $lines2 += ('⚠ 非系统服务对外端口 ' + $nb.Count + ' 个：' + (($nb | ForEach-Object { '`' + $_.port + '(' + $_.process + ')' }) -join '、'))
        } else { $lines2 += '✓ 没有额外的对外端口' }
        $lines2 += ('监听 ' + $out.net.listenTotal + ' 个，活动连接 ' + $out.net.connTotal + ' 条')
    }

    if ($out.account) {
        $blank = @($out.account.users | Where-Object { $_.enabled -and $_.password -match '无' })
        if ($blank.Count -gt 0) { $lines2 += ('⚠ 启用且空白密码的账号：' + (($blank | ForEach-Object { $_.name }) -join '、')) } else { $lines2 += '✓ 没有空白密码的启用账号' }
        if ($out.account.adminCount -gt 2) { $lines2 += ('⚠ 管理员组有 ' + $out.account.adminCount + ' 个成员') } else { $lines2 += ('✓ 管理员组 ' + $out.account.adminCount + ' 个成员') }
    }

    if ($out.boot) {
        $lines2 += ('开机自启 ' + $out.boot.total + ' 项：' + (($out.boot.items | ForEach-Object { $_.name }) -join '、'))
    }

    if ($out.patch) {
        $d = $out.patch.defender
        if ($d -and $d.realtime -eq $false) { $lines2 += '⚠ Defender 实时防护关着' }
        elseif ($d -and $d.realtime -eq $true) { $lines2 += '✓ Defender 实时防护开着' }
        $lines2 += ('最近更新 ' + $(if ($out.patch.lastUpdate) { $out.patch.lastUpdate } else { '查不到' }))
    }

    if ($out.perm -and $out.perm.riskyCount -gt 0) {
        $risky = @($out.perm.dirs | Where-Object { $_.wideWrite -gt 0 -and $_.path -notmatch 'ProgramData' })
        if ($risky.Count -gt 0) { $lines2 += ('⚠ 敏感目录可写：' + (($risky | ForEach-Object { $_.path }) -join '、')) }
    }

    if ($out.disk -and @($out.disk.lowSpace).Count -gt 0) { $lines2 += ('⚠ 磁盘快满：' + (@($out.disk.lowSpace) -join '、')) }

    $lines2 += ''
    $lines2 += '（只查了本机状态，没扫描任何外部目标。要看全部细节加 -Full）'
    $lines2 | ForEach-Object { Write-Host $_ }
    return
}

if ($Json) {
    $out | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  本机体检' -ForegroundColor Cyan
Write-Host ('  ' + $out.generatedAt) -ForegroundColor DarkGray
Write-Host '======================================================' -ForegroundColor Cyan

if ($out.patch) {
    Write-Host ''
    Write-Host '【系统】' -ForegroundColor Yellow
    Write-Host ('  ' + $out.patch.os)
    Write-Host ('  版本 ' + $out.patch.version + '  内部版本 ' + $out.patch.build)
    Write-Host ('  最近更新 ' + $(if ($out.patch.lastUpdate) { $out.patch.lastUpdate } else { '查不到' })) `
        -ForegroundColor $(if ($out.patch.lastUpdate) { 'Gray' } else { 'Red' })
    $d = $out.patch.defender
    if ($d -and $d.realtime -ne $null) {
        $f = $(if ($d.realtime) { '开' } else { '关（风险）' })
        $c = $(if ($d.realtime) { 'Green' } else { 'Red' })
        Write-Host ('  Defender 实时防护 ' + $f + '  病毒库 ' + $d.signatureDate + '（' + $d.signaturesOld + ' 天前）') -ForegroundColor $c
    }
}

if ($out.net) {
    Write-Host ''
    Write-Host '【网络】' -ForegroundColor Yellow
    Write-Host ('  监听端口 ' + $out.net.listenTotal + ' 个，其中系统服务 ' + $out.net.listenOpen + ' 个对外')
    # 只报「非系统服务」的对外端口 —— 135/445/3389 这些默认开着是正常的，
    # 一股脑列出来只会让人麻木，真正该注意的是陌生进程占了对外端口。
    $notable = @($out.net.openNotable)
    if ($notable.Count -gt 0) {
        Write-Host ('  ⚠ 系统服务以外的对外端口 ' + $notable.Count + ' 个：') -ForegroundColor Yellow
        foreach ($l in $notable) {
            Write-Host ('    ' + ([string]$l.addr).PadRight(16) + ':' + ([string]$l.port).PadRight(6) + ' ' + $l.process + ' (PID ' + $l.pid + ')') -ForegroundColor Yellow
        }
    } else {
        Write-Host '  ✓ 没有额外的对外端口' -ForegroundColor Green
    }
    Write-Host ('  活动连接 ' + $out.net.connTotal + ' 条')
    # 同一进程连外面很多次，可能是同步软件，也可能是异常外联，列出来让人自己判断
    foreach ($c in @($out.net.connections | Select-Object -First 8)) {
        Write-Host ('    ' + $c.process.PadRight(18) + $c.remote) -ForegroundColor DarkGray
    }
    $fw = @($out.net.firewall)
    if ($fw.Count -gt 0) {
        $off = $out.net.firewallOff
        if ($off.Count -eq 0) {
            Write-Host '  防火墙：三套全开 ✓' -ForegroundColor Green
        } else {
            Write-Host ('  防火墙：' + ($off -join '、') + ' 关着（风险）') -ForegroundColor Red
        }
    }
}

if ($out.account) {
    Write-Host ''
    Write-Host '【账号】' -ForegroundColor Yellow
    Write-Host ('  当前用户 ' + $out.account.currentUser + '  提权 ' + $(if ($out.account.isElevated) { '是' } else { '否' }))
    Write-Host ('  本机账号 ' + @($out.account.users).Count + ' 个：')
    foreach ($u in @($out.account.users)) {
        $warn = $(if ($u.enabled -and $u.password -match '无') { ' ← 空白密码' } else { '' })
        $c = $(if ($warn) { 'Red' } else { 'DarkGray' })
        Write-Host ('    ' + $u.name.PadRight(20) + $(if ($u.enabled) { '启用' } else { '禁用' }).PadRight(6) + ' 密码' + $u.password + $warn) -ForegroundColor $c
    }
    Write-Host ('  管理员组 ' + $out.account.adminCount + ' 个成员：') -ForegroundColor $(if ($out.account.adminCount -gt 2) { 'Yellow' } else { 'Gray' })
    foreach ($a in @($out.account.administrators)) {
        Write-Host ('    ' + $a.name + '  (' + $a.source + ')') -ForegroundColor DarkGray
    }
}

if ($out.boot) {
    Write-Host ''
    Write-Host '【开机自启】' -ForegroundColor Yellow
    Write-Host ('  共 ' + $out.boot.total + ' 项')
    foreach ($b in $out.boot.items) {
        $cmd = [string]$b.cmd
        if ($cmd.Length -gt 70) { $cmd = $cmd.Substring(0, 70) + '…' }
        Write-Host ('    ' + $b.name.PadRight(24) + ' ' + $cmd) -ForegroundColor DarkGray
    }
}

if ($out.perm) {
    Write-Host ''
    Write-Host '【敏感目录权限】' -ForegroundColor Yellow
    foreach ($p in $out.perm.dirs) {
        if ($p.wideWrite -gt 0) {
            Write-Host ('    ⚠ ' + $p.path + '  ' + $p.who + ' 可写') -ForegroundColor Red
        } else {
            Write-Host ('    ✓ ' + $p.path) -ForegroundColor Green
        }
    }
}

if ($out.disk) {
    Write-Host ''
    Write-Host '【磁盘】' -ForegroundColor Yellow
    foreach ($d in $out.disk.drives) {
        $c = $(if ($d.usedPct -ge 90) { 'Red' } elseif ($d.usedPct -ge 80) { 'Yellow' } else { 'Gray' })
        Write-Host ('    ' + $d.drive + '  ' + $d.freeGB + ' / ' + $d.totalGB + ' GB 可用（已用 ' + $d.usedPct + '%）') -ForegroundColor $c
    }
}

Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  说明：这里只查本机状态，不扫描任何外部目标。' -ForegroundColor DarkGray
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''