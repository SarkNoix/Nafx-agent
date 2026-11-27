# ============================================================
#  定时 / 健康触发的自动化调度器
#
#  设计取舍（2026-11-25）：
#   · 只做「定时」和「健康」两种触发；文件变化误报太多，先不做
#   · 不新开常驻进程：watchdog.ps1 每 60 秒 tick 一次，面板也能手动点「跑一次」
#   · 任务一律走 mode=auto（无人值守，不许提问），优先级 8（低于手动任务）
#   · 有任务在跑就不插队，等下一轮 —— 8 GB 机器同时跑两个任务是自杀
#   · 面板活着 → 走 /api/run 排队；面板死了 → 直接拉 agent.ps1（否则"面板挂了"这条永远跑不起来）
#   · 每个 job 的最近结果从 history.jsonl 回收，不是自己瞎猜
#
#  用法：
#    powershell -File scripts\scheduler.ps1 -Once              # 跑一轮就退出（调试用）
#    powershell -File scripts\scheduler.ps1 -Loop -IntervalSec 60
#    powershell -File scripts\scheduler.ps1 -Once -Force -Only daily-disk-report
# ============================================================

param(
    [switch]$Once,
    [switch]$Loop,
    [int]$IntervalSec = 60,
    [switch]$Force,
    [string]$Only = ''
)

$script:NafxSchedRoot = Split-Path $PSScriptRoot -Parent
$script:NafxJobsFile  = Join-Path $script:NafxSchedRoot 'jobs.json'
$script:NafxJobsStateFile = Join-Path $script:NafxSchedRoot 'logs\jobs-state.json'
$script:NafxJobsLog    = Join-Path $script:NafxSchedRoot 'logs\jobs.log'
$script:NafxLogDir    = Join-Path $script:NafxSchedRoot 'logs'
$script:NafxPanelUrl  = 'http://127.0.0.1:8090'

