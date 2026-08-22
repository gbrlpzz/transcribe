import Foundation
import TranscribeCore

// Pure-logic coverage for SpeechDictationEngine's decision helpers.
// The analyzer path itself is verified live via the `dictbench` mode below
// (synthetic clips through the real pipeline on this machine).
enum DictationSupportTests {

    static func testThrottleFirstEmitPasses() throws {
        var t = PartialThrottle(minimumInterval: 0.1)
        try require(t.shouldEmit(text: "Hello", at: 100.0))
    }

    static func testThrottleDedupesIdenticalText() throws {
        var t = PartialThrottle(minimumInterval: 0.1)
        try require(t.shouldEmit(text: "Hello", at: 100.0))
        try require(!t.shouldEmit(text: "Hello", at: 130.0))   // same text, later time
    }

    static func testThrottleRateLimit() throws {
        var t = PartialThrottle(minimumInterval: 0.1)
        try require(t.shouldEmit(text: "a", at: 100.0))
        try require(!t.shouldEmit(text: "ab", at: 100.05))     // too soon
        try require(t.shouldEmit(text: "abc", at: 100.101))    // boundary passed
    }

    static func testLanePickerPrefersFinalsOverLongerVolatileTail() throws {
        // Lane B has more live chars but no finals: finals win (np §3).
        let lanes = [
            LaneTally(id: "en-US", finalChars: 12, firstFinalOrder: 0, liveChars: 12),
            LaneTally(id: "it-IT", finalChars: 0, firstFinalOrder: .max, liveChars: 40),
        ]
        try require(LanePicker.choose(lanes) == "en-US")
    }

    static func testLanePickerCharCountRanking() throws {
        let lanes = [
            LaneTally(id: "it-IT", finalChars: 30, firstFinalOrder: 1, liveChars: 30),
            LaneTally(id: "en-US", finalChars: 55, firstFinalOrder: 3, liveChars: 60),
        ]
        try require(LanePicker.choose(lanes) == "en-US")
    }

    static func testLanePickerEarlierFinalBreaksTies() throws {
        let lanes = [
            LaneTally(id: "it-IT", finalChars: 30, firstFinalOrder: 4, liveChars: 31),
            LaneTally(id: "en-US", finalChars: 30, firstFinalOrder: 2, liveChars: 31),
        ]
        try require(LanePicker.choose(lanes) == "en-US")   // locked on sooner
    }

    static func testLanePickerVolatileFallbackWhenNoFinals() throws {
        let lanes = [
            LaneTally(id: "en-US", finalChars: 0, firstFinalOrder: .max, liveChars: 5),
            LaneTally(id: "it-IT", finalChars: 0, firstFinalOrder: .max, liveChars: 22),
        ]
        try require(LanePicker.choose(lanes) == "it-IT")
    }

    static func testLanePickerEmpty() throws {
        try require(LanePicker.choose([]) == nil)
        try require(LanePicker.choose([LaneTally(id: "x", finalChars: 0,
                                             firstFinalOrder: .max, liveChars: 0)]) == nil)
    }

    static func testWavHeaderBytes() throws {
        let pcm = Data([1, 2, 3, 4])
        let wav = WavFile.data(pcm: pcm, sampleRate: 16000, channels: 1)
        try require(wav.count == 44 + 4)
        try require(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        try require(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        try require(String(data: wav.subdata(in: 36..<40), encoding: .ascii) == "data")
        // RIFF size = 36 + dataLen = 40 LE
        let riffSize = wav.subdata(in: 4..<8).map { $0 }
        try require(riffSize == [40, 0, 0, 0])
        // sample rate 16000 LE @24; byte rate = rate*blockAlign = 32000 LE @28
        try require(wav.subdata(in: 24..<28).map { $0 } == [0x80, 0x3E, 0, 0])
        try require(wav.subdata(in: 28..<32).map { $0 } == [0x00, 0x7D, 0, 0])
        let dataLen = wav.subdata(in: 40..<44).map { $0 }
        try require(dataLen == [4, 0, 0, 0])
    }

    static func testWavHeaderStereo() throws {
        let wav = WavFile.data(pcm: Data(repeating: 0, count: 6), sampleRate: 8000, channels: 2)
        let channels = wav.subdata(in: 22..<24).map { $0 }  // 2 LE
        try require(channels == [2, 0])
        let blockAlign = wav.subdata(in: 32..<34).map { $0 } // 2ch * 2B = 4 LE
        try require(blockAlign == [4, 0])
    }

    static var allTests: [(String, TestCase)] {
        [
            ("throttleFirstEmitPasses", testThrottleFirstEmitPasses),
            ("throttleDedupesIdenticalText", testThrottleDedupesIdenticalText),
            ("throttleRateLimit", testThrottleRateLimit),
            ("lanePickerPrefersFinalsOverLongerVolatileTail", testLanePickerPrefersFinalsOverLongerVolatileTail),
            ("lanePickerCharCountRanking", testLanePickerCharCountRanking),
            ("lanePickerEarlierFinalBreaksTies", testLanePickerEarlierFinalBreaksTies),
            ("lanePickerVolatileFallbackWhenNoFinals", testLanePickerVolatileFallbackWhenNoFinals),
            ("lanePickerEmpty", testLanePickerEmpty),
            ("wavHeaderBytes", testWavHeaderBytes),
            ("wavHeaderStereo", testWavHeaderStereo),
        ]
    }
}
