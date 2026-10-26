import AppKit

/// Keeps Shipper current from GitHub. It reads the version in Info.plist on the main branch, downloads Shipper.dmg
/// from the same commit, and checks that the new app is signed by the same certificate as this copy. The new copy
/// replaces this one when Shipper quits; Relaunch Now quits right away and opens it.
@MainActor
enum Updater {
    nonisolated static let infoPlistURL = URL(string: "https://raw.githubusercontent.com/huygenlabs/shipper/main/Info.plist")!
    nonisolated static let downloadURL = URL(string: "https://github.com/huygenlabs/shipper/raw/main/Shipper.dmg")!
    /// Shared with the menu's @AppStorage toggle.
    static let autoCheckKey = "checkForUpdates"

    /// Downloaded and verified, waiting for Shipper to quit.
    private static var staged: URL?
    private static var relaunches = false

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// At launch, then daily while the app stays open.
    static func checkPeriodically() async {
        while !Task.isCancelled {
            if UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true { await check(userInitiated: false) }
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
        }
    }

    /// Automatic checks download quietly and speak up only when an update is ready; a manual check always answers.
    static func check(userInitiated: Bool) async {
        guard let latest = await latestVersion() else {
            if userInitiated { inform("Couldn't check for updates", "Check your internet connection and try again.") }
            return
        }
        guard isNewer(latest, than: current) else {
            if userInitiated { inform("Shipper is up to date", "Version \(current) is the latest.") }
            return
        }
        if staged == nil {
            let app = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
                return offerDownload(latest, "Shipper can't replace itself in \(app.deletingLastPathComponent().path).")
            }
            do {
                staged = try await download(replacing: app)
            } catch {
                if userInitiated { offerDownload(latest, error.localizedDescription) }
                return
            }
        } else if !userInitiated {
            return
        }
        offerRelaunch(latest)
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

    /// Mounts the downloaded .dmg, copies Shipper.app onto `app`'s volume and returns it once verified.
    /// Runs off the main actor: hdiutil takes a moment.
    nonisolated private static func download(replacing app: URL) async throws -> URL {
        let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        let (dmg, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: dmg) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }

        // Same volume as the installed app, so the swap at quit is a rename.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: app, create: true)
        let mount = work.appending(path: "mount"), staged = work.appending(path: "Shipper.app")
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }
        try run("/usr/bin/ditto", mount.appending(path: "Shipper.app").path, staged.path)

        try verify(staged, against: app)
        let version = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let installed = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard isNewer(version, than: installed) else {
            throw UpdateError("The download isn't the new version yet. Try again in a few minutes.")
        }
        return staged
    }

    /// The new copy must meet the installed copy's designated requirement: same bundle ID, signed by the same
    /// certificate. A changed repo or download can't swap in an app signed by anyone else.
    nonisolated static func verify(_ app: URL, against installed: URL) throws {
        var mine: SecStaticCode?, theirs: SecStaticCode?, requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs,
              SecStaticCodeCheckValidity(theirs, flags, requirement) == errSecSuccess else {
            throw UpdateError("The update isn't signed by the same developer as this copy of Shipper, so it wasn't installed.")
        }
    }

    /// From applicationWillTerminate. If the swap fails, this copy stays and the next launch tries again.
    static func installIfReady() {
        guard let staged, (try? FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged)) != nil,
              relaunches else { return }
        // Wait for this process to exit, then open the new copy. Values go in as arguments, never into the script.
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$1""#,
                           String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? shell.run()
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(filePath: tool).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }

    private static func offerRelaunch(_ latest: String) {
        let alert = NSAlert()
        alert.messageText = "Shipper \(latest) is ready"
        alert.informativeText = "Relaunch to finish updating, or keep working and it installs when you quit Shipper."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunches = true
        NSApp.terminate(nil)
        relaunches = false  // Only reached if quitting was cancelled.
    }

    private static func offerDownload(_ latest: String, _ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Shipper \(latest) is available"
        alert.informativeText = "\(reason) Download the new version, then drag it into Applications to replace this one."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(downloadURL) }
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
