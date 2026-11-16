# ============================================================
#  Nafx 控制面板 + 任务调度
#  设计要点：
#   1. 单线程。用 HttpListener 的异步等待，每秒空转一次做调度，
#      不用后台线程 / Start-Job / PowerShell.Create() —— 那些在
#      PS 5.1 里不稳定，一崩整个面板就退出。
#   2. 多路并行：按 config.parallel 同时起多个 agent 进程，
#      每个写自己的 state_<n>.json，模型那边有对应数量的槽位。
#   3. 队列持久化在 agent/queue.json，重启面板不丢任务。
# ============================================================

param([int]$Port = 0, [string]$ConfigFile = 'config.json')

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath   = $ConfigFile
if (-not [IO.Path]::IsPathRooted($CfgPath)) { $CfgPath = Join-Path $Root $CfgPath }
# 传给子进程（agent.ps1 靠这个知道用哪套配置）
$env:NAFX_CONFIG = $CfgPath
$Cfg       = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Port -le 0) { $Port = [int]$Cfg.monitorPort }

$StateFile = Join-Path $Root 'agent\state.json'
$HtmlPath  = Join-Path $Root 'agent\dashboard.html'
$AgentPath = Join-Path $Root 'agent\agent.ps1'
$QueueFile = Join-Path $Root 'agent\queue.json'
$HistFile  = Join-Path $Root 'agent\logs\history.jsonl'
$CtxFile   = Join-Path $Root 'agent\logs\task-context.jsonl'
$UiLogDir  = Join-Path $Root 'agent\logs'

$WorkerCount = [int]$Cfg.parallel
if ($WorkerCount -lt 1) { $WorkerCount = 1 }
if ($WorkerCount -gt 4) { $WorkerCount = 4 }

if (-not (Test-Path $HtmlPath)) { Write-Host "找不到面板页面：$HtmlPath" -ForegroundColor Red; exit 1 }

# ---------------- 小工具 ----------------

function J([string]$s) {
    if ($null -eq $s) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"'); continue }
            '\'  { [void]$sb.Append('\\'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-HtmlBytes {
    try { return ,([IO.File]::ReadAllBytes($HtmlPath)) } catch { return ,([byte[]]@()) }
}

function Send-Bytes {
    param($Response, [byte[]]$Bytes, [string]$ContentType = 'application/json; charset=utf-8', [int]$Code = 200)
    try {
        $Response.StatusCode = $Code
        $Response.ContentType = $ContentType
        $Response.Headers.Add('Cache-Control', 'no-store')
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } catch { }
    try { $Response.OutputStream.Close() } catch { }
}

function Send-Text {
    param($Response, [string]$Text, [int]$Code = 200)
    Send-Bytes -Response $Response -Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) -Code $Code
}

function Read-Body {
    param($Request)
    try {
        $reader = New-Object System.IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close()
        return $text
    } catch { return '' }
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

# ---------------- 队列 ----------------

function Get-Queue {
    $res = New-Object System.Collections.ArrayList
    if (-not (Test-Path $QueueFile)) { return ,$res }
    try {
        $raw = Get-Content $QueueFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return ,$res }
        foreach ($x in ($raw | ConvertFrom-Json)) {
            if ($null -eq $x) { continue }
            if ($x.PSObject.Properties.Name -contains 'value') { continue }
            if (-not ($x.PSObject.Properties.Name -contains 'id')) { continue }
            [void]$res.Add($x)
        }
    } catch { }
    return ,$res
}

