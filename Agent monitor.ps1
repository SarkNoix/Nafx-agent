# ============================================================
#  Nafx · Agent monitor（事件记录器）
#
#  不是仪表盘，而是把 Nafx 的变动按统一格式追加记录：
#    [时间][类型][来自]信息
#
#  类型：任务 / 模型 / 工具 / 完成 / 故障 / 警告 / 生命周期 / 状态 / 信息 / 系统 / 错误
#  来自：面板 / watchdog / agent / llama / 模型 / Agent monitor
#
#  记录原则（一个事件只记一条）：
#    - 面板收到任务 → agent 开始执行 → llama 每次请求 → agent 每一步工具 → 任务结束
#    - llama 的原始计时行合并成一行：输入、命中、等首字、生成
#    - agent 运行日志里的多行观察合并成一条
#    - 面板慢请求 3 秒以上才记，同一接口 30 秒内只记一次
#    - 看门狗的周期性内存提示 5 分钟只记一次
#    - 任务结束取自 history.jsonl 的最后一条（状态、步数、用时、结论）
#
#  记录文件：logs\Agent monitor.log（启动时超过 5 MB 则转存为 .1）
#  只记录启动之后新增的变动，不回放历史。
#  按 Q 退出；只记录，不启停服务。
# ============================================================

param(
    [switch]$Once,
    [switch]$Replay,
    [int]$Seconds = 0,
    [string]$RecordFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
try { $Host.UI.RawUI.WindowTitle = 'Agent monitor · Nafx 事件记录' } catch { }

$CfgPath = Join-Path $Root 'config.json'
$Cfg = $null
try { $Cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Cfg = $null }
if (-not $Cfg) { $Cfg = [pscustomobject]@{} }

function Get-CfgString([string]$Name, [string]$Default) {
    $v = [string]$Cfg.$Name
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

$script:HostName  = Get-CfgString 'host' '127.0.0.1'
$script:ProbeHost = if ($script:HostName -in @('0.0.0.0', '::', '[::]')) { '127.0.0.1' } else { $script:HostName }
$script:ModelPort = [int](Get-CfgString 'port' '8080')
$script:PanelPort = [int](Get-CfgString 'monitorPort' '8090')
$script:ModelUrl  = 'http://' + $script:ProbeHost + ':' + $script:ModelPort
$script:PanelUrl  = 'http://' + $script:ProbeHost + ':' + $script:PanelPort
$script:ModelMode = (Get-CfgString 'modelMode' 'local').ToLower()
$script:LlamaMode = (Get-CfgString 'llamaMode' 'cpu').ToLower()
$script:ModelLabel = Get-CfgString 'modelLabel' (Get-CfgString 'model' 'model')

$script:PanelLog   = Join-Path $Root 'logs\panel\panel.log'
$script:WatchLog   = Join-Path $Root 'logs\watchdog.log'
$script:WarmupLog  = Join-Path $Root 'logs\warmup.log'
$script:LlamaErr   = Join-Path $Root 'logs\server.err.log'
$script:LlamaOut   = Join-Path $Root 'logs\server.out.log'
$script:RunLogDir  = Join-Path $Root 'agent\logs'
$script:HistoryLog = Join-Path $script:RunLogDir 'history.jsonl'
$script:StateFile  = Join-Path $Root 'agent\state.json'
$script:PidFile    = Join-Path $Root 'agent\panel.pid'
if ($RecordFile) { $script:RecordPath = $RecordFile } else { $script:RecordPath = Join-Path $Root 'logs\Agent monitor.log' }

$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------- 运行中的状态 ----------
$script:Snapshot = $null
$script:WroteAny = $false
$script:LastGapAt = [datetime]::MinValue
$script:PanelStart = ''
$script:TaskStartedAt = [datetime]::MinValue
$script:LastHistory = ''
$script:LastLlamaLine = ''

# 当前任务
$script:CurrentTask = ''          # 面板发来、尚未结束的任务文本
$script:StartInfo = @{ Intent = ''; Tools = ''; Mode = ''; Exp = '' }
$script:LastAnswer = ''           # agent 的“完成：”，等归档行一起记
$script:LastAnswerAt = $null

# llama 请求（一次请求 = launch → 计时 → release）
$script:ReqSeq = 0
$script:Req = $null               # @{ TaskId; PromptTok; PromptMs; GenTok; GenMs }
$script:LastProgressTok = 0
$script:LlamaStart = $null
$script:LlamaStartPid = 0
$script:LlamaCtx = ''

# agent 运行日志
$script:RunFile = ''
$script:StepNum = 0
$script:StepTool = ''
$script:PendingObs = ''
$script:PendingObsSkip = $false

# 去重
$script:LastTaskText = ''
$script:LastTaskAt = $null
$script:SlowAt = @{}              # 面板慢请求：接口 → 上次记录时间
$script:MemAt = [datetime]::MinValue

# ---------- 基础函数 ----------
function Get-DisplayWidth([string]$Text) {
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { if ([int]$ch -ge 0x2E80) { $w += 2 } else { $w += 1 } }
    return $w
}

function Pad-Display([string]$Text, [int]$Width) {
    $pad = $Width - (Get-DisplayWidth $Text)
    if ($pad -le 0) { return $Text }
    return $Text + (' ' * $pad)
}

function Flatten([string]$Text) {
    $s = ([string]$Text).Replace([string][char]0, '').Trim()
    $s = $s -replace '[ \t]+', ' '
    $s = $s -replace '(\r\n|\n|\r)+', ' · '
    return $s.Trim()
}

function Cut([string]$Text, [int]$Max) {
    $s = Flatten $Text
    if ($s.Length -gt $Max) { return $s.Substring(0, $Max - 1) + '…' }
    return $s
}

function Add-Record {
    param(
        [datetime]$Time,
        [string]$Type,
        [string]$Source,
        [string]$Message,
        [switch]$NoGap
    )
    if ($null -eq $Time) { $Time = Get-Date }
    if ([string]::IsNullOrWhiteSpace($Type)) { $Type = '信息' }
    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = '-' }
    $msg = Flatten $Message
    if ($msg.Length -gt 2000) { $msg = $msg.Substring(0, 1999) + '…' }
    $stamp = $Time.ToString('yyyy-MM-dd HH:mm:ss')
    $line = '[' + $stamp + '][' + $Type + '][' + $Source + ']' + $msg

    # 每个任务前空一行，日志按任务分段
    if (-not $NoGap -and $script:WroteAny -and $Type -eq '任务' -and $Source -eq '面板' -and
        ($Time - $script:LastGapAt).TotalSeconds -gt 1) {
        try { [IO.File]::AppendAllText($script:RecordPath, "`r`n", $script:Utf8) } catch { }
        Write-Host ''
        $script:LastGapAt = $Time
    }

    try { [IO.File]::AppendAllText($script:RecordPath, $line + "`r`n", $script:Utf8) } catch { }
    $script:WroteAny = $true

    $color = 'Gray'
    switch ($Type) {
        '错误'     { $color = 'Red' }
        '故障'     { $color = 'Red' }
        '警告'     { $color = 'Yellow' }
        '任务'     { $color = 'Cyan' }
        '工具'     { $color = 'Green' }
        '完成'     { $color = 'Green' }
        '模型'     { $color = 'Blue' }
        '生命周期' { $color = 'Magenta' }
        '系统'     { $color = 'DarkGray' }
        '状态'     { $color = 'DarkCyan' }
        '信息'     { $color = 'White' }
        default    { $color = 'Gray' }
    }
    $pad = 6 - (Get-DisplayWidth $Type)
    $showType = $Type
    if ($pad -eq 2) { $showType = $Type + [string][char]0x3000 }
    $showType = Pad-Display $showType 6
    $showSrc = Pad-Display $Source 14
    $show = '[' + $stamp + '][' + $showType + '][' + $showSrc + ']' + $msg
    Write-Host $show -ForegroundColor $color
}

function Get-FileLength([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path) { return [long](Get-Item -LiteralPath $Path).Length }
    } catch { }
    return [long]0
}

