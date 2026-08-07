// spec: §3
import Foundation
import PaneCore
import PaneHarness

/// spec §3 spaces and profiles, headless.
public func spaceChecks(_ check: Check) {
    check.suite("SpaceModel — a space always has a profile") { e in
        var m = SpaceModel()
        let s = m.addSpace(named: "Work")
        e.that(m.profile(for: s) != nil, "the new space resolves to a profile")
        e.equal(m.current, s.id, "the first space becomes current")
        e.that(m.profile(for: s)?.dataStoreUUID != nil,
               "the profile carries a data-store UUID — this is what makes isolation real")
    }

    check.suite("SpaceModel — two spaces may share one profile") { e in
        // spec §3: "'Work' and 'Work Admin' wanting the same Google login is a
        // real case."
        var m = SpaceModel()
        let work = m.addSpace(named: "Work")
        let admin = m.addSpace(named: "Work Admin", sharingProfileWith: work)
        e.equal(admin.profileID, work.profileID, "sharing reuses the profile")
        e.equal(m.profiles.count, 1, "and does not create a second one")
        let personal = m.addSpace(named: "Personal")
        e.that(personal.profileID != work.profileID, "an unshared space gets its own")
        e.equal(m.profiles.count, 2, "two profiles for three spaces")
    }

    check.suite("SpaceModel — rename") { e in
        var m = SpaceModel()
        let s = m.addSpace(named: "Untitled")
        m.rename(s.id, to: "  Research  ")
        e.equal(m.spaces.first?.name, "Research", "renaming trims whitespace")
        e.equal(m.profiles[s.profileID]?.name, "Research",
                "a solely-owned profile follows the space name")
        m.rename(s.id, to: "   ")
        e.equal(m.spaces.first?.name, "Research", "an all-whitespace rename is rejected")
    }

    check.suite("SpaceModel — renaming a shared space leaves the profile alone") { e in
        var m = SpaceModel()
        let work = m.addSpace(named: "Work")
        _ = m.addSpace(named: "Work Admin", sharingProfileWith: work)
        m.rename(work.id, to: "Day Job")
        e.equal(m.profiles[work.profileID]?.name, "Work",
                "a shared profile keeps its name — renaming one space must not rename the other's identity")
    }

    check.suite("SpaceModel — icons") { e in
        var m = SpaceModel()
        let s = m.addSpace(named: "Work")
        e.that(s.icon == nil, "spaces start with no icon")
        m.setIcon(s.id, to: "briefcase")
        e.equal(m.spaces.first?.icon, "briefcase", "icon is set")
        m.setIcon(s.id, to: nil)
        e.that(m.spaces.first?.icon == nil, "icon can be cleared")
        e.that(SpaceModel.iconChoices.contains("briefcase"), "the offered set is fixed and small")
    }

    check.suite("SpaceModel — never leaves zero spaces") { e in
        var m = SpaceModel()
        let a = m.addSpace(named: "One")
        m.removeSpace(a.id)
        e.equal(m.spaces.count, 1, "deleting the only space is refused")
        let b = m.addSpace(named: "Two")
        m.removeSpace(a.id)
        e.equal(m.spaces.count, 1, "deleting one of two works")
        e.equal(m.current, b.id, "and current moves to a surviving space")
    }

    check.suite("SpaceModel — cycling wraps") { e in
        var m = SpaceModel()
        let a = m.addSpace(named: "A")
        let b = m.addSpace(named: "B")
        let c = m.addSpace(named: "C")
        m.select(a.id)
        m.cycle(by: 1);  e.equal(m.current, b.id, "next")
        m.cycle(by: 1);  e.equal(m.current, c.id, "next again")
        m.cycle(by: 1);  e.equal(m.current, a.id, "wraps forward past the end")
        m.cycle(by: -1); e.equal(m.current, c.id, "wraps backward past the start")
    }

    check.suite("SpaceModel — reorder") { e in
        var m = SpaceModel()
        let a = m.addSpace(named: "A")
        _ = m.addSpace(named: "B")
        _ = m.addSpace(named: "C")
        m.move(a.id, to: 2)
        e.equal(m.spaces.map(\.name), ["B", "C", "A"], "moved to the end")
        e.equal(m.spaces.map(\.sortIndex), [0, 1, 2], "sort indices are renumbered")
    }

    check.suite("SpaceModel — teardown eligibility (spec §3)") { e in
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        e.that(!SpaceModel.isTeardownEligible(lastActive: t0, allTabsDiscarded: true,
                                              isCurrent: true, now: t0.addingTimeInterval(3600)),
               "the current space is never torn down, however old")
        e.that(!SpaceModel.isTeardownEligible(lastActive: t0, allTabsDiscarded: false,
                                              isCurrent: false, now: t0.addingTimeInterval(3600)),
               "a space with live tabs is never torn down")
        e.that(!SpaceModel.isTeardownEligible(lastActive: t0, allTabsDiscarded: true,
                                              isCurrent: false, now: t0.addingTimeInterval(60)),
               "not before the 10-minute threshold")
        e.that(SpaceModel.isTeardownEligible(lastActive: t0, allTabsDiscarded: true,
                                             isCurrent: false, now: t0.addingTimeInterval(601)),
               "eligible once inactive 10 minutes with all tabs discarded")
    }
}