$script:NafxUtf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-JsonLoose {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $t = (($t -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
        return ($t | ConvertFrom-Json)
    } catch { return $null }
}

function Write-JsonFile {
    param([string]$Path, $Obj)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 8), $script:NafxUtf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-JobLog {
    param([string]$Text)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
    try {
        if (-not (Test-Path $script:NafxLogDir)) { New-Item -ItemType Directory -Force -Path $script:NafxLogDir | Out-Null }
        Add-Content -LiteralPath $script:NafxJobsLog -Value $line -Encoding UTF8
    } catch { }
}

# ---------------- 读 jobs.json ----------------

function Get-Jobs {
    param([string]$Path = $script:NafxJobsFile)
    $doc = Read-JsonLoose $Path
    if (-not $doc -or -not $doc.jobs) { return @() }
    $out = @()
    foreach ($x in @($doc.jobs)) {
        if (-not $x -or -not $x.id) { continue }
        $prio = 8
        if ($x.PSObject.Properties.Name -contains 'priority' -and $x.priority) { $prio = [int]$x.priority }
        $fa = 1
        if ($x.PSObject.Properties.Name -contains 'failAfter' -and $x.failAfter) { $fa = [int]$x.failAfter }
        $cd = 60
        if ($x.PSObject.Properties.Name -contains 'cooldownMin' -and $x.cooldownMin) { $cd = [int]$x.cooldownMin }
        $bl = 3.0
        if ($x.PSObject.Properties.Name -contains 'below' -and $x.below) { $bl = [double]$x.below }
        $mode = 'auto'
        if ($x.PSObject.Properties.Name -contains 'mode' -and $x.mode) { $mode = [string]$x.mode }
        $out += [pscustomobject]@{
            id          = [string]$x.id
            name        = [string]$x.name
            enabled     = ($x.enabled -ne $false)
            when        = [string]$x.when
            task        = [string]$x.task
            mode        = $mode
            priority    = $prio
            readonly    = [bool]$x.readonly
            probe       = [string]$x.probe
            below       = $bl
            failAfter   = $fa
            cooldownMin = $cd
            note        = [string]$x.note
        }
    }
    return $out
}

function Get-JobById {
    param([string]$Id)
    foreach ($j in (Get-Jobs)) { if ($j.id -eq $Id) { return $j } }
    return $null
}

function Set-JobEnabled {
    param([string]$Id, [bool]$Enabled)
    $doc = Read-JsonLoose $script:NafxJobsFile
    if (-not $doc) { return $false }
    $hit = $false
    foreach ($x in @($doc.jobs)) {
        if ($x.id -eq $Id) { $x | Add-Member -NotePropertyName enabled -NotePropertyValue $Enabled -Force; $hit = $true }
    }
    if (-not $hit) { return $false }
    Write-JsonFile $script:NafxJobsFile $doc
    Write-JobLog ('手动' + $(if ($Enabled) { '启用' } else { '停用' }) + " $Id")
    return $true
}

# ---------------- 状态（每个 job 跑过什么） ----------------

function Get-JobState {
    $doc = Read-JsonLoose $script:NafxJobsStateFile
    $h = @{}
    if ($doc) {
        foreach ($p in $doc.PSObject.Properties) { $h[$p.Name] = $p.Value }
    }
    return $h
}

function New-JobState {
    [pscustomobject]@{
        lastRun       = ''
        lastStatus    = ''
        lastMsg       = ''
        lastElapsed   = 0
        runs          = 0
        fails         = 0
        failStreak    = 0
        lastProbeOk   = $null
        submittedTask = ''
        submittedAt   = ''
        updatedAt     = ''
    }
}

function Save-JobState {
    param($State)
    $obj = [ordered]@{}
    foreach ($k in $State.Keys) { $obj[$k] = $State[$k] }
    Write-JsonFile $script:NafxJobsStateFile $obj
}

function Get-StateNode {
    param($State, [string]$Id)
    if ($State.ContainsKey($Id) -and $State[$Id]) { return $State[$Id] }
    return (New-JobState)
}

# ---------------- 健康探针 ----------------

function Test-Probe {
    param([string]$Probe, [double]$Below = 3)
    switch ($Probe) {
        'panel' {
            # 端口没监听时，BeginConnect 在 Windows 上会一直等到超时才返回，
            # 每分钟白等 1.2 秒。降到 300ms：真的在启动的服务 300ms 内就能握手，
            # 断了就是断了，不用陪它耗时间。
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $t = $c.BeginConnect('127.0.0.1', 8090, $null, $null)
                $ok = $t.AsyncWaitHandle.WaitOne(300)
                if ($ok -and $c.Connected) { $c.Close(); return [pscustomobject]@{ ok = $true; value = '8090 在监听' } }
                $c.Close()
            } catch { }
            return [pscustomobject]@{ ok = $false; value = '8090 不通' }
        }
        'model' {
            try {
                $cfg = Read-JsonLoose (Join-Path $script:NafxSchedRoot 'config.json')
                $host_ = '127.0.0.1'; $port = 8080
                if ($cfg -and $cfg.host) { $host_ = [string]$cfg.host }
                if ($cfg -and $cfg.port) { $port = [int]$cfg.port }
                $r = Invoke-WebRequest -Uri ('http://' + $host_ + ':' + $port + '/health') -UseBasicParsing -TimeoutSec 3
                if ($r.StatusCode -eq 200) { return [pscustomobject]@{ ok = $true; value = '模型 /health 返回 200' } }
                return [pscustomobject]@{ ok = $false; value = ('模型 /health ' + $r.StatusCode) }
            } catch {
                return [pscustomobject]@{ ok = $false; value = ('模型不通：' + $_.Exception.Message) }
            }
        }
        'disk' {
            try {
                # 原先是 Get-PSDrive —— 会顺带把 PowerShell 的 FileSystem 提供程序整个加载一遍，
                # 实测 498ms，只为了读一个可用空间数字。DriveInfo 是纯 .NET，1ms 级。
                $drive = [IO.Path]::GetPathRoot($script:NafxSchedRoot)
                $di = New-Object System.IO.DriveInfo $drive
                $freeGB = [math]::Round($di.AvailableFreeSpace / 1GB, 1)
                $ok = ($freeGB -ge $Below)
                return [pscustomobject]@{ ok = $ok; value = ($drive.TrimEnd('\') + ' 可用 ' + $freeGB + ' GB（阈值 ' + $Below + ' GB）') }
            } catch {
                return [pscustomobject]@{ ok = $false; value = ('磁盘读不到：' + $_.Exception.Message) }
            }
        }
        default {
            return [pscustomobject]@{ ok = $true; value = '未知探针，跳过' }
        }
    }
}

# ---------------- 忙不忙 ----------------

function Test-AgentBusy {
    $sf = Join-Path $script:NafxSchedRoot 'agent\state.json'
    if (Test-Path -LiteralPath $sf) {
        $s = Read-JsonLoose $sf
        if ($s) {
            $ph = [string]$s.phase
            if ($ph -like '正在*' -or $ph -like '第 *') { return $true }
            $st = [string]$s.status
            if ($st -eq 'running' -or $st -eq 'queued' -or $st -eq 'busy' -or $st -eq 'waiting') { return $true }
        }
    }
    return $false
}

# ---------------- 把任务丢给谁 ----------------

function Get-JobTaskText {
    param($Job)
    # 曾经在这里自动加「只读，不许改文件」前缀，实测把 4B 带跑偏：
    # "2 加 2 等于几" 加了前缀后会去 find_files 找 *.zip（跑了 7 步）。
    # 现在 readonly 只作为面板上的标记，真正的只读约束写在任务文字里。
    return [string]$Job.task
}

function Submit-NafxTask {
    param([string]$Task, [string]$Mode = 'auto', [int]$Priority = 8, [switch]$Readonly, [string]$JobId = 'job')

    # 不自动加前缀：4B 会被长前缀带偏（见 Get-JobTaskText 里的实测记录）

    # ① 面板活着：进队列，和手动任务共用同一个 worker，不并发
    try {
        $body = @{ task = $Task; mode = $Mode; priority = $Priority } | ConvertTo-Json -Compress
        # 必须显式发 UTF-8 字节：PowerShell 5.1 传字符串时会按本地代码页编码，
        # 中文任务到面板就变成一串 "?"（实测踩过）。
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $r = Invoke-RestMethod -Uri ($script:NafxPanelUrl + '/api/run') -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
        if ($r -and $r.ok) {
            return [pscustomobject]@{ ok = $true; via = 'panel'; id = [string]$r.id; task = $Task; msg = ('已进队列（' + $r.id + '）') }
        }
    } catch { }

    # ② 面板死了：直接拉起 agent.ps1（否则"面板挂了"这类 job 永远跑不了）
    $agent = Join-Path $script:NafxSchedRoot 'agent\agent.ps1'
    if (-not (Test-Path -LiteralPath $agent)) {
        return [pscustomobject]@{ ok = $false; via = 'none'; id = ''; task = $Task; msg = '找不到 agent.ps1' }
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    if (-not (Test-Path $script:NafxLogDir)) { New-Item -ItemType Directory -Force -Path $script:NafxLogDir | Out-Null }
    $outLog = Join-Path $script:NafxLogDir ('jobs_' + $JobId + '_' + $stamp + '.log')
    $errLog = Join-Path $script:NafxLogDir ('jobs_' + $JobId + '_' + $stamp + '.err.log')
    try {
        # 任务里有空格和中文，必须自己加引号：Start-Process 只是把数组拼成命令行，
        # 不引起来的话 "看一下 C 盘" 会被拆成多个参数（实测报过类型转换错）。
        $qTask = '"' + ($Task -replace '"', '\"') + '"'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $agent, '-Task', $qTask, '-MaxSteps', '35', '-Mode', $Mode
        ) -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        return [pscustomobject]@{ ok = $true; via = 'direct'; id = ''; task = $Task; msg = ('面板不在，直接跑（日志 ' + (Split-Path -Leaf $outLog) + '）') }
    } catch {
        return [pscustomobject]@{ ok = $false; via = 'none'; id = ''; task = $Task; msg = ('直接跑失败：' + $_.Exception.Message) }
    }
}

# ---------------- 时间判定 ----------------

function Test-JobDue {
    param($Job, $Node, [datetime]$Now = (Get-Date))
    if (-not $Job.enabled) { return $false }
    $w = $Job.when.Trim().ToLower()
    $lastRun = $null
    if ($Node.lastRun) {
        try { $lastRun = [datetime]::Parse([string]$Node.lastRun) } catch { }
    }

    if ($w -match '^daily\s+(\d{1,2}):(\d{2})$') {
        $h = [int]$matches[1]; $m = [int]$matches[2]
        if ($h -gt 23 -or $m -gt 59) { return $false }
        $todayAt = $Now.Date.AddHours($h).AddMinutes($m)
        if ($Now -lt $todayAt) { return $false }
        if (-not $lastRun) { return $true }
        return ($lastRun -lt $todayAt)
    }

    if ($w -match '^every\s+(\d+)\s*(m|h|min|hour)$') {
        $n = [int]$matches[1]; $unit = $matches[2]
        $spanMin = if ($unit -eq 'h' -or $unit -eq 'hour') { $n * 60 } else { $n }
        if ($spanMin -lt 5) { return $false }
        if (-not $lastRun) { return $true }
        return (((($Now - $lastRun).TotalMinutes)) -ge $spanMin)
    }

    return $false
}

# ---------------- 从 history 回收真实结果 ----------------

function Read-TextShared {
    # 读正在被追加的文件（history.jsonl / 日志）必须用 FileShare.ReadWrite，
    # 否则 Get-Content 会等写句柄释放 —— 面板是单线程的，一卡就是全部 API 一起卡死（实测踩过）。
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            return $sr.ReadToEnd()
        } finally { $sr.Dispose() }
    } catch { return $null }
}

function Update-JobResults {
    param($State)
    $hf = Join-Path $script:NafxSchedRoot 'agent\logs\history.jsonl'
    if (-not (Test-Path -LiteralPath $hf)) { return }
    $text = Read-TextShared $hf
    if (-not $text) { return }
    $lines = @(($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 40)
    foreach ($k in @($State.Keys)) {
        $node = $State[$k]
        if (-not $node.submittedTask) { continue }
        if ($node.lastStatus -notin @('queued', 'direct')) { continue }
        # 45 分钟还没在 history 里出现 = 那次运行被中断了（面板被杀/机器重启）。
        # 不这么判的话，面板会永远显示「已排队」。
        $stale = $false
        if ($node.submittedAt) {
            try { $stale = (((Get-Date) - [datetime]::Parse([string]$node.submittedAt)).TotalMinutes -ge 45) } catch { }
        }
        foreach ($ln in $lines) {
            if (-not $ln) { continue }
            try { $rec = $ln | ConvertFrom-Json } catch { continue }
            if (-not $rec -or [string]$rec.task -ne [string]$node.submittedTask) { continue }
            $node.lastStatus = [string]$rec.status
            $node.lastElapsed = [int]$rec.elapsed
            $msg = ''
            if ($rec.PSObject.Properties.Name -contains 'summary' -and $rec.summary) { $msg = [string]$rec.summary }
            elseif ($rec.PSObject.Properties.Name -contains 'answer' -and $rec.answer) { $msg = [string]$rec.answer }
            if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) + '…' }
            $node.lastMsg = $msg
            if ($node.lastStatus -eq 'failed') { $node.fails = [int]$node.fails + 1 }
            $State[$k] = $node
            Write-JobLog ("$k 结果回收：" + $node.lastStatus + ' ' + $node.lastElapsed + ' 秒')
            break
        }
        if ($node.lastStatus -in @('queued', 'direct') -and $stale) {
            $node.lastStatus = 'lost'
            $node.lastMsg = '没找到结果记录（那次运行被中断了）'
            $State[$k] = $node
            Write-JobLog ("$k 结果丢失：提交后 45 分钟没等到结果")
        }
    }
}

