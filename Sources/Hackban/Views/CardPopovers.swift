import AppKit
import HackbanKit
import SwiftUI

/// The card's properties down the right of the card sheet, as in Linear's issue view: a grey name, then a value
/// that opens its editor in a popover beside it.
struct CardProperties: View {
    let model: CardModel
    let card: Card
    let canEdit: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PropertyRow("Status", enabled: canEdit, action: { model.update(.init(dueComplete: !card.dueComplete)) }) {
                Label(card.dueComplete ? "Complete" : "Not complete", systemImage: card.dueComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(card.dueComplete ? Color(hex: "#1f845a") : .primary)
            }
            PropertyRow("List", enabled: canEdit) {
                Text(card.list?.name ?? "")
            } editor: { close in
                MoveCardPanel(model: model, card: card, copy: false, done: close).environment(app)
            }
            PropertyRow("Members", enabled: canEdit) {
                if let m = card.members, !m.isEmpty {
                    HStack(spacing: 6) {
                        AvatarStack(users: m.map(\.user), account: model.account, size: 20, max: 5)
                        if m.count == 1 { Text(m[0].user.displayName).lineLimit(1) }
                    }
                } else {
                    placeholder("Add members")
                }
            } editor: { _ in
                MemberPicker(model: model, card: card).environment(app)
            }
            PropertyRow("Labels", enabled: canEdit) {
                if let l = card.labels, !l.isEmpty {
                    FlowLayout(spacing: 4) { ForEach(l, id: \.labelId) { LabelChip(label: $0.label) } }
                } else {
                    placeholder("Add labels")
                }
            } editor: { _ in
                LabelPicker(model: model, card: card).environment(app)
            }
            PropertyRow("Dates", enabled: canEdit) {
                if card.start != nil || card.due != nil {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            if let s = card.start { Text(s.short) }
                            if card.start != nil && card.due != nil { Text("–") }
                            if let d = card.due { Text(d.shortWithTime) }
                            if card.recurrence != nil { Image(systemName: "repeat").foregroundStyle(.secondary) }
                        }
                        DueStatusPill(card: card)
                    }
                } else {
                    placeholder("Add dates")
                }
            } editor: { _ in
                DatesEditor(model: model, card: card).environment(app)
            }
            PropertyRow("Cover", enabled: canEdit) {
                if card.coverAttachmentId != nil {
                    Text("Image")
                } else if let hex = Palette.mid(card.coverColor) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: hex)).frame(width: 36, height: 14)
                } else {
                    placeholder("None")
                }
            } editor: { _ in
                CoverPicker(model: model, card: card).environment(app)
            }
            PropertyRow("Depends on", enabled: canEdit) {
                let blocked = card.blockedByTitles.count, blocking = card.blockingTitles.count
                if blocked + blocking > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        if blocked > 0 { Text("Blocked by \(blocked)").foregroundStyle(Color(hex: "#c9372c")) }
                        if blocking > 0 { Text("Blocking \(blocking)") }
                    }
                } else {
                    placeholder("None")
                }
            } editor: { _ in
                DependencyPicker(model: model, card: card).environment(app)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary)
    }
}

/// One property: its name in grey, and its value as a quiet button that highlights on hover.
private struct PropertyRow<Value: View, Editor: View>: View {
    let title: String
    let enabled: Bool
    var action: (() -> Void)?
    let value: Value
    let editor: (_ close: @escaping () -> Void) -> Editor
    @State private var open = false
    @State private var hovering = false

    init(_ title: String, enabled: Bool, @ViewBuilder value: () -> Value, @ViewBuilder editor: @escaping (_ close: @escaping () -> Void) -> Editor) {
        self.title = title
        self.enabled = enabled
        self.value = value()
        self.editor = editor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Button { if let action { action() } else { open = true } } label: {
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hovering = $0 }
            .popover(isPresented: $open, arrowEdge: .leading) { editor { open = false } }
        }
    }
}

extension PropertyRow where Editor == EmptyView {
    /// A property that acts when clicked instead of opening an editor.
    init(_ title: String, enabled: Bool, action: @escaping () -> Void, @ViewBuilder value: () -> Value) {
        self.init(title, enabled: enabled, value: value) { _ in EmptyView() }
        self.action = action
    }
}

/// The card's actions, behind the "…" in the card sheet's top bar.
struct CardActionsMenu: View {
    let model: CardModel
    let card: Card
    let canEdit: Bool
    @Binding var confirm: ConfirmAction?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel?

