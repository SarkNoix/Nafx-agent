@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   Nafx Mod 编辑器
echo   http://127.0.0.1:8070/
echo.
echo   改完点「下载 mod 文件」，把下载到的 .mod.json 放进 mod\ 目录
echo   关掉这个窗口就是停止编辑
echo.
start "" "http://127.0.0.1:8070"
powershell -NoProfile -ExecutionPolicy Bypass -File "mod-editor.ps1"
pause