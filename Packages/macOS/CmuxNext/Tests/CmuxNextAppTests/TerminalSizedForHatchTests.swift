import AppKit
import CmuxTheme
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// While another view sets a terminal's grid smaller than this pane ("Sized for"), the pane space the
/// grid does not use is hatched as in cmux-classic (`TerminalSizeBoundsOverlayView`): 0.5 pt lines
/// rising at 45°, 8 pt apart, cut out over the grid (user, Nov 9: "we should better match cmux-classic
/// which draws a bunch of diagonal lines"). Only the chip showed before.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizedForHatchTests {
    /// The visible hatch: a shape layer of 0.5 pt lines with an even-odd mask, anywhere under `view`.
    private static func hatch(in view: NSView) -> (lines: CAShapeLayer, origin: CGPoint, owner: NSView)? {
        for sub in [view] + view.subviews {
            if sub !== view, let found = hatch(in: sub) { return found }
            guard !sub.isHiddenOrHasHiddenAncestor, let layers = sub.layer?.sublayers else { continue }
            for case let shape as CAShapeLayer in layers
            where shape.lineWidth == 0.5 && !shape.isHidden && (shape.mask as? CAShapeLayer)?.fillRule == .evenOdd {
                return (shape, .zero, sub)
            }
        }
        return nil
    }

    private static func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        var start = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: start = e.points[0]
            case .addLineToPoint: out.append((start, e.points[0]))
            default: break
            }
        }
        return out
    }

    @Test func theSpaceTheGridDoesNotUseIsHatchedLikeClassic() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = HatchScriptedIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { io.finish(); window.close() }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        io.send(.status(.connected))
        io.send(.sizedFor(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                           grid: TerminalGridSize(columns: 20, rows: 5))))
        var turns = 0
        while session.view.sizedForText == nil, turns < 20_000 { await Task.yield(); turns += 1 }
        try #require(session.view.sizedForText != nil, "the chip never showed")
        session.view.layoutSubtreeIfNeeded()

        let found = try #require(Self.hatch(in: session.view), "no hatch outside the 20×5 grid")
        let mask = try #require((found.lines.mask as? CAShapeLayer)?.path)
        let area = found.owner.bounds
        // The bottom-trailing corner is outside a 20×5 grid; a point just inside the top-leading cell is in it.
        #expect(mask.contains(CGPoint(x: area.maxX - 4, y: area.minY + 4), using: .evenOdd), "the unused corner is not hatched")
        let origin = session.view.firstCellOrigin
        #expect(!mask.contains(CGPoint(x: origin.x + 3, y: area.maxY - origin.y - 3), using: .evenOdd), "the grid is hatched over")

        // Classic's lines: rising at 45°, 8 pt apart.
        let lines = try #require(found.lines.path)
        let segments = Self.segments(lines)
        try #require(segments.count > 2)
        for (a, b) in segments.prefix(4) { #expect(abs((b.y - a.y) - (b.x - a.x)) < 0.001 && b.y > a.y) }
        #expect(segments[1].0.x - segments[0].0.x == 8)
    }

    /// The hatch reads over the terminal's own background whatever the app's appearance: a light app over a dark
    /// terminal theme drew a light-appearance divider over the dark ground, 1/255 from it (Nov 10 capture). Classic
    /// takes the divider from the terminal background (Ghostty's `split-divider-color`), so it always shows.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theHatchReadsOverTheTerminalBackground(_ appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = HatchScriptedIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        defer { io.finish(); window.close() }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        io.send(.status(.connected))
        io.send(.sizedFor(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                           grid: TerminalGridSize(columns: 20, rows: 5))))
        var turns = 0
        while session.view.sizedForText == nil, turns < 20_000 { await Task.yield(); turns += 1 }
        try #require(session.view.sizedForText != nil, "the chip never showed")
        session.view.layoutSubtreeIfNeeded()

        let found = try #require(Self.hatch(in: session.view), "no hatch outside the 20×5 grid")
        let ground = try #require(NSColor(cgColor: TerminalHostView.opaqueGround(nil))?.usingColorSpace(.sRGB))
        let ink = try #require(found.lines.strokeColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        // The line as drawn: its color at its alpha over the ground, per channel, in 0...255.
        let a = ink.alphaComponent
        let delta = [(ink.redComponent, ground.redComponent), (ink.greenComponent, ground.greenComponent),
                     (ink.blueComponent, ground.blueComponent)]
            .map { abs(($0.0 * a + $0.1 * (1 - a)) - $0.1) * 255 }.max() ?? 0
        #expect(delta >= 6, "a hatch line is \(delta)/255 from the terminal background in \(appearance.rawValue)")
    }
}

