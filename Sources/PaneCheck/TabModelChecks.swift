// spec: §4
import Foundation
import PaneCore
import PaneHarness

/// spec §4 lifecycle, exercised headlessly. Milestone B's gate requires every
/// transition covered, including all four never-discard conditions.
public func tabModelChecks(_ check: Check) {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let url = URL(string: "https://example.com")!

    check.suite("TabModel — sections") { e in
        var m = TabModel()
        m.open(Tab(kind: .essential, url: url))
        m.open(Tab(kind: .pinned, url: url))
        m.open(Tab(kind: .ephemeral, url: url))
        m.open(Tab(kind: .ephemeral, url: url))
        e.equal(m.section(.essential).count, 1, "essentials section")
        e.equal(m.section(.pinned).count, 1, "pinned section")
        e.equal(m.section(.ephemeral).count, 2, "today section")
        e.equal(m.tabs.count, 4, "all tabs present")
    }

    check.suite("TabModel — open and select") { e in
        var m = TabModel()
        let a = m.open(Tab(url: url))
        e.equal(m.selected, a, "opening selects by default")
        let b = m.open(Tab(url: url), select: false)
        e.equal(m.selected, a, "select:false leaves selection alone")
        m.select(b, at: t0)
        e.equal(m.selected, b, "select moves selection")
        e.equal(m[b]?.lastActiveAt, t0, "selecting touches lastActiveAt")
    }

    check.suite("TabModel — close selects a neighbour") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .pinned, url: url))
        let b = m.open(Tab(kind: .pinned, url: url))
        let c = m.open(Tab(kind: .pinned, url: url))
        m.select(b)
        m.close(b)
        e.that(m.selected != nil, "closing the selected tab does not clear selection")
        e.equal(m.selected, c, "selection falls to the next tab in the section")
        m.close(a); m.close(c)
        e.that(m.selected == nil, "closing the last tab leaves nothing selected")
    }

    check.suite("TabModel — reopen closed") { e in
        var m = TabModel()
        let a = m.open(Tab(url: url, title: "Gone"))
        m.close(a)
        e.equal(m.tabs.count, 0, "closed tab is gone")
        let reopened = m.reopenLastClosed()
        e.that(reopened != nil, "reopen returns an id")
        e.equal(m.tabs.count, 1, "reopened tab is back")
        e.equal(m.tabs.first?.title, "Gone", "reopen preserves the title")
        e.that(m.reopenLastClosed() == nil, "reopening an empty stack is a no-op")
    }

    check.suite("TabModel — reorder") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .pinned, title: "a"))
        _ = m.open(Tab(kind: .pinned, title: "b"))
        _ = m.open(Tab(kind: .pinned, title: "c"))
        m.move(a, toIndex: 2, in: .pinned)
        e.equal(m.section(.pinned).map { $0.title ?? "" }, ["b", "c", "a"],
                "moving to the end reorders the section")
        m.move(a, toIndex: 0, in: .pinned)
        e.equal(m.section(.pinned).map { $0.title ?? "" }, ["a", "b", "c"],
                "moving back to the front reorders again")
    }

    check.suite("TabModel — cross-section move changes kind") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .ephemeral, title: "a"))
        m.move(a, toIndex: 0, in: .pinned)
        e.equal(m[a]?.kind, .pinned, "dragging into pinned repins the tab")
        e.equal(m.section(.ephemeral).count, 0, "and removes it from today")
    }

    // ---- spec §4 lifecycle ----

    check.suite("Lifecycle — idle thresholds per kind") { e in
        var m = TabModel()
        let eph = m.open(Tab(kind: .ephemeral, lastActiveAt: t0), select: false)
        let pin = m.open(Tab(kind: .pinned, lastActiveAt: t0), select: false)
        e.equal(m.discardCandidates(at: t0.addingTimeInterval(60)).count, 0,
                "nothing discards after 1 minute")
        let after6m = m.discardCandidates(at: t0.addingTimeInterval(6 * 60))
        e.that(after6m.contains(eph), "ephemeral discards after 5 minutes")
        e.that(!after6m.contains(pin), "pinned does not discard at 6 minutes")
        let after16m = m.discardCandidates(at: t0.addingTimeInterval(16 * 60))
        e.that(after16m.contains(pin), "pinned discards after 15 minutes")
    }

    check.suite("Lifecycle — the selected tab never discards") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .ephemeral, lastActiveAt: t0))
        e.equal(m.selected, a, "precondition: it is selected")
        e.that(!m.discardCandidates(at: t0.addingTimeInterval(3600)).contains(a),
               "the tab the user is looking at is never a candidate, at any age")
    }

    // The four never-discard conditions from spec §4, one check each so a
    // regression names which condition broke.
    check.suite("Lifecycle — never discard: playing audio") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .ephemeral, lastActiveAt: t0, isPlayingAudio: true), select: false)
        e.that(!m.discardCandidates(at: t0.addingTimeInterval(3600)).contains(a),
               "a tab playing audio is never discarded")
    }
    check.suite("Lifecycle — never discard: active MediaSession") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .ephemeral, lastActiveAt: t0, hasActiveMediaSession: true), select: false)
        e.that(!m.discardCandidates(at: t0.addingTimeInterval(3600)).contains(a),
               "a tab with an active MediaSession is never discarded")
    }
    check.suite("Lifecycle — never discard: unsaved form state") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .ephemeral, lastActiveAt: t0, hasUnsavedFormState: true), select: false)
        e.that(!m.discardCandidates(at: t0.addingTimeInterval(3600)).contains(a),
               "a tab with a beforeunload handler and unsaved state is never discarded")
    }
    check.suite("Lifecycle — never discard: explicitly nailed by the user") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .pinned, lastActiveAt: t0, userPinnedExplicitly: true), select: false)
        e.that(!m.discardCandidates(at: t0.addingTimeInterval(3600)).contains(a),
               "a tab the user explicitly nailed is never discarded")
    }

    check.suite("Lifecycle — state transitions") { e in
        var m = TabModel()
        let a = m.open(Tab(kind: .ephemeral, lastActiveAt: t0), select: false)
        e.equal(m[a]?.lifecycle, .live, "tabs start live")
        m.markDiscarded(a)
        e.equal(m[a]?.lifecycle, .discarded, "live -> discarded")
        e.equal(m.discardCandidates(at: t0.addingTimeInterval(3600)).count, 0,
                "an already-discarded tab is not a candidate again")
        m.markLive(a, at: t0.addingTimeInterval(3600))
        e.equal(m[a]?.lifecycle, .live, "discarded -> live on restore")
        e.equal(m[a]?.lastActiveAt, t0.addingTimeInterval(3600),
                "restoring resets the idle clock, so it is not instantly re-discarded")
    }

    check.suite("Lifecycle — essentials restore to their home URL") { e in
        let home = URL(string: "https://mail.example.com")!
        let wandered = URL(string: "https://mail.example.com/thread/9931")!
        let ess = Tab(kind: .essential, url: wandered, homeURL: home)
        e.equal(ess.restoreURL, home, "an essential restores to its pinned URL, not where it wandered")
        let pin = Tab(kind: .pinned, url: wandered, homeURL: home)
        e.equal(pin.restoreURL, wandered, "every other kind restores where it actually was")
    }

    check.suite("Tab — display name falls back sensibly") { e in
        e.equal(Tab(url: url, title: "Real Title").displayName, "Real Title", "title wins")
        e.equal(Tab(url: url, title: "").displayName, "example.com", "empty title falls back to host")
        e.equal(Tab().displayName, "New Tab", "no title and no url falls back to New Tab")
    }
}
