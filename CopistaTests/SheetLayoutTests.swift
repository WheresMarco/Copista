import Testing
import CoreGraphics
@testable import Copista

@Suite struct SheetLayoutTests {

    private func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    private func boundingBox(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test("Whole-page transform maps the crop box exactly onto destRect")
    func wholePageMapsOntoDestRect() {
        let box = CGRect(x: 10, y: 20, width: 595, height: 842)
        let geometry = PageGeometry(cropBox: box, rotation: 0)
        let plan = SheetLayout.plan(geometry: geometry)

        let mapped = corners(of: box).map { $0.applying(plan.transform) }
        #expect(approxEqual(boundingBox(of: mapped), plan.destRect))
    }

    @Test("No rotation combination ever mirrors the content", arguments: [0, 90, 180, 270], [0, 90, 180, 270])
    func noMirroring(_ pageRotation: Int, _ extraRotation: Int) {
        let geometry = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 595, height: 842), rotation: pageRotation)
        let plan = SheetLayout.plan(geometry: geometry, extraRotation: extraRotation)
        let t = plan.transform
        let determinant = t.a * t.d - t.b * t.c
        #expect(determinant > 0)
    }

    @Test("destRect is inset from the sheet by at least the margin, tight on one axis")
    func marginRespectedAndTight() {
        // A wide, short box: tight on width, loose on height.
        let geometry = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 1000, height: 100), rotation: 0)
        let plan = SheetLayout.plan(geometry: geometry)

        let leftInset = plan.destRect.minX
        let rightInset = plan.sheetSize.width - plan.destRect.maxX
        let topInset = plan.sheetSize.height - plan.destRect.maxY
        let bottomInset = plan.destRect.minY

        for inset in [leftInset, rightInset, topInset, bottomInset] {
            #expect(inset >= SheetLayout.margin - 0.01)
        }
        let isTight = [leftInset, rightInset, topInset, bottomInset].contains { abs($0 - SheetLayout.margin) < 0.01 }
        #expect(isTight)
    }

    @Test("A top-half crop occupies destRect; the bottom half falls entirely outside it")
    func splitHalfCropsCorrectly() {
        let box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let geometry = PageGeometry(cropBox: box, rotation: 0)
        let topHalf = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let plan = SheetLayout.plan(geometry: geometry, cropRect: topHalf)

        let topCorners = corners(of: CGRect(x: 0, y: 421, width: 595, height: 421)).map { $0.applying(plan.transform) }
        #expect(approxEqual(boundingBox(of: topCorners), plan.destRect))

        // Strictly inside the bottom half, away from the exact crop boundary (a point sitting
        // exactly on the boundary line correctly maps to destRect.minY, not below it).
        let bottomCorners = corners(of: CGRect(x: 0, y: 0, width: 595, height: 400)).map { $0.applying(plan.transform) }
        for point in bottomCorners {
            #expect(point.y < plan.destRect.minY - 0.01)
        }
    }

    @Test("A degenerate (zero-size) crop box does not produce NaN")
    func degenerateBoxIsSafe() {
        let geometry = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 0, height: 0), rotation: 0)
        let plan = SheetLayout.plan(geometry: geometry)
        #expect(plan.scale.isFinite)
        #expect(plan.destRect.minX.isFinite && plan.destRect.minY.isFinite)
        #expect(plan.destRect.width.isFinite && plan.destRect.height.isFinite)
    }

    @Test("A 90°-rotated landscape crop box becomes an upright A4 portrait sheet")
    func rotatedLandscapeBecomesPortrait() {
        let geometry = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 842, height: 595), rotation: 90)
        let plan = SheetLayout.plan(geometry: geometry)
        #expect(!plan.isLandscape)
    }
}
