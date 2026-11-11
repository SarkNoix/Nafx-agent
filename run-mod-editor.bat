@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo   ============================================
echo    Nafx Mod 编辑器
echo   ============================================
echo.

rem ---------- 已经在跑就直接开浏览器 ----------
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-NetTCPConnection -LocalPort 8070 -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >nul 2>&1
if not errorlevel 1 (
    echo   8070 已经在跑了，直接打开
    start "" "http://127.0.0.1:8070/"
    timeout /t 2 >nul
    exit /b 0
)

rem ---------- 刷新独立版数据 ----------
if exist "gen-standalone.ps1" (
    echo   更新内联数据...
    powershell -NoProfile -ExecutionPolicy Bypass -File "gen-standalone.ps1" >nul 2>&1
)

rem ---------- 找 Python（有的话优先，不需要控制台） ----------
set "PY="
where pythonw >nul 2>&1
if not errorlevel 1 set "PY=pythonw"
if not defined PY if exist "C:\Python312\pythonw.exe" set "PY=C:\Python312\pythonw.exe"
if not defined PY if exist "C:\Python311\pythonw.exe" set "PY=C:\Python311\pythonw.exe"
if not defined PY if exist "%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe"
if not defined PY if exist "%LOCALAPPDATA%\Programs\Python\Python311\pythonw.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python311\pythonw.exe"

if defined PY (
    echo   用 Python 后台启动（无窗口）
    start "" "!PY!" -u "%~dp0mod-editor-server.py"

    rem 等 8070 就绪
    echo   等待 8070 就绪...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i -lt 30;$i++){ try{ $r=Invoke-WebRequest 'http://127.0.0.1:8070/health' -UseBasicParsing -TimeoutSec 2; if($r.StatusCode -eq 200){$ok=$true;break} }catch{}; Start-Sleep -Seconds 1 }; if($ok){exit 0}else{exit 1}"

    if errorlevel 1 (
        echo.
        echo   [失败] Python 服务没起来
        echo   试试直接双击 mod-editor-standalone.html
        echo.
        pause
        exit /b 1
    )

    echo   就绪，打开浏览器
    start "" "http://127.0.0.1:8070/"
    echo.
    echo   编辑器在后台跑，这个窗口可以关掉。
    echo   要停服务：双击 stop-mod-editor.bat
    echo.
    timeout /t 4 >nul
    exit /b 0
)

rem ---------- 没有 Python，降级用 PowerShell（必须有控制台） ----------
echo   没找到 Python，用 PowerShell 启动
echo   （这个窗口不要关，关了服务就停）
echo   --------------------------------------------
echo.

start "" /min powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 3; Start-Process 'http://127.0.0.1:8070/'"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mod-editor.ps1"

echo.
echo   --------------------------------------------
echo   服务已停止
echo   如果浏览器打不开，直接双击 mod-editor-standalone.html
echo.
pause