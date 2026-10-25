import Foundation
import LocalAuthentication
#if canImport(UIKit)
import UIKit
#endif

/// What this device unlocks the vault with, named for the page, the Settings pane and
/// the vault's device list: Face ID on a phone, Touch ID on a Mac, the passcode or
/// login password where there is no biometry.
public enum DeviceAuth {
    #if os(iOS)
    public static let isPhone = true
    /// "phone" or "Mac", for sentences about this device.
    public static let deviceWord = "phone"
    #else
    public static let isPhone = false
    public static let deviceWord = "Mac"
    #endif

    /// The biometry this device has, read once: it does not change while the app runs.
    private static let biometry: LABiometryType = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }()

    /// "Face ID", "Touch ID", "Optic ID", or what stands in for them.
    public static let biometryName: String = {
        switch biometry {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return isPhone ? "the passcode" : "the login password"
        }
    }()

    /// The SF Symbol for the unlock button.
    public static let biometrySymbol: String = {
        switch biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.open"
        }
    }()

    /// The system sheet's fallback button, and what it falls back to.
    public static let fallbackTitle = isPhone ? "Use Passcode…" : "Use Password…"
    public static let fallbackName = isPhone ? "the passcode" : "your password"

    /// This device's name for the vault's list of enrolled devices ("Sean's MacBook Pro";
    /// a phone gives its model name since iOS 16).
    @MainActor
    public static var deviceName: String {
        #if os(iOS)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "iPhone" : name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}
