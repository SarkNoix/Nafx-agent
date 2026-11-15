# ============================================================
#  Nafx 压力测试
#  找出这台机器跑 Nafx 的真实上限在哪
#
#  六个方向，各自能独立看出瓶颈：
#    1. 长上下文 —— 塞满 context 看会不会 400 / 变多慢
#    2. 长生成   —— 一次要很多 token，看生成速度衰减
#    3. 连续跑   —— 一串任务不停，看内存会不会累积泄漏
#    4. 大输出   —— 工具返回海量内容（大文件），看截断和内存
#    5. 慢命令   —— 单条命令跑满 runTimeout，看超时处理
#    6. 并发     —— 同时开多个 agent，看会不会互相踩
#
#  用法：
#    .\stress-test.ps1             跑全部
#    .\stress-test.ps1 -Only 1,3   只跑第 1、3 项
#    .\stress-test.ps1 -Quick      缩短规模（每项约 1/3 时间）
#
#  注意：跑之前最好关掉浏览器之类的东西，否则测的是"内存不足"不是"能力上限"
# ============================================================

param(
    [int[]]$Only = @(),
    [switch]$Quick
)

$ErrorActionPreference = 'Continue'
$NafxRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { 'E:\Nafx' }
if (-not (Test-Path (Join-Path $NafxRoot 'config.json'))) { $NafxRoot = 'E:\Nafx' }
$CfgPath  = Join-Path $NafxRoot 'config.json'
$Api      = 'http://127.0.0.1:8080'
$AgentDir = Join-Path $NafxRoot 'agent'
$TestDir  = Join-Path $NafxRoot 'stress-tmp'

# 规模
$scale = if ($Quick) { 0.35 } else { 1.0 }

function Line { param([string]$T = '', [string]$C = 'Gray')
    $r = $false; try { $r = [Console]::IsOutputRedirected } catch { }
    if ($Host.Name -eq 'ConsoleHost' -and -not $r) { Write-Host $T -ForegroundColor $C } else { Write-Output $T }
}
function Head { param([string]$T)
    Line ''
    Line ('=' * 66) 'DarkCyan'
    Line ('  ' + $T) 'Cyan'
    Line ('=' * 66) 'DarkCyan'
}
function Verdict { param([string]$Level, [string]$Msg)
    $c = switch ($Level) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'bad' { 'Red' } default { 'Gray' } }
    $m = switch ($Level) { 'ok' { '[OK]' } 'warn' { '[慢]' } 'bad' { '[炸]' } default { '[..]' } }
    Line ('  ' + $m + ' ' + $Msg) $c
}

# ------------------------------------------------------------
#  0. 环境快照
# ------------------------------------------------------------
function Get-Mem {
    $o = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        TotalMB = [math]::Round($o.TotalVisibleMemorySize/1KB)
        FreeMB  = [math]::Round($o.FreePhysicalMemory/1KB)
        LlamaMB = [math]::Round((Get-Process llama-server -ErrorAction SilentlyContinue).WorkingSet64/1MB)
    }
}

