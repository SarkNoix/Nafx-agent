# ============================================================
#  推理档位 A/B：同一批题，0~4 档各跑一遍，看分数/步数/耗时差在哪
#
#  为什么不是「随便挑一道题」：
#    太简单的题（创建 a.txt）各档都是 100，看不出差别；
#    全是复杂题又会被 llama 首字等待淹没，一张表全是 300 秒。
#    所以挑四类各一道，覆盖「简单执行 / 表达克制 / 写脚本+自测 / 联网短答」。
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File ab-reason.ps1
#    powershell -ExecutionPolicy Bypass -File ab-reason.ps1 -Levels 0,2,3
# ============================================================
param(
    # 默认只测 0/2/3：MAX（4）在这台纯 CPU 机器上三次实测 19.8 / 33 / 33，
    # 全是强制收尾或跑满步数，耗时还更长（首字 150+ 秒）。换成「强」再验一次。
    [int[]]$Levels = @(0, 2, 3),
    [string]$Tasks = 'probe-logtool'
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$TrainDir = 'E:\Nafx\train'
$OutDir = Join-Path $TrainDir 'out'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# 干净 PSModulePath：从 pwsh 7 继承过来会让 5.1 里的 Security 模块加载失败
$env:PSModulePath = 'C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules'

$summary = @()
foreach ($lv in $Levels) {
    $log = Join-Path $OutDir ("ab-reason-lv{0}-{1}.log" -f $lv, (Get-Date -Format 'HHmmss'))
    $before = @(Get-ChildItem $OutDir -Filter 'report_*.txt' | Select-Object -ExpandProperty FullName)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $TrainDir 'train.ps1') `
        -NoTune -Rounds 1 -TaskId $Tasks -Reasoning $lv *> $log
    $new = @(Get-ChildItem $OutDir -Filter 'report_*.txt' | Sort-Object LastWriteTime -Descending |
             Where-Object { $before -notcontains $_.FullName } | Select-Object -First 1)
    if ($new.Count -gt 0) {
        Copy-Item $new[0].FullName (Join-Path $OutDir ("ab-reason-lv{0}.report.txt" -f $lv)) -Force
        foreach ($line in (Get-Content $new[0].FullName -Encoding UTF8)) {
            if ($line -match '第 1 轮：(\d+(\.\d+)?) 分') { $summary += "档位 $lv 总分 $($Matches[1])" }
        }
    } else {
        $summary += "档位 $lv 没找到报告（看 $log）"
    }
    $summary += "档位 $lv 日志：$log"
}

$summary | Set-Content (Join-Path $OutDir 'ab-reason-summary.txt') -Encoding UTF8
Write-Output ($summary -join "`n")
