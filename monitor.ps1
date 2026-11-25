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
# ------------------------------------------------------------
#  启动自检：内存够不够、模型起没起
#  
#  实测过一次很典型的翻车：llama 用 7168 上下文占了 4.4 GB，
#  物理内存只剩 0.4 GB。面板是个 PowerShell 进程，启动时申请不到
#  内存就静默退出 —— 没有报错、没有日志、什么都没有，用户只看到
#  「面板打不开」。
#  
#  所以启动前先量一下：
#    · 可用内存低于 300 MB → 等一会儿再试，最多等 20 秒
#    · 模型端口不通 → 提示一下但不拦（面板本身还能看历史）
#  
#  这段只做事前提示和等待，不改变原有流程。
# ------------------------------------------------------------
try {
    $freeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1024)
    if ($freeMB -lt 300) {
        for ($wait = 1; $wait -le 10; $wait++) {
            Start-Sleep -Milliseconds 2000
            $freeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1024)
            if ($freeMB -ge 300) { break }
        }
    }
} catch { $freeMB = -1 }


$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath   = $ConfigFile
if (-not [IO.Path]::IsPathRooted($CfgPath)) { $CfgPath = Join-Path $Root $CfgPath }
# 传给子进程（agent.ps1 靠这个知道用哪套配置）
$env:NAFX_CONFIG = $CfgPath
$Cfg       = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

# 自动化调度器（jobs.json）：面板读列表、手动跑一条；真正的 tick 在 watchdog 里
$schedPath = Join-Path $Root 'scripts\scheduler.ps1'
if (Test-Path $schedPath) { . $schedPath }

