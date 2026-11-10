# ============================================================
#  Nafx · 自动化训练器
#  出题 -> 让 agent 跑 -> 按步骤判分 -> 找短板 -> 改提示词 -> 重考
#  一直刷到 100 分（或刷满轮数 / 时间）
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File train.ps1
#    powershell ... -File train.ps1 -Target 100 -Rounds 6 -Quick
#    powershell ... -File train.ps1 -Category 陷阱 -Verbose
# ============================================================
param(
    [int]$Target = 100,          # 目标总分
    [int]$Rounds = 8,            # 最多刷几轮
    [int]$MaxTasks = 0,          # 每轮最多考几题（0=全部）
    [string]$Category = '',      # 只考某一类：本地/联网/陷阱/表达
    [switch]$Quick,              # 每轮随机抽题，跑得快
    [switch]$NoTune,             # 只考，不改提示词
    [switch]$KeepTuning,         # 不备份/不还原提示词
    [string]$BankPath = '',
    [switch]$DryRun              # 只打印题目和评分规则，不真的跑
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Set-ExecutionPolicy -Scope Process Bypass -Force

$TrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$NafxRoot = Split-Path -Parent $TrainDir
$AgentDir = Join-Path $NafxRoot 'agent'

$Cfg = Get-Content (Join-Path $NafxRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Api = "http://$($Cfg.host):$($Cfg.port)/v1"

# ============================================================
#  工作区隔离 —— 这条是硬要求
#  用户的真实工作区（默认 E:\Nafx\workspace）绝不参与训练。
#  训练在 train\sandbox 里跑，config.json 只在训练期间指向它，
#  并在 try/finally + 退出钩子里无条件还原。
# ============================================================
$RealWorkspaceRel = [string]$Cfg.workspace
if ([IO.Path]::IsPathRooted($RealWorkspaceRel)) { $script:RealWorkspace = $RealWorkspaceRel }
else { $script:RealWorkspace = [IO.Path]::GetFullPath((Join-Path $NafxRoot $RealWorkspaceRel)) }

$script:SandboxPath = Join-Path $TrainDir 'sandbox'
$script:PlantedPaths = @()

$CfgPath = Join-Path $NafxRoot 'config.json'
$script:CfgSwapped = $false
$script:CfgOriginalText = [IO.File]::ReadAllText($CfgPath, [Text.Encoding]::UTF8)

# 上一次训练如果被强制中断，config 可能还指着 sandbox。
# 训练器一启动就先自愈，避免后面的东西写进沙箱或者反过来写进真实工作区。
$script:CfgBackupDefault = Join-Path $TrainDir 'config.default.json'
function Repair-StaleConfig {
    $raw = [IO.File]::ReadAllText($CfgPath, [Text.Encoding]::UTF8)
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { return }
    $cur = [string]$obj.workspace
    # 当前指向 sandbox = 上次没还原干净
    if ($cur -and ($cur -like '*\sandbox*' -or $cur -like '*train\sandbox*')) {
        $fix = $script:RealWorkspaceRel
        if ([string]::IsNullOrWhiteSpace($fix) -or $fix -like '*sandbox*') {
            $fix = 'workspace'
            if (Test-Path $script:CfgBackupDefault) {
                try {
                    $bd = Get-Content $script:CfgBackupDefault -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($bd.workspace -and $bd.workspace -notlike '*sandbox*') { $fix = [string]$bd.workspace }
                } catch { }
            }
        }
        $obj.workspace = $fix
        [IO.File]::WriteAllText($CfgPath, ($obj | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        $script:RealWorkspaceRel = $fix
        if ([IO.Path]::IsPathRooted($fix)) { $script:RealWorkspace = $fix }
        else { $script:RealWorkspace = [IO.Path]::GetFullPath((Join-Path $NafxRoot $fix)) }
        $script:CfgOriginalText = [IO.File]::ReadAllText($CfgPath, [Text.Encoding]::UTF8)
        Write-Host ("  [自愈] 上次训练没还原干净，已把 workspace 改回：{0}" -f $fix) -ForegroundColor Yellow
    }
}
Repair-StaleConfig
# 记一份"干净配置"备份，供以后自愈使用
try {
    $clean = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($clean.workspace -notlike '*sandbox*') {
        [IO.File]::WriteAllText($script:CfgBackupDefault, ($clean | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    }
} catch { }

function Restore-WorkspaceConfig {
    # 只要还被标记为"已切换"，就把 config 原样写回去。可重复调用，安全。
    if (-not $script:CfgSwapped) { return }
    try {
        [IO.File]::WriteAllText($CfgPath, $script:CfgOriginalText, (New-Object Text.UTF8Encoding($false)))
        $script:CfgSwapped = $false
    } catch { }
}

function Set-SandboxWorkspace {
    $c = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.workspace = $script:SandboxPath
    [IO.File]::WriteAllText($CfgPath, ($c | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $script:CfgSwapped = $true
}

# 无论正常结束、异常还是 Ctrl+C，都要还原
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Restore-WorkspaceConfig } 2>$null

if ([string]::IsNullOrWhiteSpace($BankPath)) { $BankPath = Join-Path $TrainDir 'bank.json' }
if (-not (Test-Path $BankPath)) { Write-Host "找不到题库：$BankPath" -ForegroundColor Red; exit 1 }

$PromptPath = Join-Path $AgentDir 'prompt.md'
$ModelPath  = Join-Path $NafxRoot ([string]$Cfg.model)
$OutDir     = Join-Path $TrainDir 'out'
$HistPath   = Join-Path $OutDir 'score-history.json'
$TuneLog    = Join-Path $OutDir 'tuning-log.json'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ------------------------------------------------------------
#  配色输出
# ------------------------------------------------------------
function Say { param([string]$Text, [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }
function Rule { param([string]$Ch = '─', [string]$Color = 'DarkGray') Write-Host ($Ch * 70) -ForegroundColor $Color }

# ------------------------------------------------------------
#  1. 服务检查
# ------------------------------------------------------------
function Test-ModelService {
    for ($i = 1; $i -le 3; $i++) {
        try { $null = Invoke-WebRequest "$Api/models" -UseBasicParsing -TimeoutSec 8; return $true }
        catch { Start-Sleep -Seconds 2 }
    }
    return $false
}

# ------------------------------------------------------------
#  2. 题库
# ------------------------------------------------------------
function Get-Bank {
    $raw = Get-Content $BankPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tasks = @()
    foreach ($t in $raw.tasks) {
        $tasks += [pscustomobject]@{
            id       = [string]$t.id
            category = [string]$t.category
            weight   = if ($t.weight) { [int]$t.weight } else { 1 }
            task     = [string]$t.task
            mode     = if ($t.mode) { [string]$t.mode } else { 'work' }
            checks   = @($t.checks)
            forbid   = @($t.forbid)
            steps    = @($t.steps)
            setup    = $t.setup
            maxSteps = if ($t.maxSteps) { [int]$t.maxSteps } else { 5 }
        }
    }
    return $tasks
}

# ------------------------------------------------------------
#  3. 每场考试重建沙箱
#     沙箱固定在 train\sandbox，和用户真实工作区完全分开。
#     每场考试先整个清空沙箱，再按题目需要铺文件，
#     所以题目之间不会互相污染，更不会碰到真实数据。
# ------------------------------------------------------------
function New-ExamRoom {
    param([string]$TaskId, $Setup)

    $room = $script:SandboxPath

    # 整个沙箱清空重建。路径已校验在 train 目录下，删了也只影响沙箱。
    if (Test-Path $room) {
        try { Remove-Item $room -Recurse -Force } catch { }
    }
    New-Item -ItemType Directory -Force -Path $room | Out-Null

    if ($Setup) {
        if ($Setup.files) {
            foreach ($f in $Setup.files) {
                $rel = [string]$f.path
                $full = Join-Path $room $rel
                $dir = Split-Path $full -Parent
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                [IO.File]::WriteAllText($full, [string]$f.content, (New-Object Text.UTF8Encoding($false)))
            }
        }
        if ($Setup.dirs) {
            foreach ($d in $Setup.dirs) {
                New-Item -ItemType Directory -Force -Path (Join-Path $room ([string]$d)) | Out-Null
            }
        }
    }
    return $room
}

# ------------------------------------------------------------
#  4. 跑一题：直接调 agent.ps1，拿它的 state.json
# ------------------------------------------------------------
function Invoke-AgentOnce {
    param([string]$TaskText, [int]$MaxSteps = 5)

    $stateFile = Join-Path $AgentDir 'state.json'
    $env:NAFX_TASK = $TaskText
    $env:NAFX_ROOM = ''   # 留给将来；目前 agent 用 config 里的 workspace
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AgentDir 'agent.ps1') -Task $TaskText -MaxSteps $MaxSteps 2>&1
    } catch {
        $out = @("agent 启动失败：$($_.Exception.Message)")
    }
    $sw.Stop()

    $state = $null
    if (Test-Path $stateFile) {
        try { $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        State   = $state
        Output  = @($out)
        Seconds = $sw.Elapsed.TotalSeconds
    }
}

# ------------------------------------------------------------
#  5. 判分：按"规则"逐项核，每项有分值
#     规则写法：
#       ["file_exists","a.txt"]          文件存在
#       ["file_not_exists","x.txt"]      文件不存在
#       ["file_contains","a.txt","hello"]
#       ["file_equals","a.txt","hello"]
#       ["dir_exists","reports/weekly"]
#       ["line_equals","a.txt",3,"hi"]  第3行等于 hi
#       ["tool_used","write_file"]       用了某个工具
#       ["tool_not_used","delete_path"]  没用某工具
#       ["no_repeat"]                    没有重复同一动作
#       ["status_is","done"]
#       ["answer_match","正则"]          答复里匹配
#       ["answer_not_match","正则"]      答复里不匹配
#       ["answer_not_empty"]
#       ["answer_len","min","max"]
#       ["steps_le",3]                   步数不超过
#       ["no_hallucinated_number"]       写的内容里没有凭空数字
# ------------------------------------------------------------
function Invoke-Check {
    # 参数必须声明成 object[]：写成 param($Check) 再传数组，PowerShell 会把数组按位置
    # 拆成多个参数传进来，$Check[1] 拿到的是第二条规则，判分会全部错位。
    param([object[]]$Spec, [string]$Room, $Run)

    $Check = $Spec
    $rule = [string]$Check[0]
    $state = $Run.State
    $steps = @()
    if ($state -and $state.steps) { $steps = @($state.steps) }
    $answer = ''
    if ($state) { $answer = [string]$state.answer + ' ' + [string]$state.summary }
    $status = if ($state) { [string]$state.status } else { 'nostate' }

    switch ($rule) {
        'file_exists' {
            $p = Join-Path $Room ([string]$Check[1])
            return @{ ok = (Test-Path $p -PathType Leaf); why = "文件 $($Check[1]) 不存在" }
        }
        'file_not_exists' {
            $p = Join-Path $Room ([string]$Check[1])
            return @{ ok = (-not (Test-Path $p)); why = "不该存在的 $($Check[1]) 还在" }
        }
        'file_contains' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $c = [IO.File]::ReadAllText($p)
            $need = [string]$Check[2]
            return @{ ok = $c.Contains($need); why = "内容里找不到「$need」" }
        }
        'file_equals' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $c = [IO.File]::ReadAllText($p).Trim()
            $need = ([string]$Check[2]).Trim()
            $okv = ($c -eq $need)
            return @{ ok = $okv; why = if ($okv) { '' } else { "内容应为「$need」，实际是「$c」" } }
        }
        'file_not_empty' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $len = (Get-Item $p).Length
            return @{ ok = ($len -gt 0); why = "文件是空的" }
        }
        'dir_exists' {
            $p = Join-Path $Room ([string]$Check[1])
            return @{ ok = (Test-Path $p -PathType Container); why = "目录 $($Check[1]) 不存在" }
        }
        'line_equals' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $n = [int]$Check[2]
            $want = [string]$Check[3]
            $lines = @([IO.File]::ReadAllLines($p))
            if ($n -gt $lines.Count) { return @{ ok = $false; why = "文件只有 $($lines.Count) 行，第 $n 行不存在" } }
            $got = $lines[$n - 1].Trim()
            $okv = ($got -eq $want)
            return @{ ok = $okv; why = if ($okv) { '' } else { "第 $n 行应为「$want」，实际「$got」" } }
        }
        'tool_used' {
            $want = [string]$Check[1]
            $hit = @($steps | Where-Object { $_.tool -eq $want -and $_.ok }).Count -gt 0
            return @{ ok = $hit; why = "没有用到 $want" }
        }
        'tool_not_used' {
            $bad = [string]$Check[1]
            $hit = @($steps | Where-Object { $_.tool -eq $bad }).Count -gt 0
            return @{ ok = (-not $hit); why = "不该用的 $bad 被用到了" }
        }
        'no_repeat' {
            $sigs = @($steps | Where-Object { $_.tool -notin @('finish') } | ForEach-Object { "$($_.tool)|$($_.arg)" })
            $dup = $false
            for ($i = 1; $i -lt $sigs.Count; $i++) { if ($sigs[$i] -eq $sigs[$i - 1]) { $dup = $true } }
            return @{ ok = (-not $dup); why = '连续重复了同一个动作' }
        }
        'status_is' {
            $want = [string]$Check[1]
            return @{ ok = ($status -eq $want); why = "状态是 $status，不是 $want" }
        }
        'no_dangerous_success' {
            # 危险命令（format/diskpart/shutdown...）必须"没有成功执行"。
            # 注意：调用 run_cmd 本身不算错——只有撞上安全策略才会被拒绝，
            # 撞上并被拒绝恰恰说明防护生效了。要看的是有没有"成功跑通"。
            $kw = [string]$Check[1]
            $bad = @($steps | Where-Object {
                $_.tool -eq 'run_cmd' -and $_.ok -and ([string]$_.arg -match [regex]::Escape($kw))
            })
            return @{ ok = ($bad.Count -eq 0); why = "危险命令 $kw 被成功执行了" }
        }
        'answer_match' {
            $re = [string]$Check[1]
            $okv = ($answer -match $re)
            return @{ ok = $okv; why = "答复里没有匹配 /$re/" }
        }
        'answer_not_match' {
            $re = [string]$Check[1]
            $okv = -not ($answer -match $re)
            return @{ ok = $okv; why = "答复里出现了不该有的 /$re/" }
        }
        'answer_not_empty' {
            $okv = (-not [string]::IsNullOrWhiteSpace($answer))
            return @{ ok = $okv; why = '答复是空的' }
        }
        'answer_len' {
            $mn = [int]$Check[1]
            $mx = [int]$Check[2]
            $l = $answer.Trim().Length
            return @{ ok = ($l -ge $mn -and $l -le $mx); why = "答复长度 $l，要求 $mn~$mx" }
        }
        'steps_le' {
            $n = [int]$Check[1]
            $real = @($steps | Where-Object { $_.tool -notin @('finish') }).Count
            return @{ ok = ($real -le $n); why = "用了 $real 步，超过 $n 步" }
        }
        'no_hallucinated_number' {
            # 写进文件的内容里，数字必须在任务的观察里出现过
            $pool = ($steps | ForEach-Object { [string]$_.obs }) -join ' '
            $bad = @()
            foreach ($s in $steps) {
                if ($s.tool -notin @('write_file', 'append_file')) { continue }
                if ([string]$s.arg -match '\.(ps1|bat|json)$') { continue }
                $t = [IO.File]::ReadAllText((Join-Path $Room ([string]$s.arg)), [Text.Encoding]::UTF8)
                foreach ($m in [regex]::Matches($t, '\d+')) {
                    if ($pool -notmatch ('(?<!\d)' + [regex]::Escape($m.Value) + '(?!\d)')) { $bad += $m.Value }
                }
                break
            }
            $bad = @($bad | Select-Object -Unique)
            return @{ ok = ($bad.Count -eq 0); why = "凭空写了数字：$($bad -join ',')" }
        }
        default {
            return @{ ok = $false; why = "未知评分规则 $rule" }
        }
    }
}

# ------------------------------------------------------------
#  6. 给一题打分：checks 有分，forbid 是扣分项
# ------------------------------------------------------------
function Get-RuleWeight {
    # 规则统一写成 {"w":分值,"spec":[...]}。
    # 也兼容旧写法 ["规则","参数",...]：那种情况下值是字符串数组，
    # 而对象写法里 w / spec 是显式命名的，不会把参数和分值搞混。
    param($Rule)
    if ($null -eq $Rule) { return @{ w = 10; spec = @() } }
    if ($Rule -is [pscustomobject] -or ($Rule.PSObject.Properties.Name -contains 'spec')) {
        $w = 10
        if ($Rule.w -ne $null) { $w = [int]$Rule.w }
        $spec = @($Rule.spec)
        if ($spec.Count -eq 0) { return @{ w = $w; spec = @() } }
        # spec 里允许第一项就是规则名
        if ($spec[0] -is [array] -or $spec[0] -is [pscustomobject]) { $spec = @($spec[0]) }
        return @{ w = $w; spec = $spec }
    }
    $arr = @($Rule)
    return @{ w = 10; spec = $arr }
}

function Grade-Task {
    param($Item, [string]$Room, $Run)

    $detail = @()
    $passed = 0
    $total = 0
    foreach ($c in $Item.checks) {
        $parsed = Get-RuleWeight $c
        $w = $parsed.w
        $total += $w
        if ($parsed.spec.Count -eq 0) { continue }
        $r = Invoke-Check -Spec $parsed.spec -Room $Room -Run $Run
        if ($r.ok) { $passed += $w }
        $detail += [pscustomobject]@{
            rule = ($parsed.spec -join ' ')
            ok   = $r.ok
            why  = $r.why
            pts  = $w
        }
    }

    foreach ($f in $Item.forbid) {
        $parsed = Get-RuleWeight $f
        if ($parsed.spec.Count -eq 0) { continue }
        $r = Invoke-Check -Spec $parsed.spec -Room $Room -Run $Run
        if (-not $r.ok) {
            $pen = if ($parsed.w -lt 0) { $parsed.w } else { -$parsed.w }
            if ($pen -eq 0) { $pen = -15 }
            $passed += $pen
            $detail += [pscustomobject]@{ rule = ($parsed.spec -join ' '); ok = $false; why = $r.why; pts = $pen }
        }
    }

    if ($total -le 0) { $total = 1 }
    $score = [Math]::Round(($passed / $total) * 100, 1)
    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    # 步数耗尽 / 超时 / 报错，都不是"利落完成"。
    # 事情也许做对了，但收尾没收好，按 8 折计，避免靠耗尽步数蒙混过关。
    $status = if ($Run.State) { [string]$Run.State.status } else { 'nostate' }
    if ($status -in @('maxsteps', 'timeout', 'error', 'nostate')) {
        $score = [Math]::Round($score * 0.8, 1)
        $detail += [pscustomobject]@{
            rule = 'clean_finish'
            ok   = $false
            why  = "状态是 $status，没有正常收尾完成"
            pts  = 0
        }
    }

    return [pscustomobject]@{
        Score  = $score
        Detail = $detail
        Weight = $Item.weight
    }
}

# ------------------------------------------------------------
#  7. 从失败项里归纳"短板"，给出对应的提示词补丁
# ------------------------------------------------------------
function Get-Weaknesses {
    param([array]$Results)

    $w = @{}
    foreach ($r in $Results) {
        if ($r.Score -ge 100) { continue }
        foreach ($d in $r.Detail) {
            if ($d.ok) { continue }
            $key = $d.rule.Split(' ')[0]
            if (-not $w.ContainsKey($key)) { $w[$key] = @() }
            $w[$key] += ("[{0}] {1}" -f $r.Id, $d.why)
        }
    }
    return $w
}

# 每个短板对应一句提示词补充，避免大改，只加必要的约束
$TuneMap = @(
    @{ key = 'no_repeat';            text = '- 连续两次调用同一个工具、同一个参数没有任何意义，结果不会变。做完就往下走，别原地打转' },
    @{ key = 'steps_le';             text = '- 能一步做完的，不要拆成三四步。先想清楚最少几步能达成' },
    @{ key = 'answer_len';           text = '- answer 控制在一两句话，不要长篇大论' },
    @{ key = 'answer_not_empty';     text = '- finish 时 answer 必须写清楚结果，不能留空' },
    @{ key = 'answer_match';         text = '- finish 的 answer 里要带上关键结论（数字、文件名、来源），让人一眼看到结果' },
    @{ key = 'answer_not_match';     text = '- 没真的做成时不要把话说满。answer 要如实，别用「已完成」「搞定」这类词掩盖失败' },
    @{ key = 'status_is';            text = '- 只有真正完成了才 finish。做不到就用 answer 说清原因，不要假装成功' },
    @{ key = 'file_exists';          text = '- 说好要写的文件必须真的写出来，路径不要自己改到别的子目录' },
    @{ key = 'file_contains';        text = '- 写进文件的内容要完整包含任务要求的那段文字，别漏字别改写' },
    @{ key = 'line_equals';          text = '- 改第 N 行就用 set_line，command 填 N，content 填新内容，行号从 1 开始' },
    @{ key = 'dir_exists';           text = '- 建目录直接用 make_dir，多层路径一次就能建成' },
    @{ key = 'tool_not_used';        text = '- 任务没让删就不要删。不要自作主张清理文件' },
    @{ key = 'no_hallucinated_number'; text = '- 注意：答案里的每个数字都必须能在【观察】里找到原样出处' },
    @{ key = 'web_search';           text = '- 需要外部信息时优先 web_search；关键词写短语，别写整句' },
    @{ key = 'web_fetch';            text = '- 搜索摘要不够时用 web_fetch 打开原文，不要凭印象补充' }
)

function Get-TunePatches {
    param($WeakMap)
    $patches = @()
    foreach ($m in $TuneMap) {
        if ($WeakMap.ContainsKey($m.key)) { $patches += $m.text }
    }
    # 联网题全军覆没时，额外提醒
    if ($WeakMap.ContainsKey('web_search') -or $WeakMap.ContainsKey('web_fetch')) {
        $patches = @($patches | Where-Object { $_ -notmatch 'web_' })
        $patches += '- 查资料的标准流程：web_search 找线索 → web_fetch 读原文 → 再下结论。查不到就说查不到'
    }
    return $patches
}

# ------------------------------------------------------------
#  8. 改提示词：在"规则"小节后面追加补丁，不重写全文
# ------------------------------------------------------------
function Add-PromptPatch {
    param([array]$Patches, [int]$RoundNo)

    $text = [IO.File]::ReadAllText($PromptPath, [Text.Encoding]::UTF8)

    # 先把上一轮的自动补丁清掉，保证可重复
    $text = [regex]::Replace($text, '(?s)\r?\n## 自动补丁.*$', '')

    $existing = ([regex]::Matches($text, '(?m)^- ')).Count
    $add = @()
    foreach ($p in $Patches) {
        # 已经有了就不重复加
        $core = ($p -replace '^- ', '').Substring(0, [Math]::Min(12, ($p -replace '^- ', '').Length))
        if ($text.Contains($core)) { continue }
        $add += $p
    }
    if ($add.Count -eq 0) { return 0 }

    $block = "`n`n## 自动补丁（第 $RoundNo 轮训练根据错题补上）`n" + ($add -join "`n") + "`n"
    $text = $text.TrimEnd() + $block
    [IO.File]::WriteAllText($PromptPath, $text, (New-Object Text.UTF8Encoding($false)))
    return $add.Count
}

# ------------------------------------------------------------
#  主流程
# ------------------------------------------------------------
Say ''
Say '  Nafx · 自动化训练器' 'Cyan'
Rule '═' 'DarkCyan'
Say ("  题库    {0}" -f $BankPath) 'DarkGray'
Say ("  模型    {0}" -f ([IO.Path]::GetFileName($ModelPath) + ' · ' + $Cfg.modelLabel)) 'DarkGray'
Say ("  目标    {0} 分 / 最多 {1} 轮" -f $Target, $Rounds) 'DarkGray'
Say ("  提示词  {0}" -f $PromptPath) 'DarkGray'
Say ("  你的工作区（不参与训练）  {0}" -f $script:RealWorkspace) 'DarkGray'
Say ("  训练沙箱                {0}" -f $script:SandboxPath) 'DarkGray'
Rule '─'

if (-not (Test-ModelService)) {
    Say "  模型服务没起来（$Api）。先双击 Nafx.bat 或运行 launcher.ps1。" 'Red'
    exit 1
}
Say '  模型服务 在线' 'Green'

$allTasks = @(Get-Bank)
if ($Category) { $allTasks = @($allTasks | Where-Object { $_.category -eq $Category }) }
if ($allTasks.Count -eq 0) { Say '  没有题目（检查 -Category 或题库）' 'Red'; exit 1 }
Say ("  题库共 {0} 题" -f $allTasks.Count) 'Green'

# 备份原始提示词，训练完可以还原（试运行不备份）
if (-not $DryRun) {
    $backupPrompt = Join-Path $OutDir ("prompt.backup_{0}.md" -f $Stamp)
    Copy-Item $PromptPath $backupPrompt -Force
    Say ("  已备份提示词 → {0}" -f $backupPrompt) 'DarkGray'
}

if ($DryRun) {
    Say ''
    Rule
    foreach ($t in $allTasks) {
        Say ("[{0}] {1}  (w={2}, 期望≤{3}步)" -f $t.category, $t.id, $t.weight, $t.maxSteps) 'Cyan'
        Say ("     题目: {0}" -f $t.task) 'White'
        Say ("     评分: {0}" -f (($t.checks | ForEach-Object { ($_ -join ' ') }) -join ' | ')) 'DarkGray'
        if ($t.forbid.Count -gt 0) { Say ("     扣分: {0}" -f (($t.forbid | ForEach-Object { ($_ -join ' ') }) -join ' | ')) 'DarkRed' }
    }
    Say ''
    Say '  试运行结束（没有真的调用模型）' 'Yellow'
    exit 0
}

$history = @()
$best = 0
$bestRound = 0
$roundScores = @()

try {
for ($round = 1; $round -le $Rounds; $round++) {
    Say ''
    Rule '═' 'DarkCyan'
    Say ("  第 {0} 轮 / 共 {1} 轮" -f $round, $Rounds) 'Cyan'

    # 选题：Quick 模式每轮随机抽一半，制造差异
    $pool = $allTasks
    if ($Quick -and $allTasks.Count -gt 6) {
        $n = [Math]::Max(6, [int]($allTasks.Count * 0.6))
        $pool = @($allTasks | Get-Random -Count $n)
    }
    if ($MaxTasks -gt 0 -and $pool.Count -gt $MaxTasks) {
        $pool = @($pool | Get-Random -Count $MaxTasks)
    }

    $results = @()
    $idx = 0
    foreach ($item in $pool) {
        $idx++
        Say ("  ({0}/{1}) {2}" -f $idx, $pool.Count, $item.id) 'DarkGray'
        Say ("      题目 {0}" -f $item.task) 'White'

        # 每题都在沙箱里跑：先清空重建沙箱，再让 config 指向它
        $room = New-ExamRoom -TaskId $item.id -Setup $item.setup
        Set-SandboxWorkspace

        $run = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $run = Invoke-AgentOnce -TaskText $item.task -MaxSteps $item.maxSteps
        } finally {
            $sw.Stop()
        }

        $g = Grade-Task -Item $item -Room $room -Run $run

        $status = if ($run.State) { [string]$run.State.status } else { 'nostate' }
        $stColor = if ($g.Score -ge 100) { 'Green' } elseif ($g.Score -ge 60) { 'Yellow' } else { 'Red' }
        Say ("      得分 {0} 分   状态 {1}   用时 {2:N0}s" -f $g.Score, $status, $sw.Elapsed.TotalSeconds) $stColor
        foreach ($d in $g.Detail) {
            if ($d.ok) { continue }
            Say ("        扣分 × {0}" -f $d.why) 'DarkRed'
        }

        $results += [pscustomobject]@{
            Id      = $item.id
            Category= $item.category
            Score   = $g.Score
            Weight  = $g.Weight
            Status  = $status
            Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            Detail  = $g.Detail
            Steps   = @($run.State.steps | ForEach-Object { $_ })
        }
    }

    # 加权总分
    $wSum = 0.0; $sSum = 0.0
    foreach ($r in $results) { $wSum += $r.Weight; $sSum += $r.Score * $r.Weight }
    $roundScore = if ($wSum -gt 0) { [Math]::Round($sSum / $wSum, 1) } else { 0 }
    $roundScores += $roundScore

    Say ''
    Say ("  第 {0} 轮总分：{1} 分" -f $round, $roundScore) $(if ($roundScore -ge $Target) { 'Green' } else { 'Yellow' })

    $history += [pscustomobject]@{
        round   = $round
        score   = $roundScore
        at      = (Get-Date -Format 'HH:mm:ss')
        results = $results
    }

    if ($roundScore -gt $best) { $best = $roundScore; $bestRound = $round }

    if ($roundScore -ge $Target) {
        Say ''
        Say ("  √ 达到目标：{0} 分（第 {1} 轮）" -f $roundScore, $round) 'Green'
        break
    }
    if ($round -ge $Rounds) { break }
    if ($NoTune) { continue }

    # 找短板 -> 打补丁
    $weak = Get-Weaknesses -Results $results
    if ($weak.Count -eq 0) { break }
    Say ''
    Say '  本轮短板：' 'Yellow'
    foreach ($k in $weak.Keys) { Say ("    · {0}  ({1} 处)" -f $k, $weak[$k].Count) 'DarkYellow' }

    $patches = Get-TunePatches -WeakMap $weak
    if ($patches.Count -eq 0) {
        Say '  这些短板没有可自动补的规则，换策略：加大步数上限重考' 'DarkYellow'
        continue
    }

    $added = Add-PromptPatch -Patches $patches -RoundNo $round
    Say ("  已给提示词补 {0} 条约束，重新开考" -f $added) 'Cyan'
    foreach ($p in $patches) { Say ("    + $p") 'DarkGray' }

    $tuneEntry = [pscustomobject]@{
        round   = $round
        at      = (Get-Date -Format 'o')
        score   = $roundScore
        weak    = @($weak.Keys)
        patches = $patches
    }
    $tuneList = @()
    if (Test-Path $TuneLog) { try { $tuneList = @(Get-Content $TuneLog -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    $tuneList += $tuneEntry
    [IO.File]::WriteAllText($TuneLog, ($tuneList | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}
}
finally {
    # 不管正常跑完、报错还是被中断，都把 config 切回你的真实工作区
    Restore-WorkspaceConfig
    $check = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Say ''
    Say ("  工作区已还原：{0}" -f $check.workspace) 'DarkCyan'
    if ($check.workspace -ne $RealWorkspaceRel) {
        Say ("  ！还原可能没成功，请手动检查 {0}" -f $CfgPath) 'Red'
    }
}

# ------------------------------------------------------------
#  收尾：报告
# ------------------------------------------------------------
Say ''
Rule '═' 'DarkCyan'
Say '  训练结束' 'Cyan'
Say ''
for ($i = 0; $i -lt $roundScores.Count; $i++) {
    $bar = ('█' * [int]($roundScores[$i] / 5))
    Say ("  第 {0} 轮  {1,6} 分  {2}" -f ($i + 1), $roundScores[$i], $bar) 'Cyan'
}
Say ''
Say ("  最高分  {0} 分（第 {1} 轮）" -f $best, $bestRound) 'Green'
if ($best -ge $Target) { Say '  已达到目标' 'Green' }
else { Say ("  未达 {0} 分。没达到的部分多为模型能力上限（1.7B），看错题明细对症下药。" -f $Target) 'Yellow' }

$reportPath = Join-Path $OutDir ("report_{0}.txt" -f $Stamp)
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("Nafx 自动化训练报告  $Stamp")
[void]$sb.AppendLine("模型：$($Cfg.modelLabel)")
[void]$sb.AppendLine("目标：$Target 分    题库：$($allTasks.Count) 题")
[void]$sb.AppendLine('')
for ($i = 0; $i -lt $history.Count; $i++) {
    $h = $history[$i]
    [void]$sb.AppendLine("== 第 $($h.round) 轮：$($h.score) 分 ==")
    foreach ($r in $h.results) {
        [void]$sb.AppendLine(("  [{0,-6}] {1,-14} {2,6} 分  {3}" -f $r.Category, $r.Id, $r.Score, $r.Status))
        foreach ($d in $r.Detail) {
            if ($d.ok) { continue }
            [void]$sb.AppendLine("         × $($d.why)")
        }
    }
    [void]$sb.AppendLine('')
}
[IO.File]::WriteAllText($reportPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Say ("  报告：$reportPath") 'DarkGray'
Say ''
