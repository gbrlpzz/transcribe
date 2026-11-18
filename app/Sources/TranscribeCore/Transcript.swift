import CoreMedia
import Foundation
import NaturalLanguage
import Speech

// Word-level transcript assembly: the multi-language merge and the vocabulary
// pass. Both are pure functions over [SpokenWord] and unit-tested; the lanes
// only use them when there is more than one language or a vocabulary — a
// single pinned language with no vocabulary never touches this file.
//
// Measured on this stack (2026-11): a transcriber hearing a language it was
// not built for still emits fluent-looking text, but its per-word confidence
// drops to ~0.3–0.5 against ~0.9+ for the right one. The exception is
// English: every model reads it nearly as confidently as the English one
// (0.90 against 0.94), only spelling it worse — so a lane is also checked
// against the language of the text it produced (LanguageCheck). Misheard
// names sit at ≤ 0.75 while correctly heard ordinary words sit at ≥ 0.9.

/// One recognized token. `text` is the raw result run: it carries its own
/// leading space and trailing punctuation, so words concatenate back into the
/// transcript as-is.
public struct SpokenWord: Equatable, Sendable {
    public var text: String
    public var start: Double        // seconds into the audio
    public var end: Double
    public var confidence: Double   // 0…1

    public init(_ text: String, start: Double, end: Double, confidence: Double) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    /// The attributes a transcriber must report for `words(in:)` to work.
    public static let attributes: Set<SpeechTranscriber.ResultAttributeOption> =
        [.audioTimeRange, .transcriptionConfidence]

    /// Runs of a final result. A run without a time range (none observed, but
    /// the API allows it) is glued onto the word before it so no text is lost.
    public static func words(in text: AttributedString) -> [SpokenWord] {
        var out: [SpokenWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                out.append(SpokenWord(piece, start: range.start.seconds, end: range.end.seconds,
                                      confidence: run.transcriptionConfidence ?? 1))
            } else if out.isEmpty {
                out.append(SpokenWord(piece, start: 0, end: 0, confidence: 1))
            } else {
                out[out.count - 1].text += piece
            }
        }
        return out
    }
}

// MARK: - Multi-language merge

public enum LaneMerge {
    public struct Segment: Equatable, Sendable {
        public var lane: Int
        public var words: [SpokenWord]

        public init(lane: Int, words: [SpokenWord]) {
            self.lane = lane
            self.words = words
        }
    }

    /// The audio is scored in windows of this many seconds.
    static let window = 1.0
    /// What a language switch must earn: the other lane has to beat the
    /// current one by this much confidence-seconds before the path moves.
    /// Keeps near-ties (a German model reads English at ~0.9) from flapping.
    static let switchCost = 0.3

    /// Every lane transcribed the same audio in its own language. Returns the
    /// best path through them as time-ordered segments, each from one lane.
    public static func segments(_ lanes: [[SpokenWord]]) -> [Segment] {
        cut(lanes, along: path(lanes))
    }

    /// The lane to trust in each window.
    ///
    /// Per window, a lane scores the confidence of its words weighted by how
    /// much of the window they cover, so a lane that heard nothing scores 0
    /// and a lane guessing in the wrong language scores low. The path is the
    /// Viterbi optimum of those scores minus `switchCost` per switch; ties
    /// resolve to the earlier lane (lane 0 is the user's first language).
    public static func path(_ lanes: [[SpokenWord]]) -> [Int] {
        let end = lanes.joined().map(\.end).max() ?? 0
        guard !lanes.isEmpty, end > 0 else { return [] }
        let count = max(1, Int((end / window).rounded(.up)))
        func slot(_ time: Double) -> Int { min(count - 1, max(0, Int(time / window))) }

        var score = Array(repeating: Array(repeating: 0.0, count: count), count: lanes.count)
        for (lane, words) in lanes.enumerated() {
            for word in words where word.end > word.start {
                for i in slot(word.start)...slot(word.end) {
                    let overlap = min(word.end, Double(i + 1) * window) - max(word.start, Double(i) * window)
                    if overlap > 0 { score[lane][i] += word.confidence * overlap / window }
                }
            }
        }

        var best = score.map { $0[0] }
        var back: [[Int]] = []
        for i in 1..<count {
            var next = best, from = Array(0..<lanes.count)
            for lane in lanes.indices {
                var top = best[lane], source = lane
                for other in lanes.indices where other != lane && best[other] - switchCost > top {
                    top = best[other] - switchCost
                    source = other
                }
                next[lane] = top + score[lane][i]
                from[lane] = source
            }
            best = next
            back.append(from)
        }
        var lane = best.indices.max { best[$0] < best[$1] || (best[$0] == best[$1] && $0 > $1) } ?? 0
        var path = Array(repeating: lane, count: count)
        for i in stride(from: count - 1, to: 0, by: -1) {
            lane = back[i - 1][lane]
            path[i - 1] = lane
        }
        return path
    }