/// A scripted ``TerminalIO``: the test sends its events.
private nonisolated final class HatchScriptedIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}

/// Scratch capture (not landed): the "Sized for" pane in a light and a dark terminal theme, beside classic's
/// hatch drawn with classic's own code (TerminalSizeBoundsOverlayView.drawHatch) in the same colors.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizedForHatchShotCapture {
    private final class ClassicHatch: NSView {
        var grid: NSRect = .zero
        var color: NSColor = .gray
        var line: NSColor = .gray
        var fill: NSColor = .black
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            fill.setFill(); bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: grid).reversed)
            outside.addClip()
            let hatch = NSBezierPath()
            let spacing: CGFloat = 8
            var x = -bounds.height
            while x < bounds.width {
                hatch.move(to: NSPoint(x: x, y: bounds.height))
                hatch.line(to: NSPoint(x: x + bounds.height, y: 0))
                x += spacing
            }
            hatch.lineWidth = 0.5
            color.setStroke()
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
            line.setStroke()
            let border = NSBezierPath()
            border.move(to: NSPoint(x: grid.maxX - 0.5, y: grid.minY)); border.line(to: NSPoint(x: grid.maxX - 0.5, y: grid.maxY - 0.5))
            border.line(to: NSPoint(x: grid.minX, y: grid.maxY - 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }

    @Test func captureHatchLightAndDark() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let size = NSSize(width: 520, height: 260)
        var rows: [[NSBitmapImageRep]] = []
        for (bg, fg, look) in [(UInt32(0xFAFAFA), UInt32(0x222222), NSAppearance.Name.aqua), (0x1E1E1E, 0xD4D4D4, .darkAqua)] {
            let scope = ThemeScope(level: .room)
            scope.setOverride(try #require(ThemeSpec("Hatch Shot")),
                              input: ThemeInput(background: ThemeRGB(hex: bg), foreground: ThemeRGB(hex: fg)), animated: false)
            let io = HatchShotIO()
            let session = TerminalSession(io: io)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            root.wantsLayer = true
            root.layer?.backgroundColor = ThemeRGB(hex: bg).nsColor.cgColor
            window.contentView = root
            scope.root(root)
            session.view.frame = root.bounds
            root.addSubview(session.view)
            io.send(.status(.connected))
            io.send(.sizedFor(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                               grid: TerminalGridSize(columns: 40, rows: 9))))
            var turns = 0
            while session.view.sizedForText == nil, turns < 20_000 { await Task.yield(); turns += 1 }
            window.orderFrontRegardless()
            session.view.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            // Classic's drawing of the same grid, in the same divider color.
            let classic = ClassicHatch(frame: root.bounds)
            let scale = window.backingScaleFactor
            let cell = session.model.cellPixelSize
            let origin = session.view.firstCellOrigin
            let gw = 40 * cell.width / scale, gh = 9 * cell.height / scale
            let grid = NSRect(x: origin.x, y: size.height - origin.y - gh, width: gw, height: gh)
            classic.grid = NSRect(x: grid.minX, y: size.height - grid.maxY, width: grid.width, height: grid.height)
            var divider = NSColor.gray
            root.performWithTheme { divider = (Palette.surfaceOverride(.splitDivider) ?? Palette.separator).usingColorSpace(.sRGB) ?? .gray }
            classic.fill = ThemeRGB(hex: bg).nsColor
            classic.line = divider
            classic.color = divider.withAlphaComponent(divider.alphaComponent * 0.6)
            let classicRep = try #require(classic.bitmapImageRepForCachingDisplay(in: classic.bounds))
            classic.cacheDisplay(in: classic.bounds, to: classicRep)
            rows.append([rep, classicRep])
            print("hatch-shot: grid \(grid) divider \(divider)")
            io.finish()
            window.close()
        }
        let w = Int(size.width) * 2, h = Int(size.height) * 2, gap = 24
        let out = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2 + gap, pixelsHigh: h * 2 + gap, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w * 2 + gap, height: h * 2 + gap).fill()
        for (r, row) in rows.enumerated() {
            for (c, rep) in row.enumerated() {
                rep.draw(in: NSRect(x: (w + gap) * c, y: (h + gap) * (1 - r), width: w, height: h))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(out.representation(using: .png, properties: [:])).write(to: rootURL.appendingPathComponent("hatch-shot.png"))
    }
}

private nonisolated final class HatchShotIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    init() { (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded) }
    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}