# 读取允许整行 # 注释的 JSON（api-key.json 顶部有填写说明）。
# 只去掉整行注释，不会碰字符串里的 #。
function Read-LooseJson([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $clean = (($text -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
    return ($clean | ConvertFrom-Json)
}
if ($Port -le 0) { $Port = [int]$Cfg.monitorPort }

# 模型来源模式：local（本地 llama）/ api（外部接口）。
# 每次读配置都刷一遍，面板切模式后不用重启。
$script:CurMode = ([string]$Cfg.modelMode).Trim().ToLower()
if ($script:CurMode -notin @('local', 'api')) { $script:CurMode = 'local' }
# 接口模式下有没有配密钥 —— 面板据此提示「先填 key」
$script:ApiHasKey = $false
try {
    $kf = Join-Path $Root 'api-key.json'
    if (Test-Path $kf) {
        $kj = Read-LooseJson $kf
        if (([string]$kj.apiKey).Trim()) { $script:ApiHasKey = $true }
    }
} catch { }

$StateFile = Join-Path $Root 'agent\state.json'
# 累计用量：agent 每发一次请求就累加进这个文件，面板顶栏的「总用量」直接读它。
$UsageFile = Join-Path $Root 'agent\logs\usage.json'
$HtmlPath  = Join-Path $Root 'agent\dashboard.html'
$AgentPath = Join-Path $Root 'agent\agent.ps1'
$QueueFile = Join-Path $Root 'agent\queue.json'
$HistFile  = Join-Path $Root 'agent\logs\history.jsonl'
$CtxFile   = Join-Path $Root 'agent\logs\task-context.jsonl'
$UiLogDir  = Join-Path $Root 'agent\logs'

# ------------------------------------------------------------
#  面板自己的日志
#
#  以前 monitor 一行日志都不记，只有 8 处 Write-Host。
#  但它是用 -WindowStyle Hidden 起来的，控制台输出直接进了黑洞 ——
#  面板出错、请求异常、任务调度失败，事后一点痕迹都查不到。
#
#  现在单独一个 logs\panel\ 目录，和 agent 的日志分开：
#    panel.log      面板自己的事（启动、调度、出错、慢请求）
#    requests.log   值得留痕的 API 请求（POST 操作、出错响应）
#
#  写日志绝不能抛异常：日志写失败把面板搞挂了最蠢。整段套 try/catch。
# ------------------------------------------------------------
$script:PanelLogDir = Join-Path $Root 'logs\panel'
if (-not (Test-Path $script:PanelLogDir)) {
    try { New-Item -ItemType Directory -Force -Path $script:PanelLogDir | Out-Null } catch { }
}
# 每个请求都记 DEBUG 太吵（轮询接口每秒好几条），默认关。
# 要排查「面板到底在请求什么」时，把 config.json 里的 panelVerbose 设成 true。
$script:PanelVerbose = $false
try { if ($Cfg.PSObject.Properties.Name -contains 'panelVerbose') { $script:PanelVerbose = [bool]$Cfg.panelVerbose } } catch { }
# 连续查不到 agent 进程的轮数（用于给中断判定防抖）
$script:agentMissStreak = 0
$script:PanelLogFile = Join-Path $script:PanelLogDir 'panel.log'
$script:ReqLogFile   = Join-Path $script:PanelLogDir 'requests.log'

function Write-PanelLog {
    param([string]$Text, [string]$Level = 'INFO')
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    try {
        $line = '[' + (Get-Date -Format 'MM-dd HH:mm:ss') + '] [' + $Level + '] ' + $Text
        # AppendAllText + 无 BOM：Add-Content -Encoding UTF8 第一次会写 BOM，
        # 后面不写，混在一起就是一行乱码（这个坑踩过）。
        [IO.File]::AppendAllText($script:PanelLogFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Write-ReqLog {
    param([string]$Path, [string]$Method, [int]$Ms = 0, [string]$Note = '')
    try {
        $line = (Get-Date -Format 'MM-dd HH:mm:ss') + '  ' + $Method.PadRight(4) + '  ' +
                $Path.PadRight(26) + '  ' + $ms.ToString().PadLeft(5) + 'ms  ' + $Note
        [IO.File]::AppendAllText($script:ReqLogFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------- 热点缓存 ----------------
#
# 面板是单线程的：一个请求慢，后面的全排着。
# 日志里那一堆「慢请求 /api/state 1543ms」就是证据 ——
# 主要开销是 Get-CimInstance（查 agent 进程还在不在）。
# 模型吃满 CPU 时 WMI 要 1.5-2 秒，而前端每 350ms 就轮询一次 state。
#
# 两处都按 3 秒缓存：人眼感觉不到，但这些调用能压掉九成以上。
#   ① 进程探测   → 面板从「卡顿」变「跟手」
#   ② 模型健康   → /api/system 不用每次都发 HTTP
#
$script:ModelUrl   = 'http://' + [string]$Cfg.host + ':' + [string][int]$Cfg.port
$script:ProcCacheAt = [datetime]::MinValue
$script:ProcCacheList = @()
$script:ModelUpAt = [datetime]::MinValue
$script:ModelUpVal = $false

function Get-AgentProcessList {
    try {
        # 缓存 10 秒，不是 3 秒。这个查询（Get-CimInstance Win32_Process × 2）
        # 在模型吃满 CPU 时要 5–9 秒才回来，而 /api/state 每次轮询都会走到它 ——
        # 缓存太短等于每隔几秒就把面板主线程钉死一次，实测 /api/state 要 9 秒，
        # 前端看起来就是「任务在跑，界面不动」。
        # 判「任务是否还活着」还有 state 文件时间戳（25 秒宽限）兜底，
        # 10 秒的进程缓存不会误判。
        if (((Get-Date) - $script:ProcCacheAt).TotalSeconds -lt 10) { return ,$script:ProcCacheList }
    } catch { }
    $list = @()
    try {
        # 面板自身可能由 powershell.exe 启动，也可能由 pwsh.exe 启动；
        # 两边都收，免得换 PowerShell 版本后看不到/管不住 agent 进程。
        foreach ($name in @('powershell.exe', 'pwsh.exe')) {
            $list += @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue)
        }
    } catch { }
    $script:ProcCacheAt = Get-Date
    $script:ProcCacheList = $list
    return ,$list
}

function Test-ModelUp {
    try {
        if (((Get-Date) - $script:ModelUpAt).TotalSeconds -lt 3) { return $script:ModelUpVal }
    } catch { }
    # 接口模式不查 llama 端口 —— 那边本来就没在跑，查了永远是 false，
    # 面板会一直挂「模型没启动」的横幅，可实际上接口模式的模型好好的。
    if ($script:CurMode -eq 'api') { return $true }
    $ok = $false
    try { $ok = ((Invoke-WebRequest ($script:ModelUrl + '/health') -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) } catch { $ok = $false }
    $script:ModelUpAt = Get-Date
    $script:ModelUpVal = $ok
    return $ok
}

# llama 实际给的上下文，不是 config 里写的那个。
#
# config 里的 context 只是「想要多少」，launcher 会按内存再算一遍再传 -c。
# 实测出现过 config 写 6000、llama 实际只给 4096 ——
# 面板照着 config 显示，用户以为还能塞 6000，其实早就溢出了。
#
# /props 的响应里带着完整的 chat template（几百 KB），
# 所以只正则抓 n_ctx，不做整段 JSON 解析；结果缓存 30 秒。
$script:CtxRealAt = [datetime]::MinValue
$script:CtxRealVal = 0
function Get-RealContext {
    try { if (((Get-Date) - $script:CtxRealAt).TotalSeconds -lt 30) { return $script:CtxRealVal } } catch { }
    $val = 0
    try {
        $p = (Invoke-WebRequest ($script:ModelUrl + '/props') -UseBasicParsing -TimeoutSec 4).Content
        if ($p -match '"n_ctx"\s*:\s*(\d+)') { $val = [int]$Matches[1] }
    } catch { $val = 0 }
    $script:CtxRealAt = Get-Date
    $script:CtxRealVal = $val
    return $val
}

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
    # 请求日志在这里记：所有 API 都走 Send-Text，一处就全覆盖。
    # 轮询接口每秒好几次，记下来只会撑大文件，所以只记值得留痕的。
    try {
        if ($script:ReqSw) {
            $ms = [int]$script:ReqSw.Elapsed.TotalMilliseconds
            if ($script:LogThisReq -or $Code -ge 400) {
                $note = ''
                if ($Code -ge 400) { $note = 'HTTP ' + $Code }
                Write-ReqLog -Path ([string]$script:ReqPath) -Method ([string]$script:ReqMethod) -Ms $ms -Note $note
            }
            if ($ms -gt 1500) { Write-PanelLog ("慢请求 " + $script:ReqPath + " " + $ms + "ms") 'WARN' }
            $script:ReqSw = $null
        }
    } catch { }
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
        # 老队列项没有 mode 字段，补成 normal，别让 ConvertTo-Json 输出 null
        if (-not ($it.PSObject.Properties.Name -contains 'mode') -or -not $it.mode) {
            try { $it | Add-Member -NotePropertyName mode -NotePropertyValue 'normal' -Force } catch { }
        }
        $o = [ordered]@{
            id = [string]$it.id; task = [string]$it.task; status = [string]$it.status
            priority = [int]$it.priority; addedAt = [string]$it.addedAt
            startedAt = [string]$it.startedAt; doneAt = [string]$it.doneAt
            result = [string]$it.result; slot = [string]$it.slot
            # mode 必须写进去。
            # 漏了它，Add-QueueItem 设好的模式一存盘就没了 ——
            # 实测工作模式提交后，派发器读回来是空，一律按常规跑，
            # 面板上「常规 / 工作」两个按钮看起来完全没区别。
            mode = [string]$it.mode
            # 同理：reasoning 也得落盘。漏了它，排在前面的任务重启面板后就
            # 退回默认「标准」，用户下半句改成 MAX 也传不到 agent。
            reasoning = $(if ($it.PSObject.Properties.Name -contains 'reasoning' -and $null -ne $it.reasoning) { [int]$it.reasoning } else { 2 })
        }
        [void]$sb.Append(($o | ConvertTo-Json -Depth 6 -Compress))
    }
    [void]$sb.Append(']')
    [IO.File]::WriteAllText($QueueFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}

function Add-QueueItem {
    param([string]$TaskText, [int]$Priority = 5, [string]$Mode = 'normal', [int]$Reasoning = 2)
    # 模式随任务入队，调度时再传给 agent。
    #   normal 常规 / work 工作（步数多、先列计划）/ auto 自主（禁止提问）
    # 写错了一律当 normal，别因为一个参数拼错任务就跑不起来。
    $Mode = ([string]$Mode).Trim().ToLower()
    if ($Mode -notin @('normal', 'work', 'auto')) { $Mode = 'normal' }
    # 推理力度跟着任务走：用户下半句改成「关闭」时，排在前面的任务还是按原档跑
    $Reasoning = [Math]::Max(0, [Math]::Min(4, [int]$Reasoning))
    $items = Get-Queue
    $item = [pscustomobject]@{
        id        = 'q' + (Get-Date -Format 'HHmmss') + [Guid]::NewGuid().ToString('N').Substring(0,4)
        task      = $TaskText
        status    = 'pending'
        priority  = $Priority
        mode      = $Mode
        reasoning = $Reasoning
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

        # 取任务模式（老队列项没有 mode 字段，当 normal）
        $nextMode = 'normal'
        if ($next.PSObject.Properties.Name -contains 'mode' -and $next.mode) { $nextMode = [string]$next.mode }
        if ($nextMode -notin @('normal', 'work', 'auto')) { $nextMode = 'normal' }

        # 推理力度（老队列项没有 reasoning 字段，默认标准）
        $nextReason = 2
        if ($next.PSObject.Properties.Name -contains 'reasoning' -and $null -ne $next.reasoning) { $nextReason = [int]$next.reasoning }
        $nextReason = [Math]::Max(0, [Math]::Min(4, $nextReason))

        # 各模式的步数上限要和 agent.ps1 里的判断一致，
        # 不然面板显示的 maxSteps 和实际跑的不一样。
        $modeMaxSteps = [int]$Cfg.maxSteps
        if ($nextMode -eq 'work') { $modeMaxSteps = [int][Math]::Min(60, [int]$Cfg.maxSteps * 2) }
        if ($nextMode -eq 'auto') { $modeMaxSteps = [int][Math]::Min(40, [int]$Cfg.maxSteps + 10) }

        $slotState = Get-SlotStateFile $slot
        # speed/cacheHit 先给 0：agent 起来后第一步就有真实值。
        # 之前占位 JSON 漏了这两个字段，单步任务（代收尾，运行期间不写中间 state）
        # 的进度条全程拿到的是 undefined，一条横线都不显示。
        $ph = '{"status":"running","task":' + (J $next.task) + ',"steps":[],"step":1,"maxSteps":' + $modeMaxSteps +
              ',"elapsed":0,"phase":"第' + $slot + '路 准备","model":' + (J $Cfg.modelLabel) +
              ',"workspace":' + (J $Cfg.workspace) + ',"answer":"","logFile":"","slot":' + $slot +
              ',"speed":0,"cacheHit":0,"mode":' + (J $nextMode) +
              ',"reasoning":' + [int]$nextReason + '}'
        [IO.File]::WriteAllText($slotState, $ph, (New-Object Text.UTF8Encoding($false)))
        # 第 1 路的也同步到主 state，兼容老逻辑
        if ($slot -eq 1) { [IO.File]::WriteAllText($StateFile, $ph, (New-Object Text.UTF8Encoding($false))) }

        $uiLog = Join-Path $UiLogDir ("ui_run_$slot.txt")
        $env:NAFX_TASK  = $next.task
        $env:NAFX_STATE = $slotState
        try {
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AgentPath, '-MaxSteps', "$modeMaxSteps", '-Mode', $nextMode, '-Reasoning', "$nextReason" `
                -RedirectStandardOutput $uiLog -WindowStyle Hidden -PassThru
            $Workers[$slot] = $proc
            # agent 进程也提一档优先级。
            # 它要跟 llama-server 抢 CPU：一样是单线程，模型吃满时
            # 它写 state.json / 心跳会被推迟，面板就出现「跑着跑着不动了」。
            # AboveNormal 只抢回少量时间片，对生成速度基本无感。
            try { $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal } catch { }
            Write-Host ("  [第{0}路] ({1}) {2}" -f $slot, $nextMode, $next.task) -ForegroundColor Green
            Write-PanelLog ("第$slot 路启动 [" + $nextMode + "] " + $next.task)
        } catch {
            Write-Host ("  [第{0}路] 启动失败：{1}" -f $slot, $_.Exception.Message) -ForegroundColor Red
            Write-PanelLog ("第$slot 路启动失败：" + $_.Exception.Message) 'ERROR'
            Set-QueueStatus -Id $next.id -Status 'failed' -Result '进程启动失败'
        }
        $free--
    }
}

# ---------------- 汇总状态 ----------------
# 把多路 state 合并成一个给面板看
function Get-UsageTotals {
    $u = [ordered]@{
        since = ''; reqs = 0; inTok = 0; outTok = 0; cacheTok = 0
        apiInTok = 0; apiOutTok = 0; apiCacheTok = 0; cost = 0.0; currency = '¥'
    }
    try {
        if (Test-Path $UsageFile) {
            $o = [IO.File]::ReadAllText($UsageFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @($u.Keys)) { if ($null -ne $o.$k) { $u[$k] = $o.$k } }
        }
    } catch { }
    return [pscustomobject]$u
}

function Get-WarmupState {
    $d = [ordered]@{
        status = 'idle'; mode = ''; elapsed = 0; estSeconds = 0; remaining = 0
        promptN = 0; cacheN = 0; started = ''; restored = $false
    }
    try {
        $p = Join-Path $Root 'logs\warmup-state.json'
        if (Test-Path $p) {
            $o = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @($d.Keys)) { if ($null -ne $o.$k) { $d[$k] = $o.$k } }
            # 只在「刚启动的那几分钟」认这个 running：进程被杀掉时文件会停在 running，
            # 不设上限的话面板会一直显示「预热中」，比不显示更误导。
            if ($d['status'] -eq 'running') {
                $startAt = $null
                try { $startAt = [datetime]::Parse([string]$o.startAt, [Globalization.CultureInfo]::InvariantCulture) } catch { }
                if ($startAt) {
                    $el = ((Get-Date) - $startAt).TotalSeconds
                    $d['elapsed'] = [Math]::Round($el, 0)
                    $d['remaining'] = [Math]::Max(0, [Math]::Round([double]$d['estSeconds'] - $el, 0))
                    if ($el -gt 300) { $d['status'] = 'stale' }
                }
            }
        }
    } catch { }
    return [pscustomobject]$d
}

function Get-MergedState {
    # 1.2 秒内的重复调用直接复用上一次的结果。
    # 面板自己每秒轮询一次 state，浏览器多开几个标签页时同一秒会有好几个请求，
    # 每次都要读 state/hb/usage/warmup 四个文件再 ConvertTo-Json ——
    # 模型把 CPU 吃满时，光这一套就能花掉几百毫秒，请求会排起队。
    # 复用 1.2 秒对「步骤进度」这种秒级信息没有可感知的损失。
    try {
        if ($script:MergedCache -and ((Get-Date) - $script:MergedCacheAt).TotalSeconds -lt 1.2) {
            return $script:MergedCache
        }
    } catch { }
    $o = Build-MergedState
    $script:MergedCache = $o
    $script:MergedCacheAt = Get-Date
    return $o
}

function Build-MergedState {
    $list = @()
    for ($slot = 1; $slot -le $WorkerCount; $slot++) {
        $sf = Get-SlotStateFile $slot
        $st = Read-JsonFile $sf
        # 合并心跳。
        #
        # agent 主进程写 state.json，心跳（Runspace）写 state.hb.json ——
        # 两者分开是为了不抢同一个文件（原来都去 Replace(state.json)，
        # 必然有一边失败，实测就是 state.json 永远停在「第1路 准备」，
        # 而 agent 写好的内容卡在 state.json.tmp 里）。
        #
        # 这里：心跳文件比 state 新，就用它的 elapsed / phase 覆盖。
        if ($st) {
            $hbFile = $sf -replace '\.json$', '.hb.json'
            if (Test-Path $hbFile) {
                try {
                    $stTime = (Get-Item $sf).LastWriteTime
                    $hbTime = (Get-Item $hbFile).LastWriteTime
                    if ($hbTime -gt $stTime) {
                        $hb = Read-JsonFile $hbFile
                        if ($hb) {
                            if ($hb.elapsed) { $st.elapsed = $hb.elapsed }
                            if ($hb.phase) { $st.phase = $hb.phase }
                        }
                    }
                } catch { }
            }
        }
        if ($st) { $list += $st }
    }
    if ($list.Count -eq 0) {
        return [pscustomobject]@{
            status = 'idle'; task = ''; steps = @(); step = 0
            maxSteps = [int]$Cfg.maxSteps; elapsed = 0; model = [string]$Cfg.modelLabel
            workspace = [string]$Cfg.workspace; answer = ''; plan = ''; summary = ''
            logFile = ''; workers = @()
            usage = (Get-UsageTotals); warmup = (Get-WarmupState)
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
        # 先看最便宜的信号：state 文件最近还在被写吗。
        # agent 每步 Write-State、心跳每秒写 .hb.json，所以「文件还新鲜」
        # 本身就是最强的「它还活着」证据 —— 这种情况根本不用去查进程。
        # 这一步很关键：Get-CimInstance Win32_Process 在模型吃满 CPU 时要 5–9 秒，
        # 而 /api/state 是每 1 秒被前端轮询一次的接口，每次都查等于把面板钉死。
        $staleSec = 9999
        try {
            $sf0 = Get-SlotStateFile ([int]$main.slot)
            if (Test-Path $sf0) {
                $staleSec = ((Get-Date) - (Get-Item $sf0).LastWriteTime).TotalSeconds
                # 心跳文件（agent 里的 Runspace 每秒写一次）比 state.json 更新得勤。
                # 模型在想的时候可能几十秒不写 state.json，但心跳一直在动 ——
                # 只看 state.json 会把「正在思考」误判成「进程没了」，
                # 进而去查 CIM（几秒一次），把面板拖死。取两者较新的那个。
                $hb0 = $sf0 -replace '\.json$', '.hb.json'
                if (Test-Path $hb0) {
                    $hbAge = ((Get-Date) - (Get-Item $hb0).LastWriteTime).TotalSeconds
                    if ($hbAge -lt $staleSec) { $staleSec = $hbAge }
                }
            }
        } catch { }

        # 心跳冻结检测（自愈）。
        #
        # 现象：任务早跑完了，面板底下还挂着「正在想 / running」，非得手动刷新才变。
        # 原因不是前端轮询坏了，而是 state.json 里 status 停在 running：
        # agent 被 kill、写终态时正好撞上文件锁、或者进程崩在收尾那一步。
        #
        # agent 的心跳（.hb.json）每秒写一次 elapsed，进程没了 elapsed 就冻结在同一值。
        # 判据：① elapsed 连续 12 秒不动；② state/心跳文件也 12 秒没更新。
        # 命中就把终态写回文件：有答案 → done，没答案 → interrupted。
        # 只在「文件已经冷了」时才动手，正常跑着（心跳在跳）永远不会误伤。
        $nowEl = 0.0
        try { $nowEl = [double]$main.elapsed } catch { }
        $slotKey = 0
        try { $slotKey = [int]$main.slot } catch { }
        if (-not $script:ElWatch) { $script:ElWatch = @{} }
        $w = $script:ElWatch[$slotKey]
        if ($w -and ([Math]::Abs($nowEl - [double]$w.v) -lt 0.5)) {
            $frozenSec = ((Get-Date) - [datetime]$w.at).TotalSeconds
            # 只对「进程确实不在了」的槽位自愈。
            # 进程还活着的场景（比如 run_cmd 跑一个 30 秒的命令，这期间既不写 state
            # 也没有心跳）elapsed 也会短暂冻结 —— 那种情况绝不能改状态，
            # 否则会把正在跑的任务提前标成 done。
            $alive = $false
            try {
                $wp = $Workers[$slotKey]
                if ($wp -and -not $wp.HasExited) { $alive = $true }
            } catch { }
            if (-not $alive -and $frozenSec -ge 12 -and $staleSec -gt 12) {
                $hasAns = ([string]$main.answer).Trim().Length -gt 0
                $main.status = if ($hasAns) { 'done' } else { 'interrupted' }
                $main.phase = if ($hasAns) { '完成' } else { '运行已停止（心跳中断）' }
                try {
                    $healFile = Get-SlotStateFile $slotKey
                    $main | ConvertTo-Json -Depth 10 | Set-Content $healFile -Encoding UTF8
                } catch { }
                $script:ElWatch[$slotKey] = @{ v = 0.0; at = (Get-Date) }
                try { Write-PanelLog ('state 心跳冻结 ' + $frozenSec + 's，已自愈为 ' + $main.status) 'WARN' } catch { }
            }
        } else {
            $script:ElWatch[$slotKey] = @{ v = $nowEl; at = (Get-Date) }
        }

        # 25 秒这个阈值不能太死。
        # 调度器是「先把 state 写成 running，再 Start-Process」，中间有几秒空窗；
        # 面板正好在那几秒里轮询，就会看到 running 但找不到进程 ——
        # 用户看到的就是「明明跑完了，底下却挂着上次被中断」。
        # 现在：state 的 elapsed 刚归零（新任务）时给足 60 秒宽限，其它情况仍是 25 秒。
        $freshStart = $false
        try { if ([double]$main.elapsed -lt 5) { $freshStart = $true } } catch { }
        $graceSec = if ($freshStart) { 60 } else { 25 }

        $hasAgent = $false
        if ($staleSec -le $graceSec) {
            # 文件新鲜 → 一定还在跑，跳过 CIM 查询（这是常态路径）
            $hasAgent = $true
            $script:agentMissStreak = 0
        } else {
            # 只有文件确实冷了，才值得花几秒去查进程。
            # 连续两轮都查不到才算「真的没了」。
            # Get-CimInstance 在忙的时候偶尔返回不全（尤其模型吃满 CPU 时），
            # 单次查不到就判中断，用户会看到跑得好好的任务被打上「已中断」。
            $script:agentMissStreak = [int]$script:agentMissStreak + 1
            try {
                foreach ($ap in @(Get-AgentProcessList)) {
                    $acl = [string]$ap.CommandLine
                    # 宽松匹配：只要命令行里出现 agent.ps1 就算，不再依赖 -File 的写法
                    if ($acl -match 'agent\.ps1') { $hasAgent = $true; $script:agentMissStreak = 0; break }
                }
            } catch {
                $hasAgent = $true   # 查询本身失败就当作在跑
            }
        }
        # 第二层保护：已经有答案了就不可能「被中断」。
        # 实测「把 hello.txt 改成改好了」跑完 finish、文件也改了，
        # 底下却挂着「上次运行被中断」—— 判定串到了上个任务身上。
        $hasResult = ([string]$main.answer).Trim().Length -gt 0
        if (-not $hasResult) {
            foreach ($ss in @($main.steps)) { if ([string]$ss.tool -eq 'finish') { $hasResult = $true; break } }
        }
        # $agentMissStreak >= 2：连续两轮都没查到进程才认。
# 再叠一层：思考期（elapsed 小于 180 秒、还没有任何步骤）永远不判中断 ——
# CPU 上模型首字就要等 70 秒以上，这段时间什么都没有是正常的。
$inThinking = $false
try {
    if ([double]$main.elapsed -lt 180 -and @($main.steps).Count -eq 0) { $inThinking = $true }
} catch { }
if ($script:agentMissStreak -ge 2 -and -not $hasAgent -and -not $hasResult -and -not $inThinking -and $staleSec -gt $graceSec) {
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
        # 模式：local=本地 llama，api=外部接口。面板顶栏据此显示切换按钮。
        modelMode   = $script:CurMode
        modeLabel   = $(if ($script:CurMode -eq 'api') { [string]$Cfg.apiModel } else { [string]$Cfg.modelLabel })
        apiBase     = [string]$Cfg.apiBase
        apiHasKey   = $script:ApiHasKey
        model       = [string]$Cfg.modelLabel
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
        # ---- 上下文占用 ----
        # 这 6 个是 agent 每轮算好写进 state 的：
        #   ctxReal    llama 实际 n_ctx
        #   ctxLimit   这轮真正能用的输入预算
        #   ctxUsed    已经塞了多少（提示词+历史+工具）
        # 上面这段 return 是手工拼字段的，漏掉什么面板就拿不到什么 ——
        # 之前漏了这 6 个，面板「上下文占用」里对话历史和剩余可用
        # 一直显示「等任务开始后算」，任务明明在跑也一样。
        ctxReal    = $(if ($main.PSObject.Properties.Name -contains 'ctxReal') { [int]$main.ctxReal } else { 0 })
        ctxLimit   = $(if ($main.PSObject.Properties.Name -contains 'ctxLimit') { [int]$main.ctxLimit } else { 0 })
        ctxPrompt  = $(if ($main.PSObject.Properties.Name -contains 'ctxPrompt') { [int]$main.ctxPrompt } else { 0 })
        ctxHistory = $(if ($main.PSObject.Properties.Name -contains 'ctxHistory') { [int]$main.ctxHistory } else { 0 })
        ctxTools   = $(if ($main.PSObject.Properties.Name -contains 'ctxTools') { [int]$main.ctxTools } else { 0 })
        ctxUsed    = $(if ($main.PSObject.Properties.Name -contains 'ctxUsed') { [int]$main.ctxUsed } else { 0 })
        # ---- 生成进度条（DSH 式状态行）----
        # speed / cacheHit 由 agent 写：生成中是字符增量估的 tok/s，
        # 一步结束被 llama timings 的 predicted_per_second 和
        # cache_n/(cache_n+prompt_n) 覆盖成真实值。
        # 这个 return 是手工拼字段的，漏了面板就拿不到 ——
        # 上面 ctx 六个字段就是这么漏过一次的，别再犯。
        speed     = $(if ($main.PSObject.Properties.Name -contains 'speed') { [double]$main.speed } else { 0 })
        cacheHit  = $(if ($main.PSObject.Properties.Name -contains 'cacheHit') { [double]$main.cacheHit } else { 0 })
        cacheN    = $(if ($main.PSObject.Properties.Name -contains 'cacheN') { [int]$main.cacheN } else { 0 })
        promptN   = $(if ($main.PSObject.Properties.Name -contains 'promptN') { [int]$main.promptN } else { 0 })
        genTok    = $(if ($main.PSObject.Properties.Name -contains 'genTok') { [int]$main.genTok } else { 0 })
        phase     = [string]$main.phase
        workers   = $summary
        # 累计用量（跨任务、跨重启），面板顶栏「总用量」就是它
        usage     = (Get-UsageTotals)
        # 预热进度（启动后后台预热 prompt 前缀时给个「还剩约 N 秒」）
        warmup    = (Get-WarmupState)
    }
}

# ---------------- 上下文 ----------------
# 系统上下文：模型信息 + 提示词规模 + 工具数量 + 参数
function Get-SystemContext {
    $promptPath = Join-Path $Root 'agent\prompt.md'
    $toolsPath  = Join-Path $Root 'agent\tools-schema.json'
    $promptLen = 0; $promptChars = 0; $toolCount = 0; $toolLen = 0; $toolChars = 0
    try {
        if (Test-Path $promptPath) {
            $promptLen = (Get-Item $promptPath).Length
            $promptChars = (Get-Content $promptPath -Raw -Encoding UTF8).Length
        }
    } catch { }
    try {
        if (Test-Path $toolsPath) {
            $toolLen = (Get-Item $toolsPath).Length
            $toolRaw = Get-Content $toolsPath -Raw -Encoding UTF8
            $toolChars = $toolRaw.Length
            $tj = $toolRaw | ConvertFrom-Json
            $toolCount = @($tj).Count
        }
    } catch { }

    $slots = 0
    try { $slots = @((Invoke-WebRequest ($script:ModelUrl + '/slots') -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json).Count } catch { }

    $ctxReal = 0
    try { if (Test-ModelUp) { $ctxReal = [int](Get-RealContext) } } catch { }
    $ctxShow = $(if ($ctxReal -gt 0) { $ctxReal } else { [int]$Cfg.context })

    return [pscustomobject]@{
        # ---- 模型来源 ----
        # 面板顶栏的切换胶囊靠这几个字段：
        #   modelMode  local / api
        #   modeLabel  现在用的模型名（本地是这个 gguf 的名字，接口是 deepseek-chat）
        #   apiHasKey  接口模式有没有配密钥 —— 没配要在按钮上标红
        modelMode   = $script:CurMode
        modeLabel   = $(if ($script:CurMode -eq 'api') { [string]$Cfg.apiModel } else { [string]$Cfg.modelLabel })
        apiBase     = [string]$Cfg.apiBase
        apiHasKey   = $script:ApiHasKey
        model       = [string]$Cfg.modelLabel
        modelId     = [string]$Cfg.model
        context     = $ctxShow
        contextWant = [int]$Cfg.context
        contextPerSlot = [int][Math]::Floor($ctxShow / $WorkerCount)
        parallel    = $WorkerCount
        slotsReady  = $slots
        maxTokens   = [int]$Cfg.maxTokens
        maxSteps    = [int]$Cfg.maxSteps
        temperature = [double]$Cfg.temperature
        workspace   = [string]$Cfg.workspace
        allowAnyPath = [bool]$Cfg.allowAnyPath
        promptBytes = $promptLen
        promptTokens = [int][Math]::Round($promptChars / 2.5)
        toolCount   = $toolCount
        toolTokens   = [int][Math]::Round($toolChars / 3.5)
        running     = $Workers.Count
        isAdmin     = $script:IsAdminNow
        # 模型服务活着吗？面板据此显示「模型没启动，点这里拉起来」的横幅。
        # 没有这一项，用户发完任务只能干等 30 秒，然后收到一句连接失败。
        modelUp     = [bool](Test-ModelUp)
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
            Write-PanelLog ("端口 $Port 被占用，不重复启动") 'WARN'
    exit 0
}
Write-Host "Nafx 面板：http://$($Cfg.host):$Port/  并行 $WorkerCount 路" -ForegroundColor Cyan
Write-PanelLog ("面板启动 http://" + $Cfg.host + ":" + $Port + "/  并行 " + $WorkerCount + " 路")
Write-PanelLog ("进程 PID " + $PID + "  PowerShell " + $PSVersionTable.PSVersion.ToString())

# 面板自己的优先级提到 AboveNormal。
# llama-server 会按 config.threads 吃满几乎所有核心，模型生成时面板这个
# 单线程循环只能抢到零碎时间片 —— /api/state 这种几毫秒的活会拖成 1–2 秒，
# 前端看起来就是「任务在跑，界面卡住不动」。
# 提一级优先级不会明显拖慢生成（模型只是少几个时间片），但能让面板始终响应。
# 失败了也不影响功能（非管理员下偶尔会拒绝），所以静默处理。
try {
    $proc = [Diagnostics.Process]::GetCurrentProcess()
    $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal
    Write-PanelLog '面板进程优先级已设为 AboveNormal'
} catch { }
try { [IO.File]::WriteAllText((Join-Path $Root 'agent\panel.pid'), "$PID", (New-Object Text.UTF8Encoding($false))) } catch { }

# 启动时清理上次残留的 agent 进程
# 面板重启会丢掉 $Workers 记录，那些进程就成了"没人管的孤儿"，会一直占模型槽位
try {
    $orphans = @(Get-AgentProcessList | Where-Object { $_.CommandLine -match 'agent\.ps1' })
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

            # 请求计时。$script:ReqSw 由 Send-Text 消费，
            # 只有「值得留痕」的请求才写进 requests.log ——
            # 轮询接口（state/session/stream/queue）每秒好几次，记了只会撑大文件。
            $script:ReqSw = [Diagnostics.Stopwatch]::StartNew()
            $script:ReqPath = [string]$path
            $script:ReqMethod = [string]$method
            $script:LogThisReq = ($path -like '/api/*') -and ($path -notin @('/api/state', '/api/session', '/api/stream', '/api/queue', '/api/history'))
            if ($script:PanelVerbose) { Write-PanelLog ("→ " + $method + " " + $path) 'DEBUG' }

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


                '/api/logs' {
                    # 面板自己的日志，给用户排查用。
                    #   ?kind=panel     只面板日志（默认）
                    #   ?kind=req       请求日志
                    #   ?kind=agent     最近一次任务的运行日志
                    #   ?tail=N         只取最后 N 行（默认 200）
                    $kind = 'panel'; $tail = 200
                    $rawQ2 = [string]$ctx.Request.Url.Query
                    $mK = [regex]::Match($rawQ2, 'kind=(\w+)'); if ($mK.Success) { $kind = $mK.Groups[1].Value }
                    $mT = [regex]::Match($rawQ2, 'tail=(\d+)'); if ($mT.Success) { $tail = [Math]::Min(1000, [int]$mT.Groups[1].Value) }
                    $lf = $script:PanelLogFile
                    if ($kind -eq 'req') { $lf = $script:ReqLogFile }
                    if ($kind -eq 'agent') {
                        $runs = @(Get-ChildItem (Join-Path $Root 'agent\logs\run_*.txt') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                        if ($runs.Count -gt 0) { $lf = $runs[0].FullName }
                    }
                    $out = New-Object System.Collections.ArrayList
                    if (Test-Path $lf) {
                        try {
                            $all2 = @(Get-Content $lf -Encoding UTF8 | Where-Object { $_.Trim() })
                            $take2 = @($all2 | Select-Object -Last $tail)
                            foreach ($l2 in $take2) { [void]$out.Add($l2) }
                        } catch { }
                    }
                    $obj2 = [pscustomobject]@{ kind = $kind; file = $lf; total = @($out).Count; lines = @($out) }
                    Send-Text -Response $resp -Text ($obj2 | ConvertTo-Json -Depth 4 -Compress)
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
                    $task = ''; $prio = 5; $runMode = 'normal'; $runReason = 2
                    try {
                        $b = Read-Body $ctx.Request | ConvertFrom-Json
                        $task = ([string]$b.task).Trim()
                        if ($b.PSObject.Properties.Name -contains 'priority') { $prio = [int]$b.priority }
                        if ($b.PSObject.Properties.Name -contains 'mode') { $runMode = [string]$b.mode }
                        if ($b.PSObject.Properties.Name -contains 'reasoning') { $runReason = [int]$b.reasoning }
                    } catch { }
                    if ($runMode -notin @('normal', 'work', 'auto')) { $runMode = 'normal' }
                    if ([string]::IsNullOrWhiteSpace($task)) { Send-Text -Response $resp -Text '{"ok":false,"msg":"任务不能为空"}' -Code 400; break }
                    $item = Add-QueueItem -TaskText $task -Priority $prio -Mode $runMode -Reasoning $runReason
                    $q = Get-Queue
                    $pend = 0; $run = 0
                    foreach ($it in $q) { if ($it.status -eq 'pending') { $pend++ }; if ($it.status -eq 'running') { $run++ } }
                    Send-Text -Response $resp -Text ('{"ok":true,"id":' + (J $item.id) + ',"mode":' + (J $runMode) + ',"pending":' + $pend + ',"running":' + $run + '}')
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
                    # 流式文件也要清空。
                    # 只杀进程的话，stream.jsonl 里暂停前那半句还在，
                    # 面板照样一直读它、一直显示「模型正在输出」——
                    # 用户看到的是一段冻结的文字和一个不动的光标，很像还活着。
                    try {
                        $stf = Join-Path $Root 'agent\stream.jsonl'
                        if (Test-Path $stf) { [IO.File]::WriteAllText($stf, '', (New-Object Text.UTF8Encoding($false))) }
                    } catch { }
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
                    $all = @()
                    $fileMax = 0
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
                                    if ($sq -gt $fileMax) { $fileMax = $sq }
                                    $all += [pscustomobject]@{ seq = $sq; kind = [string]$o.kind; text = [string]$o.text }
                                } catch { }
                            }
                        } catch { }
                    }

                    # 新一轮任务开始时 agent 会清空 stream.jsonl，seq 从 1 重新开始。
                    # 面板还记着上一轮的 max seq（比如 300），于是它只请求 since=300，
                    # 而新文件最大才 50 —— 结果什么增量都收不到，界面上「正在回答」
                    # 一直挂着上一轮的字，必须刷新页面（seq 归零）才恢复。
                    # 这里显式告诉客户端「流已经重来过了」，让它把手里的 seq/文本清掉。
                    $rewound = ($since -gt 0 -and $since -gt $fileMax)
                    if ($rewound) { $since = 0 }

                    $items = @($all | Where-Object { $_.seq -gt $since })
                    $payload = [pscustomobject]@{ seq = $fileMax; items = $items; reset = $rewound } |
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
                            # 注入内容长度先挡一下：本机上下文 6144 tok，写太长把工具定义挤掉
                            if ($newCfg.PSObject.Properties.Name -contains 'contextInject') {
                                $ci = [string]$newCfg.contextInject
                                if ($ci.Length -gt 8000) {
                                    Send-Text -Response $resp -Text ('{"ok":false,"msg":"注入内容太长（' + $ci.Length + ' 字符），控制在 8000 字符以内"}') -Code 400
                                    break
                                }
                            }
                            # 模式值先校验再写盘 —— 写进去再报错，配置已经被改了
                            if ($newCfg.PSObject.Properties.Name -contains 'modelMode') {
                                $mm = ([string]$newCfg.modelMode).Trim().ToLower()
                                if ($mm -notin @('local', 'api')) {
                                    Send-Text -Response $resp -Text ('{"ok":false,"msg":"modelMode 只能是 local 或 api"}') -Code 400
                                    break
                                }
                            }
                            [IO.File]::WriteAllText($CfgPath, ($cur | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
                            $script:Cfg = $cur
                            # 端口/地址改了，健康检查地址也要立刻跟着换，
                            # 否则面板还会去探旧端口。
                            $script:ModelUrl = 'http://' + [string]$cur.host + ':' + [string][int]$cur.port
                            # 模式改了要立刻生效：
                            # 不刷新的话，面板点完「接口」，顶栏还是写着本地，
                            # 用户会以为没点成功。
                            $script:CurMode = ([string]$cur.modelMode).Trim().ToLower()
                            if ($script:CurMode -notin @('local', 'api')) { $script:CurMode = 'local' }
                            Send-Text -Response $resp -Text '{"ok":true,"msg":"已保存，部分参数重启后生效"}'
                        } catch {
                            Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J $_.Exception.Message) + '}') -Code 400
                        }
                    } else {
                        Send-Text -Response $resp -Text ((Get-Content $CfgPath -Raw -Encoding UTF8).Trim())
                    }
                }

                '/api/llama-init' {
                    # llama 编译方式（cpu/gpu）的初始化检测：
                    # 校验对应目录的 llama-server.exe 能跑、版本输出里探测后端。
                    # 检测通过才允许在面板上选中该模式。
                    if ($method -eq 'POST') {
                        try {
                            $body = Read-Body $ctx.Request | ConvertFrom-Json
                            $mode = [string]$body.mode
                            if ($mode -notin @('cpu','gpu')) { throw 'mode 必须是 cpu 或 gpu' }
                            $dirName = if ($mode -eq 'gpu') {
                                if ($Cfg.llamaGpuDir) { [string]$Cfg.llamaGpuDir } else { 'llama-gpu' }
                            } else {
                                if ($Cfg.llamaCpuDir) { [string]$Cfg.llamaCpuDir } else { 'llama' }
                            }
                            $srv = Join-Path $Root ($dirName.Trim('\') + '\llama-server.exe')
                            if (-not (Test-Path $srv)) {
                                Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J "没找到 $dirName\llama-server.exe。请先把 $mode 版编译文件放进 $dirName 文件夹再初始化。") + '}') -Code 400
                                break
                            }
                            # llama-server 把 --version 写到 stderr，直接 2>&1 在全局
                            # ErrorActionPreference=Stop 下会被当成异常抛出（报错内容
                            # 恰好是版本号）。这里临时放宽，只按退出码判断。
                            $oldEap = $ErrorActionPreference
                            $ErrorActionPreference = 'Continue'
                            $verOut = (& $srv --version 2>&1 | Out-String)
                            $verCode = $LASTEXITCODE
                            $ErrorActionPreference = $oldEap
                            if (-not $verOut -or $verCode -ne 0) { throw 'llama-server.exe --version 跑不起来，文件可能不完整' }
                            $backend = if ($verOut -match 'CUDA|Vulkan|HIP|SYCL') { 'gpu' } else { 'cpu' }
                            # 通过检测，把初始化时间和后端记进配置
                            $cur = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $init = @{}
                            try {
                                if ($cur.llamaInited) {
                                    foreach ($p in $cur.llamaInited.PSObject.Properties) { $init[$p.Name] = [string]$p.Value }
                                }
                            } catch { }
                            $init[$mode] = "$backend|$(Get-Date -Format 'yyyy-MM-dd HH:mm')"
                            $cur | Add-Member -NotePropertyName 'llamaInited' -NotePropertyValue ([pscustomobject]$init) -Force
                            [IO.File]::WriteAllText($CfgPath, ($cur | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
                            $script:Cfg = $cur
                            $msg = if ($backend -eq $mode) { "初始化通过（检测到 $($mode.ToUpper()) 后端）" }
                                   else { "初始化完成，但检测到的后端是 $backend，和 $mode 不一致，谨慎切换" }
                            Send-Text -Response $resp -Text ('{"ok":true,"msg":' + (J $msg) + ',"backend":' + (J $backend) + '}')
                        } catch {
                            Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J $_.Exception.Message) + '}') -Code 400
                        }
                    } else {
                        $init = [pscustomobject]@{}
                        try { if ($script:Cfg.llamaInited) { $init = $script:Cfg.llamaInited } } catch { }
                        $j = ($init | ConvertTo-Json -Compress)
                        if (-not $j -or $j -eq '{}') { $j = '{}' } else { if ($j -notmatch '^\{') { $j = '{}' } }
                        Send-Text -Response $resp -Text ('{"ok":true,"inited":' + $j + '}')
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

                '/api/jobs' {
                    # 自动化：GET 列表 + 最近日志；POST {action:'toggle'|'run', id}
                    if ($method -eq 'POST') {
                        $act = ''; $jid = ''
                        try {
                            $b = Read-Body $ctx.Request | ConvertFrom-Json
                            $act = ([string]$b.action).Trim().ToLower()
                            $jid = ([string]$b.id).Trim()
                        } catch { }
                        if (-not $jid) { Send-Text -Response $resp -Text '{"ok":false,"msg":"缺少 id"}' -Code 400; break }
                        $job = Get-JobById $jid
                        if (-not $job) { Send-Text -Response $resp -Text '{"ok":false,"msg":"没有这个任务"}' -Code 404; break }
                        if ($act -eq 'toggle') {
                            $nowOn = -not $job.enabled
                            $ok = Set-JobEnabled -Id $jid -Enabled $nowOn
                            Send-Text -Response $resp -Text ('{"ok":' + $(if ($ok) { 'true' } else { 'false' }) + ',"enabled":' + $(if ($nowOn) { 'true' } else { 'false' }) + '}')
                            break
                        }
                        if ($act -eq 'run') {
                            # 手动跑一次：无视 enabled，但仍走队列、优先级 8。
                            # 注意：这里绝不能回调自己的 /api/run —— 面板是单线程
                            # HttpListener，自己请求自己会把线程卡死（实测卡 10 秒超时）。
                            # 直接调进程内的 Add-QueueItem。
                            $finalTask = Get-JobTaskText $job
                            $item = Add-QueueItem -TaskText $finalTask -Priority ([int]$job.priority) -Mode $job.mode
                            $res = [pscustomobject]@{
                                ok   = $true
                                via  = 'panel'
                                msg  = ('已进队列（' + $item.id + '）')
                                task = $finalTask
                            }
                            Register-JobResult -Id $job.id -Result $res -Manual
                            Write-JobLog ('面板手动跑 ' + $job.id + '：' + $res.msg)
                            Send-Text -Response $resp -Text ('{"ok":true,"msg":' + (J $res.msg) + '}')
                            break
                        }
                        Send-Text -Response $resp -Text '{"ok":false,"msg":"未知 action"}' -Code 400
                        break
                    }
                    $snap = @(Get-JobsSnapshot)
                    $logs = @(Get-JobsLogTail -N 16)
                    $obj = [ordered]@{ ok = $true; jobs = $snap; log = $logs; at = (Get-Date -Format 'HH:mm:ss') }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $obj -Depth 6)
                }

                '/api/session' {
                    # 会话流：把 user / assistant 的轮次按时间顺序返回。
                    #
                    # 两个坑：
                    # ① 原来只取最后 40 行，会话一长就截掉前面的记录，
                    #    面板上看到的是"任务突然消失"。
                    # ② agent 正在往文件里追加内容时，Get-Content 可能读到
                    #    只写了一半的行，ConvertFrom-Json 失败后被我 catch 吞掉，
                    #    这一轮就少一条 —— 下一轮又读到了，于是"消失又出现"。
                    # 现在：用 FileShare.ReadWrite 显式共享读，跳过错行但记数，
                    # 并且把上限提到 200 行。
                    $sf = Join-Path $Root 'agent\logs\session.jsonl'
                    $list = New-Object System.Collections.ArrayList
                    if (Test-Path $sf) {
                        $lines = @()
                        try {
                            # 允许别处同时写（agent 在追加），不自锁也不被别人锁
                            $fs = [IO.File]::Open($sf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                            try {
                                $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                                $raw = $sr.ReadToEnd()
                            } finally { $fs.Close() }
                            $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
                        } catch { }

                        $take = @($lines | Select-Object -Last 300)
                        $bad = 0
                        foreach ($ln in $take) {
                            try { [void]$list.Add(($ln | ConvertFrom-Json)) }
                            catch { $bad++ }   # 半行就跳过，别让整批都挂掉
                        }
                        if ($bad -gt 0) { Write-Host ("  [session] 跳过 $bad 条不完整记录") -ForegroundColor DarkGray }
                    }
                    Send-Text -Response $resp -Text (ConvertTo-Json -InputObject $list.ToArray() -Depth 6 -Compress)
                }

                '/api/session/clear' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }

                    # 先停掉所有 agent 进程 —— 不只是面板自己启动的那些。
                    # 原来只杀 $Workers 里登记的，漏掉两类：
                    #   ① autopilot.ps1 派出去的任务（不在 $Workers 里）
                    #   ② 面板重启前留下的孤儿（$Workers 是新字典，空的）
                    # 漏掉的结果：点了「清除对话」界面上看着清了，
                    # 但那些进程还在往 session.jsonl 追加，而且下个任务启动时
                    # 会把旧内容当历史读回来 —— 就是「清除了还有旧对话，还污染新对话」。
                    # 按命令行匹配杀，宁可多杀也别漏。
                    $killed = 0
                    try {
                        foreach ($kp in @(Get-AgentProcessList)) {
                            $kcl = [string]$kp.CommandLine
                            if ($kcl -match 'agent\.ps1' -or $kcl -match 'autopilot\.ps1') {
                                try { Stop-Process -Id $kp.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ } catch { }
                            }
                        }
                    } catch { }
                    foreach ($slot in @($Workers.Keys)) {
                        try { $Workers[$slot] | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
                    }
                    $Workers.Clear()

                    $items = Get-Queue
                    foreach ($it in $items) {
                        if ($it.status -eq 'running') { $it.status = 'cancelled'; $it.result = '对话已清除' }
                    }
                    Save-Queue $items

                    # 等进程真的退出再清文件，否则它们退出前还会写最后一行
                    Start-Sleep -Milliseconds 500

                    $sf = Join-Path $Root 'agent\logs\session.jsonl'
                    try { [IO.File]::WriteAllText($sf, '', (New-Object Text.UTF8Encoding($false))) } catch { }
                    # 记一个「清除时间」。agent 启动读历史时会拿它做门槛，
                    # 只认晚于这个时间的记录 —— 兜住"进程杀不干净、清完又写了一行"的竞态。
                    try {
                        $genFile = Join-Path $Root 'agent\logs\session_gen.txt'
                        [IO.File]::WriteAllText($genFile, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), (New-Object Text.UTF8Encoding($false)))
                    } catch { }
                    # 流式记录也清，不然新对话开头会先冒出上一次的残字
                    try {
                        $stf = Join-Path $Root 'agent\stream.jsonl'
                        [IO.File]::WriteAllText($stf, '', (New-Object Text.UTF8Encoding($false)))
                    } catch { }
                    # 状态文件也一并删掉，面板上的任务卡才会消失
                    for ($sl = 1; $sl -le $WorkerCount; $sl++) {
                        $sf2 = Get-SlotStateFile $sl
                        try { if (Test-Path $sf2) { Remove-Item $sf2 -Force -ErrorAction SilentlyContinue } } catch { }
                    }
                    Send-Text -Response $resp -Text ('{"ok":true,"killed":' + $killed + '}')
                }


                # 模型服务状态：给面板轮询用。
                # 面板不能直接打 8080（跨域、超时不可控），而且「加载中」和「没起来」
                # 在 503 和连不上之间是两种完全不同的意思 —— 只看 503 会误报成挂了。
                '/api/llama' {
                    $lp = 8080
                    try { if ($Cfg.port) { $lp = [int]$Cfg.port } } catch { }
                    $up = $false; $loading = $false
                    try {
                        $null = Invoke-WebRequest ("http://127.0.0.1:$lp/health") -UseBasicParsing -TimeoutSec 3
                        $up = $true
                    } catch {
                        $code = 0
                        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
                        if ($code -eq 503) { $loading = $true; $up = $true }
                    }
                    Send-Text -Response $resp -Text ('{"up":' + $(if($up){'true'}else{'false'}) + ',"loading":' + $(if($loading){'true'}else{'false'}) + '}')
                }

                '/api/restart' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false}' -Code 405; break }
                    Send-Text -Response $resp -Text '{"ok":true,"msg":"正在重启模型服务"}'
                    # 必须先把旧进程杀掉。
                    # launcher.ps1 开头是 if (-not (Test-AiUp)) —— 端口还活着就直接
                    # 「服务已在运行」退出。结果 -fa / -ctk 这类只在启动时读的参数
                    # 改了等于没改，界面上开关拨了、配置也写进去了，进程还是老参数。
                    try {
                        Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
                            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    } catch { }
                    # 等端口真的放掉，再交棒给启动器；不然新进程会撞上还在监听的旧 socket
                    for ($wi = 0; $wi -lt 20; $wi++) {
                        $up = $false
                        $mp = 8080
                        try { if ($Cfg.port) { $mp = [int]$Cfg.port } } catch { }
                        try {
                            $tc = New-Object Net.Sockets.TcpClient
                            $tc.Connect('127.0.0.1', $mp)
                            $up = $true
                            $tc.Close()
                        } catch { $up = $false }
                        if (-not $up) { break }
                        Start-Sleep -Milliseconds 400
                    }
                    Start-Sleep -Milliseconds 300
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
                        $script:ProcCacheAt = [datetime]::MinValue
                        foreach ($pr in @(Get-AgentProcessList)) {
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

                # 一键启动模型服务。
                # 面板发现 8080 不通时，用户点一下横幅就走这里。
                # 走的是 launcher.ps1 —— 和双击 Nafx.bat 同一套逻辑
                # （先按当前可用内存算 context，再起 llama-server）。
                # -NoBrowser：面板已经开着，没必要再弹一个窗口。
                '/api/model/start' {
                    if ($method -ne 'POST') { Send-Text -Response $resp -Text '{"ok":false,"msg":"只接受 POST"}' -Code 405; break }
                    if (Test-ModelUp) {
                        Send-Text -Response $resp -Text '{"ok":true,"already":true}'
                        break
                    }
                    try {
                        $launcher = Join-Path $Root 'launcher.ps1'
                        if (-not (Test-Path $launcher)) {
                            Send-Text -Response $resp -Text '{"ok":false,"msg":"找不到 launcher.ps1"}' -Code 500
                            break
                        }
                        Start-Process -FilePath 'powershell.exe' `
                            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $launcher, '-NoBrowser') `
                            -WindowStyle Hidden
                        Write-PanelLog '按用户请求启动模型服务' 'INFO'
                        # 不等加载完（要 7-20 秒）。前端继续轮询 /api/system，
                        # 服务起来后横幅自己消失、状态灯自己变绿。
                        Send-Text -Response $resp -Text '{"ok":true,"starting":true}'
                    } catch {
                        Send-Text -Response $resp -Text ('{"ok":false,"msg":' + (J $_.Exception.Message) + '}') -Code 500
                    }
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
        # 以前这里一个字都不记，面板真死掉时日志里只有一行「面板启动」，
        # 到底是哪个请求、哪一行炸的完全查不到（只能按时间间隔猜它死过）。
        try { Write-PanelLog ('请求处理出错：' + $_.Exception.Message + '  @行 ' + $_.InvocationInfo.ScriptLineNumber) 'ERROR' } catch { }
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

# 走到这里 = 监听循环结束，面板要退出了。
# 以前是无声退出，日志里连一行都没有，只能靠「面板启动」的时间间隔猜它死过。
try { Write-PanelLog ('监听循环已结束，面板退出（PID ' + $PID + '）') 'ERROR' } catch { }