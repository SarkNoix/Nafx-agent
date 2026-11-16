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

# ---- 加载 mod（<项目根>\mod\*.mod.json）----
# mod 能在不改源码的前提下改配置、改工具、加人设、塞文档。
# 必须在读 Cfg 之后、用 Cfg.maxSteps 之前，否则 mod 改的 maxSteps 不生效。
$modsLoader = Join-Path $AgentDir 'mods.ps1'
if (Test-Path $modsLoader) {
    . $modsLoader
    $script:ActiveMods = @(Get-Mods -Root $Root)
    if ($script:ActiveMods.Count -gt 0) {
        $cfgRes = Apply-ModConfig -Mods $script:ActiveMods -Cfg $Cfg
        $Cfg = $cfgRes.Cfg
        foreach ($ap in $cfgRes.Applied) { Write-Host ("  [mod] 配置 " + $ap) -ForegroundColor DarkCyan }
        Write-Host ("  已加载 " + $script:ActiveMods.Count + " 个 mod：" + (($script:ActiveMods | ForEach-Object { $_.name }) -join '、')) -ForegroundColor DarkCyan
    } else { $script:ActiveMods = @() }
} else { $script:ActiveMods = @() }

if (-not $Task) { $Task = [string]$env:NAFX_TASK }
if (-not $Task) { $Task = '你好' }
if ($MaxSteps -le 0) { $MaxSteps = [int]$Cfg.maxSteps }

