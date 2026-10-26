import SwiftUI

@main
struct ShipperApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(Updater.autoCheckKey) private var checksForUpdates = true

    var body: some Scene {
        Window("Shipper", id: "main") {
            ContentView().environment(AppDelegate.store)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.check(userInitiated: true) } }
                Toggle("Check for Updates Automatically", isOn: $checksForUpdates)
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
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var addingAccount = false

    var body: some View {
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
                                        accountMenu(account)
                                    }
                            } else {
                                Label("Default developer account", systemImage: "person.2")
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button(action: addAccount) {
                    Label("Add Account…", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
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
            .disabled(store.jobs.contains { $0.isRunning && $0.target.appleID == account.appleID })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            Image(systemName: provider.isIndividual ? "person" : "building.2")
        }
        .help("\(provider.isIndividual ? "Individual" : "Organization") · Team ID \(provider.teamID)\nProvider ID \(provider.publicID)")
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(Store.self) private var store
    @State private var targeted = false
    @State private var logJob: Job?

    private var jobs: [Job] { store.jobs.filter { $0.target == store.selection } }

    var body: some View {
        Group {
            if store.selection == nil {
                Text("Select a developer account").foregroundStyle(.secondary)
            } else if jobs.isEmpty {
                emptyState
            } else {
                List(jobs) { job in
                    JobRow(job: job) { logJob = job }
                }
                .listStyle(.inset)
            }
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
        .navigationTitle(store.selectedProvider?.name ?? store.selection?.appleID ?? "Shipper")
        .navigationSubtitle(store.selectedProvider == nil ? "" : store.selection?.appleID ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: store.openPanel) { Label("Add App", systemImage: "plus") }
                    .help("Add an .ipa or .pkg")
                    .disabled(store.selection == nil)
            }
        }
        .sheet(item: $logJob) { LogView(job: $0) }
    }

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

struct JobRow: View {
    @Environment(Store.self) private var store
    @State private var showsError = false
    let job: Job
    let showLog: () -> Void

    var body: some View {
        // Top-aligned so the icon and buttons stay beside the name when error details expand the row.
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
                .resizable()
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
                        Text(job.issues.joined(separator: "\n\n"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Copy Message") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(job.issues.joined(separator: "\n\n"), forType: .string)
                            }
                            Button("View Full Log", action: showLog)
                        }
                        .controlSize(.small)
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
        if job.isRunning {
            Button("Stop") { store.stop(job) }
        } else if job.state == .delivered {
            Button("View Log", action: showLog)
        } else {
            if job.verified {
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
        Button("Verify Again") { store.start(job, deliver: false) }.disabled(job.isRunning || !job.verified)
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
