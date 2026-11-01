import HackbanKit
import SwiftUI

struct ListColumn: View {
    @Bindable var model: BoardModel
    let list: BoardList
    @Binding var hoveredCard: String?
    @Environment(AppModel.self) private var app
    @State private var composing = false
    @State private var composeAtTop = false
    @State private var draft = ""
    @State private var dropTarget = false
    @State private var copying = false
    @State private var copyName = ""
    @State private var confirm: ConfirmAction?
    @FocusState private var composerFocused: Bool

    var body: some View {
        let cards = model.visibleCards(in: list)
        VStack(alignment: .leading, spacing: 0) {
            header
            // Short lists hug their cards; long ones scroll.
            ViewThatFits(in: .vertical) {
                cardStack(cards)
                ScrollView(.vertical) { cardStack(cards) }.scrollIndicators(.never)
            }
            if !composing && model.canEdit {
                Button {
                    composeAtTop = false
                    composing = true
                } label: {
                    Label("Add a card", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(10)
            }
        }
        .frame(width: 272)
        .background(listBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: dropTarget ? 2 : 0))
        // Dropping on the list (not on a card) puts the card at the end.
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let cid = DragItem.cardId(s) else { return false }
            model.moveCard(cid, to: list.id, before: nil)
            return true
        } isTargeted: { dropTarget = $0 }
        .confirm($confirm)
        .alert("Copy list", isPresented: $copying) {
            TextField("Name", text: $copyName)
            Button("Copy") { if !copyName.isEmpty { model.copyList(list.id, name: copyName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func cardStack(_ cards: [Card]) -> some View {
        VStack(spacing: 8) {
            if composing && composeAtTop { composer }
            ForEach(cards) { card in
                CardFront(model: model, card: card, hovered: hoveredCard == card.id)
                    .onHover { inside in
                        if inside { hoveredCard = card.id } else if hoveredCard == card.id { hoveredCard = nil }
                    }
                    .draggable(DragItem.card(card.id)) {
                        Text(card.title).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let s = items.first, let cid = DragItem.cardId(s) else { return false }
                        model.moveCard(cid, to: list.id, before: card.id)
                        return true
                    }
            }
            if composing && !composeAtTop { composer }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var listBackground: some ShapeStyle {
        if let hex = Palette.mid(list.color) { return AnyShapeStyle(Color(hex: hex).opacity(0.85)) }
        return AnyShapeStyle(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 4) {
            if model.canEdit {
                InlineEditor(value: list.name, font: .headline) { model.renameList(list.id, $0) }
                    .draggable(DragItem.list(list.id)) { Text(list.name).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
            } else {
                Text(list.name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.filters.isActive {
                Text("\(model.visibleCards(in: list).count)/\(list.openCards.count)").font(.caption).foregroundStyle(.secondary)
            }
            if model.canEdit {
                Menu {
                    Section("Sort by") {
                        ForEach(CardSort.allCases) { s in Button(s.title) { model.sortList(list.id, by: s) } }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Sort list")
                Menu { listMenu } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var listMenu: some View {
        Button("Add card") { composeAtTop = true; composing = true }
        Button("Copy list…") { copyName = list.name; copying = true }
        if let b = model.board {
            Menu("Move list to board") {
                ForEach(model.account.allBoards.filter { $0.board.id != b.id }, id: \.board.id) { item in
                    Button("\(item.board.name) (\(item.workspace))") { model.moveListToBoard(list.id, board: item.board.id) }
                }
            }
            Menu("Move all cards to") {
                ForEach(b.lists.filter { $0.id != list.id }) { l in Button(l.name) { model.moveAllCards(from: list.id, to: l.id) } }
            }
        }
        Menu("Colour") {
            Button("None") { model.setListColor(list.id, nil) }
            ForEach(Palette.baseNames, id: \.self) { c in
                Button { model.setListColor(list.id, c) } label: { Label(c.capitalized, systemImage: list.color == c ? "checkmark" : "circle.fill") }
            }
        }
        Divider()
        Button("Archive all cards in this list") {
            confirm = ConfirmAction(title: "Archive all cards?", message: "Every card in \(list.name) is archived. You can restore them from the board menu.", button: "Archive all") {
                model.archiveAllCards(in: list.id)
            }
        }
        Button("Archive list") { model.archiveList(list.id) }
        Button("Delete list…", role: .destructive) {
            confirm = ConfirmAction(title: "Delete \(list.name)?", message: "The list and all its cards are deleted for good. This can't be undone.", button: "Delete") {
                model.deleteList(list.id)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Enter a title for this card…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .focused($composerFocused)
                .onSubmit(add)
                .onExitCommand { composing = false; draft = "" }
                .onAppear { composerFocused = true }
            HStack {
                Button("Add card", action: add).buttonStyle(.borderedProminent)
                Button { composing = false; draft = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !title.isEmpty else { return }
        Task { _ = await model.addCard(to: list.id, title: title, atTop: composeAtTop) }
        composerFocused = true
    }
}

struct CardFront: View {
    @Bindable var model: BoardModel
    let card: Card
    let hovered: Bool
    @Environment(AppModel.self) private var app
    @State private var quickEdit = false

    var body: some View {
        cardContent
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { app.open(card: card.id, in: model.account) }
            .contextMenu { CardQuickMenu(model: model, card: card) }
            .popover(isPresented: $quickEdit) { QuickEditPopover(model: model, card: card) }
            .onReceive(NotificationCenter.default.publisher(for: .hackbanQuickEdit)) { n in
                if (n.object as? String) == card.id { quickEdit = true }
            }
    }

    private var showCheck: Bool { (card.dueComplete && card.due == nil) || (hovered && model.canEdit) }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                if let labels = card.labels, !labels.isEmpty {
                    FlowLayout(spacing: 4) { ForEach(labels, id: \.labelId) { LabelChip(label: $0.label) } }
                }
                HStack(alignment: .top, spacing: 6) {
                    if showCheck {
                        Button { model.updateCard(card.id, .init(dueComplete: !card.dueComplete)) } label: {
                            Image(systemName: card.dueComplete ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(card.dueComplete ? Color(hex: "#1f845a") : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(card.dueComplete ? "Mark incomplete (d)" : "Mark complete (d)")
                    }
                    Text(card.title)
                        .strikethrough(card.dueComplete && card.due == nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                badges
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let url = card.coverUrl {
            RemoteImage(account: model.account, url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                .frame(height: card.coverSize == "full" ? 160 : 110)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        } else if let hex = Palette.mid(card.coverColor) {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(Color(hex: hex))
                .frame(height: card.coverSize == "full" ? 56 : 32)
        }
    }

    @ViewBuilder
    private var badges: some View {
        let (done, total) = card.checkCounts
        let members = (card.members ?? []).map(\.user)
        let hasBadges: Bool = hasAnyBadge(total: total, members: members)
        if hasBadges {
            FlowLayout(spacing: 6) {
                if card.isBlocked {
                    Text("Blocked").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 4)
                        .background(Color(hex: "#c9372c"), in: RoundedRectangle(cornerRadius: 3))
                        .help("Blocked by " + card.blockedByTitles.joined(separator: ", "))
                }
                if card.isBlocking {
                    Text("Blocking").font(.caption.bold()).foregroundStyle(Color(hex: "#172b4d")).padding(.horizontal, 4)
                        .background(Color(hex: "#f5cd47"), in: RoundedRectangle(cornerRadius: 3))
                        .help("Blocking " + card.blockingTitles.joined(separator: ", "))
                }
                if card.watching == true { Image(systemName: "eye").help("You're watching this card") }
                DueBadge(card: card) { if model.canEdit { model.updateCard(card.id, .init(dueComplete: !card.dueComplete)) } }
                if !card.description.isEmpty { Image(systemName: "text.alignleft").help("This card has a description") }
                if card.commentCount > 0 { Label("\(card.commentCount)", systemImage: "bubble.left") }
                if card.attachmentCount > 0 { Label("\(card.attachmentCount)", systemImage: "paperclip") }
                if total > 0 {
                    Label("\(done)/\(total)", systemImage: "checklist")
                        .padding(.horizontal, done == total ? 4 : 0)
                        .foregroundStyle(done == total ? Color.white : Color.secondary)
                        .background(done == total ? Color(hex: "#1f845a") : .clear, in: RoundedRectangle(cornerRadius: 3))
                }
                if !members.isEmpty { AvatarStack(users: members, account: model.account, size: 22, max: 4) }
            }
            .font(.caption)
            .labelStyle(CompactLabelStyle())
            .foregroundStyle(.secondary)
        }
    }
}

extension CardFront {
    func hasAnyBadge(total: Int, members: [User]) -> Bool {
        if card.due != nil || card.watching == true || !card.description.isEmpty { return true }
        if card.commentCount > 0 || card.attachmentCount > 0 || total > 0 { return true }
        return card.isBlocked || card.isBlocking || !members.isEmpty
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon; configuration.title }
    }
}

/// Right-click menu on a card front: the web's quick editor actions.
struct CardQuickMenu: View {
    let model: BoardModel
    let card: Card
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Open card") { app.open(card: card.id, in: model.account) }
        if model.canEdit, let board = model.board {
            Button(card.dueComplete ? "Mark incomplete" : "Mark complete") { model.updateCard(card.id, .init(dueComplete: !card.dueComplete)) }
            Menu("Labels") {
                ForEach(board.labels) { l in
                    Button { model.toggleLabel(card: card.id, label: l) } label: {
                        Label(l.name.isEmpty ? (l.color ?? "No colour") : l.name, systemImage: card.labelIds.contains(l.id) ? "checkmark.square" : "square")
                    }
                }
            }
            Menu("Members") {
                ForEach(board.members, id: \.userId) { m in
                    Button { model.toggleMember(card: card.id, user: m.user) } label: {
                        Label(m.user.displayName, systemImage: card.memberIds.contains(m.userId) ? "checkmark.square" : "square")
                    }
                }
            }
            Menu("Due date") {
                Button("Today") { model.updateCard(card.id, .init(due: .some(Self.at(0)))) }
                Button("Tomorrow") { model.updateCard(card.id, .init(due: .some(Self.at(1)))) }
                Button("In a week") { model.updateCard(card.id, .init(due: .some(Self.at(7)))) }
                if card.due != nil { Button("Remove due date") { model.updateCard(card.id, .init(due: .some(nil))) } }
            }
            Menu("Move to") {
                ForEach(board.lists.filter { $0.id != card.listId }) { l in
                    Button(l.name) { model.moveCard(card.id, to: l.id, before: nil) }
                }
            }
            Button("Copy card") {
                model.copyCard(card.id, title: card.title, listId: card.listId, keep: .init())
            }
            Button(card.watching == true ? "Stop watching" : "Watch") { model.toggleWatch(card: card.id) }
            Divider()
            Button("Archive (c)") { model.updateCard(card.id, .init(closed: true)) }
        }
        Button("Copy link") { copyToPasteboard(model.account.client.webURL("/c/\(card.id)").absoluteString) }
    }

    static func at(_ days: Int) -> Date {
        let cal = Calendar.current
        let hour = UserDefaults.standard.object(forKey: "hackban:defaultDueHour") as? Int ?? 12
        let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }
}

/// The web's quick editor (`e`): edit the title in place, plus the common actions.
struct QuickEditPopover: View {
    let model: BoardModel
    let card: Card
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Spacer()
                Menu("More") { CardQuickMenu(model: model, card: card) }.fixedSize()
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { title = card.title }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != card.title { model.updateCard(card.id, .init(title: t)) }
        dismiss()
    }
}

/// Wrapping horizontal layout for labels and badges.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
