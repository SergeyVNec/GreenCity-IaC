@echo off
REM Add / remove the tray app from Windows startup (per-user, no admin, no exe).
REM Launches via pythonw.exe so there is no console window.
cd /d "%~dp0"

set PYW=%~dp0.venv\Scripts\pythonw.exe
if not exist "%PYW%" set PYW=%~dp0env\Scripts\pythonw.exe
if not exist "%PYW%" (
    echo pythonw.exe not found in .venv or env. Create the venv first ^(run.bat^).
    pause
    exit /b 1
)

echo 1 = add to startup   2 = remove from startup
set /p CH=Choose:
if "%CH%"=="1" (
    powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup')+'\GreenCityVoice.lnk'); $s.TargetPath='%PYW%'; $s.Arguments='greencity_tray.py'; $s.WorkingDirectory='%~dp0'; $s.Save()"
    echo Added to startup.
) else if "%CH%"=="2" (
    powershell -NoProfile -Command "Remove-Item ([Environment]::GetFolderPath('Startup')+'\GreenCityVoice.lnk') -ErrorAction SilentlyContinue"
    echo Removed from startup.
)
pause
