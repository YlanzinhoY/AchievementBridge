@echo off
setlocal
where py >nul 2>nul
if %errorlevel% equ 0 (
  py -3 "%~dp0achievement_bridge_cli.py" %*
) else (
  python "%~dp0achievement_bridge_cli.py" %*
)
exit /b %errorlevel%
