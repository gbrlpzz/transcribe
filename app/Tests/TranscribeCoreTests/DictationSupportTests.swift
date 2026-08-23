import Foundation
import TranscribeCore

// Pure-logic coverage for SpeechDictationEngine's decision helpers.
// The analyzer path itself is verified live via the `dictbench` mode below
// (synthetic clips through the real pipeline on this machine).
enum DictationSupportTests {

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

    static var allTests: [(String, TestCase)] {
        [
            ("lanePickerPrefersFinalsOverLongerVolatileTail", testLanePickerPrefersFinalsOverLongerVolatileTail),
            ("lanePickerCharCountRanking", testLanePickerCharCountRanking),
            ("lanePickerEarlierFinalBreaksTies", testLanePickerEarlierFinalBreaksTies),
            ("lanePickerVolatileFallbackWhenNoFinals", testLanePickerVolatileFallbackWhenNoFinals),
            ("lanePickerEmpty", testLanePickerEmpty),
        ]
    }
}
