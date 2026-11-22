// A sample, not part of the app: Foolscap's Today tasks as a two-page PDF for the Kindle
// Scribe (the day page, then a page of sizes to choose from). The story and what is still
// open are in Docs/Scribe-Today-Page-2026-11-22.md.
//
//   sqlite3 -readonly -json "$HOME/Library/Application Support/Foolscap/index-<hash>.sqlite" \
//     "select t.path, t.line, t.title, (select group_concat(tag, ',') from task_tags
//      where task_id = t.id) as tags from tasks t where t.status = 'today'
//      order by t.path, t.line" > tasks.json
//   defaults read com.seanmatheny.foolscap taskPens > pens.json
//   xcrun swift Tools/scribe-day-page.swift tasks.json pens.json <pdf folder> <work folder>
//
// The PDF goes into the first folder; the second gets page-1.png and page-2.png (the pages at
// the Scribe's 1860 × 2480, greyscale) and layout.json (where each task's box sits).
// --name sets the title and file name; --outlines draws text as shapes (no fonts in the file);
// --integer-page makes the page 446 × 595. The last two were made to find out why one file
// would not open, and turned out not to matter.
import Foundation
import CoreGraphics
import CoreText
import ImageIO

let args = CommandLine.arguments
guard args.count >= 5 else {
    fputs("usage: scribe-day-page.swift tasks.json pens.json pdf-folder work-folder [--name title] [--outlines] [--integer-page]\n", stderr)
    exit(2)
}

// Variants for finding out what the Scribe objects to.
func option(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
/// Text drawn as shapes, so the file carries no fonts at all.
let outlines = args.contains("--outlines")
/// A whole-number page size (446 × 595) in place of 446.4 × 595.2.
let integerPage = args.contains("--integer-page")

// MARK: Tasks

struct Row: Decodable { let path: String; let line: Int; let title: String; let tags: String? }
struct Pen: Decodable { let colour: String; let tag: String }
struct Task { let path: String; let line: Int; let priority: Int; let title: String; let tags: [String] }

/// The title as the page shows it: the priority marks, tags and link syntax taken out.
func tidy(_ row: Row) -> Task {
    var text = row.title
    var priority = 1
    if let marks = text.range(of: #"^!{1,3}"#, options: .regularExpression) {
        priority = text.distance(from: marks.lowerBound, to: marks.upperBound)
        text.removeSubrange(marks)
    }
    text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(^|\s)#[\p{L}\p{N}_/-]+"#, with: "", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespaces)
    let tags = (row.tags ?? "").split(separator: ",").map(String.init)
    return Task(path: row.path, line: row.line, priority: priority, title: text, tags: tags)
}

let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let pens = try JSONDecoder().decode([Pen].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

/// Pen by pen in list order, then priority, then note order: `TodayTasks.select`'s order.
func rank(_ task: Task) -> Int { pens.firstIndex { task.tags.contains($0.tag) } ?? pens.count }
let tasks = rows.map(tidy).enumerated().sorted { a, b in
    let (ra, rb) = (rank(a.element), rank(b.element))
    if ra != rb { return ra < rb }
    if a.element.priority != b.element.priority { return a.element.priority > b.element.priority }
    return a.offset < b.offset
}.map(\.element)

// MARK: Drawing

/// The Scribe's 1860 × 2480 px at 300 ppi.
let W: CGFloat = 446.4, H: CGFloat = 595.2
let regular = "AvenirNext-Regular", medium = "AvenirNext-Medium", demi = "AvenirNext-DemiBold"
let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

func attributed(_ string: String, _ font: CTFont, gray: CGFloat = 0, kern: CGFloat = 0) -> NSMutableAttributedString {
    NSMutableAttributedString(string: string, attributes: [
        fontKey: font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        NSAttributedString.Key(kCTKernAttributeName as String): kern as NSNumber,
    ])
}

func width(of text: NSAttributedString) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
}

enum Align { case left, right, centre }

/// Puts a line of text at a baseline point: as text, or as filled glyph shapes with `--outlines`.
func show(_ ctx: CGContext, _ line: CTLine, at point: CGPoint) {
    guard outlines else {
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        return
    }
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName as String] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        if let colour = attributes[kCTForegroundColorAttributeName as String] {
            ctx.setFillColor(colour as! CGColor)
        } else {
            ctx.setFillColor(gray: 0, alpha: 1)
        }
        for i in 0..<count {
            var transform = CGAffineTransform(translationX: point.x + positions[i].x, y: point.y + positions[i].y)
            if let path = CTFontCreatePathForGlyph(runFont, glyphs[i], &transform) { ctx.addPath(path) }
        }
        ctx.fillPath()
    }
}

/// Draws one line of text; `top` is the baseline's distance from the top of the page.
func draw(_ ctx: CGContext, _ text: NSAttributedString, x: CGFloat, top: CGFloat, align: Align = .left) {
    let line = CTLineCreateWithAttributedString(text)
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let left = align == .left ? x : align == .right ? x - w : x - w / 2
    show(ctx, line, at: CGPoint(x: left, y: H - top))
}

