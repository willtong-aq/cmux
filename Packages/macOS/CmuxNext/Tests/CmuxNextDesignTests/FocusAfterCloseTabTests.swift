@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Closing the selected tab selects as Chrome does (`TabStripModel::DetermineNewSelectedIndex`; Lawrence
/// 2026-11-09: "ensure our cmd w behavior matches chrome"; close-focus.md, Chrome table): a tab it opened, a
/// sibling, its opener, its group's neighbor, else the shown tab after it, else before it. Case ids are the table's.
struct FocusAfterCloseTabTests {
    private static func pick(_ closed: String, in old: [String], hidden: Set<String> = [], opener: [String: String] = [:],
                             group: [String: String] = [:]) -> String? {
        let surviving = old.filter { $0 != closed }
        return FocusAfterClose.tab(selected: closed, old: old, surviving: surviving, shown: Set(surviving).subtracting(hidden),
                                   opener: opener, group: group)
    }

    @Test func p1P2TheTabAfterElseTheTabBefore() {
        #expect(Self.pick("B", in: ["A", "B", "C"]) == "C")
        #expect(Self.pick("A", in: ["A", "B", "C"]) == "B")
        #expect(Self.pick("C", in: ["A", "B", "C"]) == "B")
        #expect(Self.pick("A", in: ["A"]) == nil)
    }

    @Test func p4ASurvivingSelectionStays() {
        #expect(FocusAfterClose.tab(selected: "A", old: ["A", "B"], surviving: ["A"], shown: ["A"], opener: ["B": "A"]) == "A")
    }

    @Test func o1ToO3TheOpenerFamilyFirst() {
        #expect(Self.pick("A", in: ["X", "A", "Y", "B"], opener: ["B": "A"]) == "B")              // O1: its child
        #expect(Self.pick("B", in: ["A", "B", "C", "D"], opener: ["B": "A", "D": "A"]) == "D")    // O2: its sibling
        #expect(Self.pick("B", in: ["A", "B", "X"], opener: ["B": "A"]) == "A")                   // O3: its opener
        #expect(Self.pick("B", in: ["X", "B", "Y", "A"], opener: ["B": "A"]) == "A")
    }

    @Test func g1G2GroupsAndCollapsedOnes() {
        #expect(Self.pick("C", in: ["A", "B", "C", "D"], group: ["B": "g", "C": "g"]) == "B")    // G1
        #expect(Self.pick("D", in: ["A", "B", "C", "D"], hidden: ["B", "C"]) == "A")              // G2
        #expect(Self.pick("A", in: ["A", "B", "C", "D"], hidden: ["B", "C"]) == "D")
        // None shown at all: the nearest surviving tab after, else before (its group then expands).
        #expect(Self.pick("C", in: ["A", "B", "C"], hidden: ["A", "B"]) == "B")
    }

    @Test func liveOpenersSkipTabsThatLeft() {
        // B left: C, which B opened, takes B's opener A (Chrome's FixOpeners), for where a link's tab goes.
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "B"], among: ["A", "C"]) == ["C": "A"])
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "Z"], among: ["B", "C"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "Y", "Y": "X"], among: ["A"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "A"], among: ["A"]).isEmpty)
    }

    /// Every strip of up to 5 tabs, every hidden set, every closed tab, no relations: the nearest shown tab after the
    /// closed one, else the nearest shown one before, else the nearest surviving one after, else before.
    @Test func everySmallStripPicksTheTabAfterElseBefore() {
        var checked = 0
        for count in 1...5 {
            let tabs = (0..<count).map { "t\($0)" }
            for mask in 0..<(1 << count) {
                let hidden = Set(tabs.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                for (index, closed) in tabs.enumerated() {
                    checked += 1
                    let before = tabs[..<index].reversed(), after = tabs[(index + 1)...]
                    let expected = after.first { !hidden.contains($0) } ?? before.first { !hidden.contains($0) }
                        ?? after.first ?? before.first
                    #expect(Self.pick(closed, in: tabs, hidden: hidden) == expected, "closing \(closed) of \(tabs), hidden \(hidden)")
                }
            }
        }
        #expect(checked > 200)
    }
}
