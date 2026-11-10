import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-11-09: "ensure our cmd w behavior matches chrome, in terms of what's the next tab that
/// should be focused to".
///
/// The rule (`FocusAfterClose.tab`, cmux-focus-core `close_focus::tab`, Chrome's
/// `DetermineNewSelectedIndex`): closing the selected tab selects a tab it opened, a sibling, its opener,
/// its group's neighbor, else the visible tab after it, else the one before it. Closing a tab that is not
/// selected keeps the selection. Case ids are close-focus.md's Chrome table. Every entry point uses it:
/// the close button, middle-click, the tab menu, Cmd-W and the CLI's close (a daemon tree change), so
/// each case here runs the app's own action or strip intent against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabCloseLikeChromeTests {
    /// One pane: its terminal tab, then `count` browser tabs. Returns the pane and the tab ids in strip order.
    static func pane(_ services: AppServices, _ connection: DaemonConnection, browsers count: Int) async throws -> (PaneController, [String], [String: SurfaceID]) {
        let store = services.daemon.store
        let content = try #require(services.windows.active?.workspaceContent)
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(services.paneController(for: model))
        let terminal = try #require(model.tabs.first)
        var surfaces: [SurfaceID] = [terminal.surface]
        for index in 0..<count {
            let tab = try await connection.newFrontendBrowserTab(url: "https://example.com/\(index)", engine: .webkit,
                                                                 in: model.handle, activate: false)
            surfaces.append(tab.surface)
        }
        try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
        var ids: [String] = []
        var surfaceOf: [String: SurfaceID] = [:]
        for surface in surfaces {
            let id = try #require(store.tab(surface: surface)).id
            ids.append(id)
            surfaceOf[id] = surface
        }
        try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue) == ids },
                                        report: { "the pane holds \(pane.orderedIDs.map(\.rawValue)), wanted \(ids)" })
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        return (pane, ids, surfaceOf)
    }

    static func select(_ id: String, in pane: PaneController) async throws {
        pane.select(TabID(id))
        try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == id })
    }

    /// Waits until `closed` is gone and `pane` selects `selected`.
    static func expect(_ pane: PaneController, _ services: AppServices, closed: [String], selects selected: String,
                               _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let store = services.daemon.store
        try await PinnedPageTests.until({ closed.allSatisfy { store.tab(id: $0) == nil } && pane.stripModel.selectedID?.rawValue == selected },
                                        report: { "\(what): the pane holds \(pane.orderedIDs.map(\.rawValue)), selects \(pane.stripModel.selectedID?.rawValue ?? "none"), wanted \(selected)" },
                                        sourceLocation: sourceLocation)
    }

    private static func cmdW(_ services: AppServices) -> Bool {
        services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
    }

    /// P1, P2, P4: the close button, the tab menu, the CLI and Cmd-W each select the tab after the closed
    /// one, the last tab the one before it; an unselected close keeps the selection.
    @Test func everyEntryPointSelectsTheTabAfter() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 4) // T b0 b1 b2 b3
            try await Self.select(ids[1], in: pane)
            pane.stripModel.send(.close(TabID(ids[1]), source: .mouse)) // the close button on b0
            try await Self.expect(pane, services, closed: [ids[1]], selects: ids[2], "the close button")
            pane.stripModel.send(.close(TabID(ids[0]), source: .contextMenu)) // the tab menu on T, not selected
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[2], "an unselected close")
            try await connection.closeTab(try #require(surface[ids[2]])) // the CLI's close of the selected b1
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[3], "the CLI's close")
            try await Self.select(ids[4], in: pane)
            #expect(Self.cmdW(services)) // Cmd-W on b3, the last tab: the one before it
            try await Self.expect(pane, services, closed: [ids[4]], selects: ids[3], "Cmd-W on the last tab")
        }
    }

    /// P5: pinned tabs are not special: the last pinned tab selects the first unpinned one after it.
    @Test func theLastPinnedTabSelectsTheFirstUnpinnedTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 3) // T b0 | b1 b2
            for id in ids.prefix(2) { try await connection.setTabPinned(try #require(surface[id]), true) }
            try await PinnedPageTests.until({ pane.stripModel.orderedTabs.prefix(2).allSatisfy(\.isPinned) && pane.orderedIDs.map(\.rawValue) == ids })
            try await Self.select(ids[1], in: pane)
            pane.stripModel.send(.close(TabID(ids[1]), source: .middleClick)) // the last pinned tab
            try await Self.expect(pane, services, closed: [ids[1]], selects: ids[2], "the last pinned tab")
        }
    }

    /// G1, G2: a grouped tab stays in its group; a collapsed group's tabs are skipped.
    @Test func groupsKeepTheirNeighbourAndSkipCollapsedOnes() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 4) // T [b0 b1] b2 b3
            let group = try #require(try await connection.createTabGroup(tabs: [surface[ids[1]], surface[ids[2]]].compactMap { $0 }).groupID)
            try await PinnedPageTests.until({ pane.stripModel.groups.count == 1 && pane.orderedIDs.map(\.rawValue) == ids })
            try await Self.select(ids[2], in: pane)
            pane.stripModel.send(.close(TabID(ids[2]), source: .mouse)) // b1, the group's last tab: b0 in its group
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[1], "the group's tab before it")
            try await Self.select(ids[0], in: pane)
            try await connection.updateTabGroup(group, collapsed: true)
            try await PinnedPageTests.until({ pane.stripModel.groups.first?.isCollapsed == true })
            pane.stripModel.send(.close(TabID(ids[0]), source: .mouse)) // T: the collapsed b0 is skipped
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[3], "past a collapsed group")
        }
    }

    /// B1: Close Tabs to the Right closing the selected tab selects the kept one; Close Other Tabs keeps it.
    @Test func closeToTheRightAndCloseOthersKeepTheRule() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 3) // T b0 b1 b2
            try await Self.select(ids[3], in: pane)
            pane.stripModel.send(.closeToRight(of: TabID(ids[1])))
            try await Self.expect(pane, services, closed: [ids[2], ids[3]], selects: ids[1], "Close Tabs to the Right")
            pane.stripModel.send(.closeOthers(keeping: TabID(ids[1])))
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[1], "Close Other Tabs")
        }
    }

    /// B2: rapid Cmd-W, each press closing the tab the close before it selected: from b1 of T b0 b1 b2,
    /// presses close b1 (b2 selected), b2 (the last: b0), then b0 (T).
    @Test func rapidCmdWClosesInChromeOrder() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 3)
            try await Self.select(ids[2], in: pane)
            for _ in 0..<3 { #expect(Self.cmdW(services)) }
            try await Self.expect(pane, services, closed: [ids[2], ids[3], ids[1]], selects: ids[0], "three quick Cmd-W")
        }
    }

    /// O5, O6: Cmd-T then Cmd-W at once returns to the tab Cmd-T was pressed on, wherever the new tab
    /// went; after the person switched away and back, the new tab's close selects by position.
    @Test func cmdTThenCmdWReturnsToTheTabItWasPressedOn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 3) // T b0 b1 b2
            try await Self.select(ids[1], in: pane)
            let before = Set(pane.pane.tabs.map(\.id))
            #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ pane.stripModel.selectedID.map { !before.contains($0.rawValue) } == true },
                                            report: { "Cmd-T selected \(pane.stripModel.selectedID?.rawValue ?? "none")" })
            let made = try #require(pane.stripModel.selectedID?.rawValue)
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: [made], selects: ids[1], "Cmd-T then Cmd-W")

            #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ pane.stripModel.selectedID.map { !before.contains($0.rawValue) } == true })
            let second = try #require(pane.stripModel.selectedID?.rawValue)
            try await Self.select(ids[3], in: pane)
            try await Self.select(second, in: pane)
            let order = pane.orderedIDs.map(\.rawValue)
            let index = try #require(order.firstIndex(of: second))
            let expected = index + 1 < order.count ? order[index + 1] : order[index - 1]
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: [second], selects: expected, "Cmd-T, away and back, Cmd-W")
        }
    }

    /// O3, O7: a link tab returns to its opener when closed before the person looked elsewhere; after a
    /// switch to an unrelated tab the relation is gone and the close selects by position.
    @Test func aLinkTabReturnsToItsOpenerUntilAnUnrelatedSwitch() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 3) // T b0 b1 b2
            let openers = services.cache.pageRequests.openers
            // b2 opened from b0 (a page's link) and shown: closing it returns to b0, not to b1 before it.
            // (Selected first: the person's switch onto it from an unrelated tab would forget the relation.)
            try await Self.select(ids[3], in: pane)
            openers.adopt(try #require(surface[ids[3]]), opener: try #require(surface[ids[1]]))
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: [ids[3]], selects: ids[1], "a link tab back to its opener")

            // b1 opened from T; the person moves onto it from b0, which is not its opener: Chrome forgets
            // every relation on that switch, so the close selects by position (b0, before the last tab).
            openers.adopt(try #require(surface[ids[2]]), opener: try #require(surface[ids[0]]))
            try await Self.select(ids[2], in: pane)
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[1], "after an unrelated switch")
        }
    }
}