func rule(_ ctx: CGContext, from x0: CGFloat, to x1: CGFloat, top: CGFloat, gray: CGFloat = 0.55, weight: CGFloat = 0.5) {
    ctx.setStrokeColor(gray: gray, alpha: 1)
    ctx.setLineWidth(weight)
    ctx.move(to: CGPoint(x: x0, y: H - top))
    ctx.addLine(to: CGPoint(x: x1, y: H - top))
    ctx.strokePath()
}

/// A box to tick; `top` is its upper edge.
func box(_ ctx: CGContext, x: CGFloat, top: CGFloat, side: CGFloat, round: Bool = false) {
    let rect = CGRect(x: x, y: H - top - side, width: side, height: side)
    ctx.setStrokeColor(gray: 0, alpha: 1)
    ctx.setLineWidth(0.9)
    if round {
        ctx.strokeEllipse(in: rect)
    } else {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.2, cornerHeight: side * 0.2, transform: nil))
        ctx.strokePath()
    }
}

func wrap(_ text: NSAttributedString, width: CGFloat) -> [CTLine] {
    let setter = CTTypesetterCreateWithAttributedString(text)
    var lines: [CTLine] = []
    var start = 0
    while start < text.length {
        let count = CTTypesetterSuggestLineBreak(setter, start, Double(width))
        lines.append(CTTypesetterCreateLine(setter, CFRange(location: start, length: count)))
        start += count
    }
    return lines
}

func formatted(_ format: String, _ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.dateFormat = format
    return formatter.string(from: date)
}

let now = Date()
let left: CGFloat = 30, right: CGFloat = W - 26

func footer(_ ctx: CGContext, page: Int) {
    draw(ctx, attributed("Foolscap · made \(formatted("d MMM HH:mm", now))", font(regular, 6.5), gray: 0.45), x: left, top: H - 13)
    draw(ctx, attributed("\(page)", font(regular, 6.5), gray: 0.45), x: right, top: H - 13, align: .right)
}

// MARK: Page 1, the day

/// Where each task's box sits, in points from the page's top-left corner.
struct BoxRecord: Encodable {
    let page: Int, path: String, line: Int, title: String
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
}
var boxes: [BoxRecord] = []
var shown = 0

func dayPage(_ ctx: CGContext, record: Bool) {
    let pitch: CGFloat = 24, top0: CGFloat = 72, side: CGFloat = 13
    let titleX = left + side + 7 + 14
    let lastRule = Int((H - 28 - top0) / pitch)

    draw(ctx, attributed(formatted("EEEE d MMMM", now), font(demi, 19)), x: left, top: 46)
    draw(ctx, attributed("TODAY", font(medium, 8), gray: 0.3, kern: 1.4), x: right, top: 46, align: .right)
    rule(ctx, from: left, to: right, top: 58, gray: 0, weight: 0.8)
    for n in 1...lastRule { rule(ctx, from: left, to: right, top: top0 + CGFloat(n) * pitch) }

    var k = 1
    var drawn = 0
    for task in tasks {
        let tagText = task.tags.joined(separator: " · ")
        let tag = attributed(tagText, font(medium, 8), gray: 0.35)
        let tagRoom = tagText.isEmpty ? 0 : width(of: tag) + 10
        let title = attributed(task.title, font(regular, 11))
        if task.tags.contains("jira"), let key = task.title.range(of: #"^[A-Z][A-Z0-9]+-\d+"#, options: .regularExpression) {
            title.addAttribute(fontKey, value: font(demi, 11), range: NSRange(key, in: task.title))
        }
        let lines = wrap(title, width: right - titleX - tagRoom)
        guard k + lines.count - 1 <= lastRule else { break }

        let y = top0 + CGFloat(k) * pitch          // the rule this row's first line sits on
        let baseline = y - 5.5
        box(ctx, x: left, top: y - 3.5 - side, side: side)
        if record {
            boxes.append(BoxRecord(page: 1, path: task.path, line: task.line, title: task.title,
                                   x: left, y: y - 3.5 - side, width: side, height: side))
        }
        if task.priority > 1 {
            draw(ctx, attributed(String(repeating: "!", count: task.priority), font(demi, 11)), x: left + side + 7, top: baseline)
        }
        if !tagText.isEmpty { draw(ctx, tag, x: right, top: baseline, align: .right) }
        for (i, line) in lines.enumerated() {
            show(ctx, line, at: CGPoint(x: titleX, y: H - (baseline + CGFloat(i) * pitch)))
        }
        k += lines.count
        drawn += 1
    }
    if record { shown = drawn }
    footer(ctx, page: 1)
}

// MARK: Page 2, sizes to choose from

