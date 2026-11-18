// Editor "schnitt": tape timeline, In/Out, Extract (cut + close gap), J/K/L shuttle, appended files, clips moved by drag,
// zoom, play, save as WAV.
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// One piece of the timeline: a frame range of one source file.
struct Clip: Equatable {
    var src: Int                 // index into EditorModel.files
    var range: Range<Int>
    var count: Int { range.count }
}

@MainActor final class EditorModel: ObservableObject {
    /// Open editors, so quitting can ask about each unsaved one.
    static let open = NSHashTable<EditorModel>.weakObjects()
    /// Arrow keys step one video frame (25 fps) and play it.
    static let fps = 25.0
    nonisolated static let block = 64            // source frames per waveform peak
    static let minFramesPerPixel = 32.0

    let url: URL
    let sampleRate: Double
    /// Waveform peaks per source file (index = Clip.src). The recording's are filled in after loading.
    @Published var peaks: [[Float]] = [[]]
    /// Name shown on each source's clips (index = Clip.src).
    private(set) var names = ["aufnahme"]
    /// Edit list: clips in timeline order. Extract, import and moving clips only change this list.
    @Published var segments: [Clip]
    private var undoStack: [[Clip]] = []
    var canUndo: Bool { !undoStack.isEmpty }

    @Published var playhead = 0
    @Published var markIn: Int?
    @Published var markOut: Int?
    @Published var framesPerPixel = 1.0
    @Published var viewStart = 0.0
    /// Shuttle speed: 1, 2, 4 forward (L), -1, -2, -4 backward (J), 0 = stopped.
    @Published private(set) var speed = 0
    var playing: Bool { speed != 0 }
    @Published private(set) var importing = false
    /// Timeline index of the clip being dragged.
    @Published private(set) var dragged: Int?
    @Published var error: String?
    /// Vertical waveform zoom as power of two: 0 = 1x … 5 = 32x.
    @Published var ampZoom = 0.0
    /// Set once the file is saved or discarded, so closing the window doesn't ask again.
    private(set) var finished = false   // read by AppDelegate on quit
    var viewWidth = 600.0
    private var isFit = true

    /// Source files: 0 = the recording, then appended files converted to its format. `files` feed the player,
    /// `readers` are separate handles for reverse play and saving (reading moves a file's position).
    private var files: [AVAudioFile]
    private var readers: [AVAudioFile]
    /// Converted copies of appended files; deleted with the recording.
    private var imported: [URL] = []
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private var playStart = 0
    private var timer: Timer?
    /// Reverse play queues one-second buffers; `reverseCursor` is where the next one ends.
    private var reverseCursor = 0
    /// Bumped on every stop, so completion handlers of an old playback don't queue more audio.
    private var generation = 0
    private var dragClip: Clip?
    private var dragBase: [Clip] = []
    private var dragGrab = 0

