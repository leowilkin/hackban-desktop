import AppKit
import HackbanKit
import SwiftUI

// MARK: colours

extension Color {
    init(hex: String) {
        let c = parseHex(hex) ?? (0, 0.47, 0.75, 1)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    static let hackClubRed = Color(hex: "#ec3750")
}

/// A board's colour or gradient, or its image.
struct BoardBackground: View {
    let background: String?
    var bgImage: String? = nil
    var account: Account? = nil

    var body: some View {
        ZStack {
            let stops = Palette.backgroundStops(background).map { Color(hex: $0) }
            if stops.count > 1 {
                LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                stops[0]
            }
            if let bgImage, let account {
                RemoteImage(account: account, url: bgImage) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .clipped()
    }
}

struct LabelChip: View {
    let label: HackbanKit.Label
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let style = Palette.label(label.color, dark: scheme == .dark)
        Text(label.name.isEmpty && !compact ? " " : label.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 0 : 6)
            .frame(minWidth: compact ? 36 : 40, minHeight: compact ? 8 : 18)
            .frame(height: compact ? 8 : nil)
            .foregroundStyle(style.map { Color(hex: $0.foreground) } ?? .primary)
            .background(style.map { Color(hex: $0.background) } ?? Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                if style == nil { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4)) }
            }
            .help(label.name.isEmpty ? (label.color ?? "No colour") : label.name)
    }
}

struct ColorSwatch: View {
    let name: String?
    var selected = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let style = Palette.label(name, dark: scheme == .dark)
        RoundedRectangle(cornerRadius: 3)
            .fill(style.map { Color(hex: $0.background) } ?? Color.secondary.opacity(0.15))
            .frame(width: 44, height: 28)
            .overlay {
                if selected { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(style.map { Color(hex: $0.foreground) } ?? .primary) }
                if name == nil { Image(systemName: "nosign").foregroundStyle(.secondary) }
            }
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .help(name ?? "None")
    }
}

// MARK: images

/// In-memory cache of downloaded images, keyed by account and URL.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func image(account: Account, url: String) async -> NSImage? {
        let key = "\(account.id)|\(url)"
        if let i = images[key] { return i }
        if let t = inFlight[key] { return await t.value }
        let client = account.client
        let t = Task<NSImage?, Never> {
            guard let data = try? await client.download(url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[key] = t
        let img = await t.value
        inFlight[key] = nil
        if let img { images[key] = img }
        if images.count > 500 { images.removeAll() }
        return img
    }
}

/// An image that may need the account's token (uploads, avatars) or may be public.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let account: Account
    let url: String
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { content(Image(nsImage: image)) } else { placeholder() }
        }
        .task(id: url) { image = await ImageCache.shared.image(account: account, url: url) }
    }
}

struct AvatarView: View {
    let user: User?
    let account: Account
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: "#dfe1e6"))
            Text(user?.initials ?? "?")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color(hex: "#172b4d"))
            if let img = user?.image, !img.isEmpty {
                RemoteImage(account: account, url: img) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .opacity(user?.isGhost == true ? 0.6 : 1)
        .help(user?.displayName ?? "")
    }
}

struct AvatarStack: View {
    let users: [User]
    let account: Account
    var size: CGFloat = 24
    var max = 5

    var body: some View {
        HStack(spacing: -6) {
            ForEach(users.prefix(max), id: \.id) { u in
                AvatarView(user: u, account: account, size: size).overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            }
            if users.count > max {
                Text("+\(users.count - max)").font(.caption2.bold()).frame(width: size, height: size).background(Circle().fill(.quaternary))
            }
        }
    }
}

/// Small pill marking which account something belongs to, when there's more than one.
struct AccountTag: View {
    let account: Account
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.accounts.count > 1 {
            Text(account.config.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(account.color.opacity(0.18), in: Capsule())
                .foregroundStyle(account.color)
        }
    }
}

extension NSImage {
    /// Hackban's logo (hackclub/hackban src/app/icon.svg) as a menu bar template: the rounded square with its two
    /// columns cut out, and a dot bitten out of the corner when something's unread.
    static func hackbanMenuBarIcon(unread: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            let s = rect.width / 32  // the SVG's 32pt grid
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s), xRadius: r * s, yRadius: r * s)
            }
            let logo = box(0, 0, 32, 32, 7.2)
            logo.append(box(6, 6, 8.5, 18, 2))
            logo.append(box(17.5, 6, 8.5, 11, 2))
            logo.windingRule = .evenOdd
            NSColor.black.setFill()
            logo.fill()
            if unread {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 19 * s, y: -3 * s, width: 16 * s, height: 16 * s)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 22 * s, y: 0, width: 10 * s, height: 10 * s)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: text

/// Markdown rendered with AttributedString (links clickable), keeping line breaks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let rendered = (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
        Text(rendered).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A text field that commits on Return or losing focus, and reverts on Escape.
struct InlineEditor: View {
    let value: String
    var placeholder = ""
    var font: Font = .body
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(placeholder, text: $draft, axis: axis)
                .textFieldStyle(.roundedBorder)
                .font(font)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, f in if !f { commit() } }
                .onAppear { focused = true }
        } else {
            Text(value.isEmpty ? placeholder : value)
                .font(font)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { draft = value; editing = true }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty, v != value { onCommit(v) }
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }

    var short: String { formatted(.dateTime.month(.abbreviated).day()) }
    var shortWithTime: String { formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
}

/// Due date badge colours, as on the web.
struct DueBadge: View {
    let card: Card
    var onToggle: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        if let due = card.due {
            let status = DueStatus.of(card)
            let (fg, bg): (Color, Color) = {
                switch status {
                case .complete: return (.white, Color(hex: "#1f845a"))
                case .overdue: return (.white, Color(hex: "#c9372c"))
                case .soon: return (Color(hex: "#172b4d"), Color(hex: "#f5cd47"))
                default: return (.secondary, .clear)
                }
            }()
            HStack(spacing: 3) {
                Image(systemName: hovering && onToggle != nil ? (card.dueComplete ? "checkmark.square" : "square") : (card.recurrence != nil ? "repeat" : "clock"))
                Text(due.short)
            }
            .font(.caption)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 3))
            .onHover { hovering = $0 }
            .onTapGesture { onToggle?() }
            .help(due.shortWithTime)
        }
    }
}

/// Toast at the bottom of a window.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack {
            Spacer()
            if let t = app.toast {
                Text(t)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { app.toast = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: app.toast)
        .allowsHitTesting(app.toast != nil)
    }
}

/// Confirmation for destructive actions.
struct ConfirmAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let action: () -> Void
}

extension View {
    func confirm(_ item: Binding<ConfirmAction?>) -> some View {
        alert(item.wrappedValue?.title ?? "", isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            Button(item.wrappedValue?.button ?? "OK", role: .destructive) { item.wrappedValue?.action() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.wrappedValue?.message ?? "")
        }
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Closes a sheet when you click the window behind it, like the web's modals. macOS sheets don't do that on their own.
/// Clicks in that window's titlebar and toolbar still go through, and nothing happens while the sheet has its own
/// alert or file picker up.
struct DismissOnOutsideClick: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(dismiss: dismiss) }
    func updateNSView(_ view: Watcher, context: Context) { view.dismiss = dismiss }

    final class Watcher: NSView {
        var dismiss: () -> Void
        private var monitor: Any?

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let sheet = self.window, sheet.attachedSheet == nil, let parent = sheet.sheetParent,
                      event.window === parent, parent.contentLayoutRect.contains(event.locationInWindow) else { return event }
                self.dismiss()
                return nil
            }
        }
    }
}
