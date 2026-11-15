@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   压力测试 —— 看这台机器跑 Nafx 的极限
echo   ============================================
echo   会依次测：长上下文 / 长生成 / 连续请求 / 大文件 / 慢命令 / 并发
echo   全程可能十几分钟，期间模型会被占满。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stress-test.ps1" %*
echo.
pause