    /// A switch may move this far from its window edge to land on the end
    /// of a sentence.
    static let seamReach = 2.0
    /// Words a lane was this unsure about do not hold a seam in place.
    static let unsure = 0.6

    /// Cuts the lanes along a path into segments.
    ///
    /// Where the path switches lane, the cut is the end of the outgoing
    /// lane's nearest sentence — people change language between sentences,
    /// and both lanes mark that pause — unless that would discard words the
    /// outgoing lane was sure of; then it is the window edge, by word
    /// midpoint. Word time ranges stretch across silence, so the incoming
    /// lane starts with the first word that ENDS after the cut, and
    /// `foreign` (LanguageCheck) strips what it guessed before its own
    /// language began ("…next ye." ahead of "Buongiorno").
    public static func cut(_ lanes: [[SpokenWord]], along path: [Int],
                           foreign: [[Bool]]? = nil) -> [Segment] {
        // A seam decides, per word, whether it lies before the switch.
        typealias Seam = (SpokenWord) -> Bool
        func seam(_ words: [SpokenWord], at edge: Double) -> Seam {
            let ends = words.filter { ($0.text.last.map { ".?!。？！".contains($0) } ?? false)
                && abs($0.end - edge) <= seamReach }
            for stop in ends.sorted(by: { abs($0.end - edge) < abs($1.end - edge) }) {
                // What the snap would move across the edge must be noise
                // (dropped after an early stop) or solid (kept up to a late one).
                let moved = words.filter { word in
                    let middle = (word.start + word.end) / 2
                    return stop.end < edge ? word.end > stop.end && middle < edge
                                           : middle >= edge && word.end <= stop.end
                }
                let mean = moved.isEmpty ? nil : moved.map(\.confidence).reduce(0, +) / Double(moved.count)
                if let mean, (stop.end < edge) == (mean >= unsure) { continue }
                return { $0.end <= stop.end + 0.05 }
            }
            return { ($0.start + $0.end) / 2 < edge }
        }

        var out: [Segment] = []
        var after: Seam = { _ in false }       // the seam this segment starts at
        var i = 0
        while i < path.count {
            var j = i
            while j + 1 < path.count, path[j + 1] == path[i] { j += 1 }
            let lane = path[i]
            let before: Seam = j == path.count - 1
                ? { _ in true } : seam(lanes[lane], at: Double(j + 1) * window)
            var words: [SpokenWord] = []
            for (index, word) in lanes[lane].enumerated() where !after(word) && before(word) {
                if words.isEmpty, i > 0, foreign?[lane][index] == true { continue }
                words.append(word)
            }
            if !words.isEmpty {
                if out.last?.lane == lane {
                    out[out.count - 1].words += words
                } else {
                    out.append(Segment(lane: lane, words: words))
                }
            }
            after = before
            i = j + 1
        }
        return out
    }
}

// MARK: - Language check

public enum LanguageCheck {
    /// A sentence whose text reads as another lane's language counts this much.
    static let discount = 0.25
    /// A run with no sentence end is judged in pieces of this many words.
    static let longest = 30
    /// Below this many letters there is too little text to judge.
    static let minLetters = 12

    /// Marks, per lane, the words of every sentence that reads as a language
    /// other than the lane's own. Acoustic confidence cannot tell the English
    /// lane from a German lane transcribing English; the words themselves can.
    public static func foreign(_ lanes: [(id: String, words: [SpokenWord])]) -> [[Bool]] {
        let languages = lanes.map { language(of: $0.id) }
        let known = languages.compactMap { $0 }
        let recognizer = NLLanguageRecognizer()
        return zip(lanes, languages).map { lane, own in
            var flags = Array(repeating: false, count: lane.words.count)
            guard let own, Set(known).count > 1 else { return flags }
            var start = 0
            for (index, word) in lane.words.enumerated() {
                let ends = word.text.last.map { ".?!。？！".contains($0) } ?? false
                guard ends || index == lane.words.count - 1 || index - start + 1 >= longest else { continue }
                let text = lane.words[start...index].map(\.text).joined()
                if text.filter(\.isLetter).count >= minLetters {
                    recognizer.reset()
                    recognizer.languageConstraints = known
                    recognizer.processString(text)
                    if let heard = recognizer.dominantLanguage, heard != own {
                        for k in start...index { flags[k] = true }
                    }
                }
                start = index + 1
            }
            return flags
        }
    }

