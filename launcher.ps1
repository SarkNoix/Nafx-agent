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
$Server = Join-Path $Root 'llama\llama-server.exe'
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
    $prio = '1'
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
            $memOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $memScript -ForLauncher 2>$null
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
        '--load-mode', $loadMode,
        '--prio', $prio,
        '--timeout', '600'
    )

    # KV 缓存量化：这是省内存的关键。fp16 的 KV 很占地方，
    # 压到 8bit/4bit 后同样内存能多装 2-4 倍上下文。
    try {
        $ctk = [string]$Cfg.kvCacheTypeK
        $ctv = [string]$Cfg.kvCacheTypeV
        $fa  = [string]$Cfg.flashAttn
        if ($ctk -and $ctk -ne 'f16') { $argList += @('-ctk', $ctk) }
        if ($ctv -and $ctv -ne 'f16') { $argList += @('-ctv', $ctv) }
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

    # 用 cmd 的 start 让推理服务彻底脱离本脚本的进程树。
    # 之前用 Start-Process 直接起，脚本进程一退出，服务会被一起带走
    # （表现为：刚启动时 health 正常，几秒后进程消失、端口连不上）。
    # /b 表示不开新窗口，重定向在 cmd 层做，保证日志照常写入。
    $argLine = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $outLog = Join-Path $LogDir 'server.out.log'
    $errLog = Join-Path $LogDir 'server.err.log'
    $cmdLine = '/c start "" /b /d "' + (Join-Path $Root 'llama') + '" "' + $Server + '" ' + $argLine +
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