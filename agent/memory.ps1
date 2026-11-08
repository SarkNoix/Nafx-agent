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
        source  = $Source
        hit     = 0
    }
    $json = ($rec | ConvertTo-Json -Compress)
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

    $taskLower = $Task.ToLower()

    # 中文没空格，得按"两字一组"比。比如"写个计算器脚本"拆成
    # 写个/个计/计算/算器/器脚/脚本，跟教训里的关键词对得上的就算分。
    $taskBigrams = @()
    for ($bi = 0; $bi -lt $taskLower.Length - 1; $bi++) {
        $taskBigrams += $taskLower.Substring($bi, 2)
    }

    $scored = @()
    foreach ($l in $all) {
        $score = 0
        $key = ([string]$l.task).ToLower()

        # ① 教训里的关键词整个出现在任务里（最强信号）
        foreach ($w in ($key -split '[\s,，、;；]+')) {
            if ($w.Length -lt 2) { continue }
            if ($taskLower.Contains($w)) { $score += 6 }
        }

        # ② 两字组重合数（中文主要靠这个）
        $bigramHit = 0
        foreach ($bg in $taskBigrams) {
            if ($key.Contains($bg)) { $bigramHit++ }
        }
        if ($bigramHit -ge 2) { $score += [Math]::Min($bigramHit, 6) }
        elseif ($bigramHit -eq 1) { $score += 2 }

        # ③ 被用过说明真有用
        $score += [int]$l.hit

        if ($score -ge 5) {
            $scored += [pscustomobject]@{ Score = $score; Lesson = $l }
        }
    }

    if ($scored.Count -eq 0) { return @() }

    # 如果当前任务的模板明确说了"别用某个工具"，
    # 而某条经验却在推荐这个工具，那条经验就是有害的，扔掉。
    $picked = @($scored | Sort-Object Score -Descending | Select-Object -First ($Max * 2))
    $result = @()
    foreach ($p in $picked) {
        $conflict = $false
        if ($RejectTools -and $RejectTools.Count -gt 0) {
            $fixText = [string]$p.Lesson.fix + ' ' + [string]$p.Lesson.mistake
            foreach ($rt in $RejectTools) {
                if ([string]$rt -and $fixText.Contains([string]$rt)) { $conflict = $true; break }
            }
        }
        if (-not $conflict) { $result += $p.Lesson }
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
    if ($Status -in @('maxsteps','timeout','stuck')) {
        $found += [pscustomobject]@{
            Mistake = ("任务 '$Task' 最后没能收尾（$Status）")
            Fix     = '任务拆小一点，或者先 skill(command="list") 看有没有现成脚本'
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
