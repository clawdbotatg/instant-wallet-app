// The WEDGIE drive: how this app reaches a wedgie (an iPhone can't open its USB serial port without MFi, but it
// mounts USB drives, and every wedgie is one). Ported from wedgie-dev ios/WedgieDrive; the why and the
// gotchas are in instant-wallet docs/WEDGIE-PHONE.md.
//
// Pick the drive's top folder once (a security-scoped bookmark keeps it). The drive is read-only until we
// knock (firmware 0.3.41+: read KNOCKB, KNOCKA, KNOCKB; no question), then it drops off USB for 2 s and comes
// back writable until unplug. 0.3.37-0.3.40 knock by reading PHONE.TXT twice and ask for a green press.
// Send = a new REQ-<n>.TXT (one JSON request). Answers come back in ANSWER.TXT ("#<count>", then JSON lines).
import Foundation
import SwiftUI

struct LogLine: Identifiable {
    let id = UUID()
    let at = Date()
    let kind: Kind
    let text: String
    enum Kind { case sent, info, error }
}

/// File work on the drive, on its own thread. Every call resolves the bookmark and opens and closes the
/// security scope itself, so an unplug between calls is just an error, never a stale handle.
/// A wedged drive can hang a file call for good (seen 10-10: the app never got past its splash), so every
/// call gives up after a few seconds and nothing else in the app ever waits on the drive's thread.
final class DriveIO: @unchecked Sendable {
    static let bookmarkKey = "wedgieDriveBookmark"
    private let q = DispatchQueue(label: "io.instantwallet.drive")
    private let lock = NSLock()
    private var queued = 0

    /// Run body on the drive's thread; "plug in your wedgie" if it takes longer than `limit` or calls pile up
    /// behind a hung one.
    private func run<T>(_ limit: Double = 4, _ body: @escaping () throws -> T) async throws -> T {
        lock.lock()
        if queued >= 3 { lock.unlock(); throw DriveError.away }
        queued += 1
        lock.unlock()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let done = Once()
            q.async {
                let r = Result { try body() }
                self.lock.lock(); self.queued -= 1; self.lock.unlock()
                if done.take() { c.resume(with: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { if done.take() { c.resume(throwing: DriveError.away) } }
        }
    }

    func check() async throws -> URL { try await run { try self.checkNow() } }
    func readOnly() async throws -> Bool { try await run { try self.readOnlyNow() } }
    func exists(_ name: String) async throws -> Bool { try await run { try self.with { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } } }
    func read(_ name: String) async throws -> String? { try await run { try self.readNow(name) } }
    func send(_ line: String) async throws -> String { try await run(10) { try self.sendNow(line) } }
    func resolve() async throws -> URL { try await run { try self.resolveNow() } }

    private func resolveNow() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { throw DriveError.notPicked }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
        }
        return url
    }

