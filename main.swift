// Tapedeck: records what the Mac plays (system audio) and saves it as WAV 48 kHz / 24 bit.
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers

final class Recorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var recording = false
    @Published var startDate = Date()
    @Published var error: String?

    private var stream: SCStream?
    private var file: AVAudioFile?   // touched only on `queue` while recording
    private var tempURL: URL?
    private let queue = DispatchQueue(label: "audio")

    private var starting = false

    @MainActor func start() async {
        guard !recording, !starting else { return }
        starting = true
        defer { starting = false }
        error = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw NSError(domain: "Tapedeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Bildschirm gefunden."]) }

            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
            // Video is required by ScreenCaptureKit but unused: keep it tiny and slow.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tapedeck-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            // Processing format float32 non-interleaved = what ScreenCaptureKit delivers; AVAudioFile converts to 24-bit int.
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            queue.sync { file = f }
            tempURL = url

            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            startDate = Date()
            recording = true
        } catch {
            queue.sync { file = nil }
            self.error = "Aufnahme fehlgeschlagen: \(error.localizedDescription)\nRecht prüfen: Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme."
        }
    }

    @MainActor func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        recording = false
        queue.sync { file = nil }   // releasing AVAudioFile finalizes the WAV header
        guard let tempURL else { return }
        self.tempURL = nil
        onFinished?(tempURL)   // opens the edit window, which saves
    }

    /// Called with the finished temp WAV.
    var onFinished: ((URL) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let file, sb.isValid,
              let fd = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList) == noErr else { return }
        do { try file.write(from: buf) } catch {
            DispatchQueue.main.async { self.error = "Schreibfehler: \(error.localizedDescription)" }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.error = "Aufnahme abgebrochen: \(error.localizedDescription)"
            Task { await self.stop() }   // still offer to save what was recorded
        }
    }
}

// MARK: - Record window: wordmark, counter, record and stop keys

struct ContentView: View {
    @ObservedObject var rec: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("tapedeck").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(Deck.ink)
                Spacer()
                if rec.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        CounterWheels(groups: Self.wheels(Int(ctx.date.timeIntervalSince(rec.startDate))))
                    }
                } else {
                    CounterWheels(groups: Self.wheels(0))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 24)
            KeyTray {
                Button("Aufnahme") { Task { await rec.start() } }
                    .buttonStyle(DeckKeyStyle(latched: rec.recording, dot: true))
                    .help("Aufnahme (Leertaste)")
                Button("Stopp") { Task { await rec.stop() } }
                    .buttonStyle(DeckKeyStyle())
                    .help("Stopp (Leertaste)")
            }
            .padding(.top, 24)
            KeyLabels(texts: ["aufnahme", "stop"]).padding(.top, 12)
            if let e = rec.error {
                Text(e).font(.caption).foregroundStyle(Deck.red).multilineTextAlignment(.center).textSelection(.enabled)
                    .frame(width: 190).padding(.top, 10)
            }
        }
        .padding(.bottom, 22)
        .frame(width: 230)
        .background(Deck.panel)
        // space bar starts and stops, as before
        .background(Button("") { Task { rec.recording ? await rec.stop() : await rec.start() } }
            .keyboardShortcut(.space, modifiers: []).opacity(0))
        .environment(\.colorScheme, .light)   // hardware look stays grey in dark mode
        // closing the main window quits the app (which asks about unsaved recordings)
        .background(WindowCloseHook { NSApp.terminate(nil); return false })
        .onAppear {
            rec.onFinished = { openWindow(value: $0) }
            // `--edit file.wav` opens a copy in the editor (the editor deletes its file on save/discard)
            let args = CommandLine.arguments
            // onAppear can run more than once (e.g. when the appearance is set): open the file only once
            if !Self.editArgHandled, let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
                Self.editArgHandled = true
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Tapedeck-\(UUID().uuidString).wav")
                if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: args[i + 1]), to: copy)) != nil { openWindow(value: copy) }
            }
        }
    }

    private static var editArgHandled = false

    /// Minutes and seconds for the counter wheels (minutes wrap at 100 like a real counter).
    static func wheels(_ s: Int) -> [String] {
        [String(format: "%02d", s / 60 % 100), String(format: "%02d", s % 60)]
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()

    /// The panel is light grey metal: keep light title bars and alerts in dark mode too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    /// ⌘Q / closing the main window: ask for a running recording and every unsaved edit window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.recording {
            let a = NSAlert()
            a.messageText = "Aufnahme läuft"
            a.informativeText = "Beim Beenden geht die laufende Aufnahme verloren."
            a.addButton(withTitle: "Abbrechen")
            a.addButton(withTitle: "Beenden")
            if a.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        for m in EditorModel.open.allObjects where !m.finished {
            if !m.confirmClose() { return .terminateCancel }
        }
        return .terminateNow
    }
}

@main
struct TapedeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            renderIcon(to: args[i + 1])
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("Tapedeck") { ContentView(rec: app.recorder) }
            .windowResizability(.contentSize)
        WindowGroup("Schnitt", for: URL.self) { $url in
            if let url { EditorView(url: url) }
        }
        .defaultSize(width: 1040, height: 500)
    }
}
