@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextTabs
import Testing

/// Which tab a person's Cmd-W closes while closes before it are still under way
/// (``TabStripModel/cmdWTarget(_:closing:skipped:openers:)``): N quick presses close N tabs.
@MainActor @Suite
struct CmdWTargetTests {
    private static func strip(_ ids: [String], selected: String) -> TabStripModel {
        TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: $0) }, selectedID: TabID(selected))
    }

    /// A Chromium tab whose page decides its close (its beforeunload runs; the tab stays until
    /// Chromium closes the page) is closing: the next quick Cmd-W closes the tab after it, never
    /// the same tab again (which closed nothing: the page was already closing). The tab it closes is
    /// the one that close selects: Chrome's, the tab after it, else the one before it (Lawrence 2026-11-09).
    @Test func aPressWhileAPageDecidesItsCloseClosesTheTabItSelects() {
        let strip = Self.strip(["a", "b", "c"], selected: "b")
        let closing: Set<String> = ["b"]
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { closing.contains($0.rawValue) }) == StripTabID("c"))
        // The last tab closing: the one before it.
        #expect(strip.cmdWTarget(StripTabID("c"), closing: { ["b", "c"].contains($0.rawValue) }) == StripTabID("a"))
        // A link tab closing returns to its opener (Chrome's opener step).
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { closing.contains($0.rawValue) },
                                 openers: [StripTabID("b"): StripTabID("a")]) == StripTabID("a"))
        // Nothing else open: nil (the press says why).
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { _ in true }) == nil)
        // Not closing: the selected tab itself.
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { _ in false }) == StripTabID("b"))
    }

    /// The tab that close selects is the target even when it cannot close: the press then closes
    /// nothing, never another tab, which that close never selects. Home's tab cannot close: from
    /// a, b, Home with b closing, the close selects Home, so the press closes nothing.
    @Test func aPressNeverClosesATabTheCloseBeforeItDoesNotSelect() {
        var tabs = ["a", "b", "home"].map { TabItem(id: TabID($0), title: $0) }
        tabs[2].isClosable = false
        let strip = TabStripModel(tabs: tabs, selectedID: TabID("b"))
        #expect(strip.cmdWTarget(StripTabID("b"), closing: { $0.rawValue == "b" }) == nil)
        // A tab whose question shows is selected after the close too: the press closes nothing.
        let plain = Self.strip(["a", "b", "x"], selected: "b")
        #expect(plain.cmdWTarget(StripTabID("b"), closing: { $0.rawValue == "b" }, skipped: { $0.rawValue == "x" }) == nil)
        #expect(plain.cmdWTarget(StripTabID("b"), closing: { $0.rawValue == "b" }) == StripTabID("x"))
    }
}