function Read-NewLines {
    param(
        [string]$Path,
        [long]$Offset,
        [int]$MaxBytes = 1048576
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Lines = @(); Offset = [long]0 }
    }
    $len = Get-FileLength $Path
    if ($len -lt $Offset) { $Offset = [long]0 }
    if ($len -eq $Offset) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }
    $take = [int][Math]::Min([long]$MaxBytes, [long]($len - $Offset))
    $bytes = New-Object byte[] $take
    $read = 0
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $fs.Position = $Offset
        $read = $fs.Read($bytes, 0, $take)
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    if ($read -le 0) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }
    $lastNl = -1
    for ($i = 0; $i -lt $read; $i++) { if ($bytes[$i] -eq 10) { $lastNl = $i } }
    if ($lastNl -lt 0) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }
    $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $lastNl + 1)
    $text = $text.Replace([string][char]0xFEFF, '')
    $lines = @($text -split "`r`n|`n" | Where-Object { $_.Trim() -ne '' })
    return [pscustomobject]@{ Lines = $lines; Offset = [long]($Offset + $lastNl + 1) }
}

function Convert-ShortTime([string]$Text) {
    try {
        $year = (Get-Date).Year
        $dt = [datetime]::ParseExact(('{0}-{1}' -f $year, $Text), 'yyyy-MM-dd HH:mm:ss', $null)
        if ($dt -gt (Get-Date).AddDays(2)) { $dt = $dt.AddYears(-1) }
        return $dt
    } catch { return (Get-Date) }
}

# llama 日志的时间是从进程启动算的相对时间（分.秒.毫秒.微秒），换算成真实时间
function Convert-LlamaTime([string]$Rel) {
    if ($Rel -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)') {
        $p = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($p.Count -gt 0 -and $p[0].StartTime) {
            try { return $p[0].StartTime.AddSeconds([double]$matches[1] * 60 + [double]$matches[2] + [double]$matches[3] / 1000) } catch { }
        }
    }
    return (Get-Date)
}

