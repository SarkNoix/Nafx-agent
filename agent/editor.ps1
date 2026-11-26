# ============================================================
#  Nafx · 模型专属文件查看器 / 编辑器 / 运行器
#
#  设计目标：
#  - 一次查看多个文件，带行号，先给类型和运行提示；
#  - 支持跨文件 replace，改完只回显变更片段，不把整文件倒给模型；
#  - 按扩展名选择运行器：ps1 / bat / py / js / sh / exe 等；
#  - 不替代 write_script 的语法检查，但会守住写前备份和安全检查。
# ============================================================

$script:EditorMaxFiles  = 8
$script:EditorViewBudget = 4200
$script:EditorMaxLineLen = 220

function Get-FileTypeInfo {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    $ext  = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $kind = '文本'
    $edit = '按 UTF-8 文本编辑；保留原文件换行和缩进。'
    $run  = '不可直接运行；用对应工具处理或打开。'

    switch ($ext) {
        '.ps1'   { $kind='PowerShell 脚本'; $edit='UTF-8（建议带 BOM，兼容 Windows PowerShell 5.1 中文）；用 file_editor/write_script 编辑。'; $run='file_editor(action="run") 或 run_ps1；先检查 param() 参数。' }
        '.psm1'  { $kind='PowerShell 模块'; $edit='UTF-8 文本；改完用 Import-Module 测试。'; $run='不能直接跑；用 Import-Module 加载后调用函数。' }
        '.psd1'  { $kind='PowerShell 数据文件'; $edit='UTF-8 文本；保持键值结构。'; $run='不能直接跑；由 Import-Module / 模块清单读取。' }
        '.bat'   { $kind='CMD 批处理'; $edit='UTF-8 无 BOM；中文脚本首行加 chcp 65001。'; $run='file_editor(action="run") 或 run_bat。' }
        '.cmd'   { $kind='CMD 批处理'; $edit='UTF-8 无 BOM；中文脚本首行加 chcp 65001。'; $run='file_editor(action="run") 或 run_bat。' }
        '.py'    { $kind='Python 脚本'; $edit='UTF-8 文本；注意缩进和依赖。'; $run='file_editor(action="run")，使用 python -u；缺依赖先 install。' }
        '.js'    { $kind='JavaScript'; $edit='UTF-8 文本；区分浏览器脚本与 Node 脚本。'; $run='file_editor(action="run") 优先 Node；WSH/JScript 用 run_js。' }
        '.mjs'   { $kind='JavaScript 模块'; $edit='UTF-8 文本；使用 import/export。'; $run='file_editor(action="run")，Node 运行。' }
        '.cjs'   { $kind='JavaScript 模块'; $edit='UTF-8 文本；使用 require。'; $run='file_editor(action="run")，Node 运行。' }
        '.ts'    { $kind='TypeScript'; $edit='UTF-8 文本；先编译或用 tsx/ts-node。'; $run='需要 tsx/ts-node 或先编译；没有运行器时不要硬跑。' }
        '.sh'    { $kind='Shell 脚本'; $edit='UTF-8 文本；注意 LF 换行。'; $run='file_editor(action="run")，使用 Git Bash。' }
        '.exe'   { $kind='可执行程序'; $edit='二进制，不能当文本改。'; $run='file_editor(action="run") 直接执行；参数写在 command。' }
        '.dll'   { $kind='动态库'; $edit='二进制，不能当文本改。'; $run='不能直接跑；由宿主程序/脚本加载。' }
        '.json'  { $kind='JSON 数据'; $edit='UTF-8 文本；必须保持合法 JSON，不要加注释。'; $run='不可执行；file_editor(action="run") 会校验 JSON 合法性。' }
        '.jsonl' { $kind='JSON Lines'; $edit='一行一个 JSON；不要整体包成数组。'; $run='不可执行；逐行解析或交给技能。' }
        '.yaml'  { $kind='YAML 配置'; $edit='UTF-8 文本；缩进敏感，不要用 Tab。'; $run='不可执行；由程序读取。' }
        '.yml'   { $kind='YAML 配置'; $edit='UTF-8 文本；缩进敏感，不要用 Tab。'; $run='不可执行；由程序读取。' }
        '.toml'  { $kind='TOML 配置'; $edit='UTF-8 文本；保持节和键值结构。'; $run='不可执行；由程序读取。' }
        '.ini'   { $kind='INI 配置'; $edit='UTF-8 文本；保持节和键值结构。'; $run='不可执行；由程序读取。' }
        '.xml'   { $kind='XML 数据'; $edit='UTF-8 文本；标签必须闭合。'; $run='不可执行；由程序读取或校验。' }
        '.csv'   { $kind='CSV 表格'; $edit='UTF-8 文本；保留表头，逗号/引号按 CSV 规则。'; $run='不可执行；用 csv_preview / 技能分析。' }
        '.tsv'   { $kind='TSV 表格'; $edit='UTF-8 文本；保留表头，用 Tab 分隔。'; $run='不可执行；用表格工具分析。' }
        '.md'    { $kind='Markdown 文档'; $edit='UTF-8 文本；面板会渲染，不要写 HTML。'; $run='不可执行；直接读或展示。' }
        '.txt'   { $kind='纯文本'; $edit='UTF-8 文本；保留原换行。'; $run='不可执行。' }
        '.log'   { $kind='日志文本'; $edit='按 UTF-8 文本读；一般只追加，不要整文件重写。'; $run='不可执行；用 grep_file / read_lines。' }
        '.html'  { $kind='HTML 页面'; $edit='UTF-8 文本；标签闭合，不要混入服务端脚本。'; $run='不是命令行程序；用浏览器打开或起本地 HTTP 服务。' }
        '.htm'   { $kind='HTML 页面'; $edit='UTF-8 文本；标签闭合。'; $run='不是命令行程序；用浏览器打开或起本地 HTTP 服务。' }
        '.css'   { $kind='样式表'; $edit='UTF-8 文本；注意括号和分号。'; $run='不可执行；由 HTML 引用。' }
        '.sql'   { $kind='SQL 脚本'; $edit='UTF-8 文本；注意目标数据库和事务。'; $run='不能单独执行；需要 sqlite/mysql/psql 等客户端。' }
        '.ipynb' { $kind='Jupyter Notebook'; $edit='JSON 结构；不要手动改坏 cell；优先用 notebook 工具。'; $run='需要 Jupyter 环境，不能当普通脚本跑。' }
        '.java'  { $kind='Java 源码'; $edit='UTF-8 文本；类名要和文件名一致。'; $run='需要 javac/java；本机没装时先 install 或说明。' }
        '.c'     { $kind='C 源码'; $edit='UTF-8 文本；注意头文件和编译参数。'; $run='需要 gcc/clang；本机没装时先 install 或说明。' }
        '.h'     { $kind='C 头文件'; $edit='UTF-8 文本；只放声明，注意 include guard。'; $run='不可单独运行；随 .c 编译。' }
        '.cpp'   { $kind='C++ 源码'; $edit='UTF-8 文本；注意头文件和编译参数。'; $run='需要 g++/clang++；本机没装时先 install 或说明。' }
        '.hpp'   { $kind='C++ 头文件'; $edit='UTF-8 文本；只放声明/模板。'; $run='不可单独运行；随 .cpp 编译。' }
        '.go'    { $kind='Go 源码'; $edit='UTF-8 文本；包名和目录结构要匹配。'; $run='需要 go；本机没装时先 install。' }
        '.rs'    { $kind='Rust 源码'; $edit='UTF-8 文本；注意所有权和依赖。'; $run='需要 rustc/cargo；本机没装时先 install。' }
        '.rb'    { $kind='Ruby 脚本'; $edit='UTF-8 文本；注意缩进和依赖。'; $run='需要 ruby；本机没装时先 install。' }
        '.php'   { $kind='PHP 脚本'; $edit='UTF-8 文本；注意 <?php 标签。'; $run='需要 php；本机没装时先 install。' }
        '.zip'   { $kind='ZIP 压缩包'; $edit='二进制，不能当文本改。'; $run='不可执行；用 unzip / zip_list。' }
        '.7z'    { $kind='7z 压缩包'; $edit='二进制，不能当文本改。'; $run='不可执行；用 unzip（需 7-Zip）。' }
        '.rar'   { $kind='RAR 压缩包'; $edit='二进制，不能当文本改。'; $run='不可执行；用 unzip（需 7-Zip）。' }
        '.png'   { $kind='PNG 图片'; $edit='二进制，不能当文本改。'; $run='不可执行；用图片工具查看/编辑。' }
        '.jpg'   { $kind='JPEG 图片'; $edit='二进制，不能当文本改。'; $run='不可执行；用图片工具查看/编辑。' }
        '.jpeg'  { $kind='JPEG 图片'; $edit='二进制，不能当文本改。'; $run='不可执行；用图片工具查看/编辑。' }
        '.gif'   { $kind='GIF 图片'; $edit='二进制，不能当文本改。'; $run='不可执行；用图片工具查看/编辑。' }
        '.pdf'   { $kind='PDF 文档'; $edit='二进制，不能当文本改；要改内容用 PDF 工具。'; $run='不可执行；用 pdf_read 读正文。' }
        '.docx'  { $kind='Word 文档'; $edit='二进制，不能当文本改；用 Word 工具。'; $run='不可执行；用文档工具打开/转换。' }
        '.xlsx'  { $kind='Excel 工作簿'; $edit='二进制，不能当文本改；用表格工具。'; $run='不可执行；用表格工具/技能。' }
        default  { $kind='未知/通用文件'; $edit='先确认是文本还是二进制；文本按 UTF-8，二进制不要硬改。'; $run='没有已知运行器；先 file_info 或说明用途。' }
    }

    if (-not $ext) { $ext = '(无扩展名)' }
    return [pscustomobject]@{
        Ext  = $ext
        Kind = $kind
        Edit = $edit
        Run  = $run
    }
}

