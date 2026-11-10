"""Uplink for Windows: tray-icon course note taker.

Ctrl+Alt+N starts or stops a lesson (records the PC's sound).
Hold Ctrl+Alt+M to add a spoken note (records the microphone).
While recording, smart screenshots of the lesson window are kept when the screen changes and settles.
On stop, the lesson is transcribed on this PC (faster-whisper) and the AI picked in Settings
(Claude, ChatGPT, Gemini or a local model) writes the notes and files them for the user's agents.

Shares transcribe.py, make_notes.py, ask.py, settings.py and nt_config.py with the Mac version (one folder up).
"""
import ctypes
import datetime as dt
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import keyboard
import mss
import numpy as np
import pystray
import soundcard as sc
import soundfile as sf
import win32gui
import win32process
import psutil
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
CORE = HERE.parent
sys.path.insert(0, str(CORE))
import nt_config  # noqa: E402

APPDATA = Path(os.environ["APPDATA"]) / "Uplink"
SESSIONS = APPDATA / "sessions"
ASKS = APPDATA / "asks"
PY = sys.executable.replace("pythonw.exe", "python.exe")
RATE = 48000


def win_keys(combo):
    """Settings stores Mac-style names too; the keyboard library wants alt and windows."""
    return "+".join({"option": "alt", "opt": "alt", "cmd": "windows", "command": "windows", "win": "windows",
                     "control": "ctrl"}.get(k, k) for k in combo.lower().split("+"))


def pretty(combo):
    return "+".join(k.capitalize() if len(k) > 1 else k.upper() for k in win_keys(combo).split("+"))


def env_for():
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    return env


def signature(img):
    """32x18 greyscale thumbnail, used to compare frames."""
    return np.asarray(img.convert("L").resize((32, 18)), dtype=np.int16)


def difference(a, b):
    return float(np.abs(a - b).mean()) / 255


