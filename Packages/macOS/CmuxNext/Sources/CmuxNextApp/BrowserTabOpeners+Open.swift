import CmuxNextBridge
import CmuxNextDaemon

extension BrowserTabOpeners {
    /// A page's new tab in `pane`: `create(nil)` (the end) without an
    /// opener; with one, in Chrome's slot, returning once the store shows
    /// the new tab.
    func open(_ opener: SurfaceID?, foreground: Bool, in pane: PaneModel, browserTabs: BrowserTabService,
              create: @escaping @MainActor (_ after: SurfaceID?) async throws -> SurfaceID) async throws -> SurfaceID {
        guard let opener else { return try await create(nil) }
        let daemon = browserTabs.daemonForPane(pane)
        return try await place(opener: opener, foreground: foreground,
                               order: { [weak pane] in pane?.tabs.map(\.surface) ?? [] },
                               pinned: { [weak pane] in Set(pane?.tabs.filter(\.pinned).map(\.surface) ?? []) }) { after in
            let surface = try await create(after)
            await browserTabs.settled(daemon)
            return surface
        }
    }
}