    init(url: URL) throws {
        self.url = url
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        files = [file]
        readers = [try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)]
        sampleRate = file.processingFormat.sampleRate
        segments = [Clip(src: 0, range: 0..<Int(file.length))]
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: file.processingFormat)
        engine.connect(varispeed, to: engine.mainMixerNode, format: file.processingFormat)
        Self.open.add(self)
        Task {
            let p = try? await Task.detached { try Self.computePeaks(url) }.value
            peaks[0] = p ?? []
            fit()
        }
    }

    deinit { engine.stop() }

    nonisolated static func computePeaks(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(block * 1024)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk)!
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(f.length) / block + 1)
        while f.framePosition < f.length {
            try f.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let chans = Int(buf.format.channelCount)
            var i = 0
            while i < n {
                let end = min(i + block, n)
                var m: Float = 0
                for c in 0..<chans {
                    let p = buf.floatChannelData![c]
                    for j in i..<end { m = max(m, abs(p[j])) }
                }
                peaks.append(m)
                i = end
            }
        }
        return peaks
    }

    var length: Int { segments.reduce(0) { $0 + $1.count } }

    /// Calls `body` with the source file and its frame ranges that make up timeline range `r`.
    func forEachSource(in r: Range<Int>, _ body: (Int, Range<Int>) -> Void) {
        var t = 0
        for s in segments {
            let lo = max(r.lowerBound, t), hi = min(r.upperBound, t + s.count)
            if lo < hi { body(s.src, (s.range.lowerBound + lo - t)..<(s.range.lowerBound + hi - t)) }
            t += s.count
            if t >= r.upperBound { break }
        }
    }

    func peak(_ r: Range<Int>) -> Float {
        var m: Float = 0
        forEachSource(in: r) { src, s in
            let p = peaks[src]
            let lo = s.lowerBound / Self.block, hi = min(p.count - 1, (s.upperBound - 1) / Self.block)
            if lo <= hi { for i in lo...hi { m = max(m, p[i]) } }
        }
        return m
    }

    /// Reads timeline range `r` (across clips) into one buffer.
    private func read(_ r: Range<Int>) throws -> AVAudioPCMBuffer {
        let fmt = files[0].processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(r.count))!
        let tmp = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(r.count))!
        var failure: Error?
        forEachSource(in: r) { src, s in
            guard failure == nil else { return }
            do {
                let f = readers[src]
                f.framePosition = AVAudioFramePosition(s.lowerBound)
                try f.read(into: tmp, frameCount: AVAudioFrameCount(s.count))
                let n = Int(tmp.frameLength), o = Int(buf.frameLength)
                for c in 0..<Int(fmt.channelCount) { (buf.floatChannelData![c] + o).update(from: tmp.floatChannelData![c], count: n) }
                buf.frameLength += AVAudioFrameCount(n)
            } catch { failure = error }
        }
        if let failure { throw failure }
        return buf
    }

    /// Timeline positions of the cuts made so far.
    var editPoints: [Int] {
        var t = 0
        return segments.dropLast().map { t += $0.count; return t }
    }

    // MARK: marks + extract

    func setIn() {
        markIn = playhead
        if let o = markOut, o <= playhead { markOut = nil }
    }

    func setOut() {
        markOut = playhead
        if let i = markIn, i >= playhead { markIn = nil }
    }

    /// Removes In..Out and closes the gap (no In = from start, no Out = to end).
    func extract() {
        guard markIn != nil || markOut != nil else { return }
        let i = markIn ?? 0, o = markOut ?? length
        guard i < o else { return }
        stopPlayback()
        undoStack.append(segments)
        var out: [Clip] = []
        var t = 0
        for s in segments {
            let a = t, b = t + s.count
            if b <= i || a >= o {
                out.append(s)
            } else {
                if a < i { out.append(Clip(src: s.src, range: s.range.lowerBound..<(s.range.lowerBound + i - a))) }
                if b > o { out.append(Clip(src: s.src, range: (s.range.lowerBound + o - a)..<s.range.upperBound)) }
            }
            t = b
        }
        segments = out
        markIn = nil
        markOut = nil
        playhead = min(i, length)
        afterLengthChange()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        stopPlayback()
        segments = prev
        afterLengthChange()
    }

    // MARK: append files

    /// "+": appends audio files at the end, each converted to the recording's format (rate, channels, 24 bit).
    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Audiodateien ans Ende der Timeline anfügen"
        guard panel.runModal() == .OK else { return }
        Task { await append(panel.urls) }
    }

    func append(_ urls: [URL]) async {
        stopPlayback()
        importing = true
        let fmt = files[0].processingFormat, settings = files[0].fileFormat.settings
        let dir = url.deletingLastPathComponent()
        for src in urls {
            let out = dir.appendingPathComponent("Tapedeck-import-\(UUID().uuidString).wav")
            imported.append(out)   // before converting, so a half-written copy is deleted too
            do {
                try await Task.detached { try Self.convert(src, to: out, format: fmt, settings: settings) }.value
                let p = try await Task.detached { try Self.computePeaks(out) }.value
                files.append(try AVAudioFile(forReading: out, commonFormat: .pcmFormatFloat32, interleaved: false))
                readers.append(try AVAudioFile(forReading: out, commonFormat: .pcmFormatFloat32, interleaved: false))
                peaks.append(p)
                names.append(src.lastPathComponent)
                undoStack.append(segments)
                segments.append(Clip(src: files.count - 1, range: 0..<Int(files.last!.length)))
                afterLengthChange()
            } catch {
                self.error = "Import fehlgeschlagen (\(src.lastPathComponent)): \(error.localizedDescription)"
            }
        }
        importing = false
    }

    nonisolated static func convert(_ src: URL, to dst: URL, format: AVAudioFormat, settings: [String: Any]) throws {
        let input = try AVAudioFile(forReading: src)
        let out = try AVAudioFile(forWriting: dst, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let conv = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw NSError(domain: "Tapedeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Format wird nicht unterstützt"])
        }
        conv.downmix = true   // e.g. 5.1 → stereo; mono is copied to both channels
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32768)!
        let ratio = format.sampleRate / input.processingFormat.sampleRate
        let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(32768 * ratio) + 4096)!
        var readError: Error?
        while true {
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                guard input.framePosition < input.length else { st.pointee = .endOfStream; return nil }
                do { try input.read(into: inBuf) } catch { readError = error; st.pointee = .endOfStream; return nil }
                st.pointee = .haveData
                return inBuf
            }
            if let e = readError ?? err { throw e }
            if outBuf.frameLength > 0 { try out.write(from: outBuf) }
            if status == .endOfStream { break }
            if status == .error {
                throw NSError(domain: "Tapedeck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Umwandlung fehlgeschlagen"])
            }
        }
    }

    // MARK: move clips

    /// Starts moving the clip under pixel x; false when there is nothing to reorder.
    func beginDrag(atPixel x: Double) -> Bool {
        guard segments.count > 1 else { return false }
        let f = Int(viewStart + x * framesPerPixel)
        var t = 0, hit: Int?
        for (k, c) in segments.enumerated() {
            if f < t + c.count { hit = k; break }
            t += c.count
        }
        guard let i = hit else { return false }
        stopPlayback()
        undoStack.append(segments)
        dragClip = segments[i]
        dragBase = segments
        dragBase.remove(at: i)
        dragGrab = f - t
        dragged = i
        return true
    }

    /// Puts the dragged clip into the gap nearest to where its start would be now (live, other clips make room).
    func drag(toPixel x: Double) {
        guard let c = dragClip else { return }
        let start = Int(viewStart + x * framesPerPixel) - dragGrab
        var best = 0, bestDist = Int.max, t = 0
        for k in 0...dragBase.count {
            if abs(start - t) < bestDist { best = k; bestDist = abs(start - t) }
            if k < dragBase.count { t += dragBase[k].count }
        }
        guard best != dragged else { return }
        var s = dragBase
        s.insert(c, at: best)
        segments = s
        dragged = best
    }

    func endDrag() {
        if segments == undoStack.last { undoStack.removeLast() }   // dropped where it was: nothing to undo
        dragClip = nil
        dragged = nil
    }

    private func afterLengthChange() {
        if isFit { fit() } else { framesPerPixel = min(framesPerPixel, fitFramesPerPixel); clampView() }
    }

    // MARK: zoom + scroll

    var fitFramesPerPixel: Double { max(Self.minFramesPerPixel, Double(length) / max(1, viewWidth)) }

    /// Zoom knob: 0 = whole recording, 1 = closest zoom (log scale in between).
    var zoomLevel: Double {
        get {
            let fit = fitFramesPerPixel
            guard fit > Self.minFramesPerPixel else { return 0 }
            return min(1, max(0, log(fit / framesPerPixel) / log(fit / Self.minFramesPerPixel)))
        }
        set {
            let fit = fitFramesPerPixel
            guard fit > Self.minFramesPerPixel else { return }
            zoom(fit * pow(Self.minFramesPerPixel / fit, min(1, max(0, newValue))) / framesPerPixel)
        }
    }

    func fit() {
        isFit = true
        framesPerPixel = fitFramesPerPixel
        viewStart = 0
    }

    func zoom(_ factor: Double) {
        let visible = viewStart...(viewStart + viewWidth * framesPerPixel)
        let anchor = visible.contains(Double(playhead)) ? Double(playhead) : viewStart + viewWidth * framesPerPixel / 2
        let ax = (anchor - viewStart) / framesPerPixel
        framesPerPixel = min(fitFramesPerPixel, max(Self.minFramesPerPixel, framesPerPixel * factor))
        isFit = framesPerPixel >= fitFramesPerPixel
        viewStart = anchor - ax * framesPerPixel
        clampView()
    }

    func scroll(pixels: Double) {
        viewStart -= pixels * framesPerPixel
        clampView()
    }

    func resized(width: Double) {
        viewWidth = width
        if isFit { fit() } else { framesPerPixel = min(framesPerPixel, fitFramesPerPixel); clampView() }
    }

    private func clampView() {
        viewStart = min(max(0, viewStart), max(0, Double(length) - viewWidth * framesPerPixel))
    }

    func seek(toPixel x: Double) {
        playhead = min(length, max(0, Int(viewStart + x * framesPerPixel)))
        if playing { play(speed: speed) }
    }

    // MARK: playback

    func togglePlay() { playing ? stopPlayback() : play(speed: 1) }

    /// L (dir 1) / J (dir -1): starts playing that way; pressed again while doing so, doubles the speed up to 4×.
    func shuttle(_ dir: Int) {
        if speed.signum() == dir {
            speed = min(abs(speed) * 2, 4) * dir
            varispeed.rate = Float(abs(speed))   // tape-style: pitch goes up with speed
        } else {
            play(speed: dir)
        }
    }

    private func startEngine() -> Bool {
        do { if !engine.isRunning { try engine.start() } } catch {
            self.error = "Wiedergabe fehlgeschlagen: \(error.localizedDescription)"
            return false
        }
        return true
    }

    /// Queues timeline range start..<end on the player.
    private func schedule(from start: Int, to end: Int) {
        var t = 0
        for s in segments {
            let a = max(start, t), b = min(end, t + s.count)
            if a < b {
                player.scheduleSegment(files[s.src], startingFrame: AVAudioFramePosition(s.range.lowerBound + a - t),
                                       frameCount: AVAudioFrameCount(b - a), at: nil)
            }
            t += s.count
            if t >= end { break }
        }
    }

    /// One video frame back/forward, playing that frame's audio (hold the key to scrub).
    func step(_ dir: Int) {
        stopPlayback()
        let f = Int(sampleRate / Self.fps)
        varispeed.rate = 1
        playhead = min(length, max(0, playhead + dir * f))
        let span = viewWidth * framesPerPixel
        if Double(playhead) < viewStart || Double(playhead) > viewStart + span {
            viewStart = Double(playhead) - span / 2
            clampView()
        }
        guard startEngine() else { return }
        schedule(from: playhead, to: min(length, playhead + f))
        player.play()
    }

    private func play(speed s: Int) {
        stopPlayback()
        if s > 0, playhead >= length { playhead = 0 }
        if s < 0, playhead <= 0 { return }   // nothing before the start
        guard startEngine() else { return }
        varispeed.rate = Float(abs(s))
        playStart = playhead
        if s > 0 {
            schedule(from: playStart, to: length)
        } else {
            reverseCursor = playStart
            for _ in 0..<3 { queueReverseBuffer() }   // keep a few seconds queued; each finished one adds the next
        }
        player.play()
        speed = s
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Queues the second before `reverseCursor`, sample order reversed.
    private func queueReverseBuffer() {
        let end = reverseCursor
        guard end > 0 else { return }
        let start = max(0, end - Int(sampleRate))
        guard let buf = try? read(start..<end) else { return }
        let n = Int(buf.frameLength)
        for c in 0..<Int(buf.format.channelCount) {
            var samples = UnsafeMutableBufferPointer(start: buf.floatChannelData![c], count: n)
            samples.reverse()
        }
        reverseCursor = start
        let gen = generation
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == gen, self.speed < 0 else { return }
                self.queueReverseBuffer()
            }
        }
    }

    func stopPlayback() {
        generation += 1
        player.stop()
        timer?.invalidate()
        timer = nil
        speed = 0
    }

    private func tick() {
        guard let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) else { return }
        // sampleTime counts source frames, also when varispeed plays faster
        let pos = playStart + speed.signum() * Int(pt.sampleTime)
        if pos >= length || pos <= 0 {
            stopPlayback()
            playhead = min(length, max(0, pos))
            return
        }
        playhead = pos
        // page along when the playhead leaves the view
        let span = viewWidth * framesPerPixel
        if Double(pos) > viewStart + span { viewStart = Double(pos); clampView() }
        if Double(pos) < viewStart { viewStart = Double(pos) - span; clampView() }
    }

    // MARK: save / discard

    func time(_ frames: Int) -> String {
        let s = Double(frames) / sampleRate
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    /// Writes the edit list to a new WAV next to the source, in the source's format (48 kHz / 24 bit).
    private func render() throws -> URL {
        let outURL = url.deletingLastPathComponent().appendingPathComponent("Tapedeck-edit-\(UUID().uuidString).wav")
        let out = try AVAudioFile(forWriting: outURL, settings: files[0].fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = length
        var t = 0
        while t < total {
            let n = min(65536, total - t)
            try out.write(from: try read(t..<(t + n)))
            t += n
        }
        return outURL   // `out` is released on return, which finalizes the WAV header
    }

    /// The recording and the converted copies of appended files (the user's originals are never touched).
    private func removeTempFiles() {
        for u in [url] + imported { try? FileManager.default.removeItem(at: u) }
    }

    /// Returns true when the file was saved and the window can close.
    func save() -> Bool {
        stopPlayback()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Aufnahme \(fmt.string(from: Date())).wav"
        guard panel.runModal() == .OK, let dest = panel.url else { return false }
        do {
            let rendered = try render()
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: rendered, to: dest)
            removeTempFiles()
            finished = true
            return true
        } catch {
            self.error = "Speichern fehlgeschlagen: \(error.localizedDescription)\nOriginal liegt noch unter \(url.path)"
            return false
        }
    }

    func discard() -> Bool {
        let a = NSAlert()
        a.messageText = "Aufnahme verwerfen?"
        a.informativeText = "Die Aufnahme wird gelöscht und kann nicht wiederhergestellt werden."
        a.addButton(withTitle: "Verwerfen")
        a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        stopPlayback()
        removeTempFiles()
        finished = true
        return true
    }

    /// Red close button / ⌘W: unsaved recording → ask Save / Discard / Cancel.
    func confirmClose() -> Bool {
        if finished { return true }
        let a = NSAlert()
        a.messageText = "Aufnahme speichern?"
        a.informativeText = "Ohne Speichern geht die Aufnahme verloren."
        a.addButton(withTitle: "Speichern…")
        a.addButton(withTitle: "Verwerfen")
        a.addButton(withTitle: "Abbrechen")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            stopPlayback()
            removeTempFiles()
            finished = true
            return true
        default:
            return false
        }
    }
}

