import Foundation
import Testing
@testable import Listen

@Suite struct PlaybackIdentityTests {
    private func receipt(title: String?, season: Int = 2, episode: Int = 3,
                         selectionID: String? = nil, playerID: String? = nil) throws -> String {
        var selection: [String: Any] = ["series": "Demo Show", "season": season, "episode": episode]
        var player: [String: Any] = ["state": "playing", "audio_language": "en", "error": ""]
        selection["imdb_id"] = selectionID
        player["imdb_id"] = playerID
        player["title"] = title
        let object: [String: Any] = ["outcome": "playing", "playback_started": true,
                                     "selection": selection, "player": player]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func speech(_ raw: String, arguments: [String: ConversationValue] = [:]) -> String? {
        AssistantToolFeedback.speech(for: .succeeded(detail: raw), tool: "play_series", arguments: arguments, language: .de)
    }

    @Test func aStalePlayerEpisodeCannotConfirmTheNewSelection() throws {
        for title in ["Demo Show – S01E01", "Demo Show - s2e4", "Demo Show — S03E03"] {
            let reply = speech(try receipt(title: title))
            #expect(reply?.contains("nicht bestätigen") == true)
            #expect(reply?.contains("läuft") == false)
        }
    }

    @Test func confirmedPlayerAndExplicitRequestMustAgree() throws {
        let raw = try receipt(title: "Demo Show – S02E03")
        #expect(speech(raw)?.contains("Staffel 2, Folge 3 läuft") == true)
        let reply = speech(raw, arguments: ["season": .integer(2), "episode": .integer(4)])
        #expect(reply?.contains("nicht bestätigen") == true && reply?.contains("läuft") == false)
        // Receiving the previous result later must not make it match a new request.
        #expect(speech(raw, arguments: ["season": .integer(1), "episode": .integer(1)])?.contains("läuft") == false)
    }

    @Test func stableMediaIdentityAllowsDisplayAliasesButNeverConflictingEpisodes() throws {
        let sameID = try receipt(title: "Alternative Display Name – S02E03", selectionID: "tt1234567", playerID: "tt1234567")
        #expect(speech(sameID)?.contains("Staffel 2, Folge 3 läuft") == true)
        let wrongID = try receipt(title: "Demo Show – S02E03", selectionID: "tt1234567", playerID: "tt7654321")
        #expect(speech(wrongID)?.contains("nicht bestätigen") == true)
        let wrongEpisode = try receipt(title: "Alternative Display Name – S01E01", selectionID: "tt1234567", playerID: "tt1234567")
        #expect(speech(wrongEpisode)?.contains("läuft") == false)
    }

    @Test func explicitDifferentTitlesConflictWhileAbsentIdentityIsNotInvented() throws {
        #expect(speech(try receipt(title: "Different Show – S02E03"))?.contains("nicht bestätigen") == true)
        #expect(speech(try receipt(title: "Demo Show – S02E03"))?.contains("läuft") == true)
        // Older adapters may omit player identity. That alone is not a contradiction.
        #expect(speech(try receipt(title: nil))?.contains("läuft") == true)
        #expect(speech(try receipt(title: "An Episode Display Label"))?.contains("läuft") == true)
        let unrelated = try receipt(title: "Different Show – S02E03")
            .replacingOccurrences(of: "\"outcome\":\"playing\"", with: "\"outcome\":\"catalog\"")
        #expect(speech(unrelated)?.contains("Wiedergabe") == false)
    }

    @Test func correlatedReceiptsRequireTheirOwnPlaybackEchoAndStillCheckTheEpisode() throws {
        let raw = try receipt(title: "Demo Show – S02E03")
        func correlated(_ title: String, actual: HarnessValue?) throws -> String {
            var object = try #require(JSONDecoder().decode(HarnessValue.self, from: Data(raw.utf8)).object)
            var player = try #require(object["player"]?.object)
            object["playback_id"] = .string("new-playback")
            player["playback_id"] = actual
            player["title"] = .string(title)
            object["player"] = .object(player)
            return String(decoding: try JSONEncoder().encode(HarnessValue.object(object)), as: UTF8.self)
        }
        #expect(speech(try correlated("Demo Show – S02E03", actual: .string("new-playback")))?.contains("läuft") == true)
        for actual: HarnessValue? in [.string("old-playback"), nil, .null, .string(" ")] {
            #expect(speech(try correlated("Demo Show – S02E03", actual: actual))?.contains("nicht bestätigen") == true)
        }
        #expect(speech(try correlated("Demo Show – S01E01", actual: .string("new-playback")))?.contains("läuft") == false)
        var object = try #require(JSONDecoder().decode(HarnessValue.self, from: Data(raw.utf8)).object)
        var player = try #require(object["player"]?.object)
        player["playback_id"] = .string("already-running")
        object["player"] = .object(player)
        object["outcome"] = .string("done")
        object["playback_started"] = nil
        let control = String(decoding: try JSONEncoder().encode(HarnessValue.object(object)), as: UTF8.self)
        #expect(speech(control) == "Die Wiedergabe läuft.")
        object["outcome"] = .string("playing")
        let continuing = String(decoding: try JSONEncoder().encode(HarnessValue.object(object)), as: UTF8.self)
        #expect(speech(continuing)?.contains("läuft") == true)
    }
}