function Test-IsTextFile {
    param([string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $binaryExt = @('.exe','.dll','.zip','.7z','.rar','.png','.jpg','.jpeg','.gif','.bmp','.ico','.pdf','.docx','.xlsx','.pptx','.mp3','.mp4','.mov','.avi','.sqlite','.db')
    if ($ext -in $binaryExt) { return $false }
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4096
            $n = $fs.Read($buf, 0, 4096)
            for ($i = 0; $i -lt $n; $i++) {
                if ($buf[$i] -eq 0) { return $false }
            }
        } finally { $fs.Dispose() }
        return $true
    } catch { return $false }
}

function Get-EditorPathList {
    param($Action)
    $candidates = @()
    try {
        foreach ($p in @($Action.paths)) {
            $s = [string]$p
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            foreach ($one in ($s -split "`r?`n|;")) {
                $t = $one.Trim().Trim('"').Trim("'")
                if ($t) { $candidates += $t }
            }
        }
    } catch { }
    $raw = [string]$Action.path
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $r = $raw.Trim()
        if ($r -match '^\s*\[.*\]\s*$') {
            try {
                $arr = $r | ConvertFrom-Json
                foreach ($p in @($arr)) { if ($p) { $candidates += [string]$p } }
            } catch { $candidates += $r }
        } elseif ($r -notmatch "`r?`n" -and $r -notmatch ';' -and $r -notmatch '\|' -and (Test-Path -LiteralPath $r)) {
            $candidates += $r
        } else {
            $parts = $r -split "`r?`n|;|\|"
            foreach ($p in $parts) {
                $s = $p.Trim()
                if ($s) { $candidates += $s }
            }
        }
    }
    $out = @()
    foreach ($p in $candidates) {
        $p2 = $p.Trim().Trim('"').Trim("'")
        if (-not $p2) { continue }
        $full = Resolve-AiPath $p2
        if ($out -notcontains $full) { $out += $full }
        if ($out.Count -ge $script:EditorMaxFiles) { break }
    }
    return $out
}

