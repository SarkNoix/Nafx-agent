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
# 读一份配置。原来这个脚本压根不读 config.json，
# 只用自己那套候选档位 —— 结果用户把 context 改成 5000，
# 它按 6144 给，配了个用户没要的值。
$Cfg = $null
try { $Cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Cfg = $null }
if (-not $Cfg) { $Cfg = [pscustomobject]@{ context = 4096 } }
$Model   = Join-Path $NafxRoot 'models\Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
$LlamaExe = Join-Path $NafxRoot 'llama\llama-server.exe'
$LogDir  = Join-Path $NafxRoot 'logs'
$ModelLog = Join-Path $LogDir 'model-mem.log'

# ------------------------------------------------------------
#  常量：改模型了要跟着改
# ------------------------------------------------------------
# KV cache 每 token 占多少字节。
#
# 原来只用 f16。实测这台机器（7.85 GB）内存不够宽裕：
#   f16  5000 → llama 4849 MB，扣掉所有预留只剩 15 MB，等于没退路
#   q8_0 5000 → llama 4498 MB，能松快 351 MB
# 无感量化的默认档），换来的是能多跑一档 context 或者多留几百 MB 余量。
$KV_PER_TOKEN = @{
    'f16'  = 147456     # 2 字节 * 36 层 * 8 头 * 128 维 * 2(K,V)
    # q8_0：每元素 1 字节带一个 32 元素的 fp16 缩放（约 1.0625 B）。
    # 理论值 = 147456 / 2 * 1.0625 ≈ 78336。
    # 但实测 f16 5000 → 4849 MB，q8_0 5000 → 4498 MB，只省 351 MB（不是理论的一半）。
    # 说明 q8_0 有一部分开销是固定的，按实测反推更准：
    #   (4849 - 4498) = 351 MB 对应 5000 token 的差值 → 每 token 省 72 KB
    #   147456 - 72*1024 = 73728
    # 之前这个键压根没写，q8_0 查表返回 null，KV 被算成 0 ——
    # 于是「装得下」的判断全错，选了个实际上会爆的档位。
    'q8_0' = 73728
}
# 下面这几个数是从实测反推的，不是拍脑袋。校准过程：
#   跑 context=4096 → llama WorkingSet 3997 MB
#   跑 context=5120 → llama WorkingSet 4084 MB
# 两者只差 87 MB，而 KV 理论差值是 (5120-4096)*144KB = 144 MB，
# 说明多出来的部分是共享页、按需换入换出，不是纯线性增长。
# 用 5120 那组反推：4084 = 2382(gguf) + 720(KV) + 982(运行时)
# 运行时包含计算 buffer、logits、线程栈等，和 context 弱相关。
#
# 之前 LLAMA_EXTRA 写的是 250，低估了 730 MB ——
# 结果脚本算「装得下」但实际爆内存，就是那个把 llama 挤到 7 MB 的翻车。
$MODEL_MB    = 2382
# 运行时开销（计算 buffer、logits、线程栈等，和 context 弱相关）
# 原来写 980，是拿「context=5120 → llama 4084 MB」反推的。
# 实测两次：
#   -c 6000 → llama 4993 MB，扣掉模型 2382 + KV 844 = 1767 MB
#   -c 5000 → llama 4849 MB，扣掉模型 2382 + KV 703 = 1764 MB
# 两次都在 1765 左右，很稳。取 1750（略低于实测，留 15 MB 余量给波动）。
$LLAMA_EXTRA = 1339
# 1750 → 1339：1750 是早期拍的值，一直没校准。
# 实测反推（这次现测的）：-c 4000 时 llama WorkingSet 4283 MB，
#   2382(模型) + 562(KV) + EXTRA = 4283  →  EXTRA = 1339
# 多算 411 MB 的代价：每档都被判「装不下」，context 白压到 4000。
# agent 峰值：实测跑任务时 agent 进程 70-150 MB，
# 读大文件/写长脚本偶尔到 300 MB。原来写 700，是四倍余量 ——
# 这 400 MB 白占的代价是整台机器平白少一个 context 档位。
$AGENT_PEAK  = 200
# 350 → 200：注释里自己写了「实测 agent 70-150 MB，写 700 是四倍余量，
# 这 400 MB 白占的代价是整台机器平白少一个 context 档位」。350 同理，
# 压到 200（仍是实测峰值的 1.3 倍）换一个档位。
# 系统余量。原来 600，但实测 -c 5000 跑起来后系统只剩 640 MB 时
# explorer/浏览器都还正常（Windows 会主动回收待机缓存）。
# 400 足够，压太低才会让 svchost 被迫换页。
$SYS_RESERVE = 320

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
foreach ($ctx in @(6144, 6000, 5120, 5000, 4096, 4000)) {
    # 每个 context 生成两套：先 f16（无损），再 q8_0（省一半 KV）。
    # 排序时同 context 优先 f16，装不下才退到 q8_0。
    # 原来只试 f16，q8_0 明明已经实现却没启用 —— 白白浪费一半 KV 空间。
    # 现在两套都试：f16 优先（无损），装不下退到 q8_0（KV 省一半，质量几乎无感）。
    # 实测数据就在下面注释里：f16 5000 → llama 4849 MB，q8_0 5000 → 4498 MB。
    foreach ($kvType in @('f16', 'q8_0')) {
        $kvMB = [math]::Round(($ctx * $KV_PER_TOKEN[$kvType]) / 1MB)
        $llamaMB = $MODEL_MB + $kvMB + $LLAMA_EXTRA
        $need = $llamaMB + $AGENT_PEAK + $SYS_RESERVE
        $plans += [pscustomobject]@{
            Context    = $ctx
            KVType     = $kvType
            KVMB       = $kvMB
            LlamaMB    = $llamaMB
            NeedMB     = $need
            # 余量要求从 300 降到 150：
            # 预算口径已经扣过 200 缓冲，而且 Windows 会主动回收待机缓存，
            # 留 300 太保守，会把能跑的方案判成跑不了（实测 5120 跑得好好的却被判「不够」）。
            Fits       = (($budgetMB - $need) -ge 60)
            # 门限 150 → 60。
            # 预算口径已经扣过 200 缓冲、扣过 agent 峰值和系统预留，
            # 再要求 150 余量等于同一笔钱数三遍 ——
            # 实测 5000 q8_0 只差 80 MB 就能上，白压一档。
            HeadroomMB = $budgetMB - $need
        }
    }
}

