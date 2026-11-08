# 停止 Nafx 的所有后台进程（模型服务 + 监视面板）
$stopped = @()

Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object {
    $stopped += "llama-server (PID $($_.Id))"
    $_.Kill()
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*monitor.ps1*' } |
    ForEach-Object {
        $stopped += "monitor (PID $($_.ProcessId))"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
    }

if ($stopped.Count -eq 0) {
    Write-Host '没有在运行的 Nafx 后台进程' -ForegroundColor Yellow
} else {
    Write-Host '已停止：' -ForegroundColor Green
    $stopped | ForEach-Object { Write-Host "  - $_" }
}
