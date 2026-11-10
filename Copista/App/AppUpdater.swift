import Foundation
import Observation
import Sparkle

/// Updates, through Sparkle: it reads the feed on GitHub, checks each update's signature against
/// the key built into the app, and installs it. A build without that key, like one made in Xcode,
/// never looks for updates, and neither do test runs.
@Observable
@MainActor
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    var downloadsAutomatically: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = downloadsAutomatically }
    }
    let isEnabled: Bool

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        isEnabled = !key.isEmpty && !isTesting
        controller = SPUStandardUpdaterController(startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        downloadsAutomatically = controller.updater.automaticallyDownloadsUpdates
        canCheckForUpdates = isEnabled && controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in
                guard let self else { return }
                self.canCheckForUpdates = self.isEnabled && canCheck
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// "1.2.0 (14)": the version people see, and the build number updates are compared by.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
