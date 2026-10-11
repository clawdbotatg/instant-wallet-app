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

/// File work on the drive, on its own thread. The security scope is opened once and held while the drive
/// answers (see `held`); any failure drops it and the next call resolves the bookmark again, so an unplug
/// between calls is just an error, never a stale handle.
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
    /// What's on the drive's top folder as iOS shows it (name size), for the log.
    func listing() async throws -> String {
        try await run {
            try self.with { root in
                // hidden files too: iOS's own (._ AppleDouble, .Trashes) take the wedgie's 12 sectors of RAM
                ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [])) ?? [])
                    .map { u in
                        let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        return "\(u.lastPathComponent) \(v?.fileSize ?? -1) \(v?.contentModificationDate.map { Int($0.timeIntervalSince1970) % 100000 } ?? 0)"
                    }
                    .sorted().joined(separator: ", ")
            }
        }
    }
    /// iOS's own hidden writes on the drive (FileManager hides AppleDouble ._ files): the root's xattrs and
    /// every ._ file with its size and time. For the log.
    func hidden() async throws -> String {
        try await run {
            try self.with { root in
                var out: [String] = []
                let n = listxattr(root.path, nil, 0, 0)
                if n > 0 {
                    var buf = [CChar](repeating: 0, count: n)
                    listxattr(root.path, &buf, n, 0)
                    out.append("xattrs: " + String(decoding: buf.map { UInt8(bitPattern: $0 == 0 ? 44 : $0) }, as: UTF8.self))
                }
                if let d = opendir(root.path) {
                    while let e = readdir(d) {
                        let name = withUnsafePointer(to: e.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                        guard name.hasPrefix("._") || name.hasPrefix(".T") || name.hasPrefix(".S") else { continue }
                        var st = stat()
                        stat(root.appendingPathComponent(name).path, &st)
                        out.append("\(name) \(st.st_size) \(st.st_mtimespec.tv_sec % 100000)")
                    }
                    closedir(d)
                }
                return out.joined(separator: "; ")
            }
        }
    }
    /// The same file read a second way, POSIX open + F_NOCACHE (not NSFileCoordinator): its first line. For
    /// the log: if this one moves and the coordinated read doesn't, iOS is serving the other from a cache.
    func rawHead(_ name: String) async throws -> String {
        try await run {
            try self.with { root in
                let fd = open(root.appendingPathComponent(name).path, O_RDONLY)
                guard fd >= 0 else { return "open failed \(errno)" }
                defer { close(fd) }
                _ = fcntl(fd, F_NOCACHE, 1)
                var buf = [UInt8](repeating: 0, count: 64)
                let n = Darwin.read(fd, &buf, 64)
                return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).components(separatedBy: "\n")[0] : "read \(n) errno \(errno)"
            }
        }
    }
    func exists(_ name: String) async throws -> Bool { try await run { try self.with { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } } }
    func read(_ name: String) async throws -> String? { try await run { try self.readNow(name) } }
    /// A plain read, through iOS's cache, as a Files view would do it. Only the soak test uses it (-soakcache): does a
    /// cached copy freeze what the uncached reads see? (Bug 1, docs/WEDGIE-PHONE-DEBUG.md.)
    func readCached(_ name: String) async throws -> Int {
        try await run { try self.with { root in (try? Data(contentsOf: root.appendingPathComponent(name)))?.count ?? -1 } }
    }
    func send(_ line: String) async throws -> String { try await run(10) { try self.sendNow(line) } }
    func resolve() async throws -> URL { try await run { try self.resolveNow() } }

    private func resolveNow(_ saved: Data? = nil) throws -> URL {
        guard let data = saved ?? Self.bookmark() else { throw DriveError.notPicked }
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// The saved bookmark. Picking and forgetting set it straight away on the main thread (never through `run`,
    /// which turns calls away while the drive's thread is stuck: a new pick was lost that way, codex 10-11).
    private static let bookmarkLock = NSLock()
    static func bookmark() -> Data? {
        bookmarkLock.lock(); defer { bookmarkLock.unlock() }
        return UserDefaults.standard.data(forKey: bookmarkKey)
    }
    static func setBookmark(_ data: Data?) {
        bookmarkLock.lock(); defer { bookmarkLock.unlock() }
        if let data { UserDefaults.standard.set(data, forKey: bookmarkKey) } else { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
    }
    /// Swap in a fresh bookmark only if nobody picked or forgot since `old` was read.
    private static func refreshBookmark(from old: Data, to fresh: Data) -> Bool {
        bookmarkLock.lock(); defer { bookmarkLock.unlock() }
        guard UserDefaults.standard.data(forKey: bookmarkKey) == old else { return false }
        UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        return true
    }

    /// The drive's folder with its scope open, held while it answers: Apple says open a scope once and keep it,
    /// not per call (this app opened and closed it ~5 times a second, and at 4:40 on 10-11 iOS refused it in the
    /// middle of a signature, drive still mounted). Each time it opens, the bookmark is made again from it, so it
    /// names the drive's current mount (bookmarks don't resolve across volume mounts, Apple bug r.102995804; the
    /// drive remounts after every knock). Only touched on `q`.
    private var held: URL?
    private var sentAt: [String: Date] = [:]  // REQ files written this run, and when (sendNow); only touched on `q`
    private var heldFrom: Data?             // the bookmark `held` came from: a different one saved = picked again
    private func drop() { held?.stopAccessingSecurityScopedResource(); held = nil; heldFrom = nil }
    /// Forgotten: let go of the scope. Straight onto the queue, never turned away (it runs once the queue is free).
    func release() { q.async { self.drop() } }

    private func with<T>(_ body: (URL) throws -> T) throws -> T {
        guard let saved = Self.bookmark() else { drop(); throw DriveError.notPicked }
        if held != nil, heldFrom != saved { drop() }
        let opened = held == nil
        if opened {
            let url = try resolveNow(saved)
            guard url.startAccessingSecurityScopedResource() else { throw DriveError.noAccess }
            held = url
            heldFrom = saved
        }
        let url = held!
        guard (try? url.checkResourceIsReachable()) == true else { drop(); throw DriveError.away }
        if opened, let fresh = try? url.bookmarkData(), Self.refreshBookmark(from: saved, to: fresh) { heldFrom = fresh }
        do { return try body(url) } catch { drop(); throw error }
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
                // not one written in the last 2 s: the wedgie reads a file 0.7 s after the last write, and two
                // senders a moment apart (the page and the soak, 10-11) wiped each other's request
                let mine = n.hasPrefix("._") ? String(n.dropFirst(2)) : n
                if let at = sentAt[mine], Date().timeIntervalSince(at) < 2 { continue }
                if (try? fm.removeItem(at: u)) != nil { gone += 1; sentAt[mine] = nil }
            }
            if gone > 0 { Self.flush(root) }
            let d = UserDefaults.standard
            let n = d.integer(forKey: "wedgieReqN") % 9999 + 1
            d.set(n, forKey: "wedgieReqN")
            let name = "REQ-\(n).TXT"
            sentAt[name] = Date()
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

    @Published var state: State = DriveIO.bookmark() == nil ? .unpicked : .away
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
    private var lastHead = Date.distantPast
    /// Asking the wedgie to remount (heal): the page waits it out instead of failing.
    @Published var healing = false
    private var healedAt = Date.distantPast
    private var lastSent = Date.distantPast
    /// The wedgie's clock from ANSWER.TXT's first line (" t<ms>", 0.3.45+), stamped at every read that reaches it:
    /// the last one seen, when, and how many reads in a row came back with the same one.
    private var lastT = "", lastTAt = Date.distantPast, sameT = 0
    private var lastError = ""
    private var soaking = false
    private var refusedSince: Date?

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
        soak()
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
            DriveIO.setBookmark(try url.bookmarkData())     // the next drive call drops the old scope (heldFrom)
            note(.info, "picked \(url.lastPathComponent) at \(url.path)")
            state = .away
            Task { await tick() }       // tick knocks right away
        } catch {
            note(.error, "couldn't keep the drive: \(error.localizedDescription)")
        }
    }

    /// Back to no drive picked, to walk through picking it again.
    func forget() {
        DriveIO.setBookmark(nil)
        io.release()
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
            lastError = ""
            refusedSince = nil
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
            let e = error.localizedDescription
            if was != .away || e != lastError { note(.info, "drive: \(e)") }
            lastError = e
            state = .away
            // iOS refused the bookmark while the drive stayed mounted (10-11 4:40, mid-signature): each call opens it
            // again; still refused after 5 s, only a new pick helps (iOS needs a tap for the picker)
            if case DriveError.noAccess = error {
                refusedSince = refusedSince ?? Date()
                if Date().timeIntervalSince(refusedSince!) > 5 {
                    note(.error, "iOS keeps refusing the drive: pick it again")
                    refusedSince = nil
                    forget()
                    showPanel = true
                    return
                }
            } else { refusedSince = nil }
        }
        if was != state {
            note(.info, state == .here ? "wedgie plugged in (\(name))" : "wedgie unplugged")
        }
        // Is what we read real? Every second while writable, read ANSWER.TXT's first line: 0.3.45+ stamps its clock
        // into it at every read that reaches the wedgie. The same stamp three reads running (2 s) = iOS is serving
        // a cached copy (bug 1: minutes, after a re-pick): ask the wedgie to remount. Logged every 5 s.
        if ready, !healing, Date().timeIntervalSince(lastTAt) >= 1 {
            let head = (((try? await io.read("ANSWER.TXT")) ?? nil) ?? "").components(separatedBy: "\n")[0]
            if let r = head.range(of: #" t\d{10}"#, options: .regularExpression) {
                let t = String(head[r])
                sameT = t == lastT ? sameT + 1 : 0
                lastT = t
                if sameT >= 2 { heal("ANSWER.TXT came back the same 3 times in 2 s: [\(head)]") }
            }
            lastTAt = Date()
            if Date().timeIntervalSince(lastHead) >= 5 {
                lastHead = Date()
                note(.info, "head [\(head.trimmingCharacters(in: .whitespaces))]")
            }
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
            lastSent = Date()
            note(.sent, "\(file): \(text.prefix(200))")
            return file
        } catch {
            note(.error, "send failed (\(text.count) chars): \(error.localizedDescription)")
            throw error
        }
    }

    /// iOS is serving a cached copy of the drive (bug 1): ask the wedgie to remount (0.3.45+, `{"type":"remount"}`;
    /// writes still reach it while reads are stale). It answers, drops off USB for 2 s and comes back writable, and
    /// iOS mounts it again with nothing cached. The page sees `healing` and waits instead of failing. At most once
    /// every 20 s.
    func heal(_ why: String) {
        guard !healing, Date().timeIntervalSince(healedAt) > 20 else { return }
        healing = true
        healedAt = Date()
        note(.error, "stale view: \(why). Asking the wedgie to remount.")
        Task { @MainActor in
            defer { healing = false; sameT = 0; lastT = "" }
            // the page's last request: the wedgie reads it 0.7 s after the last write, and our send deletes old REQ files
            let wait = 1.5 - Date().timeIntervalSince(lastSent)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            do { _ = try await send(#"{"type":"remount","id":\#(Int.random(in: 1...999_999_999))}"#) }
            catch { note(.error, "remount: couldn't send it (\(error.localizedDescription))"); return }
            let t0 = Date()
            var gone = false
            while Date().timeIntervalSince(t0) < 15 {
                try? await Task.sleep(for: .milliseconds(250))
                if state != .here { gone = true }
                if gone && ready {
                    note(.info, "remounted: back in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    return
                }
            }
            note(.error, "remount: no drop and return in 15 s (gone: \(gone))")
        }
    }

    /// The soak test (launch with -soak; -soakcache also does a cached read every 5th round, to try to cause bug 1):
    /// requests nonstop with no taps (hello, then 4 safe_data pieces, never a signature), one log line each with its
    /// time. Started from a Mac: devicectl device process launch ... io.instantwallet -soak. Needs the Safe signer
    /// app running on the wedgie (safe_data); a hello alone works on anything.
    func soak() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-soak"), !soaking else { return }
        soaking = true
        let cached = args.contains("-soakcache")
        note(.info, "soak: on\(cached ? " (with cached reads)" : "")")
        Task { @MainActor in
            var round = 0, ok = 0, bad = 0
            var id = Int.random(in: 1_000_000...9_000_000) * 100
            while true {
                guard ready, !healing else { try? await Task.sleep(for: .seconds(1)); continue }
                round += 1
                if cached, round % 5 == 0 {
                    let n = (try? await io.readCached("ANSWER.TXT")) ?? -2
                    note(.info, "soak: cached read of ANSWER.TXT (\(n) bytes)")
                }
                var lines = [#"{"type":"hello""#]
                for at in stride(from: 0, to: 2800, by: 700) {
                    lines.append(#"{"type":"safe_data","at":\#(at),"hex":"\#(String(repeating: "00", count: 700))""#)
                }
                for l in lines {
                    id += 1
                    let t0 = Date()
                    let type = l.contains("hello") ? "hello" : "safe_data"
                    do { _ = try await send(l + #","id":\#(id)}"#) }
                    catch { bad += 1; note(.error, "soak \(round): \(type) \(id) send failed: \(error.localizedDescription)"); break }
                    var got = false
                    while Date().timeIntervalSince(t0) < 20, !got {
                        try? await Task.sleep(for: .milliseconds(300))
                        let a = ((try? await io.read("ANSWER.TXT")) ?? nil) ?? ""
                        got = a.contains(#""id": \#(id),"#) || a.contains(#""id": \#(id)}"#)
                    }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    if got { ok += 1; note(.info, "soak \(round): \(type) \(id) answered in \(ms) ms (ok \(ok), bad \(bad))") }
                    else { bad += 1; note(.error, "soak \(round): \(type) \(id) NO ANSWER in \(ms) ms (ok \(ok), bad \(bad))"); break }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                try? await Task.sleep(for: .seconds(1))
            }
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
