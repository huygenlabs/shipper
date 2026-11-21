import Foundation
import Testing
@testable import Shipper

@Test func cleansAltoolLines() {
    let raw = "2026-10-26 16:54:20.283 ERROR: [altool.7757035280] Unable to extract archive. (-20004)"
    let line = Altool.clean(raw)
    #expect(line == "ERROR: Unable to extract archive. (-20004)")
    #expect(Altool.issue(in: line) == "Unable to extract archive. (-20004)")
    #expect(Altool.issue(in: Altool.clean("2026-10-26 16:54:20.284 ERROR: [altool.main] ExitFailure (31)")) == nil)
}

@Test func parsesProgressAndDeliveryID() {
    #expect(Altool.percent(in: "Upload progress: 42.5% (12 MB of 28 MB)") == 42.5)
    #expect(Altool.percent(in: "No progress here") == nil)
    #expect(Altool.deliveryID(in: "Delivery UUID: 3c1f0a2e-8d1b-4b5e-9f7a-1c2d3e4f5a6b") == "3c1f0a2e-8d1b-4b5e-9f7a-1c2d3e4f5a6b")
}

@Test func parsesPkgDistribution() {
    let xml = #"<bundle-version><bundle CFBundleShortVersionString="2.3.1" CFBundleVersion="418" id="com.acme.demo" path="Demo.app"/></bundle-version>"#
    #expect(PackageInfo.fromDistribution(xml) == PackageInfo(name: "Demo", bundleID: "com.acme.demo", version: "2.3.1", build: "418"))
}

@Test func prefersReadableSignInError() {
    let lines = [
        #"2026-10-26 17:09:02.429 ERROR: [altool.7C7F4054C0] Auth context delegate failed to get headers. Error Domain=ITunesConnectFoundationErrorDomain Code=-20209 "This Apple Account has been locked." UserInfo={}"#,
        "2026-10-26 17:09:02.430 ERROR: [altool.7C7F4054C0] This Apple Account has been locked. (-20209)",
        "2026-10-26 17:09:02.431 ERROR: [altool.7C7F405980] Logging KPI using CDDawTokenAuthContext requires a provider public ID.",
    ]
    let issues = lines.compactMap { Altool.issue(in: Altool.clean($0)) }
    #expect(issues.count == 2)
    #expect(Altool.headline(issues) == "This Apple Account has been locked. (-20209)")
}

@Test func parsesProvidersFromActorsResponse() {
    let output = """
    Running altool at path '/Applications/Xcode.app/.../altool'...
    {
      "data" : [ { "type" : "actors", "id" : "c2d9a7e1", "attributes" : { "teamId" : "0b7e2f4c-5d1a-4e8b-9c3f-6a2d8e1b7f40", "roles" : [ "ADMIN" ] } } ],
      "included" : [
        { "type" : "providers", "id" : "0b7e2f4c-5d1a-4e8b-9c3f-6a2d8e1b7f40",
          "attributes" : { "name" : "Rao Field Tools LLP", "shortName" : "8K2QX9H4TZ", "developerTeamId" : "8K2QX9H4TZ", "internalId" : 4021337 } },
        { "type" : "providers", "id" : "a1b2c3d4-0000-1111-2222-333344445555",
          "attributes" : { "name" : "Anika Mehta", "shortName" : "3JD7UV2L9P", "developerTeamId" : "3JD7UV2L9P" } }
      ],
      "meta" : { "paging" : { "total" : 2 } }
    }
    """
    #expect(Provider.parse(output) == [
        Provider(name: "Anika Mehta", shortName: "3JD7UV2L9P", publicID: "a1b2c3d4-0000-1111-2222-333344445555", teamID: "3JD7UV2L9P"),
        Provider(name: "Rao Field Tools LLP", shortName: "8K2QX9H4TZ", publicID: "0b7e2f4c-5d1a-4e8b-9c3f-6a2d8e1b7f40", teamID: "8K2QX9H4TZ"),
    ])
    #expect(Provider.parse("Failed to get providers.").isEmpty)
}

