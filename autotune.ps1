# ============================================================
#  Nafx 自动调参
#  检测本机硬件，算出这套机器最合适的参数。
#  只给建议，不改文件；加 -Apply 才写进配置。
#
#  用法：
#    .\autotune.ps1              只看推荐
#    .\autotune.ps1 -Apply       写进 config.json
#    .\autotune.ps1 -Apply -Target config.self.json
# ============================================================

param(
    [switch]$Apply,
    [string]$Target = 'config.json'
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Head($t) {
    Write-Host ''
    Write-Host ('  ' + $t) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
}

# ---------------- 1. 检测硬件 ----------------
Write-Head '检测硬件'

$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)

$cores = [int]$cpu.NumberOfCores
$logical = [int]$cpu.NumberOfLogicalProcessors
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$cpuName = [string]$cpu.Name

Write-Host ('  CPU     ' + $cpuName)
Write-Host ('          ' + $cores + ' 物理核 / ' + $logical + ' 逻辑核')
Write-Host ('  内存    ' + $totalGB + ' GB（当前可用 ' + $freeGB + ' GB）')

# 判断 CPU 代际（影响 llama.cpp 用哪个 AVX 内核）
$gen = 0
if ($cpuName -match 'i[3579]-(\d{2})\d{3}') { $gen = [int]$matches[1] }
Write-Host ('          架构代际：约 ' + $(if ($gen -ge 12) { '12+ 代（AVX2，可能支持 AVX512）' } elseif ($gen -ge 10) { '10-11 代（AVX2）' } elseif ($gen -gt 0) { ($gen + 2000) + ' 系' } else { '未知' }))

# GPU
$realGpu = @($gpus | Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote Display' })
$hasNvidia = $false
$gpuName = '（无）'
$vramGB = 0
foreach ($g in $realGpu) {
    if ($g.Name -match 'NVIDIA|GeForce|RTX|GTX') { $hasNvidia = $true }
    if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) { $vramGB = [math]::Round($g.AdapterRAM / 1GB, 1) }
    $gpuName = $g.Name
}
Write-Host ('  显卡    ' + $gpuName + $(if ($vramGB -gt 0) { '（' + $vramGB + ' GB）' } else { '' }))

# llama.cpp 是不是 CUDA 版
$llamaDir = Join-Path $Root 'llama'
$hasCuda = $false
if (Test-Path $llamaDir) {
    $cudaDlls = @(Get-ChildItem $llamaDir -Filter '*cuda*' -ErrorAction SilentlyContinue)
    $hasCuda = ($cudaDlls.Count -gt 0)
}
Write-Host ('  推理版  ' + $(if ($hasCuda) { 'CUDA 版（能用显卡）' } else { 'CPU 版（显卡用不上）' }))