$Api       = "http://$($Cfg.host):$($Cfg.port)"
$Workspace = if ([IO.Path]::IsPathRooted([string]$Cfg.workspace)) { [string]$Cfg.workspace } else { Join-Path $Root ([string]$Cfg.workspace) }
$LogDir    = Join-Path $AgentDir 'logs'
$StateFile = if ($env:NAFX_STATE) { $env:NAFX_STATE } else { Join-Path $AgentDir 'state.json' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# 日志要定期清理。每次任务生成一个 run_*.txt，跑几十轮训练就是几百个，
# 实测已经堆到 560 个（0.7 MB）。虽然不大，但会一直涨，
# 而且面板/排查时翻目录也慢。保留最近 200 个，其余的删掉。
try {
    $oldLogs = @(Get-ChildItem (Join-Path $LogDir 'run_*.txt') -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -Skip 200)
    if ($oldLogs.Count -gt 0) {
        $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    }
} catch { }

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

# project.md 分段加载。
# 原来整个 1826 token 全塞进去，而 context 只有 4096 ——
# build 类任务（写脚本）要发 11 个工具 schema（1749 tok）+ project.md（1826）+ prompt.md（1410）
# 一算就是 4985，直接 400 Bad Request。实测 local-script 那题每次都是 3 秒 error。
# 现在按任务内容挑段：写脚本只给「写脚本 / 写小项目 / 处理 jsonl」这几段，
# 「做项目：先想清楚」584 token 只有真要做完整项目时才加载。
$ProjectSections = @()
$ProjectPrompt   = ''
try {
    $projPath = Join-Path $AgentDir 'project.md'
    if (Test-Path $projPath) {
        $projLines = [IO.File]::ReadAllLines($projPath, [Text.Encoding]::UTF8)
        # 按 ## 标题切段，保留标题和正文
        $cur = $null
        foreach ($pl in $projLines) {
            if ($pl -match '^##\s+(.+)') {
                if ($cur) { $ProjectSections += $cur }
                $cur = [pscustomobject]@{ Title = $matches[1]; Body = $pl + "`n" }
            } elseif ($cur) {
                $cur.Body += $pl + "`n"
            }
        }
        if ($cur) { $ProjectSections += $cur }
    }
} catch { }

# 按任务挑段。没命中就全给（宁可多花 token 也别缺信息）。
function Get-ProjectPromptFor {
    param([string]$Task)
    if ($ProjectSections.Count -eq 0) { return '' }
    $pick = @()
    $t = $Task

    # 写脚本类：只要「写脚本」那段的代码示例
    # 「"写个工具"就是写脚本」那段 297 token 讲的是「别手动一个个干」，
    # build flow 的目标说明已经覆盖同样意思，重复给等于白烧上下文。
    if ($t -match '脚本|\.ps1|\.bat|工具|命令|统计|数一下|多少行|行数') {
        $pick += @('写脚本')
    }
    # 「写小项目」讲的是 param/try-catch/完整项目骨架（280 tok），
    # 「写个脚本数行数」用不上。真说「做个XX工具/程序/系统」才加载。
    if ($t -match '做个|做一个|实现一个|开发一个|管理系统|完整|小程序' -or $t -match '工具|程序' -and $t -notmatch '写一个脚本|\.ps1') {
        $pick += @('写小项目')
    }
    # 处理数据文件
    if ($t -match 'jsonl|json|csv|日志|数据|表格') {
        $pick += @('处理 jsonl 这类文件')
    }
    # 真要做完整项目才给设计方法论（最贵的那段，585+312 tok）
    # 这个关键词原来含「小项目」「完整」，结果「在 mini 目录下建个小项目，
    # 包含 main.ps1、config.txt、README.md」也命中 —— 但那题只是建三个文件，
    # 白送 897 tok 直接把上下文撑爆（实测 400 Bad Request，3 秒 error）。
    # 判据：任务已经把要建的东西列清楚了就不给方法论，
    # 只有「做个X系统/工具」这种得自己想架构的才给。
    $hasFileList = ($t -match '包含|包括|三个文件|两个文件|这几个文件')
    if (-not $hasFileList -and $t -match '做个|做一个|实现一个|开发一个|管理系统') {
        $pick += @('做项目：先想清楚，再动手', '多步任务先列清单，而且要列出"用什么方法"')
    }

    if ($pick.Count -eq 0) { return '' }   # 都不沾边就不给，别占上下文

    $sel = @()
    foreach ($sec in $ProjectSections) {
        $tt = [string]$sec.Title
        $hit = $false
        foreach ($p in $pick) {
            # 判断「标题以关键词开头」用 IndexOf(...) -eq 0。这里踩过两个坑：
            # ① 原来用 -like '*x*'，「写脚本」会连「"写个工具"就是写脚本」一起匹配（多背 215 tok）
            # ② 改成 [string]$sec.Title.StartsWith($p) 反而六个段落全命中 ——
            #    PowerShell 把 StartsWith 当成对参数数组逐个判断、任一命中就 True，
            #    实测直接变成 2788 字符，system 撑爆。
            # IndexOf 做显式比较没有这个歧义。
            if ($tt.IndexOf([string]$p) -eq 0) { $hit = $true; break }
        }
        if ($hit) { $sel += $sec.Body }
    }
    return (($sel -join "`n").Trim())
}

$ProjectPrompt = ''
$ToolsSchemaRaw = (Get-Content (Join-Path $AgentDir 'tools-schema.json') -Raw -Encoding UTF8).Trim()

# ------------------------------------------------------------
#  流式输出：面板靠读这个文件实现逐字效果
#  写在 agent\log 目录下，一行一个 JSON 事件，前端轮询取增量。
#  用追加写 + 每片 flush：面板能实时看到，不需要等任务结束。
# ------------------------------------------------------------
$script:StreamFile = Join-Path $AgentDir 'stream.jsonl'
$script:StreamSeq  = 0
function Reset-Stream {
    try {
        [IO.File]::WriteAllText($script:StreamFile, '', (New-Object Text.UTF8Encoding($false)))
        $script:StreamSeq = 0
    } catch { }
}
function StreamPiece {
    param([string]$Text, [string]$Kind = 'text')
    if (-not $Text) { return }
    $script:StreamSeq++
    try {
        $ev = [pscustomobject]@{ seq = $script:StreamSeq; kind = $Kind; text = $Text }
        $line = (ConvertTo-Json -InputObject $ev -Compress) + "`n"
        $fs = [IO.File]::Open($script:StreamFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $b = [Text.Encoding]::UTF8.GetBytes($line)
            $fs.Write($b, 0, $b.Length)
            $fs.Flush()
        } finally { $fs.Close() }
    } catch { }
}

# 把 schema 按工具名拆开，路由时只发相关的几个
$script:ToolSchemaMap = @{}
try {
    foreach ($s in ($ToolsSchemaRaw | ConvertFrom-Json)) {
        $n = [string]$s.function.name
        if ($n) { $script:ToolSchemaMap[$n] = (ConvertTo-Json -InputObject $s -Depth 10 -Compress) }
    }
} catch {
    # 这里失败是致命的：ToolSchemaMap 空掉之后，按 flow 筛出来的工具全变成 undefined，
    # 模型拿不到任何工具定义，等于完全瘫痪。以前是 catch {} 静默吞掉，
    # 表现成「模型突然不会用工具了」，很难查。
    Write-Log ('  [严重] tools-schema.json 解析失败：' + $_.Exception.Message)
    Write-Log ('         可用工具数 = ' + $script:ToolSchemaMap.Count + '，模型将无法调用任何工具。')
}

# mod 改工具：禁用按钮、改描述
if ($script:ActiveMods -and $script:ActiveMods.Count -gt 0) {
    $toolLog = Apply-ModTools -Mods $script:ActiveMods -ToolMap $script:ToolSchemaMap
    foreach ($tl in $toolLog) { Write-Host ("  [mod] " + $tl) -ForegroundColor DarkCyan }
}

$SessionFile = Join-Path $LogDir 'session.jsonl'
$script:sessWrites = 0   # 写了几条会话，每 20 条才检查一次截断
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
        # 原子写：先写临时文件再改名。
        # 直接 WriteAllText 有个坑 —— 面板正好在这时候读会读到半截 JSON，
        # ConvertFrom-Json 抛异常被 catch 掉，面板就显示上一次的状态，
        # 看起来像"卡住了"。任务跑得快的时候（每步都要写一次）很容易撞上。
        # 改名在同一个卷上是原子操作，读的一方要么看到旧的完整文件，要么看到新的。
        $tmpState = $StateFile + '.tmp'
        [IO.File]::WriteAllText($tmpState, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path $StateFile) { [IO.File]::Delete($StateFile) }
        [IO.File]::Move($tmpState, $StateFile)
    } catch {
        # 写不进状态 = 面板收不到任何更新，表现出来的就是「卡在思考中不动」。
        # 以前这里静默吞，用户看到的是假死面板。至少记一笔，能查。
        # 注意不能调 Write-Log（它自己也写文件，可能同样失败），直接往 stderr 打。
        try { [Console]::Error.WriteLine('  [警告] 写 state.json 失败：' + $_.Exception.Message) } catch { }
    }
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
    param([string]$Intent, [string]$TaskText = '')
    # 按意图挑工具。没匹配到 flow 时用这个，别一股脑发 18 个。
    # 之前默认分支发 18 个（1315 tok），配上 system 1760 + 输出 600 = 3675，
    # 正好卡在 3696 上限，于是跑到第 2 步就触发「省上下文」砍工具，
    # 把 write_file 砍掉了，模型只好用 run_cmd echo > 绕，写出路径错的空文件。
    switch ($Intent) {
        'chat'    { return @('say', 'finish') }
        'query'   { return @('think', 'web_search', 'web_fetch', 'read_file', 'list_dir', 'say', 'finish') }
        'build'   { return @('think', 'write_file', 'read_file', 'replace_in_file', 'run_cmd', 'make_dir', 'say', 'finish') }
        'analyze' { return @('think', 'list_dir', 'read_file', 'run_cmd', 'write_file', 'say', 'finish') }
        default   { return @('think', 'list_dir', 'read_file', 'write_file', 'append_file',
                             'make_dir', 'delete_path', 'run_cmd', 'find_files', 'grep_file',
                             'web_search', 'say', 'finish') }
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

# ------------------------------------------------------------
#  上下文预算保护
#  实测 1 个中文字 ≈ 0.68 token，也就是 1 token ≈ 1.47 字符。
#  context 4096，给输出留 400，所以输入侧上限 3696 token。
#  历史里的英文/JSON 比中文便宜（约 3.5 字符/token），分开算更准。
#
#  为什么要这个：全量 45 题里 9 个任务是第 3 步就 400 Bad Request，
#  各 flow 一直是「多给点工具保险」，没人算过总账，6 个 flow 超预算。
#  flow 已经按用途收敛过，这里再加一层运行时兜底 ——
#  真到临界点时主动砍最没用的工具，而不是等 llama.cpp 吐 400。
# ------------------------------------------------------------
function Get-CtxTokens {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $cjk = ([regex]::Matches($Text, '[\u4e00-\u9fa5]')).Count
    $other = $Text.Length - $cjk
    return [int][Math]::Round($cjk / 1.47 * 1.0 + $other / 3.5)
}

function Get-HistoryTokens {
    param([array]$History)
    $n = 0
    foreach ($m in $History) {
        $n += Get-CtxTokens ([string]$m.content)
        if ($m.tool_calls_json) { $n += Get-CtxTokens ([string]$m.tool_calls_json) }
    }
    return $n
}

# 按优先级从工具集里砍，直到装进预算。think/finish 永远保留。
function Trim-ToolsToBudget {
    param([string[]]$Names, [int]$Budget)
    # 优先级：越靠前越该保留
    # 从后往前砍，所以这里排的是「最不该砍的」。
    #
    # 原来保底只有 think/finish/say/rethink —— 全是"会说话"的工具，
    # 一个"能干活"的都没有。实测砍到 5 个时 write_file / read_file / grep_file
    # 全没了，模型手里只剩会说话的工具：想写 err.txt 写不了，连试三次 think，
    # 最后居然去下 https://example.com/big.log。
    # 「能读能写」是干活的底线，必须和 think/finish 一样受保护。
    $mustKeep = @('think', 'note', 'finish', 'say', 'rethink',
                  'read_file', 'write_file', 'append_file', 'list_dir')
    $list = @($Names)
    $json = Get-ToolsJsonWithFinish -Names $list
    if ((Get-CtxTokens $json) -le $Budget) { return $list }

    # 从后面开始砍，但不砍 mustKeep
    $k = $list.Count - 1
    while ($k -ge 0 -and (Get-CtxTokens $json) -gt $Budget) {
        $nm = [string]$list[$k]
        if ($mustKeep -notcontains $nm) {
            $list = @($list | Where-Object { $_ -ne $nm })
            $json = Get-ToolsJsonWithFinish -Names $list
        }
        $k--
    }
    return $list
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
            # 带上 ts：调用方要靠它判断这条是不是「清除之前」的记录
            $out += @{ role = $role; content = $content; ts = [string]$o.ts }
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

        # 截断只在偶尔做一次。
        # 原来每写一条都要读整个文件、数行数、超了再整个重写 ——
        # 而 think 自动播报让写入频率翻了几倍（每一步至少一条），
        # 会话长到几百行时每写一行就要读一次几百行的文件。
        # 改成每 20 次才检查，其余 19 次就是一次纯追加。
        $script:sessWrites = [int]$script:sessWrites + 1
        if ($script:sessWrites % 20 -eq 0) {
            $all = @(Get-Content $SessionFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
            if ($all.Count -gt 60) {
                [IO.File]::WriteAllLines($SessionFile, @($all | Select-Object -Last 60), (New-Object Text.UTF8Encoding($false)))
            }
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
                ',"tool_choice":' + $choice +
                ',"stream":true}'
    $bytes = [Text.Encoding]::UTF8.GetBytes($jsonBody)

    # ---- 流式请求 ----
    # Invoke-WebRequest 是一次性把响应全收完才返回的，看不到中间过程。
    # 要用 HttpWebRequest + StreamReader 逐行读 SSE：
    #   data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"path"}}]}}]}
    # 工具调用时分片是半截 JSON（"path" / "\":" / " \" / "a.txt"），
    # 拼起来才完整 —— 这正好就是「模型一个字一个字写参数」的样子。
    # 纯文本回答（finish / 闲聊）分片是 content，直接显示。
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    $reader = $null
    $acc = ''
    $dtCalls = @{}   # index -> @{ id; name; args }
    $finishReason = ''
    $errMsg = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("$Api/chat/completions")
            $req.Method = 'POST'
            $req.ContentType = 'application/json; charset=utf-8'
            $req.Timeout = [int]$Cfg.stepTimeoutSeconds * 1000
            $req.ReadWriteTimeout = [int]$Cfg.stepTimeoutSeconds * 1000
            $req.ContentLength = $bytes.Length
            $reqStream = $req.GetRequestStream()
            $reqStream.Write($bytes, 0, $bytes.Length)
            $reqStream.Close()

            $resp = $req.GetResponse()
            $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)

            # 屏幕还没输出过任何字符时，用这个标记判断要不要换行
            $printed = $false
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not $line) { continue }
                if (-not $line.StartsWith('data: ')) { continue }
                $payload = $line.Substring(6).Trim()
                if ($payload -eq '[DONE]') { break }

                $chunk = $null
                try { $chunk = $payload | ConvertFrom-Json } catch { continue }
                if (-not $chunk.choices) { continue }
                $d = $chunk.choices[0].delta
                if ($chunk.choices[0].finish_reason) { $finishReason = [string]$chunk.choices[0].finish_reason }

                # 纯文本分片
                if ($d.content) {
                    $piece = [string]$d.content
                    if (-not $printed) { Write-Host '    ' -NoNewline -ForegroundColor DarkGray; $printed = $true }
                    Write-Host $piece -NoNewline -ForegroundColor Gray
                    $acc += $piece
                    StreamPiece -Text $piece -Kind 'text'
                }
                # 工具调用分片：按 index 累加
                if ($d.tool_calls) {
                    foreach ($tc in @($d.tool_calls)) {
                        $ix = [int]$tc.index
                        if (-not $dtCalls.ContainsKey($ix)) {
                            $dtCalls[$ix] = [pscustomobject]@{ id = ''; name = ''; args = ''; shown = $false }
                        }
                        $cur = $dtCalls[$ix]
                        if ($tc.id) { $cur.id = [string]$tc.id }
                        if ($tc.function -and $tc.function.name) { $cur.name = [string]$tc.function.name }
                        if ($tc.function -and $null -ne $tc.function.arguments) {
                            $frag = [string]$tc.function.arguments
                            $cur.args += $frag
                            # 参数分片实时显示（这就是「一个字一个字」的效果）
                            if (-not $cur.shown) {
                                Write-Host ("`r    " + [char]0x2192 + " " + $cur.name + " ") -NoNewline -ForegroundColor DarkCyan
                                $cur.shown = $true
                                StreamPiece -Text ("→ " + $cur.name + " ") -Kind 'tool'
                            }
                            Write-Host $frag -NoNewline -ForegroundColor DarkYellow
                            StreamPiece -Text $frag -Kind 'tool'
                        }
                    }
                }
            }
            if ($printed -or $dtCalls.Count -gt 0) { Write-Host '' }
            break
        } catch {
            $errMsg = $_.Exception.Message
            if ($reader) { try { $reader.Close() } catch { } }
            if ($resp) { try { $resp.Close() } catch { } }
            if ($attempt -ge 2) { throw }
            Write-Log ("  模型响应超时，重试一次：" + $errMsg)
            Start-Sleep -Seconds 2
            $acc = ''
            $dtCalls = @{}
        }
    }
    if ($reader) { try { $reader.Close() } catch { } }
    if ($resp) { try { $resp.Close() } catch { } }
    $sw.Stop()

    # ---- 把分片拼成调用 ----
    $calls = @()
    foreach ($ix in ($dtCalls.Keys | Sort-Object)) {
        $c = $dtCalls[$ix]
        if (-not $c.name) { continue }
        $argText = $c.args
        if (-not $argText.Trim()) { $argText = '{}' }
        $calls += [pscustomobject]@{
            id        = $(if ($c.id) { $c.id } else { 'call_' + [Guid]::NewGuid().ToString('N').Substring(0, 8) })
            name      = $c.name
            arguments = $argText
        }
    }
    $msg = [pscustomobject]@{ content = $acc; tool_calls = $null }
    # token 数：流式下没有 usage，用字符数粗估（中文约 0.68 tok/字）
    $tokEst = [int][Math]::Round($acc.Length / 1.47)
    foreach ($c in $calls) { $tokEst += [int][Math]::Round(($c.name.Length + $c.arguments.Length) / 1.47) }

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
        raw_calls = $(if ($calls.Count -gt 0) { ConvertTo-Json -InputObject @($calls) -Depth 8 -Compress } else { '' })
        tokens    = $tokEst
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

