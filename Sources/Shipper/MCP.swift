import Foundation

// `Shipper --mcp` is a stdio MCP server that an AI agent starts. It speaks the protocol itself, so opening an
// agent session doesn't open Shipper, and hands uploads to the app over a Unix socket. The app stays the only
// place builds are uploaded from: an agent's upload gets the same queue row, progress, log and Stop as a dropped file.

// MARK: - Shared by the app and the MCP process

enum Agent {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shipper")
    static var socketPath: String { directory.appendingPathComponent("agent.sock").path }

    /// Why a path from an agent can't be queued, or nil. The app checks again: its socket is the trust boundary.
    static func pathError(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "path must be absolute." }
        guard ["ipa", "pkg"].contains((path as NSString).pathExtension.lowercased()) else {
            return "Only .ipa and .pkg files can be uploaded."
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "No file at \(path)."
        }
        return nil
    }

    /// What an agent is told about a build. Never the Apple Account: agents work in Team IDs.
    static func summary(url: URL, info: PackageInfo?, state: String, deliveryID: String?, teamID: String?) -> [String: Any] {
        var out: [String: Any] = ["path": url.path, "name": info?.name ?? url.deletingPathExtension().lastPathComponent, "state": state]
        if let info {
            out["version"] = info.version
            out["build"] = info.build
            out["bundle_id"] = info.bundleID
        }
        if let teamID, !teamID.isEmpty { out["team_id"] = teamID }
        if let deliveryID { out["delivery_id"] = deliveryID }
        return out
    }

    static func json(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// A string as JSON writes it, quotes included.
    static func quoted(_ string: String) -> String {
        (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(string)\""
    }

    /// Left bare when the shell would read it as one word anyway, as /Applications/Shipper.app/… is.
    static func shellQuoted(_ path: String) -> String {
        path.wholeMatch(of: #/[A-Za-z0-9_\/.\-]+/#) != nil ? path : "'" + path.replacing("'", with: #"'\''"#) + "'"
    }
}

extension [Account] {
    func teamID(of target: Target) -> String? {
        first { $0.appleID == target.appleID }?.providers.first { $0.publicID == target.publicID }?.teamID
    }
}

extension FileHandle {
    /// Writes one message as a line of JSON. A reader that has gone away is not an error worth surfacing.
    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return }
        data.append(0x0A)
        try? write(contentsOf: data)
    }
}

