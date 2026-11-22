# Today's tasks on the Kindle Scribe: findings, 22 November 2026

Sean asked for a way to have the Daily page's Today tasks reach the Scribe as a kind of
daily note. This is what was found and tried, and where it was left. **On hold**: Sean
judged that there is no clean way to handle the pages that pile up, and is thinking it over.
Nothing was built into the app.

## The short version

- Nothing can write into a Scribe notebook. What can be done is to deliver a **PDF page**
  that the pen writes on.
- That works: a PDF sent from the Kindle app's share sheet with **"keep original layout"**
  opens on the Scribe and takes the pen anywhere on the page.
- The unsolved part is housekeeping. Send to Kindle never replaces a document, so each day
  adds one to the library, and there is no supported way to file or delete them
  automatically.

## Sean's setup

- The Scribe draws 1860 × 2480, so it is the 10.2" 2022 or 2024 model. Google Drive and
  OneDrive import, OneNote and AI search are for the 2025 models only. Model and firmware
  were never confirmed (Settings ▸ Device Options ▸ Device Info).
- `/Applications/Amazon Kindle.app` (7.70.1) ships a share extension,
  `com.amazon.Lassen.SendToKindleExtension`, that takes PDF, EPUB, HTML, text and Word. It
  asks "keep original layout" or "make layout adjustable" for a PDF.
- Scribe → Foolscap already exists: handwritten `TODO:` lines become tasks (`ScribeTodos`,
  `TodoLedger`) and dated pages show on the Daily page.
- The Amazon listing Foolscap reads (`kindle-notebook/api/notes`) holds notebooks only, no
  documents.

## Ways to get a page onto the Scribe

| Route | Each day | Pen | Catch |
|---|---|---|---|
| Kindle app's share extension | One click on Send | Yes, tried | Not silent; Foolscap gets no document id back |
| Send to Kindle by email | Nothing, once set up | Yes (documented) | Foolscap needs a mail account, or drives Mail |
| Send to Kindle's app protocol (`maxdjohnson/stkclient`, Python) | Nothing after one sign-in | Yes | Unofficial; not confirmed working in 2026 |
| USB (libmtp; see the MTP notes in memory) | Plug in | Reported since firmware 5.19.3 | Ink stays on the device; one MTP session per plug-in |
| The Scribe's browser on a page Foolscap serves | Open a bookmark | No, taps only | Mac awake on the same Wi-Fi; untested |
| Jailbreak ("Vera", August 2026) | Nothing | Anything | Firmware 5.19.6 or older only; risk |
| Writing an `nbk` notebook file over USB | Plug in | Yes | Could corrupt notebook sync; not recommended |

## What was tried on the Scribe

`Tools/scribe-day-page.swift` draws a two-page PDF with CoreGraphics: page 446.4 × 595.2 pt
(the screen at 300 ppi, so no borders), Avenir Next, black on white. Page 1 is the day: the
date, the Today tasks in `TodayTasks.select`'s order (pen by pen, then priority, then note
order) each with a box, priority marks and tag, then ruled lines for handwriting. Page 2
offers box sizes, type sizes, rule strengths and line spacings to choose from.

- **"Keep original layout"**: opens, the pen writes anywhere. This is the route.
- **"Make layout adjustable"**: Amazon reflows it into an ebook. Boxes and sizes are lost and
  writing is by inserted text box. Never use it for this.
- **One file would not open**: it downloaded, showed for a second with a percentage read, and
  flipped back to offline. A reboot and renaming the file did not help. It was the first
  sample, titled "Today, Sun 22 Nov", which Sean had sent in *both* layouts. A file built
  identically but titled without a comma and sent once opened, as did variants with no fonts
  and with a whole-number page size. So fonts, page size and PDF version are cleared. The
  two suspects left:
  1. the comma in the title stored inside the PDF (renaming the file does not change it);
  2. the same file having been sent in both layouts, the Scribe taking one for the other.
  `~/Downloads/Scribe tests/Scribe test 4, with comma.pdf` was made to tell them apart (send
  once, original layout: fails → the comma; opens → the double send). **It was not sent.**
  Either way: no comma in the title, and a time stamp in each page so no two sends are the
  same bytes.
- Sean's older original-layout PDFs (sudoku3, 7, 8, 9) open, so the route itself is sound.

## Filing and deleting