function Format-FileSize {
    param([long]$Length)
    if ($Length -ge 1MB) { return ([math]::Round($Length/1MB,1).ToString() + ' MB') }
    if ($Length -ge 1KB) { return ([math]::Round($Length/1KB,1).ToString() + ' KB') }
    return ($Length.ToString() + ' B')
}

function Get-FileViewText {
    param([string]$Full, [int]$Start = 0, [int]$End = 0, [int]$DefaultLines = 60, [int]$LineBudget = 0)
    $it = Get-Item -LiteralPath $Full -ErrorAction Stop
    $rel = Get-RelDisplay $Full
    $type = Get-FileTypeInfo $Full
    if ($it.PSIsContainer) {
        $kids = @(Get-ChildItem -LiteralPath $Full -ErrorAction SilentlyContinue | Select-Object -First 40)
        $sb0 = New-Object System.Text.StringBuilder
        [void]$sb0.AppendLine("目录 $rel（$($kids.Count) 项）")
        foreach ($k in $kids) {
            $suffix = if ($k.PSIsContainer) { '<目录>' } else { Format-FileSize $k.Length }
            [void]$sb0.AppendLine("  $($k.Name)  $suffix")
        }
        return $sb0.ToString().TrimEnd()
    }
    if (-not (Test-IsTextFile $Full)) {
        return ("$rel`n类型：$($type.Kind)；大小：$(Format-FileSize $it.Length)；这是二进制文件，不能当文本查看/编辑。`n建议：$($type.Run)")
    }

    $all = @([IO.File]::ReadAllLines($Full, [Text.Encoding]::UTF8))
    $count = $all.Count
    $startLine = 1
    if ($Start -gt 0) { $startLine = [Math]::Min($Start, [Math]::Max(1,$count)) }
    $endLine = 0
    if ($End -gt 0) { $endLine = [Math]::Min($End, $count) }
    if ($endLine -le 0) { $endLine = [Math]::Min($count, $startLine + $DefaultLines - 1) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("=== $rel === $($type.Kind)，$count 行，$(Format-FileSize $it.Length)")
    [void]$sb.AppendLine("编辑：$($type.Edit)")
    [void]$sb.AppendLine("运行：$($type.Run)")
    [void]$sb.AppendLine("")
    for ($i = $startLine - 1; $i -lt $endLine -and $i -lt $count; $i++) {
        $ln = [string]$all[$i]
        if ($ln.Length -gt $script:EditorMaxLineLen) { $ln = $ln.Substring(0,$script:EditorMaxLineLen) + '…' }
        [void]$sb.AppendLine(("{0:D4}|{1}" -f ($i + 1), $ln))
        if ($LineBudget -gt 0 -and $sb.Length -gt $LineBudget) {
            [void]$sb.AppendLine("…（输出预算到了，下一次用 line=… 继续看）")
            break
        }
    }
    if ($endLine -lt $count) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("（还有 $($count - $endLine) 行；继续看用 line=$($endLine + 1)）")
    }
    return $sb.ToString().TrimEnd()
}