func sizesPage(_ ctx: CGContext) {
    let label = { (s: String) in attributed(s, font(medium, 8), gray: 0.3, kern: 1.2) }
    let small = { (s: String) in attributed(s, font(regular, 7.5), gray: 0.35) }

    draw(ctx, attributed("Sizes to choose from", font(demi, 15)), x: left, top: 40)
    draw(ctx, attributed("Write on this page, then say which ones feel right.", font(regular, 9), gray: 0.3), x: left, top: 55)
    rule(ctx, from: left, to: right, top: 64, gray: 0, weight: 0.8)

    // Boxes
    draw(ctx, label("BOXES"), x: left, top: 84)
    let sides: [CGFloat] = [10, 12, 14, 16, 18]
    for (i, side) in sides.enumerated() {
        let centre = 118 + CGFloat(i) * 62
        box(ctx, x: centre - side / 2, top: 106 - side / 2, side: side)
        box(ctx, x: centre - side / 2, top: 134 - side / 2, side: side, round: true)
        draw(ctx, small("\(Int(side))"), x: centre, top: 156, align: .centre)
    }
    draw(ctx, small("square"), x: left, top: 108.5)
    draw(ctx, small("round"), x: left, top: 136.5)

    // Type
    draw(ctx, label("TYPE"), x: left, top: 182)
    for (i, size) in [CGFloat(9), 10, 11, 12, 13].enumerated() {
        draw(ctx, attributed("Count the cables for the sheet · \(Int(size))", font(regular, size)), x: left, top: 201 + CGFloat(i) * 18)
    }

    // Rules
    let rulesX: CGFloat = 268
    draw(ctx, label("RULES"), x: rulesX, top: 182)
    let strengths: [(String, CGFloat, CGFloat)] = [
        ("A  light, thin", 0.7, 0.35), ("B  light", 0.7, 0.7),
        ("C  mid, thin", 0.55, 0.35), ("D  mid", 0.55, 0.7),
        ("E  dark, thin", 0.35, 0.35), ("F  dark", 0.35, 0.7),
    ]
    for (i, strength) in strengths.enumerated() {
        let y = 199 + CGFloat(i) * 15
        draw(ctx, small(strength.0), x: rulesX, top: y)
        rule(ctx, from: rulesX + 62, to: right, top: y - 2.5, gray: strength.1, weight: strength.2)
    }

    // Line spacing: three lines of each, to write on
    draw(ctx, label("LINE SPACING"), x: left, top: 304)
    func block(_ pitch: CGFloat, x0: CGFloat, x1: CGFloat, top: CGFloat) -> CGFloat {
        draw(ctx, small("\(Int(pitch)) pt"), x: x0, top: top + 8)
        for n in 1...3 { rule(ctx, from: x0, to: x1, top: top + 10 + CGFloat(n) * pitch) }
        return top + 10 + 3 * pitch + 8
    }
    let middle = (left + right) / 2
    var y: CGFloat = 312
    for pitch in [CGFloat(20), 22, 24] { y = block(pitch, x0: left, x1: middle - 10, top: y) }
    y = 312
    for pitch in [CGFloat(26), 28] { y = block(pitch, x0: middle + 10, x1: right, top: y) }

    footer(ctx, page: 2)
}

// MARK: Output

// No comma in the title: the one sample that would not open on the Scribe had one (see the doc).
let name = option("--name") ?? "Today \(formatted("EEE d MMM", now))"
let pdfURL = URL(fileURLWithPath: args[3]).appendingPathComponent(name + ".pdf")
let work = URL(fileURLWithPath: args[4])

var mediaBox = integerPage ? CGRect(x: 0, y: 0, width: 446, height: 595) : CGRect(x: 0, y: 0, width: W, height: H)
let info: [CFString: Any] = [kCGPDFContextTitle: name, kCGPDFContextCreator: "Foolscap", kCGPDFContextAuthor: "Foolscap"]
guard let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
    fputs("could not create \(pdfURL.path)\n", stderr)
    exit(1)
}
pdf.beginPDFPage(nil); dayPage(pdf, record: true); pdf.endPDFPage()
pdf.beginPDFPage(nil); sizesPage(pdf); pdf.endPDFPage()
pdf.closePDF()

/// The page as the Scribe's screen has it: 1860 × 2480, greyscale.
func preview(_ file: String, _ body: (CGContext) -> Void) {
    let (pw, ph) = (1860, 2480)
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.scaleBy(x: CGFloat(pw) / W, y: CGFloat(ph) / H)
    body(ctx)
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(work.appendingPathComponent(file) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
preview("page-1.png") { dayPage($0, record: false) }
preview("page-2.png") { sizesPage($0) }

struct Layout: Encodable { let pageWidth: CGFloat, pageHeight: CGFloat, made: String, boxes: [BoxRecord] }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Layout(pageWidth: W, pageHeight: H, made: ISO8601DateFormatter().string(from: now), boxes: boxes))
    .write(to: work.appendingPathComponent("layout.json"))

print("\(pdfURL.path)")
print("tasks read \(tasks.count), shown \(shown)")
