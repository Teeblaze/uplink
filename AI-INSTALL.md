# Installing Uplink (instructions for the AI doing the install)

You are installing Uplink for the person you are working with. Uplink is a menu-bar (Mac) or tray (Windows) app that records a lesson they watch, transcribes it on their computer, and has their AI write notes and send them to their agents. Follow these steps in order. Explain each step to the person in one plain sentence before you run it.

## 1. Check the computer
- Mac: macOS 14 or newer (`sw_vers -productVersion`).
- Windows: Windows 10 or 11.
- Anything else: stop and say Uplink supports only Mac and Windows.

## 2. Run the installer
- **Mac:** `curl -fsSL https://raw.githubusercontent.com/Teeblaze/uplink/main/install.sh | bash`
- **Windows (PowerShell):** `irm https://raw.githubusercontent.com/Teeblaze/uplink/main/windows/install.ps1 | iex`

It takes about 5 minutes (it downloads a 500 MB speech model once). Let it finish.

If it stops:
- "Command Line Tools" (Mac): a macOS window has opened. Ask the person to click Install, wait for it to finish, then run the installer again.
- "Python 3.12": on Mac with Homebrew the installer installs it itself. Otherwise ask the person to install Python 3.12 from https://www.python.org/downloads/ (on Windows, tick "Add python.exe to PATH"), then run the installer again.
- Anything that asks for a password: stop and ask the person to type it themselves. Never type a password.

## 3. Permissions (Mac)
Tell the person to click Allow when macOS asks for:
- **Screen Recording** (Uplink hears and sees the lesson through it). After allowing it, they must quit Uplink from the menu bar and open it again from `~/Applications/Uplink.app`.
- **Microphone** (for spoken notes).
- **Notifications** (to say when notes are ready).

## 4. Settings
Settings opens in the browser by itself. Help the person choose:
- **Your AI:** pick the AI they use for this install. If you are Claude Code, pick "Claude (Claude Code app)"; Codex, pick "ChatGPT (Codex app)"; Gemini CLI, pick "Gemini (Gemini CLI)". These use their existing sign-in, so no key is needed. If they want an API key instead, they paste it into the page themselves.
- **Who learns from your notes:** Uplink lists their agents and skills. Ask which ones should learn from the courses they watch. If they have none, leave everything unticked and notes are filed by topic.
- **Tell your AI about the library:** tick the app you are running in.
- Press **Test**, then **Save**.

## 5. Show them how to use it
- Mac: **Ctrl+Option+N** starts and stops a lesson; hold **Ctrl+Option+M** to add a spoken note.
- Windows: **Ctrl+Alt+N** and hold **Ctrl+Alt+M**.
- Notes arrive a minute or two after they stop. The notification opens them.
- Suggest a 2-minute test: play any YouTube tutorial, press the shortcut, stop it, and open the notes together.

## Rules
- Do not edit the person's agent or instruction files yourself; Settings does it, only for what they tick.
- Do not upload their notes or settings anywhere.
