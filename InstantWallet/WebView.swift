// One full-screen WKWebView on the site. What a plain web view gets wrong, fixed:
//   1. camera — the QR scanner's getUserMedia is granted for the site, so WebKit
//      doesn't re-ask every launch (iOS asks once, for the app);
//   2. links — window.open / target=_blank and links off the site go to Safari;
//   3. a killed content process reloads the page instead of a white screen;
//   4. load state drives the Splash: waiting when the page is up, ready when the
//      site posts `ready` (balance in) or after WAIT_MAX, offline on a failed load;
//   5. the wedgie: `window.wedgieDrive` (only on the site) reaches a wedgie through its
//      WEDGIE drive (Drive.swift). The site's web/lib/safe/wedgie.ts uses it:
//        status()      -> {state: "unpicked"|"away"|"readonly"|"here", name, panel, connecting, press}
//                         (connecting: knocking or remounting; press: its firmware asks for a green press first)
//        send(line)    -> the REQ file name it wrote (one JSON request, with its id)
//        read(name)    -> the file's text, or null
//        panel(mode)   -> opens the wedgie panel; "connect": close it once the drive is writable
//        log(text)     -> a line in the app's log (Documents/log.txt), "page: ..."
//   6. NFC: `window.wedgieNfc` (only on the site) writes a claim link to a card (Nfc.swift).
//        available()   -> true if this phone can write NFC
//        write(url)    -> "ok" once written (an instantwallet.io link only), rejects with the error
import SwiftUI
import WebKit

private let bridgeJS = """
(() => {
  if (location.hostname !== "\(SITE.host!)") return;
  const call = (op, arg) => window.webkit.messageHandlers.wedgieDrive.postMessage({ op, arg });
  window.wedgieDrive = {
    status: () => call("status"),
    send: (line) => call("send", typeof line === "string" ? line : JSON.stringify(line)),
    read: (name) => call("read", name),
    panel: (mode) => call("panel", mode || ""),
    log: (text) => call("log", String(text).slice(0, 2000)),
  };
  const nfc = (op, arg) => window.webkit.messageHandlers.wedgieNfc.postMessage({ op, arg });
  window.wedgieNfc = {
    available: () => nfc("available"),
    write: (url) => nfc("write", String(url)),
  };
})();
"""

// Only a ceiling for a balance that never comes (API down, bad signal): the
// wallet stays reachable. Never a minimum — ready shows the wallet at once.
let WAIT_MAX: TimeInterval = 5
// The hard ceiling: whatever is slow or stuck, the wallet shows this long after launch.
let LOAD_MAX: TimeInterval = 8

struct WebView: UIViewRepresentable {
    @ObservedObject var nav: Nav

    func makeCoordinator() -> Coordinator { Coordinator(nav: nav) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true     // the scanner's <video> plays in the page, not full screen
        cfg.websiteDataStore = .default()        // persistent: localStorage, the wallet
        cfg.applicationNameForUserAgent = "instant-wallet-app"
        cfg.userContentController.add(context.coordinator, name: "ready")   // the site: balance is on screen
        cfg.userContentController.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addScriptMessageHandler(DriveBridge(), contentWorld: .page, name: "wedgieDrive")
        cfg.userContentController.addScriptMessageHandler(NfcBridge(), contentWorld: .page, name: "wedgieNfc")

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
        DispatchQueue.main.asyncAfter(deadline: .now() + LOAD_MAX) { [nav] in
            if nav.phase == .loading || nav.phase == .waiting { nav.phase = .ready }
        }
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

/// window.wedgieDrive's native side. Only the site's own pages get an answer.
final class DriveBridge: NSObject, WKScriptMessageHandlerWithReply {
    @MainActor
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host.lowercased() == SITE.host,
              let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return replyHandler(nil, "not allowed")
        }
        let arg = body["arg"] as? String
        let drive = Drive.shared
        Task { @MainActor in
            do {
                switch op {
                case "status":
                    let state = drive.state == .here && drive.readOnly ? "readonly" : drive.state.rawValue
                    replyHandler(["state": state, "name": drive.name, "panel": drive.showPanel,
                                  "connecting": drive.knocked != nil, "press": drive.asksFirst,
                                  "healing": drive.healing], nil)
                case "send":
                    guard let arg else { return replyHandler(nil, "nothing to send") }
                    replyHandler(try await drive.send(arg), nil)
                case "read":
                    replyHandler(try await drive.io.read(arg ?? "ANSWER.TXT"), nil)
                case "log":                 // the page's side of a drive conversation, in the same log
                    drive.note(.info, "page: \(arg ?? "")")
                    replyHandler(true, nil)
                case "panel":
                    drive.open(connect: arg == "connect")
                    replyHandler(true, nil)
                default:
                    replyHandler(nil, "unknown op \(op)")
                }
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }
}