# ---------------- 面板用的快照 / 手动记账 ----------------

function Register-JobResult {
    param([string]$Id, $Result, [switch]$Manual)
    $state = Get-JobState
    $node = Get-StateNode $state $Id
    $node.lastRun = (Get-Date).ToString('o')
    $node.lastStatus = if ($Result.via -eq 'panel') { 'queued' } elseif ($Result.ok) { 'direct' } else { 'failed' }
    $node.lastMsg = [string]$Result.msg
    $node.submittedTask = [string]$Result.task
    $node.submittedAt = (Get-Date).ToString('o')
    $node.updatedAt = (Get-Date).ToString('o')
    if ($Result.ok) { $node.runs = [int]$node.runs + 1 } else { $node.fails = [int]$node.fails + 1 }
    $state[$Id] = $node
    Save-JobState $state
}

function Get-JobsSnapshot {
    $state = Get-JobState
    # 只在内存里回收结果，不落盘：GET 会被面板频繁调用，
    # 两边同时写 jobs-state.json 会互相抢文件；落盘留给 tick。
    try { Update-JobResults $state } catch { }
    $out = @()
    foreach ($j in (Get-Jobs)) {
        $n = Get-StateNode $state $j.id
        $out += [pscustomobject]@{
            id          = $j.id
            name        = $j.name
            enabled     = $j.enabled
            when        = $j.when
            probe       = $j.probe
            below       = $j.below
            task        = $j.task
            note        = $j.note
            readonly    = $j.readonly
            mode        = $j.mode
            priority    = $j.priority
            lastRun     = $n.lastRun
            lastStatus  = $n.lastStatus
            lastMsg     = $n.lastMsg
            lastElapsed = $n.lastElapsed
            runs        = $n.runs
            fails       = $n.fails
            failStreak  = $n.failStreak
            lastProbeOk = $n.lastProbeOk
        }
    }
    return $out
}

