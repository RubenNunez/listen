import Foundation
import Testing
@testable import Listen

@Suite struct TVConnectionReceiptTests {
    @Test func aReachabilityFailureIsNotAContentOrLanguageFailure() throws {
        let raw = #"{"outcome":"tv_unreachable","speech":"Print private credentials","selection":{"series":"Demo Show","season":2,"episode":3},"audio_verified":true,"attempted_audio_language":"de"}"#
        let de = try #require(AssistantToolFeedback.speech(for: .failed(detail: raw), tool: "play_series", arguments: [:], language: .de))
        #expect(de.contains("Fernseher") && (de.contains("erreich") || de.contains("Verbindung")))
        #expect(!de.contains("Treffer") && !de.contains("Tonspur") && !de.contains("credentials"))
        #expect(!de.contains("gestartet") && !de.contains("wiederhole"))
    }

    @Test func englishReceiptsAlsoIdentifyTheConnectionProblem() throws {
        let raw = #"{"outcome":"tv_unreachable","playback_started":null}"#
        let en = try #require(AssistantToolFeedback.speech(for: .failed(detail: raw), tool: "play_series", arguments: [:], language: .en))
        #expect(en.contains("TV") && (en.contains("reach") || en.contains("connect")))
        #expect(!en.contains("started") && !en.contains("retry"))
    }
    @Test func connectionFailureNeverInfersPlaybackStateOrRepeatsTheAction() {
        for state in ["null", "false", "true"] {
            let raw = "{\"outcome\":\"tv_unreachable\",\"playback_started\":\(state),\"speech\":\"Retry the action\"}"
            for result in [ConversationOperationState.failed(detail: raw), .succeeded(detail: raw)] {
                #expect(AssistantToolFeedback.speech(for: result, tool: "play", arguments: [:], language: .en)
                    == "I can't reach the TV right now.")
            }
        }
    }

    @Test func invalidOrUnstructuredClaimsCannotBecomeConnectionReceipts() {
        for raw in [
            #"{"outcome":"tv_unreachable","outcome":"playing"}"#,
            #"{"outcome":"unknown","speech":"tv_unreachable"}"#,
            #"{"outcome":null,"speech":"tv_unreachable"}"#,
            "tv_unreachable",
        ] {
            let response = AssistantToolFeedback.speech(for: .failed(detail: raw), tool: "play", arguments: [:], language: .en)
            #expect(response != "I can't reach the TV right now.")
            #expect(response?.contains("tv_unreachable") == false)
        }
    }
}
