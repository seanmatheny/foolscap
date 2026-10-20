import SwiftUI
import CoreText
import FoolscapCore

// The chrome and the editor are shared between the Mac and the iPhone. What
// differs is the toolkit underneath: these aliases and helpers name the platform's
// type or call once, so the rest of the code reads the same on both.

#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
public typealias PlatformView = UIView
#endif

public extension RGBA {
    var platformColor: PlatformColor {
        #if canImport(AppKit)
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        #else
        UIColor(red: r, green: g, blue: b, alpha: a)
        #endif
    }
}

public extension FontSpec {
    /// The face as the toolkit's font: the named family when it is installed (its
    /// bold face when `bold`), else the system face of the design.
    var platformFont: PlatformFont {
        let weight: PlatformFont.Weight = bold ? .bold : .regular
        if let family, let f = PlatformFont(name: family, size: size) {
            return bold ? Self.boldFace(of: f) : f
        }
        switch design {
        case .mono: return PlatformFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .serif: return Self.systemFace(design: .serif, size: size, weight: weight)
        case .rounded: return Self.systemFace(design: .rounded, size: size, weight: weight)
        case .sans: return PlatformFont.systemFont(ofSize: size, weight: weight)
        }
    }

    var font: Font { Font(platformFont as CTFont) }

    private static func boldFace(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        // The font manager finds the family's real bold face; a descriptor trait can be synthesised.
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        guard let d = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: d, size: font.pointSize)
        #endif
    }

    private static func systemFace(design: PlatformFont.Descriptor.SystemDesign, size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        let system = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard let d = system.fontDescriptor.withDesign(design) else { return system }
        #if canImport(AppKit)
        return NSFont(descriptor: d, size: size) ?? system
        #else
        return UIFont(descriptor: d, size: size)
        #endif
    }
}

#if canImport(AppKit)
public extension PlatformFont { typealias Descriptor = NSFontDescriptor }
#else
public extension PlatformFont { typealias Descriptor = UIFontDescriptor }
#endif

/// The handful of system calls the shared views make that have no SwiftUI form.
public enum Platform {
    @MainActor
    public static func openURL(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor
    public static func copyText(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The clipboard's text, if it holds any.
    @MainActor
    public static func pasteboardString() -> String? {
        #if canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    public static func beep() {
        #if canImport(AppKit)
        NSSound.beep()
        #endif
    }

    /// Pixels per point of the main display: what bitmaps are decoded at.
    @MainActor
    public static var backingScale: CGFloat {
        #if canImport(AppKit)
        NSScreen.main?.backingScaleFactor ?? 2
        #else
        UITraitCollection.current.displayScale
        #endif
    }
}
