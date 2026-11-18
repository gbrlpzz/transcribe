import Foundation
import TranscribeCore

// Pure-logic coverage for transcript assembly: the multi-language merge and
// the vocabulary pass. Confidence figures mirror what the speech stack was
// measured to report (right language ≈ 0.9+, wrong language ≈ 0.3–0.5).
// The analyzer path itself is verified live via the `dictbench` mode
// (synthetic clips through the real pipeline on this machine).
enum DictationSupportTests {

    /// Evenly spaced half-second words: "w0 w1 …" from `from` seconds on.
    static func lane(_ label: String, from: Double, count: Int, confidence: Double) -> [SpokenWord] {
        (0..<count).map { i in
            SpokenWord(" \(label)\(i)", start: from + Double(i) * 0.5, end: from + Double(i) * 0.5 + 0.5,
                       confidence: confidence)
        }
    }
    static func text(_ segments: [LaneMerge.Segment]) -> String {
        segments.map { $0.words.map(\.text).joined() }.joined(separator: " |")
    }

    // MARK: Merge

    static func mergeSingleLaneIsUntouched() throws {
        let only = lane("a", from: 0, count: 6, confidence: 0.4)
        try requireEqual(LaneMerge.segments([only]), [LaneMerge.Segment(lane: 0, words: only)])
        try requireEqual(LaneMerge.segments([]), [])
        try requireEqual(LaneMerge.segments([[], []]), [])
    }

    static func mergePicksTheConfidentLaneForOneLanguage() throws {
        // German audio: the English lane guesses at 0.4, the German lane hears 0.95.
        let en = lane("en", from: 0, count: 12, confidence: 0.4)
        let de = lane("de", from: 0, count: 12, confidence: 0.95)
        let got = LaneMerge.segments([en, de])
        try requireEqual(got.map(\.lane), [1])
        try requireEqual(got.first?.words.count, 12)
    }

    static func mergeNearTieStaysOnTheFirstLanguage() throws {
        // English audio: a German model reads it at 0.90 against 0.94, and
        // wins the odd window. The path must not flap.
        var en = lane("en", from: 0, count: 12, confidence: 0.94)
        var de = lane("de", from: 0, count: 12, confidence: 0.90)
        en[0].confidence = 0.85; en[1].confidence = 0.85
        de[0].confidence = 0.93; de[1].confidence = 0.93
        try requireEqual(LaneMerge.segments([en, de]).map(\.lane), [0])
        // An exact tie resolves to the first lane too.
        let a = lane("a", from: 0, count: 8, confidence: 0.9)
        let b = lane("b", from: 0, count: 8, confidence: 0.9)
        try requireEqual(LaneMerge.segments([a, b]).map(\.lane), [0])
    }

    static func mergeFollowsALanguageSwitchAndBack() throws {
        // 0–6 s English, 6–12 s German, 12–18 s English. Each lane is sure of
        // its own language and guessing on the other.
        let en = lane("en", from: 0, count: 12, confidence: 0.95)
            + lane("xx", from: 6, count: 12, confidence: 0.35)
            + lane("en", from: 12, count: 12, confidence: 0.95)
        let de = lane("yy", from: 0, count: 12, confidence: 0.65)
            + lane("de", from: 6, count: 12, confidence: 0.92)   // and silent after 12 s
        let got = LaneMerge.segments([en, de])
        try requireEqual(got.map(\.lane), [0, 1, 0])
        try requireEqual(got.map(\.words.count), [12, 12, 12])
        try require(!text(got).contains("xx") && !text(got).contains("yy"), "no wrong-language words: \(text(got))")
    }

    static func mergeIgnoresABriefDip() throws {
        // One shaky second in the middle of English is not a language switch.
        var en = lane("en", from: 0, count: 20, confidence: 0.95)
        en[10].confidence = 0.6; en[11].confidence = 0.6
        let de = lane("de", from: 0, count: 20, confidence: 0.7)
        try requireEqual(LaneMerge.segments([en, de]).map(\.lane), [0])
    }

