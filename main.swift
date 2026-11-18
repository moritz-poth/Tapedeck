// SystemRecorder: records what the Mac plays (system audio) and saves it as WAV 48 kHz / 24 bit.
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers
import CoreImage

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
            guard let display = content.displays.first else { throw NSError(domain: "SystemRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Bildschirm gefunden."]) }

            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
            // Video is required by ScreenCaptureKit but unused: keep it tiny and slow.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SystemRecorder-\(UUID().uuidString).wav")
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

// MARK: - Look: grey plastic panel, grainy key under a clear plastic cap

/// Photographic grain made with Core Image noise, rendered once.
@MainActor enum Texture {
    private static let ctx = CIContext()
    private static func noise(px: Int, streak: Double = 0, contrast: Double = 1) -> NSImage {
        var img = CIFilter(name: "CIRandomGenerator")!.outputImage!
        if streak > 0 {
            img = img.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: streak, kCIInputAngleKey: 0])
        }
        img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: contrast])
        let cg = ctx.createCGImage(img, from: CGRect(x: 200, y: 200, width: px, height: px))!
        return NSImage(cgImage: cg, size: NSSize(width: px / 2, height: px / 2))   // 2 px per pt = Retina-sharp grain
    }
    static let grain = noise(px: 512)
    static let brushed = noise(px: 1024, streak: 30, contrast: 4)
}

struct Grain: View {
    var image: NSImage
    var opacity: Double
    var body: some View {
        Image(nsImage: image).resizable(resizingMode: .tile).blendMode(.overlay).opacity(opacity)
    }
}

/// Satin grey panel with faint horizontal brushing.
struct Panel: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.89), Color(white: 0.81), Color(white: 0.85)], startPoint: .top, endPoint: .bottom)
            Grain(image: Texture.brushed, opacity: 0.7)
            Grain(image: Texture.grain, opacity: 0.12)
            // soft light falloff like a photographed surface
            RadialGradient(colors: [.white.opacity(0.25), .black.opacity(0.08)], center: .init(x: 0.3, y: 0.2), startRadius: 0, endRadius: 500)
        }
        .compositingGroup()
    }
}

/// Key in a moulded bezel: grainy grey surface under clear plastic. `scale` lets the icon reuse it.
struct DeckKey<Symbol: View>: View {
    var pressed: Bool
    var scale: CGFloat = 1
    @ViewBuilder var symbol: Symbol

    var body: some View {
        let r = 14 * scale
        let cap = RoundedRectangle(cornerRadius: r, style: .continuous)
        ZStack {
            // bezel moulded into the panel, lit from above
            RoundedRectangle(cornerRadius: r + 8 * scale, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.6), Color(white: 0.8), Color(white: 0.97)], startPoint: .top, endPoint: .bottom))
            // dark gap around the key
            RoundedRectangle(cornerRadius: r + 3 * scale, style: .continuous)
                .fill(Color(white: 0.18))
                .padding(5 * scale)
            ZStack {
                LinearGradient(colors: [Color(white: 0.75), Color(white: 0.6)], startPoint: .top, endPoint: .bottom)
                Grain(image: Texture.grain, opacity: 0.85)
                symbol
                // clear plastic: soft glare on top, slight lift at the bottom
                LinearGradient(stops: [.init(color: .white.opacity(0.35), location: 0),
                                       .init(color: .white.opacity(0.06), location: 0.4),
                                       .init(color: .clear, location: 0.65),
                                       .init(color: .white.opacity(0.1), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                // thickness of the plastic edge
                cap.strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.3), .black.opacity(0.15)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 2.5 * scale)
                cap.inset(by: 2.5 * scale).strokeBorder(.black.opacity(0.15), lineWidth: scale)
            }
            .compositingGroup()
            .clipShape(cap)
            .brightness(pressed ? -0.06 : 0)
            .shadow(color: .black.opacity(pressed ? 0.25 : 0.4), radius: (pressed ? 0.5 : 1.5) * scale)
            .scaleEffect(pressed ? 0.985 : 1)
            .padding(8 * scale)
        }
    }
}

