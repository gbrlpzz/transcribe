import Foundation
import AVFoundation
import Speech

/// File lane (design §4): one self-driving analyzer per file.
///
/// `SpeechAnalyzer(inputAudioFile:finishAfterFile:)` reads the container via
/// AVAudioFile and converts internally (ar-§2: file-path input accepts any
/// readable format; nat-probe measured RTF unchanged for AAC 48k). The preset
/// is plain `.transcription` — finals only, no volatile overhead. The analyzer
/// reference is held for the whole drain: dropping it mid-analysis is a hard
/// trap (ar-§3.7), and finals only arrive after the internal finalize that
/// `finishAfterFile: true` performs (np-G2).
@MainActor
public enum FileTranscriber {
    public struct Output: Sendable {
        public var text: String
        /// Canonical BCP-47 identifier of the locale actually used ("en-US").
        public var language: String
        public var elapsedMs: Int
    }

    /// Transcribe one readable audio file. Throws CLIError.fileError when the
    /// container cannot be opened as audio; CLIError.transcriptionFailed when
    /// the pipeline fails after a clean open.
    public static func transcribe(url: URL, locale: Locale) async throws -> Output {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let started = DispatchTime.now()
        // Open through AVAudioFile first: unsupported containers/corrupt files
        // fail HERE as a file error (exit 3), not as a pipeline error.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw CLIError.fileError("cannot read \(url.path) as audio (unsupported container?)")
        }
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                finishAfterFile: true)
        } catch {
            throw CLIError.transcriptionFailed(
                "analyzer setup failed for \(url.lastPathComponent): \(error)")
        }
        var text = ""
        do {
            // Finals are committed prefixes carrying their own spacing
            // (live probe A: continuation finals begin with a space) — direct
            // concatenation reproduces the sentence flow.
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
        } catch {
            throw CLIError.transcriptionFailed(
                "transcription pipeline failed for \(url.lastPathComponent): \(error)")
        }
        _ = analyzer  // kept alive until the results sequence closes (ar-§3.7)
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6)
        return Output(text: text, language: locale.identifier(.bcp47), elapsedMs: ms)
    }
}