# ---------- 任务 ----------
function Reset-TaskState {
    $script:StartInfo = @{ Intent = ''; Tools = ''; Mode = ''; Exp = '' }
    $script:LastAnswer = ''
    $script:LastAnswerAt = $null
    $script:ReqSeq = 0
    $script:Req = $null
    $script:StepNum = 0
    $script:StepTool = ''
    $script:PendingObs = ''
    $script:PendingObsSkip = $false
}

function Start-Task([datetime]$Time, [string]$Task) {
    $t = ([string]$Task).Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return }
    $delta = 9999
    if ($script:LastTaskAt) { $delta = ((Get-Date) - $script:LastTaskAt).TotalSeconds }
    if ($t -eq $script:LastTaskText -and $delta -lt 30) { return }
    if ($script:CurrentTask -and $script:LastAnswer) {
        Add-Record $script:LastAnswerAt '完成' 'agent' ('任务完成：' + (Cut $script:LastAnswer 160))
    }
    $script:LastTaskText = $t
    $script:LastTaskAt = Get-Date
    $script:CurrentTask = $t
    $script:TaskStartedAt = $Time
    Reset-TaskState
    Add-Record $Time '任务' '面板' ('收到任务：“' + (Cut $t 300) + '”')
}

function Finish-Task {
    $script:TaskStartedAt = [datetime]::MinValue
    $script:CurrentTask = ''
    Reset-TaskState
}

function Flush-StartInfo([datetime]$Time) {
    $i = $script:StartInfo
    if (-not ($i.Intent -or $i.Tools -or $i.Mode)) { return }
    $parts = @()
    if ($i.Intent) { $parts += '意图=' + $i.Intent }
    if ($i.Tools)  { $parts += $i.Tools }
    if ($i.Mode)   { $parts += '模式=' + $i.Mode }
    if ($i.Exp)    { $parts += $i.Exp }
    Add-Record $Time '任务' 'agent' ('开始执行：' + ($parts -join '，'))
    $script:StartInfo = @{ Intent = ''; Tools = ''; Mode = ''; Exp = '' }
}

function Flush-PendingObs {
    if ($script:PendingObs -and -not $script:PendingObsSkip) {
        Add-Record (Get-Date) '工具' 'agent' ('第 ' + $script:StepNum + ' 步 观察：' + (Cut $script:PendingObs 220))
    }
    $script:PendingObs = ''
    $script:PendingObsSkip = $false
}

# ---------- 面板 ----------
function Handle-PanelLine([string]$Line) {
    $line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line -match '^\[([^\]]+)\]\s*\[(INFO|WARN|ERROR)\]\s*(.*)$') {
        $t = Convert-ShortTime $matches[1]
        $level = $matches[2].ToUpper()
        $msg = $matches[3].Trim()
        if ($msg -match '^第\s*\d+\s*路启动\s*\[[^\]]+\]\s*(.*)$') {
            Start-Task $t $matches[1]
            return
        }
        if ($level -eq 'ERROR') {
            Add-Record $t '错误' '面板' $msg
            return
        }
        if ($level -eq 'WARN') {
            if ($msg -match '^慢请求\s+(\S+)\s+(\d+)\s*ms') {
                $path = $matches[1]
                $ms = [int]$matches[2]
                if ($ms -lt 5000) { return }
                if ($script:SlowAt.ContainsKey($path) -and ($t - $script:SlowAt[$path]).TotalSeconds -lt 120) { return }
                $script:SlowAt[$path] = $t
                Add-Record $t '警告' '面板' ('面板响应慢：' + $path + ' 用了 ' + $ms + ' ms（模型忙时正常）')
                return
            }
            Add-Record $t '警告' '面板' $msg
            return
        }
        if ($msg -match '^面板启动\s*(.*)$') {
            $script:PanelStart = $matches[1].Trim()
            return
        }
        if ($msg -match '^进程 PID\s+(\d+)') {
            $detail = $script:PanelStart
            $script:PanelStart = ''
            Add-Record $t '生命周期' '面板' ('面板启动：' + $detail + '，PID ' + $matches[1])
            return
        }
        if ($msg -match '端口 .* 被占用') {
            Add-Record $t '警告' '面板' '端口 8090 被占用，面板没有重复启动'
            return
        }
        return
    }
}

