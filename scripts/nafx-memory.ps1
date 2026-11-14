# ============================================================
#  Nafx 内存分配器
#  按当前可用内存，自动挑一套跑得稳的 llama-server 参数
#
#  为什么需要它：
#   这台机器 7.85 GB，llama 一开机就吃 5 GB，剩下 2.8 GB 要给
#   Windows + DSH + agent。以前固定用 context=6144 + fp16 KV cache，
#   KV 就占 864 MB，加上模型 2382 MB，agent 一起来就顶到爆，
#   实测出现过 llama 被压到只剩 7 MB、CPU 空转五小时的情况。
#
#  怎么算的：
#   模型本体     2382 MB（固定）
#   KV cache     每 token 144 KB（384 层头维 * 2 字节，Qwen3-4B 36 层 8 头 128 维）
#   llama 其它   约 250 MB（运行时开销）
#   agent 峰值   约 900 MB（含 PowerShell 运行时和一次大文件读取）
#   系统余量     至少留 800 MB，否则 SQLite/explorer 之类会被挤到交换
#
#  为什么不用 KV 量化（q8_0 / q4_0）：
#   试过，能再省 400 MB，但质量掉得不能用。
#   实测 8 次任务：q8_0 出现 8 次空转（模型返回空内容），f16 时期是 0 次；
#   3 个任务从 21 秒变成 185 秒。KV 量化影响的是每一步的注意力计算，
#   不是只影响长上下文，短任务一样会被拖累。
#   所以候选只留 f16 —— 内存不够就明确报错让你关程序，不能偷偷降质量。
#
#  用法：
#    nafx-memory.ps1            只看方案，不启动（默认）
#    nafx-memory.ps1 -Start     按方案启动 llama-server
#    nafx-memory.ps1 -Restart   先杀掉现有的再启动
#    nafx-memory.ps1 -Apply     把选中的 context 写回 config.json
# ============================================================

param(
    [switch]$Start,
    [switch]$Restart,
    [switch]$Apply,
    [switch]$Json,
    # 给 launcher.ps1 用：只输出一行 JSON，不打印别的（它会解析 stdout）
    [switch]$ForLauncher
)

$ErrorActionPreference = 'Stop'

# 兼容有/无控制台：重定向时退回 Write-Output，否则 Write-Host 在无控制台进程里会丢
function Write-Line2 {
    param([string]$Text = '', [string]$Color = 'Gray')
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if ($Host.Name -eq 'ConsoleHost' -and -not $redirected) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Output $Text
    }
}

$NafxRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { 'E:\Nafx' }
# 脚本放在 scripts\ 下，项目根是上一级；直接放在根部时兜底
if (-not (Test-Path (Join-Path $NafxRoot 'config.json'))) { $NafxRoot = 'E:\Nafx' }
$CfgPath = Join-Path $NafxRoot 'config.json'
$Model   = Join-Path $NafxRoot 'models\Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
$LlamaExe = Join-Path $NafxRoot 'llama\llama-server.exe'
$LogDir  = Join-Path $NafxRoot 'logs'
$ModelLog = Join-Path $LogDir 'model-mem.log'

# ------------------------------------------------------------
#  常量：改模型了要跟着改
# ------------------------------------------------------------
# 只用 f16。加别的类型要先确认质量能接受（见文件头说明）。
$KV_PER_TOKEN = @{
    'f16' = 147456      # 2 字节 * 36 层 * 8 头 * 128 维 * 2(K,V)
}
$MODEL_MB    = 2382
$LLAMA_EXTRA = 250
$AGENT_PEAK  = 900
$SYS_RESERVE = 800

# ------------------------------------------------------------
#  1. 量可用内存
# ------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
$freeMB  = [math]::Round($os.FreePhysicalMemory / 1024)

# llama 已经在跑的话，把它占的算进来（换参数时要先腾地方）
$runningLlamaMB = 0
$lp = Get-Process llama-server -ErrorAction SilentlyContinue
if ($lp) { $runningLlamaMB = [math]::Round($lp.WorkingSet64 / 1MB) }

# 口径很重要，之前写错过一次：
#   换参数时 llama 会先被杀掉，它现在占的内存会被释放——
#   但如果按「空闲 + llama 已占」算预算，等于把旧 llama 算两遍，
#   结果永远选回当前这套，等于没优化。
# 正确口径是「杀掉 llama 之后能有多少」= 当前空闲 + 现有 llama 释放的量，
# 再扣掉启动新 llama 期间系统/DSH 的正常增长（留 200 MB 缓冲）。
# 不重启（只看方案）时也一样算，因为方案是用来指导重启的。
$budgetMB = [math]::Round($freeMB + $runningLlamaMB - 200)
if ($runningLlamaMB -eq 0) { $budgetMB = $freeMB }

