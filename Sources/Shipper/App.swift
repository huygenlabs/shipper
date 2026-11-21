import SwiftUI

@main
enum Main {
    /// `Shipper --mcp` is the MCP server AI agents start (MCP.swift); anything else is the app.
    @MainActor static func main() {
        if CommandLine.arguments.contains("--mcp") { MCPServer.run() }
        ShipperApp.main()
    }
}

struct ShipperApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(Updater.autoCheckKey) private var checksForUpdates = true

    init() {
        Store.moveFromOldBundleID()
        Store.moveFromOldName()
        NotificationService.requestAuthorization()
        // Before anything at launch can hold up the main thread, so an agent that just opened Shipper connects at once.
        AppDelegate.store.listenForAgents()
    }

    var body: some Scene {
        Window("Shipper", id: "main") {
            ContentView().environment(AppDelegate.store)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.check(userInitiated: true) } }
                Toggle("Install Updates Automatically", isOn: $checksForUpdates)
                Divider()
                Button("Connect AI Agents…") { AppDelegate.store.showsAgentSetup = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add App…") { AppDelegate.store.openPanel() }
                    .keyboardShortcut("o")
                    .disabled(AppDelegate.store.selection == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Updater.checkPeriodically() }
    }

    /// Files opened from Finder (Info.plist registers .ipa and .pkg, like Transporter).
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.store.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = Self.store.jobs.filter(\.isRunning)
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while \(running.count == 1 ? "1 upload is" : "\(running.count) uploads are") running?"
        alert.informativeText = "Running verifications and deliveries will be stopped."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        running.forEach(Self.store.stop)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.installIfReady()
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var addingAccount = false

    var body: some View {
        @Bindable var store = store
        Group {
            if store.accounts.isEmpty {
                SignInView()
            } else {
                NavigationSplitView {
                    AccountsSidebar { addingAccount = true }
                        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
                } detail: {
                    QueueView()
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .sheet(isPresented: $addingAccount) {
            SignInView(onDone: { addingAccount = false })
                .padding(.vertical, 28)
                .frame(width: 420)
        }
        .sheet(isPresented: $store.showsAgentSetup) { AgentSetupView() }
        .sheet(isPresented: $store.showsAPIKeySetup) {
            if let target = store.apiKeyTarget { APIKeySetupView(target: target) }
        }
    }
}

// MARK: - AI agents

/// One switch per agent found on this Mac: on writes Shipper into that agent's MCP servers, off takes it out.
struct AgentSetupView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var connected: Set<String> = []
    @State private var busy: Set<String> = []
    @State private var changed: Set<String> = []
    @State private var errors: [String: String] = [:]
    private let executable = Bundle.main.executablePath ?? "/Applications/Shipper.app/Contents/MacOS/Shipper"
    private let agents = AgentApp.all.filter(\.isInstalled)
    private let missing = AgentApp.all.filter { !$0.isInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect AI Agents").font(.headline).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                Text("A connected agent can upload a build to a team by its Team ID. Its uploads appear in this window.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    if !agents.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(agents) { agent in
                                if agent.id != agents.first?.id { Divider() }
                                row(agent)
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)) }
                    }
                    if !missing.isEmpty {
                        Text("Not found on this Mac: \(missing.map(\.name).joined(separator: ", ")).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DisclosureGroup {
                    if agentTeams.isEmpty {
                        Text("Sign in to an Apple Account to manage team access.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(agentTeams, id: \.teamID) { provider in
                                if provider.teamID != agentTeams.first?.teamID { Divider() }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.name).lineLimit(1)
                                        Text(provider.teamID).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Toggle("Allow agent uploads to \(provider.name)", isOn: Binding(
                                        get: { store.isAgentUploadAllowed(for: provider.teamID) },
                                        set: { store.setAgentUploadAllowed($0, for: provider.teamID) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent upload access")
                        Text("Choose which teams connected agents may upload to. Validation-only requests remain available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Closed by default: with every agent installed, the open sheet would outgrow a laptop screen.
                DisclosureGroup("Add to another agent by hand") {
                    Snippet(title: "For its MCP config file", text: Self.config(executable))
                        .padding(.top, 8)
                }
                Text("ChatGPT and Claude in a browser only reach servers on the internet, so they can't use builds on this Mac. Any app running as you can use this connection to upload with your signed-in accounts. It can't read your passwords.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .frame(height: 360)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 480)
        .onAppear { connected = Set(agents.filter { $0.isConnected(to: executable) }.map(\.id)) }
    }

    private func row(_ agent: AgentApp) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                Text(errors[agent.id] ?? detail(agent))
                    .font(.caption)
                    .foregroundStyle(errors[agent.id] == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if busy.contains(agent.id) { ProgressView().controlSize(.small) }
            Toggle(agent.name, isOn: Binding { connected.contains(agent.id) } set: { set(agent, $0) })
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(busy.contains(agent.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var agentTeams: [Provider] {
        var seen = Set<String>()
        return store.accounts.flatMap(\.providers).filter { !($0.teamID.isEmpty) && seen.insert($0.teamID.uppercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The file the switch changes; once flipped, what's left for the person to do.
    private func detail(_ agent: AgentApp) -> String {
        let path = (agent.file.path as NSString).abbreviatingWithTildeInPath
        guard changed.contains(agent.id) else { return path }
        return connected.contains(agent.id) ? "Added to \(path). Restart \(agent.name) to load it." : "Removed from \(path)."
    }

    private func set(_ agent: AgentApp, _ on: Bool) {
        busy.insert(agent.id)
        errors[agent.id] = nil
        Task {
            let executable = executable
            let error = await Task.detached { () -> String? in
                do {
                    try agent.setConnected(on, executable: executable)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            busy.remove(agent.id)
            errors[agent.id] = error
            if error == nil { changed.insert(agent.id) }
            // The switch shows what the agent's config says now, whatever was asked for.
            if agent.isConnected(to: executable) { connected.insert(agent.id) } else { connected.remove(agent.id) }
        }
    }

    static func config(_ executable: String) -> String {
        """
        {
          "mcpServers": {
            "shipper": {
              "command": \(Agent.quoted(executable)),
              "args": ["--mcp"]
            }
          }
        }
        """
    }
}

/// A command or config block to paste elsewhere, with a Copy button that confirms it copied.
private struct Snippet: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)) }
        }
    }
}

// MARK: - Sign in

/// Mirrors Transporter's sign-in scene: icon, title, two tall centered fields, one full-width button, a link below a rule.
struct SignInView: View {
    private enum Field { case appleID, password }

    /// Set when shown as the Add Account sheet: called after sign-in or Cancel.
    var onDone: (() -> Void)?

    @Environment(Store.self) private var store
    @State private var appleID = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 100, height: 100)
            Text(onDone == nil ? "Sign in with your Apple Account" : "Add another Apple Account")
                .font(.title3.weight(.medium))
                .padding(.bottom, 18)

            VStack(spacing: 12) {
                TextField("Apple Account", text: $appleID)
                    .textContentType(.username)
                    .focused($focus, equals: .appleID)
                    .tallField(focused: focus == .appleID)
                SecureField("App-specific password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .tallField(focused: focus == .password)
                Button(action: signIn) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "Signing In…" : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || appleID.isEmpty || password.isEmpty)
            }
            .disabled(busy)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.top, 12)
            }

            Divider().padding(.top, 20)
            HStack {
                Link("Create an app-specific password", destination: URL(string: "https://account.apple.com/account/manage")!)
                if let onDone {
                    Spacer()
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                }
            }
            .font(.callout)
            .padding(.top, 12)
        }
        .frame(width: 330)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .appleID }
    }

    private func signIn() {
        busy = true
        error = nil
        Task {
            error = await store.signIn(appleID.trimmingCharacters(in: .whitespaces), password: password)
            busy = false
            if error == nil { onDone?() }
        }
    }
}

private extension View {
    /// Transporter's 43pt centered field (MZCenteredTextFieldCell), with an explicit focus ring since the plain style has none.
    func tallField(focused: Bool) -> some View {
        textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.title3)
            .padding(.horizontal, 12)
            .frame(height: 43)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
            }
    }
}