    private func with<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolveNow()
        guard url.startAccessingSecurityScopedResource() else { throw DriveError.noAccess }
        defer { url.stopAccessingSecurityScopedResource() }
        guard (try? url.checkResourceIsReachable()) == true else { throw DriveError.away }
        return try body(url)
    }

    /// Is this folder the WEDGIE drive? Every wedgie's drive has these at its top (wedgie firmware/drive.bin).
    nonisolated static func isWedgie(_ root: URL) -> Bool {
        ["README.txt", "SKILL.md"].allSatisfy { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
    }

    /// Plugged in? Returns its folder, or throws why not.
    private func checkNow() throws -> URL {
        try with { root in
            guard Self.isWedgie(root) else { throw DriveError.notWedgie }
            return root
        }
    }

    private func readOnlyNow() throws -> Bool {
        try with { root in (try? root.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false }
    }

    /// Uncached, or iOS hands back its old copy of ANSWER.TXT.
    private func readNow(_ name: String) throws -> String? {
        try with { root in
            let file = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            var out: Data?, cerr: NSError?, rerr: Error?
            NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &cerr) { u in
                do { out = try Data(contentsOf: u, options: .uncached) } catch { rerr = error }
            }
            if let e = cerr ?? rerr { throw e }
            return String(decoding: (out ?? Data()).prefix(20000), as: UTF8.self)
        }
    }

    /// Write a line as a new REQ-<n>.TXT (the wedgie reads each file once, 0.7 s after the last write). Every old
    /// REQ file goes first (and iOS's ._REQ twins, and a half-written one from a failed send): the wedgie keeps
    /// what's written in RAM, 12 sectors at most, and frees a deleted file's only once the drive's FAT says it's
    /// free. Safe because the page sends one at a time, only after the last one's answer (the wedgie has read it).
    /// iOS kept the deletes in its cache, so the FAT never said free and a big tx's third piece always failed
    /// (10-10): flush the volume after deleting and after writing.
    private func sendNow(_ line: String) throws -> String {
        try with { root in
            let fm = FileManager.default
            var gone = 0
            for u in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let n = u.lastPathComponent.uppercased()
                guard n.hasPrefix("REQ-") || n.hasPrefix("._REQ-") else { continue }
                if (try? fm.removeItem(at: u)) != nil { gone += 1 }
            }
            if gone > 0 { Self.flush(root) }
            let d = UserDefaults.standard
            let n = d.integer(forKey: "wedgieReqN") % 9999 + 1
            d.set(n, forKey: "wedgieReqN")
            let name = "REQ-\(n).TXT"
            let file = root.appendingPathComponent(name)
            do { try Data((line + "\n").utf8).write(to: file) }
            catch {
                try? fm.removeItem(at: file)            // a half-written one would hold the wedgie's RAM
                Self.flush(root)
                throw error
            }
            Self.flush(root)
            return name
        }
    }

    /// Push what iOS still holds for the drive (deletes, folder and FAT changes) out to the wedgie now. Best effort:
    /// the drive's file system may not do fsync (a FileHandle.synchronize there failed every send, 10-10).
    private static func flush(_ root: URL) {
        let fd = open(root.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
        sync()
    }
}

/// The first of two racers (the work, the time limit) wins; the other does nothing.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

enum DriveError: LocalizedError {
    case notPicked, noAccess, away, notWedgie
    var errorDescription: String? {
        switch self {
        case .notPicked: return "pick the WEDGIE drive first"
        case .noAccess: return "iOS said no to the drive: pick it again"
        case .away: return "plug in your wedgie"
        case .notWedgie: return "that folder isn't the WEDGIE drive"
        }
    }
}

/// What the panel and the page see. Polls the drive every half second while the app is in front.
@MainActor final class Drive: ObservableObject {
    static let shared = Drive()
    enum State: String { case unpicked, away, here }

    @Published var state: State = UserDefaults.standard.data(forKey: DriveIO.bookmarkKey) == nil ? .unpicked : .away
    @Published var name = ""
    @Published var log: [LogLine] = []
    @Published var showPanel = ProcessInfo.processInfo.arguments.contains("-panel") {   // -panel: open on it (screenshots)
        didSet { if !showPanel { closeWhenIn = false } }    // closed by any means (X, swipe): the page's wait gives up
    }
    @Published var readOnly = false         // plugged in, not let in yet: it can't take requests
    @Published var wrongPick: String?       // the folder last picked when it wasn't the WEDGIE drive
    @Published var knocked: Date?           // when we started knocking, until it's writable
    /// Its firmware asks for a green press before it turns writable (0.3.37-0.3.40: PHONE.TXT on the drive).
    @Published var asksFirst = false
    private var asking: Task<Void, Never>?
    /// The page opened the panel to sign: it closes by itself once the phone is in.
    @Published var closeWhenIn = false
    /// The drive's folder, last time it was seen: where the picker starts (resolving the bookmark on the main
    /// thread could hang on a wedged drive).
    var lastURL: URL?

    let io = DriveIO()
    private var timer: Timer?
    private var checking = false

    /// Writable and plugged in: requests can go.
    var ready: Bool { state == .here && !readOnly }

