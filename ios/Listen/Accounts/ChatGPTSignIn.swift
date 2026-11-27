import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security

/// OpenAI's "Sign in with ChatGPT" with ChatGPT plan usage, for locally run
/// apps: the user signs in at auth.openai.com in the browser and allows this
/// app to use their Plus or Pro plan for model requests. The app never sees a
/// password; it receives tokens that only work for the Responses API.
///
/// Follows https://developers.openai.com/siwc/token-sharing-open-source
/// (read on 15 November 2026): dynamic registration with
/// `client_id=dynamic_agent_client`, PKCE, a loopback callback on 127.0.0.1,
/// and no client secret.
///
/// Built from the documentation and unit-tested in its parts. Not completed
/// against OpenAI yet: that needs the account's owner in the browser.
enum ChatGPT {
    static let issuer = "https://auth.openai.com"
    static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revoke = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let keys = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let usage = URL(string: "https://chatgpt.com/settings/usage")!
    /// The name the user sees when they approve the app.
    static let appName = "Listen"

    /// What is kept on this device for the signed-in account, as one secret.
    struct Credentials: Codable, Equatable {
        var clientID: String
        var subject: String
        var email: String?
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var scopes: [String]
        var expires: Date
        /// The model the user chose for Listen, as "slug".
        var model: String?

        var allowsPlan: Bool { scopes.contains(ChatGPT.planScope) }

        static func load() -> Credentials? {
            guard let text = Keychain.get(Connector.chatGPT.rawValue), let data = text.data(using: .utf8) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Credentials.self, from: data)
        }

