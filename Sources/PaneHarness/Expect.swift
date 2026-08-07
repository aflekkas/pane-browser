// spec: §1
import Foundation

/// The ONLY assertion type in the project.
///
/// Every assertion increments a counter, and a scenario reporting zero
/// assertions is a failure. This is the countermeasure to the most basic way an
/// autonomous agent fools itself: a test that passes because it asserts nothing
/// (harness design §7.1, docs/research/2026-08-07-verification.md).
///
/// Deliberately dependency-free. Neither swift-testing nor XCTest ships with
/// the Command Line Tools, and tying the gate to a full Xcode install would
/// mean the agent cannot verify its own work on a bare machine
/// (docs/api-notes/toolchain.md).
public final class Expect {
    public private(set) var assertions = 0
    public private(set) var failures: [String] = []
    private let suite: String

    public init(_ suite: String) { self.suite = suite }

    public func that(_ condition: Bool, _ what: String,
                     file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        if !condition { failures.append("\(suite): \(what)  (\(file):\(line))") }
    }

    public func equal<T: Equatable>(_ a: T, _ b: T, _ what: String,
                                    file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        if a != b { failures.append("\(suite): \(what)\n    expected: \(b)\n    actual:   \(a)  (\(file):\(line))") }
    }

    /// Fails if the suite asserted nothing — see §7.1.
    public func finish() -> Bool {
        if assertions == 0 {
            failures.append("\(suite): asserted nothing; a suite that cannot fail proves nothing")
        }
        return failures.isEmpty
    }
}

/// Collects suites and reports once.
public final class Check {
    private var suites: [(String, (Expect) -> Void)] = []
    public init() {}
    public func suite(_ name: String, _ body: @escaping (Expect) -> Void) {
        suites.append((name, body))
    }
    public func run() -> Int32 {
        var total = 0, failed = 0
        var messages: [String] = []
        for (name, body) in suites {
            let e = Expect(name)
            body(e)
            total += e.assertions
            if !e.finish() { failed += 1; messages.append(contentsOf: e.failures) }
        }
        for m in messages { print("FAIL  \(m)") }
        print("\(suites.count) suites, \(total) assertions, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
