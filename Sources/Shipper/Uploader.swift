import AppKit
import Observation
import Security
import UniformTypeIdentifiers

// MARK: - Apple Account

/// Transporter signs in with the real Apple Account password through private AuthKit, which needs Apple's
/// `com.apple.authkit.client.private` entitlement. altool's equivalent is an app-specific password.
enum Auth {
    /// No `-p`: altool then reads the password from stdin, which keeps it out of `ps`, out of the process
    /// environment (readable by any same-user process) and out of altool's own child processes.
    static func args(_ appleID: String) -> [String] { ["-u", appleID] }

    /// An email that can't be mistaken for an altool flag.
    static func isValidAppleID(_ appleID: String) -> Bool {
        appleID.wholeMatch(of: #/[^\s@\-][^\s@]*@[^\s@]+\.[^\s@]+/#) != nil
    }
}

/// A team (App Store Connect provider) an Apple Account can deliver for.
struct Provider: Codable, Hashable, Identifiable {
    var name: String
    var shortName: String
    var publicID: String
    var teamID: String
    /// `INDIVIDUAL` or `COMPANY`; optional so lists saved before it existed still decode.
    var entityType: String?

    var id: String { publicID }
    var isIndividual: Bool { entityType == "INDIVIDUAL" }

    /// Reads `altool --list-providers --output-format json`: App Store Connect's JSON:API `actors?include=provider`
    /// response, whose `included` providers carry the provider ID, team name and developer team ID.
    static func parse(_ output: String) -> [Provider] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let response = try? JSONDecoder().decode(ActorsResponse.self, from: Data(output[start...end].utf8))
        else { return [] }
        return (response.included ?? [])
            .filter { $0.type == "providers" }
            .map { Provider(name: $0.attributes?.name ?? $0.id, shortName: $0.attributes?.shortName ?? "",
                            publicID: $0.id, teamID: $0.attributes?.developerTeamId ?? "",
                            entityType: $0.attributes?.entityType) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct ActorsResponse: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                var name: String?
                var shortName: String?
                var developerTeamId: String?
                var entityType: String?
            }
            var id: String
            var type: String
            var attributes: Attributes?
        }
        var included: [Resource]?
    }
}

struct Account: Codable, Hashable, Identifiable {
    var appleID: String
    var providers: [Provider] = []

    var id: String { appleID }
    /// With no team list, altool picks the account's only provider itself.
    var defaultTarget: Target { Target(appleID: appleID, publicID: providers.first?.publicID) }

    /// Sidebar rows, identified by the Target that selects them: inside a ForEach, SwiftUI's List uses the
    /// element ID as the selection value and ignores `.tag`, so the ID itself must be the Target.
    /// A single team-less row stands in when the teams couldn't be listed.
    var rows: [(provider: Provider?, target: Target)] {
        providers.isEmpty ? [(nil, defaultTarget)]
            : providers.map { ($0, Target(appleID: appleID, publicID: $0.publicID)) }
    }
}

/// Where a package is delivered: an Apple Account and, when known, one of its teams.
struct Target: Codable, Hashable {
    var appleID: String
    var publicID: String?
}

