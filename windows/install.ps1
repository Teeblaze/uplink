# Uplink for Windows 10/11: installer.
#   From GitHub (PowerShell):  irm https://raw.githubusercontent.com/Teeblaze/uplink/main/windows/install.ps1 | iex
#   From a copy:               powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
$ErrorActionPreference = "Stop"
$Here = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { "" }
if (-not $Here -or -not (Test-Path (Join-Path $Here "uplink_win.py"))) {
  $Dir = Join-Path $env:USERPROFILE "uplink"
  Write-Host "Downloading Uplink to $Dir ..."
  $Zip = Join-Path $env:TEMP "uplink.zip"
  Invoke-WebRequest "https://codeload.github.com/Teeblaze/uplink/zip/refs/heads/main" -OutFile $Zip
  Expand-Archive $Zip -DestinationPath $env:TEMP -Force
  New-Item -ItemType Directory -Force $Dir | Out-Null
  Copy-Item (Join-Path $env:TEMP "uplink-main\*") $Dir -Recurse -Force
  $Here = Join-Path $Dir "windows"
}
$Venv = Join-Path $env:LOCALAPPDATA "Uplink\venv"

Write-Host "1/5 Checking Python 3.12..."
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) { throw "Python is not installed. Install Python 3.12 from python.org (tick 'Add to PATH'), then run this again." }
& py -3.12 --version
if ($LASTEXITCODE -ne 0) { throw "Python 3.12 is required (newer versions lack speech-to-text packages). Install it from python.org, then run this again." }

Write-Host "2/5 Checking for AI apps (optional)..."
foreach ($app in "claude","codex","gemini") {
  if (Get-Command $app -ErrorAction SilentlyContinue) { Write-Host "   Found $app" }
}
Write-Host "   Uplink works with Claude Code, Codex, Gemini CLI, an API key (Claude, OpenAI, Gemini) or Ollama."
Write-Host "   You pick one in Settings when Uplink first starts."

Write-Host "3/5 Creating the Python environment..."
if (-not (Test-Path $Venv)) { & py -3.12 -m venv $Venv }
& "$Venv\Scripts\python.exe" -m pip install --upgrade pip | Out-Null
& "$Venv\Scripts\python.exe" -m pip install -r (Join-Path $Here "requirements.txt")

Write-Host "4/5 Downloading the speech-to-text model (about 500 MB, once)..."
& "$Venv\Scripts\python.exe" -c "from faster_whisper import WhisperModel; WhisperModel('small.en', device='cpu', compute_type='int8')"

Write-Host "5/5 Starting Uplink at sign-in..."
$Startup = [Environment]::GetFolderPath("Startup")
$Shell = New-Object -ComObject WScript.Shell
$Link = $Shell.CreateShortcut((Join-Path $Startup "Uplink.lnk"))
$Link.TargetPath = "$Venv\Scripts\pythonw.exe"
$Link.Arguments = "`"$(Join-Path $Here 'uplink_win.py')`""
$Link.WorkingDirectory = $Here
$Link.Save()
Start-Process "$Venv\Scripts\pythonw.exe" -ArgumentList "`"$(Join-Path $Here 'uplink_win.py')`""

Write-Host ""
Write-Host "Uplink is running in the tray (bottom right; check the ^ arrow)."
Write-Host "Ctrl+Alt+N: start or stop a lesson.  Hold Ctrl+Alt+M: add a spoken note."
Write-Host "Settings opens in your browser on first start: pick your AI, the notes folder and your agents."
