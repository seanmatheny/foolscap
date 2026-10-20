#if canImport(AppKit)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// Copies a secret so clipboard managers leave it alone (the `ConcealedType`
/// convention they honour) and clears it again after a while, unless something
/// else has been copied since. On the phone the system does the clearing (an
/// expiry on the item) and the copy stays on the device (no Universal Clipboard).
@MainActor
public enum ConcealedPasteboard {
    public static let clearAfter: TimeInterval = 30

    #if canImport(AppKit)
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, concealedType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setString("", forType: concealedType)
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
    #else
    public static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(clearAfter)])
    }
    #endif
}
