import AppKit
import HackbanKit
import SwiftUI
import UniformTypeIdentifiers

struct CardSheet: View {
    @State private var model: CardModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var dropping = false
    @State private var confirm: ConfirmAction?
    @State private var addingChecklist = false
    @State private var attaching = false

    init(model: CardModel) { _model = State(initialValue: model) }

    var body: some View {
        Group {
            if let card = model.card {
                content(card)
            } else if let e = model.loadError {
                ContentUnavailableView {
                    Label("Couldn't open the card", systemImage: "exclamationmark.triangle")
                } description: { Text(e) } actions: {
                    Button("Close") { dismiss() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 760)
        .background(DismissOnOutsideClick { dismiss() })
        .task { await model.load() }
        .onDisappear { if model.boardModel?.openCard === model { model.boardModel?.openCard = nil } }
        .confirm($confirm)
    }

    private var canEdit: Bool { model.boardModel?.board?.canEdit ?? true }
    private var board: Board? { model.boardModel?.board }

    // Laid out like Linear's issue view: where the card lives along the top, the content down the left, and its
    // properties down the right.
    private func content(_ card: Card) -> some View {
        VStack(spacing: 0) {
            CardCover(card: card, account: model.account)
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    if let b = card.list?.board?.name {
                        Text(b)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    Text(card.list?.name ?? "")
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                AccountTag(account: model.account)
                if card.closed { Text("Archived").font(.caption.bold()).padding(.horizontal, 5).background(Color.orange.opacity(0.3), in: Capsule()) }
                Spacer()
                Button { model.toggleWatch() } label: { Image(systemName: card.watching == true ? "eye.fill" : "eye") }
                    .help(card.watching == true ? "Stop watching" : "Watch: get notified of comments on this card")
                CardActionsMenu(model: model, card: card, canEdit: canEdit, confirm: $confirm)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if canEdit {
                            InlineEditor(value: card.title, font: .title2.weight(.semibold), axis: .vertical) { model.update(.init(title: $0)) }
                        } else {
                            Text(card.title).font(.title2.weight(.semibold))
                        }
                        DescriptionSection(card: card, canEdit: canEdit) { model.update(.init(description: $0)) }
                        if canEdit { addRow(card) }
                        ForEach(card.checklists ?? []) { cl in
                            ChecklistSection(model: model, checklist: cl, canEdit: canEdit)
                        }
                        if let atts = card.attachments, !atts.isEmpty {
                            AttachmentsSection(model: model, card: card, canEdit: canEdit, importing: $importing)
                        }
                        ActivitySection(model: model, card: card, canEdit: canEdit)
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    CardProperties(model: model, card: card, canEdit: canEdit)
                        .padding(14)
                }
                .frame(width: 270)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .overlay(Text("Drop files to attach").font(.title3.bold()).padding().background(.regularMaterial, in: Capsule()))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.uploading > 0 {
                HStack { ProgressView().controlSize(.small); Text("Uploading…") }
                    .padding(10).background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard canEdit else { return false }
            model.upload(urls: urls.filter(\.isFileURL))
            return true
        } isTargeted: { dropping = $0 && canEdit }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.upload(urls: urls) }
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { _ in pasteFiles() }
    }

    /// Add a checklist or attachment, under the description, like Linear's "Add sub-issues".
    private func addRow(_ card: Card) -> some View {
        HStack(spacing: 8) {
            Button { addingChecklist = true } label: { Label("Checklist", systemImage: "plus") }
                .popover(isPresented: $addingChecklist, arrowEdge: .bottom) {
                    ChecklistAdder(model: model, card: card) { addingChecklist = false }.environment(app)
                }
            Button { attaching = true } label: { Label("Attachment", systemImage: "paperclip") }
                .popover(isPresented: $attaching, arrowEdge: .bottom) {
                    AttachmentAdder(model: model, importing: $importing) { attaching = false }.environment(app)
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// ⌘V with files or an image on the clipboard attaches them.
    private func pasteFiles() {
        guard canEdit else { return }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.upload(urls: urls)
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            model.upload([("Pasted image.png", "image/png", png)])
        }
    }
}

struct CardCover: View {
    let card: Card
    let account: Account

    var body: some View {
        if let id = card.coverAttachmentId, let a = card.attachments?.first(where: { $0.id == id }) {
            RemoteImage(account: account, url: a.url) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.1) }
                .frame(maxWidth: .infinity, maxHeight: 180)
                .background(Color.secondary.opacity(0.1))
        } else if let hex = Palette.mid(card.coverColor) {
            Color(hex: hex).frame(height: 90)
        }
    }
}

// MARK: due status

/// Complete, overdue or due soon, as a small coloured pill; nothing otherwise.
struct DueStatusPill: View {
    let card: Card

    var body: some View {
        switch DueStatus.of(card) {
        case .complete?: Text("Complete").font(.caption.bold()).padding(.horizontal, 4).background(Color(hex: "#1f845a"), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
        case .overdue?: Text("Overdue").font(.caption.bold()).padding(.horizontal, 4).background(Color(hex: "#c9372c"), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
        case .soon?: Text("Due soon").font(.caption.bold()).padding(.horizontal, 4).background(Color(hex: "#f5cd47"), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(Color(hex: "#172b4d"))
        default: EmptyView()
        }
    }
}

// MARK: description

struct DescriptionSection: View {
    let card: Card
    let canEdit: Bool
    let onSave: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Description", systemImage: "text.alignleft").font(.headline)
                Spacer()
                if canEdit && !editing && !card.description.isEmpty { Button("Edit") { start() } }
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Button("Save") { onSave(draft); editing = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Cancel") { editing = false }
                    Spacer()
                    Text("Markdown supported").font(.caption).foregroundStyle(.secondary)
                }
            } else if card.description.isEmpty {
                if canEdit {
                    Button { start() } label: {
                        Text("Add a more detailed description…").frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading).padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                MarkdownText(text: card.description)
                    .onTapGesture(count: 2) { if canEdit { start() } }
            }
        }
    }

    private func start() {
        draft = card.description
        editing = true
    }
}

// MARK: checklists

struct ChecklistSection: View {
    let model: CardModel
    let checklist: Checklist
    let canEdit: Bool
    @AppStorage private var hideChecked: Bool
    @State private var adding = false
    @State private var newItem = ""
    @State private var confirm: ConfirmAction?
    @FocusState private var addFocused: Bool

    init(model: CardModel, checklist: Checklist, canEdit: Bool) {
        self.model = model
        self.checklist = checklist
        self.canEdit = canEdit
        _hideChecked = AppStorage(wrappedValue: false, "hackban:hide-checked:\(checklist.id)")
    }

    var body: some View {
        let done = checklist.done, total = checklist.items.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist")
                if canEdit {
                    InlineEditor(value: checklist.name, font: .headline) { model.renameChecklist(checklist.id, $0) }
                } else {
                    Text(checklist.name).font(.headline)
                }
                Spacer()
                if done > 0 { Button(hideChecked ? "Show checked items (\(done))" : "Hide checked items") { hideChecked.toggle() } }
                if canEdit {
                    Button("Delete") {
                        confirm = ConfirmAction(title: "Delete \(checklist.name)?", message: "Deleting a checklist is permanent.", button: "Delete") {
                            model.deleteChecklist(checklist.id)
                        }
                    }
                }
            }
            HStack {
                Text(total == 0 ? "0%" : "\(done * 100 / total)%").font(.caption).monospacedDigit().frame(width: 34, alignment: .leading)
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(done == total && total > 0 ? .green : .accentColor)
            }
            ForEach(checklist.items.filter { !hideChecked || !$0.complete }) { item in
                CheckItemRow(model: model, item: item, canEdit: canEdit)
                    .draggable("hackban-item:\(item.id)")
                    .dropDestination(for: String.self) { s, _ in
                        guard let raw = s.first, raw.hasPrefix("hackban-item:") else { return false }
                        model.moveItem(String(raw.dropFirst(13)), to: checklist.id, before: item.id)
                        return true
                    }
            }
            if canEdit {
                if adding {
                    TextField("Add an item", text: $newItem, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($addFocused)
                        .onSubmit(add)
                        .onExitCommand { adding = false }
                        .onAppear { addFocused = true }
                    HStack {
                        Button("Add", action: add).buttonStyle(.borderedProminent)
                        Button("Cancel") { adding = false; newItem = "" }
                    }
                } else {
                    Button("Add an item") { adding = true }
                        .dropDestination(for: String.self) { s, _ in
                            guard let raw = s.first, raw.hasPrefix("hackban-item:") else { return false }
                            model.moveItem(String(raw.dropFirst(13)), to: checklist.id, before: nil)
                            return true
                        }
                }
            }
        }
        .confirm($confirm)
    }

    private func add() {
        // Pasting several lines adds one item per line.
        let lines = newItem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for l in lines { model.addItem(to: checklist.id, l) }
        newItem = ""
        addFocused = true
    }
}

struct CheckItemRow: View {
    let model: CardModel
    let item: CheckItem
    let canEdit: Bool
    @State private var dueOpen = false
    @State private var memberOpen = false
    @State private var due = Date()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { item.complete }, set: { model.updateItem(item.id, complete: $0) }))
                .labelsHidden()
                .disabled(!canEdit)
            if canEdit {
                InlineEditor(value: item.name, axis: .vertical) { model.updateItem(item.id, name: $0) }
                    .strikethrough(item.complete)
                    .foregroundStyle(item.complete ? .secondary : .primary)
            } else {
                Text(item.name).strikethrough(item.complete).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let d = item.due {
                Text(d.short).font(.caption).padding(.horizontal, 4)
                    .background(!item.complete && d < Date() ? Color.red.opacity(0.25) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
            if let m = item.member { AvatarView(user: m, account: model.account, size: 20) }
            if canEdit {
                Menu {
                    Button("Due date…") { due = item.due ?? CardQuickMenu.at(1); dueOpen = true }
                    if item.due != nil { Button("Remove due date") { model.updateItem(item.id, due: .some(nil)) } }
                    Menu("Assign") {
                        ForEach(model.boardModel?.board?.members ?? [], id: \.userId) { m in
                            Button(m.user.displayName) { model.updateItem(item.id, member: .some(m.user)) }
                        }
                        if item.memberId != nil { Divider(); Button("Unassign") { model.updateItem(item.id, member: .some(nil)) } }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteItem(item.id) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .popover(isPresented: $dueOpen) {
                        VStack {
                            DatePicker("Due", selection: $due).datePickerStyle(.graphical).labelsHidden()
                            Button("Save") { model.updateItem(item.id, due: .some(due)); dueOpen = false }.buttonStyle(.borderedProminent)
                        }
                        .padding()
                    }
            }
        }
    }
}

// MARK: attachments

struct AttachmentsSection: View {
    let model: CardModel
    let card: Card
    let canEdit: Bool
    @Binding var importing: Bool
    @State private var renaming: Attachment?
    @State private var newName = ""
    @State private var confirm: ConfirmAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Attachments", systemImage: "paperclip").font(.headline)
                Spacer()
                if canEdit { Button("Add") { importing = true } }
            }
            ForEach(card.attachments ?? []) { a in
                HStack(spacing: 12) {
                    Group {
                        if a.isImage {
                            RemoteImage(account: model.account, url: a.url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                        } else {
                            ZStack {
                                Color.secondary.opacity(0.15)
                                Text(a.isUpload == true ? (a.displayName.split(separator: ".").last.map { String($0).uppercased() } ?? "FILE") : "LINK")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.displayName).bold().lineLimit(1)
                        HStack(spacing: 8) {
                            if let d = a.createdAt { Text("Added \(d.relative)") }
                            if card.coverAttachmentId == a.id { Label("Cover", systemImage: "photo").labelStyle(CompactLabelStyle()) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Open") { open(a) }
                            if canEdit {
                                if a.isImage {
                                    Button(card.coverAttachmentId == a.id ? "Remove cover" : "Make cover") {
                                        model.update(.init(coverAttachmentId: .some(card.coverAttachmentId == a.id ? nil : a.id)))
                                    }
                                }
                                Button("Rename") { newName = a.displayName; renaming = a }
                                Button("Delete") {
                                    confirm = ConfirmAction(title: "Delete attachment?", message: "\(a.displayName) is deleted for good.", button: "Delete") { model.deleteAttachment(a.id) }
                                }
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(a) }
            }
        }
        .confirm($confirm)
        .alert("Rename attachment", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let a = renaming, !newName.isEmpty { model.renameAttachment(a.id, newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func open(_ a: Attachment) {
        Task { if let url = await model.open(a) { NSWorkspace.shared.open(url) } }
    }
}

// MARK: comments & activity

struct ActivitySection: View {
    let model: CardModel
    let card: Card
    let canEdit: Bool
    @AppStorage("hackban:card-show-details") private var showDetails = true
    @State private var comment = ""
    @State private var editing: String?
    @State private var editText = ""
    @State private var confirm: ConfirmAction?

    private enum Entry: Identifiable {
        case comment(Comment)
        case activity(Activity)
        var id: String { switch self { case .comment(let c): return "c" + c.id; case .activity(let a): return "a" + a.id } }
        var date: Date { switch self { case .comment(let c): return c.createdAt; case .activity(let a): return a.createdAt } }
    }

    var body: some View {
        let entries: [Entry] = ((card.comments ?? []).map(Entry.comment) + (showDetails ? (card.activities ?? []).map(Entry.activity) : []))
            .sorted { $0.date > $1.date }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Activity", systemImage: "list.bullet").font(.headline)
                Spacer()
                Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
            }
            if canEdit {
                HStack(alignment: .top) {
                    AvatarView(user: model.account.profile?.asUser, account: model.account, size: 30)
                    VStack(alignment: .leading) {
                        TextField("Write a comment…", text: $comment, axis: .vertical)
                            .lineLimit(1...8)
                            .textFieldStyle(.roundedBorder)
                        if !comment.isEmpty {
                            Button("Save") {
                                model.addComment(comment.trimmingCharacters(in: .whitespacesAndNewlines))
                                comment = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                    }
                }
            }
            ForEach(entries) { e in
                switch e {
                case .comment(let c): commentRow(c)
                case .activity(let a): activityRow(a)
                }
            }
        }
        .confirm($confirm)
    }

    private func commentRow(_ c: Comment) -> some View {
        HStack(alignment: .top) {
            AvatarView(user: c.author, account: model.account, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.author?.displayName ?? "Someone").bold()
                    Text(c.createdAt.relative).font(.caption).foregroundStyle(.secondary).help(c.createdAt.formatted())
                    if c.editedAt != nil { Text("(edited)").font(.caption).foregroundStyle(.secondary) }
                }
                if editing == c.id {
                    TextField("", text: $editText, axis: .vertical).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") { model.editComment(c.id, editText); editing = nil }.buttonStyle(.borderedProminent)
                        Button("Cancel") { editing = nil }
                    }
                } else {
                    MarkdownText(text: c.text)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    if c.authorId == model.account.me {
                        HStack {
                            Button("Edit") { editText = c.text; editing = c.id }
                            Button("Delete") {
                                confirm = ConfirmAction(title: "Delete comment?", message: "Deleting a comment is forever. There is no undo.", button: "Delete") { model.deleteComment(c.id) }
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private func activityRow(_ a: Activity) -> some View {
        HStack(alignment: .top) {
            AvatarView(user: a.actor, account: model.account, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                (Text(a.actor?.displayName ?? "Someone").bold() + Text(" ") + Text(ActivityText.describe(a, onCard: true)))
                Text(a.createdAt.relative).font(.caption).foregroundStyle(.secondary).help(a.createdAt.formatted())
            }
        }
    }
}
