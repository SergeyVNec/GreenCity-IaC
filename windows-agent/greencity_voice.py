"""GreenCity Ops — native Windows voice assistant (Siri-style, hands-free).

Always listens for a wake word (openWakeWord — fully open-source, offline, no
account/key). On wake it records your phrase, sends it to the GreenCity backend
(Whisper STT -> gpt-4o-mini + MCP tools -> ElevenLabs TTS) and speaks the answer.
No browser, full mic access.

The heavy lifting (STT/LLM/TTS + cluster access) lives in the k3s hermes-agent;
this client only does audio I/O + HTTP and needs NO API keys at all.

Setup:
    pip install -r requirements.txt
    (optional) copy .env.example .env   # to change backend URL / wake word
    python greencity_voice.py

Wake words (pretrained, auto-downloaded): hey_jarvis, alexa, hey_mycroft,
hey_rhasspy. Pick one via WAKE_MODEL (default hey_jarvis).
"""
import os
import io
import wave
import time
import struct
import tempfile

import winsound

import numpy as np
import requests
from pvrecorder import PvRecorder

def _app_dir():
    """Directory of the script, or of the .exe when frozen by PyInstaller."""
    import sys
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(_app_dir(), ".env"))
except ImportError:
    pass

import openwakeword
from openwakeword.model import Model

# Set GREENCITY_BACKEND (env or .env) to http://<observability_eip>:30890
BACKEND = os.environ.get("GREENCITY_BACKEND", "http://YOUR-OBSERVABILITY-EIP:30890").rstrip("/")
WAKE_MODEL = os.environ.get("WAKE_MODEL", "hey_jarvis")
WAKE_THRESHOLD = float(os.environ.get("WAKE_THRESHOLD", "0.5"))

SAMPLE_RATE = 16000
FRAME_LENGTH = 1280  # 80 ms @ 16 kHz — openWakeWord's expected chunk
FRAME_S = FRAME_LENGTH / SAMPLE_RATE

SILENCE_ENERGY = int(os.environ.get("SILENCE_ENERGY", "350"))
MAX_UTTERANCE_S = float(os.environ.get("MAX_UTTERANCE_S", "6.0"))
SILENCE_STOP_S = float(os.environ.get("SILENCE_STOP_S", "0.7"))  # end-of-speech pause
MIN_UTTERANCE_S = 0.5
SHOW_TIMING = os.environ.get("SHOW_TIMING", "1") == "1"


def make_model() -> Model:
    try:
        return Model(wakeword_models=[WAKE_MODEL], inference_framework="onnx")
    except Exception:
        print("Скачиваю модели wake word (один раз)...")
        openwakeword.utils.download_models()
        return Model(wakeword_models=[WAKE_MODEL], inference_framework="onnx")


def frame_energy(pcm) -> float:
    return sum(abs(s) for s in pcm) / max(len(pcm), 1)


def record_utterance(recorder):
    """Record from the running recorder until ~1s of silence or the max length."""
    frames, silent, spoken = [], 0.0, 0.0
    start = time.time()
    while time.time() - start < MAX_UTTERANCE_S:
        pcm = recorder.read()
        frames.extend(pcm)
        if frame_energy(pcm) < SILENCE_ENERGY:
            silent += FRAME_S
        else:
            silent = 0.0
            spoken += FRAME_S
        if spoken > MIN_UTTERANCE_S and silent > SILENCE_STOP_S:
            break
    return frames


def to_wav_bytes(frames) -> io.BytesIO:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(struct.pack("<%dh" % len(frames), *frames))
    buf.seek(0)
    return buf


def stt(wav_buf) -> str:
    r = requests.post(BACKEND + "/stt",
                      files={"audio": ("command.wav", wav_buf, "audio/wav")}, timeout=60)
    return r.json().get("text", "").strip()


def chat(text: str) -> str:
    r = requests.post(BACKEND + "/chat", json={"message": text}, timeout=120)
    j = r.json()
    used = ", ".join(t["tool"] for t in j.get("tools_used", []))
    if used:
        print(f"   [инструменты: {used}]")
    return j.get("reply", "")


def synth(text: str):
    """Fetch WAV from the backend (this is the real TTS latency). Returns a path."""
    r = requests.post(BACKEND + "/tts?fmt=wav", json={"text": text}, timeout=60)
    if r.status_code != 200 or "audio" not in r.headers.get("content-type", ""):
        return None
    f = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
    f.write(r.content)
    f.close()
    return f.name


def play(path):
    """Blocking playback (this is the bot speaking, not latency)."""
    if not path:
        return
    try:
        winsound.PlaySound(path, winsound.SND_FILENAME)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def run(stop_event=None, status=None):
    """Listen loop. `stop_event` (threading.Event) ends it; `status(str)` receives
    state updates (used by the tray app to update its tooltip)."""
    def setstatus(s, echo=True):
        if status:
            status(s)
        if echo:
            print(s)

    model = make_model()
    recorder = PvRecorder(frame_length=FRAME_LENGTH)
    recorder.start()
    setstatus(f"жду «{WAKE_MODEL}»")
    try:
        while stop_event is None or not stop_event.is_set():
            pcm = recorder.read()
            scores = model.predict(np.array(pcm, dtype=np.int16))
            if scores.get(WAKE_MODEL, 0.0) >= WAKE_THRESHOLD:
                setstatus("🔔 слушаю команду...")
                frames = record_utterance(recorder)
                model.reset()  # clear wake-word buffer so it re-arms cleanly
                t0 = time.time()
                text = stt(to_wav_bytes(frames))
                t1 = time.time()
                if not text:
                    setstatus("   (не расслышал)")
                    setstatus(f"жду «{WAKE_MODEL}»")
                    continue
                print(f"🧑 {text}")
                setstatus("думаю...", echo=False)
                reply = chat(text)
                t2 = time.time()
                print(f"🤖 {reply}")
                setstatus("отвечаю...", echo=False)
                wav = synth(reply)
                t3 = time.time()
                if SHOW_TIMING:
                    print(f"   ⏱ stt {t1-t0:.1f}s · chat {t2-t1:.1f}s · tts {t3-t2:.1f}s (+озвучка)")
                play(wav)
                setstatus(f"жду «{WAKE_MODEL}»")
    finally:
        recorder.delete()


def main():
    print(f"🌿 GreenCity Ops слушает. Скажи «{WAKE_MODEL}», затем команду. Ctrl+C — выход.")
    try:
        run()
    except KeyboardInterrupt:
        print("\nпока!")


if __name__ == "__main__":
    main()
