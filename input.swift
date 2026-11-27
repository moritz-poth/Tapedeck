// Input devices (microphones, audio interfaces) as a second recording source next to the system audio.
import AVFoundation
import CoreAudio

struct InputDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Live list of the Mac's input devices (updates when one is plugged in or removed).
final class InputDevices: ObservableObject {
    static let shared = InputDevices()
    @Published private(set) var all: [InputDevice] = InputDevices.scan()

    private init() {
        var addr = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.all = Self.scan()
        }
    }

    static func scan() -> [InputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Records one input device into `file`, converted to the file's processing format (48 kHz, stereo float).
final class InputCapture {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    /// `write` runs on the tap thread with each converted buffer; `onStop` on main when the device goes away.
    init(device: InputDevice, outFormat: AVAudioFormat, write: @escaping (AVAudioPCMBuffer) -> Void, onStop: @escaping () -> Void) throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw Self.fail("Eingang lässt sich nicht öffnen.") }
        var dev = device.id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else { throw Self.fail("Eingang „\(device.name)“ lässt sich nicht wählen (\(st)).") }

        // the device's own format: outputFormat(forBus:) still reports the default device after the switch
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else { throw Self.fail("Eingang „\(device.name)“ liefert kein Audio.") }
        // mono goes to both sides; from interfaces with more inputs take the first two
        conv.channelMap = inFormat.channelCount == 1 ? [0, 0] : [0, 1]
        let ratio = outFormat.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buf, _ in
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64) else { return }
            var given = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buf
            }
            if err == nil, out.frameLength > 0 { write(out) }
        }
        // Also fires right after the start and when other devices change: restart while the device is there,
        // stop (keeping the recording so far) only when it is gone or will not run again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.observer != nil else { return }
            guard Self.alive(device.id) else { onStop(); return }
            if !self.engine.isRunning { do { try self.engine.start() } catch { onStop() } }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func alive(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func fail(_ text: String) -> NSError {
        NSError(domain: "Tapedeck", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
