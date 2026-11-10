import SwiftUI

/// Copista's own touches, kept to the moments that have room for them: the first run and empty
/// states. Everything you work with stays a standard control, as it should on a Mac. Headings there
/// use the system's serif, which suits a tool for engraved music.
extension View {
    func brandHeadingFont(_ style: Font = .title.bold()) -> some View {
        font(style).fontDesign(.serif)
    }
}

/// Two beamed eighth notes: the glyph from the app icon, which `Design/make_icon.swift` draws too.
nonisolated struct CopistaNotes: Shape {
    func path(in rect: CGRect) -> Path {
        // Laid out as in the icon's artwork, y up, then fitted to the rect.
        let bounds = CGRect(x: 340, y: 360, width: 332, height: 350)
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let toRect = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)

        // Merged, not just added to one path: overlapping pieces drawn in opposite directions
        // would cancel out where they meet.
        var notes = Path()
        let heads = [CGPoint(x: 404, y: 408), CGPoint(x: 612, y: 448)]
        let stemTops: [CGFloat] = [668, 708]
        for (head, top) in zip(heads, stemTops) {
            let tilt = CGAffineTransform(translationX: head.x, y: head.y).rotated(by: 22 * .pi / 180)
            notes = notes.union(Path(ellipseIn: CGRect(x: -58, y: -40, width: 116, height: 80)).applying(tilt))
            notes = notes.union(Path(CGRect(x: head.x + 37, y: head.y + 8, width: 16, height: top - head.y - 8)))
        }
        var beam = Path()
        beam.addLines([
            CGPoint(x: heads[0].x + 37, y: stemTops[0]),
            CGPoint(x: heads[1].x + 53, y: stemTops[1]),
            CGPoint(x: heads[1].x + 53, y: stemTops[1] - 46),
            CGPoint(x: heads[0].x + 37, y: stemTops[0] - 46),
        ])
        beam.closeSubpath()
        notes = notes.union(beam)
        return notes.applying(toRect)
    }
}

/// Copies of a sheet of music, as on the app icon, which fan out further when something is dragged
/// over them: the same stack the app is about to make out of what's dropped.
struct SheetStackIllustration: View {
    var isFannedOut = false
    var size = CGSize(width: 120, height: 160)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            sheet.opacity(0.55).rotationEffect(.degrees(isFannedOut ? 24 : 13), anchor: .bottom)
            sheet.opacity(0.8).rotationEffect(.degrees(isFannedOut ? 12 : 6), anchor: .bottom)
            frontSheet.rotationEffect(.degrees(isFannedOut ? -6 : -3), anchor: .bottom)
        }
        .frame(width: size.width * 1.7, height: size.height * 1.1)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: isFannedOut)
        .accessibilityHidden(true)
    }

    private var sheet: some View {
        RoundedRectangle(cornerRadius: size.width * 0.05)
            .fill(Color.brandPaper)
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .frame(width: size.width, height: size.height)
    }

    private var frontSheet: some View {
        sheet
            .overlay {
                VStack {
                    staff
                    Spacer()
                    staff
                }
                .padding(.vertical, size.height * 0.1)
                .padding(.horizontal, size.width * 0.1)
            }
            .overlay {
                CopistaNotes()
                    .fill(Color.brandInkOnPaper)
                    .padding(size.width * 0.2)
            }
    }

    private var staff: some View {
        VStack(spacing: size.height * 0.024) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle()
                    .fill(Color.brandInkOnPaper.opacity(0.25))
                    .frame(height: 1)
            }
        }
    }
}

/// The real app icon, wherever the app introduces itself, so it's the same one the Dock shows.
struct AppIconImage: View {
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