enum Keychain {
    private static func query(_ account: String, service: String = "Shipper") -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func save(_ password: String, for account: String) -> Bool {
        delete(account)
        var q = query(account)
        q[kSecValueData] = Data(password.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load(_ account: String, service: String = "Shipper") -> String? {
        var q = query(account, service: service)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String, service: String = "Shipper") {
        SecItemDelete(query(account, service: service) as CFDictionary)
    }
}

// MARK: - altool

/// Thin wrapper over `xcrun altool`, the CLI front end of the same ContentDelivery.framework Transporter ships.
enum Altool {
    /// Runs altool with the password on stdin, streaming each output line to `onLine`. Returns the exit status.
    static func run(_ args: [String], password: String, process: Process = Process(),
                    onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["altool"] + args
        let pipe = Pipe()
        let input = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        do {
            try process.run()
        } catch {
            await onLine("ERROR: \(error.localizedDescription)")
            return -1
        }
        input.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines { await onLine(line) }
        } catch {}
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Drops altool's timestamp and `[altool.xxx]` tag.
    static func clean(_ line: String) -> String {
        line.replacing(#/^\d{4}-\d\d-\d\d [\d:.]+ /#, with: "")
            .replacing(#/\[altool\.\w+\] /#, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The message of an error line, skipping altool's `ExitFailure` summary and internal KPI logging noise.
    static func issue(in line: String) -> String? {
        guard line.hasPrefix("ERROR:"), !line.contains("ExitFailure"), !line.contains("Logging KPI") else { return nil }
        return line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
    }

    /// The issue to show a person: altool follows a raw `Error Domain=…` dump with the same message in plain words.
    /// With `--output-format json` only the raw dump is printed, so its quoted message is pulled out instead.
    static func headline(_ issues: [String]) -> String? {
        if let plain = issues.first(where: { !$0.contains("Error Domain=") }) { return plain }
        guard let raw = issues.first else { return nil }
        return raw.firstMatch(of: #/Code=(-?\d+) "([^"]+)"/#).map { "\($0.2) (\($0.1))" } ?? raw
    }

    static func percent(in line: String) -> Double? {
        line.firstMatch(of: #/(\d{1,3}(?:\.\d+)?)\s?%/#).flatMap { Double($0.1) }.map { min($0, 100) }
    }

    static func deliveryID(in line: String) -> String? {
        line.firstMatch(of: #/Delivery UUID:\s*([0-9A-Fa-f-]{36})/#).map { String($0.1) }
    }
}

// MARK: - Package info

struct PackageInfo: Codable, Equatable {
    var name: String
    var bundleID: String
    var version: String
    var build: String
    /// PNG bytes of an .ipa's app icon; nil for .pkg and for builds that keep the icon only in Assets.car.
    var icon: Data?

    /// Reads the app's identity straight out of the archive; bsdtar handles both zip (.ipa) and xar (.pkg).
    static func read(_ url: URL) -> PackageInfo? {
        url.pathExtension.lowercased() == "ipa" ? ipa(url) : pkg(url)
    }

    private static func ipa(_ url: URL) -> PackageInfo? {
        guard let entries = tar("-tf", url).flatMap({ String(data: $0, encoding: .utf8) })?.split(separator: "\n").map(String.init),
              let path = entries.first(where: { $0.wholeMatch(of: #/Payload\/[^\/]+\.app\/Info\.plist/#) != nil }),
              let data = tar("-xOf", url, path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var info = fromPlist(plist)
        else { return nil }
        info.icon = iconPath(plist, in: entries, app: String(path.dropLast("Info.plist".count))).flatMap { tar("-xOf", url, $0) }
        return info
    }

    /// The loose icon PNG the plist names, from the app's top level (not its extensions or frameworks).
    /// Xcode stores these Apple-crushed (CgBI); macOS ImageIO decodes them.
    static func iconPath(_ plist: [String: Any], in entries: [String], app: String) -> String? {
        let names = ["CFBundleIcons", "CFBundleIcons~ipad"].flatMap {
            ((plist[$0] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String] ?? []
        }
        // ponytail: picks the name that sorts last (76x76 over 60x60, @3x over @2x), not by reading pixel sizes.
        return entries.filter { entry in
            guard entry.hasPrefix(app), entry.hasSuffix(".png") else { return false }
            let file = entry.dropFirst(app.count)
            return !file.contains("/") && names.contains { file.hasPrefix($0) }
        }.max()
    }

    private static func pkg(_ url: URL) -> PackageInfo? {
        tar("-xOf", url, "Distribution").flatMap { String(data: $0, encoding: .utf8) }.flatMap(fromDistribution)
    }

    static func fromPlist(_ p: [String: Any]) -> PackageInfo? {
        guard let id = p["CFBundleIdentifier"] as? String else { return nil }
        return PackageInfo(
            name: (p["CFBundleDisplayName"] ?? p["CFBundleName"]) as? String ?? id,
            bundleID: id,
            version: p["CFBundleShortVersionString"] as? String ?? "—",
            build: p["CFBundleVersion"] as? String ?? "—")
    }

    /// Parses the first `<bundle …/>` that productbuild writes into a .pkg's Distribution file.
    static func fromDistribution(_ xml: String) -> PackageInfo? {
        guard let tag = xml.firstMatch(of: #/<bundle\s([^>]*)>/#) else { return nil }
        var attrs: [String: String] = [:]
        for m in tag.1.matches(of: #/(\w+)="([^"]*)"/#) { attrs[String(m.1)] = String(m.2) }
        guard let id = attrs["id"] else { return nil }
        let name = attrs["path"].map { ($0 as NSString).lastPathComponent.replacing(".app", with: "") }
        return PackageInfo(name: name ?? id, bundleID: id,
                           version: attrs["CFBundleShortVersionString"] ?? "—", build: attrs["CFBundleVersion"] ?? "—")
    }

    /// Archives are untrusted input: output past `limit` (a zip-bomb Info.plist, say) is refused, not buffered.
    private static func tar(_ flag: String, _ url: URL, _ member: String? = nil, limit: Int = 16 << 20) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = [flag, url.path] + (member.map { [$0] } ?? [])  // url.path is absolute, so never a flag
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        while data.count <= limit, let chunk = try? pipe.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return p.terminationStatus == 0 && data.count <= limit ? data : nil
    }
}

// MARK: - Queue

@Observable @MainActor
final class Job: Identifiable {
    enum State { case ready, verifying, delivering, verified, delivered, failed, stopped }

    let id = UUID()
    let url: URL
    let target: Target
    let size: Int64
    var info: PackageInfo?
    var state = State.ready
    var progress: Double?
    var log: [String] = []
    var issues: [String] = []
    var deliveryID: String?
    /// Passed `--validate-app`; only then is Deliver offered.
    var verified = false
    @ObservationIgnored var process: Process?

    var isRunning: Bool { state == .verifying || state == .delivering }
    var name: String { info?.name ?? url.deletingPathExtension().lastPathComponent }

    init(url: URL, target: Target) {
        self.url = url
        self.target = target
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// What a delivered job keeps across launches; the package itself may since have moved or been deleted.
    struct Saved: Codable {
        var url: URL
        var target: Target
        var size: Int64
        var info: PackageInfo?
        var deliveryID: String?
        var log: [String]
    }

    var saved: Saved { Saved(url: url, target: target, size: size, info: info, deliveryID: deliveryID, log: log) }

    init(delivered saved: Saved) {
        url = saved.url
        target = saved.target
        size = saved.size
        info = saved.info
        deliveryID = saved.deliveryID
        log = saved.log
        state = .delivered
        verified = true
    }

    func handle(_ raw: String) {
        let line = Altool.clean(raw)
        guard !line.isEmpty else { return }
        if let p = Altool.percent(in: line) {
            progress = p
            // Keep one progress line in the log instead of hundreds.
            if let last = log.last, Altool.percent(in: last) != nil { log.removeLast() }
        }
        log.append(line)
        if let issue = Altool.issue(in: line) { issues.append(issue) }
        if let id = Altool.deliveryID(in: line) { deliveryID = id }
    }
}

@Observable @MainActor
final class Store {
    /// Signed-in Apple Accounts and their teams; each app-specific password lives in the Keychain.
    var accounts: [Account] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "accounts") }
    }
    /// The developer account picked in the sidebar, remembered across launches; added packages are delivered for it.
    var selection: Target? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: "selection") }
    }
    /// Delivered jobs are kept across launches until removed or cleared.
    // ponytail: icons and logs sit in UserDefaults; move to a file in Application Support if histories grow large.
    var jobs: [Job] = [] {
        didSet { saveDelivered() }
    }
    /// Why an account's teams couldn't be refreshed, by Apple ID.
    var refreshErrors: [String: String] = [:]
    /// Apple IDs whose teams are being fetched right now.
    var refreshing: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        accounts = defaults.data(forKey: "accounts").flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        // Team lists change rarely but do change (new teams, renamed companies), so re-read them each launch.
        for account in accounts {
            Task { await refresh(account.appleID) }
        }
        let saved = defaults.data(forKey: "selection").flatMap { try? JSONDecoder().decode(Target.self, from: $0) }
        selection = saved.flatMap { isValid($0) ? $0 : nil } ?? accounts.first?.defaultTarget
        jobs = (defaults.data(forKey: "delivered").flatMap { try? JSONDecoder().decode([Job.Saved].self, from: $0) } ?? [])
            .map { Job(delivered: $0) }
    }

    private func saveDelivered() {
        let delivered = jobs.filter { $0.state == .delivered }.map(\.saved)
        UserDefaults.standard.set(try? JSONEncoder().encode(delivered), forKey: "delivered")
    }

    /// Shipper 1.1 and older were saved as "AppUploader". Moves their settings and passwords over once, then deletes
    /// the old copies. Called at launch before the store loads; drop it once nobody runs 1.1.
    static func moveFromOldName() {
        let old = "local.appuploader.AppUploader", defaults = UserDefaults.standard
        guard defaults.object(forKey: "accounts") == nil, let saved = UserDefaults(suiteName: old),
              let data = saved.data(forKey: "accounts") else { return }
        for key in ["accounts", "selection", Updater.autoCheckKey] { defaults.set(saved.object(forKey: key), forKey: key) }
        for account in (try? JSONDecoder().decode([Account].self, from: data)) ?? [] {
            if let password = Keychain.load(account.appleID, service: "AppUploader"), Keychain.save(password, for: account.appleID) {
                Keychain.delete(account.appleID, service: "AppUploader")
            }
        }
        defaults.removePersistentDomain(forName: old)
    }

    /// The target still names a signed-in account and, if it has one, a team that account still has.
    private func isValid(_ target: Target) -> Bool {
        guard let account = accounts.first(where: { $0.appleID == target.appleID }) else { return false }
        return target.publicID == nil ? account.providers.isEmpty : account.providers.contains { $0.publicID == target.publicID }
    }

    var selectedProvider: Provider? {
        accounts.first { $0.appleID == selection?.appleID }?.providers.first { $0.publicID == selection?.publicID }
    }

    /// Signs in the way Transporter does: by asking App Store Connect for the account's providers (teams).
    /// Returns the error to show, or nil when signed in. Signing in again with a known account refreshes it.
    func signIn(_ appleID: String, password: String) async -> String? {
        guard Auth.isValidAppleID(appleID) else { return "Enter your Apple Account email address." }
        let (providers, error) = await fetchProviders(appleID, password: password)
        if let error { return error }
        guard Keychain.save(password, for: appleID) else { return "Signed in, but the password couldn't be saved to the Keychain." }
        let account = Account(appleID: appleID, providers: providers)
        if let i = accounts.firstIndex(where: { $0.appleID == appleID }) { accounts[i] = account } else { accounts.append(account) }
        selection = account.defaultTarget
        return nil
    }

    /// Re-reads an account's teams with its saved password.
    func refresh(_ appleID: String) async {
        guard !refreshing.contains(appleID) else { return }
        // No saved password (or Keychain access denied): never send an empty one, since failed logins can lock the account.
        guard let password = Keychain.load(appleID) else {
            refreshErrors[appleID] = Self.missingPassword
            return
        }
        refreshing.insert(appleID)
        let (providers, error) = await fetchProviders(appleID, password: password)
        refreshing.remove(appleID)
        refreshErrors[appleID] = error
        guard error == nil, let i = accounts.firstIndex(where: { $0.appleID == appleID }) else { return }
        accounts[i].providers = providers
        if let current = selection, current.appleID == appleID, !isValid(current) { selection = accounts[i].defaultTarget }
    }

    private func fetchProviders(_ appleID: String, password: String) async -> (providers: [Provider], error: String?) {
        var output: [String] = []
        let status = await Altool.run(["--list-providers", "--output-format", "json"] + Auth.args(appleID),
                                      password: password) { output.append($0) }
        guard status == 0 else {
            let issues = output.compactMap { Altool.issue(in: Altool.clean($0)) }
            return ([], Altool.headline(issues) ?? "Sign in failed (altool exit code \(status)).")
        }
        return (Provider.parse(output.joined(separator: "\n")), nil)
    }

    func signOut(_ appleID: String) {
        for job in jobs where job.target.appleID == appleID { stop(job) }
        jobs.removeAll { $0.target.appleID == appleID }
        Keychain.delete(appleID)
        accounts.removeAll { $0.appleID == appleID }
        if selection?.appleID == appleID { selection = accounts.first?.defaultTarget }
    }

    static let missingPassword = "No saved password. Use Add Account to sign in again."

    func add(_ urls: [URL]) {
        guard let target = selection else { return }
        for url in urls where url.isFileURL && ["ipa", "pkg"].contains(url.pathExtension.lowercased())
            // A delivered row is history: a newer build exported to the same path is a new job.
            && !jobs.contains(where: { $0.url == url && $0.target == target && $0.state != .delivered }) {
            let job = Job(url: url, target: target)
            jobs.append(job)
            start(job, deliver: false)  // verify on add; Deliver unlocks once it passes
            Task.detached {
                let info = PackageInfo.read(url)
                await MainActor.run { job.info = info }
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["ipa", "pkg"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Verify runs `--validate-app`; Deliver runs `--upload-package`, matching Transporter's two actions.
    func start(_ job: Job, deliver: Bool) {
        guard !job.isRunning else { return }
        let appleID = job.target.appleID
        guard let password = Keychain.load(appleID) else {
            job.state = .failed
            job.issues = [Self.missingPassword]
            return
        }
        job.state = deliver ? .delivering : .verifying
        job.progress = nil
        job.log = []
        job.issues = []
        job.deliveryID = nil
        if !deliver { job.verified = false }
        let process = Process()
        job.process = process
        let args = [deliver ? "--upload-package" : "--validate-app", job.url.path] + Auth.args(appleID)
            + (job.target.publicID.map { ["--provider-public-id", $0] } ?? []) + ["--show-progress"]
        Task {
            let status = await Altool.run(args, password: password, process: process) { job.handle($0) }
            job.process = nil
            guard job.state != .stopped else { return }
            job.state = status == 0 ? (deliver ? .delivered : .verified) : .failed
            if status == 0, !deliver { job.verified = true }
            if status != 0, job.issues.isEmpty { job.issues = ["altool exited with code \(status) without an error message. See the full log."] }
            saveDelivered()
        }
    }

    func stop(_ job: Job) {
        guard job.isRunning else { return }
        job.state = .stopped
        job.process?.terminate()
    }

    func remove(_ job: Job) {
        stop(job)
        jobs.removeAll { $0 === job }
    }

    /// Empties the selected account's list, leaving uploads that are still running.
    func clear() {
        jobs.removeAll { !$0.isRunning && $0.target == selection }
    }
}
