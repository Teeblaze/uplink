"""Transcribes an Uplink session: the lesson audio plus the user's spoken notes.

Writes transcript.md in the session folder: timestamped lesson lines with
the user's notes merged in at the moment they spoke them.
Usage: transcribe.py <session_dir>
"""
import json
import sys
from pathlib import Path

from faster_whisper import WhisperModel

MODEL = "small.en"


def stamp(seconds):
    s = int(seconds)
    return f"{s // 3600:d}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:d}:{s % 60:02d}"


def main():
    session = Path(sys.argv[1])
    model = WhisperModel(MODEL, device="cpu", compute_type="int8")
    lines = []

    lesson = next((p for p in session.glob("system.*") if p.stat().st_size > 0), None)
    if lesson:
        segments, _ = model.transcribe(str(lesson), vad_filter=True, beam_size=1)
        for seg in segments:
            text = seg.text.strip()
            if text:
                lines.append((seg.start, "lesson", text))

    for note in sorted((p for p in (session / "voice-notes").glob("*.*") if p.stem.isdigit()), key=lambda p: int(p.stem)):
        segments, _ = model.transcribe(str(note), vad_filter=True, beam_size=1)
        text = " ".join(s.text.strip() for s in segments).strip()
        if text:
            lines.append((int(note.stem), "note", text))

    lines.sort(key=lambda x: (x[0], x[1] == "lesson"))
    out = []
    for t, kind, text in lines:
        out.append(f"[{stamp(t)}] USER NOTE: {text}" if kind == "note" else f"[{stamp(t)}] {text}")
    (session / "transcript.md").write_text("\n".join(out) + "\n", encoding="utf-8")

    words = sum(len(x[2].split()) for x in lines if x[1] == "lesson")
    notes = sum(1 for x in lines if x[1] == "note")
    print(json.dumps({"lesson_words": words, "spoken_notes": notes}))


if __name__ == "__main__":
    main()
