import GoogleSignIn
import UIKit

/// `GoogleTokenProvider` over `GIDSignIn`. Client IDs come from Info.plist (`GIDClientID`, `GIDServerClientID`),
/// so the ID token's audience is the Web client the Worker checks.
struct GIDTokenProvider: GoogleTokenProvider {
    func signIn(presenting: UIViewController) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenting) { result, error in
                if let error {
                    continuation.resume(throwing: Self.failure(error))
                } else if let token = result?.user.idToken?.tokenString {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: GoogleSignInFailure.noIDToken)
                }
            }
        }
    }

    func restore() async -> String? {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return nil }
        return await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, _ in
                guard let user else { return continuation.resume(returning: nil) }
                // The stored ID token lives an hour; the Worker rejects an expired one.
                user.refreshTokensIfNeeded { user, _ in
                    continuation.resume(returning: user?.idToken?.tokenString)
                }
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    private nonisolated static func failure(_ error: any Error) -> GoogleSignInFailure {
        let error = error as NSError
        if error.domain == kGIDSignInErrorDomain, error.code == GIDSignInError.canceled.rawValue { return .cancelled }
        return .failed
    }
}
