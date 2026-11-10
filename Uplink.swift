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
import SwiftUI
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
    /// Latest loudness (RMS), read by the island's foot line.
    private(set) var level: Float = 0

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
            let rms = (sum / Float(frames)).squareRoot()
            level = rms
            if rms > 0.01 { lastLoud = Date().timeIntervalSince(began) }
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
        arrow.fillColor = Grids.limeNS.cgColor
        arrow.strokeColor = Grids.inkNS.cgColor
        arrow.lineWidth = 2
        arrow.lineJoin = .round
        view.layer?.addSublayer(arrow)
        w.contentView = view
        w.orderFrontRegardless()
        window = w
        // Tip sits on the spot: shift so the arrow's top-left tip lands on the target.
        let end = NSRect(x: target.x - 3, y: target.y - size + 3, width: size, height: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Grids.reduceMotion ? 0.01 : 0.75
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
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
        let origin = NSPoint(x: p.x - size / 2, y: primary.frame.height - p.y - size / 2 - 7) // CG (top-left) to AppKit
        let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let ring = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        ring.wantsLayer = true
        // Grids lime, 1 pt ink keyline inside and outside so it shows on light and dark screens; short stem on top.
        let box = CGRect(x: 10, y: 10, width: size - 20, height: size - 34)
        let path = CGMutablePath()
        path.addRoundedRect(in: box, cornerWidth: 7, cornerHeight: 7)
        path.move(to: CGPoint(x: box.midX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.midX, y: box.maxY + 12.5))
        for (color, width) in [(Grids.inkNS, 3.5), (Grids.limeNS, 1.5)] {
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = .clear
            shape.strokeColor = color.cgColor
            shape.lineWidth = width
            ring.layer?.addSublayer(shape)
        }
        ring.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; ring.animator().alphaValue = 1 }
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
    private let island = Island()
    private let stickers = StickerShow()
    private var lastShotCount = 0
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
        setUpIsland()
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
                self.showError("Screen recording blocked", "Allow Uplink in System Settings, then try again.",
                               fix: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
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
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            self.island.model.marks = []
            self.island.model.notes = 0
            self.island.model.shots = 0
            self.lastShotCount = 0
            self.island.set(.recording)
            self.stickers.show("lesson-started", beside: self.island.anchor)
            self.refresh()
        }
    }

    private func stopLesson() {
        guard let rec = recorder, let dir = session else { return }
        if noteStartedAt != nil { noteUp() }
        recorder = nil
        timer?.invalidate()
        timer = nil
        island.model.hovering = false
        island.model.step = 1
        island.set(.processing)
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
        island.model.noteSeconds = 0
        island.set(.note)
        refresh()
    }

    private func noteUp() {
        guard noteStartedAt != nil else { return }
        mic.stop()
        if let start = startedAt, let began = noteStartedAt {
            island.model.marks.append(TimelineMark(t: Int(began.timeIntervalSince(start)), isNote: true))
        }
        noteStartedAt = nil
        island.model.notes += 1
        island.set(.recording)
        stickers.show("note-saved", beside: island.anchor)
        refresh()
    }

    // MARK: Island

    private var fixTarget: String?

    private func setUpIsland() {
        let m = island.model
        m.keys = shortcuts.mapValues { $0.label }
        m.onStop = { [weak self] in self?.stopLesson() }
        m.onOpenFolder = { [weak self] in
            if let dir = self?.session { NSWorkspace.shared.open(dir) }
        }
        m.onOpenNotes = { [weak self] in
            if let p = self?.lastNotes { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
            self?.island.settle()
        }
        m.onFix = { [weak self] in
            if let t = self?.fixTarget {
                NSWorkspace.shared.open(t.hasPrefix("/") ? URL(fileURLWithPath: t) : URL(string: t)!)
            }
            self?.island.settle()
        }
        m.onDismiss = { [weak self] in self?.island.settle() }
        island.isRecording = { [weak self] in self?.recorder != nil }
        stickers.enabled = { (readConfig()["stickers"] as? Bool) ?? true }
    }

    private func showError(_ title: String, _ line: String, fix: String? = nil) {
        fixTarget = fix
        island.model.errorTitle = title
        island.model.errorLine = line
        island.set(.error, autoHide: 9)
        stickers.show("oops", beside: island.anchor, minGap: 30)
    }

    /// Four times a second while recording: time, sound level, new screenshots, note timer.
    private func tick() {
        let m = island.model
        if let start = startedAt { m.elapsed = Int(Date().timeIntervalSince(start)) }
        if let rec = recorder { m.level = Double(rec.level) }
        if let began = noteStartedAt { m.noteSeconds = Int(Date().timeIntervalSince(began)) }
        if let shots = session?.appendingPathComponent("shots"),
           let files = try? FileManager.default.contentsOfDirectory(atPath: shots.path) {
            let jpgs = files.filter { $0.hasSuffix(".jpg") }
            if jpgs.count > lastShotCount {
                for f in jpgs { if let t = Int(f.dropLast(4)), !m.marks.contains(where: { !$0.isNote && $0.t == t }) {
                    m.marks.append(TimelineMark(t: t, isNote: false)) } }
                lastShotCount = jpgs.count
                m.shots = jpgs.count
                m.flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { m.flash = false }
                stickers.show("screenshot-caught", beside: island.anchor, minGap: 45)
            }
        }
        if Int(Date().timeIntervalSince1970 * 4) % 4 == 0 { refresh() }
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
        island.model.keys = shortcuts.mapValues { $0.label }
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
        island.set(.listening)
        askMic.start(url: dir.appendingPathComponent("question.caf"))
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { @MainActor in await self.captureWindow(pid: pid, into: dir) }
    }

    private func askUp() {
        guard let dir = askDir, let started = askStarted else { return }
        askMic.stop()
        askDir = nil
        askStarted = nil
        guard Date().timeIntervalSince(started) > 0.7 else { island.settle(); return }
        island.set(.thinking)
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
            showError("Could not answer", "Uplink could not start its helper.")
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
            showError("Could not answer", "No answer came back. Check Settings and try again.")
            return
        }
        if let error = result["error"] as? String {
            showError("Could not answer", error)
            return
        }
        let question = result["question"] as? String ?? ""
        let answer = result["answer"] as? String ?? ""
        let words = answer.split(separator: " ").count
        island.model.question = question
        island.model.answer = answer
        island.set(.answer, autoHide: min(20, max(8, Double(words) * 0.45 + 4)))
        stickers.show("question-answered", beside: island.anchor)
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
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, self.island.model.state == .processing else { t.invalidate(); return }
            let log = (try? String(contentsOf: dir.appendingPathComponent("process.log"), encoding: .utf8)) ?? ""
            self.island.model.step = log.contains("writing notes") ? 2 : 1
        }
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
                    self.island.model.sentTo = agents.isEmpty ? "Saved to your notes library" : "Sent to \(agents)"
                    self.island.set(.done, autoHide: 10)
                    self.stickers.show("notes-sent", beside: self.island.anchor)
                    let done = UserDefaults.standard.integer(forKey: "lessonsDone") + 1
                    UserDefaults.standard.set(done, forKey: "lessonsDone")
                    if done % 5 == 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { self.stickers.show("streak-5", beside: self.island.anchor) }
                    }
                } else {
                    let why = result?.replacingOccurrences(of: "ERROR|", with: "") ?? "See process.log in the session folder."
                    self.notify("Notes failed", why, path: dir.appendingPathComponent("process.log").path)
                    self.showError("Notes failed", why, fix: dir.appendingPathComponent("process.log").path)
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
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let live = Bundle.main.image(forResource: dark ? "glyph-live" : "glyph-live-light")
            live?.size = NSSize(width: 18, height: 18)
            button.image = noteStartedAt != nil ? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Note")
                : (live ?? NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording"))
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

// MARK: - Island (direction C "Drop", Grids colours)
// The notch grows straight down at notch width. One line at its foot does every job: lesson sound,
// then progress. Hover opens a panel; Ask opens an answer card. Lime = live, green = saved or finished,
// red = errors only. The real mouse never moves.

enum Grids {
    static let ink = Color(red: 0.031, green: 0.102, blue: 0.114)      // #081A1D
    static let lime = Color(red: 0.863, green: 1.0, blue: 0.180)       // #DCFF2E
    static let green = Color(red: 0.545, green: 1.0, blue: 0.459)      // #8BFF75
    static let paper = Color(red: 0.925, green: 0.922, blue: 0.902)    // #ECEBE6
    static let red = Color(red: 1.0, green: 0.420, blue: 0.341)        // #FF6B57
    static let limeNS = NSColor(red: 0.863, green: 1.0, blue: 0.180, alpha: 1)
    static let inkNS = NSColor(red: 0.031, green: 0.102, blue: 0.114, alpha: 1)

    /// Archivo Narrow SemiBold and IBM Plex when installed; the Mac's own fonts otherwise.
    static func caps(_ size: CGFloat) -> Font {
        NSFont(name: "ArchivoNarrow-SemiBold", size: size) != nil ? .custom("ArchivoNarrow-SemiBold", size: size)
            : .system(size: size, weight: .semibold).width(.condensed)
    }
    static func mono(_ size: CGFloat) -> Font {
        NSFont(name: "IBMPlexMono", size: size) != nil ? .custom("IBMPlexMono", size: size)
            : .system(size: size, weight: .regular, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "IBMPlexSans", size: size) != nil ? .custom("IBMPlexSans", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var cardSpring: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.92) }
}

enum IslandState: Equatable { case hidden, recording, note, listening, thinking, answer, processing, done, error }

struct TimelineMark: Identifiable { let id = UUID(); let t: Int; let isNote: Bool }

final class IslandModel: ObservableObject {
    @Published var state: IslandState = .hidden
    @Published var hovering = false
    @Published var elapsed = 0
    @Published var shots = 0
    @Published var notes = 0
    @Published var level: Double = 0
    @Published var flash = false
    @Published var noteSeconds = 0
    @Published var question = ""
    @Published var answer = ""
    @Published var step = 1
    @Published var sentTo = ""
    @Published var errorTitle = ""
    @Published var errorLine = ""
    @Published var marks: [TimelineMark] = []
    @Published var keys: [String: String] = [:]
    var notchWidth: CGFloat = 186
    var notchHeight: CGFloat = 32
    var onStop: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onOpenNotes: () -> Void = {}
    var onFix: () -> Void = {}
    var onDismiss: () -> Void = {}

    var expanded: Bool { state == .recording && hovering }

    /// Size of the island body under the notch band, per state.
    var size: CGSize {
        switch state {
        case .hidden: return .zero
        case .answer: return CGSize(width: 360, height: answerHeight)
        case .done, .error: return CGSize(width: 320, height: 64)
        default: return expanded ? CGSize(width: 340, height: 158) : CGSize(width: notchWidth, height: 30)
        }
    }

    private var answerHeight: CGFloat {
        let chars = answer.count + question.count / 2
        return CGFloat(min(220, max(96, 64 + (chars / 46 + 1) * 19)))
    }
}

struct IslandView: View {
    @ObservedObject var m: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.black).frame(height: m.notchHeight)
            ZStack(alignment: .bottom) {
                content
                    .padding(.horizontal, m.state == .answer || m.expanded || m.state == .done || m.state == .error ? 16 : 12)
                    .frame(width: m.size.width, height: m.size.height, alignment: .top)
                    .clipped()
                footLine
            }
            .frame(width: m.size.width, height: m.size.height)
            .background(Grids.ink)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .frame(width: max(m.size.width, m.notchWidth))
        .opacity(m.state == .hidden ? 0 : 1)
        .animation(Grids.cardSpring, value: m.state)
        .animation(Grids.cardSpring, value: m.expanded)
        .animation(Grids.cardSpring, value: m.answer)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // ----- the one line at the foot -----
    @ViewBuilder private var footLine: some View {
        switch m.state {
        case .recording where m.expanded: EmptyView()   // the timeline playhead is the live mark in the panel
        case .recording, .listening, .note:
            Capsule().fill(Grids.lime)
                .frame(width: max(10, m.size.width * 0.55 * CGFloat(min(1, m.level * 6))), height: 2)
                .animation(.easeOut(duration: 0.09), value: m.level)
                .padding(.bottom, 3)
        case .thinking:
            ThinkingLine().padding(.bottom, 3)
        case .processing:
            HStack(spacing: 0) {
                Rectangle().fill(Grids.green).frame(width: (m.size.width - 24) * CGFloat(m.step) / 3)
                Spacer(minLength: 0)
            }
            .frame(width: m.size.width - 24, height: 2)
            .animation(.easeInOut(duration: 0.4), value: m.step)
            .padding(.bottom, 3)
        case .error:
            Rectangle().fill(Grids.red).frame(height: 2)
        default: EmptyView()
        }
    }

    // ----- content per state -----
    @ViewBuilder private var content: some View {
        switch m.state {
        case .hidden: EmptyView()
        case .recording:
            if m.expanded { hoverPanel.transition(.opacity) } else { compactRecording }
        case .note:
            compact { Text("NOTE").font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.lime) }
                trailing: { Text(clock(m.noteSeconds)).font(Grids.mono(12)).foregroundStyle(Grids.paper) }
        case .listening:
            compact { Text("ASK").font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.lime) }
                trailing: { Text("listening").font(Grids.mono(12)).foregroundStyle(Grids.paper.opacity(0.75)) }
        case .thinking:
            compact { Text("ASK").font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.paper) }
                trailing: { Text("thinking").font(Grids.mono(12)).foregroundStyle(Grids.paper.opacity(0.75)) }
        case .processing:
            compact { Text("WRITING NOTES").font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.paper) }
                trailing: { Text("\(m.step)/3").font(Grids.mono(12)).foregroundStyle(Grids.paper.opacity(0.75)) }
        case .answer: answerCard.transition(.opacity)
        case .done: doneCard.transition(.opacity)
        case .error: errorCard.transition(.opacity)
        }
    }

    private func compact<L: View, T: View>(@ViewBuilder _ lead: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 8) { MarkGlyph().frame(width: 13, height: 11); lead(); Spacer(minLength: 4); trailing() }
            .frame(height: 24)
    }

    private var compactRecording: some View {
        compact { Text(clock(m.elapsed)).font(Grids.mono(12)).foregroundStyle(Grids.paper) }
            trailing: {
                HStack(spacing: 4) {
                    Image(systemName: "viewfinder").font(.system(size: 9, weight: .semibold))
                    Text(String(format: "%02d", m.shots)).font(Grids.mono(12))
                }
                .foregroundStyle(m.flash ? Grids.green : Grids.paper.opacity(0.8))
                .scaleEffect(m.flash && !Grids.reduceMotion ? 1.12 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: m.flash)
            }
    }

    private var hoverPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                cell("ELAPSED", clock(m.elapsed), Grids.paper)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 34)
                cell("SHOTS", String(format: "%02d", m.shots), Grids.paper)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 34)
                cell("NOTES", String(format: "%02d", m.notes), m.notes > 0 ? Grids.green : Grids.paper)
            }
            .padding(.top, 10)
            Text("LESSON SO FAR").font(Grids.caps(10)).tracking(0.6).foregroundStyle(Grids.paper.opacity(0.55))
            Timeline(marks: m.marks, elapsed: m.elapsed).frame(height: 14)
            HStack(spacing: 8) {
                Button(action: m.onStop) {
                    Text("Stop  \(m.keys["lesson"] ?? "")").font(Grids.sans(12, .semibold))
                        .foregroundStyle(Grids.ink).frame(maxWidth: .infinity, minHeight: 26)
                        .background(Grids.lime, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                Button(action: m.onOpenFolder) {
                    Text("Open folder").font(Grids.sans(12, .medium)).foregroundStyle(Grids.paper)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25)))
                }.buttonStyle(.plain)
            }
            Text("hold \(m.keys["note"] ?? "") note  ·  hold \(m.keys["ask"] ?? "") ask")
                .font(Grids.mono(10)).foregroundStyle(Grids.paper.opacity(0.5))
        }
    }

    private func cell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Grids.caps(10)).tracking(0.6).foregroundStyle(Grids.paper.opacity(0.55))
            Text(value).font(Grids.mono(20)).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ASK").font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.paper.opacity(0.6))
                Text(m.question).font(Grids.sans(12)).foregroundStyle(Grids.paper.opacity(0.7)).lineLimit(2)
            }
            Text(m.answer).font(Grids.sans(13)).lineSpacing(4).foregroundStyle(Grids.paper)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Text("click to close").font(Grids.mono(10)).foregroundStyle(Grids.paper.opacity(0.45)) }
        }
        .padding(.top, 12)
        .contentShape(Rectangle())
        .onTapGesture { m.onDismiss() }
    }

    private var doneCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NOTES READY").font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.green)
                Text(m.sentTo).font(Grids.sans(12)).foregroundStyle(Grids.paper.opacity(0.75)).lineLimit(1)
            }
            Spacer()
            Button(action: m.onOpenNotes) {
                Text("Open").font(Grids.sans(12, .semibold)).foregroundStyle(Grids.ink)
                    .padding(.horizontal, 14).frame(minHeight: 26)
                    .background(Grids.lime, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
        }
        .frame(height: 60)
    }

    private var errorCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.errorTitle.uppercased()).font(Grids.caps(11)).tracking(0.66).foregroundStyle(Grids.paper)
                Text(m.errorLine).font(Grids.sans(12)).foregroundStyle(Grids.paper.opacity(0.75)).lineLimit(2)
            }
            Spacer()
            Button(action: m.onFix) {
                Text("Fix").font(Grids.sans(12, .medium)).foregroundStyle(Grids.paper)
                    .padding(.horizontal, 14).frame(minHeight: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.3)))
            }.buttonStyle(.plain)
        }
        .frame(height: 60)
    }

    private func clock(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The two-blade mark in paper (mono inside the island).
struct MarkGlyph: View {
    var body: some View {
        if let img = Bundle.main.image(forResource: "glyph") {
            Image(nsImage: img).resizable().renderingMode(.template).foregroundStyle(Grids.paper).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "note.text").resizable().foregroundStyle(Grids.paper)
        }
    }
}