function Backup-EditorFile {
    param([string]$Full)
    if (-not (Test-Path -LiteralPath $Full)) { return '' }
    try {
        $bkDir = Join-Path $script:AiRoot '.backup'
        if (-not (Test-Path $bkDir)) { New-Item -ItemType Directory -Force -Path $bkDir | Out-Null }
        $bkName = (Split-Path $Full -Leaf) + '.' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
        Copy-Item -LiteralPath $Full -Destination (Join-Path $bkDir $bkName) -Force -ErrorAction SilentlyContinue
        return (Get-RelDisplay (Join-Path $bkDir $bkName))
    } catch { return '' }
}

function Write-EditorFile {
    param([string]$Full, [string]$Text, [string]$PathLabel)
    Assert-CanWrite -Full $Full -RelPath $PathLabel
    $dir = Split-Path $Full -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $backup = Backup-EditorFile $Full
    Write-AiFileText $Full $Text
    return $backup
}

function Get-EditorChangeSnippet {
    param([string]$Old, [string]$New, [string]$Find)
    $oldLines = $Old -split "`r?`n"
    $newLines = $New -split "`r?`n"
    $idx = -1
    for ($i = 0; $i -lt $newLines.Count; $i++) {
        if ($newLines[$i] -match [regex]::Escape(($Find -split "`r?`n")[0])) { $idx = $i; break }
    }
    if ($idx -lt 0) { return '' }
    $from = [Math]::Max(0, $idx - 2)
    $to = [Math]::Min($newLines.Count - 1, $idx + 2)
    $sb = New-Object System.Text.StringBuilder
    for ($i = $from; $i -le $to; $i++) {
        $newLn = [string]$newLines[$i]
        if ($newLn.Length -gt 180) { $newLn = $newLn.Substring(0,180) + '…' }
        [void]$sb.AppendLine(("  > {0,4}| {1}" -f ($i + 1), $newLn))
    }
    return $sb.ToString().TrimEnd()
}

function Assert-EditorContentValid {
    param([string]$Full, [string]$Text)
    $ext = [IO.Path]::GetExtension($Full).ToLowerInvariant()
    if ($ext -eq '.json') {
        try { $null = Test-Json -Json $Text -ErrorAction Stop }
        catch { throw "JSON 不合法：$($_.Exception.Message)" }
    }
    if ($ext -eq '.ps1') {
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$parseErrors) | Out-Null
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $pe = $parseErrors[0]
            throw ("PowerShell 语法错误（第 $($pe.Extent.StartLineNumber) 行）：$($pe.Message)。改完再写；要用自动修正常见坑请改用 write_script。")
        }
    }
}

