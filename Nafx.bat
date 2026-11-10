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
rem 先看是不是已经开着了，别重复启动
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 (
    echo   [3/3] 启动面板...
    start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%monitor.ps1"
) else (
    echo   [3/3] 面板已在运行
)

rem 关键：轮询等面板真能打开再开浏览器。
rem 以前这里写死 timeout /t 3，但面板要十几秒才监听，
rem 结果浏览器打开是"无法访问"，用户以为坏了。
echo   等面板就绪，最多 40 秒...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$ok=$false; for($i=0;$i -lt 40;$i++){ try{ $r=Invoke-WebRequest 'http://127.0.0.1:8090/' -UseBasicParsing -TimeoutSec 2; if($r.StatusCode -eq 200){$ok=$true;break} }catch{}; Start-Sleep -Seconds 1 }; if($ok){exit 0}else{exit 1}"
if errorlevel 1 (
    echo.
    echo   [!] 面板没起来。
    echo       可能是 8090 端口被占，或者 PowerShell 被安全软件拦了。
    echo       单独跑 自检.bat 看具体原因。
    echo.
    pause
    exit /b 1
)

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