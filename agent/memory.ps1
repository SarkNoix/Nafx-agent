# ============================================================
#  Nafx · 经验记忆
#  模型训不动，但可以记事。任务失败了把教训写下来，
#  下次遇到类似的先查一遍，就不会在同一个地方摔两次。
# ============================================================

$script:MemoryDir = $null

function Set-MemoryDir {
    param([string]$Path)
    $script:MemoryDir = $Path
    if (-not (Test-Path $script:MemoryDir)) {
        New-Item -ItemType Directory -Force -Path $script:MemoryDir | Out-Null
    }
}

function Get-LessonPath { return (Join-Path $script:MemoryDir 'lessons.jsonl') }
function Get-TaskLogPath { return (Join-Path $script:MemoryDir 'tasks.jsonl') }

# ------------------------------------------------------------
#  文本摘要 / 关键词
#
#  这里故意不调用模型：每轮上下文都要压缩，如果生成摘要也走
#  llama，等于为了省时间又多花一次推理时间，完全不划算。
#  规则摘要只做「便宜、稳定、可回读」的索引：先给每段话一个
#  短摘要 + 关键词，粗筛用它；真正相关的再回读原文。
# ------------------------------------------------------------
function Get-KeyTerms {
    param([string]$Text, [int]$Max = 12)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $t = $Text.ToLowerInvariant()
    $counts = @{}

    # 英文/路径/命令/文件名：这些通常是最硬的线索
    foreach ($m in [regex]::Matches($t, '[a-z0-9_\-./\\]{3,}')) {
        $w = $m.Value.Trim('.', '/', '\')
        if ($w.Length -lt 3) { continue }
        if ($w -match '^(the|and|for|with|this|that|you|are|from|not|have|will|can|use|run|file|path|true|false|null|error|failed)$') { continue }
        $counts[$w] = [int]$counts[$w] + 1
    }

    # 中文按两字组，效果跟现有 Get-Lessons 的打分一致。
    # 单字没有区分度，只用两字组。
    $stop = @(
        '我们','你们','他们','这个','那个','什么','怎么','可以','需要','不是','没有','就是','然后',
        '因为','所以','如果','但是','而且','以及','一个','一下','这些','那些','现在','时候','东西',
        '问题','方法','应该','已经','还是','或者','并且','进行','通过','使用','直接','自己','这里',
        '那里','上面','下面','里面','外面','之后','之前','的话','一样','这样','那样','只是','还有',
        '其中','对于','关于','按照','根据','由于','觉得','知道','看到','得到','起来','出来','回来',
        '过来','过去','不能','不会','不要','不用','比较','非常','特别','尤其','例如','比如','包括',
        '等等','是否','能否','一下','一点','一些','这次','下次','每次','一次'
    )
    for ($i = 0; $i -lt $t.Length - 1; $i++) {
        $a = [int][char]$t[$i]
        $b = [int][char]$t[$i + 1]
        if ($a -lt 0x4e00 -or $a -gt 0x9fff) { continue }
        if ($b -lt 0x4e00 -or $b -gt 0x9fff) { continue }
        $bg = [string]$t[$i] + [string]$t[$i + 1]
        if ($stop -contains $bg) { continue }
        $counts[$bg] = [int]$counts[$bg] + 1
    }

    if ($counts.Count -eq 0) { return @() }
    $ranked = @($counts.Keys | ForEach-Object {
        $term = [string]$_
        [pscustomobject]@{
            Term   = $term
            Weight = ([int]$counts[$term] * 10) + $term.Length
        }
    } | Sort-Object Weight -Descending | Select-Object -First $Max)
    return @($ranked | ForEach-Object { [string]$_.Term })
}

function Get-TextSummary {
    param([string]$Text, [int]$MaxLen = 180)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    # 去掉代码块和多余空白，摘要只保留能判断「这段在说什么」的信息。
    $t = [string]$Text
    $t = [regex]::Replace($t, '```[\s\S]*?```', ' ')
    $t = $t -replace '`', ' '
    $t = $t -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -eq 0) { return '' }

    $head = $t
    if ($head.Length -gt 110) {
        $cut = 110
        $m = [regex]::Match($head.Substring(0, 110), '[。！？!?；;]')
        if ($m.Success -and $m.Index -ge 30) { $cut = $m.Index + 1 }
        $head = $head.Substring(0, $cut).Trim()
        if ($head.Length -lt $t.Length) { $head += '…' }
    }

    $terms = @(Get-KeyTerms -Text $t -Max 10)
    $tag = ''
    if ($terms.Count -gt 0) { $tag = ' [' + ($terms -join ' ') + ']' }

    $s = $head + $tag
    if ($s.Length -gt $MaxLen) { $s = $s.Substring(0, $MaxLen) + '…' }
    return $s
}

