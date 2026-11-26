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
    [switch]$DryRun,             # 只打印题目和评分规则，不真的跑
    [string]$TaskId = '',        # 只跑指定题号（逗号分隔），方便改完一题定点回归
    [int]$Reasoning = -1         # 强制推理档位 0..4（-1 = 不指定，沿用 agent 默认）
)
$script:ForceReasoning = $Reasoning

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# 执行策略已经由启动参数 -ExecutionPolicy Bypass 管住了，这里只是兜底。
# 之前它是裸调用，一旦 Security 模块加载失败（例如从 pwsh 7 里继承 PSModulePath
# 再起 5.1），配合上面的 ErrorActionPreference='Stop' 会直接把整个训练器打挂。
try { Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction Stop } catch { }

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
        Write-Line ("  [自愈] 上次训练没还原干净，已把 workspace 改回：{0}" -f $fix) 'Yellow'
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
    # 不再改 config.json！
    # 以前是直接改 config.json 的 workspace 指向沙箱，靠 Register-EngineEvent 还原。
    # 但那个事件在 taskkill /F 时根本不触发，config 就永久留在沙箱上——
    # 用户打开面板看到工作区只剩一个 data 目录，以为文件全没了。
    # 现在改成：生成一份沙箱专用配置，让 agent 通过 NAFX_CONFIG 指向它。
    # 这样 config.json 从头到尾一个字都不动。
    $c = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.workspace = $script:SandboxPath
    $sandboxCfg = Join-Path $TrainDir 'sandbox-config.json'
    [IO.File]::WriteAllText($sandboxCfg, ($c | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $env:NAFX_CONFIG = $sandboxCfg
    $script:CfgSwapped = $false   # 没改原文件，不需要还原
}

# 无论正常结束、异常还是 Ctrl+C，都要还原
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Restore-WorkspaceConfig } 2>$null

if ([string]::IsNullOrWhiteSpace($BankPath)) { $BankPath = Join-Path $TrainDir 'bank.json' }
if (-not (Test-Path $BankPath)) { Say "找不到题库：$BankPath" 'Red'; exit 1 }

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
# 有控制台时用彩色输出，被重定向时退回 Write-Output。
# 原因：Write-Host 在 PS 5.1 写的是 Information 流，进程没有控制台时会出问题，
# 之前 8070 编辑器就这么卡死的。训练器要能在后台跑，所以得兼容两种。
function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if ($Host.Name -eq 'ConsoleHost' -and -not $redirected) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Output $Text
    }
}