# ------------------------------------------------------------
#  删除确认：删任何文件都要用户点头
#
#  用户明确要求「删什么都问」。做成硬规矩，不靠提示词让模型自觉 ——
#  模型可以说「我删了」，但真实删除必须经过这里。
#  复用面板已有的 ask.json / answer.json 机制（say 工具那套），
#  但给 3 分钟（删东西比回答问题更需要想一下）。
#  拿不到回答一律当「拒绝」—— 安全侧默认拒绝，不是默认放行。
# ------------------------------------------------------------
# ------------------------------------------------------------
#  工具出错时的反馈：不只要说"错在哪"，还要说"接下来怎么想"
#
#  原来出错只返回一句「出错了：<异常消息>」，模型拿到之后基本只会
#  原样再试一遍（同一个 move_path 连调 3 次就是这么来的），
#  或者换个工具瞎试。
#
#  这里按错误类型分类，每类都给一句「所以你现在该做什么」：
#    · 路径不存在   → 先 list_dir 看真实文件名，别猜
#    · 目标已存在   → 换个目标，或者确认是不是已经做过了
#    · 权限/被占用  → 换路径，别硬试
#    · 参数缺失     → 补哪个字段
#    · 安全拦截     → 这条路走不通，换条路，别绕过
#  分类靠异常消息里的关键词，简单但不精确——够用，因为消息是我们自己抛的。
# ------------------------------------------------------------
function Format-ToolError {
    param([string]$Tool, [string]$Arg, [string]$Message)

    $m = [string]$Message
    $head = "出错了：$m"
    $hint = ''

    if ($m -match '路径越界|这里动不得|不合法') {
        $hint = ('这个位置不许动（只允许工作区，桌面可以写 Desktop\文件名）。' +
                 '别试着换个写法绕过，换个目录做。')
    }
    elseif ($m -match '被安全策略|不许用|被删除被拒|没有批准') {
        $hint = ('这个动作被安全策略挡下了，这条路走不通。' +
                 '别换个写法再试（比如换成 run_cmd 硬来），换个能做到的方式。')
    }
    elseif ($m -match '源不存在|路径不存在|不存在：') {
        $hint = ('先 list_dir 看一眼真实有哪些文件，别猜文件名。' +
                 '确认名字对得上再动手；确实没有就别再试这个路径了。')
    }
    elseif ($m -match '目标.*已经|目标已存在|已存在') {
        $hint = ('那个位置已经有东西了。要么换个目标路径，要么先确认这件事是不是已经做过了。' +
                 '别直接删掉对方的文件——那是另一个文件。')
    }
    elseif ($m -match '不能为空|没说要挪到哪儿|要填') {
        $hint = '参数没给全。看上面的工具说明，把缺的字段补上再调一次。'
    }
    elseif ($m -match '拒绝访问|无权限|被占用|正在使用|Access') {
        $hint = '文件被占用或没权限。换个文件/目录做，别反复重试同一个。'
    }
    elseif ($m -match '超时|timed out|Timeout') {
        $hint = '这一步超时了。要么命令本身太慢（换更快的做法），要么服务卡了。别原样重跑第三次。'
    }
    elseif ($m -match '语法|Parser|参数错误|CommandNotFound|not recognized') {
        $hint = '命令或参数写错了。先 syshelp 查这条命令的正确用法，别凭印象改。'
    }
    elseif ($m -match '编码|乱码|Unicode') {
        $hint = '编码问题。读写文件时明确指定 UTF8。'
    }
    elseif ($m -match '脚本被安全策略拒绝') {
        $hint = '脚本里有不允许的操作（删除/关机/改注册表/系统目录）。删掉那段再试，别换别的写法绕过。'
    }

    if (-not $hint) {
        $hint = ('看清错误再决定：是路径写错了、还是这工具就不适合干这件事？' +
                 '同一个调用原样再试一次结果不会变。')
    }

    # 附一句"已试过几次"的提醒，防止它在同一个坑里连续撞
    return ($head + "`n`n" + $hint)
}

function Confirm-Delete {    param([string]$Target, [object]$State, [int]$StepNum)

    if ([string]::IsNullOrWhiteSpace($Target)) { return $false }

    $askId   = 'd' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $askFile = Join-Path $AgentDir 'ask.json'
    $ansFile = Join-Path $AgentDir 'answer.json'
    $waitSec = 180

    if (Test-Path $ansFile) { Remove-Item $ansFile -Force -ErrorAction SilentlyContinue }

    $askObj = [ordered]@{
        id       = $askId
        kind     = 'delete'
        question = "模型要删除「$Target」，允许吗？"
        target   = $Target
        ts       = (Get-Date -Format 'HH:mm:ss')
        deadline = (Get-Date).AddSeconds($waitSec).ToString('HH:mm:ss')
        seconds  = $waitSec
    }
    try {
        [IO.File]::WriteAllText($askFile, (($askObj | ConvertTo-Json -Compress)), (New-Object Text.UTF8Encoding($false)))
    } catch { }

    $State.status  = 'waiting'
    $State.phase   = '等你确认删除'
    $State.answer  = $askObj.question
    $State.elapsed = $clock.Elapsed.TotalSeconds
    try { Write-State $State } catch { }

    Write-Host ''
    Write-Host ("  ⚠ 要删除：" + $Target) -ForegroundColor Yellow
    Write-Host ("    请在面板上点「允许」或「拒绝」（$waitSec 秒内）") -ForegroundColor DarkYellow
    Write-Log ("  [删除确认] 等用户批准：$Target")

    $answer = $null
    $deadline = (Get-Date).AddSeconds($waitSec)
    $lastTick = -1
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (Test-Path $ansFile) {
            try {
                $raw = [IO.File]::ReadAllText($ansFile, [Text.Encoding]::UTF8)
                if ($raw.Trim()) {
                    $obj = $raw | ConvertFrom-Json
                    if ([string]$obj.id -eq $askId) { $answer = [string]$obj.answer; break }
                }
            } catch { }
        }
        $left = [int]($deadline - (Get-Date)).TotalSeconds
        if ($left -ne $lastTick -and $left % 10 -eq 0) {
            $lastTick = $left
            $State.phase = "等你确认删除（$left 秒）"
            try { Write-State $State } catch { }
        }
    }

    Remove-Item $askFile -Force -ErrorAction SilentlyContinue
    Remove-Item $ansFile -Force -ErrorAction SilentlyContinue

    if ($null -eq $answer) {
        Write-Log ("  [删除确认] 超时没有得到批准，按拒绝处理")
        return $false
    }

    $a = $answer.Trim().ToLower()
    $ok = ($a -eq 'y' -or $a -eq 'yes' -or $a -eq 'allow' -or $a -eq '允许' -or
           $a -eq '同意' -or $a -eq 'ok' -or $a -eq '好' -or $a -eq '是')
    Write-Log ("  [删除确认] 用户回答：" + $answer + " → " + $(if ($ok) { '允许' } else { '拒绝' }))
    return $ok
}

