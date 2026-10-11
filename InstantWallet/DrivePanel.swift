// The wedgie panel: one simple screen in the wallet's look (find the drive, plug it in, let this phone in,
// connected). The site opens it through window.wedgieDrive.panel(); the log, Pick again and Forget sit behind
// Details. Ported from wedgie-dev ios/WedgieDrive/App/DrivePanel.swift.
import SwiftUI

private let paper = Color(red: 0.957, green: 0.957, blue: 0.945)      // --paper #f4f4f1
private let ink = Color(red: 0.102, green: 0.106, blue: 0.102)        // --ink #1a1b1a
private let muted = Color(red: 0.42, green: 0.43, blue: 0.42)         // --muted #6b6e6b
private let mint = Color(red: 0.133, green: 0.769, blue: 0.322)       // --mint #22c452
private let green = LinearGradient(colors: [Color(red: 0.275, green: 0.804, blue: 0.392), Color(red: 0.086, green: 0.549, blue: 0.204)],
                                   startPoint: .top, endPoint: .bottom)   // --green-fill
private let greenEdge = Color(red: 0.059, green: 0.431, blue: 0.157)  // #0f6e28

/// The site's big green button.
struct PillButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Capsule().fill(green))
                .background(Capsule().fill(greenEdge).offset(y: 4))
                .shadow(color: Color(red: 0.086, green: 0.549, blue: 0.204).opacity(0.45), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }
}

struct DrivePanel: View {
    @EnvironmentObject var drive: Drive
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var details = false

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(muted)
                            .frame(width: 40, height: 40).background(Circle().fill(.white))
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                if drive.state != .unpicked { ZStack(alignment: .topTrailing) {
                    Image("Wedgie").resizable().scaledToFit().frame(width: 180, height: 134)
                    Circle().fill(drive.ready ? mint : Color.gray.opacity(0.5))
                        .frame(width: 26, height: 26).overlay(Circle().stroke(paper, lineWidth: 4)).offset(x: 6, y: -4)
                } }
                Text(title)
                    .font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(ink)
                    .multilineTextAlignment(.center).padding(.top, drive.state == .unpicked ? 0 : 28)
                Text(subtitle)
                    .font(.system(size: 19, weight: .medium, design: .rounded)).foregroundStyle(muted)
                    .multilineTextAlignment(.center).padding(.top, 10)
                if drive.state == .unpicked { PickerHint().padding(.top, 30) }
                if drive.knocked != nil && (drive.readOnly || drive.state == .away) { WaitBar().padding(.top, 30) }
                Spacer()
                switch drive.state {
                case .unpicked: PillButton(title: "Find my wedgie") { picking = true }
                case .here:
                    if drive.ready { PillButton(title: "Done") { dismiss() } }
                    else { PillButton(title: drive.knocked == nil ? "Let this phone in" : "Ask again") { Task { await drive.knock() } } }
                case .away: EmptyView()
                }
                Button("Details") { details = true }
                    .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(muted)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
        }
        .sheet(isPresented: $picking) { FolderPicker { drive.picked($0) }.ignoresSafeArea() }
        .sheet(isPresented: $details) { DriveDetails() }
    }

    private var title: String {
        switch drive.state {
        case .unpicked: return drive.wrongPick == nil ? "Find your wedgie" : "That's not your wedgie"
        case .away: return drive.knocked != nil ? "Connecting" : "Plug in your wedgie"
        case .here: return drive.readOnly ? (drive.knocked == nil ? "Let this phone in" : "Press green") : "Connected"
        }
    }

    private var subtitle: String {
        switch drive.state {
        case .unpicked: return drive.wrongPick.map { "You picked \"\($0)\". Tap Browse, then WEDGIE, then Open." }
            ?? "Tap Find my wedgie. Then tap Browse, WEDGIE, Open. Only once."
        case .away: return drive.knocked != nil ? "Your wedgie is reconnecting." : "Plug it into this iPhone. It connects by itself."
        case .here: return drive.readOnly ? (drive.knocked == nil ? "Your wedgie asks first." : "Your wedgie is asking. Press its green button.")
            : "Your wedgie is plugged in."
        }
    }
}

