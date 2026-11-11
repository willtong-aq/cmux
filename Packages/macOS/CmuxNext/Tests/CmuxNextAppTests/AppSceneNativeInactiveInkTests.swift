import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The native renderer's progress bar and menu chevron against the SwiftUI controls they replaced
/// (native-controls Before|After, controls-tour-full, 2026-11-09 and 2026-11-11). In a window that is
/// not key the SwiftUI bar drew its done part an opaque grey, (170, 170, 170) in light and dark; the
/// native bar painted the primary ink, then the tertiary ink ((130, 130, 130) light, (131, 131, 131)
/// dark). The SwiftUI borderless pull-down drew its chevron in its title's tone (title 36, chevron 39
/// in light); the native one stayed lighter (title 0, chevron 62). Pixels are read the way a capture
/// reads them: each control's layer rendered at 1x, over white.
@MainActor @Suite(.serialized, .closesItsWindows) struct AppSceneNativeInactiveInkTests {
    private static func host(_ appearance: NSAppearance.Name = .aqua) -> (NSWindow, AppSceneHostingView) {
        let model = AppSceneModel()
        model.apply([
            .create(id: "col", type: "VStack", props: ["spacing": 6]),
            .create(id: "bar", type: "ProgressView", props: ["value": 0.6]),
            .create(id: "sort", type: "Menu", props: ["title": "Sort", "menu": .array([["title": "Newest"]])]),
            .children(id: "col", children: ["bar", "sort"]),
            .root(id: "col"),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, hosting)
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// The darkest luminance (0 black, 1 white) in `view`'s layer, rendered at 1x (as the capture
    /// minis' displays draw) over white, in the horizontal span `from`..`to` (fractions of its width).
    private static func darkest(_ view: NSView, from: CGFloat = 0, to: CGFloat = 1) -> CGFloat? {
        view.needsDisplay = true
        view.displayIfNeeded()
        guard let layer = view.layer else { return nil }
        layer.displayIfNeeded()
        let scale: CGFloat = 1
        let w = max(1, Int(ceil(view.bounds.width * scale))), h = max(1, Int(ceil(view.bounds.height * scale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var best: CGFloat = 1
        for y in 0..<h {
            for x in Int(CGFloat(w) * from)..<Int(CGFloat(w) * to) {
                let p = data + (y * w + x) * 4
                let lum = (0.299 * CGFloat(p[0]) + 0.587 * CGFloat(p[1]) + 0.114 * CGFloat(p[2])) / 255
                best = min(best, lum)
            }
        }
        return best
    }

    /// Luminance of a layer color composited over `base` (both read in the same theme).
    private static func over(_ color: CGColor?, _ base: CGColor) -> CGFloat? {
        func rgba(_ c: CGColor) -> [CGFloat]? {
            guard let n = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return nil }
            return [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent]
        }
        guard let color, let f = rgba(color), let b = rgba(base) else { return nil }
        let mix = (0..<3).map { f[$0] * f[3] + b[$0] * (1 - f[3]) }
        return 0.299 * mix[0] + 0.587 * mix[1] + 0.114 * mix[2]
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aBarInAWindowThatIsNotKeyFillsAppKitsInactiveGrey(_ appearance: NSAppearance.Name) throws {
        let (window, hosting) = Self.host(appearance)
        defer { window.contentView = nil; window.close() }
        try #require(!window.isKeyWindow, "fixture: the test window is not key")
        let bar = try #require(Self.all(hosting).first { $0 is AppSceneProgressNSView })
        bar.needsDisplay = true
        bar.displayIfNeeded()
        let layers = (bar.layer?.sublayers ?? []).filter { $0.cornerRadius > 0 && $0.frame.height > 0 }.sorted { $0.frame.width < $1.frame.width }
        let done = try #require(layers.first)
        // A ground of each appearance's sidebar tone: a translucent fill would show it, an opaque one not.
        let base = appearance == .darkAqua ? CGColor(gray: 0.15, alpha: 1) : CGColor(gray: 0.95, alpha: 1)
        let fill = try #require(Self.over(done.backgroundColor, base))
        // AppKit's inactive bar: an opaque (170, 170, 170) on any ground, in light and dark.
        #expect(abs(fill - 170.0 / 255) < 0.02, "the done part composites to \(fill * 255), not AppKit's inactive 170")
    }

    @Test func aMenuChevronTakesItsTitlesTone() throws {
        let (window, hosting) = Self.host()
        defer { window.contentView = nil; window.close() }
        let menu = try #require(Self.all(hosting).first { $0 is AppSceneMenuNSView })
        let chevron = try #require(menu.subviews.first { $0 is NSImageView })
        let title = try #require(menu.subviews.first { !($0 is NSImageView) })
        let chevronInk = try #require(Self.darkest(chevron)), titleInk = try #require(Self.darkest(title))
        #expect(titleInk < 0.5, "fixture: the title drew: \(titleInk)")
        // The SwiftUI pull-down: title 36, chevron 39. A chevron whose stroke never covers a whole pixel
        // at 1x stays lighter than its title however it is tinted.
        #expect(abs(chevronInk - titleInk) < 0.1, "chevron \(chevronInk * 255), title \(titleInk * 255)")
    }
}
