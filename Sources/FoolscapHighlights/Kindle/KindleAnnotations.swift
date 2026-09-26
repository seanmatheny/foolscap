import Foundation
import GRDB

/// The Kindle app's synced annotations: `ksdk_annotation_v1.db`. Highlights
/// and underlines are position ranges; typed notes are positions with text.
/// Neither carries the highlighted text itself.
public enum KindleAnnotations {
    static let highlightDataset = 1
    static let noteDataset = 3
    static let underlineDataset = 12

    /// The signed-in account's database (the `anonymous` one is empty); the
    /// most recently written one if several accounts have signed in.
    public static func databaseURL(dataDirectory: URL) -> URL? {
        let ksdk = dataDirectory.appendingPathComponent("Library/KSDK", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: ksdk.path) else { return nil }
        let candidates = names.filter { $0.hasPrefix("amzn1.account.") }
            .map { ksdk.appendingPathComponent($0).appendingPathComponent("ksdk_annotation_v1.db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return candidates.max { a, b in
            let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ma < mb
        }
    }

    /// Annotations by book id, each list in position order, notes attached to
    /// the highlight they sit in.
    public static func annotations(dataDirectory: URL = KindleLibrary.defaultDataDirectory) throws -> [String: [KindleAnnotation]] {
        guard let url = databaseURL(dataDirectory: dataDirectory) else {
            let ksdk = dataDirectory.appendingPathComponent("Library/KSDK")
            if FileManager.default.fileExists(atPath: ksdk.path), !FileManager.default.isReadableFile(atPath: ksdk.path) {
                throw ExtractionFailure.accessDenied(KindleLibrary.accessDeniedMessage)
            }
            throw ExtractionFailure.unreadable("no Kindle annotations database was found; is the Kindle app signed in?")
        }
        let db = try KindleLibrary.openReadOnly(url)
        let rows: [Row]
        do {
            rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT dataset, dataset_id, annotation_id, serialized_payload, created_time, modified_time
                    FROM server_view WHERE dataset IN (?,?,?)
                    """, arguments: [highlightDataset, underlineDataset, noteDataset])
            }
        } catch {
            throw KindleLibrary.failure(for: error, at: url)
        }
        var highlights: [String: [KindleAnnotation]] = [:]
        var notes: [String: [(position: Int, text: String)]] = [:]
        for row in rows {
            guard let datasetID: String = row["dataset_id"], let annotationID: String = row["annotation_id"],
                  let payloadText: String = row["serialized_payload"], let dataset: Int = row["dataset"],
                  let payload = Payload(json: payloadText) else { continue }
            let bookID = String(datasetID.prefix { $0 != "-" })
            let created = payload.created ?? (row["created_time"] as Int?).flatMap { Self.date(fromMilliseconds: $0) }
            let modified = payload.modified ?? (row["modified_time"] as Int?).flatMap { Self.date(fromMilliseconds: $0) }
            if dataset == noteDataset {
                if let text = payload.noteText, !text.isEmpty { notes[bookID, default: []].append((payload.start, text)) }
                continue
            }
            guard payload.start <= payload.end else { continue }
            highlights[bookID, default: []].append(KindleAnnotation(
                id: annotationID, kind: dataset == underlineDataset ? .underline : .highlight,
                start: payload.start, end: payload.end, created: created, modified: modified, color: payload.color))
        }
        var out: [String: [KindleAnnotation]] = [:]
        for (bookID, list) in highlights {
            var sorted = list.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            for note in notes[bookID] ?? [] {
                // The highlight the note sits in (the innermost when nested), else one ending exactly there.
                let inside = sorted.indices.filter { sorted[$0].start <= note.position && note.position <= sorted[$0].end }
                let target = inside.max { sorted[$0].start < sorted[$1].start } ?? sorted.firstIndex { $0.end == note.position }
                guard let target else { continue }
                sorted[target].note = sorted[target].note.map { $0 + "\n" + note.text } ?? note.text
            }
            out[bookID] = sorted
        }
        return out
    }

    static func date(fromMilliseconds ms: Int) -> Date? {
        ms > 0 ? Date(timeIntervalSince1970: TimeInterval(ms) / 1000) : nil
    }

    /// The JSON in `serialized_payload`; `json_metadata` is a JSON string inside it.
    struct Payload {
        var start: Int
        var end: Int
        var created: Date?
        var modified: Date?
        var color: String?
        var noteText: String?

        init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let start = Self.position(object["start_position"]) else { return nil }
            self.start = start
            self.end = Self.position(object["end_position"]) ?? start
            created = (object["created_time"] as? NSNumber).flatMap { KindleAnnotations.date(fromMilliseconds: $0.intValue) }
            modified = (object["last_modified"] as? NSNumber).flatMap { KindleAnnotations.date(fromMilliseconds: $0.intValue) }
            if let metaText = object["json_metadata"] as? String, let metaData = metaText.data(using: .utf8),
               let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
                color = meta["mchl_color"] as? String
                noteText = (meta["note_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        private static func position(_ value: Any?) -> Int? {
            guard let dict = value as? [String: Any] else { return nil }
            if let n = dict["shortPosition"] as? NSNumber { return n.intValue }
            if let s = dict["shortPosition"] as? String { return Int(s) }
            return nil
        }
    }
}
