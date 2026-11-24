# ============================================================
#  Nafx · Git 工具
#
#  只暴露常用的、可解释的 Git 动作，不让模型自己拼
#  reset --hard / clean -f / push --force 这类破坏性命令。
#  - 读取：status / diff / log / show / branch / remote
#  - 写入：add / commit / init / fetch / pull --ff-only / push
# ============================================================

$script:GitTimeout = 45

function Get-GitExe {
    $g = Get-Command 'git.exe' -ErrorAction SilentlyContinue
    if (-not $g) { $g = Get-Command 'git' -ErrorAction SilentlyContinue }
    if (-not $g -or -not $g.Source) { throw '本机找不到 git.exe。先 install 安装 Git，或检查 PATH。' }
    return $g.Source
}

function Quote-GitArg {
    param([string]$S)
    if ($null -eq $S) { return '""' }
    if ($S -eq '') { return '""' }
    if ($S -match '[\s"]') {
        return '"' + ($S -replace '"', '\"') + '"'
    }
    return $S
}

function Invoke-GitProcess {
    param([string]$Repo, [string[]]$GitArgs, [int]$TimeoutSeconds = 0)
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:GitTimeout }
    $exe = Get-GitExe
    $argLine = '-C ' + (Quote-GitArg $Repo) + ' ' + (($GitArgs | ForEach-Object { Quote-GitArg ([string]$_) }) -join ' ')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.WorkingDirectory = $Repo
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $finished = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Ok=$false; Code=-1; Out=''; Err="Git 超时（${TimeoutSeconds}s），进程已终止"; Args=$argLine }
    }
    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }
    return [pscustomobject]@{ Ok=($p.ExitCode -eq 0); Code=$p.ExitCode; Out=$out.Trim(); Err=$err.Trim(); Args=$argLine }
}

function Get-GitRepoRoot {
    param([string]$Repo)
    $r = Invoke-GitProcess -Repo $Repo -GitArgs @('rev-parse','--show-toplevel')
    if (-not $r.Ok) { return $null }
    $top = ($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $top) { return $null }
    return $top.Trim()
}

function Format-GitResult {
    param($Result, [string]$Label)
    $sb = New-Object System.Text.StringBuilder
    if ($Result.Ok) { [void]$sb.AppendLine("git $Label 成功（退出码 0）") }
    else { [void]$sb.AppendLine("git $Label 失败（退出码 $($Result.Code)）") }
    if ($Result.Out) {
        $o = [string]$Result.Out
        if ($o.Length -gt 2600) { $o = $o.Substring(0,2600) + "`n…（已截断，共 $($o.Length) 字符）" }
        [void]$sb.AppendLine($o)
    }
    if ($Result.Err) {
        $e = [string]$Result.Err
        if ($e.Length -gt 900) { $e = $e.Substring(0,900) + '…' }
        $tag = if ($Result.Ok) { '--- 附加输出（git 可能把进度写到 stderr）---' } else { '--- 错误 ---' }
        [void]$sb.AppendLine($tag)
        [void]$sb.AppendLine($e)
    }
    if (-not $Result.Out -and -not $Result.Err) { [void]$sb.AppendLine('（没有输出）') }
    return $sb.ToString().TrimEnd()
}

function Split-GitFiles {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @('.') }
    $parts = @()
    if ($Raw -match "`r?`n") { $parts = $Raw -split "`r?`n" }
    elseif ($Raw -match ';') { $parts = $Raw -split ';' }
    elseif ($Raw -match ',') {
        $split = $Raw -split ','
        # 只有每一段都像路径/通配符才按逗号拆；带空格的单文件名保持完整
        $allPathish = $true
        foreach ($s in $split) { if ($s.Trim() -notmatch '^[\w./\\*?\[\]-]+$') { $allPathish = $false; break } }
        if ($allPathish) { $parts = $split } else { $parts = @($Raw) }
    }
    else { $parts = @($Raw) }
    $out = @()
    foreach ($p in $parts) {
        $s = ([string]$p).Trim().Trim('"').Trim("'")
        if ($s) { $out += $s }
    }
    if ($out.Count -eq 0) { return @('.') }
    return $out
}