        func save() throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try Keychain.set(String(decoding: encoder.encode(self), as: UTF8.self), for: Connector.chatGPT.rawValue)
        }
    }

    /// What stays after signing out, so the next sign-in reuses the app's
    /// registration for this account instead of creating a new one.
    struct Registration: Codable, Equatable {
        var clientID: String
        var subject: String
        var idToken: String

        static let account = "chatGPT-registration"

        static func load() -> Registration? {
            Keychain.get(account).flatMap { try? JSONDecoder().decode(Registration.self, from: Data($0.utf8)) }
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? Keychain.set(String(decoding: data, as: UTF8.self), for: Self.account)
        }
    }

    /// This installation, as OpenAI wants it named: opaque, stable, not a credential.
    static var hostID: String {
        let key = "chatGPTHostID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let fresh = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    enum Failure: Error, Equatable {
        case noListener
        case noPage
        case denied
        case stateMismatch
        case noClientID
        case network
        case refused(Int, String)
        case badToken(String)
        case planNotGranted
        case signedOut

        var message: String {
            switch self {
            case .noListener: "Could not wait for the browser on this device."
            case .noPage: "The sign-in page could not be shown."
            case .denied: "The sign-in was cancelled in the browser."
            case .stateMismatch: "The answer did not belong to this sign-in. Start again."
            case .noClientID: "OpenAI did not register this app. Start again."
            case .network: "No connection to OpenAI."
            case .refused(let status, let code): "OpenAI did not accept it (HTTP \(status)\(code.isEmpty ? "" : ", \(code)"))."
            case .badToken(let why): "The identity OpenAI sent could not be verified (\(why))."
            case .planNotGranted: "Signed in, but use of the ChatGPT plan was not allowed. Sign in again and allow it, or use an API key."
            case .signedOut: "The ChatGPT sign-in has expired. Sign in again in Account."
            }
        }
    }

    // MARK: Small pieces, testable on their own

    static func random(_ count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return OpenRouterSignIn.base64URL(Data(bytes))
    }

    static func data(base64URL text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    /// The page to open in the browser. `saved` is the account signed in before, if any.
    static func authorizationURL(
        callback: URL, state: String, nonce: String, verifier: String, hostID: String, saved: Registration?
    ) -> URL {
        var items = [
            URLQueryItem(name: "client_id", value: saved?.clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: callback.absoluteString),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: OpenRouterSignIn.challenge(for: verifier)),
        ]
        if let saved {
            items.append(URLQueryItem(name: "id_token_hint", value: saved.idToken))
        } else {
            // Only on first registration, as the documentation asks.
            items.append(URLQueryItem(name: "agent_name_hint", value: appName))
        }
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // A "+" must not arrive as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The query of the browser's request to the loopback listener.
    static func callbackValues(inRequest request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix("/auth/callback"),
            let components = URLComponents(string: "http://127.0.0.1" + parts[1])
        else { return [:] }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        return values
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    // MARK: ID token

    struct Identity: Equatable {
        var subject: String
        var email: String?
    }

    /// Checks an ID token as the documentation requires: RS256 signature
    /// against one of OpenAI's published keys, issuer, audience, expiry, nonce.
    /// `keys` is the JSON of the JWKS document.
    static func verify(idToken: String, keys: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> Identity {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = data(base64URL: parts[0]), let payloadData = data(base64URL: parts[1]),
            let signature = data(base64URL: parts[2]),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw Failure.badToken("not a token") }
        guard header["alg"] as? String == "RS256", let kid = header["kid"] as? String else { throw Failure.badToken("algorithm") }
        let set = (try? JSONSerialization.jsonObject(with: keys) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
        guard let jwk = set.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
            let n = (jwk["n"] as? String).flatMap(data(base64URL:)), let e = (jwk["e"] as? String).flatMap(data(base64URL:)),
            let key = SecKeyCreateWithData(
                rsaPublicKey(modulus: n, exponent: e) as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)
        else { throw Failure.badToken("unknown key") }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw Failure.badToken("signature")
        }
        guard payload["iss"] as? String == issuer else { throw Failure.badToken("issuer") }
        let audience = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID) else { throw Failure.badToken("audience") }
        guard let expires = payload["exp"] as? Double, Date(timeIntervalSince1970: expires) > now.addingTimeInterval(-60) else {
            throw Failure.badToken("expired")
        }
        if let nonce { guard payload["nonce"] as? String == nonce else { throw Failure.badToken("nonce") } }
        guard let subject = payload["sub"] as? String, !subject.isEmpty else { throw Failure.badToken("subject") }
        return Identity(subject: subject, email: payload["email"] as? String)
    }

    /// A PKCS#1 RSAPublicKey (DER) from a key's modulus and exponent, which is
    /// the form the system's crypto wants.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        func length(_ count: Int) -> [UInt8] {
            if count < 128 { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var rest = count
            while rest > 0 {
                bytes.insert(UInt8(rest & 0xff), at: 0)
                rest >>= 8
            }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ data: Data) -> [UInt8] {
            var bytes = Array(data.drop { $0 == 0 })
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30] + length(body.count) + body)
    }

    // MARK: Token endpoint

    /// Credentials from a token response. `previous` supplies what a refresh does not send again.
    static func credentials(
        fromTokenResponse data: Data, clientID: String, identity: Identity?, previous: Credentials?, now: Date = Date()
    ) -> Credentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else { return nil }
        guard let refresh = json["refresh_token"] as? String ?? previous?.refreshToken,
            let idToken = json["id_token"] as? String ?? previous?.idToken,
            let subject = identity?.subject ?? previous?.subject
        else { return nil }
        let scopes = (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        return Credentials(
            clientID: clientID, subject: subject, email: identity?.email ?? previous?.email, idToken: idToken,
            accessToken: access, refreshToken: refresh, scopes: scopes,
            expires: now.addingTimeInterval((json["expires_in"] as? Double) ?? 3600), model: previous?.model)
    }

    static func post(_ url: URL, _ fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["code"] as? String ?? ""
            throw Failure.refused(status, code)
        }
        return data
    }

    /// Where the plan models that draft next to the chosen one are kept (their slugs; not a secret).
    static let alsoAskedKey = "chatgptAlsoAsked"

    /// The models the signed-in account may use, in the server's order.
    static func models(accessToken: String) async throws -> [(slug: String, name: String)] {
        var request = URLRequest(url: URL(string: resource + "/models")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw Failure.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(status, "") }
        return models(in: data)
    }

    static func models(in data: Data) -> [(slug: String, name: String)] {
        let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return list.compactMap { model in
            guard model["visibility"] as? String == "list", let slug = model["slug"] as? String else { return nil }
            return (slug, model["display_name"] as? String ?? slug)
        }
    }
}

