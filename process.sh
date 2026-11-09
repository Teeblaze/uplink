#!/bin/zsh
# Runs after a lesson stops: transcribe on this Mac, then the chosen AI writes and files the notes.
# Usage: process.sh <session_dir>
S="$1"
T="$(dirname "$0")"
PY="${UPLINK_PYTHON:-$T/.venv/bin/python}"
{
  echo "== $(date) transcribing"
  "$PY" -I "$T/transcribe.py" "$S" || { echo "ERROR|Transcription failed. See process.log." > "$S/result.txt"; exit 1; }
  echo "== $(date) writing notes"
  "$PY" -I "$T/make_notes.py" "$S"
  echo "== $(date) done"
} >> "$S/process.log" 2>&1
