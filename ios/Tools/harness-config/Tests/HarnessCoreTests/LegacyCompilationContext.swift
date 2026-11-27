// SystemConfig's actual source is linked beside this file. Its decoder and
// defaults are tested unchanged. These names only satisfy filled(_:language:)'s
// compile-time dependencies; they do not run or simulate an answer engine.
enum Language { case de, en }
enum AnswerEngine {
    static let nothing = "NO_ANSWER"
    static let update = "UPDATE"
}
