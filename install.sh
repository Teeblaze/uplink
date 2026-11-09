#!/bin/bash
# Uplink installer for macOS 14+.
#   From GitHub:  curl -fsSL https://raw.githubusercontent.com/Teeblaze/uplink/main/install.sh | bash
#   From a copy:  ./install.sh
# Installs the code in ~/uplink (or runs from this folder), a Python environment in .venv,
# the speech-to-text model, and Uplink.app in ~/Applications. Settings, notes and keys are kept on reinstall.
set -e
REPO="https://codeload.github.com/Teeblaze/uplink/zip/refs/heads/main"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -f "$HERE/Uplink.swift" ]; then
  DIR="$HERE"
else
  DIR="$HOME/uplink"
  say "1/6 Downloading Uplink to $DIR"
  TMP="$(mktemp -d)"
  curl -fsSL "$REPO" -o "$TMP/uplink.zip"
  unzip -q "$TMP/uplink.zip" -d "$TMP"
  mkdir -p "$DIR"
  rsync -a --exclude .venv "$TMP"/uplink-main/ "$DIR"/
  rm -rf "$TMP"
fi
cd "$DIR"

say "2/6 Checking the Mac developer tools (to build the app on this Mac)"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  echo "A window asked to install the Command Line Tools. Install them, then run this installer again."
  exit 1
fi

say "3/6 Checking Python 3.12"
PY312="$(command -v python3.12 || true)"
if [ -z "$PY312" ] && command -v brew >/dev/null; then
  brew install python@3.12
  PY312="$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)"
fi
if [ -z "$PY312" ] || [ ! -x "$PY312" ]; then
  echo "Python 3.12 is needed (newer versions lack the speech-to-text package)."
  echo "Install it from https://www.python.org/downloads/ (3.12.x), then run this installer again."
  exit 1
fi

say "4/6 Setting up Uplink's Python environment"
[ -x .venv/bin/python ] || "$PY312" -m venv .venv
.venv/bin/python -m pip install -q --upgrade pip
.venv/bin/python -m pip install -q -r requirements.txt

say "5/6 Downloading the speech-to-text model (about 500 MB, once)"
.venv/bin/python -c "from faster_whisper import WhisperModel; WhisperModel('small.en', device='cpu', compute_type='int8')"

say "6/6 Building Uplink.app"
./build.sh
open "$HOME/Applications/Uplink.app"

say "Uplink is running in the menu bar."
cat <<'EOF'
- Settings opens in your browser on first start: pick your AI, your notes folder and your agents.
- Allow Screen Recording (to hear and see the lesson), Microphone (spoken notes) and Notifications when macOS asks.
  Screen Recording needs Uplink to restart: quit it from the menu bar and open it again from ~/Applications.
- Ctrl+Option+N: start or stop a lesson.  Hold Ctrl+Option+M: add a spoken note.
EOF
