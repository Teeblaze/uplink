"""Ask the lesson: answers a spoken question about the screen with the user's AI.

The idea comes from Clicky (github.com/farzaa/clicky, MIT): an AI teacher that sees your screen,
talks back and shows you where to look. Uplink never moves the mouse; it only marks the spot.

Input folder (written by the app): question.<wav|caf> (the spoken question) and shot.jpg (the screen
at the moment the key was pressed). Writes answer.json:
  {"question": str, "answer": str, "point": {"x": 0..1, "y": 0..1} | null}  or  {"error": str}
Usage: ask_screen.py <ask_dir>
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I leaves out the script folder
import ai  # noqa: E402
import nt_config  # noqa: E402

PROMPT = """You are Uplink, a calm teacher sitting beside someone who is watching a lesson on their computer.
They held a key and asked you a question about what is on their screen right now. The screenshot of
their screen is attached (or, if you have a file tool, read the file shot.jpg).

Answer in one to three short, plain sentences, the way a good teacher would say it out loud. No markdown,
no lists, no emojis. Never invent what is not visible or not known; if the screen does not show the
answer, say so briefly and suggest what to look for.

If your answer refers to one specific spot on the screen (a button, a menu, a setting, a line of code),
give its centre as fractions of the screenshot width and height, from the top-left corner. Otherwise use null.

Reply with ONLY this JSON and nothing else:
{"answer": "...", "point": {"x": 0.42, "y": 0.18}}

QUESTION: """


def transcribe(path):
    from faster_whisper import WhisperModel
    model = WhisperModel("small.en", device="cpu", compute_type="int8")
    segments, _ = model.transcribe(str(path), vad_filter=True)
    return " ".join(s.text.strip() for s in segments).strip()


def parse(raw):
    m = re.search(r"\{.*\}", raw, re.S)
    data = json.loads(m.group(0)) if m else {"answer": raw.strip(), "point": None}
    point = data.get("point")
    if isinstance(point, dict):
        try:
            x, y = float(point["x"]), float(point["y"])
            point = {"x": x, "y": y} if 0 <= x <= 1 and 0 <= y <= 1 else None
        except (KeyError, TypeError, ValueError):
            point = None
    else:
        point = None
    return str(data.get("answer", "")).strip(), point


def main():
    folder = Path(sys.argv[1])
    out = folder / "answer.json"
    audio = next((p for p in folder.glob("question.*")), None)
    if not audio:
        return out.write_text(json.dumps({"error": "No question was recorded."}))
    question = transcribe(audio)
    if len(question.split()) < 2:
        return out.write_text(json.dumps({"error": "I did not catch the question. Hold the key and speak."}))
    cfg = nt_config.load()
    shot = folder / "shot.jpg"
    images = [("Screenshot of the user's screen: shot.jpg", "shot.jpg")] if shot.exists() else []
    try:
        raw = ai.generate(cfg, PROMPT + question, folder, images=images)
        answer, point = parse(raw)
    except ai.AIError as e:
        return out.write_text(json.dumps({"question": question, "error": str(e)}))
    except (ValueError, json.JSONDecodeError):
        return out.write_text(json.dumps({"question": question, "error": "The AI answer could not be read."}))
    out.write_text(json.dumps({"question": question, "answer": answer, "point": point}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 - the app shows this message
        (Path(sys.argv[1]) / "answer.json").write_text(json.dumps({"error": f"{type(e).__name__}: {e}"}))
