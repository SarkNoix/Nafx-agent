@echo off
chcp 65001 >nul
echo.
echo   停止 Mod 编辑器...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter ""Name='python.exe'"" | Where-Object { $_.CommandLine -like '*mod-editor-server*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('  已停止 Python 服务 PID ' + $_.ProcessId) }; Get-CimInstance Win32_Process -Filter ""Name='pythonw.exe'"" | Where-Object { $_.CommandLine -like '*mod-editor-server*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('  已停止 Python 服务 PID ' + $_.ProcessId) }; Get-CimInstance Win32_Process -Filter ""Name='powershell.exe'"" | Where-Object { $_.CommandLine -like '*mod-editor.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('  已停止 PowerShell 服务 PID ' + $_.ProcessId) }"
echo.
timeout /t 2 >nul