    enum Panel: String, Identifiable {
        case move, copy
        var id: String { rawValue }
    }

    var body: some View {
        Menu {
            if canEdit {
                Button("Move…") { panel = .move }
                Button("Copy…") { panel = .copy }
            }
            Button("Copy Link") { copyToPasteboard(model.account.client.webURL("/c/\(card.id)").absoluteString); app.flash("Link copied") }
            if canEdit {
                Divider()
                if card.closed {
                    Button("Send to Board") { model.update(.init(closed: false)) }
                    Button("Delete…", role: .destructive) {
                        confirm = ConfirmAction(title: "Delete card?", message: "All actions will be removed from the activity feed and you won't be able to re-open the card. There is no undo.", button: "Delete") {
                            let bm = model.boardModel
                            Task {
                                do {
                                    try await model.api.deleteCard(card.id)
                                    bm?.scheduleReload()
                                    dismiss()
                                } catch { app.flash(error.localizedDescription) }
                            }
                        }
                    }
                } else {
                    Button("Archive") { model.update(.init(closed: true)) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .popover(item: $panel, arrowEdge: .bottom) { p in
            MoveCardPanel(model: model, card: card, copy: p == .copy) { panel = nil }.environment(app)
        }
    }
}

struct MemberPicker: View {
    let model: CardModel
    let card: Card
    @State private var q = ""

    var body: some View {
        let members = (model.boardModel?.board?.members ?? []).filter { q.isEmpty || $0.user.displayName.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Members").font(.headline)
            TextField("Search members", text: $q).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(members, id: \.userId) { m in
                        Button { model.toggleMember(m.user) } label: {
                            HStack {
                                AvatarView(user: m.user, account: model.account, size: 24)
                                Text(m.user.displayName)
                                if m.guest == true { Text("Guest").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if (model.card?.memberIds ?? card.memberIds).contains(m.userId) { Image(systemName: "checkmark") }
                            }
                            .contentShape(Rectangle())
                            .padding(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct LabelPicker: View {
    let model: CardModel
    let card: Card
    @State private var q = ""
    @State private var editing: HackbanKit.Label?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if creating || editing != nil {
                LabelEditor(label: editing, board: model.boardModel) {
                    creating = false
                    editing = nil
                } onCreate: { l in
                    model.toggleLabel(l)
                }
            } else {
                Text("Labels").font(.headline)
                TextField("Search labels…", text: $q).textFieldStyle(.roundedBorder)
                let labels = (model.boardModel?.board?.labels ?? []).filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.color ?? "").contains(q.lowercased()) }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(labels) { l in
                            HStack {
                                Toggle("", isOn: Binding(get: { (model.card?.labelIds ?? card.labelIds).contains(l.id) }, set: { _ in model.toggleLabel(l) }))
                                    .labelsHidden()
                                LabelChip(label: l).frame(maxWidth: .infinity, alignment: .leading)
                                Button { editing = l } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                Button("Create a new label") { creating = true }.frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// Create or edit a board label (also used from the board menu).
struct LabelEditor: View {
    let label: HackbanKit.Label?
    let board: BoardModel?
    let done: () -> Void
    var onCreate: (HackbanKit.Label) -> Void = { _ in }
    @State private var name = ""
    @State private var color: String? = "green"
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { done() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(label == nil ? "Create label" : "Edit label").font(.headline)
            }
            LabelChip(label: HackbanKit.Label(id: "preview", name: name, color: color)).frame(maxWidth: .infinity)
            TextField("Title", text: $name).textFieldStyle(.roundedBorder)
            Text("Select a colour").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 5), spacing: 6) {
                ForEach(Palette.labelColors, id: \.self) { c in
                    ColorSwatch(name: c, selected: color == c).onTapGesture { color = c }
                }
            }
            Button("Remove colour") { color = nil }.disabled(color == nil)
            HStack {
                Button(label == nil ? "Create" : "Save") {
                    if let label { board?.updateLabel(label.id, name: name, color: color) }
                    else if let board { Task { if let l = await board.createLabel(name: name, color: color) { onCreate(l) } } }
                    done()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                if label != nil { Button("Delete", role: .destructive) { confirmDelete = true } }
            }
        }
        .onAppear {
            name = label?.name ?? ""
            color = label == nil ? "green" : label?.color
        }
        .alert("Delete label?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let label { board?.deleteLabel(label.id) }
                done()
            }
        } message: {
            Text("This removes the label from every card. There is no undo.")
        }
    }
}

struct ChecklistAdder: View {
    let model: CardModel
    let card: Card
    let done: () -> Void
    @State private var name = "Checklist"
    @State private var copyFrom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add checklist").font(.headline)
            TextField("Title", text: $name).textFieldStyle(.roundedBorder)
            if let lists = card.checklists, !lists.isEmpty {
                Picker("Copy items from", selection: $copyFrom) {
                    Text("(none)").tag("")
                    ForEach(lists) { Text($0.name).tag($0.id) }
                }
            }
            Button("Add") {
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { model.addChecklist(n, copyFrom: copyFrom.isEmpty ? nil : copyFrom) }
                done()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct DatesEditor: View {
    let model: CardModel
    let card: Card
    @Environment(\.dismiss) private var dismiss
    @State private var hasStart = false
    @State private var hasDue = true
    @State private var start = Date()
    @State private var due = Date()
    @State private var recurrence = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dates").font(.headline)
            DatePicker("", selection: hasDue ? $due : $start, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Toggle("Start date", isOn: $hasStart)
            if hasStart { DatePicker("Start", selection: $start, displayedComponents: .date) }
            Toggle("Due date", isOn: $hasDue)
            if hasDue { DatePicker("Due", selection: $due) }
            Picker("Repeat", selection: $recurrence) {
                Text("Never").tag("")
                ForEach(Recurrence.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!hasDue)
            HStack {
                Button("Save") {
                    if hasDue {
                        let comps = Calendar.current.dateComponents([.hour], from: due)
                        UserDefaults.standard.set(comps.hour, forKey: "hackban:defaultDueHour")
                    }
                    model.update(.init(
                        start: .some(hasStart ? start : nil),
                        due: .some(hasDue ? due : nil),
                        recurrence: .some(hasDue && !recurrence.isEmpty ? recurrence : nil)
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Remove") {
                    model.update(.init(start: .some(nil), due: .some(nil), recurrence: .some(nil)))
                    dismiss()
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            hasStart = card.start != nil
            hasDue = card.due != nil || card.start == nil
            start = card.start ?? Date()
            due = card.due ?? CardQuickMenu.at(1)
            recurrence = card.recurrence ?? ""
        }
    }
}

struct AttachmentAdder: View {
    let model: CardModel
    @Binding var importing: Bool
    let done: () -> Void
    @State private var url = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attach").font(.headline)
            Button("Choose files…") { done(); importing = true }
            Text("You can also drag files onto the card, or paste them.").font(.caption).foregroundStyle(.secondary)
            Divider()
            TextField("Paste a link", text: $url).textFieldStyle(.roundedBorder)
            TextField("Display text (optional)", text: $name).textFieldStyle(.roundedBorder)
            Button("Attach link") {
                var u = url.trimmingCharacters(in: .whitespaces)
                if !u.isEmpty, !u.lowercased().hasPrefix("http") { u = "https://" + u }
                if !u.isEmpty { model.addLink(u, name: name.isEmpty ? nil : name) }
                done()
            }
            .buttonStyle(.borderedProminent)
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .frame(width: 300)
    }
}

struct CoverPicker: View {
    let model: CardModel
    let card: Card

    var body: some View {
        let c = model.card ?? card
        VStack(alignment: .leading, spacing: 10) {
            Text("Cover").font(.headline)
            Picker("Size", selection: Binding(get: { c.coverSize ?? "normal" }, set: { model.update(.init(coverSize: $0)) })) {
                Text("Normal").tag("normal")
                Text("Full").tag("full")
            }
            .pickerStyle(.segmented)
            .disabled(c.coverColor == nil && c.coverAttachmentId == nil)
            Text("Colours").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 5), spacing: 6) {
                ForEach(Palette.baseNames, id: \.self) { name in
                    ColorSwatch(name: name, selected: c.coverColor == name).onTapGesture { model.update(.init(coverColor: .some(name))) }
                }
            }
            let images = (c.attachments ?? []).filter(\.isImage)
            if !images.isEmpty {
                Text("Attachments").font(.caption.bold()).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: 6), count: 3), spacing: 6) {
                    ForEach(images) { a in
                        RemoteImage(account: model.account, url: a.url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                            .frame(width: 80, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: c.coverAttachmentId == a.id ? 2 : 0))
                            .onTapGesture { model.update(.init(coverAttachmentId: .some(a.id))) }
                    }
                }
            }
            if c.coverColor != nil || c.coverAttachmentId != nil {
                Button("Remove cover") { model.update(.init(coverColor: .some(nil), coverAttachmentId: .some(nil))) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// Mark this card as blocked by other cards on the board.
struct DependencyPicker: View {
    let model: CardModel
    let card: Card
    @State private var q = ""

    var body: some View {
        let c = model.card ?? card
        let blockerIds = Set(c.blockers.map(\.id))
        let blocksIds = Set(c.blocks.map(\.id))
        let candidates = (model.boardModel?.board?.lists ?? []).flatMap { l in l.openCards.map { (l.name, $0) } }
            .filter { $0.1.id != c.id && !blockerIds.contains($0.1.id) && !blocksIds.contains($0.1.id) }
            .filter { q.isEmpty || $0.1.title.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Dependencies").font(.headline)
            if !c.blockers.isEmpty {
                Text("Blocked by").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(c.blockers) { d in
                    HStack {
                        Image(systemName: d.dueComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(d.dueComplete ? Color.green : Color.secondary)
                        Text(d.title).strikethrough(d.dueComplete)
                        Spacer()
                        Button { model.setBlocker(d.id, on: false) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
            }
            if !c.blocks.isEmpty {
                Text("Blocking").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(c.blocks) { d in Text(d.title) }
            }
            Divider()
            Text("Blocked by…").font(.caption.bold()).foregroundStyle(.secondary)
            TextField("Search cards on this board", text: $q).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(candidates.prefix(40)), id: \.1.id) { item in
                        Button { model.setBlocker(item.1.id, on: true) } label: {
                            VStack(alignment: .leading) {
                                Text(item.1.title).lineLimit(1)
                                Text(item.0).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 320)
    }
}

/// Move or copy a card to any board/list/position on the same server.
struct MoveCardPanel: View {
    let model: CardModel
    let card: Card
    let copy: Bool
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @State private var boardId = ""
    @State private var listId = ""
    @State private var position = 0
    @State private var target: Board?
    @State private var title = ""
    @State private var keep = HackbanAPI.CopyKeep()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy ? "Copy card" : "Move card").font(.headline)
            if copy {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Text("Keep").font(.caption.bold()).foregroundStyle(.secondary)
                Toggle("Checklists", isOn: $keep.checklists)
                Toggle("Labels", isOn: $keep.labels)
                Toggle("Members", isOn: $keep.members)
                Toggle("Attachments", isOn: $keep.attachments)
            }
            Picker("Board", selection: $boardId) {
                ForEach(model.account.allBoards, id: \.board.id) { item in Text(item.board.name).tag(item.board.id) }
            }
            Picker("List", selection: $listId) {
                ForEach(target?.lists ?? []) { Text($0.name).tag($0.id) }
            }
            Picker("Position", selection: $position) {
                let count = (target?.lists.first { $0.id == listId }?.openCards.filter { $0.id != card.id }.count ?? 0) + 1
                ForEach(0..<count, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            Button(copy ? "Create card" : "Move") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(listId.isEmpty)
        }
        .padding(12)
        .frame(width: 300)
        .task(id: boardId) {
            guard !boardId.isEmpty else { return }
            target = try? await model.api.board(boardId)
            if !(target?.lists.contains { $0.id == listId } ?? false) { listId = target?.lists.first?.id ?? "" }
            let cards = target?.lists.first { $0.id == listId }?.openCards.filter { $0.id != card.id } ?? []
            position = min(position, cards.count)
        }
        .onAppear {
            title = card.title
            boardId = card.list?.boardId ?? ""
            listId = card.listId
            position = (model.boardModel?.list(card.listId)?.openCards.firstIndex { $0.id == card.id }) ?? 0
        }
    }

    private func submit() {
        let cards = target?.lists.first { $0.id == listId }?.openCards.filter { $0.id != card.id } ?? []
        let afterId: String? = position > 0 && position <= cards.count ? cards[position - 1].id : nil
        let api = model.api
        let id = card.id
        let bm = model.boardModel
        Task {
            do {
                if copy {
                    _ = try await api.copyCard(id, title: title.isEmpty ? card.title : title, listId: listId, afterId: .some(afterId), keep: keep)
                } else {
                    try await api.moveCard(id, listId: listId, afterId: afterId)
                }
                bm?.scheduleReload()
                if boardId != bm?.boardId { app.boardModel(account: model.account, boardId: boardId).scheduleReload() }
                model.scheduleReload()
            } catch { app.flash(error.localizedDescription) }
        }
        done()
    }
}