@Test func sidebarRowsAreKeyedBySelectableTargets() {
    let teams = Account(appleID: "a@example.com", providers: [
        Provider(name: "Alpha Co", shortName: "", publicID: "p1", teamID: "T1"),
        Provider(name: "Gamma", shortName: "", publicID: "p2", teamID: "T2"),
    ])
    #expect(teams.rows.map(\.target) == [Target(appleID: "a@example.com", publicID: "p1"), Target(appleID: "a@example.com", publicID: "p2")])
    let unlisted = Account(appleID: "b@example.com")
    #expect(unlisted.rows.map(\.target) == [Target(appleID: "b@example.com", publicID: nil)])
    #expect(unlisted.rows.first?.provider == nil)
}

@Test func rejectsAppleIDsThatCouldBeFlags() {
    #expect(Auth.isValidAppleID("jane.doe@example.com"))
    #expect(!Auth.isValidAppleID("--verbose@example.com"))
    #expect(!Auth.isValidAppleID("jane doe@example.com"))
    #expect(!Auth.isValidAppleID("jane"))
}

/// The password must travel on stdin, never in argv or the environment.
@Test func passesPasswordOnStdinOnly() async {
    let args = ["--list-providers"] + Auth.args("jane.doe@example.com")
    #expect(!args.contains("-p") && !args.contains { $0.contains("@env:") })
    let process = Process()
    _ = await Altool.run(["--help"], password: "s3cret-pass", process: process) { _ in }
    #expect(process.environment == nil)  // inherits as-is; nothing added
    #expect(!(process.arguments ?? []).contains("s3cret-pass"))
}

@Test func readsMessageOutOfRawErrorWhenAlone() {
    let raw = #"Auth context delegate failed to get headers. Error Domain=ITunesConnectFoundationErrorDomain Code=-20209 "This Apple Account has been locked." UserInfo={}"#
    #expect(Altool.headline([raw]) == "This Apple Account has been locked. (-20209)")
}

/// A missing Keychain password must fail the job locally, never send an empty password to Apple.
@MainActor @Test func missingPasswordFailsWithoutRunningAltool() {
    let store = Store()
    store.accounts = []
    store.selection = nil
    let job = Job(url: URL(fileURLWithPath: "/tmp/Demo.ipa"), target: Target(appleID: "nobody@example.invalid", publicID: nil))
    store.start(job, deliver: false)
    #expect(job.state == .failed)
    #expect(job.issues == [Store.missingPassword])
    #expect(job.process == nil)
}

@MainActor @Test func ignoresDroppedWebLinks() {
    let store = Store()
    store.selection = Target(appleID: "nobody@example.invalid", publicID: nil)
    store.add([URL(string: "https://example.com/Evil.ipa")!])
    #expect(store.jobs.isEmpty)
}

/// Delivered builds survive a relaunch until cleared, and never block adding a newer build from the same path.
@MainActor @Test func keepsDeliveredJobsAcrossLaunches() {
    let url = URL(fileURLWithPath: "/tmp/Demo.ipa"), target = Target(appleID: "nobody@example.invalid", publicID: nil)
    let job = Job(url: url, target: target)
    job.info = PackageInfo(name: "Demo", bundleID: "com.acme.demo", version: "1.0", build: "7", icon: Data([1, 2]))
    job.state = .delivered
    let store = Store()
    store.jobs = [job, Job(url: URL(fileURLWithPath: "/tmp/Other.ipa"), target: target)]
    let relaunched = Store()
    #expect(relaunched.jobs.map(\.info) == [job.info])
    #expect(relaunched.jobs.first?.state == .delivered)
    relaunched.selection = target
    relaunched.add([url])
    #expect(relaunched.jobs.count == 2)
    #expect(relaunched.jobs.last?.state == .delivered)  // newest added sits on top
    relaunched.clear()
    #expect(relaunched.jobs.isEmpty)
    #expect(Store().jobs.isEmpty)
}

