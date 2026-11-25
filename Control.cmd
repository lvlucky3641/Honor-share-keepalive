@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HonorShareKeepAlive.ps1" Menu
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%
