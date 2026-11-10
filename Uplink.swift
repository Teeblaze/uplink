// Uplink: menu-bar course note taker. What you learn is sent up to your AI and your agents.
// Shortcuts (set in Settings): start or stop a lesson (default Ctrl+Option+N), hold to add a spoken
// note (Ctrl+Option+M), hold to ask about your screen (Ctrl+Option+A).
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

// MARK: - Shortcuts (set in Settings; config.json "shortcuts")

struct Shortcut { let key: UInt32; let mods: UInt32; let label: String }

private let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
    "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "space": kVK_Space, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
]

/// "ctrl+option+n" -> key code, Carbon modifiers and a label like ⌃⌥N. Needs at least one modifier.
func parseShortcut(_ text: String) -> Shortcut? {
    var mods = 0, key: Int? = nil, symbols = "", name = ""
    for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch part {
        case "ctrl", "control": mods |= controlKey; symbols += "⌃"
        case "option", "alt", "opt": mods |= optionKey; symbols += "⌥"
        case "shift": mods |= shiftKey; symbols += "⇧"
        case "cmd", "command": mods |= cmdKey; symbols += "⌘"
        default:
            if let code = keyCodes[part] { key = code; name = part == "space" ? "Space" : part.uppercased() }
        }
    }
    guard let key, mods != 0 else { return nil }
    return Shortcut(key: UInt32(key), mods: UInt32(mods), label: symbols + name)
}

let defaultShortcuts = ["lesson": "ctrl+option+n", "note": "ctrl+option+m", "ask": "ctrl+option+a"]

func configuredShortcuts() -> [String: Shortcut] {
    let saved = readConfig()["shortcuts"] as? [String: String] ?? [:]
    var out: [String: Shortcut] = [:]
    for (name, fallback) in defaultShortcuts {
        out[name] = parseShortcut(saved[name] ?? fallback) ?? parseShortcut(fallback)
    }
    return out
}

// MARK: - Hotkeys (Carbon, no Accessibility permission needed)

final class HotKeys {
    var onToggle: () -> Void = {}
    var onNoteDown: () -> Void = {}
    var onNoteUp: () -> Void = {}
    var onAskDown: () -> Void = {}
    var onAskUp: () -> Void = {}
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    /// Registers lesson (id 1), spoken note (id 2) and ask (id 3); call again after Settings change them.
    func register(_ keys: [String: Shortcut]) {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if !installed { installHandler(); installed = true }
        let sig = OSType(0x4E544B52) // "NTKR"
        for (id, name) in [(UInt32(1), "lesson"), (UInt32(2), "note"), (UInt32(3), "ask")] {
            guard let k = keys[name] else { continue }
            var ref: EventHotKeyRef?
            RegisterEventHotKey(k.key, k.mods, EventHotKeyID(signature: sig, id: id), GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    private func installHandler() {
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
                case (3, true): keys.onAskDown()
                case (3, false): keys.onAskUp()
                default: break
                }
            }
            return noErr
        }, 2, &specs, me, nil)
    }
}

// MARK: - Answer card, highlight ring and gliding pointer (Ask the lesson)

/// Settings choice for marking the spot: "ring" (still, default) or "pointer" (glides like Clicky's buddy).
var markStyle: String { (readConfig()["mark_style"] as? String) == "pointer" ? "pointer" : "ring" }

/// A lime arrow drawn over the screen that glides from beside the real cursor to the spot.
/// It is only a drawing: the real mouse never moves.
final class GlidingPointer {
    private var window: NSWindow?

    func glide(toCGPoint p: CGPoint, seconds: TimeInterval = 5) {
        window?.orderOut(nil)
        guard let primary = NSScreen.screens.first else { return }
        let size: CGFloat = 34
        let target = NSPoint(x: p.x, y: primary.frame.height - p.y)            // CG (top-left) to AppKit
        let start = NSEvent.mouseLocation                                        // beside the real cursor
        let frameAt = { (pt: NSPoint) in NSRect(x: pt.x + 6, y: pt.y - size - 6, width: size, height: size) }
        let w = NSWindow(contentRect: frameAt(start), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        let arrow = CAShapeLayer()                                              // tip at top-left
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3, y: size - 3))
        path.addLine(to: CGPoint(x: size - 6, y: size * 0.42))
        path.addLine(to: CGPoint(x: size * 0.45, y: size * 0.36))
        path.addLine(to: CGPoint(x: size * 0.30, y: 4))
        path.closeSubpath()
        arrow.path = path
        arrow.fillColor = NSColor(red: 0.863, green: 1.0, blue: 0.180, alpha: 1).cgColor
        arrow.strokeColor = NSColor(red: 0.086, green: 0.094, blue: 0.090, alpha: 1).cgColor
        arrow.lineWidth = 2
        arrow.lineJoin = .round
        view.layer?.addSublayer(arrow)
        w.contentView = view
        w.orderFrontRegardless()
        window = w
        // Tip sits on the spot: shift so the arrow's top-left tip lands on the target.
        let end = NSRect(x: target.x - 3, y: target.y - size + 3, width: size, height: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.7
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(end, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak w] in
            guard let w else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 },
                                                 completionHandler: { w.orderOut(nil); if self?.window === w { self?.window = nil } })
        }
    }
}

