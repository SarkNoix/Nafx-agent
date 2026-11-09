@echo off
chcp 65001 >nul
cd /d "%~dp0"
set NAFX_CONFIG=config.self.json
echo.
echo   Nafx - 我的配置
echo   ----------------------------
echo   用 config.self.json 启动（个人参数）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "launcher.ps1" -ConfigFile "config.self.json"
if errorlevel 1 (
    echo.
    echo   启动失败，看看上面写的什么
    pause
    exit /b 1
)
echo.
echo   模型服务起来了，面板地址：http://127.0.0.1:8090
echo   关这个窗口不会停服务；停服务用「停止服务.bat」
echo.
timeout /t 5 >nul