function Invoke-EditorWrite {
    param($Action)
    $paths = @(Get-EditorPathList $Action)
    if ($paths.Count -ne 1) { throw 'write 一次只写一个文件；要批量改多个文件用 action="replace"。' }
    $full = $paths[0]
    $content = [string]$Action.content
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    Assert-EditorContentValid $full $content
    if (Test-Path -LiteralPath $full -PathType Container) {
        throw "这是目录，不能当文件写：$(Get-RelDisplay $full)。写文件请给具体文件名。"
    }
    $exists = (Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Container)
    if ($exists) {
        $oldSize = (Get-Item -LiteralPath $full).Length
        if ($oldSize -gt 0 -and [string]::IsNullOrWhiteSpace($content)) {
            throw '不许用空内容覆盖非空文件；要清空请先说明，或改用 replace 精确删除。'
        }
        if (-not (Test-IsTextFile $full)) { throw "这是二进制文件，不能当文本覆盖：$(Get-RelDisplay $full)" }
    }
    $bak = Write-EditorFile $full $content ([string]$Action.path)
    $lines = ($content -split "`r?`n").Count
    $info = Get-FileTypeInfo $full
    $bakText = if ($bak) { "；旧版备份在 $bak" } else { '；新建文件' }
    return "已写入 $(Get-RelDisplay $full)（$lines 行，$($content.Length) 字符）$bakText。类型：$($info.Kind)。运行：$($info.Run)"
}

function Invoke-EditorAppend {
    param($Action)
    $paths = @(Get-EditorPathList $Action)
    if ($paths.Count -ne 1) { throw 'append 一次只处理一个文件。' }
    $full = $paths[0]
    if (-not (Test-Path -LiteralPath $full)) { throw "文件不存在：$(Get-RelDisplay $full)。新建请用 action=write。" }
    if (-not (Test-IsTextFile $full)) { throw "这是二进制文件，不能追加文本：$(Get-RelDisplay $full)" }
    $old = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
    $add = [string]$Action.content
    if ([string]::IsNullOrEmpty($add)) { throw 'append 需要在 content 里给要追加的内容。' }
    $newText = $old.TrimEnd("`r","`n") + "`r`n" + $add
    Assert-EditorContentValid $full $newText
    $bak = Write-EditorFile $full $newText ([string]$Action.path)
    return "已追加到 $(Get-RelDisplay $full)（+$($add.Length) 字符）；旧版备份在 $bak"
}

function Invoke-EditorInsert {
    param($Action)
    $paths = @(Get-EditorPathList $Action)
    if ($paths.Count -ne 1) { throw 'insert 一次只处理一个文件。' }
    $full = $paths[0]
    if (-not (Test-Path -LiteralPath $full)) { throw "文件不存在：$(Get-RelDisplay $full)。新建请用 action=write。" }
    if (-not (Test-IsTextFile $full)) { throw "这是二进制文件，不能插入文本：$(Get-RelDisplay $full)" }
    $n = 0
    if (-not [int]::TryParse(([string]$Action.line).Trim(), [ref]$n) -or $n -lt 1) {
        throw 'insert 需要在 line 里给行号（从 1 开始）。'
    }
    $text = [string]$Action.content
    if ([string]::IsNullOrEmpty($text)) { throw 'insert 需要在 content 里给要插入的内容。' }
    $all = @([IO.File]::ReadAllLines($full, [Text.Encoding]::UTF8))
    if ($n -gt $all.Count + 1) { throw "文件只有 $($all.Count) 行，不能插到第 $n 行；追加请用 action=append。" }
    $newLines = @()
    if ($n -eq 1) { $newLines = @($text -split "`r?`n") + $all }
    elseif ($n -eq $all.Count + 1) { $newLines = @($all) + @($text -split "`r?`n") }
    else { $newLines = @($all[0..($n-2)]) + @($text -split "`r?`n") + @($all[($n-1)..($all.Count-1)]) }
    $newText = (($newLines -join "`r`n") + "`r`n")
    Assert-EditorContentValid $full $newText
    $bak = Write-EditorFile $full $newText ([string]$Action.path)
    return "已在 $(Get-RelDisplay $full) 第 $n 行前插入 $($newLines.Count - $all.Count) 行；旧版备份在 $bak"
}