// MARK: - Waveform timeline

/// Wraps SwiftUI's window delegate to ask before closing; everything else is forwarded unchanged.
final class CloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    let shouldClose: () -> Bool
    init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }
    func windowShouldClose(_ w: NSWindow) -> Bool {
        shouldClose() && (original?.windowShouldClose?(w) ?? true)
    }
    override func responds(to sel: Selector!) -> Bool {
        super.responds(to: sel) || (original?.responds(to: sel) ?? false)
    }
    override func forwardingTarget(for sel: Selector!) -> Any? {
        original?.responds(to: sel) == true ? original : nil
    }
}

/// Put in a window's background to decide whether the red close button / ⌘W may close it.
struct WindowCloseHook: NSViewRepresentable {
    let shouldClose: () -> Bool
    func makeNSView(context: Context) -> HookView { HookView(shouldClose) }
    func updateNSView(_ v: HookView, context: Context) {}

    final class HookView: NSView {
        let shouldClose: () -> Bool
        private var closeGuard: CloseGuard?   // window.delegate is weak, so keep it alive here
        init(_ shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, closeGuard == nil else { return }
            let g = CloseGuard(original: w.delegate, shouldClose: shouldClose)
            closeGuard = g
            w.delegate = g
        }
    }
}

final class WaveformNSView: NSView {
    var model: EditorModel?
    override var isFlipped: Bool { true }
    override var clipsToBounds: Bool { get { true } set {} }
    /// Layout of the timeline (pt): ruler with time marks, the In/Out bar below it, then the tape.
    static let ruler: CGFloat = 22
    static let tapeTop: CGFloat = 46
    static let bottomMargin: CGFloat = 26
    /// Click/drag above the tape moves the playhead. On the tape a click places the playhead and a drag moves the clip.
    private var scrubbing = false
    private var downX: CGFloat = 0
    private var draggingClip = false
    private var kHeld = false