# 摘要粗筛用的打分。Text 参数用于第二阶段回读原文后精排：
# 同一套规则先打摘要、再打原文，原文命中更多时自然胜出。
function Get-SummaryScore {
    param([string]$Task, [string]$Summary, [string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Task)) { return [pscustomobject]@{ Score = 0; Hits = 0 } }

    $target = $Summary
    if (-not [string]::IsNullOrWhiteSpace($Text)) { $target = $Text }
    if ([string]::IsNullOrWhiteSpace($target)) { return [pscustomobject]@{ Score = 0; Hits = 0 } }

    $taskLower = $Task.ToLowerInvariant()
    $targetLower = $target.ToLowerInvariant()
    $score = 0
    $hits = 0

    # ① 任务里整词/整段出现在候选里：最强信号
    foreach ($w in ($taskLower -split '[\s,，、;；|/]+')) {
        if ($w.Length -lt 2) { continue }
        if ($targetLower.Contains($w)) { $score += 6; $hits++ }
    }

    # ② 关键词（英文标识符 + 中文两字组）
    foreach ($term in @(Get-KeyTerms -Text $Task -Max 20)) {
        if ($targetLower.Contains([string]$term)) { $score += 2; $hits++ }
    }

    # ③ 任务两字组覆盖率：中文没有空格，这一层是主要召回来源
    $covered = 0
    for ($i = 0; $i -lt $taskLower.Length - 1; $i++) {
        $a = [int][char]$taskLower[$i]
        $b = [int][char]$taskLower[$i + 1]
        if ($a -lt 0x4e00 -or $a -gt 0x9fff) { continue }
        if ($b -lt 0x4e00 -or $b -gt 0x9fff) { continue }
        $bg = [string]$taskLower[$i] + [string]$taskLower[$i + 1]
        if ($targetLower.Contains($bg)) { $covered++ }
    }
    if ($covered -ge 2) { $score += [Math]::Min($covered, 6) }
    elseif ($covered -eq 1) { $score += 1 }

    return [pscustomobject]@{ Score = $score; Hits = $hits }
}

