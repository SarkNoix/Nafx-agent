@echo off
chcp 65001 >nul
setlocal
set "ROOT=%~dp0"

rem 命令行对话模式：一行一个任务，直接回车退出

echo.
echo   Nafx 命令行模式
echo   ----------------------------------------
echo   输入任务，回车执行。直接回车退出。
echo.

:loop
echo.
set "TASK="
set /p "TASK=  任务> "
if not defined TASK goto end
if /i "%TASK%"=="exit" goto end
if /i "%TASK%"=="quit" goto end

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%agent\agent.ps1" -Task "%TASK%"
goto loop

:end
echo.
echo   再见。
echo.
timeout /t 2 >nul
exit /b 0
