# 停止 Nafx 的所有后台进程（模型服务 + 监视面板 + 正在跑的 agent）
$stopped = @()

# 1) 模型服务
Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object {
    $stopped += "llama-server (PID $($_.Id))"
    try { $_.Kill() } catch { }
}

# 2) 看门狗：先停它，否则面板刚停掉又会被拉起来
$psProcs = @()
foreach ($name in @('powershell.exe', 'pwsh.exe')) {
    $psProcs += Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue
}
$psProcs |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*watchdog.ps1*' } |
    ForEach-Object {
        $stopped += "watchdog (PID $($_.ProcessId))"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
    }

# 3) 面板
$psProcs |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*monitor.ps1*' } |
    ForEach-Object {
        $stopped += "monitor (PID $($_.ProcessId))"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
    }

# 4) 正在跑的 agent。面板被杀之后这些就成孤儿了，会一直占着模型槽位
$psProcs |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*agent.ps1*' } |
    ForEach-Object {
        $stopped += "agent (PID $($_.ProcessId))"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
    }

# 5) 清临时文件：ask.json 留着的话，下次打开面板会显示上一次的提问
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in @('agent\ask.json', 'agent\answer.json', 'agent\state.json', 'agent\stop.flag', 'agent\panel.pid')) {
    $p = Join-Path $root $f
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

if ($stopped.Count -eq 0) {
    Write-Host '没有在运行的 Nafx 后台进程' -ForegroundColor Yellow
} else {
    Write-Host '已停止：' -ForegroundColor Green
    $stopped | ForEach-Object { Write-Host "  - $_" }
}