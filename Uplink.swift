// Uplink: menu-bar course note taker. What you learn is sent up to your AI and your agents.
// Ctrl+Option+N starts or stops a lesson (records the Mac's sound).
// Hold Ctrl+Option+M to add a spoken note (records the microphone).
// On stop, process.sh transcribes the lesson and the AI picked in Settings writes and files the notes.

import AppKit
import AVFoundation
import CoreImage
import ImageIO
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import UserNotifications

/// The Uplink folder (scripts and .venv). build.sh writes it into Info.plist as UplinkHome.
let toolDir = Bundle.main.object(forInfoDictionaryKey: "UplinkHome") as? String
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("uplink").path
let pythonPath = ProcessInfo.processInfo.environment["UPLINK_PYTHON"] ?? "\(toolDir)/.venv/bin/python"
/// Apps opened from Finder get a bare PATH; add the usual places AI command-line tools live.
let searchPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", ProcessInfo.processInfo.environment["PATH"] ?? ""].joined(separator: ":")
}()
let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Uplink/config.json")

/// Uplink's mark for the menu bar (one colour; macOS tints it for light and dark).
let uplinkGlyph: NSImage? = {
    guard let img = Bundle.main.image(forResource: "glyph") else { return nil }
    img.size = NSSize(width: 18, height: 18)
    img.isTemplate = true
    img.accessibilityDescription = "Uplink"
    return img
}()

/// Settings written by settings.py (nt_config.py): the library folder and the chosen AI.
func readConfig() -> [String: Any] {
    guard let data = try? Data(contentsOf: configURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}
var learningDir: String {
    (readConfig()["library"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Uplink Library").path
}
var isConfigured: Bool { !((readConfig()["provider"] as? String) ?? "").isEmpty }
let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Uplink/sessions")

// MARK: - System audio recorder (ScreenCaptureKit)

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let url: URL
    private let shotsDir: URL?
    private let queue = DispatchQueue(label: "uplink.audio")
    private(set) var framesWritten: AVAudioFramePosition = 0

    // Smart screenshots: keep a frame when the screen changed and has settled.
    // Saves more often when the lesson is quiet (a silent demo).
    private let began = Date()
    private let ci = CIContext()
    private var prevSig: [UInt8]?
    private var keptSig: [UInt8]?
    private var lastShot: Double = -100
    private var lastLoud: Double = 0
    private var shotCount = 0
    private let maxShots = 120

    init(url: URL, shotsDir: URL?) {
        self.url = url
        self.shotsDir = shotsDir
    }

    /// Records only the sound of the app the lesson plays in (pid), or all sound if that app is not found.
    func start(pid: pid_t?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "Uplink", code: 1) }
        let filter: SCContentFilter
        if let pid, pid != ProcessInfo.processInfo.processIdentifier,
           let app = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        if shotsDir != nil {
            // One frame every 2 seconds, at most 1440 pixels wide.
            let w = min(Double(display.width) * 2, 1440)
            cfg.width = Int(w)
            cfg.height = Int(w * Double(display.height) / Double(display.width))
            cfg.minimumFrameInterval = CMTime(value: 2, timescale: 1)
            cfg.showsCursor = true
        } else {
            // Video is required by the API; keep it tiny and slow.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync { file = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if type == .screen { handleFrame(sb); return }
        guard type == .audio,
              let desc = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        try? file?.write(from: pcm)
        framesWritten += AVAudioFramePosition(frames)
        if let ch = pcm.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(frames) { sum += ch[i] * ch[i] }
            if (sum / Float(frames)).squareRoot() > 0.01 { lastLoud = Date().timeIntervalSince(began) }
        }
    }

    private func handleFrame(_ sb: CMSampleBuffer) {
        guard let dir = shotsDir, shotCount < maxShots,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pb)
        guard let sig = signature(image) else { return }
        defer { prevSig = sig }
        // Settled: the same as the last frame (2 seconds ago).
        guard let prev = prevSig, difference(sig, prev) < 0.012 else { return }
        // Changed: different from the last screenshot kept.
        if let kept = keptSig, difference(sig, kept) < 0.035 { return }
        let t = Date().timeIntervalSince(began)
        let quiet = t - lastLoud > 3
        guard t - lastShot >= (quiet ? 4 : 10) else { return }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let jpg = ci.jpegRepresentation(of: image, colorSpace: srgb,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else { return }
        try? jpg.write(to: dir.appendingPathComponent("\(Int(t)).jpg"))
        keptSig = sig
        lastShot = t
        shotCount += 1
    }

    /// 32x18 greyscale thumbnail, used to compare frames.
    private func signature(_ image: CIImage) -> [UInt8]? {
        let w = 32, h = 18
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        ci.render(small, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0..<(w * h)).map { i in UInt8((Int(rgba[i * 4]) + Int(rgba[i * 4 + 1]) + Int(rgba[i * 4 + 2])) / 3) }
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count * 255)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Uplink stream stopped: \(error)")
    }
}