@Test func comparesVersionsNumerically() {
    #expect(Updater.isNewer("1.1", than: "1.0"))
    #expect(Updater.isNewer("1.10", than: "1.9"))
    #expect(Updater.isNewer("2", than: "1.9.9"))
    #expect(!Updater.isNewer("1.0", than: "1.0.0"))
    #expect(!Updater.isNewer("1.0", than: "1.1"))
}

@Test func readsOnlyAPlainVersionFromTheRemotePlist() throws {
    func plist(_ version: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
    }
    #expect(Updater.version(fromPlist: try plist("1.2.3")) == "1.2.3")
    #expect(Updater.version(fromPlist: try plist("1.2; rm -rf ~")) == nil)
    #expect(Updater.version(fromPlist: Data("<html>404</html>".utf8)) == nil)
}

@Test func installsOnlyAppsSignedLikeTheInstalledCopy() {
    let calculator = URL(filePath: "/System/Applications/Calculator.app")
    let textEdit = URL(filePath: "/System/Applications/TextEdit.app")
    #expect(throws: Never.self) { try Updater.verify(calculator, against: calculator) }
    #expect(throws: (any Error).self) { try Updater.verify(textEdit, against: calculator) }
}

@Test func picksAppIconFromIpaListing() {
    let plist: [String: Any] = [
        "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]],
        "CFBundleIcons~ipad": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"]]],
    ]
    let entries = [
        "Payload/Runner.app/Info.plist",
        "Payload/Runner.app/AppIcon60x60@2x.png",
        "Payload/Runner.app/AppIcon76x76@2x~ipad.png",
        "Payload/Runner.app/PlugIns/Widget.appex/AppIcon99x99@3x.png",
        "Payload/Runner.app/LaunchImage.png",
    ]
    #expect(PackageInfo.iconPath(plist, in: entries, app: "Payload/Runner.app/") == "Payload/Runner.app/AppIcon76x76@2x~ipad.png")
    #expect(PackageInfo.iconPath([:], in: entries, app: "Payload/Runner.app/") == nil)
}

// MARK: - Agents (MCP)

@Test func picksTheAccountForATeamID() {
    func provider(_ team: String, _ id: String) -> Provider { Provider(name: team, shortName: "", publicID: id, teamID: team) }
    let accounts = [
        Account(appleID: "asha@example.com", providers: [provider("A1B2C3D4E5", "p-1"), provider("", "p-2")]),
        Account(appleID: "ravi@example.com", providers: [provider("A1B2C3D4E5", "p-3"), provider("Z9Y8X7W6V5", "p-4")]),
    ]
    // A team two accounts share goes to the first, unless the other is the one selected in the sidebar.
    #expect(accounts.target(forTeam: "A1B2C3D4E5") == Target(appleID: "asha@example.com", publicID: "p-1"))
    #expect(accounts.target(forTeam: "a1b2c3d4e5 ", preferring: "ravi@example.com") == Target(appleID: "ravi@example.com", publicID: "p-3"))
    #expect(accounts.target(forTeam: "Z9Y8X7W6V5", preferring: "asha@example.com") == Target(appleID: "ravi@example.com", publicID: "p-4"))
    #expect(accounts.target(forTeam: "NOSUCHTEAM") == nil)
    // A provider listed without a Team ID must not be picked by an empty one.
    #expect(accounts.target(forTeam: "") == nil)
    #expect(accounts.teamID(of: Target(appleID: "ravi@example.com", publicID: "p-4")) == "Z9Y8X7W6V5")
}

