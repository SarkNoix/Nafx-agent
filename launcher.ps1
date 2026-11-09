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

    # 线程数：0 或超过物理核心时，自动用实际核心数（换 CPU 后不用改配置）
    $cores = [Environment]::ProcessorCount
    $threads = 0
    if ($Cfg.threads) { $threads = [int]$Cfg.threads }
    if ($threads -le 0 -or $threads -gt $cores) { $threads = $cores }
    if ($threads -gt 16) { $threads = 16 }

    # 模型相关参数从配置读，这样换任何模型都能调，不用改脚本
    $prof = $null
    try { $prof = $Cfg.modelProfile } catch { }

    $argList = @(
        '-m', $ModelPath,
        '--host', $Listen,
        '--port', [string]$Port,
        '-c', [string]$Cfg.context,
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
