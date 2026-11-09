@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   自动调参 - 写入 config.json
echo   ============================================
echo   会先备份成 config.json.bak，然后按本机硬件改参数
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "autotune.ps1" -Apply
echo.
echo   记得重启服务：先「停止服务.bat」，再「Nafx.bat」
pause