# ---------------- 2. 读当前配置 ----------------
$cfgPath = $Target
if (-not [IO.Path]::IsPathRooted($cfgPath)) { $cfgPath = Join-Path $Root $cfgPath }
if (-not (Test-Path $cfgPath)) {
    Write-Host ''
    Write-Host ('  找不到配置：' + $cfgPath) -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

# 模型文件大小
$modelRel = [string]$cfg.model
$modelPath = if ([IO.Path]::IsPathRooted($modelRel)) { $modelRel } else { Join-Path $Root $modelRel }
$modelGB = 2.4
if (Test-Path $modelPath) {
    $modelGB = [math]::Round((Get-Item $modelPath).Length / 1GB, 2)
}
Write-Head ('模型：' + (Split-Path $modelRel -Leaf) + '（' + $modelGB + ' GB）')

# ---------------- 3. 算推荐值 ----------------

# 系统要留的。这个值是用实测校准出来的：
# 8 GB 机器跑 4B + 6144 context 时，Windows + 浏览器 + agent 实测占约 2.5 GB
$sysReserve = 2.5
# 安全余量。留太少会在峰值时被换页拖死，留太多又白白浪费。
# 512 MB 是实测下来既不浪费也不崩的值。
$safety = 0.5
# 每 token 的 KV cache 内存：4B Q4 实测约 0.4 MB，按模型大小线性缩放
$perTokMB = 0.4 * ($modelGB / 2.38)

$kvGB = $totalGB - $sysReserve - $modelGB - $safety
if ($kvGB -lt 0.5) { $kvGB = 0.5 }   # 内存实在太紧，给个下限
$rawCtx = [int](($kvGB * 1024) / $perTokMB)

# 取整到 1024 的倍数，夹在 2048 - 32768
$context = [int]([math]::Floor($rawCtx / 1024) * 1024)
if ($context -lt 2048) { $context = 2048 }
# 上限 16384：再大 prefill 会慢到没意义（每多 1k token 就多 24 秒）
if ($context -gt 16384) { $context = 16384 }

# 线程：物理核数，上限 16
$threads = $cores
if ($threads -gt 16) { $threads = 16 }
if ($threads -lt 1) { $threads = 1 }

# 单步生成上限：CPU 慢就给小点，别让它生成到天荒地老
$maxTokens = 500
if ($cores -ge 8) { $maxTokens = 800 }
elseif ($cores -ge 4) { $maxTokens = 600 }

# 步数：内存越紧，越要少给（少给点，早点收尾）
$maxSteps = 30
if ($totalGB -ge 16) { $maxSteps = 40 }
elseif ($totalGB -le 8 -and $modelGB -gt 2) { $maxSteps = 25 }

# 单步超时：核少的机器生成慢，时间要给够
$stepTimeout = 180
if ($cores -le 4) { $stepTimeout = 240 }
if ($cores -ge 12) { $stepTimeout = 150 }

# 加载模式：有 CUDA 版 + 有 N 卡才考虑 mlock，否则 mmap 最稳
$loadMode = 'mmap'
if ($hasCuda -and $hasNvidia) { $loadMode = 'mlock' }

# GPU 层数：CUDA 版且显存够才 offload
$ngl = 0
if ($hasCuda -and $hasNvidia -and $vramGB -ge 4) { $ngl = 99 }

# ---------------- 4. 对比展示 ----------------
Write-Head '推荐值 vs 当前值'

$rows = @(
    @{ Name = 'context';            Cur = [string]$cfg.context;           Rec = [string]$context;       Why = '按内存和模型大小算，留 1 GB 余量' },
    @{ Name = 'threads';            Cur = [string]$cfg.threads;           Rec = [string]$threads;       Why = '物理核数，0 表示自动（也是这个值）' },
    @{ Name = 'maxTokens';          Cur = [string]$cfg.maxTokens;         Rec = [string]$maxTokens;     Why = '核多给多点，但太大反而慢' },
    @{ Name = 'maxSteps';           Cur = [string]$cfg.maxSteps;          Rec = [string]$maxSteps;      Why = '内存紧就少给，避免半路被换页拖死' },
    @{ Name = 'stepTimeoutSeconds'; Cur = [string]$cfg.stepTimeoutSeconds; Rec = [string]$stepTimeout;  Why = '核少的机器生成慢，超时给够' },
    @{ Name = 'loadMode';           Cur = [string]$cfg.loadMode;          Rec = $loadMode;              Why = '没有可用的 CUDA 就用 mmap 省内存' }
)
foreach ($r in $rows) {
    $mark = if ($r.Cur -eq $r.Rec) { ' ' } else { '→' }
    $color = if ($r.Cur -eq $r.Rec) { 'DarkGray' } else { 'Yellow' }
    Write-Host ('  ' + $r.Name.PadRight(20) + $r.Cur.PadLeft(7) + ' ' + $mark + ' ' + $r.Rec.PadLeft(7) + '   ' + $r.Why) -ForegroundColor $color
}

if ($ngl -gt 0) {
    Write-Host ''
    Write-Host ('  检测到 CUDA 版 llama.cpp + ' + $gpuName + '，可以把 ' + $ngl + ' 层放显卡上') -ForegroundColor Green
}

# 内存压力提醒
Write-Host ''
if ($freeGB -lt 1.5) {
    Write-Host ('  ⚠ 当前可用内存只有 ' + $freeGB + ' GB，跑任务可能被换页拖慢') -ForegroundColor Yellow
    Write-Host ('    关掉浏览器能腾出 300-500 MB') -ForegroundColor DarkGray
}
if ($context -lt 3072) {
    Write-Host ('  ⚠ 推荐值偏低（' + $context + '），说明内存对当前模型来说有点紧') -ForegroundColor Yellow
    Write-Host ('    可以考虑换更小的模型，或者加内存条') -ForegroundColor DarkGray
}

# ---------------- 5. 写回 ----------------
if ($Apply) {
    Write-Head '写入配置'
    $backup = $cfgPath + '.bak'
    Copy-Item $cfgPath $backup -Force
    Write-Host ('  已备份原配置 → ' + (Split-Path $backup -Leaf)) -ForegroundColor DarkGray

    $raw = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
    $pairs = @(
        @('context', $context),
        @('threads', $threads),
        @('maxTokens', $maxTokens),
        @('maxSteps', $maxSteps),
        @('stepTimeoutSeconds', $stepTimeout),
        @('loadMode', $loadMode)
    )
    foreach ($p in $pairs) {
        $k = $p[0]; $v = [string]$p[1]
        # 用正则找出这个键的"值"部分，保留原来的引号风格。
        # 坑：loadMode 这类值是带引号的字符串，直接替换成 mmap 会毁掉 JSON。
        $pattern = '("' + [regex]::Escape($k) + '"\s*:\s*)("?)([^",\r\n}]+)(\2)'
        $m = [regex]::Match($raw, $pattern)
        if ($m.Success) {
            $quote = $m.Groups[2].Value          # 原来是 " 就还是 "
            $newVal = $quote + $v + $quote
            $start = $m.Groups[3].Index
            $len = $m.Groups[3].Length
            $raw = $raw.Substring(0, $start) + $v + $raw.Substring($start + $len)
        }
    }
    [IO.File]::WriteAllText($cfgPath, $raw, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('  ✓ 已写入 ' + (Split-Path $cfgPath -Leaf)) -ForegroundColor Green
    Write-Host ''
    Write-Host '  改完要重启服务才生效：' -ForegroundColor Yellow
    Write-Host '    双击「停止服务.bat」，再双击「Nafx.bat」' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host '  想直接写进配置，加 -Apply 再跑一次：' -ForegroundColor DarkGray
    Write-Host '    .\autotune.ps1 -Apply' -ForegroundColor DarkGray
    Write-Host '    或 .\autotune.ps1 -Apply -Target config.self.json' -ForegroundColor DarkGray
}
Write-Host ''
