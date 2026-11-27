import Foundation
import Testing
@testable import Listen

@Suite struct ForecastPool {
    @Test func cardsAreReadOneJSONObjectPerLine() {
        let reply = """
            Here are the cards:
            {"title": "**Pyannote Sprecherzahl**", "bullets": ["num_speakers legt die Zahl fest.", "min/max_speakers geben Grenzen."], "keywords": "pyannote sprecher anzahl"}
            not json
            {"title": "", "bullets": ["no title"]}
            {"title": "Teams Recap", "bullets": ["a", "b", "c", "d"], "keywords": "teams zusammenfassung"}
            """
        let hints = Forecast.hints(in: reply, language: .de, first: 5)
        #expect(hints.map(\.id) == ["f5", "f6"])
        #expect(hints.first?.title == "Pyannote Sprecherzahl")
        #expect(hints.last?.bullets.count == 3, "at most three bullets")
        #expect(hints.allSatisfy { $0.isValid && $0.urls.isEmpty })
    }

    @Test func aNewForecastComesFirstAndReplacesTheSameSubject() {
        func hint(_ id: String, _ title: String) -> MaterialIndex.PreparedHint {
            .init(id: id, title: title, bullets: ["A fact."], sources: ["forecast"], keywords: "", language: "de")
        }
        let pool = [hint("f0", "Alpha"), hint("f1", "Beta"), hint("f2", "Gamma")]
        let merged = Forecast.merge([hint("f3", "beta"), hint("f4", "Delta")], into: pool, size: 4)
        #expect(merged.map(\.id) == ["f3", "f4", "f0", "f2"])
    }

    @Test func generatedCandidatesNeedAnAnchorFromSpeechInsteadOfTheBriefing() {
        let reply = """
        {"anchor":"Pyannote", "title":"Speaker count", "bullets":["Set num_speakers."], "keywords":"speaker"}
        {"anchor":"Kubernetes", "title":"Container scheduling", "bullets":["A scheduler assigns pods."], "keywords":"pods"}
        {"title":"Unanchored guess", "bullets":["Something unrelated."], "keywords":"guess"}
        """
        let hints = Forecast.hints(in: reply, language: .en, first: 0, grounding: ["We use Pyannote for speaker labels."])
        #expect(hints.map(\.title) == ["Speaker count"])
    }

    @Test func anchorsMatchWholeSpokenWordsAndDoNotSpanSentences() {
        #expect(Forecast.isSpoken("PYANNOTE, speaker", in: ["We use Pyannote speaker labels."]))
        #expect(!Forecast.isSpoken("SQL", in: ["We chose PostgreSQL."]))
        #expect(!Forecast.isSpoken("speaker labels", in: ["We need a speaker.", "Labels are wrong."]))
        #expect(!Forecast.isSpoken("", in: ["A sentence."]))
    }

    @Test func thePublicationIntervalIncludesTheBoundaryAndFailsClosedForInvalidSettings() {
        let first = Date(timeIntervalSinceReferenceDate: 100)
        #expect(Forecast.mayPublish(last: nil, interval: 20, at: first))
        #expect(!Forecast.mayPublish(last: first, interval: 20, at: first.addingTimeInterval(19.99)))
        #expect(Forecast.mayPublish(last: first, interval: 20, at: first.addingTimeInterval(20)))
        #expect(!Forecast.mayPublish(last: first, interval: 20, at: first.addingTimeInterval(-1)))
        #expect(!Forecast.mayPublish(last: nil, interval: .nan, at: first))
        #expect(!Forecast.mayPublish(last: nil, interval: -1, at: first))
    }

    @Test func aRankingNeedsAllKnownChoicesAndAConsistentWinningProbability() {
        let valid = #"{"answers":{"rank":{"type":"choice","choice":"hint_f0","confidence":0.9,"probabilities":{"hint_f0":0.93,"none":0.07}}}}"#
        #expect(Forecast.ranking(in: valid, candidates: ["f0"])?.probability == 0.93)
        #expect(Forecast.ranking(in: valid, candidates: ["f0", "f1"]) == nil)
        for broken in [
            valid.replacingOccurrences(of: "\"choice\":\"hint_f0\"", with: "\"choice\":\"invented\""),
            valid.replacingOccurrences(of: "\"type\":\"choice\"", with: "\"type\":\"noul\""),
            valid.replacingOccurrences(of: "0.93", with: "true"),
            valid.replacingOccurrences(of: "0.93", with: "1.5"),
            valid.replacingOccurrences(of: "0.93", with: "0.4"),
            valid.replacingOccurrences(of: "0.93", with: "0.07").replacingOccurrences(of: "\"none\":0.07", with: "\"none\":0.93"),
            valid.replacingOccurrences(of: "\"confidence\":0.9", with: "\"confidence\":false")
        ] {
            #expect(Forecast.ranking(in: broken, candidates: ["f0"]) == nil)
        }
    }

    @Test func newDefaultsKeepEarlyPublicationOffAndUseTheStricterBar() {
        let config = SystemConfig()
        #expect(!config.agents.forecastWhileSpeaking)
        #expect(config.scheduler.forecastRankProbability == 0.9)
        #expect(config.scheduler.forecastMinimumIntervalSeconds == 20)
        #expect(config.scheduler.forecastRankCallsPerSession == 200)
    }
}