@Test func refusesPathsAnAgentShouldNotUpload() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder.ipa"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let build = dir.appendingPathComponent("Demo.IPA"), notes = dir.appendingPathComponent("notes.txt")
    try Data().write(to: build)
    try Data().write(to: notes)
    #expect(Agent.pathError(build.path) == nil)
    #expect(Agent.pathError("Demo.ipa") != nil)  // relative
    #expect(Agent.pathError(notes.path) != nil)  // not a build
    #expect(Agent.pathError(dir.appendingPathComponent("Missing.ipa").path) != nil)
    #expect(Agent.pathError(dir.appendingPathComponent("Folder.ipa").path) != nil)  // a directory
}

@Test func answersTheMCPHandshake() throws {
    let hello = try #require(MCPServer.reply(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]]))
    let result = try #require(hello["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-03-26")
    #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    // A revision it has never heard of gets one it knows.
    let future = MCPServer.reply(to: ["id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
    #expect((future?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")

    let listed = MCPServer.reply(to: ["id": 3, "method": "tools/list"])?["result"] as? [String: Any]
    let names = (listed?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    #expect(names == ["list_teams", "upload_build", "list_builds"])

    #expect(MCPServer.reply(to: ["method": "notifications/initialized"]) == nil)  // notifications get no reply
    #expect((MCPServer.reply(to: ["id": 4, "method": "resources/list"])?["error"] as? [String: Any])?["code"] as? Int == -32601)
    #expect(Agent.shellQuoted("/Applications/Shipper.app/Contents/MacOS/Shipper") == "/Applications/Shipper.app/Contents/MacOS/Shipper")
    #expect(Agent.shellQuoted("/Users/it's me/Shipper") == #"'/Users/it'\''s me/Shipper'"#)
}

@Test func addsShipperToAJSONConfigAndKeepsTheRest() throws {
    let existing = Data(#"{"theme": "dark", "mcpServers": {"figma": {"url": "https://example.com/mcp"}}}"#.utf8)
    let entry: [String: Any] = ["command": "/Applications/Shipper.app/Contents/MacOS/Shipper", "args": ["--mcp"]]
    let added = try AgentApp.json(existing, key: "mcpServers", entry: entry)
    let root = try #require(JSONSerialization.jsonObject(with: added) as? [String: Any])
    #expect(root["theme"] as? String == "dark")
    #expect((root["mcpServers"] as? [String: Any])?["figma"] != nil)
    #expect(AgentApp.command(inJSON: added, key: "mcpServers") == "/Applications/Shipper.app/Contents/MacOS/Shipper")
    #expect(String(decoding: added, as: UTF8.self).contains("/Applications/Shipper.app"))  // slashes left readable

    let removed = try AgentApp.json(added, key: "mcpServers", entry: nil)
    #expect(AgentApp.command(inJSON: removed, key: "mcpServers") == nil)
    #expect(String(decoding: removed, as: UTF8.self).contains("figma"))

    // No file yet, or an empty one, starts a new config.
    #expect(AgentApp.command(inJSON: try AgentApp.json(nil, key: "servers", entry: entry), key: "servers") != nil)
    #expect(AgentApp.command(inJSON: try AgentApp.json(Data(" \n".utf8), key: "servers", entry: entry), key: "servers") != nil)
    // A file with comments is refused, not rewritten without them.
    #expect(throws: AgentApp.Failure.self) { try AgentApp.json(Data("{ // mine\n \"servers\": {} }".utf8), key: "servers", entry: entry) }
    #expect(throws: AgentApp.Failure.self) { try AgentApp.json(Data(#"{"servers": []}"#.utf8), key: "servers", entry: entry) }
}

@Test func addsShipperToCodexConfigAndKeepsTheRest() {
    let existing = """
        model = "gpt-5"

        [mcp_servers.dart]
        command = "dart"
        args = [
            "mcp-server",
        ]

        [mcp_servers.dart.env]
        FOO = "1"
        """
    let added = AgentApp.toml(existing, command: "/Applications/Shipper.app/Contents/MacOS/Shipper")
    #expect(added == existing + "\n\n[mcp_servers.shipper]\ncommand = \"/Applications/Shipper.app/Contents/MacOS/Shipper\"\nargs = [\"--mcp\"]\n")
    #expect(AgentApp.isInTOML(added, command: "/Applications/Shipper.app/Contents/MacOS/Shipper"))
    #expect(!AgentApp.isInTOML(added, command: "/Users/asha/Shipper.app/Contents/MacOS/Shipper"))  // another copy
    #expect(!AgentApp.isInTOML(existing, command: "dart"))

    // Connecting again from a copy somewhere else replaces the table instead of adding a second one.
    let moved = AgentApp.toml(added, command: "/Users/asha/Shipper.app/Contents/MacOS/Shipper")
    #expect(moved.components(separatedBy: "[mcp_servers.shipper]").count == 2)
    #expect(AgentApp.isInTOML(moved, command: "/Users/asha/Shipper.app/Contents/MacOS/Shipper"))

    // Removing takes out only Shipper's table, wherever it sits.
    #expect(AgentApp.toml(added, command: nil) == existing + "\n")
    let middle = "[mcp_servers.shipper]\ncommand = \"x\"\nargs = [\"--mcp\"]\n\n[mcp_servers.dart]\ncommand = \"dart\"\n"
    #expect(AgentApp.toml(middle, command: nil) == "[mcp_servers.dart]\ncommand = \"dart\"\n")
    #expect(AgentApp.toml("", command: "/x") == "[mcp_servers.shipper]\ncommand = \"/x\"\nargs = [\"--mcp\"]\n")
}

@Test func connectingKeepsTheConfigFilePrivateAndLinked() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A config kept in a dotfiles repo, readable only by its owner because it holds an API key.
    let real = dir.appendingPathComponent("dotfiles-mcp.json"), link = dir.appendingPathComponent("mcp.json")
    try Data(#"{"mcpServers": {"notes": {"command": "notes", "env": {"KEY": "secret"}}}}"#.utf8).write(to: real)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let agent = AgentApp(name: "Test", files: [link.path], markers: [], format: .json(key: "mcpServers"))
    #expect(!agent.isConnected(to: "/x/Shipper"))
    try agent.setConnected(true, executable: "/x/Shipper")
    #expect(agent.isConnected(to: "/x/Shipper"))
    #expect(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    #expect(String(decoding: try Data(contentsOf: real), as: UTF8.self).contains("secret"))
    try agent.setConnected(false, executable: "/x/Shipper")
    #expect(!agent.isConnected(to: "/x/Shipper"))

    // Turning off an agent that has no config yet must not create one.
    let fresh = AgentApp(name: "Fresh", files: [dir.appendingPathComponent("new/config.toml").path], markers: [], format: .toml)
    try fresh.setConnected(false, executable: "/x/Shipper")
    #expect(!FileManager.default.fileExists(atPath: fresh.file.path))
    try fresh.setConnected(true, executable: "/x/Shipper")
    #expect(fresh.isConnected(to: "/x/Shipper"))
}

@MainActor @Test func movesSettingsFromOldBundleID() {
    let old = "test.shipper.old-\(UUID())", new = "test.shipper.new-\(UUID())"
    let defaults = UserDefaults(suiteName: new)!
    defer { UserDefaults.standard.removePersistentDomain(forName: new); UserDefaults.standard.removePersistentDomain(forName: old) }
    UserDefaults.standard.setPersistentDomain(["accounts": Data([1]), "selection": "x"], forName: old)
    Store.moveFromOldBundleID(old, to: defaults)
    #expect(defaults.data(forKey: "accounts") == Data([1]))
    #expect(defaults.string(forKey: "selection") == "x")
    #expect(UserDefaults.standard.persistentDomain(forName: old)?.isEmpty ?? true)
    // Already has settings: leaves them alone.
    UserDefaults.standard.setPersistentDomain(["accounts": Data([2])], forName: old)
    Store.moveFromOldBundleID(old, to: defaults)
    #expect(defaults.data(forKey: "accounts") == Data([1]))
}
