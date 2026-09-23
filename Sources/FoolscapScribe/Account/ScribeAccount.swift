import Foundation
import Observation

/// Whether Foolscap can talk to Amazon, and the sign-in flow.
@MainActor
@Observable
public final class ScribeAccount {
    public private(set) var isSignedIn: Bool
    public private(set) var isSigningIn = false
    public private(set) var signInError: String?
    @ObservationIgnored private let signIn = ScribeSignInWindow()

    public init() {
        isSignedIn = AmazonScribeClient.hasSessionCookies()
    }

    public func refresh() { isSignedIn = AmazonScribeClient.hasSessionCookies() }

    /// Open the sign-in window; `onSuccess` runs once cookies are captured.
    public func beginSignIn(onSuccess: @escaping @MainActor () -> Void = {}) {
        isSigningIn = true
        signInError = nil
        signIn.present { [weak self] result in
            guard let self else { return }
            self.isSigningIn = false
            switch result {
            case .success:
                self.isSignedIn = AmazonScribeClient.hasSessionCookies()
                if self.isSignedIn { onSuccess() } else { self.signInError = "Amazon did not return a session; try again." }
            case .failure(let error):
                self.signInError = error.localizedDescription
            }
        }
    }

    public func signOut() {
        AmazonScribeClient.clearCookies()
        ScribeSignInWindow.clearWebCookies()
        isSignedIn = false
    }

    /// Amazon redirected a request: the session lapsed.
    public func markSignedOut() {
        AmazonScribeClient.clearCookies()
        isSignedIn = false
    }
}
