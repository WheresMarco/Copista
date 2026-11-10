import Foundation

/// Which pages are marked in Review, following the same rules as Finder: a click selects one page,
/// ⌘-click adds or removes one, and ⇧-click takes in everything from the last plain click.
nonisolated struct PageSelection: Equatable, Sendable {
    enum Modifier: Sendable {
        case none, toggle, extend
    }

    private(set) var ids: Set<UUID> = []
    /// The page ⇧-click and ⇧-arrow measure from.
    private(set) var anchor: UUID?
    /// The page most recently acted on: what Quick Look opens and what scrolls into view.
    private(set) var focus: UUID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    /// The selected pages, in the order they're shown.
    func orderedIDs(in order: [UUID]) -> [UUID] {
        order.filter(ids.contains)
    }

    mutating func click(_ id: UUID, modifier: Modifier, in order: [UUID]) {
        switch modifier {
        case .none:
            ids = [id]
            anchor = id
        case .toggle:
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        case .extend:
            ids = range(from: anchor ?? id, to: id, in: order)
            if anchor == nil { anchor = id }
        }
        focus = id
    }

    /// Arrow keys: steps from the focused page, taking the pages in between along when extending.
    mutating func move(by offset: Int, extending: Bool, in order: [UUID]) {
        guard !order.isEmpty else { return }
        guard let focus, let current = order.firstIndex(of: focus) else {
            if let first = order.first { click(first, modifier: .none, in: order) }
            return
        }
        let target = order[min(max(current + offset, 0), order.count - 1)]
        click(target, modifier: extending ? .extend : .none, in: order)
    }

    mutating func select(_ pageIDs: [UUID]) {
        ids = Set(pageIDs)
        anchor = pageIDs.first
        focus = pageIDs.first
    }

    mutating func clear() {
        self = PageSelection()
    }

    private func range(from start: UUID, to end: UUID, in order: [UUID]) -> Set<UUID> {
        guard let a = order.firstIndex(of: start), let b = order.firstIndex(of: end) else { return [end] }
        return Set(order[min(a, b)...max(a, b)])
    }
}
