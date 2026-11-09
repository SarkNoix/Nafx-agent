@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   自动调参（只看推荐，不改文件）
echo   ============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "autotune.ps1"
echo.
pause