/// The sign-in page shown inside the app, as on the iPhone: there the app must
/// stay in front, because iOS suspends it behind Safari and the listener dies.
struct ChatGPTPage {
    enum End { case user, failed }

    /// Shows the page and returns how to close it from code, or nil when it
    /// could not be shown. `ended` is called when it closes any other way.
    var open: @MainActor (URL, _ ended: @escaping @MainActor (End) -> Void) -> (@MainActor () -> Void)?

    /// The system's sign-in sheet, sharing Safari's cookies so that a ChatGPT
    /// login there is reused. The redirect is plain http on 127.0.0.1, which
    /// the sheet does not report: the listener receives it and closes the sheet.
    static func system(ephemeral: Bool = false) -> ChatGPTPage {
        ChatGPTPage { url, ended in
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
            let anchor = PageAnchor(window: window)
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("listen-unused")) { _, error in
                let byUser = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                Task { @MainActor in ended(byUser ? .user : .failed) }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = ephemeral
            guard session.start() else { return nil }
            // The session does not keep its anchor alive; this closure does.
            return { _ = anchor; session.cancel() }
        }
    }

    private final class PageAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        let window: UIWindow
        init(window: UIWindow) { self.window = window }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
    }
}

/// One sign-in attempt: fresh state, nonce and PKCE verifier, and a listener
/// on 127.0.0.1 that exists only while the browser is open.
@MainActor
final class ChatGPTSignIn {
    private let state = ChatGPT.random()
    private let nonce = ChatGPT.random()
    private let verifier = ChatGPT.random(48)
    private var listener: NWListener?
    private var pageFailed = false

    /// What the browser brought back, checked against this attempt.
    struct Answer: Equatable {
        var code: String
        var clientID: String
        var callback: URL
    }

