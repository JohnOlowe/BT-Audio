@echo off
rem Wrapper for bt-audio-send.ps1.
rem
rem Windows ships PowerShell with ExecutionPolicy=Restricted, which refuses to
rem run ANY .ps1 file - the script is fine, the policy is just cautious. This
rem wrapper launches it with -ExecutionPolicy Bypass for this one process, so
rem nothing is changed system-wide and no admin rights are needed.
rem
rem   bt-audio-send.bat COM8                 (short form)
rem   bt-audio-send.bat -Port COM8           (same thing, explicit)
rem   bt-audio-send.bat -Port COM8 -Mode File -File song.wav
setlocal
set "ARGS=%*"
if not "%~1"=="" (
    echo %~1| findstr /b /c:"-" >nul
    if errorlevel 1 set "ARGS=-Port %*"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bt-audio-send.ps1" %ARGS%
endlocal
