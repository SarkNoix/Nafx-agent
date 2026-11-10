# ============================================================
#  Nafx · 本地 AI 智能体
#  模型：Qwen3-4B（llama.cpp 本地推理）
#  用标准 function calling 调工具，能读写文件、跑 cmd/ps1、上网查
#
#  设计取向（v4）：
#   · 意图路由：先判断任务类型，只给相关的工具子集，模型不容易选错
#   · 软约束：只做技术性修复（JSON 转义），不纠正模型的"想法"
#   · 无兜底：不预判任务、不自动生成脚本、不替模型做决定
#   · 唯一硬保护：连续空转 3 次就收尾，避免烧步数
# ============================================================

param(
    [string]$Task = '',
    [int]$MaxSteps = 0,
    [switch]$ShowRaw
)

$ErrorActionPreference = 'Stop'

$AgentDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root     = Split-Path -Parent $AgentDir
# 配置文件名优先取环境变量（面板启动 agent 时会传），默认 config.json
$cfgName  = if ($env:NAFX_CONFIG) { [string]$env:NAFX_CONFIG } else { 'config.json' }
$cfgPath  = if ([IO.Path]::IsPathRooted($cfgName)) { $cfgName } else { Join-Path $Root $cfgName }
$Cfg      = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $Task) { $Task = [string]$env:NAFX_TASK }
if (-not $Task) { $Task = '你好' }
if ($MaxSteps -le 0) { $MaxSteps = [int]$Cfg.maxSteps }