function Invoke-EditorReplace {
    param($Action)
    $paths = @(Get-EditorPathList $Action)
    if ($paths.Count -eq 0) { throw 'replace 需要 path 或 paths，指定要改的文件。' }
    $find = [string]$Action.find
    if ([string]::IsNullOrEmpty($find)) { throw 'replace 需要在 find 里给要替换的原文（精确匹配，不是正则）。' }
    $replace = [string]$Action.replace
    $results = @()
    $changed = 0
    foreach ($full in $paths) {
        if (-not (Test-Path -LiteralPath $full)) { $results += "跳过不存在：$(Get-RelDisplay $full)"; continue }
        if (-not (Test-IsTextFile $full)) { $results += "跳过二进制：$(Get-RelDisplay $full)"; continue }
        $old = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        $cnt = ([regex]::Matches($old, [regex]::Escape($find))).Count
        if ($cnt -le 0) { $results += "没找到：$(Get-RelDisplay $full)"; continue }
        $new = $old.Replace($find, $replace)
        Assert-EditorContentValid $full $new
        $bak = Write-EditorFile $full $new ([string]$Action.path)
        $changed++
        $snippet = Get-EditorChangeSnippet $old $new $find
        $results += "已改 $(Get-RelDisplay $full)：$cnt 处；备份 $bak"
        if ($snippet) { $results += $snippet }
    }
    if ($changed -eq 0) { return ("没有文件被改。`n" + ($results -join "`n")) }
    return (($results -join "`n") + "`n共改 $changed 个文件。改完可 run 或 finish。")
}

