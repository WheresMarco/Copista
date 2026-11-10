import Foundation
import CoreGraphics

nonisolated enum DetectionSource: Codable, Hashable, Sendable {
    case bookmark
    case filename
    case textLayer
    case ocr
    case intelligentOCR
    case manual
    case continuation
}

nonisolated struct PageItem: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let documentID: UUID
    let pageIndex: Int
    var rotation: Int                 // extra rotation to apply, 0/90/180/270
    var cropRect: CGRect?             // nil = whole page; normalized 0...1, lower-left origin,
                                       // expressed in "upright" space (i.e. after undoing the
                                       // page's intrinsic /Rotate). Top half = (0, 0.5, 1, 0.5).
    var detectedText: String?         // raw name found
    var confidence: Double            // 0...1
    var source: DetectionSource

    static let uncertainBelow = 0.6

    /// A name was read but barely. A continuation page, which never had a name, doesn't count.
    var isUncertain: Bool {
        confidence < Self.uncertainBelow && source != .continuation && source != .manual
    }
}

extension Array where Element == PageItem {
    /// These pages moved, together and in their current order, to just before or after `target`.
    /// Moving pages next to themselves changes nothing.
    nonisolated func moving(_ pageIDs: Set<UUID>, relativeTo target: UUID, after: Bool) -> [PageItem] {
        guard !pageIDs.contains(target) else { return self }
        var remaining = filter { !pageIDs.contains($0.id) }
        guard let index = remaining.firstIndex(where: { $0.id == target }) else { return self }
        remaining.insert(contentsOf: filter { pageIDs.contains($0.id) }, at: after ? index + 1 : index)
        return remaining
    }

    /// One step earlier or later, past the neighbouring page. Stays put at either end.
    nonisolated func shifting(_ pageIDs: Set<UUID>, later: Bool) -> [PageItem] {
        let selected = indices.filter { pageIDs.contains(self[$0].id) }
        guard let first = selected.first, let last = selected.last else { return self }
        if later {
            guard last + 1 < count else { return self }
            return moving(pageIDs, relativeTo: self[last + 1].id, after: true)
        }
        guard first > 0 else { return self }
        return moving(pageIDs, relativeTo: self[first - 1].id, after: false)
    }
}