$Api       = "http://$($Cfg.host):$($Cfg.port)"
$Workspace = if ([IO.Path]::IsPathRooted([string]$Cfg.workspace)) { [string]$Cfg.workspace } else { Join-Path $Root ([string]$Cfg.workspace) }
$LogDir    = Join-Path $AgentDir 'logs'
$StateFile = if ($env:NAFX_STATE) { $env:NAFX_STATE } else { Join-Path $AgentDir 'state.json' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

$TaskText = $Task.Trim()
$logFile  = Join-Path $LogDir ("run_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$clock    = [Diagnostics.Stopwatch]::StartNew()

# 载入工具实现
. (Join-Path $AgentDir 'tools.ps1')
# 载入流程模板
$FlowsLoaded = $false
try {
    . (Join-Path $AgentDir 'flows.ps1')
    Set-FlowsPath (Join-Path $AgentDir 'flows.json')
    $FlowsLoaded = ($script:Flows.Count -gt 0)
} catch { Write-Log ('  流程模板加载失败：' + $_.Exception.Message) }

# 载入经验记忆
$MemoryLoaded = $false
try {
    . (Join-Path $AgentDir 'memory.ps1')
    Set-MemoryDir (Join-Path $AgentDir 'memory')
    $MemoryLoaded = $true
} catch { Write-Log ('  经验记忆加载失败：' + $_.Exception.Message) }
Set-AiRoot -Path $Workspace -TimeoutSeconds ([int]$Cfg.stepTimeoutSeconds) -MaxOutput ([int]$Cfg.maxOutputChars) -AllowAnyPath:([bool]$Cfg.allowAnyPath)
Initialize-AiWorkspace

$SystemPrompt   = Get-Content (Join-Path $AgentDir 'prompt.md') -Raw -Encoding UTF8
# 渐进式：做项目才加载 project.md，平常不占上下文
$ProjectPrompt  = ''
try {
    $projPath = Join-Path $AgentDir 'project.md'
    if (Test-Path $projPath) { $ProjectPrompt = Get-Content $projPath -Raw -Encoding UTF8 }
} catch { }
$ToolsSchemaRaw = (Get-Content (Join-Path $AgentDir 'tools-schema.json') -Raw -Encoding UTF8).Trim()

# 把 schema 按工具名拆开，路由时只发相关的几个
$script:ToolSchemaMap = @{}
try {
    foreach ($s in ($ToolsSchemaRaw | ConvertFrom-Json)) {
        $n = [string]$s.function.name
        if ($n) { $script:ToolSchemaMap[$n] = (ConvertTo-Json -InputObject $s -Depth 10 -Compress) }
    }
} catch { }

$SessionFile = Join-Path $LogDir 'session.jsonl'
$HistFile    = Join-Path $LogDir 'history.jsonl'

# ============================================================
#  基础工具
# ============================================================

function To-JsonStr {
    param([string]$s)
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

function Write-Log {
    param([string]$Text)
    try { Add-Content -Path $logFile -Value $Text -Encoding UTF8 } catch { }
}

# 状态文件。面板按这个渲染，字段名不能随便改。
function Write-State {
    param($St)
    try {
        $json = $St | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($StateFile, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# 只修技术性的转义损坏，不改模型的意思。
# 例："data\resources\x" 在 JSON 里会被吃成带回车的东西。
function Repair-ActionStrings {
    param($Act)
    foreach ($f in @('path', 'find', 'replace', 'command')) {
        $v = [string]$Act.$f
        if (-not $v) { continue }
        $v = $v -replace '\\([a-zA-Z])', '\$1'
        $v = $v -replace "`r", ''
        $Act | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force
    }
    # content 保留原样（里面的 \n 是模型想要的换行）
    return $Act
}

# ============================================================
#  意图路由
#  目的：任务简单时别给 19 个工具，模型反而挑得准。
# ============================================================

function Get-Intent {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return 'operate' }

    # 纯闲聊
    if ($t.Length -le 14 -and $t -match '^(你好|您好|hi|hello|嘿|在吗|在不在|谢谢|多谢|哈哈|嗯+|哦+|好的|收到|ok|OK)') { return 'chat' }
    # 写东西
    if ($t -match '写一个|写个|做个|做一个|实现一个|实现|开发|帮我写|生成一个|小项目|写段|写一个.*脚本') { return 'build' }
    # 查资料
    if ($t -match '怎么用|怎样用|是什么|有哪些|参数|用法|文档|区别|什么意思|查一下|搜一下') { return 'query' }
    # 算数统计
    if ($t -match '多少|几个|几次|几条|统计|计算|求和|总和|平均|汇总|占比|排序|最大|最小') { return 'analyze' }
    return 'operate'
}

function Get-ToolNamesFor {
    param([string]$Intent)
    switch ($Intent) {
        'chat'    { return @('say', 'finish') }
        'query'   { return @('syshelp', 'help', 'win_doc', 'web_search', 'web_fetch', 'say', 'finish') }
        'build'   { return @('plan', 'write_file', 'read_file', 'replace_in_file', 'run_ps1', 'run_cmd', 'list_dir', 'make_dir', 'say', 'finish') }
        'analyze' { return @('list_dir', 'read_file', 'run_cmd', 'run_ps1', 'write_file', 'say', 'finish') }
        default   { return @('plan', 'list_dir', 'read_file', 'write_file', 'append_file', 'replace_in_file', 'make_dir', 'delete_path', 'run_cmd', 'run_ps1', 'run_bat', 'syshelp', 'help', 'say', 'finish') }
    }
}

function Get-ToolsJsonFor {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return $ToolsSchemaRaw }
    $parts = @()
    foreach ($n in $Names) {
        if ($script:ToolSchemaMap.ContainsKey($n)) { $parts += $script:ToolSchemaMap[$n] }
    }
    if ($parts.Count -eq 0) { return $ToolsSchemaRaw }
    return ('[' + ($parts -join ',') + ']')
}

# finish 不在 tools.ps1 里，它是收尾信号，由 agent 自己处理。
# 这里把 finish 的 schema 补进去（如果在子集里）。
function Get-ToolsJsonWithFinish {
    param([string[]]$Names)
    $json = Get-ToolsJsonFor -Names $Names
    # 通用工具：不管套哪个流程都得有，否则模型没法收尾、没法问人、没法重来。
    # 以前只加了 finish，结果 say 和 rethink 永远发不出去——
    # 信息不够时它只能瞎猜，走偏了也只能硬着头皮往下走。
    foreach ($name in @('finish', 'say', 'rethink')) {
        if ($json -match ('"name":"' + $name + '"')) { continue }
        $sc = $script:ToolSchemaMap[$name]
        if (-not $sc) { continue }
        if ($json -eq '[]' -or [string]::IsNullOrWhiteSpace($json)) { $json = '[' + $sc + ']' }
        else { $json = $json.TrimEnd(']') + ',' + $sc + ']' }
    }
    return $json
}

# ============================================================
#  会话
# ============================================================

function Get-SessionHistory {
    param([int]$MaxTurns = 2, [int]$MaxCharsPerMsg = 180)
    $out = @()
    if (-not (Test-Path $SessionFile)) { return $out }
    try {
        $lines = @(Get-Content $SessionFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    } catch { return $out }
    if ($lines.Count -eq 0) { return $out }

    $take = @($lines | Select-Object -Last ($MaxTurns * 2))
    foreach ($l in $take) {
        try {
            $o = $l | ConvertFrom-Json
            $role = [string]$o.role
            $content = [string]$o.content
            if (-not $content) { continue }
            if ($role -notin @('user', 'assistant')) { continue }
            if ($content.Length -gt $MaxCharsPerMsg) { $content = $content.Substring(0, $MaxCharsPerMsg) + '…' }
            $out += @{ role = $role; content = $content }
        } catch { }
    }
    return $out
}

function Add-SessionTurn {
    param([string]$Role, [string]$Content, [bool]$Ok = $true, [array]$Files = @(), [string]$Raw = '')
    try {
        $clean = ($Content -replace '\s+', ' ').Trim()
        if ($clean.Length -gt 500) { $clean = $clean.Substring(0, 500) + '…' }
        if ($Raw.Length -gt 4000) { $Raw = $Raw.Substring($Raw.Length - 4000) }
        $fileJson = (($Files | Where-Object { $_ -and $_ -match '\.\w{1,5}$' } | Select-Object -Unique | ForEach-Object { To-JsonStr $_ }) -join ',')
        $line = '{"role":' + (To-JsonStr $Role) +
                ',"content":' + (To-JsonStr $clean) +
                ',"ts":' + (To-JsonStr (Get-Date -Format 'MM-dd HH:mm:ss')) +
                ',"ok":' + $(if ($Ok) { 'true' } else { 'false' }) +
                ',"files":[' + $fileJson + ']' +
                ',"raw":' + (To-JsonStr $Raw) + '}'
        Add-Content -Path $SessionFile -Value $line -Encoding UTF8

        $all = @(Get-Content $SessionFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
        if ($all.Count -gt 60) {
            [IO.File]::WriteAllLines($SessionFile, @($all | Select-Object -Last 60), (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
}

# 把一步动作翻译成 function calling 的 assistant 回合。
# 主循环靠这个让模型看到"自己刚才调了什么"，不然它会把同一件事反复做。
function Format-ToolCallMessage {
    param($Act, [string]$CallId)

    $tool = [string]$Act.tool
    $args = [ordered]@{}

    if ($tool -eq 'say') {
        $v = [string]$Act.message; if (-not $v) { $v = [string]$Act.content }
        $args['message'] = $v
    }
    elseif ($tool -eq 'rethink') {
        $v = [string]$Act.reason; if (-not $v) { $v = [string]$Act.think }
        $args['reason'] = $v
    }
    elseif ($tool -eq 'plan') {
        $v = [string]$Act.steps; if (-not $v) { $v = [string]$Act.content }
        $args['steps'] = $v
    }
    elseif ($tool -eq 'finish') {
        $args['answer'] = [string]$Act.answer
    }
    elseif ($tool -in @('run_cmd', 'syshelp', 'win_doc', 'help', 'web_search')) {
        $args['command'] = [string]$Act.command
    }
    elseif ($tool -eq 'web_fetch') {
        $args['path'] = [string]$Act.path
    }
    elseif ($tool -eq 'replace_in_file') {
        $args['path'] = [string]$Act.path
        $args['find'] = [string]$Act.find
        $args['replace'] = [string]$Act.replace
    }
    elseif ($tool -in @('read_file', 'list_dir', 'make_dir', 'delete_path', 'run_ps1', 'run_bat')) {
        $args['path'] = [string]$Act.path
    }
    else {
        $args['path'] = [string]$Act.path
        $args['content'] = [string]$Act.content
    }

    $argJson = '{'
    $first = $true
    foreach ($k in $args.Keys) {
        if (-not $first) { $argJson += ',' }
        $argJson += (To-JsonStr $k) + ':' + (To-JsonStr ([string]$args[$k]))
        $first = $false
    }
    $argJson += '}'

    if ([string]::IsNullOrWhiteSpace($CallId)) { $CallId = 'call_' + [Guid]::NewGuid().ToString('N').Substring(0,16) }

    return [pscustomobject]@{
        role            = 'assistant'
        content         = [string]$Act.think
        tool_calls_json = '[{"id":' + (To-JsonStr $CallId) + ',"type":"function","function":{"name":' + (To-JsonStr $tool) + ',"arguments":' + (To-JsonStr $argJson) + '}}]'
        call_id         = $CallId
    }
}

# ============================================================
#  计划清单
# ============================================================

function Format-PlanList {
    param($Steps)
    if (-not $Steps -or $Steps.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('【任务清单】（做完一步自动打勾，只写还没做的）')
    $i = 0
    foreach ($s in $Steps) {
        $i++
        $mark = if ($s.done) { '[x]' } else { '[ ]' }
        [void]$sb.AppendLine(("{0} {1}. {2}" -f $mark, $i, $s.text))
    }
    return $sb.ToString().TrimEnd()
}

function Set-PlanStepDone {
    param($Plan)
    if (-not $Plan) { return $Plan }
    foreach ($p in $Plan) { if (-not $p.done) { $p.done = $true; break } }
    return $Plan
}

function Format-DoneList {
    param($Steps)
    if (-not $Steps -or $Steps.Count -eq 0) { return '（还没做任何事）' }
    $lines = @()
    foreach ($s in $Steps) {
        if ($s.tool -eq 'finish' -or $s.tool -eq 'check') { continue }
        $ok = if ($s.ok -eq $false) { '×' } else { '·' }
        $note = [string]$s.note
        if ($note.Length -gt 90) { $note = $note.Substring(0, 90) + '…' }
        $lines += ("{0} {1}. {2} {3}" -f $ok, $s.n, $s.tool, $note)
    }
    if ($lines.Count -eq 0) { return '（还没做任何事）' }
    return (($lines | Select-Object -Last 12) -join "`n")
}

# ============================================================
#  模型调用
# ============================================================

function Invoke-Model {
    param([array]$Messages, [string]$ToolsJson = '', [switch]$ForceTool, [switch]$ForceFinish, [int]$MaxTokens = 0)

    $msgJson = foreach ($m in $Messages) {
        $role = [string]$m.role
        if ($role -eq 'assistant' -and $m.tool_calls_json) {
            '{"role":"assistant","content":' + (To-JsonStr ([string]$m.content)) +
            ',"tool_calls":' + [string]$m.tool_calls_json + '}'
        } elseif ($role -eq 'tool') {
            '{"role":"tool","tool_call_id":' + (To-JsonStr ([string]$m.tool_call_id)) +
            ',"content":' + (To-JsonStr ([string]$m.content)) + '}'
        } else {
            '{"role":' + (To-JsonStr $role) + ',"content":' + (To-JsonStr ([string]$m.content)) + '}'
        }
    }

    if (-not $ToolsJson) { $ToolsJson = $ToolsSchemaRaw }
    $choice = if ($ForceTool) { '"required"' } else { '"auto"' }

    $jsonBody = '{"model":"qwen","messages":[' + ($msgJson -join ',') + ']' +
                ',"temperature":' + ([string]$Cfg.temperature) +
                ',"top_p":' + ([string]$Cfg.topP) +
                ',"max_tokens":' + $(if ($MaxTokens -gt 0) { $MaxTokens } else { [int]$Cfg.maxTokens }) +
                ',"tools":' + $ToolsJson +
                ',"tool_choice":' + $choice + '}'
    $bytes = [Text.Encoding]::UTF8.GetBytes($jsonBody)

    # 偶发的慢不该让整个任务失败，给一次重试机会
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $resp = Invoke-WebRequest "$Api/chat/completions" -Method Post `
                -ContentType 'application/json; charset=utf-8' -Body $bytes `
                -UseBasicParsing -TimeoutSec ([int]$Cfg.stepTimeoutSeconds)
            break
        } catch {
            if ($attempt -ge 2) { throw }
            Write-Log ("  模型响应超时，重试一次：" + $_.Exception.Message)
            Start-Sleep -Seconds 2
        }
    }
    $sw.Stop()

    $obj = $resp.Content | ConvertFrom-Json
    $msg = $obj.choices[0].message

    $calls = @()
    if ($msg.tool_calls) {
        foreach ($tc in @($msg.tool_calls)) {
            $calls += [pscustomobject]@{
                id        = [string]$tc.id
                name      = [string]$tc.function.name
                arguments = [string]$tc.function.arguments
            }
        }
    }

    # ---- 兼容 xLAM 这类「工具调用写在正文里」的模型 ----
    # 它的模板要求输出纯文本 JSON 数组：
    #   [{"name":"write_file","arguments":{"path":"a.txt","content":"hi"}}]
    # llama.cpp 不会把它解析成 tool_calls，所以这里补一层。
    # 防误判：必须能解析成数组，每个元素有 name，且 name 是已注册的工具。
    if ($calls.Count -eq 0 -and $msg.content) {
        $txt = [string]$msg.content
        $lb = $txt.IndexOf('[')
        $rb = $txt.LastIndexOf(']')
        if ($lb -ge 0 -and $rb -gt $lb) {
            $cand = $txt.Substring($lb, $rb - $lb + 1)
            try {
                # 坑：PowerShell 5.1 里 @($json | ConvertFrom-Json) 会把整个数组再包一层，
                # Count 变成 1。必须先判断类型，是数组就直接用，不是才包成单元素数组。
                $parsedJson = $cand | ConvertFrom-Json
                $arr = @()
                if ($parsedJson -is [array]) { $arr = $parsedJson } else { $arr = @($parsedJson) }
                $parsed = @()
                $good = $true
                foreach ($a in $arr) {
                    $nm = [string]$a.name
                    if (-not $nm) { $good = $false; break }
                    if (-not $script:ToolSchemaMap.ContainsKey($nm)) { $good = $false; break }
                    $argJson = ''
                    if ($null -ne $a.arguments) {
                        $argJson = ConvertTo-Json -InputObject $a.arguments -Depth 8 -Compress
                    }
                    $parsed += [pscustomobject]@{
                        id        = 'call_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
                        name      = $nm
                        arguments = $argJson
                    }
                }
                if ($good -and $parsed.Count -gt 0) { $calls = $parsed }
            } catch { }
        }
    }

    return [pscustomobject]@{
        content   = [string]$msg.content
        calls     = $calls
        raw_calls = $(if ($msg.tool_calls) { ConvertTo-Json -InputObject @($msg.tool_calls) -Depth 8 -Compress } elseif ($calls.Count -gt 0) { ConvertTo-Json -InputObject @($calls) -Depth 8 -Compress } else { '' })
        tokens    = $obj.usage.completion_tokens
        seconds   = $sw.Elapsed.TotalSeconds
    }
}

# 模型服务活着吗？3 秒就能判断出来，不用等 180 秒超时。
function Test-ModelAlive {
    param([int]$TimeoutSec = 3)
    try {
        $r = Invoke-WebRequest "$Api/health" -UseBasicParsing -TimeoutSec $TimeoutSec
        return ($r.StatusCode -eq 200 -and $r.Content -match 'ok')
    } catch {
        return $false
    }
}

# 卡死就干脆收尾，别让用户干等
function Close-AsStuck {
    param($State, [string]$Reason, [int]$StepCount)
    $State.status = 'stuck'
    $State.phase = '会话卡死'
    $State.elapsed = $clock.Elapsed.TotalSeconds
    $State.answer = "会话卡死了：$Reason"
    $State.summary = "会话卡死：$Reason。已经做的事都记在下面的步骤里。"
    Write-State $State
    Write-Log ("  [卡死] $Reason")
    Write-Closing -State $State -Status 'stuck' -Summary $State.summary -StepCount $StepCount
}

# 闲聊：不调工具，纯对话
function Invoke-ChatTask {
    param([string]$Text)
    $sys = $SystemPrompt + "`n`n（现在是闲聊，不用调工具。像朋友那样回一两句，轻松点，别端着。）"
    $msgs = @('{"role":"system","content":' + (To-JsonStr $sys) + '}')
    foreach ($h in (Get-SessionHistory -MaxTurns 2)) {
        $msgs += '{"role":' + (To-JsonStr $h.role) + ',"content":' + (To-JsonStr $h.content) + '}'
    }
    $msgs += '{"role":"user","content":' + (To-JsonStr $Text) + '}'

    $body = '{"model":"qwen","messages":[' + ($msgs -join ',') +
            '],"temperature":0.8,"top_p":0.9,"max_tokens":300}'
    try {
        $resp = Invoke-WebRequest "$Api/chat/completions" -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 180
        $reply = [string](($resp.Content | ConvertFrom-Json).choices[0].message.content)
    } catch {
        $reply = '我这边没答上来，稍后再试一次。'
    }
    if ([string]::IsNullOrWhiteSpace($reply)) { $reply = '嗯，我在。' }

    Add-SessionTurn -Role 'user' -Content $Text -Ok $true
    Add-SessionTurn -Role 'assistant' -Content $reply -Ok $true

    $st = [pscustomobject]@{
        status = 'done'; task = $Text; steps = @(); step = 1; maxSteps = 1
        elapsed = $clock.Elapsed.TotalSeconds; model = [string]$Cfg.modelLabel
        workspace = [string]$Cfg.workspace; answer = $reply; summary = $reply
        plan = ''; logFile = $logFile; slot = 1
    }
    Write-State $st

    Write-Host ''
    Write-Host ('  ' + $reply) -ForegroundColor Gray
    Write-Host ''
    return
}

# ============================================================
#  收尾
# ============================================================

function Get-Summary {
    param($Steps, [string]$Status, [string]$TaskText)
    if ($Status -eq 'done') {
        $acts = @($Steps | Where-Object { $_.tool -and $_.tool -notin @('finish', 'check', 'plan', 'say', 'rethink') })
        if ($acts.Count -eq 0) { return '搞定。' }
        return ("做了 {0} 步：" -f $acts.Count) + (($acts | Select-Object -Last 3 | ForEach-Object { $_.tool }) -join '、')
    }
    return '出错了。'
}

function Write-Closing {
    param($State, [string]$Status, [string]$Summary, [int]$StepCount)
    $color = if ($Status -eq 'done') { 'Green' } else { 'Red' }
    $mark  = if ($Status -eq 'done') { '√ 完成' } else { '× 出错了' }
    Write-Host ''
    Write-Host ('  ' + $mark) -ForegroundColor $color

    $answer = [string]$State.answer
    if ($answer) {
        Write-Host ('    ' + $answer) -ForegroundColor Gray
    }

    # 正文：把做过的动作列一遍，让人看到经过
    $acts = @($State.steps | Where-Object { $_.tool -and $_.tool -notin @('finish', 'check') })
    if ($acts.Count -gt 0) {
        Write-Host ''
        Write-Host '    【正文】这一趟的经过：' -ForegroundColor DarkGray
        foreach ($s in $acts) {
            $okMark = if ($s.ok -eq $false) { '×' } else { '·' }
            $c = if ($s.ok -eq $false) { 'Red' } else { 'DarkGray' }
            Write-Host ("      {0} {1}. {2} {3}" -f $okMark, $s.n, $s.tool, $s.arg) -ForegroundColor $c
        }
    }

    if ($Summary) {
        Write-Host ''
        Write-Host '    【成果】' -ForegroundColor DarkGray
        Write-Host ('      ' + $Summary) -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host ("    用时 {0:N0} 秒，共 {1} 步" -f $State.elapsed, $StepCount) -ForegroundColor DarkGray
    Write-Host ("    日志：{0}" -f $logFile) -ForegroundColor DarkGray
    Write-Host ''
}

# ============================================================
#  主流程
# ============================================================

$intent = Get-Intent -Text $TaskText
# 放开：19 个工具全给它，让模型自己判断该用哪个。
# 意图只用来显示和记日志，不再限制工具。
$toolNames = @($script:ToolSchemaMap.Keys)

Write-Log ("任务：$TaskText")
Write-Log ("意图：$intent（仅参考）  工具：全部 $($toolNames.Count) 个")

if ($intent -eq 'chat') {
    Invoke-ChatTask -Text $TaskText
    return
}

# 工作区快照：告诉模型现在有哪些文件，省得它瞎猜。
# 只列前 15 个 + 总数——列太多白占上下文，模型也看不过来。
$wsSnapshot = ''
try {
    $allFiles = @(Get-ChildItem -LiteralPath $Workspace -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -notmatch '\\\.backup\\' })
    if ($allFiles.Count -gt 0) {
        $show = @($allFiles | Select-Object -First 15 | ForEach-Object { $_.FullName.Substring($Workspace.Length).TrimStart('\') })
        $wsSnapshot = "`n`n【工作区文件】共 $($allFiles.Count) 个：`n" + ($show -join "`n")
        if ($allFiles.Count -gt 15) { $wsSnapshot += "`n…（还有 $($allFiles.Count - 15) 个没列出）" }
        $wsSnapshot += "`n（只是参考，任务没提到的别碰）"
    }
} catch { }

# 会话历史
$sessionMsgs = @()
try { $sessionMsgs = @(Get-SessionHistory -MaxTurns 2) } catch { }

# 判断要不要把 project.md 也带上：任务像"做东西"才加
$isBuild = $TaskText -match '写|做|实现|开发|生成|工具|脚本|项目|计算器|管理器|系统'
$sysFull = $SystemPrompt
if ($isBuild -and $ProjectPrompt) {
    $sysFull = $SystemPrompt + "`n`n" + $ProjectPrompt
    Write-Log ("  已加载 project.md（判为做东西的任务）")
}

# 套流程模板：这个任务的硬约束
$script:ActiveFlow = $null
$script:ActiveFlowToolCount = 0
if ($FlowsLoaded) {
    try {
        $fr = Get-Flow -Task $TaskText
        if ($fr) {
            $script:ActiveFlow = $fr.Flow
            $sysFull = $sysFull + "`n`n" + (Format-Flow -Flow $fr.Flow)
            Write-Log ("  套用模板：" + $fr.Flow.name + "（分 " + $fr.Score + "）")
        } else {
            # 没匹配到流程：至少给一张技能速查表，别让它裸奔。
            # 之前这里什么都不加，模型只能凭提示词里的工具名硬猜，
            # 结果是「大文件」任务去 list_dir 两次然后瞎报一个 1.8 KB 是「大文件」。
            $fallback = @'

## 没见过的任务，先想清楚再动手

**别看到任务里有个词就直接做最像的动作。** 先想三件事，把答案写进 think：

1. 用户要的**最终结果**是什么？（一个数字 / 一段文字 / 文件改好了 / 只是想知道情况）
2. **哪个工具**能拿到？下表里找；表里没有就先用 read_file / list_dir / find_files 看情况
3. 拿到后**怎么确认对了**？（工具返回里能不能看到你要的东西）

**信息不够就用 say 问。猜错方向比多问一句贵得多**（一步 30 秒，走错三步就一分半）。

## 常见活儿的现成技能

没给专用流程，你自己判断。这些技能都是写好的，**能用就别自己写命令**：

| 想干什么 | 怎么调 |
|---|---|
| 按文件类型数个数 | `skill(command="count_ext -Path data")` |
| 文本统计（行/字/词） | `skill(command="text_stats -Path data/x.txt")` |
| 某字段求和 | `skill(command="sum_field -Path data/x.jsonl -Field amount")` |
| 查 JSON 字段 | `skill(command="json_query -Path data/x.jsonl -Pattern amount")` |
| 找重复文件 | `skill(command="find_duplicates -Path data")` |
| 找大文件 | `skill(command="find_large -Path . -MinMB 10")` |
| 搜文字 | `skill(command="search_text -Pattern 关键词 -Path .")` |
| 看目录结构 | `skill(command="tree -Path data")` |
| 压缩 | `skill(command="zip_dir -Path data")` |
| 解压 | `skill(command="unzip -Path data/x.zip")` |
| 表格统计 | `skill(command="csv_stats -Path staff.csv")` |
| 批量改名 | `skill(command="batch_rename -Path data -AddPrefix bak_")` |

不确定有哪些，先 `skill(command="list")` 看全部 24 个。
'@
            $sysFull = $sysFull + $fallback
            Write-Log ("  没匹配到流程模板，注入通用技能速查表")
        }
    } catch { }

# 按任务类型只发相关工具，能省一大截输入 token（每步快十几秒）
$toolsJson = $ToolsSchemaRaw
try {
    if ($script:ActiveFlow -and $script:ActiveFlow.tools) {
        $flowTools = @($script:ActiveFlow.tools)
        if ($flowTools.Count -gt 0) {
            $script:ActiveFlowToolCount = $flowTools.Count
            $filtered = Get-ToolsJsonWithFinish -Names $flowTools
            if ($filtered -and $filtered.Length -gt 100) {
                $toolsJson = $filtered
                Write-Log ("  只发 " + $flowTools.Count + " 个相关工具（共 " + (@($script:ToolSchemaMap.Keys).Count) + " 个），省输入")
            }
        }
    } else {
        # 没匹配到流程：给一套常用工具，别把 32 个全发出去。
        # 之前这里发全部，一次「找所有 txt」光 prefill 就花了 105 秒。
        $defaultTools = @('read_file', 'read_lines', 'grep_file', 'write_file', 'find_files', 'file_info', 'run_cmd', 'run_ps', 'web_search', 'web_fetch', 'sys_info', 'open_app', 'unit_convert', 'project_doc', 'skill', 'now', 'date_calc', 'finish')
        $script:ActiveFlowToolCount = $defaultTools.Count
        $dflt = Get-ToolsJsonWithFinish -Names $defaultTools
        if ($dflt -and $dflt.Length -gt 100) {
            $toolsJson = $dflt
            Write-Log ("  没匹配到流程，发 " + $defaultTools.Count + " 个常用工具（共 " + (@($script:ToolSchemaMap.Keys).Count) + " 个）")
        }
    }
} catch { }
}

# 把以前踩过的坑带上（这是"从失败里学"的地方）
$script:UsedLessons = @()
if ($MemoryLoaded) {
    try {
        $rej = @()
        if ($script:ActiveFlow -and $script:ActiveFlow.reject_tools) { $rej = @($script:ActiveFlow.reject_tools) }
        $script:UsedLessons = @(Get-Lessons -Task $TaskText -Max 4 -RejectTools $rej)
        if ($script:UsedLessons.Count -gt 0) {
            $sysFull = $sysFull + "`n`n" + (Format-Lessons -Lessons $script:UsedLessons)

            Write-Log ("  带上 " + $script:UsedLessons.Count + " 条以前的经验")
        }
    } catch { }
}
# 个人配置里的额外指令（config.self.json 的 personalPrompt）
# 注意：必须放在 if 块外面，不然后面没有经验教训时这段就失效了。
$personalPrompt = [string]$Cfg.personalPrompt
if (-not [string]::IsNullOrWhiteSpace($personalPrompt)) {
    $sysFull = $sysFull + "`n`n## 我的习惯`n`n" + $personalPrompt
    Write-Log ("  带上个人指令（" + $personalPrompt.Length + " 字符）")
}


# 任务太模糊时，硬性要求它先问一句。
# 只靠提示词里的「信息不够就问」不管用——「帮我整理一下」这种，
# 模型会看到流程模板里的 cheatsheet 就直接干了，最后做错方向。
$vagueWords = @('整理', '清理', '处理', '弄一下', '搞一下', '收拾', '优化一下')
$isVague = $false
foreach ($vw in $vagueWords) { if ($TaskText -match [regex]::Escape($vw)) { $isVague = $true; break } }
# 有具体路径或文件名，就说明用户说清楚了，不用问
$hasTarget = ($TaskText -match '[A-Za-z0-9_\-\u4e00-\u9fa5]+\.(txt|md|log|csv|json|jsonl|xlsx|ps1|bat|zip)') -or
             ($TaskText -match '(data|test|logs?|downloads?|桌面|文档|图片)\b')
if ($isVague -and -not $hasTarget -and $TaskText.Length -lt 20) {
    $sysFull = $sysFull + "`n`n## 这个任务没说清楚`n`n用户只说了「$TaskText」，没说对什么东西做。**你必须先用 say 问一句具体要处理哪个目录、按什么方式，问完等回答再动手。别自己挑一个做。**"
    Write-Log ("  任务太模糊，要求它先问")
}
$history = @(@{ role = 'system'; content = $sysFull })
foreach ($sm in $sessionMsgs) { $history += $sm }
$history += @{ role = 'user'; content = "任务：$TaskText$wsSnapshot" }

Add-SessionTurn -Role 'user' -Content $TaskText -Ok $true

# 清掉上一次可能残留的提问文件。
# agent 正常结束时自己会删（下面 say 那段有 Remove-Item），
# 但被 stop 或崩掉时就走不到了——那个 ask.json 留着，
# 前端会一直显示"等你回答"，看起来像界面卡死。
foreach ($stale in @('ask.json', 'answer.json')) {
    $sp = Join-Path $AgentDir $stale
    if (Test-Path $sp) { Remove-Item $sp -Force -ErrorAction SilentlyContinue }
}

$state = [pscustomobject]@{
    status    = 'running'
    task      = $TaskText
    steps     = @()
    step      = 1
    maxSteps  = $MaxSteps
    elapsed   = 0
    model     = [string]$Cfg.modelLabel
    workspace = [string]$Cfg.workspace
    answer    = ''
    summary   = ''
    plan      = ''
    logFile   = $logFile
    slot      = 1
    intent    = $intent
    flow      = $(if ($script:ActiveFlow) { [string]$script:ActiveFlow.id } else { '' })
    flowName  = $(if ($script:ActiveFlow) { [string]$script:ActiveFlow.name } else { '' })
    # 实际发出去的工具定义有多大。面板拿这个算剩余上下文，
    # 不能用整个 schema 文件的大小——那是 50 个全量，实际只发 4-10 个。
    toolTokens = [int][Math]::Round($toolsJson.Length / 3.5)
    flowTools  = $script:ActiveFlowToolCount
    phase     = '准备'
}
Write-State $state

$finished    = $false
$noToolCount = 0
$planList    = @()
$lastToolKey = ''
$repeatCount = 0

for ($step = 1; $step -le $MaxSteps; $step++) {
    $state.step = $step
    $state.elapsed = $clock.Elapsed.TotalSeconds
    Write-State $state

    if (-not [Console]::IsOutputRedirected) {
        Write-Host ("  [{0}] 思考中…" -f $step) -ForegroundColor DarkGray -NoNewline
    }

    # 每步开跑前先探一下模型服务活着没。
    # 死了就等几秒重试，三次都不行就干脆收尾，别让用户干等 180 秒超时。
    $alive = $false
    for ($ping = 1; $ping -le 3; $ping++) {
        if (Test-ModelAlive) { $alive = $true; break }
        $state.phase = "模型无响应，等 $ping/3"
        Write-State $state
        Write-Log ("  [ping] 模型服务没响应，等 5 秒重试（$ping/3）")
        if ($ping -lt 3) { Start-Sleep -Seconds 5 }
    }
    if (-not $alive) {
        Close-AsStuck -State $state -Reason '模型服务没有响应，重试三次都不行。' -StepCount ($step - 1)
        $finished = $true
        break
    }

    $state.phase = '思考中'
    Write-State $state
    try {
        # 固定额度：降过一版（400）确实快，但 finish 那步会被截断导致超时，
        # 反而更糟。稳定优先，统一用配置里的值。
        $res = Invoke-Model -Messages $history -ToolsJson $toolsJson -ForceTool:($noToolCount -gt 0)
    } catch {
        Write-Host ''
        # 请求超时也要分辨是真慢还是服务挂了。挂了就报卡死，别报个含糊的"超时"。
        if (-not (Test-ModelAlive -TimeoutSec 5)) {
            Close-AsStuck -State $state -Reason '调用模型时服务失去响应。' -StepCount ($step - 1)
            $finished = $true
            break
        }
        $state.status = 'error'
        $state.elapsed = $clock.Elapsed.TotalSeconds
        $state.answer = "出错了：$($_.Exception.Message)"
        $state.summary = "出错了：模型调用失败"
        Write-State $state
        Write-Closing -State $state -Status 'error' -Summary $state.summary -StepCount ($step - 1)
        $finished = $true
        break
    }

    $rate = if ($res.seconds -gt 0) { $res.tokens / $res.seconds } else { 0 }
    Write-Host ("`r  [{0}] {1:N1}s · {2} tok · {3:N1} tok/s  " -f $step, $res.seconds, $res.tokens, $rate) -ForegroundColor DarkGray

    # ---------- 没有工具调用 ----------
    if (-not $res.calls -or @($res.calls).Count -eq 0) {
        # 4B 有时把调用写成文字：finish(answer="...")。
        # 这不是"没干活"，是它把工具当成了要输出的文本。解析出来当真的收尾。
        $fakeContent = [string]$res.content
        $mFakeFinish = [regex]::Match($fakeContent, 'finish\s*\(\s*answer\s*=\s*["'']([^"'']*)["'']')
        if ($mFakeFinish.Success) {
            $fakeAnswer = $mFakeFinish.Groups[1].Value.Trim()
            if ($fakeAnswer) {
                $state.status = 'done'
                $state.answer = $fakeAnswer
                $state.elapsed = $clock.Elapsed.TotalSeconds
                $state.summary = $fakeAnswer
                $state.steps += @{ n = $step; think = $fakeContent; tool = 'finish'; arg = ''; ok = $true
                                   note = $fakeAnswer; raw = $res.raw_calls; obs = ''; sec = $res.seconds }
                Write-State $state
                Write-Log ("  [识别] 模型把 finish 写成了文字，已按真收尾处理：$fakeAnswer")
                Write-Closing -State $state -Status 'done' -Summary $state.summary -StepCount $step
                $finished = $true
                break
            }
        }

        $noToolCount++
        if ($noToolCount -ge 3) {
            $state.status = 'failed'
            $state.answer = '出错了：模型连续三次没有调用工具，任务没法继续。'
            $state.summary = '出错了：模型只说话不动手。'
            $state.elapsed = $clock.Elapsed.TotalSeconds
            Write-State $state
            Write-Log '连续三次不调工具，收尾'
            Write-Closing -State $state -Status 'failed' -Summary $state.summary -StepCount $step
            $finished = $true
            break
        }
        Write-Log ("  [空转] 第 {0} 次没调工具" -f $noToolCount)
        $history += @{ role = 'assistant'; content = [string]$res.content }
        $lastTool = ''
        if ($state.steps.Count -gt 0) { $lastTool = [string]$state.steps[-1].tool }
        $hint = if ($lastTool) {
            "你刚才已经执行了 $lastTool，结果就在上面的观察里。现在直接调 finish，answer 用一句话给结论（不超过 30 字），不要复述过程，不要再调工具。"
        } else {
            "请调用合适的工具来推进任务；做完了就调 finish。"
        }
        $history += @{ role = 'user'; content = $hint }
        continue
    }

    $noToolCount = 0
    $call = @($res.calls)[0]
    $callId = [string]$call.id
    $toolName = [string]$call.name

    $argsObj = $null
    try { $argsObj = $call.arguments | ConvertFrom-Json } catch { }

    $act = [pscustomobject]@{
        think   = [string]$res.content
        tool    = $toolName
        path    = ''
        content = ''
        find    = ''
        replace = ''
        command = ''
        answer  = ''
        steps   = ''
        message = ''
        reason  = ''
    }
    if ($argsObj) {
        foreach ($p in $argsObj.PSObject.Properties) {
            $act | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([string]$p.Value) -Force
        }
    }
    $act = Repair-ActionStrings $act

    $think = [string]$act.think
    $path  = [string]$act.path

    # ---------- finish ----------
    if ($toolName -eq 'finish') {
        $answer = [string]$act.answer
        if (-not $answer) { $answer = [string]$res.content }
        $state.status = 'done'
        $state.answer = $answer
        $state.elapsed = $clock.Elapsed.TotalSeconds
        $state.summary = if ($answer) { $answer } else { Get-Summary -Steps $state.steps -Status 'done' -TaskText $TaskText }
        $state.steps += @{ n = $step; think = $think; tool = 'finish'; arg = ''; ok = $true
                           note = $answer; raw = $res.raw_calls; obs = ''; sec = $res.seconds }
        Write-State $state
        Write-Log ("  [{0}] {1} -> finish" -f $step, $think)
        Write-Log ("  完成：$answer")
        Write-Closing -State $state -Status 'done' -Summary $state.summary -StepCount $step
        $finished = $true
        break
    }

    # ---------- say（问用户，等回答，最多 60 秒）----------
    if ($toolName -eq 'say') {
        $what = [string]$act.message
        if (-not $what) { $what = [string]$res.content }
        if ([string]::IsNullOrWhiteSpace($what)) { $what = '（模型没写问题，你想怎么办？）' }

        $askId = 'q' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $askFile = Join-Path $AgentDir 'ask.json'
        $ansFile = Join-Path $AgentDir 'answer.json'
        $waitSec = 60

        if (Test-Path $ansFile) { Remove-Item $ansFile -Force -ErrorAction SilentlyContinue }

        $askObj = [ordered]@{
            id       = $askId
            question = $what
            ts       = (Get-Date -Format 'HH:mm:ss')
            deadline = (Get-Date).AddSeconds($waitSec).ToString('HH:mm:ss')
            seconds  = $waitSec
        }
        try {
            [IO.File]::WriteAllText($askFile, (($askObj | ConvertTo-Json -Compress)), (New-Object Text.UTF8Encoding($false)))
        } catch { }

        $state.status = 'waiting'
        $state.answer = $what
        $state.phase  = '等你回答'
        $state.elapsed = $clock.Elapsed.TotalSeconds
        $state.summary = '需要你回答：' + $what
        $state.steps += @{ n = $step; think = $think; tool = 'say'; arg = ''; ok = $true
                           note = $what; raw = $res.raw_calls; obs = ''; sec = $res.seconds }
        Write-State $state
        Write-Log ("  [{0}] -> say：{1}（等 {2} 秒）" -f $step, $what, $waitSec)

        $userAnswer = $null
        $deadline = (Get-Date).AddSeconds($waitSec)
        $lastTick = -1
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400

            $remain = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            if ($remain -ne $lastTick) {
                $lastTick = $remain
                $state.phase = "等你回答（还剩 $remain 秒）"
                $state.elapsed = $clock.Elapsed.TotalSeconds
                Write-State $state
            }

            if (Test-Path (Join-Path $AgentDir 'stop.flag')) { break }

            if (Test-Path $ansFile) {
                try {
                    $ans = Get-Content $ansFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($ans.id -eq $askId -and -not [string]::IsNullOrWhiteSpace([string]$ans.answer)) {
                        $userAnswer = [string]$ans.answer
                        break
                    }
                } catch { }
            }
        }

        if (Test-Path $askFile) { Remove-Item $askFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $ansFile) { Remove-Item $ansFile -Force -ErrorAction SilentlyContinue }

        if (-not $userAnswer) {
            $state.status = 'timeout'
            $state.phase  = '没等到回答'
            $state.answer = "等了你 $waitSec 秒没回音，这个回合先结束了。想继续就把任务再说一遍。"
            $state.summary = '等你回答超时'
            $state.elapsed = $clock.Elapsed.TotalSeconds
            Write-State $state
            Write-Log ("  等回答超时（{0} 秒），结束回合" -f $waitSec)
            Write-Closing -State $state -Status 'timeout' -Summary $state.summary -StepCount $step
            $finished = $true
            break
        }

        Write-Log ("  用户回答：" + $userAnswer)
        $state.status = 'running'
        $state.phase  = '继续'
        $state.answer = ''
        $state.summary = ''
        $state.elapsed = $clock.Elapsed.TotalSeconds
        $state.steps += @{ n = ($step + 1); think = ''; tool = 'answer'; arg = ''; ok = $true
                           note = $userAnswer; raw = ''; obs = ''; sec = 0 }
        Write-State $state

        $tcMsg = Format-ToolCallMessage -Act $act -CallId $callId
        $history += $tcMsg
        $history += @{ role = 'tool'; tool_call_id = $callId; content = ("用户回答：" + $userAnswer + "`n`n（用户已经回答了。根据这个回答继续做，别再问同样的问题。）") }
        continue
    }

    # ---------- plan（记清单 + 量化检查）----------
    if ($toolName -eq 'plan') {
        $rawPlan = [string]$act.steps
        $planList = @()
        foreach ($ln in ($rawPlan -split "`r?`n")) {
            $t = $ln.Trim()
            if (-not $t) { continue }
            $t = $t -replace '^\d+[\.\)、]\s*', '' -replace '^[-*·]\s*', ''
            if ($t) { $planList += @{ text = $t; done = $false } }
        }
        $state.plan = $rawPlan
        $planText = Format-PlanList -Steps $planList

        # ---- 量化检查：步骤是不是太空泛 ----
        # 太空泛的步骤等于没计划（"统计文件数量" 这种，做完也不知道算不算完）。
        # 判断标准：有没有说用什么工具/方法，或者说清产出什么。
        $vague = @()
        $methodWords = 'skill|run_|read_|write_|list_|replace_|make_|delete_|append_|set_|unzip|ps\b|install|findstr|dir |find /c|Get-|Measure-|ConvertTo-|Select-|Group-|Sort-|plan|finish'
        foreach ($pl in $planList) {
            $tx = [string]$pl.text
            $hasMethod = ($tx -match $methodWords)
            $hasOutput = ($tx -match '得到|拿到|输出|生成|写入|改成|返回|确认|检查|验证|存到|放进|列出来|报出|说出')
            if (-not $hasMethod -and -not $hasOutput) {
                $vague += $tx
            }
        }

        $obs = ''
        if ($planList.Count -eq 0) {
            $obs = '清单是空的。先想清楚要做什么，再把步骤列出来（每步写清用什么方法）。'
        } else {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("清单已记下，共 $($planList.Count) 步。")
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('逐条对一下，每步都要「说清怎么做」或者「说清做完产出什么」：')
            $i2 = 0
            foreach ($pl in $planList) {
                $i2++
                $tx = [string]$pl.text
                $ok = -not ($vague -contains $tx)
                [void]$sb.AppendLine(("  {0}. {1}  {2}" -f $i2, $tx, $(if ($ok) { '✓' } else { '← 太空泛' })))
            }
            if ($vague.Count -gt 0) {
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine("有 $($vague.Count) 步太空泛，做起来容易跑偏。")
                [void]$sb.AppendLine('举例：')
                [void]$sb.AppendLine('  差：统计文件数量')
                [void]$sb.AppendLine('  好：用 skill count_ext -Path data 统计，得到每种类型的个数')
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine('不用重新列清单，直接按下面的补充开始做：')
                [void]$sb.AppendLine('每步执行前先想一下「这一步做完，我能拿出什么」。')
            } else {
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine('每步都有具体方法，很好。开始做第一步。')
            }
            $obs = "清单已记下，共 $($planList.Count) 步。" + $(if ($vague.Count -gt 0) { "（$($vague.Count) 步要再具体点）" } else { '' }) + ' 现在开始做第一步。'
            $planText = $sb.ToString()
        }

        $state.steps += @{ n = $step; think = $think; tool = 'plan'; arg = "$($planList.Count) 步"; ok = $true
                           note = $obs; raw = $res.raw_calls; obs = $obs; sec = $res.seconds }
        Write-State $state
        Write-Log ("  [{0}] {1} -> plan" -f $step, $think)
        foreach ($pl in $planList) { Write-Log ("      · " + $pl.text) }
        if ($vague.Count -gt 0) { Write-Log ("      ⚠ 有 $($vague.Count) 步太空泛") }

        $tcMsg = Format-ToolCallMessage -Act $act -CallId $callId
        $history += $tcMsg
        $history += @{ role = 'tool'; tool_call_id = $callId; content = $planText }
        continue
    }

    # ---------- rethink ----------
    if ($toolName -eq 'rethink') {
        $why = [string]$act.reason
        if (-not $why) { $why = '重新审视这个任务' }
        $obs = "好，从头想一遍：$why"
        $state.steps += @{ n = $step; think = $think; tool = 'rethink'; arg = ''; ok = $true
                           note = $obs; raw = $res.raw_calls; obs = $obs; sec = $res.seconds }
        Write-State $state
        Write-Log ("  [{0}] {1} -> rethink" -f $step, $think)
        $tcMsg = Format-ToolCallMessage -Act $act -CallId $callId
        $history += $tcMsg
        $history += @{ role = 'tool'; tool_call_id = $callId; content = $obs }
        continue
    }

    # ---------- 其余工具：交给 tools.ps1 ----------
    $obs = ''
    $ok = $true
    $state.phase = "执行 $toolName"
    Write-State $state
    try {
        $obs = [string](Invoke-AiTool -Action $act)
        if (-not $obs) { $obs = '（没有输出）' }
    } catch {
        $ok = $false
        $obs = '出错了：' + $_.Exception.Message
    }

    $stepArg = $path
    if ($toolName -eq 'run_cmd' -or $toolName -eq 'syshelp' -or $toolName -eq 'win_doc') { $stepArg = [string]$act.command }
    if (-not $stepArg) { $stepArg = [string]$act.command }

    $state.steps += @{ n = $step; think = $think; tool = $toolName; arg = $stepArg; ok = $ok
                       note = (($obs -split "`n")[0]); raw = $res.raw_calls; obs = $obs; sec = $res.seconds; tok = $res.tokens }

    if ($ok -and $planList.Count -gt 0) { $planList = Set-PlanStepDone -Plan $planList }

    $state.elapsed = $clock.Elapsed.TotalSeconds
    Write-State $state
    Write-Log ("  [{0}] {1} -> {2} {3}  ({4} tok / {5:N1}s)" -f $step, $think, $toolName, $stepArg, $res.tokens, $res.seconds)
    Write-Log ("      观察：$obs`n")

    # 同一个动作连着做 = 它绕进去了。下一轮强制它 finish，别再耗步数。
    $toolKey = $toolName + '|' + [string]$call.arguments
    if ($toolKey -eq $lastToolKey) { $repeatCount++ } else { $repeatCount = 0; $lastToolKey = $toolKey }
    if ($repeatCount -ge 1) {
        Write-Log ("  [重复] $toolName 连着做了 $($repeatCount + 1) 次")
        # 不用 tool_choice 硬逼（4B 在 forced 模式下会返回空），改成把话说明白
        $history += @{ role = 'user'; content = "注意：你已经调用 $toolName 拿到结果了，答案就在上面的观察里。现在调 finish 把答案说出来，不要再查一遍。" }

        # 提示了还不收，就用已经拿到的结果替它收尾——再耗下去只是白烧步数
        if ($repeatCount -ge 3) {
            $finalObs = ($obs -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join '；'
            $state.status = 'done'
            $state.answer = "查到的结果：$finalObs"
            $state.elapsed = $clock.Elapsed.TotalSeconds
            $state.summary = $state.answer
            Write-State $state
            Write-Log '  同一动作重复 4 次，用已有结果收尾'
            Write-Closing -State $state -Status 'done' -Summary $state.summary -StepCount $step
            $finished = $true
            break
        }
    }

    # 回填历史：标准 function calling 回合
    $tcMsg = Format-ToolCallMessage -Act $act -CallId $callId
    $history += $tcMsg

    # 提示直接塞进 tool 结果末尾。
    # 不要在 assistant(tool_calls) 和 tool 之间插 user 消息——那会打断标准回合结构，
    # 4B 模型会因此迷路、反复调同一个工具。
    $hint = ''
    if ($state.steps.Count -ge 2) {
        $hint = "`n`n（这一步已经做完。如果上面的结果已经能回答任务，现在就调 finish；" +
                "不要再调 $toolName 或别的工具去确认一遍。）"
    }
    $history += @{ role = 'tool'; tool_call_id = $callId; content = ($obs + $hint) }

    # 截断时保住 system 和第一条任务，后面成对保留
    if ($history.Count -gt 16) {
        $history = @($history[0], $history[1]) + $history[($history.Count - 12)..($history.Count - 1)]
    }
}

if (-not $finished) {
    $state.status = 'maxsteps'
    $state.elapsed = $clock.Elapsed.TotalSeconds
    $state.answer = "步数用完了（$MaxSteps 步），任务还没做完。"
    $state.summary = "出错了：跑满 $MaxSteps 步还没收尾。"
    Write-State $state
    Write-Closing -State $state -Status 'maxsteps' -Summary $state.summary -StepCount $MaxSteps
}

# ---------- 记进会话 ----------
try {
    $sessFiles = @($state.steps |
        Where-Object { $_.ok -and $_.tool -in @('write_file', 'append_file', 'set_line', 'replace_in_file', 'make_dir', 'delete_path') } |
        ForEach-Object { [string]$_.arg } | Where-Object { $_ })
    $sessText = [string]$state.answer
    if ([string]::IsNullOrWhiteSpace($sessText)) { $sessText = [string]$state.summary }
    if ([string]::IsNullOrWhiteSpace($sessText)) { $sessText = '（没有输出）' }
    $sessOk = ([string]$state.status -eq 'done')
    $sessRaw = ''
    foreach ($st1 in @($state.steps)) {
        if ([string]$st1.raw) { $sessRaw += ("== 第{0}步 {1} ==`n{2}`n`n" -f $st1.n, $st1.tool, $st1.raw) }
    }
    Add-SessionTurn -Role 'assistant' -Content $sessText -Ok $sessOk -Files $sessFiles -Raw $sessRaw
} catch { }

# ---------- 记进历史（面板历史抽屉用）----------
try {
    $histSteps = foreach ($s in $state.steps) {
        if ($s.tool -eq 'check') { continue }
        [pscustomobject]@{
            n = $s.n; tool = $s.tool; arg = $s.arg; ok = $s.ok
            think = $s.think; note = $s.note
        }
    }
    $rec = [pscustomobject]@{
        ts      = (Get-Date -Format 'MM-dd HH:mm:ss')
        task    = $TaskText
        status  = $state.status
        elapsed = [Math]::Round($state.elapsed, 1)
        summary = $state.summary
        plan    = $state.plan
        steps   = @($histSteps)
    }
    $line = ConvertTo-Json -InputObject $rec -Depth 6 -Compress
    Add-Content -Path $HistFile -Value $line -Encoding UTF8
    $all = @(Get-Content $HistFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    if ($all.Count -gt 200) {
        [IO.File]::WriteAllLines($HistFile, @($all | Select-Object -Last 200), (New-Object Text.UTF8Encoding($false)))
    }
} catch { }

# ---------- 经验记忆：记结果 + 自动提炼教训 ----------
if ($MemoryLoaded) {
    try {
        Add-TaskRecord -Task $TaskText -Status $state.status -Steps @($state.steps) -Answer ([string]$state.answer)
        # 用过的教训记一次"被用上"，以后优先带出来
        if ($script:UsedLessons -and $script:UsedLessons.Count -gt 0) {
            Add-LessonHit -Lessons $script:UsedLessons
        }
        # 失败或者跑得不顺，自动提炼教训
        if ($state.status -in @('failed','error','maxsteps','timeout','stuck')) {
            $auto = @(Get-AutoLessons -Task $TaskText -Steps @($state.steps) -Status $state.status)
            $added = 0
            foreach ($a in $auto) {
                if (Add-Lesson -Task $TaskText -Mistake $a.Mistake -Fix $a.Fix -Source 'auto') { $added++ }
            }
            if ($added -gt 0) {
                Write-Log ("  从这次失败里记了 " + $added + " 条教训（下次不会再犯）")
            }
        }
        $st = Get-MemoryStats
        Write-Log ("  经验库：教训 " + $st.Lessons + " 条，任务记录 " + $st.Tasks + " 条")
    } catch { }
}

$clock.Stop()