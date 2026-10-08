# Instant Wallet app

The iOS app for [Instant Wallet](https://instantwallet.io). It's the website in a native web view, nothing more.
The website lives in [clawdbotatg/instant-wallet](https://github.com/clawdbotatg/instant-wallet). Ship changes there.

- **Passkeys** work because the site serves `/.well-known/apple-app-site-association` naming
  `XX7QP5899Z.io.instantwallet` (`web/app/.well-known/…/route.ts` in the site repo), and
  `InstantWallet.entitlements` names the site. Both are required.
- **Site links** (claim cards, camera QR) open in the app (applinks).
- **Camera** for the QR scanner is granted to the site once.
- Not shared with Safari: localStorage. The passkey is shared (iCloud Keychain).

## Build

```
brew install xcodegen
xcodegen generate
open InstantWallet.xcodeproj      # pick your iPhone, Run
```

Team XX7QP5899Z, bundle id `io.instantwallet`. If you change either, change the site's AASA too.

If passkeys say "Cancelled" (NotAllowedError) on an Xcode build: the phone hasn't approved the app for the site.
The `?mode=developer` entries make Xcode builds check the site directly. Turn on Settings → Developer →
Associated Domains Development, then delete and reinstall the app. TestFlight/App Store builds ignore those entries.
