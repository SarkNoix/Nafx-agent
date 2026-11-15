# ============================================================
#  本地 AI 智能体 · 工具实现
#  所有文件操作被限制在 $AiRoot 目录内（沙箱）
# ============================================================

$script:AiRoot = 'D:\AI\workspace'
$script:MaxOutput = 3000      # 返回给模型的最长观察字符数
$script:RunTimeout = 30       # 运行 bat/ps1 的超时秒数
# 本文件所在目录（find 手册用）
$script:ToolDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 经验记忆（记教训用的）
$script:MemoryReady = $false
try {
    $memMod = Join-Path $script:ToolDir 'memory.ps1'
    if (Test-Path $memMod) {
        . $memMod
        Set-MemoryDir (Join-Path $script:ToolDir 'memory')
        $script:MemoryReady = $true
    }
} catch { $script:MemoryReady = $false }

# 联网工具单独一个模块，找不到就降级为"联网不可用"，不影响本地干活
$script:WebReady = $false
try {
    $webMod = Join-Path $script:ToolDir 'webtools.ps1'
    if (Test-Path $webMod) { . $webMod; $script:WebReady = $true }
} catch { $script:WebReady = $false }

function Set-AiRoot {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 30,
        [int]$MaxOutput = 0,
        [switch]$AllowAnyPath
    )
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $script:AiRoot = $Path }
    if ($TimeoutSeconds -gt 0) { $script:RunTimeout = $TimeoutSeconds }
    if ($MaxOutput -gt 0) { $script:MaxOutput = $MaxOutput }
    $script:AiAllowAnyPath = [bool]$AllowAnyPath
}

function Initialize-AiWorkspace {
    New-Item -ItemType Directory -Force -Path $script:AiRoot | Out-Null
    # 不预先建 data 目录。
    # 以前每次启动都建一个 data/，模型看到它存在，执行「创建 x.txt」时会先
    # make_dir data（返回「已经存在了」），然后顺手把文件写成 data/x.txt，
    # 根目录下什么都没有。要 data 目录时任务自己会建。
}