/// Flat printed red dot, seen through the plastic.
struct RecDot: View {
    var size: CGFloat = 32
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 0.94, green: 0.3, blue: 0.16), Color(red: 0.84, green: 0.2, blue: 0.1)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            // shallow dimple: upper wall in shadow, lower wall catches the light
            .overlay(Circle().fill(LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                                          .init(color: .clear, location: 0.45),
                                                          .init(color: .white.opacity(0.18), location: 1)],
                                                  startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.1), .white.opacity(0.55)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: max(1, size / 22)))
            .padding(max(1, size / 30))
            .background(Circle().fill(LinearGradient(colors: [.black.opacity(0.15), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom)))
            .frame(width: size, height: size)
    }
}

struct LED: View {
    var on: Bool
    var body: some View {
        Circle()
            .fill(on ? AnyShapeStyle(RadialGradient(colors: [Color(red: 1, green: 0.5, blue: 0.4), .red], center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: 7))
                     : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.5)], startPoint: .top, endPoint: .bottom)))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5).offset(y: 0.5))
            .shadow(color: on ? .red.opacity(0.9) : .clear, radius: 5)
    }
}

/// Printed label with a faint highlight below.
struct Printed: View {
    var text: String
    var color: Color
    var size: CGFloat = 17
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .tracking(size * 0.1)
            .foregroundStyle(color)
            .shadow(color: .white.opacity(0.5), radius: 0, y: 1)
    }
}

/// Keeps the key visually down while `latched` (during recording).
struct DeckKeyStyle<Symbol: View>: ButtonStyle {
    var latched = false
    var symbol: Symbol
    func makeBody(configuration: Configuration) -> some View {
        DeckKey(pressed: latched || configuration.isPressed) { symbol }
    }
}

struct ContentView: View {
    @ObservedObject var rec: Recorder
    private let grey = Color(white: 0.5)
    private let red = Color(red: 0.72, green: 0.16, blue: 0.12)

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                LED(on: rec.recording)
                Printed(text: "REC", color: red, size: 22)
            }
            Button(rec.recording ? "Stopp" : "Aufnahme") {
                Task { rec.recording ? await rec.stop() : await rec.start() }
            }
            .buttonStyle(DeckKeyStyle(latched: rec.recording, symbol: RecDot()))
            .frame(width: 180, height: 116)
            .keyboardShortcut(.space, modifiers: [])
            Group {
                if rec.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(rec.startDate))
                        Printed(text: String(format: "%d:%02d", s / 60, s % 60), color: red, size: 13).monospacedDigit()
                    }
                } else {
                    Printed(text: "WAV · 48 kHz · 24 BIT", color: grey, size: 11)
                }
            }
            if let e = rec.error {
                Text(e).font(.caption).foregroundStyle(red).multilineTextAlignment(.center).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 270)
        .background(Panel())
        .environment(\.colorScheme, .light)   // hardware look stays grey in dark mode
        // closing the main window quits the app (which asks about unsaved recordings)
        .background(WindowCloseHook { NSApp.terminate(nil); return false })
        .onAppear {
            rec.onFinished = { openWindow(value: $0) }
            // `--edit file.wav` opens a copy in the editor (the editor deletes its file on save/discard)
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("SystemRecorder-\(UUID().uuidString).wav")
                if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: args[i + 1]), to: copy)) != nil { openWindow(value: copy) }
            }
        }
    }
    @Environment(\.openWindow) private var openWindow
}

// MARK: - App icon (rendered from the same views: `SystemRecorder --render-icon out.png`)

struct IconView: View {
    var body: some View {
        ZStack {
            Panel()
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 3))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
                .frame(width: 824, height: 824)
            VStack(spacing: 40) {
                Printed(text: "REC", color: Color(red: 0.72, green: 0.16, blue: 0.12), size: 120)
                DeckKey(pressed: false, scale: 4) { RecDot(size: 180) }
                    .frame(width: 580, height: 390)
            }
            .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
        .environment(\.colorScheme, .light)
    }
}

@MainActor func renderIcon(to path: String) {
    let r = ImageRenderer(content: IconView())
    r.scale = 1
    guard let cg = r.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { exit(1) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()

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
struct SystemRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            renderIcon(to: args[i + 1])
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("SystemRecorder") { ContentView(rec: app.recorder) }
            .windowResizability(.contentSize)
        WindowGroup("Schnitt", for: URL.self) { $url in
            if let url { EditorView(url: url) }
        }
        .defaultSize(width: 820, height: 300)
    }
}