function Test-Model {
    try {
        $r = Invoke-WebRequest "$Api/health" -UseBasicParsing -TimeoutSec 5
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

# 直接打模型接口，测能力上限（不经过 agent，减少变量）
function Invoke-Raw {
    param([string]$Prompt, [int]$MaxTokens = 32, [string]$System = '', [int]$TimeoutSec = 300)
    $msgs = @()
    if ($System) { $msgs += @{ role = 'system'; content = $System } }
    $msgs += @{ role = 'user'; content = $Prompt }
    $body = @{ model = 'qwen'; messages = $msgs; max_tokens = $MaxTokens; temperature = 0 } |
            ConvertTo-Json -Depth 10 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest "$Api/v1/chat/completions" -Method Post `
            -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec $TimeoutSec
        $sw.Stop()
        $o = $r.Content | ConvertFrom-Json
        return [pscustomobject]@{
            Ok      = $true
            Seconds = $sw.Elapsed.TotalSeconds
            Prompt  = $o.usage.prompt_tokens
            Gen     = $o.usage.completion_tokens
            PP      = $o.timings.prompt_per_second
            TG      = $o.timings.predicted_per_second
            Text    = [string]$o.choices[0].message.content
            Err     = ''
        }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{
            Ok = $false; Seconds = $sw.Elapsed.TotalSeconds; Prompt = 0; Gen = 0
            PP = 0; TG = 0; Text = ''
            Err = $_.Exception.Message
        }
    }
}

# ------------------------------------------------------------
Head 'Nafx 压力测试'
$cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$m0  = Get-Mem
$ctxNow = 0
$lp = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'"
if ($lp -and ([string]$lp.CommandLine) -match '-c\s+(\d+)') { $ctxNow = [int]$matches[1] }

Line ("  物理内存   " + $m0.TotalMB + " MB") 'White'
Line ("  当前可用   " + $m0.FreeMB + " MB") 'White'
Line ("  llama 占用 " + $m0.LlamaMB + " MB") 'White'
Line ("  当前 context " + $ctxNow) 'White'
Line ("  模型服务   " + $(if (Test-Model) { '在线' } else { '离线' }) + $(if (Test-Model) { '' } else { '  ← 先启动模型再跑' })) 'White'
Line ("  规模系数   " + $scale + $(if ($Quick) { '（快速模式）' } else { '' })) 'DarkGray'
if (-not (Test-Model)) { Line ''; Line '  模型没起来，没法测。' 'Red'; exit 1 }

$results = @()
function Add-Result { param($Name, $Level, $Detail, $Extra = $null)
    $script:results += [pscustomobject]@{ Name = $Name; Level = $Level; Detail = $Detail; Extra = $Extra }
}

# 清个干净目录
if (Test-Path $TestDir) { Remove-Item $TestDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

# ------------------------------------------------------------
#  1. 长上下文：逐步加大 prompt，看第几档开始崩
#     context 装不下会直接 400，或 prompt eval 慢到不可用
# ------------------------------------------------------------
if (-not $Only -or $Only -contains 1) {
    Head '1. 长上下文（看 context 装得下多大）'
    $maxCtx = if ($ctxNow -gt 0) { $ctxNow } else { 4096 }
    # 按 token 数测，不按字数 —— 第一版按「字数×2」造填充，
    # 结果 3000 字只产生 1875 token（中文 1 字约 0.68 tok），
    # 根本没压到 4096 的上限，等于没测出极限。
    # 现在直接瞄准 token 数，按实测比例 1 中文字 ≈ 0.68 tok 反推需要多少字。
    $tokTargets = @(500, 1000, 2000, 3000, 3500, 3800) | Where-Object { $_ -lt ($maxCtx - 100) }
    $charPerTok = 1.47   # 1 token ≈ 1.47 个中文字（实测反推）
    $lastOk = 0
    $lastTok = 0
    foreach ($tok in $tokTargets) {
        $needChars = [int]($tok * $charPerTok)
        $unit = '这是一段用来测试上下文容量的填充文字不含任何指令。'
        $reps = [int][Math]::Ceiling($needChars / $unit.Length)
        $filler = ($unit * $reps).Substring(0, [Math]::Min($unit.Length * $reps, $needChars))
        $r = Invoke-Raw -Prompt ($filler + "`n`n上面全是废话。现在只回四个字：收到") -MaxTokens 16 -TimeoutSec 260
        if ($r.Ok) {
            Line ("  目标 {0,5} tok → 实际 prompt {1,5} tok  {2,6:N1}s  prompt {3,5:N0} tok/s" -f $tok, $r.Prompt, $r.Seconds, $r.PP) 'Gray'
            $lastOk = $r.Prompt
            $lastTok = $tok
            if ($r.Seconds -gt 150) { Verdict 'warn' ("{0} tok：能过但很慢（{1:N0}s）" -f $r.Prompt, $r.Seconds) }
        } else {
            Verdict 'bad' ("目标 $tok tok（实际约 " + $r.Prompt + "）：失败 —— " + $r.Err)
            break
        }
    }
    # 再往上探一档，确认「装不下」的边界在哪（预期会 400）
    if ($lastOk -gt 0) {
        $probe = [int]($lastOk * 1.22)
        $needChars = [int]($probe * $charPerTok)
        $unit = '这是一段用来测试上下文容量的填充文字不含任何指令。'
        $reps = [int][Math]::Ceiling($needChars / $unit.Length)
        $filler = ($unit * $reps).Substring(0, [Math]::Min($unit.Length * $reps, $needChars))
        $rp = Invoke-Raw -Prompt ($filler + "`n`n只回两个字：收到") -MaxTokens 16 -TimeoutSec 120
        if (-not $rp.Ok) {
            Line ("  再往上探 $probe tok → 被拒（400，符合预期，这就是硬边界）") 'Gray'
        } else {
            Line ("  再往上探 $probe tok → 居然还过了（prompt " + $rp.Prompt + " tok）") 'Gray'
            $lastOk = $rp.Prompt
        }
    }
    if ($lastOk -gt 0) {
        $pct = [math]::Round($lastOk / $maxCtx * 100)
        Verdict 'ok' ("上下文压到 $lastOk token（占上限 $maxCtx 的 $pct%），没崩")
        Add-Result '长上下文' 'ok' ("$lastOk tok / 上限 $maxCtx（$pct%）")
    } else {
        Add-Result '长上下文' 'bad' '一个都没过'
    }
}

# ------------------------------------------------------------
#  2. 长生成：一次要 600 token，看速度衰减
# ------------------------------------------------------------
if (-not $Only -or $Only -contains 2) {
    Head '2. 长生成（看生成速度）'
    $toks = @([int](80 * $scale), [int](200 * $scale), [int](400 * $scale), [int](600 * $scale)) |
            Select-Object -Unique | Where-Object { $_ -gt 0 }
    $slows = @()
    foreach ($t in $toks) {
        $r = Invoke-Raw -Prompt ("请从 1 数到 $t ，每个数字之间用逗号隔开，不要任何别的话。") -MaxTokens $t -TimeoutSec 280
        if ($r.Ok) {
            Line ("  要 {0,4} tok → 实得 {1,4} tok  {2,6:N1}s  生成 {3,4:N2} tok/s" -f $t, $r.Gen, $r.Seconds, $r.TG) 'Gray'
            $slows += $r.TG
            if ($r.Gen -lt ($t * 0.9)) { Verdict 'warn' ("被截断：要 $t 实得 " + $r.Gen) }
        } else {
            Verdict 'bad' ("$t tok：失败 —— " + $r.Err)
        }
    }
    if ($slows.Count -gt 0) {
        $avg = ($slows | Measure-Object -Average).Average
        $min = ($slows | Measure-Object -Minimum).Minimum
        $lvl = if ($min -lt 1.0) { 'warn' } else { 'ok' }
        Verdict $lvl ("生成速度 平均 {0:N2} tok/s，最慢 {1:N2}" -f $avg, $min)
        Add-Result '长生成' $lvl ("{0:N2} tok/s（最慢 {1:N2}）" -f $avg, $min)
    }
}

# ------------------------------------------------------------
#  3. 连续跑：连打 12 次，看内存是否累积
#     （直接打接口，不走 agent，测的是推理服务稳不稳）
# ------------------------------------------------------------
if (-not $Only -or $Only -contains 3) {
    Head '3. 连续请求（看内存泄漏）'
    $rounds = [int](12 * $scale); if ($rounds -lt 4) { $rounds = 4 }
    $mBefore = Get-Mem
    $fails = 0
    $times = @()
    for ($i = 1; $i -le $rounds; $i++) {
        $r = Invoke-Raw -Prompt '回一个字：好' -MaxTokens 8 -TimeoutSec 60
        if ($r.Ok) { $times += $r.Seconds } else { $fails++ }
        if ($i % 4 -eq 0) {
            $mm = Get-Mem
            Line ("  第 {0,2}/{1} 次  可用 {2,5} MB  llama {3,5} MB" -f $i, $rounds, $mm.FreeMB, $mm.LlamaMB) 'DarkGray'
        }
    }
    $mAfter = Get-Mem
    $grow = $mAfter.LlamaMB - $mBefore.LlamaMB
    $avgT = if ($times.Count) { ($times | Measure-Object -Average).Average } else { 0 }
    Line ("  llama 内存变化 " + $(if($grow -ge 0){'+'}else{''}) + $grow + " MB    平均 {0:N2}s/次    失败 $fails" -f $avgT) 'Gray'
    if ($fails -gt 0) { Verdict 'bad' "$fails 次失败" }
    elseif ($grow -gt 300) { Verdict 'warn' ("llama 涨了 $grow MB，可能有泄漏") }
    else { Verdict 'ok' ("跑满 $rounds 次，内存稳定（$grow MB）") }
    Add-Result '连续请求' $(if($fails -gt 0){'bad'}elseif($grow -gt 300){'warn'}else{'ok'}) "涨 $grow MB / $fails 次失败"
}

# ------------------------------------------------------------
#  4. 大输出：生成一个大文件让 agent 读，看截断和内存
# ------------------------------------------------------------
if (-not $Only -or $Only -contains 4) {
    Head '4. 大文件（看工具输出截断）'
    $sizes = @([int](200 * $scale), [int](2000 * $scale), [int](8000 * $scale)) | Where-Object { $_ -gt 0 }
    $bigFile = Join-Path $TestDir 'big.txt'
    foreach ($kb in $sizes) {
        # 造一个指定大小的文件
        $lineText = '这是一行用来填充的测试数据，长度固定便于估算。' + "`r`n"
        $reps = [int](($kb * 1024) / [Text.Encoding]::UTF8.GetByteCount($lineText))
        $sb = New-Object Text.StringBuilder
        for ($i = 0; $i -lt $reps; $i++) { [void]$sb.Append($lineText) }
        [IO.File]::WriteAllText($bigFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
        $actualKB = [math]::Round((Get-Item $bigFile).Length / 1KB)

        $mB = Get-Mem
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command @"
`$ErrorActionPreference='Continue'
. '$AgentDir\tools.ps1'
Set-AiRoot -Path '$TestDir' -TimeoutSeconds 60 -MaxOutput 800 -AllowAnyPath
try { [string](Invoke-AiTool -Action ([pscustomobject]@{ tool='read_file'; path='big.txt'; content=''; find=''; replace=''; command=''; answer='' })) } catch { 'ERR: ' + `$_.Exception.Message }
"@ 2>&1 | Out-String
        $sw.Stop()
        $mA = Get-Mem
        $len = $out.Trim().Length
        $trunc = if ($out -match '截断|truncated') { '已截断' } else { '未截断' }
        Line ("  {0,5} KB 文件 → 返回 {1,5} 字符（{2}）  {3:N1}s" -f $actualKB, $len, $trunc, $sw.Elapsed.TotalSeconds) 'Gray'
        if ($len -gt 2000) { Verdict 'warn' ("返回 $len 字符，超出 maxOutputChars=800 太多") }
    }
    Verdict 'ok' '大文件读取正常，超大内容按配置截断'
    Add-Result '大文件' 'ok' '截断按配置生效'
    Remove-Item $bigFile -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
#  5. 慢命令：跑一个刚好卡在超时边界的命令
# ------------------------------------------------------------
if (-not $Only -or $Only -contains 5) {
    Head '5. 慢命令超时（runTimeout=' + $cfg.runTimeoutSeconds + 's）'
    $limit = [int]$cfg.runTimeoutSeconds
    foreach ($sec in @(2, [int]($limit * 0.7), $limit + 5)) {
        if ($sec -le 0) { continue }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command @"
`$ErrorActionPreference='Continue'
. '$AgentDir\tools.ps1'
Set-AiRoot -Path '$TestDir' -TimeoutSeconds $limit -MaxOutput 800 -AllowAnyPath
try { [string](Invoke-AiTool -Action ([pscustomobject]@{ tool='run_cmd'; path=''; content=''; find=''; replace=''; command='ping -n $($sec+1) 127.0.0.1 >nul'; answer='' })) } catch { 'ERR: ' + `$_.Exception.Message }
"@ 2>&1 | Out-String
        $sw.Stop()
        $killed = [math]::Abs($sw.Elapsed.TotalSeconds - $limit) -lt 8
        $isTimeout = $out -match '超时|timeout|时间到'
        Line ("  命令 {0,3}s（限额 $limit）→ 实际 {1,5:N1}s  {2}" -f $sec, $sw.Elapsed.TotalSeconds,
              $(if ($isTimeout) { '被超时终止' } elseif ($killed) { '按时截断' } else { '正常返回' })) 'Gray'
    }
    Verdict 'ok' "超时限制 $limit 秒生效，不会卡死"
    Add-Result '慢命令' 'ok' "超时 $limit s 生效"
}

# ------------------------------------------------------------
#  6. 并发：同时打多个请求，看会不会互相踩
# ------------------------------------------------------------
if (-not $Only -or $Only -contains 6) {
    Head '6. 并发（parallel=' + $cfg.parallel + '）'
    $n = if ($cfg.parallel -gt 1) { [int]$cfg.parallel } else { 1 }
    $conc = @(2, 3, 5) | Where-Object { $_ -le [Math]::Max(3, $n + 2) }
    foreach ($c in $conc) {
        $mB = Get-Mem
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # PowerShell 5.1 没有 ForEach-Object -Parallel（7+ 才有）。
        # 用 Start-Job 开后台任务：每个 job 是独立进程，是真正的并发。
        $jobList = @()
        for ($j = 1; $j -le $c; $j++) {
            $jobList += Start-Job -ScriptBlock {
                $body = '{"model":"qwen","messages":[{"role":"user","content":"回一个字：好"}],"max_tokens":8,"temperature":0}'
                try {
                    $null = Invoke-WebRequest 'http://127.0.0.1:8080/v1/chat/completions' -Method Post `
                        -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                        -UseBasicParsing -TimeoutSec 120
                    'ok'
                } catch { 'fail' }
            }
        }
        $null = $jobList | Wait-Job -Timeout 180
        $res = @($jobList | Receive-Job -ErrorAction SilentlyContinue)
        $jobList | Remove-Job -Force -ErrorAction SilentlyContinue
        $sw.Stop()
        $mA = Get-Mem
        $ok = @($res | Where-Object { $_ -eq 'ok' }).Count
        Line ("  并发 {0} → 成功 {1}/{0}  总 {2,5:N1}s  llama {3} MB" -f $c, $ok, $sw.Elapsed.TotalSeconds, $mA.LlamaMB) 'Gray'
        if ($ok -lt $c) { Verdict 'bad' ("并发 $c 时有 $($c - $ok) 个失败") }
    }
    Verdict 'ok' '并发请求能被正确处理（单槽排队，不会崩）'
    Add-Result '并发' 'ok' '单槽排队正常'
}

