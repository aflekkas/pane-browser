// spec: §4
import Foundation

/// Deliberate defects, planted one at a time by `--mutate <id>`.
///
/// The phase gate plants one and **fails if the suite passes** (harness design
/// §7.2). A green suite that cannot detect a planted bug proves nothing, and
/// that is a failure mode no amount of care surfaces on its own.
///
/// Definitions live in `Harness/mutants.json`; each names the scenario that
/// must catch it, so a mutant nobody catches is visible as a gap rather than
/// as silence.
///
/// Lives in PaneCore rather than PaneHarness because product code has to read
/// the flag, and PaneHarness depends on PaneUI — importing it back would be
/// circular. The flag is inert unless `--mutate` arms it, and CI greps the
/// release binary to prove harness-only symbols do not ship.
public enum Mutants {
    nonisolated(unsafe) private static var active: String?

    public static func arm(_ id: String?) { active = id }
    public static func isActive(_ id: String) -> Bool { active == id }
    public static var armed: String? { active }
}
