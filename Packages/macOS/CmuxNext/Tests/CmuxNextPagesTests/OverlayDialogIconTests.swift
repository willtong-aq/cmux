@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Lawrence 2026-11-09 ("here's a design that i like"): every cmux dialog leads with an icon at the left, the
/// app's own when the spec names none, and the keys read as a Mac keyboard prints them ("esc", "↩"). A web
/// page's dialog (it names its origin) never gets the app's icon, so a page cannot pose as cmux.
@MainActor
struct OverlayDialogIconTests {
    private static let appIcon = "data:image/png;base64,APPICON"

    private func wire(_ spec: CmuxDialogSpec) async throws -> JSONValue? {
        let provider = OverlayDialogProvider(defaultIcon: { Self.appIcon })
        let dialog = CmuxDialogPresentation(id: 3, spec: spec, activeLook: nil)
        provider.show(dialog)
        var state: JSONValue?
        let subscription = try await provider.subscribe("cmux.overlay.dialog.state", filter: .null,
                                                        context: PageCallContext(page: "cmux.overlay")) { state = $0 }
        return withExtendedLifetime((dialog, subscription)) { state?["dialog"] }
    }

    @Test func aCmuxDialogWithNoIconLeadsWithTheAppsIcon() async throws {
        let spec = CmuxDialogSpec(title: "Close Workspace?", buttons: [.cancel(), CmuxDialogButton(id: "close", title: "Close", role: .default)])
        let dialog = try #require(try await wire(spec))
        #expect(dialog["icon"]?.stringValue == Self.appIcon)
    }

    @Test func aWebPagesDialogNeverWearsTheAppsIcon() async throws {
        let spec = CmuxDialogSpec(title: "Leave site?", origin: "example.com",
                                  buttons: [.cancel(), CmuxDialogButton(id: "leave", title: "Leave", role: .default)])
        let dialog = try #require(try await wire(spec))
        #expect(dialog["icon"] == nil)
    }

    @Test func escapeReadsAsTheKeyboardPrintsIt() {
        #expect(CmuxDialogKeyHint.escape.glyph == "esc")
        #expect(CmuxDialogKeyHint.return.glyph == "↩")
    }
}