- **Send to Kindle cannot file into a collection.** Sean's "work" collection is a cloud
  collection (the Kindle Mac app's `BookData.sqlite` lists it, `ZCOLLECTIONV2`). Collections
  sync through Whispersync from Kindle apps and devices (the Mac app's
  `CollectionsSyncFromCoreData` / `CollectionsSyncFromWhisperSync`; an item is
  `amzn://<document id>/DOC`). No documented or community-known call adds a document to one.
- **Deleting old pages** is likelier to work, through the internal calls of Amazon's Manage
  Your Content and Devices page (`hz/mycd`), which people have scripted for years; every
  example found is old and Amazon throttles such calls. Unverified.
- Both would need a full Amazon website sign-in in Foolscap (the Scribe tab's sign-in is to
  the notebook reader and may not cover that page) and a way to recognise Foolscap's pages:
  title pattern plus the "Foolscap" author stamped into the PDF.
- **Deleting a page should be assumed to delete the handwriting on it**, and it is permanent
  on the Amazon account. Guards if it is ever built: only Foolscap's own title and author,
  only older than a set number of days, off by default, and not before ink can be read back.
- By hand: on the Scribe, the three-dot menu under a document ▸ Add/remove from collection;
  on the website, tick several Docs and delete them together.
- Ruled out: speaking Whispersync as a registered device (large, against Amazon's terms),
  and writing into the Kindle Mac app's database (could corrupt the library).

## Bringing ticks back (not started)

Foolscap draws the PDF, so it knows where each task's box is (`layout.json` from the script).
A tick can be read by testing ink against those rectangles, with no handwriting recognition.
Where the ink might come from:

- USB: the `<document id>!!PDOC!!notebook/nbk` stroke files (format notes in memory).
- Amazon's cloud: whether `openNotebook` accepts that id is **untested**, and is the
  experiment that matters most.
- The Scribe's Share by email: by hand, and the link lasts 7 days.

## To pick this up again

1. Send test 4 to settle the comma question (or just avoid commas and move on).
2. Get Sean's choices from page 2 of a sample: box, type size, rule strength, line spacing.
3. Note the Scribe's model and firmware; see what the lock screen shows with a page open.
4. The five-minute website test: Sean signed in to Amazon in a browser Claude can watch,
   adds one test page to "work" and deletes another, to read what the page sends and to see
   whether the Scribe follows. This decides whether filing or deleting can be automated.
5. Try `openNotebook` on a written-on page's id, for the ticks.
6. Only then design the feature: a day-page renderer in the app, sending through the share
   extension first, silent delivery later.

Ideas that might dissolve the housekeeping problem: one document a week in place of one a
day; the browser page for a live view with no documents at all.

## Sources

- [Kindle Scribes now support writing notes on PDFs loaded via USB](https://blog.the-ebook-reader.com/2026/03/13/kindle-scribes-now-support-writing-notes-on-pdfs-loaded-via-usb/)
- [Kindle software update 5.19.3, improved PDF support](https://blog.the-ebook-reader.com/2026/03/27/kindle-software-update-5-19-3-released-with-improved-pdf-support/)
- [New software features aren't coming to older Kindle Scribes](https://blog.the-ebook-reader.com/2026/01/09/new-software-features-arent-coming-to-older-kindle-scribes/)
- [Amazon: personal document file types that support notes](https://digprjsurvey.amazon.com/csad/help/node/TNtSm13k3txFI4EvDV)
- [Amazon: share notes and notebooks from your Kindle Scribe](https://digprjsurvey.amazon.com/csad/help/node/TJE2UYmdw0ppUuR3Rs)
- [Amazon: adding a local file to a cloud collection](https://digprjsurvey.amazon.com/csad/help/node/TgmjLZNVFjByHNDkMd)
- [stkclient](https://github.com/maxdjohnson/stkclient)
- [Getting PDFs onto your Kindle Scribe without breaking them](https://plannedpages.com/blog/kindle-scribe-pdf-transfer/)
- [New Vera jailbreak for latest Kindles](https://blog.the-ebook-reader.com/2026/08/11/new-vera-jailbreak-released-for-latest-kindles-with-current-software/)
- [Reverse engineer Whispersync](https://ptbrowne.github.io/posts/whispersync-reverse-engineering)
- [Bookmarklet to delete archived personal documents](https://www.mobileread.com/forums/showthread.php?t=162972)
