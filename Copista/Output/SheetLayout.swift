import Foundation
import CoreGraphics

/// The result of fitting one source page (or half-page) onto an A4 sheet: which orientation was
/// chosen, the transform that maps the page's raw, unrotated user space into sheet space, and
/// the rect on the sheet the content actually occupies (used both to draw and to clip).
nonisolated struct SheetPlan: Sendable {
    var sheetSize: CGSize
    var destRect: CGRect
    var transform: CGAffineTransform
    var isLandscape: Bool
    var scale: CGFloat
}

/// Computes the transform that fits a source PDF page onto an A4 sheet: undoes the page's own
/// rotation, applies an optional split-half crop and an optional extra user rotation, then scales
/// to fit A4 (portrait or landscape, whichever is the better fit) with a 5 mm margin, centred.
///
/// Coordinate policy: PDF/CoreGraphics user space is lower-left origin, y-up — the same
/// convention Vision's `NormalizedRect` uses, which is why a `PageItem.cropRect` normalized in
/// that space can be used directly here with no flip. SwiftUI is the only upper-left-origin
/// space in this app, and no SwiftUI code should touch a `SheetPlan` directly.
///
/// This is a pure function of its inputs — no PDFKit types appear here — so it is fully testable
/// without a PDF fixture.
nonisolated enum SheetLayout {
    static let a4Portrait = CGSize(width: 595.276, height: 841.890)
    static let a4Landscape = CGSize(width: 841.890, height: 595.276)
    static let margin: CGFloat = 5.0 * 72.0 / 25.4   // 5 mm in points ≈ 14.1732 pt

    static func plan(geometry: PageGeometry, extraRotation: Int = 0, cropRect: CGRect? = nil, margin: CGFloat = margin) -> SheetPlan {
        let box = geometry.cropBox

        // 1. translate the crop box's own origin to zero.
        let t1 = CGAffineTransform(translationX: -box.minX, y: -box.minY)

        // 2. undo the page's intrinsic /Rotate, landing in "upright" space.
        let (t2, upright) = rotate(geometry.rotation, box.width, box.height)

        // 3. select the normalized sub-rect (a split half, or the whole page) and move it to the origin.
        let selection = (cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)).standardized
        let content = CGRect(
            x: selection.minX * upright.width,
            y: selection.minY * upright.height,
            width: selection.width * upright.width,
            height: selection.height * upright.height
        )
        let t3 = CGAffineTransform(translationX: -content.minX, y: -content.minY)

        // 4. the user's requested extra rotation (rotate/split editor), clockwise.
        let (t4, visual) = rotate(extraRotation, content.width, content.height)

        // 5. pick whichever A4 orientation yields the larger fit scale, then scale to fit with a margin.
        let scalePortrait = fitScale(visual, in: a4Portrait, margin: margin)
        let scaleLandscape = fitScale(visual, in: a4Landscape, margin: margin)
        let isLandscape = scaleLandscape > scalePortrait
        let sheet = isLandscape ? a4Landscape : a4Portrait
        let scale = max(scalePortrait, scaleLandscape)
        let t5 = CGAffineTransform(scaleX: scale, y: scale)

        // 6. centre the scaled content on the sheet.
        let drawSize = CGSize(width: visual.width * scale, height: visual.height * scale)
        let dest = CGRect(
            x: (sheet.width - drawSize.width) / 2,
            y: (sheet.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let t6 = CGAffineTransform(translationX: dest.minX, y: dest.minY)

        let transform = t1.concatenating(t2).concatenating(t3).concatenating(t4).concatenating(t5).concatenating(t6)
        return SheetPlan(sheetSize: sheet, destRect: dest, transform: transform, isLandscape: isLandscape, scale: scale)
    }

    /// Normalizes any rotation to one of 0/90/180/270.
    static func quarter(_ degrees: Int) -> Int {
        (((degrees % 360) + 360) % 360) / 90 * 90
    }

    /// A clockwise rotation of an origin-anchored `w`×`h` box, translated back into the first
    /// quadrant. Returns the transform and the rotated box's new size.
    static func rotate(_ degrees: Int, _ w: CGFloat, _ h: CGFloat) -> (CGAffineTransform, CGSize) {
        switch quarter(degrees) {
        case 90:
            let t = CGAffineTransform(rotationAngle: -.pi / 2).concatenating(CGAffineTransform(translationX: 0, y: w))
            return (t, CGSize(width: h, height: w))
        case 180:
            let t = CGAffineTransform(rotationAngle: .pi).concatenating(CGAffineTransform(translationX: w, y: h))
            return (t, CGSize(width: w, height: h))
        case 270:
            let t = CGAffineTransform(rotationAngle: .pi / 2).concatenating(CGAffineTransform(translationX: h, y: 0))
            return (t, CGSize(width: h, height: w))
        default:
            return (.identity, CGSize(width: w, height: h))
        }
    }

    static func fitScale(_ size: CGSize, in sheet: CGSize, margin: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min((sheet.width - 2 * margin) / size.width, (sheet.height - 2 * margin) / size.height)
    }
}