# 解析路径。allowAnyPath 打开后可以访问整个电脑，
# 但系统关键位置仍然拦下——AI 管理电脑不等于让它把 Windows 删了。
function Resolve-AiPath {
    param([string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($RelPath)) { throw 'path 不能为空' }

    $raw = $RelPath.Trim()
    # 允许写绝对的 Windows 路径（D:\code\x.txt）和 ~ 开头的家目录
    if ($raw -match '^~[\\/]') { $raw = $raw -replace '^~', $env:USERPROFILE }
    $isAbsolute = [IO.Path]::IsPathRooted($raw)

    try {
        if ($isAbsolute -and $script:AiAllowAnyPath) {
            $full = [IO.Path]::GetFullPath($raw)
        } else {
            $rootFull = [IO.Path]::GetFullPath($script:AiRoot).TrimEnd('\')
            $rel = $raw -replace '/', '\'
            $full = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, $rel))
        }
    } catch {
        throw ("路径不合法：$RelPath。路径里不能有 * ? | 这类字符。")
    }

    if (-not $script:AiAllowAnyPath) {
        $rootFull = [IO.Path]::GetFullPath($script:AiRoot).TrimEnd('\')
        if (-not ($full -eq $rootFull -or $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw "路径越界：$RelPath。只允许操作 workspace 内的文件。"
        }
        return $full
    }

    # 系统关键位置：只准许读，不许写改删
    if (Test-IsProtectedPath $full) { return $full }
    # ---- 路径自动纠正 ----
    # 模型经常自己给文件名加目录前缀：任务说「sales.csv」，它调 data/sales.csv。
    # 文件明明在 workspace 根下，它却报「不存在」，然后开始瞎找。
    # 这里兜一下：原路径不存在时，去掉第一层目录再试一次。
    if (-not (Test-Path -LiteralPath $full)) {
        $rootFull2 = [IO.Path]::GetFullPath($script:AiRoot).TrimEnd('\')
        if ($full.StartsWith($rootFull2 + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $relPart = $full.Substring($rootFull2.Length + 1)
            $parts = $relPart -split '\\'
            if ($parts.Count -ge 2) {
                $rest = ($parts[1..($parts.Count - 1)] -join '\')
                $candidate = Join-Path $rootFull2 $rest
                if (Test-Path -LiteralPath $candidate) {
                    [Console]::Error.WriteLine("  [路径纠正] $RelPath 不存在，已改用 $rest")
                    return $candidate
                }
            }
        }
    }
    return $full
}

# 这些地方绝对不许 AI 写入或删除
function Test-IsProtectedPath {
    param([string]$Full)
    $f = $Full.TrimEnd('\')

    # 盘符根目录本身（C:\ 或 D:\）不许写删，但不代表下面的目录也不许
    # 盘符根目录本身、或直接扔在盘根下的文件，都不许写删
    if ($f -match '^[A-Za-z]:$') { return $true }
    $parent = $null
    try { $parent = [IO.Path]::GetDirectoryName($f) } catch { }
    if ($parent -and ($parent.TrimEnd('\') -match '^[A-Za-z]:$')) { return $true }

    $sys = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $protected = @(
        $sys,
        (Join-Path $sys 'System32'),
        (Join-Path $sys 'SysWOW64'),
        (Join-Path $sys 'WinSxS'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($pfx in $protected) {
        $p2 = ([string]$pfx).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($p2)) { continue }
        if ($f -eq $p2) { return $true }
        if ($f.StartsWith($p2 + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# 写/删之前统一问一句：这个位置是不是动不得
function Assert-CanWrite {
    param([string]$Full, [string]$RelPath)
    if (-not $script:AiAllowAnyPath) { return }
    if (Test-IsProtectedPath $Full) {
        throw ("这里动不得：$RelPath。Windows 系统目录、Program Files、ProgramData 和盘符根目录不许写入或删除。" +
               "要动手请换个目录，比如桌面、文档或 D:\ 下自己建的文件夹。")
    }
}

function Get-RelDisplay {
    param([string]$FullPath)
    $rootFull = [IO.Path]::GetFullPath($script:AiRoot).TrimEnd('\')
    # 必须在 workspace 里面才做相对化。
    # 以前只看长度就裁，路径在 workspace 外面时会裁错：
    # E:\Nafx\skills\clean_logs.md 会变成 "an_logs.md"（少了 3 个字符）。
    if ($FullPath.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($rootFull.Length + 1)
    }
    # 在项目目录里但不在 workspace：按项目根做相对路径
    try {
        $proj = Split-Path $script:ToolDir -Parent
        if ($FullPath.StartsWith($proj + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $FullPath.Substring($proj.Length + 1)
        }
    } catch { }
    return $FullPath
}

function Trim-AiText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $script:MaxOutput) { return $Text }
    return $Text.Substring(0, $script:MaxOutput) + "`n...[已截断，共 $($Text.Length) 字符]"
}

# 统一决定写文件用什么编码，所有写操作都必须走这里：
#  - .ps1 / .js / .jse 必须带 BOM（脚本引擎读无 BOM 文件会按 GBK 解，中文全乱）
#  - .bat/.cmd 绝对不能带 BOM（cmd 会把 BOM 当第一行内容）
#  - 其他文件按无 BOM UTF-8
# 之前只有 write_file 走了这套判断，set_line / replace_in_file / append_file
# 写回去时又退回无 BOM，结果脚本被改一次中文就烂一次。
function Get-AiFileEncoding([string]$fullPath) {
    # 三种脚本的 BOM 需求各不相同，都是实测出来的：
    #  - .ps1     必须带 BOM（PowerShell 5.1 读无 BOM 文件按 GBK 解，中文全乱）
    #  - .js/.jse 绝对不能带 BOM（JScript 会把 BOM 当代码，报"缺少 ';'"）
    #  - .bat/.cmd 绝对不能带 BOM（cmd 会把 BOM 当第一行内容）
    if ($fullPath -match '\.ps1$') { return (New-Object System.Text.UTF8Encoding($true)) }
    return (New-Object System.Text.UTF8Encoding($false))
}

function Write-AiFileText([string]$fullPath, [string]$text) {
    $enc = Get-AiFileEncoding $fullPath
    # PowerShell 的 WriteAllLines 会自动按系统换行拼，这里先统一成 CRLF 再整体写
    [IO.File]::WriteAllText($fullPath, $text, $enc)
}

function Write-AiFileLines([string]$fullPath, [string[]]$lines) {
    Write-AiFileText $fullPath (($lines -join "`r`n") + "`r`n")
}

# 在多本手册里找最相关的一节：
# 先按标题匹配，再按正文匹配；两本都找，取第一个命中的。
function Find-ManualSection {
    param([array]$Targets, [string]$Topic)

    foreach ($t in $Targets) {
        $lines = [IO.File]::ReadAllText($t.Path, [Text.Encoding]::UTF8) -split "`r?`n"
        if ($lines.Count -lt 2) { continue }

        $idx = -1
        # 1) 标题里含关键词
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^#{2,3} ' -and $lines[$i] -like "*$Topic*") { $idx = $i; break }
        }
        # 2) 正文里含关键词，回退到它所属的小节标题
        if ($idx -lt 0) {
            $lastHead = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^#{2,3} ') { $lastHead = $i }
                if ($lastHead -ge 0 -and $lines[$i] -match [regex]::Escape($Topic)) { $idx = $lastHead; break }
            }
        }
        if ($idx -lt 0) { continue }

        # 取到下一个同级或更高级标题之前
        $level = if ($lines[$idx] -match '^### ') { 3 } else { 2 }
        $end = $lines.Count - 1
        for ($j = $idx + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^## ') { $end = $j - 1; break }
            if ($level -eq 3 -and $lines[$j] -match '^### ') { $end = $j - 1; break }
        }
        if ($end -lt $idx) { $end = $idx }
        return ("手册｜$($t.Name)｜$Topic`n" + ($lines[$idx..$end] -join "`n"))
    }
    return ''
}

function Invoke-AiTool {
    param($Action)

    $tool = [string]$Action.tool
    try {
        switch ($tool) {

            'write_file' {
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                # 记下写之前是否已经存在。覆盖和新建要给不同的提示——
                # 模型经常该用 append_file 时又调一次 write_file，把前面的内容冲掉，
                # 结果里还说「写入成功」，它自己看不出问题。
                $existed = (Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Container)
                # 覆盖已有文件前先留一份，模型改错了还能找回来
                if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Container)) {
                    try {
                        $bkDir = Join-Path $script:AiRoot '.backup'
                        if (-not (Test-Path $bkDir)) { New-Item -ItemType Directory -Force -Path $bkDir | Out-Null }
                        $bkName = (Split-Path $full -Leaf) + '.' + (Get-Date -Format 'yyyyMMdd_HHmmss')
                        Copy-Item -LiteralPath $full -Destination (Join-Path $bkDir $bkName) -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
                $content = [string]$Action.content
                # 不要把命令报错当成结果写进文件
                if ($content -match '不是内部或外部命令|无法识别|--- 错误输出 ---|is not recognized as') {
                    throw '内容里是命令的报错信息，不能写进文件。请先修正命令，或改用 read_file 直接读文件。'
                }
                $dir = Split-Path $full -Parent
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

                # 如果同名位置是个目录（多半是之前误用 make_dir 建错了），
                # 不删它也不报错，而是把内容写成"这个目录里的同名文件"，
                # 并明确告诉模型改成了哪里，免得它反复撞 Access denied。
                $fixedFrom = ''
                if (Test-Path $full -PathType Container) {
                    $leafName = Split-Path $full -Leaf
                    $fixedFrom = Get-RelDisplay $full
                    $full = Join-Path $full $leafName
                    $dir = Split-Path $full -Parent
                    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                }

                # 编码按脚本类型分开处理，这两者需求正好相反：
                #  - .ps1：PowerShell 5.1 读无 BOM 文件会按 GBK 解释，中文乱码，必须带 BOM
                #  - .bat：cmd 会把 BOM 当成第一行内容（'@echo' 不是内部命令），绝对不能带，
                #          中文靠首行 chcp 65001 配合 UTF-8 无 BOM 解决
                $isBat = $full -match '\.(bat|cmd)$'
                # bat 里没有 chcp 就先补一行，否则中文输出必乱
                if ($isBat) {
                    if ($content -notmatch '(?im)^\s*chcp\s') {
                        $rest = ($content -replace '(?im)^\s*@echo off\s*\r?\n?', '')
                        $content = "@echo off`r`nchcp 65001 >nul`r`n" + $rest
                    }
                }
                $enc = Get-AiFileEncoding $full
                try {
                    [IO.File]::WriteAllText($full, $content, $enc)
                } catch [System.UnauthorizedAccessException] {
                    # 只读文件：自动去掉只读再试一次
                    try { (Get-Item -LiteralPath $full).IsReadOnly = $false } catch { }
                    try {
                        [IO.File]::WriteAllText($full, $content, $enc)
                        return "已写入 $(Get-RelDisplay $full)（$($content.Length) 字符，原文件是只读的，已自动解除）"
                    } catch {
                        throw "写不进去：$($_.Exception.Message)。文件可能是只读的，或被别的程序占用着。"
                    }
                } catch [System.IO.IOException] {
                    throw "写不进去：$($_.Exception.Message)。文件可能正被其他程序打开。"
                }
                if ($existed) {
                    return "已覆盖 $(Get-RelDisplay $full)（$($content.Length) 字符）。**这是整个文件重写，原来的内容已经没了。** 本意是追加的话应该用 append_file。改完了直接 finish。"
                }
                return "已写入 $(Get-RelDisplay $full)（$($content.Length) 字符）。写入成功，不用再读一遍验证，直接 finish。"
            }

            'append_file' {
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                if (-not (Test-Path $full)) { throw "文件不存在：$($Action.path)" }
                $content = [string]$Action.content
                # 统一走 Get-AiFileEncoding：对 .ps1 会保留 BOM，
                # 否则往脚本里追加一行就把它的 BOM 丢了，下次运行中文全乱
                $enc = Get-AiFileEncoding $full
                $old = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
                [IO.File]::WriteAllText($full, $old + "`r`n" + $content, $enc)
                return "已追加到 $(Get-RelDisplay $full)"
            }

            'set_line' {
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                if (-not (Test-Path $full)) {
                    # 小模型最常见的死循环：文件还没建就想改行，然后跑去 make_dir 建同名目录。
                    # 提示必须点名 write_file，否则它看不懂该改用哪个工具。
                    throw "文件不存在：$($Action.path)。要新建就直接用 write_file，把完整内容一次写进去（会自动建目录）；不要用 make_dir 建同名目录，那不是文件。"
                }
                $n = 0
                if (-not [int]::TryParse(([string]$Action.command).Trim(), [ref]$n) -or $n -lt 1) {
                    throw 'command 里要填行号，比如 4'
                }
                $newText = [string]$Action.content
                $lines = @([IO.File]::ReadAllLines($full))
                if ($n -gt $lines.Count + 1) {
                    throw "文件现在只有 $($lines.Count) 行，不能直接写到第 $n 行。要追加就写第 $($lines.Count + 1) 行。"
                }
                $enc = Get-AiFileEncoding $full
                if ($n -eq $lines.Count + 1) {
                    $all = @($lines) + @($newText)
                    Write-AiFileLines $full $all
                    return "已把第 $n 行写成「$newText」（新增一行，文件现在 $($all.Count) 行）"
                }
                $all = @($lines)
                $old = $all[$n - 1]
                # 值本来就一样：别真去写，明确告诉它"没变化"，免得它接着反复刷同一行
                # 必须用 -ceq（区分大小写）：PowerShell 的 -eq 对字符串不区分大小写，
                # 会把 hello 当成等于 HELLO，导致"只改大小写"的操作被静默跳过。
                if ($old -ceq $newText) {
                    return "第 $n 行本来就是「$newText」，没有变化，这一步不需要再做。文件共 $($all.Count) 行。"
                }
                $all[$n - 1] = $newText
                Write-AiFileLines $full $all
                return "已把第 $n 行写成「$newText」（原来是「$old」，文件共 $($all.Count) 行）"
            }

            'make_dir' {
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                # 小模型常把 "创建 a.txt" 错理解成"建一个叫 a.txt 的目录"，
                # 一旦建成目录，后面 write_file 就永远写不进去（Access denied），
                # 然后无限循环。带文件扩展名的路径直接挡掉。
                if ($Action.path -match '\.(txt|md|log|csv|jsonl|json|ps1|bat|ini|xml|html|ya?ml)$') {
                    throw "make_dir 是建目录的，而 $($Action.path) 是文件名。要写文件请直接用 write_file，path 填这个文件名、content 填内容。"
                }
                if (Test-Path $full) {
                    if ((Get-Item -LiteralPath $full) -is [System.IO.DirectoryInfo]) { return "$($Action.path) 已经存在了" }
                    throw "已经有一个同名文件：$($Action.path)"
                }
                New-Item -ItemType Directory -Force -Path $full | Out-Null
                return "已创建目录 $(Get-RelDisplay $full)"
            }

            # ---------- 文件操作（以前只能绕 run_cmd 做的） ----------

            'find_files' {
                # 按通配符找文件。比 run_cmd(dir /b *关键词*) 好在：能递归、输出带大小、不用记 cmd 语法
                $dir = Resolve-AiPath $Action.path
                if (-not (Test-Path $dir)) { throw "目录不存在：$($Action.path)" }
                $pat = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($pat)) { $pat = '*' }
                $files = @(Get-ChildItem -LiteralPath $dir -Filter $pat -File -Recurse -ErrorAction SilentlyContinue)
                if ($files.Count -eq 0) { return "没找到匹配 $pat 的文件" }
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine("找到 $($files.Count) 个匹配 $pat 的文件：")
                foreach ($x in ($files | Select-Object -First 30)) {
                    $sz = if ($x.Length -ge 1MB) { [math]::Round($x.Length/1MB,1).ToString() + ' MB' } elseif ($x.Length -ge 1KB) { [math]::Round($x.Length/1KB,1).ToString() + ' KB' } else { $x.Length.ToString() + ' B' }
                    [void]$sb.AppendLine(("  " + (Get-RelDisplay $x.FullName) + "  " + $sz))
                }
                if ($files.Count -gt 30) { [void]$sb.AppendLine("  ...还有 $($files.Count - 30) 个") }
                return $sb.ToString()
            }

            'file_info' {
                # 看文件/目录的基本信息。以前要 run_cmd(dir 文件) 然后自己解析
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "不存在：$($Action.path)" }
                $it = Get-Item -LiteralPath $full
                if ($it.PSIsContainer) {
                    $fs = @(Get-ChildItem -LiteralPath $full -File -Recurse -ErrorAction SilentlyContinue)
                    $sum = ($fs | Measure-Object Length -Sum).Sum
                    return "$($Action.path) 是目录：$($fs.Count) 个文件，共 $([math]::Round($sum/1KB,1)) KB"
                }
                $sz = if ($it.Length -ge 1MB) { [math]::Round($it.Length/1MB,1).ToString() + ' MB' } elseif ($it.Length -ge 1KB) { [math]::Round($it.Length/1KB,1).ToString() + ' KB' } else { $it.Length.ToString() + ' B' }
                $ro = if ($it.IsReadOnly) { '，只读' } else { '' }
                return "$($Action.path)：$sz，改于 $($it.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))$ro"
            }

            'move_path' {
                # 移动 / 重命名。目标路径填在 command 里
                $src = Resolve-AiPath $Action.path
                $dstRel = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($dstRel)) { throw 'command 里要填目标路径，比如 b.txt 或 new\a.txt' }
                if (-not (Test-Path $src)) { throw "源不存在：$($Action.path)" }
                $dst = Resolve-AiPath $dstRel
                Assert-CanWrite -Full $dst -RelPath $dstRel
                if (Test-Path $dst) { throw "目标已存在：$dstRel。要覆盖就先 delete_path 删掉它。" }
                $d = Split-Path $dst -Parent
                if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                Move-Item -LiteralPath $src -Destination $dst -Force
                return "已移动 $(Get-RelDisplay $src) → $(Get-RelDisplay $dst)"
            }

            'copy_path' {
                # 复制文件或目录。目标路径填在 command 里
                $src = Resolve-AiPath $Action.path
                $dstRel = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($dstRel)) { throw 'command 里要填目标路径' }
                if (-not (Test-Path $src)) { throw "源不存在：$($Action.path)" }
                $dst = Resolve-AiPath $dstRel
                Assert-CanWrite -Full $dst -RelPath $dstRel
                $d = Split-Path $dst -Parent
                if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
                return "已复制 $(Get-RelDisplay $src) → $(Get-RelDisplay $dst)"
            }

            'grep_file' {
                # 在文件里搜关键词，返回行号和上下文。比 read_file 整个读省 token
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "文件不存在：$($Action.path)" }
                if (Test-Path $full -PathType Container) { throw "$($Action.path) 是目录。搜目录用 skill(search_text)" }
                $kw = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($kw)) { throw 'command 里要填要找的关键词' }
                $ctx = 0
                $tryN = 0
                if ([int]::TryParse([string]$Action.content, [ref]$tryN) -and $tryN -gt 0) { $ctx = [Math]::Min($tryN, 5) }
                $all = @([IO.File]::ReadAllLines($full))
                $hitIdx = @()
                for ($i = 0; $i -lt $all.Count; $i++) {
                    if ($all[$i] -like "*$kw*") { $hitIdx += $i }
                }
                if ($hitIdx.Count -eq 0) { return "文件里没有 $kw（共 $($all.Count) 行）" }
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine("在 $(Get-RelDisplay $full) 里找到 $($hitIdx.Count) 处 $kw（共 $($all.Count) 行）：")
                $shown = 0
                foreach ($h in $hitIdx) {
                    if ($shown -ge 10) { break }
                    $shown++
                    $from = [Math]::Max(0, $h - $ctx)
                    $to = [Math]::Min($all.Count - 1, $h + $ctx)
                    [void]$sb.AppendLine("")
                    for ($k = $from; $k -le $to; $k++) {
                        $mark = if ($k -eq $h) { '>' } else { ' ' }
                        $ln = $all[$k]
                        if ($ln.Length -gt 100) { $ln = $ln.Substring(0,100) }
                        [void]$sb.AppendLine("  $mark $($k+1): $ln")
                    }
                }
                if ($hitIdx.Count -gt 10) { [void]$sb.AppendLine("  ...还有 $($hitIdx.Count - 10) 处") }
                return $sb.ToString()
            }

            # ---------- 只读辅助（算哈希、分段读、看系统、剪贴板） ----------

            'hash_file' {
                # 算文件哈希。用来判断两个文件是不是一模一样（比逐字节快）
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "不存在：$($Action.path)" }
                if (Test-Path $full -PathType Container) { throw "$($Action.path) 是目录。算目录里所有文件的哈希用 skill(find_duplicates)" }
                $algo = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($algo)) { $algo = 'sha256' }
                $algo = $algo.Trim().ToUpperInvariant().Replace('-','')
                if ($algo -notin @('MD5','SHA1','SHA256')) { $algo = 'SHA256' }
                $h = (Get-FileHash -LiteralPath $full -Algorithm $algo).Hash.ToLowerInvariant()
                $sz = (Get-Item -LiteralPath $full).Length
                return "$algo $(Get-RelDisplay $full)`n  $h`n  大小 $sz 字节"
            }

            'read_lines' {
                # 按行号范围读。大文件用这个分段看，比 read_file 截断后瞎猜好
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "文件不存在：$($Action.path)" }
                if (Test-Path $full -PathType Container) { throw "$($Action.path) 是目录，不是文件" }
                $from = 1
                $tryFrom = 0
                if ([int]::TryParse([string]$Action.command, [ref]$tryFrom) -and $tryFrom -gt 0) { $from = $tryFrom }
                $cnt = 40
                $tryCnt = 0
                if ([int]::TryParse([string]$Action.content, [ref]$tryCnt) -and $tryCnt -gt 0) { $cnt = [Math]::Min($tryCnt, 200) }
                $all = @([IO.File]::ReadAllLines($full))
                if ($from -gt $all.Count) { throw "文件只有 $($all.Count) 行，第 $from 行不存在" }
                $to = [Math]::Min($all.Count, $from + $cnt - 1)
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine("$(Get-RelDisplay $full) 第 $from-$to 行（共 $($all.Count) 行）：")
                [void]$sb.AppendLine('')
                for ($i = $from - 1; $i -lt $to; $i++) {
                    $ln = $all[$i]
                    if ($ln.Length -gt 160) { $ln = $ln.Substring(0,160) + '…' }
                    [void]$sb.AppendLine(("$($i+1): " + $ln))
                }
                if ($to -lt $all.Count) { [void]$sb.AppendLine("") ; [void]$sb.AppendLine("（还有 $($all.Count - $to) 行，接着读用 command=" + ($to+1) + "）") }
                return $sb.ToString()
            }

            'sys_info' {
                # 看本机硬件。command 填 cpu / mem / disk / all（默认 all）
                $what = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($what)) { $what = 'all' }
                $what = $what.Trim().ToLowerInvariant()
                $sb = New-Object System.Text.StringBuilder
                if ($what -in @('all','cpu')) {
                    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
                    if ($cpu) {
                        [void]$sb.AppendLine("CPU  $($cpu.Name)")
                        [void]$sb.AppendLine("     $($cpu.NumberOfCores) 物理核 / $($cpu.NumberOfLogicalProcessors) 逻辑核")
                    }
                }
                if ($what -in @('all','mem')) {
                    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                    if ($os) {
                        $t = [math]::Round($os.TotalVisibleMemorySize/1MB,2)
                        $f2 = [math]::Round($os.FreePhysicalMemory/1MB,2)
                        [void]$sb.AppendLine("内存  共 $t GB，可用 $f2 GB")
                    }
                }
                if ($what -in @('all','disk')) {
                    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                        $sz = [math]::Round($d.Size/1GB,1)
                        $fr = [math]::Round($d.FreeSpace/1GB,1)
                        [void]$sb.AppendLine("磁盘  $($d.DeviceID) 共 $sz GB，可用 $fr GB")
                    }
                }
                if ($sb.Length -eq 0) { return "不认识 $what，能填 cpu / mem / disk / all" }
                return $sb.ToString().TrimEnd()
            }

            'clipboard' {
                # 读写剪贴板。command 填 get 或 set；set 时正文放 content
                $op = ([string]$Action.command).Trim().ToLowerInvariant()
                if ($op -eq 'set') {
                    $txt = [string]$Action.content
                    if ([string]::IsNullOrEmpty($txt)) { throw 'command 填 set 时要给 content' }
                    Set-Clipboard -Value $txt
                    return "已放进剪贴板（$($txt.Length) 字符）"
                }
                if ($op -eq 'get' -or [string]::IsNullOrWhiteSpace($op)) {
                    $cur = Get-Clipboard -Raw -ErrorAction SilentlyContinue
                    if ([string]::IsNullOrWhiteSpace($cur)) { return '剪贴板是空的' }
                    if ($cur.Length -gt 2000) { $cur = $cur.Substring(0,2000) + '…' }
                    return "剪贴板内容：`n$cur"
                }
                throw "command 只能填 get 或 set，收到：$op"
            }


            # ---------- 剩下几个"现在完全做不了"的 ----------

            'now' {
                # 当前日期时间。模型的训练数据有截止日期，问"今天几号"必须查这个
                $d = Get-Date
                $wk = @('星期日','星期一','星期二','星期三','星期四','星期五','星期六')[[int]$d.DayOfWeek]
                return ("现在是 " + $d.ToString('yyyy年M月d日') + " " + $wk + " " + $d.ToString('HH:mm:ss'))
            }

            'zip_list' {
                # 不解压，先看压缩包里有什么
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "不存在：$($Action.path)" }
                if (Test-Path $full -PathType Container) { throw "$($Action.path) 是目录。要打包用 skill(zip_dir)" }
                if ($full -notmatch '\.(zip|docx|xlsx|pptx|jar|apk)$') { throw "这个格式读不了清单（只支持 zip 系）。要看内容就 unzip 解出来" }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [IO.Compression.ZipFile]::OpenRead($full)
                try {
                    $items = @($zip.Entries)
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.AppendLine("$(Get-RelDisplay $full) 里有 $($items.Count) 项：")
                    $shown = 0
                    foreach ($e in $items) {
                        if ($shown -ge 40) { break }
                        $shown++
                        $sz = if ($e.Length -ge 1MB) { [math]::Round($e.Length/1MB,1).ToString() + ' MB' } elseif ($e.Length -ge 1KB) { [math]::Round($e.Length/1KB,1).ToString() + ' KB' } else { $e.Length.ToString() + ' B' }
                        [void]$sb.AppendLine(("  " + $sz.PadLeft(9) + "  " + $e.FullName))
                    }
                    if ($items.Count -gt 40) { [void]$sb.AppendLine("  ...还有 $($items.Count - 40) 项") }
                    return $sb.ToString()
                } finally { $zip.Dispose() }
            }

            'diff_files' {
                # 两个文件逐行比，说清楚哪几行不一样。command 填另一个文件
                $a = Resolve-AiPath $Action.path
                $bRel = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($bRel)) { throw 'command 里要填第二个文件的路径' }
                $b = Resolve-AiPath $bRel
                if (-not (Test-Path $a)) { throw "不存在：$($Action.path)" }
                if (-not (Test-Path $b)) { throw "不存在：$bRel" }
                $la = @([IO.File]::ReadAllLines($a))
                $lb = @([IO.File]::ReadAllLines($b))
                if ($la.Count -eq $lb.Count) {
                    $same = $true
                    for ($i = 0; $i -lt $la.Count; $i++) { if ($la[$i] -cne $lb[$i]) { $same = $false; break } }
                    if ($same) { return "两个文件内容完全一样（都是 $($la.Count) 行）" }
                }
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine("$(Get-RelDisplay $a)（$($la.Count) 行） vs $(Get-RelDisplay $b)（$($lb.Count) 行）：")
                $max = [Math]::Max($la.Count, $lb.Count)
                $diffCount = 0
                $shown = 0
                for ($i = 0; $i -lt $max; $i++) {
                    $x = if ($i -lt $la.Count) { $la[$i] } else { $null }
                    $y = if ($i -lt $lb.Count) { $lb[$i] } else { $null }
                    if ($x -ceq $y) { continue }
                    $diffCount++
                    if ($shown -ge 20) { continue }
                    $shown++
                    [void]$sb.AppendLine("")
                    [void]$sb.AppendLine("第 $($i+1) 行：")
                    $xs = if ($null -eq $x) { '（没有这行）' } elseif ($x.Length -gt 80) { $x.Substring(0,80) + '…' } else { $x }
                    $ys = if ($null -eq $y) { '（没有这行）' } elseif ($y.Length -gt 80) { $y.Substring(0,80) + '…' } else { $y }
                    [void]$sb.AppendLine("  前: $xs")
                    [void]$sb.AppendLine("  后: $ys")
                }
                if ($diffCount -gt 20) { [void]$sb.AppendLine("") ; [void]$sb.AppendLine("（共 $diffCount 处不同，只列了前 20 处）") }
                return $sb.ToString()
            }

            'json_format' {
                # 美化（缩进）或压缩 JSON。command 填 pretty 或 compact
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "不存在：$($Action.path)" }
                $mode = ([string]$Action.command).Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'pretty' }
                $raw = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
                $obj = $null
                try { $obj = $raw | ConvertFrom-Json } catch { throw "不是合法 JSON：$($_.Exception.Message)" }
                $out = if ($mode -eq 'compact') { $obj | ConvertTo-Json -Depth 20 -Compress } else { $obj | ConvertTo-Json -Depth 20 }
                $save = [string]$Action.content
                if ($save -eq '1' -or $save -match '^(?i)(yes|true|写入)') {
                    Write-AiFileText $full $out
                    return "已把 $(Get-RelDisplay $full) 写成 $mode 格式"
                }
                if ($out.Length -gt 3000) { $out = $out.Substring(0,3000) + '…（太长，只显示前 3000 字符）' }
                return $out
            }

            'csv_preview' {
                # 先看 CSV 长什么样：列名 + 前几行。不解全表
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "不存在：$($Action.path)" }
                $n = 8
                $tryN = 0
                if ([int]::TryParse([string]$Action.command, [ref]$tryN) -and $tryN -gt 0) { $n = [Math]::Min($tryN, 50) }
                $rows = @(Get-Content -LiteralPath $full -Encoding UTF8 -TotalCount ($n + 1))
                if ($rows.Count -eq 0) { return "文件是空的" }
                $cols = @($rows[0] -split ',')
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine("$(Get-RelDisplay $full) 共 $($cols.Count) 列：")
                [void]$sb.AppendLine(("  列名  " + ($cols -join ' | ')))
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("前 $([Math]::Min($n, $rows.Count-1)) 行：")
                for ($i = 1; $i -lt $rows.Count; $i++) {
                    $r = $rows[$i]
                    if ($r.Length -gt 120) { $r = $r.Substring(0,120) + '…' }
                    [void]$sb.AppendLine("  $i. $r")
                }
                return $sb.ToString()
            }

            # ---------- 日期 / 网络 / 环境 ----------

            'date_calc' {
                # 算日期。command 填：有符号天数（3 = 三天后，-7 = 七天前），
                # 或者一个日期（2024-01-01），那就算距今多少天
                $q = ([string]$Action.command).Trim()
                $now = Get-Date
                if ([string]::IsNullOrWhiteSpace($q)) { throw 'command 里填天数（如 3）或日期（如 2024-01-01）' }
                $off = 0
                if ([int]::TryParse($q, [ref]$off)) {
                    $target = $now.AddDays($off)
                    $dir = if ($off -gt 0) { "$off 天后" } elseif ($off -lt 0) { "$([Math]::Abs($off)) 天前" } else { '今天' }
                    return ("$dir 是 " + $target.ToString('yyyy年M月d日') + " " + $target.ToString('dddd'))
                }
                $dt = [datetime]::MinValue
                if ([datetime]::TryParse($q, [ref]$dt)) {
                    $days = [int][Math]::Floor(($dt.Date - $now.Date).TotalDays)
                    if ($days -gt 0) { return "$q 还有 $days 天（" + $dt.ToString('yyyy年M月d日') + " " + $dt.ToString('dddd') + "）" }
                    if ($days -lt 0) { return "$q 已经过去 $([Math]::Abs($days)) 天" }
                    return "$q 就是今天"
                }
                throw "看不懂 $q。填天数（3 / -7）或者日期（2024-01-01）"
            }

            'download_file' {
                # 把网址上的文件存到本地。path 填网址，command 填存到哪（留空用原文件名）
                $url = ([string]$Action.path).Trim()
                if ($url -notmatch '^https?://') { throw 'path 要填 http:// 或 https:// 开头的网址' }
                $dstRel = ([string]$Action.command).Trim()
                if ([string]::IsNullOrWhiteSpace($dstRel)) {
                    $leaf = ($url -split '[/\\?]' | Where-Object { $_ } | Select-Object -Last 1)
                    if (-not $leaf) { $leaf = 'download.bin' }
                    $dstRel = $leaf
                }
                $dst = Resolve-AiPath $dstRel
                Assert-CanWrite -Full $dst -RelPath $dstRel
                $d = Split-Path $dst -Parent
                if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 120
                $sz = (Get-Item -LiteralPath $dst).Length
                $szTxt = if ($sz -ge 1MB) { [math]::Round($sz/1MB,1).ToString() + ' MB' } elseif ($sz -ge 1KB) { [math]::Round($sz/1KB,1).ToString() + ' KB' } else { $sz.ToString() + ' B' }
                return "已下载到 $(Get-RelDisplay $dst)（$szTxt）"
            }

            'env_get' {
                # 看环境变量。command 填变量名（留空列出常见的几个）
                $name = ([string]$Action.command).Trim()
                if ([string]::IsNullOrWhiteSpace($name)) {
                    $keys = @('USERPROFILE', 'TEMP', 'PATH', 'COMPUTERNAME', 'USERNAME', 'PROCESSOR_ARCHITECTURE')
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.AppendLine('常用环境变量：')
                    foreach ($k in $keys) {
                        $v = [Environment]::GetEnvironmentVariable($k)
                        if ($v) {
                            if ($v.Length -gt 100) { $v = $v.Substring(0,100) + '…' }
                            [void]$sb.AppendLine("  $k = $v")
                        }
                    }
                    return $sb.ToString().TrimEnd()
                }
                $val = [Environment]::GetEnvironmentVariable($name)
                if ([string]::IsNullOrEmpty($val)) { return "环境变量 $name 不存在或为空" }
                return "$name = $val"
            }

            # ---------- 应用 / 进程 / Python / 技能 / 单位 ----------

            'open_app' {
                # 打开程序或文件。command 填程序名（notepad/calc/explorer）或完整路径
                $what = ([string]$Action.command).Trim()
                if ([string]::IsNullOrWhiteSpace($what)) { $what = ([string]$Action.path).Trim() }
                if ([string]::IsNullOrWhiteSpace($what)) { throw 'command 里填程序名，比如 notepad、calc、explorer' }
                # 常见程序直接用（不填全路径，靠系统自己找）
                $known = @{
                    'notepad' = 'notepad.exe'; '记事本' = 'notepad.exe'
                    'calc' = 'calc.exe'; '计算器' = 'calc.exe'
                    'mspaint' = 'mspaint.exe'; '画图' = 'mspaint.exe'
                    'explorer' = 'explorer.exe'; '资源管理器' = 'explorer.exe'
                    'cmd' = 'cmd.exe'; 'terminal' = 'wt.exe'; 'wt' = 'wt.exe'
                    'taskmgr' = 'taskmgr.exe'; '任务管理器' = 'taskmgr.exe'
                    'control' = 'control.exe'; '控制面板' = 'control.exe'
                    'mstsc' = 'mstsc.exe'; 'devmgmt' = 'devmgmt.msc'
                }
                $key = $what.ToLowerInvariant()
                if ($known.ContainsKey($key)) {
                    Start-Process -FilePath $known[$key] -ErrorAction Stop
                    return "已打开 $what"
                }
                # 不是内置名字：当路径或可执行文件处理
                if ($what -match '^[A-Za-z]:[\\/]' -or $what -match '[\\/]') {
                    $p = $what
                    if (-not (Test-Path -LiteralPath $p)) { $p = Resolve-AiPath $what }
                    if (-not (Test-Path -LiteralPath $p)) { throw "找不到：$what" }
                    Start-Process -FilePath $p -ErrorAction Stop
                    return "已打开 $what"
                }
                # 最后试一把：当命令名
                try { Start-Process -FilePath $what -ErrorAction Stop; return "已打开 $what" }
                catch { throw "打不开 $what。常用的是 notepad / calc / explorer / mspaint / taskmgr，或者给完整路径。" }
            }

            'kill_process' {
                # 结束进程。command 填进程名（不带 .exe）或 PID
                $what = ([string]$Action.command).Trim()
                if ([string]::IsNullOrWhiteSpace($what)) { throw 'command 里填进程名（如 notepad）或 PID' }
                # 保护：这些绝对不能杀
                $protect = @('system', 'idle', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'smss', 'explorer')
                $killed = @()
                $numId = 0
                if ([int]::TryParse($what, [ref]$numId)) {
                    $p = Get-Process -Id $numId -ErrorAction SilentlyContinue
                    if (-not $p) { throw "没有 PID 为 $numId 的进程" }
                    if ($protect -contains $p.ProcessName.ToLowerInvariant()) { throw "$($p.ProcessName) 是系统进程，不能杀" }
                    $n = $p.ProcessName
                    try { $p.Kill(); $killed += "$n (PID $numId)" } catch { throw "杀不掉：$($_.Exception.Message)" }
                } else {
                    $name = $what -replace '\.exe$', ''
                    if ($protect -contains $name.ToLowerInvariant()) { throw "$name 是系统进程，不能杀" }
                    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
                    if ($procs.Count -eq 0) { throw "没有叫 $name 的进程在跑" }
                    foreach ($p in $procs) {
                        try { $pid2 = $p.Id; $p.Kill(); $killed += "$name (PID $pid2)" } catch { }
                    }
                }
                if ($killed.Count -eq 0) { throw "没能结束 $what（可能需要管理员权限）" }
                return ("已结束：" + ($killed -join '、'))
            }

            'run_python' {
                # 跑 Python。path 给 .py 文件，或者 content 直接给代码
                $py = 'C:\Python312\python.exe'
                if (-not (Test-Path $py)) {
                    $found = Get-Command python -ErrorAction SilentlyContinue
                    if ($found) { $py = $found.Source } else { throw '没找到 Python。装一个或者用 run_ps 代替' }
                }
                $code = [string]$Action.content
                $fileRel = [string]$Action.path
                $tmpMade = $false
                if (-not [string]::IsNullOrWhiteSpace($fileRel)) {
                    $script = Resolve-AiPath $fileRel
                    if (-not (Test-Path $script)) { throw "文件不存在：$fileRel" }
                } else {
                    if ([string]::IsNullOrWhiteSpace($code)) { throw 'path 给 .py 文件，或者 content 直接给代码' }
                    $script = Join-Path $env:TEMP ('nafx_' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.py')
                    [IO.File]::WriteAllText($script, $code, (New-Object Text.UTF8Encoding($false)))
                    $tmpMade = $true
                }
                try {
                    $env:PYTHONIOENCODING = 'utf-8'
                    $out = & $py $script 2>&1 | Out-String
                    if ($tmpMade) { Remove-Item $script -Force -ErrorAction SilentlyContinue }
                    $out = $out.Trim()
                    if ([string]::IsNullOrWhiteSpace($out)) { return 'Python 跑完了，没有输出' }
                    if ($out.Length -gt 3000) { $out = $out.Substring(0,3000) + "`n…（太长，只显示前 3000 字符）" }
                    return "运行 Python 结束（退出码 $LASTEXITCODE）：`n--- 标准输出 ---`n$out"
                } catch {
                    if ($tmpMade) { Remove-Item $script -Force -ErrorAction SilentlyContinue }
                    throw "Python 跑失败了：$($_.Exception.Message)"
                }
            }


            'write_script' {
                # 一次调用干三件事：写脚本 → 运行 → 返回输出。
                # 为什么要有这个：一个「写脚本统计行数然后运行」的任务，
                # 拆成 write_file + run_ps1 两步，4B 模型经常在中间绕圈（实测 210 秒 maxsteps）。
                # 合并成一步，它就没机会迷路。
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                if ($full -notmatch '\.ps1$') { throw 'path 要以 .ps1 结尾' }
                $content = [string]$Action.content
                if ([string]::IsNullOrWhiteSpace($content)) { throw 'content 里填脚本内容' }
                $dir = Split-Path $full -Parent
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                Write-AiFileText $full $content
                # 立刻运行，参数放在 command 里（可留空）
                $runArgs = [string]$Action.command
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $full)
                if (-not [string]::IsNullOrWhiteSpace($runArgs)) { $argList += ($runArgs -split '\s+') }
                $sw = [Diagnostics.Stopwatch]::StartNew()
                # 必须先把当前目录切到 workspace 再跑。
                # 子进程继承父进程的 cwd，不切的话脚本里的相对路径全找不到
                # （实测报 "Cannot find path ...\default-workspace\data\orders.jsonl"）。
                $oldCwd = (Get-Location).Path
                try {
                    Set-Location -LiteralPath $script:AiRoot
                    $out = & powershell.exe @argList 2>&1 | Out-String
                } catch {
                    $out = "运行出错：" + $_.Exception.Message
                } finally {
                    try { Set-Location -LiteralPath $oldCwd } catch { }
                }
                $sw.Stop()
                $out = $out.Trim()
                if ($out.Length -gt 2500) { $out = $out.Substring(0,2500) + "`n…（太长，只显示前 2500 字符）" }
                $relDisp = Get-RelDisplay $full
                if ([string]::IsNullOrWhiteSpace($out)) { return "已写 $relDisp 并运行，没有输出（退出码 $LASTEXITCODE，耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）" }
                return "已写 $relDisp 并运行（退出码 $LASTEXITCODE，耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒）：`n--- 输出 ---`n$out"
            }
            'write_skill' {
                # 把一套做法写成技能说明（md），以后可以查。path 填技能名
                $name = ([string]$Action.path).Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { throw 'path 里填技能名，比如 clean_logs' }
                $name = $name -replace '[^\w\u4e00-\u9fa5\-]', ''
                if (-not $name) { throw '技能名里要有字母或中文' }
                $body = [string]$Action.content
                if ([string]::IsNullOrWhiteSpace($body)) { throw 'content 里填技能说明（markdown）' }
                $skillDir = Join-Path (Split-Path $script:ToolDir -Parent) 'skills'
                if (-not (Test-Path $skillDir)) { New-Item -ItemType Directory -Force -Path $skillDir | Out-Null }
                $mdPath = Join-Path $skillDir ($name + '.md')
                $doc = "# " + $name + "`n`n" + $body + "`n`n---`n`n（这个技能是 " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + " 自动写的，用法见上面的说明）`n"
                Write-AiFileText $mdPath $doc
                return "已创建技能说明 $(Get-RelDisplay $mdPath)。以后用 skill 工具查 'list' 能看到它。"
            }

            'project_doc' {
                # 查 Nafx 自己的文档。
                # 别把全文塞给模型：README 有 1 万多字，一次返回 4000 字符会让下一步
                # 的提示词爆掉（实测「查一下 Nafx 的架构」直接卡死）。
                # 所以只给「章节目录 + 开头一段」，想看细节让它再指定章节。
                $topic = ([string]$Action.command).Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($topic)) { $topic = 'all' }
                $root = Split-Path $script:ToolDir -Parent
                $docs = @{
                    '架构' = 'README.md'; 'arch' = 'README.md'; '说明' = 'README.md'; 'readme' = 'README.md'
                    '工具' = 'agent\工具手册.md'; 'tools' = 'agent\工具手册.md'; '手册' = 'agent\工具手册.md'
                    '流程' = 'agent\flows.json'; 'flows' = 'agent\flows.json'
                }
                $pick = $null
                foreach ($k in $docs.Keys) { if ($topic -eq $k -or $topic -like "*$k*") { $pick = $docs[$k]; break } }
                if (-not $pick) {
                    return ("能查这些：" + (($docs.Keys | Sort-Object) -join '、') + "`n用法：project_doc(架构)")
                }
                $p = Join-Path $root $pick
                if (-not (Test-Path $p)) { throw "文档不存在：$pick" }
                $txt = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
                # 提章节标题当目录。
                # 先把 ``` 代码块整段去掉——里面用 # 写的注释会被当成标题
                # （README 那段 PowerShell 就混进来好几条「- 留给系统的：...」）。
                $clean = [regex]::Replace($txt, '(?s)```.*?```', '')
                $heads = @()
                foreach ($m in [regex]::Matches($clean, '(?m)^(#{2,3})\s+(.+)$')) {
                    $h = $m.Groups[2].Value.Trim()
                    if ($h.Length -le 30) { $heads += $h }
                }
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine("【$pick】共 $($txt.Length) 字")
                if ($heads.Count -gt 0) {
                    [void]$sb.AppendLine("")
                    [void]$sb.AppendLine("章节：")
                    $hs = $heads | Select-Object -First 12
                    foreach ($h in $hs) { [void]$sb.AppendLine("  - $h") }
                    if ($heads.Count -gt 12) { [void]$sb.AppendLine("  ...还有 $($heads.Count - 12) 节") }
                }
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("开头：")
                $head600 = if ($txt.Length -gt 600) { $txt.Substring(0, 600) } else { $txt }
                [void]$sb.AppendLine($head600)
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**上面是目录。回答用户时**：从目录里挑最相关的那一节，说清它讲了什么；")
                [void]$sb.AppendLine("不要原样复述下面的开头——那只是文件前 600 字，不一定是答案。")
                [void]$sb.AppendLine("要看某一节的全文，用 read_file 读这个文件，或者问得更具体一点。")
                return $sb.ToString()
            }

            'unit_convert' {
                # 单位换算。command 写 "100 km to miles" 这种
                $expr = ([string]$Action.command).Trim()
                if ([string]::IsNullOrWhiteSpace($expr)) { throw 'command 里写换算，比如 100 km to miles' }
                if ($expr -notmatch '^\s*(-?[\d.]+)\s*([A-Za-z°]+)\s*(?:to|转|->|→)\s*([A-Za-z°]+)\s*$') {
                    throw "看不懂 $expr。写成：100 km to miles、30 c to f、1 gb to mb"
                }
                $val = [double]$Matches[1]
                $from = $Matches[2].ToLowerInvariant()
                $to = $Matches[3].ToLowerInvariant()
                # 每个单位换算成基准单位（长度=米，重量=克，数据=字节，温度=摄氏度）
                $len = @{ 'mm'=0.001; 'cm'=0.01; 'm'=1; 'km'=1000; 'in'=0.0254; 'ft'=0.3048; 'yd'=0.9144; 'mi'=1609.344; 'miles'=1609.344; 'mile'=1609.344; '英尺'=0.3048; '米'=1; '公里'=1000 }
                $wt = @{ 'mg'=0.001; 'g'=1; 'kg'=1000; 't'=1000000; 'oz'=28.3495; 'lb'=453.592; 'lbs'=453.592; '斤'=500; '克'=1; '公斤'=1000 }
                $data = @{ 'b'=1; 'kb'=1024; 'mb'=1048576; 'gb'=1073741824; 'tb'=1099511627776 }
                $result = $null
                $unit = ''
                if ($len.ContainsKey($from) -and $len.ContainsKey($to)) {
                    $result = $val * $len[$from] / $len[$to]; $unit = '长度'
                } elseif ($wt.ContainsKey($from) -and $wt.ContainsKey($to)) {
                    $result = $val * $wt[$from] / $wt[$to]; $unit = '重量'
                } elseif ($data.ContainsKey($from) -and $data.ContainsKey($to)) {
                    $result = $val * $data[$from] / $data[$to]; $unit = '数据量'
                } elseif (($from -in @('c','°c','摄氏')) -and ($to -in @('f','°f','华氏'))) {
                    $result = $val * 9 / 5 + 32; $unit = '温度'
                } elseif (($from -in @('f','°f','华氏')) -and ($to -in @('c','°c','摄氏'))) {
                    $result = ($val - 32) * 5 / 9; $unit = '温度'
                }
                if ($null -eq $result) { throw "换不了 $from → $to。支持长度（mm/cm/m/km/in/ft/mi）、重量（mg/g/kg/lb/斤）、数据（b/kb/mb/gb/tb）、温度（c/f）" }
                $r = [math]::Round($result, 4)
                return "$val $from = $r $to（$unit）"
            }
            'replace_in_file' {
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                if (-not (Test-Path $full)) { throw "文件不存在：$($Action.path)" }
                $find = [string]$Action.find
                if ([string]::IsNullOrEmpty($find)) { throw 'find 不能为空' }
                $text = [IO.File]::ReadAllText($full)
                $idx = $text.IndexOf($find, [StringComparison]::Ordinal)
                if ($idx -lt 0) { throw "文件里没有找到：$find" }
                $newText = $text.Substring(0, $idx) + [string]$Action.replace + $text.Substring($idx + $find.Length)
                # 必须按文件类型选编码：对 .ps1 要保住 BOM，
                # 否则改一次脚本，脚本里的中文就变成 "鎬婚噾棰?" 这种乱码
                Write-AiFileText $full $newText
                return "已替换 $(Get-RelDisplay $full) 中的 1 处内容。替换成功，不用再读一遍验证，直接 finish。"
            }

            'read_file' {
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "文件不存在：$($Action.path)" }
                $text = [IO.File]::ReadAllText($full)
                # 顺带给出统计，模型不用自己数
                $nonEmpty = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count
                $stat = "（共 $nonEmpty 行非空内容，$($text.Length) 字符）"

                # 大文件不全塞给模型：超过 800 字符只给开头，剩下的教它怎么看
                $limit = 550
                if ($text.Length -gt $limit) {
                    $head = $text.Substring(0, $limit)
                    $rest = $text.Length - $limit
                    $howto = @"

--- 只显示了前 $limit 字符，后面还有 $rest 字符 ---
要看后面的内容，别整个重读，用这些：
  run_cmd(command="findstr /n ""关键词"" $($Action.path)")     直接找你要的那段
  run_cmd(command="type $($Action.path) | more +100")           从第 100 行往后看
  run_cmd(command="powershell -NoProfile -c ""(Get-Content '$($Action.path)')[-80..-1]""")   看最后 80 行
"@
                    return Trim-AiText ("文件 $($Action.path) 的内容：`n$head" + $howto + "`n`n" + $stat)
                }
                return Trim-AiText ("文件 $($Action.path) 的内容：`n$text`n`n" + $stat)
            }

            'list_dir' {
                $target = $Action.path
                if ([string]::IsNullOrWhiteSpace($target)) { $target = '.' }
                $full = Resolve-AiPath $target
                if (-not (Test-Path $full)) { throw "目录不存在：$target" }
                $items = Get-ChildItem -LiteralPath $full -Force | Sort-Object PSIsContainer, Name
                if (-not $items) { return "目录 $target 是空的（0 个文件、0 个目录）" }
                $fileCount = @($items | Where-Object { -not $_.PSIsContainer }).Count
                $dirCount  = @($items | Where-Object { $_.PSIsContainer }).Count
                $lines = $items | ForEach-Object {
                    if ($_.PSIsContainer) { "[目录] $($_.Name)/" }
                    else { "[文件] $($_.Name)  $([math]::Round($_.Length/1KB,1)) KB" }
                }
                # 直接把统计结论写出来：4B 自己数容易错，也容易反复查
                $summary = "`n`n（共 $fileCount 个文件、$dirCount 个目录）"
                return Trim-AiText ("目录 $target 的内容：`n" + ($lines -join "`n") + $summary)
            }

            'delete_path' {
                $full = Resolve-AiPath $Action.path
                Assert-CanWrite -Full $full -RelPath ([string]$Action.path)
                if (-not (Test-Path $full)) { throw "路径不存在：$($Action.path)" }
                $rootFull = [IO.Path]::GetFullPath($script:AiRoot).TrimEnd('\')
                if ($full -eq $rootFull) { throw '不允许删除 workspace 根目录' }
                Remove-Item -LiteralPath $full -Recurse -Force
                return "已删除 $(Get-RelDisplay $full)"
            }

            'run_ps1' {
                $full = Resolve-AiPath $Action.path
                # 模型有时把「工具名」当成脚本名传进来。
                # 实测：建目录的任务里，它先 run_ps1 make_dir.ps1（不存在），
                # 然后居然 write_file 写了个 make_dir.ps1 脚本去建目录，
                # 绕了 4 步才做完一件 make_dir 一步就能完成的事。
                # 这类混淆直接把正确工具告诉它，别让它自己猜。
                $bn = [IO.Path]::GetFileNameWithoutExtension([string]$Action.path)
                $looksLikeTool = @('make_dir','write_file','read_file','list_dir','delete_path','find_files',
                                   'append_file','replace_in_file','set_line','copy_path','move_path',
                                   'grep_file','read_lines','file_info','run_cmd') -contains $bn
                if ($looksLikeTool) {
                    throw ("$($Action.path) 这名字看着是工具名，不是你的脚本。" +
                           "如果你要建目录，直接用 make_dir 工具（不用写脚本）；" +
                           "要写文件用 write_file；要列目录用 list_dir。" +
                           "只有真的是自己写的 .ps1 才用 run_ps1 跑。")
                }
                if (-not (Test-Path $full)) { throw "脚本不存在：$($Action.path)。要跑脚本得先用 write_file 创建它。" }
                # 只能跑 .ps1。模型有时会把数据文件当脚本传进来，把话说清楚它就懂了。
                if ($full -notmatch '\.ps1$') {
                    throw ("run_ps1 只能运行 .ps1 脚本，$($Action.path) 不是脚本。" +
                           "要用脚本处理这个文件的话，先用 write_file 写一个 .ps1，再 run_ps1 跑那个脚本。")
                }
                $extra = [string]$Action.command
                # 脚本有 param() 但没传 command，跑出来会是空的 ——
                # 模型会误以为「退出码 0 = 成功」，然后拿空结果编答案。
                # 实测就是这么翻车的：calc.ps1 有 param($a,$b,$op)，
                # 模型 run_ps1 没传参数，输出一片空白，它却在 finish 里写
                # 「12 + 3 = 15，结果正确」—— 那个 15 是它自己算的，不是脚本算的。
                if ([string]::IsNullOrWhiteSpace($extra)) {
                    $head = ''
                    try { $head = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) } catch { }
                    if ($head -match 'param\s*\(') {
                        throw ("这个脚本有 param() 要收参数，但你没传 command。" +
                               "带参数运行要写 command，比如 command=""-a 12 -b 3 -op +""。" +
                               "不传参数跑出来是空的 —— 看到空输出不代表成功。")
                    }
                }
                # 子进程固定用 UTF-8 输出（含错误流），否则中文会按 GBK 解成乱码
                $inner = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '$OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '& ''' + $full + ''''
                if (-not [string]::IsNullOrWhiteSpace($extra)) { $inner += " $extra" }
                $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
                $r = Invoke-ChildScript -FilePath 'powershell.exe' -CommandLine $cmdLine -Label "run_ps1 $($Action.path)"
                # 跑出来是空的也要提醒，别让模型把「没输出」当「做对了」
                $rs = [string]$r
                if ($rs.TrimEnd().EndsWith('--- 标准输出 ---')) {
                    $rs += "`n（脚本没输出任何东西。如果它本该打印结果，检查是不是没传参数、或者代码里没写输出。空输出不等于成功。）"
                }
                return $rs
            }

            'run_js' {
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "脚本不存在：$($Action.path)。要写 JS 脚本请先用 write_file 创建（扩展名 .js 或 .jse）。" }
                if ($full -notmatch '\.(js|jse)$') { throw "run_js 只跑 .js 或 .jse 文件，$($Action.path) 不是。" }

                $extra = [string]$Action.command

                # Windows 自带的 cscript + JScript，不用装 Node。
                # 坑：JScript 引擎只认 ANSI 源文件，UTF-8 存的中文会让它报
                # "未结束的字符串常量"。所以这里先看一眼有没有非 ASCII 字符，
                # 有就转一份 GBK 的临时文件去跑；纯英文脚本直接用原文件。
                $runFile = $full
                $tmpFile = $null
                try {
                    $raw = [IO.File]::ReadAllText($full)
                    $hasNonAscii = $false
                    foreach ($ch in $raw.ToCharArray()) {
                        if ([int][char]$ch -gt 127) { $hasNonAscii = $true; break }
                    }
                    if ($hasNonAscii) {
                        $tmpFile = Join-Path $script:AiRoot ('.nafx_run_' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.js')
                        [IO.File]::WriteAllText($tmpFile, $raw, [Text.Encoding]::GetEncoding(936))
                        $runFile = $tmpFile
                    }
                } catch { $runFile = $full }

                try {
                    $cmdLine = '/c chcp 936>nul & cscript //nologo //E:JScript "' + $runFile + '"'
                    if (-not [string]::IsNullOrWhiteSpace($extra)) { $cmdLine += ' ' + $extra }
                    $out = Invoke-ChildScript -FilePath 'cmd.exe' -CommandLine $cmdLine `
                        -Enc ([Text.Encoding]::GetEncoding(936)) -Label "run_js $($Action.path)"
                    return $out
                } finally {
                    if ($tmpFile -and (Test-Path $tmpFile)) {
                        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            'run_bat' {
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "脚本不存在：$($Action.path)" }
                $extra = [string]$Action.command
                # 先判断这个 bat 本身是 UTF-8 还是 GBK，再决定用哪个代码页跑，否则中文会乱码
                $isUtf8 = $true
                try {
                    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
                    $null = $strictUtf8.GetString([IO.File]::ReadAllBytes($full))
                } catch { $isUtf8 = $false }

                if ($isUtf8) { $cp = '65001'; $enc = [Text.Encoding]::UTF8 }
                else { $cp = '936'; $enc = [Text.Encoding]::GetEncoding(936) }

                $cmdLine = '/c chcp ' + $cp + '>nul & "' + $full + '"'
                if (-not [string]::IsNullOrWhiteSpace($extra)) { $cmdLine += " $extra" }
                return Invoke-ChildScript -FilePath 'cmd.exe' -CommandLine $cmdLine -Enc $enc -Label "run_bat $($Action.path)"
            }

            'skill' {
                # 技能库：事先写好、验证过能跑的脚本。
                # 模型只管判断该用哪个，不用自己写代码——这是 4B 能稳定干活的关键。
                $arg = ([string]$Action.command).Trim()
                $skillDir = Join-Path (Split-Path $script:ToolDir -Parent) 'skills'
                $indexPath = Join-Path $skillDir 'skill.json'

                if (-not (Test-Path $indexPath)) {
                    throw '技能库还没建（找不到 skills\skill.json）'
                }

                $idx = Get-Content $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $all = @($idx.skills)

                # 不带参数 / list → 一行一个技能。详细参数用 info 查（省上下文）
                if ([string]::IsNullOrWhiteSpace($arg) -or $arg -match '^(?i)(list|ls|all|列表|全部)$') {
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.AppendLine("技能库 $($all.Count) 个。用法 skill(command=`"名字 参数`")；看详细参数用 skill(command=`"info 名字`")")
                    [void]$sb.AppendLine('')
                    foreach ($s in $all) {
                        $d = [string]$s.desc
                        # 只在句号处截断。逗号不能截——括号里的逗号会被误伤
                        # （"找出重复文件（按哈希判断，不看文件名）"会断成半句）
                        $cut = $d.IndexOf([char]0x3002)
                        if ($cut -gt 6) { $d = $d.Substring(0, $cut) }
                        if ($d.Length -gt 30) { $d = $d.Substring(0, 30) + [char]0x2026 }
                        [void]$sb.AppendLine(("{0,-20} {1}" -f $s.name, $d))
                    }
                    return $sb.ToString()
                }

                # info 名字 → 看这个技能怎么用
                if ($arg -match '^(?i)(info|详情|帮助)\s+(\S+)$') {
                    $qn = $Matches[2]
                    $one = $all | Where-Object { $_.name -eq $qn } | Select-Object -First 1
                    if (-not $one) { $one = $all | Where-Object { [string]$_.title -like "*$qn*" } | Select-Object -First 1 }
                    if (-not $one) { throw "没有这个技能：$qn。先 skill(command=`"list`") 看有哪些。" }
                    return ("技能 " + $one.name + " —— " + $one.title + "`n`n" + [string]$one.desc + "`n`n参数: " + [string]$one.params + "`n用例: " + [string]$one.example)
                }

                # 拆出技能名和参数
                $name = $arg
                $params = ''
                if ($arg -match '^(\S+)\s+([\s\S]*)$') {
                    $name = $Matches[1]
                    $params = $Matches[2].Trim()
                }

                # 名字没对上：按标题、触发词、单词重叠度找最像的那个
                $hit = $null
                foreach ($sk in $all) {
                    if ($sk.name -eq $name) { $hit = $sk; break }
                }
                if (-not $hit) {
                    foreach ($sk in $all) {
                        if ($sk.title -eq $name -or $sk.title -like "*$name*" -or $name -like "*$($sk.title)*") {
                            $hit = $sk; break
                        }
                    }
                }
                if (-not $hit) {
                    # 触发词命中：挑匹配最长的那个，别取第一个
                    $bestHit = $null
                    $bestLen = 0
                    foreach ($sk in $all) {
                        foreach ($tg in @($sk.triggers)) {
                            if (-not $tg) { continue }
                            if ($name -like "*$tg*" -or $tg -like "*$name*") {
                                $len = [Math]::Min([string]$tg.Length, $name.Length)
                                if ($len -gt $bestLen) { $bestLen = $len; $bestHit = $sk }
                            }
                        }
                    }
                    if ($bestHit) { $hit = $bestHit }
                }
                if (-not $hit) {
                    # 最后兜底：英文名按单词重叠算分（中文没空格，拆词没用）
                    if ($name -match '[A-Za-z]') {
                        $qwords = @($name -split '[_\-\s\.]+' | Where-Object { $_.Length -ge 2 })
                        $best = $null
                        $bestScore = 0
                        foreach ($sk in $all) {
                            $score = 0
                            $tgText = (@($sk.triggers) -join ' ')
                            foreach ($w in $qwords) {
                                if ([string]$sk.name -like "*$w*")  { $score += 5 }
                                if ([string]$sk.title -like "*$w*") { $score += 3 }
                                if ($tgText -like "*$w*")           { $score += 2 }
                                if ([string]$sk.desc -like "*$w*")  { $score += 1 }
                            }
                            if ($score -gt $bestScore) { $bestScore = $score; $best = $sk }
                        }
                        if ($bestScore -ge 5) { $hit = $best }
                    }                }
                if (-not $hit) {
                    $names = ($all | ForEach-Object { $_.name }) -join '、'
                    throw "没有这个技能：$name。现有：$names。用 skill(command=`"list`") 看全部。"
                }
                if ($hit.name -ne $name -and $name -notlike "*$($hit.name)*") {
                    Write-Host ("  [skill] '$name' 没精确匹配，改用 '$($hit.name)'（$($hit.title)）") -ForegroundColor DarkGray
                }
                $scriptPath = Join-Path $skillDir ($hit.name + '.ps1')
                if (-not (Test-Path $scriptPath)) {
                    throw "技能 $($hit.name) 的脚本文件不见了：$($hit.name).ps1"
                }

                # 子进程固定 UTF-8，否则中文输出会乱
                $inner = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '$OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '& ''' + $scriptPath + ''''
                if (-not [string]::IsNullOrWhiteSpace($params)) { $inner += " $params" }
                $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
                return Invoke-ChildScript -FilePath 'powershell.exe' -CommandLine $cmdLine -Label "skill $($hit.name)"
            }

            'run_cmd' {
                $cmd = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($cmd)) { throw 'command 不能为空' }

                # 几条绝对不允许执行的命令
                $deny = '(?i)\b(format\s+[a-z]:|diskpart|shutdown|restart-computer|stop-computer|' +
                        'bcdedit|reg\s+delete\s+hklm|rd\s+/s\s+/q\s+[a-z]:\\?\s*$|del\s+/s\s+/q\s+[a-z]:\\?\s*$)'
                if ($cmd -match $deny) { throw '这条命令被安全策略拒绝' }

                # 会停下来等键盘输入的命令：跑起来就永远不返回
                if ($cmd -match '(?i)(^|[&|]\s*)(pause|choice|set\s+/p)\b') {
                    throw '这条命令会停下来等键盘输入，永远不会返回。去掉 pause / choice / set /p。'
                }

                # cmd 的输出编码分两种：
                #   - 外部命令（find/findstr/robocopy）受 chcp 影响，能按 UTF-8 出
                #   - copy / del / md / rd 等内置命令走系统 ANSI（中文系统是 GBK），
                #     按 UTF-8 解会变乱码，模型看到乱码就瞎猜（曾把"已复制 0 个文件"
                #     读成文件名 srcile.txt，然后跑去问用户）
                # 折中：先按 UTF-8 跑，疑似乱码就按 GBK 重跑一次。
                $line = '/c chcp 65001>nul & ' + $cmd
                $lbl = "run_cmd " + $cmd.Substring(0, [Math]::Min(40, $cmd.Length))
                $out1 = Invoke-ChildScript -FilePath 'cmd.exe' -CommandLine $line -Enc ([Text.Encoding]::UTF8) -Label $lbl
                $mojibake = ([regex]::Matches($out1, '\uFFFD')).Count -ge 2 -or
                            ($out1 -match '[\u00C0-\u00FF]{3,}') -or
                            ($out1 -match '锟斤拷|锟')
                if ($mojibake) {
                    $out2 = Invoke-ChildScript -FilePath 'cmd.exe' -CommandLine ('/c ' + $cmd) -Enc ([Text.Encoding]::GetEncoding(936)) -Label $lbl
                    if ($out2 -and -not ($out2 -match '[\u00C0-\u00FF]{3,}|锟斤拷')) { return $out2 }
                }
                return $out1
            }

            'run_ps' {
                # 直接跑一条 PowerShell 命令。
                # 什么时候用：cmd 做不了的（对象、管道、cmdlet、算数、正则、JSON）。
                # 能用 run_cmd 解决的优先 run_cmd，那个更快。
                $cmd = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($cmd)) { throw 'command 不能为空，把 PowerShell 命令填进去' }

                # 危险命令一律拒绝
                $deny = '(?i)\b(Format-Volume|Clear-Disk|Remove-Partition|Initialize-Disk|' +
                        'Stop-Computer|Restart-Computer|Set-ExecutionPolicy\s+Unrestricted|' +
                        'Remove-Item\s+.*-Recurse.*\s+[A-Za-z]:\\?\s*$|' +
                        'Invoke-Expression\s+\(New-Object\s+Net\.WebClient)'
                if ($cmd -match $deny) { throw '这条命令被安全策略拒绝' }

                # 会停下来等人的：跑起来永远不返回
                if ($cmd -match '(?i)\b(Read-Host|pause\b|Out-GridView|Show-Command)') {
                    throw '这条命令会停下来等人操作，永远不会返回。去掉 Read-Host / Out-GridView 之类。'
                }

                # 多行命令包成一行跑（分号连接），并强制 UTF-8 输出
                $inner = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '$OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '$ErrorActionPreference=''Continue''; ' +
                         $cmd
                $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "' + ($inner -replace '"','\"') + '"'
                $lbl = 'run_ps ' + $cmd.Substring(0, [Math]::Min(40, $cmd.Length))
                return Invoke-ChildScript -FilePath 'powershell.exe' -CommandLine $cmdLine `
                    -Enc ([Text.Encoding]::UTF8) -Label $lbl
            }

            'unzip' {
                $full = Resolve-AiPath $Action.path
                if (-not (Test-Path $full)) { throw "压缩包不存在：$($Action.path)" }
                if (Test-Path $full -PathType Container) { throw "$($Action.path) 是个目录，不是压缩包" }

                # 解压目标：command 传目录，没传就用压缩包同名的目录
                $destRel = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($destRel)) {
                    $destRel = [IO.Path]::GetFileNameWithoutExtension($full)
                }
                $destFull = Resolve-AiPath $destRel
                Assert-CanWrite -Full $destFull -RelPath $destRel
                if (-not (Test-Path $destFull)) { New-Item -ItemType Directory -Force -Path $destFull | Out-Null }

                $ext = [IO.Path]::GetExtension($full).ToLower()
                try {
                    if ($ext -eq '.zip') {
                        Expand-Archive -LiteralPath $full -DestinationPath $destFull -Force -ErrorAction Stop
                    }
                    elseif ($ext -in @('.tar', '.gz', '.tgz', '.bz2', '.xz', '.zst', '.tbz2')) {
                        # Win10 自带 bsdtar，能解 tar 系列
                        & tar.exe -xf $full -C $destFull 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "tar 解压失败（退出码 $LASTEXITCODE）" }
                    }
                    elseif ($ext -in @('.7z', '.rar')) {
                        $sz = @(
                            'C:\Program Files\7-Zip\7z.exe',
                            'C:\Program Files (x86)\7-Zip\7z.exe'
                        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
                        if (-not $sz) {
                            $szCmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
                            if ($szCmd) { $sz = $szCmd.Source }
                        }
                        if (-not $sz) {
                            throw "解压 .7z/.rar 需要 7-Zip，这台机器没装。可以先用 install(command=`"7zip`") 装上再来。"
                        }
                        & $sz x $full "-o$destFull" -y 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "7-Zip 解压失败（退出码 $LASTEXITCODE）" }
                    }
                    else {
                        throw "不认识的压缩格式：$ext。支持 zip / tar / gz / tgz / 7z / rar"
                    }
                } catch {
                    if ($_.Exception.Message -match '不认识的压缩格式|需要 7-Zip|解压失败') { throw }
                    throw ("解压失败：" + $_.Exception.Message)
                }

                $n = @(Get-ChildItem -LiteralPath $destFull -Recurse -File -ErrorAction SilentlyContinue).Count
                return "已解压到 $destRel，共 $n 个文件"
            }

            'ps' {
                # 宽容一点：内存/cpu/空/全部 这类词都当成"按内存排序列出来"，
                # 其余当成进程名关键词筛。
                $kw = ([string]$Action.command).Trim()

                $all = @(Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending)
                $isDim = [string]::IsNullOrWhiteSpace($kw) -or
                         $kw -match '^(?i)(memory|mem|ram|cpu|heap|内存|占用|最多|全部|all|top|list|show)$'

                if ($isDim) {
                    $list = @($all | Select-Object -First 12)
                    $totalMb = [math]::Round((($all | Measure-Object WorkingSet64 -Sum).Sum)/1MB)
                    $head = "占内存最多的 $($list.Count) 个进程（全部进程共 $totalMb MB）："
                } else {
                    $list = @($all | Where-Object { $_.ProcessName -like "*$kw*" })
                    if ($list.Count -eq 0) {
                        $top = @($all | Select-Object -First 5 | ForEach-Object {
                            "{0} {1:N0}MB" -f $_.ProcessName, ($_.WorkingSet64/1MB)
                        }) -join '、'
                        return ("没有名字含 '$kw' 的进程。当前占内存最多的是：$top" +
                                "`n（想按内存排就 ps(command=`"memory`") 或直接 ps(command=`"`")）")
                    }
                    $totalMb = [math]::Round((($list | Measure-Object WorkingSet64 -Sum).Sum)/1MB)
                    $head = "名字含 '$kw' 的进程 $($list.Count) 个，共 $totalMb MB："
                }

                $rows = @()
                foreach ($p in ($list | Select-Object -First 15)) {
                    $rows += ("{0,-22} {1,7:N0} MB  PID {2}" -f $p.ProcessName, ($p.WorkingSet64/1MB), $p.Id)
                }
                $tail = ''
                if ($list.Count -gt 25) { $tail = "`n…（还有 $($list.Count - 25) 个没列出）" }
                return ($head + "`n" + ($rows -join "`n") + $tail)
            }
            'install' {
                $arg = ([string]$Action.command).Trim()
                if ([string]::IsNullOrWhiteSpace($arg)) {
                    throw '要指定软件名，比如 install(command="7zip")；只搜索就写 install(command="search 7zip")'
                }
                $wg = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
                if (-not $wg) {
                    throw ('这台机器没有 winget，装不了。' +
                           '可以改用 run_cmd 下载安装包，或者让用户自己去装。')
                }

                $oldEnc = [Console]::OutputEncoding
                try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
                try {
                    # search <关键词>：只看不装
                    if ($arg -match '^(?i)\s*search\s+(.+)$') {
                        $kw = $Matches[1].Trim()
                        $out = (& winget.exe search $kw --accept-source-agreements 2>&1 | Out-String)
                        if ([string]::IsNullOrWhiteSpace($out)) { return "没搜到 '$kw' 相关的软件包" }
                        return Trim-AiText ("winget 搜 '$kw' 的结果：`n" + $out.Trim())
                    }

                    # 直接装：--silent + 自动同意协议，避免卡在交互提示
                    $out = (& winget.exe install --id $arg -e --silent --disable-interactivity `
                                --accept-package-agreements --accept-source-agreements 2>&1 | Out-String)
                    $ok = ($LASTEXITCODE -eq 0)
                    if (-not $ok) {
                        # 用 id 精确匹配失败，退一步用名字搜
                        $out2 = (& winget.exe install $arg --silent --disable-interactivity `
                                     --accept-package-agreements --accept-source-agreements 2>&1 | Out-String)
                        if ($LASTEXITCODE -eq 0) { $ok = $true; $out = $out2 }
                        else { $out = $out + "`n" + $out2 }
                    }
                    if ($ok) { return Trim-AiText ("装好了：$arg`n" + $out.Trim()) }
                    throw ("winget 安装失败。输出：`n" + (Trim-AiText $out.Trim()))
                } finally {
                    try { [Console]::OutputEncoding = $oldEnc } catch { }
                }
            }

            'learn' {
                # 把这次的教训记下来，下次遇到类似任务会自动带上。
                # 三个字段的用法：path = 什么样的任务，find = 踩了什么坑，replace = 正确做法
                if (-not $script:MemoryReady) { throw '经验记忆模块没加载，记不了' }

                $task = ([string]$Action.path).Trim()
                $mistake = ([string]$Action.find).Trim()
                $fix = ([string]$Action.replace).Trim()

                # 也支持 command 里用 | 分隔：任务|坑|做法
                if (-not $mistake -and $Action.command) {
                    $parts = ([string]$Action.command) -split '\|'
                    if ($parts.Count -ge 2) {
                        $task = $parts[0].Trim()
                        $mistake = $parts[1].Trim()
                        if ($parts.Count -ge 3) { $fix = $parts[2].Trim() }
                    } else {
                        throw '要写清楚记什么：path=任务关键词，find=踩的坑，replace=正确做法'
                    }
                }
                if ([string]::IsNullOrWhiteSpace($mistake)) {
                    throw '要写清楚踩了什么坑：find="..."'
                }

                $ok = Add-Lesson -Task $task -Mistake $mistake -Fix $fix -Source 'model'
                if ($ok) {
                    $st = Get-MemoryStats
                    return "记下了。经验库现在有 $($st.Lessons) 条教训。"
                } else {
                    return "这条已经记过了，没重复写。"
                }
            }

            'help' {
                # 查手册：先查工具详情，再查工具手册，最后查 shell / 错误处理
                $topic = [string]$Action.command
                # 模型有时会传 topic 而不是 command，这里接住
                if ([string]::IsNullOrWhiteSpace($topic) -and ($Action.PSObject.Properties.Name -contains 'topic')) {
                    $topic = [string]$Action.topic
                }
                if ([string]::IsNullOrWhiteSpace($topic)) { $topic = [string]$Action.path }
                if ([string]::IsNullOrWhiteSpace($topic)) { $topic = [string]$Action.content }
                $topic = ([string]$topic).Trim()

                # ① topic 就是工具名 → 从 schema 直接生成完整参数说明
                #    比翻手册精确，而且只返回这一个工具，省 token
                if ($topic) {
                    $schemaPath = Join-Path $script:ToolDir 'tools-schema.json'
                    if (Test-Path $schemaPath) {
                        try {
                            $schemas = Get-Content $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            foreach ($s in @($schemas)) {
                                if ($s.function.name -eq $topic) {
                                    $f = $s.function
                                    $sb1 = New-Object System.Text.StringBuilder
                                    [void]$sb1.AppendLine("工具：" + $f.name)
                                    [void]$sb1.AppendLine("用途：" + $f.description)
                                    $reqList = @()
                                    if ($f.parameters.required) { $reqList = @($f.parameters.required) }
                                    if ($reqList.Count -gt 0) { [void]$sb1.AppendLine("必填：" + ($reqList -join ', ')) }
                                    [void]$sb1.AppendLine("参数：")
                                    if ($f.parameters.properties) {
                                        foreach ($p in $f.parameters.properties.PSObject.Properties) {
                                            $mark = if ($reqList -contains $p.Name) { '必填' } else { '可选' }
                                            $desc = ''
                                            if ($p.Value.PSObject.Properties.Name -contains 'description') { $desc = [string]$p.Value.description }
                                            [void]$sb1.AppendLine(("  - {0}（{1}）{2}" -f $p.Name, $mark, $desc))
                                        }
                                    }
                                    return $sb1.ToString()
                                }
                            }
                        } catch { }
                    }
                }

                # ② 翻手册
                # 三本手册：工具怎么用 / shell 与 cmd 怎么写 / 出错了怎么办
                $manuals = @(
                    @{ Name = '工具手册'; Path = (Join-Path $script:ToolDir '工具手册.md') },
                    @{ Name = 'shell 手册'; Path = (Join-Path $script:ToolDir 'shell手册.md') },
                    @{ Name = '错误处理手册'; Path = (Join-Path $script:ToolDir '错误处理.md') }
                )
                $all = @()
                foreach ($m in $manuals) {
                    if (Test-Path $m.Path) { $all += [pscustomobject]@{ Name = $m.Name; Path = $m.Path } }
                }
                if ($all.Count -eq 0) { return '手册不存在' }

                # 没给关键词：列出各手册的目录
                if ([string]::IsNullOrWhiteSpace($topic)) {
                    $sb = New-Object System.Text.StringBuilder
                    foreach ($m in $all) {
                        $lines0 = [IO.File]::ReadAllText($m.Path, [Text.Encoding]::UTF8) -split "`n"
                        $heads = @($lines0 | Where-Object { $_ -match '^#{2,3} ' })
                        [void]$sb.AppendLine("== $($m.Name) ==")
                        [void]$sb.AppendLine(($heads -join "`n"))
                        [void]$sb.AppendLine('')
                    }
                    return Trim-AiText $sb.ToString()
                }

                # 出错相关的关键词，优先去错误处理手册找
                $isErrTopic = $topic -match '(?i)错误|失败|出错|报错|异常|网络|403|404|越界|不存在|没有找到|退出码|超时|拒绝|反复|卡住|怎么办'
                if ($isErrTopic) {
                    $errOnly = @($all | Where-Object { $_.Name -like '*错误*' })
                    if ($errOnly.Count -gt 0) {
                        $e1 = Find-ManualSection -Targets $errOnly -Topic $topic
                        if ($e1) {
                            return Trim-AiText ("先用这份流程图想清楚再动手：`n`n" + $e1)
                        }
                    }
                }

                $hit = Find-ManualSection -Targets $all -Topic $topic
                if ($hit) {
                    # 工具手册命中后，若主题偏"怎么写脚本/命令"，再把 shell 手册的写法补上：
                    # 光知道"用 run_cmd"不够，还得知道那条命令本身怎么写。
                    $extra = ''
                    $isHowTo = $topic -match '(?i)数行数|求和|合计|统计|列表|列目录|遍历|日期|时间|bat|cmd|shell|powershell|命令行|脚本|json|csv|找文字|删除|复制'
                    if ($isHowTo -and $hit -match '^手册｜工具手册') {
                        $shellOnly = @($all | Where-Object { $_.Name -like '*shell*' })
                        if ($shellOnly.Count -gt 0) {
                            $s2 = Find-ManualSection -Targets $shellOnly -Topic $topic
                            if ($s2) { $extra = "`n`n===== 具体怎么写 =====`n" + $s2 }
                        }
                    }
                    return Trim-AiText ($hit + $extra)
                }
                return "手册里没有 $topic 相关的内容。可以查：write_file、run_cmd、run_ps1、数行数、求和、bat、PowerShell"
            }

            'syshelp' {
                # 查本机自带帮助——最权威、最准，不联网也不会过时。
                #   cmd 命令：dir /?
                #   PowerShell：Get-Help
                # 之前只会查自己写的 md 手册，手册没覆盖到的就抓瞎。
                $q = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($q)) { $q = [string]$Action.path }
                if ([string]::IsNullOrWhiteSpace($q)) { $q = [string]$Action.content }
                $q = $q.Trim()
                if ([string]::IsNullOrWhiteSpace($q)) {
                    throw 'syshelp 要指定查什么，比如 command="dir" 或 command="Get-ChildItem"'
                }

                $name = ($q -split '\s+')[0]
                $psCmd = Get-Command $name -CommandType Cmdlet,Function,ExternalScript -ErrorAction SilentlyContinue

                if ($psCmd) {
                    $h = Get-Help $name -ErrorAction SilentlyContinue
                    if ($h) {
                        $sb = New-Object System.Text.StringBuilder
                        [void]$sb.AppendLine("=== $name ===")
                        if ($h.Synopsis -and ([string]$h.Synopsis).Trim()) { [void]$sb.AppendLine('摘要: ' + ([string]$h.Synopsis).Trim()) }
                        if ($h.Syntax) {
                            [void]$sb.AppendLine('语法（照这个抄参数）:')
                            foreach ($sy in $h.Syntax) { [void]$sb.AppendLine('  ' + $sy.Definition) }
                        }
                        if ($h.Parameters -and $h.Parameters.Parameter) {
                            [void]$sb.AppendLine('')
                            [void]$sb.AppendLine('常用参数:')
                            $cnt = 0
                            foreach ($prm in $h.Parameters.Parameter) {
                                if ($cnt -ge 25) { break }
                                $desc = ''
                                if ($prm.Description) { $desc = [string]$prm.Description.Text }
                                if ($desc) { $desc = ($desc -split "`r?`n")[0] }
                                [void]$sb.AppendLine("  -$($prm.Name)  $desc")
                                $cnt++
                            }
                        }
                        if ($h.Examples -and $h.Examples.Example) {
                            [void]$sb.AppendLine('')
                            [void]$sb.AppendLine('示例:')
                            $ec = 0
                            foreach ($ex in $h.Examples.Example) {
                                if ($ec -ge 6) { break }
                                $code = [string]$ex.Code
                                if ($code) {
                                    $firstLine = ($code -split "`r?`n")[0].Trim()
                                    [void]$sb.AppendLine('  ' + $firstLine)
                                }
                                $ec++
                            }
                        }
                        $txt = $sb.ToString().Trim()
                        if ($txt.Length -gt $script:MaxOutput) { $txt = $txt.Substring(0, $script:MaxOutput) + "`n…（已截断）" }
                        return ($txt + "`n
（参数已经查到了，照上面的写法拼命令，直接 run_cmd 或 run_ps1 跑，不要再重复查）")
                    }
                }

                # 当成 cmd 命令，用 /? 查
                $out2 = & cmd.exe /c "$name /?" 2>&1
                $txt2 = ($out2 | Out-String)
                if ([string]::IsNullOrWhiteSpace($txt2) -or $txt2 -match '不是内部或外部命令|is not recognized') {
                    $gc = Get-Command $name -ErrorAction SilentlyContinue
                    if ($gc) { return "$name 是 PowerShell 命令（$($gc.CommandType)），请用 syshelp 查 PowerShell 名称。" }
                    throw "本机没有找到 $name 这个命令。检查拼写，或者用 win_doc 查微软文档。"
                }
                if ($txt2.Length -gt $script:MaxOutput) { $txt2 = $txt2.Substring(0, $script:MaxOutput) + "`n…（输出太长已截断）" }
                return ($txt2.Trim() + "`n
（参数已经查到了，照上面的写法拼命令，直接 run_cmd 或 run_ps1 跑，不要再重复查）")
            }


            'win_doc' {
                # 查 Windows 官方文档。比搜索引擎可靠得多：
                # 搜 "whoami /privileges" 会返回 Linux 的 whoami，而这里直接给微软文档。
                if (-not $script:WebReady) { throw '联网模块没有加载成功（agent\webtools.ps1），暂时不能用。' }
                $nm = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = [string]$Action.path }
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = [string]$Action.content }
                if ([string]::IsNullOrWhiteSpace($nm)) { throw 'name 不能为空，填命令名，比如 whoami、net user、tasklist、Get-Date' }
                $res = Invoke-WinDoc -Name $nm.Trim()
                return Trim-AiText (Format-WinDocResult $res)
            }

            'web_search' {
                if (-not $script:WebReady) { throw '联网模块没有加载成功（agent\webtools.ps1），暂时不能用搜索。' }
                # 关键词可能写在 command，也可能写在 content / path，都兼容
                $q = [string]$Action.command
                if ([string]::IsNullOrWhiteSpace($q)) { $q = [string]$Action.path }
                if ([string]::IsNullOrWhiteSpace($q)) { $q = [string]$Action.content }
                if ([string]::IsNullOrWhiteSpace($q)) { throw 'query 不能为空，把要搜索的关键词填进 command。' }

                # ---- 查询词顺序修正 ----
                # 实测这事影响巨大：搜「2026年 诺贝尔文学奖 得主」，
                # 回来的全是 "2026年日历""2026年放假通知""2026世界杯" —— 一条都不沾诺贝尔。
                # 搜「诺贝尔文学奖 2026 获奖者」就正常，前三条都是诺贝尔奖相关页面。
                # 原因是引擎按词序给权重，年份数字放最前面会把整个结果带偏。
                # 所以把开头的年份/数字挪到最后，主题词优先。
                $q0 = $q.Trim()
                $mYear = [regex]::Match($q0, '^\s*(今年|去年|明年|今天|现在|目前|最新|当前|(?:19|20)\d{2}\s*年?)\s*')
                if ($mYear.Success -and $q0.Length -gt $mYear.Length) {
                    $prefix = $mYear.Groups[1].Value.Trim()
                    $rest = $q0.Substring($mYear.Length).Trim()
                    if ($rest.Length -ge 2) {
                        # 只对数字年份去掉"年"字（"年"会额外匹配一堆日历站）。
                        # 不能对「今年/去年/明年」动手 —— 那样会变成"今"，词就废了。
                        if ($prefix -match '^\d{4}') { $prefix = $prefix -replace '年$', '' }
                        $q = ($rest + ' ' + $prefix).Trim()
                        if ($q -ne $q0) { Write-Log ("  [搜索] 词序调整：" + $q0 + " → " + $q) }
                    }
                }

                $n = 6
                $mN = [regex]::Match([string]$Action.find, '^\s*(\d+)\s*$')
                if ($mN.Success) { $n = [int]$mN.Groups[1].Value }
                if ($n -gt 12) { $n = 12 }

                $res = Invoke-WebSearch -Query $q.Trim() -Count $n
                $txt = Format-SearchResult $res
                # 搜的是 Windows 命令时，提醒它用更可靠的办法：
                # 引擎会把同名命令优先给 Linux 版本，结果经常驴唇不对马嘴。
                $winCmd = '(?i)^\s*(whoami|net|wmic|sc|reg|tasklist|taskkill|schtasks|systeminfo|ipconfig|' +
                          'netstat|nslookup|ping|tracert|route|arp|attrib|icacls|robocopy|xcopy|' +
                          'dir|type|find|findstr|fsutil|bcdedit|diskpart|chkdsk|certutil|wmic)\b'
                if ($q.Trim() -match $winCmd -and $q -notmatch '(?i)linux|ubuntu|bash') {
                    $txt += "`n`n【提醒】这是 Windows 命令。如果上面搜到的是 Linux 的用法，别照着抄——" +
                            "改用 win_doc(command=`"命令名`") 直接查微软官方文档，那里的语法和参数才是 Windows 的。"
                }
                return Trim-AiText $txt
            }

            'web_fetch' {
                if (-not $script:WebReady) { throw '联网模块没有加载成功（agent\webtools.ps1），暂时不能抓网页。' }
                # 网址可能写在 path，也可能写在 command / content
                $u = [string]$Action.path
                if ($u -notmatch '^https?://') {
                    if ($Action.command -match '^https?://') { $u = [string]$Action.command }
                    elseif ($Action.content -match '^https?://') { $u = [string]$Action.content }
                }
                if ([string]::IsNullOrWhiteSpace($u)) { throw 'url 不能为空，把网址填进 path，例如 https://example.com' }

                $res = Invoke-WebFetch -Url $u.Trim()
                return Trim-AiText (Format-FetchResult $res)
            }

            'plan' {
                return '（计划已记下，开始做第一步）'
            }

            'think' {
                # 显式的「先想清楚」。
                # Qwen3-4B-Instruct 是 Instruct 版，没有内置 thinking
                # （reasoning 关着，响应里也没有 reasoning_content 字段），
                # 所以只能靠这个工具把「想」和「做」分开：
                #   think    → 只写推理，不碰任何文件
                #   其它工具 → 新任务的第一个动作必须是 think（agent.ps1 里约束）
                $what = [string]$Action.content
                if ([string]::IsNullOrWhiteSpace($what)) { $what = [string]$Action.command }
                if ([string]::IsNullOrWhiteSpace($what)) {
                    return '（你没写想法。把「要做什么、先做哪步、怎么判断做对了」写进 content）'
                }
                return '（想法已记下。现在开始动手，别再重复这段推理。）'
            }

            'rethink' {
                # 重新审视任务用。真正的逻辑在 agent.ps1 里（要清空步骤、重置判断），
                # 这里只返回一句提示，防止它被当成普通动作执行。
                return '（正在重新审视任务，本步不执行实际动作）'
            }

            'say' {
                # 向用户提问、征求意见用的。不是"随便说句话"，而是明确把疑点抛给用户。
                # 优先从 content 取内容，没有再看 command / find，兼容模型乱填。
                $msg = [string]$Action.content
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$Action.command }
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$Action.find }
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$Action.path }
                if ([string]::IsNullOrWhiteSpace($msg)) {
                    return '（没有要问的内容）如果你想请用户确认，请把问题写在 content 字段。'
                }
                return "已向用户提问：$msg`n（等你确认后再继续，本步不执行任何操作）"
            }

            default {
                throw "未知工具：$tool"
            }
        }
    }
    catch {
        return "错误：$($_.Exception.Message)"
    }
}

