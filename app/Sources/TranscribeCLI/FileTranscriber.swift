import Foundation
import AVFoundation
import Speech
import TranscribeCore

/// File lane (design §4): one self-driving analyzer per file.
///
/// `SpeechAnalyzer(inputAudioFile:finishAfterFile:)` reads the container via
/// AVAudioFile and converts internally (ar-§2: file-path input accepts any
/// readable format; nat-probe measured RTF unchanged for AAC 48k). The preset
/// is plain `.transcription` — finals only, no volatile overhead. The analyzer
/// reference is held for the whole drain: dropping it mid-analysis is a hard
/// trap (ar-§3.7), and finals only arrive after the internal finalize that
/// `finishAfterFile: true` performs (np-G2).
///
/// One locale and no vocabulary is the plain path: finals concatenated
/// untouched. Several locales run as several transcribers on the one analyzer
/// and the transcript is composed from their words (Transcript.swift) — that
/// is what follows a recording that changes language.
@MainActor
public enum FileTranscriber {
    public struct Output: Sendable {
        public var text: String
        /// Canonical BCP-47 identifiers of the languages in the transcript,
        /// in order of first appearance, comma-separated ("en-US,de-DE").
        public var language: String
        public var elapsedMs: Int
    }

    /// Write the transcript as `<basename>.md` beside the audio file
    /// (`# <title>\n\n<text>\n`). The only persistence in the app: the
    /// transcript lives beside the audio, and the app forgets everything else.
    public static func writeMarkdown(audioPath: URL, text: String) throws -> URL {
        let md = URL(fileURLWithPath: audioPath.path)
            .deletingPathExtension().appendingPathExtension("md")
        let title = md.deletingPathExtension().lastPathComponent
        let body = "# \(title)\n\n\(text)\n"
        try Data(body.utf8).write(to: md, options: [.atomic])
        return md
    }

    /// Transcribe one readable audio file. Throws CLIError.fileError when the
    /// container cannot be opened as audio; CLIError.transcriptionFailed when
    /// the pipeline fails after a clean open. `locales` must be canonical and
    /// ready, the user's first language first.
    public static func transcribe(url: URL, locales: [Locale],
                                  vocabulary: [String] = []) async throws -> Output {
        let wordLevel = locales.count > 1 || !vocabulary.isEmpty
        // Several languages: the progressive preset. Measured on mixed
        // recordings, a plain-preset transcriber commits one long final and
        // loses whole sentences of its own language after hearing another;
        // the progressive one keeps its footing. Volatile results are skipped.
        let preset: SpeechTranscriber.Preset = locales.count > 1 ? .progressiveTranscription : .transcription
        let transcribers = locales.map { locale in
            wordLevel
                ? SpeechTranscriber(locale: locale,
                                    transcriptionOptions: preset.transcriptionOptions,
                                    reportingOptions: preset.reportingOptions,
                                    attributeOptions: preset.attributeOptions.union(SpokenWord.attributes))
                : SpeechTranscriber(locale: locale, preset: preset)
        }
        let started = DispatchTime.now()
        // Open through AVAudioFile first: unsupported containers/corrupt files
        // fail HERE as a file error (exit 3), not as a pipeline error.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw CLIError.fileError("cannot read \(url.path) as audio (unsupported container?)")
        }
        // A zero-length file never closes its results stream: the analyzer
        // waits forever for audio that is not coming.
        guard audioFile.length > 0 else {
            throw CLIError.fileError("\(url.path) contains no audio")
        }
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: transcribers,
                finishAfterFile: true)
        } catch {
            throw CLIError.transcriptionFailed(
                "analyzer setup failed for \(url.lastPathComponent): \(error)")
        }
        // One drain per transcriber, all on the main actor. Finals are
        // committed prefixes carrying their own spacing (live probe A:
        // continuation finals begin with a space) — direct concatenation
        // reproduces the sentence flow.
        let drains = transcribers.map { transcriber in
            Task { @MainActor () throws -> (text: String, words: [SpokenWord]) in
                var text = ""
                var words: [SpokenWord] = []
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                    if wordLevel { words += SpokenWord.words(in: result.text) }
                }
                return (text, words)
            }
        }
        var lanes: [(id: String, text: String, words: [SpokenWord])] = []
        do {
            for (locale, drain) in zip(locales, drains) {
                let done = try await drain.value
                lanes.append((locale.identifier(.bcp47), done.text, done.words))
            }
        } catch {
            drains.forEach { $0.cancel() }
            throw CLIError.transcriptionFailed(
                "transcription pipeline failed for \(url.lastPathComponent): \(error)")
        }
        _ = analyzer  // kept alive until the results sequences close (ar-§3.7)
        var text = lanes.first?.text ?? ""
        var languages = lanes.first.map { [$0.id] } ?? []
        if wordLevel {
            let composed = Transcript.compose(lanes: lanes.map { (id: $0.id, words: $0.words) },
                                              vocabulary: vocabulary)
            if !composed.text.isEmpty { (text, languages) = composed }
        }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6)
        return Output(text: text, language: languages.joined(separator: ","), elapsedMs: ms)
    }
}

/// Shared CLI error surface: message + documented exit code.
public enum CLIError: Error {
    case usage(String)
    case fileError(String)
    case localeNotReady(String)
    case transcriptionFailed(String)

    public var errorMessage: String {
        switch self {
        case .usage(let m), .fileError(let m), .localeNotReady(let m),
             .transcriptionFailed(let m):
            return m
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .fileError: return 3
        case .localeNotReady: return 4
        case .transcriptionFailed: return 5
        }
    }
}
