import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination for the global quick-add shortcut, in Carbon terms.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// ⌃⌥Space
    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥Space")

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[code] != nil
        // A plain letter would hijack typing everywhere.
        guard carbon != 0 || isFunctionKey else { return nil }
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 || isFunctionKey else { return nil }
        let key = Self.names[code] ?? Self.functionKeys[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(keyCode: UInt32(code), modifiers: carbon, display: symbols + key)
    }

    static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
}

/// Registers the global quick-add shortcut with Carbon's RegisterEventHotKey, which works system-wide
/// without the Accessibility permission that an NSEvent global monitor would need.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private static let key = "hackban:quickAddShortcut"

    private(set) var shortcut: Shortcut?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var registrationFailed = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            shortcut = try? JSONDecoder().decode(Shortcut?.self, from: data)
        } else {
            shortcut = .default
        }
    }

    func registerSavedShortcut() {
        installHandler()
        register()
    }

    func set(_ s: Shortcut?) {
        shortcut = s
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
        register()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickAddController.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func register() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registrationFailed = false
        guard let s = shortcut else { return }
        let id = EventHotKeyID(signature: OSType(0x4842_4B4E), id: 1) // "HBKN"
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        registrationFailed = status != noErr
    }
}

/// Click, then press the new shortcut. Escape cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChange = { shortcut = $0 }
        v.shortcut = shortcut
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        v.shortcut = shortcut
        v.onChange = { shortcut = $0 }
        v.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut?
        var onChange: (Shortcut?) -> Void = { _ in }
        private var recording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            if event.keyCode == UInt16(kVK_Escape) { recording = false; return }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                onChange(nil)
                recording = false
                return
            }
            if let s = Shortcut(event: event) {
                onChange(s)
                recording = false
            } else {
                NSSound.beep()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = recording ? "Type shortcut…" : (shortcut?.display ?? "Click to record")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: shortcut == nil && !recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}