function Say { param([string]$Text, [string]$Color = 'Gray') Write-Line $Text $Color }
function Rule { param([string]$Ch = '─', [string]$Color = 'DarkGray') Write-Line ($Ch * 70) $Color }

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
    # 删不掉通常是上一个 agent 还没放开文件句柄（Windows 会锁住），所以重试几次。
    # 实在清不掉要明确警告：上一题留下的目录会让下一题看到不该存在的东西，
    # 实测就是「建 data 目录」那题跑完后 data 留在沙箱里，
    # 下一题「创建 x.txt」被写成 data/x.txt，白扣 50 分。
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Test-Path $room)) { break }
        try {
            Remove-Item $room -Recurse -Force -ErrorAction Stop
        } catch {
            Start-Sleep -Milliseconds 600
        }
    }
    if (Test-Path $room) {
        $left = @(Get-ChildItem $room -Recurse -Force -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0) {
            Write-Line ("  [警告] 沙箱没清干净，还残留 " + $left.Count + " 项：" + (($left | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')) 'Yellow'
        }
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

    # think 要单独留步数。
    # 题库里的 maxSteps 是「加 think 之前」定的：一个「创建 a.txt」的题给 4 步，
    # 原本 write_file + read_file + finish 正好够。现在第一步必须是 think，
    # 4 步就变成 think + write + read，finish 没了，被迫「跑满步数收尾」。
    # 实测全量 45 题里 4 个任务这么被卡掉。
    # 这里统一 +2：1 步给 think，1 步给模型常见的「多验证一次」。
    # 不改题库里的数字，是为了让「期望≤N步」的展示仍按真实动作数算。
    $MaxSteps = $MaxSteps + 2

    # 每题开始前清掉跨任务会话历史。
    # agent 会读 session.jsonl 的前 2 轮（让连续对话有上下文），但训练是独立考题：
    # 第 2 题聊过「创建 data 目录」，第 4 题「创建 x.txt」就会接着把文件写成 data/x.txt，
    # 白扣 50 分。考题之间必须互不影响。
    $sessFile = Join-Path (Join-Path $AgentDir 'logs') 'session.jsonl'
    if (Test-Path $sessFile) { Remove-Item $sessFile -Force -ErrorAction SilentlyContinue }
    $stateFile = Join-Path $AgentDir 'state.json'
    $env:NAFX_TASK = $TaskText
    $env:NAFX_ROOM = ''   # 留给将来；目前 agent 用 config 里的 workspace
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # 推理档位：只有外层显式指定了（-Reasoning 0..4）才往下传，
        # 默认 -1 表示沿用 agent 自己的默认档，保证老用法完全不变。
        $agentArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $AgentDir 'agent.ps1'), '-Task', $TaskText, '-MaxSteps', "$MaxSteps")
        if ($script:ForceReasoning -ge 0) { $agentArgs += @('-Reasoning', "$script:ForceReasoning") }
        $out = & powershell.exe @agentArgs 2>&1
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
    # 只算 answer：summary 是面板上的过程摘要，跟「答复多长」不是一回事。
    # 实测「创建 done.txt 写入 ok」答复本身 31 字（完全达标），
    # 拼上 summary 变成 63 字，白扣长度分。
    $answerOnly = ''
    if ($state) { $answerOnly = [string]$state.answer }
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
        'file_matches' {
            # 同一个要求有多种合法写法时用正则，别把判分绑死在某一种实现上。
            # 例：参数校验可以 try/catch，也可以 [int]::TryParse，还可以手写正则。
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $c = [IO.File]::ReadAllText($p)
            $re = [string]$Check[2]
            $okv = [regex]::IsMatch($c, $re)
            return @{ ok = $okv; why = "内容里没有匹配 /$re/" }
        }
        'file_not_matches' {
            # 反过来：内容里不许出现某个正则。
            # 例：paid.jsonl 里不许有 id=2 那条（unpaid），但模型可能写成 "id": 2，
            # 用正则把空格差异吃掉，判分才稳。
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $c = [IO.File]::ReadAllText($p)
            $re = [string]$Check[2]
            $okv = -not [regex]::IsMatch($c, $re)
            return @{ ok = $okv; why = "内容里出现了不该有的 /$re/" }
        }
        'glob_exists' {
            # 项目题不规定文件名/目录名，按文件名模式找，避免把“自主”判成“必须叫 xxx”。
            $pats = @(([string]$Check[1] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $files = @(Get-ChildItem -LiteralPath $Room -Recurse -File -ErrorAction SilentlyContinue)
            $hit = @($files | Where-Object { $n = $_.Name; @($pats | Where-Object { $n -like $_ }).Count -gt 0 })
            $okv = ($hit.Count -gt 0)
            return @{ ok = $okv; why = ('没有找到 ' + ($pats -join ' / ')) }
        }
        'glob_matches' {
            # 在匹配模式的文件里找一段内容，适合“入口脚本里必须有持久化/参数”。
            $pat = [string]$Check[1]
            $re = [string]$Check[2]
            $files = @(Get-ChildItem -LiteralPath $Room -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -like $pat })
            $hit = $false
            foreach ($f in $files) {
                try { $c = [IO.File]::ReadAllText($f.FullName) } catch { continue }
                if ([regex]::IsMatch($c, $re)) { $hit = $true; break }
            }
            return @{ ok = $hit; why = "匹配 $pat 的文件里没有 /$re/" }
        }
        'file_equals' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $c = [IO.File]::ReadAllText($p).Trim()
            $need = ([string]$Check[2]).Trim()
            # 训练时模型多写 CRLF、题库里写 LF，按行比较前先统一换行，避免
            # 内容完全正确却因为换行符不同被判错。
            $c = $c -replace "`r`n", "`n"
            $need = $need -replace "`r`n", "`n"
            $okv = ($c -eq $need)
            return @{ ok = $okv; why = if ($okv) { '' } else { "内容应为「$need」，实际是「$c」" } }
        }
        'file_not_empty' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $len = (Get-Item $p).Length
            return @{ ok = ($len -gt 0); why = "文件是空的" }
        }
        'file_line_count' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $false; why = "文件 $($Check[1]) 不存在" } }
            $want = [int]$Check[2]
            $got = @(Get-Content -LiteralPath $p -Encoding UTF8).Count
            return @{ ok = ($got -eq $want); why = "文件有 $got 行，要求 $want 行" }
        }
        'file_not_contains' {
            $p = Join-Path $Room ([string]$Check[1])
            if (-not (Test-Path $p)) { return @{ ok = $true; why = '' } }
            $c = [IO.File]::ReadAllText($p)
            $bad = [string]$Check[2]
            return @{ ok = (-not $c.Contains($bad)); why = "内容里不该出现「$bad」" }
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
            # 支持写多个工具名，逗号分隔，任一命中就算过。
            # 起因：local-script 要求「写脚本然后运行」，原来只认 run_ps1；
            # 但 write_script 是一步写完直接跑，效果等价，不该判错。
            $wantRaw = [string]$Check[1]
            $wants = @($wantRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $hit = $false
            foreach ($w in $wants) {
                if (@($steps | Where-Object { $_.tool -eq $w -and $_.ok }).Count -gt 0) { $hit = $true; break }
            }
            return @{ ok = $hit; why = ('没有用到 ' + ($wants -join ' 或 ')) }
        }
        'last_run_ok' {
            # write_script / run_ps1 的 step.ok 只表示“调用发出去了”，
            # 脚本本身退出码 -1/1 也算 ok。这里看最后一次运行的真实结果。
            # 只看主动 run_ps1；write_script 的自动空跑不能算“用户真实用法”。
            $runs = @($steps | Where-Object { [string]$_.tool -eq 'run_ps1' })
            if ($runs.Count -eq 0) { return @{ ok = $false; why = '没有用 run_ps1 主动跑过' } }
            $last = $runs[$runs.Count - 1]
            $okv = ([string]$last.note -match '退出码\s+0') -and
                   ([string]$last.obs -notmatch '运行出错|错误：|错误输出|CommandNotFound|无法将.*识别|不是.*cmdlet|ParserError|MissingArgument|缺少参数') -and
                   (-not [string]::IsNullOrWhiteSpace([string]$last.fp2))
            return @{ ok = $okv; why = '最后一次运行失败，或没有带参数真正跑通' }
        }
        'tool_not_used' {
            # 与 tool_used 一样支持逗号分隔：任一出现就算命中。
            $badRaw = [string]$Check[1]
            $bads = @($badRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $hit = @($steps | Where-Object { $_.tool -in $bads }).Count -gt 0
            return @{ ok = (-not $hit); why = ('不该用的 ' + ($bads -join ' / ') + ' 被用到了') }
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
            # 上限看「答复本身」—— 这是用户真正读到的字数；
            # 下限看「答复 + 摘要」—— 摘要里也承载了结论（实测 net-search-basic
            # 答复就俩字「韩江」，全靠摘要补足内容，按下限卡答复本身会误杀）。
            $l = $answerOnly.Trim().Length
            $lo = $answer.Trim().Length
            return @{ ok = ($lo -ge $mn -and $l -le $mx); why = "答复长度 $l（含摘要 $lo），要求 $mn~$mx" }
        }
        'steps_le' {
            $n = [int]$Check[1]
            $real = @($steps | Where-Object { $_.tool -notin @('finish') }).Count
            return @{ ok = ($real -le $n); why = "用了 $real 步，超过 $n 步" }
        }
        'no_hallucinated_number' {
            # 写进文件的内容里，数字必须在任务的观察里出现过 —— 或者能从观察里的数字
            # 简单算出来。实测「sales.csv 三行金额 10/25/65，总和写 100」被判成
            # 凭空编数字：100 确实没在观察里出现过，但它是三行之和。
            # 所以允许：单个数字原样出现、同一份观察里所有数字之和、两两之和。
            $pool = ($steps | ForEach-Object { [string]$_.obs }) -join ' '
            # 把观察里出现过的全部数字攒起来，算「任意几个加起来」的和。
            # 只算「同一份观察里所有数字之和」不够：这题的观察里还有「共 4 行 / 41 字符」，
            # 全加起来是 145，而正确答案 100 是其中 10+25+65 三个 —— 组合和才盖得住。
            $allNums = @($steps | ForEach-Object {
                [regex]::Matches([string]$_.obs, '\d+') | ForEach-Object { [long]$_.Value }
            } | Select-Object -Unique)
            if ($allNums.Count -le 14) {
                $n = $allNums.Count
                for ($mask = 0; $mask -lt (1 -shl $n); $mask++) {
                    $sum = 0L; $cnt = 0
                    for ($b = 0; $b -lt $n; $b++) {
                        if ($mask -band (1 -shl $b)) { $sum += $allNums[$b]; $cnt++ }
                    }
                    if ($cnt -ge 2) { $pool += " $sum" }
                }
            } else {
                foreach ($ob in $steps) {
                    $nums = @([regex]::Matches([string]$ob.obs, '\d+') | ForEach-Object { [long]$_.Value })
                    if ($nums.Count -gt 1) {
                        $sum = 0; foreach ($x in $nums) { $sum += $x }
                        $pool += " $sum"
                    }
                }
            }
            $bad = @()
            foreach ($s in $steps) {
                if ($s.tool -notin @('write_file', 'append_file')) { continue }
                if ([string]$s.arg -match '\.(ps1|bat|json)$') { continue }
                $p = Join-Path $Room ([string]$s.arg)
                # 文件可能因为写错路径根本不存在，或者被安全策略拦下。
                # 这种情况不能把整轮判分带崩，直接算这条检查没通过。
                if (-not (Test-Path -LiteralPath $p)) {
                    $bad += "文件 $($s.arg) 不存在"
                    continue
                }
                try { $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
                catch { $bad += "文件 $($s.arg) 读不出来"; continue }
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
Say ("  模型    {0}" -f $(if ($Cfg.modelMode -eq 'api') { "接口 · $($Cfg.apiModel)" } else { ([IO.Path]::GetFileName($ModelPath) + ' · ' + $Cfg.modelLabel) })) 'DarkGray'
Say ("  目标    {0} 分 / 最多 {1} 轮" -f $Target, $Rounds) 'DarkGray'
Say ("  提示词  {0}" -f $PromptPath) 'DarkGray'
Say ("  你的工作区（不参与训练）  {0}" -f $script:RealWorkspace) 'DarkGray'
Say ("  训练沙箱                {0}" -f $script:SandboxPath) 'DarkGray'
Rule '─'

if ($Cfg.modelMode -eq 'api') {
    # 接口模式不需要本地 llama-server，别去探 8080，直接开跑
    Say ("  接口模式  {0}" -f $Cfg.apiBase) 'Green'
} else {
    if (-not (Test-ModelService)) {
        Say "  模型服务没起来（$Api）。先双击 Nafx.bat 或运行 launcher.ps1。" 'Red'
        exit 1
    }
    Say '  模型服务 在线' 'Green'
}

$allTasks = @(Get-Bank)
if ($Category) { $allTasks = @($allTasks | Where-Object { $_.category -eq $Category }) }
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
    $ids = @($TaskId -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $allTasks = @($allTasks | Where-Object { $ids -contains $_.id })
}
if ($allTasks.Count -eq 0) { Say '  没有题目（检查 -Category、-TaskId 或题库）' 'Red'; exit 1 }
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
        Say ("     评分: {0}" -f (($t.checks | ForEach-Object { 'w{0}: {1}' -f $_.w, (@($_.spec) -join ' ') }) -join ' | ')) 'DarkGray'
        if ($t.forbid.Count -gt 0) { Say ("     扣分: {0}" -f (($t.forbid | ForEach-Object { 'w{0}: {1}' -f $_.w, (@($_.spec) -join ' ') }) -join ' | ')) 'DarkRed' }
    }
    Say ''
    Say '  试运行结束（没有真的调用模型）' 'Yellow'
    exit 0
}

# 训练没有真人点删除确认。只在这个进程/子进程里打开沙箱自动批准，
# agent 侧还会再检查目标必须在 \train\sandbox 内，双重保险。
$env:NAFX_TRAIN_AUTO_APPROVE = '1'

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
    # 不管正常跑完、报错还是被中断，都收尾。
    # 注意：现在不改 config.json 了，只清掉 NAFX_CONFIG 环境变量，
    # 顺便删掉临时生成的 sandbox-config.json。
    Restore-WorkspaceConfig
    if ($env:NAFX_CONFIG -and $env:NAFX_CONFIG -like '*sandbox-config*') { $env:NAFX_CONFIG = '' }
    if ($env:NAFX_TRAIN_AUTO_APPROVE -eq '1') { $env:NAFX_TRAIN_AUTO_APPROVE = '' }
    $sandboxCfg2 = Join-Path $TrainDir 'sandbox-config.json'
    if (Test-Path $sandboxCfg2) { Remove-Item $sandboxCfg2 -Force -ErrorAction SilentlyContinue }
    $check = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Say ''
    Say ("  工作区：{0}（训练没动过 config.json）" -f $check.workspace) 'DarkCyan'
    if ($check.workspace -match 'sandbox') {
        Say ("  ！config 的 workspace 还指向沙箱，手动检查 {0}" -f $CfgPath) 'Red'
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
    # 分类均分：一眼看出是整体弱，还是某一类拖后腿。
    foreach ($cg in ($h.results | Group-Object Category)) {
        $cw = ($cg.Group | Measure-Object -Property Weight -Sum).Sum
        $cs = 0.0
        foreach ($r in $cg.Group) { $cs += $r.Score * $r.Weight }
        $avg = if ($cw -gt 0) { [Math]::Round($cs / $cw, 1) } else { 0 }
        [void]$sb.AppendLine(("  -- {0}：{1} 分（{2} 题）" -f $cg.Name, $avg, $cg.Count))
    }
    [void]$sb.AppendLine('')
}
[IO.File]::WriteAllText($reportPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Say ("  报告：$reportPath") 'DarkGray'
Say ''