function Save-Queue {
    param($Items)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    $first = $true
    foreach ($it in $Items) {
        if ($null -eq $it) { continue }
        if (-not ($it.PSObject.Properties.Name -contains 'id')) { continue }
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        $o = [ordered]@{
            id = [string]$it.id; task = [string]$it.task; status = [string]$it.status
            priority = [int]$it.priority; addedAt = [string]$it.addedAt
            startedAt = [string]$it.startedAt; doneAt = [string]$it.doneAt
            result = [string]$it.result; slot = [string]$it.slot
        }
        [void]$sb.Append(($o | ConvertTo-Json -Compress))
    }
    [void]$sb.Append(']')
    [IO.File]::WriteAllText($QueueFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}

function Add-QueueItem {
    param([string]$TaskText, [int]$Priority = 5)
    $items = Get-Queue
    $item = [pscustomobject]@{
        id        = 'q' + (Get-Date -Format 'HHmmss') + [Guid]::NewGuid().ToString('N').Substring(0,4)
        task      = $TaskText
        status    = 'pending'
        priority  = $Priority
        addedAt   = (Get-Date -Format 'MM-dd HH:mm:ss')
        startedAt = ''
        doneAt    = ''
        result    = ''
        slot      = ''
    }
    [void]$items.Add($item)
    Save-Queue $items
    return $item
}

function Set-QueueStatus {
    param([string]$Id, [string]$Status, [string]$Result = '', [string]$Slot = '')
    $items = Get-Queue
    foreach ($it in $items) {
        if ($it.id -eq $Id) {
            $it.status = $Status
            if ($Status -eq 'running') { $it.startedAt = (Get-Date -Format 'MM-dd HH:mm:ss'); if ($Slot) { $it.slot = $Slot } }
            if ($Status -in @('done','failed','cancelled')) { $it.doneAt = (Get-Date -Format 'MM-dd HH:mm:ss') }
            if ($Result) { $it.result = $Result }
            break
        }
    }
    Save-Queue $items
}

function Get-SlotStateFile([int]$slot) {
    if ($slot -eq 1) { return $StateFile }
    return (Join-Path $Root ("agent\state_$slot.json"))
}

# ---------------- 调度 ----------------
# 运行中的 worker：key = slot 号，value = Process 对象
$Workers = @{}

function Invoke-Dispatch {
    # 1) 回收已经退出的 worker
    foreach ($slot in @($Workers.Keys)) {
        $proc = $Workers[$slot]
        $exited = $false
        try { $exited = $proc.HasExited } catch { $exited = $true }
        if ($exited) {
            $slotState = Get-SlotStateFile $slot
            $ans = ''
            $st = Read-JsonFile $slotState
            if ($st) { $ans = [string]$st.answer }

            $items = Get-Queue
            foreach ($it in $items) {
                if ($it.status -eq 'running' -and [string]$it.slot -eq [string]$slot) {
                    $finalStatus = 'done'
                    if ($st -and [string]$st.status -in @('failed','error','maxsteps','timeout')) { $finalStatus = 'failed' }
                    $it.status = $finalStatus
                    $it.doneAt = (Get-Date -Format 'MM-dd HH:mm:ss')
                    $it.result = $ans
                }
            }
            Save-Queue $items
            $Workers.Remove($slot)

            # 这个槽位收工，顺手把它的 state 标成结束，别让面板一直显示 running
            if ($st -and [string]$st.status -eq 'running') {
                $st.status = 'done'
                $st | ConvertTo-Json -Depth 8 | Set-Content $slotState -Encoding UTF8
            }
        }
    }

    # 2) 有空位就补
    $free = $WorkerCount - $Workers.Count
    if ($free -le 0) { return }

    for ($slot = 1; $slot -le $WorkerCount; $slot++) {
        if ($Workers.ContainsKey($slot)) { continue }
        if ($free -le 0) { break }

        $items = Get-Queue
        $next = $null
        foreach ($it in ($items | Sort-Object priority, addedAt)) {
            if ($it.status -eq 'pending') { $next = $it; break }
        }
        if (-not $next) { break }

        Set-QueueStatus -Id $next.id -Status 'running' -Slot $slot

        $slotState = Get-SlotStateFile $slot
        $ph = '{"status":"running","task":' + (J $next.task) + ',"steps":[],"step":1,"maxSteps":' + $Cfg.maxSteps +
              ',"elapsed":0,"phase":"第' + $slot + '路 准备","model":' + (J $Cfg.modelLabel) +
              ',"workspace":' + (J $Cfg.workspace) + ',"answer":"","logFile":"","slot":' + $slot + '}'
        [IO.File]::WriteAllText($slotState, $ph, (New-Object Text.UTF8Encoding($false)))
        # 第 1 路的也同步到主 state，兼容老逻辑
        if ($slot -eq 1) { [IO.File]::WriteAllText($StateFile, $ph, (New-Object Text.UTF8Encoding($false))) }

        $uiLog = Join-Path $UiLogDir ("ui_run_$slot.txt")
        $env:NAFX_TASK  = $next.task
        $env:NAFX_STATE = $slotState
        try {
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AgentPath, '-MaxSteps', "$($Cfg.maxSteps)" `
                -RedirectStandardOutput $uiLog -WindowStyle Hidden -PassThru
            $Workers[$slot] = $proc
            Write-Host ("  [第{0}路] {1}" -f $slot, $next.task) -ForegroundColor Green
        } catch {
            Write-Host ("  [第{0}路] 启动失败：{1}" -f $slot, $_.Exception.Message) -ForegroundColor Red
            Set-QueueStatus -Id $next.id -Status 'failed' -Result '进程启动失败'
        }
        $free--
    }
}

# ---------------- 汇总状态 ----------------
# 把多路 state 合并成一个给面板看
function Get-MergedState {
    $list = @()
    for ($slot = 1; $slot -le $WorkerCount; $slot++) {
        $sf = Get-SlotStateFile $slot
        $st = Read-JsonFile $sf
        if ($st) { $list += $st }
    }
    if ($list.Count -eq 0) {
        return [pscustomobject]@{
            status = 'idle'; task = ''; steps = @(); step = 0
            maxSteps = [int]$Cfg.maxSteps; elapsed = 0; model = [string]$Cfg.modelLabel
            workspace = [string]$Cfg.workspace; answer = ''; plan = ''; summary = ''
            logFile = ''; workers = @()
        }
    }

    # 挑一个"最活跃"的当主状态：running 优先，其次按 step 倒序
    $main = $null
    foreach ($s in $list) { if ([string]$s.status -eq 'running') { $main = $s; break } }
    if (-not $main) { $main = $list[0] }

    # state.json 说 running，但 agent 进程已经没了——系统重启、Ctrl+C、被 taskkill。
    # 这时候还照 state 显示「思考中」，用户看到的就是一个永远不动的死面板。
    #
    # 但这个判断必须很保守，误报比不报更难受：
    #   ① Get-CimInstance 偶尔查不全（进程刚起来、命令行还没就绪），
    #      直接判"没了"会让正在跑的任务显示成"已中断"。
    #   ② 原来只匹配 '-File\s+.*agent\.ps1'，路径带引号/空格就匹配不上。
    #   ③ 用 state.json 的修改时间做第二重证据：agent 每步都会 Write-State，
    #      只要最近改过，就说明它还活着。
    # 只有「找不到进程」且「state.json 已经 25 秒没更新」才判中断。
    if ([string]$main.status -eq 'running') {
        $hasAgent = $false
        try {
            foreach ($ap in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
                $acl = [string]$ap.CommandLine
                # 宽松匹配：只要命令行里出现 agent.ps1 就算，不再依赖 -File 的写法
                if ($acl -match 'agent\.ps1') { $hasAgent = $true; break }
            }
        } catch {
            $hasAgent = $true   # 查询本身失败就当作在跑
        }

        # 第二重证据：state 文件最近还在被写吗
        $staleSec = 9999
        try {
            $sf0 = Get-SlotStateFile ([int]$main.slot)
            if (Test-Path $sf0) {
                $staleSec = ((Get-Date) - (Get-Item $sf0).LastWriteTime).TotalSeconds
            }
        } catch { }

        if (-not $hasAgent -and $staleSec -gt 25) {
            $main.status = 'interrupted'
            $main.phase = '上次运行被中断（进程已退出），结果可能不完整'
        }
    }

    $summary = @()
    foreach ($s in $list) {
        $summary += [pscustomobject]@{
            slot    = [int]$s.slot
            status  = [string]$s.status
            task    = [string]$s.task
            step    = [int]$s.step
            elapsed = [double]$s.elapsed
        }
    }

    return [pscustomobject]@{
        status    = [string]$main.status
        task      = [string]$main.task
        steps     = @($main.steps)
        step      = [int]$main.step
        maxSteps  = [int]$main.maxSteps
        elapsed   = [double]$main.elapsed
        model     = [string]$Cfg.modelLabel
        workspace = [string]$Cfg.workspace
        answer    = [string]$main.answer
        plan      = [string]$main.plan
        summary   = [string]$main.summary
        logFile   = [string]$main.logFile
        slot      = [int]$main.slot
        intent    = [string]$main.intent
        flow      = [string]$main.flow
        flowName  = [string]$main.flowName
        # 这两个是 agent 算好的"实际发出去的"工具规模，面板用它算剩余上下文
        toolTokens = [int]$main.toolTokens
        flowTools  = [int]$main.flowTools
        phase     = [string]$main.phase
        workers   = $summary
    }
}

# ---------------- 上下文 ----------------
# 系统上下文：模型信息 + 提示词规模 + 工具数量 + 参数
function Get-SystemContext {
    $promptPath = Join-Path $Root 'agent\prompt.md'
    $toolsPath  = Join-Path $Root 'agent\tools-schema.json'
    $promptLen = 0; $toolCount = 0; $toolLen = 0
    try { if (Test-Path $promptPath) { $promptLen = (Get-Item $promptPath).Length } } catch { }
    try {
        if (Test-Path $toolsPath) {
            $toolLen = (Get-Item $toolsPath).Length
            $tj = Get-Content $toolsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $toolCount = @($tj).Count
        }
    } catch { }

    $slots = 0
    try { $slots = @((Invoke-WebRequest 'http://127.0.0.1:8080/slots' -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json).Count } catch { }

    return [pscustomobject]@{
        model       = [string]$Cfg.modelLabel
        modelId     = [string]$Cfg.model
        context     = [int]$Cfg.context
        contextPerSlot = [int][Math]::Floor([int]$Cfg.context / $WorkerCount)
        parallel    = $WorkerCount
        slotsReady  = $slots
        maxTokens   = [int]$Cfg.maxTokens
        maxSteps    = [int]$Cfg.maxSteps
        temperature = [double]$Cfg.temperature
        workspace   = [string]$Cfg.workspace
        allowAnyPath = [bool]$Cfg.allowAnyPath
        promptBytes = $promptLen
        promptTokens = [int][Math]::Round($promptLen / 2.5)
        toolCount   = $toolCount
        toolTokens   = [int][Math]::Round($toolLen / 3.5)
        running     = $Workers.Count
        isAdmin     = $script:IsAdminNow
    }
}

# ---------------- 启动 ----------------

# 当前是不是管理员权限（面板启动时决定，agent 继承）
$script:IsAdminNow = $false
try {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($wi)
    $script:IsAdminNow = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }


$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://$($Cfg.host):$Port/")
try { $listener.Start() }
catch {
    Write-Host "面板端口 $Port 被占用（可能已经开了一个），本次不重复启动。" -ForegroundColor Yellow
    exit 0
}
Write-Host "Nafx 面板：http://$($Cfg.host):$Port/  并行 $WorkerCount 路" -ForegroundColor Cyan
try { [IO.File]::WriteAllText((Join-Path $Root 'agent\panel.pid'), "$PID", (New-Object Text.UTF8Encoding($false))) } catch { }

# 启动时清理上次残留的 agent 进程
# 面板重启会丢掉 $Workers 记录，那些进程就成了"没人管的孤儿"，会一直占模型槽位
try {
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match 'agent\.ps1' })
    foreach ($o in $orphans) {
        try { & cmd /c "taskkill /F /PID $($o.ProcessId)" 2>&1 | Out-Null } catch { }
    }
    if ($orphans.Count -gt 0) { Write-Host ("  清理残留 agent 进程 " + $orphans.Count + " 个") -ForegroundColor DarkGray }
} catch { }

# 启动时把上次中断的任务标成失败
$stale = Get-Queue
$changed = $false
foreach ($it in $stale) {
    if ($it.status -eq 'running') { $it.status = 'failed'; $it.doneAt = (Get-Date -Format 'MM-dd HH:mm:ss'); $it.result = '面板重启，任务中断'; $changed = $true }
}
if ($changed) { Save-Queue $stale }

$async = $listener.BeginGetContext($null, $null)

while ($listener.IsListening) {
    try {
        # 每秒空转一次：有请求就处理，没请求就调度
        if ($async.AsyncWaitHandle.WaitOne(1000)) {
            $ctx = $listener.EndGetContext($async)
            $async = $listener.BeginGetContext($null, $null)

            $path = $ctx.Request.Url.AbsolutePath
            $resp = $ctx.Response
            $method = $ctx.Request.HttpMethod

            switch ($path) {

                '/' {
                    Send-Bytes -Response $resp -Bytes (Get-HtmlBytes) -ContentType 'text/html; charset=utf-8'
                }

                '/editor' {
                    # mod 编辑器。面板本身就在跑，复用它省一个进程——
                    # 8 GB 内存下再起一个 PowerShell 经常申请不到内存（实测 8070 起不来）。
                    # 这里直接吐 mod-editor.html，它要的 /api/config /tools /mods 面板都有。
                    $edPath = Join-Path $Root 'mod-editor.html'
                    if (Test-Path $edPath) {
                        Send-Bytes -Response $resp -Bytes ([IO.File]::ReadAllBytes($edPath)) -ContentType 'text/html; charset=utf-8'
                    } else {
                        Send-Text -Response $resp -Text '{"ok":false,"msg":"找不到 mod-editor.html"}'
                    }
                }

                '/api/state' {
                    $merged = Get-MergedState
                    Send-Text -Response $resp -Text ($merged | ConvertTo-Json -Depth 10 -Compress)
                }

                '/api/system' {
                    Send-Text -Response $resp -Text ((Get-SystemContext) | ConvertTo-Json -Depth 5 -Compress)
                }

                '/api/queue' {
                    $all = Get-Queue
                    $pend = New-Object System.Collections.ArrayList
                    $run  = New-Object System.Collections.ArrayList
                    $done = New-Object System.Collections.ArrayList
                    foreach ($it in $all) {
                        switch ([string]$it.status) {
                            'pending' { [void]$pend.Add($it) }
                            'running' { [void]$run.Add($it) }
                            default   { [void]$done.Add($it) }
                        }
                    }
                    # 已完成的只留最近 20 条
                    $doneArr = @($done)
                    if ($doneArr.Count -gt 20) { $doneArr = $doneArr[($doneArr.Count-20)..($doneArr.Count-1)] }

                    $json = '{"pending":' + (ConvertTo-Json -InputObject $pend.ToArray() -Depth 5 -Compress) +
                            ',"running":' + (ConvertTo-Json -InputObject $run.ToArray() -Depth 5 -Compress) +
                            ',"finished":' + (ConvertTo-Json -InputObject $doneArr -Depth 5 -Compress) + '}'
                    foreach ($k in @('"pending":null','"running":null','"finished":null')) {
                        $json = $json.Replace($k, $k.Replace('null','[]'))
                    }
                    Send-Text -Response $resp -Text $json
                }

                '/api/run' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false,"msg":"只接受 POST"}' -Code 405; break }
                    $task = ''; $prio = 5
                    try {
                        $b = Read-Body $ctx.Request | ConvertFrom-Json
                        $task = ([string]$b.task).Trim()
                        if ($b.PSObject.Properties.Name -contains 'priority') { $prio = [int]$b.priority }
                    } catch { }
                    if ([string]::IsNullOrWhiteSpace($task)) { Send-Text -Response $resp -Text '{"ok":false,"msg":"任务不能为空"}' -Code 400; break }
                    $item = Add-QueueItem -TaskText $task -Priority $prio
                    $q = Get-Queue
                    $pend = 0; $run = 0
                    foreach ($it in $q) { if ($it.status -eq 'pending') { $pend++ }; if ($it.status -eq 'running') { $run++ } }
                    Send-Text -Response $resp -Text ('{"ok":true,"id":' + (J $item.id) + ',"pending":' + $pend + ',"running":' + $run + '}')
                }

                '/api/answer' {
                    # 面板把用户对 say 问题的回答写进来，agent 那边在轮询这个文件
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    try {
                        $b = Read-Body $ctx.Request | ConvertFrom-Json
                    } catch { Send-Text -Response $resp -Text '{"ok":false,"msg":"请求格式不对"}' -Code 400; break }

                    $qid = [string]$b.id
                    $ans = [string]$b.answer
                    if ([string]::IsNullOrWhiteSpace($ans)) {
                        Send-Text -Response $resp -Text '{"ok":false,"msg":"回答不能为空"}' -Code 400
                        break
                    }

                    # 没有 id 也行，agent 只比对有 id 时是否匹配
                    $payload = [ordered]@{
                        id   = $qid
                        answer = $ans
                        ts   = (Get-Date -Format 'HH:mm:ss')
                    }
                    $ansPath = Join-Path $Root 'agent\answer.json'
                    try {
                        [IO.File]::WriteAllText($ansPath, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
                        Send-Text -Response $resp -Text '{"ok":true}'
                    } catch {
                        Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J $_.Exception.Message) + '}') -Code 500
                    }
                }

                '/api/ask' {
                    # 面板读当前有没有在等回答。
                    # 必须检查 deadline：ask.json 没人删的话，前端会永远显示
                    # 「等你回答」那个框，用户就以为界面卡死了。
                    $askPath = Join-Path $Root 'agent\ask.json'
                    if (Test-Path $askPath) {
                        try {
                            $raw = [IO.File]::ReadAllText($askPath, [Text.Encoding]::UTF8)
                            $aj = $raw | ConvertFrom-Json
                            $expired = $false
                            if ($aj.deadline) {
                                try {
                                    $dl = [datetime]::ParseExact([string]$aj.deadline, 'HH:mm:ss', $null)
                                    if ($dl -lt (Get-Date).Date) { $dl = $dl.AddDays(1) }
                                    if ((Get-Date) -gt $dl) { $expired = $true }
                                } catch { }
                            }
                            if (-not $expired) {
                                $age = ((Get-Date) - (Get-Item $askPath).LastWriteTime).TotalSeconds
                                if ($age -gt 180) { $expired = $true }
                            }
                            if (-not $expired) {
                                Send-Text -Response $resp -Text $raw
                                break
                            }
                            Remove-Item $askPath -Force -ErrorAction SilentlyContinue
                        } catch { }
                    }
                    Send-Text -Response $resp -Text '{"id":"","question":""}'
                }

                '/api/pause' {
                    # 强停：kill 掉正在跑 agent，队列里那条标成 paused
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $n = 0
                    foreach ($slot in @($Workers.Keys)) {
                        try { $Workers[$slot] | Stop-Process -Force -ErrorAction SilentlyContinue; $n++ } catch { }
                    }
                    $Workers.Clear()

                    # 强停时也把提问文件清掉，否则前端会一直显示"等你回答"
                    foreach ($f2 in @('ask.json', 'answer.json')) {
                        $fp = Join-Path $Root ('agent\' + $f2)
                        if (Test-Path $fp) { Remove-Item $fp -Force -ErrorAction SilentlyContinue }
                    }
                    $items = Get-Queue
                    foreach ($it in $items) {
                        if ($it.status -eq 'running') {
                            $it.status = 'paused'
                            $it.doneAt = (Get-Date -Format 'MM-dd HH:mm:ss')
                            $it.result = '用户手动暂停'
                        }
                    }
                    Save-Queue $items
                    # 关键：状态文件也要改，否则面板还显示"执行中"，看着像没停
                    for ($sl = 1; $sl -le $WorkerCount; $sl++) {
                        $sf2 = Get-SlotStateFile $sl
                        $st2 = Read-JsonFile $sf2
                        if ($st2 -and [string]$st2.status -eq 'running') {
                            $st2.status = 'paused'
                            $st2.phase = '已暂停（你手动停的）'
                            $st2.answer = '你手动暂停了这个任务，前面的进度都保留着。'
                            $st2.summary = '任务已暂停，没做完。要继续的话把任务重新发一次。'
                            try { [IO.File]::WriteAllText($sf2, ($st2 | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false))) } catch { }
                        }
                    }
                    Send-Text -Response $resp -Text ('{"ok":true,"stopped":' + $n + '}')
                }

                '/api/stop' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $n = 0
                    foreach ($slot in @($Workers.Keys)) {
                        try { $Workers[$slot] | Stop-Process -Force -ErrorAction SilentlyContinue; $n++ } catch { }
                    }
                    $Workers.Clear()

                    # 光杀进程不够。任务状态还留在 running，面板会一直显示"跑着"，
                    # 下一个任务的 state 又把它覆盖掉，看起来就像两个任务的答案串了。
                    # 所以这里要把队列和 state 一起收尾。
                    try {
                        $q = Get-Queue
                        $changedQ = $false
                        foreach ($it in $q) {
                            if ($it.status -eq 'running' -or $it.status -eq 'pending') {
                                $it.status = 'stopped'
                                $it.doneAt = (Get-Date -Format 'MM-dd HH:mm:ss')
                                if (-not $it.result) { $it.result = '已手动停止' }
                                $changedQ = $true
                            }
                        }
                        if ($changedQ) { Save-Queue $q }
                    } catch { }

                    try {
                        $st = [ordered]@{ status = 'stopped'; task = ''; step = 0; answer = '已手动停止'; steps = @(); elapsed = 0 }
                        [IO.File]::WriteAllText($StateFile, ($st | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
                    } catch { }

                    Send-Text -Response $resp -Text ('{"ok":true,"stopped":' + $n + '}')
                }

                '/api/admin' {
                    # 以管理员身份重启面板：弹一次 UAC，通过后新面板有管理员权限
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $isAdmin = $false
                    try {
                        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
                        $pr = New-Object Security.Principal.WindowsPrincipal($id)
                        $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                    } catch { }
                    if ($isAdmin) {
                        Send-Text -Response $resp -Text '{"ok":true,"msg":"已经是管理员权限了"}'
                        break
                    }
                    Send-Text -Response $resp -Text '{"ok":true,"msg":"正在请求管理员权限，请在弹出的窗口点「是」"}'
                    try {
                        $self = $MyInvocation.MyCommand.Path
                        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden `
                            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self)
                        Start-Sleep -Milliseconds 900
                        # 老面板退场，让新的接管端口
                        try { $listener.Stop() } catch { }
                        exit
                    } catch {
                        Write-Host ("  提权失败：" + $_.Exception.Message) -ForegroundColor Yellow
                    }
                }

                '/api/replay' {
                    # 重答：把某条历史任务重新入队跑一遍
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $taskText = ''
                    try { $taskText = ([string]((Read-Body $ctx.Request | ConvertFrom-Json).task)).Trim() } catch { }
                    if ([string]::IsNullOrWhiteSpace($taskText)) { Send-Text -Response $resp -Text '{"ok":false,"msg":"没有任务内容"}' -Code 400; break }
                    $item = Add-QueueItem -TaskText $taskText -Priority 1
                    Send-Text -Response $resp -Text ('{"ok":true,"id":' + (J $item.id) + '}')
                }


                '/api/queue/cancel' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $items = Get-Queue
                    $n = 0
                    foreach ($it in $items) {
                        if ($it.status -eq 'pending') { $it.status = 'cancelled'; $it.doneAt = (Get-Date -Format 'MM-dd HH:mm:ss'); $n++ }
                    }
                    Save-Queue $items
                    Send-Text -Response $resp -Text ('{"ok":true,"cancelled":' + $n + '}')
                }

                # 流式增量：前端按 seq 轮询，只取比上次新的片段
                # ?since=N 表示「我已经看到第 N 条了，给我后面的」
                '/api/stream' {
                    $since = 0
                    $rawQ = [string]$ctx.Request.Url.Query
                    $mSince = [regex]::Match($rawQ, 'since=(\d+)')
                    if ($mSince.Success) { $since = [int]$mSince.Groups[1].Value }

                    $sf = Join-Path $Root 'agent\stream.jsonl'
                    $items = @()
                    $maxSeq = $since
                    if (Test-Path $sf) {
                        try {
                            # agent 正在写的时候也能读，所以要 FileShare.ReadWrite
                            $fsr = [IO.File]::Open($sf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                            try {
                                $srd = New-Object IO.StreamReader($fsr, [Text.Encoding]::UTF8)
                                $txt = $srd.ReadToEnd()
                                $srd.Close()
                            } finally { $fsr.Close() }
                            foreach ($ln in ($txt -split "`n")) {
                                if (-not $ln.Trim()) { continue }
                                try {
                                    $o = $ln | ConvertFrom-Json
                                    $sq = [int]$o.seq
                                    if ($sq -gt $maxSeq) { $maxSeq = $sq }
                                    if ($sq -gt $since) {
                                        $items += [pscustomobject]@{ seq = $sq; kind = [string]$o.kind; text = [string]$o.text }
                                    }
                                } catch { }
                            }
                        } catch { }
                    }
                    $payload = [pscustomobject]@{ seq = $maxSeq; items = @($items) } |
                               ConvertTo-Json -Depth 5 -Compress
                    Send-Text -Response $resp -Text $payload
                }

                '/api/config' {
                    if ($method -eq 'POST') {
                        $body = Read-Body $ctx.Request
                        try {
                            $newCfg = $body | ConvertFrom-Json
                            $cur = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

                            # 范围校验：面板能改，但不能改成跑不起来的数
                            $limits = @{
                                context            = @(1024, 32768)
                                threads            = @(0, 32)
                                maxTokens          = @(100, 4000)
                                maxSteps           = @(5, 100)
                                stepTimeoutSeconds = @(30, 1800)
                                taskTimeoutSeconds = @(60, 7200)
                                runTimeoutSeconds  = @(5, 600)
                                maxOutputChars     = @(200, 8000)
                                parallel           = @(1, 4)
                                temperature        = @(0.0, 2.0)
                                topP               = @(0.1, 1.0)
                                port               = @(1024, 65535)
                                monitorPort        = @(1024, 65535)
                            }
                            $bad = @()
                            foreach ($pv in $newCfg.PSObject.Properties) {
                                if (-not $limits.ContainsKey($pv.Name)) { continue }
                                $lo = $limits[$pv.Name][0]; $hi = $limits[$pv.Name][1]
                                $num = 0.0
                                if (-not [double]::TryParse([string]$pv.Value, [ref]$num)) {
                                    $bad += ($pv.Name + ' 不是数字')
                                    continue
                                }
                                if ($num -lt $lo -or $num -gt $hi) {
                                    $bad += ($pv.Name + ' 要在 ' + $lo + ' - ' + $hi + ' 之间')
                                }
                            }
                            if ($bad.Count -gt 0) {
                                Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J ($bad -join '；')) + '}') -Code 400
                                break
                            }
                            $intKeys = @('port','monitorPort','threads','context','maxTokens','maxSteps','parallel','runTimeoutSeconds','stepTimeoutSeconds','taskTimeoutSeconds','prio','maxOutputChars')
                            foreach ($p in $newCfg.PSObject.Properties) {
                                if ($p.Name -in $intKeys) { $cur | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([int]$p.Value) -Force }
                                elseif ($p.Name -eq 'temperature' -or $p.Name -eq 'topP') { $cur | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([double]$p.Value) -Force }
                                elseif ($p.Name -eq 'allowAnyPath' -or $p.Name -eq 'allowGui' -or $p.Name -eq 'allowAdmin') { $cur | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([bool]$p.Value) -Force }
                                else { $cur | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
                            }
                            [IO.File]::WriteAllText($CfgPath, ($cur | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
                            $script:Cfg = $cur
                            Send-Text -Response $resp -Text '{"ok":true,"msg":"已保存，部分参数重启后生效"}'
                        } catch {
                            Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J $_.Exception.Message) + '}') -Code 400
                        }
                    } else {
                        Send-Text -Response $resp -Text ((Get-Content $CfgPath -Raw -Encoding UTF8).Trim())
                    }
                }

                '/api/history' {
                    $list = New-Object System.Collections.ArrayList
                    if (Test-Path $HistFile) {
                        try {
                            $all = @(Get-Content $HistFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
                            $take = @($all | Select-Object -Last 40)
                            [array]::Reverse($take)
                            foreach ($ln in $take) {
                                try { [void]$list.Add(($ln | ConvertFrom-Json)) } catch { }
                            }
                        } catch { }
                    }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $list.ToArray() -Depth 8 -Compress)
                }

                '/api/context' {
                    $list = New-Object System.Collections.ArrayList
                    if (Test-Path $CtxFile) {
                        try {
                            $all = @(Get-Content $CtxFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
                            $take = @($all | Select-Object -Last 20)
                            [array]::Reverse($take)
                            foreach ($ln in $take) {
                                try { [void]$list.Add(($ln | ConvertFrom-Json)) } catch { }
                            }
                        } catch { }
                    }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $list.ToArray() -Depth 8 -Compress)
                }

                '/api/open' {
                    # 在资源管理器里打开工作区里的某个目录
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $rel = ''
                    try { $rel = ([string]((Read-Body $ctx.Request | ConvertFrom-Json).path)).Trim() } catch { }
                    $wsFull = if ([IO.Path]::IsPathRooted([string]$Cfg.workspace)) { [string]$Cfg.workspace } else { Join-Path $Root ([string]$Cfg.workspace) }
                    $target = if ([string]::IsNullOrWhiteSpace($rel) -or $rel -eq '.') { $wsFull } else { Join-Path $wsFull $rel }
                    try { $target = [IO.Path]::GetFullPath($target) } catch { }
                    # 只允许打开工作区里面的路径
                    $wsNorm = [IO.Path]::GetFullPath($wsFull).TrimEnd('\')
                    if (-not $target.StartsWith($wsNorm, [StringComparison]::OrdinalIgnoreCase)) {
                        Send-Text -Response $resp -Text '{"ok":false,"msg":"只能打开工作区里的目录"}' -Code 400
                        break
                    }
                    if (-not (Test-Path -LiteralPath $target)) {
                        Send-Text -Response $resp -Text '{"ok":false,"msg":"目录不存在"}' -Code 400
                        break
                    }
                    if (-not (Test-Path -LiteralPath $target -PathType Container)) { $target = Split-Path $target -Parent }
                    try {
                        Start-Process -FilePath 'explorer.exe' -ArgumentList @($target) -ErrorAction Stop
                        Send-Text -Response $resp -Text ('{"ok":true,"path":' + (J $target) + '}')
                    } catch {
                        Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J $_.Exception.Message) + '}') -Code 500
                    }
                }

                '/api/tools' {
                    # 面板/编辑器的工具列表。直接读 tools-schema.json，加几个就显示几个。
                    # 顺便按语义分组——51 个工具平铺太长，编辑器里要能折叠和搜索。
                    $toolsPath = Join-Path $Root 'agent\tools-schema.json'
                    $groups = @{
                        '文件' = @('write_file','read_file','list_dir','hash_file','read_lines','zip_list','diff_files','replace_in_file','set_line','append_file','make_dir','find_files','file_info','move_path','copy_path','grep_file','delete_path')
                        '执行' = @('run_cmd','run_ps','run_ps1','run_bat','run_js','run_python','write_script')
                        '系统' = @('sys_info','clipboard','env_get','open_app','kill_process','ps','install')
                        '网络' = @('download_file','web_search','web_fetch')
                        '数据' = @('json_format','csv_preview')
                        '查询' = @('now','date_calc','unit_convert','project_doc','help','syshelp','win_doc')
                        '流程' = @('say','rethink','plan','learn','finish')
                        '技能' = @('skill','write_skill','unzip')
                    }
                    $nameToGroup = @{}
                    foreach ($gName in $groups.Keys) { foreach ($tn in $groups[$gName]) { $nameToGroup[$tn] = $gName } }
                    $list = New-Object System.Collections.ArrayList
                    if (Test-Path $toolsPath) {
                        try {
                            $arr = Get-Content $toolsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            foreach ($tool in @($arr)) {
                                $fn = $tool.function
                                if (-not $fn -or -not $fn.name) { continue }
                                $tn = [string]$fn.name
                                $grp = if ($nameToGroup.ContainsKey($tn)) { $nameToGroup[$tn] } else { '其他' }
                                [void]$list.Add([pscustomobject]@{
                                    name = $tn
                                    desc = [string]$fn.description
                                    group = $grp
                                })
                            }
                        } catch { }
                    }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $list.ToArray() -Depth 4 -Compress)
                }

                '/api/checkscript' {
                    # 语法检查。编辑器里写的 PowerShell 和生成的 JSON 都在这里过一遍。
                    # 手写 mod 最容易漏逗号，提前查出来比加载失败强。
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false,"msg":"只接受 POST"}' -Code 405; break }
                    $b = $null
                    try { $b = (Read-Body $ctx.Request) | ConvertFrom-Json } catch { }
                    $ckType = if ($b -and $b.type) { [string]$b.type } else { 'ps1' }
                    $ckCode = if ($b -and $null -ne $b.code) { [string]$b.code } else { '' }
                    $errs = New-Object System.Collections.ArrayList
                    $ckOk = $true
                    if (-not [string]::IsNullOrWhiteSpace($ckCode)) {
                        if ($ckType -eq 'json') {
                            try { $null = ($ckCode | ConvertFrom-Json) }
                            catch {
                                $ckOk = $false
                                [void]$errs.Add('{"line":0,"col":0,"msg":' + (J ([string]$_.Exception.Message)) + '}')
                            }
                        } else {
                            $pe = $null
                            [void][System.Management.Automation.Language.Parser]::ParseInput($ckCode, [ref]$null, [ref]$pe)
                            if ($pe -and @($pe).Count -gt 0) {
                                $ckOk = $false
                                foreach ($one in @($pe)) {
                                    [void]$errs.Add('{"line":' + $one.Extent.StartLineNumber + ',"col":' + $one.Extent.StartColumnNumber + ',"msg":' + (J ([string]$one.Message)) + '}')
                                }
                            }
                        }
                    }
                    $errJson = if ($errs.Count -gt 0) { '[' + ($errs -join ',') + ']' } else { '[]' }
                    Send-Text -Response $resp -Text ('{"ok":' + $(if ($ckOk) { 'true' } else { 'false' }) + ',"errors":' + $errJson + '}')
                }
                '/api/mods' {
                    # 面板显示已加载的 mod。读的是 mod/*.mod.json 的文件名和元数据，
                    # 不 execute 里面的脚本（那由 agent 在启动时做）。
                    $modDir2 = Join-Path $Root 'mod'
                    $modList = New-Object System.Collections.ArrayList
                    if (Test-Path $modDir2) {
                        foreach ($mf in @(Get-ChildItem $modDir2 -Filter '*.mod.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                            try {
                                $mj = Get-Content $mf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                                [void]$modList.Add([pscustomobject]@{
                                    file    = [string]$mf.Name
                                    id      = [string]$mj.id
                                    name    = [string]$mj.name
                                    version = [string]$mj.version
                                    enabled = $(if ($null -eq $mj.enabled) { $true } else { [bool]$mj.enabled })
                                    hasPrompt = [bool]$mj.prompt
                                    docCount  = @($mj.docs).Count
                                    toolCount = @($mj.tools.PSObject.Properties).Count
                                    cfgCount  = @($mj.config.PSObject.Properties).Count
                                })
                            } catch { }
                        }
                    }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $modList.ToArray() -Depth 4)
                }

                '/api/files' {
                    # 工作区文件清单，给面板左侧的文件栏用
                    $wsFull = if ([IO.Path]::IsPathRooted([string]$Cfg.workspace)) { [string]$Cfg.workspace } else { Join-Path $Root ([string]$Cfg.workspace) }
                    $items = New-Object System.Collections.ArrayList
                    try {
                        $all = @(Get-ChildItem -LiteralPath $wsFull -Recurse -File -ErrorAction SilentlyContinue |
                                 Where-Object { $_.FullName -notmatch '\\\.backup\\' } |
                                 Sort-Object LastWriteTime -Descending)
                        foreach ($f in $all) {
                            $rel = $f.FullName.Substring($wsFull.Length).TrimStart('\')
                            $dir = ''
                            if ($rel -match '\\') { $dir = $rel.Substring(0, $rel.LastIndexOf('\')) }
                            [void]$items.Add([pscustomobject]@{
                                name  = $f.Name
                                rel   = $rel
                                dir   = $dir
                                size  = [int]$f.Length
                                mtime = $f.LastWriteTime.ToString('MM-dd HH:mm')
                            })
                        }
                    } catch { }
                    $out = '{"workspace":' + (J ([string]$Cfg.workspace)) +
                           ',"count":' + $items.Count +
                           ',"files":' + (ConvertTo-Json -InputObject $items.ToArray() -Depth 4 -Compress) + '}'
                    if ($out -match '"files":null') { $out = $out.Replace('"files":null', '"files":[]') }
                    Send-Text -Response $resp -Text $out
                }

                '/api/session' {
                    # 会话流：把 user / assistant 的轮次按时间顺序返回
                    $sf = Join-Path $Root 'agent\logs\session.jsonl'
                    $list = New-Object System.Collections.ArrayList
                    if (Test-Path $sf) {
                        try {
                            $all = @(Get-Content $sf -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
                            $take = @($all | Select-Object -Last 40)
                            foreach ($ln in $take) {
                                try { [void]$list.Add(($ln | ConvertFrom-Json)) } catch { }
                            }
                        } catch { }
                    }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $list.ToArray() -Depth 6 -Compress)
                }

                '/api/session/clear' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    # 先停掉正在跑的任务，不然它一直往 state 里写，清不干净
                    foreach ($slot in @($Workers.Keys)) {
                        try { $Workers[$slot] | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
                    }
                    $Workers.Clear()
                    $items = Get-Queue
                    foreach ($it in $items) {
                        if ($it.status -eq 'running') { $it.status = 'cancelled'; $it.result = '对话已清除' }
                    }
                    Save-Queue $items

                    $sf = Join-Path $Root 'agent\logs\session.jsonl'
                    try { [IO.File]::WriteAllText($sf, '', (New-Object Text.UTF8Encoding($false))) } catch { }
                    # 状态文件也一并删掉，面板上的任务卡才会消失
                    for ($sl = 1; $sl -le $WorkerCount; $sl++) {
                        $sf2 = Get-SlotStateFile $sl
                        try { if (Test-Path $sf2) { Remove-Item $sf2 -Force -ErrorAction SilentlyContinue } } catch { }
                    }
                    Send-Text -Response $resp -Text '{"ok":true}'
                }


                '/api/restart' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    Send-Text -Response $resp -Text '{"ok":true,"msg":"正在重启模型服务"}'
                    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $Root 'launcher.ps1'),'-NoBrowser') -WindowStyle Hidden
                }

                # 自主模式状态：面板读它显示「在跑吗 / 下次几点醒 / 做了几件」
                '/api/autopilot' {
                    $af = Join-Path $Root 'agent\autopilot.json'
                    if (Test-Path $af) {
                        try {
                            $raw = [IO.File]::ReadAllText($af, [Text.Encoding]::UTF8)
                            Send-Text -Response $resp -Text $raw.Trim()
                        } catch { Send-Text -Response $resp -Text '{"running":false}' }
                    } else {
                        Send-Text -Response $resp -Text '{"running":false}'
                    }
                }

                # 手动开一轮自主模式。用户明确要「手动触发才启动」。
                '/api/wake' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $body = Read-Body $ctx.Request
                    $minutes = 30
                    $focus = ''
                    try {
                        $j = $body | ConvertFrom-Json
                        if ($j.minutes) { $minutes = [int]$j.minutes }
                        if ($j.focus) { $focus = [string]$j.focus }
                    } catch { }
                    if ($minutes -lt 1) { $minutes = 1 }
                    if ($minutes -gt 240) { $minutes = 240 }

                    $af = Join-Path $Root 'agent\autopilot.json'
                    $already = $false
                    if (Test-Path $af) {
                        try {
                            $cur = Get-Content $af -Raw -Encoding UTF8 | ConvertFrom-Json
                            if ($cur.running -eq $true) { $already = $true }
                        } catch { }
                    }
                    if ($already) {
                        Send-Text -Response $resp -Text '{"ok":false,"msg":"自主模式已经在跑了"}'
                        break
                    }

                    $apArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                                (Join-Path $Root 'agent\autopilot.ps1'), '-ForMinutes', [string]$minutes)
                    if ($focus) { $apArgs += @('-Focus', $focus) }
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $apArgs -WindowStyle Hidden
                    Send-Text -Response $resp -Text ('{"ok":true,"minutes":' + $minutes + '}')
                }

                # 停掉自主模式
                '/api/wake/stop' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    $n = 0
                    try {
                        foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
                            $cl = [string]$pr.CommandLine
                            if ($cl -match 'autopilot\.ps1') {
                                try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue; $n++ } catch { }
                            }
                        }
                    } catch { }
                    $af = Join-Path $Root 'agent\autopilot.json'
                    try {
                        [IO.File]::WriteAllText($af, '{"running":false,"stopped":"' + (Get-Date -Format 'HH:mm:ss') + '"}', (New-Object Text.UTF8Encoding($false)))
                    } catch { }
                    Send-Text -Response $resp -Text ('{"ok":true,"stopped":' + $n + '}')
                }

                default {
                    Send-Text -Response $resp -Text '{"ok":false,"msg":"not found"}' -Code 404
                }
            }
        }

        # 无论有没有请求，都做一次调度
        Invoke-Dispatch

    } catch {
        # 单次请求出错不能拖垮整个面板。
        #
        # 关键是这里必须把监听句柄重新挂上。
        # 如果异常发生在 EndGetContext 之后、或者 async 本身已经失效，
        # 原来的写法只关流 + 睡 200ms 就继续循环 ——
        # 下一轮 WaitOne 立刻返回、EndGetContext 又抛，转成死循环，
        # 表现就是"面板突然没反应了"，浏览器一直转圈。
        try { [void]$ctx.Response.OutputStream.Close() } catch { }
        try {
            if (-not $listener.IsListening) { break }
            # 重新挂一个干净的异步监听
            $async = $listener.BeginGetContext($null, $null)
        } catch {
            # 连 BeginGetContext 都失败，说明监听器本身废了，重建它
            try {
                $listener.Stop()
                $listener.Close()
            } catch { }
            try {
                $listener = New-Object System.Net.HttpListener
                $listener.Prefixes.Add("http://$($Cfg.host):$Port/")
                $listener.Start()
                $async = $listener.BeginGetContext($null, $null)
            } catch {
                Start-Sleep -Seconds 2
            }
        }
        Start-Sleep -Milliseconds 150
    }
}