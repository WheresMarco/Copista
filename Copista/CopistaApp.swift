import SwiftUI

@main
struct CopistaApp: App {
    @State private var model = AppModel()

    init() {
        QuickLookFiles.removeAll()
    }

    var body: some Scene {
        // One window: all of its state lives in the one `AppModel`, so a second window would only
        // show the same songs, and the welcome guide twice.
        Window("Copista", id: "main") {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.corrections)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.isFileImporterPresented = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                Button("Review") { model.step = .review }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Copies") { model.step = .copies }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Print") { model.step = .print }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Welcome Guide") { model.isWelcomeGuidePresented = true }
            }
        }
        Settings {
            SettingsView()
                .environment(model.settings)
        }
    }
}
