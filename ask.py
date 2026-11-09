"""Answers a question from the notes library with the user's AI, citing lesson and timestamp.

Claude Code searches the library files itself. Other AIs get the best-matching lessons and
transcript passages packed into the prompt. Writes the answer to <library>/answers/ and prints its path.
Usage: ask.py "<question>"
"""
import datetime as dt
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I leaves out the script folder
import ai
import nt_config

CFG = nt_config.load()
LIBRARY = Path(CFG["library"])
NOTES_BUDGET = 60000
TRANSCRIPT_BUDGET = 30000
STOP = set("what when where which with have does about from that this there their your into been were will would "
           "should could they them then than also more most some such only just like learn learned learnt lesson "
           "course notes said teach taught".split())

RULES = """Answer the question below only from the learning library.
- INDEX.md lists every lesson, newest first. Each lesson has notes (<date>-<slug>.md) and a full timestamped transcript in transcripts/.
- Cite every point with the lesson title linked to its notes file and the timestamp, e.g. ([Lesson title](2026-11-09-slug.md), 3:42).
- Keep what the teacher said apart from the notes' own "Apply this" suggestions. Mark the user's spoken notes as theirs.
- If the library does not cover the question, say so plainly and name the closest lesson, if any. Never invent.
- Output only the answer.
"""


def words(text):
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) > 3 and w not in STOP}


def packed_context(question):
    """INDEX.md, the best-matching notes in full, and matching transcript passages."""
    terms = words(question)
    notes = sorted(LIBRARY.glob("[0-9][0-9][0-9][0-9]-*.md"))
    scored = []
    for f in notes:
        text = f.read_text(encoding="utf-8", errors="ignore").lower()
        score = sum(text.count(t) for t in terms)
        tpath = LIBRARY / "transcripts" / f.name
        if tpath.exists():
            score += sum(tpath.read_text(encoding="utf-8", errors="ignore").lower().count(t) for t in terms) // 3
        scored.append((score, f))
    scored.sort(key=lambda x: (-x[0], x[1].name))
    index = (LIBRARY / "INDEX.md").read_text(encoding="utf-8") if (LIBRARY / "INDEX.md").exists() else ""
    out, used = [f"=== INDEX.md ===\n{index}"], 0
    picked = [f for s, f in scored if s > 0] or [f for _, f in scored[:3]]
    for f in picked:
        text = f.read_text(encoding="utf-8", errors="ignore")
        if used + len(text) > NOTES_BUDGET:
            break
        out.append(f"=== {f.name} ===\n{text}")
        used += len(text)
    used = 0
    for f in picked[:6]:
        tpath = LIBRARY / "transcripts" / f.name
        if not tpath.exists():
            continue
        lines = tpath.read_text(encoding="utf-8", errors="ignore").splitlines()
        keep = sorted({j for i, l in enumerate(lines) if words(l) & terms
                       for j in range(max(0, i - 2), min(len(lines), i + 3))})
        chunk = "\n".join(lines[j] for j in keep)
        if not chunk or used + len(chunk) > TRANSCRIPT_BUDGET:
            continue
        out.append(f"=== transcripts/{f.name} (matching passages) ===\n{chunk}")
        used += len(chunk)
    return "\n\n".join(out)


def main():
    question = " ".join(sys.argv[1:]).strip()
    if not question:
        sys.exit("No question given.")
    if not (LIBRARY / "INDEX.md").exists():
        sys.exit("The library is empty. Record a lesson first.")
    if (CFG.get("provider") or "claude-code") == "claude-code":
        prompt = RULES + "Read INDEX.md, search the notes and transcripts for the key words, then read the lessons that answer the question.\n\nQUESTION: " + question
        answer = ai.generate(CFG, prompt, LIBRARY, read_files=True)
    else:
        prompt = RULES + "\nLIBRARY\n" + packed_context(question) + "\n\nQUESTION: " + question
        answer = ai.generate(CFG, prompt, LIBRARY)
    slug = re.sub(r"[^a-z0-9]+", "-", question.lower()).strip("-")[:50] or "question"
    out = LIBRARY / "answers" / f"{dt.date.today().isoformat()}-{slug}.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text(f"# {question}\n\n{answer.strip()}\n", encoding="utf-8")
    print(out)


if __name__ == "__main__":
    try:
        main()
    except ai.AIError as e:
        sys.exit(str(e))