function Invoke-EditorRun {
    param($Action)
    $paths = @(Get-EditorPathList $Action)
    if ($paths.Count -ne 1) { throw 'run 一次只运行一个文件；先指定 path。' }
    $full = $paths[0]
    if (-not (Test-Path -LiteralPath $full)) { throw "文件不存在：$(Get-RelDisplay $full)" }
    if (Test-Path -LiteralPath $full -PathType Container) { throw "这是目录，不是可运行文件：$(Get-RelDisplay $full)" }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    $args = [string]$Action.command
    if ([string]::IsNullOrWhiteSpace($args)) { $args = [string]$Action.find }
    if ([string]::IsNullOrWhiteSpace($args)) { $args = [string]$Action.args }
    $rel = Get-RelDisplay $full
    $info = Get-FileTypeInfo $full

    if ($ext -eq '.ps1') {
        $scriptText = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        $risk = Test-ScriptSafety -Code $scriptText
        if ($risk) { throw ('这个脚本被安全策略拒绝，没有执行：' + $risk) }
        if ($scriptText -match '(?im)^\s*param\s*\(' -and [string]::IsNullOrWhiteSpace($args)) {
            throw '这个脚本有 param()，必须用 command 传参数；空跑参数全是 null，不能当成功。'
        }
        $inner = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8; & ''' +
                 ($full -replace "'", "''") + ''''
        if (-not [string]::IsNullOrWhiteSpace($args)) { $inner += ' ' + $args }
        $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "' + ($inner -replace '"','\"') + '"'
        return Invoke-ChildScript -FilePath 'powershell.exe' -CommandLine $cmdLine -Label "run $rel"
    }
    if ($ext -in @('.bat','.cmd')) {
        $isUtf8 = $true
        try { $null = (New-Object System.Text.UTF8Encoding($false,$true)).GetString([IO.File]::ReadAllBytes($full)) } catch { $isUtf8 = $false }
        $cp = if ($isUtf8) { '65001' } else { '936' }
        $enc = if ($isUtf8) { [Text.Encoding]::UTF8 } else { [Text.Encoding]::GetEncoding(936) }
        $line = '/c chcp ' + $cp + '>nul & "' + $full + '"'
        if (-not [string]::IsNullOrWhiteSpace($args)) { $line += ' ' + $args }
        return Invoke-ChildScript -FilePath 'cmd.exe' -CommandLine $line -Enc $enc -Label "run $rel"
    }
    if ($ext -eq '.py') {
        $py = Get-Command 'python' -ErrorAction SilentlyContinue
        $exe = ''
        $prefix = ''
        if ($py -and $py.Source) { $exe = $py.Source; $prefix = '-u' }
        else {
            $py2 = Get-Command 'py' -ErrorAction SilentlyContinue
            if ($py2 -and $py2.Source) { $exe = $py2.Source; $prefix = '-3 -u' }
        }
        if (-not $exe) { throw '本机找不到 Python（python / py）。先用 install 安装，或改用 run_python。' }
        $cmdLine = $prefix + ' "' + $full + '"'
        if (-not [string]::IsNullOrWhiteSpace($args)) { $cmdLine += ' ' + $args }
        return Invoke-ChildScript -FilePath $exe -CommandLine $cmdLine -Label "run $rel"
    }
    if ($ext -in @('.js','.mjs','.cjs')) {
        $node = Get-Command 'node' -ErrorAction SilentlyContinue
        if (-not $node -or -not $node.Source) { throw '本机找不到 Node.js；用 run_js（WSH/JScript）或 install 安装 Node。' }
        $cmdLine = '"' + $full + '"'
        if (-not [string]::IsNullOrWhiteSpace($args)) { $cmdLine += ' ' + $args }
        return Invoke-ChildScript -FilePath $node.Source -CommandLine $cmdLine -Label "run $rel"
    }
    if ($ext -eq '.sh') {
        $bash = Get-Command 'bash' -ErrorAction SilentlyContinue
        $bashPath = if ($bash -and $bash.Source) { $bash.Source } else { '' }
        if (-not $bashPath) {
            foreach ($cand in @('C:\Git\bin\bash.exe','C:\Git\usr\bin\bash.exe')) {
                if (Test-Path -LiteralPath $cand -PathType Leaf) { $bashPath = $cand; break }
            }
        }
        if (-not $bashPath) { throw '本机找不到 bash（Git Bash）；不能运行 .sh。' }
        $cmdLine = '"' + $full + '"'
        if (-not [string]::IsNullOrWhiteSpace($args)) { $cmdLine += ' ' + $args }
        return Invoke-ChildScript -FilePath $bashPath -CommandLine $cmdLine -Label "run $rel"
    }
    if ($ext -eq '.exe') {
        # 原生 Windows 程序通常按系统 ANSI 输出；中文机器用 936，避免控制台乱码。
        $enc = [Text.Encoding]::GetEncoding(0)
        return Invoke-ChildScript -FilePath $full -CommandLine $args -Enc $enc -Label "run $rel"
    }
    if ($ext -eq '.json') {
        $jsonText = Get-Content -LiteralPath $full -Raw -Encoding UTF8
        try { $null = Test-Json -Json $jsonText -ErrorAction Stop; return "JSON 合法：$rel（没有实际运行程序）" }
        catch { throw "JSON 不合法：$($_.Exception.Message)" }
    }
    if ($ext -eq '.html' -or $ext -eq '.htm') {
        return "HTML 不是命令行程序：$rel。要预览可以打开浏览器，或在目录起一个本地 HTTP 服务。"
    }
    if ($ext -eq '.sql') {
        return "SQL 不能单独运行：$rel。需要 sqlite3 / mysql / psql 等客户端连接数据库。"
    }
    throw "这个文件没有已知运行器：$rel（$($info.Kind)）。$($info.Run) 编辑建议：$($info.Edit)"
}

