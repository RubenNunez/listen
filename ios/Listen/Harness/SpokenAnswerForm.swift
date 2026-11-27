import Foundation

/// What changes for the roles of a system when their answers are also said aloud
/// (`AnswerEngine.Settings.spoken`). Nothing else changes: the same models are asked, with the
/// system's card rules, the owner's instructions, the topic's material and the same budget,
/// and with typed decisions every draft is reviewed before it is shown or said.
///
/// It lives beside the engine and not in `system.json`: a conversation of cards never sees it,
/// and saved systems need no new key.
struct SpokenAnswerForm: Equatable, Sendable {
    /// Follows the card rules and the owner's instructions in every request that writes a card
    /// (draft, merge, web look-up). It changes the form of the card, not what may be claimed.
    var rules = SpokenAnswerForm.defaultRules
    /// The reply allowance of a routed draft. A card of cards has two lines (160 tokens); a few
    /// spoken sentences need more.
    var routedDraftTokens = 320
    /// With typed decisions one writer is asked per round. Spoken, the first writers of the
    /// system are asked at once and the first complete draft is reviewed and said. A later
    /// draft is not said as it is; it is given to the main model (`deepens`). One is the
    /// behaviour of cards.
    var parallelDrafts = 2
    /// How long the other writer may still write after a draft was accepted. After that it is
    /// stopped, so it never holds the main model back for longer.
    var hedgeGraceSeconds = 1.5
    /// While the fast answer is being said, the system's main model (its merger role) is asked
    /// once what that answer lacks or has wrong (`AnswerEngine.deepen`). Its reviewed reply is
    /// said as an addition or correction. It follows the system's merge switch and budget, and
    /// is not asked when a web look-up answers the same moment.
    var deepens = true
    /// A turn of fewer words than this (a greeting, a yes or no) is not deepened.
    var deepenMinimumWords = 5
    var deepenTokens = 400
    /// The main model may think longer than a fast writer; it holds nothing that is said.
    var deepenFirstTextSeconds = 12.0
    var deepenTotalSeconds = 25.0
    var deepenRules = SpokenAnswerForm.defaultDeepenRules

    static let defaultDeepenRules = """
        A faster model has already answered this moment, and its answer is being said to the person \
        right now. You are the main model of this system. Do not answer again and do not rephrase: \
        say only what that first answer is missing or has wrong.
        Add what a knowledgeable person would still want the listener to know: the reason behind it, \
        the number that matters, the important exception, a better example, the consequence for this \
        person's situation as far as the supplied material shows it. If the first answer states \
        something wrong, correct it and say plainly what is different.
        Reply with the same subject title on line 1 and then at most three new sentences. If the first \
        answer is already complete and correct for what was asked, reply {NOTHING}.
        Say them as natural short sentences: one thought and one comfortable breath each, about twelve \
        to eighteen words where the language permits. Split a long explanation at a meaningful boundary \
        instead of joining clauses. This is a rhythm, not a word cap: keep the important qualification \
        and the fuller explanation where it is useful, and never drop or shorten a fact, or add filler, \
        to meet it.
        """

    static let defaultRules = """
        This conversation is spoken. A voice reads your card to the person, who may not look at the \
        screen. That changes the form of the card and nothing else: every rule above about evidence, \
        sources, uncertainty, other people, {NOTHING} and untrusted material stays in force, and this \
        form takes the place of the line and word limits given above.
        Line 1: a short subject title. It is shown and not spoken, so the answer must not depend on it.
        Then the answer in natural spoken {LANGUAGE}: complete sentences, one sentence per line, the way \
        a knowledgeable person says it to someone across the table.
        The first sentence is the direct answer and stands on its own.
        Keep every sentence natural and short: one thought and one comfortable breath each, about \
        twelve to eighteen words where {LANGUAGE} permits. Split a long explanation at a meaningful \
        boundary instead of joining clauses. This is a rhythm, not a word cap: the first sentence stays \
        a complete answer, important qualifications and a useful fuller explanation stay, and you never \
        drop or shorten a fact, or add filler, to meet it.
        After it, say what helps this listener most: the reason, the key number, an example, the usual \
        pitfall. A question that deserves it gets two to four more sentences. A simple question, a yes \
        or no, a greeting or a single fact gets one or two sentences. Never pad, never repeat the \
        question, never announce what you are about to say, and never say that you are thinking, \
        searching or checking.
        No lists, no keywords without a verb, no headings and no abbreviations a voice cannot say. \
        Write numbers and units so they can be read aloud. Do not say that something was checked, \
        confirmed or looked up unless the supplied material shows it.
        For a subject that already has a block, write only sentences that add to it or correct it; \
        sentences the block already contains are not said again. When you correct something, say \
        plainly what is different.
        Code, a formula, a chart and source lines may follow after the sentences where the rules \
        above ask for them. They are shown and not spoken.
        """
}
