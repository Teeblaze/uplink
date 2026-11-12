"""Sends a prompt (and screenshots) to the AI the user picked in Settings, returns its text.

Providers: claude-code, codex, gemini-cli (programs on this computer, signed in by the user),
anthropic, openai, gemini (API keys), ollama (local models). See nt_config.PROVIDERS.
"""
import base64
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import nt_config

TIMEOUT = 1800
MAX_TOKENS = 32000


class AIError(Exception):
    pass


def provider_of(cfg):
    p = cfg.get("provider") or "claude-code"
    if p not in nt_config.PROVIDERS:
        raise AIError(f"Unknown AI provider '{p}'. Open Settings and pick one.")
    return p


def model_of(cfg, provider):
    return cfg.get("model") or nt_config.PROVIDERS[provider].get("model", "")


def key_of(cfg, provider):
    key = (cfg.get("api_keys") or {}).get(provider, "")
    if not key:
        raise AIError("No API key saved. Open Uplink Settings and paste your key.")
    return key


def b64(path):
    return base64.standard_b64encode(Path(path).read_bytes()).decode("ascii")


def generate(cfg, prompt, cwd, images=(), read_files=False):
    """images: [(label, path relative to cwd)]. read_files: let a CLI read files in cwd (Ask my library)."""
    provider = provider_of(cfg)
    cwd = Path(cwd)
    images = [(label, cwd / rel) for label, rel in images]
    fn = {"claude-code": _claude_code, "codex": _codex, "gemini-cli": _gemini_cli, "anthropic": _anthropic,
          "openai": _openai, "gemini": _gemini, "ollama": _ollama}[provider]
    text = fn(cfg, provider, prompt, cwd, images, read_files)
    if not text or not text.strip():
        raise AIError(f"{nt_config.PROVIDERS[provider]['label']} returned nothing.")
    return text


# ----- programs on this computer -----

def _program(provider):
    name = nt_config.PROVIDERS[provider]["program"]
    path = nt_config.find_program(name)
    if not path:
        raise AIError(f"'{name}' is not installed or not found. Install it and sign in, or pick another AI in Settings.")
    return path


def _run(cmd, prompt, cwd):
    try:
        run = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8",
                             timeout=TIMEOUT, cwd=str(cwd))
    except subprocess.TimeoutExpired:
        raise AIError("The AI took longer than 30 minutes.")
    if run.returncode != 0:
        raise AIError((run.stderr or run.stdout or "The AI program failed.").strip()[:300])
    return run.stdout


def _claude_code(cfg, provider, prompt, cwd, images, read_files):
    cmd = [_program(provider), "-p", "--output-format", "text", "--no-session-persistence"]
    if cfg.get("model"):
        cmd += ["--model", cfg["model"]]
    if read_files:
        cmd += ["--tools", "Read,Grep,Glob", "--allowedTools", "Read", "Grep", "Glob"]
    elif images:
        cmd += ["--tools", "Read", "--allowedTools", "Read"]
    else:
        cmd += ["--tools", ""]
    return _run(cmd, prompt, cwd)


def _codex(cfg, provider, prompt, cwd, images, read_files):
    out = cwd / ".codex-answer.txt"
    cmd = [_program(provider), "exec", "--skip-git-repo-check", "--sandbox", "read-only",
           "--output-last-message", str(out)]
    if cfg.get("model"):
        cmd += ["--model", cfg["model"]]
    for _, path in images:
        cmd += ["--image", str(path)]
    _run(cmd + ["-"], prompt, cwd)
    text = out.read_text(encoding="utf-8") if out.exists() else ""
    out.unlink(missing_ok=True)
    return text


def _gemini_cli(cfg, provider, prompt, cwd, images, read_files):
    task = cwd / ".uplink-prompt.md"
    task.write_text(prompt, encoding="utf-8")
    refs = " ".join(f"@{p.relative_to(cwd).as_posix()}" for _, p in images)
    cmd = [_program(provider)]
    if cfg.get("model"):
        cmd += ["--model", cfg["model"]]
    cmd += ["-p", f"Follow the instructions in @{task.name} exactly and output only what it asks for. {refs}".strip()]
    try:
        return _run(cmd, "", cwd)
    finally:
        task.unlink(missing_ok=True)


# ----- API keys -----

class Busy(AIError):
    """The service is overloaded right now (HTTP 5xx or 'high demand'); worth retrying or another model."""


def _http(url, body, headers, retries=(3, 8, 15, 15)):
    """POST JSON. Busy services (500/502/503/504) are retried after the waits in `retries` (seconds)."""
    data = json.dumps(body).encode("utf-8")
    for attempt in range(len(retries) + 1):
        req = urllib.request.Request(url, data=data, headers={"content-type": "application/json", **headers})
        try:
            return _http_once(req)
        except Busy:
            if attempt == len(retries):
                raise
            time.sleep(retries[attempt])


def _http_once(req):
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:300]
        if e.code in (401, 403):
            raise AIError("The API key was not accepted. Check it in Settings.")
        if e.code == 404:
            raise AIError("That model was not found. Pick another model in Settings.")
        if e.code in (500, 502, 503, 504) or "high demand" in detail.lower() or "overloaded" in detail.lower():
            raise Busy("The AI service is busy right now. Uplink tried several times; use Retry last lesson in a few minutes.")
        if e.code == 429:
            raise AIError("Rate limit reached, or the free daily allowance is used up. Try again later or tomorrow.")
        raise AIError(f"API error {e.code}: {detail}")
    except urllib.error.URLError as e:
        raise AIError(f"Could not reach the AI service: {e.reason}")


