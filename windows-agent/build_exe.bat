@echo off
REM Build a single-file tray .exe with PyInstaller. Run once; output in dist\.
cd /d "%~dp0"

if not exist ".venv" (
    echo No .venv found. Run run.bat once first to create it.
    pause
    exit /b 1
)
call .venv\Scripts\activate.bat
pip install pyinstaller

REM --windowed = no console window (tray only). --collect-all pulls in the
REM onnxruntime binaries + openwakeword's bundled model files.
pyinstaller --noconfirm --onefile --windowed --name GreenCityVoice ^
  --collect-all openwakeword ^
  --collect-all onnxruntime ^
  --collect-submodules pvrecorder ^
  greencity_tray.py

echo.
echo Done -> dist\GreenCityVoice.exe
echo (first launch downloads the wake-word model, needs internet once)
pause