    /// The lanes as the merge should score them: flagged words at a discount.
    /// For scoring only — the transcript is cut from the originals.
    static func discounted(_ lanes: [(id: String, words: [SpokenWord])], _ foreign: [[Bool]]) -> [[SpokenWord]] {
        zip(lanes, foreign).map { lane, flags in
            zip(lane.words, flags).map { word, flag in
                var word = word
                if flag { word.confidence *= discount }
                return word
            }
        }
    }

    /// BCP-47 lane id → the language NaturalLanguage knows it as; nil when
    /// it cannot judge that language (the lane is then never discounted).
    static func language(of id: String) -> NLLanguage? {
        let language = Locale.Language(identifier: id)
        guard let code = language.languageCode?.identifier else { return nil }
        switch code {
        case "yue": return nil
        case "zh": return language.region?.identifier == "CN" ? .simplifiedChinese : .traditionalChinese
        default: return NLLanguage(rawValue: code)
        }
    }
}

// MARK: - Vocabulary

public enum Vocabulary {
    /// Only words the recognizer itself was unsure about are rewritten.
    static let gate = 0.8
    /// Largest edit distance, as a fraction of the longer spelling.
    static let maxDistance = 0.34
    /// Shorter terms only ever match exactly: too little signal to guess.
    static let minFuzzyLength = 4

    /// Rewrites near-miss spellings of the user's terms ("Kubernitz" →
    /// "Kubernetes", "Gabrielle Pizzi" → "Gabriele Pizzi"). Apple's
    /// SpeechTranscriber ignores contextual strings (measured: identical
    /// output with and without), so the bias is applied after the fact:
    /// a span is replaced when it spells the term apart from case, accents
    /// and spacing, or when it is close to it AND was recognized with low
    /// confidence. A confidently heard "window" is never turned into "Winnow".
    public static func apply(_ terms: [String], to words: [SpokenWord]) -> [SpokenWord] {
        struct Match { var start: Int; var length: Int; var distance: Double; var term: String }
        var matches: [Match] = []
        for term in terms {
            let target = key(term)
            guard !target.isEmpty else { continue }
            let size = term.split(whereSeparator: \.isWhitespace).count
            for length in max(1, size - 1)...(size + 1) where length <= words.count {
                for start in 0...(words.count - length) {
                    let span = words[start..<start + length]
                    let spelled = key(span.map(\.text).joined())
                    guard !spelled.isEmpty else { continue }
                    if spelled == target {
                        matches.append(Match(start: start, length: length, distance: 0, term: term))
                        continue
                    }
                    let longest = max(spelled.count, target.count)
                    guard target.count >= minFuzzyLength,
                          Double(abs(spelled.count - target.count)) <= maxDistance * Double(longest),
                          span.map(\.confidence).reduce(0, +) / Double(length) < gate else { continue }
                    let distance = Double(editDistance(spelled, target)) / Double(longest)
                    if distance <= maxDistance {
                        matches.append(Match(start: start, length: length, distance: distance, term: term))
                    }
                }
            }
        }
        // Closest spelling first; a span is rewritten at most once.
        var taken = Array(repeating: false, count: words.count)
        var chosen: [Match] = []
        for match in matches.sorted(by: { ($0.distance, $0.start) < ($1.distance, $1.start) }) {
            let range = match.start..<match.start + match.length
            guard !taken[range].contains(true) else { continue }
            for i in range { taken[i] = true }
            chosen.append(match)
        }
        var out = words
        for match in chosen.sorted(by: { $0.start > $1.start }) {
            let span = words[match.start..<match.start + match.length]
            let first = span.first!, last = span.last!
            let lead = first.text.prefix { $0.isWhitespace }
            let trail = String(last.text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            let word = SpokenWord(String(lead) + match.term + trail, start: first.start, end: last.end, confidence: 1)
            out.replaceSubrange(match.start..<match.start + match.length, with: [word])
        }
        return out
    }

    /// Letters and digits only, case and accents folded.
    static func key(_ text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber })
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}

// MARK: - Assembly

public enum Transcript {
    /// Lanes (first = the user's first language) → final text and the
    /// languages that actually ended up in it, in order of first appearance.
    public static func compose(lanes: [(id: String, words: [SpokenWord])],
                               vocabulary: [String]) -> (text: String, languages: [String]) {
        var parts: [String] = []
        var languages: [String] = []
        let foreign = LanguageCheck.foreign(lanes)
        let path = LaneMerge.path(LanguageCheck.discounted(lanes, foreign))
        for segment in LaneMerge.cut(lanes.map(\.words), along: path, foreign: foreign) {
            let words = vocabulary.isEmpty ? segment.words : Vocabulary.apply(vocabulary, to: segment.words)
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.append(text)
            if !languages.contains(lanes[segment.lane].id) { languages.append(lanes[segment.lane].id) }
        }
        return (parts.joined(separator: " "), languages)
    }
}