    /// Opens the listener, lets `open` show the page, waits for the browser to
    /// come back and returns the verified, saved credentials. With `page`, the
    /// page is also shown inside the app.
    func run(page: ChatGPTPage? = nil, open: (URL) -> Void) async throws -> ChatGPT.Credentials {
        let saved = ChatGPT.Registration.load()
        let earlier = ChatGPT.Credentials.load()
        let answer = try await authorize(saved: saved, page: page, open: open)
        let (clientID, callback) = (answer.clientID, answer.callback)
        let response = try await ChatGPT.post(ChatGPT.token, [
            "grant_type": "authorization_code", "client_id": clientID, "code": answer.code, "code_verifier": verifier,
            "redirect_uri": callback.absoluteString, "resource": ChatGPT.resource,
        ])
        guard let idToken = (try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["id_token"] as? String else {
            throw ChatGPT.Failure.badToken("missing")
        }
        guard let (keys, _) = try? await URLSession.shared.data(from: ChatGPT.keys) else { throw ChatGPT.Failure.network }
        let identity = try ChatGPT.verify(idToken: idToken, keys: keys, clientID: clientID, nonce: nonce)
        // A returning sign-in must be the same person as before.
        let previous = earlier?.subject == identity.subject && earlier?.clientID == clientID ? earlier : nil
        ChatGPT.Registration(clientID: clientID, subject: identity.subject, idToken: idToken).save()
        guard var credentials = ChatGPT.credentials(
            fromTokenResponse: response, clientID: clientID, identity: identity, previous: previous)
        else { throw ChatGPT.Failure.badToken("incomplete") }
        guard credentials.allowsPlan else {
            try? credentials.save()
            throw ChatGPT.Failure.planNotGranted
        }
        if credentials.model == nil {
            credentials.model = try? await ChatGPT.models(accessToken: credentials.accessToken).first?.slug
        }
        try credentials.save()
        return credentials
    }

    /// The part before OpenAI's token endpoint: listener, page, the browser's
    /// answer. The listener is stopped and the in-app page closed on every way out.
    func authorize(saved: ChatGPT.Registration?, page: ChatGPTPage?, open: (URL) -> Void) async throws -> Answer {
        let (callback, answer) = try await listen()
        var close: (@MainActor () -> Void)?
        defer {
            close?()
            stop()
        }
        let url = ChatGPT.authorizationURL(
            callback: callback, state: state, nonce: nonce, verifier: verifier, hostID: ChatGPT.hostID, saved: saved)
        open(url)
        if let page {
            guard let dismiss = page.open(url, { [weak self] end in
                // Closing the page from code may report here too; by then the answer is in.
                self?.pageFailed = end == .failed
                answer.cancel()
            }) else {
                answer.cancel()
                throw ChatGPT.Failure.noPage
            }
            close = dismiss
        }
        let values = await withTaskCancellationHandler { await answer.value } onCancel: { answer.cancel() }
        // The user closing the page is not an error.
        guard let values else { throw pageFailed ? ChatGPT.Failure.noPage : CancellationError() }
        guard values["state"] == state else { throw ChatGPT.Failure.stateMismatch }
        if values["error"] != nil { throw ChatGPT.Failure.denied }
        guard let code = values["code"] else { throw ChatGPT.Failure.denied }
        // A new registration brings the issued client ID; a returning one may leave it out.
        guard let clientID = values["client_id"] ?? saved?.clientID, clientID != "dynamic_agent_client" else {
            throw ChatGPT.Failure.noClientID
        }
        return Answer(code: code, clientID: clientID, callback: callback)
    }

    var isListening: Bool { listener != nil }

    private func listen() async throws -> (callback: URL, answer: Task<[String: String]?, Never>) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { throw ChatGPT.Failure.noListener }
        self.listener = listener
        let (answers, answerContinuation) = AsyncStream<[String: String]>.makeStream()
        let (ports, portContinuation) = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: portContinuation.yield(listener.port?.rawValue)
            case .failed, .cancelled:
                portContinuation.yield(nil)
                answerContinuation.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let values = ChatGPT.callbackValues(inRequest: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                let body = values["code"] != nil
                    ? "<h3>Signed in.</h3><p>You can go back to Listen.</p>"
                    : "<h3>Not signed in.</h3><p>Go back to Listen and try again.</p>"
                let page = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                    + "<body style='font:17px -apple-system;margin:15vh 8vw'>" + body
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                // Other requests (a favicon) are not the answer.
                if !values.isEmpty { answerContinuation.yield(values) }
            }
        }
        listener.start(queue: .main)
        var port: UInt16?
        for await value in ports {
            port = value
            break
        }
        // 127.0.0.1, not localhost, and always this path: the documentation requires both.
        guard let port, let callback = URL(string: "http://127.0.0.1:\(port)/auth/callback") else {
            stop()
            throw ChatGPT.Failure.noListener
        }
        let answer = Task { () -> [String: String]? in
            for await values in answers { return values }
            return nil
        }
        return (callback, answer)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// The signed-in session: hands out a valid access token and renews it. An
/// actor, so two requests never renew at once (the refresh token rotates).
actor ChatGPTSession {
    static let shared = ChatGPTSession()

    func accessToken() async throws -> String {
        guard let credentials = ChatGPT.Credentials.load(), credentials.allowsPlan else { throw ChatGPT.Failure.signedOut }
        if credentials.expires.timeIntervalSinceNow > 120 { return credentials.accessToken }
        do {
            let response = try await ChatGPT.post(ChatGPT.token, [
                "grant_type": "refresh_token", "client_id": credentials.clientID,
                "refresh_token": credentials.refreshToken, "resource": ChatGPT.resource,
            ])
            guard let renewed = ChatGPT.credentials(
                fromTokenResponse: response, clientID: credentials.clientID, identity: nil, previous: credentials)
            else { throw ChatGPT.Failure.badToken("incomplete") }
            try renewed.save()
            return renewed.accessToken
        } catch ChatGPT.Failure.refused(let status, let code) where status == 400 || status == 401 {
            // The refresh token is no longer usable: the user has to sign in again.
            _ = code
            throw ChatGPT.Failure.signedOut
        }
    }

    /// Ends the session at OpenAI, then forgets the tokens here. Returns
    /// whether OpenAI confirmed the revocation.
    func signOut() async -> Bool {
        guard let credentials = ChatGPT.Credentials.load() else { return true }
        let confirmed = (try? await ChatGPT.post(ChatGPT.revoke, [
            "token": credentials.refreshToken, "token_type_hint": "refresh_token", "client_id": credentials.clientID,
        ])) != nil
        Keychain.remove(Connector.chatGPT.rawValue)
        return confirmed
    }
}
