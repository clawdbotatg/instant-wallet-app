// Instant Wallet — the iOS app that IS the website. Same page, same passkeys:
// the passkey's RP ID is the page's hostname, so the app and Safari share them
// (iCloud Keychain). That needs the site's apple-app-site-association naming
// this app AND InstantWallet.entitlements naming the site.
//
// Not shared with Safari: localStorage. A wallet made in Safari shows up here
// only through its passkey.
import SwiftUI

let SITE = URL(string: "https://instantwallet.io/")!

final class Nav: ObservableObject {
    enum Phase { case loading, ready, offline }
    @Published var url = SITE
    @Published var phase = Phase.loading
    @Published var retries = 0               // bumped by Try again; WebView reloads on change
}

@main
struct InstantWalletApp: App {
    @StateObject private var nav = Nav()

    var body: some Scene {
        WindowGroup {
            ZStack {
                WebView(nav: nav)
                    .ignoresSafeArea()           // viewport-fit=cover: the page owns the notch + home bar
                if nav.phase != .ready { Splash(nav: nav).transition(.opacity) }
            }
                .animation(.easeOut(duration: 0.25), value: nav.phase)
                .background(Color("Background"))
                .preferredColorScheme(.light)
                // a site link (claim card, camera QR) opens here instead of Safari
                .onOpenURL { u in if u.host == SITE.host { nav.url = u } }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    if let u = a.webpageURL, u.host == SITE.host { nav.url = u }
                }
        }
    }
}

// The logo while the site loads; picks up exactly where the launch screen
// (UILaunchScreen: Mark on Background) leaves off. Spinner only if it's slow;
// no connection → Try again instead of a blank screen.
struct Splash: View {
    @ObservedObject var nav: Nav
    @State private var slow = false

    var body: some View {
        ZStack {
            Color("Background")
            Image("Mark")
            VStack(spacing: 14) {
                if nav.phase == .offline {
                    Text("No connection").font(.headline).foregroundStyle(.black)
                    Button("Try again") { nav.phase = .loading; nav.retries += 1 }
                        .buttonStyle(.borderedProminent).tint(.black)
                } else if slow {
                    ProgressView().controlSize(.large).tint(.gray)
                }
            }
                .offset(y: 150)                  // under the logo, so the logo never moves
        }
            .ignoresSafeArea()
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation { slow = true }
            }
    }
}
