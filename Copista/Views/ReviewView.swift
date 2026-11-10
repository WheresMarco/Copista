import SwiftUI
import AppKit
import QuickLook

struct ReviewView: View {
    let song: Song
    @Environment(AppModel.self) private var model
    @State private var unknownSheetPage: (id: UUID, text: String)?
    @State private var selection = PageSelection()
    @State private var quickLookItems: [URL] = []
    @State private var quickLookURL: URL?
    @State private var isPreparingQuickLook = false
    @State private var dropIndicator: DropIndicator?
    @State private var dropTargetPartID: UUID?
    @AppStorage("reviewPageWidth") private var pageWidth = PageThumbnailView.defaultWidth
    @FocusState private var isGridFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ReviewActionBar(
                selectedCount: selection.count,
                canConfirm: selectedFlaggedIDs.isEmpty == false,
                hasPages: !orderedPages.isEmpty,
                isPreparingQuickLook: isPreparingQuickLook,
                instrumentGroups: instrumentGroups,
                onQuickLook: toggleQuickLook,
                onSelectAll: { selection.select(pageOrder) },
                onDeselect: { selection.clear() },
                onAssign: { assign($0, to: selectedIDs) },
                onConfirm: { model.confirmPages(selectedFlaggedIDs, inSongID: song.id) },
                onMarkAsScore: {
                    model.markAsScore(selectedIDs, inSongID: song.id)
                    selection.clear()
                },
                onExclude: {
                    model.excludePages(selectedIDs, inSongID: song.id)
                    selection.clear()
                },
                onRotate: { model.rotatePages(selectedIDs, inSongID: song.id) }
            )
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ReviewIssuesPanel(
                            items: song.reviewItems,
                            instrumentName: instrumentName,
                            onSelect: { selection.select(orderedSubset($0)) },
                            onConfirm: { model.confirmPages($0, inSongID: song.id) }
                        )

                        if let pageCount = includedScorePageCount {
                            ScoreBanner(song: song, pageCount: pageCount)
                        }