/// The Unix socket between the MCP process and the app. Owner-only, and the app also checks the caller's user.
enum AgentSocket {
    private static func make() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        return fd
    }

    /// Without this, writing to a peer that hung up would kill the process with SIGPIPE.
    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Agent.socketPath.utf8
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func connect() -> FileHandle? {
        guard let fd = make() else { return nil }
        guard withAddress({ Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// App side: hands each connection from this user's processes to `handle` for as long as the app runs.
    static func listen(_ handle: @escaping (FileHandle) -> Void) {
        try? FileManager.default.createDirectory(at: Agent.directory, withIntermediateDirectories: true)
        unlink(Agent.socketPath)  // left behind by the previous run
        guard let fd = make() else { return }
        guard withAddress({ bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        chmod(Agent.socketPath, 0o600)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    close(client)
                    continue
                }
                noSigPipe(client)
                handle(FileHandle(fileDescriptor: client, closeOnDealloc: true))
            }
        }
    }
}

// MARK: - App side

extension Store {
    /// Each connection carries one request line; the app answers with progress lines and then one final line.
    func listenForAgents() {
        AgentSocket.listen { connection in
            Task { @MainActor in
                var lines = connection.bytes.lines.makeAsyncIterator()
                guard let line = try? await lines.next(), let request = Agent.json(line) else { return }
                connection.send(await self.answer(request) { connection.send($0) })
            }
        }
    }

    func answer(_ request: [String: Any], progress: ([String: Any]) -> Void) async -> [String: Any] {
        switch request["op"] as? String {
        case "builds":
            let team = (request["team_id"] as? String)?.uppercased()
            return ["builds": jobs.map(summary).filter { team == nil || ($0["team_id"] as? String)?.uppercased() == team }]
        case "upload":
            return await upload(request, progress: progress)
        default:
            return ["error": "Unknown request."]
        }
    }

    private func upload(_ request: [String: Any], progress: ([String: Any]) -> Void) async -> [String: Any] {
        guard let path = request["path"] as? String, let team = request["team_id"] as? String else {
            return ["error": "path and team_id are required."]
        }
        if let error = Agent.pathError(path) { return ["error": error] }
        guard !accounts.isEmpty else { return ["error": "No Apple Account is signed in. Open Shipper and sign in first."] }
        var target = accounts.target(forTeam: team, preferring: selection?.appleID)
        if target == nil {
            // The saved team lists may be stale (a team joined since): read them again before giving up.
            for account in accounts { await refresh(account.appleID) }
            while !refreshing.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }  // refreshes begun at launch
            target = accounts.target(forTeam: team, preferring: selection?.appleID)
        }
        guard let target else {
            let known = Set(accounts.flatMap(\.providers).map(\.teamID).filter { !$0.isEmpty }).sorted()
            return ["error": "No Apple Account signed in to Shipper has team \(team). Teams it can upload for: \(known.joined(separator: ", "))."]
        }
        selection = target  // show the upload where the person is looking
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let verifyOnly = request["verify_only"] as? Bool ?? false
        let job = unfinished(url, target) ?? enqueue(url, target)
        if !job.isRunning { start(job, deliver: !verifyOnly) }
        await finished(job, progress)
        // It was still verifying, dropped in by hand, when the agent asked to deliver it.
        if !verifyOnly, job.state == .verified {
            start(job, deliver: true)
            await finished(job, progress)
        }
        return ["build": summary(job)]
    }

    // ponytail: polls the job twice a second; observe it instead if agents ever queue many builds at once.
    private func finished(_ job: Job, _ progress: ([String: Any]) -> Void) async {
        var last: Double?
        while job.isRunning {
            if let percent = job.progress, percent != last {
                last = percent
                progress(["progress": percent, "message": job.state == .delivering ? "Delivering" : "Verifying"])
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func summary(_ job: Job) -> [String: Any] {
        var out = Agent.summary(url: job.url, info: job.info, state: job.state.rawValue, deliveryID: job.deliveryID,
                                teamID: accounts.teamID(of: job.target))
        if job.isRunning, let percent = job.progress { out["progress"] = percent }
        // altool sometimes names the account in its messages; the agent has no use for it.
        if job.state == .failed {
            out["errors"] = job.issues.map { $0.replacingOccurrences(of: job.target.appleID, with: "<Apple Account>") }
        }
        return out
    }
}

// MARK: - MCP process

enum MCPServer {
    static let tools: [[String: Any]] = [
        [
            "name": "list_teams",
            "description": "List the Apple developer teams Shipper can upload builds for, with their Team IDs.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "upload_build",
            "description": """
                Upload an .ipa or .pkg to App Store Connect for a developer team. Shipper opens and shows the upload \
                in its queue. Returns when the upload finishes, which can take several minutes. If the call times \
                out the upload keeps running: check list_builds instead of uploading again. An uploaded build \
                cannot be deleted from App Store Connect.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path of the .ipa or .pkg file."],
                    "team_id": ["type": "string", "description": "Apple Developer Team ID, such as A1B2C3D4E5. See list_teams."],
                    "verify_only": ["type": "boolean", "description": "Validate with App Store Connect without uploading. Default false."],
                ],
                "required": ["path", "team_id"],
            ],
            "annotations": ["readOnlyHint": false, "openWorldHint": true],
        ],
        [
            "name": "list_builds",
            "description": "List the builds in Shipper's queue with their state (verifying, delivering, verified, delivered, failed, stopped), progress and errors.",
            "inputSchema": [
                "type": "object",
                "properties": ["team_id": ["type": "string", "description": "Only this team's builds."]],
            ],
            "annotations": ["readOnlyHint": true],
        ],
    ]

    /// Only tools are used, and those are the same in every protocol revision so far.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The reply to every request except a tool call. Nil for notifications and for replies, which need no answer.
    static func reply(to message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let result: [String: Any]
        switch method {
        case "initialize":
            let asked = (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? ""
            result = [
                "protocolVersion": protocolVersions.contains(asked) ? asked : "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "shipper", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": "Uploads iOS and macOS builds to App Store Connect through the Shipper app. Call list_teams for Team IDs, then upload_build with an absolute path. Uploads appear in Shipper's window.",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools]
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine() {
            guard let message = Agent.json(line) else { continue }
            if message["method"] as? String == "tools/call", let id = message["id"] {
                // Off the reading thread, so a ping or a second call is answered while an upload runs.
                Task.detached {
                    let (text, isError) = await call(message["params"] as? [String: Any] ?? [:])
                    write(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": isError]])
                }
            } else if let reply = reply(to: message) {
                write(reply)
            }
        }
        exit(0)  // the agent closed the session; an upload it started carries on in the app
    }

    private static let output = NSLock()

    private static func write(_ message: [String: Any]) {
        output.lock()
        defer { output.unlock() }
        FileHandle.standardOutput.send(message)
    }

    private static func call(_ params: [String: Any]) async -> (text: String, isError: Bool) {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let accounts = UserDefaults.standard.data(forKey: "accounts").flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        switch params["name"] as? String {
        case "list_teams":
            guard !accounts.isEmpty else { return ("No Apple Account is signed in. Open Shipper and sign in first.", true) }
            var seen = Set<String>()
            let teams = accounts.flatMap(\.providers).filter { !$0.teamID.isEmpty && seen.insert($0.teamID).inserted }
            return (text(["teams": teams.map { ["team_id": $0.teamID, "name": $0.name] }]), false)

        case "list_builds":
            var request: [String: Any] = ["op": "builds"]
            request["team_id"] = arguments["team_id"]
            if let reply = await ask(request, launch: false) { return result(reply) }
            // Shipper isn't open, so nothing is uploading; what's left is the history it keeps of delivered builds.
            let team = (arguments["team_id"] as? String)?.uppercased()
            let saved = UserDefaults.standard.data(forKey: "delivered").flatMap { try? JSONDecoder().decode([Job.Saved].self, from: $0) } ?? []
            let builds = saved.map {
                Agent.summary(url: $0.url, info: $0.info, state: "delivered", deliveryID: $0.deliveryID, teamID: accounts.teamID(of: $0.target))
            }.filter { team == nil || ($0["team_id"] as? String)?.uppercased() == team }
            return (text(["builds": builds]), false)

        case "upload_build":
            guard let path = arguments["path"] as? String, let team = arguments["team_id"] as? String else {
                return ("path and team_id are required.", true)
            }
            if let error = Agent.pathError(path) { return (error, true) }
            var request: [String: Any] = ["op": "upload", "path": path, "team_id": team]
            request["verify_only"] = arguments["verify_only"]
            let token = (params["_meta"] as? [String: Any])?["progressToken"]
            let reply = await ask(request, launch: true) { update in
                guard let token else { return }
                var progress = update
                progress["progressToken"] = token
                progress["total"] = 100
                write(["jsonrpc": "2.0", "method": "notifications/progress", "params": progress])
            }
            return result(reply ?? ["error": "Shipper didn't answer. Quit and reopen Shipper (1.3 or later), then try again."])

        default:
            return ("Unknown tool.", true)
        }
    }

    /// A failed upload is an error to the agent even though the app answered.
    private static func result(_ reply: [String: Any]) -> (text: String, isError: Bool) {
        if let error = reply["error"] as? String { return (error, true) }
        let state = (reply["build"] as? [String: Any])?["state"] as? String
        return (text(reply), state == "failed" || state == "stopped")
    }

    private static func text(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Sends the app one request and returns its final line, passing progress lines to `onProgress`. With `launch`,
    /// opens Shipper in the background first. Nil when the app can't be reached.
    private static func ask(_ request: [String: Any], launch: Bool, onProgress: ([String: Any]) -> Void = { _ in }) async -> [String: Any]? {
        var connection = AgentSocket.connect()
        if connection == nil, launch, Bundle.main.bundleURL.pathExtension == "app" {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", Bundle.main.bundlePath]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<100 where connection == nil {  // up to 20 s for the app to start listening
                try? await Task.sleep(for: .milliseconds(200))
                connection = AgentSocket.connect()
            }
        }
        guard let connection else { return nil }
        connection.send(request)
        do {
            for try await line in connection.bytes.lines {
                guard let message = Agent.json(line) else { continue }
                if message["progress"] != nil { onProgress(message) } else { return message }
            }
        } catch {}
        return ["error": "Shipper quit before it finished."]
    }
}

// MARK: - Adding Shipper to agents

/// An agent Shipper can add itself to. MCP has no system-wide registry: every agent keeps its own list of servers,
/// so connecting one means writing Shipper's entry where that agent looks.
struct AgentApp: Identifiable, Sendable {
    enum Format: Sendable {
        /// A JSON file with an object of servers under `key`. `type` is added to the entry for agents that want it.
        case json(key: String, type: String? = nil)
        /// Codex's config.toml: one `[mcp_servers.<name>]` table per server.
        case toml
        /// Claude Code rewrites ~/.claude.json while it runs, so changes go through its own `claude mcp` command.
        case claudeCLI
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    let name: String
    /// Where the agent keeps its servers. When its docs name more than one place, the one that exists is used.
    let files: [String]
    /// Paths that exist only once the agent has been set up on this Mac.
    let markers: [String]
    let format: Format

    var id: String { name }

    static let all = [
        AgentApp(name: "Claude Code", files: ["~/.claude.json"], markers: ["~/.claude.json"], format: .claudeCLI),
        AgentApp(name: "Claude Desktop", files: ["~/Library/Application Support/Claude/claude_desktop_config.json"],
                 markers: ["~/Library/Application Support/Claude"], format: .json(key: "mcpServers")),
        AgentApp(name: "Cursor", files: ["~/.cursor/mcp.json"], markers: ["~/.cursor"], format: .json(key: "mcpServers")),
        AgentApp(name: "Codex", files: ["~/.codex/config.toml"], markers: ["~/.codex"], format: .toml),
        AgentApp(name: "Antigravity", files: ["~/.gemini/config/mcp_config.json", "~/.gemini/antigravity/mcp_config.json"],
                 markers: ["~/.gemini/config", "~/.gemini/antigravity", "/Applications/Antigravity.app"], format: .json(key: "mcpServers")),
        AgentApp(name: "VS Code", files: ["~/Library/Application Support/Code/User/mcp.json"],
                 markers: ["~/Library/Application Support/Code/User"], format: .json(key: "servers", type: "stdio")),
        AgentApp(name: "Windsurf", files: ["~/.codeium/windsurf/mcp_config.json"], markers: ["~/.codeium/windsurf"],
                 format: .json(key: "mcpServers")),
        AgentApp(name: "Gemini CLI", files: ["~/.gemini/settings.json"], markers: ["~/.gemini/settings.json"],
                 format: .json(key: "mcpServers")),
    ]

    private static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    var file: URL {
        URL(fileURLWithPath: Self.expand(files.first { FileManager.default.fileExists(atPath: Self.expand($0)) } ?? files[0]))
    }

    var isInstalled: Bool { markers.contains { FileManager.default.fileExists(atPath: Self.expand($0)) } }

    /// Whether the agent already starts this copy of Shipper.
    func isConnected(to executable: String) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        switch format {
        case .json(let key, _): return Self.command(inJSON: data, key: key) == executable
        case .claudeCLI: return Self.command(inJSON: data, key: "mcpServers") == executable
        case .toml: return Self.isInTOML(String(decoding: data, as: UTF8.self), command: executable)
        }
    }

    /// Adds Shipper to the agent's servers, or removes it. Blocks while `claude` runs, so call it off the main thread.
    func setConnected(_ on: Bool, executable: String) throws {
        let exists = FileManager.default.fileExists(atPath: file.path)
        if !on, !exists { return }
        let data: Data
        switch format {
        case .claudeCLI:
            let remove = "claude mcp remove --scope user shipper"
            try Self.claude(on ? "\(remove) >/dev/null 2>&1; claude mcp add --scope user shipper -- \(Agent.shellQuoted(executable)) --mcp" : remove)
            return
        case .json(let key, let type):
            var entry: [String: Any] = ["command": executable, "args": ["--mcp"]]
            entry["type"] = type
            data = try Self.json(exists ? Data(contentsOf: file) : nil, key: key, entry: on ? entry : nil)
        case .toml:
            let text = exists ? String(decoding: try Data(contentsOf: file), as: UTF8.self) : ""
            data = Data(Self.toml(text, command: on ? executable : nil).utf8)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written in place, not swapped in: that keeps the file's permissions (these configs often hold API keys)
        // and a symlink to a dotfiles repo stays a symlink.
        try data.write(to: file)
    }

    // MARK: JSON

    static func command(inJSON data: Data, key: String) -> String? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((root?[key] as? [String: Any])?["shipper"] as? [String: Any])?["command"] as? String
    }

    /// The config with Shipper's entry set, or removed when `entry` is nil. Everything else in it is kept.
    static func json(_ data: Data?, key: String, entry: [String: Any]?) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Comments and trailing commas fail here on purpose: writing the file back would drop them.
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  parsed[key] == nil || parsed[key] is [String: Any]
            else { throw Failure(errorDescription: "This file has comments or a layout Shipper can't keep. Add Shipper by hand with the config below.") }
            root = parsed
        }
        var servers = root[key] as? [String: Any] ?? [:]
        if let entry { servers["shipper"] = entry } else { servers.removeValue(forKey: "shipper") }
        root[key] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    // MARK: TOML

    private static let header = "[mcp_servers.shipper]"

    /// The lines of Shipper's table: from its header up to the next table.
    private static func table(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        return start..<end
    }

    static func isInTOML(_ text: String, command: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard let table = table(in: lines) else { return false }
        return lines[table].contains { $0.trimmingCharacters(in: .whitespaces) == "command = \(Agent.quoted(command))" }
    }

    /// The config with Shipper's table replaced, or removed when `command` is nil. Every other line is kept as it is.
    static func toml(_ text: String, command: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if let table = table(in: lines) { lines.removeSubrange(table) }
        var out = lines.joined(separator: "\n")
        while out.hasSuffix("\n\n") { out.removeLast() }
        guard let command else { return out }
        if !out.isEmpty { out += out.hasSuffix("\n") ? "\n" : "\n\n" }
        // A JSON string is also a valid TOML basic string.
        return out + "\(header)\ncommand = \(Agent.quoted(command))\nargs = [\"--mcp\"]\n"
    }

    // MARK: Claude Code

    private static func claude(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // An app opened from Finder has no shell PATH: use a login shell plus the places Claude Code installs itself.
        process.arguments = ["-lc", #"PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"; "# + command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        throw Failure(errorDescription: process.terminationStatus == 127
            ? "Couldn't find the claude command. Add Shipper by hand with the config below."
            : output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
