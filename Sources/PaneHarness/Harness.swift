// spec: §1
import Foundation

/// Compiled to a stub without -DPANE_HARNESS, so the ship build carries none of
/// this (ADR 0006). CI greps the release binary to prove it.
public enum Harness {
    public static var isCompiledIn: Bool {
        #if PANE_HARNESS
        return true
        #else
        return false
        #endif
    }

    @MainActor
    public static func runSelfTest(json: Bool) async -> Int32 {
        await Scenarios.runAll(json: json)
    }
}
