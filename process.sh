#!/bin/zsh
# Runs after a lesson stops (or on Retry): transcribe on this computer, then the chosen AI writes and files the notes.
# A retry reuses the transcript when it already exists, so only the failed step runs again.
# Usage: process.sh <session_dir>
S="$1"
T="$(dirname "$0")"
PY="${UPLINK_PYTHON:-$T/.venv/bin/python}"
rm -f "$S/result.txt"
{
  if [ -s "$S/transcript.md" ]; then
    echo "== $(date) transcript already made, reusing it"
  else
    echo "== $(date) transcribing"
    "$PY" -I "$T/transcribe.py" "$S" || { echo "ERROR|Transcription failed. See process.log." > "$S/result.txt"; exit 1; }
  fi
  echo "== $(date) writing notes"
  "$PY" -I "$T/make_notes.py" "$S"
  echo "== $(date) done"
} >> "$S/process.log" 2>&1
