# ============================================================
#  Nafx 预热（warmup）
#
#  为什么需要：
#    llama-server 的 KV 缓存只活在进程里，重启就清空。
#    而每个任务的第一步都要把 3900 多个 token 从头 prefill 一遍，
#    实测 36 tok/s 要 107 秒 —— 用户看到的就是「刚打开 Nafx，
#    第一个任务要等两分多钟」。
#
#  怎么预热才对：
#    Qwen3 的对话模板里，system 正文排在 tools 定义之前：
#        <system> prompt.md 正文 ... 附加段 # Tools </system>
#    所以只要先把 prompt.md 正文灌进 KV，真实任务的提示词从第一个
#    token 到第 2500 个都是同一串，缓存直接命中，只需要算剩下的
#    工具定义 + 任务文字。实测 cache_n=2505。
#
#  代价：
#    预热本身要跑约 70 秒（2500 token）。所以由 launcher 在服务就绪后
#    丢到后台跑，不和界面抢；用户打字那段时间刚好跑完。
#    就算用户手快，任务请求排在预热后面，总耗时也不比冷启动差。
#
#  ⚠ 两个踩过的坑（Windows PowerShell 5.1，别再踩）：
#    1) 本文件必须存成 UTF-8 带 BOM。5.1 读无 BOM 的 .ps1 会按 ANSI
#       解码，中文全变乱码，引号错位直接语法报错。
#    2) 读 prompt.md 要用 [IO.File]::ReadAllText，不能用 Get-Content -Raw：
#       5.1 下后者返回的字符串会被 ConvertTo-Json 序列化成
#       {"value":...,"Count":...} 这种对象，content 不再是字符串，
#       llama-server 直接 400 Bad Request。
#
#  用法：
#    nafx-warmup.ps1            预热一次
#    nafx-warmup.ps1 -Quiet     不打印（launcher 后台调用用这个）
# ============================================================

param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$NafxRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { 'E:\Nafx' }
if (-not (Test-Path (Join-Path $NafxRoot 'config.json'))) { $NafxRoot = 'E:\Nafx' }

function Say {
    param([string]$Text)
    if (-not $Quiet) { Write-Output $Text }
}

$promptPath = Join-Path $NafxRoot 'agent\prompt.md'
if (-not (Test-Path $promptPath)) { Say '找不到 agent\prompt.md，跳过预热'; exit 0 }
$system = [IO.File]::ReadAllText($promptPath, [Text.Encoding]::UTF8)

$port = 8080
try {
    $cfg = Get-Content (Join-Path $NafxRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.port) { $port = [int]$cfg.port }
} catch { }

# 服务没起来就别硬等，静默退出 —— 这是给 launcher 兜底用的
try { $h = Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 3 } catch { Say '模型服务没起来，跳过预热'; exit 0 }
if ($h.status -ne 'ok') { Say '模型服务没就绪，跳过预热'; exit 0 }

$body = @{
    model       = 'nafx-warmup'
    messages    = @(
        @{ role = 'system'; content = $system },
        @{ role = 'user';   content = '热身' }
    )
    max_tokens  = 1
    temperature = 0
    stream      = $false
} | ConvertTo-Json -Depth 6 -Compress

# 明确按 UTF-8 发字节，交给 5.1 自己按 charset 编码容易出岔子
$bytes = [Text.Encoding]::UTF8.GetBytes($body)

$t0 = Get-Date
try {
    $r = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 600
} catch {
    Say ('预热失败：' + $_.Exception.Message)
    exit 0
}
$sec = ((Get-Date) - $t0).TotalSeconds

$logDir = Join-Path $NafxRoot 'logs'
if (Test-Path $logDir) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  预热 prompt_n=' + $r.timings.prompt_n +
            ' cache_n=' + $r.timings.cache_n + '  用时 ' + [math]::Round($sec, 1) + ' 秒'
    [IO.File]::AppendAllText((Join-Path $logDir 'warmup.log'), $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

Say ('预热完成：已写入 ' + $r.timings.prompt_n + ' token，' + [math]::Round($sec, 1) + ' 秒')
