import Foundation

struct CLIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Parsing is independent of audio and storage: invalid input cannot start a session.
struct CLIArguments: Equatable {
    enum Command: String { case interactive, topics, recordings, show, listen, paths, help }
    var command = Command.interactive
    var topic: String?
    var recording: String?
    var json = false
    var demo = false
    var duration: Double?

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var result = CLIArguments()
        var index = 0
        var positional: [String] = []
        var seen = Set<String>()
        while index < arguments.count {
            let word = arguments[index]
            if word == "-cli" { index += 1; continue }
            if word == "--help" || word == "-h" { result.command = .help; return result }
            if word.hasPrefix("-") {
                guard seen.insert(word).inserted else { throw CLIError(message: "Option repeated: \(word)") }
                switch word {
                case "--json": result.json = true
                case "--demo": result.demo = true
                #if DEBUG
                case "-audioFile":
                    index += 1
                    guard index < arguments.count, FileManager.default.isReadableFile(atPath: arguments[index]) else {
                        throw CLIError(message: "The explicitly selected evaluation audio file cannot be read.")
                    }
                #endif
                case "--topic", "--duration":
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("-") else { throw CLIError(message: "Missing value for \(word).") }
                    if word == "--topic" { result.topic = arguments[index] }
                    else {
                        guard let seconds = Double(arguments[index]), seconds.isFinite, seconds > 0, seconds <= 86_400 else {
                            throw CLIError(message: "Duration must be a number from greater than zero to 86400 seconds.")
                        }
                        result.duration = seconds
                    }
                default: throw CLIError(message: "Unknown option: \(word). Use listen -cli --help.")
                }
            } else { positional.append(word) }
            index += 1
        }
        if let first = positional.first {
            guard let command = Command(rawValue: first) else { throw CLIError(message: "Unknown command: \(first).") }
            result.command = command
            positional.removeFirst()
        }
        if result.command == .show {
            guard positional.count == 1 else { throw CLIError(message: "Use: listen -cli show <recording-id>.") }
            result.recording = positional.removeFirst()
        }
        guard positional.isEmpty else { throw CLIError(message: "Unexpected argument: \(positional[0]).") }
        guard result.duration == nil || result.command == .listen else { throw CLIError(message: "--duration is available with the listen command.") }
        guard !result.demo || [.listen, .interactive].contains(result.command) else { throw CLIError(message: "--demo is available with listen or interactive.") }
        guard result.topic == nil || [.listen, .interactive, .recordings].contains(result.command) else { throw CLIError(message: "--topic is available with listen, interactive or recordings.") }
        return result
    }

    static let help = """
    Usage: listen -gui
           listen -cli [command] [options]

    No command: interactive terminal. Audio starts only after 'start'.
    topics                         List the app's topics and their IDs
    recordings [--topic <id/name>] List the app's recordings
    show <recording-id>             Read a recording's transcript and cards (no inference)
    listen [--topic <id/name>]      Start a microphone conversation in that topic
    paths                          Show the shared topic, system and recording paths
    --json                         Emit newline-delimited JSON (diagnostics use stderr)
    --duration <seconds>            Stop the listen command after this many seconds
    --demo                         Fixed demo events; no microphone, models or saved run

    Interactive: topics, recordings, show <id>, start [topic-id/name], pause, resume,
    say <request> (voice topics), allow <pending-operation-id>, deny <pending-operation-id>,
                 ask, me <voice-number>, status, stop, help, quit
    Cards:       shorter <id>, explain <id>, deeper <id>, dismiss <id>
    Ctrl-C / Ctrl-D stop cleanly and save permitted recordings and topic notes.
    CLI microphone input is local; selected cloud models use the same configured accounts.
    """
}

@MainActor enum CLICatalog {
    static func topic(_ selector: String?, in store: TopicStore) throws -> Topic {
        guard let selector else { return store.selected }
        if let id = UUID(uuidString: selector), let topic = store.topics.first(where: { $0.id == id }) { return topic }
        let named = store.topics.filter { $0.name == selector }
        guard named.count == 1 else {
            throw CLIError(message: named.isEmpty ? "No topic matches that ID or exact name." : "More than one topic has that name. Use its UUID.")
        }
        return named[0]
    }

    static func recording(_ selector: String, among runs: [URL]) throws -> URL {
        let found = runs.filter { $0.lastPathComponent == selector || $0.standardizedFileURL.path == selector }
        guard found.count == 1 else { throw CLIError(message: "No unique recording matches that ID. Use a path listed by recordings.") }
        return found[0]
    }
}
