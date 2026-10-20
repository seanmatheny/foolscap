import Testing
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

@Suite @MainActor struct EditorSizingTests {
    @Test func textViewGrowsBeyondTheVisibleHeight() {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText((1...120).map { "Line \($0)" }.joined(separator: "\n"))
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scroll.documentView = view
        view.minSize = NSSize(width: 0, height: 200)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.sizeToFit()
        #expect(view.frame.height > 1000, "frame height was \(view.frame.height)")
    }
}

/// The page's decorations draw through `EditorDecorations` into a bare `CGContext`
/// (no `NSGraphicsContext`), as the iOS view will hand them one.
@Suite @MainActor struct RulingDrawTests {
    static let width = 600, height = 400

    /// A clear RGBA bitmap with the view's coordinates (origin top left, y down).
    private func bitmap() throws -> CGContext {
        let ctx = try #require(CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                         bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(Self.height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    private func view(_ text: String, ruling: Ruling) -> MarkdownTextView {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText(text)
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: NotebookTheme.classicBlack.ruled(ruling, marginRule: true)))
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        return view
    }

    /// The RGBA bytes of one pixel, in view coordinates (the bitmap's first row is
    /// its top, where the flipped context puts y = 0).
    private func pixel(_ ctx: CGContext, x: Int, y: Int) -> [UInt8] {
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let p = bytes + y * ctx.bytesPerRow + x * 4
        return [p[0], p[1], p[2], p[3]]
    }

    private func paintedPixels(_ ctx: CGContext) -> Int {
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var n = 0
        for i in stride(from: 3, to: Self.width * Self.height * 4, by: 4) where bytes[i] != 0 { n += 1 }
        return n
    }

    /// A scroll bouncing past the top asks for a rect wholly above the first rule;
    /// the ruling loop used to build `0...-3` there and trap.
    @Test func drawingAboveTheFirstRuleDoesNotTrap() throws {
        for ruling in [Ruling.lined, .grid, .dotted] {
            let view = view("one\ntwo\n", ruling: ruling)
            let ctx = try bitmap()
            EditorDecorations(geometry: view).drawUnderText(in: ctx, rect: CGRect(x: 0, y: -400, width: 600, height: 20))
            #expect(paintedPixels(ctx) == 0)
        }
    }

    /// Each ruling paints rules of its own shape on an otherwise clear page.
    @Test func eachRulingReachesTheBitmap() throws {
        var painted: [Ruling: Int] = [:]
        for ruling in [Ruling.lined, .grid, .dotted] {
            let view = view("one\ntwo\n", ruling: ruling)
            let ctx = try bitmap()
            EditorDecorations(geometry: view).drawUnderText(in: ctx, rect: view.bounds)
            painted[ruling] = paintedPixels(ctx)
        }
        #expect(painted[.lined]! > 0 && painted[.grid]! > 0 && painted[.dotted]! > 0)
        #expect(painted[.grid]! > painted[.lined]!, "a grid has columns as well as rules")
        #expect(painted[.dotted]! < painted[.lined]!, "dots cover less than rules")
    }

    /// A fenced block gets an opaque backdrop in the palette's code colour, over the ruling.
    @Test func fencedBlockGetsItsBackdrop() throws {
        let view = view("one\n```swift\nlet x = 1\n```\nthree\n", ruling: .lined)
        let blocks = view.decorations(in: view.bounds)
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.kind == .code(language: "swift"))
        let ctx = try bitmap()
        EditorDecorations(geometry: view).drawUnderText(in: ctx, rect: view.bounds)
        let got = pixel(ctx, x: Int(block.rect.midX), y: Int(block.rect.midY))
        let want = try #require(view.palette.codeBlockBackground.usingColorSpace(.sRGB))
        let expected = [want.redComponent, want.greenComponent, want.blueComponent, want.alphaComponent].map { Int(($0 * 255).rounded()) }
        for (g, w) in zip(got, expected) { #expect(abs(Int(g) - w) <= 3, "pixel \(got) is not the code backdrop \(expected)") }
        // The ruling alone is translucent: the backdrop made that pixel opaque.
        #expect(got[3] == 255)
    }
}

@Suite @MainActor struct CaretSkipTests {
    @Test func caretStepsOverCollapsedImageLines() {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("one\n![pic](a.png)\nthree\n")          // lines at 0, 4, 18
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: 8, length: 0))   // click inside the image line, moving forward
        #expect(view.selectedRange().location == 18)             // start of "three"
        view.setSelectedRange(NSRange(location: 21, length: 0))
        view.setSelectedRange(NSRange(location: 10, length: 0))  // moving backward
        #expect(view.selectedRange().location == 3)              // end of "one"
        // Revealed from the badge: the caret may sit there.
        view.styler.forceReveal(line: 1)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(view.selectedRange().location == 8)
        // Leaving the line collapses it again.
        view.setSelectedRange(NSRange(location: 21, length: 0))
        #expect(view.styler.isCollapsed(line: 1))
    }
}