/// Flat event line: ink ticks for screenshots, green brackets for spoken notes, lime playhead.
struct Timeline: View {
    let marks: [TimelineMark]
    let elapsed: Int
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, span = CGFloat(max(elapsed, 60))
            ZStack(alignment: .leading) {
                Rectangle().fill(Grids.paper.opacity(0.35)).frame(height: 1.5)
                ForEach(marks) { mk in
                    Rectangle().fill(mk.isNote ? Grids.green : Grids.paper.opacity(0.75))
                        .frame(width: mk.isNote ? 3 : 1.5, height: mk.isNote ? 12 : 8)
                        .offset(x: min(w - 3, w * CGFloat(mk.t) / span))
                }
                Rectangle().fill(Grids.lime).frame(width: 2, height: 14)
                    .offset(x: min(w - 2, w * CGFloat(elapsed) / span))
            }
            .frame(height: g.size.height)
        }
    }
}

/// A short green segment breathing along the foot while the AI thinks.
final class Flag: ObservableObject { @Published var on = false }

struct ThinkingLine: View {
    @ObservedObject var flag = Flag()
    var body: some View {
        Capsule().fill(Grids.green).frame(width: flag.on ? 46 : 18, height: 2)
            .onAppear {
                guard !Grids.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { flag.on = true }
            }
    }
}

