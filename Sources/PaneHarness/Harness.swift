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

    public static func runSelfTest() -> Int32 {
        #if PANE_HARNESS
        // Scenarios land in milestone B, alongside the tab model they exercise.
        FileHandle.standardOutput.write(Data(#"{"rec":"env","scenarios":0}\#n"#.utf8))
        return 0
        #else
        FileHandle.standardError.write(Data("harness not compiled in; build with -Xswiftc -DPANE_HARNESS\n".utf8))
        return 70
        #endif
    }
}
