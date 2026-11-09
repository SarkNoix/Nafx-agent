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
    New-Item -ItemType Directory -Force -Path (Join-Path $script:AiRoot 'data') | Out-Null
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

function Get-RelDisplay {    param([string]$FullPath)
    $rootFull = [IO.Path]::GetFullPath($script:AiRoot).TrimEnd('\')
    if ($FullPath.Length -gt $rootFull.Length) { return $FullPath.Substring($rootFull.Length + 1) }
    return '.'
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
                return "已替换 $(Get-RelDisplay $full) 中的 1 处内容"
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
                if (-not (Test-Path $full)) { throw "脚本不存在：$($Action.path)。要跑脚本得先用 write_file 创建它。" }
                # 只能跑 .ps1。模型有时会把数据文件当脚本传进来，把话说清楚它就懂了。
                if ($full -notmatch '\.ps1$') {
                    throw ("run_ps1 只能运行 .ps1 脚本，$($Action.path) 不是脚本。" +
                           "要用脚本处理这个文件的话，先用 write_file 写一个 .ps1，再 run_ps1 跑那个脚本。")
                }
                $extra = [string]$Action.command
                # 子进程固定用 UTF-8 输出（含错误流），否则中文会按 GBK 解成乱码
                $inner = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '$OutputEncoding=[Text.Encoding]::UTF8; ' +
                         '& ''' + $full + ''''
                if (-not [string]::IsNullOrWhiteSpace($extra)) { $inner += " $extra" }
                $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
                return Invoke-ChildScript -FilePath 'powershell.exe' -CommandLine $cmdLine -Label "run_ps1 $($Action.path)"
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