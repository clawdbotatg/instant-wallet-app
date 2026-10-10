// One full-screen WKWebView on the site. What a plain web view gets wrong, fixed:
//   1. camera — the QR scanner's getUserMedia is granted for the site, so WebKit
//      doesn't re-ask every launch (iOS asks once, for the app);
//   2. links — window.open / target=_blank and links off the site go to Safari;
//   3. a killed content process reloads the page instead of a white screen;
//   4. load state drives the Splash: waiting when the page is up, ready when the
//      site posts `ready` (balance in) or after WAIT_MAX, offline on a failed load.
import SwiftUI
import WebKit

// Only a ceiling for a balance that never comes (API down, bad signal): the
// wallet stays reachable. Never a minimum — ready shows the wallet at once.
let WAIT_MAX: TimeInterval = 5

struct WebView: UIViewRepresentable {
    @ObservedObject var nav: Nav

    func makeCoordinator() -> Coordinator { Coordinator(nav: nav) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true     // the scanner's <video> plays in the page, not full screen
        cfg.websiteDataStore = .default()        // persistent: localStorage, the wallet
        cfg.applicationNameForUserAgent = "instant-wallet-app"
        cfg.userContentController.add(context.coordinator, name: "ready")   // the site: balance is on screen

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .never   // the page reads env(safe-area-inset-*) itself
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = false
        context.coordinator.loaded = nav.url
        wv.load(URLRequest(url: nav.url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if nav.retries != context.coordinator.retries {
            context.coordinator.retries = nav.retries
            wv.load(URLRequest(url: context.coordinator.loaded ?? SITE))
        } else if nav.url != context.coordinator.loaded {
            context.coordinator.loaded = nav.url
            wv.load(URLRequest(url: nav.url))
        }
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: URL?
        var retries = 0
        let nav: Nav
        init(nav: Nav) { self.nav = nav }

        private func mine(_ host: String?) -> Bool { host?.lowercased() == SITE.host }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(mine(origin.host) && type == .camera ? .grant : .prompt)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url {
                if mine(u.host) { webView.load(URLRequest(url: u)) } else { UIApplication.shared.open(u) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame ?? true, let u = navigationAction.request.url {
                let s = u.scheme ?? ""
                let web = s == "http" || s == "https"
                if web ? !mine(u.host) : !["about", "blob", "data", "javascript"].contains(s) {
                    UIApplication.shared.open(u)     // other sites, mailto:, ethereum:, tel: → the system
                    return decisionHandler(.cancel)
                }
            }
            decisionHandler(.allow)
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if mine(message.frameInfo.securityOrigin.host), nav.phase == .loading || nav.phase == .waiting { nav.phase = .ready }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard nav.phase == .loading else { return }
            // only the wallet (/) has a balance to wait for; a claim link or /recover shows as soon as it's up
            if webView.url?.path != "/" { nav.phase = .ready; return }
            nav.phase = .waiting
            let tries = retries
            DispatchQueue.main.asyncAfter(deadline: .now() + WAIT_MAX) { [nav] in
                if tries == self.retries, nav.phase == .waiting { nav.phase = .ready }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        // a cancelled load (a newer one replaced it, or a link went to the system) isn't offline
        private func failed(_ error: Error) {
            let e = error as NSError
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
            if e.domain == "WebKitErrorDomain" && e.code == 102 { return }   // frame load interrupted
            nav.phase = .offline
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: loaded ?? SITE))
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(a, webView) ?? completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(a, webView) ?? completionHandler(false)
        }

        private func present(_ a: UIAlertController, _ v: UIView) -> Void? {
            guard let vc = v.window?.rootViewController else { return nil }
            (vc.presentedViewController ?? vc).present(a, animated: true)
            return ()
        }
    }
}
