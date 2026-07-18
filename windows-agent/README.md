# GreenCity Ops — Windows Voice Assistant

Hands-free, Siri-style voice control of the GreenCity k3s cluster. Always listens
for a wake word (offline, open-source), then sends your spoken command to the
cluster backend and answers by voice. No browser, native microphone access.

```
🎤 "hey jarvis, сколько подов в неймспейсе гринсити"
      → Whisper (STT) → gpt-4o-mini + MCP tools → ElevenLabs (TTS) → 🔊 ответ
```

Wake-word detection uses **openWakeWord** — fully open-source, offline, **no
account and no API keys**. All STT/LLM/TTS + cluster access run in the k3s
`hermes-agent`, so this client needs no keys at all.

## Setup (with a venv, recommended)

```powershell
cd F:\DevOps\GreenCityAWS\windows-agent
python -m venv .venv
.\.venv\Scripts\Activate.ps1        # (cmd: .venv\Scripts\activate.bat)
pip install -r requirements.txt      # installs only inside .venv
python greencity_voice.py
```

First run auto-downloads the small wake-word models (~a few MB). Then say
**"hey jarvis"**, wait for `🔔 слушаю команду...`, and speak your command in
Russian:
- *"сколько подов в неймспейсе гринсити"*
- *"какой Quality Gate у backcore"*
- *"отмасштабируй backuser до двух реплик"*
- *"запусти сборку"*

Or just double-click **`run.bat`** — it creates the venv, installs deps, and runs.

## Wake word

Pretrained models (set via `WAKE_MODEL`): `hey_jarvis` (default), `alexa`,
`hey_mycroft`, `hey_rhasspy`. A custom "ГринСити" word can be trained with the
openWakeWord training notebook and dropped in as a `.onnx` model.

## Config (optional, via .env or env vars)

| Variable | Default | Meaning |
|---|---|---|
| `GREENCITY_BACKEND` | `http://<observability_eip>:30890` | hermes-agent URL (`terraform output observability_eip`) |
| `WAKE_MODEL` | `hey_jarvis` | wake word |
| `WAKE_THRESHOLD` | `0.5` | detection sensitivity (lower = easier trigger) |
| `SILENCE_ENERGY` | `350` | end-of-speech silence threshold |

Copy `.env.example` → `.env` to set these in a file (auto-loaded).

## Tray app + autostart (recommended: no PyInstaller)

Run it as a silent background tray app using `pythonw.exe` — no console, no build,
reliable on any Python version:

- **Test it:** double-click **`start_tray.bat`** (or run
  `.\.venv\Scripts\pythonw.exe greencity_tray.py`). A green dot appears in the
  system tray (amber while handling a command). Right-click → **Выход**.
- **Autostart with Windows:** double-click **`register_autostart.bat`** → `1` to add
  (a shortcut to `pythonw greencity_tray.py` in the Startup folder), `2` to remove.

After that the assistant launches with Windows, sits in the tray, and always
listens for the wake word — no console, no browser.

### Building a standalone .exe (optional)

`build_exe.bat` / `build_exe_debug.bat` use PyInstaller. This is fiddly with
onnxruntime and **currently broken on Python 3.14** (produces an exe Windows
refuses to run). If you want a single .exe, build inside a **Python 3.12** venv.
The `pythonw` + autostart route above needs none of this and is the recommended
way to run it in the background.

Files: `greencity_voice.py` (core), `greencity_tray.py` (tray),
`start_tray.bat`, `register_autostart.bat`, `run.bat`, `.env.example`.
