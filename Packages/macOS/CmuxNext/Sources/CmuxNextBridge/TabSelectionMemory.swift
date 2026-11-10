import CmuxNextCompat
import CmuxNextDesign
public import Observation

/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). When the selected tab disappears, the selection goes to
/// Chrome's successor (`FocusAfterClose.tab`: its family, else the tab after it, else before it). It also keeps the pane
/// this window last focused in each workspace (the daemon's `focused_at` is a
/// default the app never writes, focus.md 2), which a sidebar row's face reads.
///
/// Keyed (`ObservedMap`, perf-speed-of-light.md I2): reading pane X's
/// selection observes pane X only, and a selection in another pane re-runs
/// nothing that read this one. A read never writes an observed value;
/// `resolve` writes the selection only when it changes.
@MainActor @Observable
public final class TabSelectionMemory {
    private let selected = ObservedMap<String, String>()
    /// The pane last focused per workspace id: reading workspace X's observes X only.
    private let focused = ObservedMap<String, String>()
    /// The order `resolve` last saw per pane (for the neighbor after a close); never observed.
    @ObservationIgnored private var lastOrder: [String: [String]] = [:]
    /// Each tab's group per pane as `resolve` last saw it (the closed tab's group decides Chrome's group step); never observed.
    @ObservationIgnored private var lastGroups: [String: [String: String]] = [:]
    /// Bumped by every selection change in any pane: for a reader that follows
    /// all of this window's selections (one read, no walk of the panes).
    public private(set) var revision: UInt64 = 0
    /// Each pane whose selection changed since ``takeChanges()`` last ran, with its selection now; never observed.
    @ObservationIgnored private var changes: [String: String?] = [:]

    public init() {}

    private func set(_ tab: String?, in pane: String) {
        guard selected[pane] != tab else { return }
        selected[pane] = tab
        revision &+= 1
        changes.updateValue(tab, forKey: pane)
    }

    /// Each pane whose selection changed (set, replaced or dropped: nil) since the last call, with its selection
    /// now. For the one reader that keeps a copy of every selection of this window (its saved record,
    /// `WindowRecordSaver`): it applies these and reads no pane. ONE caller only: a second one would take changes
    /// that the first never sees. One entry per pane at most, so it never holds more than the panes this window
    /// selected a tab in.
    package func takeChanges() -> [String: String?] {
        guard !changes.isEmpty else { return [:] }
        var taken: [String: String?] = [:]
        swap(&taken, &changes)
        return taken
    }

    public func select(_ tab: String, in pane: String) {
        set(tab, in: pane)
    }

    public func selection(in pane: String) -> String? { selected[pane] }

    /// Records `pane` as the one this window last focused in `workspace`. A focus that stays on
    /// the same pane (every key typed into it) writes nothing, so no sidebar row re-maps.
    public func focus(_ pane: String, in workspace: String) {
        guard focused[workspace] != pane else { return }
        focused[workspace] = pane
    }

    /// Records a settled focus: `pane` in `workspace`, nothing when either is nil (no shown workspace or pane).
    public func focus(_ pane: String?, in workspace: String?) {
        guard let pane, let workspace else { return }
        focus(pane, in: workspace)
    }

    /// Takes a saved window's last focused panes (`focusedPanes` per workspace, `pane` in the `shown`
    /// workspace), so the sidebar rows show each workspace's focused tab from the first frame after a relaunch.
    public func restoreFocus(_ focusedPanes: [String: String], shown: String?, pane: String?) {
        for (workspace, pane) in focusedPanes { focus(pane, in: workspace) }
        focus(pane, in: shown)
    }

    /// The pane this window last focused in `workspace`; nil before any focus there.
    public func focusedPane(in workspace: String) -> String? { focused[workspace] }

    /// The tab to show for `pane` given its current order. Remembers the
    /// order so a later removal can pick Chrome's successor
    /// (`FocusAfterClose.tab`: a tab it opened, a sibling, its opener, else the
    /// shown tab after it, else before it; a member of a collapsed group in
    /// `hidden` is skipped while a shown tab survives). `openers` gives each
    /// link or new tab's opener by tab id, read only when the selected tab left; `groups` each grouped tab's group.
    public func resolve(pane: String, tabs: [String], defaultIndex: Int, hidden: Set<String> = [],
                        groups: [String: String] = [:], openers: () -> [String: String] = { [:] }) -> String? {
        let earlierGroups = lastGroups[pane] ?? [:]
        defer {
            lastOrder[pane] = tabs
            if groups.isEmpty { lastGroups[pane] = nil } else { lastGroups[pane] = groups }
        }
        guard !tabs.isEmpty else {
            set(nil, in: pane)
            return nil
        }
        if let current = selected[pane] {
            if tabs.contains(current) { return current }
            if let old = lastOrder[pane], old.contains(current) {
                let pick = FocusAfterClose.tab(selected: current, old: old, surviving: tabs, shown: Set(tabs).subtracting(hidden),
                                               opener: openers(), group: earlierGroups.merging(groups) { _, now in now }) ?? tabs[0]
                set(pick, in: pane)
                return pick
            }
        }
        let pick = tabs[min(max(defaultIndex, 0), tabs.count - 1)]
        set(pick, in: pane)
        return pick
    }

    /// Drops panes that no longer exist.
    public func prune(livePanes: Set<String>) {
        for pane in selected.keys where !livePanes.contains(pane) { set(nil, in: pane) }
        selected.compact { livePanes.contains($0) }
        lastOrder = lastOrder.filter { livePanes.contains($0.key) }
        lastGroups = lastGroups.filter { livePanes.contains($0.key) }
    }
}
