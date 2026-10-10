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
    // loading: the page isn't up · waiting: it is, the balance isn't · ready: the wallet shows
    enum Phase { case loading, waiting, ready, offline }
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
                .animation(.easeOut(duration: 0.2), value: nav.phase)
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

// The logo until the wallet has its balance, so the page never shows "…".
// Faded and breathing while the page loads (the launch screen is the same faded
// logo), solid and pulsing while the balance loads. No minimum time: it goes the
// moment the site says ready. No connection → Try again instead of a blank screen.
struct Splash: View {
    @ObservedObject var nav: Nav

    var body: some View {
        ZStack {
            Color("Background")
            TimelineView(.animation(paused: nav.phase == .offline)) { t in
                let wave = (1 - cos(t.date.timeIntervalSinceReferenceDate * .pi)) / 2   // 0…1, every 2 s
                Image("Mark")
                    .opacity(nav.phase == .loading ? 0.3 + 0.3 * wave : 1)
                    .scaleEffect(nav.phase == .waiting ? 1 + 0.05 * wave : 1)
            }
            if nav.phase == .offline {
                VStack(spacing: 14) {
                    Text("No connection").font(.headline).foregroundStyle(.black)
                    Button("Try again") { nav.phase = .loading; nav.retries += 1 }
                        .buttonStyle(.borderedProminent).tint(.black)
                }
                    .offset(y: 150)              // under the logo, so the logo never moves
            }
        }
            .ignoresSafeArea()
    }
}
