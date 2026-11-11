@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo.
echo   ================================================
echo    Nafx Mod 编辑器
echo   ================================================
echo.
echo    关掉这个窗口 = 停止编辑器
echo.

rem 3 秒后自动开浏览器（等服务器起来）
start "" /min cmd /c "timeout /t 3 >nul & start """" http://127.0.0.1:8070/"

rem 前台跑服务（必须有 console，不能用 -WindowStyle Hidden）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mod-editor.ps1"

echo.
echo   编辑器已停止
pause