# ---------- 看门狗 ----------
function Handle-WatchdogLine([string]$Line) {
    $line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line -match '^\[([^\]]+)\]\s*(.*)$') {
        $t = Convert-ShortTime $matches[1]
        $msg = $matches[2].Trim()
        if ($msg -match '面板没有响应|面板挂起|面板无响应') {
            Add-Record $t '故障' 'watchdog' ('面板没有响应，' + ($msg -replace '^面板(没有响应|挂起|无响应)[，,：:]?\s*', ''))
            return
        }
        if ($msg -match '面板已恢复|面板恢复') {
            Add-Record $t '生命周期' 'watchdog' '面板已恢复'
            return
        }
        if ($msg -match '内存超阈值') {
            Add-Record $t '故障' 'watchdog' $msg
            return
        }
        if ($msg -match 'llama-server 已恢复') {
            Add-Record $t '生命周期' 'watchdog' $msg
            return
        }
        if ($msg -match '可用内存') {
            if (($t - $script:MemAt).TotalSeconds -lt 300) { return }
            $script:MemAt = $t
            Add-Record $t '警告' 'watchdog' $msg
            return
        }
        if ($msg -match '内存告警') {
            if ($msg -match '第\s*(\d+)\s*次') {
                $n = [int]$matches[1]
                if ($n -ne 1 -and ($n % 5) -ne 0) { return }
            }
            Add-Record $t '警告' 'watchdog' $msg
            return
        }
        if ($msg -match '冷却期内') { return }
        if ($msg -match '看门狗启动') {
            Add-Record $t '生命周期' 'watchdog' $msg
            return
        }
        Add-Record $t '状态' 'watchdog' $msg
        return
    }
}

# ---------- 模型预热 ----------
function Handle-WarmupLine([string]$Line) {
    $line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*(.*)$') {
        $t = Get-Date
        try { $t = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { }
        $msg = $matches[2].Trim()
        if ($msg -match '预热(.*)prompt_n=(\d+)\s+cache_n=(\d+)\s+用时\s*([\d.]+)\s*秒') {
            $how = (Flatten ($matches[1] -replace '[（）()]', '')).Trim()
            if ($how) { $how = '（' + $how + '）' }
            $recalc = [int]$matches[2] - [int]$matches[3]
            if ($recalc -lt 0) { $recalc = 0 }
            Add-Record $t '模型' '模型' ('模型预热完成' + $how + '：输入 ' + $matches[2] + ' tok，缓存里已有 ' + $matches[3] +
                '，要算 ' + $recalc + '，用时 ' + $matches[4] + ' 秒')
            return
        }
        Add-Record $t '模型' '模型' $msg
        return
    }
}

# ---------- llama ----------
function Get-ReqLabel {
    if ($script:CurrentTask) { return '第 ' + $script:ReqSeq + ' 次请求' }
    return '预热/面板外的请求'
}

function Handle-LlamaLine([string]$Line) {
    $msg = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($msg)) { return }
    if ($msg -eq $script:LastLlamaLine) { return }
    $script:LastLlamaLine = $msg

    # 相对时间 + 级别
    $rel = ''
    $lvl = 'I'
    $body = $msg
    if ($msg -match '^(\d+\.\d+\.\d+\.\d+)\s+([IWE])\s+(.*)$') {
        $rel = $matches[1]; $lvl = $matches[2]; $body = $matches[3]
    }
    $t = if ($rel) { Convert-LlamaTime $rel } else { Get-Date }

    # 启动噪声：系统信息、模型加载细节
    if ($body -match 'get_availabl|selected slot|n_past was set|need to evaluate at least|graph reallocs|graphs reused|total time|n_ctx_slot|print_info|llama_model_loader|load_tensors|common_init|srv init|sampler|system_info|main: |warming up|HTTP server is listening|server is listening|slot init: |slot new|launch_slot_: id -1|get_available_slot') {
        if ($body -match 'n_ctx_slot\s*=\s*(\d+)') { $script:LlamaCtx = $matches[1] }
        if ($body -match '(?i)error|failed|fatal') { Add-Record $t '错误' 'llama' $body }
        return
    }
    if ($body -match '(?i)(\berror\b|\bfailed\b|\bfatal\b|异常|too long|context shift|truncated = 1)') {
        Add-Record $t '错误' 'llama' $body
        return
    }
    if ($lvl -eq 'W') {
        Add-Record $t '警告' 'llama' $body
        return
    }

    # 生命周期
    if ($body -match 'model loaded') {
        $extra = ''
        if ($script:LlamaCtx) { $extra = '，上下文 ' + $script:LlamaCtx }
        Add-Record $t '生命周期' 'llama' ('模型加载完成' + $extra)
        return
    }
    if ($body -match 'listening on|server is listening|HTTP server listening') {
        Add-Record $t '生命周期' 'llama' ('llama 开始监听：' + $body)
        return
    }

    # 一次请求开始
    if ($body -match 'processing task') {
        if (((Get-Date) - $script:TaskStartedAt).TotalMinutes -gt 30) { Finish-Task }
        if ($script:CurrentTask) { $script:ReqSeq++ }
        $taskId = ''
        if ($body -match 'task\s+(-?\d+)') { $taskId = $matches[1] }
        $script:Req = @{ TaskId = $taskId; PromptTok = -1; PromptMs = 0; GenTok = 0; GenMs = 0; NTokens = 0 }
        $script:LastProgressTok = 0
        Add-Record $t '模型' 'llama' ((Get-ReqLabel) + '开始')
        return
    }

    # 输入处理进度（慢的时候让人知道在动）
    if ($body -match 'prompt processing, n_tokens =\s*(\d+), progress =\s*([\d.]+), t =\s*([\d.]+) s') {
        $n = [int]$matches[1]
        if ([double]$matches[3] -ge 10 -and $n - $script:LastProgressTok -ge 1000) {
            $script:LastProgressTok = $n
            Add-Record $t '模型' 'llama' ((Get-ReqLabel) + '：输入处理 ' + [int]([double]$matches[2] * 100) + '%（' + $n + ' tok，已 ' + [int][double]$matches[3] + ' 秒）')
        }
        return
    }

    # 计时行先收着，等 release 一起记
    if ($body -match 'prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens') {
        if ($script:Req) { $script:Req.PromptMs = [double]$matches[1]; $script:Req.PromptTok = [int]$matches[2] }
        return
    }
    if ($body -match '(?<!prompt )eval time =\s*([\d.]+) ms /\s*(\d+) tokens') {
        if ($script:Req) { $script:Req.GenMs = [double]$matches[1]; $script:Req.GenTok = [int]$matches[2] }
        return
    }
    if ($body -match 'stop processing: n_tokens =\s*(\d+)') {
        $n = [int]$matches[1]
        $r = $script:Req
        if ($r -and $r.PromptTok -ge 0) {
            $hit = $n - $r.PromptTok
            if ($hit -lt 0) { $hit = 0 }
            $parts = @('输入 ' + $n + ' tok，缓存命中 ' + $hit + '，重算 ' + $r.PromptTok,
                       '等首字 ' + ([Math]::Round($r.PromptMs / 1000, 1)) + ' 秒')
            if ($r.GenTok -gt 0) {
                $tps = if ($r.GenMs -gt 0) { [Math]::Round($r.GenTok * 1000 / $r.GenMs, 1) } else { 0 }
                $parts += '生成 ' + $r.GenTok + ' tok / ' + ([Math]::Round($r.GenMs / 1000, 1)) + ' 秒（' + $tps + ' tok/s）'
            } else {
                $parts += '没有生成'
            }
            Add-Record $t '模型' 'llama' ((Get-ReqLabel) + '结束：' + ($parts -join '，'))
        } else {
            Add-Record $t '模型' 'llama' ((Get-ReqLabel) + '结束，输入 ' + $n + ' tok')
        }
        $script:Req = $null
        $script:LastProgressTok = 0
        return
    }

    # 其余信息行不逐条照搬
    return
}