function Invoke-GitTool {
    param($Action)
    $act = ([string]$Action.action).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($act)) { $act = 'status' }

    $repoRaw = [string]$Action.path
    $pathWasEmpty = [string]::IsNullOrWhiteSpace($repoRaw)
    if ($pathWasEmpty) { $repoRaw = '.' }
    $repo = Resolve-AiPath $repoRaw
    if (Test-Path -LiteralPath $repo -PathType Leaf) { $repo = Split-Path -Parent $repo }

    if ($act -eq 'init') {
        if (-not (Test-Path -LiteralPath $repo)) { New-Item -ItemType Directory -Force -Path $repo | Out-Null }
        $root = Get-GitRepoRoot $repo
        if ($root) { return "已经是 Git 仓库：$repo（根：$root）" }
        $r = Invoke-GitProcess -Repo $repo -GitArgs @('init')
        return Format-GitResult $r 'init'
    }

    # clone 的目标通常还不存在，不能走下面的“必须是已有 Git 仓库”检查。
    if ($act -eq 'clone') {
        $url = [string]$Action.command
        if ([string]::IsNullOrWhiteSpace($url)) { throw 'clone 需要在 command 里填仓库 URL。' }
        if ($url -notmatch '^(https://|http://|git@|ssh://|file://)') { throw 'clone 的 URL 必须是 http(s)/ssh/git@/file:// 地址。' }
        if ($pathWasEmpty) {
            $leaf = ($url.TrimEnd('/') -split '/')[-1]
            $leaf = $leaf -replace '\.git$',''
            if (-not $leaf) { $leaf = 'cloned-repo' }
            $repo = Resolve-AiPath $leaf
        }
        $target = $repo
        if (Test-Path -LiteralPath $target -PathType Leaf) { throw "clone 目标必须是目录，不是文件：$target" }
        if (Test-Path -LiteralPath $target) {
            $kids = @(Get-ChildItem -LiteralPath $target -ErrorAction SilentlyContinue)
            if ($kids.Count -gt 0) { throw "clone 目标不是空目录：$target。换一个目标路径。" }
        }
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $r = Invoke-GitProcess -Repo $parent -GitArgs @('clone',$url,$target)
        return Format-GitResult $r 'clone'
    }

    if (-not (Test-Path -LiteralPath $repo)) {
        throw "目录不存在：$repoRaw。先确认路径，必要的话用 make_dir 创建，或用 git(action=`"init`", path=`"目录`")。"
    }
    $root = Get-GitRepoRoot $repo
    if (-not $root) {
        $hint = "这里不是 Git 仓库：$repo。用户明确要做版本管理时，先 git(action=`"init`", path=`"$repoRaw`")；" +
                '只是读文件/改文件不需要 Git，别自作主张初始化。'
        throw $hint
    }
    $repo = $root

    switch ($act) {
        'status' {
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('status','--short','--branch')
            if ($r.Ok) {
                $s = if ($r.Out) { $r.Out } else { '（工作区干净，没有改动）' }
                return ("仓库：$repo`n" + $s + "`n`n下一步：改完先用 git(action=`"diff`") 看改动；要提交先 git(action=`"add`", files=`"路径`")。")
            }
            return Format-GitResult $r 'status'
        }
        'diff' {
            $stat = Invoke-GitProcess -Repo $repo -GitArgs @('diff','--stat','--no-color')
            $patch = Invoke-GitProcess -Repo $repo -GitArgs @('diff','--unified=3','--no-color')
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("仓库：$repo")
            if ($stat.Out) { [void]$sb.AppendLine($stat.Out) }
            if ($patch.Out) { [void]$sb.AppendLine($patch.Out) }
            if (-not $stat.Out -and -not $patch.Out) { [void]$sb.AppendLine('（没有未暂存改动）') }
            $txt = $sb.ToString().TrimEnd()
            if ($txt.Length -gt 3200) { $txt = $txt.Substring(0,3200) + "`n…（diff 已截断）" }
            return $txt
        }
        'log' {
            $n = 12
            $m = [regex]::Match([string]$Action.command, '\d+')
            if ($m.Success) { $n = [Math]::Max(1, [Math]::Min(30, [int]$m.Value)) }
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('log','--oneline','--decorate','--no-color',('-n'+$n))
            return Format-GitResult $r 'log'
        }
        'show' {
            $ref = ([string]$Action.command).Trim()
            if ([string]::IsNullOrWhiteSpace($ref)) { $ref = 'HEAD' }
            if ($ref -notmatch '^[A-Za-z0-9_./@{}^~:+-]+$' -or $ref -match '^-') { throw "show 的版本引用不合法：$ref" }
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('show','--stat','--patch','--no-color',$ref)
            return Format-GitResult $r "show $ref"
        }
        'branch' {
            $cur = Invoke-GitProcess -Repo $repo -GitArgs @('branch','--show-current')
            $all = Invoke-GitProcess -Repo $repo -GitArgs @('branch','--format=%(refname:short)')
            $sb = New-Object System.Text.StringBuilder
            if ($cur.Out) { [void]$sb.AppendLine("当前分支：$($cur.Out)") }
            if ($all.Out) { [void]$sb.AppendLine("全部分支：`n$($all.Out)") }
            return $sb.ToString().TrimEnd()
        }
        'remote' {
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('remote','-v')
            return Format-GitResult $r 'remote -v'
        }
        'add' {
            $raw = [string]$Action.files
            if ([string]::IsNullOrWhiteSpace($raw)) { $raw = [string]$Action.command }
            if ([string]::IsNullOrWhiteSpace($raw)) { throw 'add 需要在 files 里写要暂存的文件/目录（多个用换行或分号），不要无脑 add 全部。' }
            $files = @(Split-GitFiles $raw)
            $gitArgs = @('add','--')
            foreach ($f in $files) {
                if ($f -match '^--' -or $f -match '^\-') { throw "add 的文件名不能以 - 开头：$f" }
                $gitArgs += $f
            }
            $r = Invoke-GitProcess -Repo $repo -GitArgs $gitArgs
            if (-not $r.Ok) { return Format-GitResult $r 'add' }
            $st = Invoke-GitProcess -Repo $repo -GitArgs @('diff','--cached','--stat','--no-color')
            $out = "已暂存：$($files -join ', ')`n直接下一步：git(action=`"commit`", message=`"说明这次改了什么`")。"
            if ($st.Out) { $out += "`n暂存区：`n$($st.Out)" }
            return $out
        }
        'commit' {
            $msg = [string]$Action.message
            if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$Action.command }
            if ([string]::IsNullOrWhiteSpace($msg)) { throw 'commit 需要在 message 里写提交说明。' }
            $staged = Invoke-GitProcess -Repo $repo -GitArgs @('diff','--cached','--name-only')
            if (-not $staged.Ok -or [string]::IsNullOrWhiteSpace($staged.Out)) {
                throw '暂存区是空的，没有可提交的内容。先 git(action="add", files="任务相关的文件")，不要直接 commit。'
            }
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('commit','-m',$msg)
            return Format-GitResult $r 'commit'
        }
        'fetch' {
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('fetch','--all','--prune')
            return Format-GitResult $r 'fetch --all --prune'
        }
        'pull' {
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('pull','--ff-only')
            return Format-GitResult $r 'pull --ff-only'
        }
        'push' {
            $r = Invoke-GitProcess -Repo $repo -GitArgs @('push')
            return Format-GitResult $r 'push（未使用 --force）'
        }
        default {
            throw "不认识 action=$act。可用：status / diff / log / show / branch / remote / add / commit / fetch / pull / push / init / clone"
        }
    }
}