function Get-EditorTypeGuide {
    param([string]$Filter = '')
    $f = $Filter.Trim().ToLowerInvariant()
    if ($f -and $f -notmatch '^\.') { $f = '.' + $f }
    $rows = @(
        @('.ps1','PowerShell 脚本','UTF-8 建议 BOM；用 file_editor 或 write_script','file_editor run / run_ps1'),
        @('.bat','CMD 批处理','UTF-8 无 BOM；中文加 chcp 65001','file_editor run / run_bat'),
        @('.cmd','CMD 批处理','同 .bat；双击/命令行运行','file_editor run / run_bat'),
        @('.py','Python 脚本','UTF-8；注意缩进和依赖','file_editor run / python -u'),
        @('.js','JavaScript','UTF-8；区分 Node 与浏览器','file_editor run（Node）/ run_js（WSH）'),
        @('.mjs','ES Module','UTF-8；Node 下用 import','file_editor run（Node）'),
        @('.cjs','CommonJS','UTF-8；Node 下用 require','file_editor run（Node）'),
        @('.sh','Shell 脚本','UTF-8；LF 换行','file_editor run（Git Bash）'),
        @('.json','JSON 数据','UTF-8；不能加注释','用 Test-Json 校验'),
        @('.jsonl','JSON Lines','一行一个 JSON','逐行解析'),
        @('.csv','CSV 表格','UTF-8；保留表头','csv_preview / 技能'),
        @('.md','Markdown','UTF-8；面板会渲染','直接读/展示'),
        @('.txt','纯文本','UTF-8 或 ANSI；保留换行','直接读/展示'),
        @('.html','HTML 页面','UTF-8；标签闭合','浏览器打开/本地服务'),
        @('.exe','可执行程序','二进制不能文本改','file_editor run 直接执行'),
        @('.zip','压缩包','二进制不能文本改','unzip / zip_list'),
        @('.pdf','PDF 文档','二进制不能文本改','pdf 技能 / pdftotext'),
        @('.docx','Word 文档','二进制不能文本改；用 word 技能','不直接执行'),
        @('.xlsx','Excel 表格','二进制不能文本改；用 sheet 技能','不直接执行'),
        @('.png','图片','二进制不能文本改','图片查看/编辑工具')
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('后缀指南（编辑 / 运行）：')
    foreach ($r in $rows) {
        if ($f -and $r[0] -ne $f) { continue }
        [void]$sb.AppendLine(("{0,-7} {1}" -f $r[0], $r[1]))
        [void]$sb.AppendLine(("        编辑：{0}" -f $r[2]))
        [void]$sb.AppendLine(("        运行：{0}" -f $r[3]))
    }
    if ($sb.Length -lt 30) { return "没有这个后缀的指南：$Filter。试试 .ps1 .py .js .json .csv .html .exe .zip" }
    return $sb.ToString().TrimEnd()
}

function Invoke-FileEditor {
    param($Action)
    $act = ([string]$Action.action).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($act)) { $act = 'view' }
    if ($act -in @('read','cat','open')) { $act = 'view' }
    if ($act -in @('save','create','put')) { $act = 'write' }
    if ($act -in @('replace_all','sub')) { $act = 'replace' }
    if ($act -in @('run_file','exec','execute')) { $act = 'run' }
    if ($act -in @('type','types','ext','guide')) { $act = 'types' }

    switch ($act) {
        'view' {
            $paths = @(Get-EditorPathList $Action)
            if ($paths.Count -eq 0) { throw 'view 需要 path 或 paths；多个文件用换行/分号分隔，或传 paths 数组。' }
            $single = ($paths.Count -eq 1)
            $start = 0
            $end = 0
            if ([int]::TryParse(([string]$Action.line).Trim(), [ref]$start) -eq $false) { $start = 0 }
            if ([int]::TryParse(([string]$Action.end_line).Trim(), [ref]$end) -eq $false) { $end = 0 }
            $defaultLines = if ($single) { 120 } else { 45 }
            $sb = New-Object System.Text.StringBuilder
            $budgetLeft = $script:EditorViewBudget
            foreach ($full in $paths) {
                if (-not (Test-Path -LiteralPath $full)) { [void]$sb.AppendLine("=== $(Get-RelDisplay $full) === 不存在"); continue }
                $piece = Get-FileViewText -Full $full -Start $start -End $end -DefaultLines $defaultLines -LineBudget $budgetLeft
                [void]$sb.AppendLine($piece)
                [void]$sb.AppendLine('')
                $budgetLeft = $script:EditorViewBudget - $sb.Length
                if ($budgetLeft -lt 200) { [void]$sb.AppendLine('…（多文件查看预算到了；下一次指定 line 或只传一个文件）'); break }
            }
            $out = $sb.ToString().TrimEnd()
            if ($out.Length -gt $script:EditorViewBudget) {
                $out = $out.Substring(0, $script:EditorViewBudget) + "`n…（多文件输出已截到 $($script:EditorViewBudget) 字符；下一次用 line 继续看）"
            }
            return $out
        }
        'write' { return Invoke-EditorWrite $Action }
        'append' { return Invoke-EditorAppend $Action }
        'insert' { return Invoke-EditorInsert $Action }
        'replace' { return Invoke-EditorReplace $Action }
        'run' { return Invoke-EditorRun $Action }
        'types' {
            $f = [string]$Action.find
            if ([string]::IsNullOrWhiteSpace($f)) { $f = [string]$Action.command }
            return (Get-EditorTypeGuide -Filter $f)
        }
        default { throw "不认识 action=$act。可用：view / write / append / insert / replace / run / types" }
    }
}
