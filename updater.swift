// Updates from GitHub (same updater as Mountpoint/MarkTheRoughcut): when a newer release is out, a small window
// offers it – install, later, or skip this version. App menu → "Nach Updates suchen …" checks by hand.
import AppKit
import CryptoKit
import SwiftUI

/// Version from a release tag like "v1.2" or "v1.3.0-beta.2". Final releases rank above their betas.
struct AppVersion: Comparable, Equatable {
    let numbers: [Int]
    let beta: Int?   // nil = final release

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let nums = first.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(nil) else { return nil }
        numbers = nums.map { $0! }
        if parts.count == 2 {
            guard let b = Int(parts[1].lowercased().replacingOccurrences(of: "beta.", with: "")) else { return nil }
            beta = b
        } else {
            beta = nil
        }
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }   // 1.2 == 1.2.0

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.numbers.count, b.numbers.count)
        let x = a.numbers + Array(repeating: 0, count: n - a.numbers.count)
        let y = b.numbers + Array(repeating: 0, count: n - b.numbers.count)
        if x != y { return x.lexicographicallyPrecedes(y) }
        switch (a.beta, b.beta) {
        case let (p?, q?): return p < q
        case (_?, nil): return true
        default: return false
        }
    }
}

struct Release: Equatable {
    let tag: String
    let page: URL
    let zip: URL
    /// `<zip>.sig`: Ed25519 signature of the zip (scripts/update-key.swift)
    let signature: URL
    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    static let releasesPage = URL(string: "https://github.com/moritz-poth/Tapedeck/releases")!
    /// Release page, but only on this project's GitHub – otherwise the list of releases.
    var safePage: URL { page.absoluteString.hasPrefix(Release.releasesPage.absoluteString + "/") ? page : Release.releasesPage }
}

/// Newest final, non-draft release with a signed Tapedeck zip, from GitHub's releases JSON.
func newestRelease(fromJSON data: Data) -> Release? {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    struct R: Decodable { let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool?; let assets: [Asset] }
    guard let list = try? JSONDecoder().decode([R].self, from: data) else { return nil }
    return list
        .filter { !$0.draft && $0.prerelease != true && AppVersion($0.tag_name) != nil }
        .compactMap { r -> (AppVersion, Release)? in
            guard let zip = r.assets.first(where: { $0.name.hasPrefix("Tapedeck-") && $0.name.hasSuffix(".zip") }),
                  let sig = r.assets.first(where: { $0.name == zip.name + ".sig" }) else { return nil }
            return (AppVersion(r.tag_name)!, Release(tag: r.tag_name, page: r.html_url, zip: zip.browser_download_url, signature: sig.browser_download_url))
        }
        .max { $0.0 < $1.0 }?.1
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case failed(String)
    }

    @Published var available: Release?
    @Published var state = State.idle

    static let current = Bundle.main.object(forInfoDictionaryKey: "TapedeckRelease") as? String ?? "dev"
    /// Public half of the update key (scripts/update-key.swift): only zips signed with it are installed –
    /// the codesign check alone proves the app is intact, not who made it (ad-hoc signature).
    nonisolated static let publicKey = "PXulUHipJv/ROBsA0HdJx6IH+sEypN42ZVa50EWALoQ="
    private static let api = URL(string: "https://api.github.com/repos/moritz-poth/Tapedeck/releases?per_page=20")!
    private static let skipKey = "skippedVersion"

    /// Opens the update window (set by the record window, which has `openWindow`).
    var show: () -> Void = {}
    /// Why installing has to wait (a recording runs, an edit is unsaved), or nil.
    var busyReason: () -> String? = { nil }
    private var timer: Timer?

    /// Checks shortly after launch and then every 6 hours, quietly; the window only appears for a new version.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
    }

    /// `manual`: from the menu – always shows the window, also for "up to date", errors and a skipped version.
    func check(manual: Bool) {
        guard state != .checking, state != .installing else { if manual { show() }; return }
        if manual { state = .checking; show() }
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = ok ? data.flatMap(newestRelease(fromJSON:)) : nil
            Task { @MainActor in
                guard self.state != .installing else { return }
                if let release, let new = AppVersion(release.tag), let mine = AppVersion(Self.current), mine < new {
                    self.available = release
                    self.state = .idle
                    if manual || UserDefaults.standard.string(forKey: Self.skipKey) != release.tag { self.show() }
                } else if ok {
                    self.available = nil
                    if manual { self.state = .upToDate }
                } else if manual {
                    self.state = .failed("Tapedeck konnte nicht nach Updates suchen. Bitte die Internetverbindung prüfen und es noch einmal versuchen.")
                }
            }
        }.resume()
    }

    /// "Diese Version überspringen": no more automatic window for it (the menu still finds it).
    func skip() {
        if let tag = available?.tag { UserDefaults.standard.set(tag, forKey: Self.skipKey) }
    }

    /// Downloads the zip and its signature, checks both, swaps the app and restarts. The old version goes to the Trash.
    func install() {
        guard let release = available, state != .installing else { return }
        if let busy = busyReason() { state = .failed(busy); return }
        state = .installing
        Task {
            let signature = try? await Self.session.data(from: release.signature).0
            Self.session.downloadTask(with: release.zip) { file, response, _ in
                let result: Result<URL, Error>
                if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                    result = Result { try Self.unpack(file, expecting: release.tag, signature: signature) }
                } else {
                    result = .failure(UpdateError("Das Update konnte nicht geladen werden. Bitte die Internetverbindung prüfen und es noch einmal versuchen."))
                }
                Task { @MainActor in
                    switch result {
                    case .success(let app):
                        do { try self.swapAndRestart(with: app) } catch { self.state = .failed(error.localizedDescription) }
                    case .failure(let error):
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }.resume()
        }
    }

    /// A hanging download ends after 2 minutes with a message instead of waiting forever.
    nonisolated private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        return URLSession(configuration: c)
    }()

    /// The zip was signed with the update key (checked before anything in it is unpacked or run).
    nonisolated static func signatureValid(_ zip: Data, _ signature: Data?, publicKey: String = Updater.publicKey) -> Bool {
        guard let signature, let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(sig, for: zip)
    }

    /// Unzips into a temporary folder and checks that it really is the expected, intact Tapedeck version.
    nonisolated static func unpack(_ zip: URL, expecting tag: String, signature: Data?, publicKey: String = Updater.publicKey,
                                   bundleID: String? = Bundle.main.bundleIdentifier) throws -> URL {
        let damaged = UpdateError("Das geladene Update ist beschädigt. Bitte später noch einmal versuchen oder es von GitHub laden.")
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe), signatureValid(data, signature, publicKey: publicKey) else { throw damaged }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tapedeck-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) else { throw damaged }
        let app = dir.appendingPathComponent("Tapedeck.app")
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID,
              let release = info["TapedeckRelease"] as? String,
              AppVersion(release) == AppVersion(tag),
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        else { throw damaged }
        return app
    }

    private func swapAndRestart(with app: URL) throws {
        // a recording may have started while downloading
        if let busy = busyReason() { throw UpdateError(busy) }
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let cannot = "Tapedeck konnte sich nicht selbst ersetzen. Bitte Tapedeck in den Programme-Ordner legen oder das Update von GitHub laden."
        var trashed: NSURL?
        do {
            try fm.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            throw UpdateError(cannot + "\n\nDetails: \(error.localizedDescription)")
        }
        do {
            try fm.moveItem(at: app, to: current)
        } catch {
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: current) }
            throw UpdateError(cannot + "\n\nDetails: \(error.localizedDescription)")
        }
        // start the new version once this one has quit
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       current.path, String(ProcessInfo.processInfo.processIdentifier)]
        do { try p.run() } catch {
            state = .failed("Das Update ist installiert. Bitte Tapedeck beenden und neu öffnen.")
            return
        }
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Update window

