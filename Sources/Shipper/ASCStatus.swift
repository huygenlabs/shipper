import CryptoKit
import Foundation
import UserNotifications

enum ASCStatus {
    enum ResultState {
        case processing
        case valid
        case failed(String)
    }

    private struct Response: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                var version: String?
                var processingState: String?
            }
            struct Relationships: Decodable {
                struct DataRef: Decodable { var id: String? }
                var preReleaseVersion: Relation?
                struct Relation: Decodable { var data: DataRef? }
            }
            var id: String
            var type: String
            var attributes: Attributes?
            var relationships: Relationships?
        }
        struct Included: Decodable {
            struct Attributes: Decodable { var version: String? }
            var id: String
            var type: String
            var attributes: Attributes?
        }
        var data: [Resource]
        var included: [Included]?
    }

    static func validPrivateKey(_ pem: String) -> Bool {
        (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
    }

    static func check(info: PackageInfo?, keyID: String, issuerID: String, privateKey: String) async -> ResultState? {
        guard let info, let token = token(keyID: keyID, issuerID: issuerID, privateKey: privateKey),
              let appID = await appID(for: info.bundleID, token: token),
              let response = await builds(appID: appID, token: token) else { return nil }
        let versions = Dictionary(uniqueKeysWithValues: (response.included ?? []).filter { $0.type == "preReleaseVersions" }.map { ($0.id, $0.attributes?.version ?? "") })
        let build = response.data.first { resource in
            guard resource.attributes?.version == info.build else { return false }
            guard let relationID = resource.relationships?.preReleaseVersion?.data?.id else { return true }
            return versions[relationID] == info.version
        }
        guard let state = build?.attributes?.processingState?.uppercased() else { return nil }
        switch state {
        case "PROCESSING": return .processing
        case "VALID": return .valid
        case "FAILED", "INVALID": return .failed("Apple could not process this build (\(state)). Open the build in App Store Connect for details.")
        default: return nil
        }
    }

    private static func appID(for bundleID: String, token: String) async -> String? {
        await get("/v1/apps", query: [URLQueryItem(name: "filter[bundleId]", value: bundleID), URLQueryItem(name: "limit", value: "1")], token: token)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .flatMap { $0["data"] as? [[String: Any]] }
            .flatMap { $0.first?["id"] as? String }
    }

    private static func builds(appID: String, token: String) async -> Response? {
        guard let data = await get("/v1/apps/\(appID)/builds", query: [
            URLQueryItem(name: "include", value: "preReleaseVersion"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
        ], token: token) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    private static func get(_ path: String, query: [URLQueryItem], token: String) async -> Data? {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func token(keyID: String, issuerID: String, privateKey: String) -> String? {
        let header = "{\"alg\":\"ES256\",\"kid\":\"\(keyID)\",\"typ\":\"JWT\"}"
        let now = Int(Date().timeIntervalSince1970)
        let payload = "{\"iss\":\"\(issuerID)\",\"iat\":\(now),\"exp\":\(now + 15 * 60),\"aud\":\"appstoreconnect-v1\"}"
        let unsigned = "\(base64URL(Data(header.utf8))).\(base64URL(Data(payload.utf8)))"
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: privateKey),
              let signature = try? key.signature(for: Data(unsigned.utf8)) else { return nil }
        return "\(unsigned).\(base64URL(signature.rawRepresentation))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor static func failure(_ job: Job, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Build delivery failed"
        content.subtitle = job.name
        content.body = message.replacingOccurrences(of: job.target.appleID, with: "<Apple Account>")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "shipper-\(job.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
