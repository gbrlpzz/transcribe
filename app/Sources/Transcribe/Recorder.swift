import AVFoundation
import Foundation

/// Press-to-talk recording. Captures 16 kHz mono 16-bit PCM WAV — exactly what
/// the Whisper engine expects, with no transcoding anywhere in the pipeline.
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("transcribe_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true
        guard rec.record() else {
            throw NSError(domain: "Transcribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the microphone."])
        }
        recorder = rec
        currentURL = url
        return url
    }

    func stop() {
        recorder?.stop()
    }

    /// Current input level as 0...1 (from AVAudioRecorder metering).
    func level() -> Float {
        recorder?.updateMeters()
        let db = recorder?.averagePower(forChannel: 0) ?? -160
        return max(0, min(1, (db + 55) / 55))
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // keep the file; the engine will consume it
        recorder.stop()
    }
}