struct UpdateView: View {
    @ObservedObject var updater = Updater.shared
    @Environment(\.dismiss) private var dismiss

    private func line(_ s: String, color: Color = Deck.label) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("tapedeck").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(Deck.ink)
                        Text("update").font(.system(size: 15, weight: .light)).tracking(-0.2).foregroundStyle(Deck.label)
                    }
                    switch updater.state {
                    case .checking:
                        HStack(spacing: 8) { ProgressView().controlSize(.small); line("Suche nach Updates …") }
                    case .installing:
                        HStack(spacing: 8) { ProgressView().controlSize(.small); line("Update wird geladen und installiert …") }
                        line("Tapedeck startet danach neu.")
                    case .upToDate:
                        line("Tapedeck \(Updater.current) ist die neueste Version.")
                    case .failed(let message):
                        line(message, color: Deck.red)
                    case .idle:
                        if let r = updater.available {
                            line("Tapedeck \(r.version) ist da. Installiert ist \(Updater.current).")
                            line("Installieren lädt die neue Version, ersetzt Tapedeck und startet es neu.")
                            Button("Was ist neu?") { NSWorkspace.shared.open(r.safePage) }
                                .buttonStyle(.link).font(.system(size: 12))
                        } else {
                            line("Tapedeck \(Updater.current) ist die neueste Version.")
                        }
                    }
                }
            }
            .frame(width: 300, alignment: .leading)

            HStack {
                Spacer()
                if updater.available != nil && updater.state != .upToDate {
                    VStack(spacing: 8) {
                        KeyTray {
                            Button("Diese Version überspringen") { updater.skip(); dismiss() }.buttonStyle(DeckKeyStyle())
                                .help("Diese Version überspringen – Tapedeck meldet sich erst bei der nächsten wieder")
                            Button("Später") { dismiss() }.buttonStyle(DeckKeyStyle())
                                .keyboardShortcut(.cancelAction).help("Später erinnern")
                            Button("Installieren") { updater.install() }.buttonStyle(DeckKeyStyle(latched: updater.state == .installing))
                                .keyboardShortcut(.defaultAction).help("Update installieren (↩)")
                        }
                        .disabled(updater.state == .installing)
                        KeyLabels(texts: ["überspringen", "später", "installieren"])
                    }
                } else {
                    VStack(spacing: 8) {
                        KeyTray {
                            Button("OK") { dismiss() }.buttonStyle(DeckKeyStyle())
                                .keyboardShortcut(.defaultAction).disabled(updater.state == .checking)
                        }
                        KeyLabels(texts: ["ok"])
                    }
                }
                Spacer()
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .fixedSize()
        .background(Deck.panel)
        .environment(\.colorScheme, .light)
    }
}