# ------------------------------------------------------------
#  2. 逐个方案试，挑能装下的最大的
#     优先级：context 越大越好 > KV 精度越高越好
# ------------------------------------------------------------
$plans = @()
# 注意：context 最低只到 4096，不放更小的。
# 原因：build 类任务（写脚本/做工具）会发 11 个工具 schema + project.md，
# 光这些就要 3000+ token。如果压到 2048/3072，模型直接返回 400 Bad Request，
# 任务第一步就死。实测就是这么翻车的：训练时内存紧，脚本算出 2048，
# 结果 local-script 题 3 秒 error。宁可内存不够报错让用户关程序，
# 也不能给一个跑不通的小 context。
foreach ($ctx in @(6144, 5120, 4096)) {
    foreach ($kv in @('f16')) {
        $kvMB = [math]::Round(($ctx * $KV_PER_TOKEN[$kv]) / 1MB)
        $need = $MODEL_MB + $kvMB + $LLAMA_EXTRA + $AGENT_PEAK + $SYS_RESERVE
        $plans += [pscustomobject]@{
            Context  = $ctx
            KVType   = $kv
            KVMB     = $kvMB
            NeedMB   = $need
            # 余量小于 300 MB 视为「装不下」。
            # 算得刚好够是最危险的：任务一跑 agent 就涨，立刻把 llama 挤出去。
            # 之前就是这么翻车的 —— 预算刚好，实际 agent 一起来 llama 掉到 7 MB。
            Fits     = (($budgetMB - $need) -ge 300)
            HeadroomMB = $budgetMB - $need
        }
    }
}

# 从大到小找第一个装得下的：context 优先，同 context 优先高精度
$best = $plans | Where-Object { $_.Fits } |
        Sort-Object @{ Expression = 'Context'; Descending = $true },
                    @{ Expression = { switch ($_.KVType) { 'f16' {3} 'q8_0' {2} 'q4_0' {1} } }; Descending = $true } |
        Select-Object -First 1

if (-not $best) {
    # 一个都装不下：用最省的那套，但要警告
    $best = $plans | Sort-Object NeedMB | Select-Object -First 1
    $best.Fits = $false
}

# ------------------------------------------------------------
#  3. 输出
# ------------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        totalMB   = $totalMB
        freeMB    = $freeMB
        budgetMB  = $budgetMB
        context   = $best.Context
        kvType    = $best.KVType
        needMB    = $best.NeedMB
        headroomMB= $best.HeadroomMB
        fits      = $best.Fits
    } | ConvertTo-Json -Compress
    exit 0
}

# launcher.ps1 调这个：只回一行 JSON，别的什么都不输出。
# 单独做一档是因为 launcher 要解析 stdout，混进任何提示文字都会让它坏掉。
if ($ForLauncher) {
    [pscustomobject]@{
        context = $best.Context
        kvType  = $best.KVType
        fits    = $best.Fits
    } | ConvertTo-Json -Compress
    exit 0
}

Write-Line2 "Nafx 内存分配" 'Cyan'
Write-Line2 ("-" * 62) 'DarkGray'
Write-Line2 ("  物理内存   " + $totalMB + " MB") 'White'
Write-Line2 ("  当前可用   " + $freeMB + " MB") 'White'
if ($runningLlamaMB -gt 0) {
    Write-Line2 ("  llama 已占  " + $runningLlamaMB + " MB（重启时会释放，计入预算）") 'DarkGray'
}
Write-Line2 ("  可分配预算 " + $budgetMB + " MB") 'White'
Write-Line2 ""

Write-Line2 "候选方案：" 'Gray'
foreach ($p in ($plans | Sort-Object @{Expression='Context';Descending=$true}, @{Expression={ switch ($_.KVType) { 'f16' {3} 'q8_0' {2} 'q4_0' {1} } };Descending=$true})) {
    $mark = if ($p -eq $best) { '>>' } else { '  ' }
    $fit  = if ($p.Fits) { 'OK  ' } else { '不够' }
    $line = "$mark ctx $($p.Context.ToString().PadLeft(4))  KV $($p.KVType.PadRight(4))  需 $($p.NeedMB.ToString().PadLeft(5)) MB  $fit  余 $($p.HeadroomMB.ToString().PadLeft(5)) MB"
    $col  = if ($p -eq $best) { 'Green' } elseif ($p.Fits) { 'DarkGray' } else { 'DarkRed' }
    Write-Line2 $line $col
}
Write-Line2 ""

if (-not $best.Fits) {
    Write-Line2 "!! 内存不够，最省的方案也差 $([math]::Abs($best.HeadroomMB)) MB" 'Red'
    Write-Line2 "   建议先关掉浏览器 / 别的占内存程序再试。" 'Yellow'
} else {
    # KV 量化对质量的影响：q8_0 基本无损，q4_0 可能掉点
    # 只会是 f16，不需要再提示精度问题
}