// MARK: - Accounts

/// Every signed-in Apple Account with the developer accounts (providers) it can deliver for, like App Store Connect's account menu.
struct AccountsSidebar: View {
    @Environment(Store.self) private var store
    @State private var collapsed: Set<String> = []
    let addAccount: () -> Void

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            ForEach(store.accounts) { account in
                Section(isExpanded: expanded(account.appleID)) {
                    if let error = store.refreshErrors[account.appleID] {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .help(error)
                            .selectionDisabled()
                    }
                    ForEach(account.rows, id: \.target) { row in
                        Group {
                            if let provider = row.provider {
                                ProviderRow(provider: provider)
                                    .contextMenu {
                                        Button("Copy Team ID") { copy(provider.teamID) }.disabled(provider.teamID.isEmpty)
                                        Button("Copy Provider ID") { copy(provider.publicID) }
                                        Divider()
                                        Button(provider.apiKeyID == nil ? "Add App Store Connect API Key…" : "Manage App Store Connect API Key…") {
                                            store.showAPIKeySetup(for: Target(appleID: account.appleID, publicID: provider.publicID))
                                        }
                                        accountMenu(account)
                                    }
                            } else {
                                Label {
                                    Text("Default developer account")
                                } icon: {
                                    ProviderIcon(systemName: "person.2.fill")
                                }
                                .help("Developer accounts couldn't be listed; altool picks the only one.")
                            }
                        }
                        .badge(store.jobs.filter { $0.target == row.target }.count)
                    }
                } header: {
                    AccountHeader(account: account, refreshing: store.refreshing.contains(account.appleID)) {
                        accountMenu(account)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text("Shipper")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 10) {
                    Button(action: addAccount) {
                        Label("Add Account…", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    Button { store.showsAgentSetup = true } label: {
                        Label("Connect AI Agents…", systemImage: "powerplug")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func expanded(_ appleID: String) -> Binding<Bool> {
        Binding { !collapsed.contains(appleID) } set: { open in
            if open { collapsed.remove(appleID) } else { collapsed.insert(appleID) }
        }
    }

    @ViewBuilder private func accountMenu(_ account: Account) -> some View {
        Button("Refresh Developer Accounts") { Task { await store.refresh(account.appleID) } }
            .disabled(store.refreshing.contains(account.appleID))
        Button("Copy Apple Account") { copy(account.appleID) }
        Divider()
        Button("Sign Out of \(account.appleID)") { store.signOut(account.appleID) }
            .disabled(store.jobs.contains { $0.isPending && $0.target.appleID == account.appleID })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct APIKeySetupView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: Target
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var privateKey = ""
    @State private var hasSavedKey = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App Store Connect API Key").font(.headline)
            Text("This team's API key lets Shipper check Apple's processing result after upload. Your existing app-specific password still handles uploads.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Key ID", text: $keyID)
            TextField("Issuer ID", text: $issuerID)
            Text("Private key (.p8)").font(.callout.weight(.medium))
            TextEditor(text: $privateKey)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)) }
            Link("Create an API key in App Store Connect", destination: URL(string: "https://appstoreconnect.apple.com/access/api")!)
                .font(.callout)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if hasSavedKey {
                    Button("Remove Key", role: .destructive) {
                        store.removeAPIKey(for: target)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(keyID.isEmpty || issuerID.isEmpty || privateKey.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            if let provider = store.accounts.first(where: { $0.appleID == target.appleID })?.providers.first(where: { $0.publicID == target.publicID }) {
                keyID = provider.apiKeyID ?? ""
                issuerID = provider.apiIssuerID ?? ""
            }
            let savedKey = store.apiPrivateKey(for: target)
            hasSavedKey = savedKey != nil
            privateKey = savedKey ?? ""
        }
    }

    private func save() {
        error = store.saveAPIKey(for: target, keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                                 issuerID: issuerID.trimmingCharacters(in: .whitespacesAndNewlines), privateKey: privateKey)
        if error == nil { dismiss() }
    }
}

/// The Apple Account a group of developer accounts belongs to: monogram, email, count, options.
struct AccountHeader<MenuItems: View>: View {
    let account: Account
    let refreshing: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        HStack(spacing: 8) {
            Text(initials)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.gray.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(account.appleID)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if refreshing { ProgressView().controlSize(.mini) }
            Menu(content: menuItems) { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Options for \(account.appleID)")
        }
        .textCase(nil)
        .padding(.vertical, 6)
        .contextMenu(menuItems: menuItems)
    }

    /// "jane.doe@…" → "JD".
    private var initials: String {
        let name = account.appleID.split(separator: "@").first ?? ""
        let parts = name.split(whereSeparator: { ".-_+".contains($0) }).prefix(2)
        return parts.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    private var subtitle: String {
        if refreshing && account.providers.isEmpty { return "Loading developer accounts…" }
        let count = account.providers.count
        return count == 1 ? "1 developer account" : "\(count) developer accounts"
    }
}

/// One developer account (provider): name, kind, and the Team ID used when delivering.
struct ProviderRow: View {
    let provider: Provider

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .lineLimit(2)
                Text(provider.teamID.isEmpty ? provider.publicID : provider.teamID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 2)
        } icon: {
            ProviderIcon(systemName: provider.isIndividual ? "person.fill" : "building.2.fill")
        }
        .help("\(provider.isIndividual ? "Individual" : "Organization") · Team ID \(provider.teamID)\nProvider ID \(provider.publicID)")
    }
}

/// A developer account's glyph in a rounded tile, so individuals and organizations read apart at a glance.
struct ProviderIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var targeted = false
    @State private var logJob: Job?

    private var jobs: [Job] { store.jobs.filter { $0.target == store.selection } }

    var body: some View {
        GeometryReader { proxy in
            let noticeTarget = store.selection.flatMap { store.shouldShowAPIKeyNotice(for: $0) ? $0 : nil }
            List {
                if store.selection == nil {
                    Text("Select a developer account")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                } else {
                    if let noticeTarget {
                        APIKeySetupNotice(target: noticeTarget)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    if jobs.isEmpty {
                        emptyState
                            .frame(height: max(proxy.size.height - (noticeTarget == nil ? 0 : 120), 240))
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(jobs) { job in
                            JobRow(job: job) { logJob = job }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return store.selection != nil
        } isTargeted: { targeted = $0 }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
            }
        }
        .navigationTitle("")
        .navigationSubtitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selectedProvider?.name ?? store.selection?.appleID ?? "Shipper")
                        .font(.headline)
                        .lineLimit(1)
                    if let appleID = store.selectedProvider == nil ? nil : store.selection?.appleID {
                        Text(appleID).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if store.selectedProvider != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openURL(Self.appStoreConnectURL)
                    } label: {
                        Label("Open App Store Connect", systemImage: "arrow.up.right.square")
                    }
                    .help("Open App Store Connect")
                    .accessibilityLabel("Open App Store Connect for this team")
                }
            }
            ToolbarItem {
                Button(action: store.clear) { Label("Clear", systemImage: "clear") }
                    .help("Remove finished builds from this list")
                    .disabled(!jobs.contains { !$0.isPending })
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: store.openPanel) { Label("Add App", systemImage: "plus") }
                    .help("Add an .ipa or .pkg")
                    .disabled(store.selection == nil)
            }
        }
        .sheet(item: $logJob) { LogView(job: $0) }
    }

    private static let appStoreConnectURL = URL(string: "https://appstoreconnect.apple.com")!

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drag an .ipa or .pkg here")
                .font(.title3)
            Button("Add App…", action: store.openPanel)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(20)
        }
    }
}

