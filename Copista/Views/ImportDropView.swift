import SwiftUI

/// The empty state. The drop target and file importer themselves live on `RootView`, so files can
/// still be added once songs are showing.
struct ImportDropView: View {
    let isDropTargeted: Bool
    let onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            SheetStackIllustration(isFannedOut: isDropTargeted)
                .padding(.bottom, 4)
            Text("Drop PDFs or folders here")
                .brandHeadingFont(.title2.bold())
            Text("Files added together become one song. A folder is sorted into songs for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Add Files…", action: onAddFiles)
                .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.brandInk.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.tertiary))
                .padding()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Drop zone. Drop PDFs or folders here, or use Add Files."))
    }
}
