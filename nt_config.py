"""Uplink settings: where they live, defaults, and what is installed on this computer.

One config.json per user:
  macOS    ~/Library/Application Support/Uplink/config.json
  Windows  %APPDATA%\\Uplink\\config.json
  other    ~/.config/uplink/config.json
UPLINK_CONFIG overrides the path.
"""
import json
import os
import re
import shutil
import sys
from pathlib import Path

TOOL = Path(__file__).resolve().parent
HOME = Path.home()

if os.environ.get("UPLINK_CONFIG"):
    CONFIG = Path(os.environ["UPLINK_CONFIG"])
elif sys.platform == "darwin":
    CONFIG = HOME / "Library" / "Application Support" / "Uplink" / "config.json"
elif os.name == "nt":
    CONFIG = Path(os.environ.get("APPDATA", HOME)) / "Uplink" / "config.json"
else:
    CONFIG = HOME / ".config" / "uplink" / "config.json"

# Which AI writes the notes. "kind": cli runs a program on this computer; api needs a key.
PROVIDERS = {
    "claude-code": {"label": "Claude (Claude Code app)", "kind": "cli", "program": "claude"},
    "codex": {"label": "ChatGPT (Codex app)", "kind": "cli", "program": "codex"},
    "gemini-cli": {"label": "Gemini (Gemini CLI)", "kind": "cli", "program": "gemini"},
    "anthropic": {"label": "Claude (API key)", "kind": "api", "model": "claude-opus-5-5",
                  "keys": "https://platform.claude.com/settings/keys"},
    "openai": {"label": "ChatGPT (OpenAI API key)", "kind": "api", "model": "gpt-5.5",
               "keys": "https://platform.openai.com/api-keys"},
    "gemini": {"label": "Gemini (Google AI Studio key)", "kind": "api", "model": "gemini-3.6-flash",
               "keys": "https://aistudio.google.com/apikey"},
    "ollama": {"label": "Local model (Ollama, free, offline)", "kind": "local", "model": ""},
}

# Folders used when the user has no agents: one reading list per topic.
TOPICS = {
    "design": "Graphic, brand, UI and product design",
    "video": "Video editing, filmmaking, motion and sound",
    "marketing": "Marketing, social media, content and sales",
    "business": "Business, freelancing, pricing and clients",
    "tech": "Coding, AI tools and software",
    "writing": "Writing, scripts and storytelling",
    "finance": "Money, investing and trading",
    "personal-growth": "Habits, productivity and mindset",
    "other": "Anything else",
}

# AI home folders: their global instruction file, and where their agents or skills live.
HOMES = {
    "claude": {"label": "Claude Code", "memory": HOME / ".claude" / "CLAUDE.md",
               "agents": HOME / ".claude" / "agents", "skills": HOME / ".claude" / "skills"},
    "codex": {"label": "Codex", "memory": HOME / ".codex" / "AGENTS.md",
              "agents": None, "skills": HOME / ".codex" / "skills"},
    "gemini": {"label": "Gemini CLI", "memory": HOME / ".gemini" / "GEMINI.md",
               "agents": HOME / ".gemini" / "agents", "skills": HOME / ".gemini" / "skills"},
}


def default_library():
    docs = HOME / "Documents"
    return str((docs if docs.exists() else HOME) / "Uplink Library")


DEFAULTS = {
    "provider": "",          # empty until setup has run
    "model": "",
    "api_keys": {},          # provider -> key, kept only in this file (owner-only permissions)
    "ollama_url": "http://localhost:11434",
    "library": "",
    "prompt": "generic",     # "generic" or a path to a custom notes prompt
    "route_dir": "agents",
    "routes": [],            # [{id, description, kind, file}]
    "screenshots": True,
    "shortcuts": {},         # filled per platform by shortcuts()
    "mark_style": "ring",    # Ask the lesson marks the spot with a still "ring" or a gliding "pointer"
}

# Default keys. "lesson" toggles, "note" and "ask" are held while speaking.
DEFAULT_SHORTCUTS = ({"lesson": "ctrl+alt+n", "note": "ctrl+alt+m", "ask": "ctrl+alt+a"} if os.name == "nt" else
                     {"lesson": "ctrl+option+n", "note": "ctrl+option+m", "ask": "ctrl+option+a"})


def shortcuts(cfg):
    return {**DEFAULT_SHORTCUTS, **(cfg.get("shortcuts") or {})}