Write-Line2 "选定方案：" 'Cyan'
Write-Line2 ("  context   " + $best.Context) 'Green'
Write-Line2 ("  KV cache  " + $best.KVType + "  (约 " + $best.KVMB + " MB)") 'Green'
Write-Line2 ("  预计占用  " + $best.NeedMB + " MB（含 $AGENT_PEAK MB agent 峰值 + $SYS_RESERVE MB 系统余量）") 'Green'
Write-Line2 ""

# ------------------------------------------------------------
#  4. 启动参数
# ------------------------------------------------------------
$startArgs = @(
    '-m', $Model,
    '--host', '127.0.0.1',
    '--port', '8080',
    '-c', [string]$best.Context,
    '-t', '8',
    '-tb', '8',
    '-b', '2048',
    '-ub', '512',
    '--keep', '256',
    '-np', '1',
    '--no-warmup',
    '--jinja'
)
# KV 量化参数（f16 是默认，不用显式传）
if ($best.KVType -ne 'f16') {
    $startArgs += @('-ctk', $best.KVType, '-ctv', $best.KVType)
}

$argLine = ($startArgs | ForEach-Object { if ($_ -match '[\s\\]') { '"' + $_ + '"' } else { $_ } }) -join ' '

Write-Line2 "启动命令：" 'Gray'
Write-Line2 ("  llama-server.exe " + $argLine) 'DarkGray'
Write-Line2 ""

# ------------------------------------------------------------
#  5. 动手
# ------------------------------------------------------------
if ($Restart) {
    foreach ($p in @(Get-Process llama-server -ErrorAction SilentlyContinue)) {
        Write-Line2 ("停掉旧 llama PID " + $p.Id) 'Yellow'
        try { $p.Kill(); $p.WaitForExit(5000) | Out-Null } catch { }
    }
    Start-Sleep -Seconds 3
    $Start = $true
}

if ($Start) {
    if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
        Write-Line2 "8080 已经被占用，可能是 llama 在跑。要换参数请加 -Restart。" 'Red'
        exit 1
    }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $cmdLine = '/c start "" /b /d "' + $NafxRoot + '" "' + $LlamaExe + '" ' + $argLine + ' > "' + $ModelLog + '" 2>&1'
    Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WindowStyle Hidden

    Write-Line2 "启动中..." 'Gray'
    $ok = $false
    for ($i = 1; $i -le 40; $i++) {
        Start-Sleep -Seconds 2
        try {
            $h = Invoke-WebRequest 'http://127.0.0.1:8080/health' -UseBasicParsing -TimeoutSec 2
            if ($h.StatusCode -eq 200) { $ok = $true; break }
        } catch { }
    }
    if ($ok) {
        Start-Sleep -Seconds 2
        $np = Get-Process llama-server -ErrorAction SilentlyContinue
        $nowMB = [math]::Round($np.WorkingSet64 / 1MB)
        $os2 = Get-CimInstance Win32_OperatingSystem
        Write-Line2 ("OK  模型已就绪（" + ($i * 2) + " 秒）") 'Green'
        Write-Line2 ("    llama 实占 " + $nowMB + " MB（预算 " + $best.NeedMB + " MB）") 'Gray'
        Write-Line2 ("    系统可用   " + [math]::Round($os2.FreePhysicalMemory / 1024) + " MB") 'Gray'
        if ($nowMB -gt ($best.NeedMB - $AGENT_PEAK - $SYS_RESERVE + 200)) {
            Write-Line2 "    注意：实际占用比预算高，跑任务时留意内存。" 'Yellow'
        }
    } else {
        Write-Line2 "启动失败，看日志：" 'Red'
        Write-Line2 ("  " + $ModelLog) 'Yellow'
        if (Test-Path $ModelLog) {
            Get-Content $ModelLog -Tail 8 -Encoding UTF8 | ForEach-Object { Write-Line2 ("    " + $_) 'DarkRed' }
        }
        exit 1
    }
}

if ($Apply) {
    if (-not (Test-Path $CfgPath)) {
        Write-Line2 ("找不到配置文件 " + $CfgPath) 'Red'
        exit 1
    }
    $json = [IO.File]::ReadAllText($CfgPath, [Text.Encoding]::UTF8)
    $json2 = [regex]::Replace($json, '("context"\s*:\s*)\d+', ('${1}' + $best.Context))
    if ($json2 -ne $json) {
        [IO.File]::WriteAllText($CfgPath, $json2, (New-Object Text.UTF8Encoding($false)))
        Write-Line2 ("已把 config.json 的 context 改成 " + $best.Context) 'Green'
    } else {
        Write-Line2 ("config.json 的 context 已经是 " + $best.Context + "，没动") 'Gray'
    }
}

if (-not $Start -and -not $Apply) {
    Write-Line2 "（只计算，没动手。加 -Start 启动 / -Restart 重启 / -Apply 写回 config.json）" 'DarkGray'
}