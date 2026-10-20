import Foundation

/// The notes folder the user picked in the Files app, remembered as a
/// security-scoped bookmark. The iPhone app has no iCloud entitlement (a free
/// Personal Team cannot have one), so the Foolscap folder in iCloud Drive is
/// reached the way any document is: the picker grants it, the bookmark keeps the
/// grant across launches, and the scoped access stays open for the process's life
/// because every read, write and watcher below `root` needs it.
public enum BookmarkedFolder {
    public static let defaultsKey = "notesFolderBookmark"

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Keep `url` (fresh from a picker) as the notes folder. Returns the URL to
    /// use, with its scoped access started.
    @discardableResult
    public static func remember(_ url: URL, defaults: UserDefaults = .standard) throws -> URL {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: defaultsKey)
        return try resolve(defaults: defaults) ?? url
    }

    /// The remembered folder, its access started and left open; nil when none was
    /// kept or the bookmark no longer resolves. A stale bookmark (the folder moved)
    /// is re-saved on the way through.
    public static func resolve(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: defaultsKey)
        }
        return url
    }

    public static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
