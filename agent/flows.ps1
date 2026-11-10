# ============================================================
#  Nafx · 流程模板
#  任务先归到某个 flow，flow 规定必须走哪几步。
#  模型不负责想流程，只负责按流程填参数。
# ============================================================

$script:Flows = @()

function Set-FlowsPath {
    param([string]$Path)
    $script:Flows = @()
    if (-not (Test-Path $Path)) { return }
    try {
        $j = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Flows = @($j.flows)
    } catch { $script:Flows = @() }
}

# ------------------------------------------------------------
#  按任务文本匹配 flow
#  返回 @{ Flow=...; Score=... } 或 $null
# ------------------------------------------------------------
function Get-Flow {
    param([string]$Task = '')

    if ($script:Flows.Count -eq 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($Task)) { return $null }

    $taskLower = $Task.ToLower()

    # 中文没空格，用两字组合来对。
    # 但只收纯中文的两字组 —— 英文的碎片会捣乱：
    #   "orders.jsonl" 里有 js/so/on，会把 "变成json" 这种关键词误判成命中。
    $bigrams = @()
    for ($i = 0; $i -lt $taskLower.Length - 1; $i++) {
        $bg = $taskLower.Substring($i, 2)
        if ($bg -match '^[\u4e00-\u9fa5]{2}$') { $bigrams += $bg }
    }

    $best = $null
    $bestScore = 0
    $bestLen = 0

    foreach ($flow in $script:Flows) {
        $score = 0
        $longest = 0
        foreach ($kw in @($flow.match)) {
            if (-not $kw) { continue }
            $k = ([string]$kw).ToLower()
            # 关键词整个出现在任务里，最强信号
            if ($taskLower.Contains($k)) {
                $score += $k.Length * 2
                if ($k.Length -gt $longest) { $longest = $k.Length }
            }
            else {
                # 退一步：只比中文两字组。英文（json/csv 这类）必须整词出现才算，
                # 否则 orders.jsonl 的 js/so/on 会让「变成json」凭空得分。
                $hit = 0
                for ($bi = 0; $bi -lt $k.Length - 1; $bi++) {
                    $bg = $k.Substring($bi, 2)
                    if ($bg -notmatch '^[\u4e00-\u9fa5]{2}$') { continue }
                    if ($bigrams -contains $bg) { $hit++ }
                }
                if ($hit -ge 2) { $score += $hit }
            }
        }
        # 分数相同就比"命中的最长关键词"——词更长说明更具体。
        # 不然「内存还剩多少」（count 的"多少" 4 分）会压过「内存」（system 也是 4 分），
        # 只是因为它先被遍历到。
        if ($score -gt $bestScore -or ($score -eq $bestScore -and $score -gt 0 -and $longest -gt $bestLen)) {
            $bestScore = $score
            $bestLen = $longest
            $best = $flow
        }
    }

    # 分数太低就当没匹配（避免乱套模板）
    if ($bestScore -lt 3) { return $null }

    return [pscustomobject]@{ Flow = $best; Score = $bestScore }
}

# ------------------------------------------------------------
#  把一个 flow 转成提示词里的一段硬约束
# ------------------------------------------------------------
function Format-Flow {
    param($Flow)

    if (-not $Flow) { return '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## 这个任务的执行模板：$($Flow.name)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**目标**：$($Flow.goal)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**必须按这个顺序走，一步都不能跳：**')
    [void]$sb.AppendLine('')

    foreach ($st in @($Flow.steps)) {
        [void]$sb.AppendLine("$($st.n). $($st.do)")
        if ($st.need) { [void]$sb.AppendLine("   完成标准：$($st.need)") }
    }

    # 常见操作直接给命令，省得模型自己想
    $cheat = @($Flow.cheatsheet)
    if ($cheat.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**这类活儿通常这么干**（照着抄，别自己想）：')
        foreach ($c in $cheat) { [void]$sb.AppendLine("- $c") }
    }

    # 该用哪些工具、别用哪些——这是硬约束里最实的一条
    $sug = @($Flow.suggest_tools)
    if ($sug.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**这个任务该用的工具**（优先从这里面选）：')
        foreach ($s in $sug) { [void]$sb.AppendLine("- $s") }
    }
    $rej = @($Flow.reject_tools)
    if ($rej.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**这些工具跟本任务无关，别调**：' + ($rej -join '、'))
    }

    $forbid = @($Flow.forbid)
    if ($forbid.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**这几件事绝对不能做：**')
        foreach ($f in $forbid) {
            [void]$sb.AppendLine("- $f")
        }
    }

    if ($Flow.example) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**照着这个做：**')
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine([string]$Flow.example)
        [void]$sb.AppendLine('```')
    }

    [void]$sb.AppendLine('')
    return $sb.ToString()
}

# ------------------------------------------------------------
#  检查某一步的工具调用是否符合模板
#  返回 $null 表示没问题，返回字符串表示有问题
# ------------------------------------------------------------
function Test-StepAgainstFlow {
    param(
        $Flow,
        [int]$StepNo,
        [string]$ToolName,
        [string]$ToolArg
    )

    if (-not $Flow) { return $null }

    # 统计类任务：不许一上来就 finish
    if ($Flow.id -eq 'count' -and $StepNo -eq 1 -and $ToolName -eq 'finish') {
        return '这个任务是数数量，第一步必须先跑工具拿到真实数字，不能直接回答。'
    }

    # 创建类任务：第一步应该是 write_file
    if ($Flow.id -eq 'create' -and $StepNo -eq 1 -and $ToolName -in @('finish', 'list_dir')) {
        return '这个任务是创建文件，第一步应该直接 write_file 写出来。'
    }

    # 构建类任务：不许在第一步就 finish
    if ($Flow.id -eq 'build' -and $StepNo -eq 1 -and $ToolName -eq 'finish') {
        return '这个任务是写脚本，第一步应该 plan 列步骤。'
    }

    return $null
}

# ------------------------------------------------------------
#  列出所有 flow（调试用）
# ------------------------------------------------------------
function Get-FlowList {
    return @($script:Flows | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; match = ($_.match -join '、') } })
}
