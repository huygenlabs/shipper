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