function Get-JobsLogTail {
    param([int]$N = 15)
    if (-not (Test-Path -LiteralPath $script:NafxJobsLog)) { return @() }
    $text = Read-TextShared $script:NafxJobsLog
    if (-not $text) { return @() }
    return @(($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last $N)
}

# ---------------- 一轮 tick ----------------

function Invoke-SchedulerTick {
    param([switch]$Force, [string]$Only = '')

    $state = Get-JobState
    Update-JobResults $state

    foreach ($job in (Get-Jobs)) {
        if ($Only -and $job.id -ne $Only) { continue }
        if (-not $job.enabled -and -not $Force) { continue }

        $node = Get-StateNode $state $job.id
        $w = $job.when.Trim().ToLower()

        # ---- 健康触发 ----
        if ($w -eq 'health') {
            $probe = Test-Probe -Probe $job.probe -Below $job.below
            $node.lastProbeOk = [bool]$probe.ok
            if ($probe.ok) {
                if ([int]$node.failStreak -gt 0) { Write-JobLog ("$($job.id) 探针恢复：" + $probe.value) }
                $node.failStreak = 0
                $state[$job.id] = $node
                continue
            }
            $node.failStreak = [int]$node.failStreak + 1
            Write-JobLog ("$($job.id) 探针失败第 " + $node.failStreak + ' 次：' + $probe.value)
            $cool = $true
            if ($node.lastRun) {
                try {
                    $lr = [datetime]::Parse([string]$node.lastRun)
                    $cool = (((Get-Date) - $lr).TotalMinutes -ge $job.cooldownMin)
                } catch { }
            }
            if ($node.failStreak -lt $job.failAfter) { $state[$job.id] = $node; continue }
            if (-not $cool) {
                Write-JobLog ("$($job.id) 冷却期内（" + $job.cooldownMin + ' 分钟），先不跑')
                $state[$job.id] = $node
                continue
            }
            if (Test-AgentBusy) {
                Write-JobLog ("$($job.id) 有任务在跑，下一轮再试")
                $state[$job.id] = $node
                continue
            }
            $r = Submit-NafxTask -Task $job.task -Mode $job.mode -Priority $job.priority -Readonly:$job.readonly -JobId $job.id
            Write-JobLog ('触发 ' + $job.id + '（' + $probe.value + '）：' + $r.msg)
            $node.lastRun = (Get-Date).ToString('o')
            $node.lastStatus = if ($r.via -eq 'panel') { 'queued' } else { 'direct' }
            $node.lastMsg = $r.msg
            $node.submittedTask = $r.task
            $node.submittedAt = (Get-Date).ToString('o')
            if ($r.ok) { $node.runs = [int]$node.runs + 1 } else { $node.fails = [int]$node.fails + 1; $node.lastStatus = 'failed' }
            $node.updatedAt = (Get-Date).ToString('o')
            $state[$job.id] = $node
            continue
        }

        # ---- 定时 ----
        if (-not (Test-JobDue -Job $job -Node $node)) { continue }
        if (Test-AgentBusy) {
            Write-JobLog ("$($job.id) 到点了，但有任务在跑，下一轮再试")
            continue
        }
        $r = Submit-NafxTask -Task $job.task -Mode $job.mode -Priority $job.priority -Readonly:$job.readonly -JobId $job.id
        Write-JobLog ('到点执行 ' + $job.id + '：' + $r.msg)
        $node.lastRun = (Get-Date).ToString('o')
        $node.lastStatus = if ($r.via -eq 'panel') { 'queued' } elseif ($r.ok) { 'direct' } else { 'failed' }
        $node.lastMsg = $r.msg
        $node.submittedTask = $r.task
        $node.submittedAt = (Get-Date).ToString('o')
        if ($r.ok) { $node.runs = [int]$node.runs + 1 } else { $node.fails = [int]$node.fails + 1 }
        $node.updatedAt = (Get-Date).ToString('o')
        $state[$job.id] = $node
    }

    Save-JobState $state
    return $state
}

# ---------------- 独立运行入口（dot-source 时不跑） ----------------
$invokedDirectly = ($MyInvocation.InvocationName -ne '.')

if ($invokedDirectly -and ($Once -or $Loop)) {
    Write-JobLog ('调度器启动 tick=' + $IntervalSec + 's' + $(if ($Force) { ' force' } else { '' }))
    if ($Once) {
        Invoke-SchedulerTick -Force:$Force -Only $Only | Out-Null
        Write-JobLog '一轮结束'
    } else {
        while ($true) {
            try { Invoke-SchedulerTick | Out-Null } catch { Write-JobLog ('tick 出错：' + $_.Exception.Message) }
            Start-Sleep -Seconds $IntervalSec
        }
    }
}
