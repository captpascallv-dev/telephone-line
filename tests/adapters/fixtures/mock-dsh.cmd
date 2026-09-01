@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "TELEPHONE_LINE_MOCK_DSH_EXECUTABLE=1"
pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0mock-dsh-relay.ps1" %*
exit /b %ERRORLEVEL%