# 通用两级检索：
#   1) 先用摘要粗排，取 CoarseTop，外加「分数接近截断线」的模糊候选；
#   2) 对候选回读原文再精排，原文命中优先；
#   3) 模糊区间宁可多读一段，避免「摘要说不相关、原文其实相关」。
function Select-MemoryItems {
    param(
        [string]$Task = '',
        [array]$Items = @(),
        [string]$SummaryField = 'summary',
        [string]$TextField = 'text',
        [int]$Max = 4,
        [int]$CoarseTop = 10,
        [int]$MinScore = 5,
        [int]$FuzzyMargin = 3
    )
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    if ([string]::IsNullOrWhiteSpace($Task)) {
        return @($Items | Select-Object -Last $Max)
    }

    $field = {
        param($Obj, [string]$Name)
        if ($null -eq $Obj) { return '' }
        if ($Obj -is [System.Collections.IDictionary]) { return [string]$Obj[$Name] }
        $p = $Obj.PSObject.Properties[$Name]
        if ($p) { return [string]$p.Value }
        return ''
    }

    # 第一阶段：只碰摘要，便宜。
    $coarse = @()
    foreach ($it in $Items) {
        $sum = & $field $it $SummaryField
        if ([string]::IsNullOrWhiteSpace($sum)) {
            $sum = Get-TextSummary -Text (& $field $it $TextField) -MaxLen 140
        }
        $c = Get-SummaryScore -Task $Task -Summary $sum
        $coarse += [pscustomobject]@{ Item = $it; Summary = $sum; CoarseScore = [int]$c.Score }
    }
    if ($coarse.Count -eq 0) { return @() }

    $ordered = @($coarse | Sort-Object CoarseScore -Descending)
    $cutoff = 0
    if ($ordered.Count -ge $CoarseTop) { $cutoff = [int]$ordered[$CoarseTop - 1].CoarseScore }

    # 第二阶段：候选才回读原文。截断线附近的也一起读——
    # 这就是「模糊匹配宁可多读一段，别漏」。
    $fine = @()
    foreach ($c in $ordered) {
        $take = ($fine.Count -lt $CoarseTop) -or
                ($c.CoarseScore -gt 0 -and $c.CoarseScore -ge ($cutoff - $FuzzyMargin))
        if (-not $take) { continue }
        $raw = & $field $c.Item $TextField
        $f = Get-SummaryScore -Task $Task -Summary $c.Summary -Text $raw
        $final = [Math]::Max([int]$c.CoarseScore, [int]$f.Score)
        $fine += [pscustomobject]@{
            Item         = $c.Item
            Summary      = $c.Summary
            CoarseScore  = [int]$c.CoarseScore
            TextScore    = [int]$f.Score
            FinalScore   = $final
        }
    }

    $picked = @($fine | Where-Object { $_.FinalScore -ge $MinScore } |
        Sort-Object FinalScore -Descending | Select-Object -First $Max)
    return $picked
}