private struct APIKeySetupNotice: View {
    @Environment(Store.self) private var store
    let target: Target

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Track Apple's processing")
                    .font(.callout.weight(.semibold))
                Text("Your Apple login lets Shipper validate and upload. Apple requires a separate team API key to read processing results after upload. Its .p8 file signs those read-only requests and stays in your Mac's Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up API Key…") { store.showAPIKeySetup(for: target) }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer(minLength: 4)
            Button {
                store.dismissAPIKeyNotice(for: target)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss for this team")
            .accessibilityLabel("Dismiss API key explanation")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.18)) }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct JobRow: View {
    @Environment(Store.self) private var store
    @State private var showsError = false
    let job: Job
    let showLog: () -> Void

    var body: some View {
        // Top-aligned so the icon and buttons stay beside the name when error details expand the row.
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = job.info?.icon.flatMap(NSImage.init(data:)) {
                    // iOS icons ship square and the system masks them; inset to match Finder icons' visual size.
                    Image(nsImage: icon)
                        .resizable()
                        .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                        .padding(3)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
                        .resizable()
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).font(.headline)
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.isRunning {
                    // Indeterminate until altool reports a percentage.
                    ProgressView(value: job.progress, total: 100)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .padding(.vertical, 3)
                }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            HStack { actions }.frame(height: 40)
        }
        .padding(.vertical, 6)
        .contextMenu { menuItems }
    }

    private var details: String {
        var parts: [String] = []
        if let info = job.info { parts += ["\(info.version) (\(info.build))", info.bundleID] }
        parts.append(ByteCountFormatter.string(fromByteCount: job.size, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .ready:
            EmptyView()
        case .verifying, .delivering:
            Text((job.state == .delivering ? "Delivering" : "Verifying") + (job.progress.map { " – \(Int($0))%" } ?? "…"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .processing:
            Label("Apple is processing this build…", systemImage: "hourglass")
                .font(.callout).foregroundStyle(.secondary)
        case .uploaded:
            Label(job.issue ?? "Uploaded; processing status is not connected", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.orange)
        case .verified:
            Label("Verified, ready to deliver", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .delivered:
            Label("Delivered" + (job.deliveryID.map { " · \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failed:
            // One line by default; Details opens every message, selectable and copyable.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(Altool.headline(job.issues) ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button {
                        showsError.toggle()
                    } label: {
                        Label(showsError ? "Hide Details" : "Details", systemImage: showsError ? "chevron.up" : "chevron.down")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                }
                if showsError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.verified ? job.issues.joined(separator: "\n\n") : job.validationReport)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button(job.verified ? "Copy Message" : "Copy Validation Report") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(job.verified ? job.issues.joined(separator: "\n\n") : job.validationReport, forType: .string)
                            }
                            Button("View Full Log", action: showLog)
                        }
                        .controlSize(.small)
                        if !job.verified {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Suggested next steps").font(.callout.weight(.semibold))
                                ForEach(job.validationSuggestions, id: \.self) { suggestion in
                                    Label(suggestion, systemImage: "arrow.turn.down.right")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.25)) }
                }
            }
            .font(.callout)
        case .stopped:
            Text("Stopped").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Verify runs on add; Deliver appears only once the package has passed verification.
    @ViewBuilder private var actions: some View {
        if job.state == .processing {
            Button("Stop Check") { store.stop(job) }
        } else if job.isRunning {
            Button("Stop") { store.stop(job) }
        } else if job.state == .delivered || job.state == .uploaded {
            if job.state == .uploaded {
                Button("Check Processing") { store.retryProcessingCheck(job) }
                    .disabled(job.deliveryID == nil)
            }
            Button("View Log", action: showLog)
        } else if job.state == .stopped, job.deliveryID != nil {
            Button("Resume Check") { store.retryProcessingCheck(job) }
        } else {
            if job.state == .failed || job.state == .stopped {
                if job.verified {
                    Button("Retry Upload") { store.retry(job) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Retry Validation") { store.retry(job) }
                }
            } else if job.verified {
                Button("Deliver") { store.start(job, deliver: true) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Verify") { store.start(job, deliver: false) }
            }
        }
        Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    @ViewBuilder private var menuItems: some View {
        Button("View Log", action: showLog).disabled(job.log.isEmpty)
        Button("Verify Again") { store.start(job, deliver: false) }.disabled(job.isPending || job.deliveryID != nil)
        if job.isPending { Button(job.state == .processing ? "Stop Status Check" : "Stop") { store.stop(job) } }
        if job.state == .failed || job.state == .stopped, job.deliveryID == nil {
            Button(job.verified ? "Retry Upload" : "Retry Validation") { store.retry(job) }
        }
        if [.uploaded, .stopped].contains(job.state), job.deliveryID != nil {
            Button("Check Processing Again") { store.retryProcessingCheck(job) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
        Divider()
        Button("Remove from Queue", role: .destructive) { store.remove(job) }
    }
}

struct LogView: View {
    let job: Job
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(job.name) – Log").font(.headline).padding()
            Divider()
            ScrollView {
                Text(job.log.isEmpty ? "No output yet." : job.log.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .defaultScrollAnchor(.bottom)
            Divider()
            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.log.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 700, height: 440)
    }
}