    // arrow keys and J/K/L need key focus: take it when shown and on click
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 123: model?.step(-1)   // ←
        case 124: model?.step(1)    // →
        // J/K/L as in editing programs; K held + J/L steps one frame (hold to scrub)
        case 40: if !e.isARepeat { kHeld = true; model?.stopPlayback() }   // K
        case 38: if kHeld { model?.step(-1) } else if !e.isARepeat { model?.shuttle(-1) }   // J
        case 37: if kHeld { model?.step(1) } else if !e.isARepeat { model?.shuttle(1) }     // L
        default: super.keyDown(with: e)
        }
    }
    override func keyUp(with e: NSEvent) {
        if e.keyCode == 40 { kHeld = false } else { super.keyUp(with: e) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let w = Double(newSize.width)
        DispatchQueue.main.async { [weak self] in self?.model?.resized(width: w) }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        scrubbing = p.y < Self.tapeTop - 4
        downX = p.x
        draggingClip = false
        model?.seek(toPixel: Double(p.x))
    }
    override func mouseDragged(with e: NSEvent) {
        guard let m = model else { return }
        let x = convert(e.locationInWindow, from: nil).x
        if scrubbing { m.seek(toPixel: Double(x)); return }
        if !draggingClip, abs(x - downX) > 4 { draggingClip = m.beginDrag(atPixel: Double(downX)) }
        if draggingClip { m.drag(toPixel: Double(x)) }
    }
    override func mouseUp(with e: NSEvent) {
        if draggingClip { model?.endDrag() }
        draggingClip = false
    }

    override func scrollWheel(with e: NSEvent) {
        // trackpad swipes sideways; a mouse wheel scrolls vertically – both move the timeline
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        model?.scroll(pixels: Double(d) * (e.hasPreciseScrollingDeltas ? 1 : 10))
    }

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    private static let tape = rgb(0x2a2623), wave = rgb(0xece6d4), cream = rgb(0xf6f3ea), red = rgb(0xd63c1a)

    /// Ruler step in seconds: the smallest one that keeps labels at least 80 pt apart.
    private static func step(framesPerPixel fpp: Double, rate: Double) -> Double {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]
        return steps.first { $0 * rate / fpp >= 80 } ?? 3600
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Self.rgb(0xdcdde0).cgColor)
        ctx.fill(bounds)
        let fpp = m.framesPerPixel, start = m.viewStart, len = m.length
        func x(_ f: Int) -> CGFloat { CGFloat((Double(f) - start) / fpp) }

        // ruler: minor ticks, major ticks with time
        let rulerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: Self.rgb(0x3a3a3a)]
        ctx.setFillColor(Self.rgb(0x8b8e92).cgColor)
        ctx.fill(CGRect(x: 0, y: Self.ruler, width: bounds.width, height: 1))
        let major = Self.step(framesPerPixel: fpp, rate: m.sampleRate), minor = major / 5
        let firstMinor = Int(floor(start / m.sampleRate / minor))
        var i = firstMinor
        while true {
            let sec = Double(i) * minor
            let px = CGFloat((sec * m.sampleRate - start) / fpp)
            if px > bounds.width { break }
            let isMajor = i % 5 == 0
            ctx.setFillColor(Self.rgb(isMajor ? 0x55585c : 0x8b8e92).cgColor)
            ctx.fill(CGRect(x: px, y: Self.ruler - (isMajor ? 10 : 5), width: 1, height: isMajor ? 10 : 5))
            if isMajor {
                let t = major < 1 ? String(format: "%d:%04.1f", Int(sec) / 60, sec.truncatingRemainder(dividingBy: 60))
                                  : String(format: "%d:%02d", Int(sec) / 60, Int(sec) % 60)
                (t as NSString).draw(at: NSPoint(x: px + 3, y: 2), withAttributes: rulerAttrs)
            }
            i += 1
        }

        guard !m.peaks[0].isEmpty else {
            ("lade wellenform …" as NSString).draw(at: NSPoint(x: 8, y: Self.tapeTop + 8), withAttributes: rulerAttrs)
            return
        }

        // clips: dark tape with a cream waveform, diagonal splicing tape where two clips meet; the dragged one lifted
        let tapeH = max(40, bounds.height - Self.tapeTop - Self.bottomMargin)
        let gain = Float(pow(2, m.ampZoom))
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: Self.rgb(0xd9d3c3)]
        var spans: [(k: Int, a: Int, b: Int)] = []
        var t = 0
        for (k, c) in m.segments.enumerated() { spans.append((k, t, t + c.count)); t += c.count }
        let order = spans.filter { $0.k != m.dragged } + spans.filter { $0.k == m.dragged }
        for sp in order {
            let x0 = x(sp.a), x1 = x(sp.b)
            if x1 < -10 || x0 > bounds.width + 10 { continue }
            let lifted = sp.k == m.dragged
            let top = Self.tapeTop - (lifted ? 10 : 0)
            let r = CGRect(x: x0, y: top, width: x1 - x0, height: tapeH)
            ctx.saveGState()
            if lifted { ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor) }
            ctx.setFillColor(Self.tape.cgColor)
            ctx.fill(r)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: r)
            // waveform as 2 pt bars every 3 pt, centred in the clip below its name
            let mid = top + 18 + (tapeH - 24) / 2, maxH = (tapeH - 24) / 2
            let bars = CGMutablePath()
            var col = max(x0, 0)
            while col < min(x1, bounds.width) {
                let fa = max(sp.a, Int(start + Double(col) * fpp)), fb = min(sp.b, max(fa + 1, Int(start + Double(col + 3) * fpp)))
                if fa < fb {
                    let h = max(1, CGFloat(min(1, m.peak(fa..<fb) * gain)) * maxH)
                    bars.addRect(CGRect(x: col, y: mid - h, width: 2, height: h * 2))
                }
                col += 3
            }
            ctx.addPath(bars)
            ctx.setFillColor(Self.wave.cgColor)
            ctx.fillPath()
            (m.names[m.segments[sp.k].src] as NSString).draw(at: NSPoint(x: x0 + (sp.k > 0 ? 12 : 6), y: top + 4), withAttributes: nameAttrs)
            ctx.restoreGState()
            if sp.k > 0 && !lifted {
                let splice = CGMutablePath()
                splice.addLines(between: [CGPoint(x: x0 - 7 + 6.3, y: top), CGPoint(x: x0 + 7, y: top),
                                          CGPoint(x: x0 - 7 + 7.7, y: top + tapeH), CGPoint(x: x0 - 7, y: top + tapeH)])
                splice.closeSubpath()
                ctx.addPath(splice)
                ctx.setFillColor(Self.cream.withAlphaComponent(0.82).cgColor)
                ctx.fillPath()
            }
            if lifted {
                ctx.setStrokeColor(Self.cream.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(r.insetBy(dx: -1, dy: -1))
            }
        }

        // In/Out: light range over the tape with cream edges, cream bar under the ruler
        if m.markIn != nil || m.markOut != nil {
            let a = x(m.markIn ?? 0), b = x(m.markOut ?? len)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
            ctx.fill(CGRect(x: a, y: Self.tapeTop, width: b - a, height: tapeH))
            ctx.setFillColor(Self.cream.cgColor)
            ctx.fill(CGRect(x: a, y: Self.tapeTop, width: 2, height: tapeH))
            ctx.fill(CGRect(x: b - 2, y: Self.tapeTop, width: 2, height: tapeH))
            let bar = CGRect(x: a, y: 30, width: b - a, height: 10)
            ctx.fill(bar)
            ctx.setStrokeColor(Self.rgb(0x8b8e92).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(bar.insetBy(dx: 0.5, dy: 0.5))
        }

        // playhead: red line with a triangle on the ruler
        let px = x(m.playhead)
        ctx.setFillColor(Self.red.cgColor)
        ctx.fill(CGRect(x: px - 1, y: 0, width: 2, height: Self.tapeTop + tapeH + 6))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: px - 6, y: 0)); ctx.addLine(to: CGPoint(x: px + 6, y: 0)); ctx.addLine(to: CGPoint(x: px, y: 8))
        ctx.closePath()
        ctx.fillPath()
    }
}

