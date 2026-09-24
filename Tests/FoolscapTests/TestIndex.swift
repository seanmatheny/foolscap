import Foundation
import FoolscapStore

/// Test libraries keep their index in the temporary directory, not beside the
/// real notebook's in Application Support.
enum TestIndex {
    static func path(for folder: NotesFolder) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-test-index-\(UUID().uuidString).sqlite").path
    }
}
