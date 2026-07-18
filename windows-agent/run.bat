@echo off
REM Double-click launcher. No API keys needed (openWakeWord is offline).
cd /d "%~dp0"

REM Prefer Python 3.12 (all deps have wheels); fall back to 3.11, then default.
set PY=
py -3.12 --version >nul 2>&1 && set PY=py -3.12
if "%PY%"=="" ( py -3.11 --version >nul 2>&1 && set PY=py -3.11 )
if "%PY%"=="" set PY=python
echo Using: %PY%

if not exist ".venv" (
    echo Creating virtual environment...
    %PY% -m venv .venv
    call .venv\Scripts\activate.bat
    python -m pip install --upgrade pip
    pip install -r requirements.txt
) else (
    call .venv\Scripts\activate.bat
)

REM set GREENCITY_BACKEND=http://<observability_eip>:30890   (or put it in .env)
set WAKE_MODEL=hey_jarvis

python greencity_voice.py
pause
