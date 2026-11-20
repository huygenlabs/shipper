import Foundation
import Security
import Darwin

/// Standalone, local MCP server for the ChatGPT Desktop plugin. It deliberately does not depend on Shipper.app.
/// Apple credentials are entered in Terminal by `--setup` and stored in the user's login Keychain; they are never
/// accepted as MCP arguments or passed through the model.
enum ShipperChatGPTMCP {
    private static let service = "Shipper ChatGPT Plugin"
    private static let preferences = UserDefaults(suiteName: "com.huygenlabs.shipper-chatgpt-plugin")!
    private static let outputLock = NSLock()

    private struct Provider: Decodable {
        let id: String
        let type: String
        let attributes: Attributes?
        struct Attributes: Decodable {
            let name: String?
            let developerTeamId: String?
        }
        var name: String { attributes?.name ?? id }
        var teamID: String { attributes?.developerTeamId ?? "" }
    }

    private struct ProviderResponse: Decodable {
        let included: [Provider]?
    }

    private static let tools: [[String: Any]] = [
        ["name": "list_teams",
         "description": "List the App Store Connect teams available to the Apple Accounts configured on this Mac.",
         "inputSchema": ["type": "object", "properties": [String: Any]()],
         "annotations": ["readOnlyHint": true]],
        ["name": "validate_build",
         "description": "Run Apple's Transporter validation for a local .ipa or .pkg without uploading it.",
         "inputSchema": ["type": "object", "properties": [
            "path": ["type": "string", "description": "Absolute path to a local .ipa or .pkg file."],
            "team_id": ["type": "string", "description": "Apple Developer Team ID from list_teams."]
         ], "required": ["path", "team_id"]],
         "annotations": ["readOnlyHint": true]],
        ["name": "upload_build",
         "description": "Validate a local .ipa or .pkg with Apple's Transporter, then upload it to App Store Connect. Upload is irreversible; confirm with the user before calling this tool.",
         "inputSchema": ["type": "object", "properties": [
            "path": ["type": "string", "description": "Absolute path to a local .ipa or .pkg file."],
            "team_id": ["type": "string", "description": "Apple Developer Team ID from list_teams."]
         ], "required": ["path", "team_id"]],
         "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]]
    ]

    static func main() -> Never {
        if CommandLine.arguments.contains("--setup") { setup() }
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if message["method"] as? String == "tools/call", let id = message["id"] {
                let params = message["params"] as? [String: Any] ?? [:]
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = call(name: params["name"] as? String ?? "", args: params["arguments"] as? [String: Any] ?? [:])
                    write(["jsonrpc": "2.0", "id": id,
                           "result": ["content": [["type": "text", "text": result.text]], "isError": result.isError]])
                }
            } else if let id = message["id"], let method = message["method"] as? String {
                switch method {
                case "initialize":
                    write(["jsonrpc": "2.0", "id": id, "result": [
                        "protocolVersion": "2025-06-18", "capabilities": ["tools": [String: Any]()],
                        "serverInfo": ["name": "shipper-chatgpt", "version": "1.0.0"],
                        "instructions": "Local App Store Connect uploader. Use list_teams, validate_build, then ask the user before upload_build. Apple credentials are configured locally with shipper-mcp --setup and are never requested in chat."
                    ]])
                case "ping": write(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
                case "tools/list": write(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
                default: write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
                }
            }
        }
        exit(0)
    }

    private static func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    private static func call(name: String, args: [String: Any]) -> (text: String, isError: Bool) {
        let appleIDs = preferences.stringArray(forKey: "appleIDs") ?? []
        switch name {
        case "list_teams":
            guard !appleIDs.isEmpty else { return ("No Apple Account is configured. Run the bundled shipper-mcp --setup command in Terminal.", true) }
            var teams: [[String: String]] = []
            var failures: [String] = []
            for appleID in appleIDs {
                guard let password = password(for: appleID) else {
                    failures.append("Saved credentials for an account are unavailable in Keychain.")
                    continue
                }
                let result = runAltool(["--list-providers", "--output-format", "json", "-u", appleID], password: password)
                guard result.status == 0 else {
                    failures.append(headline(result.output, appleID: appleID, password: password) ?? "Could not list teams for a configured Apple Account.")
                    continue
                }
                for provider in providers(in: result.output) where !provider.teamID.isEmpty {
                    teams.append(["team_id": provider.teamID, "name": provider.name])
                }
            }
            var unique: [String: [String: String]] = [:]
            for team in teams { unique[team["team_id", default: ""].uppercased()] = team }
            let response: [String: Any] = ["teams": unique.values.sorted { $0["name", default: ""].localizedCaseInsensitiveCompare($1["name", default: ""]) == .orderedAscending }, "warnings": failures]
            return (json(response), false)

        case "validate_build", "upload_build":
            guard let path = args["path"] as? String, let teamID = args["team_id"] as? String else {
                return ("path and team_id are required.", true)
            }
            guard path.hasPrefix("/"), ["ipa", "pkg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                return ("Provide an absolute path to an .ipa or .pkg file.", true)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return ("No file exists at \(path).", true)
            }
            guard let target = findAccount(for: teamID) else {
                return ("No configured Apple Account has team \(teamID). Run shipper-mcp --setup or check the Team ID.", true)
            }
            let file = URL(fileURLWithPath: path).standardizedFileURL.path
            let validate = runAltool(["--validate-app", file, "-u", target.appleID, "--provider-public-id", target.providerID], password: target.password)
            guard validate.status == 0 else {
                return (json(["state": "validation_failed", "team_id": target.teamID, "path": file,
                              "error": headline(validate.output, appleID: target.appleID, password: target.password) ?? "Apple validation failed.",
                              "details": redacted(validate.output, appleID: target.appleID, password: target.password)]), true)
            }
            if name == "validate_build" {
                return (json(["state": "validated", "team_id": target.teamID, "path": file,
                              "message": "Apple validation passed. The build was not uploaded."]), false)
            }
            let upload = runAltool(["--upload-package", file, "-u", target.appleID, "--provider-public-id", target.providerID], password: target.password)
            guard upload.status == 0 else {
                return (json(["state": "upload_failed", "team_id": target.teamID, "path": file,
                              "error": headline(upload.output, appleID: target.appleID, password: target.password) ?? "Apple upload failed.",
                              "details": redacted(upload.output, appleID: target.appleID, password: target.password)]), true)
            }
            let deliveryID = upload.output.firstMatch(of: #/Delivery UUID:\s*([0-9A-Fa-f-]{36})/#).map { String($0.1) }
            var result: [String: Any] = ["state": "uploaded", "team_id": target.teamID, "path": file,
                                        "message": "Apple accepted the upload command. Check App Store Connect for processing status."]
            if let deliveryID { result["delivery_id"] = deliveryID }
            return (json(result), false)

        default: return ("Unknown tool.", true)
        }
    }

    private struct Target { let appleID: String; let password: String; let providerID: String; let teamID: String }

    private static func findAccount(for teamID: String) -> Target? {
        for appleID in preferences.stringArray(forKey: "appleIDs") ?? [] {
            guard let password = password(for: appleID) else { continue }
            let result = runAltool(["--list-providers", "--output-format", "json", "-u", appleID], password: password)
            guard result.status == 0 else { continue }
            if let provider = providers(in: result.output).first(where: { $0.teamID.caseInsensitiveCompare(teamID) == .orderedSame }) {
                return Target(appleID: appleID, password: password, providerID: provider.id, teamID: provider.teamID)
            }
        }
        return nil
    }

    private static func providers(in output: String) -> [Provider] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let response = try? JSONDecoder().decode(ProviderResponse.self, from: Data(output[start...end].utf8)) else { return [] }
        return (response.included ?? []).filter { $0.type == "providers" }
    }

    private static func runAltool(_ args: [String], password: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["altool"] + args
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        do { try process.run() } catch { return (-1, "ERROR: Xcode's altool could not start: \(error.localizedDescription)") }
        input.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func headline(_ output: String, appleID: String, password: String) -> String? {
        let issues = output.split(separator: "\n").map(String.init).map {
            $0.replacingOccurrences(of: appleID, with: "<Apple Account>").replacingOccurrences(of: password, with: "<redacted>")
        }
            .filter { $0.contains("ERROR:") && !$0.contains("ExitFailure") && !$0.contains("Logging KPI") }
        return issues.first { !$0.contains("Error Domain=") } ?? issues.first
    }

    private static func redacted(_ output: String, appleID: String, password: String) -> String {
        output.replacingOccurrences(of: appleID, with: "<Apple Account>")
            .replacingOccurrences(of: password, with: "<redacted>")
            .replacing(#/\u{001B}\[[0-9;]*[A-Za-z]/#, with: "")
            .split(separator: "\n").map(String.init).filter { !$0.contains("Logging KPI") }.suffix(80).joined(separator: "\n")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func password(for appleID: String) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: appleID,
                                    kSecReturnData as String: true]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ password: String, for appleID: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: appleID]
        let attrs: [String: Any] = [kSecValueData as String: Data(password.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        attrs.forEach { add[$0.key] = $0.value }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func setup() -> Never {
        guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
            fputs("Run --setup from Terminal so the password can be entered privately.\n", stderr); exit(2)
        }
        fputs("Apple Account email: ", stderr)
        guard let appleID = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), appleID.contains("@") else {
            fputs("A valid Apple Account email is required.\n", stderr); exit(2)
        }
        fputs("App-specific password (input hidden): ", stderr)
        guard let appPassword = readSecret(), !appPassword.isEmpty else {
            fputs("An app-specific password is required.\n", stderr); exit(2)
        }
        let result = runAltool(["--list-providers", "--output-format", "json", "-u", appleID], password: appPassword)
        guard result.status == 0 else {
            fputs((headline(result.output, appleID: appleID, password: appPassword) ?? "Apple sign-in failed.") + "\n", stderr); exit(1)
        }
        guard save(appPassword, for: appleID) else {
            fputs("Could not save the app-specific password in the login Keychain.\n", stderr); exit(1)
        }
        var appleIDs = preferences.stringArray(forKey: "appleIDs") ?? []
        if !appleIDs.contains(where: { $0.caseInsensitiveCompare(appleID) == .orderedSame }) { appleIDs.append(appleID) }
        preferences.set(appleIDs, forKey: "appleIDs")
        let teams = providers(in: result.output).filter { !$0.teamID.isEmpty }
        fputs("Saved securely. Teams available to the plugin:\n", stderr)
        for team in teams { fputs("  \(team.name) (\(team.teamID))\n", stderr) }
        if teams.isEmpty { fputs("  No teams were returned for this account.\n", stderr) }
        fputs("The password was saved to your macOS login Keychain. You can now use the ChatGPT Desktop plugin.\n", stderr)
        exit(0)
    }

    private static func readSecret() -> String? {
        var old = termios()
        guard tcgetattr(STDIN_FILENO, &old) == 0 else { return nil }
        var hidden = old
        hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else { return nil }
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &old) }
        let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
        fputs("\n", stderr)
        return value
    }
}

ShipperChatGPTMCP.main()
