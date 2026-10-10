#!/usr/bin/osascript -l JavaScript
// Render one page of a Scribe notebook PDF to a PNG at its native 1860×2480.
//   Tools/scribe-page-png.js "Scribe/Work/Daily Work Notes.pdf" 24 out/page24.png
// (page numbers are 1-based). PDFKit through the ObjC bridge, so it needs no build.
ObjC.import('Quartz'); ObjC.import('AppKit');
function run(argv) {
  if (argv.length < 3) { return 'usage: scribe-page-png.js <pdf> <page> <out.png>'; }
  const [path, number, out] = argv;
  const doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(path));
  if (doc.isNil()) { return 'cannot open ' + path; }
  const index = parseInt(number) - 1;
  if (index < 0 || index >= doc.pageCount) { return 'page ' + number + ' is beyond ' + doc.pageCount; }
  const page = doc.pageAtIndex(index);
  const bounds = page.boundsForBox($.kPDFDisplayBoxMediaBox);
  const scale = 96 / 72;
  const size = $.NSMakeSize(Math.round(bounds.size.width * scale), Math.round(bounds.size.height * scale));
  const img = page.thumbnailOfSizeForBox(size, $.kPDFDisplayBoxMediaBox);
  const rep = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
  const png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
  png.writeToFileAtomically(out, true);
  return 'ok ' + rep.pixelsWide + 'x' + rep.pixelsHigh + ' ' + out;
}