def load():
    cfg = json.loads(json.dumps(DEFAULTS))
    if CONFIG.exists():
        cfg.update(json.loads(CONFIG.read_text(encoding="utf-8")))
    cfg["library"] = cfg["library"] or default_library()
    cfg["shortcuts"] = shortcuts(cfg)
    if not cfg["routes"]:
        cfg["routes"] = [{"id": k, "description": v, "kind": "topic", "file": ""} for k, v in TOPICS.items()]
    return cfg


def save(cfg):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(CONFIG, 0o600)
    except OSError:
        pass


def configured():
    return CONFIG.exists() and bool(load().get("provider"))


def find_program(name):
    """Finds a CLI even when the app was started without the user's shell PATH."""
    found = shutil.which(name)
    if found:
        return found
    exe = name + (".cmd" if os.name == "nt" else "")
    for d in [HOME / ".local" / "bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"),
              HOME / ".npm-global" / "bin", Path(os.environ.get("APPDATA", HOME)) / "npm"]:
        if (d / exe).exists():
            return str(d / exe)
    return None


def frontmatter(path):
    """name and description from a markdown file's frontmatter."""
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return {}
    m = re.match(r"---\s*\n(.*?)\n---", text, re.S)
    out = {}
    if m:
        for line in m.group(1).splitlines():
            if ":" in line and not line.startswith((" ", "\t")):
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip().strip("'\"")
    return out


def detect_destinations():
    """Agents and skills installed for Claude Code, Codex and Gemini CLI."""
    found = []
    for home_id, h in HOMES.items():
        if h["agents"] and h["agents"].is_dir():
            for f in sorted(h["agents"].glob("*.md")):
                fm = frontmatter(f)
                found.append({"id": fm.get("name") or f.stem, "description": fm.get("description", ""),
                              "kind": f"{home_id}-agent", "file": str(f), "home": h["label"]})
        if h["skills"] and h["skills"].is_dir():
            for f in sorted(h["skills"].glob("*/SKILL.md")):
                if f.parent.name.startswith("."):
                    continue
                fm = frontmatter(f)
                found.append({"id": fm.get("name") or f.parent.name, "description": fm.get("description", ""),
                              "kind": f"{home_id}-skill", "file": str(f), "home": h["label"]})
    return found


def detect():
    """What the settings page shows: installed AI apps and their agents."""
    providers = {}
    for pid, p in PROVIDERS.items():
        info = dict(p)
        if p["kind"] == "cli":
            info["installed"] = bool(find_program(p["program"]))
        providers[pid] = info
    memories = {k: {"label": h["label"], "file": str(h["memory"]), "exists": h["memory"].parent.exists()}
                for k, h in HOMES.items()}
    return {"providers": providers, "destinations": detect_destinations(), "memories": memories,
            "topics": TOPICS, "config_path": str(CONFIG)}


# ----- linking agents to the library -----

def reading_list(cfg, route_id):
    return Path(cfg["library"]) / cfg["route_dir"] / f"{route_id}.md"


def link_destination(cfg, route):
    """Adds a 'Learned notes' section to an agent or skill file so it reads its list. Safe to repeat."""
    if not route.get("file"):
        return False
    path = Path(route["file"])
    if not path.exists():
        return False
    target = str(reading_list(cfg, route["id"]))
    text = path.read_text(encoding="utf-8")
    if target in text:
        return False
    section = ("\n\n## Learned notes\n"
               f"Before starting a job, read `{target}` (if it exists) and open the lessons that fit the job. "
               "They are notes from courses and videos the user watched, written by Uplink. "
               "Use them where they fit; the user's own instructions win where they conflict.\n")
    path.write_text(text.rstrip("\n") + section, encoding="utf-8")
    return True


def link_memory(cfg, home_id):
    """Tells an AI app (CLAUDE.md, AGENTS.md, GEMINI.md) where the notes library is. Safe to repeat."""
    path = HOMES[home_id]["memory"]
    index = str(Path(cfg["library"]) / "INDEX.md")
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if index in text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    block = ("\n\n## My learning library (Uplink)\n"
             f"When a task touches something I may have studied, read `{index}` first. It lists notes from "
             "courses and videos I watched, newest first; each has a full transcript in `transcripts/`. "
             "Cite the lesson and timestamp when you use them.\n")
    path.write_text(text.rstrip("\n") + block if text else block.lstrip("\n"), encoding="utf-8")
    return True
