import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import Testing

/// Every dialog (JavaScript alert, confirm, prompt, Leave site?, HTTP sign-in, the app's confirms) draws on
/// this one card, in the overlay panel: a clear window over the page's own window.
///
/// Lawrence 2026-11-09, on the frosted card: "i need to be able to see liquid glass effect". Liquid Glass
/// in the clear panel bends the page's window behind it (a child window over a child window, measured on
/// macOS 27): the flat look was the blur and the veil painted over it, not the glass. The card is the
/// sheet's Liquid Glass where this Mac draws it; Reduce Transparency keeps the opaque surface.
@MainActor
struct OverlayDialogCardTests {
    @Test func theCardIsTheSheetsLiquidGlassWhereThisMacDrawsIt() {
        let card = OverlayDialogCard(activeLook: nil)
        let sheet = Glass.makeSurface(.sheet, content: NSView())
        #expect(card.glass.material == sheet.material, "the sheet's material on this Mac")
        if Glass.isLiquidGlassAvailable, !ReduceTransparency.shared.isEnabled {
            #expect(card.glass.material == .liquidGlass, "Liquid Glass, never the frosted blur")
        }
        #expect(card.glass.samplesBehindWindow, "the blur (macOS 14 and 15) samples the page behind the window")
    }

    @Test func theCardCastsThePopupShadowAtItsOwnRoundedRect() throws {
        let card = OverlayDialogCard(activeLook: nil)
        card.frame = NSRect(x: 40, y: 30, width: 380, height: 150)
        card.layoutSubtreeIfNeeded()
        let shadow = try #require(card.shadowLayer)
        let elevation = PopupStyle.standard.elevation
        #expect(shadow.shadowOpacity == Float(elevation.alpha))
        #expect(shadow.shadowRadius == elevation.layerRadius)
        #expect(shadow.shadowOffset == elevation.layerOffset())
        // The shadow follows the card's rect and corner, and the cutout keeps it off the glass.
        // One radius: the shadow's corner is the glass's.
        let radius = card.glass.cornerRadius
        #expect(shadow.shadowPath == CGPath(roundedRect: card.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        #expect(card.glass.frame == card.bounds)
        let cutout = try #require(shadow.mask as? CAShapeLayer)
        #expect(cutout.fillRule == .evenOdd)
        #expect(cutout.path?.contains(CGPoint(x: card.bounds.midX, y: card.bounds.midY), using: .evenOdd) == false)
        #expect(cutout.path?.contains(CGPoint(x: card.bounds.midX, y: -elevation.offset), using: .evenOdd) == true)
    }
}
