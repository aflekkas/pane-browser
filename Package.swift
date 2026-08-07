// swift-tools-version:6.0
import PackageDescription

// Pane. SPM is the build system; Xcode is a tool, not the project (ADR 0005).
// Target split is what makes headless verification possible (ADR 0006):
// PaneCore imports nothing, so its logic is testable under `swift test`.
let package = Package(
    name: "Pane",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic. No AppKit, no WebKit. Fully unit-testable.
        .target(name: "PaneCore"),
        // The ONLY target that imports WebKit. A translator: WK delegates in,
        // WebEngineEvent out.
        .target(name: "PaneWeb", dependencies: ["PaneCore"]),
        // AppKit shell.
        .target(name: "PaneUI", dependencies: ["PaneCore", "PaneWeb"]),
        // Scenarios and benchmarks. Empty stubs without -DPANE_HARNESS.
        .target(name: "PaneHarness", dependencies: ["PaneUI"]),
        .executableTarget(name: "Pane", dependencies: ["PaneUI", "PaneHarness"]),
        // Dependency-free unit checks. Neither swift-testing nor XCTest ships
        // with the Command Line Tools; see docs/api-notes/toolchain.md.
        .executableTarget(name: "paneshot"),
        .executableTarget(name: "PaneCheck", dependencies: ["PaneCore", "PaneHarness"]),
    ]
)
