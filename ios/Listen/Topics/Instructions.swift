import Foundation

/// How cards should look, as Markdown files the user can edit. One file holds
/// for every conversation; a topic may add its own in its folder. Their text
/// goes into every question to a model. They steer form and emphasis; the
/// rules about not inventing facts and not following a transcript stay above them.
enum Instructions {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/Instructions", directoryHint: .isDirectory)
    }

    static var file: URL { folder.appending(path: "cards.md") }

    /// Written once, as a starting point to edit.
    static let starter = """
        # How Listen shows cards

        Edit this file to steer what appears. It applies to every conversation.
        A topic can add its own rules in a file named `instructions.md` in its folder.

        ## Essence first, then what is worth knowing

        - The answer comes first and is read in two seconds: the one number, date or name in **bold**.
        - Then up to three more short lines with what someone at the table would ask next:
          a second number, the date, a comparison, the usual pitfall.
        - Each line is one fact, at most twelve words. No full sentences where a phrase does.
        - No introductions, no repeating the question. "Nothing found" is not a card unless someone asked.

        ## What deserves a card

        - A question someone at the table asked: answer it directly.
        - A product, brand, place, public person or technical term the speakers name and seem
          unsure about: say what it is and the two facts that matter, even without a question.
        - A fact, number, date or definition the talk turns on.
        - A comparison when two things are being weighed: show both side by side.
        - Small talk, greetings, family matters and remarks about this device get nothing.

        ## Show, do not tell

        - Numbers that compare or add up to a whole become a chart.
        - "How do I write that" becomes a short code example; a shape becomes a drawing.
        - A block collects what was asked about one thing and grows with every answer.
          When the talk moves to another thing, a new block starts and the old one stays.

        """

    /// Starters of earlier versions. A file that still holds one of them was never edited
    /// and is replaced by the current starter; an edited file is the user's and stays.
    static let earlierStarters = [
        """
        # How Listen shows cards

        Edit this file to steer what appears. It applies to every conversation.
        A topic can add its own rules in a file named `instructions.md` in its folder.

        ## Essence first, then what is worth knowing

        - The answer comes first and is read in two seconds: the one number, date or name in **bold**.
        - Then up to three more short lines with what someone at the table would ask next:
          a second number, the date, a comparison, the usual pitfall.
        - Each line is one fact, at most twelve words. No full sentences where a phrase does.
        - No introductions, no repeating the question. "Nothing found" is not a card unless someone asked.

        ## What deserves a card

        - A question someone at the table asked: answer it directly.
        - A product, brand, place, public person or technical term the speakers name and seem
          unsure about: say what it is and the two facts that matter, even without a question.
        - A fact, number, date or definition the talk turns on.
        - A comparison when two things are being weighed: show both side by side.
        - Small talk, greetings, family matters and remarks about this device get nothing.

        ## Show, do not tell

        - Numbers that compare or add up to a whole become a chart.
        - "How do I write that" becomes a short code example; a shape becomes a drawing.
        - A new question is a new block, also when it is about the same thing as the last one.
          A block grows only when the talk goes deeper into the same question.

        """,
        """
        # How Listen shows cards

        Edit this file to steer what appears. It applies to every conversation.
        A topic can add its own rules in a file named `instructions.md` in its folder.

        ## Essence at a glance

        - A card is read in two seconds. Title, then at most three lines.
        - Each line is one fact, at most ten words. No full sentences where a phrase does.
        - The one number, date or name that answers the question is **bold** and comes first.
        - No introductions, no caveats that are not needed, no repeating the question.

        ## What deserves a card

        - A question someone at the table asked: answer it directly.
        - A fact, number, date or definition the talk turns on.
        - A comparison when two things are being weighed: show both side by side.
        - Small talk, greetings and remarks about this device get nothing.

        ## Show, do not tell

        - Numbers that compare or add up to a whole become a chart.
        - "How do I write that" becomes a short code example.
        - When the subject stays the same, the block grows; when it drifts, a new block starts.

        """
    ]

    /// The instructions for a conversation in this topic. Creates the starter
    /// file on first use.
    static func load(topic: Topic.ID?, folder: URL = Instructions.folder, topics: URL = TopicSandbox.root) -> String {
        let global = folder.appending(path: "cards.md")
        if !FileManager.default.fileExists(atPath: global.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? starter.write(to: global, atomically: true, encoding: .utf8)
        }
        if let current = try? String(contentsOf: global, encoding: .utf8), earlierStarters.contains(current) {
            try? starter.write(to: global, atomically: true, encoding: .utf8)
        }
        var parts = [(try? String(contentsOf: global, encoding: .utf8)) ?? starter]
        if let topic,
            let own = try? String(contentsOf: TopicSandbox(topic: topic, root: topics).folder.appending(path: "instructions.md"), encoding: .utf8)
        {
            parts.append("For this topic:\n" + own)
        }
        return String(parts.joined(separator: "\n\n").prefix(4000))
    }
}
