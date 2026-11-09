"""Sends an Uplink transcript to the user's AI and files the notes.

The AI, the library folder and the agents (destinations) come from Settings (nt_config).
Writes the notes to the library, updates INDEX.md and each destination's reading list,
then writes result.txt for the app:
  OK|<notes path>|<title>|<agents>   or   ERROR|<reason>
Usage: make_notes.py <session_dir>
"""
import datetime as dt
import json
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I leaves out the script folder
import ai
import nt_config

TOOL = Path(__file__).resolve().parent
CFG = nt_config.load()
LEARNING = Path(CFG["library"])
PROMPT = TOOL / "notes_prompt_generic.md" if CFG["prompt"] == "generic" else Path(CFG["prompt"])
AGENTS = [r["id"] for r in CFG["routes"]]
ROUTE_DIR = CFG["route_dir"]
MIN_WORDS = 40
MAX_SHOTS = 40


def stamp(seconds):
    s = int(seconds)
    return f"{s // 3600:d}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:d}:{s % 60:02d}"


def pick_shots(session):
    """Screenshots in time order, thinned evenly to MAX_SHOTS."""
    shots = sorted((session / "shots").glob("*.jpg"), key=lambda p: int(p.stem)) if (session / "shots").exists() else []
    if len(shots) > MAX_SHOTS:
        step = len(shots) / MAX_SHOTS
        shots = [shots[int(i * step)] for i in range(MAX_SHOTS)]
    return shots


def result(session, text):
    (session / "result.txt").write_text(text + "\n", encoding="utf-8")
    print(text)


def parse(raw):
    """Returns (frontmatter dict, full notes text) from Claude's output."""
    lines = raw.strip().splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip() == "---")
    end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "---")
    meta = {}
    for l in lines[start + 1:end]:
        if ":" in l:
            k, v = l.split(":", 1)
            meta[k.strip()] = v.strip()
    agents = [a.strip(" '\"") for a in meta.get("agents", "").strip("[]").split(",")]
    meta["agents"] = [a for a in agents if a in AGENTS]
    return meta, "\n".join(lines[start:]).strip() + "\n"


def destinations():
    lines = []
    for r in CFG["routes"]:
        d = re.sub(r"\s+", " ", r.get("description", "")).strip()
        lines.append(f"- {r['id']}: {d[:240] + '...' if len(d) > 240 else d}")
    return "\n".join(lines)


def add_line(path, header, line):
    """Adds line as the newest entry under the header of a list file (an existing header is kept)."""
    if path.exists():
        text = path.read_text(encoding="utf-8").rstrip("\n").split("\n")
        path.write_text("\n".join(text[:len(header)] + [line] + text[len(header):]) + "\n", encoding="utf-8")
    else:
        path.write_text("\n".join(header + [line]) + "\n", encoding="utf-8")


def main():
    session = Path(sys.argv[1])
    transcript = (session / "transcript.md").read_text(encoding="utf-8") if (session / "transcript.md").exists() else ""
    lesson_words = sum(len(l.split()) for l in transcript.splitlines() if "USER NOTE:" not in l)
    if lesson_words < MIN_WORDS:
        return result(session, "ERROR|No lesson speech was captured. Check that the sound was playing on this Mac.")

    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    prompt = PROMPT.read_text(encoding="utf-8").replace("{DESTINATIONS}", destinations())
    prompt += f"Window title: {meta.get('title', '')}\nApp: {meta.get('app', '')}\nStarted: {meta.get('started', '')}\n"
    shots = pick_shots(session)
    if shots:
        prompt += ("\nSCREENSHOTS\nThe lesson window was captured when the screen changed and settled, more often when the "
                   "lesson was quiet (silent demos). Look at every screenshot listed below before writing (they are "
                   "attached with their file names; if you have a file-reading tool instead, read each file). "
                   "Add a section \"## On screen\" after \"Steps and methods\": for each moment that shows something the "
                   "transcript does not say (settings, menus, layouts, values, code, slides), write the timestamp and what "
                   "is shown. To place a screenshot in the notes, write the token SHOT:<seconds> on its own line "
                   "(for example SHOT:75); use 3 to 8 of the most useful ones. Skip blank, duplicate or unrelated frames.\n")
        prompt += "\n".join(f"- {stamp(int(p.stem))}: shots/{p.name}" for p in shots) + "\n"
    prompt += f"\nTRANSCRIPT\n{transcript}"

    images = [(f"Screenshot shots/{p.name} at {stamp(int(p.stem))}", f"shots/{p.name}") for p in shots]
    try:
        raw = ai.generate(CFG, prompt, session, images=images)
    except ai.AIError as e:
        return result(session, "ERROR|" + str(e).replace("\n", " ").replace("|", "/")[:250])
    (session / "ai-output.md").write_text(raw, encoding="utf-8")
    if "---" not in raw:
        return result(session, "ERROR|The AI did not return notes in the expected format. See ai-output.md.")

    fm, notes = parse(raw)
    title = fm.get("title", meta.get("title", "Lesson"))
    slug = re.sub(r"[^a-z0-9-]+", "-", fm.get("slug", "lesson").lower()).strip("-") or "lesson"
    date = dt.date.today().isoformat()

    LEARNING.mkdir(exist_ok=True)
    (LEARNING / ROUTE_DIR).mkdir(exist_ok=True)
    path = LEARNING / f"{date}-{slug}.md"
    n = 2
    while path.exists():
        path = LEARNING / f"{date}-{slug}-{n}.md"
        n += 1
    if shots:
        (LEARNING / "images").mkdir(exist_ok=True)

        def place(m):
            src = session / "shots" / f"{m.group(1)}.jpg"
            if not src.exists():
                return ""
            name = f"{path.stem}-{m.group(1)}.jpg"
            shutil.copy(src, LEARNING / "images" / name)
            return f"![Screen at {stamp(int(m.group(1)))}](images/{name})"
        notes = re.sub(r"`?SHOT:(\d+)`?", place, notes)
    path.write_text(notes, encoding="utf-8")
    (LEARNING / "transcripts").mkdir(exist_ok=True)
    (LEARNING / "transcripts" / path.name).write_text(transcript, encoding="utf-8")

    summary = fm.get("summary", "")
    agents = fm["agents"]
    add_line(LEARNING / "INDEX.md",
             ["# Learning library", "", "Notes from courses and videos I watched, newest first. Written by Uplink.", ""],
             f"- {date} [{title}]({path.name}) ({fm.get('topic', 'other')}; for {', '.join(agents) or 'me'}): {summary}")
    kinds = {r["id"]: r.get("kind") for r in CFG["routes"]}
    for agent in agents:
        if kinds.get(agent) == "folder":  # Custom GPT, Gem or Project: a copy to upload
            (LEARNING / "for-upload" / agent).mkdir(parents=True, exist_ok=True)
            shutil.copy(path, LEARNING / "for-upload" / agent / path.name)
        add_line(LEARNING / ROUTE_DIR / f"{agent}.md",
                 [f"# Lessons for {agent}", "", "Newest first. Open the ones that fit the job before starting.", ""],
                 f"- {date} [{title}](../{path.name}): {summary}")

    for audio in [*session.glob("system.*"), *(session / "voice-notes").glob("*.*")]:
        audio.unlink(missing_ok=True)
    shutil.rmtree(session / "shots", ignore_errors=True)
    result(session, f"OK|{path}|{title}|{', '.join(agents)}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 - report any failure to the menu-bar app
        result(Path(sys.argv[1]), f"ERROR|{type(e).__name__}: {e}")