# ------------------------------------------------------------
#  统一收尾：能捞就捞，实在没有才认输
#
#  背景：这段逻辑原来在 4 个地方各写一遍（任务超时、模型调用失败、
#  连续空转、跑满步数），每处 10 行几乎逐字相同，只差变量名和日志文案。
#  散在主循环各处的问题是改一处忘三处 —— 前几轮就因此反复出同类 bug：
#  工具明明已经返回结果，却因为「收尾那步失败」把整题判成 error。
#
#  现在统一成：有观察就用观察收尾（done），没有才按 FailStatus 认输。
# ------------------------------------------------------------
function Close-WithResult {
    param(
        [object]$State,
        [string]$Reason,          # 为什么要收尾（写进日志）
        [string]$FailStatus,      # 没有结果时判成什么：timeout / error / maxsteps / failed
        [string]$FailAnswer,      # 没有结果时给用户的说明
        [int]$StepCount
    )
    # 从 steps 末尾往前找最后一条非空观察
    $lastObs = ''
    for ($ci = $State.steps.Count - 1; $ci -ge 0; $ci--) {
        $cob = [string]$State.steps[$ci].obs
        if ($cob.Trim()) { $lastObs = $cob; break }
    }

    $State.elapsed = $clock.Elapsed.TotalSeconds
    if ($lastObs.Trim()) {
        $final = ($lastObs -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 15) -join "`n"

        # 观察里带着明显的失败字样，就不该当成功交差。
        # 起因：「写一个计算器」那题，脚本输出是
        #     错误：不支持的操作
        #     测试：12 + 3 = 15
        # write_script 的返回值是「已写 calc.ps1 并运行（退出码 0）」，看着成功，
        # 于是把这两行原样当答案交了，用户看到的就是一个自相矛盾的错结果。
        # 现在识别到失败字样就判 failed，让面板/日志明确显示「没做成」。
        $badMarkers = '错误[:：]|不支持|失败|未找到|找不到|Cannot find|not recognized|Exception|Traceback|参数错误|语法错误'
        $looksFailed = ($final -match $badMarkers)

        if ($looksFailed) {
            $State.status  = 'failed'
            $State.answer  = "没做成，最后跑出来是这些：`n" + $final
            $State.summary = '出错了：脚本跑出来是错误'
            Write-Log ("  " + $Reason + "，但输出里有错误字样，判 failed 而不是 done")
            Write-State $State
            Write-Closing -State $State -Status 'failed' -Summary $State.summary -StepCount $StepCount
        } else {
            $State.status  = 'done'
            $State.answer  = $final
            $State.summary = $final
            Write-Log ("  " + $Reason + "，用已有结果收尾")
            Write-State $State
            Write-Closing -State $State -Status 'done' -Summary $State.summary -StepCount $StepCount
        }
    } else {
        $State.status  = $FailStatus
        $State.answer  = $FailAnswer
        $State.summary = '出错了：' + $FailAnswer
        Write-Log ("  " + $Reason + "，没有任何结果，判 " + $FailStatus)
        Write-State $State
        Write-Closing -State $State -Status $FailStatus -Summary $State.summary -StepCount $StepCount
    }
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
#
# 加一道「代际」保险：
# 用户点「清除对话」时，面板会写一个 session_gen 文件夹（里面是时间戳）。
# 这里只认「比清除时间更新」的会话记录 —— 万一还有漏网的老进程在清完之后
# 又写了一行，也不会被当成本次对话的历史读进来。
# 光靠"杀进程 + 清文件"不够稳：进程杀可能有几百毫秒延迟，
# 而这段时间足够它写完一行。代际号是为了兜住这个竞态。
$sessionMsgs = @()
try {
    $genFile = Join-Path $LogDir 'session_gen.txt'
    $genTs = [datetime]::MinValue
    if (Test-Path $genFile) {
        try {
            $gt = ([IO.File]::ReadAllText($genFile, [Text.Encoding]::UTF8)).Trim()
            if ($gt) { $genTs = [datetime]::Parse($gt, [Globalization.CultureInfo]::InvariantCulture) }
        } catch { }
    }
    $rawHist = @(Get-SessionHistory -MaxTurns 2)
    if ($rawHist.Count -gt 0 -and $genTs -ne [datetime]::MinValue) {
        # 只有带着 ts 且晚于清除时间的才保留
        $sessionMsgs = @($rawHist | Where-Object {
            $t = $null
            try {
                if ($_.ts) { $t = [datetime]::Parse([string]$_.ts, [Globalization.CultureInfo]::InvariantCulture) }
            } catch { }
            ($t -ne $null) -and ($t -gt $genTs)
        })
    } else {
        $sessionMsgs = $rawHist
    }
} catch { $sessionMsgs = @() }

# 按任务挑 project.md 的相关段落（不再是全量 1826 token）
$sysFull = $SystemPrompt
$projPick = Get-ProjectPromptFor -Task $TaskText
if ($projPick) {
    $sysFull = $SystemPrompt + "`n`n" + $projPick
    Write-Log ("  已加载 project.md 相关段（" + $projPick.Length + " 字符，全量是 2684）")
} else {
    Write-Log ("  project.md 没加载（任务不涉及写脚本/项目）")
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
2. **哪个工具**能拿到？表里没有就先用 read_file / list_dir / find_files 看情况
3. 拿到后**怎么确认对了**？（工具返回里能不能看到你要的东西）

**信息不够就用 say 问。猜错方向比多问一句贵得多**（一步 30 秒，走错三步就一分半）。

有现成技能就先查：`skill(command="list")` 看全部。
按文件类型数个数、文本统计、求和、查 JSON、去重、搜文字、压解压、表格统计都有。
技能能干的事别自己拼命令 —— 但**要产出文件的任务，还是得自己 write_file**。
'@
            $sysFull = $sysFull + $fallback
            Write-Log ("  没匹配到流程模板，注入通用技能速查表")
        }
    } catch { }