/// Panels that may sit over the menu bar and the notch.
final class TopPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

/// Hosting view that reports hover even while Uplink is not the active app, and takes the first click.
final class IslandHostingView: NSHostingView<IslandView> {
    var onHover: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["island"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["island": true]))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

final class Island {
    let model = IslandModel()
    private let panel: TopPanel
    private let host: IslandHostingView
    private var hoverWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?

    init() {
        panel = TopPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host = IslandHostingView(rootView: IslandView(m: model))
        panel.contentView = host
        host.onHover = { [weak self] inside in self?.hover(inside) }
        measureNotch()
    }

    /// Notch size from the screen's top safe area and the free areas either side of it.
    private func measureNotch() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.notchHeight = screen.safeAreaInsets.top
            model.notchWidth = max(150, screen.frame.width - l.width - r.width)
        } else {
            model.notchHeight = NSApp.mainMenu?.menuBarHeight ?? 24 // no notch: sit under the menu bar
            model.notchWidth = 186
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main }

    /// The panel always matches what is drawn, so it never blocks clicks beside the island.
    private func fitPanel(to size: CGSize, immediately: Bool) {
        guard let screen else { return }
        let w = max(size.width, model.notchWidth) + 2, h = model.notchHeight + size.height + 2
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        shrinkWork?.cancel()
        if immediately || frame.width >= panel.frame.width && frame.height >= panel.frame.height {
            panel.setFrame(frame, display: true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.panel.setFrame(frame, display: true) }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    var anchor: NSRect { panel.frame }

    func set(_ state: IslandState, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        measureNotch()
        let previous = model.state
        model.state = state
        if state == .hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.model.state == .hidden { self?.panel.orderOut(nil) }
            }
            return
        }
        fitPanel(to: model.size, immediately: previous == .hidden)
        panel.orderFrontRegardless()
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// After a card: back to the lesson if one is recording, else hidden.
    var isRecording: () -> Bool = { false }
    func settle() { set(isRecording() ? .recording : .hidden) }

    func refit() { fitPanel(to: model.size, immediately: false) }

    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .recording else { return }
            self.model.hovering = inside
            self.fitPanel(to: self.model.size, immediately: false)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.25 : 0.4), execute: work)
    }
}

