public import CmuxNextDaemon
import CmuxNextDesign

/// Where a page's new tab goes, in Chrome's order (cx-d0d.19,
/// plans/cmux-next/browser-parity.md Rank 1). This is Chromium's
/// `TabStripModel` opener model, rule for rule:
///
/// - Every link tab records its opener (`TabModel::opener`).
/// - A foreground tab goes right after the opener and first forgets every
///   relation (`ForgetAllOpeners`), then records its own.
/// - A background tab goes after the run of the opener's descendants
///   (children, grandchildren...) that directly follows the opener; the run
///   ends at the first tab outside the family, pinned tabs skipped
///   (`GetIndexOfLastWebContentsOpenedBy`). No run: right after the opener.
/// - A tab that leaves the pane hands its children its own opener
///   (`FixOpeners`).
/// - A user switch between tabs that are not opener and child or siblings
///   (two tabs with the same opener; no opener is not one) forgets every
///   relation (`SetSelection` with a user gesture), and so
///   does a typed navigation (`TabNavigating`), except a new tab page at the
///   end of the strip.
///
/// - A person's new tab (Cmd-T, the +) records the tab they were on as its
///   opener, after forgetting every relation, and loses it as soon as they
///   switch away from it (`AddWebContents`' quick look-up,
///   `reset_opener_on_active_tab_change`): Cmd-T then Cmd-W returns there.
///
/// The close rule reads these relations for every tab kind
/// (`FocusAfterClose.tab`, Chrome's `DetermineNewSelectedIndex`).
///
/// The daemon commits the tab in the slot (`frontend-browser-insert-after-v1`);
/// this type only names it. Placements for one opener run one at a time:
/// the next slot depends on the tab the previous one made, and the caller's
/// `create` returns only once the store shows that tab
/// (`BrowserTabService.settled`).
public final class BrowserTabOpeners {
    /// Each link tab's opener, by surface.
    public private(set) var openerOf: [SurfaceID: SurfaceID] = [:]
    /// New tabs whose opener goes once the person switches away from them (``newTab(_:from:)``).
    private var resetOnSwitch: Set<SurfaceID> = []
    /// The placement each opener's next one waits for.
    private var queue: [SurfaceID: Task<SurfaceID, any Error>] = [:]
    /// A page's new tab exists (child, opener): the browser host reports it
    /// as `tab.created`, so an agent driving the opener sees its popup.
    public var onChildPlaced: ((SurfaceID, SurfaceID) -> Void)?
    /// Runs first for each placed child (child, opener): the App marks the
    /// child agent-driven when its opener is (`BrowserPageRequests`).
    public var inheritsFromOpener: ((SurfaceID, SurfaceID) -> Void)?

    /// An opener model with no relations.
    public init() {}

    /// Creates the opener's new tab through `create(after)` in Chrome's slot
    /// and records the opener. `order` is the pane's tab order (surfaces) as
    /// the store shows it now; `pinned` its pinned tabs.
    public func place(opener: SurfaceID, foreground: Bool, order: @escaping @MainActor () -> [SurfaceID],
               pinned: @escaping @MainActor () -> Set<SurfaceID> = { [] },
               create: @escaping @MainActor (_ after: SurfaceID) async throws -> SurfaceID) async throws -> SurfaceID {
        let previous = queue[opener]
        let placing = Task { [weak self] () async throws -> SurfaceID in
            // A failed earlier placement does not stop this one.
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            let after = foreground ? opener : self.slot(after: opener, in: order(), pinned: pinned())
            let child = try await create(after)
            if foreground { self.forgetAll() }
            if child != opener {
                self.openerOf[child] = opener
                self.inheritsFromOpener?(child, opener)
                self.onChildPlaced?(child, opener)
            }
            return child
        }
        queue[opener] = placing
        defer { if queue[opener] == placing { queue[opener] = nil } }
        return try await placing.value
    }

    /// The tab a background child goes after: the last tab of the run of
    /// the opener's descendants that directly follows it, else the opener.
    public func slot(after opener: SurfaceID, in order: [SurfaceID], pinned: Set<SurfaceID> = []) -> SurfaceID {
        reconcile(with: order)
        guard let start = order.firstIndex(of: opener) else { return opener }
        var family: Set<SurfaceID> = [opener]
        var last: SurfaceID?
        for tab in order[order.index(after: start)...] {
            guard let parent = openerOf[tab], family.contains(parent) else {
                // New tabs go after pinned tabs: a pinned tab never ends the run.
                if pinned.contains(tab) { continue }
                break
            }
            family.insert(tab)
            last = tab
        }
        return last ?? opener
    }

    /// The user moved from tab `old` to tab `new` in a pane: every relation
    /// is forgotten unless one is the other's opener or both share one.
    /// Two tabs without an opener are not siblings: moving between them
    /// forgets too, so a page's next background tab goes right of it.
    public func userActivated(from old: SurfaceID?, to new: SurfaceID?) {
        let oldOpener = old.flatMap { openerOf[$0] }
        // A person's new tab forgets its opener on any switch away (`OnActiveTabChanged`'s `ForgetOpener`).
        if let old, resetOnSwitch.remove(old) != nil { openerOf[old] = nil }
        let newOpener = new.flatMap { openerOf[$0] }
        let siblings = oldOpener != nil && oldOpener == newOpener
        let openerAndChild = (old != nil && newOpener == old) || (new != nil && oldOpener == new)
        if !siblings && !openerAndChild { forgetAll() }
    }

    /// A tab navigated by a typed URL: the user starts another task, so
    /// every relation is forgotten, except in a new tab page that is the
    /// last tab of its pane (a quick look-up keeps them for one navigation).
    public func typedNavigation(onNewTabPageAtEnd: Bool) {
        if !onNewTabPageAtEnd { forgetAll() }
    }

    /// Forgets every opener relation.
    public func forgetAll() {
        openerOf.removeAll()
        resetOnSwitch.removeAll()
    }

    /// A person's new tab `child` (Cmd-T, the +) made while `opener` was selected: Chrome's typed new tab inherits the
    /// opener (`ADD_INHERIT_OPENER`, foreground: every other relation forgotten first) until the person switches away.
    public func newTab(_ child: SurfaceID, from opener: SurfaceID) {
        guard child != opener, openerOf[child] != opener else { return }
        forgetAll()
        openerOf[child] = opener
        resetOnSwitch.insert(child)
    }

    /// A foreground page tab (the GitHub page) a link made outside ``place``: Chrome's foreground rule (its next link tab goes beside it).
    public func adopt(_ child: SurfaceID, opener: SurfaceID) {
        forgetAll()
        openerOf[child] = opener
    }

    /// The relations among one pane's tabs by tab id, for the close rule (`FocusAfterClose.tab`): `ids` names each
    /// surface's tab (the pane's tabs now, plus those of its last apply, so a tab that just closed keeps its relations,
    /// as Chrome reads them before the removal).
    ///
    /// - Parameter ids: Each surface's tab id.
    /// - Returns: Each child tab's opener tab, both by tab id; relations naming a surface outside `ids` are left out.
    public func relations(byTabID ids: [SurfaceID: String]) -> [String: String] {
        var openers: [String: String] = [:]
        for (child, parent) in openerOf {
            if let child = ids[child], let parent = ids[parent] { openers[child] = parent }
        }
        return openers
    }

    /// Tabs the pane no longer shows (closed, moved away) leave the tree;
    /// their children take their opener (`FixOpeners`).
    private func reconcile(with order: [SurfaceID]) {
        openerOf = FocusAfterClose.liveOpeners(openerOf, among: order)
    }
}
