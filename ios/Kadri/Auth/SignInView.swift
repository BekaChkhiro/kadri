import SwiftUI
import UIKit

/// Temporary sign-in screen in the Theme style; the onboarding design replaces it later.
struct SignInView: View {
    @Environment(GoogleAuthController.self) private var auth

    var body: some View {
        ZStack {
            Theme.Colors.surface.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("შესვლა")
                    .font(.kadri(21, weight: .semibold))
                content
            }
            .foregroundStyle(Theme.Colors.ink[900]!)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
            .padding(16)
        }
        .navigationTitle("შესვლა")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.user?.id) { await auth.verifySession() }
    }

    @ViewBuilder private var content: some View {
        switch auth.state {
        case .signedIn(let user):
            VStack(alignment: .leading, spacing: 4) {
                if let name = user.name {
                    Text(name).font(.kadri(15, weight: .medium))
                }
                Text(user.email)
                    .font(.kadri(14))
                    .foregroundStyle(Theme.Colors.ink[600]!)
            }
            verificationLabel
            Button("გასვლა") { Task { await auth.signOut() } }
                .buttonStyle(SessionButtonStyle(primary: false))
        case .signingIn:
            HStack(spacing: 10) {
                ProgressView()
                Text("შესვლა მიმდინარეობს…").font(.kadri(14))
            }
            .frame(minHeight: 48)
        case .signedOut, .failed:
            Text("შედი Google-ის ანგარიშით, რომ კადრმა ინსტრუქციები მოგაწოდოს.")
                .font(.kadri(14))
                .foregroundStyle(Theme.Colors.ink[600]!)
            if let message = auth.errorMessage {
                Text(message)
                    .font(.kadri(13.5, weight: .medium))
                    .foregroundStyle(.red)
            }
            Button {
                guard let presenter = UIApplication.shared.kadriTopViewController else { return }
                Task { await auth.signIn(presenting: presenter) }
            } label: {
                Label("Google-ით შესვლა", systemImage: "person.crop.circle")
            }
            .buttonStyle(SessionButtonStyle())
            .accessibilityHint("Google-ის ანგარიშით შესვლის ფანჯარას გახსნის")
        }
    }

    @ViewBuilder private var verificationLabel: some View {
        switch auth.verification {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("სესია მოწმდება…").font(.kadri(13.5))
            }
        case .active:
            Label("სესია აქტიურია", systemImage: "checkmark.seal.fill")
                .font(.kadri(13.5, weight: .medium))
                .foregroundStyle(.green)
        case .failed(let error):
            Text(error.localizedDescription)
                .font(.kadri(13.5))
                .foregroundStyle(.red)
        }
    }
}

extension UIApplication {
    /// The view controller Google's sign-in sheet is presented from.
    var kadriTopViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