/// A small card at the top centre of the screen: "Listening", "Thinking", then the answer.
/// Temporary look until the island design is approved; it never takes keyboard focus.
final class AnswerCard {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(red: 0.086, green: 0.094, blue: 0.090, alpha: 0.97).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = NSColor(red: 0.863, green: 1.0, blue: 0.180, alpha: 1) // lime
        body.font = .systemFont(ofSize: 14)
        body.textColor = NSColor(red: 0.925, green: 0.933, blue: 0.914, alpha: 1)
        body.maximumNumberOfLines = 6
        for v in [title, body] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            body.widthAnchor.constraint(equalToConstant: 404),
        ])
        panel.contentView = box
    }

    func show(_ heading: String, _ text: String, hideAfter: TimeInterval? = nil) {
        hideWork?.cancel()
        title.stringValue = heading.uppercased()
        body.stringValue = text
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 440, height: 90)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 10,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        if let hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }
}

/// A still lime ring drawn over the spot the answer refers to. It never moves the mouse.
final class HighlightRing {
    private var window: NSWindow?

    func show(atCGPoint p: CGPoint, seconds: TimeInterval = 5) {
        window?.orderOut(nil)
        guard let primary = NSScreen.screens.first else { return }
        let size: CGFloat = 76
        let origin = NSPoint(x: p.x - size / 2, y: primary.frame.height - p.y - size / 2) // CG (top-left) to AppKit
        let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let ring = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        ring.wantsLayer = true
        let shape = CAShapeLayer()
        shape.path = CGPath(ellipseIn: CGRect(x: 6, y: 6, width: size - 12, height: size - 12), transform: nil)
        shape.fillColor = .clear
        shape.strokeColor = NSColor(red: 0.863, green: 1.0, blue: 0.180, alpha: 1).cgColor
        shape.lineWidth = 4
        ring.layer?.addSublayer(shape)
        w.contentView = ring
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak w] in
            guard let w else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 },
                                                 completionHandler: { w.orderOut(nil); if self?.window === w { self?.window = nil } })
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeys()
    private var recorder: SystemAudioRecorder?
    private let mic = MicNoteRecorder()
    private let askMic = MicNoteRecorder()
    private let speech = AVSpeechSynthesizer()
    private let card = AnswerCard()
    private let ring = HighlightRing()
    private let pointer = GlidingPointer()
    private var askDir: URL?
    private var askStarted: Date?
    private var shortcuts = configuredShortcuts()
    private var configStamp: Date?
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
        hotKeys.onAskDown = { [weak self] in self?.askDown() }
        hotKeys.onAskUp = { [weak self] in self?.askUp() }
        hotKeys.register(shortcuts)
        configStamp = configModified()
        // Settings is a web page; pick up new shortcuts a moment after it saves.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reloadIfConfigChanged() }
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

    // MARK: Ask the lesson (idea from Clicky, github.com/farzaa/clicky, MIT)

    private func configModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    }

    private func reloadIfConfigChanged() {
        let stamp = configModified()
        guard stamp != configStamp else { return }
        configStamp = stamp
        shortcuts = configuredShortcuts()
        hotKeys.register(shortcuts)
        refresh()
    }

    private func label(_ name: String) -> String { shortcuts[name]?.label ?? "" }

    private func askDown() {
        guard askDir == nil, noteStartedAt == nil else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = sessionsDir.deletingLastPathComponent().appendingPathComponent("asks/\(stamp)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        askDir = dir
        askStarted = Date()
        speech.stopSpeaking(at: .immediate)
        card.show("Listening", "Ask about your screen. Let go of \(label("ask")) when you finish.")
        askMic.start(url: dir.appendingPathComponent("question.caf"))
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { @MainActor in await self.captureWindow(pid: pid, into: dir) }
    }

    private func askUp() {
        guard let dir = askDir, let started = askStarted else { return }
        askMic.stop()
        askDir = nil
        askStarted = nil
        guard Date().timeIntervalSince(started) > 0.7 else { card.hide(); return }
        card.show("Thinking", "Looking at your screen...")
        let lessonOffset = startedAt.map { Int(started.timeIntervalSince($0)) }
        let lessonDir = session
        processing += 1
        refresh()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = ["-I", "\(toolDir)/ask_screen.py", dir.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        p.environment = env
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.processing -= 1
                self?.showAnswer(dir: dir, lessonDir: lessonDir, offset: lessonOffset)
                self?.refresh()
            }
        }
        do { try p.run() } catch {
            processing -= 1
            card.show("Could not answer", "Uplink could not start its helper.", hideAfter: 6)
        }
    }

    /// Screenshot of the front window at the moment the question starts, plus where that window sits.
    private func captureWindow(pid: pid_t?, into dir: URL) async {
        guard let pid, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let win = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let config = SCStreamConfiguration()
        let scale = min(2.0, 1600.0 / max(win.frame.width, 1))
        config.width = Int(win.frame.width * scale)
        config.height = Int(win.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win),
                                                                      configuration: config) else { return }
        let url = dir.appendingPathComponent("shot.jpg") as CFURL
        if let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        let frame = ["x": win.frame.minX, "y": win.frame.minY, "w": win.frame.width, "h": win.frame.height]
        if let data = try? JSONSerialization.data(withJSONObject: frame) {
            try? data.write(to: dir.appendingPathComponent("window.json"))
        }
    }

    private func showAnswer(dir: URL, lessonDir: URL?, offset: Int?) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("answer.json")),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            card.show("Could not answer", "No answer came back. Check Settings and try again.", hideAfter: 6)
            return
        }
        if let error = result["error"] as? String {
            card.show("Could not answer", error, hideAfter: 7)
            return
        }
        let question = result["question"] as? String ?? ""
        let answer = result["answer"] as? String ?? ""
        let words = answer.split(separator: " ").count
        card.show(question.isEmpty ? "Answer" : question, answer, hideAfter: max(7, Double(words) * 0.45 + 3))
        speech.speak(AVSpeechUtterance(string: answer))
        if let point = result["point"] as? [String: Double],
           let fdata = try? Data(contentsOf: dir.appendingPathComponent("window.json")),
           let f = try? JSONSerialization.jsonObject(with: fdata) as? [String: Double],
           let x = point["x"], let y = point["y"], let fx = f["x"], let fy = f["y"], let fw = f["w"], let fh = f["h"] {
            let spot = CGPoint(x: fx + x * fw, y: fy + y * fh)
            if markStyle == "pointer" { pointer.glide(toCGPoint: spot) } else { ring.show(atCGPoint: spot) }
        }
        // During a lesson the question, answer and screenshot become part of that lesson's notes.
        if let lessonDir, let offset {
            let shot = dir.appendingPathComponent("shot.jpg")
            let shots = lessonDir.appendingPathComponent("shots")
            if FileManager.default.fileExists(atPath: shot.path) {
                try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: shot, to: shots.appendingPathComponent("\(offset).jpg"))
            }
            let line: [String: Any] = ["t": offset, "question": question, "answer": answer]
            if let json = try? JSONSerialization.data(withJSONObject: line),
               let handle = FileHandle(forWritingAtPath: lessonDir.appendingPathComponent("asks.jsonl").path)
                ?? { FileManager.default.createFile(atPath: lessonDir.appendingPathComponent("asks.jsonl").path, contents: nil)
                     return FileHandle(forWritingAtPath: lessonDir.appendingPathComponent("asks.jsonl").path) }() {
                handle.seekToEndOfFile()
                handle.write(json + Data("\n".utf8))
                try? handle.close()
            }
        }
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
        menu.addItem(withTitle: (startedAt == nil ? "Start lesson  " : "Stop lesson  ") + label("lesson"),
                     action: #selector(menuToggle), keyEquivalent: "").target = self
        for text in ["Hold \(label("note")) to add a spoken note", "Hold \(label("ask")) to ask about your screen"] {
            let hint = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
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
        menu.addItem(withTitle: "Settings (AI, shortcuts, agents)...", action: #selector(openSettings), keyEquivalent: ",").target = self
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
