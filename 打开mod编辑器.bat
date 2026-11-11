@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   打开 Mod 编辑器（独立版，不需要服务）
echo.
echo   改完点「下载 mod 文件」，把下载到的 .mod.json 放进 mod\ 目录
echo.
start "" "mod-editor-standalone.html"
timeout /t 2 >nul