def _anthropic(cfg, provider, prompt, cwd, images, read_files):
    try:
        import anthropic
    except ImportError:
        raise AIError("The Claude API needs the 'anthropic' package. Run the installer again.")
    client = anthropic.Anthropic(api_key=key_of(cfg, provider), timeout=TIMEOUT)
    content = []
    for label, path in images:
        content.append({"type": "text", "text": label})
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64(path)}})
    content.append({"type": "text", "text": prompt})
    model = model_of(cfg, provider)
    args = {"model": model, "max_tokens": MAX_TOKENS, "messages": [{"role": "user", "content": content}]}
    try:
        if model in ("claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"):
            # Server-side fallback: if the model declines, the API reruns the request on a fallback model.
            with client.beta.messages.stream(betas=["server-side-fallback-2026-07-01"], fallbacks="default", **args) as s:
                msg = s.get_final_message()
        else:
            with client.messages.stream(**args) as s:
                msg = s.get_final_message()
    except anthropic.AuthenticationError:
        raise AIError("The API key was not accepted. Check it in Settings.")
    except anthropic.NotFoundError:
        raise AIError("That model was not found. Pick another model in Settings.")
    except anthropic.RateLimitError:
        raise AIError("Rate limit or no credit left on this API account.")
    except anthropic.APIStatusError as e:
        raise AIError(f"Claude API error {e.status_code}: {e.message}"[:300])
    except anthropic.APIConnectionError:
        raise AIError("Could not reach the Claude API. Check the internet connection.")
    if msg.stop_reason == "refusal":
        raise AIError("Claude declined this lesson.")
    return "".join(b.text for b in msg.content if b.type == "text")


def _openai(cfg, provider, prompt, cwd, images, read_files):
    content = []
    for label, path in images:
        content.append({"type": "text", "text": label})
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64(path)}"}})
    content.append({"type": "text", "text": prompt})
    r = _http("https://api.openai.com/v1/chat/completions",
              {"model": model_of(cfg, provider), "max_completion_tokens": MAX_TOKENS,
               "messages": [{"role": "user", "content": content}]},
              {"authorization": f"Bearer {key_of(cfg, provider)}"})
    return (r.get("choices") or [{}])[0].get("message", {}).get("content") or ""


def _gemini(cfg, provider, prompt, cwd, images, read_files):
    parts = []
    for label, path in images:
        parts.append({"text": label})
        parts.append({"inline_data": {"mime_type": "image/jpeg", "data": b64(path)}})
    parts.append({"text": prompt})
    key = key_of(cfg, provider)
    first = model_of(cfg, provider).removeprefix("models/")
    body = {"contents": [{"role": "user", "parts": parts}], "generationConfig": {"maxOutputTokens": MAX_TOKENS}}
    r = None
    for model in [first] + _gemini_fallbacks(key, first):
        try:
            r = _http(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
                      body, {"x-goog-api-key": key})
            break
        except Busy:
            continue  # this model is overloaded; try the next one the key can use
    if r is None:
        raise AIError("Gemini is busy right now (all models tried). Use Retry last lesson in a few minutes.")
    cands = r.get("candidates") or []
    if not cands:
        raise AIError("Gemini returned no answer: " + json.dumps(r.get("promptFeedback", {}))[:200])
    return "".join(p.get("text", "") for p in cands[0].get("content", {}).get("parts", []))


def _gemini_fallbacks(key, current, limit=2):
    """Other Flash models this key can use, newest first, for when the chosen one is overloaded."""
    try:
        names = list_models("gemini", key)
    except AIError:
        return []
    flash = [n for n in names if "flash" in n and n != current and "image" not in n and "tts" not in n and "live" not in n]
    return sorted(flash, reverse=True)[:limit]


def _ollama(cfg, provider, prompt, cwd, images, read_files):
    model = model_of(cfg, provider)
    if not model:
        raise AIError("Pick a local model in Settings.")
    msg = {"role": "user", "content": prompt}
    if images:
        msg["images"] = [b64(p) for _, p in images[:8]]  # local models handle few images
    url = cfg.get("ollama_url", "http://localhost:11434").rstrip("/") + "/api/chat"
    body = {"model": model, "messages": [msg], "stream": False, "options": {"num_ctx": 32768}}
    try:
        r = _http(url, body, {})
    except AIError:
        if not images:
            raise
        msg.pop("images")  # the model may not read images; try with text only
        r = _http(url, body, {})
    return r.get("message", {}).get("content", "")


# ----- model lists for Settings -----

def _get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def list_models(provider, key="", ollama_url="http://localhost:11434"):
    """Model ids this account can use, newest providers' naming as returned. Raises AIError."""
    try:
        if provider == "anthropic":
            import anthropic
            return [m.id for m in anthropic.Anthropic(api_key=key).models.list(limit=100)]
        if provider == "openai":
            data = _get("https://api.openai.com/v1/models", {"authorization": f"Bearer {key}"})["data"]
            ids = [m["id"] for m in data if m["id"].startswith(("gpt-", "o", "chatgpt"))]
            return sorted(ids, reverse=True)
        if provider == "gemini":
            data = _get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", {"x-goog-api-key": key})
            return [m["name"].removeprefix("models/") for m in data.get("models", [])
                    if "generateContent" in m.get("supportedGenerationMethods", []) and "gemini" in m["name"]]
        if provider == "ollama":
            data = _get(ollama_url.rstrip("/") + "/api/tags", {})
            return [m["name"] for m in data.get("models", [])]
    except urllib.error.HTTPError as e:
        raise AIError("The API key was not accepted." if e.code in (401, 403) else f"Error {e.code} listing models.")
    except urllib.error.URLError:
        raise AIError("Ollama is not running." if provider == "ollama" else "Could not reach the service.")
    except Exception as e:  # noqa: BLE001 - SDK errors (bad key, network) shown in Settings
        raise AIError(str(e)[:200])
    return []