    func note(_ kind: LogLine.Kind, _ text: String) {
        log.insert(LogLine(kind: kind, text: text), at: 0)
        if log.count > 200 { log.removeLast() }
        // Also to Documents/log.txt, so a Mac can read it: devicectl device copy from --domain-type appDataContainer
        let f = URL.documentsDirectory.appending(path: "log.txt")
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(kind) \(text)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: f) }
    }

    func start() {
        if timer == nil { note(.info, "app in front: watching the drive") }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Task { @MainActor in await Drive.shared.tick() } }
        Task { await tick() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// The page asks for the panel. connect: it wants to sign now, so ask right away and close once allowed.
    func open(connect: Bool) {
        closeWhenIn = connect && !ready
        showPanel = !(connect && ready)
        if state == .here, readOnly { ask() }
    }

    /// From the folder picker (still inside its security scope): keep a bookmark for every later use.
    func picked(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard DriveIO.isWedgie(url) else {
            wrongPick = url.lastPathComponent
            note(.error, "picked \(url.lastPathComponent): not the WEDGIE drive (no README.txt + SKILL.md)")
            return
        }
        wrongPick = nil
        do {
            UserDefaults.standard.set(try url.bookmarkData(), forKey: DriveIO.bookmarkKey)
            note(.info, "picked \(url.lastPathComponent) at \(url.path)")
            state = .away
            Task { await tick() }       // tick knocks right away
        } catch {
            note(.error, "couldn't keep the drive: \(error.localizedDescription)")
        }
    }

    /// Back to no drive picked, to walk through picking it again.
    func forget() {
        UserDefaults.standard.removeObject(forKey: DriveIO.bookmarkKey)
        lastURL = nil
        state = .unpicked; name = ""; readOnly = false; knocked = nil
        note(.info, "forgot the drive")
    }

    func tick() async {
        guard !checking, state != .unpicked else { return }
        checking = true
        defer { checking = false }
        let was = state
        do {
            let root = try await io.check()
            name = root.lastPathComponent
            lastURL = root
            state = .here
            let ro = (try? await io.readOnly()) ?? false
            if ro != readOnly || was != .here {
                readOnly = ro
                if ro {
                    let old = (try? await io.exists("PHONE.TXT")) == true
                    let new = (try? await io.exists("KNOCKB.TXT")) == true
                    asksFirst = old && !new
                }
                note(.info, ro ? "read-only: not let in yet" : "let in: writable")
                if !ro { knocked = nil }
            }
        } catch DriveError.notWedgie {
            let n = (try? await io.resolve())?.lastPathComponent ?? ""
            forget()
            wrongPick = n
            return
        } catch {
            if was != .away { note(.info, "drive: \(error.localizedDescription)") }
            state = .away
        }
        if was != state {
            note(.info, state == .here ? "wedgie plugged in (\(name))" : "wedgie unplugged")
        }
        // knocked, then gone for good (unplugged, not the 2 s drop after a knock): not connecting any more
        if state == .away, let k = knocked, Date().timeIntervalSince(k) > 20 { knocked = nil }
        // Plugged in but read-only: knock, without a tap (the app is in front: tick only runs then).
        if state == .here, readOnly { ask() }
        if closeWhenIn && ready {
            closeWhenIn = false
            try? await Task.sleep(for: .milliseconds(900))      // let "Connected" show for a moment
            showPanel = false
        }
    }

    /// Send one request line (the page adds its id). Returns the REQ file name.
    func send(_ line: String) async throws -> String {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let file = try await io.send(text)
            note(.sent, "\(file): \(text.prefix(200))")
            return file
        } catch {
            note(.error, "send failed (\(text.count) chars): \(error.localizedDescription)")
            throw error
        }
    }

    /// Knock until the drive is writable, while the app is in front. Firmware 0.3.41+: read KNOCKB, KNOCKA,
    /// KNOCKB, each 0.3-3 s after the last (0.5 s here), uncached; it turns writable with no question, and a scan
    /// can't knock (it reads A then B milliseconds apart). Older (0.3.37-0.3.40): PHONE.TXT read twice 0.7-10 s
    /// apart, not in its first 8 s, then a green press; one read per round, rounds ~2 s apart, does it. Both every
    /// round: it costs nothing, and we can't know when it was plugged in, so we never wait, we just keep on. Extra
    /// knocks are ignored once it's writable. (One knock that landed in the old 8 s did nothing: "Ask again",
    /// 10-11.)
    func ask() {
        guard asking == nil else { return }
        knocked = Date()
        note(.info, asksFirst ? "knocking (old firmware): press green on the wedgie" : "knocking: it turns writable by itself")
        asking = Task { @MainActor in
            defer { asking = nil }
            while timer != nil, state == .here, readOnly, !Task.isCancelled {
                for f in ["KNOCKB.TXT", "KNOCKA.TXT", "KNOCKB.TXT"] {
                    _ = try? await io.read(f)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                _ = try? await io.read("PHONE.TXT")
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }
}
