@echo off
REM Launch the tray app silently in the background via pythonw (no console).
cd /d "%~dp0"
set PYW=%~dp0.venv\Scripts\pythonw.exe
if not exist "%PYW%" set PYW=%~dp0env\Scripts\pythonw.exe
start "" "%PYW%" greencity_tray.py