# 按任务类型只发相关工具，能省一大截输入 token（每步快十几秒）
$toolsJson = $ToolsSchemaRaw
# 当前实际发给模型的工具名列表。上下文吃紧时 Trim-ToolsToBudget 会改这个。
$script:ActiveFlowTools = @('think', 'finish')
try {
    if ($script:ActiveFlow -and $script:ActiveFlow.tools) {
        $flowTools = @($script:ActiveFlow.tools)
        if ($flowTools.Count -gt 0) {
            $script:ActiveFlowToolCount = $flowTools.Count
            $script:ActiveFlowTools = $flowTools
            $filtered = Get-ToolsJsonWithFinish -Names $flowTools
            if ($filtered -and $filtered.Length -gt 100) {
                $toolsJson = $filtered
                Write-Log ("  只发 " + $flowTools.Count + " 个相关工具（共 " + (@($script:ToolSchemaMap.Keys).Count) + " 个），省输入")
            }
        }
    } else {
        # 没匹配到流程：按意图挑一套，别一股脑发 18 个。
        #
        # 踩过两个坑：
        # ① 砍到 7 个（去掉 make_dir）→「在 deep/a/b/c 建文件」时模型没建目录的工具，
        #    改用 say 问用户，干等 60 秒超时。
        # ② 恢复到 18 个（1315 tok）→ 配上 system 1760 + 输出 600 = 3675，
        #    正好卡在 3696 上限，第 2 步就触发「省上下文」砍工具，
        #    把 write_file 砍掉，模型只好 run_cmd echo > 绕，写出路径错的空文件。
        # 现在按意图发 10-13 个，既不缺必需品，也不会一上来就顶满。
        $defaultTools = Get-ToolNamesFor -Intent $intent -TaskText $TaskText
        $script:ActiveFlowToolCount = @($defaultTools).Count
        $script:ActiveFlowTools = @($defaultTools)
        $dflt = Get-ToolsJsonWithFinish -Names @($defaultTools)
        if ($dflt -and $dflt.Length -gt 100) {
            $toolsJson = $dflt
            Write-Log ("  没匹配到流程（意图 $intent），发 " + @($defaultTools).Count + " 个工具（共 " + (@($script:ToolSchemaMap.Keys).Count) + " 个）")
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
# mod 追加的人设 / 规则 / 文档
if ($script:ActiveMods -and $script:ActiveMods.Count -gt 0) {
    $modPromptText = Get-ModPrompt -Mods $script:ActiveMods
    if ($modPromptText) {
        $sysFull = $sysFull + "`n" + $modPromptText
        Write-Host ("  [mod] 追加人设/文档 " + $modPromptText.Length + " 字符") -ForegroundColor DarkCyan
    }
    $modScriptLog = Invoke-ModScripts -Mods $script:ActiveMods -Root $Root
    foreach ($ml in $modScriptLog) { Write-Host ("  [mod] " + $ml) -ForegroundColor DarkCyan }
}
# 消息顺序直接影响速度：llama 的 prompt cache 按「从头匹配到哪」算，
# 前缀越长越稳定，缓存命中越多。实测同一段 2779 token 的 prompt，
# 冷启动 70.9 秒，热缓存 5.2 秒 —— 差 13 倍。
# 所以固定不变的内容（system）放最前，易变的（工作区快照、当前任务）放最后。
#   system        ← 提示词 + project.md + flow 模板，同一类任务基本不变
#   会话历史       ← 同一轮里只有末尾会增长
#   任务文本       ← 每次变，放最后
#   工作区快照     ← 每次变，单独一条放它后面（原来拼在任务文本里，
#                    导致「任务文本」这条每次都不一样，缓存从这就断了）
$history = @(@{ role = 'system'; content = $sysFull })
foreach ($sm in $sessionMsgs) { $history += $sm }
$history += @{ role = 'user'; content = "任务：$TaskText" }
if ($wsSnapshot.Trim()) { $history += @{ role = 'user'; content = $wsSnapshot.Trim() } }

# 清掉上一次的流式记录，否则面板会把上一条任务的字显示成本次的
Reset-Stream

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
# 第一步「必须先 think」的打回次数。限 2 次，防止模型死活不肯 think 时把上下文撑爆。
$script:thinkNudge = 0
# finish 时「任务要文件但一个都没写」的打回次数。同样限 2 次。
$script:fileNudge = 0
# finish 时「任务是归类/整理但一个文件都没挪」的打回次数。同样限 2 次。
$script:organizeNudge = 0
# 连续出错后逼它分析的打回次数。限 3 次，防它拿这个当拖延借口。
$script:errThinkNudge = 0
# 时效性问题却没联网搜索的打回次数。同样限 2 次。
$script:webNudge = 0
$planList    = @()
$lastToolKey = ''
$repeatCount = 0

for ($step = 1; $step -le $MaxSteps; $step++) {
    # 任务级超时。config 里的 taskTimeoutSeconds 原来只在面板做字段校验，
    # 没有任何地方真正执行 —— 直接跑 agent.ps1 时任务能无限跑下去。
    # 每步开头检查一次：超了就用已有结果收尾，不留半截状态。
    $taskLimit = [int]$Cfg.taskTimeoutSeconds
    if ($taskLimit -gt 0 -and $clock.Elapsed.TotalSeconds -ge $taskLimit) {
        Close-WithResult -State $state -Reason "到任务时限（$taskLimit 秒）" `
            -FailStatus 'timeout' `
            -FailAnswer "任务超时：超过 $taskLimit 秒还没做完。" `
            -StepCount ($step - 1)
        $finished = $true
        break
    }

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

    # ---- 上下文预算兜底 ----
    # 发之前估一下总量：历史 + 工具 schema + 这次输出 ≤ context - 输出余量。
    #
    # 这里的思路改过一版，记下来免得再走回头路：
    # 第一版是「超了就砍工具」。结果「读 orders.jsonl 挑 paid 写文件」那题，
    # think 每步都吐 200-300 tok，历史一路涨到 2800，工具被砍成
    # 13→12→11→9→5→4→3 个 —— 最后连 write_file 都没了，
    # 模型只能反复 think，654 秒什么都没做成。
    #
    # 正确的取舍：工具是「能干活的抓手」，历史是「说过的废话」。
    # 要砍就砍历史，不能砍到连工具都没得用。
    # 工具侧最多砍到 minKeep 个，剩下的全靠裁历史来腾。
    # 输出额度统一留 600（config 里的 maxTokens）。
    #
    # 试过给 build 类 1200 —— 输入预算从 3436 掉到 2836，
    # 8 个工具被砍到只剩 2 个，连 write_script 和 write_file 都没了，任务直接废。
    # 这是死结：要写脚本就得有输出空间，留了空间工具就保不住。
    # 600 是平衡点：够写一个中等脚本，工具也留得下。
    # 更长的脚本本来该拆成多次 write_script + replace_in_file，而不是一次吐 1200 tok。
    # 空转时压到 64：那时只需要它调一次 finish。
    $mt0 = 0
    if ($noToolCount -gt 0) {
        $mt0 = 64
    } else {
        $mt0 = [Math]::Max(500, [int]$Cfg.maxTokens)
    }

    # 输入上限 = context - 这次真正要留的输出 - 一点余量。
    # 注意这里必须和上面 $mt0 用同一个值算，各算各的必然对不上 ——
    # 之前 ctxLimit 按 600 留、实际发 1200，输入占满时输出就没地方，直接 400。
    $ctxLimit = [int]$Cfg.context - $mt0 - 60
    $histTok = Get-HistoryTokens -History $history
    $toolsTokNow = Get-CtxTokens $toolsJson

    # ① 历史太长先裁历史。
    #
    # 尾部原来只留 6 条 —— 一次工具调用本身占 2 条（assistant + tool），
    # 等于只能记住最近 3 步。实测「按类型归类」：模型挪完 3 个文件后，
    # 前面挪过哪些已经被裁掉了，于是同一个 calc.ps1 被挪了 3 次，
    # 目录名在 logs/scripts/脚本/config/data/text/notes 之间乱跳 ——
    # 因为它每轮都像重新开始，压根看不到自己建了哪些目录、挪了哪些文件。
    #
    # 现在改成按条数留 14 条（约 7 步），再按 token 上限兜一层：
    # 光是条数够但内容太长也会超，所以最后再按 token 砍到 tailTok 以内。
    if ($histTok + $toolsTokNow + $mt0 -gt $ctxLimit -and $history.Count -gt 8) {
        $head = @($history[0])
        $hi = 1
        while ($hi -lt $history.Count -and [string]$history[$hi].role -eq 'user' -and $hi -le 3) {
            $head += $history[$hi]; $hi++
        }
        # 尾部取 14 条，但不切断 assistant(tool_calls) 和 tool 的配对
        $tailStart = [Math]::Max($hi, $history.Count - 14)
        while ($tailStart -gt $hi -and [string]$history[$tailStart].role -eq 'tool') { $tailStart-- }
        $tail = @()
        for ($ti = $tailStart; $ti -lt $history.Count; $ti++) { $tail += $history[$ti] }

        # 条数够了但 token 还可能超：从尾部往前累加，装不下就停。
        # 这样保证「留的是最近的」，而不是「留的是随便哪 14 条」。
        $headTok = Get-HistoryTokens -History @($head)
        $budgetForTail = $ctxLimit - $headTok - $mt0 - 120
        $kept = @()
        $acc = 0
        for ($ti = $tail.Count - 1; $ti -ge 0; $ti--) {
            $one = @($tail[$ti])
            $t1 = Get-HistoryTokens -History $one
            if (($acc + $t1) -gt $budgetForTail -and $kept.Count -ge 2) { break }
            $kept = @($one) + $kept
            $acc += $t1
        }
        # 别把 assistant(tool_calls) 和它的 tool 回复拆散
        while ($kept.Count -gt 0 -and [string]$kept[0].role -eq 'tool') { $kept = @($kept | Select-Object -Skip 1) }

        $history = @($head) + @($kept)
        $histTok = Get-HistoryTokens -History $history
        Write-Log ("  [裁历史] 上下文吃紧，历史裁到 " + $history.Count + " 条（$histTok tok）")
    }

    # ② 裁完历史还不够，才动工具，但保底 minKeep 个（think/finish/say + 基础读写）
    $roomForTools = $ctxLimit - $histTok - $mt0
    if ($toolsTokNow -gt $roomForTools -and @($script:ActiveFlowTools).Count -gt 6) {
        $before = @($script:ActiveFlowTools).Count
        $trimmed = Trim-ToolsToBudget -Names $script:ActiveFlowTools -Budget $roomForTools
        if (@($trimmed).Count -lt $before) {
            $script:ActiveFlowTools = $trimmed
            $toolsJson = Get-ToolsJsonWithFinish -Names $trimmed
            Write-Log ("  [省上下文] 历史 $histTok + 工具 $toolsTokNow 要超 $ctxLimit，" +
                       "工具 $before → " + @($trimmed).Count + " 个")
        }
    }

    try {
        # 输出额度 $mt0 在上面已经按任务类型算好了（和 ctxLimit 用的是同一个值），
        # 这里直接用，别再算一遍 —— 两处各算各的迟早会对不上。
        $res = Invoke-Model -Messages $history -ToolsJson $toolsJson -ForceTool:($noToolCount -gt 0) -MaxTokens $mt0
    } catch {
        Write-Host ''
        # 请求超时也要分辨是真慢还是服务挂了。挂了就报卡死，别报个含糊的"超时"。
        if (-not (Test-ModelAlive -TimeoutSec 5)) {
            Close-AsStuck -State $state -Reason '调用模型时服务失去响应。' -StepCount ($step - 1)
            $finished = $true
            break
        }
        # 模型调不通了。但如果之前已经做出来东西了，别把它丢掉判 error。
        # 实测「创建 notes.txt 写三行」：write_file 早就成功写入 16 字符，
        # 只是后面生成 finish 时超时，结果整题被判 error 扣 20 分。
        Close-WithResult -State $state -Reason '模型调用失败' `
            -FailStatus 'error' `
            -FailAnswer "出错了：$($_.Exception.Message)" `
            -StepCount ($step - 1)
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
        # 有结果就收，没结果才认输。
        # 「列出当前目录有哪些文件」就卡在这：list_dir 早返回内容了，
        # 模型却一直空转，最后判 failed，答案白白丢掉。
        if ($noToolCount -ge 2 -and $state.steps.Count -gt 0) {
            $hasObs = $false
            for ($si = $state.steps.Count - 1; $si -ge 0; $si--) {
                if (([string]$state.steps[$si].obs).Trim()) { $hasObs = $true; break }
            }
            if ($hasObs) {
                Close-WithResult -State $state -Reason "连续 $noToolCount 次不调工具" `
                    -FailStatus 'failed' -FailAnswer '出错了：模型只说话不动手。' -StepCount $step
                $finished = $true
                break
            }
        }
        if ($noToolCount -ge 3) {
            $state.status = 'failed'
            $state.answer = '出错了：模型连续三次没有调用工具，也没拿到任何结果。'
            $state.summary = '出错了：模型只说话不动手。'
            $state.elapsed = $clock.Elapsed.TotalSeconds
            Write-State $state
            Write-Log '连续三次不调工具且没有任何观察，收尾'
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

    # ---- 新任务的第一步必须是 think ----
    # Qwen3-4B-Instruct 没有内置 thinking（reasoning 关着，也没有 reasoning_content），
    # 模型容易一上来就瞎动手：实测写计算器时没想清楚就写脚本，
    # 运算符写成 div、测试还是假的（$(12+3) 而不是调用脚本）。
    # 这里强制它动手前先把推理写进 think 工具。
    #
    # 判断口径：只放行 think 和 finish。不能放 say ——
    # 曾经把 say 加进豁免名单（想着「允许它先提问」），结果模型发现
    # 调 list_dir 被拦两次后改用 say，把整段推理当「问题」发出去，
    # 然后干等用户回答 60 秒，一个「列目录」的简单任务就这么废了。
    #
    # 必须限次数。第一版没有上限，模型就是不肯 think，
    # 结果连续被拦 8 次，每次把提示词往 history 里塞一遍，
    # 直接把上下文撑到 400 Bad Request（实测「列目录」跑了 196 秒最后 error）。
    # 拦两次还不听话就放行 —— 宁可少一次思考，不能把任务卡死。
    #
    # web_search 也不拦。实测「查一下今年诺贝尔文学奖得主是谁」：
    # 模型第一个动作就想 web_search（这是最对的反应），被拦去 think 之后
    # 它反而被「未来事件查不到」这个念头带偏，改成 say 问用户了。
    # 直接查比先纠结强，不拦。
    $anyStep = ($state.steps.Count -gt 0)
    if (-not $anyStep -and $toolName -notin @('think', 'finish', 'web_search')) {
        $script:thinkNudge = [int]$script:thinkNudge + 1
        if ($script:thinkNudge -le 2) {
            Write-Log ("  [要求先想] 第 $($script:thinkNudge) 次打回：" + $toolName + " → 先 think")
            $history += @{ role = 'user'; content = (
                "第一步还没写想法。先调 think 工具，把推理写进 content（这个任务要什么结果、" +
                "分几步、每步用什么工具、怎么判断做对了），然后再调 $toolName。") }
            continue
        }
        Write-Log ("  [要求先想] 已经打回 2 次还不肯 think，放行 $toolName")
    }

    $argsObj = $null
    try {
        $argsObj = $call.arguments | ConvertFrom-Json
    } catch {
        Write-Log ('  [参数解析失败] ' + $_.Exception.Message)
    }
    if (-not $argsObj) {
        $argRaw = [string]$call.arguments
        Write-Log ('  [参数为空] 长度=' + $argRaw.Length + ' 内容=[' + $argRaw.Substring(0,[Math]::Min(150,$argRaw.Length)) + ']')
    }

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
    # think 工具的想法在 content 参数里，不在 act.think。
    # 不补这一条，面板上「想法」那一栏对 think 步骤永远是空的 ——
    # 而 think 恰恰是模型唯一认真写推理的地方。
    if ($toolName -eq 'think' -and -not $think.Trim()) {
        $think = [string]$act.content
        if (-not $think.Trim()) { $think = [string]$act.command }
    }

    # ---- think 的内容自动播报给用户 ----
    #
    # 加了 note 工具让模型主动交代进度，实测它一次都不调 ——
    # 4B 手里工具一多，就不会主动想起来用哪个。
    # 但它的 think 里本来就在写「先列目录看有哪些，再建 text 目录挪文件」，
    # 这恰恰就是用户想看的进度。与其指望它自觉，不如直接把它想的推给面板。
    #
    # 每一条 think 都播报。
    # 一开始只播第 2 步之后的，觉得第一步那句"我要先想想"没必要显示 ——
    # 实测这个判断是错的：模型经常只 think 一次就一路连调工具
    # （这次是 list_dir → make_dir → find_files → move_path ×3，全程没再 think），
    # 结果一条播报都没有，用户还是看不到进度。
    if ($toolName -eq 'think' -and $think.Trim().Length -ge 8) {
        $bc = $think.Trim()
        if ($bc.Length -gt 160) { $bc = $bc.Substring(0, 160) + '…' }
        try { Add-SessionTurn -Role 'assistant' -Content ('· ' + $bc) -Ok $true } catch { }
        Write-Log ("  [播报] " + $bc)
    }
    $path  = [string]$act.path

    # ---------- finish ----------
    if ($toolName -eq 'finish') {
        $answer = [string]$act.answer
        if (-not $answer) { $answer = [string]$res.content }

        # ---- 收尾前查：该联网搜的题有没有真搜 ----
        # 实测题库 6 道联网题全部失分，共同原因是「没用到 web_search」。
        # 典型：「查一下今年诺贝尔文学奖得主是谁」——
        # 模型 think 完直接 finish："2026年的诺贝尔文学奖尚未公布，因此得主未知"。
        # 它自认为知道答案，压根没试搜索，等于凭记忆编了个"查不到"。
        #
        # 判据要卡得很紧，不然会误伤。
        # 踩过的坑：「列一下当前目录有哪些文件」——「当前目录」的「当前」
        # 被当成时间词，finish 被拦掉，模型被迫去 web_search「目录有哪些文件 当前」，
        # 搜回来一堆 Word 怎么生成目录的教程。一个本地列目录的活硬推去联网。
        #
        # 现在三个条件同时成立才拦：
        #   ① 带时间/时效词  ② 带明确的信息需求  ③ 不是本地文件操作
        $timeWords = '今年|去年|上月|本周|最新|当前时间|现在几|今天|目前|实时|新闻|发布了|版本号'
        $infoWords = '谁|得主|多少钱|价格|排名|冠军|是什么|叫什么|怎么样|哪些|多少|如何'
        $localOps  = '目录|文件|本机|这个|本地|列表|当前目录|工作区|文件夹|路径'
        # 任务里直接写了「上网/网上/搜一下/百度」——那是明确要求联网，无条件拦。
        # 否则「上网查一下 Windows 11 最新版本号」可能因为别的原因被放过。
        $explicitWeb = ($TaskText -match '上网|网上|联网|在线搜|搜一下|搜一搜|百度|谷歌|bing|搜索')
        $needsWeb = $explicitWeb -or (
                        ($TaskText -match $timeWords) -and
                        ($TaskText -match $infoWords) -and
                        (-not ($TaskText -match $localOps))
                    )
        $didSearch = (@($state.steps | Where-Object {
            [string]$_.tool -in @('web_search', 'web_fetch')
        }).Count -gt 0)
        if ($needsWeb -and -not $didSearch -and $script:webNudge -lt 2) {
            $script:webNudge = [int]$script:webNudge + 1
            Write-Log ("  [该联网] 任务是时效性问题但没搜过，打回让它先 web_search")
            $history += @{ role = 'user'; content = (
                "这个任务问的是「现在/今年/最新」的事实，你的记忆里没有正确答案 —— " +
                "不许凭印象答，也不许说「尚未公布」就收尾。" +
                "先用 web_search 真的搜一次；搜到了再 finish，搜不到就如实说搜不到。") }
            continue
        }

        # ---- 收尾前查文件是否真写了 ----
        # 实测最气人的失分模式：模型 finish 说「summary.txt 内容为：a.txt: 0 / b.txt: 0」，
        # 读起来像做完了，可 summary.txt 根本不存在 —— 那些内容是它现编的。
        # 全量 45 题里 6 个任务栽在这上面（pipe-filter-paid / logic-batch-txt /
        # recover-partial-missing / pipe-jsonl-to-csv 等），全是 status=done 但文件没有。
        #
        # 判据：任务文本里点了 .txt/.csv/.jsonl/.md 这类文件名，
        # 但整趟里没有任何写文件的动作（write_file / append_file / set_line /
        # replace_in_file / write_script），就说明它在编 —— 打回去让它真写。
        # 例外：删除 / 移动 / 改名的任务本来就不写文件。
        # 实测「删掉 victim.txt」——delete_path 已经删成功了，
        # 却被这条判成"没写文件"，打回重来三次，最后绕圈收尾。
        $isNotWriteTask = ($TaskText -match '删|移除|重命名|改名|移动|挪|剪切' -or
                           @($state.steps | Where-Object {
                               [string]$_.tool -in @('delete_path', 'move_path', 'copy_path')
                           }).Count -gt 0)
        $wantFiles = @()
        if (-not $isNotWriteTask) {
            $wantFiles = @([regex]::Matches($TaskText, '[\w\-\.]+\.(txt|csv|jsonl|json|md|ps1|bat|log)') |
                           ForEach-Object { $_.Value } | Select-Object -Unique)
        }
        $wroteSomething = (@($state.steps | Where-Object {
            [string]$_.tool -in @('write_file', 'append_file', 'set_line', 'replace_in_file', 'write_script')
        }).Count -gt 0)
        if ($wantFiles.Count -gt 0 -and -not $wroteSomething -and $script:fileNudge -lt 2) {
            $script:fileNudge = [int]$script:fileNudge + 1
            Write-Log ("  [没写文件] 任务点了 " + ($wantFiles -join ',') + "，但没有任何写文件的动作，打回重来")
            $history += @{ role = 'user'; content = (
                "任务要的是文件：" + ($wantFiles -join '、') + "。你到现在一个文件都没写，" +
                "光在 answer 里说「内容为...」不算做完——那文件根本不存在。" +
                "现在用 write_file 真的把它写出来，写完再 finish。") }
            continue
        }

        # ---- 收尾前查：要「归类/整理」的任务有没有真动文件 ----
        #
        # 实测场景：用户让「把文件按类型归类」。上一轮建好了 5 个空目录但没挪文件；
        # 这一轮模型 list_dir 看到目录已存在，直接 finish：
        #   「目录已存在，无需新建」—— 把"确认目录存在"当成了任务完成，
        #   14 个文件还散在根目录里，一个都没动。
        #
        # 判据：任务含 归类/整理/分类/移动/归档，但整趟没有一次 move_path / copy_path，
        # 而且它用的工具只有"查看类"（list_dir/read_file/find_files）——
        # 说明它只是看了看就说完了。打回去让它真的动手。
        $isOrganizeTask = ($TaskText -match '归类|整理|分类|移动|挪|归档|分门别类')
        $didMove = (@($state.steps | Where-Object {
            [string]$_.tool -in @('move_path', 'copy_path', 'write_script', 'run_ps1', 'run_cmd')
        }).Count -gt 0)
        if ($isOrganizeTask -and -not $didMove -and $script:organizeNudge -lt 2) {
            $script:organizeNudge = [int]$script:organizeNudge + 1
            Write-Log ("  [没归类] 任务是归类/整理，但一趟下来没移动过任何文件，打回重来")
            $history += @{ role = 'user'; content = (
                "这个任务是要把文件**真的挪进对应目录**，不是只确认目录存不存在。" +
                "你到现在一次 move_path / copy_path 都没做过 —— " +
                "「目录已存在，无需新建」不等于做完了，文件还在原地。" +
                "现在用 move_path 把文件一个个挪进对应目录；不确定放哪个就问，但别停下来说完了。") }
            continue
        }

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

    # ---------- note（对用户说话，不等回答）----------
    #
    # 和 say 的区别：say 是问问题、阻塞等 60 秒；note 是播报进度、说完就继续。
    # 这里把这句话写进 session.jsonl，面板每轮读它 —— 用户就能边做边看到进度，
    # 而不是等任务全干完才蹦出一段总结。
    if ($toolName -eq 'note') {
        $msg = [string]$act.message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$act.content }
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$act.text }
        $msg = $msg.Trim()
        if ($msg.Length -lt 2) {
            $obs = '（没写要说什么。把要对用户讲的进度写进 content）'
        } else {
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '…' }
            try { Add-SessionTurn -Role 'assistant' -Content $msg -Ok $true } catch { }
            $state.steps += @{ n = $step; think = $think; tool = 'note'; arg = ''; ok = $true
                               note = $msg; raw = $res.raw_calls; obs = ''; sec = $res.seconds; tok = $res.tokens }
            $state.phase = $msg
            Write-State $state
            Write-Log ("  [{0}] note：{1}" -f $step, $msg)
            $obs = ("已告诉用户：「" + $msg + "」`n接着做下一步，别停在这儿。")
        }
        $history += (Format-ToolCallMessage -Act $act -CallId $callId)
        $history += @{ role = 'tool'; tool_call_id = $callId; content = $obs }
        continue
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

    # ---- 同一个文件别挪第二次 ----
    #
    # 实测「按类型归类」：calc.ps1 被挪了 3 次
    # （scripts\calc.ps1 → 脚本\calc.ps1 → 脚本\calc.ps1），
    # hello.txt 挪了 3 次去了 3 个不同目录。根因是历史被裁到只剩 3 步，
    # 它看不到自己刚挪过什么（历史窗口已加宽，这里再兜一道）。
    # 一个源文件只该挪一次；要挪第二次说明它在乱试，直接说清楚。
    if ($toolName -eq 'move_path' -and $path) {
        $srcKey = ([string]$path) -replace '/', '\'
        $already = $null
        foreach ($dm in @($state.steps | Where-Object { [string]$_.tool -eq 'move_path' })) {
            $a = ([string]$dm.arg) -replace '/', '\'
            if ($a -eq $srcKey -or $a.StartsWith($srcKey + ' ')) { $already = [string]$dm.note }
        }
        if ($already) {
            $obs = ("这个文件已经挪过了（" + $already + "）。别再挪它，接着处理下一个文件；" +
                    "全部处理完就 finish。")
            $state.steps += @{ n = $step; think = $think; tool = 'move_path'; arg = $srcKey
                               ok = $false; note = '重复挪，已跳过'; raw = $res.raw_calls; obs = $obs
                               sec = $res.seconds; tok = $res.tokens; fp2 = '' }
            Write-State $state
            Write-Log ("  [重复挪] " + $srcKey + " 已经挪过，跳过")
            $history += (Format-ToolCallMessage -Act $act -CallId $callId)
            $history += @{ role = 'tool'; tool_call_id = $callId; content = $obs }
            continue
        }
    }

    # ---------- 其余工具：交给 tools.ps1 ----------
    $obs = ''
    $ok = $true

    # ---- 删除前必须用户点头 ----
    # 用户要求：删什么都问。这是硬规矩，不靠模型自觉。
    # 在这里拦比在 tools.ps1 里拦好 —— 这里能拿到面板的确认机制，
    # 而且被拒绝时还能干净地回一句给模型，让它知道这事没成。
    if ($toolName -eq 'delete_path') {
        $delTarget = [string]$act.path
        $approved = Confirm-Delete -Target $delTarget -State $state -StepNum $step
        if (-not $approved) {
            $obs = "用户没有批准删除 $delTarget。这个文件保持原样。" +
                   "别换个说法再删一次，也别用 run_cmd del / Remove-Item 绕过。"
            $state.steps += @{ n = $step; think = $think; tool = 'delete_path'; arg = $delTarget
                               ok = $false; note = '用户拒绝删除'; raw = $res.raw_calls; obs = $obs; sec = $res.seconds }
            Write-State $state
            Write-Log ("  [删除被拒] $delTarget")
            $history += (Format-ToolCallMessage -Act $act -CallId $callId)
            $history += @{ role = 'tool'; tool_call_id = $callId; content = $obs }
            continue
        }
    }

    $state.phase = "执行 $toolName"
    Write-State $state
    try {
        $obs = [string](Invoke-AiTool -Action $act)
        if (-not $obs) { $obs = '（没有输出）' }
    } catch {
        $ok = $false
        $obs = Format-ToolError -Tool $toolName -Arg ([string]$act.path) -Message $_.Exception.Message
    }

    $stepArg = $path
    if ($toolName -eq 'run_cmd' -or $toolName -eq 'syshelp' -or $toolName -eq 'win_doc') { $stepArg = [string]$act.command }
    if (-not $stepArg) { $stepArg = [string]$act.command }
    # move_path / copy_path 显示成「源 → 目标」。
    # 以前只显示 path，日志里全是「move_path calc.ps1」，
    # 看不出它要挪到哪儿 —— 排查时误以为是参数没传。
    if ($toolName -in @('move_path', 'copy_path') -and $act.command) {
        $stepArg = $path + ' → ' + [string]$act.command
    }

    $state.steps += @{ n = $step; think = $think; tool = $toolName; arg = $stepArg; ok = $ok
                       note = (($obs -split "`n")[0]); raw = $res.raw_calls; obs = $obs; sec = $res.seconds; tok = $res.tokens
                       fp2 = [string]$act.command }

    if ($ok -and $planList.Count -gt 0) { $planList = Set-PlanStepDone -Plan $planList }

    $state.elapsed = $clock.Elapsed.TotalSeconds
    Write-State $state
    Write-Log ("  [{0}] {1} -> {2} {3}  ({4} tok / {5:N1}s)" -f $step, $think, $toolName, $stepArg, $res.tokens, $res.seconds)
    Write-Log ("      观察：$obs`n")

    # ---- 做成了事就自动播报一句 ----
    #
    # 模型不会主动调 note（手里工具一多就忘了），只靠它 think 也播不了几条。
    # 那就在「真的动了一个文件」时替它说一句 —— 用户至少能看见东西在动。
    # 只在有实际产出的工具上播，读目录/查文件这种不出声。
    if ($ok -and $toolName -in @('move_path', 'copy_path', 'write_file', 'append_file',
                                 'write_script', 'make_dir', 'delete_path', 'zip_dir', 'unzip')) {
        $bcLine = ''
        if ($toolName -in @('move_path', 'copy_path') -and $act.command) {
            $bcLine = (Get-RelDisplay ([string]$act.path)) + ' → ' + [string]$act.command
        } elseif ($toolName -eq 'make_dir') {
            $bcLine = '建好了 ' + [string]$act.path
        } elseif ($toolName -eq 'write_file' -or $toolName -eq 'write_script') {
            $bcLine = '写好了 ' + [string]$act.path
        } elseif ($toolName -eq 'append_file') {
            $bcLine = '追加到 ' + [string]$act.path
        } elseif ($toolName -eq 'delete_path') {
            $bcLine = '删掉了 ' + [string]$act.path
        }
        if ($bcLine) {
            try { Add-SessionTurn -Role 'assistant' -Content ('· ' + $bcLine) -Ok $true } catch { }
        }
    }

    # ---- 同一个文件别挪两次 ----
    #
    # 实测「按类型归类」：calc.ps1 被挪了 3 次（scripts\calc.ps1 → 脚本\calc.ps1 → 脚本\calc.ps1），
    # hello.txt 挪了 3 次去了 3 个不同目录。原因是历史被裁到只剩 3 步，
    # 它看不到自己刚才挪过什么。
    # 历史窗口已经加宽了，但这条也硬拦一下：一个源文件只应该被挪一次。
    # 挪第二次说明它在乱试，直接告诉它「这个已经挪过了，换下一个」。
    if ($ok -and $toolName -eq 'move_path' -and $Action.path) {
        $srcKey = ([string]$Action.path) -replace '/', '\'
        $prevMoves = @($state.steps | Where-Object {
            [string]$_.tool -eq 'move_path' -and ([string]$_.arg -replace '/', '\') -like ($srcKey + '*')
        })
        # 当前这一步已经在 steps 里了，所以 >1 才算挪过第二次
        if ($prevMoves.Count -gt 1) {
            Write-Log ("  [重复挪] " + $srcKey + " 已经被挪过 " + ($prevMoves.Count - 1) + " 次")
        }
    }

    # ---- 连续出错：逼它停下来分析，别原样重试 ----
    #
    # 4B 出错后的默认反应是"再试一次"，而且试的是同一个调用。
    # 实测归类任务里 move_path 撞「目标已存在」后，它连着改了 4 个目标名，
    # 一次都没回头看错误说的是什么。
    #
    # 所以连续 2 步失败就打回去，要求它先写清三件事：
    # 错在哪、为什么错、下一步具体怎么做（和刚才不一样的做法）。
    if (-not $ok) {
        $failRun = @($state.steps | Select-Object -Last 4 | Where-Object { [string]$_.ok -eq 'False' })
        if ($failRun.Count -ge 2 -and $script:errThinkNudge -lt 3) {
            $script:errThinkNudge = [int]$script:errThinkNudge + 1
            Write-Log ("  [连续出错] 已经连错 " + $failRun.Count + " 次，要求先分析再动手")
            $recentErr = (($failRun | ForEach-Object { "- " + [string]$_.tool + " " + [string]$_.note }) -join "`n")
            $history += @{ role = 'user'; content = (
                "你已经连着出错 " + $failRun.Count + " 次了，别再原样重试。" + "`n" +
                "先停下来想清楚三件事，写进下一步的 think：" + "`n" +
                "1. 错在哪？看上面的错误消息，具体是哪一句。" + "`n" +
                "2. 为什么会错？是我的参数写错了、目标选错了、还是这个工具根本不适合干这件事？" + "`n" +
                "3. 下一步具体怎么做？要和刚才的做法**不一样**。" + "`n`n" +
                "最近几次的失败：" + "`n" + $recentErr + "`n`n" +
                "想不清楚就用 say 问用户，别硬试。") }
            continue
        }
    } else {
        $script:errThinkNudge = 0
    }

    # ---- 防绕圈（按工具名 + 目标 + 关键参数）----
    # 原来的判重是 "工具名|参数"，模型换个参数就绕过去了：
    # list_dir . → list_dir ./ → run_cmd dir → find_files . ，repeatCount 一直是 0，
    # 最后跑到 maxsteps 才停（实测「列出当前目录有哪些文件」跑了 311 秒）。
    # 按「工具名 + 目标路径」判重，不是只看工具名。
    #
    # 但只看路径又会误伤：实测「按类型归类」时模型连续调
    #   find_files . command="*.txt" / "*.ps1" / "*.json"
    # 三次 arg 都是 "."，被当成绕圈强制收尾 —— 其实每次拿到的是不同类型，
    # 全是有用的新信息。所以把 command 也算进指纹里。
    $stepFp = $stepArg + '|' + [string]$Action.command
    $recentSame = @($state.steps | Select-Object -Last 6 | Where-Object {
        ([string]$_.tool -eq $toolName) -and (([string]$_.arg + '|' + [string]$_.fp2) -eq $stepFp)
    })
    # steps 里已经包含当前这一步，减掉它才是「之前重复过几次」
    $sameToolCount = [Math]::Max(0, $recentSame.Count - 1)
    if ($sameToolCount -ge 1) {
        $history += @{ role = 'user'; content = "你刚才已经对 $stepArg 用过 $toolName 了，结果就在上面的观察里。**别对同一个目标重复操作**——要改方式就换工具（比如覆盖了想追加，用 append_file），否则直接 finish。" }
        Write-Log ("  [绕圈] " + $toolName + " 对同一个目标第 " + ($sameToolCount + 1) + " 次")
    }
    # 对同一个目标重复 3 次，用已有结果收尾，别再烧步数
    if ($sameToolCount -ge 2) {
        $finalObs = ($obs -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 8) -join '；'
        $state.status = 'done'
        $state.answer = if ($finalObs) { $finalObs } else { '没能完成这个任务' }
        $state.elapsed = $clock.Elapsed.TotalSeconds
        $state.summary = $state.answer
        Write-State $state
        Write-Log ("  " + $toolName + " 对同一个目标做了 " + ($sameToolCount + 1) + " 次，强制收尾")
        Write-Closing -State $state -Status 'done' -Summary $state.summary -StepCount $step
        $finished = $true
        break
    }

    # ---- list_dir 之后别挨个 read_file：只写在 prompt.md，不在这里硬拦 ----
    # 试过硬拦（检测到 list_dir 后紧跟 read_file 就打回）。
    # 结果模型不读文件了，改用 now {} 和重复 list_dir 来绕 ——
    # 「列目录」耗时从 94 秒涨到 175 秒，越拦越慢。
    # 教训：对 4B 模型，堵一条路它只会换一条，规则放提示词里更有效。
    # 真绕圈由下面的「同一动作重复」和「连续 5 步只读」兜底。

    # ---- 只读工具连着 5 步，也当绕圈 ----
    # 光看目录/读文件不产生新信息，再读下去也是白烧
    $readOnlyTools = @('list_dir', 'read_file', 'read_lines', 'grep_file', 'find_files', 'file_info')
    $lastFive = @($state.steps | Select-Object -Last 5)
    if ($lastFive.Count -ge 5) {
        $allRead = $true
        foreach ($st0 in $lastFive) { if ($readOnlyTools -notcontains [string]$st0.tool) { $allRead = $false; break } }
        if ($allRead) {
            $finalObs2 = ($obs -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 8) -join '；'
            $state.status = 'done'
            $state.answer = if ($finalObs2) { $finalObs2 } else { '没能完成这个任务' }
            $state.elapsed = $clock.Elapsed.TotalSeconds
            $state.summary = $state.answer
            Write-State $state
            Write-Log '  连续 5 步只读操作，强制收尾'
            Write-Closing -State $state -Status 'done' -Summary $state.summary -StepCount $step
            $finished = $true
            break
        }
    }

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

    # ---- 历史裁剪 ----
    # 旧逻辑有两个毛病：
    #   1) 写死 @($history[0], $history[1]) —— 以为 [1] 一定是任务消息，
    #      但带上会话历史后 [1] 是上一轮的话，任务反而被剪掉了
    #   2) 直接取末尾 12 条，会把 assistant(tool_calls) 和它的 tool 响应拆散，
    #      llama.cpp 收到不成对的消息会直接 400
    # 现在：保住 system + 最初的用户消息（任务），末尾按「整组」裁 ——
    # 一个 assistant 带几个 tool 响应算一组，要么整组留要么整组丢。
    if ($history.Count -gt 18) {
        # 从头找连续的用户消息（system 之后的第一组），这是任务描述，必须留
        $headKeep = @($history[0])
        $hi = 1
        while ($hi -lt $history.Count -and $history[$hi].role -eq 'user') {
            $headKeep += $history[$hi]
            $hi++
        }
        # 从尾部往前凑，凑到 12 条左右就停，但不切断 tool 配对
        $tailKeep = @()
        for ($ti2 = $history.Count - 1; $ti2 -ge $hi; $ti2--) {
            $tailKeep = @($history[$ti2]) + $tailKeep
            if ($tailKeep.Count -ge 12) {
                # 如果当前这个还是 tool 响应，说明它上面的 assistant 没带上，继续往前收
                if ($history[$ti2].role -eq 'tool' -and $ti2 -gt $hi) { continue }
                break
            }
        }
        # 若截断点落在 assistant 上（它后面本该跟 tool 响应），把整组丢掉更安全
        while ($tailKeep.Count -gt 0 -and $tailKeep[0].role -eq 'tool') {
            $tailKeep = @($tailKeep | Select-Object -Skip 1)
        }
        $history = $headKeep + $tailKeep
    }
}

if (-not $finished) {
    # 步数用完了。有结果就用结果收尾，别因为「没正常 finish」把做出来的东西丢掉。
    Close-WithResult -State $state -Reason "跑满 $MaxSteps 步" `
        -FailStatus 'maxsteps' `
        -FailAnswer "步数用完了（$MaxSteps 步），任务还没做完。" `
        -StepCount $MaxSteps
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