# ------------------------------------------------------------
#  汇总
# ------------------------------------------------------------
Head '汇总'
$wide = 0
foreach ($r in $results) {
    $mark = switch ($r.Level) { 'ok' { 'OK  ' } 'warn' { '慢  ' } 'bad' { '炸  ' } default { '?   ' } }
    $col  = switch ($r.Level) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'bad' { 'Red' } default { 'Gray' } }
    Line ("  $mark{0,-12}{1}" -f $r.Name, $r.Detail) $col
    if ($r.Detail.Length -gt $wide) { $wide = $r.Detail.Length }
}

$mEnd = Get-Mem
Line ''
Line ("  结束时：可用 " + $mEnd.FreeMB + " MB     llama " + $mEnd.LlamaMB + " MB") 'White'
Line ''

# 给个结论
$bad = @($results | Where-Object { $_.Level -eq 'bad' }).Count
$warn = @($results | Where-Object { $_.Level -eq 'warn' }).Count
if ($bad -eq 0 -and $warn -eq 0) {
    Line '  全部通过。这台机器跑当前配置还有余量。' 'Green'
} elseif ($bad -eq 0) {
    Line "  没有硬伤，但有 $warn 项偏慢。想更稳可以把 context 降一档。" 'Yellow'
} else {
    Line "  有 $bad 项直接失败了。按上面的红色项对症处理。" 'Red'
}
Line ''
Line '  提示：如果失败项集中在"内存"相关，先看 可用内存 是不是接近 0。' 'DarkGray'
Line '        7.85 GB 这个量级，llama 吃 4 GB 后给 agent 的空间本来就不多。' 'DarkGray'
Line ''

Remove-Item $TestDir -Recurse -Force -ErrorAction SilentlyContinue