# ---------- agent 运行日志 ----------
# agent 自己打的标签（观察内容里的 “[文件] xxx” 这类不算，属于上一条观察的续行）
$script:AgentTags = '计时|空转|播报|精简 system|要求先想|要求先计划|裁历史|识别|代收尾|两级检索|省上下文|补参数|参数|去重'

function Test-KnownRunLine([string]$s) {
    return ($s -match '^(任务|意图|观察|完成|经验库|模式)\s*[:：]' -or
            $s -match '^\[\d+\]\s' -or
            $s -match ('^\[(' + $script:AgentTags + ')\]') -or
            $s -match '^(带上 \d+ 条|连续三次|出错了|到任务时限)')
}

function Handle-RunLine([string]$Line) {
    $msg = $Line.TrimEnd()
    $s = $msg.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return }
    $now = Get-Date

    # 观察的后续行（目录列表、文件内容、答案后半段）
    if ($script:PendingObs -or $script:PendingObsSkip) {
        if (-not (Test-KnownRunLine $s)) {
            if (-not $script:PendingObsSkip) { $script:PendingObs += "`n" + $s }
            return
        }
        Flush-PendingObs
    }

    if ($s -match '^任务[:：]\s*(.*)$') {
        if (-not $script:CurrentTask) {
            Start-Task $now $matches[1]
        }
        return
    }
    if ($s -match '^意图[:：]\s*([A-Za-z_]+)') {
        $script:StartInfo.Intent = $matches[1]
        return
    }
    if ($s -match '发\s*(\d+)\s*个工具（共\s*(\d+)\s*个）') {
        $script:StartInfo.Tools = '工具 ' + $matches[1] + '/' + $matches[2]
        return
    }
    if ($s -match '^带上\s*(\d+)\s*条以前的经验') {
        $script:StartInfo.Exp = '经验 ' + $matches[1] + ' 条'
        return
    }
    if ($s -match '^(套用|命中)流程') {
        $script:StartInfo.Tools = Cut $s 60
        return
    }
    if ($s -match '^模式[:：]\s*(.+)$') {
        $script:StartInfo.Mode = $matches[1].Trim()
        Flush-StartInfo $now
        return
    }

    # 一步：[N] 想法 -> 工具 参数  (N tok / Ns)
    if ($s -match '^\[(\d+)\]\s*(.*?)\s*->\s*([A-Za-z_]\w*)(?:\s+(.*?))?\s*(?:\((\d+)\s*tok\s*/\s*([\d.]+)s\))?\s*$') {
        $n = [int]$matches[1]
        $think = Flatten $matches[2]
        $tool = $matches[3]
        $arg = Flatten $matches[4]
        $tok = $matches[5]
        $sec = $matches[6]
        $script:StepNum = $n
        $script:StepTool = $tool
        $cost = ''
        if ($tok) { $cost = '（' + $tok + ' tok / ' + $sec + ' 秒）' }
        if ($tool -eq 'think') {
            if ($think) { Add-Record $now '工具' 'agent' ('第 ' + $n + ' 步 think' + $cost + '：' + (Cut $think 160)) }
            else { Add-Record $now '工具' 'agent' ('第 ' + $n + ' 步 think' + $cost) }
        } elseif ($tool -eq 'finish') {
            # 紧接着的“完成：”行会带完整回答，这里不重复记
        } else {
            $a = ''
            if ($arg) { $a = ' ' + (Cut $arg 100) }
            Add-Record $now '工具' 'agent' ('第 ' + $n + ' 步 ' + $tool + $a + $cost)
        }
        return
    }

    if ($s -match '^观察[:：]\s*(.*)$') {
        $script:PendingObsSkip = ($script:StepTool -eq 'think')
        $script:PendingObs = $matches[1].Trim()
        return
    }

    if ($s -match '^完成[:：]\s*(.*)$') {
        $script:LastAnswer = $matches[1].Trim()
        $script:LastAnswerAt = $now
        return
    }
    if ($s -match '^经验库[:：]') { return }

    # [标签] 行
    if ($s -match '^\[([^\]]{1,12})\]\s*(.*)$') {
        $tag = $matches[1]
        $rest = Flatten $matches[2]
        switch -Regex ($tag) {
            '^(精简 system|播报|两级检索|省上下文|补参数|参数|记忆)' { return }
            '^计时$' {
                if ($rest -match '第一次请求发出[:：]\s*([\d.]+)\s*秒') {
                    Add-Record $now '信息' 'agent' ('进程启动到发出第一次请求：' + $matches[1] + ' 秒')
                }
                return
            }
            '^空转$' {
                Add-Record $now '警告' 'agent' ('模型只说话没调工具（' + $rest + '）')
                return
            }
            '^(要求先想|要求先计划|裁历史)' {
                Add-Record $now '警告' 'agent' ($tag + '：' + (Cut $rest 200))
                return
            }
            default {
                if ($rest) { Add-Record $now '信息' 'agent' ($tag + '：' + (Cut $rest 200)) }
                return
            }
        }
    }

    if ($s -match '^(连续三次|出错了|到任务时限)') {
        Add-Record $now '警告' 'agent' (Cut $s 200)
        return
    }
    # 其余内部细节（project.md 没加载、注入速查表等）不记
}

