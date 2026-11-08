@echo off
chcp 65001 >nul
setlocal
set "ROOT=%~dp0"

echo.
echo   Nafx
echo   ----------------------------------------
echo.

rem ---------- 1) 模型服务 ----------
tasklist /fi "imagename eq llama-server.exe" 2>nul | find /i "llama-server.exe" >nul
if errorlevel 1 (
    echo   [1/3] 启动模型服务...
    start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%launcher.ps1" -NoBrowser
) else (
    echo   [1/3] 模型服务已在运行
)

rem ---------- 2) 等模型就绪 ----------
echo   [2/3] 等模型加载，最多 90 秒...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$ok=$false; for($i=0;$i -lt 90;$i++){ try{ $r=Invoke-WebRequest 'http://127.0.0.1:8080/health' -UseBasicParsing -TimeoutSec 2; if($r.Content -match 'ok'){$ok=$true;break} }catch{}; Start-Sleep -Seconds 1 }; if($ok){exit 0}else{exit 1}"
if errorlevel 1 (
    echo   [!] 模型没起来。面板还能开，但跑不了任务。
    echo       可以单独跑 自检.bat 看哪里不对。
)

rem ---------- 3) 面板 ----------
echo   [3/3] 启动面板...
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%monitor.ps1"
timeout /t 3 >nul
start "" "http://127.0.0.1:8090"

echo.
echo   好了。
echo.
echo   面板    http://127.0.0.1:8090
echo   停止    双击 停止服务.bat
echo   自检    双击 自检.bat
echo.
echo   关掉这个黑窗口不影响使用。
echo.
timeout /t 4 >nul
exit /b 0