    static func cutSnapsToTheSentenceAndSkipsStretchedAndGuessedWords() throws {
        // Shapes measured on an English → Italian → German recording. Time
        // ranges stretch across silence ("Zum" starts 1.7 s early), and each
        // lane guesses a little past the point where its language ended.
        func s(_ t: String, _ a: Double, _ b: Double, _ c: Double) -> SpokenWord {
            SpokenWord(t, start: a, end: b, confidence: c)
        }
        let en = [s(" do", 5.0, 5.0, 1.0), s(" next", 5.0, 5.2, 1.0), s(" year.", 5.2, 5.8, 0.93),
                  s(" Bonjour", 5.9, 6.4, 0.15), s(" Natuti.", 6.4, 7.0, 0.17)]
        let it = [s(" next", 5.2, 5.5, 0.83), s(" ye.", 5.5, 5.9, 0.71),
                  s(" Buongiorno", 5.9, 6.2, 0.93), s(" a", 6.2, 6.6, 0.97), s(" tutti,", 6.6, 7.1, 0.73),
                  s(" prossimo", 11.3, 11.6, 0.99), s(" anno.", 11.6, 12.1, 0.76),
                  s(" Probeiben.", 12.1, 17.4, 0.51)]
        let de = [s(" di", 9.6, 9.8, 0.80), s(" cosiam", 9.8, 10.4, 0.67),
                  s(" Zum", 10.4, 12.6, 0.87), s(" Schluss", 12.6, 12.8, 0.88), s(" haben.", 16.7, 17.3, 0.76)]
        let path = Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6) + Array(repeating: 2, count: 6)
        let foreign = [[false, false, false, true, true],
                       [true, true, false, false, false, false, false, false],
                       [false, false, false, false, false]]
        let got = LaneMerge.cut([en, it, de], along: path, foreign: foreign)
        try requireEqual(got.map(\.lane), [0, 1, 2])
        try requireEqual(text(got), " do next year. | Buongiorno a tutti, prossimo anno. | Zum Schluss haben.")
    }

    static func cutKeepsConfidentWordsPastAnEarlySentenceEnd() throws {
        // The speaker carries on in the same language after the full stop and
        // switches mid-sentence: the words between must not be thrown away.
        func s(_ t: String, _ a: Double, _ b: Double, _ c: Double) -> SpokenWord {
            SpokenWord(t, start: a, end: b, confidence: c)
        }
        let a = [s("Fine.", 0, 2.4, 0.95), s(" And", 2.5, 3.0, 0.95), s(" then", 3.0, 3.9, 0.95)]
        let b = [s(" ecco", 4.1, 5.0, 0.95), s(" qua.", 5.0, 6.0, 0.95)]
        let got = LaneMerge.cut([a, b], along: [0, 0, 0, 0, 1, 1])
        try requireEqual(text(got), "Fine. And then | ecco qua.")
    }

    static func languageCheckFlagsALaneReadingAnotherLanguage() throws {
        func words(_ sentence: String) -> [SpokenWord] {
            sentence.split(separator: " ").enumerated().map { i, t in
                SpokenWord(" " + t, start: Double(i), end: Double(i) + 1, confidence: 0.9)
            }
        }
        let english = "Today I want to talk about the quarterly results and what we plan to do next year."
        let german = "Heute möchte ich über die Quartalsergebnisse sprechen und darüber, was wir nächstes Jahr vorhaben."
        // The German lane transcribed English audio into English words.
        let flags = LanguageCheck.foreign([(id: "en-US", words: words(english + " " + german)),
                                           (id: "de-DE", words: words(english + " " + german))])
        let n = english.split(separator: " ").count
        try require(flags[0][..<n].allSatisfy { !$0 } && flags[0][n...].allSatisfy { $0 }, "en lane: \(flags[0])")
        try require(flags[1][..<n].allSatisfy { $0 } && flags[1][n...].allSatisfy { !$0 }, "de lane: \(flags[1])")
        // One language, or too little text: nothing is flagged.
        try require(LanguageCheck.foreign([(id: "en-US", words: words(german))])[0].allSatisfy { !$0 })
        try require(LanguageCheck.foreign([(id: "en-US", words: words("Ja gut.")),
                                           (id: "de-DE", words: [])])[0].allSatisfy { !$0 })
    }

    static func composeJoinsSegmentsAndListsLanguages() throws {
        let en = [SpokenWord("Good", start: 0, end: 1, confidence: 0.95),
                  SpokenWord(" morning.", start: 1, end: 2, confidence: 0.95),
                  SpokenWord(" Gutten", start: 2, end: 3, confidence: 0.3),
                  SpokenWord(" morgan.", start: 3, end: 4, confidence: 0.3)]
        let de = [SpokenWord("Gut", start: 0, end: 1, confidence: 0.5),
                  SpokenWord(" Mornin.", start: 1, end: 2, confidence: 0.5),
                  SpokenWord(" Guten", start: 2, end: 3, confidence: 0.95),
                  SpokenWord(" Morgen.", start: 3, end: 4, confidence: 0.95)]
        let got = Transcript.compose(lanes: [(id: "en-US", words: en), (id: "de-DE", words: de)], vocabulary: [])
        try requireEqual(got.text, "Good morning. Guten Morgen.")
        try requireEqual(got.languages, ["en-US", "de-DE"])
    }

    // MARK: Vocabulary

    static func w(_ text: String, _ confidence: Double) -> SpokenWord {
        SpokenWord(text, start: 0, end: 0, confidence: confidence)
    }
    static func spell(_ words: [SpokenWord]) -> String { words.map(\.text).joined() }

    static func vocabularyFixesLowConfidenceNearMisses() throws {
        // Confidences as measured on a synthesized clip of these names.
        let heard = [w("I", 0.99), w(" met", 1.0), w(" Gabrielle", 0.72), w(" Pizzi", 0.59),
                     w(" about", 1.0), w(" the", 0.98), w(" Kubernitz", 0.43), w(" Migration.", 0.84)]
        let got = Vocabulary.apply(["Gabriele Pizzi", "Kubernetes"], to: heard)
        try requireEqual(spell(got), "I met Gabriele Pizzi about the Kubernetes Migration.")
    }

    static func vocabularyLeavesConfidentWordsAlone() throws {
        // "window" is one letter from "Winnow" and "Gabrielle" one from
        // "Gabriele" — but they were heard clearly, so they stand.
        let heard = [w("Open", 0.99), w(" the", 1.0), w(" window,", 1.0), w(" Gabrielle.", 0.98)]
        try requireEqual(Vocabulary.apply(["Winnow", "Gabriele Pizzi"], to: heard), heard)
    }

    static func vocabularyExactSpellingGetsCanonicalCaseAndKeepsPunctuation() throws {
        let heard = [w("at", 0.9), w(" liminal", 0.95), w(" futures,", 0.97), w(" and", 1.0), w(" Zurich.", 0.99)]
        let got = Vocabulary.apply(["Liminal Futures", "Zürich"], to: heard)
        try requireEqual(spell(got), "at Liminal Futures, and Zürich.")
    }

    static func vocabularyIgnoresFarAndShortTerms() throws {
        let heard = [w("Head", 0.4), w(" Center", 0.4), w(" is", 0.5), w(" at", 0.5)]
        // "Hetzner" is too far from "Head Center"; "AI" is too short to guess at.
        try requireEqual(Vocabulary.apply(["Hetzner", "AI", "  "], to: heard), heard)
        try requireEqual(Vocabulary.apply(["Kubernetes"], to: []), [])
    }

    static func vocabularyPrefersTheClosestSpan() throws {
        // "met Gabrielle Pizzi" is also within range of the term; the tighter
        // two-word span must win and "met" must survive.
        let heard = [w("met", 0.5), w(" Gabrielle", 0.5), w(" Pizzi", 0.5)]
        try requireEqual(spell(Vocabulary.apply(["Gabriele Pizzi"], to: heard)), "met Gabriele Pizzi")
    }

    static var allTests: [(String, TestCase)] {
        [
            ("mergeSingleLaneIsUntouched", mergeSingleLaneIsUntouched),
            ("mergePicksTheConfidentLaneForOneLanguage", mergePicksTheConfidentLaneForOneLanguage),
            ("mergeNearTieStaysOnTheFirstLanguage", mergeNearTieStaysOnTheFirstLanguage),
            ("mergeFollowsALanguageSwitchAndBack", mergeFollowsALanguageSwitchAndBack),
            ("mergeIgnoresABriefDip", mergeIgnoresABriefDip),
            ("cutSnapsToTheSentenceAndSkipsStretchedAndGuessedWords", cutSnapsToTheSentenceAndSkipsStretchedAndGuessedWords),
            ("cutKeepsConfidentWordsPastAnEarlySentenceEnd", cutKeepsConfidentWordsPastAnEarlySentenceEnd),
            ("languageCheckFlagsALaneReadingAnotherLanguage", languageCheckFlagsALaneReadingAnotherLanguage),
            ("composeJoinsSegmentsAndListsLanguages", composeJoinsSegmentsAndListsLanguages),
            ("vocabularyFixesLowConfidenceNearMisses", vocabularyFixesLowConfidenceNearMisses),
            ("vocabularyLeavesConfidentWordsAlone", vocabularyLeavesConfidentWordsAlone),
            ("vocabularyExactSpellingGetsCanonicalCaseAndKeepsPunctuation", vocabularyExactSpellingGetsCanonicalCaseAndKeepsPunctuation),
            ("vocabularyIgnoresFarAndShortTerms", vocabularyIgnoresFarAndShortTerms),
            ("vocabularyPrefersTheClosestSpan", vocabularyPrefersTheClosestSpan),
        ]
    }
}
