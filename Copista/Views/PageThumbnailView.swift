import SwiftUI
import PDFKit

struct PageThumbnailView: View {
    let documentURL: URL
    let pageIndex: Int
    let rotation: Int
    let flag: ReviewItem.Kind?
    let caption: String?
    let isSelected: Bool
    /// Its place in the part, shown on parts of more than one page, where order is something to get right.
    var position: Int?
    var width = PageThumbnailView.defaultWidth
    let accessibilityLabel: String

    @State private var image: CGImage?

    static let defaultWidth = 90.0
    static let widthRange = 70.0...320.0

    private var height: Double { width * 4 / 3 }

    /// Pixels to draw the page at: enough for a Retina screen, in steps, since drawing at every
    /// point the size slider passes through would only hold it up.
    private var renderedLongSide: Int {
        Int((height * 2 / 240).rounded(.up)) * 240
    }

    private var severity: ReviewItem.Severity? {
        flag.map { ReviewItem(kind: $0, pageIDs: []).severity }
    }

    var body: some View {
        VStack(spacing: 3) {
            page
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(severity?.color ?? .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: width)
            }
        }
        .contentShape(Rectangle())
        .task(id: renderedLongSide) {
            // A sharper one is only worth drawing once the slider has stopped on a size that needs it.
            if let image {
                guard max(image.width, image.height) < renderedLongSide else { return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            image = await Self.render(documentURL, pageIndex: pageIndex, longSide: renderedLongSide)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(caption ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var page: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.white)
            // Pages are white, so on a white background they need an edge of their own.
            RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(Double(rotation)))
                    .scaleEffect(rotation % 180 == 0 ? 1 : 0.72)
                    .padding(2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, height: height)
        .overlay {
            if let severity, severity != .note {
                RoundedRectangle(cornerRadius: 4).strokeBorder(severity.color, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let severity {
                Image(systemName: severity.systemImage)
                    .foregroundStyle(severity.color)
                    .background(Circle().fill(.white).padding(1))
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let position {
                Text("\(position)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
        }
        // In a corner of its own: a part's name is printed at the top left of the page. Brand ink
        // rather than the accent color, which can be the same orange as "needs checking".
        .overlay(alignment: .bottomLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.brandInk)
                    .font(.title3)
                    .padding(4)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.brandInk, lineWidth: 3).padding(-3)
            }
        }
    }

    /// Off the main actor: a song can show dozens of these, and opening a PDF isn't free.
    private nonisolated static func render(_ url: URL, pageIndex: Int, longSide: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let page = PDFDocument(url: url)?.page(at: pageIndex) else { return nil }
            return PageRasterizer.raster(page, longSide: CGFloat(longSide))?.cgImage
        }.value
    }
}
