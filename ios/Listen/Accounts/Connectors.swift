import Foundation
import Observation

/// A service the user can attach with their own account.
enum Connector: String, CaseIterable, Identifiable {
    case openRouter, claude, openAI, gemini, deepSeek, chatGPT, jev, elevenLabs, gitHub

    enum Group: String, CaseIterable {
        case intelligence = "Intelligence"
        case decisions = "Decision making · optional"
        case voice = "Voice · experimental"
        case context = "Context"
    }

    enum Access: Equatable {
        case apiKey
        /// OAuth in the browser: the user signs in on the provider's site.
        case signIn
        /// OAuth device flow: the user confirms a code on the provider's site.
        case deviceCode
        /// Named so the user sees why it is missing; nothing is faked.
        case unavailable(String)
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        case .chatGPT: "ChatGPT"
        case .jev: "Jev (TypeSafe)"
        case .elevenLabs: "ElevenLabs"
        case .gitHub: "GitHub"
        }
    }

    var group: Group {
        switch self {
        case .jev: .decisions
        case .elevenLabs: .voice
        case .gitHub: .context
        default: .intelligence
        }
    }

    var access: Access {
        switch self {
        case .gitHub: .deviceCode
        case .openRouter, .chatGPT: .signIn
        default: .apiKey
        }
    }

    var detail: String {
        switch self {
        case .openRouter: "Sign in · one account for Claude, GPT, Gemini and DeepSeek, paid from your OpenRouter credit"
        case .claude: "API key. Anthropic offers no sign-in with a Claude plan for other apps."
        case .openAI, .gemini, .deepSeek: "API key"
        case .chatGPT: "Sign in · uses your ChatGPT Plus or Pro plan, no API key"
        case .jev: "Optional structured decisions · TypeSafe API key"
        case .elevenLabs: "API key · audio would leave the device"
        case .gitHub: "Sign in with a code · read access to repositories you choose"
        }
    }

    /// Checks account access without running model inference.
    func check(with key: String) -> URLRequest? {
        var request: URLRequest
        switch self {
        case .openRouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .deepSeek:
            request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .jev:
            // Account access only; never send a conversation as a key check.
            request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .elevenLabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .gitHub:
            request = URLRequest(url: URL(string: "https://api.github.com/user")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        case .chatGPT:
            return nil
        }
        request.timeoutInterval = 15
        return request
    }
}

/// Which connectors are attached, and who the user is. Secrets stay in the
/// Keychain; this object only knows whether one exists.
@MainActor
@Observable
final class AccountStore {
    enum Status: Equatable {
        case notConnected
        case connected
        case checking
        case accepted
        case rejected(String)
        case unchecked(String)

        var isConnected: Bool {
            switch self {
            case .notConnected, .rejected: false
            default: true
            }
        }
    }

    var name: String { didSet { UserDefaults.standard.set(name, forKey: "accountName") } }
    private(set) var status: [Connector: Status] = [:]

    init() {
        name = UserDefaults.standard.string(forKey: "accountName") ?? ""
        for connector in Connector.allCases {
            status[connector] = Keychain.get(connector.rawValue) == nil ? .notConnected : .connected
        }
    }

    /// Connectors that can answer questions and have a key.
    var attachedModels: [Connector] {
        Connector.allCases.filter { $0.group == .intelligence && status[$0]?.isConnected == true }
    }

    /// Stores the secret, then asks the provider whether it is valid.
    func connect(_ connector: Connector, secret: String) async {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        do {
            try Keychain.set(secret, for: connector.rawValue)
        } catch let failure as Keychain.Failure {
            status[connector] = .rejected("Could not be saved. \(failure.message).")
            return
        } catch {
            status[connector] = .rejected("Could not be saved.")
            return
        }
        await check(connector)
    }

    func check(_ connector: Connector) async {
        guard let secret = Keychain.get(connector.rawValue), let request = connector.check(with: secret) else { return }
        status[connector] = .checking
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: status[connector] = .accepted
            case 401, 403: status[connector] = .rejected("\(connector.title) did not accept it (HTTP \(code)).")
            default: status[connector] = .unchecked("Saved. \(connector.title) answered HTTP \(code).")
            }
        } catch {
            status[connector] = .unchecked("Saved, not checked: no connection.")
        }
    }

    /// After a sign-in that stored its own secret: look again.
    func refresh(_ connector: Connector) {
        status[connector] = Keychain.get(connector.rawValue) == nil ? .notConnected : .connected
    }

    func disconnect(_ connector: Connector) {
        Keychain.remove(connector.rawValue)
        status[connector] = .notConnected
    }
}
