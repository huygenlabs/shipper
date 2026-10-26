import AppKit

/// Checks GitHub for a newer Shipper by reading the version in Info.plist on the main branch, the same commit that
/// carries Shipper.dmg. It only tells the user and opens the download; nothing is downloaded or installed on its own.
@MainActor
enum Updater {
    static let infoPlistURL = URL(string: "https://raw.githubusercontent.com/huygenlabs/shipper/main/Info.plist")!
    static let downloadURL = URL(string: "https://github.com/huygenlabs/shipper/raw/main/Shipper.dmg")!
    /// Shared with the menu's @AppStorage toggle.
    static let autoCheckKey = "checkForUpdates"

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// At launch, then daily while the app stays open.
    static func checkPeriodically() async {
        while !Task.isCancelled {
            if UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true { await check(userInitiated: false) }
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
        }
    }

    /// Automatic checks stay quiet unless there's an update the user hasn't skipped; a manual check always answers.
    static func check(userInitiated: Bool) async {
        guard let latest = await latestVersion() else {
            if userInitiated { inform("Couldn't check for updates", "Check your internet connection and try again.") }
            return
        }
        if isNewer(latest, than: current), userInitiated || UserDefaults.standard.string(forKey: "skippedVersion") != latest {
            offer(latest)
        } else if userInitiated {
            inform("Shipper is up to date", "Version \(current) is the latest.")
        }
    }

    static func latestVersion() async -> String? {
        let request = URLRequest(url: infoPlistURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return version(fromPlist: data)
    }

    /// Only a plain dotted number is accepted from the network.
    nonisolated static func version(fromPlist data: Data) -> String? {
        guard data.count < 64 << 10,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              version.wholeMatch(of: #/\d{1,6}(\.\d{1,6}){0,3}/#) != nil else { return nil }
        return version
    }

    /// Numeric, part by part: 1.10 > 1.9, and 1.0 == 1.0.0.
    nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offer(_ latest: String) {
        let alert = NSAlert()
        alert.messageText = "Shipper \(latest) is available"
        alert.informativeText = "You have \(current). Download the new version, then drag it into Applications to replace this one."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(downloadURL)
        case .alertThirdButtonReturn: UserDefaults.standard.set(latest, forKey: "skippedVersion")
        default: break
        }
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