struct WaveformView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> WaveformNSView {
        let v = WaveformNSView()
        v.model = model
        return v
    }
    func updateNSView(_ v: WaveformNSView, context: Context) { v.needsDisplay = true }
}

// MARK: - Window

struct EditorView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var model: EditorModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model { EditorContent(model: model) }
            else { Text(loadError ?? "Lade…").foregroundStyle(Deck.label).padding() }
        }
        .frame(minWidth: 1040, minHeight: 500)   // the designed size is the smallest; larger is fine
        .background(Deck.panel)
        .environment(\.colorScheme, .light)   // hardware look stays grey in dark mode
        .onAppear {
            guard model == nil else { return }
            // macOS restores editor windows after a crash: keep them only while their recording still exists
            guard FileManager.default.fileExists(atPath: url.path) else { dismiss(); return }
            do { model = try EditorModel(url: url) } catch {
                loadError = "Aufnahme kann nicht geöffnet werden: \(error.localizedDescription)"
            }
        }
    }
}

struct EditorContent: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    /// Tape guide pin where the tape enters and leaves the timeline frame.
    private struct Pin: View {
        var body: some View {
            Circle().fill(Deck.rgb(0xe8e8e9)).overlay(Circle().strokeBorder(Deck.rgb(0x55585c), lineWidth: 1)).frame(width: 7, height: 7)
        }
    }

    private var status: String? {
        if let e = model.error { return e }
        if model.importing { return "importiere …" }
        if model.speed < 0 || model.speed > 1 { return model.speed < 0 ? "◂ \(-model.speed)×" : "▸ \(model.speed)×" }
        return nil
    }

    private var lengthWheels: [String] {
        let cs = Int((Double(model.length) / model.sampleRate * 100).rounded())
        return [String(cs / 6000), String(format: "%02d", cs / 100 % 60), String(format: "%02d", cs % 100)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("tapedeck").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(Deck.ink)
                    Text("schnitt").font(.system(size: 15, weight: .light)).tracking(-0.2).foregroundStyle(Deck.label)
                }
                .padding(.top, 3)
                Spacer()
                if let status {
                    Text(status).font(.system(size: 11)).foregroundStyle(model.error != nil ? Deck.red : Deck.label)
                        .lineLimit(2).textSelection(.enabled).frame(maxWidth: 420).padding(.top, 5)
                    Spacer()
                }
                VStack(spacing: 6) {
                    CounterWheels(groups: lengthWheels)
                    Text("länge").font(Deck.labelFont).foregroundStyle(Deck.label)
                }
            }
            .padding(.horizontal, 46)
            .padding(.top, 24)

            // timeline in a thin frame like the head cover; the tape runs in over a pin on each side
            GeometryReader { g in
                let tapeY = 14 + WaveformNSView.tapeTop + (g.size.height - 24 - WaveformNSView.tapeTop - WaveformNSView.bottomMargin) / 2
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: tapeY)); p.addLine(to: CGPoint(x: 30, y: tapeY))
                        p.move(to: CGPoint(x: g.size.width - 30, y: tapeY)); p.addLine(to: CGPoint(x: g.size.width, y: tapeY))
                    }
                    .stroke(Deck.rgb(0x3b3835), lineWidth: 1)
                    Pin().position(x: 30, y: tapeY)
                    Pin().position(x: g.size.width - 30, y: tapeY)
                    RoundedRectangle(cornerRadius: 14).stroke(Deck.rgb(0x6f7276), lineWidth: 0.9)
                        .frame(width: g.size.width - 88, height: g.size.height)
                        .offset(x: 44)
                    WaveformView(model: model)
                        .frame(width: g.size.width - 104, height: g.size.height - 24)
                        .offset(x: 52, y: 14)
                        .background(WindowCloseHook { model.confirmClose() })
                }
            }
            .padding(.top, 12)

            HStack(alignment: .top) {
                VStack(spacing: 8) {
                    KeyTray {
                        Button("Rückwärts") { model.shuttle(-1) }.buttonStyle(DeckKeyStyle(latched: model.speed < 0))
                            .help("Rückwärts abspielen (J) – nochmal drücken = schneller")
                        Button("Stopp") { model.stopPlayback() }.buttonStyle(DeckKeyStyle(latched: !model.playing))
                            .help("Stopp (K) – Leertaste: abspielen / stopp")
                        Button("Vorwärts") { model.shuttle(1) }.buttonStyle(DeckKeyStyle(latched: model.speed > 0))
                            .help("Vorwärts abspielen (L) – nochmal drücken = schneller")
                    }
                    KeyLabels(texts: ["◂◂ rückw.", "stop", "vorw. ▸▸"])
                }
                Spacer()
                VStack(spacing: 8) {
                    KeyTray {
                        Button("In") { model.setIn() }.buttonStyle(DeckKeyStyle())
                            .keyboardShortcut("i", modifiers: []).help("In-Punkt setzen (I)")
                        Button("Out") { model.setOut() }.buttonStyle(DeckKeyStyle())
                            .keyboardShortcut("o", modifiers: []).help("Out-Punkt setzen (O)")
                        Button("Schnitt") { model.extract() }.buttonStyle(DeckKeyStyle())
                            .keyboardShortcut("x", modifiers: []).disabled(model.markIn == nil && model.markOut == nil)
                            .help("In bis Out herausschneiden (X)")
                    }
                    KeyLabels(texts: ["in", "out", "schnitt"])
                }
                Spacer()
                VStack(spacing: 8) {
                    KeyTray {
                        Button("Anfügen") { model.importFiles() }.buttonStyle(DeckKeyStyle()).disabled(model.importing)
                            .help("Audiodatei ans Ende anfügen – Clips mit der Maus verschieben")
                        Button("Zurück") { model.undo() }.buttonStyle(DeckKeyStyle())
                            .keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo).help("Rückgängig (⌘Z)")
                    }
                    KeyLabels(texts: ["anfügen", "zurück"])
                }
                Spacer()
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Knob(value: Binding(get: { model.zoomLevel }, set: { model.zoomLevel = $0 }),
                             scale: ["1", "2", "4", "6", "8", "10"], name: "Zoom (⌘+ / ⌘− / ⌘0)")
                            .padding(.top, -15)
                        Text("zoom").font(Deck.labelFont).foregroundStyle(Deck.label).padding(.top, -7)
                    }
                    VStack(spacing: 0) {
                        Knob(value: Binding(get: { model.ampZoom / 5 }, set: { model.ampZoom = $0 * 5 }),
                             scale: ["1", "2", "3", "4", "5", "6"], name: "Höhe der Wellenform")
                            .padding(.top, -15)
                        Text("höhe").font(Deck.labelFont).foregroundStyle(Deck.label).padding(.top, -7)
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    KeyTray {
                        Button("Verwerfen") { if model.discard() { dismiss() } }.buttonStyle(DeckKeyStyle())
                            .help("Aufnahme verwerfen")
                        Button("Sichern") { if model.save() { dismiss() } }.buttonStyle(DeckKeyStyle())
                            .keyboardShortcut(.defaultAction).disabled(model.length == 0).help("Als WAV sichern (↩)")
                    }
                    KeyLabels(texts: ["verwerfen", "sichern"])
                }
            }
            .padding(.horizontal, 46)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        // keys without a key of their own on the panel
        .background {
            Group {
                Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("") { model.zoom(2) }.keyboardShortcut("-", modifiers: .command)
                Button("") { model.zoom(0.5) }.keyboardShortcut("+", modifiers: .command)
                Button("") { model.fit() }.keyboardShortcut("0", modifiers: .command)
            }
            .opacity(0)
        }
    }
}