/// The log, Pick again, Forget, and a hello to test the drive.
struct DriveDetails: View {
    @EnvironmentObject var drive: Drive
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Circle().fill(drive.ready ? .green : .gray).frame(width: 10, height: 10)
                        Text(status).font(.headline)
                    }
                    Button(drive.state == .unpicked ? "Pick the WEDGIE drive" : "Pick the drive again") { picking = true }
                    if drive.ready { Button("Send hello") { Task { _ = try? await drive.send(#"{"type":"hello","id":1}"#) } } }
                    if drive.state != .unpicked { Button("Forget the drive", role: .destructive) { drive.forget() } }
                }
                Section("Log") {
                    if drive.log.isEmpty { Text("nothing yet").foregroundStyle(.secondary) }
                    ForEach(drive.log) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.at.formatted(date: .omitted, time: .standard)).font(.caption)
                                .foregroundStyle(l.kind == .error ? .red : l.kind == .sent ? .blue : .secondary)
                            Text(l.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $picking) { FolderPicker { drive.picked($0) }.ignoresSafeArea() }
        }
    }

    private var status: String {
        switch drive.state {
        case .unpicked: return "No drive picked yet"
        case .away: return "Not plugged in"
        case .here: return (drive.readOnly ? "Plugged in, not let in" : "Connected") + (drive.name.isEmpty ? "" : " (\(drive.name))")
        }
    }
}

/// Apple's folder picker. iOS only starts it at a folder this app was given before (the kept bookmark), so the
/// first time it opens wherever the person last was, and PickerHint shows them the way.
struct FolderPicker: UIViewControllerRepresentable {
    let done: (URL) -> Void
    func makeCoordinator() -> Coord { Coord(done) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        var stale = false
        if let b = UserDefaults.standard.data(forKey: DriveIO.bookmarkKey),
           let u = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) { p.directoryURL = u }
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let done: (URL) -> Void
        init(_ d: @escaping (URL) -> Void) { done = d }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let u = urls.first { done(u) } }
    }
}

/// A picture of the next screen (Apple's picker, its Browse tab), drawn as a small phone so nobody taps it:
/// Locations with WEDGIE ringed, and the Browse tab ringed. The first pick opens wherever the person last was
/// (often Recents: no back button there, so Browse is the way in).
struct PickerHint: View {
    @State private var bob = false
    private let red = Color(red: 0.89, green: 0.19, blue: 0.17)
    var body: some View {
        VStack(spacing: 8) {
            Text("NEXT SCREEN").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(muted).kerning(1.2)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 34).fill(Color(white: 0.12))
                RoundedRectangle(cornerRadius: 27).fill(Color(white: 0.95)).padding(7)
                Capsule().fill(Color(white: 0.12)).frame(width: 56, height: 16).padding(.top, 15)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Locations").font(.system(size: 13, weight: .bold)).foregroundStyle(ink).padding(.leading, 6)
                    VStack(spacing: 0) {
                        row("cloud", "iCloud Drive", false)
                        row("iphone", "On My iPhone", false)
                        row("externaldrive", "WEDGIE", true)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .padding(.top, 6)
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        tab("clock", "Recents", false)
                        tab("folder.badge.person.crop", "Shared", false)
                        tab("folder.fill", "Browse", true)
                    }
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .padding(.bottom, 4)
                }
                .padding(.horizontal, 16).padding(.top, 40).padding(.bottom, 12)
            }
            .frame(width: 230, height: 250)
            .overlay(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "arrow.left").font(.system(size: 24, weight: .black))
                    Text("2. WEDGIE").font(.system(size: 15, weight: .heavy, design: .rounded)).padding(.top, 3)
                }
                .foregroundStyle(red).fixedSize()
                .offset(x: 96 + (bob ? -4 : 0), y: 117)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "arrow.left").font(.system(size: 24, weight: .black))
                    Text("1. Browse").font(.system(size: 15, weight: .heavy, design: .rounded)).padding(.top, 3)
                }
                .foregroundStyle(red).fixedSize()
                .offset(x: 96 + (bob ? -4 : 0), y: -22)
            }
            Text("3. tap Open").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(red)
        }
        .padding(.trailing, 70)
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { bob = true } }
    }

    private func row(_ icon: String, _ name: String, _ hot: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.blue).frame(width: 18)
            Text(name).font(.system(size: 12, weight: hot ? .bold : .regular)).foregroundStyle(hot ? ink : muted)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(muted)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .overlay(hot ? RoundedRectangle(cornerRadius: 9).stroke(red, lineWidth: 3).padding(1) : nil)
    }

    private func tab(_ icon: String, _ name: String, _ hot: Bool) -> some View {
        VStack(spacing: 1) {
            Image(systemName: icon).font(.system(size: 12))
            Text(name).font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(hot ? Color.blue : ink)
        .frame(maxWidth: .infinity, minHeight: 30)
        .overlay(hot ? Capsule().stroke(red, lineWidth: 3).padding(.horizontal, 2) : nil)
    }
}

/// After "Let this phone in": a green bar that keeps creeping (slower near the end) until it's connected.
struct WaitBar: View {
    @State private var start = Date()
    var body: some View {
        TimelineView(.animation) { t in
            let s = t.date.timeIntervalSince(start)
            let f = 0.95 * (1 - exp(-s / 6))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.85)).frame(height: 18)
                Capsule().fill(green).frame(width: max(18, 300 * f), height: 18)
            }
            .frame(width: 300)
        }
    }
}