# ------------------------------------------------------------
#  加一条教训
#  -Task    什么样的任务会用到（写关键词，比如"表格 统计 excel"）
#  -Mistake 踩了什么坑
#  -Fix     正确做法
# ------------------------------------------------------------
function Add-Lesson {
    param(
        [string]$Task = '',
        [string]$Mistake = '',
        [string]$Fix = '',
        [string]$Source = 'model'
    )
    if ([string]::IsNullOrWhiteSpace($Mistake)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Task)) { $Task = '通用' }

    # 去重：同样的话不重复记
    $path = Get-LessonPath
    if (Test-Path $path) {
        try {
            foreach ($line in @(Get-Content $path -Encoding UTF8)) {
                if (-not $line.Trim()) { continue }
                $o = $line | ConvertFrom-Json
                if ($o.mistake -eq $Mistake -and $o.fix -eq $Fix) { return $false }
            }
        } catch { }
    }

    $rec = [ordered]@{
        ts      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        task    = $Task
        mistake = $Mistake
        fix     = $Fix
        # 摘要只做检索索引；原文仍在 mistake/fix 里，随时可回读。
        summary = (Get-TextSummary -Text ($Task + ' ' + $Mistake + ' ' + $Fix) -MaxLen 180)
        source  = $Source
        hit     = 0
    }
    $json = ($rec | ConvertTo-Json -Depth 5 -Compress)
    try {
        [IO.File]::AppendAllText($path, $json + "`n", (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

# ------------------------------------------------------------
#  找跟当前任务相关的教训
#  按关键词重合度打分，取前 N 条
# ------------------------------------------------------------
function Get-Lessons {
    param(
        [string]$Task = '',
        [int]$Max = 4,
        [array]$RejectTools = @()
    )
    $path = Get-LessonPath
    if (-not (Test-Path $path)) { return @() }

    $all = @()
    try {
        foreach ($line in @(Get-Content $path -Encoding UTF8)) {
            if (-not $line.Trim()) { continue }
            try { $all += ($line | ConvertFrom-Json) } catch { }
        }
    } catch { return @() }
    if ($all.Count -eq 0) { return @() }

    if ([string]::IsNullOrWhiteSpace($Task)) {
        return @($all | Select-Object -Last $Max)
    }

    # 每条教训补一个摘要和一个「可回读原文」字段。
    # 老记录没有 summary，加载时现算，不阻塞。
    foreach ($l in $all) {
        $sum = [string]$l.summary
        if ([string]::IsNullOrWhiteSpace($sum)) {
            $sum = Get-TextSummary -Text (([string]$l.task + ' ' + [string]$l.mistake + ' ' + [string]$l.fix)) -MaxLen 160
            $l | Add-Member -NotePropertyName summary -NotePropertyValue $sum -Force
        }
        $searchText = ([string]$l.task + ' ' + [string]$l.mistake + ' ' + [string]$l.fix)
        $l | Add-Member -NotePropertyName _search -NotePropertyValue $searchText -Force
    }

    # 两级检索：摘要粗排 -> 回读 mistake/fix 精排。
    # 阈值 5 沿用原来的判断，避免突然多带一堆无关经验。
    $picked = @(Select-MemoryItems -Task $Task -Items $all -SummaryField 'summary' -TextField '_search' -Max ($Max * 2) -CoarseTop 10 -MinScore 5 -FuzzyMargin 3)

    $result = @()
    foreach ($p in $picked) {
        $l = $p.Item
        $conflict = $false
        if ($RejectTools -and $RejectTools.Count -gt 0) {
            $fixText = [string]$l.fix + ' ' + [string]$l.mistake
            foreach ($rt in $RejectTools) {
                if ([string]$rt -and $fixText.Contains([string]$rt)) { $conflict = $true; break }
            }
        }
        if (-not $conflict) { $result += $l }
        if ($result.Count -ge $Max) { break }
    }
    return $result
}

# ------------------------------------------------------------
#  把教训拼成提示词里的一段
# ------------------------------------------------------------
function Format-Lessons {
    param([array]$Lessons)
    if (-not $Lessons -or $Lessons.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## 以前踩过的坑（记住这些，别再犯）')
    [void]$sb.AppendLine('')
    foreach ($l in $Lessons) {
        [void]$sb.AppendLine('- 坑：' + $l.mistake)
        if ($l.fix) { [void]$sb.AppendLine('  对：' + $l.fix) }
    }
    [void]$sb.AppendLine('')
    return $sb.ToString()
}

# ------------------------------------------------------------
#  标记某条教训被用上了（用来判断哪条真的有用）
# ------------------------------------------------------------
function Add-LessonHit {
    param([array]$Lessons)
    if (-not $Lessons -or $Lessons.Count -eq 0) { return }
    $path = Get-LessonPath
    if (-not (Test-Path $path)) { return }
    try {
        $lines = @(Get-Content $path -Encoding UTF8)
        $out = @()
        foreach ($line in $lines) {
            if (-not $line.Trim()) { continue }
            try {
                $o = $line | ConvertFrom-Json
                foreach ($l in $Lessons) {
                    if ($o.mistake -eq $l.mistake) { $o.hit = [int]$o.hit + 1 }
                }
                $out += ($o | ConvertTo-Json -Compress)
            } catch { $out += $line }
        }
        [IO.File]::WriteAllLines($path, $out, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ------------------------------------------------------------
#  记一次任务的结果（原始数据，用来后续提炼教训）
# ------------------------------------------------------------
function Add-TaskRecord {
    param(
        [string]$Task = '',
        [string]$Status = '',
        [array]$Steps = @(),
        [string]$Answer = ''
    )
    $path = Get-TaskLogPath
    $rec = [ordered]@{
        ts     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        task   = $Task
        status = $Status
        steps  = @($Steps | ForEach-Object {
            [ordered]@{ tool = $_.tool; arg = $_.arg; ok = $_.ok; note = ([string]$_.note) }
        })
        answer = $Answer
        summary = (Get-TextSummary -Text ($Task + ' ' + $Status + ' ' + $Answer) -MaxLen 200)
    }
    try {
        $json = ($rec | ConvertTo-Json -Compress -Depth 5)
        [IO.File]::AppendAllText($path, $json + "`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ------------------------------------------------------------
#  从失败的任务里自动提炼教训（不用模型，靠规则）
# ------------------------------------------------------------
function Get-AutoLessons {
    param([string]$Task = '', [array]$Steps = @(), [string]$Status = '')

    $found = @()
    if (-not $Steps -or $Steps.Count -eq 0) { return $found }

    $failed = @($Steps | Where-Object { $_.ok -eq $false })
    $toolCount = @($Steps | Group-Object { $_.tool })

    # 同一个工具调了 4 次以上
    foreach ($g in $toolCount) {
        if ($g.Count -ge 4) {
            $found += [pscustomobject]@{
                Mistake = ("'$($g.Name)' 在同一个任务里调了 $($g.Count) 次")
                Fix     = '调两次没结果就换工具，或者直接用 skill 里的现成脚本'
            }
        }
    }

    # 失败的那一步
    foreach ($f in ($failed | Select-Object -First 2)) {
        $note = [string]$f.note
        if ($note.Length -gt 60) { $note = $note.Substring(0,60) + '…' }
        if ($note) {
            $found += [pscustomobject]@{
                Mistake = ("用 $($f.tool) 做 '$($f.arg)' 时报错：" + $note)
                Fix     = '这个参数或路径有问题，用前先 list_dir 或 read_file 确认'
            }
        }
    }

    # 跑满步数或超时
    # 注意：这里绝不把 $Task 全文写进教训。任务描述里常带具体路径（data/orders.jsonl 之类），
    # 存进去之后下一题会被模型当成「该用这个路径」，把 x.txt 写成 data/x.txt。
    # 只记「哪个工具在绕圈」「是不是超时」这种跟具体任务无关的信息。
    if ($Status -in @('maxsteps','timeout','stuck')) {
        $loopTool = @($Steps | Group-Object { $_.tool } | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 1)
        $lastTool = ''
        if ($Steps.Count -gt 0) { $lastTool = [string]$Steps[-1].tool }
        if ($loopTool.Count -gt 0) {
            $found += [pscustomobject]@{
                Mistake = ("'" + $loopTool[0].Name + "' 在同一个任务里被反复调用了 " + $loopTool[0].Count + " 次")
                Fix     = '同一个工具调两次还没结果就换思路：换工具，或者直接用观察里的内容收尾'
            }
        }
        if ($Status -eq 'timeout') {
            $found += [pscustomobject]@{
                Mistake = '模型响应超时，任务没能正常收尾'
                Fix     = '上下文太长容易超时，步骤别太啰嗦，做完动作就收'
            }
        } elseif ($Status -eq 'maxsteps' -and $loopTool.Count -eq 0) {
            $found += [pscustomobject]@{
                Mistake = ("跑满步数还没收尾，最后一步是 " + $lastTool)
                Fix     = '该做的动作做完就直接 finish，别反复确认'
            }
        }
    }
    return $found
}

# ------------------------------------------------------------
#  统计
# ------------------------------------------------------------
function Get-MemoryStats {
    $lessons = 0
    $tasks = 0
    $lp = Get-LessonPath
    $tp = Get-TaskLogPath
    if (Test-Path $lp) { $lessons = @(Get-Content $lp -Encoding UTF8 | Where-Object { $_.Trim() }).Count }
    if (Test-Path $tp) { $tasks = @(Get-Content $tp -Encoding UTF8 | Where-Object { $_.Trim() }).Count }
    return [pscustomobject]@{ Lessons = $lessons; Tasks = $tasks }
}