function Read-ScriptOutput {
    param([string]$Path)
    # 子进程输出可能是 UTF-8，也可能是系统 ANSI（中文 Windows 为 GBK），
    # 先按 UTF-8 严格解码，失败再退回 ANSI，避免中文变乱码。
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $strict.GetString($bytes) }
    catch { return [Text.Encoding]::GetEncoding(0).GetString($bytes) }
}

function Invoke-ChildScript {
    param([string]$FilePath, [string]$CommandLine, [string]$Label, [object]$Enc = $null)

    # 用 .NET 的 Process 直接起子进程：能拿到真实退出码，也能指定输出编码。
    # 默认按 UTF-8 解码；run_bat 会传进来它实际使用的代码页。
    if ($null -eq $Enc) { $Enc = [Text.Encoding]::UTF8 }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $CommandLine
    $psi.WorkingDirectory = $script:AiRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Enc
    $psi.StandardErrorEncoding  = $Enc

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $finished = $p.WaitForExit($script:RunTimeout * 1000)
    if (-not $finished) {
        try { $p.Kill() } catch { }
        return "运行 $Label 超时（$($script:RunTimeout)s），进程已终止"
    }

    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }
    $exitCode = $p.ExitCode

    # PowerShell 的非终止错误不会改退出码，这里靠特征识别，避免“出错还当成功”
    # PowerShell 的非终止错误不会改退出码，这里靠特征识别，避免"出错还当成功"。
    $looksFailed = $false
    if (-not [string]::IsNullOrWhiteSpace($err)) { $looksFailed = $true }
    if ($out -match 'CategoryInfo|At line:|不是内部或外部命令|无法识别|找不到接受实际参数') { $looksFailed = $true }

    # robocopy 的退出码 0~7 全都表示成功（1 = 有文件被复制，2 = 有多余文件，
    # 3 = 两者都有…… 8 以上才是真失败）。它还会把进度写进 stderr，
    # 按"stderr 非空即失败"的通用规则会一直误判，模型看到退出码 1 就以为失败了。
    $isRobocopy = ($CommandLine -match '(?i)robocopy')
    if ($isRobocopy) {
        if ($exitCode -ge 0 -and $exitCode -le 7) { $looksFailed = $false }
        else { $looksFailed = $true }
    }

    $sb = New-Object System.Text.StringBuilder
    if ($looksFailed) { [void]$sb.Append('错误：') }
    [void]$sb.AppendLine("运行 $Label 结束，退出码 $exitCode")
    if (-not [string]::IsNullOrWhiteSpace($out)) { [void]$sb.AppendLine("--- 标准输出 ---"); [void]$sb.AppendLine($out.Trim()) }
    if (-not [string]::IsNullOrWhiteSpace($err)) { [void]$sb.AppendLine("--- 错误输出 ---"); [void]$sb.AppendLine($err.Trim()) }
    if ([string]::IsNullOrWhiteSpace($out) -and [string]::IsNullOrWhiteSpace($err)) { [void]$sb.AppendLine('（脚本没有任何输出）') }

    return Trim-AiText $sb.ToString()
}