// MARK: - Microphone note recorder (hold to talk)

final class MicNoteRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    func start(url: URL) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            try? self?.file?.write(from: buf)
        }
        do { try engine.start() } catch { NSLog("Uplink mic failed: \(error)") }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

// MARK: - Hotkeys (Carbon, no Accessibility permission needed)

final class HotKeys {
    var onToggle: () -> Void = {}
    var onNoteDown: () -> Void = {}
    var onNoteUp: () -> Void = {}
    private var refs: [EventHotKeyRef?] = []

    func register() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return noErr }
            let keys = Unmanaged<HotKeys>.fromOpaque(user).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                switch (hk.id, pressed) {
                case (1, true): keys.onToggle()
                case (2, true): keys.onNoteDown()
                case (2, false): keys.onNoteUp()
                default: break
                }
            }
            return noErr
        }, 2, &specs, me, nil)
        let mods = UInt32(controlKey | optionKey)
        let sig = OSType(0x4E544B52) // "NTKR"
        for (id, key) in [(UInt32(1), UInt32(kVK_ANSI_N)), (UInt32(2), UInt32(kVK_ANSI_M))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, mods, EventHotKeyID(signature: sig, id: id), GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeys()
    private var recorder: SystemAudioRecorder?
    private let mic = MicNoteRecorder()
    private var session: URL?
    private var startedAt: Date?
    private var noteStartedAt: Date?
    private var timer: Timer?
    private var processing = 0
    private var lastNotes: String?
    private var screenshotsOn: Bool {
        get { UserDefaults.standard.object(forKey: "screenshots") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "screenshots") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hotKeys.onToggle = { [weak self] in self?.toggle() }
        hotKeys.onNoteDown = { [weak self] in self?.noteDown() }
        hotKeys.onNoteUp = { [weak self] in self?.noteUp() }
        hotKeys.register()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        try? SMAppService.mainApp.register()
        refresh()
        if !isConfigured { openSettings() }
    }

    // MARK: Lesson

    private func toggle() { recorder == nil ? startLesson() : stopLesson() }

    private func startLesson() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = sessionsDir.appendingPathComponent(stamp)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("voice-notes"), withIntermediateDirectories: true)
        var shots: URL? = nil
        if screenshotsOn {
            shots = dir.appendingPathComponent("shots")
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        let rec = SystemAudioRecorder(url: dir.appendingPathComponent("system.caf"), shotsDir: shots)
        let front = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let title = await self.frontWindowTitle(pid: front?.processIdentifier) ?? front?.localizedName ?? "Lesson"
            do {
                try await rec.start(pid: front?.processIdentifier)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                self.notify("Could not start recording", "Allow Uplink in System Settings > Privacy & Security > Screen & System Audio Recording, then try again.", path: nil)
                return
            }
            let meta: [String: Any] = ["title": title, "app": front?.localizedName ?? "",
                                       "started": ISO8601DateFormatter().string(from: Date())]
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
                try? data.write(to: dir.appendingPathComponent("meta.json"))
            }
            self.recorder = rec
            self.session = dir
            self.startedAt = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            self.refresh()
            self.notify("Recording lesson", title, path: nil)
        }
    }

    private func stopLesson() {
        guard let rec = recorder, let dir = session else { return }
        if noteStartedAt != nil { noteUp() }
        recorder = nil
        timer?.invalidate()
        timer = nil
        Task { @MainActor in
            await rec.stop()
            self.session = nil
            self.startedAt = nil
            self.process(dir)
        }
    }

    // MARK: Spoken notes

    private func noteDown() {
        guard let dir = session, let start = startedAt, noteStartedAt == nil else { return }
        let offset = Int(Date().timeIntervalSince(start))
        noteStartedAt = Date()
        mic.start(url: dir.appendingPathComponent("voice-notes/\(offset).caf"))
        refresh()
    }

    private func noteUp() {
        guard noteStartedAt != nil else { return }
        mic.stop()
        noteStartedAt = nil
        refresh()
    }

    // MARK: Processing

    private func process(_ dir: URL) {
        processing += 1
        refresh()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["\(toolDir)/process.sh", dir.path]
        var env = ProcessInfo.processInfo.environment
        env["UPLINK_PYTHON"] = pythonPath
        env["PATH"] = searchPath
        p.environment = env
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.processing -= 1
                let result = (try? String(contentsOf: dir.appendingPathComponent("result.txt"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let result, result.hasPrefix("OK|") {
                    let parts = result.split(separator: "|", maxSplits: 3).map(String.init)
                    self.lastNotes = parts.count > 1 ? parts[1] : nil
                    let title = parts.count > 2 ? parts[2] : "Lesson"
                    let agents = parts.count > 3 ? parts[3] : ""
                    self.notify("Notes saved: \(title)", agents.isEmpty ? "Saved to your notes library" : "For \(agents)", path: self.lastNotes)
                } else {
                    let why = result?.replacingOccurrences(of: "ERROR|", with: "") ?? "See process.log in the session folder."
                    self.notify("Notes failed", why, path: dir.appendingPathComponent("process.log").path)
                }
                self.refresh()
            }
        }
        do { try p.run() } catch {
            processing -= 1
            notify("Notes failed", "Could not start process.sh", path: nil)
        }
    }

    // MARK: Helpers

    private func frontWindowTitle(pid: pid_t?) async -> String? {
        guard let pid, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        return content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && !($0.title ?? "").isEmpty }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.title
    }

    private func notify(_ title: String, _ body: String, path: String?) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let path { c.userInfo = ["path": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        if let start = startedAt {
            let s = Int(Date().timeIntervalSince(start))
            button.image = NSImage(systemSymbolName: noteStartedAt != nil ? "mic.fill" : "record.circle.fill", accessibilityDescription: "Recording")
            button.title = String(format: " %d:%02d", s / 60, s % 60)
        } else {
            button.image = processing > 0
                ? NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Working")
                : (uplinkGlyph ?? NSImage(systemSymbolName: "note.text", accessibilityDescription: "Uplink"))
            button.title = processing > 0 ? " Working" : ""
        }
        let menu = NSMenu()
        menu.addItem(withTitle: startedAt == nil ? "Start lesson  (Ctrl+Option+N)" : "Stop lesson  (Ctrl+Option+N)",
                     action: #selector(menuToggle), keyEquivalent: "").target = self
        let hint = NSMenuItem(title: "Hold Ctrl+Option+M to add a spoken note", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if processing > 0 {
            let p = NSMenuItem(title: "Working on \(processing) job(s)...", action: nil, keyEquivalent: "")
            p.isEnabled = false
            menu.addItem(p)
        }
        menu.addItem(.separator())
        let last = NSMenuItem(title: "Open last notes", action: #selector(openLast), keyEquivalent: "")
        last.target = self
        last.isEnabled = lastNotes != nil
        menu.addItem(last)
        menu.addItem(withTitle: "Open notes library", action: #selector(openLibrary), keyEquivalent: "").target = self
        let shotsItem = NSMenuItem(title: "Take screenshots of the lesson", action: #selector(toggleShots), keyEquivalent: "")
        shotsItem.target = self
        shotsItem.state = screenshotsOn ? .on : .off
        menu.addItem(shotsItem)
        menu.addItem(withTitle: "Ask my library...", action: #selector(askLibrary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings (AI, library, agents)...", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Uplink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuToggle() { toggle() }
    @objc private func openLast() { if let p = lastNotes { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    @objc private func openLibrary() { NSWorkspace.shared.open(URL(fileURLWithPath: learningDir)) }
    @objc private func toggleShots() { screenshotsOn.toggle(); refresh() }

    // MARK: Settings

    /// Opens the settings page in the browser (settings.py serves it on this Mac only).
    @objc private func openSettings() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = ["-I", "\(toolDir)/settings.py"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        p.environment = env
        do { try p.run() } catch { notify("Settings did not open", "Could not start settings.py", path: nil) }
    }

    // MARK: Ask my library

    @objc private func askLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ask my library"
        alert.informativeText = "Answers come only from your course notes, with the lesson and timestamp for each point."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "What have I learned about pricing?"
        alert.accessoryView = field
        alert.addButton(withTitle: "Ask")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let question = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        processing += 1
        refresh()
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = ["-I", "\(toolDir)/ask.py", question]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        p.environment = env
        p.standardOutput = out
        p.terminationHandler = { [weak self] proc in
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.processing -= 1
                self.refresh()
                if proc.terminationStatus == 0, !path.isEmpty {
                    self.notify("Answer ready", question, path: path)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    self.notify("Could not answer", "Your AI did not return an answer. Check Settings and try again.", path: nil)
                }
            }
        }
        do { try p.run() } catch {
            processing -= 1
            refresh()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