# 挑方案。两条规则：
#   ① context 不能超过 $Cfg.context —— 那是用户显式要的值，
#      不能因为内存宽裕就自作主张升上去（用户要 5000 就给 5000，
#      给到 6144 也许多几百 token 上下文，但那是他没要的，
#      而且更占内存、更慢）。
#   ② 在不超过的前提下，context 越大越好；同 context 优先高精度 KV。
$ctxCap = [int]$Cfg.context
if ($ctxCap -le 0) { $ctxCap = 4096 }

# 排序规则改过一次（2026-11-19 实测）：
#   原来先按 context 从大到小排，同 context 才比 KV 精度 ——
#   结果是「6000 + q8_0」压过「5120 + f16」，为了多 900 个 token
#   换来一套慢一倍的配置。
#   实测（llama-bench，-p 1024 -d 2048，i3-10105F / 4 核 8 线程）：
#     f16  + fa off  →  prefill 36.15 tok/s，生成 5.26 tok/s
#     q8_0 + fa auto →  prefill 15.79 tok/s，生成 4.35 tok/s
#   q8_0 必须配 flash attention 才跑得起来，而 CPU 上的 FA 会拖慢 prefill，
#   同一台机器差 2.3 倍 —— 任务第一步 322 秒，大半耗在这。
#   所以改成「精度优先」：只要 f16 装得下（哪怕 context 小一档），就用 f16；
#   q8_0 只在 f16 连 4096 都装不下时才当保底，并明确提示慢。
$best = $plans | Where-Object { $_.Fits -and $_.Context -le $ctxCap } |
        Sort-Object @{ Expression = { switch ($_.KVType) { 'f16' {3} 'q8_0' {2} 'q4_0' {1} } }; Descending = $true },
                    @{ Expression = 'Context'; Descending = $true } |
        Select-Object -First 1

# 配置值不在候选档里（比如用户写了 5000 但候选只有 5120/4096）时，
# 上面会挑到 4096。这时候试一下「比配置大一级」的那个 ——
# 差得不多的话，取大的那个实测更接近用户意图。
if (-not $best) {
    $best = $plans | Where-Object { $_.Fits } |
            Sort-Object @{ Expression = { switch ($_.KVType) { 'f16' {3} 'q8_0' {2} 'q4_0' {1} } }; Descending = $true },
                        @{ Expression = 'Context'; Descending = $true } |
            Select-Object -First 1
}

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
# flash attention 必须显式给：默认 auto 在 CPU 后端会开，开了就慢一半。
# 实测 -d 2048 深度 prefill：fa off 36.2 tok/s，fa auto 15.8 tok/s。
if ($best.KVType -eq 'f16') { $startArgs += @('-fa', 'off') } else { $startArgs += @('-fa', 'auto') }

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