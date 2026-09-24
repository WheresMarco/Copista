import Foundation
import CoreGraphics

enum DetectionSource: Codable, Hashable {
    case bookmark
    case filename
    case textLayer
    case ocr
    case manual
    case continuation
}

struct PageItem: Identifiable, Hashable {
    let id: UUID
    let documentID: UUID
    let pageIndex: Int
    var rotation: Int                 // extra rotation to apply, 0/90/180/270
    var cropRect: CGRect?             // nil = whole page; set for split halves (page-space, normalized 0…1)
    var detectedText: String?         // raw name found
    var confidence: Double            // 0…1
    var source: DetectionSource
}