class Uplink:
    def __init__(self):
        self.cfg = nt_config.load()
        self.session = None
        self.t0 = None
        self.recording = False
        self.note_on = False
        self.last_loud = 0.0
        self.jobs = 0
        self.last_notes = None
        self.hwnd = None
        self.ask_dir = None
        self.ask_on = False
        self.ask_t = None
        self.keys = nt_config.shortcuts(self.cfg)
        self.icon = pystray.Icon("Uplink", self.draw_icon(False), "Uplink", self.menu())

    # ----- tray -----
    def draw_icon(self, rec):
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        if rec:
            d.ellipse((8, 8, 56, 56), fill=(220, 40, 40))
        else:
            d.rectangle((14, 8, 50, 56), outline=(240, 240, 240), width=5)
            for y in (22, 32, 42):
                d.line((22, y, 42, y), fill=(240, 240, 240), width=4)
        return img

    def menu(self):
        M = pystray.MenuItem
        return pystray.Menu(
            M(lambda _: f"{'Stop' if self.recording else 'Start'} lesson ({pretty(self.keys['lesson'])})", lambda: self.toggle()),
            M(lambda _: f"Hold {pretty(self.keys['note'])} to add a spoken note", None, enabled=False),
            M(lambda _: f"Hold {pretty(self.keys['ask'])} to ask about your screen", None, enabled=False),
            M(lambda _: f"Working on {self.jobs} job(s)..." if self.jobs else "Idle", None, enabled=False),
            pystray.Menu.SEPARATOR,
            M("Open last notes", lambda: os.startfile(self.last_notes), enabled=lambda _: bool(self.last_notes)),
            M("Open notes library", lambda: os.startfile(self.library())),
            M("Ask my library...", lambda: self.ask()),
            M("Take screenshots of the lesson", lambda: self.toggle_shots(), checked=lambda _: self.cfg["screenshots"]),
            M("Settings (AI, shortcuts, agents)...", lambda: self.settings()),
            pystray.Menu.SEPARATOR,
            M("Quit Uplink", lambda: self.quit()),
        )

    def refresh(self):
        self.icon.icon = self.draw_icon(self.recording)
        self.icon.update_menu()

    def notify(self, title, body):
        try:
            self.icon.notify(body, title)
        except Exception:
            pass

    def library(self):
        p = Path(nt_config.load()["library"])
        p.mkdir(parents=True, exist_ok=True)
        return str(p)

    def toggle_shots(self):
        self.cfg = nt_config.load()
        self.cfg["screenshots"] = not self.cfg["screenshots"]
        nt_config.save(self.cfg)
        self.refresh()

    def settings(self):
        subprocess.Popen([PY, "-I", str(CORE / "settings.py")], env=env_for(), creationflags=subprocess.CREATE_NO_WINDOW)

    # ----- lesson -----
    def toggle(self):
        self.stop() if self.recording else self.start()

    def start(self):
        self.hwnd = win32gui.GetForegroundWindow()
        title = win32gui.GetWindowText(self.hwnd) or "Lesson"
        try:
            _, pid = win32process.GetWindowThreadProcessId(self.hwnd)
            app = psutil.Process(pid).name()
        except Exception:
            app = ""
        stamp = dt.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
        self.session = SESSIONS / stamp
        (self.session / "voice-notes").mkdir(parents=True, exist_ok=True)
        (self.session / "meta.json").write_text(json.dumps(
            {"title": title, "app": app, "started": dt.datetime.now().isoformat()}, indent=2), encoding="utf-8")
        self.t0 = time.time()
        self.last_loud = 0.0
        self.recording = True
        threading.Thread(target=self.audio_loop, daemon=True).start()
        if self.cfg["screenshots"]:
            (self.session / "shots").mkdir(exist_ok=True)
            threading.Thread(target=self.shot_loop, daemon=True).start()
        self.refresh()
        self.notify("Recording lesson", title)

    def stop(self):
        if not self.recording:
            return
        self.note_up()
        self.recording = False
        session = self.session
        self.session = None
        self.refresh()
        time.sleep(0.8)  # let the audio and screenshot threads close their files
        threading.Thread(target=self.process, args=(session,), daemon=True).start()

    def audio_loop(self):
        speaker = sc.get_microphone(id=str(sc.default_speaker().name), include_loopback=True)
        with sf.SoundFile(str(self.session / "system.wav"), "w", samplerate=RATE, channels=2) as f, \
                speaker.recorder(samplerate=RATE, channels=2) as rec:
            while self.recording:
                data = rec.record(numframes=RATE // 10)
                f.write(data)
                if data.size and float(np.sqrt(np.mean(np.square(data)))) > 0.01:
                    self.last_loud = time.time() - self.t0

    def shot_loop(self):
        """Keeps a screenshot when the lesson window changed and settled; more often when quiet."""
        prev = kept = None
        last_shot = -100.0
        count = 0
        shots = self.session / "shots"
        with mss.mss() as grab:
            while self.recording and count < 120:
                time.sleep(2)
                try:
                    l, t, r, b = win32gui.GetWindowRect(self.hwnd)
                    if r - l < 50 or b - t < 50:
                        continue
                    raw = grab.grab({"left": l, "top": t, "width": r - l, "height": b - t})
                except Exception:
                    continue
                img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
                sig = signature(img)
                settled = prev is not None and difference(sig, prev) < 0.012
                prev = sig
                if not settled or (kept is not None and difference(sig, kept) < 0.035):
                    continue
                now = time.time() - self.t0
                quiet = now - self.last_loud > 3
                if now - last_shot < (4 if quiet else 10):
                    continue
                if img.width > 1440:
                    img = img.resize((1440, int(img.height * 1440 / img.width)))
                img.save(shots / f"{int(now)}.jpg", quality=70)
                kept, last_shot = sig, now
                count += 1

    # ----- spoken notes -----
    def note_down(self):
        if not self.recording or self.note_on:
            return
        self.note_on = True
        path = self.session / "voice-notes" / f"{int(time.time() - self.t0)}.wav"
        threading.Thread(target=self.note_loop, args=(path,), daemon=True).start()

    def note_loop(self, path):
        mic = sc.default_microphone()
        with sf.SoundFile(str(path), "w", samplerate=RATE, channels=1) as f, mic.recorder(samplerate=RATE, channels=1) as rec:
            while self.note_on:
                f.write(rec.record(numframes=RATE // 20))

    def note_up(self):
        self.note_on = False

    # ----- processing -----
    def process(self, session):
        self.jobs += 1
        self.refresh()
        env = env_for()
        log = open(session / "process.log", "a", encoding="utf-8")
        flags = subprocess.CREATE_NO_WINDOW
        ok = subprocess.run([PY, "-I", str(CORE / "transcribe.py"), str(session)], stdout=log, stderr=log,
                            env=env, creationflags=flags).returncode == 0
        if ok:
            subprocess.run([PY, "-I", str(CORE / "make_notes.py"), str(session)], stdout=log, stderr=log,
                           env=env, creationflags=flags)
        log.close()
        result_file = session / "result.txt"
        result = result_file.read_text(encoding="utf-8").strip() if result_file.exists() else "ERROR|Transcription failed. See process.log."
        self.jobs -= 1
        if result.startswith("OK|"):
            parts = result.split("|", 3)
            self.last_notes = parts[1]
            self.notify(f"Notes saved: {parts[2] if len(parts) > 2 else 'Lesson'}",
                        f"For {parts[3]}" if len(parts) > 3 and parts[3] else "Saved to your library")
        else:
            self.notify("Notes failed", result.replace("ERROR|", ""))
        self.refresh()

    # ----- ask my library -----
    def ask(self):
        subprocess.Popen([sys.executable, str(HERE / "uplink_win.py"), "--ask"], env=env_for())

    def quit(self):
        self.recording = False
        self.note_on = False
        keyboard.unhook_all()
        self.icon.stop()

    # ----- ask the lesson (idea from Clicky, github.com/farzaa/clicky, MIT) -----
    def ask_down(self):
        if self.ask_on or self.note_on:
            return
        self.ask_on = True
        self.ask_t = time.time()
        self.ask_dir = ASKS / dt.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
        self.ask_dir.mkdir(parents=True, exist_ok=True)
        self.grab_window(self.ask_dir)
        self.notify("Listening", "Ask about your screen, then let go.")
        threading.Thread(target=self.ask_loop, args=(self.ask_dir / "question.wav",), daemon=True).start()

    def ask_loop(self, path):
        mic = sc.default_microphone()
        with sf.SoundFile(str(path), "w", samplerate=RATE, channels=1) as f, mic.recorder(samplerate=RATE, channels=1) as rec:
            while self.ask_on:
                f.write(rec.record(numframes=RATE // 20))

    def grab_window(self, folder):
        try:
            hwnd = win32gui.GetForegroundWindow()
            l, t, r, b = win32gui.GetWindowRect(hwnd)
            with mss.mss() as grab:
                raw = grab.grab({"left": l, "top": t, "width": r - l, "height": b - t})
            img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
            if img.width > 1600:
                img = img.resize((1600, int(img.height * 1600 / img.width)))
            img.save(folder / "shot.jpg", quality=80)
            (folder / "window.json").write_text(json.dumps({"x": l, "y": t, "w": r - l, "h": b - t}))
        except Exception:
            pass

    def ask_up(self):
        if not self.ask_on:
            return
        self.ask_on = False
        folder, started = self.ask_dir, self.ask_t
        if time.time() - started < 0.7:
            return
        lesson = self.session
        offset = int(started - self.t0) if self.recording and self.t0 else None
        threading.Thread(target=self.answer, args=(folder, lesson, offset), daemon=True).start()

    def answer(self, folder, lesson, offset):
        time.sleep(0.3)  # let the recorder close the file
        self.jobs += 1
        self.refresh()
        subprocess.run([PY, "-I", str(CORE / "ask_screen.py"), str(folder)], env=env_for(),
                       creationflags=subprocess.CREATE_NO_WINDOW)
        self.jobs -= 1
        self.refresh()
        try:
            result = json.loads((folder / "answer.json").read_text(encoding="utf-8"))
        except Exception:
            result = {"error": "No answer came back. Check Settings."}
        if "error" in result:
            return self.notify("Could not answer", result["error"])
        answer = result.get("answer", "")
        self.notify(result.get("question") or "Answer", answer)
        point = result.get("point")
        if point and (folder / "window.json").exists():
            f = json.loads((folder / "window.json").read_text())
            x, y = int(f["x"] + point["x"] * f["w"]), int(f["y"] + point["y"] * f["h"])
            style = nt_config.load().get("mark_style", "ring")
            subprocess.Popen([sys.executable, str(HERE / "uplink_win.py"), "--mark", style, str(x), str(y)])
        try:
            import win32com.client
            win32com.client.Dispatch("SAPI.SpVoice").Speak(answer)
        except Exception:
            pass
        if lesson and offset is not None:
            shots = lesson / "shots"
            if (folder / "shot.jpg").exists():
                shots.mkdir(exist_ok=True)
                (shots / f"{offset}.jpg").write_bytes((folder / "shot.jpg").read_bytes())
            with open(lesson / "asks.jsonl", "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"t": offset, "question": result.get("question", ""), "answer": answer}) + "\n")

    # ----- shortcuts (set in Settings, reloaded when saved) -----
    def bind_keys(self):
        keyboard.unhook_all()
        k = self.keys
        keyboard.add_hotkey(win_keys(k["lesson"]), self.toggle)
        keyboard.add_hotkey(win_keys(k["note"]), self.note_down)
        keyboard.on_release_key(win_keys(k["note"]).split("+")[-1], lambda e: self.note_up())
        keyboard.add_hotkey(win_keys(k["ask"]), self.ask_down)
        keyboard.on_release_key(win_keys(k["ask"]).split("+")[-1], lambda e: self.ask_up())

    def watch_config(self):
        stamp = nt_config.CONFIG.stat().st_mtime if nt_config.CONFIG.exists() else 0
        while True:
            time.sleep(3)
            now = nt_config.CONFIG.stat().st_mtime if nt_config.CONFIG.exists() else 0
            if now != stamp:
                stamp = now
                self.cfg = nt_config.load()
                self.keys = nt_config.shortcuts(self.cfg)
                self.bind_keys()
                self.refresh()

    def run(self):
        self.bind_keys()
        threading.Thread(target=self.watch_config, daemon=True).start()
        if not nt_config.configured():
            self.settings()  # first run: pick the AI, library and agents
        self.icon.run()


def show_mark(style, x, y, seconds=5):
    """A still lime ring, or a lime arrow that glides from beside the cursor. Never moves the mouse."""
    import tkinter as tk
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-transparentcolor", "#010101")
    root.configure(bg="#010101")
    size = 76 if style == "ring" else 34
    c = tk.Canvas(root, width=size, height=size, bg="#010101", highlightthickness=0)
    c.pack()
    if style == "ring":
        c.create_oval(6, 6, size - 6, size - 6, outline="#DCFF2E", width=4)
        root.geometry(f"{size}x{size}+{x - size // 2}+{y - size // 2}")
    else:
        c.create_polygon(3, 3, size - 6, size * 0.58, size * 0.45, size * 0.64, size * 0.30, size - 4,
                         fill="#DCFF2E", outline="#161817", width=2)
        cx, cy = win32gui.GetCursorPos()
        steps = 28
        for i in range(steps + 1):
            k = i / steps
            k = k * k * (3 - 2 * k)  # ease in and out
            px, py = int(cx + 8 + (x - 3 - cx - 8) * k), int(cy + 8 + (y - 3 - cy - 8) * k)
            root.after(int(i * 700 / steps), lambda px=px, py=py: root.geometry(f"{size}x{size}+{px}+{py}"))
    root.after(int(seconds * 1000), root.destroy)
    root.mainloop()


def ask_dialog():
    """Small window: type a question, get the answer from the library, open it."""
    import tkinter as tk
    from tkinter import simpledialog, messagebox
    root = tk.Tk()
    root.withdraw()
    q = simpledialog.askstring("Ask my library", "Answers come only from your course notes, with the lesson and timestamp.")
    if not q:
        return
    run = subprocess.run([PY, "-I", str(CORE / "ask.py"), q], capture_output=True, text=True, encoding="utf-8",
                         env=env_for(), creationflags=subprocess.CREATE_NO_WINDOW)
    path = run.stdout.strip().splitlines()[-1] if run.returncode == 0 and run.stdout.strip() else ""
    if path:
        os.startfile(path)
    else:
        messagebox.showerror("Ask my library", (run.stderr or "").strip()[-300:] or "Your AI did not return an answer. Check Settings.")


if __name__ == "__main__":
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # real pixel coordinates for screenshots
    except Exception:
        pass
    if "--mark" in sys.argv:
        i = sys.argv.index("--mark")
        show_mark(sys.argv[i + 1], int(sys.argv[i + 2]), int(sys.argv[i + 3]))
    elif "--ask" in sys.argv:
        ask_dialog()
    else:
        Uplink().run()