                        ForEach(partGroups) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                if case .section(let section) = group.kind {
                                    Text(section.title)
                                        .brandHeadingFont(.title3.bold())
                                        .padding(.horizontal)
                                }
                                ForEach(group.parts) { part in
                                    partView(part)
                                }
                            }
                        }
                    }
                    .padding(.vertical)
                }
                .focusable(interactions: .edit)
                .focused($isGridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                    if press.modifiers.contains(.option) {
                        model.shiftPages(selectedIDs, later: press.key == .rightArrow, inSongID: song.id)
                    } else {
                        selection.move(by: press.key == .leftArrow ? -1 : 1, extending: press.modifiers.contains(.shift), in: pageOrder)
                    }
                    return .handled
                }
                .onChange(of: selection.focus) { _, pageID in
                    if let pageID { proxy.scrollTo(pageID) }
                }
            }
            Divider()
            ReviewStatusBar(pageWidth: $pageWidth)
        }
        .quickLookPreview($quickLookURL, in: quickLookItems)
        .onChange(of: quickLookURL) { _, url in
            // Arrow keys in the panel page through the song: keep the selection up with them. With
            // several pages marked the panel only pages through those, and the marks stay as they are.
            if selection.count <= 1, let url, let page = orderedPages.first(where: { QuickLookFiles.url(for: $0) == url }) {
                selection.click(page.id, modifier: .none, in: pageOrder)
            }
        }
        .onChange(of: song.id) {
            selection.clear()
            quickLookURL = nil
            quickLookItems = []
        }
        .sheet(item: Binding(
            get: { unknownSheetPage.map { IdentifiablePage(id: $0.id, text: $0.text) } },
            set: { unknownSheetPage = $0.map { ($0.id, $0.text) } }
        )) { page in
            UnknownNameSheet(detectedText: page.text, pageID: page.id, songID: song.id)
        }
    }

    private func partView(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(headerColor(for: part)).frame(width: 8, height: 8)
                Text(partTitle(part)).font(.headline)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Color.brandInk.opacity(dropTargetPartID == part.id ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            // Dropped on the name: to the end of that part.
            .dropDestination(for: String.self) { items, _ in
                guard let last = part.pages.last else { return false }
                return handleDrop(items, on: last, after: true)
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetPartID = part.id
                } else if dropTargetPartID == part.id {
                    dropTargetPartID = nil
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: pageWidth, maximum: pageWidth), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(part.pages) { page in
                    if let url = model.sourceDocuments[page.documentID]?.url {
                        PageThumbnailView(
                            documentURL: url, pageIndex: page.pageIndex, rotation: page.rotation,
                            flag: pageFlags[page.id],
                            caption: caption(for: page, flag: pageFlags[page.id]),
                            isSelected: selection.contains(page.id),
                            position: part.pages.count > 1 ? (part.pages.firstIndex { $0.id == page.id } ?? 0) + 1 : nil,
                            width: pageWidth,
                            accessibilityLabel: accessibilityLabel(for: part, page: page)
                        )
                        .id(page.id)
                        .overlay(alignment: dropIndicator?.isAfter == true ? .trailing : .leading) {
                            if dropIndicator?.pageID == page.id {
                                Capsule()
                                    .fill(Color.brandInk)
                                    .frame(width: 3)
                                    .offset(x: dropIndicator?.isAfter == true ? 6 : -6)
                            }
                        }
                        .overlay { dropZones(for: page) }
                        .draggable(page.id.uuidString) {
                            PageThumbnailView(
                                documentURL: url, pageIndex: page.pageIndex, rotation: page.rotation, flag: nil, caption: nil,
                                isSelected: false, accessibilityLabel: ""
                            )
                        }
                        .accessibilityAction(named: Text("Move Earlier")) { model.shiftPages([page.id], later: false, inSongID: song.id) }
                        .accessibilityAction(named: Text("Move Later")) { model.shiftPages([page.id], later: true, inSongID: song.id) }
                        .contextMenu { pageContextMenu(page: page, part: part) }
                        .onTapGesture(count: 2) {
                            if case .unassigned = part.kind {
                                unknownSheetPage = (page.id, page.detectedText ?? "")
                            } else {
                                showQuickLook(of: page.id)
                            }
                        }
                        // Simultaneous, or every click would wait to see if it's a double-click.
                        .simultaneousGesture(TapGesture().onEnded { handleClick(on: page.id) })
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Reordering

    private struct DropIndicator: Equatable {
        let pageID: UUID
        let isAfter: Bool
    }

    /// A page drops before or after the one under it, depending on which half it's over, and into
    /// that page's part, whichever part it came from.
    private func dropZones(for page: PageItem) -> some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { isAfter in
                Color.clear
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, on: page, after: isAfter)
                    } isTargeted: { isTargeted in
                        let indicator = DropIndicator(pageID: page.id, isAfter: isAfter)
                        if isTargeted {
                            dropIndicator = indicator
                        } else if dropIndicator == indicator {
                            dropIndicator = nil
                        }
                    }
            }
        }
    }

    /// Dragging a marked page takes the other marked ones along, as in Finder.
    private func handleDrop(_ items: [String], on target: PageItem, after: Bool) -> Bool {
        defer {
            dropIndicator = nil
            dropTargetPartID = nil
        }
        guard let dragged = items.first.flatMap(UUID.init(uuidString:)), pageOrder.contains(dragged) else { return false }
        let moving = selection.contains(dragged) ? selectedIDs : [dragged]
        guard !moving.contains(target.id) else { return false }
        model.movePages(moving, nextTo: target.id, after: after, inSongID: song.id)
        return true
    }

    // MARK: - Selection

    private var partGroups: [PartGroup] {
        song.partGroups(instruments: model.settings.instruments)
    }

    private var pageOrder: [UUID] {
        orderedPages.map(\.id)
    }

    private var selectedIDs: [UUID] {
        selection.orderedIDs(in: pageOrder)
    }

    /// The selected pages that have something to confirm.
    private var selectedFlaggedIDs: [UUID] {
        selectedIDs.filter { pageFlags[$0] != nil && pageFlags[$0] != .noInstrument }
    }

    private func orderedSubset(_ ids: [UUID]) -> [UUID] {
        pageOrder.filter(ids.contains)
    }

    private func handleClick(on pageID: UUID) {
        let flags = NSEvent.modifierFlags
        let modifier: PageSelection.Modifier = flags.contains(.shift) ? .extend : flags.contains(.command) ? .toggle : .none
        selection.click(pageID, modifier: modifier, in: pageOrder)
        isGridFocused = true
    }

    private func assign(_ instrumentID: UUID, to pageIDs: [UUID]) {
        model.setInstrument(instrumentID, forPageIDs: pageIDs, inSongID: song.id)
        selection.clear()
    }

    /// What a right-click acts on, as in Finder: the whole selection if the page is part of it.
    private func contextTargets(for page: PageItem) -> [UUID] {
        selection.contains(page.id) ? selectedIDs : [page.id]
    }

    // MARK: - Quick Look

    /// Every page of the song, in the order the parts show them.
    private var orderedPages: [QuickLookFiles.Page] {
        partGroups.flatMap(\.parts).flatMap { part in
            part.pages.enumerated().compactMap { position, page -> QuickLookFiles.Page? in
                guard let url = model.sourceDocuments[page.documentID]?.url else { return nil }
                let name = partTitle(part)
                let number = position + 1
                return QuickLookFiles.Page(
                    id: page.id, documentURL: url, pageIndex: page.pageIndex, rotation: page.rotation, cropRect: page.cropRect,
                    title: String(localized: "\(name), page \(number)", comment: "VoiceOver label for a page thumbnail")
                )
            }
        }
    }

    private func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else if let pageID = selection.focus ?? orderedPages.first?.id {
            showQuickLook(of: pageID)
        }
    }

    private func showQuickLook(of pageID: UUID) {
        let all = orderedPages
        guard let target = all.first(where: { $0.id == pageID }) else { return }
        if !selection.contains(pageID) { selection.click(pageID, modifier: .none, in: pageOrder) }
        // With several pages marked the panel pages through just those, as in Finder.
        let pages = selection.count > 1 ? all.filter { selection.contains($0.id) } : all
        Task {
            isPreparingQuickLook = true
            defer { isPreparingQuickLook = false }
            do {
                quickLookItems = try await QuickLookFiles.prepare(pages)
                quickLookURL = QuickLookFiles.url(for: target)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Parts

    private var instrumentGroups: [InstrumentCatalog.SectionGroup] {
        InstrumentCatalog.grouped(model.settings.instruments)
    }

    private var pageFlags: [UUID: ReviewItem.Kind] {
        // Reversed so the most urgent reason wins for a page with more than one.
        song.reviewItems.reversed().reduce(into: [:]) { flags, item in
            for id in item.pageIDs { flags[id] = item.kind }
        }
    }

    private func instrumentName(_ id: UUID) -> String {
        model.settings.instruments.first { $0.id == id }?.displayName ?? String(localized: "Unknown instrument")
    }

    private func caption(for page: PageItem, flag: ReviewItem.Kind?) -> String? {
        let text = page.detectedText?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(40)
        switch flag {
        case .noInstrument:
            guard let text, !text.isEmpty else { return String(localized: "No name found") }
            return String(localized: "Read: \(String(text))", comment: "Under a page: the text OCR read as the part's name")
        case .hardToRead, .unknownLabel:
            // Words in the label's place may well be a new part's name that wasn't recognized.
            guard let text, !text.isEmpty else { return nil }
            return String(localized: "Read: \(String(text))", comment: "Under a page: the text OCR read as the part's name")
        default:
            return nil
        }
    }

    private var includedScorePageCount: Int? {
        for issue in song.issues {
            if case .includesScore(let count) = issue { return count }
        }
        return nil
    }

    private func partTitle(_ part: Part) -> String {
        if case .score = part.kind { return String(localized: "Score", comment: "Full orchestral score (partitur)") }
        if case .blank = part.kind { return String(localized: "Blank or excluded (won't print)") }
        if case .unassigned = part.kind { return String(localized: "Unknown instrument") }
        guard case .instrument(let id) = part.kind else { return "" }
        let name = ([id] + part.extraInstruments).map(instrumentName).joined(separator: " + ")
        // A second part for the same instrument: say what sets it apart from the first.
        if let label = part.variantLabel?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !label.isEmpty {
            return "\(name) · “\(label.prefix(30))”"
        }
        return name
    }

    private func headerColor(for part: Part) -> Color {
        switch part.kind {
        case .score: return .purple
        case .blank: return .gray
        case .unassigned: return .red
        // Not the accent color: orange means "needs checking" here, and it can be orange too.
        case .instrument: return part.needsDuplicateReview && part.variantLabel != nil ? .orange : .secondary
        }
    }

    private func accessibilityLabel(for part: Part, page: PageItem) -> String {
        let name = partTitle(part)
        let pageNumber = page.pageIndex + 1
        if page.isUncertain {
            return String(localized: "\(name), page \(pageNumber), low confidence", comment: "VoiceOver label for a page thumbnail with an uncertain instrument match")
        }
        return String(localized: "\(name), page \(pageNumber)", comment: "VoiceOver label for a page thumbnail")
    }

    @ViewBuilder
    private func pageContextMenu(page: PageItem, part: Part) -> some View {
        let targets = contextTargets(for: page)
        let flagged = targets.filter { pageFlags[$0] != nil && pageFlags[$0] != .noInstrument }
        if targets.count > 1 {
            Text("Selected pages: \(targets.count)")
            Divider()
        }
        Button("Quick Look") { showQuickLook(of: page.id) }
        Divider()
        InstrumentMenu(title: Text("Set instrument"), groups: instrumentGroups) { assign($0, to: targets) }
        if targets.count == 1, part.pages.last?.id != page.id {
            InstrumentMenu(title: Text("Set instrument from here on"), groups: instrumentGroups) {
                model.setInstrument($0, fromPageID: page.id, inSongID: song.id)
                selection.clear()
            }
        }
        if !flagged.isEmpty {
            Button("This Is Right") { model.confirmPages(flagged, inSongID: song.id) }
        }
        Divider()
        Button("Mark as score") {
            model.markAsScore(targets, inSongID: song.id)
            selection.clear()
        }
        Button("Exclude page") {
            model.excludePages(targets, inSongID: song.id)
            selection.clear()
        }
        Button("Rotate") { model.rotatePages(targets, inSongID: song.id) }
        if part.pages.count > 1 {
            Divider()
            let inThisPart = targets.filter { id in part.pages.contains { $0.id == id } }
            Button("Move Earlier") { model.shiftPages(inThisPart, later: false, inSongID: song.id) }
                .disabled(part.pages.first.map { inThisPart.contains($0.id) } ?? true)
            Button("Move Later") { model.shiftPages(inThisPart, later: true, inSongID: song.id) }
                .disabled(part.pages.last.map { inThisPart.contains($0.id) } ?? true)
        }
    }
}

/// Always-visible actions above the pages, so what can be done to the marked pages stays in reach
/// however far down they are.
struct ReviewActionBar: View {
    let selectedCount: Int
    let canConfirm: Bool
    let hasPages: Bool
    let isPreparingQuickLook: Bool
    let instrumentGroups: [InstrumentCatalog.SectionGroup]
    let onQuickLook: () -> Void
    let onSelectAll: () -> Void
    let onDeselect: () -> Void
    let onAssign: (UUID) -> Void
    let onConfirm: () -> Void
    let onMarkAsScore: () -> Void
    let onExclude: () -> Void
    let onRotate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onQuickLook) {
                // Icon only while pages are marked: the bar needs the room for what acts on them.
                if selectedCount == 0 {
                    Label("Quick Look", systemImage: "eye")
                } else {
                    Label("Quick Look", systemImage: "eye").labelStyle(.iconOnly)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!hasPages)
            .help("Quick Look")
            .fixedSize()

            if selectedCount == 0 {
                Button("Select All", action: onSelectAll)
                    .disabled(!hasPages)
                    .fixedSize()
            } else {
                Divider().frame(height: 18)
                Text("Selected pages: \(selectedCount)")
                    .font(.callout.bold())
                    .fixedSize()
                InstrumentMenu(title: Text("Set instrument"), groups: instrumentGroups, onPick: onAssign)
                    .fixedSize()
                HStack(spacing: 8) {
                    Button("This Is Right", action: onConfirm)
                        .disabled(!canConfirm)
                    Button("Score", action: onMarkAsScore)
                        .help("Mark as score")
                    Button("Exclude", action: onExclude)
                    Button("Rotate", action: onRotate)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            if isPreparingQuickLook { ProgressView().controlSize(.small) }
            if selectedCount > 0 {
                Button(action: onDeselect) {
                    Label("Deselect", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .keyboardShortcut(.cancelAction)
                .help("Deselect")
                .fixedSize()
            }
        }
        .background {
            // ⌘A has to work whether or not the visible Select All button is showing.
            Button("", action: onSelectAll)
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Along the bottom of the pages, as in Finder: how to work with them, and how big to show them.
struct ReviewStatusBar: View {
    @Binding var pageWidth: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("Click to mark a page, ⌘- or ⇧-click for several. Drag to move. Space for a closer look.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Image(systemName: "doc.text")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $pageWidth, in: PageThumbnailView.widthRange) {
                Text("Page Size")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            .help("Page Size")
            Image(systemName: "doc.text")
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// A list of what needs doing in a song, each with the reason and the way to deal with it.
struct ReviewIssuesPanel: View {
    let items: [ReviewItem]
    let instrumentName: (UUID) -> String
    let onSelect: ([UUID]) -> Void
    let onConfirm: ([UUID]) -> Void

    private var hasSomethingToDo: Bool {
        items.contains { $0.severity != .note }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hasSomethingToDo {
                Label {
                    Text("Nothing needs doing in this song.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
            }
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.horizontal)
    }

    private func row(_ item: ReviewItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.severity.systemImage)
                .foregroundStyle(item.severity.color)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title(item).font(.callout.bold())
                detail(item).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Select Pages") { onSelect(item.pageIDs) }
                confirmButton(item)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(10)
        .background(item.severity.color.opacity(item.severity == .note ? 0.05 : 0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func title(_ item: ReviewItem) -> Text {
        let count = item.pageIDs.count
        switch item.kind {
        case .noInstrument: return Text("Pages with no instrument (\(count))")
        case .hardToRead: return Text("Pages that need checking (\(count))")
        case .duplicatePart(let id): return Text("More than one part for \(instrumentName(id))")
        case .unknownLabel: return Text("Pages with unfamiliar words at the top (\(count))")
        }
    }

    private func detail(_ item: ReviewItem) -> Text {
        switch item.kind {
        case .noInstrument:
            return Text("These won't print until they have an instrument. Select them and choose one above, or exclude them. Double-click a page to also teach Copista the name.")
        case .hardToRead:
            return Text("Copista barely read the name, so the instrument is a guess. What it read is shown under each page. Change the wrong ones, then confirm the rest.")
        case .duplicatePart:
            return Text("All of them will print. If these pages belong to another instrument, select them and change it. If this is right, keep them.")
        case .unknownLabel:
            return Text("Kept with the part before them, since no instrument was found in the top corners. If what's shown under a page is a new part's name, select that page and choose the instrument. The pages after it follow.")
        }
    }

    @ViewBuilder
    private func confirmButton(_ item: ReviewItem) -> some View {
        switch item.kind {
        case .noInstrument:
            EmptyView()
        case .duplicatePart:
            Button("Keep") { onConfirm(item.pageIDs) }
        case .hardToRead, .unknownLabel:
            Button("All Are Right") { onConfirm(item.pageIDs) }
        }
    }
}

extension ReviewItem.Severity {
    var systemImage: String {
        switch self {
        case .mustFix: "exclamationmark.octagon.fill"
        case .check: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .mustFix: .red
        case .check: .orange
        case .note: .secondary
        }
    }
}

/// Every instrument, a submenu per section: 49 in one list wouldn't fit on most screens.
struct InstrumentMenu: View {
    let title: Text
    let groups: [InstrumentCatalog.SectionGroup]
    let onPick: (UUID) -> Void

    var body: some View {
        Menu {
            ForEach(groups) { group in
                Menu(group.section.title) {
                    ForEach(group.instruments) { instrument in
                        Button(instrument.displayName) { onPick(instrument.id) }
                    }
                }
            }
        } label: {
            title
        }
    }
}

private struct IdentifiablePage: Identifiable {
    let id: UUID
    let text: String
}

private struct ScoreBanner: View {
    let song: Song
    let pageCount: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("This song includes a score (\(pageCount) pages). Include it in the print?")
            Spacer()
            Toggle("", isOn: Binding(
                get: { song.includeScore },
                set: { model.setIncludeScore($0, forSongID: song.id) }
            )).labelsHidden()
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}
