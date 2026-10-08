// Instant Wallet — the iOS app that IS the website. Same page, same passkeys:
// the passkey's RP ID is the page's hostname, so the app and Safari share them
// (iCloud Keychain). That needs the site's apple-app-site-association naming
// this app AND InstantWallet.entitlements naming the site.
//
// Not shared with Safari: localStorage. A wallet made in Safari shows up here
// only through its passkey.
import SwiftUI

let SITE = URL(string: "https://instant-wallet-b2jn.vercel.app/")!

final class Nav: ObservableObject {
    @Published var url = SITE
}

@main
struct InstantWalletApp: App {
    @StateObject private var nav = Nav()

    var body: some Scene {
        WindowGroup {
            WebView(nav: nav)
                .ignoresSafeArea()               // viewport-fit=cover: the page owns the notch + home bar
                .background(Color(red: 244 / 255, green: 244 / 255, blue: 241 / 255))
                .preferredColorScheme(.light)
                // a site link (claim card, camera QR) opens here instead of Safari
                .onOpenURL { u in if u.host == SITE.host { nav.url = u } }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    if let u = a.webpageURL, u.host == SITE.host { nav.url = u }
                }
        }
    }
}
