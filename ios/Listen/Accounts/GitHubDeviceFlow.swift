import Foundation

/// GitHub's OAuth device flow: the app shows a code, the user confirms it on
/// github.com, the app receives a token. No password ever touches the app.
///
/// Needs the client ID of a GitHub App (with device flow enabled) that the
/// owner registers; none is built in. Not exercised against GitHub yet: this
/// follows GitHub's documented endpoints but has never completed a sign-in.
struct GitHubDeviceFlow {
    struct Code: Decodable, Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int

        private enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    enum Failure: Error, Equatable {
        case refused(String)
        case expired
        case network

        var message: String {
            switch self {
            case .refused(let reason): "GitHub refused: \(reason)."
            case .expired: "The code expired. Start again."
            case .network: "No connection to GitHub."
            }
        }
    }

    let clientID: String

    private func post(_ path: String, _ fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://github.com/login/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        do {
            return try await URLSession.shared.data(for: request).0
        } catch {
            throw Failure.network
        }
    }

    func requestCode() async throws -> Code {
        let data = try await post("device/code", ["client_id": clientID])
        if let code = try? JSONDecoder().decode(Code.self, from: data) { return code }
        throw Failure.refused(Self.errorName(in: data) ?? "unexpected answer")
    }

    /// Waits until the user has confirmed the code, then returns the token.
    func waitForToken(_ code: Code) async throws -> String {
        var interval = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let data = try await post("oauth/access_token", [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = Self.field("access_token", in: data) { return token }
            switch Self.errorName(in: data) {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw Failure.expired
            case let other: throw Failure.refused(other ?? "unexpected answer")
            }
        }
        throw Failure.expired
    }

    static func field(_ name: String, in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[name] as? String
    }

    static func errorName(in data: Data) -> String? { field("error", in: data) }
}