// MARK: - Stickers (one at a time, beside the island)

final class StickerShow {
    private var panel: TopPanel?
    private var lastShown: [String: Date] = [:]
    var enabled: () -> Bool = { true }

    func show(_ name: String, beside anchor: NSRect, minGap: TimeInterval = 0) {
        guard enabled(), let image = Bundle.main.image(forResource: "sticker-\(name)") else { return }
        if minGap > 0, let last = lastShown[name], Date().timeIntervalSince(last) < minGap { return }
        lastShown[name] = Date()
        panel?.orderOut(nil)
        let size: CGFloat = 56
        let p = TopPanel(contentRect: NSRect(x: anchor.maxX + 10, y: anchor.maxY - size - 6, width: size + 12, height: size + 12),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: StickerView(image: image, size: size))
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self, weak p] in
            p?.orderOut(nil)
            if self?.panel === p { self?.panel = nil }
        }
    }
}

final class StickerPhase: ObservableObject { @Published var value = 0 } // 0 tucked, 1 out, 2 leaving

struct StickerView: View {
    let image: NSImage
    let size: CGFloat
    @ObservedObject var p = StickerPhase()
    private var phase: Int { p.value }
    var body: some View {
        Image(nsImage: image).resizable().frame(width: size, height: size)
            .scaleEffect(phase == 1 ? 1 : 0.6)
            .rotationEffect(.degrees(phase == 1 ? -6 : -14))
            .offset(x: phase == 1 ? 0 : -18)
            .opacity(phase == 1 ? 1 : 0)
            .frame(width: size + 12, height: size + 12)
            .onAppear {
                let pop: Animation = Grids.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.62)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { withAnimation(pop) { p.value = 1 } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.98) {
                    withAnimation(.easeIn(duration: 0.22)) { p.value = 2 }
                }
            }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
