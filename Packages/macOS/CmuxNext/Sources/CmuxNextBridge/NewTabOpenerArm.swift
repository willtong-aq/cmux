public import CmuxNextDaemon

/// A person's new tab press (Cmd-T, the +) waiting for its tab: the tab they were on (`opener`) becomes the new
/// tab's opener once the pane selects a tab that was not there at the press (`before`), as Chrome's typed new tab
/// inherits its opener (`TabStripModel::AddWebContents`). A stand-in tab and the daemon's tab that replaces it are
/// each recorded in turn. It ends when the person selects a tab, presses again, or the pane is back on a tab from
/// before the press after one was recorded (the new tab closed).
public struct NewTabOpenerArm: Sendable {
    /// The tab selected at the press.
    public let opener: SurfaceID
    /// The pane's tab ids at the press.
    public let before: Set<String>
    /// A new tab took the opener already.
    public private(set) var recorded = false

    /// A press made while `opener` was selected among the tabs `before`.
    ///
    /// - Parameters:
    ///   - opener: The selected tab's surface at the press.
    ///   - before: The pane's tab ids at the press.
    public init(opener: SurfaceID, before: Set<String>) {
        self.opener = opener
        self.before = before
    }

    /// Reads the pane's selection after a strip apply: a new tab selected (`selected`, its `surface`) takes the
    /// opener in `openers`.
    ///
    /// - Parameters:
    ///   - selected: The tab id the pane selects now.
    ///   - surface: That tab's surface, when the pane has it.
    ///   - openers: The opener model that records the relation.
    /// - Returns: The arm still waiting, or `nil` once the press has ended.
    public func applied(selected: String, surface: SurfaceID?, openers: BrowserTabOpeners) -> NewTabOpenerArm? {
        if before.contains(selected) { return recorded ? nil : self }
        guard let surface else { return self }
        openers.newTab(surface, from: opener)
        var next = self
        next.recorded = true
        return next
    }
}
