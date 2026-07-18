"""GreenCity Ops — system-tray voice assistant.

Runs the wake-word listen loop in a background thread and shows a tray icon
(green = idle/listening, amber = handling a command). Right-click -> Выход.
Build to a single .exe with build_exe.bat, autostart with register_autostart.bat.
"""
import threading

import pystray
from PIL import Image, ImageDraw

import greencity_voice as gv

_stop = threading.Event()
_icon = None


def _dot(color):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((10, 10, 54, 54), fill=color)
    return img


IDLE = _dot((34, 197, 94))    # green
BUSY = _dot((251, 191, 36))   # amber


def _on_status(s: str):
    if _icon is None:
        return
    _icon.title = f"GreenCity Ops — {s}"
    _icon.icon = BUSY if ("слушаю" in s or "думаю" in s or "отвеч" in s) else IDLE


def _worker():
    try:
        gv.run(stop_event=_stop, status=_on_status)
    except Exception as e:  # keep the tray alive; show the error in the tooltip
        _on_status(f"ошибка: {e}")


def _on_quit(icon, item):
    _stop.set()
    icon.stop()


def main():
    global _icon
    _icon = pystray.Icon(
        "greencity", IDLE, "GreenCity Ops",
        menu=pystray.Menu(pystray.MenuItem("Выход", _on_quit)),
    )
    threading.Thread(target=_worker, daemon=True).start()
    _icon.run()  # blocks on the main thread (required on Windows)


if __name__ == "__main__":
    main()
