import Foundation

// Minimal XCTest-shaped harness: CLT toolchains ship no XCTest module, so the
// suites below run under this runner. Each test is an `async throws` closure;
// failures = thrown TestFailure, skips = TestSkipped (XCTSkip semantics).
// Porting to XCTest later is mechanical: rename require* to XCT*, skip() to
// XCTSkip(), wrap funcs in classes, delete Runner.

struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
struct TestSkipped: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

func require(_ condition: Bool, _ message: String = "") throws {
    if !condition { throw TestFailure(message) }
}
func requireEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    if a != b { throw TestFailure("\(message.isEmpty ? "not equal" : message): \(a) != \(b)") }
}
func requireNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    if a == b { throw TestFailure("\(message.isEmpty ? "unexpectedly equal" : message): \(a) == \(b)") }
}
func skipTest(_ reason: String) throws { throw TestSkipped(reason) }
func fail(_ message: String) -> TestFailure { TestFailure(message) }

/// Test closures run on the main actor (managers/stores are MainActor-isolated).
typealias TestCase = @MainActor () async throws -> Void
