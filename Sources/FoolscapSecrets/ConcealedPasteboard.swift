import AppKit

/// Copies a secret so clipboard managers leave it alone (the `ConcealedType`
/// convention they honour) and clears it again after a while, unless something
/// else has been copied since.
@MainActor
public enum ConcealedPasteboard {
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let clearAfter: TimeInterval = 30

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
}