# ---------- 归档（history.jsonl：一行一个任务的最终结果） ----------
function Handle-HistoryLine([string]$Line) {
    $line = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $h = $null
    try {
        if ($line.StartsWith('{') -and $line.EndsWith('}')) { $h = $line | ConvertFrom-Json }
    } catch { $h = $null }
    if (-not $h) {
        # 文件正在改写时读到半行，直接跳过
        return
    }
    $now = Get-Date
    $status = [string]$h.status
    $steps = if ($h.steps) { @($h.steps).Count } else { 0 }
    $elapsed = ''
    if ($h.elapsed) { $elapsed = '，用时 ' + [int][double]$h.elapsed + ' 秒' }
    $detail = Cut ([string]$h.summary) 160
    if (-not $detail) { $detail = Cut $script:LastAnswer 160 }
    if ($status -eq 'done') {
        if (-not $detail) { $detail = Cut ([string]$h.answer) 160 }
        Add-Record $now '完成' 'agent' ('任务完成：' + $steps + ' 步' + $elapsed + ' · ' + $detail)
    } else {
        Add-Record $now '故障' 'agent' ('任务未完成（' + $status + '）：' + $steps + ' 步' + $elapsed + ' · ' + $detail)
    }
    Finish-Task
}

# ---------- 进程与健康状态 ----------
function Get-LatestRunFile {
    $runs = @(Get-ChildItem -LiteralPath $script:RunLogDir -Filter 'run_*.txt' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($runs.Count -gt 0) { return $runs[0].FullName }
    return ''
}

function Get-PanelPid {
    try {
        if (Test-Path -LiteralPath $script:PidFile) {
            $n = 0
            if ([int]::TryParse((Get-Content -LiteralPath $script:PidFile -Raw).Trim(), [ref]$n)) { return $n }
        }
    } catch { }
    return 0
}

function Test-Url([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Get-Snapshot {
    $panel = Test-Url ($script:PanelUrl + '/')
    $model = 'down'
    if ($script:ModelMode -eq 'api') {
        $model = 'api'
    } elseif (Test-Url ($script:ModelUrl + '/health')) {
        $model = 'ok'
    }
    $llama = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    $llamaPids = @($llama | ForEach-Object { [string]$_.Id }) -join ','
    return [pscustomobject]@{
        Panel = [bool]$panel
        Model = $model
        LlamaCount = [int]$llama.Count
        LlamaPids = $llamaPids
        PanelPid = [int](Get-PanelPid)
    }
}

function Update-Status {
    $new = Get-Snapshot
    if ($null -eq $script:Snapshot) { $script:Snapshot = $new; return }
    $old = $script:Snapshot
    if ($new.Panel -ne $old.Panel) {
        if ($new.Panel) { Add-Record (Get-Date) '生命周期' '面板' '面板恢复响应' }
        else { Add-Record (Get-Date) '故障' '面板' '面板没有响应（健康检查失败）' }
    }
    if ($new.Model -ne $old.Model) {
        if ($new.Model -eq 'ok') { Add-Record (Get-Date) '生命周期' '模型' '模型服务恢复' }
        elseif ($new.Model -eq 'down') { Add-Record (Get-Date) '故障' '模型' '模型服务没有响应' }
    }
    if ($new.LlamaCount -ne $old.LlamaCount -or $new.LlamaPids -ne $old.LlamaPids) {
        if ($new.LlamaCount -gt 0) { Add-Record (Get-Date) '生命周期' 'llama' ('llama 进程启动，PID ' + $new.LlamaPids) }
        elseif ($old.LlamaCount -gt 0) { Add-Record (Get-Date) '故障' 'llama' ('llama 进程停止，原 PID ' + $old.LlamaPids) }
    }
    if ($new.PanelPid -ne $old.PanelPid) {
        if ($new.PanelPid -gt 0 -and $old.PanelPid -gt 0) {
            Add-Record (Get-Date) '生命周期' '面板' ('面板重启，PID ' + $old.PanelPid + ' → ' + $new.PanelPid)
        } elseif ($new.PanelPid -gt 0) {
            Add-Record (Get-Date) '生命周期' '面板' ('面板进程出现，PID ' + $new.PanelPid)
        } elseif ($old.PanelPid -gt 0) {
            Add-Record (Get-Date) '故障' '面板' ('面板进程消失，原 PID ' + $old.PanelPid)
        }
    }
    $script:Snapshot = $new
}

# 回放测试用：各日志只看最后 1 MB，输出写到临时文件，不碰真实记录
function Get-TestOffset([string]$Path) {
    if ($Replay) { return [long]([Math]::Max(0, (Get-FileLength $Path) - 1MB)) }
    return (Get-FileLength $Path)
}

# ---------- 主循环 ----------
function Scan-Logs {
    $r = Read-NewLines $script:PanelLog $script:Offsets.Panel
    $script:Offsets.Panel = $r.Offset
    foreach ($line in $r.Lines) { Handle-PanelLine $line }
    if ($script:PanelStart) {
        Add-Record (Get-Date) '生命周期' '面板' ('面板启动：' + $script:PanelStart)
        $script:PanelStart = ''
    }

    $r = Read-NewLines $script:WatchLog $script:Offsets.Watch
    $script:Offsets.Watch = $r.Offset
    foreach ($line in $r.Lines) { Handle-WatchdogLine $line }

    $r = Read-NewLines $script:WarmupLog $script:Offsets.Warmup
    $script:Offsets.Warmup = $r.Offset
    foreach ($line in $r.Lines) { Handle-WarmupLine $line }

    # run_*.txt：只跟最新一份（先读 agent，再读 llama，同一轮里顺序才是“任务 → 请求”）
    $latestRun = Get-LatestRunFile
    if ($latestRun -ne $script:RunFile) {
        $script:RunFile = $latestRun
        $script:Offsets.Run = [long]0
        $script:StepNum = 0
        $script:StepTool = ''
        $script:PendingObs = ''
        $script:PendingObsSkip = $false
    }
    if (-not $script:Replay) {
        $r = Read-NewLines $script:RunFile $script:Offsets.Run
        $script:Offsets.Run = $r.Offset
        foreach ($line in $r.Lines) { Handle-RunLine $line }
        Flush-PendingObs
    }

    $r = Read-NewLines $script:LlamaErr $script:Offsets.LlamaErr
    $script:Offsets.LlamaErr = $r.Offset
    foreach ($line in $r.Lines) { Handle-LlamaLine $line }

    $r = Read-NewLines $script:LlamaOut $script:Offsets.LlamaOut
    $script:Offsets.LlamaOut = $r.Offset
    foreach ($line in $r.Lines) { Handle-LlamaLine $line }

    if (-not $script:Replay) { Scan-History }
}

# history.jsonl 固定 200 条、每次整文件重写，按偏移读会读到半行。
# 改成只看文件最后一行：内容变了就是一条新归档。
function Get-TailCompleteLines([string]$Path, [int]$Bytes = 65536) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $len = Get-FileLength $Path
    $start = [long]0
    if ($len -gt $Bytes) { $start = $len - $Bytes }
    $take = [int]($len - $start)
    $buf = New-Object byte[] $take
    $read = 0
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $fs.Position = $start
        $read = $fs.Read($buf, 0, $take)
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    if ($read -le 0) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $text = $text.Replace([string][char]0xFEFF, '').TrimEnd([char[]]@("`r", "`n"))
    $lines = @($text -split "`r`n|`n")
    if ($start -gt 0 -and $lines.Count -gt 1) { $lines = @($lines | Select-Object -Skip 1) }
    return @($lines | Where-Object { $_.Trim() -ne '' })
}

function Scan-History {
    $ls = @(Get-TailCompleteLines $script:HistoryLog)
    if ($ls.Count -eq 0) { return }
    $last = [string]$ls[$ls.Count - 1]
    if ($last -eq $script:LastHistory) { return }
    # 文件还在写（整文件重写）就等下一轮，免得把半行当成最后一条
    $fi = Get-Item -LiteralPath $script:HistoryLog
    if ($fi -and ((Get-Date) - $fi.LastWriteTime).TotalSeconds -lt 2) { return }
    $script:LastHistory = $last
    Handle-HistoryLine $last
}

function Initialize-Recorder {
    $logDir = Split-Path -Parent $script:RecordPath
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    if (-not $Replay -and -not $RecordFile) {
        try {
            $big = Get-Item -LiteralPath $script:RecordPath
            if ($big.Length -gt 5MB) {
                $old = $script:RecordPath + '.1'
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
                Move-Item -LiteralPath $script:RecordPath -Destination $old -Force
            }
        } catch { }
    }

    $script:Offsets = @{
        Panel    = Get-TestOffset $script:PanelLog
        Watch    = Get-TestOffset $script:WatchLog
        Warmup   = if ($Replay) { [long]0 } else { Get-FileLength $script:WarmupLog }
        LlamaErr = Get-TestOffset $script:LlamaErr
        LlamaOut = Get-TestOffset $script:LlamaOut
        History  = Get-TestOffset $script:HistoryLog
        Run      = [long]0
    }
    $script:RunFile = Get-LatestRunFile
    if ($script:Replay) {
        $r = Read-NewLines $script:RunFile ([long]0) 4194304
        foreach ($line in $r.Lines) { Handle-RunLine $line }
        Flush-PendingObs
        if ($script:RunFile) { $script:Offsets.Run = Get-FileLength $script:RunFile }
    } elseif ($script:RunFile) {
        $script:Offsets.Run = Get-FileLength $script:RunFile
    }

    $hl = @(Get-TailCompleteLines $script:HistoryLog)
    if ($hl.Count -gt 0) {
        $script:LastHistory = [string]$hl[$hl.Count - 1]
        if ($Replay) { Handle-HistoryLine $script:LastHistory }
    }

    $snapshot = Get-Snapshot
    $script:Snapshot = $snapshot
    if (-not $Replay) {
        $panelText = if ($snapshot.Panel) { '在线' } else { '无响应' }
        $modelText = if ($snapshot.Model -eq 'ok') { '正常' } elseif ($snapshot.Model -eq 'api') { '接口模式' } else { '无响应' }
        $llamaText = if ($snapshot.LlamaCount -gt 0) { 'PID ' + $snapshot.LlamaPids } else { '未运行' }
        $panelPid = if ($snapshot.PanelPid -gt 0) { '，PID ' + $snapshot.PanelPid } else { '' }
        Add-Record (Get-Date) '系统' 'Agent monitor' ('启动记录，只记录从现在起的变动 → ' + $script:RecordPath)
        Add-Record (Get-Date) '状态' 'Agent monitor' ('面板=' + $panelText + $panelPid + '，模型=' + $script:ModelLabel + '（' + $script:ModelMode + '）' + $modelText +
            '，llama=' + $llamaText)
    }
}

if ($Once) {
    Initialize-Recorder
    Scan-Logs
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\NafxAgentMonitorRecorder')
$locked = $false
try {
    if (-not $mutex.WaitOne(0)) { exit 0 }
    $locked = $true
    Write-Host ''
    Write-Host '  Agent monitor · Nafx 事件记录' -ForegroundColor Cyan
    Write-Host ('  记录文件：' + $script:RecordPath) -ForegroundColor DarkGray
    Write-Host '  按 Q 退出；只记录，不启停服务。' -ForegroundColor DarkGray
    Write-Host ''
    Initialize-Recorder
    $running = $true
    $lastStatus = Get-Date
    $stopAt = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
    while ($running -and (Get-Date) -lt $stopAt) {
        Scan-Logs
        if (((Get-Date) - $lastStatus).TotalSeconds -ge 3) {
            Update-Status
            $lastStatus = Get-Date
        }
        for ($i = 0; $i -lt 10; $i++) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') { $running = $false; break }
                }
            } catch { }
            Start-Sleep -Milliseconds 100
        }
    }
    Add-Record (Get-Date) '系统' 'Agent monitor' '停止记录'
} catch {
    Add-Record (Get-Date) '错误' 'Agent monitor' ('记录器出错：' + $_.Exception.Message)
    Write-Host '  按 Enter 关闭' -ForegroundColor DarkGray
    [void](Read-Host)
} finally {
    if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
