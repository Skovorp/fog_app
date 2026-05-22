import ClerkKit
import ClerkKitUI
import SwiftUI

/// Mandatory sign-in gate. Just Clerk's prebuilt AuthView — Telegram bridge
/// was removed and may come back later as a Clerk custom OAuth provider.
struct AuthScreen: View {
    var body: some View {
        AuthView()
            .prefetchClerkImages()
    }
}

#Preview("AuthScreen") {
    AuthScreen()
}
