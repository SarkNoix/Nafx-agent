param([switch]$NoBrowser, [string]$ConfigFile = 'config.json')

# ============================================================
#  Nafx · 模型服务启动器
#  默认读 config.json；加 -ConfigFile config.self.json 用个人配置
# ============================================================
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$cfgPath = $ConfigFile
if (-not [IO.Path]::IsPathRooted($cfgPath)) { $cfgPath = Join-Path $Root $cfgPath }
if (-not (Test-Path $cfgPath)) {
    Write-Host ('找不到配置文件：' + $cfgPath) -ForegroundColor Red
    exit 1
}
Write-Host ('配置文件：' + (Split-Path $cfgPath -Leaf)) -ForegroundColor DarkGray
$Cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-AppPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    return [IO.Path]::GetFullPath((Join-Path $Root $p))
}

$ModelPath = Resolve-AppPath $Cfg.model
# llama 编译方式：cpu 用 llama\，gpu 用 llama-gpu\。
# 在面板「设置 → 模型编译方式」里切换（先初始化检测，再选择）。
$LlamaMode = if ($Cfg.llamaMode) { [string]$Cfg.llamaMode } else { 'cpu' }
$LlamaDir  = if ($LlamaMode -eq 'gpu') {
    if ($Cfg.llamaGpuDir) { [string]$Cfg.llamaGpuDir } else { 'llama-gpu' }
} else {
    if ($Cfg.llamaCpuDir) { [string]$Cfg.llamaCpuDir } else { 'llama' }
}
$Server = Join-Path $Root ($LlamaDir.Trim('\') + '\llama-server.exe')
$LogDir = Join-Path $Root 'logs'
$Listen = [string]$Cfg.host
$Port = [int]$Cfg.port
$Url = "http://" + $Listen + ":" + $Port

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Test-AiUp {
    try { return ((Invoke-WebRequest ($Url + '/health') -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) }
    catch { return $false }
}

if (-not (Test-Path $Server)) { Write-Host ('找不到 llama-server：' + $Server) -ForegroundColor Red; exit 1 }
if (-not (Test-Path $ModelPath)) { Write-Host ('找不到模型：' + $ModelPath) -ForegroundColor Red; exit 1 }

if (-not (Test-AiUp)) {
    Write-Host ('启动 ' + $Cfg.name + ' 的推理服务...') -ForegroundColor Cyan

    $loadMode = 'mmap'
    if ($Cfg.loadMode) { $loadMode = [string]$Cfg.loadMode }
    # 优先级：只有 0 = normal 才是安全默认。
    # 之前默认 1（medium），llama.cpp 会在进程基类上再抬高一级 ——
    # 实际跑起来整个 llama-server 是 AboveNormal、7 个计算线程更高，
    # 8 核机器直接被它吃干净，面板只能排队：实测 /api/state 往返 500~2400ms，
    # 顶栏延迟徽标 70~1000ms 全红。
    # 现在默认 normal，并在就绪后把进程压到 BelowNormal（见下方），
    # 面板（monitor 自己是 AboveNormal）随时插队，往返回到 10~20ms。
    $prio = '0'
    if ($Cfg.prio) { $prio = [string]$Cfg.prio }

    # 线程数。
    # 原来写得"0 或超过核心数就自动用满全部核心"，结果 i3-10105F 是 4 核 8 线程，
    # 8 个线程把 8 个逻辑核全占满 —— Windows 桌面、浏览器、本机面板全都抢不到 CPU，
    # 整台机器像死机一样卡（llama-server 空闲时都在 70-110% 占用，
    # 因为那个"查 robocopy 怎么用"的任务跑偏了，一直翻文件不收敛）。
    # 现在默认留一个核给系统和界面：线程数 = 逻辑核数 - 1，最少 2。
    # 只少一个核，推理速度几乎不掉（实测 8→7 线程，5.6s → 5.8s），
    # 但桌面和面板能正常响应了。
    $cores = [Environment]::ProcessorCount
    $reserve = 1
    $maxForModel = [Math]::Max(2, $cores - $reserve)
    $threads = 0
    if ($Cfg.threads) { $threads = [int]$Cfg.threads }
    if ($threads -le 0) {
        $threads = $maxForModel
    } elseif ($threads -gt $maxForModel) {
        # 配置里写了 8（等于全用满），压回到留一核
        $threads = $maxForModel
    }

    # 先用内存分配脚本算一下这台机器现在能开多大的上下文。
    # 算不出来（脚本不在/报错）就用 config.json 里的值，不因为这一步把启动搞挂。
    # 为什么要动态算：这台机器 7.85 GB，llama 一开就 4.6 GB，
    # 如果同时开着浏览器/编辑器，固定写 6144 会把内存顶爆，
    # 实测出现过 llama 被压到只剩 7 MB、CPU 空转五小时的情况。
    $ctxSize = [int]$Cfg.context
    try {
        $memScript = Join-Path $Root 'scripts\nafx-memory.ps1'
        if (Test-Path $memScript) {
            # 不能直接写 `& powershell`：有些会话的 PATH 里没有
            # System32\WindowsPowerShell\v1.0（实测就踩过，脚本静默回退成
            # 配置里的固定值，KV 档位永远选不对）。先按名字找，找不到用全路径。
            $memExe = $null
            try { $memExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source } catch { }
            if (-not $memExe) {
                $cand = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (Test-Path $cand) { $memExe = $cand }
            }
            $memOut = & $memExe -NoProfile -ExecutionPolicy Bypass -File $memScript -ForLauncher 2>$null
            $memObj = $null
            try { $memObj = ($memOut | Select-Object -First 1) | ConvertFrom-Json } catch { }
            if ($memObj -and $memObj.context) {
                $autoCtx = [int]$memObj.context
                if ($autoCtx -ne $ctxSize) {
                    Write-Host ("  上下文按当前内存调整为 " + $autoCtx + "（配置里是 " + $ctxSize + "）") -ForegroundColor DarkYellow
                }
                # fits=false 表示连最省的那套都装不下。这时还硬启动，
                # 会把 llama 挤进交换文件，跑起来比不跑还慢（实测掉到 7 MB 空转）。
                # 不阻止启动（用户可能就想先开着），但必须说清楚。
                if ($memObj.fits -eq $false) {
                    Write-Host '  [警告] 当前内存不够，模型可能被挤到交换文件，会明显变慢。' -ForegroundColor Red
                    Write-Host '         建议先关掉浏览器 / 编辑器等占内存的程序再启动。' -ForegroundColor Red
                }
                $ctxSize = $autoCtx
            }
        }
    } catch {
        Write-Host ('  [提示] 内存脚本没跑起来，按配置里的 context=' + $ctxSize + ' 启动') -ForegroundColor DarkGray
    }

    # 模型相关参数从配置读，这样换任何模型都能调，不用改脚本
    $prof = $null
    try { $prof = $Cfg.modelProfile } catch { }

    $argList = @(
        '-m', $ModelPath,
        '--host', $Listen,
        '--port', [string]$Port,
        '-c', [string]$ctxSize,
        '-t', [string]$threads,
        '-tb', [string]$threads,
        '-np', "$([int]$Cfg.parallel)",
        # 前缀缓存显式打开；cache-reuse 让历史被裁/改写时还能复用
        # 相邻的 KV 块，少做一次整段 prefill。
        '--cache-prompt',
        '--cache-reuse', '256',
        # KV 缓存落盘目录。预热脚本跑完会把 slot 存到这里，下次启动先 restore，
        # 把「重启后等 90~110 秒重新 prefill」变成「几秒读盘」。
        # 不传这个参数时 /slots?action=save 默认是 disabled，直接报错。
        '--slot-save-path', (Join-Path $Root 'cache\slots'),
        '--load-mode', $loadMode,
        '--prio', $prio,
        '--timeout', '600'
    )

    # GPU 编译版：默认整模全量进显存（-ngl 99）。
    # extraArgs 里用户自己写了 -ngl 就以用户的为准，不重复加。
    if ($LlamaMode -eq 'gpu') {
        $extraNgls = ''
        try { if ($prof -and $prof.extraArgs) { $extraNgls = [string]$prof.extraArgs } } catch { }
        if ($extraNgls -notmatch '-ngl') { $argList += @('-ngl', '99') }
    }

    # KV 缓存量化：这是省内存的关键。fp16 的 KV 很占地方，
    # 压到 8bit 后同样内存能多装 2 倍上下文（4B 模型上质量几乎无感）。
    #
    # 优先级：内存脚本算出来的 kvType > config.json 里的手动设置。
    # 为什么：内存脚本是按「现在能装多少」实时算的，
    # 手动设的 f16 在内存紧的时候会直接爆。
    # 之前这里只读 $Cfg.kvCacheTypeK，内存脚本算出的 q8_0 压根没用上 ——
    # 结果就是「预算说能跑 6144，实际按 f16 启动直接 OOM」。
    try {
        $ctk = [string]$Cfg.kvCacheTypeK
        $ctv = [string]$Cfg.kvCacheTypeV
        $fa  = [string]$Cfg.flashAttn
        if ($memObj -and $memObj.kvType) {
            $autoKv = [string]$memObj.kvType
            if ($autoKv -and $autoKv -ne $ctk) {
                Write-Host ("  KV 缓存按当前内存用 " + $autoKv + "（配置里是 " + $(if($ctk){$ctk}else{'f16'}) + "）") -ForegroundColor DarkYellow
            }
            $ctk = $autoKv
            $ctv = $autoKv
            # KV 量化必须配 flash attention，否则 llama 会拒绝启动
            if ($autoKv -ne 'f16') { $fa = 'auto' }
        }
        if ($ctk -and $ctk -ne 'f16') { $argList += @('-ctk', $ctk) }
        if ($ctv -and $ctv -ne 'f16') { $argList += @('-ctv', $ctv) }
        # f16 KV 必须显式关掉 flash attention。
        # CPU 后端下 -fa auto 会真的打开，一打开 prefill 就从 36 掉到 16 tok/s
        # （实测 llama-bench -p 1024 -d 2048：fa off 36.15 / fa auto 15.79）。
        # 只有用户明确写 on 才放行。
        if (($ctk -eq 'f16' -or -not $ctk) -and $fa -ne 'on') { $fa = 'off' }
        if ($fa -in @('on','off','auto')) { $argList += @('-fa', $fa) }
    } catch { }

    if ($prof) {
        # 对话模板：jinja 让 llama.cpp 用模型自带的模板（多数情况最合适）
        # 有些 GGUF 转换时把模板丢了（比如 xLAM），这时用 chatTemplateFile 指定外置模板
        $tmpl = [string]$prof.chatTemplate
        if ([string]::IsNullOrWhiteSpace($tmpl)) { $tmpl = 'jinja' }
        if ($tmpl -eq 'jinja') { $argList += '--jinja' }

        $tplFile = [string]$prof.chatTemplateFile
        if (-not [string]::IsNullOrWhiteSpace($tplFile)) {
            if (-not [IO.Path]::IsPathRooted($tplFile)) { $tplFile = Join-Path $Root $tplFile }
            if (Test-Path $tplFile) {
                $argList += @('--chat-template-file', $tplFile)
            } else {
                Write-Host ('  [警告] 模板文件不存在：' + $tplFile) -ForegroundColor Yellow
            }
        }

        # 思考模式：Qwen3 系列支持，别的模型不认这个参数
        $rs = [string]$prof.reasoning
        if ($rs -eq 'off' -or $rs -eq 'on') { $argList += @('--reasoning', $rs) }

        # 额外参数：留给自己加，比如 -fa / --no-mmap
        $extra = [string]$prof.extraArgs
        if (-not [string]::IsNullOrWhiteSpace($extra)) {
            foreach ($a in ($extra -split '\s+' | Where-Object { $_ })) { $argList += $a }
        }


    } else {
        $argList += '--jinja'
    }

    # ---- 重复惩罚（2026-11-26）----
    # 现象：模型偶尔会一直吐数字 123456789432425...，停不下来。
    # 原因：启动参数里从来没有 repeat-penalty，llama 默认 1.0 = 不惩罚；
    #       temperature 0.3 / top_p 0.7 偏低，一旦选中数字就会顺着
    #       同一方向一直续写，靠概率自己出不来。
    # 1.1 是温和档：够打断循环，又不至于让正常复述（列文件名）变形。
    # --repeat-last-n 256 只惩罚最近 256 token，不影响更早的上下文。
    # 想关掉设 1.0；想更发散可以 1.15，再高中文重复用词会变别扭。
    # 放在 if/else 外面：不管有没有 modelProfile 都要生效。
    $argList += @('--repeat-penalty', '1.1', '--repeat-last-n', '256')

    # 用 cmd 的 start 让推理服务彻底脱离本脚本的进程树。
    # 之前用 Start-Process 直接起，脚本进程一退出，服务会被一起带走
    # （表现为：刚启动时 health 正常，几秒后进程消失、端口连不上）。
    # /b 表示不开新窗口，重定向在 cmd 层做，保证日志照常写入。
    # llama 不会自己建 slot 目录，路径不存在时启动会失败
    try { New-Item -ItemType Directory -Force -Path (Join-Path $Root 'cache\slots') | Out-Null } catch { }

    $argLine = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $outLog = Join-Path $LogDir 'server.out.log'
    $errLog = Join-Path $LogDir 'server.err.log'
    # 工作目录必须跟实际 llama 目录一致：GPU 模式的 DLL 在 llama-gpu，
    # 原来这里写死 llama，切到 GPU 后可能找不到同目录的依赖。
    $llamaWork = Join-Path $Root ($LlamaDir.Trim('\'))
    $cmdLine = '/c start "" /b /d "' + $llamaWork + '" "' + $Server + '" ' + $argLine +
               ' > "' + $outLog + '" 2> "' + $errLog + '"'
    Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WindowStyle Hidden | Out-Null

    $waited = 0
    while (-not (Test-AiUp) -and $waited -lt 60) {
        Start-Sleep -Seconds 1
        $waited++
    }

    # 再多等两秒确认它不会自己夭折（脱离进程树后应该一直活着）
    if (Test-AiUp) {
        Start-Sleep -Seconds 2
        if (-not (Test-AiUp)) {
            Write-Host '服务启动后很快退出，可能有内存或权限问题，看日志：' -ForegroundColor Red
            Write-Host ('  ' + $errLog) -ForegroundColor Red
            exit 1
        }
    }

    if (-not (Test-AiUp)) {
        Write-Host ('服务启动失败，看日志：' + $errLog) -ForegroundColor Red
        exit 1
    }
    Write-Host ('服务就绪（' + $waited + 's）') -ForegroundColor Green

    # 把 llama-server 进程压到 BelowNormal。
    # --prio 只能改 llama 自己的线程优先级（取值有限，没有 below normal 这一档），
    # 而进程基类决定了那些线程最终落在哪 —— 直接改进程优先级最省事：
    # 面板请求一来就立刻插队，模型不再挡在它前面。
    # 找不到进程就跳过（不影响启动），用户自己设了 $Cfg.prio 也不强制覆盖。
    try {
        if (-not $Cfg.prio) {
            $lp = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
                  Where-Object { $_.ExecutablePath -eq $Server } | Select-Object -First 1
            if ($lp) {
                (Get-Process -Id $lp.ProcessId).PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
                Write-Host '推理服务优先级：BelowNormal（面板优先）' -ForegroundColor DarkGray
            }
        }
    } catch { }

    # 就绪后立刻在后台把 prompt.md 的前缀灌进 KV 缓存。
    # 为什么：KV 缓存只活在进程里，重启就清空，而每个任务的第一步
    # 都要把这 2500 token 从头 prefill（36 tok/s 约 70 秒）——
    # 用户看到的就是「刚打开 Nafx，第一个任务要等两分多钟」。
    # 放到后台跑，用户打字的那段时间刚好把它跑完；就算手快，
    # 任务排在预热后面，总耗时也不比冷启动差。
    try {
        $warmScript = Join-Path $Root 'scripts\nafx-warmup.ps1'
        $warmOn = -not ($Cfg -and ($Cfg.warmupOnStart -eq $false))
        if ((Test-Path $warmScript) -and $warmOn) {
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }
            Start-Process -FilePath $psExe `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $warmScript, '-Quiet') `
                -WindowStyle Hidden | Out-Null
        }
    } catch { }
} else {
    Write-Host '服务已在运行' -ForegroundColor Green
}

if (-not $NoBrowser) {
    # 注意：开的是面板地址，不是模型端口
    $panelPort = if ($Cfg.monitorPort) { [int]$Cfg.monitorPort } else { 8090 }
    $panelUrl = 'http://' + $Listen + ':' + $panelPort
    $browsers = @(
        ($env:ProgramFiles + '\Google\Chrome\Application\chrome.exe'),
        (${env:ProgramFiles(x86)} + '\Google\Chrome\Application\chrome.exe'),
        (${env:ProgramFiles(x86)} + '\Microsoft\Edge\Application\msedge.exe'),
        ($env:ProgramFiles + '\Microsoft\Edge\Application\msedge.exe')
    )
    $browser = $browsers | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($browser) {
        Start-Process -FilePath $browser -ArgumentList ('--app=' + $panelUrl)
    } else {
        Start-Process $panelUrl
    }
}

# ------------------------------------------------------------
#  面板看门狗
#  面板偶尔会自己退出，用户看到的就是「面板突然没了」，
#  还得手动重开。这里顺手带一个：端口不通就拉起来。
#  已经在跑就不重复起（先查一下进程，免得越开越多）。
# ------------------------------------------------------------
try {
    $wdScript = Join-Path $Root 'scripts\watchdog.ps1'
    if (Test-Path $wdScript) {
        $wdRunning = $false
        try {
            foreach ($name in @('powershell.exe', 'pwsh.exe')) {
                foreach ($wp in @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue)) {
                    if ([string]$wp.CommandLine -match 'watchdog\.ps1') { $wdRunning = $true; break }
                }
                if ($wdRunning) { break }
            }
        } catch { }
        if (-not $wdRunning) {
            $wdPort = if ($Cfg.monitorPort) { [int]$Cfg.monitorPort } else { 8090 }
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
                                '-File', $wdScript, '-Port', [string]$wdPort) `
                -WindowStyle Hidden
            Write-Host '看门狗已启动（面板掉了会自动拉起）' -ForegroundColor DarkGray
        }
    }
} catch { }