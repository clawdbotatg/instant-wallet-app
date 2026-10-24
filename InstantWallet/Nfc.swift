// Writes one link to an NFC card (window.wedgieNfc.write). The site's Share screen puts money on a new key, then
// writes its claim link here. Never locks the tag: locking is permanent.
import CoreNFC
import WebKit

@MainActor
final class Nfc: NSObject, NFCNDEFReaderSessionDelegate {
    static let shared = Nfc()
    private var session: NFCNDEFReaderSession?
    private var done: ((String?) -> Void)?   // nil = written, else the error
    private var url: URL?

    static var available: Bool { NFCNDEFReaderSession.readingAvailable }

    func write(_ url: URL, _ done: @escaping (String?) -> Void) {
        guard Nfc.available else { return done("This phone can't write NFC") }
        guard session == nil else { return done("Already writing a card") }
        self.url = url
        self.done = done
        let s = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        s.alertMessage = "Hold the card to the top of your phone"
        session = s
        s.begin()
    }

    private func finish(_ err: String?) {
        let d = done
        done = nil
        session = nil
        d?(err)
    }

    nonisolated func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let e = error as? NFCReaderError
        // after a write `done` is already nil, so this only reports a cancel or a failure
        let msg = e?.code == .readerSessionInvalidationErrorUserCanceled ? "Cancelled" : error.localizedDescription
        Task { @MainActor in self.finish(msg) }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "One card at a time"
            return session.restartPolling()
        }
        Task { @MainActor in
            guard let url = self.url, let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url) else {
                session.invalidate(errorMessage: "Bad link")
                return self.finish("Bad link")
            }
            do {
                try await session.connect(to: tag)
                let (status, capacity) = try await tag.queryNDEFStatus()
                guard status == .readWrite else { throw Msg(status == .readOnly ? "This card is locked" : "Not a writable card") }
                let message = NFCNDEFMessage(records: [payload])
                guard message.length <= capacity else { throw Msg("The card is too small") }
                try await tag.writeNDEF(message)
                session.alertMessage = "Done"
                session.invalidate()
                self.finish(nil)
            } catch {
                let m = (error as? Msg)?.text ?? error.localizedDescription
                session.invalidate(errorMessage: m)
                self.finish(m)
            }
        }
    }

    private struct Msg: Error { let text: String; init(_ t: String) { text = t } }
}

/// window.wedgieNfc's native side. Only the site's own pages get an answer.
final class NfcBridge: NSObject, WKScriptMessageHandlerWithReply {
    @MainActor
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host.lowercased() == SITE.host,
              let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return replyHandler(nil, "not allowed")
        }
        switch op {
        case "available":
            replyHandler(Nfc.available, nil)
        case "write":
            guard let s = body["arg"] as? String, let u = URL(string: s), u.host?.lowercased() == SITE.host else {
                return replyHandler(nil, "bad link")
            }
            Nfc.shared.write(u) { err in err == nil ? replyHandler("ok", nil) : replyHandler(nil, err) }
        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }
}
