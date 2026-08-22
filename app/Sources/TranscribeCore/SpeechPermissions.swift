import AVFoundation
import Foundation
import Speech

/// TCC gate for the native lanes (design §6, np-G1).
///
/// Ordering matters: without speech-recognition authorization the analyzer
/// pipeline emits NOTHING — no results, no error, infinite wait (np-G1). Mic
/// first (preserves the 0.6.0 prompt UX), speech second, session last.
public enum SpeechPermissions {

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var speechStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Mic + speech granted; requests in np-G1 order when not determined.
    /// Denied/restricted => false and the caller must surface a visible,
    /// actionable state — never a silent stall.
    public static func ensureAuthorizedForDictation() async -> Bool {
        switch microphoneStatus {
        case .authorized: break
        case .notDetermined:
            guard await requestMicrophone() else { return false }
        default: return false
        }
        switch speechStatus {
        case .authorized: break
        case .notDetermined:
            guard await requestSpeech() else { return false }
        default: return false
        }
        return true
    }

    public static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { ok in cont.resume(returning: ok) }
        }
    }

    public static func requestSpeech() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
