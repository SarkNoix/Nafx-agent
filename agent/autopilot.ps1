# ============================================================
#  Nafx 自主模式（autopilot）
#
#  用户点「让它自己干一会」时启动。做的事：
#    1. 拿一份「现在可以做什么」的清单（不看别人的文件，只看工作区和桌面）
#    2. 每隔一段随机时间醒一次，自己决定要不要动手
#    3. 真要动手时，走的是同一套 agent.ps1 —— 所以所有安全限制
#       （路径白名单、命令黑名单、脚本检查、删除确认）一个都不少
#
#  为什么不做成"一直跑"：用户明确选了「手动触发才启动」。
#  这个脚本跑完一轮就退出，不驻留。
#
#  用法：
#    powershell -File agent\autopilot.ps1 -ForMinutes 30
#    powershell -File agent\autopilot.ps1 -ForMinutes 30 -Focus "整理桌面"
# ============================================================

param(
    [int]$ForMinutes = 30,          # 干多久就停
    [int]$MinGap = 4,               # 两次唤醒之间最少几分钟
    [int]$MaxGap = 12,              # 最多几分钟
    [string]$Focus = '',            # 可选：给它一个方向
    [switch]$DryRun                 # 只列计划，不真做
)

$ErrorActionPreference = 'Continue'
$AgentDir = $PSScriptRoot
$Root = Split-Path $AgentDir -Parent
$LogDir = Join-Path $AgentDir 'logs'
$AutoLog = Join-Path $LogDir 'autopilot.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function AutoLog {
    param([string]$Text)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text)
    Write-Host $line
    # 用 IO.File.AppendAllText + 显式 UTF8 无 BOM。
    # Add-Content -Encoding UTF8 在 PowerShell 5.1 里第一次写带 BOM、
    # 之后追加不带，中间别的进程按 GBK 读一次就整片乱码 ——
    # 实测日志里全是「鈫?鐘舵€?done」这种，根本没法排查。
    try {
        [IO.File]::AppendAllText($AutoLog, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# 状态文件：面板读它来显示「自主模式在跑吗、下次几点醒」
$AutoState = Join-Path $AgentDir 'autopilot.json'
function Save-AutoState {
    param([hashtable]$Data)
    try {
        $obj = [ordered]@{}
        foreach ($k in $Data.Keys) { $obj[$k] = $Data[$k] }
        $obj['updated'] = (Get-Date -Format 'HH:mm:ss')
        [IO.File]::WriteAllText($AutoState, ($obj | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ------------------------------------------------------------
#  准备：读配置、确认模型活着
# ------------------------------------------------------------
$cfgPath = if ($env:NAFX_CONFIG) { $env:NAFX_CONFIG } else { Join-Path $Root 'config.json' }
if (-not (Test-Path $cfgPath)) { AutoLog "找不到配置：$cfgPath"; exit 1 }
$Cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$port = if ($Cfg.port) { [int]$Cfg.port } else { 8080 }

try {
    $h = Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5
    if ($h.Content -notmatch 'ok') { throw 'not ok' }
} catch {
    AutoLog '模型没在跑，自主模式起不来。先启动 Nafx。'
    Save-AutoState @{ running = $false; reason = '模型未启动' }
    exit 1
}

$ws = if ([IO.Path]::IsPathRooted([string]$Cfg.workspace)) { [string]$Cfg.workspace } else { Join-Path $Root ([string]$Cfg.workspace) }

AutoLog ('自主模式启动：干 ' + $ForMinutes + ' 分钟，间隔 ' + $MinGap + '-' + $MaxGap + ' 分钟')
if ($Focus) { AutoLog ('方向：' + $Focus) }

# ------------------------------------------------------------
#  看现场：工作区和桌面现在什么样
#  只读，不动。让模型自己判断该做什么。
# ------------------------------------------------------------
function Get-Scene {
    $parts = @()

    if (Test-Path $ws) {
        $files = @(Get-ChildItem $ws -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
        if ($files.Count -gt 0) {
            $parts += "工作区（$ws）最近的文件："
            foreach ($f in $files) {
                $parts += ("  {0}  {1}  {2}" -f $f.Name, (Format-Size $f.Length), $f.LastWriteTime.ToString('MM-dd HH:mm'))
            }
        } else {
            $parts += "工作区是空的。"
        }
    }

    $desk = $null
    $c1 = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Desktop' } else { $null }
    $c2 = if ($env:OneDrive) { Join-Path $env:OneDrive 'Desktop' } else { $null }
    foreach ($c in @($c1, $c2)) { if ($c -and (Test-Path $c)) { $desk = $c; break } }
    if ($desk) {
        $dfiles = @(Get-ChildItem $desk -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12)
        if ($dfiles.Count -gt 0) {
            $parts += ""
            $parts += "桌面（$desk）最近的 $($dfiles.Count) 个文件："
            foreach ($f in $dfiles) {
                $parts += ("  {0}  {1}  {2}" -f $f.Name, (Format-Size $f.Length), $f.LastWriteTime.ToString('MM-dd HH:mm'))
            }
        }
    }

    return ($parts -join "`n")
}

function Format-Size {
    param([long]$n)
    if ($n -ge 1MB) { return ('{0:N1} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return ($n.ToString() + ' B')
}

# ------------------------------------------------------------
#  让模型自己决定做什么
#  给它现场情况 + 能做的事，让它自己写一段任务描述。
#  写不出来（或者说"没什么可做的"）就跳过这一轮。
# ------------------------------------------------------------
function Ask-WhatToDo {
    param([string]$Scene)

    # 把「之前做过什么」喂回去。
    #
    # 原来只传现场，模型每轮都像第一次看 —— 实测 8 次任务全都在说
    # 「发现工作区有多个 PowerShell 脚本，建议分析/整理」，
    # 改几个字就重来一遍。它不知道这些话自己已经说过了。
    $histBlock = ''
    if ($script:History -and $script:History.Count -gt 0) {
        $recent = @($script:History | Select-Object -Last 6)
        $histBlock = "`n`n你之前已经提过、也已经做过的（**别再提同样的，换个方向或者跳过**）：`n" +
                     (($recent | ForEach-Object { "- " + $_ }) -join "`n")
    }

    $sys = @"
你是一个在用户电脑上工作的助手，现在是自主模式。
用户已经授权你：可以在工作区和桌面创建、修改文件，可以写脚本并运行。
但是：
- 删除任何文件都必须先问用户（会弹窗，你等回答就行）
- 不许碰系统目录、程序目录、用户配置目录
- 不许关机、改注册表、改服务、建计划任务

看一眼现场，判断**有没有一件具体、能做完、有实际产出的事**值得做。

判断标准（三条都要满足）：
1. **具体**：不是"分析一下""整理一下"，而是"把 log 里的 ERROR 行提出来写成 err.txt"
2. **能做完**：一次任务内（25 步以内）能出结果
3. **有产出**：做完会多出或改变一个文件，而不是只是读了几个文件

**读完文件就算完的不叫做成。** 「分析了脚本功能」「查看了日志内容」这类没有产出的活，别提。

**没想做的事就回答「跳过」。** 宁可跳过，也别为了做事而做事。

回答格式（只要一行）：
  跳过
或者
  任务：<一句话，要具体到做什么、产出什么文件>
"@

    $user = "现在的现场：`n`n$Scene" + $histBlock
    if ($Focus) { $user += "`n`n用户给的方向：" + $Focus }

    $body = @{
        model    = 'qwen'
        messages = @(
            @{ role = 'system'; content = $sys },
            @{ role = 'user';   content = $user }
        )
        max_tokens  = 200
        # 0.3：自主决策要的是"想清楚哪个值得做"，不是"随便挑一个"。
        # 原来 0.6 太发散，每轮挑的都差不多。
        temperature = 0.3
        stream      = $false
    } | ConvertTo-Json -Depth 8 -Compress

    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$port/v1/chat/completions" -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 180
        $o = $r.Content | ConvertFrom-Json
        $txt = [string]$o.choices[0].message.content
        return $txt.Trim()
    } catch {
        AutoLog ('问模型时出错：' + $_.Exception.Message)
        return ''
    }
}

# ------------------------------------------------------------
#  真去做：调 agent.ps1，和手动发任务是同一条路
#  所以所有安全限制都自动生效。
# ------------------------------------------------------------
function Invoke-Task {
    param([string]$TaskText)
    $agent = Join-Path $AgentDir 'agent.ps1'

    # 给自主派出的任务打标记。
    # 面板看到开头的 [自主] 就知道这不是用户发的，
    # 会渲染成醒目标签，避免和手动任务混淆 ——
    # 用户看着看着冒出个任务，得能一眼分清是不是自己发的。
    $marked = '[自主] ' + $TaskText

    AutoLog ('→ 派出任务：' + $TaskText)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # 任务文本走环境变量传，别拼进 -Task 参数 ——
        # 中文 + 空格的组合会被 PowerShell 误当参数名（实测「删掉 victim.txt」
        # 被解析成 -MaxSteps 的值，直接报类型转换错）。
        $env:NAFX_TASK = $marked
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -Command "& '$agent' -Task `$env:NAFX_TASK" 2>&1 | Out-String
    } catch {
        $out = 'agent 启动失败：' + $_.Exception.Message
    }
    $sw.Stop()
    $stateFile = Join-Path $AgentDir 'state.json'
    $status = '?'
    $answerText = ''
    $stepTools = @()
    if (Test-Path $stateFile) {
        try {
            $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $status = [string]$st.status
            $answerText = [string]$st.answer
            $stepTools = @($st.steps | ForEach-Object { [string]$_.tool })
            if ($answerText) { AutoLog ('← 结果：' + $answerText.Substring(0, [Math]::Min(120, $answerText.Length))) }
        } catch { }
    }

    # ---- 判断这一轮到底算不算「做成一件事」----
    #
    # 原来只要 status=done 就算做成，结果 8 次全是 done，但实际一件都没做成：
    # 5 个 read_file 读完，answer 是「文件 big.log 的内容：第 1 行…」——
    # 那只是把它读到的东西复述了一遍，工作区一个字节都没变。
    #
    # 现在要求：done 且至少动过一个文件（写/挪/建/删/跑脚本）。
    # 只读不写的不算做成，也记进历史，让它下轮别再提同类的事。
    $didChange = (@($stepTools | Where-Object {
        $_ -in @('write_file', 'append_file', 'write_script', 'move_path', 'copy_path',
                 'make_dir', 'delete_path', 'run_ps1', 'run_script', 'zip_dir', 'unzip')
    }).Count -gt 0)

    if ($status -eq 'done' -and $didChange) {
        $status = 'done'
    } elseif ($status -eq 'done') {
        AutoLog '← 只是读了文件，没有产出，不算做成'
        $status = 'noop'
    }

    AutoLog ('← 状态 ' + $status + '，用时 ' + [math]::Round($sw.Elapsed.TotalSeconds) + ' 秒')
    return $status
}

# ------------------------------------------------------------
#  主循环
# ------------------------------------------------------------
$endAt = (Get-Date).AddMinutes($ForMinutes)
$round = 0
$done = 0

# ---- 做过什么：跨会话记住 ----
# 实测 8 次自主任务全在提议「发现工作区有多个 PowerShell 脚本，建议分析/整理」，
# 因为它每轮都像第一次看现场，不知道自己已经说过了。
# 这里落一个文件，重启后也能读到，模型每轮都能看见「这些已经做过了」。
$HistoryFile = Join-Path $AgentDir 'autopilot-history.jsonl'
$script:History = @()
try {
    if (Test-Path $HistoryFile) {
        $hl = @(Get-Content $HistoryFile -Encoding UTF8 | Where-Object { $_.Trim() })
        $script:History = @($hl | Select-Object -Last 20)
    }
} catch { $script:History = @() }
if ($script:History.Count -gt 0) { AutoLog ('接过往记录 ' + $script:History.Count + ' 条') }

function Add-AutoHistory {
    param([string]$Line)
    try {
        [IO.File]::AppendAllText($HistoryFile, ($Line -replace '\s+', ' ') + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
    $script:History = @(@($script:History) + @($Line))
    if ($script:History.Count -gt 40) { $script:History = @($script:History | Select-Object -Last 40) }
}

Save-AutoState @{ running = $true; started = (Get-Date -Format 'HH:mm:ss'); until = $endAt.ToString('HH:mm'); rounds = 0; done = 0 }

while ((Get-Date) -lt $endAt) {
    $round++
    AutoLog ('--- 第 ' + $round + ' 轮 ---')

    # 模型还活着吗
    try {
        $h = Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5
        if ($h.Content -notmatch 'ok') { throw 'health' }
    } catch {
        AutoLog '模型没响应了，自主模式退出。'
        break
    }

    $scene = Get-Scene
    $plan = Ask-WhatToDo -Scene $scene

    if (-not $plan) {
        AutoLog '模型没给回答，跳过这轮。'
    } elseif ($plan -match '跳过|skip|没什么|无需|不需要|保持原样') {
        AutoLog ('决定不做：' + $plan.Substring(0, [Math]::Min(60, $plan.Length)))
    } elseif ($plan -match '任务[：:]\s*(.+)') {
        $taskText = $matches[1].Trim()
        if ($taskText.Length -ge 4) {
            if ($DryRun) {
                AutoLog ('[演练] 本会执行：' + $taskText)
            } else {
                $st = Invoke-Task -TaskText $taskText
                if ($st -eq 'done') { $done++ }
                Add-AutoHistory ('[' + (Get-Date -Format 'HH:mm') + '] ' + $st + '：' + $taskText)
            }
        } else {
            AutoLog '任务描述太短，跳过。'
        }
    } else {
        AutoLog ('回答格式不对，跳过：' + $plan.Substring(0, [Math]::Min(60, $plan.Length)))
    }

    Save-AutoState @{ running = $true; started = $endAt.AddMinutes(-$ForMinutes).ToString('HH:mm'); until = $endAt.ToString('HH:mm'); rounds = $round; done = $done }

    # 还没到点就睡一会儿
    $remain = ($endAt - (Get-Date)).TotalMinutes
    if ($remain -le $MinGap) { break }
    $gap = Get-Random -Minimum $MinGap -Maximum ($MaxGap + 1)
    if ($gap -gt $remain) { $gap = [int]$remain }
    $next = (Get-Date).AddMinutes($gap)
    AutoLog ('睡 ' + $gap + ' 分钟，' + $next.ToString('HH:mm') + ' 再醒')

    Save-AutoState @{ running = $true; sleeping = $true; next = $next.ToString('HH:mm:ss'); until = $endAt.ToString('HH:mm'); rounds = $round; done = $done }
    Start-Sleep -Seconds ($gap * 60)
}

AutoLog ('自主模式结束：跑了 ' + $round + ' 轮，做成 ' + $done + ' 件')
Save-AutoState @{ running = $false; finished = (Get-Date -Format 'HH:mm:ss'); rounds = $round; done = $done }
